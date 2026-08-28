import Foundation

/// Interprets the step vocabulary of §5.3 against a `BrowserSession`.
///
/// This is where "a plugin is data, not code" is cashed out. Every action a
/// plugin can take is one case of the switch below; there is no other way in.
/// Adding a capability to the format means adding a case here, a branch in the
/// JSON Schema, and a paragraph in the contributor guide — deliberately more
/// friction than adding a helper function would be.
public actor StepExecutor {
    private let session: any BrowserSession
    private let context: ExecutionContext
    private let policy: DomainPolicy
    private let logger: RedactingLogger
    private let rateLimiter: RateLimiter
    private let deadline: Deadline
    private let observer: (any StepObserver)?

    public init(session: any BrowserSession,
                context: ExecutionContext,
                policy: DomainPolicy,
                deadline: Deadline,
                logger: RedactingLogger = .shared,
                rateLimiter: RateLimiter = RateLimiter(),
                observer: (any StepObserver)? = nil) {
        self.session = session
        self.context = context
        self.policy = policy
        self.deadline = deadline
        self.logger = logger
        self.rateLimiter = rateLimiter
        self.observer = observer
    }

    public static let defaultStepTimeout: Duration = .seconds(20)

    // MARK: - Running

    public func run(_ steps: [PluginStep], section: String) async throws {
        for (index, step) in steps.enumerated() {
            try Task.checkCancellation()
            guard await !deadline.hasPassed else {
                throw IRError.runBudgetExhausted(seconds: Int(await deadline.budget))
            }
            let label = "\(section)[\(index)] \(step.displayName)"
            await observer?.willRun(step: step, path: label, context: context)
            do {
                try await execute(step, label: label)
                await observer?.didRun(step: step, path: label, error: nil)
            } catch {
                await observer?.didRun(step: step, path: label, error: error)
                throw error
            }
        }
    }

    private func timeout(for step: PluginStep) -> Duration {
        step.timeout.map { .milliseconds($0) } ?? Self.defaultStepTimeout
    }

    private func execute(_ step: PluginStep, label: String) async throws {
        logger.debug("→ \(label)", source: context.source.id, run: context.runID, step: label)

        switch step.action {

        // MARK: Navigation

        case .navigate:
            let resolved = try context.resolve(step.url ?? "")
            guard let url = URL(string: resolved) else {
                throw IRError.assertionFailed("'\(resolved)' is not a URL")
            }
            try check(url)
            // §8.4 rule 2: keep the request rate to something a person could
            // plausibly produce. This is not a formality — it is the difference
            // between a plugin that keeps working and one that gets the user's
            // account rate-limited.
            await rateLimiter.waitForTurn()
            try await session.navigate(to: url)

        case .waitForURL:
            let pattern = try context.resolve(step.url ?? "")
            try await poll(timeout: timeout(for: step), action: step.action.rawValue) {
                guard let current = await self.session.currentURL()?.absoluteString else { return false }
                return Self.matches(pattern: pattern, value: current)
            }

        case .waitForElement:
            let selector = try context.resolve(step.selector ?? "")
            try await poll(timeout: timeout(for: step), action: step.action.rawValue) {
                (try? await self.session.evaluate(DOMScripts.exists(selector)))?.boolValue ?? false
            }

        case .waitForNavigation:
            try await session.waitForNavigation(timeout: timeout(for: step))

        case .waitForNetworkIdle:
            try await session.waitForNetworkIdle(
                idle: .milliseconds(step.idleMs ?? 500), timeout: timeout(for: step))

        // MARK: Interaction

        case .click:
            let selector = try context.resolve(step.selector ?? "")
            let found = try await pollOptional(timeout: timeout(for: step)) {
                (try? await self.session.evaluate(DOMScripts.exists(selector)))?.boolValue ?? false
            }
            if !found {
                if step.optional == true {
                    logger.debug("optional click skipped: \(selector)", run: context.runID, step: label)
                    return
                }
                throw IRError.elementNotFound(selector: selector)
            }
            await rateLimiter.waitForTurn()
            let result = try await session.evaluate(DOMScripts.click(selector))
            if result.objectValue?["ok"]?.boolValue == false {
                throw IRError.elementNotFound(selector: selector)
            }

        case .type:
            let selector = try context.resolve(step.selector ?? "")
            let value = try context.resolve(step.value ?? "")
            try await waitForSelector(selector, timeout: timeout(for: step))
            let result = try await session.evaluate(
                DOMScripts.type(selector, value: value, pressEnter: step.pressEnter ?? false))
            if result.objectValue?["ok"]?.boolValue == false {
                throw IRError.elementNotFound(selector: selector)
            }
            // The value may have been a secret. The log line above only ever
            // held the selector, and the logger would have masked it anyway.

        case .dropdownSelect:
            let selector = try context.resolve(step.selector ?? "")
            let value = try context.resolve(step.value ?? "")
            try await waitForSelector(selector, timeout: timeout(for: step))
            let result = try await session.evaluate(DOMScripts.select(selector, value: value))
            if let reason = result.objectValue?["reason"]?.stringValue {
                throw IRError.assertionFailed("could not select '\(value)' in \(selector): \(reason)")
            }

        case .runJs:
            // Reaching here means the manifest declared usesJs and a human
            // reviewed it. The domain sandbox still applies: whatever this code
            // tries to fetch goes through the same content blocker.
            let code = try context.resolve(step.code ?? "")
            let value = try await session.evaluate(code)
            if let name = step.assignTo { context.set(name, value) }

        // MARK: Verification

        case .checkElementExists:
            let selector = try context.resolve(step.selector ?? "")
            let expected = step.expect ?? true
            let present = try await pollOptional(timeout: timeout(for: step)) {
                let found = (try? await self.session.evaluate(DOMScripts.exists(selector)))?.boolValue ?? false
                return found == expected
            }
            guard present else {
                throw IRError.assertionFailed(
                    expected ? "expected \(selector) to be present" : "expected \(selector) to be absent")
            }

        case .checkURL:
            let pattern = try context.resolve(step.url ?? "")
            let current = await session.currentURL()?.absoluteString ?? ""
            let matched = Self.matches(pattern: pattern, value: current)
            guard matched == (step.expect ?? true) else {
                throw IRError.assertionFailed("URL \(current) does not match \(pattern)")
            }

        // MARK: Extraction

        case .extract:
            let selector = try step.selector.map { try context.resolve($0) }
            let script = DOMScripts.extract(selector, attribute: step.attribute, from: step.from ?? .element)
            if (step.from ?? .element) == .element, let selector, step.optional != true {
                try await waitForSelector(selector, timeout: timeout(for: step))
            }
            var value = try await session.evaluate(script)
            if let regex = step.regex, let text = value.stringValue {
                value = Self.applyRegex(regex, to: text).map { JSONValue.string($0) } ?? .null
            }
            if case .null = value, step.optional != true {
                throw IRError.elementNotFound(selector: selector ?? (step.from ?? .element).rawValue)
            }
            context.set(step.assignTo ?? "value", value)

        case .extractAll:
            // Two sources of rows: elements on the page, or a JSON array an
            // apiRequest put in a variable. A portal that offers an API gives
            // typed values instead of text scraped out of a rendered table, and
            // the loop over them is the same loop.
            let items: [JSONValue]
            let describedBy: String
            if let template = step.items {
                describedBy = template
                let name = Self.bareVariableName(template) ?? template
                guard let value = context.variable(name) ?? context.variable(
                    name.split(separator: ".").first.map(String.init) ?? name) else {
                    throw IRError.assertionFailed(core("no variable named %@ to iterate", name))
                }
                let resolved = name.contains(".")
                    ? value.value(atPath: name.split(separator: ".").dropFirst().joined(separator: ".")) ?? value
                    : value
                guard let array = resolved.arrayValue else {
                    throw IRError.assertionFailed(core("%@ is not a list", name))
                }
                items = step.limit.map { Array(array.prefix($0)) } ?? array
            } else {
                let selector = try context.resolve(step.selector ?? "")
                describedBy = selector
                let rows = try await session.evaluate(
                    DOMScripts.extractAll(selector, fields: step.fields ?? [:], limit: step.limit))
                items = rows.arrayValue ?? []
            }
            let selector = describedBy
            context.noteMatchedRows(items.count)
            logger.info("\(items.count) row(s) matched \(selector)", run: context.runID, step: label)

            for item in items {
                try Task.checkCancellation()
                // `/me/bill` answers with a list of identifiers, not of objects.
                // A scalar row is reachable as {{item}}.
                guard var fields = item.objectValue ?? item.stringValue.map({
                    ["__value": JSONValue.string($0)]
                }) else { continue }
                for (key, spec) in step.fields ?? [:] {
                    guard let regex = spec.regex, let text = fields[key]?.stringValue else { continue }
                    fields[key] = Self.applyRegex(regex, to: text).map { JSONValue.string($0) } ?? .null
                }
                context.pushItem(fields)
                defer { context.popItem() }
                do {
                    try await run(step.forEach ?? [], section: "\(label).forEach")
                } catch let error as IRError where !error.needsUserSignIn {
                    // One unreadable row must not cost the user the other
                    // eleven invoices; the run finishes as partial instead.
                    logger.warning("row skipped: \(error.localizedDescription)",
                                   run: context.runID, step: label)
                }
            }

        case .apiRequest:
            let resolved = try context.resolve(step.url ?? "")
            guard let url = URL(string: resolved) else {
                throw IRError.assertionFailed("'\(resolved)' is not a URL")
            }
            try check(url)
            await rateLimiter.waitForTurn()

            var headers = ["Accept": "application/json"]
            for (name, value) in step.headers ?? [:] {
                headers[name] = try context.resolve(value)
            }
            let response = try await session.requestJSON(
                url: url,
                method: (step.method ?? "GET").uppercased(),
                headers: headers,
                body: step.body.map { try context.resolve($0) },
                timeout: timeout(for: step))

            // An API says "your session is gone" with a status code, where a
            // page says it by redirecting. Both mean the same thing to the
            // user, so both must produce the same offer to sign in again
            // rather than a raw HTTP error they can do nothing with.
            // 471 is not a registered status: it is OVHcloud's "low order
            // session", meaning the session is real but too weak for this
            // call, which is again resolved by signing in.
            if [401, 403, 471].contains(response.status) {
                throw IRError.authenticationRequired(core(
                    "%@ no longer accepts this session", url.host ?? url.absoluteString))
            }
            guard response.isSuccess else {
                throw IRError.assertionFailed(core(
                    "%1$@ answered %2$@: %3$@", url.host ?? url.absoluteString,
                    String(response.status),
                    response.text?.prefix(200).description ?? ""))
            }
            let value = step.jsonPath.flatMap { response.json.value(atPath: $0) } ?? response.json
            context.set(step.assignTo ?? "response", value)
            logger.debug("\(url.path) → \(value.arrayValue.map { "\($0.count) item(s)" } ?? "object")",
                         run: context.runID, step: label)

        case .extractNetworkResponse:
            let pattern = try context.resolve(step.url ?? "")
            let deadline = Date().addingTimeInterval(timeout(for: step).seconds)
            var found: JSONValue?
            while Date() < deadline, found == nil {
                for response in await session.drainNetworkResponses()
                where Self.matches(pattern: pattern, value: response.url.absoluteString) {
                    guard let body = response.body,
                          let any = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
                    else { continue }
                    let json = JSONValue(any: any)
                    found = step.jsonPath.flatMap { json.value(atPath: $0) } ?? json
                    break
                }
                if found == nil { try await Task.sleep(for: .milliseconds(200)) }
            }
            guard let found else {
                throw IRError.stepTimedOut(action: "extractNetworkResponse",
                                           milliseconds: Int(timeout(for: step).seconds * 1000))
            }
            context.set(step.assignTo ?? "response", found)

        // MARK: Documents

        case .downloadPdf:
            let resolved = try context.resolve(step.url ?? "")
            guard let url = URL(string: resolved) else {
                throw IRError.assertionFailed("'\(resolved)' is not a URL")
            }
            try check(url)
            await rateLimiter.waitForTurn()
            let data = try await session.download(from: url, timeout: timeout(for: step))
            try emit(step, data: data)

        case .waitForPdfDownload:
            let data = try await session.awaitPendingDownload(timeout: timeout(for: step))
            try emit(step, data: data)

        case .printPdf:
            if let selector = step.selector {
                try await waitForSelector(try context.resolve(selector), timeout: timeout(for: step))
            }
            let data = try await session.printToPDF()
            try emit(step, data: data)

        case .downloadBase64Pdf:
            let raw = try context.resolve(step.data ?? "")
            // Portals hand this over as a bare payload or as a data: URI.
            let payload = raw.contains(",") && raw.hasPrefix("data:")
                ? String(raw[raw.index(after: raw.firstIndex(of: ",")!)...]) : raw
            guard let data = Data(base64Encoded: payload.trimmingCharacters(in: .whitespacesAndNewlines),
                                  options: .ignoreUnknownCharacters) else {
                throw IRError.assertionFailed("the value passed to downloadBase64Pdf is not base64")
            }
            try emit(step, data: data)

        // MARK: Control flow

        case .ifStep:
            guard let condition = step.condition else {
                throw IRError.assertionFailed("if without a condition")
            }
            if try await evaluate(condition) {
                try await run(step.then ?? [], section: "\(label).then")
            } else if let alternative = step.else {
                try await run(alternative, section: "\(label).else")
            }

        case .sleep:
            let ms = min(step.ms ?? 0, 30_000)
            try await Task.sleep(for: .milliseconds(ms))

        case .exposeOption:
            let key = step.key ?? "option"
            let label = try context.resolve(step.label ?? key)
            var choices: [ConfigOption] = []
            if let template = step.values, let value = try? context.resolve(template) {
                choices = Self.parseChoices(value)
            } else if let template = step.values,
                      let name = Self.bareVariableName(template),
                      let value = context.variable(name) {
                choices = Self.parseChoices(value)
            }
            context.addExposedOption(ExposedOption(key: key, label: label, choices: choices,
                                                   allowsMultiple: step.multiple ?? false))
        }
    }

    // MARK: - Documents

    private func emit(_ step: PluginStep, data: Data) throws {
        guard let descriptor = step.document else {
            throw IRError.assertionFailed("\(step.action.rawValue) without a document")
        }
        guard !data.isEmpty else {
            throw IRError.assertionFailed("the downloaded document is empty")
        }

        let identifier = try context.resolve(descriptor.id)
        guard !identifier.isEmpty else {
            throw IRError.assertionFailed("the document id resolved to an empty string")
        }

        var document = CollectedDocument(pluginDocumentID: identifier, data: data,
                                         kind: descriptor.type ?? .invoice)

        let rawDate = try context.resolve(descriptor.date)
        document.issuedOn = InvoiceDateParser.parse(rawDate)
        if document.issuedOn == nil {
            logger.warning("could not read the date '\(rawDate)' for document \(identifier)",
                           run: context.runID)
        }

        let currency = context.resolveOptional(descriptor.currency)
        document.total = context.resolveOptional(descriptor.total).flatMap {
            MoneyParser.parse($0, defaultCurrency: currency)
        }
        document.net = context.resolveOptional(descriptor.net).flatMap {
            MoneyParser.parse($0, defaultCurrency: currency ?? document.total?.currency)
        }
        document.vat = context.resolveOptional(descriptor.vat).flatMap {
            MoneyParser.parse($0, defaultCurrency: currency ?? document.total?.currency)
        }
        document.number = context.resolveOptional(descriptor.number)
        document.issuer = context.resolveOptional(descriptor.issuer) ?? context.manifest.name
        for (key, template) in descriptor.metadata ?? [:] {
            if let value = context.resolveOptional(template) { document.metadata[key] = value }
        }

        context.addDocument(document)
        logger.info("collected \(identifier) (\(data.count) bytes)", run: context.runID)
    }

    // MARK: - Conditions

    private func evaluate(_ condition: StepCondition) async throws -> Bool {
        switch condition {
        case .elementExists(let selector):
            let resolved = try context.resolve(selector)
            return (try await session.evaluate(DOMScripts.exists(resolved))).boolValue
        case .urlMatches(let pattern):
            let resolved = try context.resolve(pattern)
            let current = await session.currentURL()?.absoluteString ?? ""
            return Self.matches(pattern: resolved, value: current)
        case .variableEquals(let name, let value):
            return context.lookup(name) == (try context.resolve(value))
        case .variableIsSet(let name):
            guard let value = context.lookup(name) else { return false }
            return !value.isEmpty
        case .not(let inner):
            return !(try await evaluate(inner))
        }
    }

    // MARK: - Helpers

    /// The domain sandbox, checked again here even though the session enforces
    /// it. Belt and braces: this gives the user a clear error naming the host
    /// instead of an opaque navigation failure, and it keeps working if a
    /// future driver's enforcement has a gap.
    private func check(_ url: URL) throws {
        guard policy.allows(url: url) else {
            throw IRError.domainNotAllowed(host: url.host ?? url.absoluteString, allowed: policy.patterns)
        }
    }

    private func waitForSelector(_ selector: String, timeout: Duration) async throws {
        let found = try await pollOptional(timeout: timeout) {
            (try? await self.session.evaluate(DOMScripts.exists(selector)))?.boolValue ?? false
        }
        guard found else { throw IRError.elementNotFound(selector: selector) }
    }

    private func poll(timeout: Duration, action: String,
                      until predicate: @Sendable () async -> Bool) async throws {
        guard try await pollOptional(timeout: timeout, until: predicate) else {
            throw IRError.stepTimedOut(action: action, milliseconds: Int(timeout.seconds * 1000))
        }
    }

    private func pollOptional(timeout: Duration,
                              until predicate: @Sendable () async -> Bool) async throws -> Bool {
        let stepDeadline = min(Date().addingTimeInterval(timeout.seconds), await deadline.date)
        while Date() < stepDeadline {
            try Task.checkCancellation()
            if await predicate() { return true }
            try await Task.sleep(for: .milliseconds(150))
        }
        return await predicate()
    }

    /// Glob matching for URL patterns: `*` stands for any run of characters,
    /// everything else is literal. Contributors reach for this shape before
    /// they reach for a regular expression, and it is much harder to get wrong.
    ///
    /// Public because it defines what `waitForURL` and `checkURL` mean, which
    /// is part of the plugin format rather than an implementation detail.
    public static func matches(pattern: String, value: String) -> Bool {
        if pattern.isEmpty { return true }
        if !pattern.contains("*") { return value.contains(pattern) }
        let escaped = pattern.split(separator: "*", omittingEmptySubsequences: false)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: ".*")
        guard let regex = try? NSRegularExpression(pattern: "^" + escaped + "$") else { return false }
        return regex.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) != nil
    }

    /// Public for the same reason as `matches`: it defines what a step's
    /// `regex` field does.
    public static func applyRegex(_ pattern: String, to text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        // Capture group 1 when the contributor provided one, whole match
        // otherwise: both spellings appear in real plugins.
        let range = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound
            ? match.range(at: 1) : match.range
        return ns.substring(with: range)
    }

    static func bareVariableName(_ template: String) -> String? {
        let trimmed = template.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{{"), trimmed.hasSuffix("}}") else { return nil }
        return String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
    }

    static func parseChoices(_ value: String) -> [ConfigOption] {
        guard let data = value.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return []
        }
        return parseChoices(json)
    }

    static func parseChoices(_ value: JSONValue) -> [ConfigOption] {
        guard let array = value.arrayValue else { return [] }
        return array.compactMap { element in
            if let object = element.objectValue {
                guard let value = object["value"]?.stringValue else { return nil }
                return ConfigOption(value: value, label: object["label"]?.stringValue ?? value)
            }
            guard let string = element.stringValue else { return nil }
            return ConfigOption(value: string, label: string)
        }
    }
}

// MARK: - Observation

/// Hook for the developer mode's step-by-step execution (F10.5). The engine
/// does not know whether anyone is watching.
public protocol StepObserver: Sendable {
    func willRun(step: PluginStep, path: String, context: ExecutionContext) async
    func didRun(step: PluginStep, path: String, error: (any Error)?) async
}

/// Enforces a human-ish request rate (§8.4 rule 2).
public actor RateLimiter {
    private let minimumInterval: Duration
    private var lastRequest: Date?

    public init(minimumInterval: Duration = .milliseconds(700)) {
        self.minimumInterval = minimumInterval
    }

    public func waitForTurn() async {
        if let last = lastRequest {
            let elapsed = Date().timeIntervalSince(last)
            let remaining = minimumInterval.seconds - elapsed
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
        }
        lastRequest = Date()
    }
}

extension Duration {
    public var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}


/// A run's time budget, which the interactive sign-in can push forward.
///
/// A plain `Date` was wrong: it made the person's own time — finding a phone,
/// typing a two-factor code — count against the automation's, so a careful
/// sign-in left nothing for the collection it existed to unlock.
public actor Deadline {
    public private(set) var budget: TimeInterval
    public private(set) var date: Date

    public init(_ budget: TimeInterval) {
        self.budget = budget
        self.date = Date().addingTimeInterval(budget)
    }

    public var hasPassed: Bool { Date() >= date }

    public func extend(by seconds: TimeInterval) {
        guard seconds > 0 else { return }
        date = date.addingTimeInterval(seconds)
    }
}

import Foundation

/// Validates a manifest beyond what the JSON Schema can express.
///
/// The same rules run in three places, and they must agree: the plugins repo
/// CI (§9.3), the developer mode inside the app (F10.5), and the loader that
/// refuses to install a bad plugin. Contributors should never discover in
/// review a rule the app could have told them about locally.
public enum PluginValidator {

    public struct Issue: Sendable, Hashable, Identifiable {
        public var id: String { "\(severity)-\(path)-\(message)" }
        public enum Severity: String, Sendable, Comparable {
            case error, warning, info
            public static func < (l: Severity, r: Severity) -> Bool {
                let order: [Severity] = [.error, .warning, .info]
                return order.firstIndex(of: l)! < order.firstIndex(of: r)!
            }
        }
        public var severity: Severity
        public var path: String
        public var message: String
        public var hint: String?

        public init(severity: Severity, path: String, message: String, hint: String? = nil) {
            self.severity = severity; self.path = path
            self.message = message; self.hint = hint
        }
    }

    public struct Report: Sendable {
        public var issues: [Issue]
        public var isValid: Bool { !issues.contains { $0.severity == .error } }
        public var requiresHumanReview: Bool
        public var errors: [Issue] { issues.filter { $0.severity == .error } }
        public var warnings: [Issue] { issues.filter { $0.severity == .warning } }

        public init(issues: [Issue], requiresHumanReview: Bool) {
            self.issues = issues
            self.requiresHumanReview = requiresHumanReview
        }
    }

    public static func validate(_ m: PluginManifest,
                                engineVersion: SemVer = PluginManifest.engineVersion) -> Report {
        var issues: [Issue] = []

        // --- API transport --------------------------------------------------
        if let api = m.api {
            let policy = m.domainPolicy

            func requireAllowed(_ raw: String, _ path: String) {
                guard let url = URL(string: raw), let host = url.host else {
                    issues.append(.init(severity: .error, path: path,
                                        message: "'\(raw)' is not a URL"))
                    return
                }
                if !policy.allows(host: host) {
                    issues.append(.init(severity: .error, path: path,
                                        message: "\(host) is not in allowedDomains",
                                        hint: "Add \"\(host)\" — the sandbox applies to API calls too."))
                }
            }
            requireAllowed(api.baseURL, "api.baseUrl")
            if URL(string: api.baseURL)?.scheme != "https" {
                issues.append(.init(severity: .error, path: "api.baseUrl",
                                    message: "the API base must be https",
                                    hint: "Credentials would otherwise travel in clear."))
            }

            // A plugin with no browser cannot click, type or run scripts. Say
            // so here rather than letting a user discover it mid-collection.
            let browserOnly: Set<StepAction> = [
                .navigate, .waitForURL, .waitForElement, .waitForNavigation, .waitForNetworkIdle,
                .click, .type, .dropdownSelect, .runJs, .checkElementExists, .checkURL,
                .extractNetworkResponse, .waitForPdfDownload, .printPdf, .downloadBase64Pdf,
            ]
            for (step, path) in walkSteps(m) where browserOnly.contains(step.action) {
                issues.append(.init(severity: .error, path: path,
                                    message: "'\(step.action.rawValue)' needs a browser, "
                                           + "and this plugin declares an API",
                                    hint: "API plugins use apiRequest, extractAll over items, "
                                        + "extract and downloadPdf."))
            }
            if m.startAuth != nil {
                issues.append(.init(severity: .error, path: "startAuth",
                                    message: "an API plugin has no interactive sign-in",
                                    hint: "Credentials are entered once; remove startAuth."))
            }

            switch api.auth?.type {
            case .signature:
                guard let signature = api.auth?.signature else {
                    issues.append(.init(severity: .error, path: "api.auth.signature",
                                        message: "a signed API needs a signature recipe"))
                    break
                }
                if signature.parts.isEmpty {
                    issues.append(.init(severity: .error, path: "api.auth.signature.parts",
                                        message: "the signature has no parts to hash"))
                }
                if signature.algorithm.isHMAC, signature.key == nil {
                    issues.append(.init(severity: .error, path: "api.auth.signature.key",
                                        message: "\(signature.algorithm.rawValue) needs a key"))
                }
                if let time = api.auth?.time { requireAllowed(time.url, "api.auth.time.url") }
            case .oauth2ClientCredentials:
                guard let token = api.auth?.token else {
                    issues.append(.init(severity: .error, path: "api.auth.token",
                                        message: "OAuth2 needs a token endpoint"))
                    break
                }
                requireAllowed(token.url, "api.auth.token.url")
            case .basic:
                if api.auth?.username == nil || api.auth?.password == nil {
                    issues.append(.init(severity: .error, path: "api.auth",
                                        message: "basic authentication needs a username and a password"))
                }
            case .header, .none:
                break
            }

            // Credentials belong in the Keychain, and only a password-typed
            // field goes there. A key pasted into a plain string field would
            // sit in the database in clear.
            for (key, field) in m.configSchema ?? [:] {
                let looksSecret = ["secret", "password", "token", "consumerkey", "privatekey", "apikey"]
                    .contains { key.lowercased().contains($0) }
                if looksSecret, field.type != .password, field.type != .totp {
                    issues.append(.init(severity: .error, path: "configSchema.\(key)",
                                        message: "'\(key)' looks like a credential but is not a password field",
                                        hint: "Only password fields reach the Keychain."))
                }
            }
        }

        // --- Identity -------------------------------------------------------
        if m.id.range(of: "^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$", options: .regularExpression) == nil {
            issues.append(.init(severity: .error, path: "id",
                                message: "'\(m.id)' is not a valid identifier",
                                hint: "Lowercase letters, digits and hyphens, 3 to 50 characters."))
        }
        if SemVer(m.version) == nil {
            issues.append(.init(severity: .error, path: "version",
                                message: "'\(m.version)' is not a semantic version"))
        }
        guard let requirement = VersionRequirement(m.engine) else {
            issues.append(.init(severity: .error, path: "engine",
                                message: "'\(m.engine)' is not a version requirement",
                                hint: "Use \">=1.0.0\", \"^1.0.0\" or \"~1.0.0\"."))
            return Report(issues: issues, requiresHumanReview: m.containsArbitraryJavaScript)
        }
        if !requirement.isSatisfied(by: engineVersion) {
            issues.append(.init(severity: .error, path: "engine",
                                message: "requires engine \(m.engine); this build implements \(engineVersion)"))
        }

        // An author who uses new vocabulary but leaves `engine` at ">=1.0.0"
        // ships a plugin that older applications reject as *invalid*, which
        // sends their users hunting for a fault that is not there. Catch it
        // here, where it costs one line to fix.
        let floor = requiredEngineFloor(m)
        if floor > SemVer(1, 0, 0), requirement.isSatisfied(by: SemVer(1, 0, 0)) {
            issues.append(.init(severity: .error, path: "engine",
                                message: "uses vocabulary introduced in engine \(floor) "
                                       + "but '\(m.engine)' also admits older engines",
                                hint: "set \"engine\": \">=\(floor)\""))
        }

        // --- The network sandbox -------------------------------------------
        if m.allowedDomains.isEmpty {
            issues.append(.init(severity: .error, path: "allowedDomains",
                                message: "allowedDomains must not be empty",
                                hint: "Without it the plugin could navigate anywhere carrying the user's session."))
        }
        for domain in m.allowedDomains {
            if domain.range(of: "^(\\*\\.)?([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$",
                            options: .regularExpression) == nil {
                issues.append(.init(severity: .error, path: "allowedDomains",
                                    message: "'\(domain)' is not a valid domain pattern",
                                    hint: "Only a leading *. wildcard is supported."))
            }
            // "*.com" or "*.co.uk" would hand the plugin a whole TLD.
            let labels = domain.replacingOccurrences(of: "*.", with: "").split(separator: ".")
            if domain.hasPrefix("*.") && labels.count < 2 {
                issues.append(.init(severity: .error, path: "allowedDomains",
                                    message: "'\(domain)' is far too broad"))
            }
        }

        let policy = m.domainPolicy
        let referenced = DomainPolicy.staticallyReferencedHosts(in: m.allSteps)
        for host in referenced.sorted() where !policy.allows(host: host) {
            issues.append(.init(severity: .error, path: "allowedDomains",
                                message: "the plugin navigates to \(host), which allowedDomains does not cover",
                                hint: "Add \"\(host)\" or \"*.\(host.split(separator: ".").suffix(2).joined(separator: "."))\"."))
        }

        // --- Arbitrary JavaScript ------------------------------------------
        let hasJS = m.containsArbitraryJavaScript
        if hasJS && m.usesJs != true {
            issues.append(.init(severity: .error, path: "usesJs",
                                message: "the plugin contains runJs steps but does not declare usesJs: true",
                                hint: "The badge shown to users is derived from the steps; the declaration must match."))
        }
        if !hasJS && m.usesJs == true {
            issues.append(.init(severity: .warning, path: "usesJs",
                                message: "usesJs is declared but no runJs step is present"))
        }
        if hasJS {
            issues.append(.init(severity: .info, path: "usesJs",
                                message: "contains runJs; merging requires human review, CI alone cannot approve it"))
        }

        // --- Sections -------------------------------------------------------
        if m.checkAuth.isEmpty {
            issues.append(.init(severity: .error, path: "checkAuth", message: "checkAuth must not be empty"))
        } else if let last = m.checkAuth.last,
                  // For an API plugin the call *is* the verification: an
                  // authenticated endpoint answers 401 when the keys are wrong,
                  // which the engine turns into "credentials refused". There is
                  // no URL to compare and no element to look for.
                  !(m.isAPIOnly && last.action == .apiRequest),
                  ![.checkURL, .checkElementExists, .runJs].contains(last.action) {
            issues.append(.init(severity: .error, path: "checkAuth",
                                message: "checkAuth must end in a verification step",
                                hint: "Finish with checkURL or checkElementExists so the engine can tell signed-in from signed-out."))
        }
        if m.getDocuments.isEmpty {
            issues.append(.init(severity: .error, path: "getDocuments", message: "getDocuments must not be empty"))
        }
        if !producesAnyDocument(m.getDocuments) {
            issues.append(.init(severity: .error, path: "getDocuments",
                                message: "getDocuments never emits a document",
                                hint: "Use downloadPdf, printPdf, waitForPdfDownload or downloadBase64Pdf."))
        }

        // --- Steps ----------------------------------------------------------
        issues += validateSteps(m.checkAuth, path: "checkAuth", manifest: m)
        if let s = m.startAuth { issues += validateSteps(s, path: "startAuth", manifest: m) }
        if let s = m.getConfigOptions { issues += validateSteps(s, path: "getConfigOptions", manifest: m) }
        issues += validateSteps(m.getDocuments, path: "getDocuments", manifest: m)

        // --- Config ---------------------------------------------------------
        let declared = Set((m.configSchema ?? [:]).keys)
        // The transport's own templates use credentials too — an API key
        // appears only in a signature recipe, never in a step.
        var used = referencedConfigKeys(in: m.allSteps)
        used.formUnion(referencedConfigKeys(inTemplates: m.api.map(transportTemplates) ?? []))
        for key in used.subtracting(declared).sorted() {
            issues.append(.init(severity: .error, path: "configSchema",
                                message: "steps reference {{config.\(key)}} or {{secret.\(key)}} but configSchema does not declare '\(key)'"))
        }
        for key in declared.subtracting(used).sorted() {
            issues.append(.init(severity: .warning, path: "configSchema.\(key)",
                                message: "'\(key)' is asked of the user but never used",
                                hint: "Do not collect what you do not need."))
        }

        // --- Editorial ------------------------------------------------------
        if m.country?.isEmpty ?? true {
            issues.append(.init(severity: .warning, path: "country",
                                message: "no country declared; the plugin will be hard to find in the catalogue"))
        }
        if m.description?.isEmpty ?? true {
            issues.append(.init(severity: .warning, path: "description", message: "no description"))
        }
        if m.maintainers?.isEmpty ?? true {
            issues.append(.init(severity: .warning, path: "maintainers",
                                message: "no maintainer; the plugin will be archived if it breaks"))
        }

        issues += detectSuspectedSecrets(m)

        return Report(issues: issues, requiresHumanReview: hasJS)
    }

    // MARK: - Steps

    private static func validateSteps(_ steps: [PluginStep], path: String,
                                      manifest: PluginManifest) -> [Issue] {
        var issues: [Issue] = []
        for (index, step) in steps.enumerated() {
            let p = "\(path)[\(index)]"
            issues += validate(step, path: p, manifest: manifest)
            if !step.nestedSteps.isEmpty {
                if let f = step.forEach { issues += validateSteps(f, path: "\(p).forEach", manifest: manifest) }
                if let t = step.then { issues += validateSteps(t, path: "\(p).then", manifest: manifest) }
                if let e = step.else { issues += validateSteps(e, path: "\(p).else", manifest: manifest) }
            }
        }
        return issues
    }

    private static func validate(_ step: PluginStep, path: String,
                                 manifest: PluginManifest) -> [Issue] {
        var issues: [Issue] = []
        func require(_ present: Bool, _ field: String) {
            if !present {
                issues.append(.init(severity: .error, path: path,
                                    message: "\(step.action.rawValue) requires '\(field)'"))
            }
        }

        switch step.action {
        case .navigate:
            require(step.url != nil, "url")
            if let u = step.url, !u.hasPrefix("https://"), !u.contains("{{") {
                issues.append(.init(severity: .error, path: path,
                                    message: "navigate must use https", hint: "Plain http would expose the session."))
            }
        case .waitForURL, .checkURL:
            require(step.url != nil, "url")
        case .waitForElement, .click, .checkElementExists:
            require(step.selector != nil, "selector")
        case .type:
            require(step.selector != nil, "selector")
            require(step.value != nil, "value")
        case .dropdownSelect:
            require(step.selector != nil, "selector")
            require(step.value != nil, "value")
        case .runJs:
            require(step.code != nil, "code")
        case .extract:
            require(step.assignTo != nil, "assignTo")
            if (step.from ?? .element) == .element && step.selector == nil {
                issues.append(.init(severity: .error, path: path,
                                    message: "extract from an element requires 'selector'"))
            }
        case .extractAll:
            require(step.forEach != nil, "forEach")
            if step.selector == nil && step.items == nil {
                issues.append(.init(severity: .error, path: path,
                                    message: "extractAll needs either 'selector' or 'items'",
                                    hint: "'selector' walks elements on the page; 'items' walks a JSON list an apiRequest produced."))
            }
            if step.selector != nil && step.items != nil {
                issues.append(.init(severity: .error, path: path,
                                    message: "extractAll takes 'selector' or 'items', not both"))
            }

        case .apiRequest:
            require(step.url != nil, "url")
            require(step.assignTo != nil, "assignTo")
            if let method = step.method,
               !["GET", "POST", "PUT", "PATCH", "DELETE"].contains(method.uppercased()) {
                issues.append(.init(severity: .error, path: path,
                                    message: "'\(method)' is not an HTTP method"))
            }
            // A plugin collecting invoices has no business changing anything on
            // the portal, and §8.4 says collect nothing but the user's own
            // documents. Reading is the whole job.
            if let method = step.method, !["GET", "POST"].contains(method.uppercased()) {
                issues.append(.init(severity: .error, path: path,
                                    message: "only GET and POST are allowed; a collector does not modify a portal"))
            }
            // A relative path takes its scheme from api.baseUrl, which is
            // required to be https in its own right.
            if let url = step.url, !url.hasPrefix("https://"), !url.contains("{{"),
               !(manifest.isAPIOnly && url.hasPrefix("/")) {
                issues.append(.init(severity: .error, path: path,
                                    message: "apiRequest must use https"))
            }
        case .extractNetworkResponse:
            require(step.url != nil, "url")
            require(step.assignTo != nil, "assignTo")
        case .downloadPdf:
            require(step.url != nil, "url")
            require(step.document != nil, "document")
        case .waitForPdfDownload, .printPdf:
            require(step.document != nil, "document")
        case .downloadBase64Pdf:
            require(step.data != nil, "data")
            require(step.document != nil, "document")
        case .ifStep:
            require(step.condition != nil, "condition")
            require(step.then != nil, "then")
        case .sleep:
            require(step.ms != nil, "ms")
            if let ms = step.ms, ms > 30_000 {
                issues.append(.init(severity: .error, path: path, message: "sleep is capped at 30000 ms"))
            }
        case .exposeOption:
            require(step.key != nil, "key")
            require(step.label != nil, "label")
        case .waitForNavigation, .waitForNetworkIdle:
            break
        }

        if let regex = step.regex, (try? NSRegularExpression(pattern: regex)) == nil {
            issues.append(.init(severity: .error, path: path, message: "invalid regular expression: \(regex)"))
        }
        if let timeout = step.timeout, timeout < 100 || timeout > 120_000 {
            issues.append(.init(severity: .error, path: path, message: "timeout must be between 100 and 120000 ms"))
        }
        if let doc = step.document {
            if doc.id.isEmpty { issues.append(.init(severity: .error, path: "\(path).document.id", message: "document id must not be empty")) }
            if doc.date.isEmpty { issues.append(.init(severity: .error, path: "\(path).document.date", message: "document date must not be empty")) }
            if doc.total == nil {
                issues.append(.init(severity: .warning, path: "\(path).document",
                                    message: "no total; the user will have to rely on text extraction for the amount"))
            }
        }
        return issues
    }

    // MARK: - Helpers

    private static func producesAnyDocument(_ steps: [PluginStep]) -> Bool {
        for step in steps {
            if step.action.producesDocument { return true }
            if producesAnyDocument(step.nestedSteps) { return true }
        }
        return false
    }

    /// Every `{{config.x}}` / `{{secret.x}}` referenced anywhere in the plugin.
    /// Same scan, over a bare list of templates.
    static func referencedConfigKeys(inTemplates templates: [String]) -> Set<String> {
        var keys: Set<String> = []
        let pattern = try! NSRegularExpression(pattern: "\\{\\{\\s*(?:config|secret|totp)\\.([a-zA-Z0-9_]+)")
        for text in templates {
            let ns = text as NSString
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                keys.insert(ns.substring(with: match.range(at: 1)))
            }
        }
        return keys
    }

    static func referencedConfigKeys(in steps: [PluginStep]) -> Set<String> {
        var keys: Set<String> = []
        let pattern = try! NSRegularExpression(pattern: "\\{\\{\\s*(?:config|secret|totp)\\.([a-zA-Z0-9_]+)")

        func scan(_ text: String?) {
            guard let text else { return }
            let ns = text as NSString
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                keys.insert(ns.substring(with: match.range(at: 1)))
            }
        }
        func walk(_ steps: [PluginStep]) {
            for step in steps {
                scan(step.url); scan(step.value); scan(step.selector); scan(step.data)
                scan(step.code); scan(step.values)
                if let d = step.document {
                    scan(d.id); scan(d.date); scan(d.total); scan(d.number)
                    scan(d.issuer); scan(d.net); scan(d.vat); scan(d.currency)
                    (d.metadata ?? [:]).values.forEach(scan)
                }
                walk(step.nestedSteps)
            }
        }
        walk(steps)
        return keys
    }

    /// CI check 3: a contributor testing against their own account sometimes
    /// leaves a real value where a template belongs. Catch the obvious shapes.
    private static func detectSuspectedSecrets(_ m: PluginManifest) -> [Issue] {
        var issues: [Issue] = []
        let suspects: [(String, String)] = [
            ("(?i)\\b(password|passwd|pwd)\\s*[:=]\\s*[\"']?[^\\s\"'{}]{6,}", "hard-coded password"),
            ("\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}\\b", "e-mail address"),
            ("(?i)\\b(sk|pk)_(live|test)_[A-Za-z0-9]{16,}", "API key"),
            ("(?i)\\bBearer\\s+[A-Za-z0-9._-]{20,}", "bearer token"),
            ("\\beyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}", "JWT"),
        ]
        func scan(_ text: String?, path: String) {
            guard let text, !text.contains("{{") else { return }
            for (pattern, label) in suspects
            where text.range(of: pattern, options: .regularExpression) != nil {
                issues.append(.init(severity: .error, path: path,
                                    message: "looks like a hard-coded \(label)",
                                    hint: "Use {{config.<key>}} or {{secret.<key>}} and declare the field in configSchema."))
            }
        }
        func walk(_ steps: [PluginStep], path: String) {
            for (i, step) in steps.enumerated() {
                scan(step.value, path: "\(path)[\(i)].value")
                scan(step.code, path: "\(path)[\(i)].code")
                scan(step.url, path: "\(path)[\(i)].url")
                walk(step.nestedSteps, path: "\(path)[\(i)]")
            }
        }
        walk(m.allSteps, path: "steps")
        return issues
    }
}

public extension PluginManifest {
    /// The lowest engine version that can run every step in this manifest.
    var requiredEngineFloor: SemVer { IRCore.requiredEngineFloor(self) }
}


/// Every step in a manifest, with the path that names it.
func walkSteps(_ manifest: PluginManifest) -> [(step: PluginStep, path: String)] {
    var out: [(PluginStep, String)] = []
    func walk(_ steps: [PluginStep], _ path: String) {
        for (index, step) in steps.enumerated() {
            let here = "\(path)[\(index)]"
            out.append((step, here))
            walk(step.forEach ?? [], "\(here).forEach")
            walk(step.then ?? [], "\(here).then")
            walk(step.else ?? [], "\(here).else")
        }
    }
    walk(manifest.checkAuth, "checkAuth")
    walk(manifest.startAuth ?? [], "startAuth")
    walk(manifest.getConfigOptions ?? [], "getConfigOptions")
    walk(manifest.getDocuments, "getDocuments")
    return out
}

/// The lowest engine that can run every step in `manifest`.
public func requiredEngineFloor(_ manifest: PluginManifest) -> SemVer {
    var floor = manifest.api == nil ? SemVer(1, 0, 0) : SemVer(1, 2, 0)
    func walk(_ steps: [PluginStep]) {
        for step in steps {
            var features: [String] = [step.action.rawValue]
            if step.action == .extractAll, step.items != nil { features.append("extractAll.items") }
            for feature in features {
                if let introduced = PluginManifest.featureVersions[feature], introduced > floor {
                    floor = introduced
                }
            }
            walk(step.forEach ?? [])
            walk(step.then ?? [])
            walk(step.else ?? [])
        }
    }
    walk(manifest.allSteps)
    return floor
}

/// Every template an API transport can carry, so the credential scan sees the
/// keys that appear only in a signature recipe.
func transportTemplates(_ api: APITransport) -> [String] {
    var out = Array((api.headers ?? [:]).values)
    guard let auth = api.auth else { return out }
    out += Array((auth.headers ?? [:]).values)
    out += [auth.username, auth.password].compactMap { $0 }
    if let token = auth.token {
        out += [token.url, token.clientID, token.clientSecret]
        out += [token.scope].compactMap { $0 }
        out += Array((token.parameters ?? [:]).values)
    }
    if let time = auth.time { out.append(time.url) }
    if let signature = auth.signature {
        out += signature.parts
        out += [signature.key].compactMap { $0 }
    }
    return out
}

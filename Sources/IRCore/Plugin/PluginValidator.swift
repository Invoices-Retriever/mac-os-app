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
        let used = referencedConfigKeys(in: m.allSteps)
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
            require(step.selector != nil, "selector")
            require(step.forEach != nil, "forEach")
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

import Foundation

/// Turns a recorded browsing session into a plugin.
///
/// The specification puts a number on contributor experience — a simple plugin
/// in under thirty minutes — and the part that eats those thirty minutes is
/// never the navigation. It is sitting with an inspector open working out which
/// element repeats and which cell is the amount. The person recording already
/// knows: they are looking at their own invoices.
///
/// So this watches what they do and writes it down. It produces a **draft**,
/// deliberately: the selectors are read from a real page rather than guessed,
/// which is a different thing from having been run twice and confirmed.
public actor PluginRecorder {

    public struct Event: Sendable, Codable, Hashable, Identifiable {
        public enum Kind: String, Sendable, Codable { case navigate, click, type }
        public var id = UUID()
        public var kind: Kind
        public var url: String
        public var selector: String?
        /// A button's visible text, or a field's label. Never a typed value.
        public var label: String?
        public var fieldType: String?
        public var at = Date()

        public init(kind: Kind, url: String, selector: String? = nil,
                    label: String? = nil, fieldType: String? = nil) {
            self.kind = kind
            self.url = url
            self.selector = selector
            self.label = label
            self.fieldType = fieldType
        }

        public var summary: String {
            switch kind {
            case .navigate: return core("Went to %@", URL(string: url)?.path ?? url)
            case .click: return core("Clicked %@", label?.nilIfBlank ?? selector ?? "")
            case .type: return core("Typed into %@", label?.nilIfBlank ?? selector ?? "")
            }
        }
    }

    /// What the analyser made of the page the user stopped on.
    public struct PageAnalysis: Sendable, Codable {
        public struct Column: Sendable, Codable, Hashable, Identifiable {
            public enum Kind: String, Sendable, Codable { case date, money, reference, text }
            public var id: String { selector }
            public var selector: String
            public var kind: Kind
            public var samples: [String]

            public init(selector: String, kind: Kind, samples: [String]) {
                self.selector = selector; self.kind = kind; self.samples = samples
            }
        }
        public struct Link: Sendable, Codable {
            public var selector: String
            public var href: String
            public var isPdf: Bool

            public init(selector: String, href: String, isPdf: Bool) {
                self.selector = selector; self.href = href; self.isPdf = isPdf
            }
        }
        public var found: Bool
        public var url: String
        public var title: String?
        public var rowSelector: String?
        public var rowCount: Int?
        public var columns: [Column]?
        public var link: Link?

        public init(found: Bool, url: String, title: String? = nil,
                    rowSelector: String? = nil, rowCount: Int? = nil,
                    columns: [Column]? = nil, link: Link? = nil) {
            self.found = found; self.url = url; self.title = title
            self.rowSelector = rowSelector; self.rowCount = rowCount
            self.columns = columns; self.link = link
        }
    }

    private(set) var events: [Event] = []
    private(set) var analysis: PageAnalysis?
    private(set) var hosts: Set<String> = []

    public init() {}

    public func record(_ event: Event) {
        // A navigation to the same place twice is the page reloading itself,
        // not the user going anywhere.
        if event.kind == .navigate, events.last?.kind == .navigate,
           events.last?.url == event.url { return }
        if let host = URL(string: event.url)?.host { hosts.insert(host.lowercased()) }
        events.append(event)
    }

    public func setAnalysis(_ analysis: PageAnalysis) {
        self.analysis = analysis
        if let host = URL(string: analysis.url)?.host { hosts.insert(host.lowercased()) }
    }

    public func reset() {
        events.removeAll()
        analysis = nil
        hosts.removeAll()
    }

    public var recordedEvents: [Event] { events }
    public var currentAnalysis: PageAnalysis? { analysis }
    public var visitedHosts: [String] { hosts.sorted() }

    // MARK: - Producing a plugin

    public struct Draft: Sendable {
        public var manifest: PluginManifest
        /// Things the recording could not settle, in the order they matter.
        /// Shown next to the result rather than buried, because a draft that
        /// looks finished and is not is worse than one that admits it.
        public var warnings: [String]
        public var json: String
    }

    /// `allowedDomains` from the hosts actually visited, collapsed to a
    /// registrable domain with a wildcard where several subdomains appeared.
    ///
    /// Narrow by construction: a recording that never touched a host does not
    /// grant it, which is a better list than anyone writes by hand.
    public static func allowedDomains(from hosts: [String]) -> [String] {
        var bases: [String: Set<String>] = [:]
        for host in hosts {
            let labels = host.split(separator: ".")
            guard labels.count >= 2 else { continue }
            // Good enough for the shapes that occur: co.uk and com.au keep
            // three labels, everything else keeps two.
            let compound = ["co", "com", "org", "net", "gov", "ac"]
            let keep = labels.count >= 3 && compound.contains(String(labels[labels.count - 2])) ? 3 : 2
            let base = labels.suffix(keep).joined(separator: ".")
            bases[base, default: []].insert(host)
        }
        var domains: [String] = []
        for (base, seen) in bases.sorted(by: { $0.key < $1.key }) {
            domains.append(base)
            // A wildcard only where a subdomain was actually used.
            if seen.contains(where: { $0 != base }) { domains.append("*." + base) }
        }
        return domains
    }

    public func makeDraft(id: String, name: String, countries: [String]) -> Draft {
        var warnings: [String] = []
        let navigations = events.filter { $0.kind == .navigate }
        let typed = events.filter { $0.kind == .type }

        // --- configSchema, from the fields the user typed into ---------------
        var configSchema: [String: ConfigField] = [:]
        var fieldKeys: [String: String] = [:]   // selector -> config key
        for event in typed {
            guard let selector = event.selector else { continue }
            let isSecret = event.fieldType == "password"
            let key = Self.configKey(for: event, taken: Set(configSchema.keys))
            configSchema[key] = ConfigField(
                type: isSecret ? .password : .string,
                label: event.label?.nilIfBlank ?? key,
                required: true)
            fieldKeys[selector] = key
        }

        // --- startAuth: how they signed in -----------------------------------
        var startAuth: [PluginStep] = []
        if let first = navigations.first, let url = URL(string: first.url) {
            var step = PluginStep(action: .navigate)
            step.url = url.absoluteString
            step.description = core("Where the recording started")
            startAuth.append(step)
        }
        for event in events where event.kind == .type || event.kind == .click {
            guard let selector = event.selector else { continue }
            if event.kind == .type, let key = fieldKeys[selector] {
                var step = PluginStep(action: .type)
                step.selector = selector
                let secret = configSchema[key]?.isSecret ?? false
                step.value = "{{\(secret ? "secret" : "config").\(key)}}"
                step.description = event.label?.nilIfBlank
                startAuth.append(step)
            } else if event.kind == .click {
                var step = PluginStep(action: .click)
                step.selector = selector
                step.description = event.label?.nilIfBlank
                startAuth.append(step)
            }
            if startAuth.count > 24 { break }
        }
        if startAuth.count > 1 {
            var wait = PluginStep(action: .waitForNavigation)
            wait.timeout = 30_000
            startAuth.append(wait)
        }

        // --- checkAuth: the page they ended on, and something only a signed-in
        //     person sees ----------------------------------------------------
        let landing = analysis?.url ?? navigations.last?.url ?? navigations.first?.url ?? ""
        var checkAuth: [PluginStep] = []
        if !landing.isEmpty {
            var navigate = PluginStep(action: .navigate)
            navigate.url = landing
            checkAuth.append(navigate)
            var idle = PluginStep(action: .waitForNetworkIdle)
            idle.idleMs = 800
            idle.timeout = 25_000
            checkAuth.append(idle)
        }
        if let rowSelector = analysis?.rowSelector {
            var check = PluginStep(action: .checkElementExists)
            check.selector = rowSelector
            check.timeout = 20_000
            check.description = core("Only a signed-in customer sees the invoice list")
            checkAuth.append(check)
        } else {
            var check = PluginStep(action: .checkURL)
            check.url = Self.urlPattern(for: landing)
            checkAuth.append(check)
            warnings.append(core("checkAuth falls back to matching the address. Replace it with an element only a signed-in customer sees — it is what tells the app your session expired."))
        }

        // --- getDocuments, from the analysed table ---------------------------
        var getDocuments: [PluginStep] = []
        if !landing.isEmpty {
            var navigate = PluginStep(action: .navigate)
            navigate.url = landing
            getDocuments.append(navigate)
            var idle = PluginStep(action: .waitForNetworkIdle)
            idle.idleMs = 1000
            idle.timeout = 30_000
            getDocuments.append(idle)
        }

        if let analysis, analysis.found, let rowSelector = analysis.rowSelector {
            var wait = PluginStep(action: .waitForElement)
            wait.selector = rowSelector
            wait.timeout = 25_000
            getDocuments.append(wait)

            var fields: [String: FieldSpec] = [:]
            let columns = analysis.columns ?? []
            if let date = columns.first(where: { $0.kind == .date }) {
                fields["date"] = FieldSpec(selector: date.selector)
            } else {
                warnings.append(core("No column looked like a date. A document needs one — point the 'date' field at the right cell."))
            }
            if let money = columns.first(where: { $0.kind == .money }) {
                fields["total"] = FieldSpec(selector: money.selector)
            } else {
                warnings.append(core("No column looked like an amount. Without it the app falls back to reading the PDF."))
            }
            if let reference = columns.first(where: { $0.kind == .reference }) {
                fields["number"] = FieldSpec(selector: reference.selector)
            }
            if let link = analysis.link {
                fields["pdf"] = FieldSpec(selector: link.selector, attribute: "href")
            }

            var extract = PluginStep(action: .extractAll)
            extract.selector = rowSelector
            extract.fields = fields
            extract.limit = 60

            var document = DocumentDescriptor(
                id: fields["number"] != nil ? "{{item.number}}" : "{{item.date}}",
                date: "{{item.date}}")
            if fields["total"] != nil { document.total = "{{item.total}}" }
            if fields["number"] != nil { document.number = "{{item.number}}" }
            document.issuer = name

            if let link = analysis.link, link.isPdf {
                var download = PluginStep(action: .downloadPdf)
                download.url = "{{item.pdf}}"
                download.timeout = 60_000
                download.document = document
                extract.forEach = [download]
            } else if analysis.link != nil {
                var open = PluginStep(action: .click)
                open.selector = fields["pdf"]?.selector
                var collect = PluginStep(action: .waitForPdfDownload)
                collect.timeout = 60_000
                collect.document = document
                extract.forEach = [open, collect]
                warnings.append(core("The link in a row does not obviously point at a PDF, so the draft clicks it and waits for a download. Check what actually happens."))
            } else {
                var print = PluginStep(action: .printPdf)
                print.document = document
                extract.forEach = [print]
                warnings.append(core("No download link was found in a row, so the draft prints the page to PDF. If the portal has a real PDF somewhere, use that instead."))
            }
            getDocuments.append(extract)

            if fields["number"] == nil {
                warnings.append(core("No column looked like an invoice number, so the date is standing in as the document id. An id has to be stable and unique or the same invoice arrives every month — check this one first."))
            }
        } else {
            warnings.append(core("No invoice table was recognised on the page. Navigate to the billing history and analyse again, or write getDocuments by hand."))
        }

        // --- Assemble --------------------------------------------------------
        var manifest = PluginManifest(
            id: id, name: name, version: "0.1.0",
            engine: ">=\(PluginManifest.engineVersion)",
            allowedDomains: Self.allowedDomains(from: hosts.sorted()),
            checkAuth: checkAuth.isEmpty ? [PluginStep(action: .waitForNavigation)] : checkAuth,
            getDocuments: getDocuments)
        manifest.description = core("Recorded from a live session. Not yet run end to end.")
        manifest.country = countries.isEmpty ? nil : countries
        manifest.status = .unverified
        manifest.configSchema = configSchema.isEmpty ? nil : configSchema
        manifest.startAuth = startAuth.count > 1 ? startAuth : nil
        manifest.autofill = .all(!configSchema.isEmpty)

        if configSchema.isEmpty {
            warnings.append(core("No sign-in was recorded, so the plugin asks the user for nothing and relies on them signing in by hand. That works, but it is worth recording the login once."))
        }

        let report = PluginValidator.validate(manifest)
        warnings += report.errors.map { core("%1$@: %2$@", $0.path, $0.message) }

        return Draft(manifest: manifest, warnings: warnings, json: Self.encode(manifest))
    }

    // MARK: - Helpers

    /// A readable config key from what the field was labelled.
    public static func configKey(for event: Event, taken: Set<String>) -> String {
        // The label is what the user saw beside the box, so it makes the most
        // recognisable key. Failing that the selector often carries the name.
        // Failing both, say what the field was rather than inventing a word:
        // a schema asking for "field" helps nobody.
        let source = event.label?.nilIfBlank
            ?? event.selector?.nilIfBlank
            ?? (event.fieldType == "password" ? "password" : "username")
        let folded: String = source.lowercased()
            .folding(options: String.CompareOptions.diacriticInsensitive,
                     locale: Locale(identifier: "en_US_POSIX"))
        let words: [String] = folded
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .prefix(3)
            .map(String.init)

        var key = ""
        for (index, word) in words.enumerated() {
            key += index == 0 ? word : word.capitalized
        }
        // A selector like "#account" folds to "account"; one like
        // "input[type=\"password\"]" folds to something starting with a digit
        // or nothing at all, which is not a usable key.
        if key.isEmpty || !(key.first?.isLetter ?? false) {
            key = event.fieldType == "password" ? "password" : "username"
        }
        var unique = key
        var suffix = 2
        while taken.contains(unique) { unique = "\(key)\(suffix)"; suffix += 1 }
        return unique
    }

    /// A `checkURL` pattern from a concrete address: keep the host and the
    /// path, drop the query, which is where the volatile parts live.
    public static func urlPattern(for address: String) -> String {
        guard let url = URL(string: address), let host = url.host else { return address }
        let path = url.path.isEmpty ? "/" : url.path
        return "https://\(host)\(path)*"
    }

    static func encode(_ manifest: PluginManifest) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(manifest) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

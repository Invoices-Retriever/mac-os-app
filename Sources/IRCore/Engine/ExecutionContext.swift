import Foundation

/// The variable environment a plugin's templates resolve against.
///
/// Secrets live here alongside ordinary values, which is exactly why this type
/// is careful: `resolve` will substitute a secret into a step's value because
/// that is the point, but `debugDescription` will not, and every secret is
/// registered with the redacting logger before it ever gets here.
public final class ExecutionContext: @unchecked Sendable {
    public let source: Source
    public let manifest: PluginManifest
    public let runID: UUID

    private let lock = NSLock()
    private var variables: [String: JSONValue] = [:]
    private var itemStack: [[String: JSONValue]] = []

    public let config: [String: String]
    private let secrets: [String: String]
    private let totpCodes: [String: String]
    public private(set) var exposedOptions: [ExposedOption] = []

    /// Documents this run has produced, in order.
    public private(set) var documents: [CollectedDocument] = []

    /// Rows `extractAll` matched. A run that matched rows and produced no
    /// document has found the list and failed to read it — a different and much
    /// more actionable outcome than finding nothing at all.
    public private(set) var matchedRows = 0

    /// Everything older than this has already been collected (F2.5).
    public let incrementalCutoff: Date

    public init(source: Source,
                manifest: PluginManifest,
                runID: UUID,
                config: [String: String],
                secrets: [String: String],
                totpCodes: [String: String],
                incrementalCutoff: Date) {
        self.source = source
        self.manifest = manifest
        self.runID = runID
        self.config = config
        self.secrets = secrets
        self.totpCodes = totpCodes
        self.incrementalCutoff = incrementalCutoff
    }

    // MARK: - Variables

    public func set(_ name: String, _ value: JSONValue) {
        lock.lock(); defer { lock.unlock() }
        variables[name] = value
    }

    public func variable(_ name: String) -> JSONValue? {
        lock.lock(); defer { lock.unlock() }
        return variables[name]
    }

    public func snapshot() -> [String: JSONValue] {
        lock.lock(); defer { lock.unlock() }
        return variables
    }

    public func pushItem(_ item: [String: JSONValue]) {
        lock.lock(); defer { lock.unlock() }
        itemStack.append(item)
    }

    public func popItem() {
        lock.lock(); defer { lock.unlock() }
        if !itemStack.isEmpty { itemStack.removeLast() }
    }

    private func currentItem() -> [String: JSONValue] {
        lock.lock(); defer { lock.unlock() }
        return itemStack.last ?? [:]
    }

    public func addExposedOption(_ option: ExposedOption) {
        lock.lock(); defer { lock.unlock() }
        exposedOptions.removeAll { $0.key == option.key }
        exposedOptions.append(option)
    }

    public func noteMatchedRows(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        matchedRows += count
    }

    public func addDocument(_ document: CollectedDocument) {
        lock.lock(); defer { lock.unlock() }
        documents.append(document)
    }

    // MARK: - Template resolution

    /// Replaces every `{{namespace.key}}` in `template`.
    ///
    /// An unresolvable reference throws rather than silently becoming an empty
    /// string: a plugin that types nothing into a password field produces a
    /// confusing "wrong password" instead of an obvious "unknown variable", and
    /// the contributor pays for that in debugging time.
    public func resolve(_ template: String) throws -> String {
        guard template.contains("{{") else { return template }

        let pattern = try NSRegularExpression(pattern: "\\{\\{\\s*([^}]+?)\\s*\\}\\}")
        let ns = template as NSString
        var result = ""
        var location = 0

        for match in pattern.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: location, length: match.range.location - location))
            let reference = ns.substring(with: match.range(at: 1))
            guard let value = lookup(reference) else {
                throw IRError.assertionFailed("unknown variable {{\(reference)}}")
            }
            result += value
            location = match.range.location + match.range.length
        }
        result += ns.substring(from: location)
        return result
    }

    /// Resolution that tolerates unknown references, for optional fields where
    /// an absent value is a legitimate answer.
    public func resolveOptional(_ template: String?) -> String? {
        guard let template else { return nil }
        return try? resolve(template)
    }

    func lookup(_ reference: String) -> String? {
        let parts = reference.split(separator: ".", maxSplits: 1).map(String.init)
        guard let head = parts.first else { return nil }
        let tail = parts.count > 1 ? parts[1] : nil

        switch head {
        case "config":
            guard let key = tail else { return nil }
            return config[key] ?? secrets[key]
        case "secret":
            guard let key = tail else { return nil }
            return secrets[key]
        case "totp":
            guard let key = tail else { return nil }
            return totpCodes[key]
        case "item":
            // A row from a JSON list of scalars has no fields; {{item}} is it.
            guard let key = tail else { return currentItem()["__value"]?.stringValue }
            return currentItem()[key]?.stringValue
        case "option":
            guard let key = tail else { return nil }
            return source.options[key]?.first
        case "vars":
            guard let key = tail else { return nil }
            return variable(key)?.stringValue
        case "source":
            switch tail {
            case "name": return source.displayName
            case "id": return source.id.uuidString
            default: return nil
            }
        case "now", "today":
            return dateComponent(of: Date(), tail)
        case "cutoff", "lastRun":
            return dateComponent(of: incrementalCutoff, tail)
        default:
            // Bare `{{invoiceNumber}}` means a variable, which is the shape
            // contributors reach for first.
            if tail == nil { return variable(head)?.stringValue }
            // `{{someObject.field}}` for a variable holding an object.
            if let value = variable(head), let tail {
                return value.value(atPath: tail)?.stringValue
            }
            return nil
        }
    }

    private func dateComponent(of date: Date, _ component: String?) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        switch component {
        case nil, "date", "iso": return InvoiceDateParser.isoString(date)
        case "year": return parts.year.map(String.init)
        case "month": return parts.month.map { String(format: "%02d", $0) }
        case "day": return parts.day.map { String(format: "%02d", $0) }
        case "epoch": return String(Int(date.timeIntervalSince1970))
        case "epochMs": return String(Int(date.timeIntervalSince1970 * 1000))
        default: return nil
        }
    }
}

public struct ExposedOption: Sendable, Hashable, Identifiable {
    public var id: String { key }
    public var key: String
    public var label: String
    public var choices: [ConfigOption]
    public var allowsMultiple: Bool

    public init(key: String, label: String, choices: [ConfigOption], allowsMultiple: Bool) {
        self.key = key; self.label = label; self.choices = choices; self.allowsMultiple = allowsMultiple
    }
}

/// A document as it comes out of the engine, before the library has decided
/// where to put it or whether it is a duplicate.
public struct CollectedDocument: Sendable {
    public var pluginDocumentID: String
    public var data: Data
    public var suggestedFilename: String?
    public var issuedOn: Date?
    public var total: Money?
    public var net: Money?
    public var vat: Money?
    public var number: String?
    public var issuer: String?
    public var kind: DocumentKind
    public var metadata: [String: String]

    public init(pluginDocumentID: String, data: Data, kind: DocumentKind = .invoice) {
        self.pluginDocumentID = pluginDocumentID
        self.data = data
        self.kind = kind
        self.metadata = [:]
    }
}

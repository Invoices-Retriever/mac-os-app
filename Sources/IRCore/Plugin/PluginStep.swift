import Foundation

/// The step vocabulary of §5.3, decoded straight from the plugin JSON.
///
/// Steps are modelled as one struct with optional fields rather than an
/// associated-value enum. That reads worse in Swift but it matters here: the
/// JSON Schema is the normative definition of the format, contributors read
/// that, and keeping the Swift shape flat means the decoder never diverges
/// from the schema by accident. Per-action requirements are checked by
/// `PluginValidator`, which reports the same errors the CI reports.
public struct PluginStep: Codable, Sendable, Hashable {
    public var action: StepAction
    public var description: String?

    // Navigation and matching
    public var url: String?
    public var selector: String?
    public var timeout: Int?
    public var idleMs: Int?

    // Interaction
    public var value: String?
    public var pressEnter: Bool?
    public var optional: Bool?
    public var code: String?

    // Verification
    public var expect: Bool?

    // API
    public var method: String?
    public var headers: [String: String]?
    public var body: String?
    /// Iterate this instead of a selector: a JSON array from `apiRequest`.
    public var items: String?

    // Extraction
    public var attribute: String?
    public var regex: String?
    public var from: ExtractSource?
    public var assignTo: String?
    public var jsonPath: String?
    public var fields: [String: FieldSpec]?
    public var limit: Int?
    public var forEach: [PluginStep]?

    // Documents
    public var document: DocumentDescriptor?
    public var data: String?

    // Control flow
    public var condition: StepCondition?
    public var then: [PluginStep]?
    public var `else`: [PluginStep]?
    public var ms: Int?

    // Options
    public var key: String?
    public var label: String?
    public var values: String?
    public var multiple: Bool?

    public init(action: StepAction) {
        self.action = action
    }

    /// Steps nested inside this one, for recursive walks (validation, domain
    /// analysis, the step-by-step debugger).
    public var nestedSteps: [PluginStep] {
        (forEach ?? []) + (then ?? []) + (self.else ?? [])
    }

    /// URL-bearing fields, used to check statically that every host a plugin
    /// navigates to is declared in `allowedDomains`.
    public var staticURLTemplates: [String] {
        var out: [String] = []
        if let url, action == .navigate || action == .downloadPdf || action == .apiRequest {
            out.append(url)
        }
        return out
    }

    /// Human-readable label for logs and the debugger.
    public var displayName: String {
        if let description, !description.isEmpty { return description }
        switch action {
        case .navigate: return "navigate \(url ?? "")"
        case .click: return "click \(selector ?? "")"
        case .type: return "type into \(selector ?? "")"
        case .extract: return "extract \(assignTo ?? "")"
        case .extractAll: return "extract rows \(selector ?? items ?? "")"
        case .apiRequest: return "\(method ?? "GET") \(url ?? "")"
        default: return action.rawValue
        }
    }
}

public enum StepAction: String, Codable, Sendable, CaseIterable, Hashable {
    case navigate, waitForURL, waitForElement, waitForNavigation, waitForNetworkIdle
    case click, type, dropdownSelect, runJs
    case checkElementExists, checkURL
    case extract, extractAll, extractNetworkResponse, apiRequest
    case downloadPdf, waitForPdfDownload, printPdf, downloadBase64Pdf
    case ifStep = "if"
    case sleep, exposeOption

    /// Actions that emit a document, and therefore must carry a `document`.
    public var producesDocument: Bool {
        switch self {
        case .downloadPdf, .waitForPdfDownload, .printPdf, .downloadBase64Pdf: return true
        default: return false
        }
    }
}

public enum ExtractSource: String, Codable, Sendable, Hashable {
    case element, url, title, page
}

public struct FieldSpec: Codable, Sendable, Hashable {
    public var selector: String?
    public var attribute: String?
    public var regex: String?
    public var optional: Bool?

    public init(selector: String? = nil, attribute: String? = nil, regex: String? = nil, optional: Bool? = nil) {
        self.selector = selector; self.attribute = attribute; self.regex = regex; self.optional = optional
    }
}

/// A single-key object, as in `{"elementExists": ".invoice-row"}`.
public indirect enum StepCondition: Codable, Sendable, Hashable {
    case elementExists(String)
    case urlMatches(String)
    case variableEquals(name: String, value: String)
    case variableIsSet(String)
    case not(StepCondition)

    private enum CodingKeys: String, CodingKey {
        case elementExists, urlMatches, variableEquals, variableIsSet, not
    }
    private struct Equality: Codable, Hashable, Sendable { var name: String; var value: String }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent(String.self, forKey: .elementExists) { self = .elementExists(v); return }
        if let v = try c.decodeIfPresent(String.self, forKey: .urlMatches) { self = .urlMatches(v); return }
        if let v = try c.decodeIfPresent(Equality.self, forKey: .variableEquals) { self = .variableEquals(name: v.name, value: v.value); return }
        if let v = try c.decodeIfPresent(String.self, forKey: .variableIsSet) { self = .variableIsSet(v); return }
        if let v = try c.decodeIfPresent(StepCondition.self, forKey: .not) { self = .not(v); return }
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "Condition must have exactly one of: elementExists, urlMatches, variableEquals, variableIsSet, not"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .elementExists(let v): try c.encode(v, forKey: .elementExists)
        case .urlMatches(let v): try c.encode(v, forKey: .urlMatches)
        case .variableEquals(let n, let v): try c.encode(Equality(name: n, value: v), forKey: .variableEquals)
        case .variableIsSet(let v): try c.encode(v, forKey: .variableIsSet)
        case .not(let v): try c.encode(v, forKey: .not)
        }
    }
}

/// The normalised document object a plugin emits. Values are templates,
/// resolved against the execution context at the moment the step runs.
public struct DocumentDescriptor: Codable, Sendable, Hashable {
    public var id: String
    public var date: String
    public var total: String?
    public var currency: String?
    public var net: String?
    public var vat: String?
    public var number: String?
    public var issuer: String?
    public var type: DocumentKind?
    public var metadata: [String: String]?

    public init(id: String, date: String) {
        self.id = id; self.date = date
    }
}

public enum DocumentKind: String, Codable, Sendable, Hashable, CaseIterable {
    case invoice, creditNote = "credit-note", receipt, statement, other

    public var displayName: String {
        switch self {
        case .invoice: return core("Invoice")
        case .creditNote: return core("Credit note")
        case .receipt: return core("Receipt")
        case .statement: return core("Statement")
        case .other: return core("Document")
        }
    }
}

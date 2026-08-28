import Foundation

/// What the step executor needs from a browser, and nothing more.
///
/// Keeping this narrow has two payoffs. The executor — where all the plugin
/// semantics live — is testable against a fake session with no WebKit and no
/// network. And the day this moves off WKWebView (the specification is explicit
/// that a future Windows/Linux port must not be a rewrite), only the driver
/// changes.
///
/// Note what is *not* here: there is no "disable the domain policy" call. The
/// policy is handed to the session once, at creation, and the session enforces
/// it. Nothing a plugin does can reach past it.
public protocol BrowserSession: AnyObject, Sendable {
    var sourceID: UUID { get }

    func currentURL() async -> URL?
    func pageTitle() async -> String?

    func navigate(to url: URL) async throws
    func waitForNavigation(timeout: Duration) async throws
    func waitForNetworkIdle(idle: Duration, timeout: Duration) async throws

    /// Evaluates JavaScript in the page and returns its result as JSON.
    /// Every DOM operation in the step vocabulary is built on this.
    func evaluate(_ javascript: String) async throws -> JSONValue

    /// Shows or hides the browser window. Interactive sign-in needs it visible
    /// (F2.3, F3.1); collection runs with it hidden.
    func setVisible(_ visible: Bool) async

    /// Waits until the user has finished signing in by hand, or the deadline
    /// passes. Returns false on timeout.
    func waitForUserSignIn(until: Date, isSignedIn: @Sendable () async -> Bool) async -> Bool

    func download(from url: URL, timeout: Duration) async throws -> Data
    /// Collects a download the page started on its own, typically after a click.
    func awaitPendingDownload(timeout: Duration) async throws -> Data
    /// Renders the current page to PDF, for portals that only ever show an
    /// invoice as HTML.
    func printToPDF() async throws -> Data
    func captureScreenshot() async throws -> Data

    /// Responses observed since the last call, for `extractNetworkResponse`.
    func drainNetworkResponses() async -> [ObservedResponse]

    /// Wipes cookies and local storage for this source, which is what "forget
    /// this session" means.
    func clearSession() async throws
    func close() async
}

public struct ObservedResponse: Sendable, Hashable {
    public var url: URL
    public var statusCode: Int
    public var mimeType: String?
    public var body: Data?

    public init(url: URL, statusCode: Int, mimeType: String? = nil, body: Data? = nil) {
        self.url = url; self.statusCode = statusCode; self.mimeType = mimeType; self.body = body
    }
}

/// Creates isolated sessions. One profile per source (F2.2) so that two AWS
/// accounts never see each other's cookies.
public protocol BrowserSessionFactory: Sendable {
    func makeSession(sourceID: UUID, policy: DomainPolicy) async throws -> any BrowserSession
}

// MARK: - JSON values

/// The result type of `evaluate`. A plain enum rather than `Any` so the
/// executor can pattern-match instead of casting.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return nil
        case .array, .object:
            guard let data = try? JSONEncoder().encode(self) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }

    public var boolValue: Bool {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return !s.isEmpty && s != "false"
        case .null: return false
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// Dotted lookup, for `extractNetworkResponse`'s jsonPath. Numeric
    /// components index into arrays.
    public func value(atPath path: String) -> JSONValue? {
        guard !path.isEmpty else { return self }
        var current = self
        for component in path.split(separator: ".") {
            if let index = Int(component), let array = current.arrayValue {
                guard index >= 0 && index < array.count else { return nil }
                current = array[index]
            } else if let object = current.objectValue {
                guard let next = object[String(component)] else { return nil }
                current = next
            } else {
                return nil
            }
        }
        return current
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Bridges from the `Any` that WKWebView hands back.
    public init(any value: Any?) {
        switch value {
        case nil, is NSNull:
            self = .null
        case let b as Bool:
            self = .bool(b)
        case let n as NSNumber:
            // NSNumber does not distinguish a boolean from 0/1 without this.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) }
            else { self = .number(n.doubleValue) }
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            self = .array(a.map { JSONValue(any: $0) })
        case let d as [String: Any]:
            self = .object(d.mapValues { JSONValue(any: $0) })
        default:
            self = .string(String(describing: value!))
        }
    }
}

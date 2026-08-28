import Foundation

/// A plugin as it appears on disk: a JSON document, never code.
///
/// That choice is what makes the whole contribution model work. A maintainer
/// who is not a Swift developer can review a pull request, the CI can validate
/// it mechanically, and the attack surface is a fixed vocabulary of steps
/// rather than arbitrary execution.
public struct PluginManifest: Codable, Sendable, Identifiable, Hashable {
    /// The engine version this build implements. A plugin asking for more is
    /// refused rather than half-run (F10.4).
    public static let engineVersion = SemVer(1, 0, 0)

    public var schemaURL: String?
    public var id: String
    public var name: String
    public var version: String
    public var description: String?
    public var homepage: String?
    public var maintainers: [String]?
    public var country: [String]?
    public var tags: [String]?
    public var engine: String
    public var allowedDomains: [String]
    public var usesJs: Bool?
    public var status: PluginStatus?
    public var configSchema: [String: ConfigField]?
    public var autofill: AutofillPolicy?

    public var checkAuth: [PluginStep]
    public var startAuth: [PluginStep]?
    public var getConfigOptions: [PluginStep]?
    public var getDocuments: [PluginStep]

    private enum CodingKeys: String, CodingKey {
        case schemaURL = "$schema"
        case id, name, version, description, homepage, maintainers, country, tags
        case engine, allowedDomains, usesJs, status, configSchema, autofill
        case checkAuth, startAuth, getConfigOptions, getDocuments
    }

    public var semanticVersion: SemVer { SemVer(version) ?? SemVer(0, 0, 0) }
    public var domainPolicy: DomainPolicy { DomainPolicy(allowedDomains: allowedDomains) }
    public var effectiveStatus: PluginStatus { status ?? .active }

    /// True when the plugin contains a `runJs` step anywhere, regardless of
    /// what it declares. The declaration is a contributor convenience; this is
    /// the truth, and the UI badge uses this one.
    public var containsArbitraryJavaScript: Bool {
        func walk(_ steps: [PluginStep]) -> Bool {
            for step in steps {
                if step.action == .runJs { return true }
                if walk(step.nestedSteps) { return true }
            }
            return false
        }
        return walk(allSteps)
    }

    public var allSteps: [PluginStep] {
        checkAuth + (startAuth ?? []) + (getConfigOptions ?? []) + getDocuments
    }

    /// Config keys whose values belong in the Keychain, never in SQLite (M5).
    public var secretConfigKeys: [String] {
        (configSchema ?? [:]).filter { $0.value.type == .password || $0.value.type == .totp }.map(\.key).sorted()
    }

    public var plainConfigKeys: [String] {
        (configSchema ?? [:]).filter { $0.value.type != .password && $0.value.type != .totp }.map(\.key).sorted()
    }

    public func isSupportedByEngine(_ current: SemVer = PluginManifest.engineVersion) -> Bool {
        guard let requirement = VersionRequirement(engine) else { return false }
        return requirement.isSatisfied(by: current)
    }

    public static func decode(from data: Data) throws -> PluginManifest {
        do {
            return try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch let error as DecodingError {
            throw IRError.invalidPlugin(Self.describe(error))
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let ctx):
            return "missing key '\(key.stringValue)' at \(path(ctx.codingPath))"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx):
            return "\(ctx.debugDescription) at \(path(ctx.codingPath))"
        case .dataCorrupted(let ctx):
            return "\(ctx.debugDescription) at \(path(ctx.codingPath))"
        @unknown default:
            return "\(error)"
        }
    }

    private static func path(_ codingPath: [CodingKey]) -> String {
        codingPath.isEmpty ? "root" : codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
    }
}

public enum PluginStatus: String, Codable, Sendable, Hashable, CaseIterable {
    /// Working as far as anyone knows.
    case active
    /// Failing for several users. Still installable, but flagged in the
    /// catalogue so nobody adds it expecting it to work.
    case degraded
    /// Unmaintained and broken for 90 days. No longer offered (§5.5).
    case archived

    public var displayName: String {
        switch self {
        case .active: return core("Working")
        case .degraded: return core("Degraded")
        case .archived: return core("Archived")
        }
    }
}

public struct ConfigField: Codable, Sendable, Hashable {
    public var type: ConfigFieldType
    public var label: String
    public var help: String?
    public var required: Bool?
    public var placeholder: String?
    public var options: [ConfigOption]?
    public var defaultValue: AnyCodableValue?

    private enum CodingKeys: String, CodingKey {
        case type, label, help, required, placeholder, options
        case defaultValue = "default"
    }

    public init(type: ConfigFieldType, label: String, required: Bool = false, help: String? = nil) {
        self.type = type; self.label = label; self.required = required; self.help = help
    }

    public var isRequired: Bool { required ?? false }
    public var isSecret: Bool { type == .password || type == .totp }
}

public enum ConfigFieldType: String, Codable, Sendable, Hashable {
    case string, password, totp, number, boolean, select, date
}

public struct ConfigOption: Codable, Sendable, Hashable {
    public var value: String
    public var label: String
    public init(value: String, label: String) { self.value = value; self.label = label }
}

/// `autofill` is either a blanket boolean or a per-field map. The user's own
/// choice always wins over the plugin's (F3.2, F3.5).
public enum AutofillPolicy: Codable, Sendable, Hashable {
    case all(Bool)
    case perField([String: Bool])

    public func allows(_ field: String) -> Bool {
        switch self {
        case .all(let enabled): return enabled
        case .perField(let map): return map[field] ?? false
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .all(b) }
        else { self = .perField(try c.decode([String: Bool].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .all(let b): try c.encode(b)
        case .perField(let m): try c.encode(m)
        }
    }
}

/// Minimal any-JSON box, needed only for `default` values in config fields.
public enum AnyCodableValue: Codable, Sendable, Hashable {
    case string(String), number(Double), bool(Bool), null

    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }
}

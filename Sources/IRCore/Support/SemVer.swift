import Foundation

public struct SemVer: Comparable, CustomStringConvertible, Codable, Sendable, Hashable {
    public let major: Int, minor: Int, patch: Int
    public let prerelease: String?

    public init(_ major: Int, _ minor: Int, _ patch: Int, prerelease: String? = nil) {
        self.major = major; self.minor = minor; self.patch = patch; self.prerelease = prerelease
    }

    public init?(_ string: String) {
        let core = string.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let parts = core[0].split(separator: ".")
        guard parts.count == 3,
              let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2]) else { return nil }
        self.init(a, b, c, prerelease: core.count > 1 ? String(core[1]) : nil)
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.map { "-\($0)" } ?? "")
    }

    public static func < (l: SemVer, r: SemVer) -> Bool {
        if l.major != r.major { return l.major < r.major }
        if l.minor != r.minor { return l.minor < r.minor }
        if l.patch != r.patch { return l.patch < r.patch }
        switch (l.prerelease, r.prerelease) {
        case (nil, nil): return false
        case (nil, _?): return false   // 1.0.0 > 1.0.0-beta
        case (_?, nil): return true
        case (let a?, let b?): return a < b
        }
    }
}

/// The subset of range syntax the plugin `engine` field allows: ">=x.y.z",
/// "^x.y.z", "~x.y.z" or a bare version.
public struct VersionRequirement: Sendable {
    public enum Kind: Sendable { case atLeast, caret, tilde, exact }
    public let kind: Kind
    public let version: SemVer

    public init?(_ string: String) {
        let s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix(">=") { kind = .atLeast; guard let v = SemVer(String(s.dropFirst(2))) else { return nil }; version = v }
        else if s.hasPrefix("^") { kind = .caret; guard let v = SemVer(String(s.dropFirst())) else { return nil }; version = v }
        else if s.hasPrefix("~") { kind = .tilde; guard let v = SemVer(String(s.dropFirst())) else { return nil }; version = v }
        else { kind = .exact; guard let v = SemVer(s) else { return nil }; version = v }
    }

    public func isSatisfied(by current: SemVer) -> Bool {
        switch kind {
        case .atLeast: return current >= version
        case .exact:   return current == version
        case .caret:   return current >= version && current.major == version.major
        case .tilde:   return current >= version && current.major == version.major && current.minor == version.minor
        }
    }
}

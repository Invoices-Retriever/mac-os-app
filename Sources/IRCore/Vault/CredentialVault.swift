import Foundation

/// The engine's view of secrets: ask for a source's credentials, get them
/// registered with the redacting logger, use them, forget them.
public final class CredentialVault: @unchecked Sendable {
    private let keychain: Keychain
    private let logger: RedactingLogger

    public init(keychain: Keychain = Keychain(), logger: RedactingLogger = .shared) {
        self.keychain = keychain
        self.logger = logger
    }

    private func account(source: UUID, key: String) -> String {
        "source.\(source.uuidString).\(key)"
    }

    public func store(_ value: String, for key: String, source: UUID, requireBiometrics: Bool = false) throws {
        try keychain.set(value, account: account(source: source, key: key), requireBiometrics: requireBiometrics)
    }

    /// Reads every secret a plugin declares and immediately registers each one
    /// with the logger. Registration happens here rather than at the point of
    /// use so that there is no window in which a secret exists but redaction
    /// does not know about it.
    public func secrets(for source: Source, manifest: PluginManifest, prompt: String? = nil) throws -> [String: String] {
        var out: [String: String] = [:]
        for key in manifest.secretConfigKeys {
            guard let value = try keychain.get(account: account(source: source.id, key: key), prompt: prompt) else {
                continue
            }
            logger.registerSecret(value)
            out[key] = value
        }
        return out
    }

    public func secret(_ key: String, for source: UUID, prompt: String? = nil) throws -> String? {
        guard let value = try keychain.get(account: account(source: source, key: key), prompt: prompt) else { return nil }
        logger.registerSecret(value)
        return value
    }

    /// Current TOTP codes, keyed by config field name, ready for `{{totp.x}}`.
    /// The code itself is registered as a secret too: a code in a log is only
    /// useful for 30 seconds, but that is 30 seconds too many.
    public func totpCodes(for source: Source, manifest: PluginManifest) throws -> [String: String] {
        var out: [String: String] = [:]
        for (key, field) in manifest.configSchema ?? [:] where field.type == .totp {
            guard let seed = try keychain.get(account: account(source: source.id, key: key)) else { continue }
            guard let parsed = TOTP.normaliseSecret(seed) else {
                throw IRError.vault("the TOTP secret stored for '\(key)' is unusable")
            }
            let code = try TOTP.code(secret: parsed.secret, digits: parsed.digits,
                                     period: parsed.period, algorithm: parsed.algorithm)
            RedactingLogger.shared.registerSecret(code)
            out[key] = code
        }
        return out
    }

    /// F4.4: removing a source removes its secrets, and we verify rather than
    /// assume, because "no residue" is a promise made to the user.
    @discardableResult
    public func purge(source: UUID) throws -> Int {
        let prefix = "source.\(source.uuidString)."
        let existing = try keychain.accounts(withPrefix: prefix)
        for account in existing {
            try keychain.delete(account: account)
        }
        let remaining = try keychain.accounts(withPrefix: prefix)
        guard remaining.isEmpty else {
            throw IRError.vault("\(remaining.count) secret(s) survived deletion of source \(source)")
        }
        return existing.count
    }

    public func storedKeys(for source: UUID) throws -> [String] {
        let prefix = "source.\(source.uuidString)."
        return try keychain.accounts(withPrefix: prefix).map { String($0.dropFirst(prefix.count)) }
    }
}

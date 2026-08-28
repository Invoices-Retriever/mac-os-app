import Foundation

/// The engine's view of secrets: ask for a source's credentials, get them
/// registered with the redacting logger, use them, forget them.
///
/// **One keychain item per source**, holding every secret that source needs, as
/// the specification asks (F4.1). That is not only tidiness. macOS prompts for
/// authorisation once per *item*, so a source with a password and a two-factor
/// seed asked twice; reading the seed again to generate a code made it three.
/// Signing in should cost at most one prompt, and with a stably signed build it
/// costs none at all.
public final class CredentialVault: @unchecked Sendable {
    private let keychain: Keychain
    private let logger: RedactingLogger

    public init(keychain: Keychain = Keychain(), logger: RedactingLogger = .shared) {
        self.keychain = keychain
        self.logger = logger
    }

    /// The single item. Everything for a source lives under this account.
    private func account(source: UUID) -> String {
        "source.\(source.uuidString)"
    }

    /// Where a secret used to live, one item per field. Read once and migrated.
    private func legacyAccount(source: UUID, key: String) -> String {
        "source.\(source.uuidString).\(key)"
    }

    // MARK: - Reading

    /// Every secret a source holds, in one keychain read.
    ///
    /// Values are registered with the redacting logger here rather than at the
    /// point of use, so there is no window in which a secret exists but
    /// redaction does not know about it.
    public func secrets(for source: Source, manifest: PluginManifest,
                        prompt: String? = nil) throws -> [String: String] {
        let stored = try bundle(for: source.id, prompt: prompt)
        var out: [String: String] = [:]
        for key in manifest.secretConfigKeys {
            guard let value = stored[key], !value.isEmpty else { continue }
            logger.registerSecret(value)
            out[key] = value
        }
        return out
    }

    public func secret(_ key: String, for source: UUID, prompt: String? = nil) throws -> String? {
        guard let value = try bundle(for: source, prompt: prompt)[key], !value.isEmpty else { return nil }
        logger.registerSecret(value)
        return value
    }

    /// Current TOTP codes, keyed by config field name, ready for `{{totp.x}}`.
    ///
    /// Takes the seeds it was already given rather than going back to the
    /// keychain: the caller has just read them, and a second read is a second
    /// prompt for a value already in hand.
    public func totpCodes(from secrets: [String: String],
                          manifest: PluginManifest) throws -> [String: String] {
        var out: [String: String] = [:]
        for (key, field) in manifest.configSchema ?? [:] where field.type == .totp {
            guard let seed = secrets[key], !seed.isEmpty else { continue }
            guard let parsed = TOTP.normaliseSecret(seed) else {
                throw IRError.vault(core("the two-factor secret stored for '%@' is unusable", key))
            }
            let code = try TOTP.code(secret: parsed.secret, digits: parsed.digits,
                                     period: parsed.period, algorithm: parsed.algorithm)
            // A code is only useful for thirty seconds, but that is thirty
            // seconds too many in a log.
            logger.registerSecret(code)
            out[key] = code
        }
        return out
    }

    // MARK: - Writing

    public func store(_ value: String, for key: String, source: UUID,
                      requireBiometrics: Bool = false) throws {
        var stored = try bundleForWriting(source)
        if value.isEmpty { stored.removeValue(forKey: key) } else { stored[key] = value }
        try write(stored, for: source, requireBiometrics: requireBiometrics)
    }

    /// Writes several at once, which is what adding a source actually does.
    public func store(_ values: [String: String], source: UUID,
                      requireBiometrics: Bool = false) throws {
        var stored = try bundleForWriting(source)
        for (key, value) in values {
            if value.isEmpty { stored.removeValue(forKey: key) } else { stored[key] = value }
        }
        try write(stored, for: source, requireBiometrics: requireBiometrics)
    }

    /// F4.4: removing a source removes its secrets, and we verify rather than
    /// assume, because "no residue" is a promise made to the user.
    @discardableResult
    public func purge(source: UUID) throws -> Int {
        let stored = (try? bundle(for: source)) ?? [:]
        try keychain.delete(account: account(source: source))

        // Anything left from when secrets were one item per field.
        let prefix = "source.\(source.uuidString)."
        let legacy = try keychain.accounts(withPrefix: prefix)
        for item in legacy { try keychain.delete(account: item) }

        let remaining = try keychain.accounts(withPrefix: "source.\(source.uuidString)")
        guard remaining.isEmpty else {
            throw IRError.vault(core("%@ secret(s) survived deletion", String(remaining.count)))
        }
        return max(stored.count, legacy.count)
    }

    public func storedKeys(for source: UUID) throws -> [String] {
        Array((try bundle(for: source)).keys).sorted()
    }

    // MARK: - Storage

    /// What is stored, for the purpose of writing over it.
    ///
    /// Writing is the *remedy* for an item the keychain will not release — the
    /// user is told to enter their credentials again, and doing so rewrites the
    /// item under the signature of the application actually running. So this
    /// path must not be blocked by the very failure it exists to fix. Reading
    /// first is only ever an optimisation, to keep the fields the user is not
    /// retyping; when the old value is unreachable there is nothing to keep,
    /// and it is replaced wholesale.
    private func bundleForWriting(_ source: UUID) throws -> [String: String] {
        do {
            return try bundle(for: source)
        } catch let error as IRError where Self.isUnreadable(error) {
            logger.warning("the stored credentials for this source could not be read; "
                         + "replacing the keychain item rather than merging into it")
            return [:]
        }
    }

    /// Whether a failure means "the item is there but shut" rather than
    /// something a write should not paper over.
    public static func isUnreadable(_ error: IRError) -> Bool {
        if case .credentialsUnreadable = error { return true }
        return false
    }

    private func bundle(for source: UUID, prompt: String? = nil) throws -> [String: String] {
        if let raw = try keychain.get(account: account(source: source), prompt: prompt),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            return decoded
        }
        return try migrateLegacyItems(for: source, prompt: prompt)
    }

    /// Reads the per-field items an earlier version wrote and folds them into
    /// one, so an existing install stops paying a prompt per field without the
    /// user re-entering anything.
    private func migrateLegacyItems(for source: UUID, prompt: String?) throws -> [String: String] {
        let prefix = "source.\(source.uuidString)."
        let accounts = try keychain.accounts(withPrefix: prefix)
        guard !accounts.isEmpty else { return [:] }

        var stored: [String: String] = [:]
        for item in accounts {
            let key = String(item.dropFirst(prefix.count))
            if let value = try keychain.get(account: item, prompt: prompt) {
                stored[key] = value
            }
        }
        guard !stored.isEmpty else { return [:] }

        try write(stored, for: source, requireBiometrics: false)
        for item in accounts { try? keychain.delete(account: item) }
        logger.info("consolidated \(stored.count) keychain item(s) into one for this source")
        return stored
    }

    private func write(_ stored: [String: String], for source: UUID,
                       requireBiometrics: Bool) throws {
        guard !stored.isEmpty else {
            try keychain.delete(account: account(source: source))
            return
        }
        let data = try JSONEncoder().encode(stored)
        try keychain.set(String(decoding: data, as: UTF8.self),
                         account: account(source: source),
                         requireBiometrics: requireBiometrics)
    }
}

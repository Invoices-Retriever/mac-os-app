import Foundation
import Security
import LocalAuthentication

/// Thin, honest wrapper over the macOS keychain.
///
/// Everything secret in this application ends up here and nowhere else: not in
/// SQLite, not in a preferences file, not in the run log. That is the whole
/// mitigation for a stolen machine (M5), and it only holds if there is exactly
/// one door in and out — this type.
public struct Keychain: Sendable {
    public let service: String

    public init(service: String = "app.invoicesretriever.vault") {
        self.service = service
    }

    /// `requireBiometrics` binds the item to Touch ID or the login password
    /// (F4.2). It is off by default: prompting for every field of every source
    /// on every run would train the user to click through prompts.
    public func set(_ value: String, account: String, requireBiometrics: Bool = false) throws {
        let data = Data(value.utf8)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        if requireBiometrics {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                [.userPresence],
                &error
            ) else {
                throw IRError.vault("could not create access control: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
            }
            query[kSecAttrAccessControl as String] = access
        } else {
            // ThisDeviceOnly keeps secrets out of iCloud Keychain, so a
            // compromised Apple account does not hand over every supplier login.
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw IRError.vault("could not store '\(account)' (OSStatus \(status))")
        }
    }

    public func get(account: String, prompt: String? = nil) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let prompt { query[kSecUseOperationPrompt as String] = prompt }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        case errSecUserCanceled, errSecAuthFailed:
            throw IRError.vault("access to '\(account)' was refused")
        default:
            throw IRError.vault("could not read '\(account)' (OSStatus \(status))")
        }
    }

    public func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw IRError.vault("could not delete '\(account)' (OSStatus \(status))")
        }
    }

    /// Accounts currently stored, so that deleting a source can prove it left
    /// nothing behind (F4.4).
    public func accounts(withPrefix prefix: String) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw IRError.vault("could not enumerate the vault (OSStatus \(status))")
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
            .filter { $0.hasPrefix(prefix) }
    }

    public static func biometricsAvailable() -> Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }
}

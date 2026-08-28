import Foundation
import CryptoKit

/// Ed25519 signing for the plugin index (F10.2).
///
/// The threat this addresses is R7: a malicious plugin reaching users. An index
/// nobody signs is an index anyone can substitute — on a compromised CDN, or
/// through a hijacked repository — and the app would install whatever it said.
/// Signing moves the trust to a key held outside the distribution path.
public enum Signing {

    public struct KeyPair: Sendable {
        public let privateKeyBase64: String
        public let publicKeyBase64: String
    }

    public static func generateKeyPair() -> KeyPair {
        let key = Curve25519.Signing.PrivateKey()
        return KeyPair(
            privateKeyBase64: key.rawRepresentation.base64EncodedString(),
            publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString())
    }

    public static func sign(_ data: Data, privateKeyBase64: String) throws -> Data {
        guard let raw = Data(base64Encoded: privateKeyBase64),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
            throw IRError.invalidPlugin("the signing key is not a valid base64 Ed25519 private key")
        }
        return try key.signature(for: data)
    }

    public static func verify(_ data: Data, signature: Data, publicKeyBase64: String) -> Bool {
        guard let raw = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
            return false
        }
        return key.isValidSignature(signature, for: data)
    }
}

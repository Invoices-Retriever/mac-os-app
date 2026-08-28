import Foundation
import CryptoKit

/// RFC 6238 time-based one-time passwords (F3.3).
///
/// Generating the code locally from a seed the user pasted once is the
/// difference between an unattended monthly collection and one that stops on
/// every source to wait for a phone.
public enum TOTP {
    public enum Algorithm: String, Sendable, CaseIterable {
        case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512"
    }

    public static func code(secret: String,
                            at date: Date = Date(),
                            digits: Int = 6,
                            period: TimeInterval = 30,
                            algorithm: Algorithm = .sha1) throws -> String {
        guard let key = base32Decode(secret) else {
            throw IRError.vault("the TOTP secret is not valid base32")
        }
        guard (6...8).contains(digits) else {
            throw IRError.vault("TOTP digits must be between 6 and 8")
        }

        var counter = UInt64(floor(date.timeIntervalSince1970 / period)).bigEndian
        let counterData = Data(bytes: &counter, count: MemoryLayout<UInt64>.size)
        let symmetricKey = SymmetricKey(data: key)

        let digest: Data
        switch algorithm {
        case .sha1:   digest = Data(HMAC<Insecure.SHA1>.authenticationCode(for: counterData, using: symmetricKey))
        case .sha256: digest = Data(HMAC<SHA256>.authenticationCode(for: counterData, using: symmetricKey))
        case .sha512: digest = Data(HMAC<SHA512>.authenticationCode(for: counterData, using: symmetricKey))
        }

        // Dynamic truncation, RFC 4226 §5.4.
        let offset = Int(digest[digest.count - 1] & 0x0f)
        let truncated = (UInt32(digest[offset] & 0x7f) << 24)
            | (UInt32(digest[offset + 1]) << 16)
            | (UInt32(digest[offset + 2]) << 8)
            | UInt32(digest[offset + 3])

        let modulus = UInt32(pow(10, Double(digits)))
        return String(format: "%0\(digits)u", truncated % modulus)
    }

    /// Seconds until the current code expires, so the engine can decide to wait
    /// rather than type a code that dies mid-submit.
    public static func secondsRemaining(at date: Date = Date(), period: TimeInterval = 30) -> TimeInterval {
        period - date.timeIntervalSince1970.truncatingRemainder(dividingBy: period)
    }

    /// Accepts a bare secret or a full otpauth:// URI, because that is what
    /// people actually have in front of them when they set a source up.
    public static func normaliseSecret(_ input: String) -> (secret: String, digits: Int, period: TimeInterval, algorithm: Algorithm)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("otpauth://") {
            guard let components = URLComponents(string: trimmed) else { return nil }
            let items = components.queryItems ?? []
            guard let secret = items.first(where: { $0.name == "secret" })?.value else { return nil }
            let digits = items.first(where: { $0.name == "digits" })?.value.flatMap(Int.init) ?? 6
            let period = items.first(where: { $0.name == "period" })?.value.flatMap(TimeInterval.init) ?? 30
            let algorithm = items.first(where: { $0.name == "algorithm" })?.value
                .flatMap { Algorithm(rawValue: $0.uppercased()) } ?? .sha1
            return (secret, digits, period, algorithm)
        }
        let cleaned = trimmed.replacingOccurrences(of: " ", with: "").uppercased()
        guard base32Decode(cleaned) != nil else { return nil }
        return (cleaned, 6, 30, .sha1)
    }

    static func base32Decode(_ input: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var lookup: [Character: UInt8] = [:]
        for (i, c) in alphabet.enumerated() { lookup[c] = UInt8(i) }

        let cleaned = input.uppercased()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard !cleaned.isEmpty else { return nil }

        var bits = 0
        var accumulator: UInt32 = 0
        var out = Data()
        for character in cleaned {
            guard let value = lookup[character] else { return nil }
            accumulator = (accumulator << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                out.append(UInt8((accumulator >> UInt32(bits - 8)) & 0xff))
                bits -= 8
            }
        }
        return out.isEmpty ? nil : out
    }
}

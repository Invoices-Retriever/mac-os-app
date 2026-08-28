import Foundation

/// An RFC 5322 message with attachments, built by hand.
///
/// No dependency for this on purpose (M6): a mail composer is a few hundred
/// lines of string building, and the alternative is pulling a package into an
/// application whose whole security story is that it has none.
///
/// Everything here is pure. The awkward parts of e-mail — headers that must be
/// encoded when they are not ASCII, lines that must not exceed 998 octets, a
/// lone "." that would end the message early — are all decisions with one right
/// answer that can be checked without a server anywhere near.
public struct MIMEMessage: Sendable {
    public struct Attachment: Sendable {
        public var filename: String
        public var mimeType: String
        public var data: Data

        public init(filename: String, mimeType: String = "application/pdf", data: Data) {
            self.filename = filename
            self.mimeType = mimeType
            self.data = data
        }
    }

    public var from: String
    public var to: [String]
    public var subject: String
    public var body: String
    public var attachments: [Attachment]
    public var date: Date
    /// Injected so the same message renders identically in a test.
    public var boundary: String
    public var messageID: String

    public init(from: String,
                to: [String],
                subject: String,
                body: String,
                attachments: [Attachment] = [],
                date: Date = Date(),
                boundary: String = "ir-\(UUID().uuidString)",
                messageID: String = "\(UUID().uuidString)@invoicesretriever.app") {
        self.from = from
        self.to = to
        self.subject = subject
        self.body = body
        self.attachments = attachments
        self.date = date
        self.boundary = boundary
        self.messageID = messageID
    }

    public func render() -> String {
        var lines: [String] = [
            "From: \(Self.encodeAddress(from))",
            "To: \(to.map(Self.encodeAddress).joined(separator: ", "))",
            "Subject: \(Self.encodeHeader(subject))",
            "Date: \(Self.rfc5322Date(date))",
            "Message-ID: <\(messageID)>",
            "MIME-Version: 1.0",
        ]

        if attachments.isEmpty {
            lines.append("Content-Type: text/plain; charset=UTF-8")
            lines.append("Content-Transfer-Encoding: base64")
            lines.append("")
            lines.append(contentsOf: Self.base64Lines(Data(body.utf8)))
        } else {
            lines.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
            lines.append("")
            lines.append("--\(boundary)")
            lines.append("Content-Type: text/plain; charset=UTF-8")
            lines.append("Content-Transfer-Encoding: base64")
            lines.append("")
            lines.append(contentsOf: Self.base64Lines(Data(body.utf8)))

            for attachment in attachments {
                lines.append("")
                lines.append("--\(boundary)")
                lines.append("Content-Type: \(attachment.mimeType); name=\"\(Self.encodeHeader(attachment.filename))\"")
                lines.append("Content-Transfer-Encoding: base64")
                lines.append("Content-Disposition: attachment; filename=\"\(Self.encodeHeader(attachment.filename))\"")
                lines.append("")
                lines.append(contentsOf: Self.base64Lines(attachment.data))
            }
            lines.append("")
            lines.append("--\(boundary)--")
        }
        return lines.joined(separator: "\r\n")
    }

    /// The message as it goes inside DATA: every line that begins with a dot
    /// gets another, because a bare "." on its own line is what ends the
    /// message. Forgetting this truncates any mail whose body happens to start
    /// a line with a full stop, which is rare enough to ship and awful to find.
    public func dataPayload() -> String {
        let stuffed = render()
            .components(separatedBy: "\r\n")
            .map { $0.hasPrefix(".") ? "." + $0 : $0 }
            .joined(separator: "\r\n")
        return stuffed + "\r\n.\r\n"
    }

    // MARK: - The fiddly parts

    /// RFC 2047. A subject with an accent in it is not ASCII, and sending it
    /// raw produces the mojibake everyone has seen in a mail client.
    public static func encodeHeader(_ value: String) -> String {
        guard value.contains(where: { !$0.isASCII }) else { return value }
        let encoded = Data(value.utf8).base64EncodedString()
        return "=?UTF-8?B?\(encoded)?="
    }

    /// A display name needs encoding; the address inside the angle brackets
    /// must not be touched.
    public static func encodeAddress(_ value: String) -> String {
        guard let open = value.lastIndex(of: "<"), value.hasSuffix(">") else {
            return value
        }
        let name = String(value[value.startIndex..<open]).trimmingCharacters(in: .whitespaces)
        let address = String(value[open...])
        return name.isEmpty ? address : "\(encodeHeader(name)) \(address)"
    }

    /// Base64 wrapped at 76 characters, as the encoding requires.
    public static func base64Lines(_ data: Data) -> [String] {
        let encoded = data.base64EncodedString()
        var lines: [String] = []
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let end = encoded.index(index, offsetBy: 76, limitedBy: encoded.endIndex) ?? encoded.endIndex
            lines.append(String(encoded[index..<end]))
            index = end
        }
        return lines
    }

    /// Deliberately not DateFormatter's locale-sensitive output: the month has
    /// to be the English abbreviation whatever the user's region is, and a
    /// French "mars" in a Date header is a malformed message.
    public static func rfc5322Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}

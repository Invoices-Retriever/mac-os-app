import Foundation

/// Turns a document into a filename the user chose the shape of (F7.4).
///
/// The default is `{date}_{issuer}_{number}_{total}.pdf`, which sorts
/// chronologically in Finder and tells an accountant what they are looking at
/// without opening it — the whole point of the exercise.
public struct NamingTemplate: Sendable, Codable, Hashable {
    public var pattern: String

    public static let `default` = NamingTemplate(pattern: "{date}_{issuer}_{number}_{total}")
    public static let folderDefault = NamingTemplate(pattern: "{year}/{month}")

    public init(pattern: String) {
        self.pattern = pattern
    }

    public static let availableTokens: [(token: String, explanation: String)] = [
        ("{date}", "Invoice date, 2026-03-31"),
        ("{year}", "2026"),
        ("{month}", "03"),
        ("{day}", "31"),
        ("{issuer}", "Supplier name"),
        ("{source}", "Name you gave the source"),
        ("{number}", "Invoice number"),
        ("{total}", "Gross amount, 1234.56"),
        ("{currency}", "EUR"),
        ("{kind}", "invoice, credit-note, receipt…"),
        ("{id}", "Identifier reported by the plugin"),
    ]

    public func render(document: InvoiceDocument, sourceName: String?) -> String {
        var output = pattern
        for (token, value) in tokens(document: document, sourceName: sourceName) {
            output = output.replacingOccurrences(of: token, with: value)
        }
        // Collapse the gaps a missing field leaves behind: an invoice with no
        // number should be "2026-03-31_OVH.pdf", not "2026-03-31_OVH__.pdf".
        while output.contains("__") { output = output.replacingOccurrences(of: "__", with: "_") }
        while output.contains("--") { output = output.replacingOccurrences(of: "--", with: "-") }
        output = output.trimmingCharacters(in: CharacterSet(charactersIn: "_- "))
        return output.isEmpty ? "document" : output
    }

    private func tokens(document: InvoiceDocument, sourceName: String?) -> [(String, String)] {
        let date = document.issuedOn ?? document.createdAt
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)

        let total = document.total.map { money -> String in
            let value = abs(money.cents)
            return String(format: "%d.%02d", value / 100, value % 100)
        } ?? ""

        return [
            ("{date}", InvoiceDateParser.isoString(date)),
            ("{year}", parts.year.map(String.init) ?? ""),
            ("{month}", parts.month.map { String(format: "%02d", $0) } ?? ""),
            ("{day}", parts.day.map { String(format: "%02d", $0) } ?? ""),
            ("{issuer}", Self.sanitise(document.issuer ?? sourceName ?? "")),
            ("{source}", Self.sanitise(sourceName ?? "")),
            ("{number}", Self.sanitise(document.number ?? "")),
            ("{total}", total),
            ("{currency}", document.total?.currency ?? ""),
            ("{kind}", document.kind.rawValue),
            ("{id}", Self.sanitise(document.pluginDocumentID ?? "")),
        ]
    }

    /// Makes a scraped string safe as a path component on macOS, and reasonable
    /// on Windows too — users sync these folders, and a filename with a colon
    /// in it breaks on the other side.
    public static func sanitise(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\u{0}\n\r\t")
        var cleaned = raw.components(separatedBy: forbidden).joined(separator: "-")
        cleaned = cleaned.replacingOccurrences(of: " ", with: "-")
        while cleaned.contains("--") { cleaned = cleaned.replacingOccurrences(of: "--", with: "-") }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-. "))
        // Leave room for a disambiguating suffix and the extension.
        return String(cleaned.prefix(60))
    }
}

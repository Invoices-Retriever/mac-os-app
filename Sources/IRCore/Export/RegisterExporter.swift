import Foundation

/// F8.5. The register: one row per document, for reconciliation in a
/// spreadsheet or an accounting package.
///
/// Amounts are written as plain decimals with a dot, and dates as ISO-8601,
/// because the alternative — locale-formatted values — is how a French comma
/// decimal ends up parsed as a thousands separator in someone else's tool.
public struct RegisterExporter: Exporter {
    public enum Format: String, Sendable { case csv, json }

    public let format: Format
    public let outputURL: URL
    public let sourceNames: [UUID: String]

    public init(format: Format, outputURL: URL, sourceNames: [UUID: String] = [:]) {
        self.format = format
        self.outputURL = outputURL
        self.sourceNames = sourceNames
    }

    public var destinationID: String { "\(format.rawValue):\(outputURL.standardizedFileURL.path)" }
    public var kind: ExportDestinationKind { format == .csv ? .csv : .json }
    public var displayName: String { "\(format.rawValue.uppercased()) register" }

    public func export(_ document: InvoiceDocument, fileURL: URL) async throws -> String? {
        nil  // the register is written once, in finish
    }

    public func finish(_ documents: [InvoiceDocument]) async throws -> String? {
        guard !documents.isEmpty else { return nil }
        let data: Data
        switch format {
        case .csv:
            data = Data(csv(documents).utf8)
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            data = try encoder.encode(documents.map(row))
        }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: outputURL, options: .atomic)
        return "\(documents.count) row(s) written to \(outputURL.lastPathComponent)"
    }

    private static let columns = [
        "date", "issuer", "number", "total", "net", "vat", "currency",
        "vat_number", "kind", "source", "origin", "verified", "confidence", "file", "sha256",
    ]

    private func csv(_ documents: [InvoiceDocument]) -> String {
        var lines = [Self.columns.joined(separator: ",")]
        for document in documents {
            let values = Self.columns.map { field(document, $0) }
            lines.append(values.map(Self.escape).joined(separator: ","))
        }
        // A BOM makes Excel on macOS open UTF-8 as UTF-8 rather than mangling
        // every accented supplier name.
        return "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
    }

    private func row(_ document: InvoiceDocument) -> [String: String] {
        Dictionary(uniqueKeysWithValues: Self.columns.map { ($0, field(document, $0)) })
    }

    private func field(_ document: InvoiceDocument, _ column: String) -> String {
        func amount(_ money: Money?) -> String {
            guard let money else { return "" }
            let sign = money.cents < 0 ? "-" : ""
            let value = abs(money.cents)
            return String(format: "%@%d.%02d", sign, value / 100, value % 100)
        }
        switch column {
        case "date": return document.issuedOn.map(InvoiceDateParser.isoString) ?? ""
        case "issuer": return document.issuer ?? ""
        case "number": return document.number ?? ""
        case "total": return amount(document.total)
        case "net": return amount(document.net)
        case "vat": return amount(document.vat)
        case "currency": return document.total?.currency ?? ""
        case "vat_number": return document.vatNumber ?? ""
        case "kind": return document.kind.rawValue
        case "source": return document.sourceID.flatMap { sourceNames[$0] } ?? ""
        case "origin": return document.origin.rawValue
        case "verified": return document.verifiedByHuman ? "yes" : "no"
        case "confidence": return String(format: "%.2f", document.lowestConfidence)
        case "file": return document.relativePath
        case "sha256": return document.sha256
        default: return ""
        }
    }

    private static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

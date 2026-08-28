import Foundation

/// A collected document and everything we know about it.
///
/// The file itself lives in the user's document folder, in a layout readable
/// without this app (F7.1). This record is the index entry; losing the SQLite
/// database must never mean losing documents, and re-scanning the folder
/// rebuilds it (F7.2).
public struct InvoiceDocument: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var entityID: UUID
    public var sourceID: UUID?
    /// Stable identifier reported by the plugin. Together with sourceID it is
    /// the primary deduplication key, and it catches the case where a portal
    /// re-renders the same invoice into a byte-different PDF.
    public var pluginDocumentID: String?
    /// SHA-256 of the file contents: the second deduplication key (F7.3),
    /// which catches the same document arriving from two different sources.
    public var sha256: String
    /// Path relative to the library root, so the library can be moved.
    public var relativePath: String
    public var byteSize: Int

    public var issuer: String?
    public var number: String?
    public var issuedOn: Date?
    public var total: Money?
    public var net: Money?
    public var vat: Money?
    public var vatNumber: String?
    public var kind: DocumentKind
    public var origin: DocumentOrigin

    public var fieldConfidence: [String: Double]
    public var verifiedByHuman: Bool
    public var extractedText: String?
    public var notes: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(),
                entityID: UUID,
                sourceID: UUID? = nil,
                pluginDocumentID: String? = nil,
                sha256: String,
                relativePath: String,
                byteSize: Int,
                kind: DocumentKind = .invoice,
                origin: DocumentOrigin = .portal,
                createdAt: Date = Date()) {
        self.id = id
        self.entityID = entityID
        self.sourceID = sourceID
        self.pluginDocumentID = pluginDocumentID
        self.sha256 = sha256
        self.relativePath = relativePath
        self.byteSize = byteSize
        self.kind = kind
        self.origin = origin
        self.fieldConfidence = [:]
        self.verifiedByHuman = false
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    /// Lowest confidence across the fields that matter, so the library can flag
    /// a document worth a human glance (F6.7).
    public var lowestConfidence: Double {
        let keys = ["issuer", "number", "issuedOn", "total"]
        let values = keys.compactMap { fieldConfidence[$0] }
        return values.min() ?? 0
    }

    public var needsReview: Bool {
        !verifiedByHuman && lowestConfidence < 0.6
    }
}

public enum DocumentOrigin: String, Codable, Sendable, Hashable, CaseIterable {
    case portal, email, manualImport, folderScan

    public var displayName: String {
        switch self {
        case .portal: return core("Portal")
        case .email: return core("E-mail")
        case .manualImport: return core("Imported")
        case .folderScan: return core("Found on disk")
        }
    }
}

/// How a field's value was arrived at. Drives the confidence score and lets the
/// UI explain itself rather than presenting a number out of nowhere.
public enum ExtractionMethod: String, Codable, Sendable, Hashable {
    case plugin      // declared by the plugin: the most reliable source (F6.1)
    case pdfText     // regex over embedded text
    case ocr         // Vision, on a scanned PDF
    case llm         // opt-in fallback, off by default
    case human       // corrected by the user

    public var baseConfidence: Double {
        switch self {
        case .plugin: return 0.95
        case .pdfText: return 0.75
        case .ocr: return 0.55
        case .llm: return 0.7
        case .human: return 1.0
        }
    }
}

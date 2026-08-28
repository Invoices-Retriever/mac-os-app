import Foundation

/// Proof that a document reached a destination, which is what makes exports
/// idempotent (F8.7): a second export skips whatever is already recorded here
/// unless the user explicitly asks to send it again.
public struct ExportRecord: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var documentID: UUID
    public var destinationID: String
    public var destinationKind: ExportDestinationKind
    public var exportedAt: Date
    public var succeeded: Bool
    public var detail: String?

    public init(id: UUID = UUID(), documentID: UUID, destinationID: String,
                destinationKind: ExportDestinationKind, exportedAt: Date = Date(),
                succeeded: Bool = true, detail: String? = nil) {
        self.id = id
        self.documentID = documentID
        self.destinationID = destinationID
        self.destinationKind = destinationKind
        self.exportedAt = exportedAt
        self.succeeded = succeeded
        self.detail = detail
    }
}

public enum ExportDestinationKind: String, Codable, Sendable, Hashable, CaseIterable {
    case folder, csv, json, webhook, email, smtp, paperless

    public var displayName: String {
        switch self {
        case .folder: return core("Folder")
        case .csv: return core("CSV register")
        case .json: return core("JSON register")
        case .webhook: return core("Webhook")
        case .email: return core("E-mail (your mail app)")
        case .smtp: return core("E-mail (mail server)")
        case .paperless: return core("Paperless-ngx")
        }
    }
}

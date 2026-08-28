import Foundation

/// One destination documents can be sent to.
///
/// Every destination goes through the same interface so that idempotence
/// (F8.7) is enforced once, by `ExportService`, rather than being re-derived —
/// and forgotten — in each exporter. An exporter's job is to move one document
/// and say what happened; it does not decide whether it should.
public protocol Exporter: Sendable {
    /// Stable identity of this configured destination. Two folder exports to
    /// two different directories are two destinations, and a document sent to
    /// one is not "already exported" for the other.
    var destinationID: String { get }
    var kind: ExportDestinationKind { get }
    var displayName: String { get }

    func export(_ document: InvoiceDocument, fileURL: URL) async throws -> String?
    /// Called once after a batch, for destinations that emit a single artefact
    /// — a CSV register, a monthly e-mail.
    func finish(_ documents: [InvoiceDocument]) async throws -> String?
}

public extension Exporter {
    func finish(_ documents: [InvoiceDocument]) async throws -> String? { nil }
}

public actor ExportService {
    private let store: Store
    private let library: DocumentLibrary
    private let logger: RedactingLogger

    public init(store: Store, library: DocumentLibrary, logger: RedactingLogger = .shared) {
        self.store = store
        self.library = library
        self.logger = logger
    }

    public struct Report: Sendable {
        public var exported: [UUID] = []
        public var skipped: [UUID] = []
        public var failed: [(documentID: UUID, message: String)] = []
        public var summary: String?

        public var exportedCount: Int { exported.count }
    }

    /// UC-05. `force` is the "sauf demande explicite" of F8.7 — the user asking
    /// for a document to be sent again, which is a legitimate thing to want.
    public func export(_ documents: [InvoiceDocument],
                       to exporter: any Exporter,
                       force: Bool = false,
                       progress: (@Sendable (Int, Int) -> Void)? = nil) async -> Report {
        var report = Report()
        var succeeded: [InvoiceDocument] = []

        for (index, document) in documents.enumerated() {
            progress?(index, documents.count)

            if !force {
                let already = (try? await store.hasBeenExported(
                    documentID: document.id, destinationID: exporter.destinationID)) ?? false
                if already { report.skipped.append(document.id); continue }
            }

            let fileURL = library.url(for: document)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                report.failed.append((document.id, "the file is missing from the library"))
                continue
            }

            do {
                let detail = try await exporter.export(document, fileURL: fileURL)
                try await store.record(ExportRecord(
                    documentID: document.id, destinationID: exporter.destinationID,
                    destinationKind: exporter.kind, succeeded: true, detail: detail))
                report.exported.append(document.id)
                succeeded.append(document)
            } catch {
                let message = logger.redact(error.localizedDescription)
                report.failed.append((document.id, message))
                try? await store.record(ExportRecord(
                    documentID: document.id, destinationID: exporter.destinationID,
                    destinationKind: exporter.kind, succeeded: false, detail: message))
                logger.error("export to \(exporter.displayName) failed: \(message)")
            }
        }

        report.summary = try? await exporter.finish(succeeded)
        progress?(documents.count, documents.count)
        return report
    }

    /// The documents a destination has not seen yet, which is what an "export
    /// this month" button actually wants.
    public func pendingDocuments(for exporter: any Exporter,
                                 filter: DocumentFilter) async throws -> [InvoiceDocument] {
        var filter = filter
        filter.exportedTo = DocumentFilter.ExportFilter(destinationID: exporter.destinationID, negated: true)
        return try await store.documents(filter: filter)
    }
}

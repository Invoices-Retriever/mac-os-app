import Foundation
import CryptoKit

/// Owns the document folder and the rules for putting things in it.
///
/// The invariant this type defends: the folder is legible and usable without
/// the app. Anyone can open it in Finder, see year/month directories, and read
/// the filenames. The database is an index over this, never the other way
/// round — which is why `rescan` can rebuild the index from the folder alone.
public struct DocumentLibrary: Sendable {
    public let root: URL
    public let store: Store
    public var fileTemplate: NamingTemplate
    public var folderTemplate: NamingTemplate

    public init(root: URL, store: Store,
                fileTemplate: NamingTemplate = .default,
                folderTemplate: NamingTemplate = .folderDefault) {
        self.root = root
        self.store = store
        self.fileTemplate = fileTemplate
        self.folderTemplate = folderTemplate
    }

    public enum Ingestion: Sendable {
        case stored(InvoiceDocument)
        /// Already present. Carries the existing record so the caller can say
        /// which document it collided with rather than just "skipped".
        case duplicate(InvoiceDocument, reason: DuplicateReason)
    }

    public enum DuplicateReason: String, Sendable {
        case sameContent          // identical bytes, seen before (SHA-256)
        case samePluginDocumentID // this source already reported this identifier
    }

    /// Writes a collected document to disk and indexes it, unless we already
    /// have it. Both deduplication keys of F7.3 are checked, in the order that
    /// costs least.
    public func ingest(_ collected: CollectedDocument,
                       source: Source?,
                       entityID: UUID,
                       origin: DocumentOrigin = .portal) async throws -> Ingestion {

        if let source {
            if let existing = try await store.document(sourceID: source.id,
                                                       pluginDocumentID: collected.pluginDocumentID) {
                return .duplicate(existing, reason: .samePluginDocumentID)
            }
        }

        let digest = Self.sha256(collected.data)
        if let existing = try await store.document(sha256: digest) {
            return .duplicate(existing, reason: .sameContent)
        }

        var document = InvoiceDocument(
            entityID: entityID,
            sourceID: source?.id,
            pluginDocumentID: collected.pluginDocumentID,
            sha256: digest,
            relativePath: "",
            byteSize: collected.data.count,
            kind: collected.kind,
            origin: origin)
        document.issuer = collected.issuer ?? source?.displayName
        document.number = collected.number
        document.issuedOn = collected.issuedOn
        document.total = collected.total
        document.net = collected.net
        document.vat = collected.vat
        document.vatNumber = collected.metadata["vatNumber"]

        // Values the plugin declared are the most reliable we will ever have
        // (F6.1), so they start at the plugin's confidence and the extractor
        // below is told not to overwrite them.
        for (field, value) in [("issuer", document.issuer), ("number", document.number)] {
            if value != nil { document.fieldConfidence[field] = ExtractionMethod.plugin.baseConfidence }
        }
        if document.issuedOn != nil { document.fieldConfidence["issuedOn"] = ExtractionMethod.plugin.baseConfidence }
        if document.total != nil { document.fieldConfidence["total"] = ExtractionMethod.plugin.baseConfidence }

        let relativePath = try uniqueRelativePath(for: document, sourceName: source?.displayName,
                                                  suggested: collected.suggestedFilename)
        document.relativePath = relativePath

        let destination = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try collected.data.write(to: destination, options: .atomic)

        do {
            try await store.upsert(document)
        } catch {
            // Keep the folder and the index in step: an orphaned file the user
            // never asked for is worse than no file.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return .stored(document)
    }

    /// Imports a PDF the user dropped on the window (UC-08, F5/F7).
    public func importFile(at url: URL, entityID: UUID) async throws -> Ingestion {
        let data = try Data(contentsOf: url)
        var collected = CollectedDocument(
            pluginDocumentID: url.deletingPathExtension().lastPathComponent, data: data)
        collected.suggestedFilename = url.lastPathComponent
        return try await ingest(collected, source: nil, entityID: entityID, origin: .manualImport)
    }

    // MARK: - Paths

    func uniqueRelativePath(for document: InvoiceDocument,
                            sourceName: String?,
                            suggested: String?) throws -> String {
        let folder = folderTemplate.render(document: document, sourceName: sourceName)
        var base = fileTemplate.render(document: document, sourceName: sourceName)
        if base == "document", let suggested {
            base = NamingTemplate.sanitise((suggested as NSString).deletingPathExtension)
        }

        let directory = folder.isEmpty ? root : root.appendingPathComponent(folder)
        var candidate = base + ".pdf"
        var counter = 2
        // Two invoices genuinely can share a date, an issuer and no number.
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(counter).pdf"
            counter += 1
            if counter > 999 {
                throw IRError.storage("could not find a free filename for \(base)")
            }
        }
        return folder.isEmpty ? candidate : "\(folder)/\(candidate)"
    }

    public func url(for document: InvoiceDocument) -> URL {
        root.appendingPathComponent(document.relativePath)
    }

    public func fileExists(for document: InvoiceDocument) -> Bool {
        FileManager.default.fileExists(atPath: url(for: document).path)
    }

    // MARK: - Rescan

    public struct RescanResult: Sendable {
        public var added: Int = 0
        public var alreadyKnown: Int = 0
        public var missingFiles: [InvoiceDocument] = []
    }

    /// Rebuilds the index from the folder (F7.2). This is the answer to "what
    /// happens if the database is lost", and it is also how a user brings an
    /// existing archive of PDFs into the app.
    public func rescan(entityID: UUID) async throws -> RescanResult {
        var result = RescanResult()
        let known = try await store.allRelativePaths()

        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "pdf" else { continue }
            let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")
            if known.contains(relativePath) { result.alreadyKnown += 1; continue }

            let data = try Data(contentsOf: url)
            let digest = Self.sha256(data)
            if try await store.document(sha256: digest) != nil { result.alreadyKnown += 1; continue }

            var document = InvoiceDocument(
                entityID: entityID, sha256: digest, relativePath: relativePath,
                byteSize: data.count, origin: .folderScan)
            document.issuedOn = InvoiceDateParser.parse(String(url.lastPathComponent.prefix(10)))
            try await store.upsert(document)
            result.added += 1
        }

        for document in try await store.documents(filter: DocumentFilter(entityID: entityID))
        where !fileExists(for: document) {
            result.missingFiles.append(document)
        }
        return result
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// F7.7: nothing is deleted without the caller having asked in as many
    /// words. There is no automatic cleanup anywhere in this application.
    public func delete(_ document: InvoiceDocument, removeFile: Bool) async throws {
        if removeFile {
            let url = url(for: document)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        }
        try await store.deleteDocument(id: document.id)
    }
}

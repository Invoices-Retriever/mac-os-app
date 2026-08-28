import Foundation

/// F8.1. Copies documents into a folder the user hands to their accountant,
/// with a directory layout they chose.
///
/// The copy is deliberate rather than a move or a link: the library keeps its
/// own organisation, and an accountant's folder that stops working because the
/// library was reorganised would be a nasty surprise.
public struct FolderExporter: Exporter {
    public let root: URL
    public let folderTemplate: NamingTemplate
    public let fileTemplate: NamingTemplate
    public let sourceNames: [UUID: String]

    public init(root: URL,
                folderTemplate: NamingTemplate = .folderDefault,
                fileTemplate: NamingTemplate = .default,
                sourceNames: [UUID: String] = [:]) {
        self.root = root
        self.folderTemplate = folderTemplate
        self.fileTemplate = fileTemplate
        self.sourceNames = sourceNames
    }

    public var destinationID: String { "folder:\(root.standardizedFileURL.path)" }
    public var kind: ExportDestinationKind { .folder }
    public var displayName: String { "Folder \(root.lastPathComponent)" }

    public func export(_ document: InvoiceDocument, fileURL: URL) async throws -> String? {
        let sourceName = document.sourceID.flatMap { sourceNames[$0] }
        let folder = folderTemplate.render(document: document, sourceName: sourceName)
        let base = fileTemplate.render(document: document, sourceName: sourceName)

        let directory = folder.isEmpty ? root : root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var destination = directory.appendingPathComponent(base + ".pdf")
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            // Never silently overwrite something already in the accountant's
            // folder; it may not have come from us.
            if let existing = try? Data(contentsOf: destination),
               DocumentLibrary.sha256(existing) == document.sha256 {
                return destination.path  // identical file, nothing to do
            }
            destination = directory.appendingPathComponent("\(base)-\(counter).pdf")
            counter += 1
            if counter > 999 { throw IRError.export("could not find a free name for \(base)") }
        }

        try FileManager.default.copyItem(at: fileURL, to: destination)
        return destination.path
    }
}

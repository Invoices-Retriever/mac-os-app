import Foundation
import CryptoKit

/// Everything the app knows about available plugins, and where each one came
/// from — which matters, because the warning the user sees depends on it
/// (F10.6).
public actor PluginCatalog {
    public enum Provenance: String, Sendable, Codable, Hashable {
        /// Shipped inside the application bundle. Reviewed as part of a release.
        case bundled
        /// Downloaded from the signed official index.
        case official
        /// A folder the user pointed at, typically their own work in progress.
        case local
        /// Installed from a file the user chose, not from the index. This is
        /// the one that gets the banner.
        case sideloaded
    }

    public struct Entry: Sendable, Identifiable, Hashable {
        public var id: String { manifest.id }
        public var manifest: PluginManifest
        public var provenance: Provenance
        public var fileURL: URL?
        public var installedAt: Date?

        public init(manifest: PluginManifest, provenance: Provenance,
                    fileURL: URL? = nil, installedAt: Date? = nil) {
            self.manifest = manifest
            self.provenance = provenance
            self.fileURL = fileURL
            self.installedAt = installedAt
        }

        /// F10.6 and F10.8: what a user needs to be told before they trust this.
        public var warnings: [String] {
            var out: [String] = []
            if provenance == .sideloaded || provenance == .local {
                out.append(core("This plugin did not come from the official index. It has not been reviewed by the project."))
            }
            if manifest.containsArbitraryJavaScript {
                out.append(core("It runs its own JavaScript inside the supplier's pages."))
            }
            if manifest.effectiveStatus == .degraded {
                out.append(core("It is currently reported as failing for several people."))
            }
            if manifest.effectiveStatus == .archived {
                out.append(core("It is archived: unmaintained and broken for more than 90 days."))
            }
            return out
        }

        /// The plain-language version of `allowedDomains`, for the install
        /// dialog. "It can sign in and read pages on ovh.com" is something a
        /// non-technical user can actually weigh.
        public var capabilitySummary: String {
            let domains = manifest.allowedDomains.joined(separator: ", ")
            return core("It can open pages, type your credentials and download files on: %@. It cannot reach anywhere else.", domains)
        }
    }

    private var entries: [String: Entry] = [:]
    private let installedDirectory: URL
    private var localDirectories: [URL] = []
    private let logger: RedactingLogger

    /// Public key the official index is signed with (F10.2). Compiled into the
    /// app on purpose: an index that told us which key to trust would not be
    /// verifying anything.
    public static let indexPublicKeyBase64 = "REPLACE_WITH_RELEASE_PUBLIC_KEY"

    public init(installedDirectory: URL, logger: RedactingLogger = .shared) {
        self.installedDirectory = installedDirectory
        self.logger = logger
    }

    // MARK: - Loading

    public func loadAll(bundledDirectory: URL?) async {
        entries.removeAll()
        if let bundledDirectory {
            load(from: bundledDirectory, provenance: .bundled)
        }
        load(from: installedDirectory, provenance: .official)
        for directory in localDirectories {
            load(from: directory, provenance: .local)
        }
        logger.info("catalogue: \(entries.count) plugin(s) available")
    }

    /// F10.3: point the app at a folder and iterate without reinstalling
    /// anything. This is the single biggest lever on "first plugin in under
    /// thirty minutes".
    public func addLocalDirectory(_ url: URL) {
        guard !localDirectories.contains(url) else { return }
        localDirectories.append(url)
        load(from: url, provenance: .local)
    }

    public func removeLocalDirectory(_ url: URL) {
        localDirectories.removeAll { $0 == url }
        for (id, entry) in entries where entry.provenance == .local
            && entry.fileURL?.deletingLastPathComponent() == url {
            entries.removeValue(forKey: id)
        }
    }

    public var localDirectoryURLs: [URL] { localDirectories }

    private func load(from directory: URL, provenance: Provenance) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }

        for url in contents where url.pathExtension.lowercased() == "json" {
            do {
                let manifest = try PluginManifest.decode(from: Data(contentsOf: url))
                let report = PluginValidator.validate(manifest)
                guard report.isValid else {
                    logger.warning("ignoring \(url.lastPathComponent): \(report.errors.first?.message ?? "invalid")")
                    continue
                }
                // A local copy always wins, so that a contributor debugging
                // "ovh" sees their edits rather than the shipped version.
                if let existing = entries[manifest.id], existing.provenance.precedence >= provenance.precedence,
                   provenance != .local {
                    continue
                }
                entries[manifest.id] = Entry(manifest: manifest, provenance: provenance,
                                             fileURL: url, installedAt: Date())
            } catch {
                logger.warning("could not read \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Queries

    public func manifest(id: String) -> PluginManifest? { entries[id]?.manifest }
    public func entry(id: String) -> Entry? { entries[id] }

    public func all() -> [Entry] {
        entries.values.sorted { $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending }
    }

    /// F1.1: search by name and by country, which is the axis this project is
    /// betting on — the catalogues of the German-speaking competitors are
    /// where French suppliers are hardest to find.
    public func search(text: String = "", country: String? = nil, includeArchived: Bool = false) -> [Entry] {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        return all().filter { entry in
            let manifest = entry.manifest
            if !includeArchived && manifest.effectiveStatus == .archived { return false }
            if let country, !(manifest.country ?? []).contains(country) { return false }
            guard !needle.isEmpty else { return true }
            return manifest.name.lowercased().contains(needle)
                || manifest.id.contains(needle)
                || (manifest.description ?? "").lowercased().contains(needle)
                || (manifest.tags ?? []).contains { $0.contains(needle) }
        }
    }

    public func countries() -> [String] {
        Array(Set(entries.values.flatMap { $0.manifest.country ?? [] })).sorted()
    }

    // MARK: - Installing

    /// UC-07. Validates before writing anything: a plugin that would be
    /// refused at load time should be refused at install time, with the same
    /// message.
    @discardableResult
    public func install(from url: URL, provenance: Provenance = .sideloaded) throws -> Entry {
        let data = try Data(contentsOf: url)
        let manifest = try PluginManifest.decode(from: data)
        let report = PluginValidator.validate(manifest)
        guard report.isValid else {
            throw IRError.invalidPlugin(report.errors.map(\.message).joined(separator: "; "))
        }

        try FileManager.default.createDirectory(at: installedDirectory, withIntermediateDirectories: true)
        let destination = installedDirectory.appendingPathComponent("\(manifest.id).json")
        try data.write(to: destination, options: .atomic)

        let entry = Entry(manifest: manifest, provenance: provenance,
                          fileURL: destination, installedAt: Date())
        entries[manifest.id] = entry
        logger.info("installed plugin \(manifest.id) \(manifest.version) (\(provenance.rawValue))")
        return entry
    }

    public func uninstall(id: String) throws {
        guard let entry = entries[id] else { return }
        if let url = entry.fileURL, entry.provenance != .bundled {
            try? FileManager.default.removeItem(at: url)
        }
        entries.removeValue(forKey: id)
    }

    // MARK: - Official index

    /// The signed index of F10.2 and the revocation lever of R7: if a malicious
    /// plugin is ever merged, publishing a new index with it removed and a
    /// higher revision is how it stops reaching people.
    public struct SignedIndex: Codable, Sendable {
        public struct Item: Codable, Sendable {
            public var id: String
            public var version: String
            public var name: String
            public var country: [String]?
            public var tags: [String]?
            public var status: PluginStatus?
            public var usesJs: Bool?
            public var sha256: String
            public var path: String

            public init(id: String, version: String, name: String, country: [String]?,
                        tags: [String]?, status: PluginStatus?, usesJs: Bool?,
                        sha256: String, path: String) {
                self.id = id; self.version = version; self.name = name
                self.country = country; self.tags = tags; self.status = status
                self.usesJs = usesJs; self.sha256 = sha256; self.path = path
            }
        }
        public var revision: Int
        public var generatedAt: Date
        public var engine: String
        public var plugins: [Item]

        public init(revision: Int, generatedAt: Date, engine: String, plugins: [Item]) {
            self.revision = revision; self.generatedAt = generatedAt
            self.engine = engine; self.plugins = plugins
        }
    }

    public struct IndexUpdate: Sendable {
        public var installed: [String]
        public var updated: [String]
        public var removed: [String]
        public var skipped: [String: String]
    }

    /// Verifies the detached Ed25519 signature over the index bytes, then
    /// verifies each plugin's SHA-256 against what the index promised. Both
    /// checks matter: the first says the index is ours, the second says the
    /// file we downloaded is the one the index describes.
    public static func verify(indexData: Data, signature: Data, publicKeyBase64: String) -> Bool {
        guard let keyData = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            return false
        }
        return key.isValidSignature(signature, for: indexData)
    }

    public func applyIndex(_ indexData: Data,
                           signature: Data,
                           publicKeyBase64: String = PluginCatalog.indexPublicKeyBase64,
                           fetch: @Sendable (String) async throws -> Data) async throws -> IndexUpdate {

        guard Self.verify(indexData: indexData, signature: signature, publicKeyBase64: publicKeyBase64) else {
            throw IRError.invalidPlugin("the plugin index signature is not valid; refusing to install anything from it")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let index = try decoder.decode(SignedIndex.self, from: indexData)

        var update = IndexUpdate(installed: [], updated: [], removed: [], skipped: [:])
        try FileManager.default.createDirectory(at: installedDirectory, withIntermediateDirectories: true)

        for item in index.plugins {
            let existing = entries[item.id]
            if let existing, existing.manifest.version == item.version, existing.provenance == .official {
                continue
            }
            if let existing, existing.provenance == .local {
                update.skipped[item.id] = "a local copy is in use"
                continue
            }
            do {
                let data = try await fetch(item.path)
                let digest = DocumentLibrary.sha256(data)
                guard digest == item.sha256 else {
                    update.skipped[item.id] = "checksum mismatch"
                    logger.error("refusing \(item.id): checksum does not match the index")
                    continue
                }
                let manifest = try PluginManifest.decode(from: data)
                let report = PluginValidator.validate(manifest)
                guard report.isValid else {
                    update.skipped[item.id] = report.errors.first?.message ?? "invalid"
                    continue
                }
                let destination = installedDirectory.appendingPathComponent("\(manifest.id).json")
                try data.write(to: destination, options: .atomic)
                entries[manifest.id] = Entry(manifest: manifest, provenance: .official,
                                             fileURL: destination, installedAt: Date())
                if existing == nil { update.installed.append(item.id) } else { update.updated.append(item.id) }
            } catch {
                update.skipped[item.id] = error.localizedDescription
            }
        }

        // A plugin that disappears from the index has been withdrawn, possibly
        // for a security reason. Remove it rather than leaving it installed.
        let indexed = Set(index.plugins.map(\.id))
        for (id, entry) in entries where entry.provenance == .official && !indexed.contains(id) {
            try? uninstall(id: id)
            update.removed.append(id)
        }

        logger.info("index revision \(index.revision): +\(update.installed.count) ~\(update.updated.count) -\(update.removed.count)")
        return update
    }
}

private extension PluginCatalog.Provenance {
    /// Which source wins when the same plugin id appears twice.
    var precedence: Int {
        switch self {
        case .bundled: return 0
        case .official: return 1
        case .sideloaded: return 2
        case .local: return 3
        }
    }
}

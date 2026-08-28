import Foundation

/// Fetches the published plugin index and hands it to the catalogue (F10.2).
///
/// This is the only place the application reaches a network host that is not a
/// supplier the user configured, so it is deliberately small and deliberately
/// suspicious of what comes back:
///
/// - The index must carry a valid Ed25519 signature from the key compiled into
///   this build. An unsigned or wrongly-signed index installs nothing.
/// - Every plugin path in the index is resolved *relative to the index* and
///   refused if it tries to escape — a tampered index must not be able to point
///   the downloader at another host.
/// - Each plugin's SHA-256 is checked against what the index promised, so a
///   file swapped after signing is caught.
///
/// The last two matter even though the first exists: signature verification
/// proves the index is ours, not that the bytes we then fetch are the ones it
/// describes.
public struct PluginIndexUpdater: Sendable {

    public let indexURL: URL
    public let publicKeyBase64: String
    private let session: URLSession
    private let logger: RedactingLogger

    public init(indexURL: URL,
                publicKeyBase64: String = PluginCatalog.indexPublicKeyBase64,
                session: URLSession = .shared,
                logger: RedactingLogger = .shared) {
        self.indexURL = indexURL
        self.publicKeyBase64 = publicKeyBase64
        self.session = session
        self.logger = logger
    }

    /// The detached signature sits next to the index.
    public var signatureURL: URL {
        indexURL.deletingLastPathComponent()
            .appendingPathComponent(indexURL.lastPathComponent + ".sig")
    }

    public func update(_ catalog: PluginCatalog) async throws -> PluginCatalog.IndexUpdate {
        guard publicKeyBase64 != PluginCatalog.placeholderPublicKey else {
            throw IRError.invalidPlugin(core(
                "This build has no plugin index signing key, so it cannot verify the catalogue. See MAINTAINERS.md."))
        }

        logger.info("fetching the plugin index from \(indexURL.absoluteString)")
        let index = try await fetch(indexURL)
        let signature = try await fetch(signatureURL)

        let base = indexURL.deletingLastPathComponent()
        return try await catalog.applyIndex(index, signature: signature,
                                            publicKeyBase64: publicKeyBase64) { path in
            let url = try Self.resolve(path: path, against: base)
            return try await fetch(url)
        }
    }

    /// Resolves a path from the index, refusing anything that would leave the
    /// directory the index was served from.
    ///
    /// The signature already makes a hostile index unlikely; this makes it
    /// harmless. `..` and an absolute URL are the two ways out, and both are
    /// rejected rather than normalised — a plugin path has no legitimate reason
    /// to contain either.
    /// Public because it is a security boundary worth testing directly, not
    /// only through a network call nobody will make in a test.
    public static func resolve(path: String, against base: URL) throws -> URL {
        guard !path.isEmpty,
              !path.contains("://"),
              !path.hasPrefix("/"),
              !path.split(separator: "/").contains("..")
        else {
            throw IRError.invalidPlugin("the index points at '\(path)', which is not a path inside it")
        }
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL,
              url.host == base.host, url.scheme == base.scheme else {
            throw IRError.invalidPlugin("the index points at '\(path)', which leaves \(base.host ?? "the index host")")
        }
        return url
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        // The index is a static file; a stale one would silently hold back a
        // fix to a broken plugin.
        request.cachePolicy = .reloadRevalidatingCacheData

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw IRError.invalidPlugin("no HTTP response from \(url.host ?? url.absoluteString)")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw IRError.invalidPlugin("\(url.lastPathComponent): HTTP \(http.statusCode)")
        }
        // A plugin index is kilobytes. Anything enormous is a redirect to
        // something that is not our index.
        guard data.count < 8_000_000 else {
            throw IRError.invalidPlugin("\(url.lastPathComponent) is implausibly large")
        }
        return data
    }
}

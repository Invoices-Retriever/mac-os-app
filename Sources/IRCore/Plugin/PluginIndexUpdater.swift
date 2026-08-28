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

    /// The index this build last applied. An index announcing an older
    /// revision is refused: see `update`.
    public let minimumRevision: Int

    public init(indexURL: URL,
                publicKeyBase64: String = PluginCatalog.indexPublicKeyBase64,
                minimumRevision: Int = 0,
                session: URLSession? = nil,
                logger: RedactingLogger = .shared) {
        self.indexURL = indexURL
        self.publicKeyBase64 = publicKeyBase64
        self.minimumRevision = minimumRevision
        self.session = session ?? URLSession(configuration: Self.ephemeralConfiguration)
        self.logger = logger
    }

    /// A session with no cache at all.
    ///
    /// `URLSession.shared` writes to a shared on-disk cache, and a CDN happily
    /// marks the index cacheable for minutes. Setting a cache policy on the
    /// request is not enough — it was still handing back a five-minute-old
    /// index in practice. That matters beyond staleness: withdrawing a
    /// compromised plugin only protects anyone if the next refresh actually
    /// sees the index without it.
    private static var ephemeralConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return configuration
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

        // Anti-rollback. A signature stays valid forever, so anyone able to
        // serve an old-but-genuine index could quietly reinstate a plugin that
        // was withdrawn. Revisions only go up.
        if minimumRevision > 0, let announced = try? Self.revision(of: index), announced < minimumRevision {
            throw IRError.invalidPlugin(core(
                "The plugin index went backwards, from revision %1$@ to %2$@. Refusing it.",
                String(minimumRevision), String(announced)))
        }

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

    /// Reads the revision without trusting the rest of the document, so the
    /// rollback check happens before anything else is acted on.
    public static func revision(of index: Data) throws -> Int {
        struct Envelope: Decodable { let revision: Int }
        return try JSONDecoder().decode(Envelope.self, from: index).revision
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        // Ask for the uncompressed representation, deliberately.
        //
        // The index is a few kilobytes, so compression buys nothing — and the
        // host caches per `Vary: Accept-Encoding`. Observed in practice on
        // raw.githubusercontent.com: the identity variant was serving revision
        // 6 while the gzip variant, which URLSession asks for by default, was
        // still serving revision 5 well past its expiry. The signature on the
        // stale copy is perfectly valid, so nothing downstream can notice.
        //
        // A client pinned to a stale variant never sees a withdrawn plugin get
        // withdrawn, which is the one thing the index has to be able to do.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        // Ignore the cache outright rather than revalidate. The index is a few
        // kilobytes fetched when a person presses a button, and a CDN happily
        // serving a five-minute-old copy would silently withhold the fix to a
        // broken plugin — or, worse, the removal of a withdrawn one.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

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

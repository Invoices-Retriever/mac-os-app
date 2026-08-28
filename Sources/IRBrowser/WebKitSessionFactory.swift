import Foundation
import IRCore

/// Hands out one browser per source, and keeps it.
///
/// F2.2 asks that cookies and local storage persist per source so that
/// two-factor authentication is not replayed on every run. A persistent
/// `WKWebsiteDataStore` only gets part of the way there: portals overwhelmingly
/// authenticate with **session cookies**, which are by definition never written
/// to disk. Creating a browser per run therefore threw the sign-in away every
/// time — a collection started ten seconds after a successful sign-in reported
/// that the session had expired, which is exactly what a fresh cookie jar would
/// say.
///
/// So a source's browser is created once and reused. Two sources still never
/// share anything: separate sessions, separate data stores.
///
/// What this cannot do is survive quitting the application. Session cookies
/// end with the browsing session, in every browser; a portal that wants to be
/// remembered longer has to say so, which is what the "remember this account"
/// box on a login form does.
public final class WebKitSessionFactory: BrowserSessionFactory, @unchecked Sendable {
    private let logger: RedactingLogger
    private let sourceNames: @Sendable (UUID) -> String
    private let cache = SessionCache()

    public init(logger: RedactingLogger = .shared,
                sourceNames: @escaping @Sendable (UUID) -> String = { _ in "collection" }) {
        self.logger = logger
        self.sourceNames = sourceNames
    }

    public func makeSession(sourceID: UUID, policy: DomainPolicy) async throws -> any BrowserSession {
        if let existing = await cache.session(for: sourceID, policy: policy) {
            logger.debug("reusing the browser already signed in for this source", source: sourceID)
            return existing
        }
        let session = try await WebKitBrowserSession(
            sourceID: sourceID, policy: policy, title: sourceNames(sourceID), logger: logger)
        await cache.store(session, policy: policy, for: sourceID)
        return session
    }

    /// Closes a source's browser. Called when the source is removed, or when
    /// the user asks to forget the session — not at the end of a run.
    public func release(sourceID: UUID) async {
        await cache.release(sourceID)
    }

    public func releaseAll() async {
        await cache.releaseAll()
    }
}

/// Keeps one live session per source.
private actor SessionCache {
    private var sessions: [UUID: (session: WebKitBrowserSession, policy: DomainPolicy)] = [:]

    func session(for sourceID: UUID, policy: DomainPolicy) async -> WebKitBrowserSession? {
        guard let entry = sessions[sourceID] else { return nil }
        // A plugin update can widen or narrow allowedDomains, and the sandbox is
        // compiled into the session when it is created. Reusing a browser built
        // for the old policy would apply the old sandbox, which is the one
        // reuse we must never do.
        guard entry.policy == policy else {
            await entry.session.close()
            sessions.removeValue(forKey: sourceID)
            return nil
        }
        return entry.session
    }

    func store(_ session: WebKitBrowserSession, policy: DomainPolicy, for sourceID: UUID) {
        sessions[sourceID] = (session, policy)
    }

    func release(_ sourceID: UUID) async {
        guard let entry = sessions.removeValue(forKey: sourceID) else { return }
        await entry.session.close()
    }

    func releaseAll() async {
        let all = sessions.values
        sessions.removeAll()
        for entry in all { await entry.session.close() }
    }
}

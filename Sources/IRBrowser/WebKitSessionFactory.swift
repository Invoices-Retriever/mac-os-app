import Foundation
import IRCore

/// Hands out one isolated browser session per source (F2.1).
public final class WebKitSessionFactory: BrowserSessionFactory, @unchecked Sendable {
    private let logger: RedactingLogger
    private let sourceNames: @Sendable (UUID) -> String

    public init(logger: RedactingLogger = .shared,
                sourceNames: @escaping @Sendable (UUID) -> String = { _ in "collection" }) {
        self.logger = logger
        self.sourceNames = sourceNames
    }

    public func makeSession(sourceID: UUID, policy: DomainPolicy) async throws -> any BrowserSession {
        try await WebKitBrowserSession(sourceID: sourceID, policy: policy,
                                       title: sourceNames(sourceID), logger: logger)
    }
}

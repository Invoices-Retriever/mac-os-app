import Foundation

/// One execution of one source.
public struct Run: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var sourceID: UUID
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: RunStatus
    public var documentsFound: Int
    public var documentsNew: Int
    public var errorMessage: String?
    /// Path to the failure screenshot (F2.8). Stored locally, never uploaded,
    /// never attached to an anomaly report without the user saying so.
    public var screenshotPath: String?
    /// Path to the page outline captured at the moment of failure. Structure
    /// only, no text — safe to attach to a bug report.
    public var outlinePath: String?
    public var attempt: Int
    public var trigger: RunTrigger

    public init(id: UUID = UUID(), sourceID: UUID, startedAt: Date = Date(),
                trigger: RunTrigger = .manual, attempt: Int = 1) {
        self.id = id
        self.sourceID = sourceID
        self.startedAt = startedAt
        self.status = .running
        self.documentsFound = 0
        self.documentsNew = 0
        self.attempt = attempt
        self.trigger = trigger
    }

    public var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(startedAt) }
    }
}

public enum RunStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case running
    case succeeded
    /// Finished, but something was not right — a document failed to download
    /// while the rest worked. The run counts as a success for scheduling.
    case partial
    case failed
    /// The session expired or 2FA is due. Distinct from `failed` because the
    /// remedy is the user signing in, not a retry (F3.4).
    case needsSignIn
    case cancelled

    public var isTerminal: Bool { self != .running }
    public var countsAsSuccess: Bool { self == .succeeded || self == .partial }

    /// Whether this run may move the incremental cutoff forward.
    ///
    /// Deliberately narrower than `countsAsSuccess`. A partial run is one that
    /// found documents it could not read — and moving the window past them
    /// would mean never looking at them again. The user would simply never
    /// receive those invoices, and nothing would ever say so. Re-reading a
    /// period costs one request and is caught by deduplication; skipping one
    /// silently loses documents, so the two are not close to equivalent.
    public var advancesIncrementalCutoff: Bool { self == .succeeded }

    public var displayName: String {
        switch self {
        case .running: return core("Running")
        case .succeeded: return core("Succeeded")
        case .partial: return core("Partly succeeded")
        case .failed: return core("Failed")
        case .needsSignIn: return core("Sign-in needed")
        case .cancelled: return core("Cancelled")
        }
    }
}

public enum RunTrigger: String, Codable, Sendable, Hashable {
    case manual, scheduled, retry
}

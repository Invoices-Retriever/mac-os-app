import Foundation

/// One configured instance of a plugin. Two AWS accounts are two sources
/// sharing one plugin (F1.5), each with its own browser profile, its own
/// Keychain item and its own incremental cursor.
public struct Source: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var entityID: UUID
    public var pluginID: String
    public var pluginVersion: String
    public var displayName: String
    public var isEnabled: Bool

    /// Non-secret configuration only. Passwords and TOTP seeds live in the
    /// Keychain and are never written here (M5).
    public var config: [String: String]
    /// Choices surfaced by `getConfigOptions` / `exposeOption`.
    public var options: [String: [String]]

    public var rememberCredentials: Bool
    public var autofillEnabled: Bool
    public var schedule: Schedule
    public var lookbackDays: Int

    public var lastRunAt: Date?
    public var lastSuccessAt: Date?
    public var lastRunStatus: RunStatus?
    public var lastErrorMessage: String?
    public var documentCount: Int
    public var createdAt: Date

    public init(id: UUID = UUID(),
                entityID: UUID,
                pluginID: String,
                pluginVersion: String,
                displayName: String,
                isEnabled: Bool = true,
                config: [String: String] = [:],
                options: [String: [String]] = [:],
                rememberCredentials: Bool = true,
                autofillEnabled: Bool = true,
                schedule: Schedule = .manual,
                lookbackDays: Int = 90,
                createdAt: Date = Date()) {
        self.id = id
        self.entityID = entityID
        self.pluginID = pluginID
        self.pluginVersion = pluginVersion
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.config = config
        self.options = options
        self.rememberCredentials = rememberCredentials
        self.autofillEnabled = autofillEnabled
        self.schedule = schedule
        self.lookbackDays = lookbackDays
        self.documentCount = 0
        self.createdAt = createdAt
    }

    /// The incremental cursor of F2.5: everything strictly older than this has
    /// already been collected, so the run can stop walking the history.
    /// Falls back to a lookback window on a source that never succeeded.
    public func incrementalCutoff(now: Date = Date()) -> Date {
        if let lastSuccessAt {
            // One week of overlap: portals routinely back-date an invoice by a
            // few days, and re-seeing a document we already have costs nothing
            // because deduplication catches it.
            return lastSuccessAt.addingTimeInterval(-7 * 86_400)
        }
        return now.addingTimeInterval(-Double(lookbackDays) * 86_400)
    }

    public var needsAttention: Bool {
        lastRunStatus == .failed || lastRunStatus == .needsSignIn
    }
}

public enum Schedule: Codable, Sendable, Hashable {
    case manual
    case daily(hour: Int)
    case weekly(weekday: Int, hour: Int)
    case monthly(day: Int, hour: Int)

    public var displayName: String {
        switch self {
        case .manual: return "Manual"
        case .daily(let h): return String(format: "Daily at %02d:00", h)
        case .weekly(_, let h): return String(format: "Weekly at %02d:00", h)
        case .monthly(let d, let h): return String(format: "Monthly on day %d at %02d:00", d, h)
        }
    }

    public var isAutomatic: Bool {
        if case .manual = self { return false }
        return true
    }

    /// F9.5: nothing runs on its own until the user turns it on, so a manual
    /// schedule simply has no next date.
    public func nextDate(after reference: Date, calendar: Calendar = .current) -> Date? {
        var components = DateComponents()
        switch self {
        case .manual:
            return nil
        case .daily(let hour):
            components.hour = hour; components.minute = 0
            return calendar.nextDate(after: reference, matching: components, matchingPolicy: .nextTime)
        case .weekly(let weekday, let hour):
            components.weekday = weekday; components.hour = hour; components.minute = 0
            return calendar.nextDate(after: reference, matching: components, matchingPolicy: .nextTime)
        case .monthly(let day, let hour):
            components.day = day; components.hour = hour; components.minute = 0
            return calendar.nextDate(after: reference, matching: components, matchingPolicy: .nextTimePreservingSmallerComponents)
        }
    }
}

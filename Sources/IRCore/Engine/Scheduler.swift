import Foundation

/// F9. Runs collections on a timetable, while the app is open.
///
/// There is no launch daemon and no background helper in v1 (F9.2), and that is
/// a considered choice rather than a shortcut: a background process holding
/// every supplier credential the user owns and driving a browser unattended is
/// a much larger thing to ask people to trust than an app they can see. When
/// this grows a daemon, it should be because users asked for it.
public actor Scheduler {
    private let store: Store
    private let collector: CollectionService
    private let logger: RedactingLogger
    private var timer: Task<Void, Never>?
    private var lastFired: [UUID: Date] = [:]

    /// F9.5: nothing runs by itself until the user turns this on.
    public private(set) var isEnabled = false

    public var onBatchFinished: (@Sendable (CollectionService.BatchReport) -> Void)?

    public init(store: Store, collector: CollectionService, logger: RedactingLogger = .shared) {
        self.store = store
        self.collector = collector
        self.logger = logger
    }

    public func setEnabled(_ enabled: Bool, entityID: UUID) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        timer?.cancel()
        timer = nil

        guard enabled else {
            logger.info("scheduler stopped")
            return
        }
        logger.info("scheduler started")
        timer = Task { [weak self] in
            // A minute of granularity is plenty for something whose finest
            // schedule is hourly, and it keeps the app asleep the rest of the
            // time.
            while !Task.isCancelled {
                await self?.tick(entityID: entityID)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    public func setCallback(_ callback: @escaping @Sendable (CollectionService.BatchReport) -> Void) {
        onBatchFinished = callback
    }

    /// Sources whose next scheduled time has passed, so the UI can show what is
    /// about to happen.
    public func dueSources(entityID: UUID, now: Date = Date()) async throws -> [Source] {
        try await store.sources(entityID: entityID, enabledOnly: true).filter { source in
            isDue(source, now: now)
        }
    }

    private func isDue(_ source: Source, now: Date) -> Bool {
        guard source.schedule.isAutomatic else { return false }
        // Never twice in the same minute, even if a run took less than the tick.
        if let last = lastFired[source.id], now.timeIntervalSince(last) < 120 { return false }

        let reference = source.lastSuccessAt ?? source.createdAt
        guard let next = source.schedule.nextDate(after: reference) else { return false }
        return next <= now
    }

    private func tick(entityID: UUID) async {
        guard isEnabled else { return }
        do {
            let due = try await dueSources(entityID: entityID)
            guard !due.isEmpty else { return }

            logger.info("scheduler: \(due.count) source(s) due")
            let now = Date()
            for source in due { lastFired[source.id] = now }

            var reports: [CollectionService.RunReport] = []
            for source in due {
                // Sequential on purpose. A scheduled run happens while the user
                // is doing something else on this machine, and taking two
                // browser sessions' worth of memory in the background is rude.
                reports.append(await collector.collect(source: source, trigger: .scheduled))
            }

            let batch = CollectionService.BatchReport(
                reports: reports, startedAt: now, finishedAt: Date())
            onBatchFinished?(batch)
        } catch {
            logger.error("scheduler tick failed: \(error.localizedDescription)")
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        isEnabled = false
    }
}

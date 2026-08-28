import Foundation

/// Turns "collect my invoices" into runs, documents and log entries.
///
/// This is the layer that owns the promises the specification makes about
/// robustness: one source failing never touches another (each runs in its own
/// task and its own error is caught there), retries follow F2.9 exactly, and
/// every run ends with a row in the database whatever happened to it.
public actor CollectionService {
    private let store: Store
    private let library: DocumentLibrary
    private let catalog: PluginCatalog
    private let vault: CredentialVault
    private let sessionFactory: any BrowserSessionFactory
    private let extractor: MetadataExtractor
    private let logger: RedactingLogger

    /// F2.4. Two at a time by default: enough to halve a ten-source collection,
    /// few enough that the machine stays usable and no portal sees a burst.
    public private(set) var maximumConcurrency: Int = 2

    public func setMaximumConcurrency(_ value: Int) {
        maximumConcurrency = max(1, min(value, 6))
    }

    /// The user's floor on how far back to go at all. Nil means no floor.
    public private(set) var earliestDocumentDate: Date?

    public func setEarliestDocumentDate(_ date: Date?) {
        earliestDocumentDate = date
    }

    private var inFlight: [UUID: Task<RunReport, Never>] = [:]

    public init(store: Store,
                library: DocumentLibrary,
                catalog: PluginCatalog,
                vault: CredentialVault,
                sessionFactory: any BrowserSessionFactory,
                extractor: MetadataExtractor = MetadataExtractor(),
                logger: RedactingLogger = .shared) {
        self.store = store
        self.library = library
        self.catalog = catalog
        self.vault = vault
        self.sessionFactory = sessionFactory
        self.extractor = extractor
        self.logger = logger
    }

    public struct RunReport: Sendable {
        public var sourceID: UUID
        public var sourceName: String
        public var run: Run
        public var newDocuments: [InvoiceDocument]
        public var duplicates: Int
        public var error: String?

        public var status: RunStatus { run.status }
    }

    public struct BatchReport: Sendable {
        public var reports: [RunReport]
        public var startedAt: Date
        public var finishedAt: Date

        public var newDocumentCount: Int { reports.reduce(0) { $0 + $1.newDocuments.count } }
        public var failedSources: [RunReport] { reports.filter { !$0.status.countsAsSuccess } }
        public var sourcesNeedingSignIn: [RunReport] { reports.filter { $0.status == .needsSignIn } }
    }

    // MARK: - Batch

    /// UC-02: collect from every enabled source. Bounded concurrency, and a
    /// source that throws is reported rather than allowed to escape.
    public func collectAll(entityID: UUID,
                           trigger: RunTrigger = .manual,
                           progress: (@Sendable (RunReport) -> Void)? = nil) async throws -> BatchReport {
        let startedAt = Date()
        let sources = try await store.sources(entityID: entityID, enabledOnly: true)
        var reports: [RunReport] = []

        await withTaskGroup(of: RunReport.self) { group in
            var iterator = sources.makeIterator()
            var running = 0

            func startNext() {
                guard let source = iterator.next() else { return }
                running += 1
                group.addTask { [self] in
                    await collect(source: source, trigger: trigger)
                }
            }

            for _ in 0..<min(maximumConcurrency, sources.count) { startNext() }

            while running > 0, let report = await group.next() {
                running -= 1
                reports.append(report)
                progress?(report)
                startNext()
            }
        }

        return BatchReport(reports: reports, startedAt: startedAt, finishedAt: Date())
    }

    // MARK: - One source

    public func collect(source: Source, trigger: RunTrigger = .manual) async -> RunReport {
        if let existing = inFlight[source.id] {
            return await existing.value
        }
        let task = Task<RunReport, Never> { [self] in
            await performWithRetries(source: source, trigger: trigger)
        }
        inFlight[source.id] = task
        let report = await task.value
        inFlight[source.id] = nil
        return report
    }

    public func cancel(sourceID: UUID) {
        inFlight[sourceID]?.cancel()
    }

    public var runningSourceIDs: Set<UUID> { Set(inFlight.keys) }

    /// F2.9: at most two attempts, exponential backoff, and never a second
    /// attempt at something that failed on authentication — a portal that
    /// locks the account after three bad passwords does not care that we were
    /// being helpful.
    private func performWithRetries(source: Source, trigger: RunTrigger) async -> RunReport {
        var lastReport: RunReport?

        for attempt in 1...2 {
            let report = await perform(source: source, trigger: attempt == 1 ? trigger : .retry, attempt: attempt)
            lastReport = report

            guard attempt == 1,
                  let error = report.run.errorMessage,
                  report.status == .failed,
                  isRetryable(report)
            else { break }

            logger.warning("retrying \(source.displayName) after: \(error)", source: source.id)
            try? await Task.sleep(for: .seconds(3))
        }
        return lastReport!
    }

    private func isRetryable(_ report: RunReport) -> Bool {
        report.status != .needsSignIn && report.status != .cancelled
    }

    private func perform(source: Source, trigger: RunTrigger, attempt: Int) async -> RunReport {
        var run = Run(sourceID: source.id, trigger: trigger, attempt: attempt)
        var report = RunReport(sourceID: source.id, sourceName: source.displayName,
                               run: run, newDocuments: [], duplicates: 0)

        // The log sink is installed for the life of this run so that every line
        // the engine emits lands in the run's own journal (F2.7). It has been
        // through redaction already.
        let store = self.store
        let runID = run.id
        logger.addSink { record in
            guard record.runID == runID else { return }
            Task { try? await store.appendLog(record) }
        }

        do {
            try await store.upsert(run)

            guard let manifest = await catalog.manifest(id: source.pluginID) else {
                throw IRError.invalidPlugin("plugin '\(source.pluginID)' is not installed")
            }

            let runner = PluginRunner(manifest: manifest, sessionFactory: sessionFactory,
                                      vault: vault, earliestDocumentDate: earliestDocumentDate,
                                      logger: logger)
            let outcome = await runner.run(source: source, mode: .collect, runID: run.id)

            run.documentsFound = outcome.documents.count
            if let screenshot = outcome.screenshot {
                run.screenshotPath = try? saveScreenshot(screenshot, runID: run.id)
            }
            if let outline = outcome.outline, !outline.isEmpty {
                run.outlinePath = try? saveOutline(outline, runID: run.id)
            }

            var stored: [InvoiceDocument] = []
            var duplicates = 0
            var ingestionFailures = 0

            for collected in outcome.documents {
                do {
                    switch try await library.ingest(collected, source: source, entityID: source.entityID) {
                    case .duplicate(_, let reason):
                        duplicates += 1
                        logger.debug("skipped \(collected.pluginDocumentID): \(reason.rawValue)", run: run.id)
                    case .stored(let document):
                        let enriched = await extractor.enrich(document, pdf: collected.data)
                        try await store.upsert(enriched.document)
                        stored.append(enriched.document)
                    }
                } catch {
                    // One document that will not save must not cost us the rest.
                    ingestionFailures += 1
                    logger.error("could not file \(collected.pluginDocumentID): \(error.localizedDescription)",
                                 run: run.id)
                }
            }

            run.documentsNew = stored.count
            run.finishedAt = Date()

            if let error = outcome.error {
                run.status = outcome.status
                run.errorMessage = logger.redact(error.localizedDescription)
            } else if ingestionFailures > 0 {
                run.status = .partial
                run.errorMessage = "\(ingestionFailures) document(s) could not be filed"
            } else {
                run.status = .succeeded
            }

            report.run = run
            report.newDocuments = stored
            report.duplicates = duplicates
            report.error = run.errorMessage

        } catch {
            run.finishedAt = Date()
            run.status = (error as? IRError)?.needsUserSignIn == true ? .needsSignIn : .failed
            run.errorMessage = logger.redact(error.localizedDescription)
            report.run = run
            report.error = run.errorMessage
        }

        try? await store.upsert(run)
        await updateSource(source, after: run)
        return report
    }

    private func updateSource(_ source: Source, after run: Run) async {
        var updated = source
        updated.lastRunAt = run.finishedAt ?? run.startedAt
        updated.lastRunStatus = run.status
        updated.lastErrorMessage = run.errorMessage
        if run.status.advancesIncrementalCutoff {
            updated.lastSuccessAt = run.finishedAt
        }
        if run.status.countsAsSuccess {
            updated.lastErrorMessage = nil
        }
        updated.documentCount = (try? await store.documentCount(sourceID: source.id)) ?? source.documentCount
        try? await store.upsert(updated)
    }

    /// Written beside the screenshot, and only ever read by a human debugging a
    /// plugin. It carries no page text — see `DOMScripts.outline` — so it is
    /// safe to attach to an issue, which is the whole point of it.
    private func saveOutline(_ outline: String, runID: UUID) throws -> String {
        try Self.writeOutline(outline, runID: runID, root: library.root)
    }

    static func writeOutline(_ outline: String, runID: UUID, root: URL) throws -> String {
        let directory = root.appendingPathComponent(".invoices-retriever/diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(runID.uuidString).outline.txt")
        try Data(outline.utf8).write(to: url, options: .atomic)
        return url.path
    }

    private func saveScreenshot(_ data: Data, runID: UUID) throws -> String {
        let directory = library.root.appendingPathComponent(".invoices-retriever/diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(runID.uuidString).png")
        try data.write(to: url, options: .atomic)
        return url.path
    }

    // MARK: - Interactive sign-in

    /// UC-01 and UC-03. Runs with the window visible and does not collect
    /// anything, so the user can deal with 2FA once and get on with their day.
    ///
    /// Recorded as a run like any other. A sign-in is where a plugin most often
    /// breaks — it is the part that touches a login form — and leaving it out
    /// of the journal meant the one failure a user most needed to show someone
    /// left no trace at all.
    public func authenticate(source: Source) async throws {
        var run = Run(sourceID: source.id, trigger: .manual)
        let store = self.store
        let runID = run.id
        logger.addSink { record in
            guard record.runID == runID else { return }
            Task { try? await store.appendLog(record) }
        }
        try await store.upsert(run)

        do {
            guard let manifest = await catalog.manifest(id: source.pluginID) else {
                throw IRError.invalidPlugin("plugin '\(source.pluginID)' is not installed")
            }
            var runner = PluginRunner(manifest: manifest, sessionFactory: sessionFactory,
                                      vault: vault, earliestDocumentDate: earliestDocumentDate,
                                      logger: logger)
            // Write it while the user is still looking at the screen it
            // describes, not once the run is over.
            let runID = run.id
            let store = self.store
            let root = library.root
            runner.onHandOver = { outline in
                guard let path = try? Self.writeOutline(outline, runID: runID, root: root) else { return }
                var partial = Run(id: runID, sourceID: source.id, startedAt: Date())
                partial.outlinePath = path
                if var current = try? await store.runs(sourceID: source.id, limit: 5)
                    .first(where: { $0.id == runID }) {
                    current.outlinePath = path
                    partial = current
                }
                try? await store.upsert(partial)
            }
            let outcome = await runner.run(source: source, mode: .authenticateOnly, runID: run.id)

            if let screenshot = outcome.screenshot {
                run.screenshotPath = try? saveScreenshot(screenshot, runID: run.id)
            }
            if let outline = outcome.outline, !outline.isEmpty {
                run.outlinePath = try? saveOutline(outline, runID: run.id)
            }
            run.finishedAt = Date()

            if let error = outcome.error {
                run.status = outcome.status
                run.errorMessage = logger.redact(error.localizedDescription)
                try? await store.upsert(run)
                await updateSource(source, after: run)
                throw error
            }

            run.status = .succeeded
            // Keep the hand-over outline even on success: the sign-in worked
            // because a person did the part the plugin could not, and that page
            // is what a contributor needs to teach it the missing step.
            if let outline = outcome.outline, !outline.isEmpty {
                run.outlinePath = try? saveOutline(outline, runID: run.id)
            }
            try? await store.upsert(run)

            var updated = source
            updated.lastRunAt = run.finishedAt
            updated.lastRunStatus = nil
            updated.lastErrorMessage = nil
            try await store.upsert(updated)
        } catch {
            if run.finishedAt == nil {
                run.finishedAt = Date()
                run.status = (error as? IRError)?.needsUserSignIn == true ? .needsSignIn : .failed
                run.errorMessage = logger.redact(error.localizedDescription)
                try? await store.upsert(run)
            }
            throw error
        }
    }

    public func discoverOptions(source: Source) async throws -> [ExposedOption] {
        guard let manifest = await catalog.manifest(id: source.pluginID) else {
            throw IRError.invalidPlugin("plugin '\(source.pluginID)' is not installed")
        }
        let runner = PluginRunner(manifest: manifest, sessionFactory: sessionFactory,
                                  vault: vault, logger: logger)
        let outcome = await runner.run(source: source, mode: .discoverOptions)
        if let error = outcome.error { throw error }
        return outcome.exposedOptions
    }

    /// F1.3 and F4.4: removing a source removes its secrets and its browser
    /// profile, and says how many secrets it destroyed so the UI can tell the
    /// truth rather than a reassuring guess.
    @discardableResult
    public func deleteSource(_ source: Source, purgeCredentials: Bool) async throws -> Int {
        cancel(sourceID: source.id)
        // Close its browser too, or a deleted source leaves a signed-in window
        // behind holding its cookies.
        await sessionFactory.release(sourceID: source.id)
        var purged = 0
        if purgeCredentials {
            purged = try vault.purge(source: source.id)
        }
        try await store.deleteSource(id: source.id)
        return purged
    }
}

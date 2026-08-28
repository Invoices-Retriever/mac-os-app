import Foundation
import SwiftUI
import UserNotifications
import IRCore
import IRBrowser

/// The application's single piece of mutable state, and the only place the UI
/// talks to the core from.
///
/// Views read published properties and call methods here; they never touch the
/// store, the vault or the engine directly. That keeps the security-relevant
/// code in one place — in particular, nothing in `Views/` can reach a secret,
/// because nothing in `Views/` has a `CredentialVault`.
@MainActor
@Observable
final class AppModel {

    // MARK: - Loaded state

    var entity: Entity?
    var sources: [Source] = []
    var documents: [InvoiceDocument] = []
    var catalogEntries: [PluginCatalog.Entry] = []
    var selectedSection: RootSection = .sources
    /// Unfiltered, so an empty list can say which kind of empty it is.
    var totalDocumentCount = 0
    var exportDestinations: [ExportDestination] = []
    var runningDestinationIDs: Set<UUID> = []

    /// The plugin behind a source, when it is installed.
    func manifest(for source: Source) -> PluginManifest? {
        catalogEntries.first { $0.manifest.id == source.pluginID }?.manifest
    }

    /// True when this source's plugin talks to an API with its own credentials.
    /// It changes what the interface can honestly offer: there is no portal to
    /// open, so "Sign in" would be a button that cannot do anything.
    func isAPIOnly(_ source: Source) -> Bool {
        manifest(for: source)?.isAPIOnly ?? false
    }

    /// The organisation invoices are collected for. Its name and VAT number
    /// travel into exports and file names, so they are worth being able to fix
    /// without editing the database.
    func updateEntity(name: String, vatNumber: String?) async {
        guard let store, var entity else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        entity.name = trimmed.isEmpty ? Entity.defaultName : trimmed
        entity.vatNumber = vatNumber?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        guard entity != self.entity else { return }
        do {
            try await store.upsert(entity)
            self.entity = entity
        } catch {
            alert = AlertContent(title: t("Could not save the organisation"),
                                 message: error.localizedDescription)
        }
    }

    /// The plugin a collected document came from, for its supplier's logo.
    func manifest(forSourceID id: UUID?) -> PluginManifest? {
        guard let id, let source = sources.first(where: { $0.id == id }) else { return nil }
        return manifest(for: source)
    }

    /// Every supplier domain the catalogue knows, for the logo prefetch.
    var catalogueLogoDomains: [String] {
        catalogEntries.compactMap(\.manifest.logoDomain)
    }
    var recentRuns: [Run] = []
    var preferences = Preferences.default

    var runningSourceIDs: Set<UUID> = []
    var liveLog: [RedactingLogger.LogRecord] = []
    var lastBatch: CollectionService.BatchReport?

    var documentFilter = DocumentFilter()
    var alert: AlertContent?
    var isLoading = true

    struct AlertContent: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    // MARK: - Services

    private(set) var paths: AppPaths
    private(set) var store: Store!
    private(set) var catalog: PluginCatalog!
    private(set) var library: DocumentLibrary!
    private(set) var collector: CollectionService!
    private(set) var exportService: ExportService!
    private(set) var scheduler: Scheduler!
    private let vault = CredentialVault()
    private var sourceNameBox: SourceNameBox?

    var sourceNames: [UUID: String] {
        Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.displayName) })
    }

    init() {
        self.paths = AppPaths.standard()
    }

    // MARK: - Start-up

    func start() async {
        do {
            preferencesBootstrap: do {
                try paths.ensureDirectoriesExist()
            }
            store = try await Store.open(at: paths.databaseURL)
            preferences = await Preferences.load(from: store)
            applyLanguage()

            if let path = preferences.libraryPath {
                paths = AppPaths(supportDirectory: paths.supportDirectory,
                                 libraryRoot: URL(fileURLWithPath: path))
                try paths.ensureDirectoriesExist()
            }

            // Nothing survives a quit, so anything still marked running is a
            // leftover rather than a run.
            try? await store.closeInterruptedRuns()

            entity = try await store.defaultEntity()
            documentFilter.entityID = entity?.id

            catalog = PluginCatalog(installedDirectory: paths.installedPluginsDirectory)
            await catalog.loadAll(bundledDirectory: BundledResources.bundledPluginsDirectory)

            library = DocumentLibrary(
                root: paths.libraryRoot, store: store,
                fileTemplate: NamingTemplate(pattern: preferences.fileNamePattern),
                folderTemplate: NamingTemplate(pattern: preferences.folderPattern))

            // The browser window titles the source it belongs to, which matters
            // when two windows are open during an interactive sign-in. The
            // names are snapshot into a box rather than read back through the
            // model, so the factory carries no main-actor state.
            let names = SourceNameBox()
            self.sourceNameBox = names
            names.update(sourceNames)

            collector = CollectionService(
                store: store, library: library, catalog: catalog, vault: vault,
                sessionFactory: WebKitSessionFactory(sourceNames: { names.name(for: $0) }),
                extractor: MetadataExtractor(enableOCR: preferences.enableOCR))
            await collector.setMaximumConcurrency(preferences.maximumConcurrency)
            await collector.setEarliestDocumentDate(preferences.earliestDocumentDate)

            exportService = ExportService(store: store, library: library)
            scheduler = Scheduler(store: store, collector: collector)
            await scheduler.setCallback { [weak self] batch in
                Task { @MainActor in self?.finishBatch(batch) }
            }

            installLogSink()
            await requestNotificationPermission()
            await reload()

            if preferences.schedulerEnabled, let entityID = entity?.id {
                await scheduler.setEnabled(true, entityID: entityID)
            }
        } catch {
            alert = AlertContent(title: t("Could not start"),
                                 message: error.localizedDescription)
        }
        isLoading = false
    }

    private func installLogSink() {
        RedactingLogger.shared.addSink { [weak self] record in
            Task { @MainActor in
                guard let self else { return }
                // A live log worth reading is a short one; the full journal of
                // every run is in the database.
                if self.liveLog.count > 400 { self.liveLog.removeFirst(200) }
                self.liveLog.append(record)
            }
        }
    }

    func reload() async {
        guard let store, let entity else { return }
        do {
            sources = try await store.sources(entityID: entity.id)
            sourceNameBox?.update(sourceNames)
            documents = try await store.documents(filter: documentFilter)
            totalDocumentCount = try await store.totalDocumentCount()
            exportDestinations = try await store.exportDestinations(entityID: entity.id)
            recentRuns = try await store.runs(limit: 60)
            catalogEntries = await catalog.all()
        } catch {
            alert = AlertContent(title: t("Could not read the library"),
                                 message: error.localizedDescription)
        }
    }

    func reloadDocuments() async {
        guard let store else { return }
        documents = (try? await store.documents(filter: documentFilter)) ?? []
        totalDocumentCount = (try? await store.totalDocumentCount()) ?? totalDocumentCount
    }

    // MARK: - Sources

    func addSource(plugin: PluginManifest,
                   displayName: String,
                   config: [String: String],
                   secrets: [String: String],
                   rememberCredentials: Bool,
                   requireBiometrics: Bool) async -> Source? {
        guard let entity else { return nil }
        var source = Source(entityID: entity.id, pluginID: plugin.id,
                            pluginVersion: plugin.version,
                            displayName: displayName.isEmpty ? plugin.name : displayName,
                            config: config,
                            rememberCredentials: rememberCredentials)
        source.autofillEnabled = rememberCredentials

        do {
            if rememberCredentials {
                // One write, one keychain item, one authorisation prompt.
                try vault.store(secrets.filter { !$0.value.isEmpty },
                                source: source.id, requireBiometrics: requireBiometrics)
            }
            try await store.upsert(source)
            await reload()
            return source
        } catch {
            // Never leave a half-created source with orphaned secrets behind.
            try? vault.purge(source: source.id)
            alert = AlertContent(title: t("Could not add the source"),
                                 message: error.localizedDescription)
            return nil
        }
    }

    func update(_ source: Source) async {
        do {
            try await store.upsert(source)
            await reload()
        } catch {
            alert = AlertContent(title: t("Could not save"), message: error.localizedDescription)
        }
    }

    func setSecrets(_ secrets: [String: String], for source: Source, requireBiometrics: Bool) async {
        do {
            try vault.store(secrets, source: source.id, requireBiometrics: requireBiometrics)
        } catch {
            alert = AlertContent(title: t("Could not save to the keychain"),
                                 message: error.localizedDescription)
        }
    }

    func deleteSource(_ source: Source, purgeCredentials: Bool) async {
        do {
            let purged = try await collector.deleteSource(source, purgeCredentials: purgeCredentials)
            await reload()
            if purgeCredentials {
                alert = AlertContent(
                    title: t("Source removed"),
                    message: purged == 0
                        ? t("No credentials were stored for this source.")
                        : tn("%d stored credentials were deleted from the keychain.", purged))
            }
        } catch {
            alert = AlertContent(title: t("Could not remove the source"),
                                 message: error.localizedDescription)
        }
    }

    // MARK: - Running

    /// UC-01 and UC-03. Establishes the session and stops there — collecting is
    /// a separate action, because a user may well want to deal with two-factor
    /// now and fetch invoices later.
    ///
    /// It says so when it worked. Succeeding in silence is indistinguishable
    /// from doing nothing, and was reported as exactly that.
    func authenticate(_ source: Source) async {
        runningSourceIDs.insert(source.id)
        defer { runningSourceIDs.remove(source.id) }
        do {
            try await collector.authenticate(source: source)
            await reload()
            alert = AlertContent(
                title: isAPIOnly(source)
                    ? t("%@ accepted these credentials", source.displayName)
                    : t("Signed in to %@", source.displayName),
                message: isAPIOnly(source)
                    ? t("The keys work. Use “Collect” to fetch your invoices — this source needs no browser and no two-factor code.")
                    : t("The session is stored, so later collections will not ask for your two-factor code again. Use “Collect” to fetch your invoices now."))
        } catch {
            alert = AlertContent(title: t("Sign-in to %@ failed", source.displayName),
                                 message: error.localizedDescription)
        }
    }

    /// Collect ignoring everything already known, looking back as far as the
    /// source's first-run window allows.
    ///
    /// Needed because the incremental cutoff can end up ahead of invoices that
    /// were never actually collected — a plugin that was fixed after a run went
    /// wrong, or a window that moved for a reason that turned out to be false.
    /// Nothing is deleted and nothing is duplicated: deduplication means the
    /// worst case is re-downloading what is already in the library.
    func collectFromScratch(_ source: Source) async {
        guard let store else { return }
        var reset = source
        reset.lastSuccessAt = nil
        try? await store.upsert(reset)
        await reload()
        await collect(reset)
    }

    func collect(_ source: Source) async {
        runningSourceIDs.insert(source.id)
        defer { runningSourceIDs.remove(source.id) }
        let report = await collector.collect(source: source)
        await reload()
        if !report.newDocuments.isEmpty { await runAutomaticExports() }
        if report.status == .needsSignIn {
            alert = AlertContent(
                title: isAPIOnly(source)
                    ? t("%@ refused these credentials", source.displayName)
                    : t("%@ needs you to sign in", source.displayName),
                message: isAPIOnly(source)
                    ? t("The API keys are wrong, expired, or lack the rights this plugin needs. Check them in the source's settings.")
                    : t("The stored session has expired. Use “Sign in” to open the portal, deal with two-factor authentication, then collect again."))
        } else if let error = report.error, !report.status.countsAsSuccess {
            alert = AlertContent(title: t("%@ failed", source.displayName), message: error)
        }
    }

    func collectAll() async {
        guard let entity else { return }
        liveLog.removeAll()
        do {
            let batch = try await collector.collectAll(entityID: entity.id) { [weak self] report in
                Task { @MainActor in
                    self?.runningSourceIDs.remove(report.sourceID)
                    await self?.reload()
                }
            }
            finishBatch(batch)
            if batch.reports.contains(where: { !$0.newDocuments.isEmpty }) {
                await reload()
                await runAutomaticExports()
            }
        } catch {
            alert = AlertContent(title: t("Collection failed"), message: error.localizedDescription)
        }
        await reload()
    }

    func cancel(_ source: Source) async {
        await collector.cancel(sourceID: source.id)
        runningSourceIDs.remove(source.id)
    }

    private func finishBatch(_ batch: CollectionService.BatchReport) {
        lastBatch = batch
        Task { await reload() }
        notify(batch)
    }

    // MARK: - Library

    func setVerified(_ document: InvoiceDocument, fields: [String: String]) async {
        var updated = document
        updated.issuer = fields["issuer"]?.nilIfEmpty
        updated.number = fields["number"]?.nilIfEmpty
        if let raw = fields["issuedOn"]?.nilIfEmpty { updated.issuedOn = InvoiceDateParser.parse(raw) }
        if let raw = fields["total"]?.nilIfEmpty {
            updated.total = MoneyParser.parse(raw, defaultCurrency: document.total?.currency)
        }
        if let raw = fields["vat"]?.nilIfEmpty {
            updated.vat = MoneyParser.parse(raw, defaultCurrency: updated.total?.currency)
        }
        updated.vatNumber = fields["vatNumber"]?.nilIfEmpty
        // F6.6: a value a person checked is worth more than any extraction, and
        // nothing may silently overwrite it later.
        updated.verifiedByHuman = true
        for key in ["issuer", "number", "issuedOn", "total", "vat"] {
            updated.fieldConfidence[key] = ExtractionMethod.human.baseConfidence
        }
        updated.updatedAt = Date()

        do {
            try await store.upsert(updated)
            await reloadDocuments()
        } catch {
            alert = AlertContent(title: t("Could not save"), message: error.localizedDescription)
        }
    }

    func importFiles(_ urls: [URL]) async {
        guard let entity else { return }
        var imported = 0, duplicates = 0
        for url in urls where url.pathExtension.lowercased() == "pdf" {
            do {
                switch try await library.importFile(at: url, entityID: entity.id) {
                case .stored(let document):
                    let data = try Data(contentsOf: library.url(for: document))
                    let enriched = await MetadataExtractor(enableOCR: preferences.enableOCR)
                        .enrich(document, pdf: data)
                    try await store.upsert(enriched.document)
                    imported += 1
                case .duplicate:
                    duplicates += 1
                }
            } catch {
                alert = AlertContent(title: t("Could not import %@", url.lastPathComponent),
                                     message: error.localizedDescription)
            }
        }
        await reloadDocuments()
        if imported + duplicates > 0 {
            alert = AlertContent(title: t("Import finished"),
                                 message: t("%1$@ added, %2$@ already in the library.",
                                            number(imported), number(duplicates)))
        }
    }

    func rescanLibrary() async {
        guard let entity else { return }
        do {
            let result = try await library.rescan(entityID: entity.id)
            await reloadDocuments()
            var message = t("%1$@ new file(s) indexed, %2$@ already known.",
                            number(result.added), number(result.alreadyKnown))
            if !result.missingFiles.isEmpty {
                message += "\n" + tn("%d indexed documents are missing from disk.",
                                      result.missingFiles.count)
            }
            alert = AlertContent(title: t("Rescan finished"), message: message)
        } catch {
            alert = AlertContent(title: t("Rescan failed"), message: error.localizedDescription)
        }
    }

    func delete(_ document: InvoiceDocument, removeFile: Bool) async {
        do {
            try await library.delete(document, removeFile: removeFile)
            await reloadDocuments()
        } catch {
            alert = AlertContent(title: t("Could not delete"), message: error.localizedDescription)
        }
    }

    // MARK: - Export

    // MARK: - Saved export destinations

    func saveDestination(_ destination: ExportDestination, secret: String?) async {
        guard let store else { return }
        do {
            try await store.upsert(destination)
            if destination.needsSecret, let secret {
                // Empty means "leave what is stored" — the field comes up blank
                // when editing, because a secret is never read back to show it.
                if !secret.isEmpty {
                    try Keychain().set(secret, account: destination.secretAccount)
                }
            }
            await reload()
        } catch {
            alert = AlertContent(title: t("Could not save this destination"),
                                 message: error.localizedDescription)
        }
    }

    func deleteDestination(_ destination: ExportDestination) async {
        guard let store else { return }
        // The secret goes with it: a destination the user removed must not
        // leave a token behind in the keychain (F4.4 applied here too).
        try? Keychain().delete(account: destination.secretAccount)
        try? await store.deleteExportDestination(id: destination.id)
        await reload()
    }

    func hasSecret(_ destination: ExportDestination) -> Bool {
        guard destination.needsSecret else { return true }
        return (try? Keychain().get(account: destination.secretAccount))??.isEmpty == false
    }

    /// Turns a saved destination into something that can move a document.
    /// Returns nil when it is not configured enough to run, which is the same
    /// question `isComplete` answers for the interface.
    func makeExporter(for destination: ExportDestination) -> (any Exporter)? {
        let names = sourceNames
        let secret = (try? Keychain().get(account: destination.secretAccount)) ?? nil

        switch destination.kind {
        case .folder:
            guard let path = destination.config["path"], !path.isEmpty else { return nil }
            return FolderExporter(root: URL(fileURLWithPath: path),
                                  folderTemplate: NamingTemplate(pattern: preferences.folderPattern),
                                  fileTemplate: NamingTemplate(pattern: preferences.fileNamePattern),
                                  sourceNames: names)
        case .csv, .json:
            guard let path = destination.config["path"], !path.isEmpty else { return nil }
            return RegisterExporter(format: destination.kind == .csv ? .csv : .json,
                                    outputURL: URL(fileURLWithPath: path), sourceNames: names)
        case .webhook:
            guard let url = URL(string: destination.config["url"] ?? "") else { return nil }
            var headers: [String: String] = [:]
            if let secret, !secret.isEmpty { headers["Authorization"] = secret }
            return WebhookExporter(url: url, headers: headers, sourceNames: names)
        case .paperless:
            guard let url = URL(string: destination.config["url"] ?? ""),
                  let secret, !secret.isEmpty else { return nil }
            let tags = (destination.config["tags"] ?? "")
                .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            return PaperlessExporter(baseURL: url, token: secret, tagIDs: tags, sourceNames: names)
        case .email:
            return EmailExporter(recipients: Self.recipients(in: destination),
                                 entityName: entity?.name)
        case .smtp:
            guard let host = destination.config["host"], !host.isEmpty,
                  let secret, !secret.isEmpty else { return nil }
            let security = SMTPSettings.Security(rawValue: destination.config["security"] ?? "")
                ?? .startTLS
            let settings = SMTPSettings(
                host: host,
                port: Int(destination.config["port"] ?? "") ?? SMTPSettings.defaultPort(for: security),
                security: security,
                username: destination.config["username"] ?? "",
                password: secret,
                from: destination.config["from"] ?? destination.config["username"] ?? "")
            return SMTPExporter(settings: settings,
                                recipients: Self.recipients(in: destination),
                                entityName: entity?.name,
                                oneMessagePerInvoice: destination.config["perInvoice"] != "false")
        }
    }

    /// Recipients are written the way people write them: commas, semicolons or
    /// just spaces between addresses.
    static func recipients(in destination: ExportDestination) -> [String] {
        (destination.config["recipients"] ?? "")
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Sends the documents currently in view to a saved destination, and
    /// records how it went on the destination itself — which is what its card
    /// shows.
    @discardableResult
    func run(_ destination: ExportDestination,
             documents: [InvoiceDocument],
             force: Bool = false,
             announce: Bool = true) async -> ExportService.Report? {
        guard let store, let exporter = makeExporter(for: destination) else {
            if announce {
                alert = AlertContent(title: t("%@ is not ready", destination.name),
                                     message: t("Finish setting this destination up before running it."))
            }
            return nil
        }
        runningDestinationIDs.insert(destination.id)
        defer { runningDestinationIDs.remove(destination.id) }

        let report = await exportService.export(documents, to: exporter, force: force)

        var saved = destination
        saved.lastRunAt = Date()
        saved.lastSucceeded = report.failed.isEmpty
        saved.documentsSent += report.exportedCount
        saved.lastDetail = report.failed.first?.message ?? report.summary
        try? await store.upsert(saved)
        await reload()

        if announce {
            var message = tn("%d documents exported", report.exportedCount)
            if !report.skipped.isEmpty { message += ", " + tn("%d already sent", report.skipped.count) }
            if !report.failed.isEmpty { message += ", " + tn("%d failed", report.failed.count) }
            if let summary = report.summary { message += ".\n" + summary }
            if let first = report.failed.first { message += "\n" + t("First failure: %@", first.message) }
            alert = AlertContent(title: t("Export to %@", destination.name), message: message)
        }
        return report
    }

    /// Called after a collection. Only destinations the user switched on, only
    /// kinds that can run unattended, and only documents that are actually new
    /// — the idempotence record does the rest.
    func runAutomaticExports() async {
        let automatic = exportDestinations.filter {
            $0.runsAutomatically && $0.kind.canRunAutomatically && $0.isComplete(hasSecret: hasSecret($0))
        }
        guard !automatic.isEmpty, !documents.isEmpty else { return }
        for destination in automatic {
            // Quietly: this happens after a collection the user started, and an
            // alert per destination would bury the collection's own result.
            await run(destination, documents: documents, announce: false)
        }
    }

    func export(_ documents: [InvoiceDocument], to exporter: any Exporter, force: Bool) async {
        let report = await exportService.export(documents, to: exporter, force: force)
        await reloadDocuments()

        var message = tn("%d documents exported", report.exportedCount)
        if !report.skipped.isEmpty {
            message += ", " + tn("%d already sent", report.skipped.count)
        }
        if !report.failed.isEmpty {
            message += ", " + tn("%d failed", report.failed.count)
        }
        if let summary = report.summary { message += ".\n" + summary }
        if let first = report.failed.first {
            message += "\n" + t("First failure: %@", first.message)
        }

        alert = AlertContent(title: t("Export to %@", exporter.displayName), message: message)
    }

    // MARK: - Preferences

    /// The interface language is applied before anything else in `save`,
    /// because the alert that a failing save produces should already be in the
    /// language the user just chose.
    private func applyLanguage() {
        Localization.setLanguage(preferences.interfaceLanguage
            .flatMap(Localization.Language.init(rawValue:)))
        languageRevision &+= 1
    }

    /// Bumped whenever the language changes. The root view keys its identity on
    /// it, which is what forces SwiftUI to rebuild a tree whose strings were
    /// resolved eagerly rather than through LocalizedStringKey.
    private(set) var languageRevision = 0

    func save(_ newValue: Preferences) async {
        let languageChanged = newValue.interfaceLanguage != preferences.interfaceLanguage
        preferences = newValue
        if languageChanged { applyLanguage() }
        try? await newValue.save(to: store)
        library.fileTemplate = NamingTemplate(pattern: newValue.fileNamePattern)
        library.folderTemplate = NamingTemplate(pattern: newValue.folderPattern)
        await collector.setMaximumConcurrency(newValue.maximumConcurrency)
        await collector.setEarliestDocumentDate(newValue.earliestDocumentDate)
        if let entityID = entity?.id {
            await scheduler.setEnabled(newValue.schedulerEnabled, entityID: entityID)
        }
    }

    // MARK: - Plugins

    func installPlugin(from url: URL) async {
        do {
            let entry = try await catalog.install(from: url)
            await reload()
            alert = AlertContent(
                title: t("Installed %@", entry.manifest.name),
                message: entry.warnings.joined(separator: "\n\n") + "\n\n" + entry.capabilitySummary)
        } catch {
            alert = AlertContent(title: t("Could not install the plugin"),
                                 message: error.localizedDescription)
        }
    }

    var isRefreshingCatalogue = false

    // MARK: - Plugin recorder

    var isRecording = false
    var recorderEvents: [PluginRecorder.Event] = []
    var recorderAnalysis: PluginRecorder.PageAnalysis?
    var recorderDraft: PluginRecorder.Draft?
    private var recorder: PluginRecorder?
    private var recordingSession: RecordingSession?
    private var recordingIdentity: (id: String, name: String, countries: [String]) = ("", "", [])
    private var recorderPoll: Task<Void, Never>?

    func startRecording(at url: URL, id: String, name: String, countries: [String]) async {
        let recorder = PluginRecorder()
        self.recorder = recorder
        self.recordingIdentity = (id, name, countries)
        recorderEvents = []
        recorderAnalysis = nil
        recorderDraft = nil

        let session = RecordingSession(recorder: recorder)
        recordingSession = session
        session.start(at: url)
        isRecording = true

        // The recording window is the user's; this only mirrors what it saw so
        // the list beside it stays live.
        recorderPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(600))
                let events = await recorder.recordedEvents
                await MainActor.run { self?.recorderEvents = events }
            }
        }
    }

    func analyseRecordedPage() async {
        guard let session = recordingSession, let recorder else { return }
        do {
            recorderAnalysis = try await session.analyseCurrentPage()
            recorderEvents = await recorder.recordedEvents
            recorderDraft = await recorder.makeDraft(
                id: recordingIdentity.id,
                name: recordingIdentity.name,
                countries: recordingIdentity.countries)
        } catch {
            alert = AlertContent(title: t("Could not analyse the page"),
                                 message: error.localizedDescription)
        }
    }

    /// Back to watching, keeping everything recorded so far — for a portal
    /// where the invoices are spread over more than one page.
    func resumeRecording() async {
        recorderDraft = nil
    }

    func stopRecording() async {
        recorderPoll?.cancel()
        recorderPoll = nil
        recordingSession?.stop()
        recordingSession = nil
        recorder = nil
        isRecording = false
    }

    /// F10.2. The catalogue updates without reinstalling the application, and
    /// the index it reads is signature-verified before anything is written to
    /// disk — see `PluginIndexUpdater`.
    func refreshCatalogue() async {
        guard let url = URL(string: preferences.pluginIndexURL) else {
            alert = AlertContent(title: t("Could not refresh the catalogue"),
                                 message: t("The plugin index address in Settings is not a URL."))
            return
        }
        isRefreshingCatalogue = true
        defer { isRefreshingCatalogue = false }

        do {
            let update = try await PluginIndexUpdater(
                indexURL: url, minimumRevision: preferences.lastIndexRevision).update(catalog)

            if update.revision > preferences.lastIndexRevision {
                var updated = preferences
                updated.lastIndexRevision = update.revision
                await save(updated)
            }
            // Before composing the message, so the count it reports is the one
            // the catalogue now holds.
            await reload()

            var parts: [String] = []
            if !update.installed.isEmpty { parts.append(tn("%d added", update.installed.count)) }
            if !update.updated.isEmpty { parts.append(tn("%d updated", update.updated.count)) }
            if !update.removed.isEmpty { parts.append(tn("%d withdrawn", update.removed.count)) }
            if parts.isEmpty { parts.append(t("Already up to date.")) }

            // Say which index answered. "Already up to date" on its own leaves
            // no way to tell a working refresh from one that read a stale copy,
            // which is exactly the doubt this had to be debugged through once.
            parts.append(t("Index revision %1$@, %2$@ installed.",
                           number(update.revision),
                           tn("%d plugin", catalogEntries.count)))

            var message = parts.joined(separator: "\n")
            if !update.skipped.isEmpty {
                message += "\n" + update.skipped
                    .map { t("%1$@ skipped: %2$@", $0.key, $0.value) }
                    .sorted().joined(separator: "\n")
            }
            alert = AlertContent(title: t("Catalogue"), message: message)
        } catch {
            alert = AlertContent(title: t("Could not refresh the catalogue"),
                                 message: error.localizedDescription)
        }
    }

    func addDeveloperFolder(_ url: URL) async {
        await catalog.addLocalDirectory(url)
        await reload()
    }

    // MARK: - Notifications

    private func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    /// F9.3. One notification for the batch, not one per source: the user wants
    /// to know it is done and whether anything needs them.
    private func notify(_ batch: CollectionService.BatchReport) {
        let content = UNMutableNotificationContent()
        content.title = t("Collection finished")
        var parts = [tn("%d new documents", batch.newDocumentCount)]
        if !batch.failedSources.isEmpty {
            parts.append(tn("%d sources failed", batch.failedSources.count))
        }
        if !batch.sourcesNeedingSignIn.isEmpty {
            parts.append(tn("%d need you to sign in", batch.sourcesNeedingSignIn.count))
        }
        content.body = parts.joined(separator: ", ")

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}



/// A snapshot of source names the browser driver can read from any thread.
final class SourceNameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [UUID: String] = [:]

    func update(_ newValue: [UUID: String]) {
        lock.lock(); defer { lock.unlock() }
        names = newValue
    }

    func name(for id: UUID) -> String {
        lock.lock(); defer { lock.unlock() }
        return names[id] ?? "collection"
    }
}

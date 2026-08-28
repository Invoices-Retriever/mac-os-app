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
                for (key, value) in secrets where !value.isEmpty {
                    try vault.store(value, for: key, source: source.id,
                                    requireBiometrics: requireBiometrics)
                }
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
            for (key, value) in secrets {
                if value.isEmpty {
                    try? vault.store("", for: key, source: source.id)
                } else {
                    try vault.store(value, for: key, source: source.id,
                                    requireBiometrics: requireBiometrics)
                }
            }
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

    func authenticate(_ source: Source) async {
        runningSourceIDs.insert(source.id)
        defer { runningSourceIDs.remove(source.id) }
        do {
            try await collector.authenticate(source: source)
            await reload()
        } catch {
            alert = AlertContent(title: t("Sign-in to %@ failed", source.displayName),
                                 message: error.localizedDescription)
        }
    }

    func collect(_ source: Source) async {
        runningSourceIDs.insert(source.id)
        defer { runningSourceIDs.remove(source.id) }
        let report = await collector.collect(source: source)
        await reload()
        if report.status == .needsSignIn {
            alert = AlertContent(
                title: t("%@ needs you to sign in", source.displayName),
                message: t("The stored session has expired. Use “Sign in” to open the portal, deal with two-factor authentication, then collect again."))
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
            let update = try await PluginIndexUpdater(indexURL: url).update(catalog)
            await reload()

            var parts: [String] = []
            if !update.installed.isEmpty { parts.append(tn("%d added", update.installed.count)) }
            if !update.updated.isEmpty { parts.append(tn("%d updated", update.updated.count)) }
            if !update.removed.isEmpty { parts.append(tn("%d withdrawn", update.removed.count)) }
            if parts.isEmpty { parts.append(t("Already up to date.")) }

            var message = parts.joined(separator: ", ")
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

extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

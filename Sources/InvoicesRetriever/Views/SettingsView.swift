import SwiftUI
import IRCore

/// Everything that can be configured, on one scrollable page.
///
/// Deliberately not a tab bar. Tabs make you guess which of three drawers a
/// setting is in, and the guessing is worst for the person who has used the
/// application least. One page can be read top to bottom, searched with the
/// eye, and scrolled past; the groups are there to break it up, not to hide
/// things behind a click.
///
/// Every change saves immediately. There is no OK button, because there is
/// nothing here that is dangerous half-applied, and a settings sheet you can
/// abandon by mistake is worse than one that simply remembers.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(LogoStore.self) private var logos

    @State private var draft = Preferences.default
    @State private var entityName = ""
    @State private var vatNumber = ""
    @State private var loaded = false

    /// The floor is edited as a month and a year, which is how people think
    /// about "from when" — nobody wants a day picker for this.
    @State private var hasEarliestDate = false
    @State private var earliestMonth = 1
    @State private var earliestYear = Calendar(identifier: .gregorian).component(.year, from: Date())

    private static let years: [Int] = {
        let thisYear = Calendar(identifier: .gregorian).component(.year, from: Date())
        return Array((thisYear - 12)...(thisYear + 1)).reversed()
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                organisation
                collection
                library
                naming
                reading
                appearance
                plugins
                privacy
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            PageHeader(title: t("Settings"),
                       subtitle: t("Everything here applies to every source, and saves as you change it.")) { }
                .background(.background)
        }
        .navigationTitle("")
        .onAppear(perform: load)
        .onChange(of: draft) { _, newValue in
            Task { await model.save(newValue) }
        }
    }

    // MARK: - Groups

    private var organisation: some View {
        SettingsGroup(title: t("Organisation"), symbol: "building.2") {
            SettingsRow(title: t("Name"),
                        subtitle: t("Shown on exported registers, so an accountant knows whose books these are."),
                        isFirst: true) {
                TextField("", text: $entityName, prompt: Text(Entity.defaultName))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onSubmit(saveEntity)
            }
            SettingsRow(title: t("VAT number"),
                        subtitle: t("Appears on exported registers, where an accountant expects it.")) {
                TextField("", text: $vatNumber, prompt: Text(verbatim: "FR12345678901"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onSubmit(saveEntity)
            }
        }
        .onChange(of: entityName) { _, _ in saveEntity() }
        .onChange(of: vatNumber) { _, _ in saveEntity() }
    }

    private var collection: some View {
        SettingsGroup(title: t("Collection"), symbol: "arrow.down.circle") {
            SettingsRow(title: t("Skip documents issued before"),
                        subtitle: t("Nothing older is downloaded, whatever a source's own look-back says. Useful when a supplier keeps ten years of history you have no use for."),
                        isFirst: true) {
                HStack(spacing: 8) {
                    if hasEarliestDate {
                        Picker("", selection: $earliestMonth) {
                            ForEach(1...12, id: \.self) { month in
                                Text(Self.monthName(month)).tag(month)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)

                        Picker("", selection: $earliestYear) {
                            ForEach(Self.years, id: \.self) { year in
                                Text(verbatim: String(year)).tag(year)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                    }
                    Toggle("", isOn: $hasEarliestDate)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
            .onChange(of: hasEarliestDate) { _, _ in saveEarliestDate() }
            .onChange(of: earliestMonth) { _, _ in saveEarliestDate() }
            .onChange(of: earliestYear) { _, _ in saveEarliestDate() }

            SettingsRow(title: t("Sources at a time"),
                        subtitle: t("More is not always faster: each source runs a browser, and portals notice bursts.")) {
                Stepper(value: $draft.maximumConcurrency, in: 1...6) {
                    Text(verbatim: number(draft.maximumConcurrency))
                        .monospacedDigit()
                        .frame(width: 24, alignment: .trailing)
                }
            }

            SettingsRow(title: t("Run scheduled collections"),
                        subtitle: t("Only while Invoices Retriever is open. There is no background helper, so nothing runs when it is closed.")) {
                Toggle("", isOn: $draft.schedulerEnabled).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    private var library: some View {
        SettingsGroup(title: t("Library"), symbol: "folder") {
            SettingsRow(title: t("Documents folder"),
                        subtitle: draft.libraryPath ?? model.paths.libraryRoot.path,
                        isFirst: true) {
                HStack(spacing: 6) {
                    Button(t("Reveal")) {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: draft.libraryPath ?? model.paths.libraryRoot.path)])
                    }
                    Button(t("Change…"), action: chooseLibrary)
                }
            }
            SettingsNote(text: t("Documents are filed here in folders you can read without this application. If you move them, use “Rescan folder” afterwards."))
            SettingsRow(title: t("Rescan the folder"),
                        subtitle: t("Rebuilds the index from the files on disk. Nothing is deleted.")) {
                Button(t("Rescan")) { Task { await model.rescanLibrary() } }
            }
        }
    }

    private var naming: some View {
        SettingsGroup(title: t("File names"), symbol: "textformat") {
            SettingsRow(title: t("File name"), subtitle: preview(draft.fileNamePattern) + ".pdf",
                        isFirst: true) {
                TextField("", text: $draft.fileNamePattern)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(width: 280)
            }
            SettingsRow(title: t("Folders"), subtitle: preview(draft.folderPattern) + "/") {
                TextField("", text: $draft.folderPattern)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(width: 280)
            }
            VStack(spacing: 0) {
                Divider().padding(.leading, 16)
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(NamingTemplate.availableTokens, id: \.token) { token in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(token.token)
                                    .font(.callout.monospaced())
                                    .frame(width: 108, alignment: .leading)
                                Text(token.explanation)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                } label: {
                    Text(t("Available tokens")).font(.callout)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    private var reading: some View {
        SettingsGroup(title: t("Reading invoices"), symbol: "text.viewfinder") {
            SettingsRow(title: t("Read scanned PDFs"),
                        subtitle: t("On-device OCR through Apple's Vision framework. Nothing is sent anywhere."),
                        isFirst: true) {
                Toggle("", isOn: $draft.enableOCR).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: t("Ask a language model when a field cannot be read"),
                        subtitle: t("Off by default, and a decision rather than a default you inherit.")) {
                Toggle("", isOn: $draft.enableLLMFallback).labelsHidden().toggleStyle(.switch)
            }
            if draft.enableLLMFallback {
                SettingsNote(text: t("This sends the text of the invoice to the provider you configure. You become responsible for that transfer under the GDPR."),
                             symbol: "exclamationmark.triangle.fill", colour: .orange)
                SettingsRow(title: t("Provider")) {
                    TextField("", text: Binding(get: { draft.llmProvider ?? "" },
                                                set: { draft.llmProvider = $0.nilIfEmpty }),
                              prompt: Text(t("A local model endpoint, or an API")))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                }
            }
        }
    }

    private var appearance: some View {
        SettingsGroup(title: t("Appearance"), symbol: "paintbrush") {
            SettingsRow(title: t("Interface language"),
                        subtitle: t("Dates and amounts always follow your regional settings, whichever language you pick."),
                        isFirst: true) {
                Picker("", selection: Binding(get: { draft.interfaceLanguage },
                                              set: { draft.interfaceLanguage = $0 })) {
                    Text(t("Follow the system")).tag(String?.none)
                    ForEach(Localization.Language.allCases) { language in
                        Text(language.endonym).tag(String?.some(language.rawValue))
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }
            SettingsRow(title: t("Show suppliers' logos"),
                        subtitle: t("Asked for once per plugin in the catalogue — the same list for everybody, so the request says nothing about which suppliers you use. They are then kept on this Mac.")) {
                Toggle("", isOn: Binding(get: { draft.showSupplierLogos },
                                         set: { newValue in
                                             draft.showSupplierLogos = newValue
                                             logos.isEnabled = newValue
                                             if !newValue { logos.clear() }
                                         }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    private var plugins: some View {
        SettingsGroup(title: t("Plugins"), symbol: "square.grid.2x2") {
            SettingsRow(title: t("Index address"),
                        subtitle: t("Where the catalogue is downloaded from. Only a correctly signed index is ever installed."),
                        isFirst: true) {
                TextField("", text: $draft.pluginIndexURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .frame(width: 300)
            }
            SettingsRow(title: t("Installed catalogue"),
                        subtitle: t("Revision %1$@ · %2$@", number(draft.lastIndexRevision),
                                    tn("%d plugin", model.catalogEntries.count))) {
                Button(t("Refresh")) { Task { await model.refreshCatalogue() } }
                    .disabled(model.isRefreshingCatalogue)
            }
            if draft.pluginIndexURL != Preferences.defaultIndexURL {
                SettingsRow(title: t("Back to the official index")) {
                    Button(t("Restore")) { draft.pluginIndexURL = Preferences.defaultIndexURL }
                }
            }
        }
    }

    private var privacy: some View {
        SettingsGroup(title: t("Privacy"), symbol: "hand.raised") {
            SettingsNote(text: t("There is no account, no server of ours, and no telemetry. Documents, credentials and logs stay on this Mac."),
                         symbol: "lock.shield", isFirst: true)
            SettingsNote(text: t("Supplier websites, when you collect"), symbol: "network")
            SettingsNote(text: t("The plugin index, to find new and updated plugins"), symbol: "square.grid.2x2")
            SettingsNote(text: t("A logo service, once per plugin, if logos are on"), symbol: "photo")
            SettingsNote(text: t("Any export destination you configure yourself"), symbol: "square.and.arrow.up")
            SettingsRow(title: t("Credentials"),
                        subtitle: Keychain.biometricsAvailable()
                            ? t("Kept in the macOS keychain. Touch ID is available on this Mac and can be required per source.")
                            : t("Kept in the macOS keychain, protected by your login password.")) {
                Button(t("Open Keychain Access")) {
                    let path = "/System/Applications/Utilities/Keychain Access.app"  // not prose
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            }
        }
    }

    // MARK: - Loading and saving

    private func load() {
        guard !loaded else { return }
        draft = model.preferences
        entityName = model.entity?.name ?? ""
        vatNumber = model.entity?.vatNumber ?? ""
        if let date = model.preferences.earliestDocumentDate {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            hasEarliestDate = true
            earliestMonth = calendar.component(.month, from: date)
            earliestYear = calendar.component(.year, from: date)
        }
        loaded = true
    }

    private func saveEntity() {
        guard loaded else { return }
        Task { await model.updateEntity(name: entityName, vatNumber: vatNumber.nilIfEmpty) }
    }

    private func saveEarliestDate() {
        guard loaded else { return }
        guard hasEarliestDate else {
            draft.earliestDocumentDate = nil
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = earliestYear
        components.month = earliestMonth
        components.day = 1
        draft.earliestDocumentDate = calendar.date(from: components)
    }

    static func monthName(_ month: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Localization.formattingLocale
        let names = calendar.monthSymbols
        guard month >= 1, month <= names.count else { return String(month) }
        return names[month - 1].capitalized(with: Localization.formattingLocale)
    }

    private func preview(_ pattern: String) -> String {
        var document = InvoiceDocument(entityID: UUID(), sha256: "", relativePath: "", byteSize: 0)
        document.issuedOn = InvoiceDateParser.parse("2026-03-31")
        document.issuer = "OVHcloud"   // not prose: sample data for the preview
        document.number = "FR-12345"
        document.total = Money(cents: 123456, currency: "EUR")
        return NamingTemplate(pattern: pattern).render(document: document, sourceName: "OVH")
    }

    private func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = t("Choose where your documents are stored.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.libraryPath = url.path
    }
}

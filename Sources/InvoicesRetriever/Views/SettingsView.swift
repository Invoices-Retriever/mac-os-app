import SwiftUI
import IRCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = Preferences.default
    @State private var loaded = false

    var body: some View {
        TabView {
            general.tabItem { Label(t("General"), systemImage: "gearshape") }
            naming.tabItem { Label(t("Naming"), systemImage: "textformat") }
            privacy.tabItem { Label(t("Privacy"), systemImage: "hand.raised") }
        }
        .onAppear {
            guard !loaded else { return }
            draft = model.preferences
            loaded = true
        }
        .onChange(of: draft) { _, newValue in
            Task { await model.save(newValue) }
        }
    }

    private var general: some View {
        Form {
            Section(t("Language")) {
                Picker(t("Interface language"), selection: Binding(
                    get: { draft.interfaceLanguage },
                    set: { draft.interfaceLanguage = $0 }
                )) {
                    Text(t("Follow the system")).tag(String?.none)
                    ForEach(Localization.Language.allCases) { language in
                        Text(language.endonym).tag(String?.some(language.rawValue))
                    }
                }
                Text(t("Dates and amounts always follow your regional settings, whichever language you pick here."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(t("Library")) {
                HStack {
                    Text(draft.libraryPath ?? model.paths.libraryRoot.path)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(t("Change…")) { chooseLibrary() }
                }
                Text(t("Documents are stored here in a folder structure you can read without this app. Moving them is your call; use “Rescan folder” afterwards."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(t("Collection")) {
                Stepper(tn("Collect from %d sources at a time", draft.maximumConcurrency),
                        value: $draft.maximumConcurrency, in: 1...6)
                Text(t("More is not always faster: each source runs a browser, and portals notice bursts."))
                    .font(.caption).foregroundStyle(.secondary)

                Toggle(t("Run scheduled collections while the app is open"), isOn: $draft.schedulerEnabled)
                Text(t("There is no background helper. Nothing runs when Invoices Retriever is closed."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var naming: some View {
        Form {
            Section(t("File name")) {
                TextField(t("Pattern"), text: $draft.fileNamePattern)
                    .font(.body.monospaced())
                Text(preview(draft.fileNamePattern) + ".pdf")
                    .font(.callout.monospaced()).foregroundStyle(.secondary)
            }
            Section(t("Folders")) {
                TextField(t("Pattern"), text: $draft.folderPattern)
                    .font(.body.monospaced())
                Text(preview(draft.folderPattern) + "/")
                    .font(.callout.monospaced()).foregroundStyle(.secondary)
            }
            Section(t("Available tokens")) {
                ForEach(NamingTemplate.availableTokens, id: \.token) { token in
                    LabeledContent(token.token, value: token.explanation)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var privacy: some View {
        Form {
            Section(t("What leaves this Mac")) {
                Label(t("Supplier websites, when you collect"), systemImage: "network")
                Label(t("The plugin index, to find new and updated plugins"), systemImage: "square.grid.2x2")
                Label(t("Any export destination you configure yourself"), systemImage: "square.and.arrow.up")
                Text(t("There is no account, no server of ours, and no telemetry. Documents, credentials and logs stay here."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(t("Reading invoices")) {
                Toggle(t("Use on-device OCR for scanned PDFs"), isOn: $draft.enableOCR)
                Text(t("Uses Apple's Vision framework. Nothing is sent anywhere."))
                    .font(.caption).foregroundStyle(.secondary)

                Toggle(t("Ask a language model when a field cannot be read"), isOn: $draft.enableLLMFallback)
                if draft.enableLLMFallback {
                    Label(t("This sends the text of the invoice to the provider you configure. You become responsible for that transfer under the GDPR."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                    TextField(t("Provider"), text: Binding(
                        get: { draft.llmProvider ?? "" },
                        set: { draft.llmProvider = $0.nilIfEmpty }),
                              prompt: Text(t("A local model endpoint, or an API")))
                }
            }

            Section(t("Keychain")) {
                Label(Keychain.biometricsAvailable()
                      ? "Touch ID is available on this Mac and can be required per source."
                      : "Touch ID is not available; credentials are protected by your login password.",
                      systemImage: "touchid")
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func preview(_ pattern: String) -> String {
        var document = InvoiceDocument(entityID: UUID(), sha256: "", relativePath: "", byteSize: 0)
        document.issuedOn = InvoiceDateParser.parse("2026-03-31")
        document.issuer = "OVHcloud"
        document.number = "FR-12345"
        document.total = Money(cents: 123456, currency: "EUR")
        return NamingTemplate(pattern: pattern).render(document: document, sourceName: "OVH")
    }

    private func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose where your documents are stored."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.libraryPath = url.path
    }
}

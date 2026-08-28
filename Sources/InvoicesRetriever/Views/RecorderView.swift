import SwiftUI
import UniformTypeIdentifiers
import IRCore
import IRBrowser

/// Record a plugin by using the portal.
///
/// The flow is deliberately three steps and no more: say what you are covering,
/// go and fetch an invoice the way you always do, press analyse. Anything that
/// asked the user to think about selectors would defeat the point — they are
/// here precisely because they should not have to.
struct RecorderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var pluginID = ""
    @State private var name = ""
    @State private var country = "FR"
    @State private var startURL = ""
    @State private var isAnalysing = false

    private var canStart: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && URL(string: startURL)?.scheme?.hasPrefix("http") == true
            && pluginID.range(of: "^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$", options: .regularExpression) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.recorderDraft != nil {
                result
            } else if model.isRecording {
                recording
            } else {
                setup
            }
        }
        .frame(width: 640, height: 620)
    }

    // MARK: - Step one

    private var setup: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text(t("Fetch an invoice the way you normally would. The app watches where you go and what you click, works out where the invoice list is, and writes the plugin."))
                        .font(.callout)
                    Label(t("What you type is never recorded — only which field you used. A password cannot end up in the plugin."),
                          systemImage: "lock")
                        .font(.callout).foregroundStyle(.secondary)
                }

                Section(t("The supplier")) {
                    TextField(t("Name"), text: $name, prompt: Text(verbatim: "OVHcloud"))
                        .onChange(of: name) { _, new in
                            if pluginID.isEmpty || pluginID == Self.suggestedID(from: name) {
                                pluginID = Self.suggestedID(from: new)
                            }
                        }
                    TextField(t("Identifier"), text: $pluginID, prompt: Text(verbatim: "ovhcloud"))
                        .font(.body.monospaced())
                    TextField(t("Country"), text: $country, prompt: Text(verbatim: "FR"))
                    TextField(t("Start from"), text: $startURL,
                              prompt: Text(verbatim: "https://www.example.com/login"))
                    Text(t("The sign-in page is the usual starting point. If you are already signed in elsewhere, start at the billing page instead — the recording uses its own browser profile and shares nothing with your sources."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(t("Cancel")) { dismiss() }
                Button(t("Start recording")) {
                    guard let url = URL(string: startURL) else { return }
                    let countries = country.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
                        .filter { !$0.isEmpty }
                    Task {
                        await model.startRecording(at: url, id: pluginID,
                                                   name: name, countries: countries)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart)
            }
            .padding()
        }
    }

    // MARK: - Step two

    private var recording: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 9, height: 9)
                Text(t("Recording. Use the window that opened."))
                    .font(.headline)
                Spacer()
                Text(tn("%d step", model.recorderEvents.count))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            if model.recorderEvents.isEmpty {
                ContentUnavailableView {
                    Label(t("Nothing yet"), systemImage: "record.circle")
                } description: {
                    Text(t("Sign in, then go to the page that lists your invoices. Come back here and press Analyse."))
                }
            } else {
                List(model.recorderEvents) { event in
                    HStack(spacing: 8) {
                        Image(systemName: Self.symbol(for: event.kind))
                            .foregroundStyle(.secondary).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.summary)
                            if let selector = event.selector {
                                Text(selector).font(.caption.monospaced()).foregroundStyle(.tertiary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Button(t("Stop")) { Task { await model.stopRecording() } }
                Spacer()
                if isAnalysing { ProgressView().controlSize(.small) }
                Button(t("Analyse this page")) {
                    isAnalysing = true
                    Task { await model.analyseRecordedPage(); isAnalysing = false }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isAnalysing)
                .help(t("Go to the page listing your invoices first, then press this."))
            }
            .padding()
        }
    }

    // MARK: - Step three

    @ViewBuilder
    private var result: some View {
        if let draft = model.recorderDraft {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let analysis = model.recorderAnalysis, analysis.found {
                            GroupBox(t("What it found")) {
                                VStack(alignment: .leading, spacing: 6) {
                                    LabeledContent(t("Invoice rows"),
                                                   value: tn("%d row", analysis.rowCount ?? 0))
                                    ForEach(analysis.columns ?? []) { column in
                                        HStack(alignment: .firstTextBaseline) {
                                            Text(Self.label(for: column.kind))
                                                .frame(width: 84, alignment: .leading)
                                                .foregroundStyle(.secondary)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(column.samples.joined(separator: " · "))
                                                Text(column.selector)
                                                    .font(.caption.monospaced()).foregroundStyle(.tertiary)
                                            }
                                        }
                                        .font(.callout)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                            }
                        }

                        if !draft.warnings.isEmpty {
                            GroupBox(t("Check these")) {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(draft.warnings, id: \.self) { warning in
                                        Label(warning, systemImage: "exclamationmark.triangle")
                                            .font(.callout).foregroundStyle(.orange)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                            }
                        }

                        GroupBox(t("The plugin")) {
                            ScrollView(.horizontal) {
                                Text(draft.json)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 220)
                        }
                    }
                    .padding()
                }

                Divider()
                HStack {
                    Button(t("Record more")) { Task { await model.resumeRecording() } }
                    Spacer()
                    Button(t("Copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(draft.json, forType: .string)
                    }
                    Button(t("Save as…")) { save(draft) }
                        .keyboardShortcut(.defaultAction)
                    Button(t("Done")) {
                        Task { await model.stopRecording() }
                        dismiss()
                    }
                }
                .padding()
            }
        }
    }

    private func save(_ draft: PluginRecorder.Draft) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(draft.manifest.id).json"
        panel.allowedContentTypes = [.json]
        panel.message = t("Save it into the folder you added under Plugin developer, and it appears in the catalogue straight away.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(draft.json.utf8).write(to: url)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Presentation

    static func suggestedID(from name: String) -> String {
        let cleaned = name.lowercased()
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(cleaned).split(separator: "-").joined(separator: "-")
    }

    static func symbol(for kind: PluginRecorder.Event.Kind) -> String {
        switch kind {
        case .navigate: return "arrow.right.circle"
        case .click: return "cursorarrow.click"
        case .type: return "character.cursor.ibeam"
        }
    }

    static func label(for kind: PluginRecorder.PageAnalysis.Column.Kind) -> String {
        switch kind {
        case .date: return t("Date")
        case .money: return t("Amount")
        case .reference: return t("Number")
        case .text: return t("Text")
        }
    }
}

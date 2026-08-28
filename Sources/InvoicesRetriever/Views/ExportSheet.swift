import SwiftUI
import IRCore

/// UC-05. Four destinations, one idempotence rule, and a plain statement of
/// what is about to be sent where.
struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let documents: [InvoiceDocument]

    @State private var destination: Kind = .folder
    @State private var folderURL: URL?
    @State private var webhookURL = ""
    @State private var webhookHeader = ""
    @State private var resend = false
    @State private var isWorking = false

    enum Kind: String, CaseIterable, Identifiable {
        case folder, csv, json, webhook
        var id: String { rawValue }
        var title: String {
            switch self {
            case .folder: return "Folder"
            case .csv: return "CSV register"
            case .json: return "JSON register"
            case .webhook: return "Webhook"
            }
        }
        var explanation: String {
            switch self {
            case .folder: return "Copies the PDFs into a folder, organised the way your library is. This is what you hand to your accountant."
            case .csv: return "One row per document, for reconciliation in a spreadsheet. Amounts use a dot decimal so any tool reads them."
            case .json: return "The same register as JSON, for a script."
            case .webhook: return "Posts each document to a URL as multipart: the metadata as JSON, the PDF as a file."
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Send to", selection: $destination) {
                        ForEach(Kind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(destination.explanation)
                        .font(.callout).foregroundStyle(.secondary)
                }

                switch destination {
                case .folder, .csv, .json:
                    Section(destination == .folder ? "Destination folder" : "Destination file") {
                        HStack {
                            Text(folderURL?.path ?? "Not chosen")
                                .lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(folderURL == nil ? .secondary : .primary)
                            Spacer()
                            Button("Choose…") { chooseDestination() }
                        }
                    }
                case .webhook:
                    Section("Webhook") {
                        TextField("https://…", text: $webhookURL)
                        TextField("Authorization header (optional)", text: $webhookHeader,
                                  prompt: Text("Bearer …"))
                        Text("The URL and any header are stored in this window only — configure a permanent destination in Settings once you are happy with it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("Send documents that were already exported here", isOn: $resend)
                    Text(resend
                         ? "Every one of the \(documents.count) selected documents will be sent."
                         : "Documents already sent to this destination will be skipped.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text("\(documents.count) document(s) in the current view")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Export") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isReady || isWorking)
            }
            .padding()
        }
        .frame(width: 560, height: 480)
        .overlay {
            if isWorking {
                ProgressView("Exporting…")
                    .padding(30)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var isReady: Bool {
        switch destination {
        case .folder, .csv, .json: return folderURL != nil
        case .webhook: return URL(string: webhookURL)?.scheme?.hasPrefix("http") == true
        }
    }

    private func chooseDestination() {
        if destination == .folder {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.message = "Choose where to copy the PDFs."
            if panel.runModal() == .OK { folderURL = panel.url }
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = destination == .csv ? "register.csv" : "register.json"
            panel.message = "Choose where to write the register."
            if panel.runModal() == .OK { folderURL = panel.url }
        }
    }

    private func export() {
        guard let exporter = makeExporter() else { return }
        isWorking = true
        Task {
            await model.export(documents, to: exporter, force: resend)
            isWorking = false
            dismiss()
        }
    }

    private func makeExporter() -> (any Exporter)? {
        let names = model.sourceNames
        switch destination {
        case .folder:
            guard let folderURL else { return nil }
            return FolderExporter(root: folderURL,
                                  folderTemplate: NamingTemplate(pattern: model.preferences.folderPattern),
                                  fileTemplate: NamingTemplate(pattern: model.preferences.fileNamePattern),
                                  sourceNames: names)
        case .csv:
            guard let folderURL else { return nil }
            return RegisterExporter(format: .csv, outputURL: folderURL, sourceNames: names)
        case .json:
            guard let folderURL else { return nil }
            return RegisterExporter(format: .json, outputURL: folderURL, sourceNames: names)
        case .webhook:
            guard let url = URL(string: webhookURL) else { return nil }
            var headers: [String: String] = [:]
            if !webhookHeader.isEmpty { headers["Authorization"] = webhookHeader }
            return WebhookExporter(url: url, headers: headers, sourceNames: names)
        }
    }
}

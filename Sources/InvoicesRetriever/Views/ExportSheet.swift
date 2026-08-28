import SwiftUI
import IRCore

/// UC-05. Six destinations, one idempotence rule, and a plain statement of
/// what is about to be sent where.
struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let documents: [InvoiceDocument]

    @State private var destination: Kind = .folder
    @State private var folderURL: URL?
    @State private var webhookURL = ""
    @State private var webhookHeader = ""
    @State private var paperlessURL = ""
    @State private var paperlessToken = ""
    @State private var emailRecipients = ""
    @State private var resend = false
    @State private var isWorking = false

    enum Kind: String, CaseIterable, Identifiable {
        case folder, email, csv, json, webhook, paperless
        var id: String { rawValue }
        var title: String {
            switch self {
            case .folder: return t("Folder")
            case .csv: return t("CSV register")
            case .json: return t("JSON register")
            case .webhook: return t("Webhook")
            case .email: return t("E-mail")
            case .paperless: return t("Paperless-ngx")
            }
        }
        var explanation: String {
            switch self {
            case .folder: return t("Copies the PDFs into a folder, organised the way your library is. This is what you hand to your accountant.")
            case .csv: return t("One row per document, for reconciliation in a spreadsheet. Amounts use a dot decimal so any tool reads them.")
            case .json: return t("The same register as JSON, for a script.")
            case .webhook: return t("Posts each document to a URL as multipart: the metadata as JSON, the PDF as a file.")
            case .email: return t("Opens a message with the invoices attached and a summary written out. Nothing is sent: you read it and press Send yourself.")
            case .paperless: return t("Uploads each PDF into a Paperless-ngx instance, with its date and a title already filled in.")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker(t("Send to"), selection: $destination) {
                        ForEach(Kind.allCases) { Text($0.title).tag($0) }
                    }
                    // Six destinations do not fit as segments without
                    // truncating every label into an initial.
                    .pickerStyle(.menu)
                    Text(destination.explanation)
                        .font(.callout).foregroundStyle(.secondary)
                }

                switch destination {
                case .folder, .csv, .json:
                    Section(destination == .folder ? t("Destination folder") : t("Destination file")) {
                        HStack {
                            Text(folderURL?.path ?? t("Not chosen"))
                                .lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(folderURL == nil ? .secondary : .primary)
                            Spacer()
                            Button(t("Choose…")) { chooseDestination() }
                        }
                    }
                case .webhook:
                    Section(t("Webhook")) {
                        TextField("https://…", text: $webhookURL)
                        TextField(t("Authorization header (optional)"), text: $webhookHeader,
                                  prompt: Text(t("Bearer …")))
                        Text(t("The URL and any header are kept for this export only. Nothing is stored."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .paperless:
                    Section(t("Paperless-ngx")) {
                        TextField("https://…", text: $paperlessURL)
                        SecureField(t("API token"), text: $paperlessToken)
                        Text(t("Create the token in Paperless under your user's settings. It is kept for this export only."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .email:
                    Section(t("E-mail")) {
                        TextField(t("To (optional)"), text: $emailRecipients,
                                  prompt: Text(verbatim: "comptable@example.com"))
                        Label(t("Your mail application opens with the message ready. Invoices Retriever never sends anything itself."),
                              systemImage: "hand.raised")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle(t("Send documents that were already exported here"), isOn: $resend)
                    Text(resend
                         ? tn("Every one of the %d selected documents will be sent.", documents.count)
                         : t("Documents already sent to this destination will be skipped."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text(tn("%d documents in the current view", documents.count))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(t("Cancel")) { dismiss() }
                Button(t("Export")) { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isReady || isWorking)
            }
            .padding()
        }
        .frame(width: 580, height: 500)
        .overlay {
            if isWorking {
                ProgressView(t("Exporting…"))
                    .padding(30)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var isReady: Bool {
        switch destination {
        case .folder, .csv, .json: return folderURL != nil
        case .webhook: return URL(string: webhookURL)?.scheme?.hasPrefix("http") == true
        case .paperless:
            return URL(string: paperlessURL)?.scheme?.hasPrefix("http") == true
                && !paperlessToken.isEmpty
        // A recipient is optional: filling it in the mail window is normal.
        case .email: return true
        }
    }

    private func chooseDestination() {
        if destination == .folder {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.message = t("Choose where to copy the PDFs.")
            if panel.runModal() == .OK { folderURL = panel.url }
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = destination == .csv ? "register.csv" : "register.json"
            panel.message = t("Choose where to write the register.")
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
        case .paperless:
            guard let url = URL(string: paperlessURL) else { return nil }
            return PaperlessExporter(baseURL: url, token: paperlessToken, sourceNames: names)
        case .email:
            let recipients = emailRecipients
                .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return EmailExporter(recipients: recipients, entityName: model.entity?.name)
        }
    }
}

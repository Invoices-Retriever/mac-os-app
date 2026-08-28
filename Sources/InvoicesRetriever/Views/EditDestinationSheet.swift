import SwiftUI
import IRCore

/// Configuring one export destination.
///
/// The same sheet for creating and editing, because the fields are the same and
/// two sheets would drift apart. What differs is the secret: on an existing
/// destination the field comes up empty and an empty field means "keep what is
/// stored" — a token is never read back out of the keychain to be shown, so
/// there is nothing to display and nothing to leak into a screenshot.
struct EditDestinationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State var destination: ExportDestination

    @State private var secret = ""

    private var kind: ExportDestinationKind { destination.kind }

    /// Derived rather than passed in. Two pieces of state set in one closure
    /// are two chances for the sheet to be built with the older of them, and
    /// this one decides both the button's verb and what the secret field says —
    /// it was showing "leave empty to keep the stored one" for a destination
    /// that had never been saved.
    private var isNew: Bool {
        !model.exportDestinations.contains { $0.id == destination.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: kind.symbol)
                            .font(.system(size: 20))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.accentColor.gradient,
                                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.displayName).font(.title3.bold())
                            Text(kind.explanation)
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                }

                Section(t("Name")) {
                    TextField("", text: $destination.name, prompt: Text(kind.displayName))
                    Text(t("Yours to recognise — “Accountant, quarterly” — especially with two of the same kind."))
                        .font(.caption).foregroundStyle(.secondary)
                }

                fields

                if kind.canRunAutomatically {
                    Section {
                        Toggle(t("Send new invoices here after every collection"),
                               isOn: $destination.runsAutomatically)
                        Text(t("Only documents that have not been sent here before. Nothing is sent twice unless you ask for it."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        Label(t("This one cannot run on its own: it opens a message you have to read and send."),
                              systemImage: "hand.raised")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(t("Cancel")) { dismiss() }
                Button(isNew ? t("Connect") : t("Save")) {
                    Task {
                        await model.saveDestination(destination, secret: secret)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isReady)
            }
            .padding()
        }
        .frame(width: 580, height: 560)
    }

    @ViewBuilder
    private var fields: some View {
        switch kind {
        case .folder:
            Section(t("Destination folder")) {
                pathRow(chooseDirectory: true,
                        message: t("Choose where to copy the PDFs."))
            }
        case .csv, .json:
            Section(t("Destination file")) {
                pathRow(chooseDirectory: false,
                        message: t("Choose where to write the register."))
                Text(t("The file is rewritten each run with every document of that export."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .webhook:
            Section(t("Webhook")) {
                TextField("https://…", text: binding("url"))
                SecureField(t("Authorization header (optional)"), text: $secret,
                            prompt: Text(t("Bearer …")))
                Text(secretHint).font(.caption).foregroundStyle(.secondary)
            }
        case .paperless:
            Section(t("Paperless-ngx")) {
                TextField("https://…", text: binding("url"))
                SecureField(t("API token"), text: $secret)
                Text(secretHint).font(.caption).foregroundStyle(.secondary)
                TextField(t("Tag identifiers (optional)"), text: binding("tags"),
                          prompt: Text(verbatim: "3, 7"))
                Text(t("Numeric tag ids from your Paperless instance, applied to every document."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .email:
            Section(t("E-mail")) {
                TextField(t("To (optional)"), text: binding("recipients"),
                          prompt: Text(verbatim: "comptable@example.com"))
                Label(t("Your mail application opens with the message ready. Invoices Retriever never sends anything itself."),
                      systemImage: "hand.raised")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var secretHint: String {
        isNew
            ? t("Stored in your keychain, never in the database.")
            : t("Leave empty to keep the one already stored.")
    }

    @ViewBuilder
    private func pathRow(chooseDirectory: Bool, message: String) -> some View {
        HStack {
            Text(destination.config["path"] ?? t("Not chosen"))
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle((destination.config["path"] ?? "").isEmpty ? .secondary : .primary)
            Spacer()
            Button(t("Choose…")) { choose(directory: chooseDirectory, message: message) }
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { destination.config[key] ?? "" },
                set: { destination.config[key] = $0 })
    }

    /// Complete enough to save. An existing destination whose secret is already
    /// in the keychain must not be blocked by an empty secret field.
    private var isReady: Bool {
        guard !destination.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let hasSecret = !secret.isEmpty || (!isNew && model.hasSecret(destination))
        return destination.isComplete(hasSecret: hasSecret)
    }

    private func choose(directory: Bool, message: String) {
        if directory {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.message = message
            if panel.runModal() == .OK, let url = panel.url {
                destination.config["path"] = url.path
            }
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = kind == .csv ? "register.csv" : "register.json"
            panel.message = message
            if panel.runModal() == .OK, let url = panel.url {
                destination.config["path"] = url.path
            }
        }
    }
}

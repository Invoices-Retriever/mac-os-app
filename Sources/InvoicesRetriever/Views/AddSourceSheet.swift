import SwiftUI
import IRCore

/// UC-01. Three things have to happen here and be obvious: the user says which
/// account this is, provides what the plugin declared it needs, and — before
/// any of that — sees plainly what the plugin will be allowed to do (F10.6).
struct AddSourceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let entry: PluginCatalog.Entry

    @State private var displayName = ""
    @State private var config: [String: String] = [:]
    @State private var secrets: [String: String] = [:]
    @State private var rememberCredentials = true
    @State private var requireBiometrics = false
    @State private var signInNow = true
    @State private var isWorking = false

    private var manifest: PluginManifest { entry.manifest }
    private var schema: [String: ConfigField] { manifest.configSchema ?? [:] }

    private var missingRequired: [String] {
        schema.filter { key, field in
            guard field.isRequired else { return false }
            if field.isSecret { return !rememberCredentials ? false : (secrets[key]?.isEmpty ?? true) }
            return config[key]?.isEmpty ?? true
        }.map(\.key).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name this source", text: $displayName,
                              prompt: Text(manifest.name))
                    Text("Give it a name you will recognise — “OVH — main account” — especially if you have several accounts with the same supplier.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("What this plugin can do") {
                    Label(entry.capabilitySummary, systemImage: "network.badge.shield.half.filled")
                        .font(.callout)
                    ForEach(entry.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }

                if !schema.isEmpty {
                    Section(manifest.name) {
                        ForEach(schema.keys.sorted(), id: \.self) { key in
                            if let field = schema[key] { row(key: key, field: field) }
                        }
                    }
                }

                Section("Credentials") {
                    Toggle("Remember them in my keychain", isOn: $rememberCredentials)
                    if rememberCredentials {
                        Toggle("Require Touch ID each time they are used", isOn: $requireBiometrics)
                            .disabled(!Keychain.biometricsAvailable())
                        Text("Credentials go to the macOS keychain, on this Mac only. They are never written to the database, the logs or a screenshot.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("You will sign in by hand in a browser window every time this source runs.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("Open the portal and sign in now", isOn: $signInNow)
                    Text("Signing in once stores the session, so later collections do not need your two-factor code again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if !missingRequired.isEmpty {
                    Text("Still needed: \(missingRequired.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button(signInNow ? "Add and sign in" : "Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!missingRequired.isEmpty || isWorking)
            }
            .padding()
        }
        .frame(width: 580, height: 640)
        .overlay {
            if isWorking {
                ProgressView("Opening \(manifest.name)…")
                    .padding(30)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder
    private func row(key: String, field: ConfigField) -> some View {
        switch field.type {
        case .password:
            SecureField(field.label, text: secretBinding(key))
        case .totp:
            VStack(alignment: .leading, spacing: 2) {
                SecureField(field.label, text: secretBinding(key))
                Text("Paste the secret shown when you set up two-factor authentication, or the whole otpauth:// link.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        case .boolean:
            Toggle(field.label, isOn: Binding(
                get: { config[key] == "true" },
                set: { config[key] = $0 ? "true" : "false" }))
        case .select:
            Picker(field.label, selection: configBinding(key)) {
                Text("—").tag("")
                ForEach(field.options ?? [], id: \.value) { Text($0.label).tag($0.value) }
            }
        default:
            TextField(field.label, text: configBinding(key),
                      prompt: field.placeholder.map(Text.init))
                .help(field.help ?? "")
        }
    }

    // Two separate bindings, deliberately. A single helper taking "which
    // dictionary" would be one refactor away from writing a password into
    // `config`, which is the one place it must never go — `config` is stored
    // in SQLite, `secrets` goes to the keychain.
    private func secretBinding(_ key: String) -> Binding<String> {
        Binding(get: { secrets[key] ?? "" }, set: { secrets[key] = $0 })
    }

    private func configBinding(_ key: String) -> Binding<String> {
        Binding(get: { config[key] ?? "" }, set: { config[key] = $0 })
    }

    private func add() {
        isWorking = true
        Task {
            let source = await model.addSource(
                plugin: manifest, displayName: displayName, config: config, secrets: secrets,
                rememberCredentials: rememberCredentials, requireBiometrics: requireBiometrics)
            if signInNow, let source {
                await model.authenticate(source)
            }
            isWorking = false
            dismiss()
        }
    }
}

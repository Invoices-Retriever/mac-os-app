import SwiftUI
import IRCore

struct EditSourceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Source
    @State private var scheduleKind: ScheduleKind
    @State private var scheduleHour: Int
    @State private var scheduleDay: Int
    @State private var newSecrets: [String: String] = [:]
    @State private var requireBiometrics = false

    private let manifest: PluginManifest?

    enum ScheduleKind: String, CaseIterable, Identifiable {
        case manual, daily, weekly, monthly
        var id: String { rawValue }
        var title: String {
            switch self {
            case .manual: return "Only when I ask"
            case .daily: return "Every day"
            case .weekly: return "Every week"
            case .monthly: return "Every month"
            }
        }
    }

    init(source: Source) {
        _draft = State(initialValue: source)
        self.manifest = nil
        switch source.schedule {
        case .manual:
            _scheduleKind = State(initialValue: .manual)
            _scheduleHour = State(initialValue: 9); _scheduleDay = State(initialValue: 5)
        case .daily(let hour):
            _scheduleKind = State(initialValue: .daily)
            _scheduleHour = State(initialValue: hour); _scheduleDay = State(initialValue: 5)
        case .weekly(let weekday, let hour):
            _scheduleKind = State(initialValue: .weekly)
            _scheduleHour = State(initialValue: hour); _scheduleDay = State(initialValue: weekday)
        case .monthly(let day, let hour):
            _scheduleKind = State(initialValue: .monthly)
            _scheduleHour = State(initialValue: hour); _scheduleDay = State(initialValue: day)
        }
    }

    private var pluginManifest: PluginManifest? {
        model.catalogEntries.first { $0.id == draft.pluginID }?.manifest
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Source") {
                    TextField("Name", text: $draft.displayName)
                    Toggle("Enabled", isOn: $draft.isEnabled)
                    LabeledContent("Plugin", value: "\(draft.pluginID) \(draft.pluginVersion)")
                }

                if let manifest = pluginManifest, let schema = manifest.configSchema, !schema.isEmpty {
                    Section("Settings") {
                        ForEach(schema.keys.sorted(), id: \.self) { key in
                            if let field = schema[key] {
                                configRow(key: key, field: field)
                            }
                        }
                    }
                }

                Section("Credentials") {
                    Toggle("Remember credentials in the keychain", isOn: $draft.rememberCredentials)
                    if draft.rememberCredentials {
                        Toggle("Ask for Touch ID each time they are used", isOn: $requireBiometrics)
                            .disabled(!Keychain.biometricsAvailable())
                    } else {
                        Text("You will be asked to sign in by hand on every run.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Schedule") {
                    Picker("Run", selection: $scheduleKind) {
                        ForEach(ScheduleKind.allCases) { Text($0.title).tag($0) }
                    }
                    if scheduleKind != .manual {
                        Stepper("At \(String(format: "%02d", scheduleHour)):00", value: $scheduleHour, in: 0...23)
                    }
                    if scheduleKind == .monthly {
                        Stepper("On day \(scheduleDay)", value: $scheduleDay, in: 1...28)
                    }
                    if scheduleKind != .manual && !model.preferences.schedulerEnabled {
                        Label("Scheduling is off in Settings, so nothing will run automatically yet.",
                              systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Collection window") {
                    Stepper("Look back \(draft.lookbackDays) days on the first run",
                            value: $draft.lookbackDays, in: 7...730, step: 7)
                    Text("After a successful run, only documents newer than the last success are fetched.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    draft.schedule = schedule
                    Task {
                        if !newSecrets.isEmpty {
                            await model.setSecrets(newSecrets, for: draft, requireBiometrics: requireBiometrics)
                        }
                        await model.update(draft)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 560, height: 620)
    }

    private var schedule: Schedule {
        switch scheduleKind {
        case .manual: return .manual
        case .daily: return .daily(hour: scheduleHour)
        case .weekly: return .weekly(weekday: min(scheduleDay, 7), hour: scheduleHour)
        case .monthly: return .monthly(day: scheduleDay, hour: scheduleHour)
        }
    }

    @ViewBuilder
    private func configRow(key: String, field: ConfigField) -> some View {
        if field.isSecret {
            SecureField(field.label, text: Binding(
                get: { newSecrets[key] ?? "" },
                set: { newSecrets[key] = $0 }))
                .help(field.help ?? "Stored in your keychain, never in the database.")
        } else {
            TextField(field.label, text: Binding(
                get: { draft.config[key] ?? "" },
                set: { draft.config[key] = $0 }))
                .help(field.help ?? "")
        }
    }
}

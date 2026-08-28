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
            case .manual: return t("Only when I ask")
            case .daily: return t("Every day")
            case .weekly: return t("Every week")
            case .monthly: return t("Every month")
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
                Section(t("Source")) {
                    TextField(t("Name"), text: $draft.displayName)
                    Toggle(t("Enabled"), isOn: $draft.isEnabled)
                    LabeledContent(t("Plugin"), value: "\(draft.pluginID) \(draft.pluginVersion)")
                }

                if let manifest = pluginManifest, let schema = manifest.configSchema, !schema.isEmpty {
                    Section(t("Settings")) {
                        ForEach(schema.keys.sorted(), id: \.self) { key in
                            if let field = schema[key] {
                                configRow(key: key, field: field)
                            }
                        }
                    }
                }

                Section(t("Credentials")) {
                    Toggle(t("Remember credentials in the keychain"), isOn: $draft.rememberCredentials)
                    if draft.rememberCredentials {
                        Toggle(t("Ask for Touch ID each time they are used"), isOn: $requireBiometrics)
                            .disabled(!Keychain.biometricsAvailable())
                    } else {
                        Text(t("You will be asked to sign in by hand on every run."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section(t("Schedule")) {
                    Picker(t("Run"), selection: $scheduleKind) {
                        ForEach(ScheduleKind.allCases) { Text($0.title).tag($0) }
                    }
                    if scheduleKind != .manual {
                        Stepper(t("At %@", String(format: "%02d:00", scheduleHour)), value: $scheduleHour, in: 0...23)
                    }
                    if scheduleKind == .monthly {
                        Stepper(t("On day %@", number(scheduleDay)), value: $scheduleDay, in: 1...28)
                    }
                    if scheduleKind != .manual && !model.preferences.schedulerEnabled {
                        Label(t("Scheduling is off in Settings, so nothing will run automatically yet."),
                              systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section(t("Collection window")) {
                    Stepper(tn("Look back %d days on the first run", draft.lookbackDays),
                            value: $draft.lookbackDays, in: 7...730, step: 7)
                    Text(t("After a successful run, only documents newer than the last success are fetched."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(t("Cancel")) { dismiss() }
                Button(t("Save")) {
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
                .help(field.help ?? t("Stored in your keychain, never in the database."))
        } else {
            TextField(field.label, text: Binding(
                get: { draft.config[key] ?? "" },
                set: { draft.config[key] = $0 }))
                .help(field.help ?? "")
        }
    }
}

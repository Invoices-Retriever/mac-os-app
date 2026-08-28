import SwiftUI
import IRCore

/// F10.5. The specification puts a number on this — a simple plugin in under
/// thirty minutes — so this screen has one job: shorten the loop between
/// editing a JSON file and knowing whether it works.
///
/// Point it at the folder where you are editing plugins, and every reload runs
/// the same validator the CI runs, with the same messages. The step-by-step
/// debugger lives in `irctl run --step`, because a terminal is where you
/// already are when you are writing JSON.
struct DeveloperView: View {
    @Environment(AppModel.self) private var model
    @State private var folders: [URL] = []
    @State private var reports: [(name: String, report: PluginValidator.Report)] = []
    @State private var selectedIssue: PluginValidator.Issue?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if reports.isEmpty {
                ContentUnavailableView {
                    Label(t("No local plugin folder"), systemImage: "hammer")
                } description: {
                    Text(t("Choose the folder where you are editing plugin JSON files. They are loaded ahead of the shipped versions, so you can iterate on an existing plugin without uninstalling anything."))
                } actions: {
                    Button(t("Choose a folder…")) { chooseFolder() }
                }
            } else {
                List {
                    ForEach(reports, id: \.name) { entry in
                        Section(entry.name) {
                            if entry.report.issues.isEmpty {
                                Label(t("No issues"), systemImage: "checkmark.circle")
                                    .foregroundStyle(.green)
                            }
                            ForEach(entry.report.issues.sorted(by: { $0.severity < $1.severity })) { issue in
                                IssueRow(issue: issue)
                            }
                            if entry.report.requiresHumanReview {
                                Label(t("Contains runJs, so CI cannot merge it alone — it needs a human reviewer."),
                                      systemImage: "person.badge.shield.checkmark")
                                    .font(.callout)
                                    .foregroundStyle(.purple)
                            }
                        }
                    }
                }
            }

            Divider()
            footer
        }
        .navigationTitle(t("Plugin developer"))
        .task { await refresh() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(t("Engine %@", PluginManifest.engineVersion.description))
                    .font(.callout)
                ForEach(folders, id: \.self) { url in
                    Text(url.path)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Button(t("Add folder…")) { chooseFolder() }
            Button(t("Reload")) { Task { await refresh() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        .padding()
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button(t("Copy the JSON Schema path")) {
                if let url = BundledResources.schemaURL {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
            }
            .help(t("Point your editor at this for autocompletion"))

            Text(t("Step through a plugin with:  irctl run my-plugin.json --step"))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal).padding(.vertical, 8)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = t("Choose the folder containing the plugin JSON files you are editing.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await model.addDeveloperFolder(url)
            await refresh()
        }
    }

    private func refresh() async {
        folders = await model.catalog.localDirectoryURLs
        var found: [(String, PluginValidator.Report)] = []

        for folder in folders {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for file in contents.filter({ $0.pathExtension.lowercased() == "json" }).sorted(by: { $0.path < $1.path }) {
                do {
                    let manifest = try PluginManifest.decode(from: Data(contentsOf: file))
                    var report = PluginValidator.validate(manifest)
                    if file.lastPathComponent != "\(manifest.id).json" {
                        report.issues.insert(.init(severity: .error, path: "filename",
                                                   message: "should be named \(manifest.id).json",
                                                   hint: t("The CI checks this so reviewers can find a plugin by its id.")),
                                             at: 0)
                    }
                    found.append((file.lastPathComponent, report))
                } catch {
                    found.append((file.lastPathComponent, PluginValidator.Report(
                        issues: [.init(severity: .error, path: "root",
                                       message: error.localizedDescription, hint: nil)],
                        requiresHumanReview: false)))
                }
            }
        }
        reports = found
        await model.reload()
    }
}

private struct IssueRow: View {
    let issue: PluginValidator.Issue

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(colour)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.message)
                Text(issue.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                if let hint = issue.hint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch issue.severity {
        case .error: return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }

    private var colour: Color {
        switch issue.severity {
        case .error: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
    }
}

import SwiftUI
import IRCore

/// F2.7 and F9.4. The journal, and the direct route from "something failed" to
/// "here is what the browser was looking at when it failed".
struct RunsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Run.ID?
    @State private var logs: [RedactingLogger.LogRecord] = []

    private var selected: Run? { model.recentRuns.first { $0.id == selection } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                PageHeader(title: t("History"),
                           subtitle: t("Every collection, and what it found.")) { }
                if model.recentRuns.isEmpty {
                    FirstStep(symbol: "clock.arrow.circlepath",
                              title: t("Nothing has run yet"),
                              message: t("Once you collect from a supplier, every attempt is recorded here — what it found, how long it took, and the log if it went wrong."))
                } else {
                    List(model.recentRuns, selection: $selection) { run in
                        RunRow(run: run,
                               manifest: model.manifest(forSourceID: run.sourceID),
                               sourceName: model.sourceNames[run.sourceID] ?? t("Removed source"))
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minWidth: 340)

            VStack(alignment: .leading, spacing: 0) {
                if let run = selected {
                    detail(run)
                } else if !model.liveLog.isEmpty {
                    liveLog
                } else {
                    Text(t("Select a run to read its log"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 420)
        }
        .navigationTitle("")
        .onChange(of: selection) { _, _ in loadLogs() }
    }

    @ViewBuilder
    private func detail(_ run: Run) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.sourceNames[run.sourceID] ?? t("Removed source")).font(.headline)
                Spacer()
                Text(run.status.displayName)
                    .font(.callout)
                    .foregroundStyle(run.status.countsAsSuccess ? .green : .orange)
            }
            HStack(spacing: 14) {
                Label(tn("%d new", run.documentsNew), systemImage: "doc.badge.plus")
                Label(tn("%d seen", run.documentsFound), systemImage: "doc")
                if let duration = run.duration {
                    Label(String(format: "%.1f s", duration), systemImage: "clock")
                }
                if run.attempt > 1 { Label(t("attempt %@", number(run.attempt)), systemImage: "arrow.clockwise") }
            }
            .font(.callout).foregroundStyle(.secondary)

            if let error = run.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            if run.screenshotPath != nil || run.outlinePath != nil {
                HStack {
                    if let path = run.screenshotPath {
                        Button(t("Open the failure screenshot")) {
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        }
                    }
                    if let path = run.outlinePath {
                        Button(t("Open the page structure")) {
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        }
                        .help(t("What the page was made of when it failed: tags, ids and classes, no text. This is what a selector is written against, and it is safe to attach to an issue."))
                    }
                    Text(t("Stored on this Mac. Nothing uploads it."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()
            logTable(logs)
        }
        .padding()
    }

    private var liveLog: some View {
        VStack(alignment: .leading) {
            Text(t("Live")).font(.headline)
            logTable(model.liveLog)
        }
        .padding()
    }

    private func logTable(_ records: [RedactingLogger.LogRecord]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(records) { record in
                    HStack(alignment: .top, spacing: 8) {
                        Text(record.timestamp.formatted(date: .omitted, time: .standard))
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                        Text(record.message)
                            .font(.caption.monospaced())
                            .foregroundStyle(colour(record.level))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func colour(_ level: RedactingLogger.Level) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func loadLogs() {
        guard let runID = selection else { logs = []; return }
        Task { logs = (try? await model.store.logs(runID: runID)) ?? [] }
    }
}

private struct RunRow: View {
    let run: Run
    let manifest: PluginManifest?
    let sourceName: String

    var body: some View {
        HStack(spacing: 10) {
            SupplierTile(manifest: manifest, fallbackName: sourceName, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(sourceName).font(.callout)
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if run.documentsNew > 0 {
                Text(verbatim: "+\(number(run.documentsNew))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.green)
            }
            Image(systemName: run.status.countsAsSuccess ? "checkmark.circle.fill"
                            : (run.status == .needsSignIn ? "person.badge.key.fill"
                                                          : "exclamationmark.circle.fill"))
                .foregroundStyle(run.status.countsAsSuccess ? Color.green
                               : (run.status == .needsSignIn ? .blue : .orange))
        }
        .padding(.vertical, 4)
    }
}

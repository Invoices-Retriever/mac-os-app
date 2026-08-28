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
            List(model.recentRuns, selection: $selection) { run in
                RunRow(run: run, sourceName: model.sourceNames[run.sourceID] ?? "removed source")
            }
            .frame(minWidth: 320)

            VStack(alignment: .leading, spacing: 0) {
                if let run = selected {
                    detail(run)
                } else if !model.liveLog.isEmpty {
                    liveLog
                } else {
                    Text("Select a run to read its log")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 420)
        }
        .navigationTitle("Runs")
        .onChange(of: selection) { _, _ in loadLogs() }
    }

    @ViewBuilder
    private func detail(_ run: Run) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.sourceNames[run.sourceID] ?? "Removed source").font(.headline)
                Spacer()
                Text(run.status.displayName)
                    .font(.callout)
                    .foregroundStyle(run.status.countsAsSuccess ? .green : .orange)
            }
            HStack(spacing: 14) {
                Label("\(run.documentsNew) new", systemImage: "doc.badge.plus")
                Label("\(run.documentsFound) seen", systemImage: "doc")
                if let duration = run.duration {
                    Label(String(format: "%.1f s", duration), systemImage: "clock")
                }
                if run.attempt > 1 { Label("attempt \(run.attempt)", systemImage: "arrow.clockwise") }
            }
            .font(.callout).foregroundStyle(.secondary)

            if let error = run.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            if let path = run.screenshotPath {
                HStack {
                    Button("Open the failure screenshot") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                    Text("Stored on this Mac. Nothing uploads it.")
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
            Text("Live").font(.headline)
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
    let sourceName: String

    var body: some View {
        HStack {
            Circle()
                .fill(run.status.countsAsSuccess ? Color.green :
                        (run.status == .needsSignIn ? .blue : .orange))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(sourceName).font(.callout)
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if run.documentsNew > 0 {
                Text("+\(run.documentsNew)").font(.caption.monospacedDigit()).foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }
}

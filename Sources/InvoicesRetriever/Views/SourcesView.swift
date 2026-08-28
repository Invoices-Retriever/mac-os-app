import SwiftUI
import IRCore

/// UC-02 and UC-03: what the user looks at on the 5th of the month.
struct SourcesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Source?
    @State private var deleting: Source?
    @State private var purgeCredentials = true

    var body: some View {
        VStack(spacing: 0) {
            if model.sources.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(model.sources) { source in
                        SourceRow(source: source, isRunning: model.runningSourceIDs.contains(source.id))
                            .contextMenu {
                                Button(t("Edit…")) { editing = source }
                                Button(t("Remove…"), role: .destructive) { deleting = source }
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(t("Sources"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.collectAll() }
                } label: {
                    Label(t("Collect everything"), systemImage: "arrow.down.circle")
                }
                .disabled(model.sources.filter(\.isEnabled).isEmpty || !model.runningSourceIDs.isEmpty)
            }
        }
        .sheet(item: $editing) { source in
            EditSourceSheet(source: source)
                .environment(model)
        }
        .confirmationDialog(
            t("Remove “%@”?", deleting?.displayName ?? ""),
            isPresented: Binding(get: { deleting != nil },
                                 set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { source in
            Button(t("Remove and delete stored credentials"), role: .destructive) {
                Task { await model.deleteSource(source, purgeCredentials: true) }
                deleting = nil
            }
            Button(t("Remove but keep credentials in the keychain")) {
                Task { await model.deleteSource(source, purgeCredentials: false) }
                deleting = nil
            }
            Button(t("Cancel"), role: .cancel) { deleting = nil }
        } message: { _ in
            Text(t("Documents already collected stay in your library. Nothing is deleted from the supplier's portal."))
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(t("No sources yet"), systemImage: "building.2")
        } description: {
            Text(t("Add a supplier from the catalogue to start collecting invoices automatically."))
        } actions: {
            Text(t("Everything stays on this Mac. Credentials go to your keychain, documents to a folder you choose."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
    }
}

private struct SourceRow: View {
    @Environment(AppModel.self) private var model
    let source: Source
    let isRunning: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            statusIcon
                .font(.title2)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(source.displayName).font(.headline)
                    if !source.isEnabled {
                        Text(t("disabled"))
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let error = source.lastErrorMessage, source.needsAttention {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }

            Spacer()

            Text(verbatim: number(source.documentCount))
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)
                .help(t("Documents collected from this source"))

            if isRunning {
                ProgressView().controlSize(.small)
                Button(t("Stop")) { Task { await model.cancel(source) } }
            } else {
                if source.lastRunStatus == .needsSignIn {
                    Button(t("Sign in")) { Task { await model.authenticate(source) } }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(t("Sign in")) { Task { await model.authenticate(source) } }
                }
                Button(t("Collect")) { Task { await model.collect(source) } }
                    .disabled(!source.isEnabled)
            }
        }
        .padding(.vertical, 6)
    }

    private var subtitle: String {
        var parts: [String] = [source.pluginID]
        if let last = source.lastRunAt {
            parts.append(t("last run %@", last.formatted(.relative(presentation: .named))))
        } else {
            parts.append(t("never run"))
        }
        parts.append(source.schedule.displayName.lowercased())
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch source.lastRunStatus {
        case .succeeded, .partial:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .needsSignIn:
            Image(systemName: "person.badge.key.fill").foregroundStyle(.blue)
        case .cancelled:
            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        case .running, .none:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }
}

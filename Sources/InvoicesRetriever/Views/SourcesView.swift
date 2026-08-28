import SwiftUI
import IRCore

/// UC-02 and UC-03: what the user looks at on the 5th of the month.
///
/// Built as cards rather than a table. A table is denser, and density is the
/// wrong thing to optimise for here: a person has five or ten suppliers, opens
/// this once a month, and needs to see at a glance which one wants something
/// from them. The logo does most of that work before any text is read.
struct SourcesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Source?
    @State private var deleting: Source?

    private var busy: Bool { !model.runningSourceIDs.isEmpty }

    private var needingAttention: [Source] {
        model.sources.filter { $0.needsAttention || $0.lastRunStatus == .needsSignIn }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.sources.isEmpty {
                FirstStep(symbol: "building.2",
                          title: t("No suppliers yet"),
                          message: t("Add a supplier and Invoices Retriever will fetch its invoices for you. Everything stays on this Mac: credentials in your keychain, documents in a folder you choose."),
                          actionTitle: t("Browse the catalogue")) {
                    model.selectedSection = .catalog
                }
            } else {
                PageHeader(title: t("Suppliers"),
                           subtitle: summary) {
                    Button {
                        Task { await model.collectAll() }
                    } label: {
                        Label(t("Collect everything"), systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.sources.filter(\.isEnabled).isEmpty || busy)
                }

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.sources) { source in
                            SourceCard(source: source,
                                       isRunning: model.runningSourceIDs.contains(source.id),
                                       edit: { editing = source },
                                       remove: { deleting = source })
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
        .navigationTitle("")
        .sheet(item: $editing) { source in
            EditSourceSheet(source: source).environment(model)
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

    /// One sentence about the whole screen, so the state of things is readable
    /// without counting rows.
    private var summary: String {
        if busy { return t("Collecting…") }
        let attention = needingAttention.count
        if attention > 0 {
            return tn("%d supplier needs you", attention)
        }
        // Two counted strings joined by a separator. Not a catalogue entry:
        // there is nothing to translate in "· ", and a format string that is
        // identical in every language is one more thing to keep in step.
        return "\(tn("%d supplier", model.sources.count)) · \(tn("%d document", model.documents.count))"
    }
}

// MARK: - One supplier

private struct SourceCard: View {
    @Environment(AppModel.self) private var model
    let source: Source
    let isRunning: Bool
    let edit: () -> Void
    let remove: () -> Void

    private var health: SourceHealth { .of(source, isRunning: isRunning) }
    private var manifest: PluginManifest? { model.manifest(for: source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                SupplierTile(manifest: manifest, fallbackName: source.displayName, size: 44)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(source.displayName).font(.headline)
                        if !source.isEnabled {
                            Pill(text: t("Paused"), colour: .secondary, symbol: "pause.fill")
                        }
                        if manifest?.isAPIOnly == true {
                            Pill(text: "API", colour: .green, symbol: "key.horizontal.fill")  // not prose
                        }
                    }
                    HStack(spacing: 6) {
                        Image(systemName: health.symbol)
                            .foregroundStyle(health.colour)
                            .font(.caption)
                        Text(statusLine)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(verbatim: number(source.documentCount))
                        .font(.title2.monospacedDigit().weight(.medium))
                    Text(tn("%d document", source.documentCount))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .help(t("Documents collected from this source"))

                actions
            }

            // The failure and the button that fixes it, together. Reading an
            // error in one place and hunting for the remedy in another is how
            // people give up on an application.
            if let error = source.lastErrorMessage, source.needsAttention, !isRunning {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 12)
            }
        }
        .card()
        .contextMenu {
            Button(t("Edit…"), action: edit)
            Button(t("Remove…"), role: .destructive, action: remove)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if isRunning {
            ProgressView().controlSize(.small)
            Button(t("Stop")) { Task { await model.cancel(source) } }
        } else {
            // Whichever action the source actually needs is the prominent one.
            // Everything else moves into the menu, so a card offers one obvious
            // thing to click rather than three of equal weight.
            if source.lastRunStatus == .needsSignIn {
                Button(signInLabel) { Task { await model.authenticate(source) } }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(t("Collect")) { Task { await model.collect(source) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!source.isEnabled)
            }

            Menu {
                if source.lastRunStatus == .needsSignIn {
                    Button(t("Collect")) { Task { await model.collect(source) } }
                        .disabled(!source.isEnabled)
                } else {
                    Button(signInLabel) { Task { await model.authenticate(source) } }
                }
                Divider()
                Button(t("Edit…"), action: edit)
                Button(t("Remove…"), role: .destructive, action: remove)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 18)
        }
    }

    private var signInLabel: String {
        model.isAPIOnly(source) ? t("Check credentials") : t("Sign in")
    }

    /// Plain language, and only what is true. "Never collected" is more use to
    /// a beginner than an empty date, and "Needs you to sign in" says what to
    /// do where "auth required" says what went wrong.
    private var statusLine: String {
        if isRunning { return t("Collecting…") }
        if !source.isEnabled { return t("Paused — it will not run on its own") }

        switch source.lastRunStatus {
        case .needsSignIn:
            return model.isAPIOnly(source)
                ? t("Waiting for you to check its credentials")
                : t("Waiting for you to sign in")
        case .failed:
            return t("Last attempt failed")
        case .none:
            return t("Never collected yet")
        default:
            guard let last = source.lastRunAt else { return t("Never collected yet") }
            return t("Up to date · collected %@",
                     last.formatted(.relative(presentation: .named)))
        }
    }
}

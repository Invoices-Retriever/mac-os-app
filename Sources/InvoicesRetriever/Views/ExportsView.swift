import SwiftUI
import IRCore

/// Where invoices go once they have been collected.
///
/// Built as connections you keep rather than a dialog you re-fill: the accountant's
/// folder, the Paperless instance, the webhook into the accounting package are
/// the same every month, and re-typing a URL each time is both tedious and the
/// place mistakes get made. A destination is configured once, shows how its last
/// run went, and can be left to run on its own after every collection.
struct ExportsView: View {
    @Environment(AppModel.self) private var model

    @State private var editing: ExportDestination?
    @State private var deleting: ExportDestination?

    private var connected: [ExportDestination] { model.exportDestinations }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if connected.isEmpty {
                    FirstStep(symbol: "arrow.up.forward.square",
                              title: t("Nothing is connected yet"),
                              message: t("Connect a destination and your invoices go there on their own after every collection — a folder for your accountant, a Paperless instance, or anything that accepts an HTTP POST."))
                        .frame(height: 240)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(t("Connected"), systemImage: "link")
                            .font(.headline).foregroundStyle(.secondary)
                        ForEach(connected) { destination in
                            ConnectedCard(destination: destination,
                                          edit: { editing = destination },
                                          remove: { deleting = destination })
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Label(t("Add a destination"), systemImage: "plus.circle")
                        .font(.headline).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                        ForEach(ExportDestinationKind.allCases, id: \.self) { kind in
                            AvailableCard(kind: kind) {
                                editing = ExportDestination(entityID: model.entity?.id ?? UUID(),
                                                            kind: kind,
                                                            name: kind.displayName)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            PageHeader(title: t("Exports"), subtitle: subtitle) {
                if !connected.isEmpty {
                    Button {
                        Task { await runAll() }
                    } label: {
                        Label(t("Run all"), systemImage: "arrow.up.forward.square.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.documents.isEmpty || !model.runningDestinationIDs.isEmpty)
                }
            }
            .background(.background)
        }
        .navigationTitle("")
        .sheet(item: $editing) { destination in
            EditDestinationSheet(destination: destination)
                .environment(model)
        }
        .confirmationDialog(
            t("Disconnect “%@”?", deleting?.name ?? ""),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { destination in
            Button(t("Disconnect"), role: .destructive) {
                Task { await model.deleteDestination(destination) }
                deleting = nil
            }
            Button(t("Cancel"), role: .cancel) { deleting = nil }
        } message: { _ in
            Text(t("Documents already sent stay where they are. Any token for this destination is deleted from your keychain."))
        }
    }

    private var subtitle: String {
        let automatic = connected.filter(\.runsAutomatically).count
        if connected.isEmpty {
            return t("Send collected invoices onwards, automatically or on demand.")
        }
        if automatic > 0 {
            // Two counted strings and a separator; nothing to translate in "· ".
            return "\(tn("%d destination", connected.count)) · \(tn("%d runs automatically", automatic))"
        }
        return tn("%d destination", connected.count)
    }

    private func runAll() async {
        for destination in connected where destination.isComplete(hasSecret: model.hasSecret(destination)) {
            await model.run(destination, documents: model.documents, announce: false)
        }
        model.alert = AppModel.AlertContent(
            title: t("Exports finished"),
            message: t("Every connected destination has been run for the documents in your library view."))
    }
}

// MARK: - A destination you have

private struct ConnectedCard: View {
    @Environment(AppModel.self) private var model
    let destination: ExportDestination
    let edit: () -> Void
    let remove: () -> Void

    private var isRunning: Bool { model.runningDestinationIDs.contains(destination.id) }
    private var isComplete: Bool { destination.isComplete(hasSecret: model.hasSecret(destination)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: destination.kind.symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.gradient,
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(destination.name).font(.headline)
                        if !isComplete {
                            Pill(text: t("Unfinished"), colour: .orange,
                                 symbol: "exclamationmark.circle.fill")
                        } else if destination.runsAutomatically {
                            Pill(text: t("Automatic"), colour: .green, symbol: "bolt.fill")
                        }
                    }
                    Text(statusLine).font(.callout).foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if destination.kind.canRunAutomatically {
                    Toggle("", isOn: Binding(
                        get: { destination.runsAutomatically },
                        set: { newValue in
                            var updated = destination
                            updated.runsAutomatically = newValue
                            Task { await model.saveDestination(updated, secret: nil) }
                        }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!isComplete)
                        .help(t("Send new invoices here after every collection"))
                }

                if isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Button(t("Run now")) {
                        Task { await model.run(destination, documents: model.documents) }
                    }
                    .disabled(!isComplete || model.documents.isEmpty)

                    Menu {
                        Button(t("Edit…"), action: edit)
                        Button(t("Send everything again")) {
                            Task {
                                await model.run(destination, documents: model.documents, force: true)
                            }
                        }
                        .disabled(!isComplete || model.documents.isEmpty)
                        Divider()
                        Button(t("Disconnect…"), role: .destructive, action: remove)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 18)
                }
            }

            if let detail = destination.lastDetail, destination.lastSucceeded == false {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(detail).font(.callout).fixedSize(horizontal: false, vertical: true)
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
            Button(t("Disconnect…"), role: .destructive, action: remove)
        }
    }

    private var statusLine: String {
        if isRunning { return t("Sending…") }
        if !isComplete { return t("Needs finishing before it can run") }
        guard let last = destination.lastRunAt else {
            return t("%1$@ · never run", target)
        }
        let when = last.formatted(.relative(presentation: .named))
        if destination.lastSucceeded == false {
            return t("%1$@ · failed %2$@", target, when)
        }
        return t("%1$@ · %2$@ sent · last run %3$@", target,
                 tn("%d document", destination.documentsSent), when)
    }

    /// Where this destination points, in the shortest form that still tells two
    /// of the same kind apart.
    private var target: String {
        switch destination.kind {
        case .folder, .csv, .json:
            let path = destination.config["path"] ?? ""
            return path.isEmpty ? destination.kind.displayName
                                : (path as NSString).lastPathComponent
        case .webhook, .paperless:
            return URL(string: destination.config["url"] ?? "")?.host ?? destination.kind.displayName
        case .email:
            let recipients = destination.config["recipients"] ?? ""
            return recipients.isEmpty ? destination.kind.displayName : recipients
        }
    }
}

// MARK: - A destination you could add

private struct AvailableCard: View {
    let kind: ExportDestinationKind
    let add: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: add) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 16))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 34, height: 34)
                        .background(Color.accentColor.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Text(kind.displayName).font(.headline)
                    Spacer(minLength: 0)
                    Image(systemName: "plus").foregroundStyle(.secondary)
                }
                Text(kind.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .card(highlighted: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

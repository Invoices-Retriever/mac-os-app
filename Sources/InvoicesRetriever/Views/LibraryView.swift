import SwiftUI
import QuickLook
import IRCore

/// UC-04, UC-05 and UC-08 in one screen: look at what was collected, fix what
/// the extractor got wrong, and send a period to the accountant.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: InvoiceDocument.ID?
    @State private var search = ""
    @State private var period: Period = .thisYear
    @State private var showingReviewOnly = false
    @State private var previewURL: URL?

    enum Period: String, CaseIterable, Identifiable {
        case thisMonth, lastMonth, thisQuarter, thisYear, everything
        var id: String { rawValue }

        var title: String {
            switch self {
            case .thisMonth: return t("This month")
            case .lastMonth: return t("Last month")
            case .thisQuarter: return t("This quarter")
            case .thisYear: return t("This year")
            case .everything: return t("Everything")
            }
        }

        var range: (Date?, Date?) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let now = Date()
            switch self {
            case .everything:
                return (nil, nil)
            case .thisMonth:
                let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now))
                return (start, now)
            case .lastMonth:
                let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
                let start = calendar.date(byAdding: .month, value: -1, to: thisMonth)
                return (start, calendar.date(byAdding: .day, value: -1, to: thisMonth))
            case .thisQuarter:
                let month = calendar.component(.month, from: now)
                let firstMonth = ((month - 1) / 3) * 3 + 1
                var components = calendar.dateComponents([.year], from: now)
                components.month = firstMonth
                components.day = 1
                return (calendar.date(from: components), now)
            case .thisYear:
                var components = calendar.dateComponents([.year], from: now)
                components.month = 1; components.day = 1
                return (calendar.date(from: components), now)
            }
        }
    }

    private var selected: InvoiceDocument? {
        model.documents.first { $0.id == selection }
    }

    private var total: Money? {
        let amounts = model.documents.compactMap(\.total)
        guard let currency = amounts.first?.currency,
              amounts.allSatisfy({ $0.currency == currency }) else { return nil }
        return Money(cents: amounts.reduce(0) { $0 + $1.cents }, currency: currency)
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                PageHeader(title: t("Invoices"), subtitle: summaryLine) {
                    // The destinations the user has already connected, one
                    // click each. Configuring one is a different job and lives
                    // on its own page rather than in a dialog re-filled every
                    // month.
                    Menu {
                        ForEach(model.exportDestinations) { destination in
                            Button(destination.name) {
                                Task { await model.run(destination, documents: model.documents) }
                            }
                            .disabled(!destination.isComplete(hasSecret: model.hasSecret(destination)))
                        }
                        if !model.exportDestinations.isEmpty { Divider() }
                        Button(t("Manage exports…")) { model.selectedSection = .exports }
                    } label: {
                        Label(t("Send to…"), systemImage: "square.and.arrow.up")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 128)
                    .disabled(model.documents.isEmpty)
                }
                filters
                Divider()
                if model.documents.isEmpty {
                    emptyState
                } else {
                    table
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if let selected {
                DocumentDetailView(document: selected, previewURL: $previewURL)
                    .frame(minWidth: 320, idealWidth: 380)
            } else if !model.documents.isEmpty {
                Text(t("Select a document"))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 320, maxHeight: .infinity)
            }
        }
        .navigationTitle("")
        .searchable(text: $search, prompt: t("Search issuer, number or text"))
        .onChange(of: search) { _, _ in applyFilter() }
        .onChange(of: period) { _, _ in applyFilter() }
        .onChange(of: showingReviewOnly) { _, _ in applyFilter() }
        .quickLookPreview($previewURL)
        .toolbar {
            ToolbarItem {
                Button { importFiles() } label: {
                    Label(t("Import PDFs…"), systemImage: "plus")
                }
            }
        }
    }

    private var filters: some View {
        HStack(spacing: 12) {
            Picker("", selection: $period) {
                ForEach(Period.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 150)

            Toggle(t("Needs a look"), isOn: $showingReviewOnly)
                .toggleStyle(.checkbox)
                .help(t("Documents where a field was guessed rather than declared by the plugin"))

            Spacer()
            Button(t("Rescan folder")) { Task { await model.rescanLibrary() } }
                .help(t("Rebuild the index from the files on disk"))
        }
        .padding(.horizontal, 20).padding(.bottom, 10)
    }

    private var table: some View {
        Table(model.documents, selection: $selection) {
            TableColumn(t("Date")) { document in
                Text(document.issuedOn.map { $0.formatted(date: .numeric, time: .omitted) } ?? "—")
                    .foregroundStyle(document.issuedOn == nil ? .secondary : .primary)
            }
            .width(90)

            TableColumn(t("Issuer")) { document in
                HStack(spacing: 6) {
                    SupplierTile(manifest: model.manifest(forSourceID: document.sourceID),
                                 fallbackName: document.issuer ?? "",
                                 size: 18)
                    Text(document.issuer ?? "—")
                    if document.needsReview {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.orange)
                            .help(t("Some fields were guessed. Check and confirm them."))
                    }
                    if document.verifiedByHuman {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .help(t("Checked by you"))
                    }
                }
            }

            TableColumn(t("Number")) { Text($0.number ?? "—") }

            TableColumn(t("Total")) { document in
                Text(document.total?.formatted() ?? "—")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(110)

            TableColumn(t("Kind")) { Text($0.kind.displayName).foregroundStyle(.secondary) }
                .width(90)
        }
        .tableStyle(.inset)
    }

    /// The count and, when every document shares a currency, what they add up
    /// to — which is the number someone actually came here for.
    private var summaryLine: String {
        let count = tn("%d document", model.documents.count)
        guard let total else { return count }
        return "\(count) · \(total.formatted())"
    }

    /// Two different nothings, and telling them apart is the whole point: an
    /// empty library needs a first step, an empty filter needs the filter
    /// widened.
    @ViewBuilder
    private var emptyState: some View {
        if isFiltered {
            FirstStep(symbol: "line.3.horizontal.decrease.circle",
                      title: t("Nothing matches"),
                      message: t("No document matches this period or search. Try “Everything”, or clear the search field."),
                      actionTitle: t("Show everything")) {
                period = .everything
                search = ""
                showingReviewOnly = false
            }
        } else {
            FirstStep(symbol: "doc.text",
                      title: t("No invoices yet"),
                      message: t("Collected invoices land here, filed into your library folder. You can also drop in PDFs you already have."),
                      actionTitle: t("Import PDFs…"),
                      action: importFiles)
        }
    }

    /// A filter is only "the reason you see nothing" when there is something
    /// to filter. With an empty library, widening the period would find the
    /// same nothing, and offering it would send the user in a circle.
    private var isFiltered: Bool {
        model.totalDocumentCount > 0
    }

    private func applyFilter() {
        var filter = model.documentFilter
        filter.searchText = search.nilIfEmpty
        (filter.issuedFrom, filter.issuedTo) = period.range
        filter.needingReviewOnly = showingReviewOnly
        model.documentFilter = filter
        Task { await model.reloadDocuments() }
    }

    private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf]
        panel.message = t("Choose PDFs to add to your library.")
        guard panel.runModal() == .OK else { return }
        Task { await model.importFiles(panel.urls) }
    }
}

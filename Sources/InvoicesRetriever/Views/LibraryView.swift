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
    @State private var exporting = false

    enum Period: String, CaseIterable, Identifiable {
        case thisMonth, lastMonth, thisQuarter, thisYear, everything
        var id: String { rawValue }

        var title: String {
            switch self {
            case .thisMonth: return "This month"
            case .lastMonth: return "Last month"
            case .thisQuarter: return "This quarter"
            case .thisYear: return "This year"
            case .everything: return "Everything"
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
                filters
                Divider()
                table
                Divider()
                summary
            }
            .frame(minWidth: 520)

            if let selected {
                DocumentDetailView(document: selected, previewURL: $previewURL)
                    .frame(minWidth: 320, idealWidth: 380)
            } else {
                Text("Select a document")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 320)
            }
        }
        .navigationTitle("Library")
        .searchable(text: $search, prompt: "Search issuer, number or text")
        .onChange(of: search) { _, _ in applyFilter() }
        .onChange(of: period) { _, _ in applyFilter() }
        .onChange(of: showingReviewOnly) { _, _ in applyFilter() }
        .quickLookPreview($previewURL)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { exporting = true } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .disabled(model.documents.isEmpty)
            }
            ToolbarItem {
                Button { importFiles() } label: {
                    Label("Import PDFs…", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $exporting) {
            ExportSheet(documents: model.documents).environment(model)
        }
    }

    private var filters: some View {
        HStack(spacing: 12) {
            Picker("", selection: $period) {
                ForEach(Period.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 150)

            Toggle("Needs a look", isOn: $showingReviewOnly)
                .toggleStyle(.checkbox)
                .help("Documents where a field was guessed rather than declared by the plugin")

            Spacer()
            Button("Rescan folder") { Task { await model.rescanLibrary() } }
                .help("Rebuild the index from the files on disk")
        }
        .padding(.horizontal).padding(.vertical, 8)
    }

    private var table: some View {
        Table(model.documents, selection: $selection) {
            TableColumn("Date") { document in
                Text(document.issuedOn.map { $0.formatted(date: .numeric, time: .omitted) } ?? "—")
                    .foregroundStyle(document.issuedOn == nil ? .secondary : .primary)
            }
            .width(90)

            TableColumn("Issuer") { document in
                HStack(spacing: 5) {
                    Text(document.issuer ?? "—")
                    if document.needsReview {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.orange)
                            .help("Some fields were guessed. Check and confirm them.")
                    }
                    if document.verifiedByHuman {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .help("Checked by you")
                    }
                }
            }

            TableColumn("Number") { Text($0.number ?? "—") }

            TableColumn("Total") { document in
                Text(document.total?.formatted() ?? "—")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(110)

            TableColumn("Kind") { Text($0.kind.displayName).foregroundStyle(.secondary) }
                .width(90)
        }
        .tableStyle(.inset)
    }

    private var summary: some View {
        HStack {
            Text("\(model.documents.count) document(s)")
            if let total {
                Text("· total \(total.formatted())").monospacedDigit()
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal).padding(.vertical, 6)
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
        panel.message = "Choose PDFs to add to your library."
        guard panel.runModal() == .OK else { return }
        Task { await model.importFiles(panel.urls) }
    }
}

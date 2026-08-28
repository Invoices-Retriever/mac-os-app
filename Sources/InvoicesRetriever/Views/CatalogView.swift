import SwiftUI
import UniformTypeIdentifiers
import IRCore

/// F1.1 and UC-01. The catalogue is where the project's editorial bet is
/// visible: browsing by country is a first-class control, because "does it
/// cover my French suppliers" is the question that decides whether someone
/// uses this at all.
struct CatalogView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var country: String?
    @State private var adding: PluginCatalog.Entry?
    @State private var isImporting = false

    private var entries: [PluginCatalog.Entry] {
        model.catalogEntries.filter { entry in
            let manifest = entry.manifest
            if manifest.effectiveStatus == .archived { return false }
            if let country, !(manifest.country ?? []).contains(country) { return false }
            let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
            guard !needle.isEmpty else { return true }
            return manifest.name.lowercased().contains(needle)
                || manifest.id.contains(needle)
                || (manifest.description ?? "").lowercased().contains(needle)
                || (manifest.tags ?? []).contains { $0.contains(needle) }
        }
    }

    private var countries: [String] {
        Array(Set(model.catalogEntries.flatMap { $0.manifest.country ?? [] })).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: t("Catalogue"),
                       subtitle: t("Pick a supplier and Invoices Retriever learns how to fetch its invoices.")) {
                Button {
                    Task { await model.refreshCatalogue() }
                } label: {
                    Label(t("Refresh"), systemImage: "arrow.triangle.2.circlepath")
                }
                .controlSize(.large)
                .disabled(model.isRefreshingCatalogue)
                .help(t("Download the latest plugins from the project's signed index. Nothing is installed unless the signature checks out."))
            }

            HStack {
                Picker(t("Country"), selection: $country) {
                    Text(t("Everywhere")).tag(String?.none)
                    ForEach(countries, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .pickerStyle(.menu)
                .frame(width: 190)

                Spacer()

                Text(tn("%d plugins", entries.count))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.bottom, 10)

            if entries.isEmpty {
                ContentUnavailableView {
                    Label(model.catalogEntries.isEmpty ? t("No plugins installed") : t("No plugin matches"),
                          systemImage: model.catalogEntries.isEmpty ? "square.grid.2x2" : "magnifyingglass")
                } description: {
                    Text(model.catalogEntries.isEmpty
                         ? t("Use “Refresh from the index” to download the published catalogue. Your supplier may not be covered yet — writing a plugin is a single JSON file, see the Plugin developer tab.")
                         : t("Your supplier may not be covered yet. Writing a plugin is a single JSON file — see the Plugin developer tab."))
                } actions: {
                    if model.catalogEntries.isEmpty {
                        Button(t("Refresh from the index")) {
                            Task { await model.refreshCatalogue() }
                        }
                        .disabled(model.isRefreshingCatalogue)
                    }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 268), spacing: 14)], spacing: 14) {
                        ForEach(entries) { entry in
                            CatalogCard(entry: entry) { adding = entry }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
        .searchable(text: $search, prompt: t("Search suppliers"))
        .navigationTitle("")
        .toolbar {
            ToolbarItem {
                Button {
                    isImporting = true
                } label: {
                    Label(t("Install a plugin file…"), systemImage: "square.and.arrow.down")
                }
                .help(t("Install a plugin that is not in the official index. You will be told what it can do."))
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result {
                Task { await model.installPlugin(from: url) }
            }
        }
        .sheet(item: $adding) { entry in
            AddSourceSheet(entry: entry).environment(model)
        }
    }
}

private struct CatalogCard: View {
    let entry: PluginCatalog.Entry
    let add: () -> Void

    @State private var hovering = false

    private var manifest: PluginManifest { entry.manifest }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                SupplierTile(manifest: manifest, size: 48)

                VStack(alignment: .leading, spacing: 2) {
                    Text(manifest.name)
                        .font(.headline)
                        .lineLimit(1)
                    if let countries = manifest.country, !countries.isEmpty {
                        Text(countries.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            Text(manifest.description ?? t("No description."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)

            HStack(spacing: 6) {
                ForEach(badges, id: \.text) { badge in
                    Pill(text: badge.text, colour: badge.colour, symbol: badge.symbol)
                }
                Spacer(minLength: 0)
            }

            Button(action: add) {
                Text(t("Add"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .card(highlighted: hovering)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// Only the things that change a decision. A plugin that is official,
    /// tested and browser-driven is the unremarkable case and gets no badge —
    /// if every card carries three, none of them is read.
    private var badges: [(text: String, colour: Color, symbol: String)] {
        var out: [(String, Color, String)] = []
        // Two entries for the same supplier are common now — one driving the
        // portal, one calling the API — and this is the difference that decides
        // which one someone wants.
        if manifest.isAPIOnly {
            out.append((t("No browser"), .green, "key.horizontal.fill"))
        }
        switch manifest.effectiveStatus {
        case .unverified: out.append((t("Not tested"), .orange, "questionmark.circle.fill"))
        case .degraded: out.append((t("Degraded"), .red, "exclamationmark.triangle.fill"))
        default: break
        }
        // F10.8: derived from the steps, not from what the manifest claims.
        if manifest.containsArbitraryJavaScript {
            out.append((t("Runs JavaScript"), .purple, "curlybraces"))
        }
        switch entry.provenance {
        case .local: out.append((t("Local copy"), .blue, "hammer.fill"))
        case .sideloaded: out.append((t("Unofficial"), .orange, "questionmark.circle.fill"))
        default: break
        }
        return out.map { (text: $0.0, colour: $0.1, symbol: $0.2) }
    }
}

struct Badge: View {
    let text: String
    let colour: Color
    var symbol: String?

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let symbol { Image(systemName: symbol) }
        }
        .font(.caption2)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(colour.opacity(0.15), in: Capsule())
        .foregroundStyle(colour)
    }
}

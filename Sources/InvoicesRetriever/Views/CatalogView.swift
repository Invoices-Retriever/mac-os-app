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
            .padding(.horizontal).padding(.vertical, 8)

            Divider()

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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                        ForEach(entries) { entry in
                            CatalogCard(entry: entry) { adding = entry }
                        }
                    }
                    .padding()
                }
            }
        }
        .searchable(text: $search, prompt: t("Search suppliers"))
        .navigationTitle(t("Catalogue"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refreshCatalogue() }
                } label: {
                    Label(t("Refresh from the index"), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(model.isRefreshingCatalogue)
                .help(t("Download the latest plugins from the project's signed index. Nothing is installed unless the signature checks out."))
            }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.manifest.name).font(.headline)
                Spacer()
                ForEach(entry.manifest.country ?? [], id: \.self) { code in
                    Text(code)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
            }

            Text(entry.manifest.description ?? "No description.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if entry.manifest.effectiveStatus == .degraded {
                    Badge(text: "Degraded", colour: .orange, symbol: "exclamationmark.triangle")
                }
                // F10.8: the badge is derived from the steps, not from what the
                // manifest claims about itself.
                if entry.manifest.containsArbitraryJavaScript {
                    Badge(text: "Runs JavaScript", colour: .purple, symbol: "curlybraces")
                }
                if entry.provenance == .local {
                    Badge(text: "Local copy", colour: .blue, symbol: "hammer")
                } else if entry.provenance == .sideloaded {
                    Badge(text: "Unofficial", colour: .orange, symbol: "questionmark.circle")
                }
                Spacer()
                Button(t("Add"), action: add)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
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

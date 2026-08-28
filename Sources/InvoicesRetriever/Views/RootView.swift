import SwiftUI
import IRCore

/// What the sidebar can be pointing at.
///
/// A place, or one particular supplier. Suppliers are in the sidebar because
/// they are the thing a person actually comes here about: seeing at a glance
/// which one wants something is worth more than a list of five nouns, and the
/// logos make that legible without reading.
enum SidebarItem: Hashable {
    case place(RootSection)
    case source(UUID)
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(LogoStore.self) private var logos

    /// Optional, because that is what a `List` selection binding is. A
    /// non-optional one silently never updates. What it points at lives in the
    /// model rather than here, so an empty screen can send the user to the one
    /// that fixes it — "Browse the catalogue" from an empty supplier list is
    /// the whole first-run path.
    private var selection: Binding<SidebarItem?> {
        Binding(
            get: {
                if let focused = model.focusedSourceID { return .source(focused) }
                return .place(model.selectedSection)
            },
            set: { item in
                switch item {
                case .place(let section):
                    model.selectedSection = section
                    model.focusedSourceID = nil
                case .source(let id):
                    // A supplier is not a seventh place; it is the supplier
                    // list, scrolled to one of them.
                    model.selectedSection = .sources
                    model.focusedSourceID = id
                case nil:
                    break
                }
            })
    }

    /// The places above the suppliers. Settings and the plugin developer sit in
    /// the footer instead: one is not somewhere you go often, and the other is
    /// not for most people at all.
    private static let places: [RootSection] = [.sources, .library, .exports, .catalog, .runs]

    var body: some View {
        NavigationSplitView {
            sidebar
                // Wide enough for "Développement de plugins", which is what the
                // longest English label becomes in French.
                .navigationSplitViewColumnWidth(min: 236, ideal: 248)
        } detail: {
            Group {
                switch model.selectedSection {
                case .sources: SourcesView()
                case .library: LibraryView()
                case .exports: ExportsView()
                case .catalog: CatalogView()
                case .runs: RunsView()
                case .developer: DeveloperView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Logos are fetched for the whole catalogue at once, keyed on it, so
        // the requests are identical for every user and say nothing about which
        // suppliers this one has. See LogoStore.
        .task(id: model.catalogEntries.count) {
            logos.isEnabled = model.preferences.showSupplierLogos
            await logos.prefetch(model.catalogueLogoDomains)
            logos.persist()
        }
        .overlay {
            if model.isLoading {
                ProgressView(t("Opening your library…"))
                    .padding(40)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Rows carry a tag and the selection drives the detail column. Not
            // NavigationLink: inside a split view that pushes onto a navigation
            // stack the detail column does not read, so the sidebar highlights
            // nothing and clicking changes nothing.
            List(selection: selection) {
                Section(t("General")) {
                    ForEach(Self.places, id: \.self) { section in
                        Label(section.title, systemImage: section.symbol)
                            .badge(badge(for: section))
                            .tag(SidebarItem.place(section))
                    }
                }

                if !model.sources.isEmpty {
                    Section {
                        ForEach(model.sources) { source in
                            SidebarSupplier(source: source,
                                            isRunning: model.runningSourceIDs.contains(source.id))
                                .tag(SidebarItem.source(source.id))
                        }
                    } header: {
                        HStack(spacing: 4) {
                            Text(t("Your suppliers"))
                            Text(verbatim: "(\(number(model.sources.count)))")
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Button {
                                model.selectedSection = .catalog
                                model.focusedSourceID = nil
                            } label: {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.plain)
                            .help(t("Add a supplier from the catalogue"))
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            footer
        }
    }

    /// The two places that are not part of the daily loop, kept out of it. A
    /// person who has never written a plugin should not be reading "Plugin
    /// developer" every time they look for their invoices.
    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 2) {
                ForEach([RootSection.developer, .settings], id: \.self) { section in
                    Button {
                        model.selectedSection = section
                        model.focusedSourceID = nil
                    } label: {
                        Label(section.title, systemImage: section.symbol)
                            .font(.callout)
                            .foregroundStyle(model.selectedSection == section
                                             ? Color.accentColor : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    /// Only counts that mean "you need to do something" get a badge. A badge
    /// showing how many documents exist would be noise.
    private func badge(for section: RootSection) -> Int {
        switch section {
        case .sources: return model.sources.filter(\.needsAttention).count
        case .library: return model.documents.filter(\.needsReview).count
        default: return 0
        }
    }
}

// MARK: - One supplier in the sidebar

private struct SidebarSupplier: View {
    @Environment(AppModel.self) private var model
    let source: Source
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 8) {
            SupplierTile(manifest: model.manifest(for: source),
                         fallbackName: source.displayName, size: 20)
            Text(source.displayName)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            // A dot rather than a word: the sidebar is for noticing, and the
            // supplier list one click away is for reading.
            if isRunning {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 10, height: 10)
            } else {
                let health = SourceHealth.of(source, isRunning: false)
                if health != .ready {
                    Circle()
                        .fill(health.colour)
                        .frame(width: 7, height: 7)
                        .help(source.lastErrorMessage ?? "")
                }
            }
        }
    }
}

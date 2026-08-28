import SwiftUI
import IRCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(LogoStore.self) private var logos
    /// Optional, because that is what a `List` selection binding is. A
    /// non-optional one silently never updates. The chosen section lives in
    /// the model rather than here, so an empty screen can send the user to the
    /// one that fixes it — "Browse the catalogue" from an empty supplier list
    /// is the whole first-run path.
    private var selection: Binding<RootSection?> {
        Binding(get: { model.selectedSection },
                set: { model.selectedSection = $0 ?? .sources })
    }

    var body: some View {
        NavigationSplitView {
            // Rows carry a tag and the selection drives the detail column. Not
            // NavigationLink: inside a split view that pushes onto a navigation
            // stack the detail column does not read, so the sidebar highlights
            // nothing and clicking changes nothing.
            List(RootSection.allCases, selection: selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .badge(badge(for: section))
                    .tag(section)
            }
            // Wide enough for "Développement de plugins", which is what the
            // longest English label becomes in French.
            .navigationSplitViewColumnWidth(min: 232, ideal: 240)
            .listStyle(.sidebar)
        } detail: {
            Group {
                switch model.selectedSection {
                case .sources: SourcesView()
                case .library: LibraryView()
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

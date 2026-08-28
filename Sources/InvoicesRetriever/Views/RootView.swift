import SwiftUI
import IRCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    /// Optional, because that is what a `List` selection binding is. A
    /// non-optional one silently never updates.
    @State private var selection: Section? = .sources

    enum Section: String, CaseIterable, Identifiable {
        case sources, library, catalog, runs, developer
        var id: String { rawValue }

        var title: String {
            switch self {
            case .sources: return t("Sources")
            case .library: return t("Library")
            case .catalog: return t("Catalogue")
            case .runs: return t("Runs")
            case .developer: return t("Plugin developer")
            }
        }

        var symbol: String {
            switch self {
            case .sources: return "building.2"
            case .library: return "tray.full"
            case .catalog: return "square.grid.2x2"
            case .runs: return "clock.arrow.circlepath"
            case .developer: return "hammer"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            // Rows carry a tag and the selection drives the detail column. Not
            // NavigationLink: inside a split view that pushes onto a navigation
            // stack the detail column does not read, so the sidebar highlights
            // nothing and clicking changes nothing.
            List(Section.allCases, selection: $selection) { section in
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
                switch selection ?? .sources {
                case .sources: SourcesView()
                case .library: LibraryView()
                case .catalog: CatalogView()
                case .runs: RunsView()
                case .developer: DeveloperView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    private func badge(for section: Section) -> Int {
        switch section {
        case .sources: return model.sources.filter(\.needsAttention).count
        case .library: return model.documents.filter(\.needsReview).count
        default: return 0
        }
    }
}

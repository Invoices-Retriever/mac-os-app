import SwiftUI
import IRCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Section = .sources

    enum Section: String, CaseIterable, Identifiable {
        case sources, library, catalog, runs, developer
        var id: String { rawValue }

        var title: String {
            switch self {
            case .sources: return "Sources"
            case .library: return "Library"
            case .catalog: return "Catalogue"
            case .runs: return "Runs"
            case .developer: return "Plugin developer"
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
            List(selection: $selection) {
                ForEach(Section.allCases) { section in
                    NavigationLink(value: section) {
                        Label(section.title, systemImage: section.symbol)
                            .badge(badge(for: section))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .listStyle(.sidebar)
        } detail: {
            Group {
                switch selection {
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
                ProgressView("Opening your library…")
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

import SwiftUI

/// The application's top-level places.
enum RootSection: String, CaseIterable, Identifiable {
    case sources, library, catalog, runs, developer
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sources: return t("Suppliers")
        case .library: return t("Invoices")
        case .catalog: return t("Catalogue")
        case .runs: return t("History")
        case .developer: return t("Plugin developer")
        }
    }

    var symbol: String {
        switch self {
        case .sources: return "building.2"
        case .library: return "doc.text"
        case .catalog: return "square.grid.2x2"
        case .runs: return "clock.arrow.circlepath"
        case .developer: return "hammer"
        }
    }
}

import SwiftUI

/// The application's top-level places.
enum RootSection: String, CaseIterable, Identifiable {
    case sources, library, exports, catalog, runs, developer, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sources: return t("Suppliers")
        case .library: return t("Invoices")
        case .exports: return t("Exports")
        case .catalog: return t("Catalogue")
        case .runs: return t("History")
        case .developer: return t("Plugin developer")
        case .settings: return t("Settings")
        }
    }

    var symbol: String {
        switch self {
        case .sources: return "building.2"
        case .library: return "doc.text"
        case .exports: return "arrow.up.forward.square"
        case .catalog: return "square.grid.2x2"
        case .runs: return "clock.arrow.circlepath"
        case .developer: return "hammer"
        case .settings: return "gearshape"
        }
    }
}

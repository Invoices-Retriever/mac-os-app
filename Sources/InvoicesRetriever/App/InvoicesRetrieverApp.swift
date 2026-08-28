import SwiftUI
import IRCore

@main
struct InvoicesRetrieverApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                // Strings are resolved when a view body runs, not by SwiftUI's
                // own LocalizedStringKey machinery, so changing language has to
                // rebuild the tree rather than merely invalidate it.
                .id(model.languageRevision)
                .frame(minWidth: 1040, minHeight: 640)
                .task { await model.start() }
                .alert(item: Binding(
                    get: { model.alert },
                    set: { model.alert = $0 }
                )) { content in
                    Alert(title: Text(content.title),
                          message: Text(content.message),
                          dismissButton: .default(Text(t("OK"))))
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu(t("Collection")) {
                Button(t(t("Collect from every source"))) {
                    Task { await model.collectAll() }
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button(t(t("Rescan the library folder"))) {
                    Task { await model.rescanLibrary() }
                }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .id(model.languageRevision)
                .frame(width: 640, height: 560)
        }
    }
}

/// A `Binding` over an optional, so `alert(item:)` can clear it.
private extension Binding where Value == AppModel.AlertContent? {
    init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        self.init(get: get, set: { newValue, _ in set(newValue) })
    }
}

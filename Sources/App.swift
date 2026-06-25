import SwiftUI
import AppKit

@main
struct SessionExplorerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        // Keep the standard title-bar window so full-screen (⌘⌃F) and the zoom
        // button work; hide just the title TEXT (empty title + hidden visibility)
        // so no "Session Explorer" label shows but the toolbar still fills the bar.
        WindowGroup("Session Explorer") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 600)
                .background(WindowChrome(title: model.selectedMeta.map { AutoTitle.displayTitle($0) } ?? "Session Explorer"))
                .onAppear { model.load() }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

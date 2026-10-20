import SwiftUI
import AppKit

/// Keeps the process alive without a window when the login agent is on (so the
/// ⌃⌥Space palette keeps working), and starts hidden when launchd started it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let backgroundEnv = "SESSION_EXPLORER_BACKGROUND"

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment[Self.backgroundEnv] == "1" else { return }
        // SwiftUI opens the WindowGroup window right after launch; close it so
        // a login-time start doesn't pop a window in the user's face.
        DispatchQueue.main.async {
            NSApp.windows.filter { !($0 is NSPanel) }.forEach { $0.close() }
            NSApp.hide(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !LoginAgent.isEnabled
    }
}

@main
struct SessionExplorerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
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

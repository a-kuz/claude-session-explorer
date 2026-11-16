import SwiftUI
import AppKit

/// Keeps the process alive without a window when the login agent is on (so the
/// ⌃⌥Space palette keeps working), and starts in the background when the login
/// agent started it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let backgroundEnv = "SESSION_EXPLORER_BACKGROUND"
    @MainActor static let model = AppModel()

    /// A background start while the app is already open (the login agent
    /// fires when its toggle is turned on) leaves; the open app stays resident.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment[Self.backgroundEnv] == "1",
              let id = Bundle.main.bundleIdentifier else { return }
        let me = NSRunningApplication.current.processIdentifier
        if NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains(where: { $0.processIdentifier != me }) {
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { Self.model.load() }
        AgentSignature.reregisterIfRebuilt(
            LoginAgent.wanted ? [LoginAgent.service, BackupService.service] : [BackupService.service])
        guard ProcessInfo.processInfo.environment[Self.backgroundEnv] == "1" else { return }
        // SwiftUI opens the WindowGroup window right after launch; close it so
        // a login-time start doesn't pop a window in the user's face.
        DispatchQueue.main.async { Self.goToBackground() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !LoginAgent.isEnabled
    }

    /// With the login agent on, Quit (⌘Q, Dock) only closes the windows and
    /// drops the Dock icon: the process stays for the ⌃⌥Space palette. Logout,
    /// restart and shutdown quit for real.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard LoginAgent.isEnabled, !Self.sessionIsEnding() else { return .terminateNow }
        Self.goToBackground()
        return .terminateCancel
    }

    /// A window of the explorer came up again (Dock/Finder reopen, palette
    /// jump): the app gets its Dock icon back.
    /// Also tracks whether any explorer window is open, for the background
    /// sync rate.
    func applicationDidUpdate(_ notification: Notification) {
        let windowOpen = NSApp.windows.contains { !($0 is NSPanel) && $0.isVisible && $0.canBecomeMain }
        if windowOpen, NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        MainActor.assumeIsolated {
            if Self.model.inBackground == windowOpen { Self.model.inBackground = !windowOpen }
        }
    }

    private static func goToBackground() {
        NSApp.windows.filter { !($0 is NSPanel) }.forEach { $0.close() }
        NSApp.setActivationPolicy(.accessory)
    }

    /// The quit request carries a reason only when the user session ends.
    private static func sessionIsEnding() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication else { return false }
        return event.attributeDescriptor(forKeyword: kAEQuitReason) != nil
    }
}

@main
struct SessionExplorerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppDelegate.model

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

import Foundation
import ServiceManagement

/// The login-time LaunchAgent bundled at `Contents/Library/LaunchAgents`.
/// launchd starts the app hidden (`SESSION_EXPLORER_BACKGROUND=1`); the app
/// then stays resident without a window so the palette hotkey keeps working.
enum LoginAgent {
    private static let plist = "ai.enface.SessionExplorer.agent.plist"
    private static var service: SMAppService { .agent(plistName: plist) }

    static var isEnabled: Bool { service.status == .enabled }

    /// Returns the resulting state (registration can be refused by the system,
    /// e.g. until the user approves it in Login Items).
    @discardableResult
    static func set(enabled: Bool) -> Bool {
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            NSLog("LoginAgent: \(enabled ? "register" : "unregister") failed: \(error)")
        }
        if enabled, service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        return isEnabled
    }
}

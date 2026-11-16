import Foundation
import ServiceManagement

/// The login-time LaunchAgent bundled at `Contents/Library/LaunchAgents`. It
/// runs `session-launcher`, which opens the app hidden
/// (`SESSION_EXPLORER_BACKGROUND=1`); the app then stays resident without a
/// window so the palette hotkey keeps working.
enum LoginAgent {
    private static let plist = "ai.enface.SessionExplorer.agent.plist"
    static var service: SMAppService { .agent(plistName: plist) }

    static var isEnabled: Bool { service.status == .enabled }

    /// The user's choice, kept apart from the service status: a rebuilt app
    /// invalidates the registration, and the choice says to register again.
    static var wanted: Bool {
        get { UserDefaults.standard.bool(forKey: "loginAgent.wanted") }
        set { UserDefaults.standard.set(newValue, forKey: "loginAgent.wanted") }
    }

    /// Returns the resulting state (registration can be refused by the system,
    /// e.g. until the user approves it in Login Items).
    @discardableResult
    static func set(enabled: Bool) -> Bool {
        wanted = enabled
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

import Foundation
import ServiceManagement

/// The launchd agent that runs `session-backup` (the iCloud backup pass) every
/// 10 minutes, bundled at `Contents/Library/LaunchAgents`.
enum BackupService {
    private static let plist = "ai.enface.SessionExplorer.backup.plist"
    static var service: SMAppService { .agent(plistName: plist) }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SessionExplorer/backup.log")
    }

    static var isEnabled: Bool { service.status == .enabled }

    /// Register the agent if it isn't yet; returns whether it is enabled.
    @discardableResult
    static func ensureRegistered() -> Bool {
        if isEnabled { return true }
        do { try service.register() } catch {
            NSLog("BackupService: register failed: \(error)")
        }
        return isEnabled
    }
}

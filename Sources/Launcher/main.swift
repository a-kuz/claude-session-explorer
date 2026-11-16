// `session-launcher`: started by the login agent (ai.enface.SessionExplorer.agent),
// opens Session Explorer hidden through LaunchServices and exits. launchd
// refuses the app's own executable as an agent program ("Launch Constraint
// Violation"); an app opened by LaunchServices is not subject to that.

import AppKit

// launchd passes a relative argv[0] ("Contents/MacOS/session-launcher").
guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath(), exe.path.hasPrefix("/") else { exit(1) }
let app = exe
    .deletingLastPathComponent()   // MacOS
    .deletingLastPathComponent()   // Contents
    .deletingLastPathComponent()   // SessionExplorer.app

let config = NSWorkspace.OpenConfiguration()
config.activates = false
config.hides = true
config.addsToRecentItems = false
config.environment = ["SESSION_EXPLORER_BACKGROUND": "1"]

guard app.pathExtension == "app" else {
    FileHandle.standardError.write(Data("session-launcher: not inside an app bundle: \(exe.path)\n".utf8))
    exit(1)
}

let done = DispatchSemaphore(value: 0)
NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in
    if let error { FileHandle.standardError.write(Data("session-launcher: \(error)\n".utf8)) }
    done.signal()
}
_ = done.wait(timeout: .now() + 30)

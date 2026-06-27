// Open a selected Claude Code session in Ghostty.
//
// Ghostty exposes a real AppleScript dictionary (1.3+): we can enumerate
// terminal surfaces (each has a `working directory` and a `title` — the title
// reads "✳ Claude Code" while Claude runs), `focus` one, and create a new tab
// or window from a `surface configuration` that runs a `command` in an
// `initial working directory`. That lets us:
//   1. Jump to an already-open session's terminal instead of spawning a new one.
//   2. Launch `claude --resume <id>` natively, independent of keyboard layout.

import AppKit
import Foundation

struct OpenResult {
    let ok: Bool
    let message: String
}

/// Terminal that hosts the resumed `claude` session.
enum TerminalApp: String, CaseIterable, Identifiable {
    case ghostty
    case terminal
    case iterm

    var id: String { rawValue }

    /// Application name as AppleScript / `tell application` expects it.
    var appName: String {
        switch self {
        case .ghostty: return "Ghostty"
        case .terminal: return "Terminal"
        case .iterm: return "iTerm"
        }
    }

    var label: String {
        switch self {
        case .ghostty: return "Ghostty"
        case .terminal: return "Terminal.app"
        case .iterm: return "iTerm2"
        }
    }
}

enum OpenSession {
    private static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escape a string for an AppleScript double-quoted literal.
    private static func asEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Absolute path to the `claude` binary, resolved once via the user's login
    /// shell. Ghostty launches commands with `/bin/bash --noprofile --norc`, which
    /// never reads the user's profiles — so the PATH that holds `claude` (often
    /// `~/.local/bin`) is absent and a bare `claude` resolves to nothing. We look
    /// it up in a login+interactive shell (which DOES source the profiles) and use
    /// the absolute path in the launch command. Falls back to bare `claude`.
    private static let resolvedClaudePath: String = {
        let proc = Process()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-ilc", "command -v claude"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return "claude" }
        proc.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (proc.terminationStatus == 0 && out.hasPrefix("/")) ? out : "claude"
    }()

    /// User-configured absolute path to `claude` (Settings). Empty → auto-resolve.
    static var claudePathOverride: String = ""

    private static var claudePath: String {
        let o = claudePathOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return o.isEmpty ? resolvedClaudePath : o
    }

    /// Terminal chosen in Settings; drives which app `openInTerminal` drives.
    static var terminal: TerminalApp = .ghostty

    /// Env prefix forcing Claude Code to persist the resumed session to jsonl.
    /// When a `claude` is started in the context of an active Claude Code session
    /// it can mark itself a child (CLAUDE_CODE_CHILD_SESSION) and SKIP writing its
    /// session to disk — clearing the inherited env doesn't help, since the CLI
    /// learns the parent context from its daemon, not the spawning shell's env.
    /// CLAUDE_CODE_FORCE_SESSION_PERSISTENCE disables that suppression outright, so
    /// the resumed session is always saved regardless of how SessionManager itself
    /// was launched.
    private static let envPrefix = "env CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 "

    /// The user's login shell, e.g. `/bin/zsh`. Falls back to zsh.
    private static var loginShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Wrap a resume command so it runs inside the user's LOGIN+INTERACTIVE shell.
    /// Ghostty (and `do script` in Terminal/iTerm) executes a supplied `command`
    /// via a bare, profile-less shell — `.zprofile`/`.zshrc` are never sourced, so
    /// PATH augmentations and shell-function tooling (nvm, cargo env, pyenv shims)
    /// are absent and the resumed `claude` "can't run anything". Re-running the
    /// command through `$SHELL -ilc` sources those profiles first, then `exec`s
    /// claude — identical to opening a tab by hand.
    ///
    /// `leadingExec` controls whether the wrapper itself starts with `exec`.
    /// Terminal/iTerm receive this as a line typed into a shell, so `exec $SHELL …`
    /// is right (it replaces that shell). Ghostty instead runs `command:` as
    /// `login -fp … /bin/bash -c exec -l <command>` — it already prepends its own
    /// `exec -l`, so a leading `exec` here yields `exec -l exec '/bin/zsh' …`, where
    /// bash reads the second `exec` as exec's program argument → "exec: not found"
    /// and the window dies instantly. For Ghostty the command must start with the
    /// shell binary, not `exec`.
    private static func wrapInLoginShell(_ inner: String, leadingExec: Bool = true) -> String {
        "\(leadingExec ? "exec " : "")\(shq(loginShell)) -ilc \(shq("exec " + inner))"
    }

    /// cd into the project, then resume the exact session — inside a login shell.
    static func buildResumeCommand(_ meta: SessionMeta) -> String {
        wrapInLoginShell("cd \(shq(meta.projectPath)) && \(envPrefix)\(shq(claudePath)) --resume \(shq(meta.id))")
    }

    @discardableResult
    static func setClipboard(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.setString(text, forType: .string)
    }

    private static func runOsascript(_ script: String) -> (out: String, code: Int32, err: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do { try proc.run() } catch { return ("", -1, error.localizedDescription) }
        proc.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (out.trimmingCharacters(in: .whitespacesAndNewlines), proc.terminationStatus, err)
    }

    /// Open the session in Ghostty: focus the terminal already running it, or
    /// launch a fresh tab/window. Never throws.
    ///
    /// Matching a live session: while Claude Code runs, Ghostty's terminal title
    /// is the session's title (e.g. "✳ Add animation…") — Claude pushes it
    /// via OSC. So we match the terminal whose title CONTAINS the session title;
    /// `working directory` is an unreliable fallback (it tracks the shell's cwd,
    /// which stays at $HOME while `claude` runs as the foreground command).
    @discardableResult
    static func openInTerminal(_ meta: SessionMeta, displayTitle: String) -> OpenResult {
        switch terminal {
        case .ghostty: return openInGhostty(meta, displayTitle: displayTitle)
        case .terminal: return openInAppleTerminal(meta)
        case .iterm: return openInITerm(meta)
        }
    }

    @discardableResult
    private static func openInGhostty(_ meta: SessionMeta, displayTitle: String) -> OpenResult {
        let wd = asEscape(meta.projectPath)
        let cmd = asEscape(wrapInLoginShell("\(envPrefix)\(shq(claudePath)) --resume \(shq(meta.id))", leadingExec: false))
        let title = asEscape(displayTitle)

        let script = """
        tell application "Ghostty"
          activate
          set targetTitle to "\(title)"
          set targetWD to "\(wd)"
          -- 1) Focus a terminal already running this session (match by title).
          try
            repeat with t in terminals
              set nm to ""
              try
                set nm to name of t
              end try
              if (targetTitle is not "") and (nm contains targetTitle) then
                focus t
                return "focused"
              end if
            end repeat
          end try
          -- 2) No live session — launch it. New tab in the front window, else a
          --    new window.
          set cfg to {command:"\(cmd)", initial working directory:targetWD}
          try
            set w to front window
            new tab in w with configuration cfg
            return "newtab"
          on error
            new window with configuration cfg
            return "newwindow"
          end try
        end tell
        """

        let result = runOsascript(script)
        if result.code == 0 {
            let how: String
            switch result.out {
            case "focused": how = "switched to open session"
            case "newwindow": how = "new window"
            default: how = "new tab"
            }
            return OpenResult(ok: true, message: "Ghostty: \(how) — \(meta.id.prefix(8))")
        }
        let hint = result.err.range(of: "not allowed|assistive|accessibility|-1743|-1728",
                                    options: .regularExpression) != nil
            ? " — grant Automation access for Ghostty: System Settings → Privacy → Automation"
            : ""
        let detail = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
        return OpenResult(ok: false, message: "Ghostty returned an error\(hint): \(detail.isEmpty ? "\(result.code)" : detail)")
    }

    /// Terminal.app and iTerm have no Ghostty-style surface API; we just `do script`
    /// the resume command in a fresh tab/window. No live-session focus matching.
    @discardableResult
    private static func openInAppleTerminal(_ meta: SessionMeta) -> OpenResult {
        let cmd = asEscape(buildResumeCommand(meta))
        let script = """
        tell application "Terminal"
          activate
          do script "\(cmd)"
        end tell
        """
        return runTerminalScript(script, app: "Terminal", meta: meta)
    }

    @discardableResult
    private static func openInITerm(_ meta: SessionMeta) -> OpenResult {
        let cmd = asEscape(buildResumeCommand(meta))
        let script = """
        tell application "iTerm"
          activate
          set w to (create window with default profile)
          tell current session of w to write text "\(cmd)"
        end tell
        """
        return runTerminalScript(script, app: "iTerm", meta: meta)
    }

    private static func runTerminalScript(_ script: String, app: String, meta: SessionMeta) -> OpenResult {
        let result = runOsascript(script)
        if result.code == 0 {
            return OpenResult(ok: true, message: "\(app): new session — \(meta.id.prefix(8))")
        }
        let hint = result.err.range(of: "not allowed|assistive|accessibility|-1743|-1728",
                                    options: .regularExpression) != nil
            ? " — grant Automation access for \(app): System Settings → Privacy → Automation"
            : ""
        let detail = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
        return OpenResult(ok: false, message: "\(app) returned an error\(hint): \(detail.isEmpty ? "\(result.code)" : detail)")
    }

    @discardableResult
    static func copyResumeCommand(_ meta: SessionMeta) -> OpenResult {
        setClipboard(buildResumeCommand(meta))
            ? OpenResult(ok: true, message: "Resume command copied to clipboard")
            : OpenResult(ok: false, message: "clipboard is unavailable")
    }

    static func revealInFinder(_ meta: SessionMeta) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: meta.filePath)])
    }
}

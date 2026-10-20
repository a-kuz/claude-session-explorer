import Foundation

/// A running Claude Code process, as registered in `~/.claude/sessions/<pid>.json`.
/// The CLI writes one file per process and updates `status`/`name` while it runs;
/// files of crashed processes stay behind, so liveness is checked by pid.
struct LiveSession: Identifiable, Hashable {
    var id: Int { pid }
    let pid: Int
    let sessionId: String
    let cwd: String
    /// Peer name the CLI derives from the cwd (`pure-15`), or a user-set one.
    let name: String
    /// `busy` | `idle` | `waiting` | `shell`.
    let status: String
    /// What a `waiting` session waits for (`approve Bash`, `input needed`, …).
    let waitingFor: String?
    let kind: String
    let startedAt: Date
    let updatedAt: Date

    /// Ordering for the palette: sessions that need a human first.
    var statusRank: Int {
        switch status {
        case "waiting": return 0
        case "busy": return 1
        case "shell": return 2
        default: return 3
        }
    }
}

enum LiveSessions {
    static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
    }

    /// Reads the registry and keeps only processes that are still alive.
    /// Several processes can share one `sessionId` (the same session resumed
    /// twice); all of them are returned, the caller decides how to fold.
    static func scan() -> [LiveSession] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [LiveSession] = []
        for name in names where name.hasSuffix(".json") {
            guard Int(name.dropLast(5)) != nil,
                  let data = fm.contents(atPath: dir.appendingPathComponent(name).path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = obj["pid"] as? Int,
                  let sid = obj["sessionId"] as? String,
                  isAlive(pid) else { continue }
            let ms = { (k: String) -> Date in
                Date(timeIntervalSince1970: ((obj[k] as? Double) ?? 0) / 1000)
            }
            out.append(LiveSession(
                pid: pid,
                sessionId: sid,
                cwd: obj["cwd"] as? String ?? "",
                name: obj["name"] as? String ?? "",
                status: obj["status"] as? String ?? "idle",
                waitingFor: obj["waitingFor"] as? String,
                kind: obj["kind"] as? String ?? "interactive",
                startedAt: ms("startedAt"),
                updatedAt: ms("updatedAt")))
        }
        return out
    }

    /// One entry per session id: the most recently updated process wins.
    static func bySession(_ list: [LiveSession]) -> [String: LiveSession] {
        var map: [String: LiveSession] = [:]
        for s in list {
            if let cur = map[s.sessionId], cur.updatedAt >= s.updatedAt { continue }
            map[s.sessionId] = s
        }
        return map
    }

    private static func isAlive(_ pid: Int) -> Bool {
        kill(pid_t(pid), 0) == 0 || errno == EPERM
    }
}

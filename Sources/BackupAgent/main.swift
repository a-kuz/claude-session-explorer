// `session-backup`: one iCloud backup pass of the Claude Code session files,
// run by launchd every 10 minutes (ai.enface.SessionExplorer.backup.plist),
// independent of the app. Appends a line per pass to `BackupService.logURL`.

import Foundation

let started = Date()
let s = Archive.backupPass(sweep: true)
let line = String(format: "%@ archived=%d (%.1f MB) pruned=%d evicted=%d failed=%d %.1fs\n",
                  ISO8601DateFormatter().string(from: started), s.archived,
                  Double(s.archivedBytes) / 1_048_576, s.pruned, s.evicted, s.failed,
                  Date().timeIntervalSince(started))
let log = BackupService.logURL
try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
if let fh = try? FileHandle(forWritingTo: log) {
    _ = try? fh.seekToEnd()
    try? fh.write(contentsOf: Data(line.utf8))
    try? fh.close()
} else {
    try? Data(line.utf8).write(to: log)
}

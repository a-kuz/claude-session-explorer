// gzip compress/decompress of session jsonl files via /usr/bin/gzip.
// The app is unsandboxed and gzip ships with macOS, so a child process is the
// zero-dependency route (Compression.framework speaks raw deflate, not the
// gzip container). Both calls block until the process exits — run off-main.

import Foundation

enum Gzip {
    /// Compress `src` into `dst` (`gzip -9 -c src > dst`). Returns false on any
    /// process or I/O failure; a partial `dst` is removed.
    static func compress(file src: String, to dst: URL) -> Bool {
        run(arguments: ["-9", "-c", src], writingTo: dst)
    }

    /// Decompress a `.gz` file into `dst` (`gzip -d -c src > dst`).
    static func decompress(file src: String, to dst: URL) -> Bool {
        run(arguments: ["-d", "-c", src], writingTo: dst)
    }

    private static func run(arguments: [String], writingTo dst: URL) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: dst.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        guard fm.createFile(atPath: dst.path, contents: nil),
              let out = try? FileHandle(forWritingTo: dst) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        p.arguments = arguments
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            try? out.close()
            try? fm.removeItem(at: dst)
            return false
        }
        p.waitUntilExit()
        try? out.close()
        if p.terminationStatus != 0 {
            try? fm.removeItem(at: dst)
            return false
        }
        return true
    }
}

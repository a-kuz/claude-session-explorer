// Backup of session files to iCloud Drive, so sessions survive the CLI's
// `cleanupPeriodDays` deletion of old transcripts from ~/.claude/projects.
//
// Layout: `<iCloud Drive>/Claude Sessions/<encoded-cwd>/<id>.jsonl.xz`, plus
// `<encoded-cwd>/<id>/…/<file>.xz` for the session's subagent transcripts and
// tool-result files — a mirror of the projects dir with every file compressed
// (LZMA, the xz container). An archive's mtime is set to the source file's
// mtime: equal mtimes mean the copy is current.
//
// The local path stays the session's identity (`SessionMeta.filePath`); when
// that file is gone, readers fall back to its archive (`JSONLBytes.read`).

import Foundation

enum Archive {
    static let root: URL? = {
        let docs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: docs.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return docs.appendingPathComponent("Claude Sessions", isDirectory: true)
    }()

    /// A file is backed up once it has not been written for this long, so a
    /// live session isn't recompressed on every turn.
    static let quietPeriod: TimeInterval = 10 * 60

    /// A session untouched for this long is removed from the projects dir once
    /// its archive is current and uploaded. Shorter than the CLI's own cleanup
    /// (`cleanupPeriodDays`, default 30), which deletes without a backup.
    static let localRetention: TimeInterval = 14 * 24 * 3600

    private static let ext = "xz"

    /// Archive location of a file under the projects dir, or nil when iCloud
    /// Drive is unavailable or the path is outside the projects dir.
    static func archiveURL(forLocal path: String) -> URL? {
        guard let root else { return nil }
        let base = Loader.projectsDir.path + "/"
        guard path.hasPrefix(base) else { return nil }
        return root.appendingPathComponent(String(path.dropFirst(base.count)) + "." + ext)
    }

    /// Local path a file under the archive root mirrors.
    private static func localPath(forArchive url: URL) -> String? {
        guard let root else { return nil }
        let base = root.path + "/"
        let p = url.path
        guard p.hasPrefix(base), p.hasSuffix("." + ext) else { return nil }
        return Loader.projectsDir.path + "/" + String(p.dropFirst(base.count).dropLast(ext.count + 1))
    }

    static func exists(forLocal path: String) -> Bool {
        guard let url = archiveURL(forLocal: path) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// The source file's mtime as recorded on its archive.
    static func sourceMtime(forLocal path: String) -> Date? {
        guard let url = archiveURL(forLocal: path) else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Decompressed contents of the archive of `path`. Reading an evicted
    /// iCloud file blocks until it is downloaded.
    static func read(forLocal path: String) -> Data? {
        guard let url = archiveURL(forLocal: path),
              let packed = try? Data(contentsOf: url) else { return nil }
        return try? (packed as NSData).decompressed(using: .lzma) as Data
    }

    /// Local paths of every archived session jsonl (`<encoded-cwd>/<id>.jsonl`).
    static func archivedSessionPaths() -> [String] {
        guard let root else { return [] }
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var out: [String] = []
        for dir in dirs {
            let dirURL = root.appendingPathComponent(dir, isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(atPath: dirURL.path) else { continue }
            for f in files where f.hasSuffix(".jsonl." + ext) {
                if let p = localPath(forArchive: dirURL.appendingPathComponent(f)) { out.append(p) }
            }
        }
        return out
    }

    // MARK: - Restore

    /// Put an archived session back under the projects dir: the jsonl and the
    /// files of its `<id>/` dir that are missing locally. The restored files get
    /// the current mtime — the CLI deletes transcripts by mtime, and a restored
    /// file with its old date would be removed at the next `claude` start.
    @discardableResult
    static func restore(forLocal path: String) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { return true }
        guard let data = read(forLocal: path) else { return false }
        guard write(data, to: path) else { return false }

        let sessionDir = (path as NSString).deletingPathExtension
        if let dirURL = archiveURL(forLocal: sessionDir).map({ $0.deletingPathExtension() }),
           let walker = fm.enumerator(at: dirURL, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in walker where url.pathExtension == ext {
                guard let local = localPath(forArchive: url), !fm.fileExists(atPath: local),
                      let packed = try? Data(contentsOf: url),
                      let body = try? (packed as NSData).decompressed(using: .lzma) as Data else { continue }
                _ = write(body, to: local)
            }
        }
        return true
    }

    private static func write(_ data: Data, to path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Run `body` with a readable path to the session jsonl: the local file,
    /// or a temporary decompressed copy of its archive.
    static func withReadablePath<T>(_ path: String, _ body: (String) -> T) -> T? {
        if FileManager.default.fileExists(atPath: path) { return body(path) }
        guard let data = read(forLocal: path) else { return nil }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("se-archive-\(UUID().uuidString)-" + (path as NSString).lastPathComponent)
        guard (try? data.write(to: tmp)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: tmp) }
        return body(tmp.path)
    }

    // MARK: - Backup

    /// Archives evicted after upload; tried again on later passes until the
    /// upload has finished.
    private static var pendingEviction: Set<URL> = []
    private static let lock = NSLock()

    /// One backup pass: compress every session file that is quiet and differs
    /// from its archive, delete local files past `localRetention`, then evict
    /// uploaded archives from the local disk.
    /// With `sweep`, every downloaded archive is a candidate for eviction (an
    /// archived session read by the app gets downloaded and stays otherwise).
    /// Blocking; run off the main thread, one pass at a time.
    static func backupPass(sweep: Bool) {
        guard let root else { return }
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let now = Date()

        for path in sessionFiles() {
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date,
                  now.timeIntervalSince(mtime) >= quietPeriod,
                  let dst = archiveURL(forLocal: path) else { continue }
            if let have = (try? fm.attributesOfItem(atPath: dst.path))?[.modificationDate] as? Date,
               abs(have.timeIntervalSince(mtime)) < 0.001 { continue }
            if compress(path, to: dst, mtime: mtime) { pendingEviction.insert(dst) }
        }

        pruneLocal(olderThan: now.addingTimeInterval(-localRetention))

        if sweep {
            let keys: [URLResourceKey] = [.ubiquitousItemDownloadingStatusKey]
            if let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys) {
                for case let url as URL in walker where url.pathExtension == ext {
                    let status = (try? url.resourceValues(forKeys: Set(keys)))?.ubiquitousItemDownloadingStatus
                    if status != .notDownloaded { pendingEviction.insert(url) }
                }
            }
        }
        evictUploaded()
    }

    /// Delete local session files last written before `cutoff` whose archives
    /// are current and uploaded. The jsonl goes only when every file of its
    /// `<id>/` dir went too, so a restore brings the whole session back.
    private static func pruneLocal(olderThan cutoff: Date) {
        let fm = FileManager.default
        func safelyArchived(_ path: String) -> Bool {
            guard let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  mtime < cutoff,
                  let dst = archiveURL(forLocal: path),
                  let have = (try? fm.attributesOfItem(atPath: dst.path))?[.modificationDate] as? Date,
                  abs(have.timeIntervalSince(mtime)) < 0.001,
                  (try? dst.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey]))?.ubiquitousItemIsUploaded == true
            else { return false }
            return true
        }
        for jsonl in Loader.listSessionFiles() where safelyArchived(jsonl) {
            let dir = (jsonl as NSString).deletingPathExtension
            var complete = true
            if let walker = fm.enumerator(at: URL(fileURLWithPath: dir, isDirectory: true),
                                          includingPropertiesForKeys: [.isRegularFileKey]) {
                for case let url as URL in walker
                where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                    if safelyArchived(url.path) { try? fm.removeItem(at: url) } else { complete = false }
                }
            }
            guard complete else { continue }
            try? fm.removeItem(atPath: dir)
            try? fm.removeItem(atPath: jsonl)
        }
    }

    /// Session jsonl files plus the regular files under each session's `<id>/`
    /// dir (subagents, tool results). Other dirs inside a project dir are not
    /// session data.
    private static func sessionFiles() -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for jsonl in Loader.listSessionFiles() {
            out.append(jsonl)
            let dir = (jsonl as NSString).deletingPathExtension
            guard let walker = fm.enumerator(at: URL(fileURLWithPath: dir, isDirectory: true),
                                             includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let url as URL in walker
            where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                out.append(url.path)
            }
        }
        return out
    }

    /// Compress into a temporary file outside iCloud Drive, then move it into
    /// place, so iCloud never uploads a half-written archive.
    private static func compress(_ src: String, to dst: URL, mtime: Date) -> Bool {
        let fm = FileManager.default
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: src)),
              let packed = try? (raw as NSData).compressed(using: .lzma) as Data else { return false }
        let tmp = Store.storeURL.deletingLastPathComponent()
            .appendingPathComponent("archive-tmp", isDirectory: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let staged = tmp.appendingPathComponent(UUID().uuidString)
        guard (try? packed.write(to: staged)) != nil else { return false }
        try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: staged.path)
        try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            if fm.fileExists(atPath: dst.path) {
                _ = try fm.replaceItemAt(dst, withItemAt: staged)
            } else {
                try fm.moveItem(at: staged, to: dst)
            }
        } catch {
            try? fm.removeItem(at: staged)
            NSLog("Archive: \(src) → \(dst.path) failed: \(error)")
            return false
        }
        try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: dst.path)
        return true
    }

    /// Free the local copy of every pending archive that iCloud has uploaded.
    private static func evictUploaded() {
        let keys: Set<URLResourceKey> = [.ubiquitousItemIsUploadedKey, .ubiquitousItemDownloadingStatusKey]
        for url in pendingEviction {
            guard let v = try? url.resourceValues(forKeys: keys) else {
                pendingEviction.remove(url); continue
            }
            if v.ubiquitousItemDownloadingStatus == .notDownloaded { pendingEviction.remove(url); continue }
            guard v.ubiquitousItemIsUploaded == true else { continue }
            if (try? FileManager.default.evictUbiquitousItem(at: url)) != nil {
                pendingEviction.remove(url)
            }
        }
    }
}

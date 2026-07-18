// Scanning the Claude config's projects/ dir and parsing session jsonl files.

import Foundation
import AppKit

enum Loader {
    /// `<config>/projects`, where `<config>` is `$CLAUDE_CONFIG_DIR` if set
    /// (matching the official CLI), otherwise `~/.claude`.
    static let projectsDir: URL = {
        let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespaces)
        let config = (env?.isEmpty == false)
            ? URL(fileURLWithPath: (env! as NSString).expandingTildeInPath)
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return config.appendingPathComponent("projects")
    }()

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        // jsonl timestamps are a fixed UTC ISO form: "2026-06-11T18:26:18.915Z".
        // ISO8601DateFormatter is comparatively slow (it dominated parseDate in the
        // profile, and we call it per message). Parse the fixed layout arithmetically
        // and only fall back to the formatters for anything that doesn't fit.
        if let d = fastISO8601UTC(s) { return d }
        return iso.date(from: s) ?? isoNoFrac.date(from: s)
    }

    /// Days from the Unix epoch (1970-01-01) to the start of `year` (UTC).
    private static func daysFromEpoch(toStartOf year: Int) -> Int {
        // Count leap years strictly before `year` since year 1, minus the count
        // before 1970, to keep the arithmetic in plain Ints.
        func leaps(before y: Int) -> Int { let p = y - 1; return p/4 - p/100 + p/400 }
        let years = year - 1970
        let leapDays = leaps(before: year) - leaps(before: 1970)
        return years * 365 + leapDays
    }
    private static let cumDays = [0,31,59,90,120,151,181,212,243,273,304,334]

    /// Parse the exact "YYYY-MM-DDTHH:MM:SS[.fff]Z" UTC form. Returns nil if the
    /// string deviates (caller falls back to ISO8601DateFormatter).
    private static func fastISO8601UTC(_ s: String) -> Date? {
        let u = Array(s.utf8)
        // Minimum "YYYY-MM-DDTHH:MM:SSZ" = 20 chars; must end in 'Z'.
        guard u.count >= 20, u.last == 0x5A /* Z */ else { return nil }
        func digit(_ i: Int) -> Int? { let c = u[i]; return (c >= 0x30 && c <= 0x39) ? Int(c - 0x30) : nil }
        func num(_ i: Int, _ n: Int) -> Int? {
            var v = 0
            for k in 0..<n { guard let d = digit(i + k) else { return nil }; v = v * 10 + d }
            return v
        }
        guard u[4] == 0x2D, u[7] == 0x2D, u[10] == 0x54, u[13] == 0x3A, u[16] == 0x3A,
              let year = num(0, 4), let month = num(5, 2), let day = num(8, 2),
              let hour = num(11, 2), let minute = num(14, 2), let second = num(17, 2),
              month >= 1, month <= 12, day >= 1, day <= 31 else { return nil }
        // Fractional seconds: optional ".fff" between SS and Z.
        var frac = 0.0
        if u.count > 20, u[19] == 0x2E /* . */ {
            var i = 20, scale = 0.1, f = 0.0
            while i < u.count - 1, let d = digit(i) { f += Double(d) * scale; scale /= 10; i += 1 }
            // Everything between the dot and the trailing Z must be digits.
            guard i == u.count - 1 else { return nil }
            frac = f
        } else if u.count != 20 {
            return nil
        }
        let isLeap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        var days = daysFromEpoch(toStartOf: year) + cumDays[month - 1] + (day - 1)
        if month > 2, isLeap { days += 1 }
        let secs = Double(days * 86400 + hour * 3600 + minute * 60 + second) + frac
        return Date(timeIntervalSince1970: secs)
    }

    /// Claude encodes the project path into the dir name by replacing "/" and
    /// "." with "-". Lossy, but jsonl carries the real cwd; this is a fallback.
    private static func decodeProjectDirName(_ name: String) -> String {
        var n = name
        if n.hasPrefix("-") { n = "/" + n.dropFirst() }
        return n.replacingOccurrences(of: "-", with: "/")
    }

    private static func projectLabel(from path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        return parts.last ?? path
    }

    private static func parseLine(_ line: String) -> [String: Any]? {
        guard !line.isEmpty, let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Running aggregate of the light metadata fields. Every field accumulates
    /// monotonically over jsonl records in file order, so the same accumulator can
    /// be filled by a cold full scan OR seeded from a cached row and advanced over
    /// just the appended tail — jsonl is append-only, so the already-parsed prefix
    /// never changes. `consume(_:)` folds one parsed record into the running state.
    struct MetaAccumulator {
        let id: String
        var customTitle: String?
        var aiTitle: String?
        var cwd: String?
        var firstUserText = ""
        var lastUserText = ""
        var lastTimestamp: Date?
        var firstTimestamp: Date?
        var lastUserTimestamp: Date?
        var lastClaudeTimestamp: Date?
        var messageCount = 0
        var userTurnCount = 0
        var model: String?
        var parentSessionId: String?

        init(id: String) { self.id = id }

        /// Seed from an already-computed meta (a cached row) so the tail picks up
        /// exactly where the previous parse stopped.
        init(seed m: SessionMeta) {
            id = m.id
            customTitle = m.titleIsCustom ? m.title : nil
            aiTitle = m.titleIsCustom ? nil : m.title
            cwd = m.projectPath
            firstUserText = m.firstUserText
            lastUserText = m.lastUserText
            firstTimestamp = m.firstActivity
            lastTimestamp = m.lastActivity
            lastUserTimestamp = m.lastUserTime
            lastClaudeTimestamp = m.lastClaudeTime
            messageCount = m.messageCount
            userTurnCount = m.userTurnCount
            model = m.model
            parentSessionId = m.parentSessionId
        }

        mutating func consume(_ rec: [String: Any]) {
            let type = rec["type"] as? String

            if parentSessionId == nil,
               let ff = rec["forkedFrom"] as? [String: Any],
               let sid = ff["sessionId"] as? String, sid != id {
                parentSessionId = sid
            }

            switch type {
            case "custom-title":
                if let t = rec["customTitle"] as? String { customTitle = t }
            case "ai-title":
                if let t = rec["aiTitle"] as? String { aiTitle = t }
            case "user", "assistant":
                if (rec["isSidechain"] as? Bool) == true { return }
                messageCount += 1
                let ts = parseDate(rec["timestamp"] as? String)
                if let ts = ts {
                    lastTimestamp = ts
                    if firstTimestamp == nil { firstTimestamp = ts }
                    if type == "assistant" { lastClaudeTimestamp = ts }
                }
                let msg = rec["message"] as? [String: Any]
                if type == "assistant", model == nil, let m = msg?["model"] as? String {
                    model = m
                }
                if type == "user" {
                    let c = msg?["content"]
                    if (rec["isMeta"] as? Bool) == true || MessageContent.isToolResultContent(c) {
                        if cwd == nil, let cc = rec["cwd"] as? String { cwd = cc }
                        return
                    }
                    let raw = MessageContent.contentToText(c)
                    let text = MessageContent.oneLine(MessageContent.stripNoise(raw))
                    if MessageContent.isMeaningfulUserText(text) {
                        userTurnCount += 1
                        if firstUserText.isEmpty { firstUserText = text }
                        lastUserText = text
                        if let ts = ts { lastUserTimestamp = ts }
                    }
                }
                if cwd == nil, let c = rec["cwd"] as? String { cwd = c }
            default:
                if cwd == nil, let c = rec["cwd"] as? String { cwd = c }
            }
        }

        /// Materialize the accumulated state into a `SessionMeta`. Returns nil for
        /// an empty file (no dialog, no first/last text).
        func finish(filePath: String, byteSize: Int, fileMtime: Date) -> SessionMeta? {
            if firstUserText.isEmpty && lastUserText.isEmpty && messageCount == 0 { return nil }
            let projectPath = cwd ?? decodeProjectDirName(((filePath as NSString).deletingLastPathComponent as NSString).lastPathComponent)
            let title = customTitle ?? aiTitle
            let displayTime = lastTimestamp ?? lastUserTimestamp ?? fileMtime
            return SessionMeta(
                id: id,
                filePath: filePath,
                projectPath: projectPath,
                projectLabel: projectLabel(from: projectPath),
                title: title,
                titleIsCustom: customTitle != nil,
                lastUserText: lastUserText.isEmpty ? firstUserText : lastUserText,
                firstUserText: firstUserText.isEmpty ? lastUserText : firstUserText,
                mtime: displayTime,
                firstActivity: firstTimestamp,
                lastActivity: lastTimestamp,
                messageCount: messageCount,
                byteSize: byteSize,
                userTurnCount: userTurnCount,
                model: model,
                lastUserTime: lastUserTimestamp,
                lastClaudeTime: lastClaudeTimestamp,
                parentSessionId: parentSessionId
            )
        }
    }

    /// Parse a single session file into metadata (cold/full scan).
    static func parseSessionMeta(_ filePath: String) -> SessionMeta? {
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: filePath)
        let fileMtime = (attrs?[.modificationDate] as? Date) ?? Date()
        let byteSize = (attrs?[.size] as? Int) ?? content.utf8.count
        let id = (filePath as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")

        var acc = MetaAccumulator(id: id)
        content.enumerateLines { rawLine, _ in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let rec = parseLine(line) else { return }
            acc.consume(rec)
        }
        return acc.finish(filePath: filePath, byteSize: byteSize, fileMtime: fileMtime)
    }

    /// Incrementally update a session's metadata by reading ONLY the appended tail
    /// from `fromOffset`. jsonl is append-only, so the cached `prev` already
    /// reflects every record before `fromOffset`; we seed the accumulator with it
    /// and fold in just the new lines. Returns nil if the file shrank/rotated
    /// (caller must fall back to a full `parseSessionMeta`) or vanished.
    static func updateSessionMeta(prev: SessionMeta, filePath: String, fromOffset: UInt64)
        -> (meta: SessionMeta, newOffset: UInt64, fileMtime: Date)? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: filePath)) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        if end < fromOffset { return nil }                 // shrank/rotated → caller re-parses
        let fileMtime = fileMtime(filePath)
        if end == fromOffset {                             // mtime touched but no new bytes
            return (prev, end, fileMtime)
        }
        try? handle.seek(toOffset: fromOffset)
        let data = (try? handle.readToEnd()) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var acc = MetaAccumulator(seed: prev)
        text.enumerateLines { rawLine, _ in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let rec = parseLine(line) else { return }
            acc.consume(rec)
        }
        guard let meta = acc.finish(filePath: filePath, byteSize: Int(end), fileMtime: fileMtime) else { return nil }
        return (meta, end, fileMtime)
    }

    /// List every session jsonl file path under the projects dir.
    static func listSessionFiles() -> [String] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: projectsDir.path) else { return [] }
        var paths: [String] = []
        for dir in dirs {
            let dirPath = projectsDir.appendingPathComponent(dir).path
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
            for f in files where f.hasSuffix(".jsonl") {
                paths.append((dirPath as NSString).appendingPathComponent(f))
            }
        }
        return paths
    }

    // Cache of parsed metadata keyed by file path, with the mtime it was parsed
    // at. Lets a re-scan reuse unchanged files and only re-parse what moved.
    private static var metaCache: [String: (mtime: Date, meta: SessionMeta)] = [:]
    private static let metaLock = NSLock()

    static func fileMtime(_ path: String) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
    }

    /// Scan all projects in parallel and return metadata sorted by recency.
    /// Files whose mtime is unchanged since the last scan are served from cache,
    /// so steady-state re-scans only re-parse the handful that actually changed.
    static func loadAllSessions() -> [SessionMeta] {
        let files = listSessionFiles()
        var results = [SessionMeta?](repeating: nil, count: files.count)
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            let path = files[i]
            let mtime = fileMtime(path)

            metaLock.lock()
            let cached = metaCache[path]
            metaLock.unlock()
            if let cached = cached, cached.mtime == mtime {
                lock.lock(); results[i] = cached.meta; lock.unlock()
                return
            }

            if let meta = parseSessionMeta(path) {
                metaLock.lock()
                metaCache[path] = (mtime, meta)
                metaLock.unlock()
                lock.lock(); results[i] = meta; lock.unlock()
            }
        }

        // Drop cache entries for files that disappeared.
        let live = Set(files)
        metaLock.lock()
        metaCache = metaCache.filter { live.contains($0.key) }
        metaLock.unlock()

        return results.compactMap { $0 }.sorted { $0.mtime > $1.mtime }
    }

    /// Parse a slice of jsonl text (already-read lines) into dialog messages.
    /// `indexBase` seeds the positional fallback id for records lacking a uuid.
    private static func parseDialogLines<S: Sequence>(_ lines: S, indexBase: Int = 0) -> [DialogMessage]
        where S.Element == Substring {
        var messages: [DialogMessage] = []
        var index = indexBase
        var resultsByID: [String: String] = [:]   // tool_use_id → result text
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let rec = parseLine(line) else { continue }
            let type = rec["type"] as? String
            guard type == "user" || type == "assistant" else { continue }
            if (rec["isSidechain"] as? Bool) == true { continue }

            let msg = rec["message"] as? [String: Any]
            let c = msg?["content"]
            let text = MessageContent.contentToText(c).trimmingCharacters(in: .whitespacesAndNewlines)
            let ex = MessageContent.extractContent(c)
            for (k, v) in ex.resultsByID { resultsByID[k] = v }
            if text.isEmpty && ex.toolUses.isEmpty && ex.toolResults.isEmpty && ex.imageCount == 0 { continue }

            let isToolOrMeta = type == "user" &&
                ((rec["isMeta"] as? Bool) == true || MessageContent.isToolResultContent(c))

            // Stable id from the record's uuid (append-only ⇒ never changes);
            // fall back to a positional id when absent.
            let recUUID = (rec["uuid"] as? String) ?? ""
            let stableID = recUUID.isEmpty ? "msg-\(index)" : recUUID
            index += 1

            messages.append(DialogMessage(
                id: stableID,
                uuid: recUUID,
                parentUuid: rec["parentUuid"] as? String,
                logicalParentUuid: rec["logicalParentUuid"] as? String,
                role: type == "user" ? .user : .assistant,
                text: text,
                timestamp: parseDate(rec["timestamp"] as? String),
                isToolOrMeta: isToolOrMeta,
                toolUses: ex.toolUses,
                toolResults: ex.toolResults,
                bodyText: ex.bodyText,
                imageCount: ex.imageCount,
                pieces: ex.pieces,
                imagePaths: ex.imagePaths))
        }
        // Link each tool call to its result (results arrive in later messages).
        func withOutput(_ t: ToolUse) -> ToolUse {
            guard !t.toolUseID.isEmpty, let out = resultsByID[t.toolUseID], !out.isEmpty else { return t }
            var c = t; c.output = out; return c
        }
        for i in messages.indices {
            messages[i].toolUses = messages[i].toolUses.map(withOutput)
            messages[i].pieces = messages[i].pieces.map { piece in
                if case .tool(let t) = piece { return .tool(withOutput(t)) }
                return piece
            }
        }
        return messages
    }

    /// jsonl is append-only, so a growing session is read incrementally: only
    /// the bytes after `fromOffset` are parsed. Returns the new messages and the
    /// new end offset. `truncated` means the file shrank/rotated → full reload.
    static func loadDialogTail(_ filePath: String, fromOffset: UInt64)
        -> (messages: [DialogMessage], newOffset: UInt64, truncated: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: filePath)) else {
            return nil
        }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        if end < fromOffset { return ([], end, true) }   // shrank/rotated
        if end == fromOffset { return ([], end, false) } // nothing new
        try? handle.seek(toOffset: fromOffset)
        let data = (try? handle.readToEnd()) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return ([], end, false) }
        let msgs = parseDialogLines(text.split(separator: "\n", omittingEmptySubsequences: true))
        return (msgs, end, false)
    }

    /// Lazily load all inline images from a session, in the SAME order that
    /// `extractContent` counts them, so per-turn slicing by index stays aligned.
    /// Two kinds: base64 `image` blocks, and `[Image: source: /path]` refs inside
    /// text blocks (files under ~/.claude/image-cache). A pasted image is written
    /// BOTH ways: a base64 record first, then the numbered cache-file ref in the
    /// prompt — and the CLI eventually cleans image-cache, killing the file while
    /// the base64 twin stays in the jsonl. So a missing ref `<k>.png` falls back
    /// to the k-th base64 image of the session; only if that fails too do we emit
    /// a placeholder NSImage (indices must stay aligned).
    static func loadImages(_ filePath: String) -> [NSImage] {
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { return [] }
        var images: [NSImage] = []
        var base64Seen: [NSImage] = []   // standalone base64 images, in file order

        func loadRef(_ path: String) -> NSImage {
            if let img = NSImage(contentsOfFile: path) { return img }
            // "<k>.png" → the k-th pasted image → the k-th base64 twin.
            let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            if let k = Int(stem), k >= 1, k <= base64Seen.count { return base64Seen[k - 1] }
            return NSImage()
        }

        content.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("\"image\"") || trimmed.contains("Image: source:"),
                  let rec = parseLine(trimmed),
                  (rec["type"] as? String) == "user" || (rec["type"] as? String) == "assistant",
                  let c = (rec["message"] as? [String: Any])?["content"] as? [Any] else { return }
            for block in c {
                if let b = block as? [String: Any] {
                    switch b["type"] as? String {
                    case "text":
                        if let t = b["text"] as? String {
                            for path in MessageContent.imageFileRefs(in: t) {
                                images.append(loadRef(path))
                            }
                        }
                    case "image":
                        if let src = b["source"] as? [String: Any], let b64 = src["data"] as? String,
                           let data = Data(base64Encoded: b64), let img = NSImage(data: data) {
                            images.append(img)
                            base64Seen.append(img)
                        } else {
                            images.append(NSImage())
                        }
                    default: break
                    }
                } else if let s = block as? String {
                    for path in MessageContent.imageFileRefs(in: s) {
                        images.append(loadRef(path))
                    }
                }
            }
        }
        return images
    }

    /// Current byte length of a session file (for the incremental read offset).
    static func fileLength(_ filePath: String) -> UInt64 {
        (((try? FileManager.default.attributesOfItem(atPath: filePath))?[.size] as? NSNumber)?.uint64Value) ?? 0
    }

    /// Fully parse a session file into an ordered list of dialog messages.
    static func loadDialog(_ filePath: String) -> SessionDialog {
        let id = (filePath as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return SessionDialog(id: id, messages: [])
        }
        let messages = parseDialogLines(content.split(separator: "\n", omittingEmptySubsequences: true))
        return SessionDialog(id: id, messages: messages)
    }

    /// Derive list metadata from an already-parsed message array (no file read).
    static func metaFrom(messages: [DialogMessage], filePath: String,
                         header: (custom: String?, ai: String?, cwd: String?, model: String?),
                         byteSize: Int, fileMtime: Date) -> SessionMeta? {
        let id = (filePath as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
        var firstUser = "", lastUser = ""
        var firstTs: Date?, lastTs: Date?, lastUserTs: Date?, lastClaudeTs: Date?
        var userTurns = 0
        let model = header.model
        for m in messages {
            if firstTs == nil { firstTs = m.timestamp }
            if let t = m.timestamp { lastTs = t }
            if m.role == .assistant, let t = m.timestamp { lastClaudeTs = t }
            if m.role == .user, !m.isToolOrMeta {
                let text = MessageContent.oneLine(MessageContent.stripNoise(m.bodyText))
                if MessageContent.isMeaningfulUserText(text) {
                    userTurns += 1
                    if firstUser.isEmpty { firstUser = text }
                    lastUser = text
                    if let t = m.timestamp { lastUserTs = t }
                }
            }
        }
        if firstUser.isEmpty && lastUser.isEmpty && messages.isEmpty { return nil }
        let projectPath = header.cwd ?? decodeProjectDirName(((filePath as NSString).deletingLastPathComponent as NSString).lastPathComponent)
        return SessionMeta(
            id: id, filePath: filePath, projectPath: projectPath,
            projectLabel: projectLabel(from: projectPath),
            title: header.custom ?? header.ai, titleIsCustom: header.custom != nil,
            lastUserText: lastUser.isEmpty ? firstUser : lastUser,
            firstUserText: firstUser.isEmpty ? lastUser : firstUser,
            // Sort/display time = the user's LAST prompt (not Claude's last
            // activity) — a session only climbs the list when YOU write to it.
            mtime: lastUserTs ?? lastTs ?? fileMtime,
            firstActivity: firstTs, lastActivity: lastTs,
            messageCount: messages.count, byteSize: byteSize,
            userTurnCount: userTurns, model: model,
            lastUserTime: lastUserTs, lastClaudeTime: lastClaudeTs)
    }

    /// Read the title records (custom/ai) and cwd from a jsonl prefix — needed
    /// for meta but not part of the dialog message stream.
    static func readHeader(_ filePath: String, limitBytes: Int = 1_000_000)
        -> (custom: String?, ai: String?, cwd: String?, model: String?) {
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return (nil, nil, nil, nil)
        }
        var custom: String?, ai: String?, cwd: String?, model: String?
        content.enumerateLines { line, stop in
            guard let rec = parseLine(line.trimmingCharacters(in: .whitespaces)) else { return }
            switch rec["type"] as? String {
            case "custom-title": custom = rec["customTitle"] as? String
            case "ai-title": ai = rec["aiTitle"] as? String
            default:
                if cwd == nil, let c = rec["cwd"] as? String { cwd = c }
                if model == nil, let m = (rec["message"] as? [String: Any])?["model"] as? String { model = m }
            }
        }
        return (custom, ai, cwd, model)
    }

    // Small LRU of recently opened dialogs (NOT every session — that leaked GBs).
    // Only the few sessions the user actually opened are kept; search no longer
    // touches this cache at all.
    private static var dialogCache: [String: SessionDialog] = [:]
    private static var dialogLRU: [String] = []
    private static let dialogCacheLimit = 3
    private static let cacheLock = NSLock()

    static func loadDialogCached(_ meta: SessionMeta) -> SessionDialog {
        cacheLock.lock()
        if let hit = dialogCache[meta.id] {
            touchLRU(meta.id); cacheLock.unlock(); return hit
        }
        cacheLock.unlock()
        let d = loadDialog(meta.filePath)
        cacheLock.lock()
        dialogCache[meta.id] = d
        touchLRU(meta.id)
        while dialogLRU.count > dialogCacheLimit {
            let evict = dialogLRU.removeFirst()
            dialogCache.removeValue(forKey: evict)
        }
        cacheLock.unlock()
        return d
    }

    /// Move id to the most-recently-used end (caller holds cacheLock).
    private static func touchLRU(_ id: String) {
        dialogLRU.removeAll { $0 == id }
        dialogLRU.append(id)
    }

    /// Drop the cached parse for a session so the next load re-reads from disk
    /// (used when the file changes on disk while it is the active session).
    static func invalidateDialog(_ id: String) {
        cacheLock.lock()
        dialogCache.removeValue(forKey: id)
        dialogLRU.removeAll { $0 == id }
        cacheLock.unlock()
    }

    /// Build the searchable text blob for a session TRANSIENTLY: read the file,
    /// produce a lowercased blob, and let it deallocate. We deliberately do NOT
    /// retain it (neither on `meta` nor in `dialogCache`) — caching every
    /// session's full dialog text across keystrokes was a multi-GB memory leak.
    static func buildSearchBlob(_ meta: SessionMeta) -> String {
        guard let content = try? String(contentsOfFile: meta.filePath, encoding: .utf8) else {
            return "\(meta.title ?? "")\n\(meta.projectLabel)\n\(meta.lastUserText)".lowercased()
        }
        // Cheap substring scan over raw jsonl prose — good enough for matching,
        // and avoids building/holding a full parsed dialog.
        var parts = [meta.title ?? "", meta.projectLabel, meta.projectPath]
        content.enumerateLines { line, _ in
            // Only index human-readable text fields, not the whole jsonl noise.
            if line.contains("\"text\"") || line.contains("\"content\"") {
                parts.append(line)
            }
        }
        return parts.joined(separator: "\n").lowercased()
    }
}

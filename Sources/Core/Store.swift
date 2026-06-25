// Persistent cache so the app draws instantly on launch and parses each jsonl
// line at most once. Backed by SwiftData (SQLite under the hood).
//
// Strategy:
//  - SessionRecord holds the list metadata PLUS a preview blob (the first turns
//    of the dialog) so both the list and the initial conversation render with
//    zero file I/O at startup.
//  - `parsedOffset` is how many bytes of the jsonl we've already consumed; jsonl
//    is append-only, so a refresh reads only the tail from that offset — every
//    line is parsed exactly once across the lifetime of the cache.

import Foundation
import SwiftData

@Model
final class SessionRecord {
    @Attribute(.unique) var id: String
    var filePath: String
    var projectPath: String
    var projectLabel: String
    var title: String?
    var titleIsCustom: Bool
    var lastUserText: String
    var firstUserText: String
    var mtime: Date
    var firstActivity: Date?
    var lastActivity: Date?
    var messageCount: Int
    var byteSize: Int
    var userTurnCount: Int
    var model: String?
    var lastUserTime: Date?
    var lastClaudeTime: Date?
    /// Parent session id (`forkedFrom.sessionId`), if this session is a fork.
    var parentSessionId: String?
    /// Bumped when derived-metadata logic changes, to force a recompute of old
    /// rows whose fields predate the change (without re-reading the file).
    var schemaVersion: Int = 0

    /// Bytes of the jsonl already parsed (append-only ⇒ never re-read).
    var parsedOffset: Int
    /// File mtime at last parse, to detect external changes cheaply.
    var fileMtime: Date

    // NOTE: the full dialog is intentionally NOT stored. Persisting every
    // session's parsed transcript here ballooned the DB and — worse — re-encoding
    // the active session's growing transcript on every file write leaked tens of
    // GB. The dialog is read from the jsonl on demand (and LRU-cached in memory).

    init(id: String, filePath: String, projectPath: String, projectLabel: String,
         title: String?, titleIsCustom: Bool, lastUserText: String, firstUserText: String,
         mtime: Date, firstActivity: Date?, lastActivity: Date?, messageCount: Int,
         byteSize: Int, userTurnCount: Int, model: String?,
         lastUserTime: Date?, lastClaudeTime: Date?, parentSessionId: String? = nil,
         schemaVersion: Int = 0,
         parsedOffset: Int, fileMtime: Date) {
        self.id = id; self.filePath = filePath; self.projectPath = projectPath
        self.projectLabel = projectLabel; self.title = title; self.titleIsCustom = titleIsCustom
        self.lastUserText = lastUserText; self.firstUserText = firstUserText; self.mtime = mtime
        self.firstActivity = firstActivity; self.lastActivity = lastActivity
        self.messageCount = messageCount; self.byteSize = byteSize
        self.userTurnCount = userTurnCount; self.model = model
        self.lastUserTime = lastUserTime; self.lastClaudeTime = lastClaudeTime
        self.parentSessionId = parentSessionId
        self.schemaVersion = schemaVersion
        self.parsedOffset = parsedOffset; self.fileMtime = fileMtime
    }
}

/// Codable mirror of DialogMessage for persistence.
struct StoredMessage: Codable {
    var id: String
    var role: String
    var text: String
    var timestamp: Date?
    var isToolOrMeta: Bool
    var toolUses: [StoredTool]
    var toolResults: [String]
    var bodyText: String
    var imageCount: Int
    /// Ordered prose/tool pieces (for in-place tool rendering). Optional so old
    /// caches without it still decode.
    var pieces: [StoredPiece]?
    var imagePaths: [String]?
}

struct StoredTool: Codable {
    var name: String
    var arg: String
    var input: String
    var rawInputJSON: String?
    var toolUseID: String?
    var output: String?
}

/// Codable mirror of ContentPiece: kind "t" (text) or "u" (tool).
struct StoredPiece: Codable {
    var kind: String
    var text: String?
    var tool: StoredTool?
}

extension StoredTool {
    init(_ t: ToolUse) {
        self.init(name: t.name, arg: t.arg, input: t.input, rawInputJSON: t.rawInputJSON,
                  toolUseID: t.toolUseID, output: t.output)
    }
    var toolUse: ToolUse {
        ToolUse(name: name, arg: arg, input: input, rawInputJSON: rawInputJSON ?? "",
                toolUseID: toolUseID ?? "", output: output ?? "")
    }
}

extension DialogMessage {
    init(stored s: StoredMessage) {
        let pieces: [ContentPiece] = (s.pieces ?? []).compactMap { p in
            switch p.kind {
            case "t": return p.text.map { .text($0) }
            case "u": return p.tool.map { .tool($0.toolUse) }
            default: return nil
            }
        }
        self.init(
            id: s.id,
            role: s.role == "user" ? .user : .assistant,
            text: s.text,
            timestamp: s.timestamp,
            isToolOrMeta: s.isToolOrMeta,
            toolUses: s.toolUses.map { $0.toolUse },
            toolResults: s.toolResults,
            bodyText: s.bodyText,
            imageCount: s.imageCount,
            pieces: pieces,
            imagePaths: s.imagePaths ?? [])
    }
    var stored: StoredMessage {
        let sp: [StoredPiece] = pieces.map { p in
            switch p {
            case .text(let t): return StoredPiece(kind: "t", text: t, tool: nil)
            case .tool(let t): return StoredPiece(kind: "u", text: nil, tool: StoredTool(t))
            }
        }
        return StoredMessage(
            id: id, role: role.rawValue, text: text, timestamp: timestamp,
            isToolOrMeta: isToolOrMeta,
            toolUses: toolUses.map { StoredTool($0) },
            toolResults: toolResults, bodyText: bodyText, imageCount: imageCount,
            pieces: sp, imagePaths: imagePaths)
    }
}

extension SessionMeta {
    convenience init(record r: SessionRecord) {
        self.init(
            id: r.id, filePath: r.filePath, projectPath: r.projectPath,
            projectLabel: r.projectLabel, title: r.title, titleIsCustom: r.titleIsCustom,
            lastUserText: r.lastUserText, firstUserText: r.firstUserText, mtime: r.mtime,
            firstActivity: r.firstActivity, lastActivity: r.lastActivity,
            messageCount: r.messageCount, byteSize: r.byteSize,
            userTurnCount: r.userTurnCount, model: r.model,
            lastUserTime: r.lastUserTime, lastClaudeTime: r.lastClaudeTime,
            parentSessionId: r.parentSessionId)
    }
}

/// Thin actor-free wrapper over a SwiftData ModelContext used off the main
/// thread for scanning, and on the main thread for reads.
final class Store {
    let container: ModelContainer

    static var storeURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SessionExplorer/cache.store")
    }

    init() {
        let url = Store.storeURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let config = ModelConfiguration(url: url)
        // Fall back to an in-memory store if the on-disk one is incompatible.
        if let c = try? ModelContainer(for: SessionRecord.self, configurations: config) {
            container = c
        } else {
            try? FileManager.default.removeItem(at: url)
            container = try! ModelContainer(for: SessionRecord.self, configurations: config)
        }
    }

    /// Drop every cached row so the next sync re-parses all sessions from jsonl.
    @MainActor
    func deleteAllCached() {
        let ctx = container.mainContext
        let records = (try? ctx.fetch(FetchDescriptor<SessionRecord>())) ?? []
        for rec in records { ctx.delete(rec) }
        try? ctx.save()
    }

    /// Load all cached sessions (metadata) for an instant first paint.
    @MainActor
    func loadCachedMetas() -> [SessionMeta] {
        let ctx = container.mainContext
        let records = (try? ctx.fetch(FetchDescriptor<SessionRecord>())) ?? []
        return records.map { SessionMeta(record: $0) }.sorted { $0.mtime > $1.mtime }
    }

    /// Fetch metas from an arbitrary context (e.g. the background sync context).
    func metas(in ctx: ModelContext) -> [SessionMeta] {
        let records = (try? ctx.fetch(FetchDescriptor<SessionRecord>())) ?? []
        return records.map { SessionMeta(record: $0) }.sorted { $0.mtime > $1.mtime }
    }

    /// Upsert a session's METADATA only (no transcript). Cheap and constant-size
    /// regardless of how large the conversation grows.
    func upsert(meta: SessionMeta, offset: Int, fileMtime: Date,
                schemaVersion: Int, into ctx: ModelContext) {
        let id = meta.id
        var d = FetchDescriptor<SessionRecord>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        if let rec = try? ctx.fetch(d).first {
            rec.filePath = meta.filePath; rec.projectPath = meta.projectPath
            rec.projectLabel = meta.projectLabel; rec.title = meta.title
            rec.titleIsCustom = meta.titleIsCustom; rec.lastUserText = meta.lastUserText
            rec.firstUserText = meta.firstUserText; rec.mtime = meta.mtime
            rec.firstActivity = meta.firstActivity; rec.lastActivity = meta.lastActivity
            rec.messageCount = meta.messageCount; rec.byteSize = meta.byteSize
            rec.userTurnCount = meta.userTurnCount; rec.model = meta.model
            rec.lastUserTime = meta.lastUserTime; rec.lastClaudeTime = meta.lastClaudeTime
            rec.parentSessionId = meta.parentSessionId
            rec.schemaVersion = schemaVersion
            rec.parsedOffset = offset; rec.fileMtime = fileMtime
        } else {
            ctx.insert(SessionRecord(
                id: meta.id, filePath: meta.filePath, projectPath: meta.projectPath,
                projectLabel: meta.projectLabel, title: meta.title, titleIsCustom: meta.titleIsCustom,
                lastUserText: meta.lastUserText, firstUserText: meta.firstUserText, mtime: meta.mtime,
                firstActivity: meta.firstActivity, lastActivity: meta.lastActivity,
                messageCount: meta.messageCount, byteSize: meta.byteSize,
                userTurnCount: meta.userTurnCount, model: meta.model,
                lastUserTime: meta.lastUserTime, lastClaudeTime: meta.lastClaudeTime,
                parentSessionId: meta.parentSessionId,
                schemaVersion: schemaVersion,
                parsedOffset: offset, fileMtime: fileMtime))
        }
    }
}

// Searchable text of every session, for deep search without reading jsonl.
//
// One file per session under Application Support/SessionExplorer/text/<id>.txt,
// one line per content block of the main transcript: human and assistant text,
// thinking, tool inputs (compact JSON) and the head of each tool result.
// Images and the rest of tool output are left out, so the index is ~2% of the
// jsonl and stays local when old transcripts live only in the iCloud archive.
// Filled by the same incremental meta parse as the Store and `PromptIndex`:
// a tail parse appends, a cold parse rewrites the file.

import Foundation

enum TextIndex {
    /// Characters of a tool result kept in the index.
    static let toolResultHead = 500

    static var directory: URL {
        Store.storeURL.deletingLastPathComponent().appendingPathComponent("text", isDirectory: true)
    }

    static func path(_ id: String) -> String {
        directory.appendingPathComponent("\(id).txt").path
    }

    /// The index lines of one record's content (`message.content` or a queued
    /// prompt): string content and blocks in order.
    static func lines(of content: Any?, isUser: Bool) -> [String] {
        func prose(_ s: String) -> String { isUser ? MessageContent.stripNoise(s) : s }
        if let s = content as? String { return [prose(s)] }
        guard let blocks = content as? [Any] else { return [] }
        var out: [String] = []
        for block in blocks {
            if let s = block as? String { out.append(prose(s)); continue }
            guard let b = block as? [String: Any] else { continue }
            switch b["type"] as? String {
            case "text":
                if let t = b["text"] as? String { out.append(prose(t)) }
            case "thinking":
                if let t = b["thinking"] as? String { out.append(t) }
            case "tool_use":
                if let input = b["input"], JSONSerialization.isValidJSONObject(input),
                   let data = try? JSONSerialization.data(withJSONObject: input, options: [.withoutEscapingSlashes]) {
                    out.append(String(decoding: data, as: UTF8.self))
                }
            case "tool_result":
                out.append(String(MessageContent.contentToText(b["content"]).prefix(toolResultHead)))
            default:
                break
            }
        }
        return out
    }

    /// Lines as file bytes: line breaks and tabs inside a line become spaces,
    /// empty lines are dropped.
    private static func encode(_ lines: [String]) -> Data {
        var out = Data()
        for line in lines {
            var bytes = Array(line.utf8)
            var blank = true
            for i in bytes.indices {
                switch bytes[i] {
                case 0x0A, 0x0D, 0x09: bytes[i] = 0x20
                case 0x20: break
                default: blank = false
                }
            }
            if blank { continue }
            out.append(contentsOf: bytes)
            out.append(0x0A)
        }
        return out
    }

    static func append(_ lines: [String], to id: String) {
        let data = encode(lines)
        guard !data.isEmpty else { return }
        let url = URL(fileURLWithPath: path(id))
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    static func replace(_ lines: [String], for id: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? encode(lines).write(to: URL(fileURLWithPath: path(id)), options: .atomic)
    }

    static func remove(_ id: String) {
        try? FileManager.default.removeItem(atPath: path(id))
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

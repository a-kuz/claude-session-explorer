// In-place editing of user prompt records inside a session jsonl.
//
// A jsonl session file is append-only for every OTHER writer (Claude Code, the
// incremental loaders). Editing rewrites exactly one line — the record with the
// given uuid — and leaves every other line byte-identical, then replaces the
// file atomically. Callers must treat the file as fully changed afterwards:
// invalidate dialog caches and re-parse metadata cold (saved parse offsets
// point into the OLD byte layout).

import Foundation

enum SessionEditor {
    enum EditorError: LocalizedError {
        case fileUnreadable
        case recordNotFound
        case notEditable
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .fileUnreadable: return "Could not read the session file"
            case .recordNotFound: return "Record not found in the session file"
            case .notEditable: return "This record's content can't be edited"
            case .encodingFailed: return "Could not re-encode the record"
            }
        }
    }

    /// Raw text of the user record `uuid`, exactly as stored: a string content
    /// as-is, or the text blocks of an array content joined by a blank line.
    /// Nil when the record is missing or carries no text.
    static func userText(filePath: String, uuid: String) -> String? {
        guard let rec = findRecord(filePath: filePath, uuid: uuid) else { return nil }
        let c = (rec["message"] as? [String: Any])?["content"]
        if let s = c as? String { return s }
        if let blocks = c as? [Any] {
            var texts: [String] = []
            for b in blocks {
                if let s = b as? String { texts.append(s) }
                else if let bb = b as? [String: Any], (bb["type"] as? String) == "text",
                        let t = bb["text"] as? String { texts.append(t) }
            }
            return texts.joined(separator: "\n\n")
        }
        return nil
    }

    /// Replace the text of the user record `uuid` with `newText` and rewrite the
    /// file atomically. String content is replaced whole; in an array content the
    /// first text block takes `newText` and the remaining text blocks are removed
    /// (they were shown joined in the editor), while non-text blocks (images,
    /// tool_result) keep their place untouched.
    static func setUserText(filePath: String, uuid: String, newText: String) throws {
        let url = URL(fileURLWithPath: filePath)
        guard let content = JSONLBytes.read(filePath) else { throw EditorError.fileUnreadable }
        guard let hit = locate(uuid: uuid, in: content) else { throw EditorError.recordNotFound }
        var rec = hit.record
        guard (rec["type"] as? String) == "user",
              var msg = rec["message"] as? [String: Any] else { throw EditorError.notEditable }

        let c = msg["content"]
        if c == nil || c is String {
            msg["content"] = newText
        } else if let blocks = c as? [Any] {
            var out: [Any] = []
            var inserted = false
            for b in blocks {
                if var bb = b as? [String: Any], (bb["type"] as? String) == "text" {
                    if !inserted { bb["text"] = newText; out.append(bb); inserted = true }
                } else if b is String {
                    if !inserted { out.append(["type": "text", "text": newText] as [String: Any]); inserted = true }
                } else {
                    out.append(b)
                }
            }
            if !inserted { out.insert(["type": "text", "text": newText] as [String: Any], at: 0) }
            msg["content"] = out
        } else {
            throw EditorError.notEditable
        }
        rec["message"] = msg

        guard JSONSerialization.isValidJSONObject(rec),
              let newLine = try? JSONSerialization.data(withJSONObject: rec,
                                                        options: [.withoutEscapingSlashes]),
              !newLine.contains(0x0A) else {
            throw EditorError.encodingFailed
        }
        // Everything outside the record's line is copied through as raw bytes.
        var out = Data(capacity: content.count - hit.line.count + newLine.count)
        out.append(content[content.startIndex..<(content.startIndex + hit.line.lowerBound)])
        out.append(newLine)
        out.append(content[(content.startIndex + hit.line.upperBound)...])
        try out.write(to: url, options: .atomic)
    }

    /// Find the record whose own `uuid` matches (not a parentUuid reference).
    private static func findRecord(filePath: String, uuid: String) -> [String: Any]? {
        guard let content = JSONLBytes.read(filePath) else { return nil }
        return locate(uuid: uuid, in: content)?.record
    }

    /// The first line whose parsed record has `uuid` as its own uuid, with the
    /// line's byte range in `content` (newline excluded). Only lines that
    /// contain the uuid bytes are parsed — a child record carries the same
    /// value as parentUuid, hence the check on the parsed record.
    private static func locate(uuid: String, in content: Data) -> (record: [String: Any], line: Range<Int>)? {
        let needle = Array(uuid.utf8)
        var found: (record: [String: Any], line: Range<Int>)?
        JSONLBytes.forEachLine(content) { line, offset, stop in
            guard JSONLBytes.contains(line, needle),
                  let rec = JSONLBytes.parse(line),
                  (rec["uuid"] as? String) == uuid else { return }
            found = (rec, offset..<(offset + line.count))
            stop = true
        }
        return found
    }
}

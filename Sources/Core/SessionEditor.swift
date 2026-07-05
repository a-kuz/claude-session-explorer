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
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            throw EditorError.fileUnreadable
        }
        // Keep empty subsequences so join() reproduces the original layout,
        // including the trailing newline.
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var lineIndex: Int?
        var record: [String: Any]?
        for i in lines.indices {
            // Cheap prefilter: the child record contains this uuid as parentUuid
            // too, so verify the parsed record's own uuid.
            guard lines[i].contains(uuid),
                  let data = lines[i].data(using: .utf8),
                  let rec = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (rec["uuid"] as? String) == uuid else { continue }
            lineIndex = i
            record = rec
            break
        }
        guard let i = lineIndex, var rec = record else { throw EditorError.recordNotFound }
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
              let newData = try? JSONSerialization.data(withJSONObject: rec,
                                                        options: [.withoutEscapingSlashes]),
              let newLine = String(data: newData, encoding: .utf8),
              !newLine.contains("\n") else {
            throw EditorError.encodingFailed
        }
        lines[i] = newLine
        try Data(lines.joined(separator: "\n").utf8).write(to: url, options: .atomic)
    }

    /// Find the record whose own `uuid` matches (not a parentUuid reference).
    private static func findRecord(filePath: String, uuid: String) -> [String: Any]? {
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { return nil }
        var found: [String: Any]?
        content.enumerateLines { line, stop in
            guard line.contains(uuid),
                  let data = line.data(using: .utf8),
                  let rec = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (rec["uuid"] as? String) == uuid else { return }
            found = rec
            stop = true
        }
        return found
    }
}

// Extracting human-readable text from Claude Code message content,
// and deciding which user messages are "real" prompts vs noise.
// Port of src/lib/content.ts.

import Foundation

enum MessageContent {
    /// Patterns that mark a user "message" as machinery rather than a real prompt.
    private static let noisePrefixes = [
        "<task-notification>", "<local-command-caveat>", "<local-command-stdout>",
        "<command-name>", "<command-message>", "<command-args>",
        "<bash-stdout>", "<bash-stderr>", "<user-memory-input>",
        "<system-reminder>", "<<autonomous-loop", "Caveat: The messages below",
    ]

    private static let noiseExact: Set<String> = [
        "Continue from where you left off.",
        "[Request interrupted by user]",
        "(no content)",
    ]

    /// Flatten a content value (string | array of blocks) into plain text.
    static func contentToText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        guard let arr = content as? [Any] else { return "" }

        var parts: [String] = []
        for block in arr {
            if let s = block as? String { parts.append(s); continue }
            guard let b = block as? [String: Any] else { continue }
            let type = b["type"] as? String
            switch type {
            case "text":
                if let t = b["text"] as? String { parts.append(t) }
            case "image":
                parts.append("[image]")
            case "document":
                parts.append("[document]")
            case "tool_use":
                let name = (b["name"] as? String) ?? "tool"
                parts.append("[→ \(name)]")
            case "tool_result":
                let inner = contentToText(b["content"])
                parts.append(inner.isEmpty ? "[result]" : "[result] \(inner)")
            case "thinking":
                break
            default:
                if let t = b["text"] as? String { parts.append(t) }
            }
        }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Argument keys we surface as the short summary, in priority order.
    private static let argKeys = [
        "file_path", "path", "command", "pattern", "query", "url",
        "prompt", "description", "old_string",
    ]

    private static func summarizeToolInput(_ input: Any?) -> String {
        guard let obj = input as? [String: Any] else { return "" }
        for k in argKeys {
            if let v = obj[k] as? String, !v.trimmingCharacters(in: .whitespaces).isEmpty {
                return oneLine(v, max: 80)
            }
        }
        for v in obj.values {
            if let s = v as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                return oneLine(s, max: 80)
            }
        }
        return ""
    }

    private static func formatToolInput(_ input: Any?) -> String {
        guard let input = input else { return "" }
        if let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return String(describing: input)
    }

    struct ExtractedContent {
        let bodyText: String
        let toolUses: [ToolUse]
        let toolResults: [String]
        let imageCount: Int
        /// Prose and tool calls in their original order (for in-place rendering).
        var pieces: [ContentPiece] = []
        /// Absolute paths of "[Image: source: …]" attachments, loaded from disk.
        var imagePaths: [String] = []
        /// tool_use_id → result text carried by this (user) message.
        var resultsByID: [String: String] = [:]
    }

    /// Re-encode a tool input value as compact JSON (for rich tool renderers).
    private static func inputJSON(_ input: Any?) -> String {
        guard let input, JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(withJSONObject: input),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    /// Split a message's content into prose, tool calls, and tool results.
    static func extractContent(_ content: Any?) -> ExtractedContent {
        if let s = content as? String {
            return ExtractedContent(bodyText: s.trimmingCharacters(in: .whitespacesAndNewlines),
                                    toolUses: [], toolResults: [], imageCount: 0)
        }
        guard let arr = content as? [Any] else {
            return ExtractedContent(bodyText: "", toolUses: [], toolResults: [], imageCount: 0)
        }

        var bodyParts: [String] = []
        var toolUses: [ToolUse] = []
        var toolResults: [String] = []
        var imageCount = 0
        var pieces: [ContentPiece] = []
        var imagePaths: [String] = []
        var resultsByID: [String: String] = [:]

        // Coalesce adjacent prose into one .text piece so a tool between two
        // paragraphs splits them, but consecutive text stays one block.
        func pushText(_ t: String) {
            if case .text(let prev)? = pieces.last {
                pieces[pieces.count - 1] = .text(prev + "\n" + t)
            } else {
                pieces.append(.text(t))
            }
        }

        // Strip "[Image: source: /path.png]" references out of prose, counting
        // each as an image (the file is loaded lazily for inline display).
        func handleText(_ t: String) {
            let refs = imageFileRefs(in: t)
            imageCount += refs.count
            imagePaths.append(contentsOf: refs)
            let cleaned = stripImageRefs(t)
            if !cleaned.isEmpty { bodyParts.append(cleaned); pushText(cleaned) }
        }

        for block in arr {
            if let s = block as? String { handleText(s); continue }
            guard let b = block as? [String: Any] else { continue }
            switch b["type"] as? String {
            case "text":
                if let t = b["text"] as? String { handleText(t) }
            case "image":
                imageCount += 1
            case "document":
                bodyParts.append("[document]"); pushText("[document]")
            case "tool_use":
                let tool = ToolUse(
                    name: (b["name"] as? String) ?? "tool",
                    arg: summarizeToolInput(b["input"]),
                    input: formatToolInput(b["input"]),
                    rawInputJSON: inputJSON(b["input"]),
                    toolUseID: (b["id"] as? String) ?? ""
                )
                toolUses.append(tool)
                pieces.append(.tool(tool))
            case "tool_result":
                let txt = contentToText(b["content"])
                toolResults.append(txt)
                if let rid = b["tool_use_id"] as? String { resultsByID[rid] = txt }
            case "thinking":
                break
            default:
                if let t = b["text"] as? String { handleText(t) }
            }
        }

        return ExtractedContent(
            bodyText: bodyParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            toolUses: toolUses, toolResults: toolResults, imageCount: imageCount, pieces: pieces,
            imagePaths: imagePaths, resultsByID: resultsByID)
    }

    /// Regex matching a Claude image reference: "[Image: source: /abs/path]".
    private static let imageRefRegex = try! NSRegularExpression(
        pattern: "\\[Image: source: ([^\\]]+)\\]", options: [])

    /// Extract the file paths from all "[Image: source: …]" refs in a string.
    static func imageFileRefs(in text: String) -> [String] {
        let ns = text as NSString
        return imageRefRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces)
        }
    }

    /// Remove "[Image: source: …]" refs from a string (so prose stays clean).
    static func stripImageRefs(_ text: String) -> String {
        let ns = text as NSString
        let stripped = imageRefRegex.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Does this content represent a tool_result / meta payload (not a typed prompt)?
    static func isToolResultContent(_ content: Any?) -> Bool {
        guard let arr = content as? [Any] else { return false }
        let blocks = arr.compactMap { $0 as? [String: Any] }
        if blocks.isEmpty { return false }
        return blocks.allSatisfy {
            let t = $0["type"] as? String
            return t == "tool_result" || t == "image" || t == "document"
        }
    }

    /// Strip machinery wrappers (caveats, <command-*>, stdout dumps, reminders)
    /// from a user message so only the real typed prompt remains.
    static func stripNoise(_ text: String) -> String {
        var t = text
        // Remove paired/standalone machinery tags and their contents.
        let patterns = [
            "<local-command-caveat>[\\s\\S]*?</local-command-caveat>",
            "<command-name>[\\s\\S]*?</command-name>",
            "<command-message>[\\s\\S]*?</command-message>",
            "<command-args>[\\s\\S]*?</command-args>",
            "<local-command-stdout>[\\s\\S]*?</local-command-stdout>",
            "<bash-stdout>[\\s\\S]*?</bash-stdout>",
            "<bash-stderr>[\\s\\S]*?</bash-stderr>",
            "<system-reminder>[\\s\\S]*?</system-reminder>",
            "<user-memory-input>[\\s\\S]*?</user-memory-input>",
            "<task-notification>[\\s\\S]*?</task-notification>",
            "Caveat: The messages below[^\\n]*",
            "\\[Request interrupted by user[^\\]]*\\]",
            "<<autonomous-loop[^>]*>>",
            "\\[Image #\\d+\\]",
            "\\[Image: source: [^\\]]+\\]",
            "\\[image\\]", "\\[document\\]",
        ]
        for p in patterns {
            t = t.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }
        // Unwrap <bash-input>cmd</bash-input> to just the command text (the tags
        // are machinery, the command itself is meaningful).
        t = t.replacingOccurrences(of: "</?bash-input>", with: "", options: .regularExpression)
        // Collapse the resulting blank runs.
        t = t.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Is this text a real user prompt worth surfacing (not command/system noise)?
    static func isMeaningfulUserText(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        if noiseExact.contains(t) { return false }
        for p in noisePrefixes where t.hasPrefix(p) { return false }
        return true
    }

    /// Collapse whitespace and trim for single-line display.
    static func oneLine(_ text: String, max: Int = 400) -> String {
        let collapsed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > max ? String(collapsed.prefix(max)) : collapsed
    }
}

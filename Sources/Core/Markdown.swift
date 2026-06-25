// Lightweight Markdown → block model for the SwiftUI dialog view.
// Handles the constructs in Claude transcripts: headings, bullet/numbered
// lists, blockquotes, fenced code blocks, and inline spans (bold/italic/code).

import Foundation
import SwiftUI

enum MarkdownBlock: Identifiable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(depth: Int, text: String)
    case numbered(marker: String, depth: Int, text: String)
    case quote(String)
    case code(lang: String, lines: [String])
    /// header row + body rows, each a list of cell strings.
    case table(header: [String], rows: [[String]])

    var id: String {
        switch self {
        case .heading(let l, let t): return "h\(l)-\(t.hashValue)"
        case .paragraph(let t): return "p-\(t.hashValue)"
        case .bullet(let d, let t): return "b\(d)-\(t.hashValue)"
        case .numbered(let m, let d, let t): return "n\(m)\(d)-\(t.hashValue)"
        case .quote(let t): return "q-\(t.hashValue)"
        case .code(let lang, let lines): return "c\(lang)-\(lines.joined().hashValue)"
        case .table(let h, let r): return "t\(h.joined())-\(r.count)-\(r.flatMap{$0}.joined().hashValue)"
        }
    }

    /// Reconstructs a plain-text form of the block for copying.
    var plainText: String {
        switch self {
        case .heading(let l, let t): return String(repeating: "#", count: l) + " " + t
        case .paragraph(let t): return t
        case .bullet(_, let t): return "- " + t
        case .numbered(let m, _, let t): return "\(m) \(t)"
        case .quote(let t): return "> " + t
        case .code(let lang, let lines): return "```\(lang)\n" + lines.joined(separator: "\n") + "\n```"
        case .table(let h, let rows):
            let head = "| " + h.joined(separator: " | ") + " |"
            let body = rows.map { "| " + $0.joined(separator: " | ") + " |" }.joined(separator: "\n")
            return head + "\n" + body
        }
    }
}

enum Markdown {
    static func parse(_ src: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = src.components(separatedBy: "\n")
        var i = 0
        var paragraph: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }

        while i < lines.count {
            let line = lines[i]

            // fenced code block
            if let m = line.range(of: "^\\s*```(.*)$", options: .regularExpression) {
                flushParagraph()
                let lang = String(line[m]).replacingOccurrences(of: "`", with: "")
                    .trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].range(of: "^\\s*```", options: .regularExpression) != nil { break }
                    code.append(lines[i]); i += 1
                }
                blocks.append(.code(lang: lang, lines: code))
                i += 1
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flushParagraph(); i += 1; continue }

            // pipe table: a header row "| a | b |", a separator "|---|---|",
            // then body rows. Requires the next line to be a separator.
            if isTableRow(trimmed), i + 1 < lines.count,
               isSeparatorRow(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                flushParagraph()
                let header = tableCells(trimmed)
                var rows: [[String]] = []
                i += 2 // skip header + separator
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if !isTableRow(t) { break }
                    rows.append(tableCells(t))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // heading
            if let m = line.range(of: "^(#{1,6})\\s+", options: .regularExpression) {
                flushParagraph()
                let hashes = line[m].filter { $0 == "#" }.count
                let text = String(line[m.upperBound...]).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: hashes, text: text))
                i += 1; continue
            }
            // blockquote
            if let m = line.range(of: "^\\s*>\\s?", options: .regularExpression) {
                flushParagraph()
                blocks.append(.quote(String(line[m.upperBound...])))
                i += 1; continue
            }
            // bullet list
            if let m = line.range(of: "^(\\s*)[-*+]\\s+", options: .regularExpression) {
                flushParagraph()
                let indent = line.prefix { $0 == " " }.count
                blocks.append(.bullet(depth: indent / 2, text: String(line[m.upperBound...])))
                i += 1; continue
            }
            // numbered list
            if let m = line.range(of: "^(\\s*)(\\d+)[.)]\\s+", options: .regularExpression) {
                flushParagraph()
                let indent = line.prefix { $0 == " " }.count
                let markerPart = String(line[m]).trimmingCharacters(in: .whitespaces)
                blocks.append(.numbered(marker: markerPart, depth: indent / 2,
                                        text: String(line[m.upperBound...])))
                i += 1; continue
            }

            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    /// A line that looks like a table data/header row (has a column pipe).
    private static func isTableRow(_ t: String) -> Bool {
        guard t.contains("|") else { return false }
        // Avoid treating prose with a stray | as a table — require ≥2 pipes
        // or a leading pipe.
        let pipes = t.filter { $0 == "|" }.count
        return pipes >= 2 || t.hasPrefix("|")
    }

    /// A markdown table separator row like `|---|:--:|---|`.
    private static func isSeparatorRow(_ t: String) -> Bool {
        guard t.contains("-"), isTableRow(t) else { return false }
        let stripped = t.filter { !"|:- ".contains($0) }
        return stripped.isEmpty
    }

    /// Split a `| a | b |` row into trimmed cell strings.
    private static func tableCells(_ t: String) -> [String] {
        var s = t
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Build a styled AttributedString from a line's inline spans (bold / italic /
    /// `code` / links). Shared by paragraph rendering and table cells so markdown
    /// works everywhere. `codeColor`/`codeBg`/`linkColor` come from the theme.
    static func attributed(_ text: String, size: CGFloat, weight: SwiftUI.Font.Weight,
                           color: SwiftUI.Color, codeColor: SwiftUI.Color,
                           codeBg: SwiftUI.Color, linkColor: SwiftUI.Color) -> AttributedString {
        var out = AttributedString()
        for span in spans(text) {
            var piece = AttributedString(span.text)
            if span.code {
                piece.font = DialogFonts.mono(size: size - 1.5)
                piece.foregroundColor = codeColor
                piece.backgroundColor = codeBg
            } else {
                var f = DialogFonts.prose(size: size, weight: span.bold ? .semibold : weight)
                if span.italic { f = f.italic() }
                piece.font = f
                piece.foregroundColor = span.link ? linkColor : color
            }
            out.append(piece)
        }
        return out
    }

    /// One styled inline span.
    struct Span {
        var text: String
        var bold = false
        var italic = false
        var code = false
        var link = false
    }

    /// Tokenize a logical line into styled spans: **bold**, *italic*, `code`,
    /// [text](url). Hand-rolled so spacing and code styling are predictable —
    /// the system markdown parser mangled both.
    static func spans(_ text: String) -> [Span] {
        var spans: [Span] = []
        let chars = Array(text)
        var i = 0
        var buf = ""
        func flush() { if !buf.isEmpty { spans.append(Span(text: buf)); buf = "" } }

        func matchPaired(_ marker: String) -> Int? {
            let m = Array(marker)
            guard i + m.count <= chars.count, Array(chars[i..<i+m.count]) == m else { return nil }
            var j = i + m.count
            while j + m.count <= chars.count {
                if Array(chars[j..<j+m.count]) == m { return j }
                j += 1
            }
            return nil
        }

        while i < chars.count {
            let c = chars[i]
            // inline code `...`
            if c == "`" {
                if let end = matchPaired("`") {
                    flush()
                    spans.append(Span(text: String(chars[(i+1)..<end]), code: true))
                    i = end + 1; continue
                }
            }
            // bold **...**
            if c == "*", i + 1 < chars.count, chars[i+1] == "*" {
                if let end = matchPaired("**") {
                    flush()
                    spans.append(Span(text: String(chars[(i+2)..<end]), bold: true))
                    i = end + 2; continue
                }
            }
            // italic *...*
            if c == "*" {
                if let end = matchPaired("*") {
                    flush()
                    spans.append(Span(text: String(chars[(i+1)..<end]), italic: true))
                    i = end + 1; continue
                }
            }
            // link [text](url)
            if c == "[" {
                let rest = String(chars[i...])
                if let m = rest.range(of: "^\\[([^\\]]+)\\]\\(([^)]+)\\)", options: .regularExpression) {
                    let token = String(rest[m])
                    if let lb = token.firstIndex(of: "]"),
                       token.index(after: token.startIndex) < lb {
                        let label = String(token[token.index(after: token.startIndex)..<lb])
                        flush()
                        spans.append(Span(text: label, link: true))
                        i += token.count; continue
                    }
                }
            }
            buf.append(c); i += 1
        }
        flush()
        return spans
    }
}

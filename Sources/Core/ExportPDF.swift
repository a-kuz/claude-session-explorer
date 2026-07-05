// Export a session transcript as a paginated PDF that mirrors the in-app
// conversation rendering (MessageView): user prompts as left-ruled headings,
// Claude prose without role headers, tool calls as dark terminal-like cards
// with the full command AND full output (the expanded view), code blocks as
// light cards with a language header, AskUserQuestion as a question card.
// Full-width card backgrounds come from NSTextTable blocks, which the Cocoa
// text system draws and paginates; the PDF is written through
// NSTextView + NSPrintOperation.

import AppKit

enum ExportPDF {
    /// A4 content width; `write()` forces A4 paper with matching margins so
    /// tab stops and attachment sizing in the builder line up with the page.
    static let contentWidth: CGFloat = 503

    // Palette matched to the app's light appearance (Theme/MessageView).
    private static let ink = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    private static let secondary = NSColor(srgbRed: 0.43, green: 0.43, blue: 0.45, alpha: 1)
    private static let tertiary = NSColor(srgbRed: 0.63, green: 0.63, blue: 0.66, alpha: 1)
    private static let accent = NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1)      // 0x0A84FF
    private static let ruleGray = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.12)
    private static let green = NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)      // 0x34C759
    private static let codeBg = NSColor(srgbRed: 0.965, green: 0.965, blue: 0.97, alpha: 1)
    private static let codeHeaderBg = NSColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1)
    private static let cardBorder = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.1)
    // The tool card is dark in the app — keep it dark in the PDF too.
    private static let termBg = NSColor(srgbRed: 0.118, green: 0.118, blue: 0.118, alpha: 1)  // 0x1E1E1E
    private static let termText = NSColor(srgbRed: 0.902, green: 0.902, blue: 0.902, alpha: 1) // 0xE6E6E6
    private static let termOut = NSColor(srgbRed: 0.76, green: 0.76, blue: 0.76, alpha: 1)     // 0xC2C2C2
    private static let termPrompt = NSColor(srgbRed: 0.478, green: 0.635, blue: 0.969, alpha: 1) // 0x7AA2F7
    private static let termLabel = NSColor(srgbRed: 0.604, green: 0.627, blue: 0.667, alpha: 1)  // 0x9AA0AA
    private static let termRule = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12)
    private static let askBg = NSColor(srgbRed: 0.97, green: 0.97, blue: 0.975, alpha: 1)

    private static func prose(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }
    private static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    private static func para(spacingBefore: CGFloat = 0, spacing: CGFloat = 4,
                             indent: CGFloat = 0, lineSpacing: CGFloat = 2,
                             charWrap: Bool = false) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = spacingBefore
        p.paragraphSpacing = spacing
        p.firstLineHeadIndent = indent
        p.headIndent = indent
        p.lineSpacing = lineSpacing
        p.lineBreakMode = charWrap ? .byCharWrapping : .byWordWrapping
        return p
    }

    // MARK: - Transcript

    /// Build the whole transcript of one session, styled like the app's dialog
    /// view. `sessionImages` are the session's inline base64 images in jsonl
    /// order (turns slice them via `imageStartIndex`); file-based attachments
    /// come from each turn's `imagePaths`. Safe off the main thread.
    static func attributedTranscript(meta: SessionMeta, title: String,
                                     blocks: [DialogBlock], toolOutputLimit: Int,
                                     sessionImages: [NSImage] = []) -> NSAttributedString {
        let out = NSMutableAttributedString()

        out.append(NSAttributedString(string: title + "\n", attributes: [
            .font: prose(19, .bold), .foregroundColor: ink,
            .paragraphStyle: para(spacing: 3),
        ]))
        var sub = "\(meta.projectLabel) · \(meta.id)"
        if let first = meta.firstActivity, let last = meta.lastActivity {
            sub += " · \(Format.longDateTime(first)) — \(Format.longDateTime(last))"
        }
        out.append(NSAttributedString(string: sub + "\n", attributes: [
            .font: prose(9.5), .foregroundColor: secondary,
            .paragraphStyle: para(spacing: 10),
        ]))

        for (i, block) in blocks.enumerated() {
            // The next block's prompt answers an AskUserQuestion in this one.
            let nextPrompt = i + 1 < blocks.count
                ? blocks[i + 1].promptTurn?.bodyText : nil
            for turn in block.turns {
                if turn.isUserPrompt {
                    appendPrompt(turn, to: out)
                } else {
                    appendAssistantTurn(turn, to: out, toolOutputLimit: toolOutputLimit,
                                        nextPrompt: nextPrompt)
                }
                appendImages(turn, sessionImages: sessionImages, to: out)
            }
        }
        return out
    }

    // MARK: - User prompt (left-ruled heading, time on the right)

    private static func appendPrompt(_ turn: DialogTurn, to out: NSMutableAttributedString) {
        let table = NSTextTable()
        table.numberOfColumns = 1
        let cell = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1,
                                    startingColumn: 0, columnSpan: 1)
        cell.setBorderColor(accent)
        cell.setWidth(2.5, type: .absoluteValueType, for: .border, edge: .minX)
        cell.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
        cell.setWidth(3, type: .absoluteValueType, for: .padding, edge: .minY)
        cell.setWidth(3, type: .absoluteValueType, for: .padding, edge: .maxY)
        cell.setWidth(14, type: .absoluteValueType, for: .margin, edge: .minY)
        cell.setWidth(8, type: .absoluteValueType, for: .margin, edge: .maxY)

        let ps = para(spacing: 2, lineSpacing: 2.5)
        ps.textBlocks = [cell]
        ps.tabStops = [NSTextTab(textAlignment: .right, location: contentWidth - 26)]

        var text = MessageContent.clampHead(turn.bodyText)
        var time = ""
        if let ts = turn.timestamp { time = Format.timeOrDate(ts) }
        // The timestamp sits right-aligned on the FIRST line, like the app.
        if !time.isEmpty {
            if let nl = text.firstIndex(of: "\n") {
                text.insert(contentsOf: "\t\(time)", at: nl)
            } else {
                text += "\t\(time)"
            }
        }
        let s = NSMutableAttributedString(string: text + "\n", attributes: [
            .font: prose(12, .semibold), .foregroundColor: ink, .paragraphStyle: ps,
        ])
        if !time.isEmpty, let r = s.string.range(of: "\t\(time)") {
            s.addAttributes([.font: prose(8.5), .foregroundColor: tertiary],
                            range: NSRange(r, in: s.string))
        }
        out.append(s)
    }

    // MARK: - Assistant turn (prose + expanded tool cards, in order)

    private static func appendAssistantTurn(_ turn: DialogTurn, to out: NSMutableAttributedString,
                                            toolOutputLimit: Int, nextPrompt: String?) {
        if !turn.segments.isEmpty {
            for seg in turn.segments {
                switch seg {
                case .prose(_, let mdBlocks):
                    for b in mdBlocks { appendMarkdown(b, to: out) }
                case .tool(let tool):
                    guard !["TodoWrite", "Task"].contains(tool.name) else { break }
                    if tool.name == "AskUserQuestion" {
                        appendAskCard(tool, nextPrompt: nextPrompt, to: out)
                    } else {
                        appendToolCard(tool, to: out, outputLimit: toolOutputLimit)
                    }
                }
            }
        } else {
            for b in turn.blocks { appendMarkdown(b, to: out) }
            for tool in turn.toolUses where !["TodoWrite", "Task"].contains(tool.name) {
                appendToolCard(tool, to: out, outputLimit: toolOutputLimit)
            }
        }
    }

    // MARK: - Markdown blocks (app typography, print-scaled)

    private static func appendMarkdown(_ block: MarkdownBlock, to out: NSMutableAttributedString) {
        switch block {
        case .heading(let level, let text):
            if level <= 1 {
                out.append(inline(text, font: prose(12.5, .bold), color: ink,
                                  style: para(spacingBefore: 8, spacing: 4, lineSpacing: 2.5)))
            } else {
                out.append(inline(text, font: prose(10.5, .semibold), color: secondary,
                                  style: para(spacingBefore: 7, spacing: 4, lineSpacing: 2.5)))
            }
        case .paragraph(let text):
            out.append(inline(text, font: prose(10.5), color: ink,
                              style: para(spacing: 5, lineSpacing: 2.5)))
        case .bullet(let depth, let text):
            out.append(inline("•  " + text, font: prose(10.5), color: ink,
                              style: listPara(depth: depth)))
        case .numbered(let marker, let depth, let text):
            out.append(inline("\(marker)  " + text, font: prose(10.5), color: ink,
                              style: listPara(depth: depth)))
        case .quote(let text):
            out.append(inline("│  " + text, font: prose(10.5), color: secondary,
                              style: para(spacing: 3, indent: 8, lineSpacing: 2.5)))
        case .code(let lang, let lines):
            appendCodeCard(lang: lang, lines: lines, to: out)
        case .table(let header, let rows):
            appendPipeTable(header: header, rows: rows, to: out)
        }
    }

    private static func listPara(depth: Int) -> NSParagraphStyle {
        let p = para(spacing: 2.5, lineSpacing: 2.5)
        let base = CGFloat(6 + depth * 14)
        p.firstLineHeadIndent = base
        p.headIndent = base + 12
        return p
    }

    /// Inline spans (**bold**, *italic*, `code`, links) inside one block, with
    /// the app's span styling (code = mono on a light fill, links = accent).
    private static func inline(_ text: String, font: NSFont, color: NSColor,
                               style: NSParagraphStyle) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for span in Markdown.spans(text) {
            var attrs: [NSAttributedString.Key: Any] = [.paragraphStyle: style]
            if span.code {
                attrs[.font] = mono(max(8, font.pointSize - 1.5))
                attrs[.foregroundColor] = secondary
                attrs[.backgroundColor] = codeBg
            } else {
                var f = font
                var traits: NSFontTraitMask = []
                if span.bold { traits.insert(.boldFontMask) }
                if span.italic { traits.insert(.italicFontMask) }
                if !traits.isEmpty {
                    f = NSFontManager.shared.convert(f, toHaveTrait: traits)
                }
                attrs[.font] = f
                attrs[.foregroundColor] = span.link ? accent : color
            }
            out.append(NSAttributedString(string: span.text, attributes: attrs))
        }
        out.append(NSAttributedString(string: "\n", attributes: [
            .font: font, .paragraphStyle: style,
        ]))
        return out
    }

    // MARK: - Code card (header row with a language chip + the code body)

    private static func appendCodeCard(lang: String, lines: [String],
                                       to out: NSMutableAttributedString) {
        let table = NSTextTable()
        table.numberOfColumns = 1

        let head = cardCell(table: table, row: 0, bg: codeHeaderBg,
                            marginTop: 6, marginBottom: 0)
        head.setBorderColor(cardBorder)
        head.setWidth(0.5, type: .absoluteValueType, for: .border)
        let headPS = para(spacing: 0, lineSpacing: 0)
        headPS.textBlocks = [head]
        let headStr = NSMutableAttributedString(string: "● ", attributes: [
            .font: prose(7), .foregroundColor: green, .paragraphStyle: headPS,
        ])
        headStr.append(NSAttributedString(string: (lang.isEmpty ? "code" : lang) + "\n", attributes: [
            .font: mono(8.5), .foregroundColor: secondary, .paragraphStyle: headPS,
        ]))
        out.append(headStr)

        let body = cardCell(table: table, row: 1, bg: codeBg,
                            marginTop: 0, marginBottom: 6)
        body.setBorderColor(cardBorder)
        body.setWidth(0.5, type: .absoluteValueType, for: .border)
        let bodyPS = para(spacing: 0, lineSpacing: 1.5, charWrap: true)
        bodyPS.textBlocks = [body]
        out.append(NSAttributedString(string: lines.joined(separator: "\n") + "\n", attributes: [
            .font: mono(9), .foregroundColor: ink, .paragraphStyle: bodyPS,
        ]))
    }

    // MARK: - Tool card (dark terminal card: name, "> command", full output)

    /// The full command/input for the expanded card. `arg` is an 80-char
    /// one-line summary, so recover the complete value from the raw input JSON:
    /// Bash → the whole `command`; other tools → their input pretty-printed
    /// (without slash escaping).
    private static func fullCommand(_ tool: ToolUse) -> String {
        if let data = tool.rawInputJSON.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if tool.name == "Bash", let c = obj["command"] as? String { return c }
            if let d = try? JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
               let s = String(data: d, encoding: .utf8) { return s }
        }
        return tool.name == "Bash" ? tool.arg : (tool.input.isEmpty ? tool.arg : tool.input)
    }

    private static func appendToolCard(_ tool: ToolUse, to out: NSMutableAttributedString,
                                       outputLimit: Int) {
        let command = fullCommand(tool).trimmingCharacters(in: .whitespacesAndNewlines)
        var output = tool.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if outputLimit > 0, output.count > outputLimit {
            let dropped = output.count - outputLimit
            output = String(output.prefix(outputLimit)) + "\n… (\(dropped) more chars)"
        }

        let table = NSTextTable()
        table.numberOfColumns = 1

        let head = cardCell(table: table, row: 0, bg: termBg,
                            marginTop: 6, marginBottom: output.isEmpty ? 6 : 0)
        let headPS = para(spacing: 0, lineSpacing: 1.5, charWrap: true)
        headPS.textBlocks = [head]

        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: tool.name + "\n", attributes: [
            .font: mono(8, .semibold), .foregroundColor: termLabel, .paragraphStyle: headPS,
        ]))
        s.append(NSAttributedString(string: "> ", attributes: [
            .font: mono(9), .foregroundColor: termPrompt, .paragraphStyle: headPS,
        ]))
        s.append(NSAttributedString(string: (command.isEmpty ? "—" : command) + "\n", attributes: [
            .font: mono(9), .foregroundColor: termText, .paragraphStyle: headPS,
        ]))
        out.append(s)

        if !output.isEmpty {
            let body = cardCell(table: table, row: 1, bg: termBg,
                                marginTop: 0, marginBottom: 6)
            body.setBorderColor(termRule)
            body.setWidth(0.5, type: .absoluteValueType, for: .border, edge: .minY)
            let bodyPS = para(spacing: 0, lineSpacing: 1.5, charWrap: true)
            bodyPS.textBlocks = [body]
            out.append(NSAttributedString(string: output + "\n", attributes: [
                .font: mono(9), .foregroundColor: termOut, .paragraphStyle: bodyPS,
            ]))
        }
    }

    /// One full-width card row with a background fill and standard padding.
    private static func cardCell(table: NSTextTable, row: Int, bg: NSColor,
                                 marginTop: CGFloat, marginBottom: CGFloat) -> NSTextTableBlock {
        let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1,
                                    startingColumn: 0, columnSpan: 1)
        cell.backgroundColor = bg
        cell.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
        cell.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
        cell.setWidth(7, type: .absoluteValueType, for: .padding, edge: .minY)
        cell.setWidth(7, type: .absoluteValueType, for: .padding, edge: .maxY)
        cell.setWidth(marginTop, type: .absoluteValueType, for: .margin, edge: .minY)
        cell.setWidth(marginBottom, type: .absoluteValueType, for: .margin, edge: .maxY)
        return cell
    }

    // MARK: - AskUserQuestion card

    private struct AskOption: Decodable { let label: String }
    private struct AskQuestion: Decodable {
        let question: String
        let header: String?
        let options: [AskOption]?
    }
    private struct AskInput: Decodable { let questions: [AskQuestion]? }

    private static func appendAskCard(_ tool: ToolUse, nextPrompt: String?,
                                      to out: NSMutableAttributedString) {
        guard let data = tool.rawInputJSON.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(AskInput.self, from: data),
              let questions = parsed.questions, !questions.isEmpty else {
            appendToolCard(tool, to: out, outputLimit: 0)
            return
        }
        // `"Question"="Answer"` pairs from the result (or the follow-up prompt).
        let answerSrc = tool.output.isEmpty ? (nextPrompt ?? "") : tool.output
        var answers: [String: String] = [:]
        if let re = try? NSRegularExpression(pattern: "\"([^\"]+)\"=\"([^\"]*)\"") {
            let ns = answerSrc as NSString
            re.enumerateMatches(in: answerSrc, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m, m.numberOfRanges == 3 else { return }
                answers[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
            }
        }

        let table = NSTextTable()
        table.numberOfColumns = 1
        let cell = cardCell(table: table, row: 0, bg: askBg, marginTop: 6, marginBottom: 6)
        cell.setBorderColor(accent.withAlphaComponent(0.4))
        cell.setWidth(2, type: .absoluteValueType, for: .border, edge: .minX)

        func ps(_ spacing: CGFloat, before: CGFloat = 0) -> NSParagraphStyle {
            let p = para(spacingBefore: before, spacing: spacing, lineSpacing: 2)
            p.textBlocks = [cell]
            return p
        }

        for (qi, q) in questions.enumerated() {
            var chosen = answers[q.question]
            if chosen == nil, answers.count == 1, questions.count == 1 { chosen = answers.values.first }

            if let h = q.header, !h.isEmpty {
                out.append(NSAttributedString(string: h.uppercased() + "\n", attributes: [
                    .font: prose(7.5, .semibold), .foregroundColor: secondary,
                    .kern: 0.3, .paragraphStyle: ps(2, before: qi > 0 ? 8 : 0),
                ]))
            }
            out.append(NSAttributedString(string: q.question + "\n", attributes: [
                .font: prose(10.5, .semibold), .foregroundColor: ink, .paragraphStyle: ps(3),
            ]))
            if let chosen, !chosen.isEmpty {
                out.append(NSAttributedString(string: "✓ " + chosen + "\n", attributes: [
                    .font: prose(10.5, .medium), .foregroundColor: accent, .paragraphStyle: ps(3),
                ]))
            }
            if let opts = q.options, !opts.isEmpty {
                let line = NSMutableAttributedString()
                for (oi, opt) in opts.enumerated() {
                    if oi > 0 {
                        line.append(NSAttributedString(string: "   ", attributes: [
                            .font: prose(9), .paragraphStyle: ps(2),
                        ]))
                    }
                    let picked = matches(opt.label, chosen)
                    line.append(NSAttributedString(string: (picked ? "● " : "○ ") + opt.label, attributes: [
                        .font: prose(9, picked ? .semibold : .regular),
                        .foregroundColor: picked ? accent : tertiary,
                        .paragraphStyle: ps(2),
                    ]))
                }
                line.append(NSAttributedString(string: "\n", attributes: [
                    .font: prose(9), .paragraphStyle: ps(2),
                ]))
                out.append(line)
            }
        }
    }

    private static func matches(_ label: String, _ answer: String?) -> Bool {
        guard let answer, !answer.isEmpty else { return false }
        let l = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let a = answer.lowercased()
        return !l.isEmpty && (a == l || a.contains(l) || l.contains(a))
    }

    // MARK: - Markdown pipe table (quiet header + rows, like the app's grid)

    private static func appendPipeTable(header: [String], rows: [[String]],
                                        to out: NSMutableAttributedString) {
        let headPS = para(spacingBefore: 5, spacing: 2, lineSpacing: 1.5)
        out.append(NSAttributedString(string: header.map { $0.uppercased() }.joined(separator: "   ") + "\n",
                                      attributes: [
            .font: prose(7.5, .semibold), .foregroundColor: secondary,
            .kern: 0.3, .paragraphStyle: headPS,
        ]))
        let bodyPS = para(spacing: 2, lineSpacing: 1.5)
        for r in rows {
            out.append(NSAttributedString(string: r.joined(separator: "   ") + "\n", attributes: [
                .font: prose(9.5), .foregroundColor: secondary, .paragraphStyle: bodyPS,
            ]))
        }
        out.append(NSAttributedString(string: "\n", attributes: [
            .font: prose(4), .paragraphStyle: para(spacing: 3),
        ]))
    }

    // MARK: - Image attachments

    private static func appendImages(_ turn: DialogTurn, sessionImages: [NSImage],
                                     to out: NSMutableAttributedString) {
        var images: [NSImage] = []
        if !turn.imagePaths.isEmpty {
            images = turn.imagePaths.compactMap { NSImage(contentsOfFile: $0) }
        } else if turn.imageCount > 0, turn.imageStartIndex >= 0 {
            let end = min(turn.imageStartIndex + turn.imageCount, sessionImages.count)
            if turn.imageStartIndex < end {
                images = Array(sessionImages[turn.imageStartIndex..<end]).filter { $0.size.width > 1 }
            }
        }
        guard !images.isEmpty else {
            if turn.imageCount > 0 {
                out.append(NSAttributedString(string: "🖼 \(turn.imageCount) attachment(s)\n", attributes: [
                    .font: prose(9), .foregroundColor: secondary, .paragraphStyle: para(spacing: 4),
                ]))
            }
            return
        }
        let ps = para(spacingBefore: 4, spacing: 6)
        let s = NSMutableAttributedString()
        let single = images.count == 1
        for (i, img) in images.enumerated() {
            guard img.size.width > 0, img.size.height > 0 else { continue }
            let maxW: CGFloat = single ? 340 : 180
            let maxH: CGFloat = single ? 280 : 150
            let k = min(1, min(maxW / img.size.width, maxH / img.size.height))
            let att = NSTextAttachment()
            att.image = img
            att.bounds = NSRect(x: 0, y: 0, width: img.size.width * k, height: img.size.height * k)
            if i > 0 { s.append(NSAttributedString(string: "  ", attributes: [.paragraphStyle: ps])) }
            s.append(NSAttributedString(attachment: att))
        }
        s.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: s.length))
        s.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: ps]))
        out.append(s)
    }

    // MARK: - PDF writing

    /// Lay the attributed transcript out at page width and print it to a PDF
    /// file. Must run on the main thread (NSPrintOperation / NSTextView).
    @MainActor
    static func write(_ transcript: NSAttributedString, to url: URL) -> Bool {
        let pi = NSPrintInfo()
        pi.paperSize = NSSize(width: 595.28, height: 841.89)   // A4; matches contentWidth
        pi.topMargin = 42; pi.bottomMargin = 42
        pi.leftMargin = 46; pi.rightMargin = 46
        pi.horizontalPagination = .fit
        pi.verticalPagination = .automatic
        pi.isHorizontallyCentered = false
        pi.isVerticallyCentered = false
        pi.jobDisposition = .save
        pi.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let width = pi.paperSize.width - pi.leftMargin - pi.rightMargin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(transcript)
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc)
            textView.frame = NSRect(x: 0, y: 0, width: width, height: max(100, used.height))
        }

        let op = NSPrintOperation(view: textView, printInfo: pi)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        return op.run()
    }
}

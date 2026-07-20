import SwiftUI

/// A render group derived from a turn's ordered segments: a prose run, a run of
/// adjacent tool calls (collapsed into one strip), or an AskUserQuestion card.
enum SegmentGroup: Identifiable {
    case prose(id: String, blocks: [MarkdownBlock])
    case tools(id: String, [ToolUse])
    case ask(ToolUse)

    var id: String {
        switch self {
        case .prose(let id, _): return id
        case .tools(let id, _): return id
        case .ask(let t): return "ask-\(t.id.uuidString)"
        }
    }
}

/// One conversation block: a user prompt and the run of Claude turns it produced.
/// This is the scroll/navigation unit — its top is the scroll anchor.
struct BlockView: View {
    let block: DialogBlock
    let tokens: [String]
    let focusedID: String?
    /// Vertical air between turns within this block (tunable, 8–40px).
    var air: CGFloat = 18
    /// Per-turn image slices, keyed by turn id.
    var images: [String: [NSImage]] = [:]
    /// The next block's user prompt — the answer to an AskUserQuestion here.
    var nextPrompt: String? = nil

    @Environment(\.s) private var s

    var body: some View {
        VStack(alignment: .leading, spacing: s(air)) {
            ForEach(block.turns) { turn in
                TurnView(turn: turn, tokens: tokens,
                         isFocused: block.hasPrompt && turn.id == block.id && focusedID == block.id,
                         images: images[turn.id] ?? [],
                         nextPrompt: nextPrompt)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TurnView: View {
    let turn: DialogTurn
    let tokens: [String]
    let isFocused: Bool
    /// Lazily-loaded inline images belonging to this turn (may be empty while
    /// they're still decoding off-thread).
    var images: [NSImage] = []
    var nextPrompt: String? = nil

    @Environment(\.uiScale) private var scale
    @Environment(\.s) private var s
    @Environment(\.editPrompt) private var editPrompt
    /// Cursor is over the prompt heading — reveals the edit (pencil) button.
    @State private var hovering = false

    private var isUser: Bool { turn.role == .user }

    var body: some View {
        if isUser {
            // A user prompt renders as a section heading: an accent/grey rule down
            // the left, the prompt text at 15/600, the time to the right — no
            // avatar, no "You". (Matches the design mock.) Pasted images hang
            // beneath the heading.
            VStack(alignment: .leading, spacing: s(8)) {
                userHeading
                attachmentImages
            }
        } else {
            // Claude's reply: just the prose, flush under the prompt above it.
            turnBody
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Attached images for this turn. The session-wide slice (`images`) is the
    /// authority once decoded: it covers base64 images AND cache-file refs in one
    /// aligned sequence, with dead refs already recovered from their base64 twins
    /// (Loader.loadImages). Until it arrives, file refs render directly from disk.
    @ViewBuilder
    private var attachmentImages: some View {
        if !images.isEmpty {
            ImageTiles(images: images)
        } else if !turn.imagePaths.isEmpty {
            InlineImages(paths: turn.imagePaths)
        }
        // turn.imageCount > 0 with nothing yet: base64 still decoding off-thread.
    }

    /// User prompt as a left-ruled heading row, with the body (if any longer than
    /// one line) flowing beneath at body size.
    private var userHeading: some View {
        HStack(alignment: .firstTextBaseline, spacing: s(10)) {
            // Заголовок промпта: обрезаем гигантский текст (срезы контекста
            // тимлида бывают на сотни КБ) — typesetter иначе вешает main-thread.
            Text(MessageContent.clampHead(turn.bodyText))
                .font(.system(size: 15 * scale, weight: .semibold))
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            // Pencil on hover: the primary way into the prompt editor (the text
            // itself is selection-enabled, so right-click there shows the system
            // selection menu, not our contextMenu).
            Button { editPrompt(turn.id) } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 12 * scale, weight: .medium))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .buttonStyle(.plain)
            .help("Edit Prompt")
            .opacity(hovering ? 1 : 0)
            .layoutPriority(1)
            if let ts = turn.timestamp {
                Text(Format.timeOrDate(ts))
                    .font(.system(size: 11 * scale)).foregroundStyle(Theme.tertiaryText)
                    .layoutPriority(1)
            }
        }
        .padding(.vertical, s(2)).padding(.leading, s(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(isFocused ? Theme.accent : Theme.rule)
                .frame(width: s(2.5))
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Edit Prompt…") { editPrompt(turn.id) }
        }
    }

    @ViewBuilder
    /// Group the ordered segments so consecutive tool calls collapse into one
    /// strip (e.g. Read³ · Edit) while keeping prose runs in their place.
    private var groupedSegments: [SegmentGroup] {
        var out: [SegmentGroup] = []
        for seg in turn.segments {
            switch seg {
            case .prose(let id, let blocks):
                out.append(.prose(id: id, blocks: blocks))
            case .tool(let t):
                // Noise tools never shown (todo lists, reminders).
                if ToolChip.isHidden(t.name) { break }
                // AskUserQuestion is always its own rich card, never merged.
                if t.name == "AskUserQuestion" {
                    out.append(.ask(t))
                } else if case .tools(let id, var arr)? = out.last {
                    arr.append(t); out[out.count - 1] = .tools(id: id, arr)
                } else {
                    out.append(.tools(id: "tg-\(t.id.uuidString)", [t]))
                }
            }
        }
        return out
    }

    @ViewBuilder
    private var turnBody: some View {
        VStack(alignment: .leading, spacing: s(10)) {
            if turn.segments.isEmpty {
                // Fallback (e.g. user prompts): the old flat block list.
                ForEach(turn.blocks) { block in
                    MarkdownBlockView(block: block, tokens: tokens)
                }
            } else {
                ForEach(groupedSegments) { group in
                    switch group {
                    case .prose(_, let blocks):
                        VStack(alignment: .leading, spacing: s(10)) {
                            ForEach(blocks) { block in
                                MarkdownBlockView(block: block, tokens: tokens)
                            }
                        }
                    case .tools(_, let tools):
                        // Tool calls as wrapping chips (one per call).
                        FlowLayout(spacing: s(6), lineSpacing: s(6)) {
                            ForEach(tools) { ToolChip(tool: $0) }
                        }
                    case .ask(let tool):
                        AskUserQuestionCard(tool: tool, selectedAnswer: nextPrompt)
                    }
                }
            }
            attachmentImages
        }
    }
}

/// Loads image files from disk by path and lays them out as a wrapping row of
/// thumbnails (a single image renders larger). Decoding happens off the main
/// thread; missing files are skipped.
/// A wrapping row of already-decoded images (a single image renders larger).
/// An invalid slot (an attachment that could not be recovered) shows an
/// explicit "unavailable" tile so it never disappears silently.
struct ImageTiles: View {
    let images: [NSImage]
    @Environment(\.s) private var s

    private var single: Bool { images.count == 1 }

    var body: some View {
        FlowLayout(spacing: s(8), lineSpacing: s(8)) {
            ForEach(Array(images.enumerated()), id: \.offset) { _, img in
                if img.size.width > 1 {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: s(single ? 460 : 260), maxHeight: s(single ? 380 : 220))
                        .clipShape(RoundedRectangle(cornerRadius: s(8)))
                        .overlay(RoundedRectangle(cornerRadius: s(8))
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                } else {
                    RoundedRectangle(cornerRadius: s(8))
                        .fill(Color.primary.opacity(0.04))
                        .frame(width: s(single ? 200 : 120), height: s(single ? 140 : 90))
                        .overlay(RoundedRectangle(cornerRadius: s(8))
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                        .overlay {
                            VStack(spacing: s(5)) {
                                Image(systemName: "photo.badge.exclamationmark")
                                    .font(.system(size: 16))
                                    .foregroundStyle(Theme.tertiaryText)
                                Text("Image unavailable")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Theme.tertiaryText)
                            }
                        }
                }
            }
        }
    }
}

struct InlineImages: View {
    let paths: [String]
    @State private var loaded: [String: NSImage] = [:]
    /// Paths that were attempted and produced no image (deleted screenshots are
    /// common) — shown as an explicit "unavailable" tile, not an eternal spinner.
    @State private var failed: Set<String> = []
    @Environment(\.s) private var s

    private var single: Bool { paths.count == 1 }
    private var maxDim: CGFloat { single ? 460 : 200 }

    var body: some View {
        FlowLayout(spacing: s(8), lineSpacing: s(8)) {
            ForEach(paths, id: \.self) { path in
                if let img = loaded[path], img.size.width > 1 {
                    Image(nsImage: img)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: s(maxDim), maxHeight: s(single ? 380 : 200))
                        .clipShape(RoundedRectangle(cornerRadius: s(8)))
                        .overlay(RoundedRectangle(cornerRadius: s(8))
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                } else {
                    RoundedRectangle(cornerRadius: s(8))
                        .fill(Color.primary.opacity(0.04))
                        .frame(width: s(single ? 200 : 120), height: s(single ? 140 : 90))
                        .overlay(RoundedRectangle(cornerRadius: s(8))
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                        .overlay {
                            if failed.contains(path) {
                                VStack(spacing: s(5)) {
                                    Image(systemName: "photo.badge.exclamationmark")
                                        .font(.system(size: 16))
                                        .foregroundStyle(Theme.tertiaryText)
                                    Text("Image unavailable")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Theme.tertiaryText)
                                }
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                }
            }
        }
        .task(id: paths) {
            for p in paths where loaded[p] == nil && !failed.contains(p) {
                if let img = await Self.load(p) {
                    await MainActor.run { loaded[p] = img }
                } else {
                    await MainActor.run { _ = failed.insert(p) }
                }
            }
        }
    }

    private static func load(_ path: String) async -> NSImage? {
        await Task.detached(priority: .utility) { NSImage(contentsOfFile: path) }.value
    }
}

// MARK: - Markdown block rendering

struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let tokens: [String]

    @Environment(\.uiScale) private var scale
    @Environment(\.s) private var s

    /// Body text size and leading, tuned to the mock (14px / 1.55–1.6), scaled.
    private var bodySize: CGFloat { 14 * scale }
    private var bodyLeading: CGFloat { 5 * scale }

    var body: some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text, size: (level <= 1 ? 16 : 13.5) * scale,
                       weight: level <= 1 ? .bold : .semibold,
                       color: level <= 1 ? .primary : .secondary)
                .padding(.top, s(6))
        case .paragraph(let text):
            if MessageContent.isOversized(text) {
                OversizedProse(text: text, tokens: tokens, size: bodySize,
                               weight: .regular, color: .primary, leading: bodyLeading)
            } else {
                inlineText(text, size: bodySize, weight: .regular, color: .primary)
                    .lineSpacing(bodyLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        case .bullet(let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: s(8)) {
                Text("•").font(DialogFonts.prose(size: bodySize)).foregroundStyle(Theme.secondaryText)
                inlineText(text, size: bodySize, weight: .regular, color: .primary)
                    .lineSpacing(bodyLeading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, s(CGFloat(depth) * 18))
        case .numbered(let marker, let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: s(8)) {
                Text(marker).font(DialogFonts.prose(size: bodySize)).foregroundStyle(Theme.secondaryText)
                inlineText(text, size: bodySize, weight: .regular, color: .primary)
                    .lineSpacing(bodyLeading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, s(CGFloat(depth) * 18))
        case .quote(let text):
            HStack(alignment: .top, spacing: s(9)) {
                RoundedRectangle(cornerRadius: s(1.5))
                    .fill(Color.primary.opacity(0.18)).frame(width: s(3))
                inlineText(text, size: bodySize, weight: .regular, color: Theme.secondaryText)
                    .lineSpacing(bodyLeading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(let lang, let lines):
            CodeBlock(lang: lang, lines: lines)
        case .table(let header, let rows):
            TableBlock(header: header, rows: rows)
        }
    }

    /// Build a styled AttributedString from inline spans (bold/italic/code/link),
    /// then paint a yellow background on every search-token hit so matches are
    /// visible in the conversation, like the mock.
    private func inlineText(_ text: String, size: CGFloat, weight: Font.Weight,
                            color: Color) -> Text {
        var out = Markdown.attributed(
            text, size: size, weight: weight, color: color,
            codeColor: .secondary, codeBg: Theme.codeBg, linkColor: Theme.accent)
        if !tokens.isEmpty { applyHighlight(&out) }
        return Text(out)
    }

    /// Highlight each search token (case-insensitive) with a yellow background.
    private func applyHighlight(_ attr: inout AttributedString) {
        let lower = String(attr.characters).lowercased()
        for token in tokens where !token.isEmpty {
            var start = lower.startIndex
            while let r = lower.range(of: token, range: start..<lower.endIndex) {
                let lo = lower.distance(from: lower.startIndex, to: r.lowerBound)
                let hi = lower.distance(from: lower.startIndex, to: r.upperBound)
                let aLo = attr.index(attr.startIndex, offsetByCharacters: lo)
                let aHi = attr.index(attr.startIndex, offsetByCharacters: hi)
                attr[aLo..<aHi].backgroundColor = Theme.highlight
                start = r.upperBound
            }
        }
    }
}

/// Огромный prose-блок: по умолчанию рендерим только первые `maxRenderChars`
/// (typesetter не вешает main-thread), с кнопкой развернуть полностью. Разворот
/// предупреждает, что отрисовка большого текста может на секунды подвиснуть.
private struct OversizedProse: View {
    let text: String
    let tokens: [String]
    let size: CGFloat
    let weight: Font.Weight
    let color: Color
    let leading: CGFloat

    @State private var expanded = false
    @Environment(\.s) private var s

    private var hiddenKB: Int { (text.count - MessageContent.maxRenderChars) / 1024 }

    var body: some View {
        VStack(alignment: .leading, spacing: s(8)) {
            Text(styled(expanded ? text : MessageContent.clampHead(text)))
                .lineSpacing(leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !expanded {
                Button {
                    expanded = true
                } label: {
                    Label("Показать полностью (~\(hiddenKB) КБ) — может подвиснуть",
                          systemImage: "arrow.down.circle")
                        .font(.system(size: size * 0.92, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
        }
    }

    private func styled(_ t: String) -> AttributedString {
        var out = Markdown.attributed(
            t, size: size, weight: weight, color: color,
            codeColor: .secondary, codeBg: Theme.codeBg, linkColor: Theme.accent)
        if !tokens.isEmpty {
            let lower = String(out.characters).lowercased()
            for token in tokens where !token.isEmpty {
                var start = lower.startIndex
                while let r = lower.range(of: token, range: start..<lower.endIndex) {
                    let lo = lower.distance(from: lower.startIndex, to: r.lowerBound)
                    let hi = lower.distance(from: lower.startIndex, to: r.upperBound)
                    let aLo = out.index(out.startIndex, offsetByCharacters: lo)
                    let aHi = out.index(out.startIndex, offsetByCharacters: hi)
                    out[aLo..<aHi].backgroundColor = Theme.highlight
                    start = r.upperBound
                }
            }
        }
        return out
    }
}

/// Renders a markdown pipe-table as an aligned grid with a header row.
struct TableBlock: View {
    let header: [String]
    let rows: [[String]]

    @Environment(\.uiScale) private var scale
    @Environment(\.s) private var s

    private var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        // Modern, borderless table: no outer box, no cell grid lines. Just a
        // quiet uppercase header with a hairline underline and very light zebra
        // striping for row legibility.
        VStack(spacing: 0) {
            gridRow(header, isHeader: true)
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                gridRow(row, isHeader: false)
                    .background(idx % 2 == 1 ? Color.primary.opacity(0.025) : Color.clear)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: s(6)))
        .fixedSize(horizontal: false, vertical: true)
        .help("\(columnCount) columns")
    }

    private func cellText(_ value: String, isHeader: Bool) -> Text {
        if isHeader {
            // Quiet uppercase column labels (tabular-data convention).
            return Text(value.uppercased())
                .font(.system(size: 10 * scale, weight: .semibold))
                .foregroundColor(Theme.sectionLabel)
                .tracking(0.3)
        }
        // Render markdown inside body cells (bold/italic/`code`/links).
        return Text(Markdown.attributed(
            value, size: 12 * scale, weight: .regular, color: .secondary,
            codeColor: .secondary, codeBg: Theme.codeBg, linkColor: Theme.accent))
    }

    private func gridRow(_ cells: [String], isHeader: Bool) -> some View {
        HStack(spacing: s(14)) {
            ForEach(0..<columnCount, id: \.self) { c in
                cellText(c < cells.count ? cells[c] : "", isHeader: isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, s(4))
        .padding(.vertical, isHeader ? s(4) : s(6))
    }
}

// MARK: - AskUserQuestion

/// Rich rendering of an AskUserQuestion tool call: each question with its header
/// chip, the prompt text, and the offered options as quiet chips — instead of
/// raw JSON. Parsed from the tool's raw input.
struct AskUserQuestionCard: View {
    let tool: ToolUse
    /// The user's reply that followed this question (to mark the chosen option).
    var selectedAnswer: String? = nil

    @Environment(\.uiScale) private var scale
    @Environment(\.s) private var s

    private struct Option: Decodable { let label: String; let description: String? }
    private struct Question: Decodable {
        let question: String
        let header: String?
        let options: [Option]?
    }
    private struct Input: Decodable { let questions: [Question]? }

    private var questions: [Question] {
        guard let data = tool.rawInputJSON.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(Input.self, from: data) else { return [] }
        return parsed.questions ?? []
    }

    /// Parse the tool result — `"Question"="Answer", "Q2"="A2"` — into a map.
    private var answers: [String: String] {
        let src = tool.output.isEmpty ? (selectedAnswer ?? "") : tool.output
        guard !src.isEmpty else { return [:] }
        var out: [String: String] = [:]
        let re = try? NSRegularExpression(pattern: "\"([^\"]+)\"=\"([^\"]*)\"")
        let ns = src as NSString
        re?.enumerateMatches(in: src, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.numberOfRanges == 3 else { return }
            out[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
        }
        return out
    }

    private func answer(for q: Question) -> String? {
        let a = answers
        if let exact = a[q.question] { return exact }
        // Fallback: single-question case → take the only answer.
        if a.count == 1, questions.count == 1 { return a.values.first }
        return nil
    }

    var body: some View {
        let a = answers
        VStack(alignment: .leading, spacing: s(13)) {
            ForEach(Array(questions.enumerated()), id: \.offset) { _, q in
                let chosenText = answer(for: q)
                VStack(alignment: .leading, spacing: s(6)) {
                    if let h = q.header, !h.isEmpty {
                        Text(h.uppercased())
                            .font(.system(size: 10 * scale, weight: .semibold)).tracking(0.3)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Text(q.question)
                        .font(.system(size: 13 * scale, weight: .semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    // The user's actual answer — the most important line. Full text.
                    if let chosenText, !chosenText.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: s(6)) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11 * scale)).foregroundStyle(Theme.accent)
                            Text(chosenText)
                                .font(.system(size: 13 * scale, weight: .medium))
                                .foregroundStyle(Theme.accent)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    // Offered options as quiet inline chips (the chosen one bold).
                    if let opts = q.options, !opts.isEmpty {
                        FlowLayout(spacing: s(5), lineSpacing: s(5)) {
                            ForEach(Array(opts.enumerated()), id: \.offset) { _, opt in
                                let picked = matches(opt.label, chosenText)
                                Text(opt.label)
                                    .font(.system(size: 11 * scale, weight: picked ? .semibold : .regular))
                                    .foregroundStyle(picked ? Theme.accent : Theme.tertiaryText)
                                    .padding(.horizontal, s(7)).padding(.vertical, s(2))
                                    .background(picked ? Theme.accent.opacity(0.1) : Color.primary.opacity(0.04),
                                                in: Capsule())
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, s(10)).padding(.horizontal, s(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.accent.opacity(0.4)).frame(width: s(2))
        }
        .background(Color.primary.opacity(0.02))
        .id(a.count)   // re-eval when answers resolve
    }

    private func matches(_ label: String, _ answer: String?) -> Bool {
        guard let answer, !answer.isEmpty else { return false }
        let l = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let a = answer.lowercased()
        return !l.isEmpty && (a == l || a.contains(l) || l.contains(a))
    }
}

struct CodeBlock: View {
    let lang: String
    let lines: [String]

    @Environment(\.uiScale) private var scale
    @Environment(\.s) private var s

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: s(7)) {
                Circle().fill(Color(hex: 0x34C759)).frame(width: s(8), height: s(8))
                Text(lang.isEmpty ? "code" : lang)
                    .font(.system(size: 11.5 * scale, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Image(systemName: "doc.on.doc").font(.system(size: 11 * scale))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, s(12)).padding(.vertical, s(7))
            .background(Theme.codeBg)
            Divider()
            Text(lines.joined(separator: "\n"))
                .font(DialogFonts.mono(size: 12.5 * scale))
                .lineSpacing(s(3))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, s(14)).padding(.vertical, s(12))
                .textSelection(.enabled)
        }
        .background(Theme.cardBg)
        .overlay(RoundedRectangle(cornerRadius: s(10)).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: s(10)))
    }
}

// MARK: - Tool chip
//
// One compact chip per tool call. Read/Write/Edit → file name; Bash → first two
// words of the command; Grep/Glob/WebSearch/WebFetch → an icon + short arg.
// Click expands to the full command (dark, terminal-like); click again adds the
// output. TodoWrite / reminders are hidden entirely.

struct ToolChip: View {
    let tool: ToolUse
    /// Collapsed (chip) vs expanded (card). The chip grows in place.
    @State private var expanded = false
    /// Whether the output is shown in full (when it exceeds the preview lines).
    @State private var outputFull = false

    @Environment(\.uiScale) private var scale
    @Environment(\.s) private var s

    private static let outputPreviewLines = 3

    /// Tools we never render.
    static func isHidden(_ name: String) -> Bool {
        ["TodoWrite", "Task"].contains(name)
    }

    /// File-path tools whose chip shows just the basename.
    private static let fileTools: Set<String> =
        ["Read", "Write", "Edit", "MultiEdit", "NotebookEdit"]

    /// SF Symbol for tools shown as an icon (else nil → text name).
    private var icon: String? {
        switch tool.name {
        case "Grep": return "doc.text.magnifyingglass"
        case "Glob": return "magnifyingglass"
        case "WebSearch": return "magnifyingglass.circle"
        case "WebFetch": return "globe"
        case "Bash": return "terminal"
        default: return nil
        }
    }

    private func basename(_ p: String) -> String {
        (p as NSString).lastPathComponent
    }

    /// First two words of a shell command.
    private func firstWords(_ cmd: String, _ n: Int = 2) -> String {
        cmd.split(whereSeparator: { $0 == " " || $0 == "\n" }).prefix(n).joined(separator: " ")
    }

    /// The chip's label (collapsed).
    private var label: String {
        if Self.fileTools.contains(tool.name) {
            return tool.arg.isEmpty ? tool.name : basename(tool.arg)
        }
        if tool.name == "Bash" {
            return tool.arg.isEmpty ? "bash" : firstWords(tool.arg)
        }
        // Grep/Glob/WebSearch/WebFetch → short arg (icon carries the meaning).
        if icon != nil, !tool.arg.isEmpty { return MessageContent.oneLine(tool.arg, max: 28) }
        // Everything else: name + short arg.
        return tool.arg.isEmpty ? tool.name : "\(tool.name) · \(MessageContent.oneLine(tool.arg, max: 24))"
    }

    /// Full command / input to reveal at level 1.
    private var commandText: String {
        tool.name == "Bash" ? tool.arg : (tool.input.isEmpty ? tool.arg : tool.input)
    }

    private var outputLineCount: Int {
        tool.output.isEmpty ? 0 : tool.output.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    var body: some View {
        if expanded {
            expandedCard
        } else {
            chip
        }
    }

    // Collapsed pill.
    private var chip: some View {
        Button { expanded = true } label: {
            HStack(spacing: s(5)) {
                if let icon { Image(systemName: icon).font(.system(size: 10.5 * scale)) }
                Text(label)
                    .font(DialogFonts.mono(size: 11.5 * scale, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, s(9)).padding(.vertical, s(4))
            .background(Color.primary.opacity(0.05), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // The chip grown into a card. No dedicated icon row — the command sits on the
    // first line prefixed with "> ", so no line is wasted. Click anywhere on the
    // command to collapse. Text wraps (by character) and is never truncated.
    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Non-Bash: a small label so it's clear which tool this is.
            if tool.name != "Bash", icon == nil {
                Text(tool.name)
                    .font(DialogFonts.mono(size: 10 * scale, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x9AA0AA))
                    .padding(.horizontal, s(11)).padding(.top, s(8))
            }
            Button { expanded = false } label: {
                HStack(alignment: .top, spacing: s(5)) {
                    Text(">")
                        .foregroundStyle(Color(hex: 0x7AA2F7))
                    Text(commandText)
                        .foregroundStyle(Color(hex: 0xE6E6E6))
                        .multilineTextAlignment(.leading)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(DialogFonts.mono(size: 11 * scale))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .textSelection(.enabled)
            .padding(.horizontal, s(11)).padding(.vertical, s(9))

            if !tool.output.isEmpty {
                Divider().overlay(Color.white.opacity(0.12))
                Text(outputFull ? tool.output : previewOutput)
                    .font(DialogFonts.mono(size: 11 * scale))
                    .foregroundStyle(Color(hex: 0xC2C2C2))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, s(11)).padding(.vertical, s(9))
                // Output longer than the preview → reveal the rest on click.
                if outputLineCount > Self.outputPreviewLines {
                    Button { outputFull.toggle() } label: {
                        Text(outputFull ? "Collapse output" : "Show full output (\(outputLineCount) lines)")
                            .font(.system(size: 10.5 * scale))
                            .foregroundStyle(Color(hex: 0x8AB4F8))
                            .padding(.horizontal, s(11)).padding(.bottom, s(9))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(Color(hex: 0x1E1E1E), in: RoundedRectangle(cornerRadius: s(9)))
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// First N lines of the output.
    private var previewOutput: String {
        let lines = tool.output.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > Self.outputPreviewLines else { return tool.output }
        return lines.prefix(Self.outputPreviewLines).joined(separator: "\n")
    }
}

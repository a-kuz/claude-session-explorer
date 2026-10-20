import Foundation
import AppKit

/// One row of the jump palette: a session from the library, a running process,
/// or both when the running process's session is in the library.
struct PaletteItem: Identifiable {
    let id: String
    let meta: SessionMeta?
    let live: LiveSession?
    let title: String
    let projectLabel: String
    let projectPath: String
    let subtitle: String
    let when: Date
    let score: Double
}

enum Palette {
    static let maxRows = 60

    /// Ranks library sessions and live processes against a free-text query.
    /// Empty query: only the sessions that are generating right now, by recency
    /// (`showAll` lifts that to every session). Otherwise every whitespace token must match the
    /// row (title, project, peer name, last prompt, id); the score prefers
    /// word-prefix hits in the title, then a fuzzy subsequence, then recency.
    static func rank(query: String, sessions: [SessionMeta],
                     live: [String: LiveSession], showAll: Bool = false,
                     now: Date = Date()) -> [PaletteItem] {
        let tokens = query.lowercased()
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var items: [PaletteItem] = []
        var seenLive = Set<String>()

        let busyOnly = tokens.isEmpty && !showAll
        for meta in sessions {
            let l = live[meta.id]
            if l != nil { seenLive.insert(meta.id) }
            if busyOnly, l?.status != "busy" { continue }
            let title = AutoTitle.displayTitle(meta)
            let when = [meta.mtime, meta.lastActivity ?? .distantPast, l?.updatedAt ?? .distantPast].max()!
            let fields = Fields(title: title, project: meta.projectLabel + " " + meta.projectPath,
                                name: l?.name ?? "", body: meta.lastUserText, id: meta.id)
            guard let s = score(tokens, fields) else { continue }
            items.append(PaletteItem(
                id: meta.id, meta: meta, live: l, title: title,
                projectLabel: meta.projectLabel, projectPath: meta.projectPath,
                subtitle: meta.lastUserText, when: when,
                score: s + recency(when, now: now) + (l.map { liveBonus($0) } ?? 0)))
        }
        // Processes whose session has no jsonl in the library yet (just started).
        for (sid, l) in live where !seenLive.contains(sid) && (!busyOnly || l.status == "busy") {
            let label = (l.cwd as NSString).lastPathComponent
            let fields = Fields(title: l.name, project: label + " " + l.cwd, name: l.name, body: "", id: sid)
            guard let s = score(tokens, fields) else { continue }
            items.append(PaletteItem(
                id: sid, meta: nil, live: l, title: label,
                projectLabel: label, projectPath: l.cwd, subtitle: "running, no transcript yet",
                when: l.updatedAt, score: s + recency(l.updatedAt, now: now) + liveBonus(l)))
        }

        items.sort { a, b in
            if !tokens.isEmpty, a.score != b.score { return a.score > b.score }
            return a.when > b.when
        }
        return Array(items.prefix(maxRows))
    }

    private struct Fields {
        let title: String, project: String, name: String, body: String, id: String
    }

    /// nil = some token matched nothing. Each token is also tried as typed in
    /// the other keyboard layout (ЙЦУКЕН ↔ QWERTY), so a query typed before
    /// switching layouts still finds the session.
    private static func score(_ tokens: [String], _ f: Fields) -> Double? {
        if tokens.isEmpty { return 0 }
        var total = 0.0
        for t in tokens {
            let direct = scoreToken(t, f)
            let swapped = swapLayout(t)
            let alt = swapped == t ? nil : scoreToken(swapped, f).map { $0 - 0.1 }
            guard let best = [direct, alt].compactMap({ $0 }).max() else { return nil }
            total += best
        }
        return total
    }

    private static let ruRow = Array("йцукенгшщзхъфывапролджэячсмитьбю.ёЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,Ё")
    private static let enRow = Array("qwertyuiop[]asdfghjkl;'zxcvbnm,./`QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>?~")
    private static let ru2en: [Character: Character] = Dictionary(uniqueKeysWithValues: zip(ruRow, enRow))
    private static let en2ru: [Character: Character] = Dictionary(uniqueKeysWithValues: zip(enRow, ruRow))

    static func swapLayout(_ s: String) -> String {
        let hasCyrillic = s.unicodeScalars.contains { $0.value >= 0x400 && $0.value <= 0x4FF }
        let map = hasCyrillic ? ru2en : en2ru
        return String(s.map { map[$0] ?? $0 }).lowercased()
    }

    private static func scoreToken(_ t: String, _ f: Fields) -> Double? {
        let title = f.title.lowercased(), project = f.project.lowercased()
        let name = f.name.lowercased(), body = f.body.lowercased(), id = f.id.lowercased()
        var best = 0.0
        if title.hasPrefix(t) { best = 5 }
        else if wordPrefix(title, t) { best = 4 }
        else if title.contains(t) { best = 3 }
        if name.hasPrefix(t) { best = max(best, 4) }
        else if name.contains(t) { best = max(best, 3) }
        if wordPrefix(project, t) { best = max(best, 2.5) }
        else if project.contains(t) { best = max(best, 2) }
        if id.hasPrefix(t) { best = max(best, 3) }
        if best == 0, body.contains(t) { best = 1 }
        if best == 0, t.count >= 3, subsequence(t, in: title) || subsequence(t, in: name) { best = 0.6 }
        return best == 0 ? nil : best
    }

    private static func wordPrefix(_ s: String, _ t: String) -> Bool {
        var atWordStart = true
        var idx = s.startIndex
        while idx < s.endIndex {
            if atWordStart, s[idx...].hasPrefix(t) { return true }
            atWordStart = !(s[idx].isLetter || s[idx].isNumber)
            idx = s.index(after: idx)
        }
        return false
    }

    private static func subsequence(_ t: String, in s: String) -> Bool {
        var it = t.makeIterator()
        var need = it.next()
        for c in s {
            if need == nil { return true }
            if c == need { need = it.next() }
        }
        return need == nil
    }

    /// 0…1.5, fading over about a week.
    private static func recency(_ d: Date, now: Date) -> Double {
        let hours = max(0, now.timeIntervalSince(d) / 3600)
        return 1.5 * exp(-hours / 72)
    }

    private static func liveBonus(_ l: LiveSession) -> Double {
        switch l.status {
        case "waiting": return 2.5
        case "busy": return 2
        default: return 1.5
        }
    }
}

// MARK: - Preview

/// The last block of a transcript, built by the same turn pipeline as the
/// transcript view (brief mode): the prompt that led it and Claude's turns.
struct PalettePreview {
    let promptTurn: DialogTurn?
    /// Images pasted into the prompt (base64 or cache-file refs).
    let promptImages: [NSImage]
    /// Fallback heading when the prompt lies before the chunk that was read.
    let promptText: String
    let responses: [DialogTurn]
}

extension Palette {
    static let previewTailSteps: [UInt64] = [400_000, 2_000_000, 8_000_000, 32_000_000]

    /// Reads only the file tail; the first line of the chunk is usually cut
    /// mid-record and is skipped by the parser. The window widens in steps
    /// until the last block comes with its prompt.
    static func loadPreview(_ meta: SessionMeta) -> PalettePreview? {
        guard !meta.filePath.isEmpty else { return nil }
        let len = Loader.fileLength(meta.filePath)
        var block: DialogBlock?
        var chunk = ""
        for bytes in previewTailSteps {
            let from = len > bytes ? len - bytes : 0
            guard let tail = Loader.loadDialogTail(meta.filePath, fromOffset: from) else { return nil }
            chunk = tail.text
            let blocks = DialogBlock.build(from: DialogTurn.build(from: tail.messages, brief: true))
            block = blocks.last(where: \.hasPrompt) ?? blocks.last
            // A prompt with a pasted image is one multi-megabyte line: keep
            // widening until the block actually starts with its prompt.
            if block?.hasPrompt == true || from == 0 { break }
        }
        guard let block else { return nil }
        let prompt = block.promptTurn
        var promptImages: [NSImage] = []
        if let p = prompt, p.imageCount > 0, p.imageStartIndex >= 0 {
            let all = Loader.loadImages(in: chunk)
            let end = min(p.imageStartIndex + p.imageCount, all.count)
            if p.imageStartIndex < end { promptImages = Array(all[p.imageStartIndex..<end]) }
        }
        return PalettePreview(
            promptTurn: prompt,
            promptImages: promptImages,
            promptText: prompt?.bodyText ?? meta.lastUserText,
            responses: prompt == nil ? block.turns : Array(block.turns.dropFirst()))
    }
}

// Lazy auto-title generation. Port of src/lib/autotitle.ts — deterministic,
// no network/LLM, memoized per session id.

import Foundation

enum AutoTitle {
    private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    private static let leadingFiller = try! NSRegularExpression(
        pattern: "^(пожалуйста|плиз|please|можешь|could you|can you|нужно|надо|сделай|сделать|давай|let's|lets)\\s+",
        options: [.caseInsensitive])

    private static func clean(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        t = t.replacingOccurrences(of: "\\[Image #\\d+\\]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let range = NSRange(t.startIndex..., in: t)
        t = leadingFiller.stringByReplacingMatches(in: t, range: range, withTemplate: "")
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func firstClause(_ text: String, max: Int = 60) -> String {
        let t = clean(text)
        if t.isEmpty { return "" }
        var head = t
        if let r = t.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?\n")) {
            let end = t.distance(from: t.startIndex, to: r.lowerBound)
            if end > 8 && end <= max { head = String(t[..<r.lowerBound]) }
        }
        if head.count > max {
            let slice = String(head.prefix(max))
            if let lastSpace = slice.range(of: " ", options: .backwards),
               slice.distance(from: slice.startIndex, to: lastSpace.lowerBound) > max / 2 {
                head = String(slice[..<lastSpace.lowerBound]) + "…"
            } else {
                head = slice + "…"
            }
        }
        return head.trimmingCharacters(in: .whitespaces)
    }

    private static func capitalize(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + s.dropFirst()
    }

    /// Return a display title for a session — explicit if present, else generated.
    static func displayTitle(_ meta: SessionMeta) -> String {
        if let t = meta.title, !t.isEmpty { return t }
        lock.lock()
        if let cached = cache[meta.id] { lock.unlock(); return cached }
        lock.unlock()
        let source = meta.firstUserText.isEmpty ? meta.lastUserText : meta.firstUserText
        let generated = source.isEmpty ? "(пустая сессия)" : capitalize(firstClause(source))
        lock.lock()
        cache[meta.id] = generated
        lock.unlock()
        return generated
    }

    static func isAuto(_ meta: SessionMeta) -> Bool { meta.title == nil || meta.title?.isEmpty == true }
}

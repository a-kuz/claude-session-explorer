// Fast, incremental full-text search across sessions.
// Port of src/lib/search.ts (token AND-semantics + regex), two-tier matching.

import Foundation

struct SearchHit: Identifiable {
    var id: String { meta.id }
    let meta: SessionMeta
    let score: Double
    /// A short snippet around the first deep match, if the match was deep.
    let snippet: String?
}

enum Query {
    case empty
    case tokens([String])
    case regex(NSRegularExpression)
}

enum Search {
    static func parseQuery(_ query: String) -> Query {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .empty }
        // Regex form: /pattern/  (mirrors the TUI's query.ts convention)
        if trimmed.hasPrefix("/"), trimmed.count > 2, trimmed.hasSuffix("/") {
            let body = String(trimmed.dropFirst().dropLast())
            if let re = try? NSRegularExpression(pattern: body, options: [.caseInsensitive]) {
                return .regex(re)
            }
        }
        let tokens = query.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        return tokens.isEmpty ? .empty : .tokens(tokens)
    }

    private static func cheapBlob(_ meta: SessionMeta) -> String {
        // Match on the *displayed* session title (explicit or auto-derived), the
        // project name and its full path, plus first/last user text — so typing a
        // project or session name finds it without a deep transcript scan.
        [AutoTitle.displayTitle(meta), meta.title ?? "", meta.lastUserText,
         meta.firstUserText, meta.projectLabel, meta.projectPath]
            .joined(separator: "\n").lowercased()
    }

    private static func makeSnippet(_ blob: String, _ token: String, radius: Int = 60) -> String? {
        guard let range = blob.range(of: token) else { return nil }
        let lower = blob.index(range.lowerBound, offsetBy: -radius, limitedBy: blob.startIndex) ?? blob.startIndex
        let upper = blob.index(range.upperBound, offsetBy: radius, limitedBy: blob.endIndex) ?? blob.endIndex
        let prefix = lower > blob.startIndex ? "…" : ""
        let suffix = upper < blob.endIndex ? "…" : ""
        let mid = blob[lower..<upper]
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return "\(prefix)\(mid)\(suffix)"
    }

    private static func recency(_ meta: SessionMeta) -> Double {
        min(2, meta.mtime.timeIntervalSince1970 / 1e12)
    }

    private static func regexMatches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func matchOne(_ meta: SessionMeta, _ q: Query, deep: Bool) -> SearchHit? {
        let cheap = cheapBlob(meta)

        switch q {
        case .empty:
            return SearchHit(meta: meta, score: 0, snippet: nil)
        case .regex(let re):
            if regexMatches(re, cheap) {
                let titleHit = (meta.title.map { regexMatches(re, $0.lowercased()) }) ?? false
                return SearchHit(meta: meta, score: (titleHit ? 12 : 8) + recency(meta), snippet: nil)
            }
            if !deep { return nil }
            let blob = Loader.buildSearchBlob(meta)
            guard regexMatches(re, blob) else { return nil }
            var snippet: String?
            if let m = re.firstMatch(in: blob, range: NSRange(blob.startIndex..., in: blob)),
               let r = Range(m.range, in: blob) {
                snippet = makeSnippet(blob, String(blob[r]))
            }
            return SearchHit(meta: meta, score: 3 + recency(meta), snippet: snippet)
        case .tokens(let tokens):
            var score = 0.0
            var snippet: String?
            var missing: [String] = []
            for tok in tokens {
                if cheap.contains(tok) {
                    score += (meta.title?.lowercased().contains(tok) ?? false) ? 12 : 8
                } else {
                    missing.append(tok)
                }
            }
            if !missing.isEmpty {
                if !deep { return nil }
                let blob = Loader.buildSearchBlob(meta)
                for tok in missing {
                    if blob.contains(tok) {
                        score += 3
                        if snippet == nil { snippet = makeSnippet(blob, tok) }
                    } else {
                        return nil
                    }
                }
            }
            return SearchHit(meta: meta, score: score + recency(meta), snippet: snippet)
        }
    }

    /// Synchronous cheap-only search (no file reads) — instant feedback.
    static func searchCheap(_ candidates: [SessionMeta], _ query: String) -> [SearchHit] {
        let q = parseQuery(query)
        if case .empty = q { return candidates.map { SearchHit(meta: $0, score: 0, snippet: nil) } }
        return candidates.compactMap { matchOne($0, q, deep: false) }
    }

    /// Deep search over a chunk of candidates (run off the main thread).
    static func searchDeep(_ candidates: [SessionMeta], _ query: String,
                           isCancelled: () -> Bool) -> [SearchHit] {
        let q = parseQuery(query)
        if case .empty = q { return candidates.map { SearchHit(meta: $0, score: 0, snippet: nil) } }
        var hits: [SearchHit] = []
        for meta in candidates {
            if isCancelled() { break }
            if let hit = matchOne(meta, q, deep: true) { hits.append(hit) }
        }
        return hits
    }
}

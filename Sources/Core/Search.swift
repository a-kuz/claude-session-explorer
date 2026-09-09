// Fast, incremental full-text search across sessions.
// Port of src/lib/search.ts (token AND-semantics + regex), two-tier matching.

import Foundation

struct SearchHit: Identifiable {
    var id: String { meta.id }
    let meta: SessionMeta
    let score: Double
    /// A short snippet around the first deep match, if the match was deep.
    let snippet: String?
    /// Indexed user prompts of this session that contain the query (the
    /// children of the session row in "prompts" search).
    var prompts: [IndexedPrompt] = []
}

enum Query {
    case empty
    case tokens([String])
    case regex(NSRegularExpression)
}

/// Per-session progress of the deep scan for ONE query. jsonl is append-only, so
/// a session scanned up to `scannedBytes` only needs its tail re-read next time;
/// a rescan started for any reason (background sync, cancelled pass, list filter
/// change) resumes from here instead of re-reading gigabytes.
struct DeepScanState {
    /// Offset just past the last fully scanned line.
    var scannedBytes: Int = 0
    /// Query tokens found so far anywhere in the scanned prefix.
    var found: Set<String> = []
    /// Regex form: whether any scanned line matched.
    var regexHit = false
    /// Original-case context around the first match.
    var snippet: String?
}

/// Deep-scan progress for the current query. Cleared when the query changes.
final class DeepScanCache {
    static let shared = DeepScanCache()
    private let lock = NSLock()
    private var query = ""
    private var entries: [String: DeepScanState] = [:]

    func state(for id: String, query: String) -> DeepScanState? {
        lock.lock(); defer { lock.unlock() }
        guard self.query == query else { return nil }
        return entries[id]
    }

    func store(_ state: DeepScanState, for id: String, query: String) {
        lock.lock(); defer { lock.unlock() }
        if self.query != query { self.query = query; entries = [:] }
        entries[id] = state
    }
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

    private static func recency(_ meta: SessionMeta) -> Double {
        min(2, meta.mtime.timeIntervalSince1970 / 1e12)
    }

    private static func regexMatches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// `deep` allows the streaming file scan for tokens the cheap fields and the
    /// prompt index don't cover; with `promptsOnly` the transcript is never read
    /// — only titles, project, and indexed user prompts count.
    static func matchOne(_ meta: SessionMeta, _ q: Query, deep: Bool, promptsOnly: Bool = false,
                         query: String = "", isCancelled: () -> Bool = { false }) -> SearchHit? {
        let cheap = cheapBlob(meta)

        switch q {
        case .empty:
            return SearchHit(meta: meta, score: 0, snippet: nil)
        case .regex(let re):
            let promptHits = PromptIndex.shared.match(meta.id, regex: re)
            if regexMatches(re, cheap) {
                let titleHit = (meta.title.map { regexMatches(re, $0.lowercased()) }) ?? false
                return SearchHit(meta: meta, score: (titleHit ? 12 : 8) + recency(meta), snippet: nil,
                                 prompts: promptHits)
            }
            if !promptHits.isEmpty {
                return SearchHit(meta: meta, score: 5 + recency(meta), snippet: promptHits[0].text,
                                 prompts: promptHits)
            }
            if !deep || promptsOnly { return nil }
            let state = deepScan(meta, query: query, tokens: [], regex: re, isCancelled: isCancelled)
            guard state.regexHit else { return nil }
            return SearchHit(meta: meta, score: 3 + recency(meta), snippet: state.snippet)
        case .tokens(let tokens):
            var score = 0.0
            var missing: [String] = []
            for tok in tokens {
                if cheap.contains(tok) {
                    score += (meta.title?.lowercased().contains(tok) ?? false) ? 12 : 8
                } else {
                    missing.append(tok)
                }
            }
            let pm = PromptIndex.shared.match(meta.id, tokens: tokens,
                                              required: missing.isEmpty ? nil : missing)
            let promptHits = pm?.prompts ?? []
            if missing.isEmpty {
                return SearchHit(meta: meta, score: score + recency(meta), snippet: nil, prompts: promptHits)
            }
            if let pm, missing.allSatisfy(pm.found.contains) {
                return SearchHit(meta: meta, score: score + 5 * Double(missing.count) + recency(meta),
                                 snippet: promptHits.first?.text, prompts: promptHits)
            }
            if !deep || promptsOnly { return nil }
            let state = deepScan(meta, query: query, tokens: tokens, regex: nil, isCancelled: isCancelled)
            for tok in missing {
                guard state.found.contains(tok) || (pm?.found.contains(tok) ?? false) else { return nil }
                score += 3
            }
            return SearchHit(meta: meta, score: score + recency(meta), snippet: state.snippet, prompts: promptHits)
        }
    }

    /// Synchronous search without file reads (titles, project, prompt index) —
    /// instant feedback; the complete answer in "prompts" mode.
    static func searchCheap(_ candidates: [SessionMeta], _ query: String, promptsOnly: Bool) -> [SearchHit] {
        let q = parseQuery(query)
        if case .empty = q { return candidates.map { SearchHit(meta: $0, score: 0, snippet: nil) } }
        return candidates.compactMap { matchOne($0, q, deep: false, promptsOnly: promptsOnly) }
    }

    /// Deep search over a chunk of candidates (run off the main thread).
    static func searchDeep(_ candidates: [SessionMeta], _ query: String,
                           isCancelled: () -> Bool) -> [SearchHit] {
        let q = parseQuery(query)
        if case .empty = q { return candidates.map { SearchHit(meta: $0, score: 0, snippet: nil) } }
        var hits: [SearchHit] = []
        for meta in candidates {
            if isCancelled() { break }
            if let hit = matchOne(meta, q, deep: true, query: query, isCancelled: isCancelled) {
                hits.append(hit)
            }
        }
        return hits
    }

    // MARK: - Deep scan (streaming, byte-level)

    private static let chunkSize = 8 << 20
    private static let markers: [[UInt8]] = [
        Array("\"text\"".utf8), Array("\"content\"".utf8), Array("\"prompt\"".utf8),
    ]
    private static let dataKey = Array("\"data\":\"".utf8)

    /// Scan the session file for `tokens` (all lowercased) or `regex`, resuming
    /// from the cached progress for this query. Only lines carrying prose
    /// markers are considered, and `"data":"…"` string values (base64 images)
    /// are skipped so short tokens don't match inside image payloads. Progress
    /// is cached even when cancelled mid-file, so the next pass continues from
    /// the last complete line.
    static func deepScan(_ meta: SessionMeta, query: String, tokens: [String],
                         regex: NSRegularExpression?, isCancelled: () -> Bool) -> DeepScanState {
        var state = DeepScanState()
        if let prior = DeepScanCache.shared.state(for: meta.id, query: query) {
            // A shrunk file was rewritten — the cached prefix no longer applies.
            if prior.scannedBytes <= fileSize(meta.filePath) { state = prior }
        }
        let wantTokens = tokens.filter { !state.found.contains($0) }
        if regex == nil && wantTokens.isEmpty { return state }
        if regex != nil && state.regexHit { return state }

        guard let fh = FileHandle(forReadingAtPath: meta.filePath) else { return state }
        defer { try? fh.close() }
        do { try fh.seek(toOffset: UInt64(state.scannedBytes)) } catch { return state }

        let byteTokens = wantTokens.map { ($0, Array($0.utf8)) }
        let asciiFold = wantTokens.allSatisfy(foldableByBytes)
        var pending = Set(wantTokens)
        var carry: [UInt8] = []
        var offset = state.scannedBytes
        var done = false

        while !done {
            if isCancelled() { break }
            autoreleasepool {
            let data = fh.readData(ofLength: chunkSize)
            let eof = data.count < chunkSize
            var raw = carry
            raw.append(contentsOf: data)
            carry = []
            var lineStart = 0
            var lastLineEnd = 0
            raw.withUnsafeBufferPointer { rawBuf in
                var lower = Array(rawBuf)
                foldInPlace(&lower)
                lower.withUnsafeBufferPointer { lowBuf in
                    while lineStart < lowBuf.count {
                        guard let nl = findByte(0x0A, in: lowBuf, from: lineStart) else { break }
                        let lineEnd = nl
                        scanLine(lowBuf, rawBuf, lineStart..<lineEnd, byteTokens: byteTokens,
                                 asciiFold: asciiFold, regex: regex, pending: &pending, state: &state)
                        lineStart = nl + 1
                        lastLineEnd = lineStart
                        if regex == nil ? pending.isEmpty : state.regexHit { done = true; break }
                    }
                    if !done, eof, lineStart < lowBuf.count {
                        // Unterminated last line (still being written): scan it but
                        // don't count it as consumed, so the next pass re-reads it.
                        scanLine(lowBuf, rawBuf, lineStart..<lowBuf.count, byteTokens: byteTokens,
                                 asciiFold: asciiFold, regex: regex, pending: &pending, state: &state)
                    }
                }
            }
            if !done {
                carry = Array(raw[lastLineEnd...])
                if eof { done = true }
            }
            offset += lastLineEnd
            state.scannedBytes = offset
            }
        }
        DeepScanCache.shared.store(state, for: meta.id, query: query)
        return state
    }

    private static func fileSize(_ path: String) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    }

    private static func scanLine(_ low: UnsafeBufferPointer<UInt8>, _ raw: UnsafeBufferPointer<UInt8>,
                                 _ range: Range<Int>, byteTokens: [(String, [UInt8])], asciiFold: Bool,
                                 regex: NSRegularExpression?, pending: inout Set<String>,
                                 state: inout DeepScanState) {
        guard markers.contains(where: { find($0, in: low, range) != nil }) else { return }
        if let re = regex {
            let s = String(decoding: UnsafeBufferPointer(rebasing: raw[range]), as: UTF8.self)
            if let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) {
                state.regexHit = true
                if state.snippet == nil, let r = Range(m.range, in: s) {
                    state.snippet = snippet(in: s, around: r)
                }
            }
            return
        }
        if asciiFold {
            for (key, tok) in byteTokens {
                guard pending.contains(key) else { continue }
                if let at = findSkippingData(tok, in: low, range) {
                    pending.remove(key)
                    if state.snippet == nil { state.snippet = snippet(raw, at: at, length: tok.count, in: range) }
                    state.found.insert(key)
                }
            }
        } else {
            // Tokens with letters outside ASCII/Cyrillic: fold via String.
            let s = String(decoding: UnsafeBufferPointer(rebasing: raw[range]), as: UTF8.self).lowercased()
            for key in pending {
                if let r = s.range(of: key) {
                    pending.remove(key)
                    if state.snippet == nil { state.snippet = snippet(in: s, around: r) }
                    state.found.insert(key)
                }
            }
        }
    }

    /// Search `needle` inside `range`, jumping over `"data":"…"` string values.
    private static func findSkippingData(_ needle: [UInt8], in buf: UnsafeBufferPointer<UInt8>,
                                         _ range: Range<Int>) -> Int? {
        var from = range.lowerBound
        while from < range.upperBound {
            let dataAt = find(dataKey, in: buf, from..<range.upperBound)
            let segEnd = dataAt ?? range.upperBound
            if let hit = find(needle, in: buf, from..<segEnd) { return hit }
            guard let d = dataAt else { return nil }
            let valueStart = d + dataKey.count
            from = (findByte(0x22, in: buf, from: valueStart, to: range.upperBound) ?? range.upperBound - 1) + 1
        }
        return nil
    }

    static func find(_ needle: [UInt8], in buf: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> Int? {
        let len = range.count
        guard len >= needle.count, needle.count > 0, let base = buf.baseAddress else { return nil }
        return needle.withUnsafeBufferPointer { n in
            guard let p = memmem(base + range.lowerBound, len, n.baseAddress!, n.count) else { return nil }
            return UnsafeRawPointer(p) - UnsafeRawPointer(base)
        }
    }

    private static func findByte(_ b: UInt8, in buf: UnsafeBufferPointer<UInt8>, from: Int, to: Int? = nil) -> Int? {
        let end = to ?? buf.count
        guard from < end, let base = buf.baseAddress else { return nil }
        guard let p = memchr(base + from, Int32(b), end - from) else { return nil }
        return UnsafeRawPointer(p) - UnsafeRawPointer(base)
    }

    /// Whether `foldInPlace` lowercases every letter of the token (ASCII and
    /// basic Cyrillic); anything else takes the String path.
    static func foldableByBytes(_ tok: String) -> Bool {
        tok.unicodeScalars.allSatisfy { $0.isASCII || (0x0400...0x045F).contains($0.value) }
    }

    /// Lowercase ASCII A–Z and Cyrillic А–Я/Ё in UTF-8 bytes, in place. Byte
    /// lengths are preserved, so offsets stay valid in the original buffer.
    static func foldInPlace(_ buf: inout [UInt8]) {
        let n = buf.count
        var i = 0
        buf.withUnsafeMutableBufferPointer { p in
            while i < n {
                let b = p[i]
                if b >= 0x41 && b <= 0x5A {
                    p[i] = b + 0x20
                } else if b == 0xD0, i + 1 < n {
                    let c = p[i + 1]
                    if c >= 0x90 && c <= 0x9F { p[i + 1] = c + 0x20 }              // А–П → а–п
                    else if c >= 0xA0 && c <= 0xAF { p[i] = 0xD1; p[i + 1] = c - 0x20 } // Р–Я → р–я
                    else if c == 0x81 { p[i] = 0xD1; p[i + 1] = 0x91 }              // Ё → ё
                    i += 1
                }
                i += 1
            }
        }
    }

    private static func snippet(_ raw: UnsafeBufferPointer<UInt8>, at: Int, length: Int,
                                in range: Range<Int>, radius: Int = 60) -> String {
        var lo = max(range.lowerBound, at - radius)
        var hi = min(range.upperBound, at + length + radius)
        // Snap to UTF-8 scalar boundaries.
        while lo > range.lowerBound, raw[lo] & 0xC0 == 0x80 { lo -= 1 }
        while hi < range.upperBound, raw[hi] & 0xC0 == 0x80 { hi += 1 }
        let mid = String(decoding: UnsafeBufferPointer(rebasing: raw[lo..<hi]), as: UTF8.self)
        return decorate(mid, leading: lo > range.lowerBound, trailing: hi < range.upperBound)
    }

    private static func snippet(in s: String, around r: Range<String.Index>, radius: Int = 60) -> String {
        let lower = s.index(r.lowerBound, offsetBy: -radius, limitedBy: s.startIndex) ?? s.startIndex
        let upper = s.index(r.upperBound, offsetBy: radius, limitedBy: s.endIndex) ?? s.endIndex
        return decorate(String(s[lower..<upper]), leading: lower > s.startIndex, trailing: upper < s.endIndex)
    }

    private static func decorate(_ mid: String, leading: Bool, trailing: Bool) -> String {
        let body = mid
            .replacingOccurrences(of: "\\\\n|\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return (leading ? "…" : "") + body + (trailing ? "…" : "")
    }
}

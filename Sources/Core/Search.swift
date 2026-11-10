// Fast, incremental full-text search across sessions.
// Port of src/lib/search.ts (token AND-semantics + regex), two-tier matching.

import Foundation
import os

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

/// Read buffers of one scanning thread, reused across the files it scans.
final class ScanScratch {
    /// Case-folded bytes: the unfinished line carried from the previous read,
    /// followed by the bytes just read.
    private(set) var low: UnsafeMutablePointer<UInt8>
    /// The same bytes in original case; allocated only for scans that match
    /// on the original text (regex, tokens outside ASCII/Cyrillic).
    private(set) var raw: UnsafeMutablePointer<UInt8>?
    private var capacity: Int

    init() {
        capacity = 1 << 20
        low = .allocate(capacity: capacity)
    }

    deinit {
        low.deallocate()
        raw?.deallocate()
    }

    /// Make room for `count` bytes, keeping the first `keep` bytes.
    func reserve(_ count: Int, keep: Int, withRaw: Bool) {
        if count > capacity {
            var grown = capacity
            while grown < count { grown *= 2 }
            let newLow = UnsafeMutablePointer<UInt8>.allocate(capacity: grown)
            newLow.update(from: low, count: keep)
            low.deallocate()
            low = newLow
            if let old = raw {
                let newRaw = UnsafeMutablePointer<UInt8>.allocate(capacity: grown)
                newRaw.update(from: old, count: keep)
                old.deallocate()
                raw = newRaw
            }
            capacity = grown
        }
        if withRaw, raw == nil { raw = .allocate(capacity: capacity) }
    }
}

/// Cancellation flag shared by the scanning threads of one `searchDeep` call.
private final class CancelFlag: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var isSet: Bool { state.withLock { $0 } }
    func set() { state.withLock { $0 = true } }
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
                         query: String = "", isCancelled: () -> Bool = { false },
                         scratch: ScanScratch? = nil) -> SearchHit? {
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
            let state = deepScan(meta, query: query, tokens: [], regex: re, isCancelled: isCancelled,
                                 scratch: scratch)
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
            let state = deepScan(meta, query: query, tokens: tokens, regex: nil, isCancelled: isCancelled,
                                 scratch: scratch)
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

    /// Upper bound on files scanned at once. Each scanning thread holds its
    /// read buffers plus the longest line of its file, so the width bounds
    /// peak memory.
    private static let maxParallelScans = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8))

    /// Deep search over a chunk of candidates (run off the main thread). The
    /// candidates are scanned in parallel; hits come back in candidate order.
    static func searchDeep(_ candidates: [SessionMeta], _ query: String,
                           isCancelled: () -> Bool) -> [SearchHit] {
        let q = parseQuery(query)
        if case .empty = q { return candidates.map { SearchHit(meta: $0, score: 0, snippet: nil) } }
        let n = candidates.count
        if n == 0 || isCancelled() { return [] }

        let slots = UnsafeMutablePointer<SearchHit?>.allocate(capacity: n)
        slots.initialize(repeating: nil, count: n)
        defer { slots.deinitialize(count: n); slots.deallocate() }

        let cancel = CancelFlag()
        let next = OSAllocatedUnfairLock(initialState: 0)
        let finished = DispatchSemaphore(value: 0)
        let width = min(n, maxParallelScans)
        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.concurrentPerform(iterations: width) { _ in
                let scratch = ScanScratch()
                while !cancel.isSet {
                    let i = next.withLock { v -> Int in v += 1; return v - 1 }
                    guard i < n else { break }
                    slots[i] = matchOne(candidates[i], q, deep: true, query: query,
                                        isCancelled: { cancel.isSet }, scratch: scratch)
                }
            }
            finished.signal()
        }
        // `isCancelled` is polled here, on the caller's thread: a closure like
        // `{ Task.isCancelled }` reads the caller's task and sees nothing on
        // the scanning threads.
        while finished.wait(timeout: .now() + .milliseconds(5)) == .timedOut {
            if isCancelled() { cancel.set() }
        }
        return (0..<n).compactMap { slots[$0] }
    }

    // MARK: - Deep scan (streaming, byte-level)

    private static let chunkSize = 1 << 20
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
                         regex: NSRegularExpression?, isCancelled: () -> Bool,
                         scratch: ScanScratch? = nil) -> DeepScanState {
        var state = DeepScanState()
        if let prior = DeepScanCache.shared.state(for: meta.id, query: query) {
            // A shrunk file was rewritten — the cached prefix no longer applies.
            if prior.scannedBytes <= fileSize(meta.filePath) { state = prior }
        }
        let wantTokens = tokens.filter { !state.found.contains($0) }
        if regex == nil && wantTokens.isEmpty { return state }
        if regex != nil && state.regexHit { return state }

        let fd = open(meta.filePath, O_RDONLY)
        guard fd >= 0 else { return state }
        defer { close(fd) }

        let byteTokens = wantTokens.map { ($0, Array($0.utf8)) }
        let asciiFold = wantTokens.allSatisfy(foldableByBytes)
        // Byte-foldable tokens match on the folded bytes alone, so the read
        // goes straight into the folded buffer and is folded in place.
        let keepRaw = regex != nil || !asciiFold
        let scratch = scratch ?? ScanScratch()
        var pending = Set(wantTokens)
        // Length of the unfinished line at the start of the buffers.
        var carry = 0
        // The last folded byte is a Cyrillic lead byte whose second byte
        // arrives with the next read.
        var splitLead = false
        // File offset of the first buffer byte (a line start).
        var offset = state.scannedBytes
        var done = false
        var cancelled = false

        while !done && !cancelled {
            if isCancelled() { break }
            autoreleasepool {
            scratch.reserve(carry + chunkSize, keep: carry, withRaw: keepRaw)
            let low = scratch.low
            let raw = keepRaw ? scratch.raw : nil
            let got = readFully(fd, into: (raw ?? low) + carry, count: chunkSize, at: offset + carry)
            let eof = got < chunkSize
            let total = carry + got
            if let raw { (low + carry).update(from: raw + carry, count: got) }
            splitLead = fold(low, from: splitLead ? carry - 1 : carry, to: total)

            let line = ScanLine(low: UnsafeBufferPointer(start: low, count: total),
                                raw: raw.map { UnsafeBufferPointer(start: $0, count: total) },
                                fd: fd, fileOffset: offset)
            var lineStart = 0
            var lastLineEnd = 0
            // The carried bytes hold no newline.
            var newlineFrom = carry
            while lineStart < total {
                guard let nl = findByte(0x0A, in: line.low, from: max(lineStart, newlineFrom)) else { break }
                if isCancelled() { cancelled = true; break }
                scanLine(line, lineStart..<nl, byteTokens: byteTokens,
                         asciiFold: asciiFold, regex: regex, pending: &pending, state: &state)
                lineStart = nl + 1
                lastLineEnd = lineStart
                newlineFrom = lineStart
                if regex == nil ? pending.isEmpty : state.regexHit { done = true; break }
            }
            if !done, !cancelled, eof, lineStart < total {
                // Unterminated last line (still being written): scan it but
                // don't count it as consumed, so the next pass re-reads it.
                scanLine(line, lineStart..<total, byteTokens: byteTokens,
                         asciiFold: asciiFold, regex: regex, pending: &pending, state: &state)
            }
            if !done {
                carry = total - lastLineEnd
                if lastLineEnd > 0, carry > 0 {
                    memmove(low, low + lastLineEnd, carry)
                    if let raw { memmove(raw, raw + lastLineEnd, carry) }
                }
                if carry == 0 { splitLead = false }
                if eof { done = true }
            }
            offset += lastLineEnd
            state.scannedBytes = offset
            }
        }
        DeepScanCache.shared.store(state, for: meta.id, query: query)
        return state
    }

    /// Read up to `count` bytes at `position`; fewer only at end of file.
    private static func readFully(_ fd: Int32, into dst: UnsafeMutablePointer<UInt8>, count: Int,
                                  at position: Int) -> Int {
        var got = 0
        while got < count {
            let n = pread(fd, dst + got, count - got, off_t(position + got))
            if n > 0 { got += n }
            else if n < 0 && errno == EINTR { continue }
            else { break }
        }
        return got
    }

    private static func fileSize(_ path: String) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    }

    /// The bytes being scanned: `low` is case-folded; `raw` holds the same
    /// bytes in original case when the scan keeps them, otherwise they are
    /// re-read from the file at `fileOffset` + buffer index.
    private struct ScanLine {
        let low: UnsafeBufferPointer<UInt8>
        let raw: UnsafeBufferPointer<UInt8>?
        let fd: Int32
        let fileOffset: Int
    }

    private static func scanLine(_ line: ScanLine, _ range: Range<Int>,
                                 byteTokens: [(String, [UInt8])], asciiFold: Bool,
                                 regex: NSRegularExpression?, pending: inout Set<String>,
                                 state: inout DeepScanState) {
        let low = line.low
        guard markers.contains(where: { find($0, in: low, range) != nil }) else { return }
        if let re = regex, let raw = line.raw {
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
                    if state.snippet == nil { state.snippet = snippet(line, at: at, length: tok.count, in: range) }
                    state.found.insert(key)
                }
            }
        } else if let raw = line.raw {
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
        buf.withUnsafeMutableBufferPointer { p in
            guard let base = p.baseAddress else { return }
            _ = fold(base, from: 0, to: p.count)
        }
    }

    /// Fold bytes `from..<to`. Returns whether the last byte is a 0xD0 lead
    /// left without its second byte; the caller resumes from that byte once
    /// more data follows it.
    private static func fold(_ p: UnsafeMutablePointer<UInt8>, from: Int, to n: Int) -> Bool {
        guard from < n else { return false }
        // Cyrillic pairs first, hopping between 0xD0 lead bytes. The byte after
        // a lead belongs to the pair and keeps its value in the ASCII pass.
        var splitLead = false
        var pairedASCII: [Int] = []
        var i = from
        while i < n {
            if p[i] != 0xD0 {
                guard let hit = memchr(p + i, 0xD0, n - i) else { break }
                i = UnsafeRawPointer(hit) - UnsafeRawPointer(p)
            }
            guard i + 1 < n else { splitLead = true; break }
            let c = p[i + 1]
            if c >= 0x90 && c <= 0x9F { p[i + 1] = c + 0x20 }                   // А–П → а–п
            else if c >= 0xA0 && c <= 0xAF { p[i] = 0xD1; p[i + 1] = c - 0x20 } // Р–Я → р–я
            else if c == 0x81 { p[i] = 0xD1; p[i + 1] = 0x91 }                  // Ё → ё
            else if c >= 0x41 && c <= 0x5A { pairedASCII.append(i + 1) }
            i += 2
        }
        // Branch-free so the loop vectorizes.
        var k = from
        while k < n {
            let b = p[k]
            p[k] = b &+ ((b &- 0x41) < 26 ? 0x20 : 0)
            k += 1
        }
        for at in pairedASCII { p[at] &-= 0x20 }
        return splitLead
    }

    /// Original-case context around a match found in the folded bytes.
    private static func snippet(_ line: ScanLine, at: Int, length: Int,
                                in range: Range<Int>, radius: Int = 60) -> String {
        let low = line.low
        var lo = max(range.lowerBound, at - radius)
        var hi = min(range.upperBound, at + length + radius)
        // Snap to UTF-8 scalar boundaries (folding keeps lead and continuation
        // bytes in place).
        while lo > range.lowerBound, low[lo] & 0xC0 == 0x80 { lo -= 1 }
        while hi < range.upperBound, low[hi] & 0xC0 == 0x80 { hi += 1 }
        let mid: String
        if let raw = line.raw {
            mid = String(decoding: UnsafeBufferPointer(rebasing: raw[lo..<hi]), as: UTF8.self)
        } else {
            var bytes = [UInt8](repeating: 0, count: hi - lo)
            let got = bytes.withUnsafeMutableBufferPointer {
                readFully(line.fd, into: $0.baseAddress!, count: hi - lo, at: line.fileOffset + lo)
            }
            mid = got == hi - lo
                ? String(decoding: bytes, as: UTF8.self)
                : String(decoding: UnsafeBufferPointer(rebasing: low[lo..<hi]), as: UTF8.self)
        }
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

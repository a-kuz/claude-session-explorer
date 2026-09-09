// Persistent index of user prompts, for instant "search in prompts".
//
// Prompts are immutable and jsonl is append-only, so the index is built by the
// same incremental meta parse that fills the Store: every user prompt the
// accumulator sees is appended here exactly once (a cold re-parse replaces the
// session's file). One file per session under
// Application Support/SessionExplorer/prompts/<id>.tsv, a `uuid<TAB>text` line
// per prompt (text is whitespace-collapsed, so it holds no tabs or newlines).
// The whole index is held in memory with a case-folded byte copy, so a search
// over every prompt of every session is a handful of memmem calls.

import Foundation

struct IndexedPrompt {
    /// jsonl `uuid` of the prompt record — the block id in the open dialog.
    let uuid: String
    let text: String
}

struct PromptMatch {
    /// Query tokens found in at least one prompt of the session.
    let found: Set<String>
    /// Indices of prompts that contain every requested token.
    let prompts: [IndexedPrompt]
}

final class PromptIndex {
    static let shared = PromptIndex()

    static var directory: URL {
        Store.storeURL.deletingLastPathComponent().appendingPathComponent("prompts", isDirectory: true)
    }

    private struct Entry {
        var prompts: [IndexedPrompt] = []
        /// All prompt texts, case-folded, joined by "\n".
        var folded: [UInt8] = []
        /// Byte offset of each prompt's start inside `folded`.
        var starts: [Int] = []

        mutating func append(_ new: [IndexedPrompt]) {
            for p in new {
                if !folded.isEmpty { folded.append(0x0A) }
                starts.append(folded.count)
                var bytes = Array(p.text.utf8)
                Search.foldInPlace(&bytes)
                folded.append(contentsOf: bytes)
                prompts.append(p)
            }
        }
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private(set) var loaded = false

    private func fileURL(_ id: String) -> URL {
        Self.directory.appendingPathComponent("\(id).tsv")
    }

    /// Read every per-session file into memory. Called once at startup, off
    /// the main thread.
    func load() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let files = (try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        var fresh: [String: Entry] = [:]
        for url in files where url.pathExtension == "tsv" {
            guard let data = fm.contents(atPath: url.path) else { continue }
            let id = url.deletingPathExtension().lastPathComponent
            var entry = Entry()
            entry.append(Self.parse(data))
            fresh[id] = entry
        }
        lock.lock()
        entries = fresh
        loaded = true
        lock.unlock()
    }

    private static func parse(_ data: Data) -> [IndexedPrompt] {
        let text = String(decoding: data, as: UTF8.self)
        var out: [IndexedPrompt] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            out.append(IndexedPrompt(uuid: String(line[..<tab]), text: String(line[line.index(after: tab)...])))
        }
        return out
    }

    private static func serialize(_ prompts: [IndexedPrompt]) -> Data {
        var s = ""
        for p in prompts { s += p.uuid; s += "\t"; s += p.text; s += "\n" }
        return Data(s.utf8)
    }

    /// Append prompts parsed from a session's newly appended tail.
    func append(_ prompts: [IndexedPrompt], to id: String) {
        guard !prompts.isEmpty else { return }
        lock.lock()
        entries[id, default: Entry()].append(prompts)
        lock.unlock()
        let url = fileURL(id)
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: Self.serialize(prompts))
        } else {
            try? Self.serialize(prompts).write(to: url)
        }
    }

    /// Replace a session's prompts after a cold (full) parse.
    func replace(_ prompts: [IndexedPrompt], for id: String) {
        lock.lock()
        var entry = Entry()
        entry.append(prompts)
        entries[id] = entry
        lock.unlock()
        try? Self.serialize(prompts).write(to: fileURL(id))
    }

    func remove(_ id: String) {
        lock.lock()
        entries.removeValue(forKey: id)
        lock.unlock()
        try? FileManager.default.removeItem(at: fileURL(id))
    }

    func removeAll() {
        lock.lock()
        entries = [:]
        lock.unlock()
        try? FileManager.default.removeItem(at: Self.directory)
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
    }

    /// Find which of `tokens` (lowercased) occur in the session's prompts, and
    /// the prompts containing all of `required`. `required` defaults to every
    /// token; when the caller already matched some tokens elsewhere (title,
    /// project) it passes only the remaining ones.
    func match(_ id: String, tokens: [String], required: [String]? = nil) -> PromptMatch? {
        lock.lock()
        guard let entry = entries[id] else { lock.unlock(); return nil }
        lock.unlock()
        guard !entry.prompts.isEmpty else { return nil }

        var found: Set<String> = []
        var perToken: [String: Set<Int>] = [:]
        let byBytes = tokens.allSatisfy(Search.foldableByBytes)
        if byBytes {
            entry.folded.withUnsafeBufferPointer { buf in
                for tok in tokens {
                    let needle = Array(tok.utf8)
                    var hits: Set<Int> = []
                    var from = 0
                    while let at = Search.find(needle, in: buf, from..<buf.count) {
                        hits.insert(Self.promptIndex(for: at, starts: entry.starts))
                        from = at + 1
                    }
                    if !hits.isEmpty { found.insert(tok); perToken[tok] = hits }
                }
            }
        } else {
            for (i, p) in entry.prompts.enumerated() {
                let low = p.text.lowercased()
                for tok in tokens where low.contains(tok) {
                    found.insert(tok); perToken[tok, default: []].insert(i)
                }
            }
        }
        guard !found.isEmpty else { return nil }
        let need = (required ?? tokens).filter { found.contains($0) }
        var indices: Set<Int>?
        for tok in need {
            let s = perToken[tok] ?? []
            indices = indices.map { $0.intersection(s) } ?? s
        }
        let picked = (indices ?? []).sorted().map { entry.prompts[$0] }
        return PromptMatch(found: found, prompts: picked)
    }

    /// Prompts whose text matches the regex.
    func match(_ id: String, regex: NSRegularExpression) -> [IndexedPrompt] {
        lock.lock()
        guard let entry = entries[id] else { lock.unlock(); return [] }
        lock.unlock()
        return entry.prompts.filter {
            regex.firstMatch(in: $0.text, range: NSRange($0.text.startIndex..., in: $0.text)) != nil
        }
    }

    private static func promptIndex(for offset: Int, starts: [Int]) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}

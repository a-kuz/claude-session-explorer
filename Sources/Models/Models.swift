// Domain types for Claude Code session data — port of src/types.ts.

import Foundation

/// A single tool invocation parsed from an assistant message.
struct ToolUse: Hashable, Identifiable {
    let id = UUID()
    /// Tool name, e.g. "Read", "Bash".
    let name: String
    /// Short single-line summary of the most salient argument, if any.
    let arg: String
    /// Pretty-printed input (multi-line), shown when the tool is expanded.
    let input: String
    /// Raw tool input re-encoded as JSON (for rich renderers like AskUserQuestion).
    var rawInputJSON: String = ""
    /// jsonl tool_use id — links this call to its tool_result.
    var toolUseID: String = ""
    /// Result/output text of the call (filled by linking tool_result later).
    var output: String = ""
    /// Absolute path of the image this call reads, when it's a `Read` of an image
    /// file — the transcript renders it inline instead of a plain tool chip.
    var imageFilePath: String? = nil
}

/// An ordered piece of a message's content: prose or a tool call, in the exact
/// sequence they appeared — so tools render in place, not collected at the end.
enum ContentPiece: Hashable {
    case text(String)
    case tool(ToolUse)
}

/// A single message in a rendered dialog (after parsing jsonl).
struct DialogMessage: Identifiable {
    /// Stable id from the jsonl record's `uuid` (so re-parsing keeps identity).
    let id: String
    /// The record's own `uuid` (equals `id` when present). Empty if absent.
    var uuid: String = ""
    /// The record's `parentUuid` — the message this one replied to. A `/regenerate`
    /// or edit-and-resubmit creates a *second* child of the same parent, which is
    /// what makes a session branch. Nil for the conversation root.
    var parentUuid: String? = nil
    /// `logicalParentUuid` — set when the real chain was nulled (e.g. context
    /// compaction). Used as a parent fallback so branch detection still links up.
    var logicalParentUuid: String? = nil
    enum Role: String { case user, assistant }
    let role: Role
    /// Plain-text rendering of the message content (tool calls collapsed).
    let text: String
    let timestamp: Date?
    /// True if this is a tool_result-only / meta message (lower visual weight).
    let isToolOrMeta: Bool
    /// Tool invocations in this (assistant) message, in order.
    var toolUses: [ToolUse]
    /// Tool result texts carried by this (user) message, in order.
    let toolResults: [String]
    /// Non-tool text: assistant prose with tool_use removed, or the user prompt.
    let bodyText: String
    /// Attached images referenced by this message (file name hints).
    let imageCount: Int
    /// Prose + tool calls in original order (for in-place tool rendering).
    var pieces: [ContentPiece] = []
    /// Absolute paths of image attachments (loaded from disk for inline display).
    var imagePaths: [String] = []
}

/// Lightweight metadata for the session list — cheap to compute, no full parse.
final class SessionMeta: Identifiable, Hashable {
    /// Session UUID (jsonl filename without extension).
    let id: String
    /// Absolute path to the jsonl file.
    let filePath: String
    /// Decoded project directory (cwd), e.g. /Users/x/ws/foo.
    let projectPath: String
    /// Short project label, e.g. "foo".
    let projectLabel: String
    /// Explicit title: custom-title > ai-title, if present.
    let title: String?
    /// Whether the title is user-defined (vs ai-generated).
    let titleIsCustom: Bool
    /// First/last meaningful user prompt (last preferred for the list).
    let lastUserText: String
    /// First user prompt — used for lazy auto-title fallback.
    let firstUserText: String
    /// Display/sort time: last user message time, falling back to last
    /// activity, then file mtime. This is what the user reads as the date.
    let mtime: Date
    /// First activity time (for the inspector "created" field).
    let firstActivity: Date?
    /// Last activity time.
    let lastActivity: Date?
    /// Count of user+assistant messages (rough size signal).
    let messageCount: Int
    /// jsonl file size in bytes (shown in the list as a session "weight").
    let byteSize: Int
    /// Number of distinct user turns (for the turn navigator).
    let userTurnCount: Int
    /// Model id seen in the transcript, if any.
    let model: String?
    /// Time of the last user prompt (for the "needs attention" heuristic).
    let lastUserTime: Date?
    /// Time of the last assistant message (end of Claude's work).
    let lastClaudeTime: Date?
    /// Session id this session was forked from (`forkedFrom.sessionId` in the
    /// transcript), i.e. its parent. Nil for a normal, non-forked session.
    let parentSessionId: String?
    /// Concatenated searchable text (built lazily on first search).
    var searchBlob: String?

    init(id: String, filePath: String, projectPath: String, projectLabel: String,
         title: String?, titleIsCustom: Bool, lastUserText: String, firstUserText: String,
         mtime: Date, firstActivity: Date?, lastActivity: Date?, messageCount: Int,
         byteSize: Int, userTurnCount: Int, model: String?,
         lastUserTime: Date? = nil, lastClaudeTime: Date? = nil,
         parentSessionId: String? = nil) {
        self.id = id
        self.filePath = filePath
        self.projectPath = projectPath
        self.projectLabel = projectLabel
        self.title = title
        self.titleIsCustom = titleIsCustom
        self.lastUserText = lastUserText
        self.firstUserText = firstUserText
        self.mtime = mtime
        self.firstActivity = firstActivity
        self.lastActivity = lastActivity
        self.messageCount = messageCount
        self.byteSize = byteSize
        self.userTurnCount = userTurnCount
        self.model = model
        self.lastUserTime = lastUserTime
        self.lastClaudeTime = lastClaudeTime
        self.parentSessionId = parentSessionId
    }

    /// True when Claude kept working/responding for more than 5 minutes after
    /// the user's last prompt and the user hasn't replied since — i.e. the
    /// session is waiting on the user. (Manual dismiss handled in AppModel.)
    var needsAttention: Bool {
        guard let u = lastUserTime, let c = lastClaudeTime else { return false }
        return c > u && c.timeIntervalSince(u) > 300
    }

    static func == (lhs: SessionMeta, rhs: SessionMeta) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Fully-parsed session for the dialog view.
struct SessionDialog {
    let id: String
    let messages: [DialogMessage]
}

/// How the dialog renders a session that contains branches (a parent message
/// with more than one child — produced by `/regenerate` or an edit-and-resubmit).
enum BranchMode: String, CaseIterable, Identifiable {
    /// Show only the active branch — the linear path to the newest leaf. The
    /// abandoned alternatives are hidden, so the conversation reads as one thread.
    case activeOnly
    /// Active branch as the main thread, with an inline "N/M" switcher at each
    /// branch point so the reader can jump to an alternative path.
    case switcher
    /// Show every branch at once, indented under its branch point.
    case tree

    var id: String { rawValue }
    var label: String {
        switch self {
        case .activeOnly: return "Active branch"
        case .switcher: return "With switcher"
        case .tree: return "Tree"
        }
    }
}

/// The branch structure of a session: the parent→children graph over message
/// uuids, the active linear path, and per-branch-point alternatives. Built once
/// per parsed session; `messages` retains the raw file order.
struct BranchGraph {
    /// uuid → indices of its children in the source `messages` array, in file order.
    let childrenOf: [String: [Int]]
    /// Indices of branch-point messages (a parent with ≥2 children).
    let branchPoints: Set<Int>
    /// True if the session contains at least one branch.
    var hasBranches: Bool { !branchPoints.isEmpty }

    /// Linkable parent of a message: real `parentUuid`, else `logicalParentUuid`.
    private static func parentKey(_ m: DialogMessage) -> String? {
        m.parentUuid ?? m.logicalParentUuid
    }

    /// Build the graph. Messages without a `uuid` (legacy/positional ids) can't
    /// participate in linking — they fall through as a single linear run.
    static func build(from messages: [DialogMessage]) -> BranchGraph {
        var children: [String: [Int]] = [:]
        var indexOfUUID: [String: Int] = [:]
        for (i, m) in messages.enumerated() where !m.uuid.isEmpty {
            indexOfUUID[m.uuid] = i
        }
        // A `parentUuid` often points at a *service* record (attachment, system,
        // file-history-snapshot) that the dialog parse drops — so it isn't in
        // `indexOfUUID`. Treating those as roots would shatter one linear thread
        // into dozens of false "roots" (and hide all but the newest). Records are
        // read in append-only file order, so when the parent doesn't resolve we
        // fall back to linking to the previous dialog record by file order. Real
        // branches (a resolvable `parentUuid` with ≥2 children) are preserved.
        var prevUUID: String = ""   // uuid of the previous dialog record in file order
        for (i, m) in messages.enumerated() {
            let parent = parentKey(m)
            let key: String
            if let parent, indexOfUUID[parent] != nil {
                key = parent
            } else if !prevUUID.isEmpty {
                key = prevUUID
            } else {
                key = ""
            }
            children[key, default: []].append(i)
            if !m.uuid.isEmpty { prevUUID = m.uuid }
        }
        var points: Set<Int> = []
        for (key, kids) in children where key != "" && kids.count > 1 {
            if let pi = indexOfUUID[key] { points.insert(pi) }
        }
        return BranchGraph(childrenOf: children, branchPoints: points)
    }

    /// The active path: indices of the linear chain from the root to the newest
    /// leaf. At each branch point the child leading to the latest-timestamped
    /// descendant wins; ties fall back to file order (the last-written child).
    func activePath(in messages: [DialogMessage]) -> [Int] {
        // Memoized newest-timestamp reachable from each message index.
        var newestCache: [Int: Date] = [:]
        func newest(_ i: Int) -> Date {
            if let c = newestCache[i] { return c }
            var best = messages[i].timestamp ?? .distantPast
            for c in childrenOf[messages[i].uuid] ?? [] {
                let d = newest(c)
                if d > best { best = d }
            }
            newestCache[i] = best
            return best
        }
        var path: [Int] = []
        var frontier = childrenOf[""] ?? []
        while let next = frontier.max(by: { a, b in
            let na = newest(a), nb = newest(b)
            return na != nb ? na < nb : a < b
        }) {
            path.append(next)
            frontier = childrenOf[messages[next].uuid] ?? []
        }
        return path
    }
}

/// One ordered segment of a turn's body: a run of prose (already parsed to
/// markdown blocks) or a single tool call — rendered in original sequence.
enum TurnSegment: Identifiable, Equatable {
    case prose(id: String, blocks: [MarkdownBlock])
    case tool(ToolUse)

    var id: String {
        switch self {
        case .prose(let id, _): return "p-\(id)"
        case .tool(let t): return "t-\(t.id.uuidString)"
        }
    }
    static func == (l: TurnSegment, r: TurnSegment) -> Bool { l.id == r.id }
}

/// A visual turn: a run of adjacent messages from the same speaker, merged so
/// the UI shows one avatar + header per speaker change (like the TUI), with all
/// prose and tool calls collapsed together.
struct DialogTurn: Identifiable, Equatable {
    /// Stable id = the starter message's id (jsonl uuid).
    let id: String
    let role: DialogMessage.Role
    let timestamp: Date?
    /// Prose paragraphs in order (assistant text / user prompt), tool gaps dropped.
    let bodyChunks: [String]
    /// All tool invocations across the merged messages, in order.
    let toolUses: [ToolUse]
    let imageCount: Int
    /// Index of this turn's first image within the session-wide image array,
    /// so the view can slice the lazily-loaded images. -1 if none.
    let imageStartIndex: Int
    /// Is this a real user prompt (eligible as a "reply" for [ ] navigation)?
    let isUserPrompt: Bool
    /// In brief mode: content (tools / intermediate prose) was hidden in this turn.
    let omitted: Bool
    /// Markdown parsed once at build time (parsing per-render was a hot spot).
    let blocks: [MarkdownBlock]
    /// Prose runs and tool calls in original order, so tools render in place.
    var segments: [TurnSegment] = []
    /// Absolute paths of image attachments in this turn (loaded from disk).
    var imagePaths: [String] = []

    var bodyText: String { bodyChunks.joined(separator: "\n\n") }

    // Identity-based equality so SwiftUI skips re-rendering unchanged turns
    // cheaply (no deep block comparison).
    static func == (lhs: DialogTurn, rhs: DialogTurn) -> Bool {
        lhs.id == rhs.id && lhs.bodyChunks == rhs.bodyChunks
            && lhs.toolUses == rhs.toolUses && lhs.imageCount == rhs.imageCount
    }

    /// Short one-line label for the outline / table of contents.
    var outlineTitle: String {
        let first = bodyChunks.first ?? ""
        let oneLine = MessageContent.oneLine(first, max: 80)
        return oneLine.isEmpty ? (imageCount > 0 ? "attachment" : "…") : oneLine
    }

    /// Build turns. A "speaker" run is broken only by a *real* user prompt;
    /// tool_result / meta user messages (whose output we hide) are absorbed into
    /// the surrounding assistant turn instead of fragmenting it. This collapses
    /// the long Claude↔tool ping-pong into one Claude turn, like the TUI.
    /// A user message that carries a genuine typed prompt (not tool plumbing).
    /// Also the boundary that closes an assistant turn — used to find the last
    /// stable rebuild point when appending a tail.
    static func isRealUserPrompt(_ m: DialogMessage) -> Bool {
        guard m.role == .user, !m.isToolOrMeta else { return false }
        return !MessageContent.stripNoise(m.bodyText).isEmpty
    }

    static func build(from messages: [DialogMessage], brief: Bool = false) -> [DialogTurn] {
        build(from: messages, brief: brief, fromMessageIndex: 0, imageCursorStart: 0)
    }

    /// Build turns over `messages[fromMessageIndex...]`, with the session-wide
    /// image index seeded at `imageCursorStart`. The default full build passes
    /// 0/0; the incremental tail path passes the index of the last user prompt and
    /// the image count consumed before it, so only the open (last) turn run is
    /// rebuilt instead of the whole transcript on every appended line.
    static func build(from messages: [DialogMessage], brief: Bool,
                      fromMessageIndex: Int, imageCursorStart: Int) -> [DialogTurn] {
        var turns: [DialogTurn] = []
        var imageCursor = imageCursorStart   // running index into the session-wide image array
        var i = fromMessageIndex
        while i < messages.count {
            let starter = messages[i]
            let asUser = isRealUserPrompt(starter)
            let turnImageStart = imageCursor

            var chunks: [String] = []
            var tools: [ToolUse] = []
            var images = 0
            var firstTimestamp: Date? = starter.timestamp
            var orderedPieces: [ContentPiece] = []
            var imgPaths: [String] = []

            // For a user prompt the time is when it was sent (first); for an
            // assistant turn the meaningful time is the *last* reply produced.
            var lastProseTimestamp: Date? = nil

            func absorb(_ m: DialogMessage, asUserTurn: Bool) {
                // Strip machinery (caveats, interrupts, command tags) from both
                // roles — interrupt markers appear as assistant messages too.
                let body = MessageContent.stripNoise(m.bodyText)
                if !body.isEmpty {
                    chunks.append(body)
                    if let ts = m.timestamp { lastProseTimestamp = ts }
                }
                tools.append(contentsOf: m.toolUses)
                // Ordered pieces: keep tools in place between prose runs. Strip
                // noise from each text piece; drop emptied ones.
                for p in m.pieces {
                    switch p {
                    case .text(let t):
                        let s = MessageContent.stripNoise(t)
                        if !s.isEmpty { orderedPieces.append(.text(s)) }
                    case .tool:
                        orderedPieces.append(p)
                    }
                }
                // Always advance the session-wide cursor so per-turn slices stay
                // aligned with Loader.loadImages (which walks every image in file
                // order). But an image carried by a user-role record swallowed
                // into an assistant run is prompt plumbing — a pasted image is
                // written twice, as base64 on the prompt AND as a numbered
                // cache-ref on a following empty user record. That ref rides into
                // the assistant turn; it's a duplicate of the prompt's own image,
                // not part of Claude's reply, so it must not render under it.
                imageCursor += m.imageCount
                if asUserTurn || m.role == .assistant {
                    images += m.imageCount
                    imgPaths.append(contentsOf: m.imagePaths)
                }
                if firstTimestamp == nil { firstTimestamp = m.timestamp }
            }

            if asUser {
                // One user turn = this prompt (tool plumbing won't precede it).
                absorb(starter, asUserTurn: true)
                i += 1
            } else {
                // Assistant turn: swallow everything up to the next real prompt.
                var j = i
                while j < messages.count, !isRealUserPrompt(messages[j]) {
                    absorb(messages[j], asUserTurn: false)
                    j += 1
                }
                i = j
            }

            // Compact "compact": drop tool machinery; for assistant turns keep
            // only the final prose chunk (the conclusion before the next prompt).
            var omitted = false
            if brief {
                if !tools.isEmpty { omitted = true }
                tools = []
                images = asUser ? images : 0
                if !asUser, chunks.count > 1 { omitted = true; chunks = [chunks.last!] }
                // Brief: collapse to prose only (final chunk for assistant turns).
                let proseOnly = chunks.joined(separator: "\n\n")
                orderedPieces = proseOnly.isEmpty ? [] : [.text(proseOnly)]
            }

            // Convert ordered pieces → segments: contiguous text runs become one
            // parsed prose block; tools stay in place as their own segment.
            var segments: [TurnSegment] = []
            var pendingText: [String] = []
            var proseCounter = 0
            func flushProse() {
                guard !pendingText.isEmpty else { return }
                let joined = pendingText.joined(separator: "\n\n")
                segments.append(.prose(id: "\(starter.id)-\(proseCounter)",
                                       blocks: Markdown.parse(joined)))
                proseCounter += 1
                pendingText = []
            }
            for p in orderedPieces {
                switch p {
                case .text(let t): pendingText.append(t)
                case .tool(let tool): flushProse(); segments.append(.tool(tool))
                }
            }
            flushProse()

            if !chunks.isEmpty || !tools.isEmpty || images > 0 {
                // User: send time. Assistant: time of the final reply text.
                let ts = asUser ? firstTimestamp : (lastProseTimestamp ?? firstTimestamp)
                let body = chunks.joined(separator: "\n\n")
                turns.append(DialogTurn(
                    id: starter.id, role: asUser ? .user : .assistant,
                    timestamp: ts, bodyChunks: chunks,
                    toolUses: tools, imageCount: images,
                    imageStartIndex: images > 0 ? turnImageStart : -1,
                    isUserPrompt: asUser,
                    omitted: omitted, blocks: Markdown.parse(body),
                    segments: segments, imagePaths: imgPaths))
            }
        }
        return turns
    }
}

/// A conversation block: one user prompt followed by the run of Claude turns it
/// produced (up to the next user prompt). Blocks are the unit of scroll and
/// navigation — their stable id (the leading turn's id) makes scrollPosition
/// reliable even in huge sessions, and the outline mirrors them 1:1.
struct DialogBlock: Identifiable, Equatable {
    let id: String          // = leading turn's id (the user prompt, or first turn)
    let turns: [DialogTurn]
    /// True if this block is led by a real user prompt (for [ ] navigation).
    let hasPrompt: Bool

    /// The user prompt turn (first), if this block is led by one.
    var promptTurn: DialogTurn? { hasPrompt ? turns.first : nil }

    static func == (l: DialogBlock, r: DialogBlock) -> Bool {
        l.id == r.id && l.turns == r.turns
    }

    /// Group a flat turn list into blocks. A new block starts at each user
    /// prompt; assistant turns attach to the current block. A leading run of
    /// assistant turns (no preceding prompt) forms one promptless block.
    static func build(from turns: [DialogTurn]) -> [DialogBlock] {
        var blocks: [DialogBlock] = []
        var current: [DialogTurn] = []
        var leadIsPrompt = false
        func flush() {
            guard let first = current.first else { return }
            blocks.append(DialogBlock(id: first.id, turns: current, hasPrompt: leadIsPrompt))
            current = []
        }
        for t in turns {
            if t.isUserPrompt {
                flush()
                leadIsPrompt = true
                current = [t]
            } else {
                if current.isEmpty { leadIsPrompt = false }
                current.append(t)
            }
        }
        flush()
        return blocks
    }
}

/// A project with its session count, for the sidebar.
struct ProjectInfo: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let label: String
    let count: Int
}

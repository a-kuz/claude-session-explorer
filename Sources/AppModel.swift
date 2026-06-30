// Central observable state: sessions, filters, search, selection.

import Foundation
import SwiftUI
import Combine
import SwiftData
import AppKit

@MainActor
final class AppModel: ObservableObject {
    // Raw data
    @Published private(set) var allSessions: [SessionMeta] = []
    @Published private(set) var projects: [ProjectInfo] = []
    @Published private(set) var loading = true

    // Sidebar filtering is TWO independent axes, applied together:
    //  • `scope`  — a single-select folder / time window.
    //  • `selectedProjectPaths` — multi-select projects, layered on top of scope
    //    (and on top of "Needs reply").
    enum Scope: Hashable {
        case all
        case favorites
        case hidden
        case today
        case last24h
        case last2d
        case week
    }
    @Published var scope: Scope = .all { didSet { persistUIState() } }
    @Published var selectedProjectPaths: Set<String> = [] { didSet { persistUIState() } }

    /// Terminal used to open/resume sessions; mirrored into OpenSession.
    @Published var terminalApp: TerminalApp = .ghostty {
        didSet { OpenSession.terminal = terminalApp; persistUIState() }
    }
    /// Absolute path to `claude`; empty = auto-resolve via login shell.
    @Published var claudePath: String = "" {
        didSet { OpenSession.claudePathOverride = claudePath; persistUIState() }
    }

    /// Conversation prose font family ("" = system). Mono drives code/tools.
    @Published var proseFont: String = "" {
        didSet { DialogFonts.proseFamily = proseFont; bumpFonts(); persistUIState() }
    }
    @Published var monoFont: String = "" {
        didSet { DialogFonts.monoFamily = monoFont; bumpFonts(); persistUIState() }
    }

    /// Max characters of a tool's output kept when copying sessions/blocks to the
    /// clipboard; the overflow is replaced by a `… (N more chars)` marker. 0 = no
    /// limit (copy the full output). Prose and tool input are never truncated.
    @Published var copyToolOutputLimit: Int = 0 {
        didSet { persistUIState() }
    }
    /// Bumped on a font change so the transcript view re-renders its `Text` (the
    /// font lives in a global, not in the model the views diff against).
    @Published private(set) var fontTick = 0
    private func bumpFonts() { fontTick &+= 1 }

    /// Conversation text zoom (1.0 = 100%). ⌘+/⌘− and ⌘-scroll adjust it.
    @Published var fontScale: CGFloat = 1.0 { didSet { persistUIState() } }
    func zoom(_ delta: CGFloat) { setZoom(fontScale + delta) }
    func setZoom(_ value: CGFloat) {
        fontScale = min(2.0, max(0.7, (value * 100).rounded() / 100))
    }
    func setAir(_ value: CGFloat) { air = min(40, max(8, value.rounded())) }

    // Search
    @Published var query: String = "" { didSet { onQueryChanged() } }
    @Published private(set) var hits: [SearchHit] = []
    @Published private(set) var searching = false

    // Selection
    @Published var selectedID: String? {
        didSet {
            if selectedID != oldValue {
                syncListSelectionToSelected()
                loadSelectedDialog(); persistUIState()
            }
        }
    }
    /// Multi-selection of list rows (⌘/⇧-click). The detail pane follows the
    /// single active row (`selectedID`); this set is what "Copy Selected Sessions"
    /// acts on. Kept in sync with `selectedID` via the list binding.
    @Published var listSelection: Set<String> = []

    /// Apply a new list multi-selection coming from the List binding. The detail
    /// pane follows one row: keep the current `selectedID` if it's still in the
    /// set, otherwise adopt another member (or clear when empty).
    func updateListSelection(_ ids: Set<String>) {
        listSelection = ids
        if let cur = selectedID, ids.contains(cur) { return }
        selectedID = ids.first
    }

    /// Programmatic moves of `selectedID` (search, hide, triage, arrow keys)
    /// collapse the multi-selection down to that single row.
    private func syncListSelectionToSelected() {
        let want: Set<String> = selectedID.map { [$0] } ?? []
        if listSelection != want { listSelection = want }
    }
    @Published private(set) var dialog: SessionDialog?
    /// Merged turns derived from the dialog (one per speaker change).
    @Published private(set) var turns: [DialogTurn] = []
    /// Turns grouped into "prompt + following Claude turns" blocks — the unit of
    /// scroll, navigation and the outline. Derived navigation caches are rebuilt
    /// here (once per blocks change) so per-scroll-frame and per-keypress paths
    /// stay O(1) instead of re-filtering the whole list on big sessions.
    @Published private(set) var blocks: [DialogBlock] = [] {
        didSet { rebuildNavCache() }
    }

    /// Blocks led by a real user prompt — the navigable replies. Cached.
    private(set) var promptBlocks: [DialogBlock] = []
    /// Their ids, in order (block-jump targets). Cached.
    private(set) var userTurnIDs: [String] = []
    /// The user prompt turns, for the outline. Cached.
    private(set) var outlineTurns: [DialogTurn] = []
    /// blockID → index within `promptBlocks` (O(1) outline sync). Cached.
    private var promptIndexByID: [String: Int] = [:]
    /// blockID → index within the full `blocks` array (O(1) jump-distance). Cached.
    private var blockIndexByID: [String: Int] = [:]

    private func rebuildNavCache() {
        promptBlocks = blocks.filter { $0.hasPrompt }
        userTurnIDs = promptBlocks.map { $0.id }
        outlineTurns = promptBlocks.compactMap { $0.promptTurn }
        promptIndexByID = Dictionary(uniqueKeysWithValues: userTurnIDs.enumerated().map { ($1, $0) })
        blockIndexByID = Dictionary(uniqueKeysWithValues: blocks.enumerated().map { ($1.id, $0) })
    }
    /// Inline images of the open session, in order of appearance (lazy-loaded).
    @Published private(set) var dialogImages: [NSImage] = []

    // Layout — persisted UI state (see persistUIState / restoreUIState).
    @Published var sidebarCollapsed = false { didSet { persistUIState() } }
    /// The session-list column can be folded away too (like the sidebar), giving
    /// the conversation the full width.
    @Published var listCollapsed = false { didSet { persistUIState() } }
    /// Outline panel: a table of contents of the user's prompts. Open by default.
    @Published var showOutline = true { didSet { persistUIState() } }
    /// Set to request focus into the search field (from the `/` shortcut).
    @Published var focusSearchRequested = false
    /// Toggles the keyboard-shortcut cheat sheet overlay (⌘⇧?).
    @Published var showHotkeyHelp = false
    /// Set to move keyboard focus into the transcript (Enter on a list row).
    @Published var focusTranscriptRequested = false
    /// True while the transcript (detail) holds keyboard focus — bare ↑/↓ then
    /// navigate replies instead of moving the session selection.
    @Published var transcriptHasFocus = false
    /// Compact "compact" mode (hotkey r): hide tool machinery and intermediate
    /// assistant prose, keeping only prompts + the reply just before each prompt.
    @Published var briefMode = false {
        didSet { if briefMode != oldValue { rebuildTurns(); persistUIState() } }
    }
    /// How branched sessions render (active branch only / with a switcher / full
    /// tree). Sessions without branches look identical in every mode.
    @Published var branchMode: BranchMode = .activeOnly {
        didSet { if branchMode != oldValue { rebuildTurns(); persistUIState() } }
    }
    /// Group forked sessions under their parent in the list, indented. Off = a
    /// flat list sorted purely by time.
    @Published var groupForks = true { didSet { persistUIState() } }
    /// Branch structure of the open session (nil until a session is parsed).
    @Published private(set) var branchGraph: BranchGraph?
    /// uuid → the chosen child index, when the user overrode a branch point in
    /// `.switcher` mode. Cleared whenever the open session changes.
    @Published private(set) var branchChoice: [String: Int] = [:]
    /// True when the open session has at least one branch point.
    var hasBranches: Bool { branchGraph?.hasBranches ?? false }
    /// True while the search field holds keyboard focus (bare keys suppressed).
    @Published var searchFieldFocused = false

    /// Vertical "air" between replies in the conversation (8–40px), tunable.
    @Published var air: CGFloat = 18 { didSet { persistUIState() } }

    /// Resizable column widths (drag the dividers). NOT persisted on every change
    /// — that synchronous UserDefaults write on each drag delta caused jitter.
    /// Call `commitWidths()` once when the drag ends.
    @Published var sidebarWidth: CGFloat = 236
    @Published var listWidth: CGFloat = 366
    @Published var outlineWidth: CGFloat = 280

    // Clamp a proposed width to the panel's allowed range. Used live during a
    // drag (against local state) and again on commit.
    func clampSidebar(_ w: CGFloat) -> CGFloat { min(360, max(180, w)) }
    func clampList(_ w: CGFloat) -> CGFloat { min(520, max(260, w)) }
    func clampOutline(_ w: CGFloat) -> CGFloat { min(420, max(200, w)) }

    func resizeSidebar(_ w: CGFloat) { sidebarWidth = clampSidebar(w) }
    func resizeList(_ w: CGFloat) { listWidth = clampList(w) }
    func resizeOutline(_ w: CGFloat) { outlineWidth = clampOutline(w) }
    /// Persist the current widths (call on drag end).
    func commitWidths() { persistUIState() }

    /// "Reply to all in turn": a dedicated full-window triage screen that walks
    /// the sessions waiting on a reply, one at a time. Not a sidebar filter — a
    /// separate mode the whole window switches into.
    @Published var triageMode = false
    /// Index of the current session within `triageQueue`.
    @Published var triageIndex = 0

    /// Sessions still waiting on the user, newest first — the triage queue and
    /// the "Needs reply" badge count both come from here.
    var attentionSessions: [SessionMeta] {
        allSessions
            .filter { !hidden.contains($0.id) && needsAttention($0) && passesProjects($0) }
            .sorted { $0.mtime > $1.mtime }
    }
    var attentionCount: Int { attentionSessions.count }

    /// The current triage session (clamped to the queue).
    var triageCurrent: SessionMeta? {
        let q = attentionSessions
        guard !q.isEmpty else { return nil }
        return q[min(max(triageIndex, 0), q.count - 1)]
    }

    func enterTriage() {
        triageIndex = 0
        if let first = attentionSessions.first { selectedID = first.id }
        triageMode = true
    }
    func exitTriage() { triageMode = false }

    /// Advance to the next session in the triage queue (wrapping stops at the end).
    func triageAdvance() {
        let q = attentionSessions
        guard !q.isEmpty else { triageMode = false; return }
        if triageIndex >= q.count - 1 { triageMode = false; return }
        triageIndex += 1
        selectedID = q[triageIndex].id
    }
    func triageSkip() { triageAdvance() }
    /// Mark the current session as handled ("no reply needed") and move on.
    func triageResolve() {
        if let id = triageCurrent?.id { dismissAttention(id) }
        // The queue shrank under us — keep the same index (now points at the next).
        let q = attentionSessions
        if q.isEmpty { triageMode = false; return }
        triageIndex = min(triageIndex, q.count - 1)
        selectedID = q[triageIndex].id
    }

    // Match navigation (search highlight)
    @Published var matchIndex = 0
    @Published private(set) var matchCount = 0
    /// message id of the current match target (for scroll).
    @Published var scrollTarget: String?
    /// Bumped on every scroll request so the view re-scrolls even when the
    /// target id is unchanged (e.g. pressing ] at the last reply).
    @Published var scrollNonce = 0
    /// When true, the next scroll lands instantly (no animated travel) — used on
    /// session switch so the new transcript appears already in place, not
    /// scrolling across. Reset by the view after it consumes the request.
    @Published var scrollInstant = false
    /// True from the moment a programmatic jump (outline click, match/turn nav) is
    /// requested until the view finishes settling on it. While set, the scroll
    /// view's position feedback must NOT rewrite `turnIndex` — otherwise blocks
    /// flying past during the animated jump (or a still-settling previous jump on
    /// a rapid second click) overwrite the target and it lands on the wrong reply.
    @Published var jumpInFlight = false

    private func requestScroll(to id: String?, instant: Bool = false) {
        scrollInstant = instant
        scrollTarget = id
        jumpInFlight = true
        scrollNonce &+= 1
    }

    // Favorites (persisted)
    @Published private(set) var favorites: Set<String> = []
    /// Hidden session ids (persisted) — filtered out of the list entirely.
    @Published private(set) var hidden: Set<String> = []
    /// Sessions whose "needs attention" marker was manually dismissed (persisted).
    @Published private(set) var dismissedAttention: Set<String> = []
    /// Undo stack of recently hidden ids (Ctrl+Z restores the last).
    private var hiddenUndo: [String] = []

    private var searchTask: Task<Void, Never>?
    private let favKey = "favoriteSessionIDs"
    private let hiddenKey = "hiddenSessionIDs"
    private let dismissedKey = "dismissedAttentionIDs"
    private var watcher: FolderWatcher?
    private let store = Store()
    /// Derived-metadata schema version; bump to force recompute of cached rows.
    static let metaSchemaVersion = 3  // v3: parentSessionId (forkedFrom) captured
    /// Last opened session id, restored on next launch.
    private var lastSelectedID: String?
    private var didRestore = false

    init() {
        let d = UserDefaults.standard
        favorites = Set(d.stringArray(forKey: favKey) ?? [])
        hidden = Set(d.stringArray(forKey: hiddenKey) ?? [])
        dismissedAttention = Set(d.stringArray(forKey: dismissedKey) ?? [])
        restoreUIState()
    }

    // MARK: - Persisted UI state

    private enum K {
        static let sidebar = "ui.sidebarCollapsed"
        static let listCollapsed = "ui.listCollapsed"
        static let outline = "ui.showOutline"
        static let brief = "ui.briefMode"
        static let branch = "ui.branchMode"          // activeOnly|switcher|tree
        static let groupForks = "ui.groupForks"
        static let zoom = "ui.fontScale"
        static let selected = "ui.lastSelectedID"
        static let air = "ui.air"
        static let wSidebar = "ui.w.sidebar"
        static let wList = "ui.w.list"
        static let wOutline = "ui.w.outline"
        static let scope = "ui.scope"               // all|favorites|today|last24h|last2d|week
        static let projects = "ui.projects"         // [String] selected project paths
        static let terminal = "ui.terminal"         // ghostty|terminal|iterm
        static let claudePath = "ui.claudePath"     // absolute path override
        static let proseFont = "ui.proseFont"       // conversation prose family
        static let monoFont = "ui.monoFont"         // conversation mono family
        static let copyToolLimit = "ui.copyToolOutputLimit" // 0 = no limit
    }

    private func restoreUIState() {
        let d = UserDefaults.standard
        sidebarCollapsed = d.bool(forKey: K.sidebar)
        listCollapsed = d.bool(forKey: K.listCollapsed)
        if d.object(forKey: K.outline) != nil { showOutline = d.bool(forKey: K.outline) }
        briefMode = d.bool(forKey: K.brief)
        if let b = d.string(forKey: K.branch), let m = BranchMode(rawValue: b) { branchMode = m }
        if d.object(forKey: K.groupForks) != nil { groupForks = d.bool(forKey: K.groupForks) }
        if let z = d.object(forKey: K.zoom) as? Double, z > 0 { fontScale = CGFloat(z) }
        if let a = d.object(forKey: K.air) as? Double, a > 0 { air = CGFloat(min(max(a, 8), 40)) }
        if let w = d.object(forKey: K.wSidebar) as? Double, w > 0 { resizeSidebar(CGFloat(w)) }
        if let w = d.object(forKey: K.wList) as? Double, w > 0 { resizeList(CGFloat(w)) }
        if let w = d.object(forKey: K.wOutline) as? Double, w > 0 { resizeOutline(CGFloat(w)) }
        // Restore both filter axes independently.
        switch d.string(forKey: K.scope) {
        case "favorites": scope = .favorites
        case "today": scope = .today
        case "last24h": scope = .last24h
        case "last2d": scope = .last2d
        case "week": scope = .week
        default: scope = .all
        }
        selectedProjectPaths = Set(d.stringArray(forKey: K.projects) ?? [])
        if let t = d.string(forKey: K.terminal), let m = TerminalApp(rawValue: t) { terminalApp = m }
        claudePath = d.string(forKey: K.claudePath) ?? ""
        proseFont = d.string(forKey: K.proseFont) ?? ""
        monoFont = d.string(forKey: K.monoFont) ?? ""
        copyToolOutputLimit = max(0, d.integer(forKey: K.copyToolLimit))
        OpenSession.terminal = terminalApp
        OpenSession.claudePathOverride = claudePath
        DialogFonts.proseFamily = proseFont
        DialogFonts.monoFamily = monoFont
        lastSelectedID = d.string(forKey: K.selected)
        didRestore = true
    }

    /// Restore the last opened session if it's still present, else the newest.
    private func defaultSelection() -> String? {
        if let last = lastSelectedID, filteredHits.contains(where: { $0.meta.id == last }) {
            return last
        }
        return filteredHits.first?.meta.id
    }

    private func persistUIState() {
        guard didRestore else { return } // don't clobber during restore
        let d = UserDefaults.standard
        d.set(sidebarCollapsed, forKey: K.sidebar)
        d.set(listCollapsed, forKey: K.listCollapsed)
        d.set(showOutline, forKey: K.outline)
        d.set(briefMode, forKey: K.brief)
        d.set(branchMode.rawValue, forKey: K.branch)
        d.set(groupForks, forKey: K.groupForks)
        d.set(Double(fontScale), forKey: K.zoom)
        d.set(Double(air), forKey: K.air)
        d.set(Double(sidebarWidth), forKey: K.wSidebar)
        d.set(Double(listWidth), forKey: K.wList)
        d.set(Double(outlineWidth), forKey: K.wOutline)
        let scopeStr: String
        switch scope {
        // "Hidden" is a transient view; on restore it falls back to All.
        case .all, .hidden: scopeStr = "all"
        case .favorites: scopeStr = "favorites"
        case .today: scopeStr = "today"
        case .last24h: scopeStr = "last24h"
        case .last2d: scopeStr = "last2d"
        case .week: scopeStr = "week"
        }
        d.set(scopeStr, forKey: K.scope)
        d.set(Array(selectedProjectPaths), forKey: K.projects)
        d.set(terminalApp.rawValue, forKey: K.terminal)
        d.set(claudePath, forKey: K.claudePath)
        d.set(proseFont, forKey: K.proseFont)
        d.set(monoFont, forKey: K.monoFont)
        d.set(copyToolOutputLimit, forKey: K.copyToolLimit)
        d.set(selectedID, forKey: K.selected)
    }

    // MARK: - Loading

    func load() {
        // 1) Instant first paint from the persistent cache.
        let cached = store.loadCachedMetas()
        if !cached.isEmpty {
            allSessions = cached
            rebuildProjects()
            loading = false
            recomputeHits(instant: true)
            if selectedID == nil { selectedID = defaultSelection() }
        }
        // 2) Background sync: parse only new/changed tails, update cache + UI.
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.sync(initial: cached.isEmpty)
            await MainActor.run { self?.startWatching() }
        }
    }

    private func startWatching() {
        guard watcher == nil else { return }
        watcher = FolderWatcher(path: Loader.projectsDir.path) { [weak self] in
            Task.detached(priority: .utility) { await self?.sync(initial: false) }
        }
        watcher?.start()
    }

    /// The open session's file mtime, to detect whether *it* actually changed.
    private var openDialogMtime: Date?

    /// Incrementally reconcile the on-disk jsonl files with the cache. Each line
    /// is parsed at most once: unchanged files are skipped by mtime, changed
    /// files are read only from their stored `parsedOffset` (append-only). Then
    /// the UI + DB are updated. Runs off the main thread.
    nonisolated private func sync(initial: Bool) async {
        let ctx = ModelContext(store.container)
        let files = Loader.listSessionFiles()
        // Index existing records by id for quick lookup.
        let existing = (try? ctx.fetch(FetchDescriptor<SessionRecord>())) ?? []
        var byID: [String: SessionRecord] = [:]
        for r in existing { byID[r.id] = r }

        var dirty = false
        var sinceSave = 0

        for path in files {
            let id = (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
            let mtime = Loader.fileMtime(path)
            let size = Int(Loader.fileLength(path))

            let rec = byID[id]
            // Unchanged file with up-to-date metadata schema → nothing to do.
            if let rec, rec.fileMtime == mtime, rec.byteSize == size,
               rec.schemaVersion >= Self.metaSchemaVersion {
                continue
            }

            // An active session is append-only: when it only grew (cached row,
            // current schema, file larger than the parsed prefix), read just the
            // appended tail from `parsedOffset` and fold it into the cached
            // metadata — instead of re-reading and re-parsing the whole file on
            // every write, which is the dominant cost for a large live session.
            var meta: SessionMeta?
            var newOffset = size
            if let rec, rec.schemaVersion >= Self.metaSchemaVersion,
               size > rec.parsedOffset,
               let prev = byID[id].map({ SessionMeta(record: $0) }),
               let upd = Loader.updateSessionMeta(prev: prev, filePath: path,
                                                  fromOffset: UInt64(rec.parsedOffset)) {
                meta = upd.meta
                newOffset = Int(upd.newOffset)
            } else {
                // Cold parse: new file, shrunk/rotated file, or a schema bump.
                meta = Loader.parseSessionMeta(path)
            }
            guard let meta else { continue }
            store.upsert(meta: meta, offset: newOffset, fileMtime: mtime,
                         schemaVersion: Self.metaSchemaVersion, into: ctx)
            dirty = true
            sinceSave += 1

            // Persist + push to the UI in batches so a COLD first scan fills the
            // list progressively and survives an early quit (no all-or-nothing).
            // A warm re-sync touches only the handful of changed files, so the
            // intermediate full-table fetch/publish is pure overhead there — do it
            // only on the initial scan; warm syncs publish once at the end.
            if sinceSave >= 25 {
                try? ctx.save()
                sinceSave = 0
                if initial {
                    let snapshot = store.metas(in: ctx)
                    await MainActor.run { [weak self] in self?.applySynced(snapshot) }
                }
            }
        }

        // Remove records for deleted files.
        let live = Set(files.map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "") })
        for r in existing where !live.contains(r.id) { ctx.delete(r); dirty = true }

        if dirty || sinceSave > 0 { try? ctx.save() }

        guard dirty || initial else { return }
        let fresh = store.metas(in: ctx)
        await MainActor.run { [weak self] in
            guard let self else { return }
            self.applySynced(fresh)
        }
    }

    /// A cheap fingerprint of the list-relevant state of a session set, so we
    /// only republish (and re-render the List) when something the list actually
    /// shows changed. Without this, every write into ~/.claude/projects — including
    /// the active session writing itself — reassigned `allSessions`/`hits` and
    /// re-rendered the list mid-scroll, causing jank.
    private var lastSyncSignature = ""
    private func signature(_ sessions: [SessionMeta]) -> String {
        var h = Hasher()
        for s in sessions {
            h.combine(s.id)
            h.combine(s.mtime)
            h.combine(s.lastUserText)
            h.combine(s.lastClaudeTime)
            h.combine(s.byteSize)
        }
        return String(h.finalize())
    }

    private var pendingSynced: [SessionMeta]?
    private var coalesceTask: Task<Void, Never>?

    /// Merge a freshly-synced session set into the UI. Background file writes
    /// (including the active session writing itself, and unrelated sessions) must
    /// NOT jolt the list while the user reads/scrolls — so list updates are
    /// coalesced and applied on a short debounce, and only when the list-visible
    /// state actually changed. The OPEN dialog is refreshed immediately and
    /// independently (that's the one the user is looking at).
    private func applySynced(_ sessions: [SessionMeta]) {
        loading = false

        // 1) Open dialog grows in real time — handle right away, no debounce.
        if let meta = selectedMeta {
            let m = Loader.fileMtime(meta.filePath)
            if m != openDialogMtime {
                openDialogMtime = m
                refreshOpenDialog()
            }
        }

        // 2) The session LIST — coalesce, then apply on idle with animation, so a
        //    session that just became active visibly slides to the top instead of
        //    snapping. Skipped entirely if nothing list-visible changed.
        pendingSynced = sessions
        coalesceTask?.cancel()
        coalesceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self else { return }
            // Wait for the user to stop scrolling before reordering under them.
            while self.listIsScrolling {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { return }
            }
            self.flushPendingSynced()
        }
    }

    /// True while the user is actively scrolling the session list — set by the
    /// list view; gates animated reorders so rows don't jump under the cursor.
    @Published var listIsScrolling = false

    private func flushPendingSynced() {
        guard let pending = pendingSynced else { return }
        pendingSynced = nil
        let sig = signature(pending)
        guard sig != lastSyncSignature else { return }
        lastSyncSignature = sig
        // Animate the reorder/insert: stable ids let SwiftUI slide rows.
        withAnimation(.snappy(duration: 0.35)) {
            allSessions = pending
            recomputeHits(instant: true)
        }
        rebuildProjects()
        if selectedID == nil { selectedID = defaultSelection() }
    }

    /// Append-only refresh: read just the new tail of the open jsonl and append
    /// the new messages, so existing turns keep their identity and SwiftUI only
    /// renders the added ones (no full rebuild, no flash).
    private func refreshOpenDialog() {
        guard let meta = selectedMeta else { return }
        let path = meta.filePath
        let fromOffset = dialogOffset
        Task.detached(priority: .utility) {
            guard let tail = Loader.loadDialogTail(path, fromOffset: fromOffset) else { return }
            await MainActor.run {
                guard self.selectedID == meta.id else { return }
                if tail.truncated {
                    // File rotated/shrank — fall back to a full reload.
                    let d = Loader.loadDialog(path)
                    self.dialogMessages = d.messages
                    self.dialogOffset = Loader.fileLength(path)
                    self.setDialog(d)
                    return
                }
                guard !tail.messages.isEmpty else {
                    self.dialogOffset = tail.newOffset; return
                }
                self.dialogMessages.append(contentsOf: tail.messages)
                self.dialogOffset = tail.newOffset
                self.dialog = SessionDialog(id: meta.id, messages: self.dialogMessages)
                // A regenerated tail can append a new branch, so re-derive the
                // graph. Stable ids mean unchanged turns keep identity, so only
                // the new/last turn(s) actually re-render.
                self.branchGraph = BranchGraph.build(from: self.dialogMessages)
                self.rebuildTurnsAppending()
            }
        }
    }

    private func rebuildProjects() {
        var counts: [String: (label: String, n: Int)] = [:]
        for s in allSessions {
            let cur = counts[s.projectPath]
            counts[s.projectPath] = (s.projectLabel, (cur?.n ?? 0) + 1)
        }
        projects = counts.map { ProjectInfo(path: $0.key, label: $0.value.label, count: $0.value.n) }
            .sorted { $0.count > $1.count }
    }

    // MARK: - Filtering

    /// Does a session pass the current scope (time window / folder)?
    private func passesScope(_ s: SessionMeta, now: Date, cal: Calendar) -> Bool {
        switch scope {
        case .all: return true
        case .favorites: return favorites.contains(s.id)
        case .hidden: return hidden.contains(s.id)
        case .today: return cal.isDateInToday(s.mtime)
        case .last24h:
            guard let t = cal.date(byAdding: .hour, value: -24, to: now) else { return true }
            return s.mtime > t
        case .last2d:
            guard let t = cal.date(byAdding: .day, value: -2, to: now) else { return true }
            return s.mtime > t
        case .week:
            guard let t = cal.date(byAdding: .day, value: -7, to: now) else { return true }
            return s.mtime > t
        }
    }

    /// Does a session pass the project axis? Empty selection = all projects.
    private func passesProjects(_ s: SessionMeta) -> Bool {
        selectedProjectPaths.isEmpty || selectedProjectPaths.contains(s.projectPath)
    }

    private func candidatesForFilter() -> [SessionMeta] {
        let now = Date()
        let cal = Calendar.current
        // The "Hidden" scope shows ONLY hidden sessions; every other scope
        // excludes them. The project axis still applies in both cases.
        if scope == .hidden {
            return allSessions.filter { hidden.contains($0.id) && passesProjects($0) }
        }
        return allSessions.filter {
            !hidden.contains($0.id) && passesScope($0, now: now, cal: cal) && passesProjects($0)
        }
    }

    /// Hits already filtered to the active sidebar selection.
    var filteredHits: [SearchHit] { hits }

    func setScope(_ s: Scope) {
        scope = s
        recomputeHits(instant: false)
        if !(filteredHits.contains { $0.meta.id == selectedID }) {
            selectedID = filteredHits.first?.meta.id
        }
    }

    // MARK: - Project multi-select (checkboxes) — independent of scope.

    func isProjectSelected(_ path: String) -> Bool { selectedProjectPaths.contains(path) }

    func toggleProject(_ path: String) {
        if selectedProjectPaths.contains(path) { selectedProjectPaths.remove(path) }
        else { selectedProjectPaths.insert(path) }
        recomputeHits(instant: false)
        if !(filteredHits.contains { $0.meta.id == selectedID }) {
            selectedID = filteredHits.first?.meta.id
        }
    }

    func selectAllProjects() {
        selectedProjectPaths = Set(projects.map(\.path))
        recomputeHits(instant: false)
    }

    func clearProjects() {
        selectedProjectPaths = []
        recomputeHits(instant: false)
    }

    // MARK: - Search

    private func onQueryChanged() {
        recomputeHits(instant: true)
    }

    private func recomputeHits(instant: Bool) {
        searchTask?.cancel()
        let candidates = candidatesForFilter()
        let q = query

        // Instant cheap tier on the main actor.
        let cheap = Search.searchCheap(candidates, q)
        self.hits = cheap.sorted { $0.meta.mtime > $1.meta.mtime }

        if q.trimmingCharacters(in: .whitespaces).isEmpty { searching = false; return }

        // Deep tier off-thread, merged in.
        searching = true
        let snapshot = candidates
        let token = UUID()
        currentSearchToken = token
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Debounce: don't re-read every file on each keystroke. Wait for a
            // typing pause; a newer keystroke cancels this task first.
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            let chunkSize = 40
            var accumulated: [SearchHit] = []
            var i = 0
            while i < snapshot.count {
                if Task.isCancelled { return }
                let end = min(i + chunkSize, snapshot.count)
                let chunk = Array(snapshot[i..<end])
                let part = Search.searchDeep(chunk, q, isCancelled: { Task.isCancelled })
                accumulated.append(contentsOf: part)
                let sorted = accumulated.sorted { $0.meta.mtime > $1.meta.mtime }
                let done = end >= snapshot.count
                await MainActor.run { [weak self] in
                    guard let self, self.currentSearchToken == token else { return }
                    self.hits = sorted
                    if done { self.searching = false }
                    if !(self.hits.contains { $0.meta.id == self.selectedID }) {
                        self.selectedID = self.hits.first?.meta.id
                    }
                }
                i = end
            }
        }
    }

    private var currentSearchToken: UUID?

    var searchTokens: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return [] }
        return trimmed.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    // MARK: - Selection / dialog

    var selectedMeta: SessionMeta? {
        guard let id = selectedID else { return nil }
        return allSessions.first { $0.id == id }
    }

    /// Raw messages of the open dialog and the byte offset already consumed —
    /// the basis for append-only incremental updates.
    private var dialogMessages: [DialogMessage] = []
    private var dialogOffset: UInt64 = 0

    private func loadSelectedDialog() {
        guard let meta = selectedMeta else {
            dialog = nil; turns = []; dialogMessages = []; dialogOffset = 0; dialogImages = []
            recomputeMatches(); return
        }
        loadImagesFor(meta)
        // Read the dialog from the jsonl off the main thread (Loader keeps a
        // small LRU of recently opened dialogs in memory). The full transcript
        // is never persisted in the DB.
        let path = meta.filePath
        Task.detached(priority: .userInitiated) {
            let d = Loader.loadDialogCached(meta)
            let len = Loader.fileLength(path)
            await MainActor.run {
                guard self.selectedID == meta.id else { return }
                self.dialogMessages = d.messages
                self.dialogOffset = len
                self.openDialogMtime = Loader.fileMtime(path)
                self.setDialog(d)
            }
        }
    }

    /// Lazily load inline images for a session off the main thread.
    private func loadImagesFor(_ meta: SessionMeta) {
        dialogImages = []
        let path = meta.filePath
        let id = meta.id
        Task.detached(priority: .utility) {
            let imgs = Loader.loadImages(path)
            guard !imgs.isEmpty else { return }
            await MainActor.run { if self.selectedID == id { self.dialogImages = imgs } }
        }
    }

    func selectNext(_ delta: Int) {
        let list = filteredHits
        guard !list.isEmpty else { return }
        let idx = list.firstIndex { $0.meta.id == selectedID } ?? 0
        let next = max(0, min(list.count - 1, idx + delta))
        selectedID = list[next].meta.id
    }

    /// Build merged turns and refresh derived navigation state. Opens the
    /// session scrolled to its last turn (most recent reply), unless a search is
    /// active (then we jump to the first match instead).
    private func setDialog(_ d: SessionDialog) {
        dialog = d
        branchGraph = BranchGraph.build(from: d.messages)
        branchChoice = [:]
        rebuildTurns()
        // recomputeMatches (inside rebuildTurns) already scrolled to a match when
        // searching; otherwise land on the end of the conversation.
        if searchTokens.isEmpty {
            turnIndex = max(0, userTurnIDs.count - 1)
            // Session just switched: land at the end instantly (no animated
            // top→bottom travel, which read as a jarring jump).
            if let last = blocks.last?.id { requestScroll(to: last, instant: true) }
        }
    }

    /// Re-derive turns + blocks from the current dialog (e.g. on briefMode /
    /// branchMode change, or a branch-point override).
    private func rebuildTurns() {
        guard let d = dialog else { turns = []; blocks = []; return }
        let source = messagesForRender(d.messages)
        turns = DialogTurn.build(from: source, brief: briefMode)
        blocks = DialogBlock.build(from: turns)
        recomputeMatches()
    }

    /// Incremental rebuild after a pure tail append (append-only jsonl). A real
    /// user prompt is a hard turn boundary: every turn before the LAST one in the
    /// rendered message order is already closed and can't change when lines are
    /// appended. So we rebuild only from that last boundary, seeding the image
    /// cursor with the count consumed before it, and splice the result onto the
    /// stable prefix — instead of re-deriving the whole transcript on every line a
    /// live session writes. Falls back to a full rebuild when the rendered order
    /// isn't the raw message order (active branch filter) — there indices wouldn't
    /// line up, and that isn't the live-append hot path anyway.
    private func rebuildTurnsAppending() {
        guard let d = dialog, branchMode == .tree || branchGraph?.hasBranches != true else {
            rebuildTurns(); return
        }
        let msgs = d.messages
        // Find the last real user prompt; rebuild from there. If none, full build.
        guard let lastPrompt = msgs.lastIndex(where: { DialogTurn.isRealUserPrompt($0) }) else {
            rebuildTurns(); return
        }
        // Images consumed by messages before the rebuild point seed the cursor so
        // per-turn image slicing stays aligned with the session-wide image array.
        var imageCursorStart = 0
        for k in 0..<lastPrompt { imageCursorStart += msgs[k].imageCount }

        let tailTurns = DialogTurn.build(from: msgs, brief: briefMode,
                                         fromMessageIndex: lastPrompt,
                                         imageCursorStart: imageCursorStart)
        // The stable prefix is every turn before the one led by msgs[lastPrompt].
        let boundaryID = msgs[lastPrompt].id
        if let cut = turns.firstIndex(where: { $0.id == boundaryID }) {
            turns = Array(turns[..<cut]) + tailTurns
        } else {
            // Prefix doesn't contain the boundary yet (first build) → full.
            turns = DialogTurn.build(from: msgs, brief: briefMode)
        }
        blocks = DialogBlock.build(from: turns)
        recomputeMatches()
    }

    /// The message slice to render, per `branchMode`:
    /// - `.tree`: the raw file order (every branch shown; the view indents them).
    /// - otherwise: the active linear path, honoring any `.switcher` overrides.
    private func messagesForRender(_ messages: [DialogMessage]) -> [DialogMessage] {
        guard let g = branchGraph, g.hasBranches, branchMode != .tree else { return messages }
        let path = activeBranchPath(in: messages, graph: g)
        return path.map { messages[$0] }
    }

    /// Indices of the linear path to render: like `BranchGraph.activePath`, but at
    /// any branch point the user overrode in `.switcher` mode, take their child.
    private func activeBranchPath(in messages: [DialogMessage], graph g: BranchGraph) -> [Int] {
        let auto = g.activePath(in: messages)
        guard branchMode == .switcher, !branchChoice.isEmpty else { return auto }
        var path: [Int] = []
        var frontier = g.childrenOf[""] ?? []
        // Walk down, preferring an overridden child where one exists; otherwise
        // fall back to the auto-path's choice at this point.
        let autoSet = Set(auto)
        while !frontier.isEmpty {
            let chosen: Int
            if frontier.count > 1, let parentUUID = parentUUID(of: frontier, in: messages),
               let pick = branchChoice[parentUUID], frontier.contains(pick) {
                chosen = pick
            } else if let auto = frontier.first(where: { autoSet.contains($0) }) {
                chosen = auto
            } else {
                chosen = frontier.max(by: { $0 < $1 }) ?? frontier[0]
            }
            path.append(chosen)
            frontier = g.childrenOf[messages[chosen].uuid] ?? []
        }
        return path
    }

    /// All children in a frontier share one parent uuid; return it.
    private func parentUUID(of frontier: [Int], in messages: [DialogMessage]) -> String? {
        guard let first = frontier.first else { return nil }
        return messages[first].parentUuid ?? messages[first].logicalParentUuid
    }

    /// One alternative at a branch point: the child message id and a label.
    struct BranchAlternative: Identifiable {
        let id: String          // child message uuid
        let index: Int          // 1-based ordinal among siblings
        let total: Int
        let isActive: Bool      // currently on the rendered path
        let preview: String     // first line of the child's text
    }

    /// If `messageID` is a message whose parent has ≥2 children — i.e. the first
    /// message of a branch — return the sibling alternatives at that branch point.
    /// `messageID` is a turn/block id (a message uuid). Empty when not a branch.
    func branchAlternatives(forFirstMessageID messageID: String) -> [BranchAlternative] {
        guard let d = dialog, let g = branchGraph else { return [] }
        guard let m = d.messages.first(where: { $0.id == messageID }) else { return [] }
        guard let parent = m.parentUuid ?? m.logicalParentUuid,
              let siblings = g.childrenOf[parent], siblings.count > 1 else { return [] }
        let renderedIDs = Set(blocks.flatMap { $0.turns.map(\.id) })
        return siblings.enumerated().map { ord, idx in
            let msg = d.messages[idx]
            let preview = MessageContent.oneLine(MessageContent.stripNoise(msg.bodyText), max: 60)
            return BranchAlternative(
                id: msg.id, index: ord + 1, total: siblings.count,
                isActive: renderedIDs.contains(msg.id),
                preview: preview.isEmpty ? "…" : preview)
        }
    }

    /// Switch the active branch to the one starting at `childID` (from the
    /// `.switcher` UI). Resolves the branch point from the child's parent.
    func chooseBranch(childID: String) {
        guard let d = dialog, let g = branchGraph else { return }
        guard let child = d.messages.first(where: { $0.id == childID }),
              let parent = child.parentUuid ?? child.logicalParentUuid,
              let idx = g.childrenOf[parent]?.first(where: { d.messages[$0].id == childID })
        else { return }
        branchChoice[parent] = idx
        rebuildTurns()
    }

    // MARK: - Match navigation

    /// Turn ids that contain a search match (all tokens present).
    @Published private(set) var matchTurnIDs: [String] = []

    private func recomputeMatches() {
        guard !searchTokens.isEmpty else {
            matchTurnIDs = []; matchCount = 0; matchIndex = 0; scrollTarget = nil; return
        }
        let tokens = searchTokens
        // A block matches if any of its turns contains all tokens; scroll targets
        // are block ids (only blocks are scroll anchors in the conversation).
        let ids = blocks.compactMap { block -> String? in
            let hit = block.turns.contains { turn in
                let body = turn.bodyText.lowercased()
                return tokens.allSatisfy { body.contains($0) }
            }
            return hit ? block.id : nil
        }
        matchTurnIDs = ids
        matchCount = ids.count
        matchIndex = 0
        requestScroll(to: ids.first)
    }

    func nextMatch(_ delta: Int) {
        guard matchCount > 0 else { return }
        matchIndex = (matchIndex + delta + matchCount) % matchCount
        requestScroll(to: matchTurnIDs[matchIndex])
    }

    // MARK: - Block navigation (one block = a user prompt + its Claude turns)

    /// Index into promptBlocks of the current reply.
    @Published var turnIndex = 0

    func jumpTurn(_ delta: Int) {
        let ids = userTurnIDs
        guard !ids.isEmpty else { return }
        turnIndex = max(0, min(ids.count - 1, turnIndex + delta))
        requestScroll(to: ids[turnIndex])
    }

    /// Jump to the first / last reply (⌃⌘[ / ⌃⌘]).
    func jumpFirstTurn() {
        guard let first = userTurnIDs.first else { return }
        turnIndex = 0; requestScroll(to: first)
    }
    func jumpLastTurn() {
        let ids = userTurnIDs
        guard let last = ids.last else { return }
        turnIndex = ids.count - 1; requestScroll(to: last)
    }

    /// Sync the outline's current item to the block currently at the top of the
    /// viewport while scrolling (id is the top-most visible block id).
    func syncTurnIndex(toTopMostID id: String) {
        // Ignore position feedback while a programmatic jump is settling — only
        // free user scrolling should drive the outline's current item.
        guard !jumpInFlight else { return }
        guard let idx = promptIndexByID[id] else { return }
        if idx != turnIndex { turnIndex = idx }
    }

    /// Block index within the navigable prompt blocks, for debug readouts.
    func promptIndex(of id: String?) -> Int? {
        guard let id else { return nil }
        return promptIndexByID[id]
    }

    /// Index of a block id within the FULL block list (all blocks, not only
    /// prompt-led ones) — used to measure jump distance for near/far scroll choice.
    func blockIndex(of id: String?) -> Int? {
        guard let id else { return nil }
        return blockIndexByID[id]
    }

    /// Jump straight to a block (from the outline).
    func jumpToTurn(_ id: String) {
        if let idx = promptIndexByID[id] { turnIndex = idx }
        requestScroll(to: id)
    }

    // MARK: - Copy blocks (from the outline selection)

    /// Plain-text transcript of the given blocks, in conversation order, with
    /// each turn labelled ("You:" / "Claude:") and tool calls (name · arg, then
    /// their output) rendered in place — so the copy is the full exchange.
    func copyText(forBlockIDs ids: Set<String>) -> String {
        let chosen = blocks.filter { ids.contains($0.id) }
        return Self.plainText(forBlocks: chosen, toolOutputLimit: copyToolOutputLimit)
    }

    /// Plain-text transcript of the given blocks (in the order passed) — the
    /// shared renderer used both for an outline selection and for whole-session
    /// copying. Stateless, so it can run off the main actor on a freshly loaded
    /// dialog of any session, not just the open one.
    /// `toolOutputLimit` caps the characters kept from each tool's output (0 = no
    /// limit); prose and tool input are always copied in full.
    nonisolated static func plainText(forBlocks chosen: [DialogBlock],
                                      toolOutputLimit: Int = 0) -> String {
        var out: [String] = []
        for block in chosen {
            for turn in block.turns {
                var who = turn.role == .user ? "You" : "Claude"
                if let ts = turn.timestamp { who += " · \(Format.longDateTime(ts))" }
                let body = turnPlainText(turn, toolOutputLimit: toolOutputLimit)
                guard !body.isEmpty else { continue }
                out.append("\(who):\n\(body)")
            }
            out.append("────────")   // separator between prompt→answer blocks
        }
        if out.last == "────────" { out.removeLast() }
        return out.joined(separator: "\n\n")
    }

    /// Full text of a turn: prose and tool calls in their original order.
    nonisolated private static func turnPlainText(_ turn: DialogTurn,
                                                  toolOutputLimit: Int) -> String {
        // Prefer ordered segments (prose interleaved with tools); fall back to
        // bodyChunks if segments weren't built.
        var lines: [String] = []
        if !turn.segments.isEmpty {
            for seg in turn.segments {
                switch seg {
                case .prose(_, let blocks):
                    let t = blocks.map(\.plainText).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { lines.append(t) }
                case .tool(let tool):
                    lines.append(toolPlainText(tool, outputLimit: toolOutputLimit))
                }
            }
        } else {
            let t = turn.bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { lines.append(t) }
            for tool in turn.toolUses { lines.append(toolPlainText(tool, outputLimit: toolOutputLimit)) }
        }
        return lines.joined(separator: "\n\n")
    }

    /// A tool call as text — name, complete input, and output. The output is kept
    /// in full when `outputLimit` is 0, otherwise capped to that many characters
    /// with a `… (N more chars)` marker for the overflow.
    nonisolated private static func toolPlainText(_ tool: ToolUse, outputLimit: Int) -> String {
        var s = "[\(tool.name)]"
        let input = (tool.input.isEmpty ? tool.arg : tool.input)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !input.isEmpty { s += "\n\(input)" }
        let outTxt = tool.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !outTxt.isEmpty { s += "\n→\n\(clampOutput(outTxt, limit: outputLimit))" }
        return s
    }

    /// Truncate to `limit` characters (counting Characters, not UTF-16 units),
    /// appending a marker with how many were dropped. `limit <= 0` keeps it whole.
    nonisolated private static func clampOutput(_ text: String, limit: Int) -> String {
        guard limit > 0, text.count > limit else { return text }
        let kept = String(text.prefix(limit))
        let dropped = text.count - limit
        return "\(kept)\n… (\(dropped) more chars)"
    }

    /// Copy the selected outline blocks to the clipboard.
    func copyBlocksToClipboard(_ ids: Set<String>) {
        let text = copyText(forBlockIDs: ids)
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        showToast("Blocks copied: \(ids.count)")
    }

    // MARK: - Copy whole sessions (from the list selection)

    /// Build the active-line blocks of an already-loaded dialog, without any
    /// per-session UI branch overrides — the deterministic newest-leaf path,
    /// same as a freshly opened session shows by default.
    nonisolated static func blocksForFullCopy(_ d: SessionDialog) -> [DialogBlock] {
        let graph = BranchGraph.build(from: d.messages)
        let source: [DialogMessage]
        if graph.hasBranches {
            source = graph.activePath(in: d.messages).map { d.messages[$0] }
        } else {
            source = d.messages
        }
        let turns = DialogTurn.build(from: source)
        return DialogBlock.build(from: turns)
    }

    /// Keep only blocks at or newer than `since` — by the block's leading turn
    /// timestamp (the user prompt, or first assistant turn for a promptless one).
    /// A block whose lead turn has no timestamp is dropped when a threshold is set.
    /// `since == nil` returns the blocks unchanged.
    nonisolated static func blocks(_ blocks: [DialogBlock], newerThan since: Date?) -> [DialogBlock] {
        guard let since else { return blocks }
        return blocks.filter { block in
            guard let ts = block.turns.first?.timestamp else { return false }
            return ts >= since
        }
    }

    /// Copy one or more whole sessions — title header + full transcript each,
    /// in the list's order. Loads every dialog off the main thread (the open one
    /// included, for a uniform path) and writes the joined text to the clipboard.
    /// Menu label that reflects how many sessions ⌘C would copy.
    var copySessionsLabel: String {
        let n = copyTargetIDs.count
        return n > 1 ? "Copy \(n) Sessions with Content" : "Copy Session with Content"
    }

    /// The list rows ⌘C acts on: the multi-selection if present, else the single
    /// selected row.
    private var copyTargetIDs: Set<String> {
        if !listSelection.isEmpty { return listSelection }
        return selectedID.map { [$0] } ?? []
    }

    /// ⌘C from the menu: copy the current list selection with full content.
    func copySelectedSessions() { copySessionsToClipboard(copyTargetIDs) }

    /// Copy whole sessions; when `since` is set, only blocks at or newer than that
    /// date are kept (a session that ends up empty contributes just its header).
    func copySessionsToClipboard(_ ids: Set<String>, since: Date? = nil) {
        // Order by the visible list (search-aware); fall back to allSessions for
        // any id not currently in hits.
        var metas = hits.map(\.meta).filter { ids.contains($0.id) }
        let found = Set(metas.map(\.id))
        metas += allSessions.filter { ids.contains($0.id) && !found.contains($0.id) }
        guard !metas.isEmpty else { return }
        showToast(metas.count == 1 ? "Copying session…" : "Copying \(metas.count) sessions…")
        let toolLimit = copyToolOutputLimit
        Task.detached(priority: .userInitiated) {
            var parts: [String] = []
            for meta in metas {
                let d = Loader.loadDialogCached(meta)
                let kept = Self.blocks(Self.blocksForFullCopy(d), newerThan: since)
                let body = Self.plainText(forBlocks: kept, toolOutputLimit: toolLimit)
                let header = "# \(AutoTitle.displayTitle(meta))\n\(meta.projectLabel) · \(meta.id)"
                parts.append(body.isEmpty ? header : "\(header)\n\n\(body)")
            }
            let text = parts.joined(separator: "\n\n════════════════════════\n\n")
            await MainActor.run {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                self.showToast(metas.count == 1
                               ? "Session copied" : "Sessions copied: \(metas.count)")
            }
        }
    }

    /// Prompt for a cutoff date, then copy the given sessions keeping only blocks
    /// at or newer than it. Cancel aborts the copy.
    func copySessionsSincePrompt(_ ids: Set<String>) {
        guard !ids.isEmpty, let since = Self.askCutoffDate() else { return }
        copySessionsToClipboard(ids, since: since)
    }

    /// ⌘C target with a date prompt: act on the list selection.
    func copySelectedSessionsSince() { copySessionsSincePrompt(copyTargetIDs) }

    /// Modal date picker (NSAlert + NSDatePicker). Returns nil on Cancel.
    /// Defaults to the start of today.
    private static func askCutoffDate() -> Date? {
        let alert = NSAlert()
        alert.messageText = "Copy blocks since…"
        alert.informativeText = "Only replies at or newer than this date will be copied."
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Cancel")

        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinute]
        picker.dateValue = Calendar.current.startOfDay(for: Date())
        alert.accessoryView = picker

        return alert.runModal() == .alertFirstButtonReturn ? picker.dateValue : nil
    }

    // MARK: - Favorites

    func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        UserDefaults.standard.set(Array(favorites), forKey: favKey)
    }

    func isFavorite(_ id: String) -> Bool { favorites.contains(id) }

    // MARK: - Hide / unhide

    func hideSession(_ id: String) {
        guard !hidden.contains(id) else { return }
        hidden.insert(id)
        hiddenUndo.append(id)
        UserDefaults.standard.set(Array(hidden), forKey: hiddenKey)
        // Move selection off the now-hidden session.
        if selectedID == id { selectedID = filteredHits.first?.meta.id }
        recomputeHits(instant: true)
    }

    /// Ctrl+Z — restore the most recently hidden session.
    func unhideLast() {
        guard let id = hiddenUndo.popLast() else { return }
        hidden.remove(id)
        UserDefaults.standard.set(Array(hidden), forKey: hiddenKey)
        recomputeHits(instant: true)
        selectedID = id
        showToast("Session restored")
    }

    /// Un-hide a specific session (from the Hidden list). Drops it from the undo
    /// stack too so a later Ctrl+Z doesn't try to restore an already-visible row.
    func unhideSession(_ id: String) {
        guard hidden.contains(id) else { return }
        hidden.remove(id)
        hiddenUndo.removeAll { $0 == id }
        UserDefaults.standard.set(Array(hidden), forKey: hiddenKey)
        // Leaving the Hidden scope empty would show a blank list — fall back to All.
        if hidden.isEmpty && scope == .hidden { scope = .all }
        recomputeHits(instant: true)
        if !(filteredHits.contains { $0.meta.id == selectedID }) {
            selectedID = filteredHits.first?.meta.id
        }
        showToast("Session restored")
    }

    func isHidden(_ id: String) -> Bool { hidden.contains(id) }

    // MARK: - "Needs attention" marker

    /// Show the marker only if the heuristic fires AND it wasn't dismissed.
    func needsAttention(_ meta: SessionMeta) -> Bool {
        meta.needsAttention && !dismissedAttention.contains(meta.id)
    }

    func dismissAttention(_ id: String) {
        dismissedAttention.insert(id)
        UserDefaults.standard.set(Array(dismissedAttention), forKey: dismissedKey)
    }

    func restoreAttention(_ id: String) {
        dismissedAttention.remove(id)
        UserDefaults.standard.set(Array(dismissedAttention), forKey: dismissedKey)
    }

    // MARK: - Actions

    @Published var toast: String?
    private var toastTask: Task<Void, Never>?

    private func showToast(_ msg: String) {
        toast = msg
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            self.toast = nil
        }
    }

    func openInTerminal() {
        guard let meta = selectedMeta else { return }
        let title = AutoTitle.displayTitle(meta)
        Task.detached {
            let r = OpenSession.openInTerminal(meta, displayTitle: title)
            await MainActor.run { self.showToast(r.message) }
        }
    }

    func copyResume() {
        guard let meta = selectedMeta else { return }
        showToast(OpenSession.copyResumeCommand(meta).message)
    }

    func revealInFinder() {
        guard let meta = selectedMeta else { return }
        OpenSession.revealInFinder(meta)
    }

    /// Path to the scanned projects directory (~/.claude/projects), for Settings.
    var projectsDirPath: String { Loader.projectsDir.path }
    /// On-disk metadata cache location, for Settings.
    var cacheStorePath: String { Store.storeURL.path }

    /// Drop the persistent metadata cache and re-parse every session from jsonl.
    func resetCache() {
        store.deleteAllCached()
        allSessions = []
        loading = true
        recomputeHits(instant: true)
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.sync(initial: true)
        }
        showToast("Cache reset — recomputing metadata")
    }
}

import SwiftUI

struct SessionListView: View {
    @EnvironmentObject var model: AppModel

    private var isSearching: Bool { !model.query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// A flat, newest-first list (no date sections). When fork-grouping is on, a
    /// fork is nested directly under its parent regardless of date: each group is
    /// ordered by the NEWEST date among parent and forks, then rendered
    /// parent-then-forks. Nesting is recursive (a fork of a fork sits one level
    /// deeper). `forkDepth` maps each nested row to its indent level (1, 2, …).
    private var ordered: (hits: [SearchHit], forkDepth: [String: Int]) {
        guard model.groupForks else { return (model.hits, [:]) }

        let present = Set(model.hits.map { $0.meta.id })
        // Parent→children forest. A fork whose parent isn't present is a root.
        var childrenOf: [String: [SearchHit]] = [:]
        var roots: [SearchHit] = []
        for hit in model.hits {
            if let p = hit.meta.parentSessionId, present.contains(p) {
                childrenOf[p, default: []].append(hit)
            } else {
                roots.append(hit)
            }
        }

        // Newest date reachable in a root's group (root + all descendants).
        func groupNewest(_ hit: SearchHit) -> Date {
            var best = hit.meta.mtime
            for c in childrenOf[hit.meta.id] ?? [] { best = max(best, groupNewest(c)) }
            return best
        }
        var forkDepth: [String: Int] = [:]
        var out: [SearchHit] = []
        func emit(_ hit: SearchHit, depth: Int) {
            out.append(hit)
            if depth > 0 { forkDepth[hit.meta.id] = depth }
            for c in childrenOf[hit.meta.id] ?? [] { emit(c, depth: depth + 1) }
        }
        // Order groups by their newest date (desc); a parent pulled forward by a
        // fresh fork sorts with it.
        for (root, _) in roots.map({ (root: $0, newest: groupNewest($0)) })
            .sorted(by: { $0.newest > $1.newest }) {
            emit(root, depth: 0)
        }
        return (out, forkDepth)
    }

    var body: some View {
        Group {
            if model.loading {
                VStack(spacing: 10) {
                    ClaudeBurstView()
                        .frame(width: 110, height: 110)
                    Text("Scanning sessions…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(
                    get: { model.listSelection },
                    set: { model.updateListSelection($0) }
                )) {
                    if isSearching {
                        Section {
                            ForEach(model.hits) { hit in
                                SearchResultRow(hit: hit, tokens: model.searchTokens)
                                    .tag(hit.meta.id)
                            }
                        } header: {
                            HStack {
                                Text("\(model.hits.count) matches")
                                Spacer()
                                Text("«\(model.query)»").foregroundStyle(.tertiary)
                            }
                        }
                    } else {
                        let list = ordered
                        ForEach(list.hits) { hit in
                            SessionRow(meta: hit.meta,
                                       isFavorite: model.isFavorite(hit.meta.id),
                                       needsAttention: model.needsAttention(hit.meta),
                                       forkDepth: list.forkDepth[hit.meta.id] ?? 0)
                                .tag(hit.meta.id)
                        }
                    }
                }
                .listStyle(.inset)
                // Tell the model when the user is actively scrolling so live list
                // reorders wait for idle (no rows jumping under the cursor).
                .onScrollPhaseChange { _, phase in
                    model.listIsScrolling = (phase == .interacting || phase == .decelerating
                                             || phase == .animating)
                }
                // One native, lazy context menu for the selected row(s) — far
                // cheaper than attaching .contextMenu to every row (which made
                // scrolling janky on long lists).
                .contextMenu(forSelectionType: String.self) { ids in
                    if ids.count > 1 {
                        Button("Copy \(ids.count) Sessions with Content") {
                            model.copySessionsToClipboard(ids)
                        }
                        Button("Copy \(ids.count) Sessions since…") {
                            model.copySessionsSincePrompt(ids)
                        }
                        if ids.allSatisfy(model.isHidden) {
                            Button("Unhide \(ids.count) Sessions") {
                                ids.forEach(model.unhideSession)
                            }
                        }
                    } else if let id = ids.first,
                              let meta = model.allSessions.first(where: { $0.id == id }) {
                        rowMenu(meta)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ meta: SessionMeta) -> some View {
        Button(model.isFavorite(meta.id) ? "Remove from Favorites" : "Add to Favorites") {
            model.toggleFavorite(meta.id)
        }
        if meta.needsAttention {
            if model.needsAttention(meta) {
                Button("Clear “Needs Reply” mark") { model.dismissAttention(meta.id) }
            } else {
                Button("Restore “Needs Reply” mark") { model.restoreAttention(meta.id) }
            }
        }
        Divider()
        Button("Copy Session with Content") { model.copySessionsToClipboard([meta.id]) }
        Button("Copy Session since…") { model.copySessionsSincePrompt([meta.id]) }
        if model.isHidden(meta.id) {
            Button("Unhide Session") { model.unhideSession(meta.id) }
        } else {
            Button("Hide Session") { model.hideSession(meta.id) }
        }
        Button("Open in Terminal") { model.selectedID = meta.id; model.openInTerminal() }
        Button("Reveal in Finder") { model.selectedID = meta.id; model.revealInFinder() }
    }
}

struct SessionRow: View {
    let meta: SessionMeta
    let isFavorite: Bool
    var needsAttention: Bool = false
    /// Nesting level under the parent session (0 = a root, 1 = a fork, 2 = a fork
    /// of a fork, …). Forks render indented by depth + italic.
    var forkDepth: Int = 0
    private var isFork: Bool { forkDepth > 0 }

    @Environment(\.uiScale) private var scale
    @Environment(\.s) private var s

    // Computed ONCE per row build (not per hover): these were re-running
    // displayTitle (a locked memo) + date/byte formatting on every hover event,
    // which — combined with an animated transition — made scroll-hover janky.
    private var title: String { AutoTitle.displayTitle(meta) }
    private var project: String { meta.projectLabel }
    private var snippet: String { meta.lastUserText }
    private var time: String { Format.mailTime(meta.mtime) }

    var body: some View {
        // Mail-style row: a left dot column (vertically centred), then a content
        // column — bold title + time on top, muted project, muted snippet below.
        HStack(alignment: .top, spacing: s(8)) {
            Circle()
                .fill(needsAttention ? Theme.accent : Color.clear)
                .frame(width: s(8), height: s(8))
                .padding(.top, s(5))
            VStack(alignment: .leading, spacing: s(2)) {
                HStack(alignment: .firstTextBaseline, spacing: s(6)) {
                    if isFork {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 11 * scale))
                            .foregroundStyle(Theme.accent.opacity(0.7))
                    }
                    Text(title)
                        .font(.system(size: 14 * scale, weight: .bold))
                        .italic(isFork)
                        .lineLimit(1)
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9 * scale))
                            .foregroundStyle(Color(hex: 0xFEBC2E))
                    }
                    Spacer(minLength: 4)
                    Text(time)
                        .font(.system(size: 11.5 * scale))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize()
                }
                Text(project)
                    .font(.system(size: 12.5 * scale))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                Text(snippet)
                    .font(.system(size: 12.5 * scale))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, s(4))
        .padding(.leading, s(18) * CGFloat(forkDepth))
    }
}

/// A 4-segment bar gauge (like a signal-strength meter) giving a glanceable
/// sense of a session's size. Bar heights mirror the design mock.
struct SizeBars: View {
    /// How many of the 4 bars are filled (1…4).
    let level: Int
    var filled: Color = .secondary
    var empty: Color = Color(nsColor: .quaternaryLabelColor)

    @Environment(\.s) private var s

    private static let heights: [CGFloat] = [4, 6, 8, 9]

    /// Coarse size buckets: <128 KB, <1 MB, <8 MB, else.
    static func level(forBytes bytes: Int) -> Int {
        switch bytes {
        case ..<131_072: return 1
        case ..<1_048_576: return 2
        case ..<8_388_608: return 3
        default: return 4
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: s(1.5)) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: s(1))
                    .fill(i < level ? filled : empty)
                    .frame(width: s(2.5), height: s(Self.heights[i]))
            }
        }
        .frame(height: s(9))
    }
}

struct SearchResultRow: View {
    let hit: SearchHit
    let tokens: [String]
    @Environment(\.uiScale) private var scale
    @Environment(\.s) private var s

    var body: some View {
        VStack(alignment: .leading, spacing: s(5)) {
            Text(highlighted)
                .font(.system(size: 12.5 * scale)).lineLimit(2)
            HStack(spacing: s(6)) {
                RoundedRectangle(cornerRadius: s(2))
                    .fill(Theme.dotColor(for: hit.meta.projectPath)).frame(width: s(7), height: s(7))
                Text("\(hit.meta.projectLabel) · \(AutoTitle.displayTitle(hit.meta))")
                    .font(.system(size: 11.5 * scale)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Text(Format.relativeTime(hit.meta.mtime))
                    .font(.system(size: 11 * scale)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, s(3))
    }

    private var snippetText: String { hit.snippet ?? hit.meta.lastUserText }

    private var highlighted: AttributedString {
        var attr = AttributedString(snippetText)
        let lower = snippetText.lowercased()
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
        return attr
    }
}

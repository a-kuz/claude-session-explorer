import SwiftUI
import AppKit

struct DetailView: View {
    @EnvironmentObject var model: AppModel
    /// The block currently scrolled to the top — driven by the native
    /// `.scrollPosition` API (no per-block GeometryReader, which caused the
    /// preference storm that made scroll + panel resize stutter).
    @State private var topBlockID: String?
    @FocusState private var transcriptFocused: Bool
    @Environment(\.s) private var s

    /// Jumps within this many blocks of the current top animate (a smooth glide);
    /// farther jumps land instantly and exactly (a page-flip), avoiding the
    /// stuttering "two-stage" animated scroll across many rows.
    private let nearJumpBlocks = 10

    var body: some View {
        if let meta = model.selectedMeta {
            conversation(meta)
                .id(meta.id)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .scaledFont(40).foregroundStyle(Theme.tertiaryText)
                Text("Select a session").foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.cardBg)
        }
    }


    // MARK: - Conversation

    private func conversation(_ meta: SessionMeta) -> some View {
        // A `List` (NSTableView-backed on macOS) — NOT ScrollView+LazyVStack —
        // because only `List` keeps a precise row geometry that lets `scrollTo`
        // land exactly on a far, not-yet-rendered block. With LazyVStack the list
        // has no real height for unmeasured rows, so a far `scrollTo` lands on an
        // estimate and overshoots/bounces (Apple-confirmed: developer.apple.com
        // forums/thread/685461; fatbobman "List or LazyVStack"). Each block is its
        // OWN row (the scroll anchor); `.scrollPosition` reads the top row for the
        // outline highlight.
        ScrollViewReader { proxy in
            List {
                SessionHeader(meta: meta)
                    .frame(maxWidth: model.sidebarCollapsed ? 820 : .infinity, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .conversationRow()

                if model.dialog != nil {
                    ConversationRows(
                        blocks: model.blocks,
                        tokens: model.searchTokens,
                        focusedID: model.scrollTarget,
                        air: model.air,
                        showBranchBars: model.branchMode != .activeOnly,
                        sidebarCollapsed: model.sidebarCollapsed,
                        dialogImages: model.dialogImages,
                        fontTick: model.fontTick
                    )
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity).padding(.top, 40)
                        .conversationRow()
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 0)
            .scrollContentBackground(.hidden)
            .background(Theme.cardBg)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollPosition(id: $topBlockID, anchor: .top)
            .textSelection(.enabled)
            .onChange(of: model.scrollNonce) { _, _ in
                guard let t = model.scrollTarget else { return }
                // Near vs. far on block-index distance: a near jump animates (a
                // genuine glide of a handful of rows); a far one jumps instantly
                // and exactly — animating across hundreds of rows is what makes
                // List materialise everything in between and stutter "in two
                // stages". Far instant = a clean page-flip, no in-between churn.
                let from = model.blockIndex(of: topBlockID)
                let to = model.blockIndex(of: t)
                let distance = (from != nil && to != nil) ? abs(to! - from!) : Int.max
                let near = !model.scrollInstant && distance <= nearJumpBlocks

                if near {
                    withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(t, anchor: .top) }
                } else {
                    proxy.scrollTo(t, anchor: .top)
                }
                // List lands precisely, so there is no convergence loop to settle;
                // release the guard on the next runloop once the position applied.
                DispatchQueue.main.async {
                    model.jumpInFlight = false
                    model.scrollInstant = false
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($transcriptFocused)
        .onChange(of: topBlockID) { _, id in
            if let id { model.syncTurnIndex(toTopMostID: id) }
        }
        .onChange(of: model.focusTranscriptRequested) { _, req in
            if req { transcriptFocused = true; model.focusTranscriptRequested = false }
        }
        .onChange(of: transcriptFocused) { _, f in model.transcriptHasFocus = f }
        // ⌘-scroll zooms the conversation text.
        .background(CommandScrollZoom { delta in model.zoom(delta > 0 ? 0.05 : -0.05) })
    }
}

/// Mail-style message header: the session title set large, with a secondary line
/// of project + date beneath. It's the first element of the scroll content, so it
/// slides up under the translucent toolbar as the conversation scrolls — exactly
/// like the subject header in Mail.
private struct SessionHeader: View {
    let meta: SessionMeta
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(AutoTitle.displayTitle(meta))
                .font(.system(size: 19 * model.fontScale, weight: .semibold))
                .lineLimit(2).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Text(meta.projectLabel)
                Text("·")
                Text(Format.mailTime(meta.mtime))
            }
            .font(.system(size: 12 * model.fontScale))
            .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, model.sidebarCollapsed ? 40 : 30)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
        }
    }
}

/// The conversation's blocks, emitted as individual `List` rows. Each block is its
/// OWN row carrying `.id(block.id)` — the scroll anchor `scrollTo` lands on, and the
/// id `.scrollPosition` reports as the top row. Being real List rows (NSTableView
/// rows on macOS) is exactly what makes `scrollTo` land precisely on far blocks: the
/// list knows real row geometry rather than estimating unmeasured heights.
///
/// `@ViewBuilder` returning rows (not a wrapper View) so List sees each block as a
/// distinct row. Per-block re-render is naturally pruned: List only builds visible
/// rows, and `BlockView` diffs cheaply on its value inputs.
private struct ConversationRows: View {
    let blocks: [DialogBlock]
    let tokens: [String]
    let focusedID: String?
    let air: CGFloat
    let showBranchBars: Bool
    let sidebarCollapsed: Bool
    let dialogImages: [NSImage]
    /// Changes when the conversation font changes, forcing a re-render (the font
    /// lives in a global the views don't otherwise diff against).
    let fontTick: Int

    @Environment(\.s) private var s

    /// Map a block's turns to their slices of the session-wide image array.
    private func imagesForBlock(_ block: DialogBlock) -> [String: [NSImage]] {
        var out: [String: [NSImage]] = [:]
        for turn in block.turns where turn.imageCount > 0 && turn.imageStartIndex >= 0 {
            let start = turn.imageStartIndex
            let end = min(start + turn.imageCount, dialogImages.count)
            if start < end { out[turn.id] = Array(dialogImages[start..<end]) }
        }
        return out
    }

    var body: some View {
        let lastIdx = blocks.count - 1
        ForEach(blocks.indices, id: \.self) { idx in
            let block = blocks[idx]
            VStack(alignment: .leading, spacing: 0) {
                if showBranchBars {
                    BranchBar(firstMessageID: block.id)
                }
                BlockView(block: block,
                          tokens: tokens,
                          focusedID: focusedID,
                          air: air,
                          images: imagesForBlock(block),
                          nextPrompt: idx < lastIdx ? blocks[idx + 1].promptTurn?.bodyText : nil)
                if idx < lastIdx {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 0.5)
                        .padding(.horizontal, sidebarCollapsed ? -40 : -30)
                        .padding(.top, s(air))
                }
            }
            .padding(.horizontal, sidebarCollapsed ? 40 : 30)
            .padding(.top, idx == 0 ? s(22) : s(air))
            .padding(.bottom, idx == lastIdx ? s(22) : 0)
            .frame(maxWidth: sidebarCollapsed ? 820 : .infinity, alignment: .leading)
            .frame(maxWidth: .infinity)
            .id(block.id)
            .conversationRow()
        }
    }
}

/// Strips the stock `List` row chrome (separators, insets, selection/hover tint,
/// background) so a row renders as plain conversation content — the look the old
/// ScrollView had — while keeping List's precise row geometry for `scrollTo`.
private extension View {
    func conversationRow() -> some View {
        self
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }
}

import SwiftUI
import AppKit

struct DetailView: View {
    @EnvironmentObject var model: AppModel
    /// The block currently scrolled to the top — driven by the native
    /// `.scrollPosition` API (no per-block GeometryReader, which caused the
    /// preference storm that made scroll + panel resize stutter).
    @State private var topBlockID: String?
    /// Bumped per programmatic jump so a superseded jump's delayed guard-clear
    /// (see scrollNonce handler) knows it's stale and does nothing.
    @State private var jumpToken = 0
    @FocusState private var transcriptFocused: Bool
    @Environment(\.s) private var s

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
            .background(Color.white)
        }
    }


    // MARK: - Conversation

    private func conversation(_ meta: SessionMeta) -> some View {
        // ScrollViewReader drives jumps via `proxy.scrollTo(id)`, which forces
        // SwiftUI to materialise and land exactly on the target block — unlike
        // `.scrollPosition(id:)` writes, which on a lazy variable-height list
        // estimate the offset and undershoot ever more the farther the jump.
        // `.scrollPosition` stays only as a READER of the top block (for the
        // outline highlight), where its estimation error doesn't matter.
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SessionHeader(meta: meta)
                        .frame(maxWidth: model.sidebarCollapsed ? 820 : .infinity, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    if model.dialog != nil {
                        ConversationList(
                            blocks: model.blocks,
                            tokens: model.searchTokens,
                            focusedID: model.scrollTarget,
                            air: model.air,
                            showBranchBars: model.branchMode != .activeOnly,
                            sidebarCollapsed: model.sidebarCollapsed,
                            dialogImages: model.dialogImages,
                            fontTick: model.fontTick
                        )
                        .equatable()
                        .scrollTargetLayout()
                        .padding(.horizontal, model.sidebarCollapsed ? 40 : 30)
                        .padding(.vertical, s(22))
                        .frame(maxWidth: model.sidebarCollapsed ? 820 : .infinity, alignment: .leading)
                        .frame(maxWidth: .infinity)
                        .textSelection(.enabled)
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollPosition(id: $topBlockID, anchor: .top)
            .onChange(of: model.scrollNonce) { _, _ in
                guard let t = model.scrollTarget else { return }
                jumpToken &+= 1
                let token = jumpToken
                func land() {
                    // scrollTo on a lazy list can undershoot when the target is
                    // far off-screen and not yet measured. Re-issue once on the
                    // next runloop so the now-materialised neighbours let it land
                    // exactly. Guard by token so a newer jump cancels this.
                    DispatchQueue.main.async {
                        guard token == jumpToken else { return }
                        proxy.scrollTo(t, anchor: .top)
                        model.jumpInFlight = false
                    }
                }
                if model.scrollInstant {
                    proxy.scrollTo(t, anchor: .top)
                    land()
                } else {
                    withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(t, anchor: .top) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                        guard token == jumpToken else { return }
                        proxy.scrollTo(t, anchor: .top)
                        model.jumpInFlight = false
                    }
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

/// The conversation's block list, isolated as an `Equatable` view so SwiftUI can
/// prune it from re-render when its inputs are unchanged — keeping per-frame
/// scroll updates in the parent from rebuilding the whole LazyVStack on huge
/// sessions. Inputs are plain values (no `@EnvironmentObject`) precisely so the
/// equality check is the only thing that decides a rebuild.
private struct ConversationList: View, Equatable {
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

    static func == (l: ConversationList, r: ConversationList) -> Bool {
        // `dialogImages` compared by count: slices are positional, so a count
        // change is the only way a turn's images change identity here.
        l.blocks == r.blocks && l.tokens == r.tokens && l.focusedID == r.focusedID
            && l.air == r.air && l.showBranchBars == r.showBranchBars
            && l.sidebarCollapsed == r.sidebarCollapsed
            && l.dialogImages.count == r.dialogImages.count
            && l.fontTick == r.fontTick
    }

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
        LazyVStack(alignment: .leading, spacing: 0) {
            let lastIdx = blocks.count - 1
            ForEach(blocks.indices, id: \.self) { idx in
                let block = blocks[idx]
                // One scroll target per block: the branch bar, the block, and the
                // trailing separator are wrapped in a SINGLE id'd container. With
                // the separator as its own un-id'd sibling, `.scrollPosition` put
                // the anchor on the wrong element and every jump undershot by one
                // block — keep the LazyVStack's direct children = blocks only.
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
                            .padding(.vertical, s(air))
                    }
                }
                .id(block.id)
            }
        }
    }
}

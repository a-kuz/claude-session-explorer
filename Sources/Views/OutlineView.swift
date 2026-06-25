import SwiftUI
import AppKit

/// Table of contents: the user's prompts, in order, with the time each was sent.
/// Clicking jumps the conversation to that turn.
struct OutlineView: View {
    @EnvironmentObject var model: AppModel
    /// Set when a row is clicked here — it's already visible, so the
    /// active-row auto-centering should NOT fire (that caused the jump).
    @State private var suppressAutoScroll = false
    /// Multi-selected block ids (for copying prompt+answer text). ⌘-click toggles,
    /// ⇧-click selects a range, plain click jumps and selects just that block.
    @State private var selection: Set<String> = []
    @State private var anchorID: String?
    @Environment(\.s) private var s

    private var orderedIDs: [String] { model.outlineTurns.map(\.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.outlineTurns.enumerated()), id: \.element.id) { idx, turn in
                        row(idx: idx, turn: turn)
                    }
                }
                .padding(.vertical, s(6))
            }
            .onChange(of: model.turnIndex) { _, idx in
                if suppressAutoScroll { suppressAutoScroll = false; return }
                let ids = model.userTurnIDs
                guard ids.indices.contains(idx) else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(ids[idx], anchor: .center)
                }
            }
            }

            // Selection footer: shows how many blocks are picked and a Copy button.
            if selection.count > 1 {
                Divider()
                HStack(spacing: 8) {
                    Text("Выбрано: \(selection.count)")
                        .scaledFont(11).foregroundStyle(.secondary)
                    Spacer()
                    Button { selection = [] } label: { Text("Сброс").scaledFont(11) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    Button { model.copyBlocksToClipboard(selection) } label: {
                        Label("Копировать", systemImage: "doc.on.doc").scaledFont(11)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .background(.regularMaterial)
        // ⌘C copies the current selection (or the active block if none).
        .onCopyCommand {
            let text = copyTSV()
            return text.isEmpty ? [] : [NSItemProvider(object: text as NSString)]
        }
    }

    @ViewBuilder
    private func row(idx: Int, turn: DialogTurn) -> some View {
        let active = idx == model.turnIndex
        let picked = selection.contains(turn.id)
        HStack(alignment: .top, spacing: s(9)) {
            Text("\(idx + 1)")
                .scaledFont(11, weight: active ? .bold : .medium, design: .monospaced)
                .foregroundStyle(active ? Theme.accent : Theme.tertiaryText)
                .frame(minWidth: s(18), alignment: .trailing)
            VStack(alignment: .leading, spacing: s(2)) {
                Text(turn.outlineTitle)
                    .scaledFont(12.5, weight: active ? .semibold : .regular)
                    .foregroundStyle(active ? Theme.accent : Color.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let ts = turn.timestamp {
                    Text(Format.timeOrDate(ts))
                        .scaledFont(10.5)
                        .foregroundStyle(active ? Theme.accent.opacity(0.7) : Theme.tertiaryText)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, s(11)).padding(.vertical, s(6))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .leading) {
            if picked {
                Theme.accent.opacity(0.18)
            } else if active {
                LinearGradient(colors: [Theme.accent.opacity(0.10), Theme.accent.opacity(0)],
                               startPoint: .leading, endPoint: .trailing)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: s(3)) }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { handleClick(turn.id) }
        .padding(.vertical, s(1))
        .id(turn.id)
        .contextMenu {
            Button("Копировать этот блок") { model.copyBlocksToClipboard([turn.id]) }
            if selection.count > 1 {
                Button("Копировать выбранные (\(selection.count))") {
                    model.copyBlocksToClipboard(selection)
                }
            }
        }
    }

    /// Click semantics: plain = jump + single-select; ⌘ = toggle; ⇧ = range.
    private func handleClick(_ id: String) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchorID = id
        } else if mods.contains(.shift), let a = anchorID,
                  let lo = orderedIDs.firstIndex(of: a), let hi = orderedIDs.firstIndex(of: id) {
            selection.formUnion(orderedIDs[min(lo, hi)...max(lo, hi)])
        } else {
            selection = [id]
            anchorID = id
            suppressAutoScroll = true
            model.jumpToTurn(id)
        }
    }

    private func copyTSV() -> String {
        let ids = selection.isEmpty ? Set(model.outlineTurns.indices.contains(model.turnIndex)
                                          ? [model.outlineTurns[model.turnIndex].id] : [])
                                    : selection
        return model.copyText(forBlockIDs: ids)
    }
}

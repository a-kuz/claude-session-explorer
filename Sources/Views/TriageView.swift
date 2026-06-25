import SwiftUI

/// "Reply to all in turn" — a dedicated full-window screen that walks the
/// sessions waiting on a reply one at a time. The composer is presentational for
/// now (sending replies into Claude Code is a later step); the navigation,
/// queue, and "no reply needed" resolution are live.
struct TriageView: View {
    @EnvironmentObject var model: AppModel
    @State private var draft = ""

    private var queue: [SessionMeta] { model.attentionSessions }
    private var current: SessionMeta? { model.triageCurrent }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            queueStrip
            Divider()
            if current != nil {
                ScrollView { centerColumn }
            } else {
                emptyState
            }
        }
        .background(Color(hex: 0xF5F6F9))
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 13)).foregroundStyle(Theme.accent)
            Text("Reply to all in turn")
                .font(.system(size: 14, weight: .semibold))
            let done = model.triageIndex
            Text("\(min(done + 1, queue.count)) / \(queue.count)")
                .font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(Theme.tertiaryText)
            Spacer()
            Button("Exit") { model.exitTriage() }
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
                .padding(.horizontal, 12).frame(height: 28)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(.horizontal, 18).frame(height: 52)
        .background(.regularMaterial)
    }

    // MARK: - Queue strip

    private var queueStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("Queue")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                    .padding(.trailing, 2)
                ForEach(Array(queue.enumerated()), id: \.element.id) { idx, meta in
                    chip(for: meta, idx: idx)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
        }
        .frame(height: 46)
        .background(Color.white.opacity(0.5))
    }

    @ViewBuilder
    private func chip(for meta: SessionMeta, idx: Int) -> some View {
        let isCurrent = idx == model.triageIndex
        let isDone = idx < model.triageIndex
        Text(AutoTitle.displayTitle(meta))
            .font(.system(size: 11.5, weight: isCurrent ? .semibold : .regular))
            .lineLimit(1).frame(maxWidth: 180)
            .strikethrough(isDone)
            .foregroundStyle(isCurrent ? .white : (isDone ? Theme.secondaryText : Color(hex: 0x3A3A3C)))
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background {
                if isCurrent {
                    Capsule().fill(Theme.accent)
                } else if isDone {
                    Capsule().fill(Color.primary.opacity(0.05))
                } else {
                    Capsule().fill(Color.white)
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                }
            }
            .contentShape(Capsule())
            .onTapGesture { model.triageIndex = idx; model.selectedID = meta.id }
    }

    // MARK: - Center column

    @ViewBuilder
    private var centerColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let meta = current {
                // Session heading.
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.dotColor(for: meta.projectPath)).frame(width: 8, height: 8)
                    Text(AutoTitle.displayTitle(meta))
                        .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text("\(meta.projectLabel) · \(Format.relativeTime(meta.mtime))")
                        .font(.system(size: 12)).foregroundStyle(Theme.tertiaryText)
                }
                .padding(.bottom, 14)

                // Your last line.
                Text("You: \(meta.lastUserText)")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color(hex: 0xD8D8DC)).frame(width: 2)
                    }
                    .padding(.bottom, 14)

                // Claude's last message card.
                claudeCard(meta)

                hintsSection
                composer
                shortcutsRow
            }
        }
        .frame(maxWidth: 820, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24).padding(.vertical, 26)
    }

    private func claudeCard(_ meta: SessionMeta) -> some View {
        // The last thing Claude said is what the user is reacting to. We surface
        // the cached last-user text's counterpart lazily; for now show the title-
        // derived summary as a readable card (full transcript stays in the main
        // viewer). Tapping the card opens the session in the normal view.
        VStack(alignment: .leading, spacing: 12) {
            Text(triageClaudeText(meta))
                .font(.system(size: 14.5))
                .lineSpacing(4)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
        .padding(.bottom, 18)
    }

    /// Best available text of Claude's last turn for the open session; falls back
    /// to a neutral prompt when the dialog isn't the loaded one.
    private func triageClaudeText(_ meta: SessionMeta) -> String {
        if model.selectedID == meta.id,
           let last = model.turns.last(where: { $0.role == .assistant }) {
            let t = last.bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return String(t.prefix(600)) }
        }
        return "Claude is waiting for your reply in this session. Open it in the main window to see the full context."
    }

    // MARK: - Hints

    private var hintsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12)).foregroundStyle(Theme.accent)
                Text("SUGGESTIONS")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
            }
            FlowLayout(spacing: 8) {
                ForEach(staticHints, id: \.self) { hint in
                    Text(hint)
                        .font(.system(size: 13))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                        .onTapGesture { draft = hint }
                }
            }
        }
        .padding(.bottom, 14)
    }

    private let staticHints = ["Yes, continue", "Show what's left", "Stop and explain"]

    // MARK: - Composer (presentational until sending is wired up)

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Your reply…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...6)
            HStack(spacing: 10) {
                Button { model.triageResolve() } label: {
                    Label("No reply needed", systemImage: "checkmark")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 13).frame(height: 32)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .help("Clear the flag and move to the next one (⌥X)")

                Spacer()
                Text("⌘↵").font(.system(size: 11)).foregroundStyle(Color(hex: 0xB0B0B5))
                Button { model.triageAdvance() } label: {
                    Label("Reply and continue", systemImage: "arrow.right")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 15).frame(height: 32)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
                .help("Sending comes later; for now — move on (⌘↵)")
            }
        }
        .padding(14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent, lineWidth: 2))
        .padding(.bottom, 14)
    }

    // MARK: - Shortcuts

    private var shortcutsRow: some View {
        HStack(spacing: 18) {
            shortcut("⌘↵", "reply and continue")
            shortcut("⌥X", "no reply needed")
            shortcut("⌥→", "skip")
            shortcut("1–3", "suggestion")
        }
        .frame(maxWidth: .infinity)
    }

    private func shortcut(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color(hex: 0x6B7280))
            Text(label).font(.system(size: 11.5)).foregroundStyle(Theme.tertiaryText)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40)).foregroundStyle(Theme.tertiaryText)
            Text("All replies done").foregroundStyle(Theme.secondaryText)
            Button("Exit") { model.exitTriage() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

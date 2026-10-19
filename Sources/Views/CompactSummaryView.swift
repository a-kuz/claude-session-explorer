import SwiftUI

/// A context-compaction summary: a collapsed divider row that expands into the
/// summary text (the CLI shows the same record as "Summarized conversation").
struct CompactSummaryView: View {
    let turn: DialogTurn
    let tokens: [String]
    @State private var isExpanded = false
    @Environment(\.uiScale) private var scale
    @Environment(\.s) private var s

    var body: some View {
        VStack(alignment: .leading, spacing: s(10)) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: s(8)) {
                    Rectangle().fill(Theme.rule).frame(height: 1)
                    HStack(spacing: s(5)) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9 * scale, weight: .semibold))
                        Image(systemName: "rectangle.compress.vertical")
                            .font(.system(size: 10.5 * scale))
                        Text("Context compacted")
                            .font(.system(size: 11.5 * scale, weight: .medium))
                        if let ts = turn.timestamp {
                            Text(Format.timeOrDate(ts))
                                .font(.system(size: 11 * scale))
                                .foregroundStyle(Theme.tertiaryText)
                        }
                    }
                    .foregroundStyle(Color.secondary)
                    .fixedSize()
                    Rectangle().fill(Theme.rule).frame(height: 1)
                }
                .padding(.vertical, s(4))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .textSelection(.disabled)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                VStack(alignment: .leading, spacing: s(10)) {
                    ForEach(turn.blocks) { block in
                        MarkdownBlockView(block: block, tokens: tokens)
                    }
                }
                .padding(.leading, s(14))
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.rule).frame(width: s(2.5))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

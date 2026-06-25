import SwiftUI

/// A simple wrapping HStack: lays children left-to-right, wrapping to new rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 7
    var lineSpacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = layout(subviews, maxWidth: maxWidth)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        var widest: CGFloat = 0
        for row in rows {
            var rowWidth: CGFloat = 0
            for item in row.items { rowWidth += item.size.width + spacing }
            widest = max(widest, rowWidth)
        }
        return CGSize(width: min(widest, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = layout(subviews, maxWidth: bounds.width)
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
        }
    }

    private struct Item { let index: Int; let size: CGSize }
    private struct Row { var items: [Item] = []; var y: CGFloat = 0; var height: CGFloat = 0 }

    private func layout(_ subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0
        var y: CGFloat = 0
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, !current.items.isEmpty {
                current.y = y
                rows.append(current)
                y += current.height + lineSpacing
                current = Row()
                x = 0
            }
            current.items.append(Item(index: i, size: size))
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }
        if !current.items.isEmpty { current.y = y; rows.append(current) }
        return rows
    }
}

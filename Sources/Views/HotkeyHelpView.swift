import SwiftUI

/// Keyboard shortcut cheat sheet (⌘⇧/). Mirrors what's wired in the menu bar so
/// there's a single, layout-independent reference — every action here is a real
/// ⌘-shortcut that works regardless of keyboard layout or focus.
struct HotkeyHelpView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private struct Item: Identifiable { let id = UUID(); let keys: String; let label: String }
    private struct Group: Identifiable { let id = UUID(); let title: String; let items: [Item] }

    private let groups: [Group] = [
        Group(title: "Navigation", items: [
            Item(keys: "⌘↓ / ⌘↑", label: "Next / previous session"),
            Item(keys: "⌘] / ⌘[", label: "Next / previous turn"),
            Item(keys: "⌘G / ⌘⇧G", label: "Next / previous match"),
        ]),
        Group(title: "Search", items: [
            Item(keys: "⌘F", label: "Find"),
            Item(keys: "Esc", label: "Clear search"),
        ]),
        Group(title: "View", items: [
            Item(keys: "⌘B", label: "Sidebar"),
            Item(keys: "⌘⇧B", label: "Outline"),
            Item(keys: "⌘E", label: "Brief / full"),
            Item(keys: "⌘+ / ⌘−", label: "Text zoom"),
            Item(keys: "⌘0", label: "Reset zoom"),
            Item(keys: "⌘⇧= / ⌘⇧−", label: "More / less spacing"),
        ]),
        Group(title: "Session", items: [
            Item(keys: "⌘O", label: "Open session file (.jsonl/.gz)"),
            Item(keys: "⌘↵", label: "Open in Terminal"),
            Item(keys: "⌘⇧C", label: "Copy resume command"),
            Item(keys: "⌘C", label: "Copy session(s) with content"),
            Item(keys: "⌘⇧P", label: "Export as PDF"),
            Item(keys: "⌘⇧R", label: "Reveal in Finder"),
            Item(keys: "⌘D", label: "Add to favorites"),
            Item(keys: "⌘⌫", label: "Hide session"),
        ]),
        Group(title: "Replies", items: [
            Item(keys: "⌘⇧T", label: "Reply to all in turn"),
            Item(keys: "⌘↵", label: "Reply and continue (in triage)"),
            Item(keys: "⌥X", label: "No reply needed (in triage)"),
            Item(keys: "⌥→", label: "Skip (in triage)"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Keyboard Shortcuts").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("Esc")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 14)
            Divider()

            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .top),
                                    GridItem(.flexible(), alignment: .top)],
                          alignment: .leading, spacing: 22) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(group.title.uppercased())
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Theme.sectionLabel)
                                .padding(.bottom, 1)
                            ForEach(group.items) { item in
                                HStack(spacing: 10) {
                                    Text(item.keys)
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(Color.secondary)
                                        .frame(width: 92, alignment: .leading)
                                    Text(item.label)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(.primary)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 560, height: 460)
    }
}

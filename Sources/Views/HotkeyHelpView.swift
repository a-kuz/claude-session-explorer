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
        Group(title: "Навигация", items: [
            Item(keys: "⌘↓ / ⌘↑", label: "Следующая / предыдущая сессия"),
            Item(keys: "⌘] / ⌘[", label: "Следующая / предыдущая реплика"),
            Item(keys: "⌘G / ⌘⇧G", label: "Следующее / предыдущее совпадение"),
        ]),
        Group(title: "Поиск", items: [
            Item(keys: "⌘F", label: "Найти"),
            Item(keys: "Esc", label: "Сбросить поиск"),
        ]),
        Group(title: "Вид", items: [
            Item(keys: "⌘B", label: "Боковая панель"),
            Item(keys: "⌘⇧B", label: "Содержание"),
            Item(keys: "⌘E", label: "Кратко / полно"),
            Item(keys: "⌘+ / ⌘−", label: "Масштаб текста"),
            Item(keys: "⌘0", label: "Сбросить масштаб"),
            Item(keys: "⌘⇧= / ⌘⇧−", label: "Больше / меньше воздуха"),
        ]),
        Group(title: "Сессия", items: [
            Item(keys: "⌘↵", label: "Открыть в Ghostty"),
            Item(keys: "⌘⇧C", label: "Скопировать resume"),
            Item(keys: "⌘⇧R", label: "Показать в Finder"),
            Item(keys: "⌘D", label: "В избранное"),
            Item(keys: "⌘⌫", label: "Скрыть сессию"),
        ]),
        Group(title: "Ответы", items: [
            Item(keys: "⌘⇧T", label: "Ответить всем поочерёдно"),
            Item(keys: "⌘↵", label: "Ответить и дальше (в триаже)"),
            Item(keys: "⌥X", label: "Не требует ответа (в триаже)"),
            Item(keys: "⌥→", label: "Пропустить (в триаже)"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Сочетания клавиш").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("Esc")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                Button("Закрыть") { dismiss() }
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
                                        .foregroundStyle(Color(hex: 0x6B7280))
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

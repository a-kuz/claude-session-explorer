import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            Section {
                quickRow(.all, icon: "tray.full", title: "Все сессии",
                         count: model.allSessions.count)
                attentionRow
                quickRow(.favorites, icon: "star.fill", iconColor: Color(hex: 0xFEBC2E),
                         title: "Избранное", count: model.favorites.count)
            }

            Section {
                ForEach(model.projects) { p in
                    projectRow(p)
                }
            } header: {
                HStack(spacing: 4) {
                    Text("ПРОЕКТЫ")
                    Spacer()
                    Button { model.selectAllProjects() } label: {
                        Image(systemName: "checklist.checked")
                    }
                    .buttonStyle(.borderless).help("Выбрать все")
                    Button { model.clearProjects() } label: {
                        Image(systemName: "checklist.unchecked")
                    }
                    .buttonStyle(.borderless).help("Снять все")
                }
            }

            Section("ПЕРИОД") {
                quickRow(.today, icon: "clock", title: "Сегодня", count: countToday())
                quickRow(.last24h, icon: "clock.arrow.circlepath", title: "За 24 часа",
                         count: countWithin(.hour, -24))
                quickRow(.last2d, icon: "calendar.day.timeline.left", title: "За 2 дня",
                         count: countWithin(.day, -2))
                quickRow(.week, icon: "calendar", title: "За 7 дней", count: countWithin(.day, -7))
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private func countToday() -> Int {
        let cal = Calendar.current
        return model.allSessions.filter { cal.isDateInToday($0.mtime) }.count
    }

    private func countWithin(_ unit: Calendar.Component, _ value: Int) -> Int {
        let cal = Calendar.current
        guard let t = cal.date(byAdding: unit, value: value, to: Date()) else { return 0 }
        return model.allSessions.filter { $0.mtime > t }.count
    }

    // "Требует ответа" — not a filter but the entry point into the triage screen.
    // The accent pill shows how many sessions are waiting on a reply.
    @ViewBuilder
    private var attentionRow: some View {
        let n = model.attentionCount
        Label {
            HStack {
                Text("Требует ответа").fontWeight(n > 0 ? .medium : .regular)
                Spacer()
                if n > 0 {
                    Text("\(n)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Theme.accent, in: Capsule())
                } else {
                    Text("0").foregroundStyle(.tertiary).font(.callout)
                }
            }
        } icon: {
            Image(systemName: "arrowshape.turn.up.left")
                .foregroundStyle(n > 0 ? Theme.accent : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { if n > 0 { model.enterTriage() } }
        .help(n > 0 ? "Ответить всем поочерёдно (\(n))" : "Нет сессий, ждущих ответа")
    }

    // A single-select scope row (All / Favorites / Today / 24h / 2d / Week).
    @ViewBuilder
    private func quickRow(_ s: AppModel.Scope, icon: String,
                          iconColor: Color = .secondary, title: String, count: Int) -> some View {
        let selected = model.scope == s
        Label {
            HStack {
                Text(title)
                Spacer()
                Text("\(count)").foregroundStyle(.tertiary).font(.callout)
            }
        } icon: {
            Image(systemName: icon).foregroundStyle(selected ? Color.white : iconColor)
        }
        .listRowBackground(selected ? RoundedRectangle(cornerRadius: 6).fill(Theme.accent) : nil)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .contentShape(Rectangle())
        .onTapGesture { model.setScope(s) }
    }

    // A project row with a native checkbox (multi-select).
    private func projectRow(_ p: ProjectInfo) -> some View {
        Toggle(isOn: Binding(
            get: { model.isProjectSelected(p.path) },
            set: { _ in model.toggleProject(p.path) }
        )) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.dotColor(for: p.path)).frame(width: 9, height: 9)
                Text(p.label).lineLimit(1)
                Spacer()
                Text("\(p.count)").foregroundStyle(.tertiary).font(.callout)
            }
        }
        .toggleStyle(.checkbox)
    }
}

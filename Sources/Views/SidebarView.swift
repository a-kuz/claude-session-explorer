import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    /// Select-all / clear-all live in the PROJECTS header but only show while
    /// the cursor is over it — two tiny cryptic glyphs otherwise add noise.
    @State private var projectsHeaderHovered = false

    var body: some View {
        List {
            Section {
                quickRow(.all, icon: "tray.full", title: "All Sessions",
                         count: model.allSessions.count)
                attentionRow
                quickRow(.favorites, icon: "star.fill", iconColor: Color(hex: 0xFEBC2E),
                         title: "Favorites", count: model.favorites.count)
                if !model.hidden.isEmpty {
                    quickRow(.hidden, icon: "eye.slash", title: "Hidden",
                             count: model.hidden.count)
                }
            }

            Section {
                ForEach(model.visibleProjectRows) { p in
                    ProjectRow(project: p)
                }
            } header: {
                HStack(spacing: 4) {
                    Text("PROJECTS")
                    Spacer()
                    Button { model.selectAllProjects() } label: {
                        Image(systemName: "checklist.checked")
                    }
                    .buttonStyle(.borderless).help("Select all")
                    .opacity(projectsHeaderHovered ? 1 : 0)
                    Button { model.clearProjects() } label: {
                        Image(systemName: "checklist.unchecked")
                    }
                    .buttonStyle(.borderless).help("Clear all")
                    .opacity(projectsHeaderHovered ? 1 : 0)
                }
                .contentShape(Rectangle())
                .onHover { projectsHeaderHovered = $0 }
            }

            Section("PERIOD") {
                quickRow(.today, icon: "clock", title: "Today", count: countToday())
                quickRow(.last24h, icon: "clock.arrow.circlepath", title: "Last 24 Hours",
                         count: countWithin(.hour, -24))
                quickRow(.last2d, icon: "calendar.day.timeline.left", title: "Last 2 Days",
                         count: countWithin(.day, -2))
                quickRow(.week, icon: "calendar", title: "Last 7 Days", count: countWithin(.day, -7))
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

    // "Needs Reply" — not a filter but the entry point into the triage screen.
    // The accent pill shows how many sessions are waiting on a reply.
    @ViewBuilder
    private var attentionRow: some View {
        let n = model.attentionCount
        Label {
            HStack {
                Text("Needs Reply").fontWeight(n > 0 ? .medium : .regular)
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
        .help(n > 0 ? "Reply to all one by one (\(n))" : "No sessions waiting for a reply")
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

}

/// A project row (multi-select) in the hierarchy: projects nested inside another
/// project's directory sit under it, indented behind a disclosure triangle.
/// The checkbox shows only while checked or hovered — an empty square on every
/// row is constant noise for a rare action; it covers the whole subtree, so a
/// partly selected parent shows a dash. Clicking anywhere on the row cycles it:
/// the whole subtree, then this directory alone, then off.
private struct ProjectRow: View {
    let project: ProjectInfo
    @EnvironmentObject var model: AppModel
    @State private var hovering = false

    var body: some View {
        let check = model.projectCheck(project)
        let collapsed = model.isProjectCollapsed(project.path)
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(project.depth) * 11, height: 1)
            Group {
                if project.children.isEmpty {
                    Color.clear
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                        .contentShape(Rectangle())
                        .onTapGesture { model.toggleProjectCollapsed(project.path) }
                }
            }
            .frame(width: 10, height: 12)

            Image(systemName: check == .on ? "checkmark.square.fill"
                            : check == .mixed ? "minus.square.fill" : "square")
                .foregroundStyle(check == .off ? Color.secondary : Theme.accent)
                .opacity(check != .off || hovering ? 1 : 0)
                .contentShape(Rectangle())
                .onTapGesture { toggle() }

            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.dotColor(for: project.path)).frame(width: 9, height: 9)
                Text(project.label).lineLimit(1)
                Spacer()
                // A collapsed parent accounts for the sessions it hides.
                Text("\(collapsed && !project.children.isEmpty ? project.totalCount : project.count)")
                    .foregroundStyle(.tertiary).font(.callout)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.toggleProject(project) }
        }
        .help(project.children.isEmpty ? project.path
              : "\(project.path)\nClick cycles: with nested projects → this folder only → off")
        .onHover { hovering = $0 }
    }

    private func toggle() { model.toggleProject(project) }
}

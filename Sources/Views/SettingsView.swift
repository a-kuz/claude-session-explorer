import SwiftUI

/// App settings (⌘,). Native macOS tabbed preferences: Terminal, Appearance,
/// Dialog, Data. Each control binds straight to AppModel, which persists it.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            TerminalSettings().tabItem { Label("Терминал", systemImage: "terminal") }
            AppearanceSettings().tabItem { Label("Внешний вид", systemImage: "textformat.size") }
            DialogSettings().tabItem { Label("Диалог", systemImage: "bubble.left.and.bubble.right") }
            DataSettings().tabItem { Label("Данные", systemImage: "externaldrive") }
        }
        .frame(width: 520)
    }
}

private struct TerminalSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Picker("Открывать сессии в", selection: $model.terminalApp) {
                ForEach(TerminalApp.allCases) { app in
                    Text(app.label).tag(app)
                }
            }
        }
        .padding(20)
    }
}

private struct AppearanceSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            FontField(title: "Основной текст", systemLabel: "Системный",
                      selection: $model.proseFont)
            FontField(title: "Код и тулы", systemLabel: "Системный моноширинный",
                      selection: $model.monoFont)

            Slider(value: $model.fontScale, in: 0.7...2.0, step: 0.05) {
                Text("Масштаб текста")
            } minimumValueLabel: { Text("70%").font(.caption) }
              maximumValueLabel: { Text("200%").font(.caption) }

            Slider(value: $model.air, in: 8...40, step: 1) {
                Text("Воздух между репликами")
            } minimumValueLabel: { Text("8").font(.caption) }
              maximumValueLabel: { Text("40").font(.caption) }
        }
        .padding(20)
    }
}

private struct DialogSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Toggle("Краткий режим", isOn: $model.briefMode)
            Toggle("Группировать ветки сессий", isOn: $model.groupForks)
            Picker("Ветки в диалоге", selection: $model.branchMode) {
                ForEach(BranchMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
        }
        .padding(20)
    }
}

private struct DataSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmReset = false

    var body: some View {
        Form {
            LabeledContent("Каталог сессий") {
                Text(model.projectsDirPath).foregroundStyle(.secondary).textSelection(.enabled)
            }
            LabeledContent("Файл кеша") {
                Text(model.cacheStorePath).foregroundStyle(.secondary).textSelection(.enabled)
            }
            LabeledContent("Кеш метаданных") {
                Button("Сбросить…") { confirmReset = true }
            }
        }
        .padding(20)
        .confirmationDialog("Сбросить кеш метаданных?",
                            isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Сбросить", role: .destructive) { model.resetCache() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Все сессии будут перечитаны из jsonl. Может занять время на больших коллекциях.")
        }
    }
}

/// Font picker with substring search. Both prose and mono fields use it, so any
/// installed family is selectable from either; `selection == ""` is the system
/// default. Each row previews itself in its own family.
private struct FontField: View {
    let title: String
    let systemLabel: String
    @Binding var selection: String

    @State private var open = false
    @State private var query = ""

    private let families = DialogFonts.availableFamilies()

    private var filtered: [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return families }
        return families.filter { $0.range(of: q, options: .caseInsensitive) != nil }
    }

    var body: some View {
        LabeledContent(title) {
            Button {
                open = true
            } label: {
                HStack(spacing: 6) {
                    Text(selection.isEmpty ? systemLabel : selection)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .popover(isPresented: $open, arrowEdge: .bottom) { picker }
        }
    }

    private var picker: some View {
        VStack(spacing: 0) {
            TextField("Поиск шрифта", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    row(systemLabel, value: "", font: .body)
                    ForEach(filtered, id: \.self) { f in
                        row(f, value: f, font: DialogFonts.preview(family: f, size: 13))
                    }
                }
            }
            .frame(width: 280, height: 320)
        }
    }

    private func row(_ label: String, value: String, font: Font) -> some View {
        Button {
            selection = value
            open = false
        } label: {
            HStack {
                Text(label).font(font).lineLimit(1)
                Spacer()
                if selection == value {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }
}

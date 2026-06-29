import SwiftUI

/// App settings (⌘,). Native macOS tabbed preferences: Terminal, Appearance,
/// Dialog, Data. Each control binds straight to AppModel, which persists it.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            TerminalSettings().tabItem { Label("Terminal", systemImage: "terminal") }
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "textformat.size") }
            DialogSettings().tabItem { Label("Dialog", systemImage: "bubble.left.and.bubble.right") }
            DataSettings().tabItem { Label("Data", systemImage: "externaldrive") }
        }
        .frame(width: 520)
    }
}

private struct TerminalSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Picker("Open sessions in", selection: $model.terminalApp) {
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
            FontField(title: "Body text", systemLabel: "System",
                      selection: $model.proseFont)
            FontField(title: "Code and tools", systemLabel: "System monospaced",
                      selection: $model.monoFont)

            Slider(value: $model.fontScale, in: 0.7...2.0, step: 0.05) {
                Text("Text scale")
            } minimumValueLabel: { Text("70%").font(.caption) }
              maximumValueLabel: { Text("200%").font(.caption) }

            Slider(value: $model.air, in: 8...40, step: 1) {
                Text("Spacing between messages")
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
            Toggle("Brief mode", isOn: $model.briefMode)
            Toggle("Group session branches", isOn: $model.groupForks)
            Picker("Branches in dialog", selection: $model.branchMode) {
                ForEach(BranchMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            CopyOutputLimitField(limit: $model.copyToolOutputLimit)
        }
        .padding(20)
    }
}

/// Caps how many characters of each tool's output are placed on the clipboard
/// when copying sessions/blocks. The toggle switches between "full" (0) and a
/// numeric cap; the last non-zero value is remembered while the toggle is off.
private struct CopyOutputLimitField: View {
    @Binding var limit: Int

    @State private var lastNonZero = 2000

    private var limited: Binding<Bool> {
        Binding(get: { limit > 0 },
                set: { on in limit = on ? lastNonZero : 0 })
    }

    var body: some View {
        Toggle("Limit copied tool output", isOn: limited)
        if limit > 0 {
            LabeledContent("Max characters per output") {
                TextField("", value: Binding(
                    get: { limit },
                    set: { limit = max(1, $0); lastNonZero = limit }
                ), format: .number)
                .frame(width: 90)
                .multilineTextAlignment(.trailing)
            }
        }
    }
}

private struct DataSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmReset = false

    var body: some View {
        Form {
            LabeledContent("Sessions directory") {
                Text(model.projectsDirPath).foregroundStyle(.secondary).textSelection(.enabled)
            }
            LabeledContent("Cache file") {
                Text(model.cacheStorePath).foregroundStyle(.secondary).textSelection(.enabled)
            }
            LabeledContent("Metadata cache") {
                Button("Reset…") { confirmReset = true }
            }
        }
        .padding(20)
        .confirmationDialog("Reset metadata cache?",
                            isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { model.resetCache() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All sessions will be re-read from jsonl. This may take a while for large collections.")
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
            TextField("Search fonts", text: $query)
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

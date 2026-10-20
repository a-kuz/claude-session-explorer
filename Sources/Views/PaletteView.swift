import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - State

/// State of the jump palette (⌘K in the app, ⌃⌥Space system-wide): the query,
/// the ranked rows and the keyboard cursor. Lives for one presentation.
@MainActor
final class PaletteModel: ObservableObject {
    @Published var query = "" { didSet { rerank() } }
    @Published private(set) var items: [PaletteItem] = []
    @Published var index = 0
    @Published private(set) var live: [String: LiveSession] = [:]

    private unowned let app: AppModel
    private var liveTask: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
        rerank()
    }

    var selected: PaletteItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        index = max(0, min(items.count - 1, index + delta))
    }

    /// Polls the process registry while the palette is on screen: a session
    /// switching idle → waiting should reorder within a couple of seconds.
    func startLivePolling() {
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                let scanned = await Task.detached { LiveSessions.bySession(LiveSessions.scan()) }.value
                guard let self, !Task.isCancelled else { return }
                if scanned != self.live { self.live = scanned; self.rerank() }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stopLivePolling() { liveTask?.cancel(); liveTask = nil }

    private func rerank() {
        let hidden = app.hidden
        let sessions = app.externalSessions + app.allSessions.filter { !hidden.contains($0.id) }
        items = Palette.rank(query: query, sessions: sessions, live: live)
        index = 0
    }

    /// ↵ — show the session in the explorer window.
    func openInApp() {
        guard let item = selected else { return }
        PalettePanel.shared.hide()
        if item.meta != nil {
            app.jumpToSession(item.id)
            PalettePanel.bringAppForward()
        } else {
            // A process whose transcript isn't on disk yet: the terminal is the
            // only place it exists.
            app.openInTerminal(meta: Self.syntheticMeta(item))
        }
    }

    /// ⌘↵ — focus or start the session in the terminal.
    func openInTerminal() {
        guard let item = selected else { return }
        PalettePanel.shared.hide()
        app.openInTerminal(meta: item.meta ?? Self.syntheticMeta(item))
    }

    private static func syntheticMeta(_ item: PaletteItem) -> SessionMeta {
        SessionMeta(id: item.id, filePath: "", projectPath: item.projectPath,
                    projectLabel: item.projectLabel, title: item.title, titleIsCustom: false,
                    lastUserText: "", firstUserText: "", mtime: item.when,
                    firstActivity: nil, lastActivity: nil, messageCount: 0, byteSize: 0,
                    userTurnCount: 0, model: nil)
    }
}

// MARK: - View

struct PaletteView: View {
    @ObservedObject var palette: PaletteModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Jump to session", text: $palette.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .regular))
                    .focused($fieldFocused)
                if !palette.live.isEmpty {
                    Text("\(palette.live.count) running")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)

            Divider()

            if palette.items.isEmpty {
                Text(palette.query.isEmpty ? "No sessions" : "Nothing matches «\(palette.query)»")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(palette.items.enumerated()), id: \.element.id) { i, item in
                                PaletteRow(item: item, selected: i == palette.index)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { palette.index = i; palette.openInApp() }
                                    .onHover { if $0 { palette.index = i } }
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: min(CGFloat(palette.items.count) * 46 + 12, 420))
                    .onChange(of: palette.index) { _, i in
                        if let id = palette.items.indices.contains(i) ? palette.items[i].id : nil {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }

            Divider()
            HStack(spacing: 14) {
                Hint(keys: "↵", label: "open")
                Hint(keys: "⌘↵", label: "terminal")
                Hint(keys: "↑↓", label: "move")
                Spacer()
                Hint(keys: "esc", label: "close")
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
        }
        .frame(width: 680)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .onAppear { fieldFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: PalettePanel.focusNotification)) { _ in
            fieldFocused = true
        }
    }

    private struct Hint: View {
        let keys: String, label: String
        var body: some View {
            HStack(spacing: 5) {
                Text(keys)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                Text(label).font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
        }
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 13.5, weight: .medium))
                        .lineLimit(1)
                    if let l = item.live {
                        Text(l.name.isEmpty ? l.status : "\(l.name) · \(l.waitingFor ?? l.status)")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(dotColor)
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .background(dotColor.opacity(selected ? 0.28 : 0.14), in: Capsule())
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(Format.relativeTime(item.when))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 6) {
                    Text(item.projectLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(selected ? Theme.accent.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var dotColor: Color {
        guard let l = item.live else { return Theme.dotColor(for: item.projectPath) }
        switch l.status {
        case "waiting": return .orange
        case "busy": return Theme.accent
        case "shell": return .purple
        default: return .green
        }
    }
}

// MARK: - Panel

/// A Spotlight-style floating panel: key without activating the app, closes on
/// Esc or when it loses key status, keyboard-driven via a local event monitor.
@MainActor
final class PalettePanel: NSObject, NSWindowDelegate {
    static let shared = PalettePanel()
    static let focusNotification = Notification.Name("PalettePanel.focus")

    private var panel: NSPanel?
    private var model: PaletteModel?
    private var keyMonitor: Any?
    private weak var app: AppModel?

    func configure(app: AppModel) { self.app = app }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        guard let app else { return }
        let m = PaletteModel(app: app)
        model = m
        let p = panel ?? makePanel()
        panel = p
        let host = NSHostingView(rootView: PaletteView(palette: m))
        host.sizingOptions = [.preferredContentSize]
        p.contentView = host
        place(p)
        p.makeKeyAndOrderFront(nil)
        m.startLivePolling()
        installKeyMonitor(for: m)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.focusNotification, object: nil)
        }
    }

    func hide() {
        model?.stopLivePolling()
        if let k = keyMonitor { NSEvent.removeMonitor(k); keyMonitor = nil }
        panel?.orderOut(nil)
        panel?.contentView = nil
        model = nil
    }

    /// After a jump from the system-wide hotkey the explorer window may be
    /// behind other apps: bring it up.
    static func bringAppForward() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        }
    }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private func makePanel() -> NSPanel {
        let p = Panel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 200),
                      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                      backing: .buffered, defer: false)
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.delegate = self
        return p
    }

    private func place(_ p: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.visibleFrame
        p.layoutIfNeeded()
        let size = p.contentView?.fittingSize ?? NSSize(width: 680, height: 200)
        let origin = NSPoint(x: f.midX - size.width / 2, y: f.maxY - f.height * 0.22 - size.height)
        p.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    private func installKeyMonitor(for m: PaletteModel) {
        if let k = keyMonitor { NSEvent.removeMonitor(k) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak m] e in
            MainActor.assumeIsolated {
                guard let self, let m, e.window === self.panel else { return e }
                let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
                switch (e.keyCode, mods) {
                case (53, []): self.hide(); return nil                       // esc
                case (125, []): m.move(1); return nil                         // ↓
                case (126, []): m.move(-1); return nil                        // ↑
                case (45, [.control]): m.move(1); return nil                  // ⌃N
                case (35, [.control]): m.move(-1); return nil                 // ⌃P
                case (36, []), (76, []): m.openInApp(); return nil            // ↵
                case (36, [.command]), (76, [.command]): m.openInTerminal(); return nil
                default: return e
                }
            }
        }
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in self.hide() }
    }

    // MARK: system-wide hotkey (⌃⌥Space), Carbon — needs no Accessibility grant.

    private static var hotKeyRef: EventHotKeyRef?
    private static var handlerInstalled = false

    static func setGlobalHotkey(enabled: Bool) {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        guard enabled else { return }
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { PalettePanel.shared.toggle() }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        let id = EventHotKeyID(signature: 0x5358504C /* SXPL */, id: 1)
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

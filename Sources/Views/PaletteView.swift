import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - State

/// State of the jump palette (⌘K in the app, ⌃⌥Space system-wide): the query,
/// the ranked rows, the keyboard cursor and the preview of the cursor's
/// session. Lives for one presentation.
@MainActor
final class PaletteModel: ObservableObject {
    @Published var query = "" { didSet { rerank() } }
    @Published private(set) var items: [PaletteItem] = []
    @Published private(set) var index = 0
    @Published private(set) var live: [String: LiveSession] = [:]
    /// Preview of `selected`; `nil` while loading or when nothing is selected.
    @Published private(set) var preview: [PreviewMessage]?
    @Published private(set) var previewID: String?
    /// Bumped on keyboard moves only: a click selects a row without the list
    /// scrolling under the pointer.
    @Published private(set) var keyboardMove = 0

    private unowned let app: AppModel
    private var liveTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
        // The registry is ~50 small files: read it synchronously so the first
        // frame already has the right order and status chips.
        live = LiveSessions.bySession(LiveSessions.scan())
        rerank()
    }

    var selected: PaletteItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    var busyCount: Int { live.values.filter { $0.status == "busy" }.count }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        setIndex(max(0, min(items.count - 1, index + delta)))
        keyboardMove += 1
    }

    func select(_ i: Int) { setIndex(i) }

    private func setIndex(_ i: Int) {
        guard i != index else { return }
        index = i
        schedulePreview()
    }

    /// Polls the process registry while the palette is on screen: a session
    /// switching idle → busy should show within a couple of seconds.
    func startLivePolling() {
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                let scanned = await Task.detached { LiveSessions.bySession(LiveSessions.scan()) }.value
                guard let self, !Task.isCancelled else { return }
                if scanned != self.live { self.live = scanned; self.rerank(keepCursor: true) }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stopPolling() {
        liveTask?.cancel(); liveTask = nil
        previewTask?.cancel(); previewTask = nil
    }

    private func rerank(keepCursor: Bool = false) {
        let hidden = app.hidden
        let sessions = app.externalSessions + app.allSessions.filter { !hidden.contains($0.id) }
        let keep = keepCursor ? selected?.id : nil
        items = Palette.rank(query: query, sessions: sessions, live: live)
        index = keep.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        schedulePreview()
    }

    /// Reads the tail of the cursor's session off-thread, after a short pause
    /// so holding ↓ doesn't read a file per row.
    private func schedulePreview() {
        previewTask?.cancel()
        guard let item = selected else { preview = nil; previewID = nil; return }
        guard let meta = item.meta else { preview = []; previewID = item.id; return }
        if previewID != item.id { preview = nil; previewID = item.id }
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let msgs = await Task.detached { Palette.loadPreview(meta) }.value
            guard let self, !Task.isCancelled, self.selected?.id == item.id else { return }
            self.preview = msgs
        }
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

    static let previewWidth: CGFloat = 400
    static let listWidth: CGFloat = 600
    static let height: CGFloat = 520

    var body: some View {
        HStack(spacing: 0) {
            PalettePreviewPane(palette: palette)
                .frame(width: Self.previewWidth)
            Divider()
            listColumn
                .frame(width: Self.listWidth)
        }
        .frame(height: Self.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .onAppear { fieldFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: PalettePanel.focusNotification)) { _ in
            fieldFocused = true
        }
    }

    private var listColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Jump to session", text: $palette.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 19, weight: .regular))
                    .focused($fieldFocused)
                statusSummary
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())

            Divider()

            if palette.items.isEmpty {
                Text(palette.query.isEmpty ? "No sessions" : "Nothing matches «\(palette.query)»")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(palette.items.enumerated()), id: \.element.id) { i, item in
                                PaletteRow(item: item, selected: i == palette.index)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { palette.select(i); palette.openInApp() }
                                    .onTapGesture { palette.select(i) }
                            }
                        }
                        .padding(6)
                        .animation(.easeOut(duration: 0.12), value: palette.index)
                    }
                    .onChange(of: palette.keyboardMove) { _, _ in
                        if let id = palette.selected?.id { proxy.scrollTo(id, anchor: nil) }
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
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
        }
    }

    @ViewBuilder private var statusSummary: some View {
        let busy = palette.busyCount
        if !palette.live.isEmpty {
            HStack(spacing: 6) {
                if busy > 0 {
                    PulsingDot(color: Theme.accent, size: 6)
                    Text("\(busy) generating")
                        .foregroundStyle(Theme.accent)
                }
                Text(busy > 0 ? "· \(palette.live.count) running" : "\(palette.live.count) running")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: Capsule())
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

/// A dot that breathes while a session is generating.
struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 8
    @State private var on = false

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.35))
                .frame(width: size * 2.4, height: size * 2.4)
                .scaleEffect(on ? 1 : 0.4)
                .opacity(on ? 0 : 0.9)
            Circle().fill(color).frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { on = true }
        }
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool

    private var primary: Color { selected ? .white : .primary }
    private var secondary: Color { selected ? .white.opacity(0.8) : .secondary }
    private var tertiary: Color { selected ? .white.opacity(0.6) : Color(nsColor: .tertiaryLabelColor) }

    var body: some View {
        HStack(spacing: 10) {
            if item.live?.status == "busy" {
                PulsingDot(color: selected ? .white : dotColor, size: 8)
            } else {
                Circle().fill(selected ? .white : dotColor).frame(width: 8, height: 8)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(primary)
                        .lineLimit(1)
                    if let l = item.live {
                        Text(chipText(l))
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(selected ? .white : dotColor)
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .background((selected ? Color.white : dotColor).opacity(selected ? 0.22 : 0.14),
                                        in: Capsule())
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(Format.relativeTime(item.when))
                        .font(.system(size: 11))
                        .foregroundStyle(tertiary)
                }
                HStack(spacing: 6) {
                    Text(item.projectLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(secondary)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 11))
                            .foregroundStyle(tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(selected ? Theme.accent : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func chipText(_ l: LiveSession) -> String {
        let state = l.status == "busy" ? "generating" : (l.waitingFor ?? l.status)
        return l.name.isEmpty ? state : "\(l.name) · \(state)"
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

// MARK: - Preview pane

/// The tail of the cursor's session, compact: who said what, tools folded
/// into one line. Pinned to the bottom like the real transcript.
private struct PalettePreviewPane: View {
    @ObservedObject var palette: PaletteModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let item = palette.selected {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(item.projectLabel).fontWeight(.medium)
                        if let m = item.meta {
                            Text("·"); Text(Format.byteSize(m.byteSize))
                            Text("·"); Text("\(m.userTurnCount) prompts")
                        }
                        if let l = item.live { Text("·"); Text(l.name) }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                Divider()
                content(item)
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.025))
    }

    @ViewBuilder private func content(_ item: PaletteItem) -> some View {
        if let msgs = palette.preview, palette.previewID == item.id {
            if msgs.isEmpty {
                Text(item.meta == nil ? "Running, no transcript on disk yet" : "Empty transcript")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(msgs) { m in PreviewMessageView(message: m) }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .id(item.id)
            }
        } else {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct PreviewMessageView: View {
    let message: PreviewMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(message.role == .user ? Theme.accent : .secondary)
                if let t = message.time {
                    Text(Format.timeOrDate(t))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
            if !message.text.isEmpty {
                Text(message.text)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !message.tools.isEmpty {
                Text(message.tools)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, message.role == .user ? 6 : 2)
        .padding(.horizontal, message.role == .user ? 8 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == .user ? Theme.accent.opacity(0.07) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private var label: String {
        if message.isCompactSummary { return "Context compacted" }
        return message.role == .user ? "You" : "Claude"
    }
}

// MARK: - Panel

/// A Spotlight-style floating panel: key without activating the app, closes on
/// Esc or when it loses key status, keyboard-driven via a local event monitor.
/// Draggable by its header/footer; the position is remembered.
@MainActor
final class PalettePanel: NSObject, NSWindowDelegate {
    static let shared = PalettePanel()
    static let focusNotification = Notification.Name("PalettePanel.focus")
    private static let originKey = "palette.origin"

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
        host.sizingOptions = []
        p.contentView = host
        place(p)
        // Spotlight-style entrance: a quick fade with a slight scale-up.
        let target = p.frame
        p.alphaValue = 0
        p.setFrame(target.insetBy(dx: target.width * 0.02, dy: target.height * 0.02), display: false)
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
            p.animator().setFrame(target, display: true)
        }
        m.startLivePolling()
        installKeyMonitor(for: m)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.focusNotification, object: nil)
        }
    }

    func hide() {
        model?.stopPolling()
        if let k = keyMonitor { NSEvent.removeMonitor(k); keyMonitor = nil }
        model = nil
        guard let p = panel, p.isVisible else { return }
        UserDefaults.standard.set(NSStringFromPoint(p.frame.origin), forKey: Self.originKey)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
            p.contentView = nil
            p.alphaValue = 1
        })
    }

    /// After a jump from the system-wide hotkey the explorer window may be
    /// behind other apps or closed: bring it up, recreating it if needed.
    static func bringAppForward() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            // No main window (closed while running in the background): a
            // reopen request makes SwiftUI create the WindowGroup window again.
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                               configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private static var size: NSSize {
        NSSize(width: PaletteView.previewWidth + PaletteView.listWidth + 1, height: PaletteView.height)
    }

    private func makePanel() -> NSPanel {
        let p = Panel(contentRect: NSRect(origin: .zero, size: Self.size),
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
        let size = Self.size
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.visibleFrame
        var origin = NSPoint(x: f.midX - size.width / 2, y: f.maxY - f.height * 0.18 - size.height)
        if let saved = UserDefaults.standard.string(forKey: Self.originKey) {
            let o = NSPointFromString(saved)
            let r = NSRect(origin: o, size: size)
            // Reuse the remembered spot only while it's still on some screen.
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r) }) { origin = o }
        }
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

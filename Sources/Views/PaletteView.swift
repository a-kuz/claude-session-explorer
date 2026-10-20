import SwiftUI
import AppKit
import Carbon.HIToolbox
import Combine

// MARK: - State

/// State of the jump palette (⌘K in the app, ⌃⌥Space system-wide): the query,
/// the ranked rows, the keyboard cursor and the preview of the cursor's
/// session. Lives for one presentation.
@MainActor
final class PaletteModel: ObservableObject {
    @Published var query = "" { didSet { rerank() } }
    /// An arrow key on the empty query widens the list from the generating
    /// sessions to everything.
    @Published private(set) var showAll = false
    @Published private(set) var items: [PaletteItem] = []
    @Published private(set) var index = 0
    @Published private(set) var live: [String: LiveSession] = [:]
    /// Preview of `selected`; `nil` while loading or when nothing is selected.
    @Published private(set) var preview: PalettePreview??
    @Published private(set) var previewID: String?
    /// Bumped when the keyboard or a click chooses a row; hover never does.
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
        if query.isEmpty, !showAll {
            showAll = true
            rerank(keepCursor: true)
            keyboardMove += 1
            return
        }
        guard !items.isEmpty else { return }
        setIndex(max(0, min(items.count - 1, index + delta)))
        keyboardMove += 1
    }

    func select(_ i: Int) { setIndex(i); keyboardMove += 1 }

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
        items = Palette.rank(query: query, sessions: sessions, live: live, showAll: showAll)
        index = keep.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        schedulePreview()
    }

    /// Reads the tail of the cursor's session off-thread, after a short pause
    /// so holding ↓ doesn't read a file per row.
    private func schedulePreview() {
        previewTask?.cancel()
        guard let item = selected else { preview = nil; previewID = nil; return }
        guard let meta = item.meta else { preview = .some(nil); previewID = item.id; return }
        if previewID != item.id { preview = nil; previewID = item.id }
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let loaded = await Task.detached { Palette.loadPreview(meta) }.value
            guard let self, !Task.isCancelled, self.selected?.id == item.id else { return }
            self.preview = .some(loaded)
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

    static let previewWidth: CGFloat = 440
    static let listWidth: CGFloat = 600
    static let rowHeight: CGFloat = 52
    static let maxRows = 9

    /// Like Spotlight, the panel is just the search field until there are
    /// rows, then grows with them up to `maxRows`.
    static func height(forRows n: Int) -> CGFloat {
        let chrome: CGFloat = 50 + 1
        if n == 0 { return chrome + 70 }
        return chrome + 12 + CGFloat(min(n, maxRows)) * rowHeight
    }

    var body: some View {
        HStack(spacing: 0) {
            PalettePreviewPane(palette: palette)
                .frame(width: Self.previewWidth)
            Divider()
            listColumn
                .frame(width: Self.listWidth)
        }
        // No fixed height: the panel animates its frame and the content
        // follows it top-aligned, so the search field never slides off.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                Text(palette.query.isEmpty ? "Nothing is generating · ↓ for all sessions, or type" : "Nothing matches «\(palette.query)»")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(palette.items.enumerated()), id: \.element.id) { i, item in
                                PaletteRow(item: item, selected: i == palette.index,
                                           strong: palette.keyboardMove > 0 || i != 0)
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
    /// The cursor row. `strong` draws it blue (after the keyboard or a click
    /// chose it); the default top row is only tinted, as in Spotlight.
    let selected: Bool
    let strong: Bool
    @State private var hovering = false

    private var blue: Bool { selected && strong }
    private var primary: Color { blue ? .white : .primary }
    private var secondary: Color { blue ? .white.opacity(0.8) : .secondary }
    private var tertiary: Color { blue ? .white.opacity(0.6) : Color(nsColor: .tertiaryLabelColor) }
    private var rowBackground: Color {
        if blue { return Theme.accent }
        if selected { return Color.primary.opacity(0.09) }
        return hovering ? Color.primary.opacity(0.05) : .clear
    }

    var body: some View {
        HStack(spacing: 10) {
            if item.live?.status == "busy" {
                PulsingDot(color: blue ? .white : dotColor, size: 8)
            } else {
                Circle().fill(blue ? .white : dotColor).frame(width: 8, height: 8)
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
                            .foregroundStyle(blue ? .white : dotColor)
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .background((blue ? Color.white : dotColor).opacity(blue ? 0.22 : 0.14),
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
        .frame(height: PaletteView.rowHeight - 1)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
    }

    private func chipText(_ l: LiveSession) -> String {
        l.status == "busy" ? "generating" : (l.waitingFor ?? l.status)
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

/// The last block of the cursor's session, rendered by the transcript's own
/// turn views in brief mode. The prompt stays pinned above Claude's turns,
/// which are scrolled to their end.
private struct PalettePreviewPane: View {
    @ObservedObject var palette: PaletteModel
    static let scale: CGFloat = 0.85

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let item = palette.selected {
                content(item)
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.025))
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .environment(\.uiScale, Self.scale)
    }

    @ViewBuilder private func content(_ item: PaletteItem) -> some View {
        if let loaded = palette.preview, palette.previewID == item.id {
            if let p = loaded {
                VStack(alignment: .leading, spacing: 0) {
                    if let turn = p.promptTurn {
                        TurnView(turn: turn, tokens: [], isFocused: false)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .frame(maxWidth: .infinity, maxHeight: 150, alignment: .topLeading)
                            .clipped()
                    } else if !p.promptText.isEmpty {
                        Text(p.promptText)
                            .font(.system(size: 13 * Self.scale, weight: .semibold))
                            .lineLimit(4)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                    if p.responses.isEmpty {
                        Text("No reply yet")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .layoutPriority(1)
                    } else {
                        // Short replies sit at the top; long ones open scrolled
                        // to their end, like the transcript.
                        GeometryReader { geo in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 14) {
                                    ForEach(p.responses) { turn in
                                        TurnView(turn: turn, tokens: [], isFocused: false)
                                    }
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
                            }
                            .defaultScrollAnchor(.bottom)
                        }
                        .id(item.id)
                        .layoutPriority(1)
                    }
                }
            } else {
                Text(item.meta == nil ? "Running, no transcript on disk yet" : "Empty transcript")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
    private static let originKey = "palette.topLeft"

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
        place(p, rows: m.items.count)
        observeSize(of: m, panel: p)
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
        sizeObserver = nil
        guard let p = panel, p.isVisible else { return }
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: p.frame.minX, y: p.frame.maxY)),
                                  forKey: Self.originKey)
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

    private static func size(rows: Int) -> NSSize {
        NSSize(width: PaletteView.previewWidth + PaletteView.listWidth + 1,
               height: PaletteView.height(forRows: rows))
    }
    private var sizeObserver: AnyCancellable?

    /// Grows and shrinks the panel with the result count, keeping its top edge.
    private func observeSize(of m: PaletteModel, panel p: NSPanel) {
        sizeObserver = m.$items.map(\.count).removeDuplicates().dropFirst().sink { [weak p] n in
            guard let p else { return }
            var f = p.frame
            let h = Self.size(rows: n).height
            f.origin.y += f.height - h
            f.size.height = h
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().setFrame(f, display: true)
            }
        }
    }

    private func makePanel() -> NSPanel {
        let p = Panel(contentRect: NSRect(origin: .zero, size: Self.size(rows: 0)),
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

    private func place(_ p: NSPanel, rows: Int) {
        let size = Self.size(rows: rows)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.visibleFrame
        // The remembered position is the panel's top-left corner, so growing
        // and shrinking keep the search field where the user left it.
        var top = NSPoint(x: f.midX - size.width / 2, y: f.maxY - f.height * 0.18)
        if let saved = UserDefaults.standard.string(forKey: Self.originKey) {
            let o = NSPointFromString(saved)
            let r = NSRect(x: o.x, y: o.y - size.height, width: size.width, height: size.height)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r) }) { top = o }
        }
        p.setFrame(NSRect(x: top.x, y: top.y - size.height, width: size.width, height: size.height),
                   display: false)
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
                case (123, []), (124, []): if m.query.isEmpty { m.move(0); return nil }; return e
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

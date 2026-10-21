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
    /// The preview on screen and the session it belongs to. It stays while
    /// the next one loads, so moving the cursor never blanks the pane.
    @Published private(set) var preview: PalettePreview??
    @Published private(set) var previewID: String?
    /// True while `preview` is for a different session than the cursor's.
    @Published private(set) var previewStale = false
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
        guard let item = selected else { preview = nil; previewID = nil; previewStale = false; return }
        if previewID == item.id { previewStale = false; return }
        guard let meta = item.meta else { preview = .some(nil); previewID = item.id; previewStale = false; return }
        previewStale = true
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let loaded = await Task.detached { Palette.loadPreview(meta) }.value
            guard let self, !Task.isCancelled, self.selected?.id == item.id else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                self.preview = .some(loaded)
                self.previewID = item.id
                self.previewStale = false
            }
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
    static let corner: CGFloat = 20
    /// Transparent margin around the panel where its shadow is painted.
    static let margin: CGFloat = 60
    /// Visible gap between the preview window and the palette.
    static let gap: CGFloat = 14
    static let maxRows = 9

    /// Like Spotlight, the panel is just the search field until there are
    /// rows, then grows with them up to `maxRows`.
    static func height(forRows n: Int) -> CGFloat {
        let chrome: CGFloat = 50 + 1
        if n == 0 { return chrome + 70 }
        // The preview beside the list needs room even for a single row.
        return max(380, chrome + 12 + CGFloat(min(n, maxRows)) * rowHeight)
    }

    var body: some View {
        listColumn
            .frame(width: Self.listWidth)
        // No fixed height: the panel animates its frame and the content
        // follows it top-aligned, so the search field never slides off.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .modifier(PaletteChrome())
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
                        .transaction { if $0.animation != nil && palette.keyboardMove == 0 { $0.animation = nil } }
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

/// Material, rim, corner and the Spotlight-like shadow painted in the margin,
/// shared by the palette and the detached preview window.
struct PaletteChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: PaletteView.corner, style: .continuous))
            // A light wash over the material, strongest at the top, lifts the
            // panel the way Spotlight's bar reads lighter than its backdrop.
            .background(LinearGradient(colors: [Color.white.opacity(0.42), Color.white.opacity(0.22)],
                                       startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: PaletteView.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PaletteView.corner, style: .continuous)
                .strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: PaletteView.corner, style: .continuous)
                .stroke(Color.black.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.28), radius: 26, y: 14)
            .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
            .padding(PaletteView.margin)
    }
}

/// The detached preview window's content.
struct PalettePreviewWindowView: View {
    @ObservedObject var palette: PaletteModel
    var body: some View {
        PalettePreviewPane(palette: palette)
            .frame(width: PaletteView.previewWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: PaletteView.corner, style: .continuous))
            .modifier(PaletteChrome())
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
        ZStack(alignment: .topLeading) {
            if let id = palette.previewID, let loaded = palette.preview {
                content(loaded, id: id)
                    .id(id)
                    .transition(.opacity)
                    .opacity(palette.previewStale ? 0.45 : 1)
                    .animation(.easeOut(duration: 0.12), value: palette.previewStale)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.uiScale, Self.scale)
    }

    @ViewBuilder private func content(_ loaded: PalettePreview?, id: String) -> some View {
        Group {
            if let p = loaded {
                VStack(alignment: .leading, spacing: 0) {
                    // Pinned above the replies as a soft tinted card: regular
                    // weight, no rule. A long prompt or a pasted screenshot
                    // scrolls within its own band.
                    let text = p.promptTurn.map { MessageContent.stripNoise($0.bodyText) } ?? p.promptText
                    if !text.isEmpty || !p.promptImages.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    if !text.isEmpty {
                                        Text(MessageContent.clampHead(text))
                                            .font(.system(size: 13))
                                            .foregroundStyle(.primary)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .textSelection(.enabled)
                                    }
                                    Spacer(minLength: 4)
                                    if let ts = p.promptTurn?.timestamp {
                                        Text(Format.timeOrDate(ts))
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                if !p.promptImages.isEmpty { ImageTiles(images: p.promptImages) }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .background(Theme.accent.opacity(0.09),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .padding(10)
                        }
                        .frame(maxHeight: 200)
                        .fixedSize(horizontal: false, vertical: true)
                    }
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
                        .layoutPriority(1)
                    }
                }
            } else {
                Text("No transcript on disk yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .transaction { $0.animation = nil }
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
    /// The preview beside the palette: a child window, so it follows drags
    /// and sits at the same level, but is never key.
    private var previewPanel: NSPanel?
    private var model: PaletteModel?
    private var previewObserver: AnyCancellable?
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
        host.wantsLayer = true
        host.layerUsesCoreImageFilters = true
        let blur = CIFilter(name: "CIGaussianBlur")!
        blur.name = "blur"
        blur.setValue(0, forKey: kCIInputRadiusKey)
        host.layer?.filters = [blur]
        p.contentView = host
        place(p, rows: m.items.count)
        let pv = previewPanel ?? makePanel(key: false)
        previewPanel = pv
        let phost = NSHostingView(rootView: PalettePreviewWindowView(palette: m))
        phost.sizingOptions = []
        phost.wantsLayer = true
        phost.layerUsesCoreImageFilters = true
        let pblur = CIFilter(name: "CIGaussianBlur")!
        pblur.name = "blur"
        pblur.setValue(0, forKey: kCIInputRadiusKey)
        phost.layer?.filters = [pblur]
        pv.contentView = phost
        pv.setFrame(Self.previewFrame(beside: p.frame), display: false)
        pv.alphaValue = 0
        p.addChildWindow(pv, ordered: .below)
        observeSize(of: m, panel: p)
        observePreview(of: m, panel: pv)
        // Spotlight's entrance, measured frame by frame: fade and un-blur in
        // ~70 ms while the content springs from 105 % through a 1 % undershoot
        // to its size over ~230 ms. The window keeps its final frame so the
        // shadow lands where the panel does.
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        Self.animateBlur(host.layer, from: 14, to: 0, duration: 0.1)
        Self.springScale(host.layer, from: 1.05, to: 1, duration: 0.3)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
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
        previewObserver = nil
        guard let p = panel, p.isVisible else { return }
        if let pv = previewPanel {
            Self.animateBlur(pv.contentView?.layer, from: 0, to: 12, duration: 0.08)
            Self.springScale(pv.contentView?.layer, from: 1, to: 0.96, duration: 0.08, spring: false)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.08
                pv.animator().alphaValue = 0
            }, completionHandler: {
                p.removeChildWindow(pv)
                pv.orderOut(nil)
                pv.contentView = nil
            })
        }
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: p.frame.minX, y: p.frame.maxY)),
                                  forKey: Self.originKey)
        Self.animateBlur(p.contentView?.layer, from: 0, to: 12, duration: 0.08)
        Self.springScale(p.contentView?.layer, from: 1, to: 0.96, duration: 0.08, spring: false)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.08
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
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
        var keyable = true
        override var canBecomeKey: Bool { keyable }
        override var canBecomeMain: Bool { false }
    }

    /// Scales the content about its centre. `spring` gives the damped
    /// overshoot Spotlight shows on entrance; otherwise a plain ease-in.
    private static func springScale(_ layer: CALayer?, from: CGFloat, to: CGFloat,
                                    duration: Double, spring: Bool = true) {
        guard let layer else { return }
        let b = layer.bounds
        func t(_ k: CGFloat) -> CATransform3D {
            var m = CATransform3DMakeTranslation(b.midX, b.midY, 0)
            m = CATransform3DScale(m, k, k, 1)
            return CATransform3DTranslate(m, -b.midX, -b.midY, 0)
        }
        let a: CABasicAnimation
        if spring {
            let sp = CASpringAnimation(keyPath: "transform")
            sp.mass = 1; sp.stiffness = 380; sp.damping = 22; sp.initialVelocity = 0
            a = sp
        } else {
            a = CABasicAnimation(keyPath: "transform")
            a.timingFunction = CAMediaTimingFunction(name: .easeIn)
        }
        a.fromValue = t(from); a.toValue = t(to); a.duration = duration
        a.fillMode = .forwards; a.isRemovedOnCompletion = false
        layer.add(a, forKey: "scale")
    }

    private static func animateBlur(_ layer: CALayer?, from: CGFloat, to: CGFloat, duration: Double) {
        guard let layer else { return }
        let a = CABasicAnimation(keyPath: "filters.blur.inputRadius")
        a.fromValue = from; a.toValue = to; a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        a.fillMode = .forwards; a.isRemovedOnCompletion = false
        layer.add(a, forKey: "blur")
    }

    private static func size(rows: Int) -> NSSize {
        NSSize(width: PaletteView.listWidth + 2 * PaletteView.margin,
               height: PaletteView.height(forRows: rows) + 2 * PaletteView.margin)
    }
    private var sizeObserver: AnyCancellable?

    /// The preview window's frame: same top and height as the palette, its
    /// visible edge `gap` points left of the palette's (margins overlap).
    private static func previewFrame(beside f: NSRect) -> NSRect {
        let w = PaletteView.previewWidth + 2 * PaletteView.margin
        return NSRect(x: f.minX + 2 * PaletteView.margin - PaletteView.gap - w,
                      y: f.minY, width: w, height: f.height)
    }

    /// Fades the preview window in when there is something to show and out
    /// when the list is empty.
    private func observePreview(of m: PaletteModel, panel pv: NSPanel) {
        previewObserver = m.$previewID.map { $0 != nil }.removeDuplicates().sink { [weak pv] on in
            guard let pv else { return }
            if on { Self.animateBlur(pv.contentView?.layer, from: 10, to: 0, duration: 0.1) }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = on ? 0.12 : 0.08
                pv.animator().alphaValue = on ? 1 : 0
            }
        }
    }

    /// Grows and shrinks the panel with the result count, keeping its top edge.
    private func observeSize(of m: PaletteModel, panel p: NSPanel) {
        sizeObserver = m.$items.map(\.count).removeDuplicates().dropFirst().sink { [weak self, weak p] n in
            guard let p else { return }
            var f = p.frame
            let h = Self.size(rows: n).height
            f.origin.y += f.height - h
            f.size.height = h
            // ~270 ms with a 1 % overshoot, like Spotlight's result list.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.27
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 1.08, 0.35, 1.0)
                p.animator().setFrame(f, display: true)
                self?.previewPanel?.animator().setFrame(Self.previewFrame(beside: f), display: true)
            }
        }
    }

    private func makePanel(key: Bool = true) -> NSPanel {
        let p = Panel(contentRect: NSRect(origin: .zero, size: Self.size(rows: 0)),
                      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                      backing: .buffered, defer: false)
        p.keyable = key
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovableByWindowBackground = key
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        if key { p.delegate = self }
        return p
    }

    private func place(_ p: NSPanel, rows: Int) {
        let size = Self.size(rows: rows)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.visibleFrame
        // The remembered position is the panel's top-left corner, so growing
        // and shrinking keep the search field where the user left it.
        var top = NSPoint(x: f.midX - size.width / 2, y: f.maxY - f.height * 0.18 + PaletteView.margin)
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

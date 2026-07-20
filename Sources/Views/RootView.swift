import SwiftUI
import AppKit

struct RootView: View {
    @EnvironmentObject var model: AppModel

    // Live widths during a divider drag. Kept in local @State (NOT the model's
    // @Published widths) so a drag re-renders only RootView's layout — the heavy
    // SessionListView body isn't re-evaluated, only re-framed. Committed to the
    // model on drag end. nil = not dragging → fall back to the model's width.
    @State private var dragSidebar: CGFloat?
    @State private var dragList: CGFloat?
    @State private var dragOutline: CGFloat?

    private var sidebarW: CGFloat { dragSidebar ?? model.sidebarWidth }
    private var listW: CGFloat { dragList ?? model.listWidth }
    private var outlineW: CGFloat { dragOutline ?? model.outlineWidth }

    var body: some View {
        ZStack(alignment: .bottom) {
            if model.triageMode {
                TriageView()
                    .transition(.opacity)
            } else {
                GeometryReader { geo in
                    panes(available: geo.size.width)
                }
            }

            if let toast = model.toast {
                ToastView(text: toast)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let box = model.lightbox {
                LightboxView(box: box)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(100)
            }
        }
        .environment(\.uiScale, model.fontScale)
        .animation(.easeInOut(duration: 0.22), value: model.lightbox != nil)
        .animation(.easeInOut(duration: 0.2), value: model.sidebarCollapsed)
        .animation(.easeInOut(duration: 0.2), value: model.listCollapsed)
        .animation(.easeInOut(duration: 0.2), value: model.showOutline)
        .animation(.easeInOut(duration: 0.2), value: model.triageMode)
        .animation(.easeInOut(duration: 0.2), value: model.toast)
        .toolbar { MainToolbar() }
        .sheet(isPresented: $model.showHotkeyHelp) { HotkeyHelpView() }
        .sheet(item: $model.promptEdit) { edit in PromptEditView(edit: edit) }
        .environment(\.editPrompt, EditPromptAction { [weak model] in model?.beginEditPrompt(turnID: $0) })
        .environment(\.openLightbox, OpenLightboxAction { [weak model] item in model?.presentLightbox(item) })
        // Share-by-link progress/result. Dismissal while uploading is allowed —
        // the upload keeps running; only the sheet state is cleared on close.
        .sheet(isPresented: Binding(get: { model.shareState != nil },
                                    set: { if !$0 { model.shareState = nil } })) {
            ShareSheetView()
        }
        .background(ModalKeyMonitor(model: model))
    }

    /// Minimum width the conversation should keep before panes start folding.
    private let detailFloor: CGFloat = 360

    /// The three-column layout, with panes auto-folding as the window narrows:
    /// outline drops first, then the sidebar, then the session list — always
    /// leaving the conversation at least `detailFloor` wide. Manual collapse
    /// (⌘B / ⌘⇧L) still wins; this only hides panes when there isn't room.
    /// Decide which panes fit at a given width (outline → sidebar → list fold).
    private func visiblePanes(_ total: CGFloat) -> (sidebar: Bool, list: Bool, outline: Bool) {
        var showSidebar = !model.sidebarCollapsed
        var showList = !model.listCollapsed
        var showOutline = model.showOutline
        func used() -> CGFloat {
            (showSidebar ? sidebarW + 1 : 0)
            + (showList ? listW + 1 : 0)
            + (showOutline ? outlineW + 1 : 0)
        }
        if total - used() < detailFloor, showOutline { showOutline = false }
        if total - used() < detailFloor, showSidebar { showSidebar = false }
        if total - used() < detailFloor, showList { showList = false }
        return (showSidebar, showList, showOutline)
    }

    @ViewBuilder
    private func panes(available total: CGFloat) -> some View {
        let v = visiblePanes(total)
        let showSidebar = v.sidebar, showList = v.list, showOutline = v.outline
        HStack(spacing: 0) {
            if showSidebar {
                SidebarView().frame(width: sidebarW)
                    .debugFrame("sidebar", .red)
                ResizableDivider(width: sidebarW,
                                 onResize: { dragSidebar = model.clampSidebar($0) },
                                 onCommit: { if let w = dragSidebar { model.resizeSidebar(w); model.commitWidths() }; dragSidebar = nil })
            }
            if showList {
                SessionListView().frame(width: listW)
                    .debugFrame("list", .blue)
                ResizableDivider(width: listW,
                                 onResize: { dragList = model.clampList($0) },
                                 onCommit: { if let w = dragList { model.resizeList(w); model.commitWidths() }; dragList = nil })
            }
            DetailView()
                .frame(minWidth: 280, maxWidth: .infinity)
                .layoutPriority(1)
                .debugFrame("detail", .green)
            if showOutline {
                ResizableDivider(width: outlineW, invert: true,
                                 onResize: { dragOutline = model.clampOutline($0) },
                                 onCommit: { if let w = dragOutline { model.resizeOutline(w); model.commitWidths() }; dragOutline = nil })
                OutlineView().frame(width: outlineW)
                    .debugFrame("outline", .orange)
            }
        }
        .debugFrame("panes", .purple)
        .animation(.easeInOut(duration: 0.2), value: showSidebar)
        .animation(.easeInOut(duration: 0.2), value: showList)
        .animation(.easeInOut(duration: 0.2), value: showOutline)
    }
}

/// DEBUG: draws a labeled colored border with the live measured width, so we can
/// see which pane is refusing to shrink. Toggle with `DebugLayout.on`.
enum DebugLayout { static let on = false }

extension View {
    @ViewBuilder func debugFrame(_ label: String, _ color: Color) -> some View {
        if DebugLayout.on {
            self.overlay(alignment: .topLeading) {
                GeometryReader { g in
                    Text("\(label) \(Int(g.size.width))")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .background(color)
                        .allowsHitTesting(false)
                        .onChange(of: g.size.width) { _, w in
                            NSLog("SE-frame %@ = %.0f", label, w)
                        }
                        .onAppear { NSLog("SE-frame %@ = %.0f", label, g.size.width) }
                }
            }
            .border(color, width: 1)
        } else {
            self
        }
    }
}

/// A 1px divider with a wider invisible hit area that resizes the adjacent panel
/// by dragging. `width` is the panel's current width; `invert` is used for panels
/// that grow leftward (the outline) where the left edge is the handle.
private struct ResizableDivider: View {
    let width: CGFloat
    var invert: Bool = false
    let onResize: (CGFloat) -> Void
    var onCommit: () -> Void = {}

    @State private var startWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.10))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay(
                // Wider transparent grab strip with a resize cursor.
                Color.clear
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        // Measure in the window's coordinate space, NOT the
                        // divider's own: as the divider moves with the resized
                        // panel, a local translation would be re-measured against
                        // the shifted view and oscillate (step right, snap back).
                        // Anchor to the drag's start X in global space instead.
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if startWidth == nil { startWidth = width }
                                let base = startWidth ?? width
                                let dx = value.location.x - value.startLocation.x
                                let delta = invert ? -dx : dx
                                onResize(base + delta)
                            }
                            .onEnded { _ in startWidth = nil; onCommit() }
                    )
            )
            // No implicit animation on width — the drag should track 1:1, not lag.
            .transaction { $0.animation = nil }
    }
}

/// A minimal key monitor for layout-independent keys that can't live on the menu
/// bar: the triage screen's navigation (matched by physical keyCode, so they
/// work on any keyboard layout) and Esc. It never captures plain letters, so
/// typing in the list/search is never hijacked.
private struct ModalKeyMonitor: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.start(model: model)
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.stop() }

    final class Coordinator {
        private var monitor: Any?
        private weak var model: AppModel?

        // Physical key codes (US ANSI positions), layout-independent — these fire
        // the same regardless of the active keyboard layout (RU/EN/…).
        private enum Key {
            static let escape: UInt16 = 53
            static let rightArrow: UInt16 = 124
            static let leftArrow: UInt16 = 123
            static let upArrow: UInt16 = 126
            static let downArrow: UInt16 = 125
            static let returnKey: UInt16 = 36
            static let enter: UInt16 = 76      // numpad / fn-return
            static let x: UInt16 = 7
            static let lbracket: UInt16 = 33   // [
            static let rbracket: UInt16 = 30   // ]
            static let home: UInt16 = 115
            static let end: UInt16 = 119
            static let f: UInt16 = 3           // F
        }

        func start(model: AppModel) {
            self.model = model
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) == true ? nil : event }
            }
        }
        func stop() { if let m = monitor { NSEvent.removeMonitor(m); monitor = nil } }

        /// True while a text field / editable text view holds focus — bare keys
        /// must pass through so typing isn't hijacked.
        private func editing(_ event: NSEvent) -> Bool {
            guard let r = event.window?.firstResponder else { return false }
            if let tv = r as? NSTextView, tv.isEditable { return true }
            if r is NSTextField { return true }
            if let t = r as? NSText, t.isEditable { return true }
            return false
        }

        @MainActor private func handle(_ event: NSEvent) -> Bool {
            guard let model else { return false }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])

            // Image viewer grabs Esc / arrows while it's open, before anything else.
            if model.lightbox != nil, mods.isEmpty {
                switch event.keyCode {
                case Key.escape:     model.dismissLightbox(); return true
                case Key.leftArrow:  model.lightboxStep(-1);  return true
                case Key.rightArrow: model.lightboxStep(1);   return true
                default: break
                }
            }

            if model.triageMode {
                switch (event.keyCode, mods) {
                case (Key.x, [.option]):          model.triageResolve(); return true   // ⌥X
                case (Key.rightArrow, [.option]): model.triageSkip();    return true   // ⌥→
                case (Key.returnKey, [.command]), (Key.enter, [.command]):
                    model.triageAdvance(); return true                                 // ⌘↵
                case (Key.escape, []):            model.exitTriage();    return true   // Esc
                default: return false
                }
            }

            let isEditing = editing(event)

            // ⌘⌃F — toggle full screen. macOS didn't bind this to the menu item,
            // so wire it ourselves on the key window. Works in any mode/focus.
            if mods == [.control, .command], event.keyCode == Key.f {
                (event.window ?? NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
                return true
            }

            // ⌃⌘[ / ⌃⌘] — first / last reply. Work regardless of focus.
            if mods == [.control, .command] {
                if event.keyCode == Key.lbracket { model.jumpFirstTurn(); return true }
                if event.keyCode == Key.rbracket { model.jumpLastTurn();  return true }
            }

            // Bare [ / ] — previous / next reply. Layout-independent, and active
            // everywhere EXCEPT while editing a text field (so typing [ ] works).
            if mods.isEmpty, !isEditing {
                if event.keyCode == Key.lbracket { model.jumpTurn(-1); return true }
                if event.keyCode == Key.rbracket { model.jumpTurn(1);  return true }
                if event.keyCode == Key.home { model.jumpFirstTurn(); return true }
                if event.keyCode == Key.end  { model.jumpLastTurn();  return true }
                // ↑/↓ navigate replies WITHIN the session once the transcript is
                // focused; otherwise they fall through to the session list.
                if model.transcriptHasFocus {
                    if event.keyCode == Key.upArrow   { model.jumpTurn(-1); return true }
                    if event.keyCode == Key.downArrow { model.jumpTurn(1);  return true }
                }
                // Enter in the list → reveal the transcript + move focus into it.
                if event.keyCode == Key.returnKey || event.keyCode == Key.enter {
                    if model.selectedID != nil {
                        model.showOutline = true
                        model.focusTranscriptRequested = true
                        return true
                    }
                }
            }

            // Esc clears an active search (only when not editing — the field's own
            // clear handles that case).
            if event.keyCode == Key.escape, mods.isEmpty, !model.query.isEmpty, !isEditing {
                model.query = ""
                return true
            }

            // Kill NSTableView type-select: when the session list has focus and a
            // printable character is typed (no modifiers), the list would jump to
            // a row starting with that letter. Swallow it — searching is ⌘F.
            if mods.isEmpty, !isEditing, listHasFocus(event), isPrintable(event) {
                return true
            }
            return false
        }

        /// True if the first responder is the session-list table (or a subview).
        private func listHasFocus(_ event: NSEvent) -> Bool {
            var r = event.window?.firstResponder as? NSView
            while let v = r {
                if v is NSTableView { return true }
                r = v.superview
            }
            return false
        }

        /// A single printable character (letter/digit/punct), not a control key.
        private func isPrintable(_ event: NSEvent) -> Bool {
            guard let s = event.charactersIgnoringModifiers, let c = s.unicodeScalars.first
            else { return false }
            return !CharacterSet.controlCharacters.contains(c)
                && !CharacterSet.whitespacesAndNewlines.contains(c)
        }
    }
}

/// Intercepts ⌘-scroll over the conversation to drive text zoom.
struct CommandScrollZoom: NSViewRepresentable {
    let onZoom: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = ScrollCatcher()
        v.onZoom = onZoom
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ScrollCatcher)?.onZoom = onZoom
    }

    final class ScrollCatcher: NSView {
        var onZoom: ((CGFloat) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self, self.window != nil,
                          event.modifierFlags.contains(.command) else { return event }
                    let dy = event.scrollingDeltaY
                    if dy != 0 { MainActor.assumeIsolated { self.onZoom?(dy) } ; return nil }
                    return event
                }
            }
        }
        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
}

struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(.black.opacity(0.82), in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }
}

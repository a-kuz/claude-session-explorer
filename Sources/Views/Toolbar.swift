import SwiftUI

/// Native NSToolbar: sidebar toggle (leading), search field (principal), and the
/// outline toggle (trailing). The session title is NOT here — it lives in the
/// detail pane as plain text with no background.
struct MainToolbar: ToolbarContent {
    @EnvironmentObject var model: AppModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.sidebarCollapsed.toggle() } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Sidebar (⌘B)")
        }

        if !model.triageMode {
            // Flexible spacer pushes the search + outline toggle to the trailing
            // edge so the search field never slides left and fuses with the
            // leading sidebar button.
            ToolbarItem(placement: .primaryAction) { Spacer() }
            ToolbarItem(placement: .primaryAction) {
                ToolbarSearchField().environmentObject(model)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.showOutline.toggle() } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("Outline (⌘⇧B)")
            }
        }
    }
}

/// Shows the current session's title as the NATIVE window title (exactly where
/// "Session Explorer" used to sit, leading next to the traffic lights — no
/// background). Also ensures full-screen is allowed.
struct WindowChrome: NSViewRepresentable {
    var title: String

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { configure(v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }
    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        let mn = NSSize(width: 420, height: 360)
        window.minSize = mn
        window.contentMinSize = mn
        // The unified toolbar otherwise imposes its own (large) minimum width.
        // Don't let it dictate the window's minimum.
        window.toolbar?.sizeMode = .small
        // The centered title area sizes to the (long) title string and locks the
        // window's minimum width. Hide it; the session name is shown as a
        // truncating heading inside the detail pane instead.
        window.titleVisibility = .hidden
        window.title = title   // kept for Mission Control / window menu only
        window.collectionBehavior.insert(.fullScreenPrimary)
    }
}

/// A trailing search field: narrow at rest, grows when focused. Owns its focus.
struct ToolbarSearchField: View {
    @EnvironmentObject var model: AppModel
    @State private var focused = false

    private var active: Bool { focused || !model.query.isEmpty }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(focused ? Theme.accent : Theme.secondaryText)
                .onTapGesture { model.focusSearchRequested = true }
            // AppKit-backed field: becomes first responder reliably on ⌘F (the
            // SwiftUI @FocusState in a toolbar item is flaky), and reports focus.
            FocusableTextField(
                text: $model.query,
                focusRequest: $model.focusSearchRequested,
                onFocusChange: { f in
                    focused = f
                    model.searchFieldFocused = f
                },
                onSubmit: { model.nextMatch(1) }
            )
            .frame(height: 18)
            .frame(maxWidth: .infinity)
            if active, !model.query.isEmpty {
                if model.searching {
                    ClaudeBurstView(options: .init(zoom: 1.5))
                        .frame(width: 20, height: 20)
                }
                // In-conversation match counter "N/total" + prev/next chevrons,
                // mirroring the mock. Falls back to the session hit count when no
                // match is active in the open conversation.
                if model.matchCount > 0 {
                    HStack(spacing: 1) {
                        Text("\(model.matchIndex + 1)").foregroundStyle(Theme.secondaryText)
                        Text("/\(model.matchCount)").foregroundStyle(Theme.tertiaryText)
                    }
                    .font(.system(size: 11)).monospacedDigit()
                    HStack(spacing: 1) {
                        Button { model.nextMatch(-1) } label: {
                            Image(systemName: "chevron.up").font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.secondary)
                        .help("Previous match (⌘⇧G)")
                        Button { model.nextMatch(1) } label: {
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain).foregroundStyle(Color.secondary)
                        .help("Next match (⌘G)")
                    }
                } else {
                    Text("\(model.hits.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                }
                Button { model.query = ""; model.focusSearchRequested = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        // Thin accent underline on focus. Transparent insets on both sides keep
        // the line clear of the magnifier (left) and the item edge (right).
        .overlay(alignment: .bottom) {
            HStack(spacing: 0) {
                Rectangle().fill(Color.clear).frame(width: 28, height: 1.5)
                Rectangle()
                    .fill(focused ? Theme.accent : Color.clear)
                    .frame(height: 1.5)
                Rectangle().fill(Color.clear).frame(width: 8, height: 1.5)
            }
        }
        // Narrow at rest, grows smoothly when focused (or while a query is set).
        .frame(width: active ? 360 : 220)
        .animation(.easeOut(duration: 0.22), value: active)
    }
}

/// An NSTextField wrapped for SwiftUI that can be focused on demand (set
/// `focusRequest` true) and reports focus changes. Plain, borderless, no
/// placeholder — styling comes from the SwiftUI container.
struct FocusableTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focusRequest: Bool
    var onFocusChange: (Bool) -> Void
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> FocusReportingTextField {
        let tf = FocusReportingTextField()
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = .systemFont(ofSize: 13)
        tf.lineBreakMode = .byTruncatingTail
        tf.cell?.usesSingleLineMode = true
        tf.delegate = context.coordinator
        tf.onFocusChange = onFocusChange
        return tf
    }

    func updateNSView(_ tf: FocusReportingTextField, context: Context) {
        if tf.stringValue != text { tf.stringValue = text }
        if focusRequest {
            DispatchQueue.main.async {
                tf.window?.makeFirstResponder(tf)
                focusRequest = false
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: FocusableTextField
        init(_ p: FocusableTextField) { parent = p }
        func controlTextDidChange(_ note: Notification) {
            if let tf = note.object as? NSTextField { parent.text = tf.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) { parent.onSubmit(); return true }
            return false
        }
    }
}

/// NSTextField that reports first-responder changes (for the widen-on-focus UI).
final class FocusReportingTextField: NSTextField {
    var onFocusChange: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder(); if ok { onFocusChange?(true) }; return ok
    }
    // The field editor resigns on blur; observe via the window's first responder.
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}

// Keyboard shortcuts wired through the menu bar (so they work app-wide).
// Mirrors the TUI keymap: navigation, search, open-in-terminal, panel toggles, match/turn nav.

import SwiftUI

struct AppCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        // Replace the default "New" group with our navigation commands.
        CommandGroup(replacing: .newItem) {}

        // Search lives in the standard Find menu slot (⌘F).
        CommandGroup(after: .textEditing) {
            Button("Find") { model.focusSearchRequested = true }
                .keyboardShortcut("f", modifiers: [.command])
        }

        // Keyboard cheat sheet in the Help menu (⌘⇧/).
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { model.showHotkeyHelp.toggle() }
                .keyboardShortcut("/", modifiers: [.command, .shift])
        }

        CommandMenu("Session") {
            Button("Open in Terminal") { model.openInTerminal() }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.selectedMeta == nil)
            Button("Copy Resume Command") { model.copyResume() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.selectedMeta == nil)
            Button(model.copySessionsLabel) { model.copySelectedSessions() }
                .keyboardShortcut("c", modifiers: [.command])
                .disabled(model.selectedMeta == nil)
            Button("Reveal in Finder") { model.revealInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.selectedMeta == nil)
            Divider()
            Button("Hide Session") { if let id = model.selectedID { model.hideSession(id) } }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(model.selectedMeta == nil)
            Button("Unhide Last (Undo)") { model.unhideLast() }
                .keyboardShortcut("z", modifiers: [.control])
            Divider()
            Button(model.selectedMeta.map { model.isFavorite($0.id) } == true
                   ? "Remove from Favorites" : "Add to Favorites") {
                if let id = model.selectedID { model.toggleFavorite(id) }
            }
            .keyboardShortcut("d", modifiers: [.command])
            .disabled(model.selectedMeta == nil)
        }

        CommandMenu("Navigation") {
            Button("Next Session") { model.selectNext(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command])
            Button("Previous Session") { model.selectNext(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command])
            Divider()
            Button("Next Match") { model.nextMatch(1) }
                .keyboardShortcut("g", modifiers: [.command])
                .disabled(model.matchCount == 0)
            Button("Previous Match") { model.nextMatch(-1) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(model.matchCount == 0)
            Divider()
            Button("Next Turn") { model.jumpTurn(1) }
                .keyboardShortcut("]", modifiers: [.command])
            Button("Previous Turn") { model.jumpTurn(-1) }
                .keyboardShortcut("[", modifiers: [.command])
        }

        CommandGroup(after: .sidebar) {
            Button(model.briefMode ? "Full View" : "Brief") {
                model.briefMode.toggle()
            }
            .keyboardShortcut("e", modifiers: [.command])
            Button(model.groupForks
                   ? "Ungroup Session Branches"
                   : "Group Session Branches") {
                model.groupForks.toggle()
            }
            Menu("Branches in Dialog") {
                ForEach(BranchMode.allCases) { mode in
                    Button {
                        model.branchMode = mode
                    } label: {
                        Text((model.branchMode == mode ? "✓ " : "   ") + mode.label)
                    }
                }
            }
            Divider()
            Button(model.sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar") {
                model.sidebarCollapsed.toggle()
            }
            .keyboardShortcut("b", modifiers: [.command])
            Button(model.listCollapsed ? "Show Session List" : "Hide Session List") {
                model.listCollapsed.toggle()
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            Button(model.showOutline ? "Hide Outline" : "Show Outline") {
                model.showOutline.toggle()
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            Divider()
            Button("Increase Text Size") { model.zoom(0.1) }
                .keyboardShortcut("+", modifiers: [.command])
            Button("Decrease Text Size") { model.zoom(-0.1) }
                .keyboardShortcut("-", modifiers: [.command])
            Button("Reset Zoom") { model.setZoom(1.0) }
                .keyboardShortcut("0", modifiers: [.command])
            Divider()
            Button("More Spacing") { model.setAir(model.air + 4) }
                .keyboardShortcut("=", modifiers: [.command, .shift])
            Button("Less Spacing") { model.setAir(model.air - 4) }
                .keyboardShortcut("-", modifiers: [.command, .shift])
        }

        CommandMenu("Replies") {
            Button("Reply to All in Turn") { model.enterTriage() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(model.attentionCount == 0)
        }
    }
}

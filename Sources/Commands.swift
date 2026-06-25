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
            Button("Найти") { model.focusSearchRequested = true }
                .keyboardShortcut("f", modifiers: [.command])
        }

        // Keyboard cheat sheet in the Help menu (⌘⇧/).
        CommandGroup(replacing: .help) {
            Button("Сочетания клавиш") { model.showHotkeyHelp.toggle() }
                .keyboardShortcut("/", modifiers: [.command, .shift])
        }

        CommandMenu("Сессия") {
            Button("Открыть в Ghostty") { model.openInTerminal() }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.selectedMeta == nil)
            Button("Скопировать resume") { model.copyResume() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.selectedMeta == nil)
            Button("Показать в Finder") { model.revealInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.selectedMeta == nil)
            Divider()
            Button("Скрыть сессию") { if let id = model.selectedID { model.hideSession(id) } }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(model.selectedMeta == nil)
            Button("Вернуть скрытую (отмена)") { model.unhideLast() }
                .keyboardShortcut("z", modifiers: [.control])
            Divider()
            Button(model.selectedMeta.map { model.isFavorite($0.id) } == true
                   ? "Убрать из избранного" : "В избранное") {
                if let id = model.selectedID { model.toggleFavorite(id) }
            }
            .keyboardShortcut("d", modifiers: [.command])
            .disabled(model.selectedMeta == nil)
        }

        CommandMenu("Навигация") {
            Button("Следующая сессия") { model.selectNext(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command])
            Button("Предыдущая сессия") { model.selectNext(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command])
            Divider()
            Button("Следующее совпадение") { model.nextMatch(1) }
                .keyboardShortcut("g", modifiers: [.command])
                .disabled(model.matchCount == 0)
            Button("Предыдущее совпадение") { model.nextMatch(-1) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(model.matchCount == 0)
            Divider()
            Button("Следующая реплика") { model.jumpTurn(1) }
                .keyboardShortcut("]", modifiers: [.command])
            Button("Предыдущая реплика") { model.jumpTurn(-1) }
                .keyboardShortcut("[", modifiers: [.command])
        }

        CommandMenu("Вид") {
            Button(model.briefMode ? "Полный режим" : "Кратко") {
                model.briefMode.toggle()
            }
            .keyboardShortcut("e", modifiers: [.command])
            Button(model.groupForks
                   ? "Не группировать ветки сессий"
                   : "Группировать ветки сессий") {
                model.groupForks.toggle()
            }
            Menu("Ветки в диалоге") {
                ForEach(BranchMode.allCases) { mode in
                    Button {
                        model.branchMode = mode
                    } label: {
                        Text((model.branchMode == mode ? "✓ " : "   ") + mode.label)
                    }
                }
            }
            Divider()
            Button(model.sidebarCollapsed ? "Показать боковую панель" : "Скрыть боковую панель") {
                model.sidebarCollapsed.toggle()
            }
            .keyboardShortcut("b", modifiers: [.command])
            Button(model.listCollapsed ? "Показать список сессий" : "Скрыть список сессий") {
                model.listCollapsed.toggle()
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            Button(model.showOutline ? "Скрыть содержание" : "Показать содержание") {
                model.showOutline.toggle()
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            Divider()
            Button("Увеличить текст") { model.zoom(0.1) }
                .keyboardShortcut("+", modifiers: [.command])
            Button("Уменьшить текст") { model.zoom(-0.1) }
                .keyboardShortcut("-", modifiers: [.command])
            Button("Сбросить масштаб") { model.setZoom(1.0) }
                .keyboardShortcut("0", modifiers: [.command])
            Divider()
            Button("Больше воздуха") { model.setAir(model.air + 4) }
                .keyboardShortcut("=", modifiers: [.command, .shift])
            Button("Меньше воздуха") { model.setAir(model.air - 4) }
                .keyboardShortcut("-", modifiers: [.command, .shift])
        }

        CommandMenu("Ответы") {
            Button("Ответить всем поочерёдно") { model.enterTriage() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(model.attentionCount == 0)
        }
    }
}

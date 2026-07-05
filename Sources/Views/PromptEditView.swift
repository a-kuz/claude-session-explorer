// Edit sheet for a user prompt + the environment action that opens it.

import SwiftUI

/// Environment action "open the prompt editor for this turn id". Passed through
/// the environment (not @EnvironmentObject) so TurnView doesn't subscribe to the
/// whole AppModel; always-equal Equatable keeps it from invalidating turn views.
struct EditPromptAction: Equatable {
    var action: (String) -> Void = { _ in }
    func callAsFunction(_ turnID: String) { action(turnID) }
    static func == (l: Self, r: Self) -> Bool { true }
}

private struct EditPromptKey: EnvironmentKey {
    static let defaultValue = EditPromptAction()
}

extension EnvironmentValues {
    var editPrompt: EditPromptAction {
        get { self[EditPromptKey.self] }
        set { self[EditPromptKey.self] = newValue }
    }
}

/// The modal editor: raw stored text of the prompt record, saved back into the
/// session jsonl on confirm.
struct PromptEditView: View {
    @EnvironmentObject var model: AppModel
    let edit: AppModel.PromptEdit
    @State private var text: String

    init(edit: AppModel.PromptEdit) {
        self.edit = edit
        _text = State(initialValue: edit.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Prompt")
                .font(.system(size: 15, weight: .semibold))
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Theme.codeBg, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .frame(minWidth: 560, minHeight: 240)
            Text("Saving rewrites this record in the session jsonl. A session currently running in the CLI won't pick the change up.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
            HStack {
                Spacer()
                Button("Cancel") { model.promptEdit = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { model.savePromptEdit(uuid: edit.uuid, newText: text) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(text == edit.text
                              || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }
}

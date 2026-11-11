import AppKit
import MuseCore

/// Whether the person is typing: the key window's first responder is a text view (Claude chat's composer, a caption
/// being edited) or a text field's field editor (also an NSTextView). Editor shortcuts stay off while this is true.
@MainActor
enum TextInputFocus {
    static var isTyping: Bool {
        guard let r = (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder else { return false }
        if let tv = r as? NSTextView { return tv.isEditable || tv.isFieldEditor }
        return r is NSTextField
    }
}

/// Carries out an EditShortcuts action on the open edit.
@MainActor
enum EditShortcutRunner {
    static func run(_ action: EditShortcuts.Action, _ session: EditSuiteSession) {
        switch action {
        case .togglePlay: session.togglePlay()
        case .step(let d): session.step(d)
        case .deleteSelected: session.edit { $0.deleteSelected() }
        case .split: session.edit { $0.split() }
        case .shuttle(let d): session.shuttleStep(d)
        case .undo: session.undo()
        case .redo: session.redo()
        }
    }

    /// ⌘Z / ⇧⌘Z from the timeline's buttons: while typing they undo the text instead of the edit.
    static func undoRedo(_ redo: Bool, _ session: EditSuiteSession) {
        guard EditShortcuts.action(for: redo ? .redo : .undo, typing: TextInputFocus.isTyping, timeline: true) != nil else {
            NSApp.sendAction(redo ? Selector(("redo:")) : Selector(("undo:")), to: nil, from: nil)
            return
        }
        if redo { session.redo() } else { session.undo() }
    }
}

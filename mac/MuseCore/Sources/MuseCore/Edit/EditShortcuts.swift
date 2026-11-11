import Foundation

/// The Edit page's single-key shortcuts (space, arrows, Delete, S, J/K/L, ⌘Z), as one table the view asks.
///
/// Owner bug 2026-11-11: typing in the Claude chat inside Edit set off things on the edit page (space played, Delete
/// removed the clip, "s" split). The shortcuts sit on the whole page, so they fired while a text box had the cursor.
/// Rule: while the person is typing anywhere (chat, captions, a name field), no shortcut runs and the key goes to the
/// text box. `typing` is decided by the app (the key window's first responder is a text view or field editor).
public enum EditShortcuts {
    public enum Key: Equatable {
        case space, left, right, delete, deleteForward
        case character(String)
        case undo, redo
    }

    public enum Action: Equatable {
        case togglePlay
        case step(Int)
        case deleteSelected
        case split
        case shuttle(Int)
        case undo, redo
    }

    /// The action for a key press, or nil to leave the key alone (it then reaches the text box or the system).
    /// - Parameters:
    ///   - typing: a text input has keyboard focus.
    ///   - timeline: the editor is in timeline mode (Delete removes the selection only there).
    ///   - plainModifiers: no ⌘, ⌃ or ⌥ held (letter shortcuts only fire bare).
    public static func action(for key: Key, typing: Bool, timeline: Bool, plainModifiers: Bool = true) -> Action? {
        if typing { return nil }
        switch key {
        case .space: return .togglePlay
        case .left: return .step(-1)
        case .right: return .step(1)
        case .delete, .deleteForward: return timeline ? .deleteSelected : nil
        case .undo: return .undo
        case .redo: return .redo
        case .character(let c):
            guard plainModifiers else { return nil }
            switch c.lowercased() {
            case "s": return .split
            case "j": return .shuttle(-1)
            case "k": return .shuttle(0)
            case "l": return .shuttle(1)
            default: return nil
            }
        }
    }
}

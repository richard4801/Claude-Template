import Foundation

/// Copy helpers for the restyled screens (plans/design-direction.md §7): one short meta line per item, counted nouns,
/// and confirmations that name the action.
public enum ScreenCopy {
    /// At most `limit` non-empty parts joined by " · " (never a chain of four or more).
    public static func meta(_ parts: [String?], limit: Int = 3) -> String {
        let kept = parts.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return kept.prefix(max(1, min(limit, 3))).joined(separator: " · ")
    }

    /// "1 take", "3 takes", "0 takes". `plural` defaults to the noun plus "s".
    public static func count(_ n: Int, _ noun: String, plural: String? = nil) -> String {
        "\(n) \(n == 1 ? noun : (plural ?? noun + "s"))"
    }

    /// A confirmation that names the action: ("Delete 3 takes?", "Delete takes").
    public static func confirm(_ verb: String, _ n: Int, _ noun: String, plural: String? = nil) -> (title: String, button: String) {
        let many = plural ?? noun + "s"
        let title = n == 1 ? "\(verb) this \(noun)?" : "\(verb) \(n) \(many)?"
        return (title, "\(verb) \(n == 1 ? noun : many)")
    }

    /// The last-resort error line, with "you weren't charged" when that's true.
    public static func failure(_ what: String, charged: Bool) -> String {
        let base = what.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = base.isEmpty ? "Something went wrong" : base
        return charged ? line : "\(line) · you weren't charged"
    }
}

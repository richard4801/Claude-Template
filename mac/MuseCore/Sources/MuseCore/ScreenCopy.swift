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

    /// The last-resort error line, with "you weren't charged" when that's true, said once: the server's own failure
    /// lines often already say it ("… · you weren't charged"), and the Queue showed it twice (owner bug 2026-11-11).
    public static func failure(_ what: String, charged: Bool) -> String {
        let base = what.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = base.isEmpty ? "Something went wrong" : base
        if charged || line.lowercased().contains("charged") { return line }
        return "\(line) · you weren't charged"
    }

    /// The price on a failed job's Retry: what the server held for this same request (`cost`; the refund doesn't change
    /// it), so the button says what the retry will charge. Retrying is never free: the failed run was refunded, and the
    /// retry is a new run at the same price. Falls back to the local estimate for jobs without a server price.
    public static func retryLabel(cost: Double, estimate: Double) -> String {
        "Retry · \(Pricing.money(cost > 0 ? cost : estimate))"
    }
}

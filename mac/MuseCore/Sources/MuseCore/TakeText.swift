import Foundation

/// How a take's stored title reads on screen. Photoshoot became the Photo tool (plans/design-direction.md), but takes the
/// server stored earlier keep their titles ("Shoot · crystal", "Photoshoot"). Everything that shows a take's title or label
/// goes through here so they all read "Photo".
public enum TakeText {
    private static let oldNames = ["Photoshoot", "Shoot"]

    /// "Shoot · crystal" → "Photo · crystal", "Shoot" / "Photoshoot" → "Photo". Anything else is unchanged.
    public static func displayTitle(_ title: String) -> String {
        for old in oldNames {
            if title == old { return "Photo" }
            if title.hasPrefix(old + " ·") { return "Photo" + title.dropFirst(old.count) }
        }
        return title
    }
}

extension Take {
    /// `title` as it reads on screen (`TakeText.displayTitle`).
    public var displayTitle: String { TakeText.displayTitle(title) }
}

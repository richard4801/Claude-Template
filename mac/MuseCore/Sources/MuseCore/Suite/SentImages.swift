import Foundation

// Images sent (server images/sent.ts, owner 2026-11-11): every estimate says which images go to the model, in order, each
// with its role and why MUSE picked it, and whether Claude or the person changed the list. The composer shows them as
// "Images sent (n)" with "Changed by Claude" and "Reset to automatic".

/// One image a generation sends.
public struct SentImage: Codable, Hashable, Sendable {
    public var image: ImageRef
    /// person | outfit | product | location | style | pose | other
    public var role: String
    public var label: String
    public var why: String

    public init(image: ImageRef, role: String, label: String, why: String = "") {
        self.image = image
        self.role = role
        self.label = label
        self.why = why
    }

    enum CodingKeys: String, CodingKey { case image, role, label, why }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        image = try c.decode(ImageRef.self, forKey: .image)
        role = c.v(.role, "other")
        label = c.v(.label, "")
        why = c.v(.why, "")
    }

    /// The caption under its thumbnail: the label, else the role in words.
    public var caption: String {
        let l = label.trimmingCharacters(in: .whitespaces)
        if !l.isEmpty { return l.prefix(1).uppercased() + l.dropFirst() }
        return SentImage.roleWords[role] ?? "Reference"
    }
    public static let roleWords = ["person": "Her", "outfit": "Outfit", "product": "Product", "location": "Location", "style": "Style", "pose": "Pose", "other": "Reference"]
}

/// What an estimate returns as `sentImages`.
public struct SentImages: Codable, Hashable, Sendable {
    public var images: [SentImage]
    /// Different from MUSE's own pick.
    public var changed: Bool
    /// "claude" | "person" when changed.
    public var changedBy: String?
    /// The most the model takes.
    public var max: Int?

    public init(images: [SentImage] = [], changed: Bool = false, changedBy: String? = nil, max: Int? = nil) {
        self.images = images
        self.changed = changed
        self.changedBy = changedBy
        self.max = max
    }

    enum CodingKeys: String, CodingKey { case images, changed, changedBy, max }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        images = c.v(.images, [])
        changed = c.v(.changed, false)
        changedBy = c.o(.changedBy)
        max = c.o(.max)
    }

    public var byClaude: Bool { changed && changedBy == "claude" }
    /// "Images sent (3)".
    public var title: String { "Images sent (\(images.count))" }
    /// "Changed by Claude" / "Changed by you", nil when automatic.
    public var tag: String? { changed ? (byClaude ? "Changed by Claude" : "Changed by you") : nil }
}

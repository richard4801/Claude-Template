import Foundation

/// `POST /v1/outfits/{id}/fill`: the outfit as it is now and the estimate held for its missing angles.
public struct OutfitFill: Codable, Sendable {
    public var outfit: Outfit
    public var cost: Double
    public init(outfit: Outfit, cost: Double) { self.outfit = outfit; self.cost = cost }
}

/// The outfit section's folders (plans/outfit-head-looks.md §4): newest first, 8 per page, "‹ 1 of 3 ›".
public enum OutfitPages {
    public static let perPage = 8

    /// Newest first (an outfit without a date keeps its list order, after the dated ones of the same age).
    public static func newestFirst(_ list: [Outfit]) -> [Outfit] {
        list.enumerated().sorted { a, b in
            let x = a.element.createdAt ?? 0, y = b.element.createdAt ?? 0
            return x != y ? x > y : a.offset > b.offset
        }.map(\.element)
    }

    /// At least one page, so the pager reads "1 of 1" (and is hidden) when there are none.
    public static func count(_ items: Int, perPage: Int = perPage) -> Int { max(1, (items + perPage - 1) / perPage) }

    /// A page that no longer exists (the last page emptied by a delete) steps back to the last one.
    public static func clamp(_ page: Int, items: Int, perPage: Int = perPage) -> Int { min(max(0, page), count(items, perPage: perPage) - 1) }

    /// The items on one page (0-based); later pages refill it after a delete.
    public static func slice<T>(_ items: [T], page: Int, perPage: Int = perPage) -> [T] {
        let p = clamp(page, items: items.count, perPage: perPage)
        return Array(items.dropFirst(p * perPage).prefix(perPage))
    }

    /// The pager text: "1 of 3".
    public static func label(_ page: Int, items: Int, perPage: Int = perPage) -> String {
        "\(clamp(page, items: items, perPage: perPage) + 1) of \(count(items, perPage: perPage))"
    }
}

/// A name for a new outfit before it is added (§5): what was typed, else the product photo's file name, else
/// "Outfit · 11 Nov". Never "Product look" or "My set".
public enum OutfitNaming {
    public static let maxLength = 80

    public static func suggestion(description: String, fileName: String?, date: Date = Date()) -> String {
        let typed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return clip(typed.prefix(1).uppercased() + typed.dropFirst()) }
        if let f = fileName.map(cleanFileName), !f.isEmpty { return clip(f) }
        return "Outfit · " + dayMonth(date)
    }

    /// "green_halter-set.final.JPG" → "Green halter set final"; camera names like "IMG_2041" give nothing.
    static func cleanFileName(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let words = base.replacingOccurrences(of: "[_\\-.]+", with: " ", options: .regularExpression)
            .split(separator: " ").map(String.init)
        let camera: Set<String> = ["img", "dsc", "image", "photo", "screenshot", "pxl"]
        if words.allSatisfy({ $0.allSatisfy(\.isNumber) || camera.contains($0.lowercased()) }) { return "" }
        let joined = words.joined(separator: " ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    public static func dayMonth(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f.string(from: date)
    }

    /// The folder's date line: "11 Nov" this year, "11 Nov 2025" before.
    public static func folderDate(_ ms: Int64?, now: Date = Date()) -> String? {
        guard let ms, ms > 0 else { return nil }
        let d = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let cal = Calendar.current
        if cal.component(.year, from: d) == cal.component(.year, from: now) { return dayMonth(d) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        return f.string(from: d)
    }

    static func clip(_ s: String) -> String { String(s.prefix(maxLength)).trimmingCharacters(in: .whitespaces) }
}

/// Which pieces of her base photos an outfit keeps (plans/outfit-head-looks.md §6).
public struct OutfitKeep: Codable, Hashable, Sendable {
    public var top = false
    public var bottom = false
    public var shoes = false
    public var accessories = false
    public init(top: Bool = false, bottom: Bool = false, shoes: Bool = false, accessories: Bool = false) {
        self.top = top; self.bottom = bottom; self.shoes = shoes; self.accessories = accessories
    }

    static let names = ["top", "bottom", "shoes", "accessories"]
    var flags: [Bool] { [top, bottom, shoes, accessories] }
}

/// A base set's chosen angles (nil = the set's own; a missing one uses the front).
public struct OutfitBaseAngles: Codable, Hashable, Sendable {
    public var front: ImageRef?
    public var tq: ImageRef?
    public var side: ImageRef?
    public var back: ImageRef?
    public init() {}
    public static let keys = ["front", "tq", "side", "back"]
    public subscript(i: Int) -> ImageRef? {
        get { [front, tq, side, back][i] }
        set { switch i { case 0: front = newValue; case 1: tq = newValue; case 2: side = newValue; default: back = newValue } }
    }
    public var isEmpty: Bool { front == nil && tq == nil && side == nil && back == nil }
}

/// `POST /v1/outfits` `base`: start from her base photos (her profile photos, or one of her outfits), with single angles
/// swapped, keeping the ticked pieces and the note.
public struct OutfitBase: Codable, Hashable, Sendable {
    /// "base" (her profile body photos) or "outfit" (one of her outfits as the base set).
    public var source = "base"
    public var outfitId: String?
    public var angles: OutfitBaseAngles?
    public var keep: OutfitKeep
    public var note: String?
    public init(keep: OutfitKeep, note: String?, outfitId: String? = nil, angles: OutfitBaseAngles? = nil) {
        self.source = outfitId == nil ? "base" : "outfit"
        self.outfitId = outfitId
        self.angles = (angles?.isEmpty ?? true) ? nil : angles
        self.keep = keep
        let n = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.note = n.isEmpty ? nil : n
    }

    /// Anything kept: a tick or a note (else the outfit is made as before).
    public var keeping: Bool { keep.flags.contains(true) || note != nil }

    /// The sheet's preview line: "Keeps the top (the black lace bra). Changes the bottom, the shoes and the accessories."
    public var summary: String {
        let kept = zip(OutfitKeep.names, keep.flags).filter { $0.1 }.map { "the \($0.0)" }
        let rest = zip(OutfitKeep.names, keep.flags).filter { !$0.1 }.map { "the \($0.0)" }
        var k = Self.and(kept)
        if let note { k = k.isEmpty ? note : "\(k) (\(note))" }
        guard !k.isEmpty else { return "Tick what to keep from her base photos." }
        return "Keeps \(k). Changes \(rest.isEmpty ? "the rest" : Self.and(rest))."
    }

    static func and(_ xs: [String]) -> String {
        xs.count <= 1 ? xs.joined() : xs.dropLast().joined(separator: ", ") + " and " + xs.last!
    }
}

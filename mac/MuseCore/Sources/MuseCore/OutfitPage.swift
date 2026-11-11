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

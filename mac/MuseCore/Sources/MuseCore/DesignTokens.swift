import Foundation

/// The design-direction tokens as plain values (plans/design-direction.md §2–§4), shared by the app's theme
/// (Muse/Theme/DesignRoles.swift) and the contrast tests. Colours are 0xRRGGBB. Android keeps the same values in
/// android/core/…/DesignTokens.kt.
public enum DesignTokens {
    /// One colour per role; the roles are the same in all four themes (§2).
    public struct RoleSet: Equatable, Sendable {
        public let canvas, raised, field, ink, ink2, hairline: UInt32
        /// The selection mark and focus ring. In Creator Pop it is a fill only (pink under ink text).
        public let accent: UInt32
        /// Text links: the accent where it reads as text, Creator Pop's cobalt otherwise.
        public let link: UInt32
        public let action, onAction: UInt32
        public let positive, caution, danger: UInt32
        /// The outline that marks the current selection: accent, except Creator Pop's ink.
        public let selection: UInt32
    }

    /// container > control > chip (§4). 999 = fully round.
    public struct Radii: Equatable, Sendable { public let container, control, chip: Double }
    /// The one `float` shadow (§4): y offset and blur in pt, colour = the theme's ink at `alpha`.
    public struct Float: Equatable, Sendable { public let y, blur, alpha: Double }
    /// One step of the type scale (§3).
    public struct Step: Equatable, Sendable { public let size, lineHeight: Double; public let weight: Int }
    /// Two families per theme (§3): display for titles only, text for everything else.
    public struct Families: Equatable, Sendable { public let display, text: String }

    public static let themes = ["a", "b", "c", "d"]

    public static func roles(_ theme: String) -> RoleSet {
        switch theme {
        case "a": return RoleSet(canvas: 0xEFEBE3, raised: 0xF8F5EF, field: 0xE7E1D6, ink: 0x141210, ink2: 0x67605A, hairline: 0xCFC7BA, accent: 0xB5121B,
                                 link: 0xB5121B, action: 0x141210, onAction: 0xF8F5EF, positive: 0x2F6B3A, caution: 0x8A5200, danger: 0xB5121B, selection: 0xB5121B)
        case "b": return RoleSet(canvas: 0x0D0E0F, raised: 0x17191B, field: 0x212427, ink: 0xECEAE5, ink2: 0xA9A6A0, hairline: 0x2C3033, accent: 0xF2A93B,
                                 link: 0xF2A93B, action: 0xF2A93B, onAction: 0x1A1205, positive: 0x7BD88F, caution: 0xF2C14E, danger: 0xFF6B5E, selection: 0xF2A93B)
        case "c": return RoleSet(canvas: 0xE7E2D9, raised: 0xF3F0EA, field: 0xEAE5DC, ink: 0x23262A, ink2: 0x5E5C57, hairline: 0xD9D3C8, accent: 0x4E6B45,
                                 link: 0x4E6B45, action: 0x4E6B45, onAction: 0xFFFFFF, positive: 0x4E6B45, caution: 0x7F5418, danger: 0xA8382F, selection: 0x4E6B45)
        default: return RoleSet(canvas: 0xFFF6EC, raised: 0xFFFFFF, field: 0xFFEBD8, ink: 0x111111, ink2: 0x55504A, hairline: 0x111111, accent: 0xFF7EB6,
                                link: 0x1F4BFF, action: 0xFF7EB6, onAction: 0x111111, positive: 0x0E7A45, caution: 0x9A4D00, danger: 0xC8102E, selection: 0x111111)
        }
    }

    /// The camera bag (pickers, rig drums) is dark in every theme (§9, design/direction/render.py BAG). Accent and action
    /// use Camera Body's amber, the one accent that reads on this dark.
    public static let bag = RoleSet(canvas: 0x141414, raised: 0x141414, field: 0x1E1F21, ink: 0xECEAE5, ink2: 0xA9A6A0, hairline: 0x2C3033,
                                    accent: 0xF2A93B, link: 0xF2A93B, action: 0xF2A93B, onAction: 0x1A1205,
                                    positive: 0x7BD88F, caution: 0xF2C14E, danger: 0xFF6B5E, selection: 0xF2A93B)

    public static func radii(_ theme: String) -> Radii {
        switch theme {
        case "a": return Radii(container: 4, control: 2, chip: 2)
        case "b": return Radii(container: 14, control: 10, chip: 8)
        case "c": return Radii(container: 24, control: 16, chip: 12)
        default: return Radii(container: 16, control: 12, chip: 999)
        }
    }

    /// None in Camera Body: the dark theme never uses a shadow.
    public static func float(_ theme: String) -> Float? { theme == "b" ? nil : Float(y: 12, blur: 32, alpha: 0.14) }

    public static func families(_ theme: String) -> Families {
        switch theme {
        case "a": return Families(display: "Instrument Serif", text: "Archivo")
        case "b": return Families(display: "Barlow Condensed", text: "Barlow")
        case "c": return Families(display: "Outfit", text: "Outfit")
        default: return Families(display: "Bricolage Grotesque", text: "Figtree")
        }
    }

    /// The scale is the same in every theme (§3).
    public static let display = Step(size: 28, lineHeight: 32, weight: 400)
    public static let title = Step(size: 20, lineHeight: 26, weight: 600)
    public static let heading = Step(size: 16, lineHeight: 22, weight: 600)
    public static let body = Step(size: 15, lineHeight: 21, weight: 400)
    public static let label = Step(size: 14, lineHeight: 18, weight: 500)
    public static let caption = Step(size: 13, lineHeight: 18, weight: 400)
    public static let micro = Step(size: 11, lineHeight: 14, weight: 500)

    /// 4/8 grid (§4): s1…s7.
    public static let space: [Double] = [4, 8, 12, 16, 24, 32, 48]
}

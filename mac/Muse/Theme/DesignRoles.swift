import MuseCore
import SwiftUI

// The design-direction tokens (plans/design-direction.md §2–§4) for SwiftUI. The values live in MuseCore's DesignTokens,
// shared with the contrast tests; Android has the same names (MuseRoles / MuseTypeScale / MuseSpace). New and restyled
// screens use these; the older Theme colours and fonts stay until each screen is restyled.

/// Colour roles (§2). Views use roles, never a literal colour.
struct Roles {
    let canvas, raised, field, ink, ink2, hairline: Color
    /// The selection mark and focus ring, once per region. In Creator Pop it is a fill only; its outline is `selection`.
    let accent: Color
    /// Text links.
    let link: Color
    /// The one primary button per screen, and its label.
    let action, onAction: Color
    let positive, caution, danger: Color
    /// The outline that marks the current selection: accent, except Creator Pop's ink.
    let selection: Color

    init(_ r: DesignTokens.RoleSet) {
        canvas = Color(hex: r.canvas); raised = Color(hex: r.raised); field = Color(hex: r.field)
        ink = Color(hex: r.ink); ink2 = Color(hex: r.ink2); hairline = Color(hex: r.hairline)
        accent = Color(hex: r.accent); link = Color(hex: r.link); action = Color(hex: r.action); onAction = Color(hex: r.onAction)
        positive = Color(hex: r.positive); caution = Color(hex: r.caution); danger = Color(hex: r.danger); selection = Color(hex: r.selection)
    }

    private static let byTheme: [ThemeID: Roles] = Dictionary(uniqueKeysWithValues: ThemeID.allCases.map { ($0, Roles(DesignTokens.roles($0.rawValue))) })
    static func of(_ id: ThemeID) -> Roles { byTheme[id]! }
    /// The camera bag (pickers, rig drums) is dark in every theme (§9).
    static let bag = Roles(DesignTokens.bag)
}

/// Type scale (§3): the same steps in every theme, two families per theme. Line heights: apply `lineSpacing(style.leading)`
/// on multi-line text. Numbers that line up use `.monospacedDigit()`.
struct TypeScale {
    struct Style {
        let font: Font
        let size: CGFloat
        /// Extra line spacing that gives the scale's line height.
        let leading: CGFloat
    }
    let display, title, heading, body, label, caption, micro: Style
    let displayFamily, textFamily: String

    init(_ id: ThemeID) {
        let f = DesignTokens.families(id.rawValue)
        displayFamily = f.display; textFamily = f.text
        // The display face's own weight: Instrument Serif has one; Barlow Condensed and Bricolage are set heavier.
        let displayWeight: Font.Weight
        switch id {
        case .a: displayWeight = .regular
        case .b: displayWeight = .semibold
        case .c: displayWeight = .medium
        case .d: displayWeight = .bold
        }
        func w(_ v: Int) -> Font.Weight { v >= 600 ? .semibold : v >= 500 ? .medium : .regular }
        func style(_ family: String, _ s: DesignTokens.Step, _ weight: Font.Weight? = nil) -> Style {
            Style(font: Fonts.font(family, s.size, weight ?? w(s.weight)), size: s.size, leading: max(0, s.lineHeight - s.size * 1.2))
        }
        display = style(f.display, DesignTokens.display, displayWeight)
        title = style(f.text, DesignTokens.title); heading = style(f.text, DesignTokens.heading); body = style(f.text, DesignTokens.body)
        label = style(f.text, DesignTokens.label); caption = style(f.text, DesignTokens.caption); micro = style(f.text, DesignTokens.micro)
    }

    private static let byTheme: [ThemeID: TypeScale] = Dictionary(uniqueKeysWithValues: ThemeID.allCases.map { ($0, TypeScale($0)) })
    static func of(_ id: ThemeID) -> TypeScale { byTheme[id]! }
}

/// Spacing on the 4/8 grid (§4). Inside a group s2, between groups s5, between sections s6. The Mac gutter is 32.
enum Space {
    static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16, s5: CGFloat = 24, s6: CGFloat = 32, s7: CGFloat = 48
    static let gutter: CGFloat = s6
}

/// Radii by hierarchy (§4): container (sheets, media tiles) > control (buttons, fields) > chip.
struct Radii {
    let container, control, chip: CGFloat
    static func of(_ id: ThemeID) -> Radii {
        let r = DesignTokens.radii(id.rawValue)
        return Radii(container: r.container, control: r.control, chip: r.chip)
    }
}

extension Theme {
    var roles: Roles { Roles.of(id) }
    var scale: TypeScale { TypeScale.of(id) }
    var radii: Radii { Radii.of(id) }
}

extension View {
    /// The one shadow (`float`, §4), for things that float over content: menus, popovers, toasts. No glow; none in Camera Body.
    @ViewBuilder func museFloat(_ theme: Theme) -> some View {
        if let f = DesignTokens.float(theme.id.rawValue) {
            shadow(color: theme.roles.ink.opacity(f.alpha), radius: f.blur / 2, x: 0, y: f.y)
        } else {
            self
        }
    }

    /// A scale step: font plus its line spacing.
    func typeStep(_ s: TypeScale.Style) -> some View { font(s.font).lineSpacing(s.leading) }
}

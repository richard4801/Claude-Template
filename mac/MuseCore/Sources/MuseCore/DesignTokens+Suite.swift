import Foundation

// The Video suite redesign (owner-approved 2026-11-14, plans/design/suite-redesign/README.md). Light is Editorial's own
// tokens unchanged. Dark is Camera Body lifted one step, measured off the approved "Swap filled dark" frame: the page
// is Camera Body's `raised` tone, the stage one step up, the panels its `field` tone, with the amber accent and action
// unchanged. Owner decision 4: Shot and Home use these too. Only the Suite's pages take them (Muse/Views/Suite).
public extension DesignTokens {
    static func suite(_ theme: String) -> RoleSet {
        let r = roles(theme)
        guard theme == "b" else { return r }
        return RoleSet(canvas: 0x17191B, raised: 0x212427, field: 0x1D2022, ink: r.ink, ink2: r.ink2, hairline: 0x2C3034,
                       accent: r.accent, link: r.link, action: r.action, onAction: r.onAction,
                       positive: r.positive, caution: r.caution, danger: r.danger, selection: r.selection)
    }
}

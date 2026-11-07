import Foundation

// The cinematic Suite's "dark room" (plans/ai-suite-design.md, MOCKS APPROVED; plans/ai-suite-cinematic/README.md).
// Owner rule: it must not clash with the app's theme, so every colour is a darker or lighter shade of that theme's own
// tokens (ink, accent, link, raised, caution): no new hues. Same derivation as design/direction/cinematic.py `room()`.
public extension DesignTokens {
    /// The room's colours as a role set (canvas = the room's tone, ink = text on it, action = Generate), plus the
    /// tint of the composer's glass (the theme's own surface colour).
    struct Room: Equatable, Sendable {
        public let roles: RoleSet
        public let glassTint: UInt32
    }

    /// 0xRRGGBB a → b by t (0…1), per channel.
    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func ch(_ v: UInt32, _ s: UInt32) -> Double { Double((v >> s) & 0xFF) }
        var out: UInt32 = 0
        for s: UInt32 in [16, 8, 0] {
            let v = ch(a, s) + (ch(b, s) - ch(a, s)) * t
            out |= UInt32(max(0, min(255, v.rounded()))) << s
        }
        return out
    }

    static func room(_ theme: String) -> Room {
        let r = roles(theme)
        let white: UInt32 = 0xFFFFFF, black: UInt32 = 0x000000
        let s0, text, mark, gen, onGen: UInt32
        switch theme {
        case "b":   // Camera Body is already a dark room.
            s0 = 0x0D0E0F; text = r.ink; mark = r.accent; gen = r.accent; onGen = r.onAction
        case "a":   // Editorial: its ink black warmed by its red; the red as the mark.
            s0 = mix(r.ink, r.accent, 0.05); text = r.raised; mark = mix(r.accent, white, 0.22); gen = r.accent; onGen = r.raised
        case "c":   // Soft Tactile: a deep olive charcoal from its ink and sage; the sage lifted for the mark.
            s0 = mix(mix(r.ink, r.accent, 0.34), black, 0.36); text = r.raised; mark = mix(r.accent, 0xD8E8C8, 0.45); gen = mark
            onGen = mix(r.ink, black, 0.3)
        default:    // Creator Pop: its ink deepened with its cobalt; the pink as the mark.
            s0 = mix(mix(r.ink, r.link, 0.22), black, 0.25); text = r.raised; mark = r.accent; gen = r.accent; onGen = r.ink
        }
        let light = theme != "b"
        let set = RoleSet(canvas: s0, raised: mix(s0, text, 0.06), field: mix(s0, text, 0.10), ink: text, ink2: mix(text, s0, 0.36),
                          hairline: mix(s0, text, 0.16), accent: mark, link: mark, action: gen, onAction: onGen,
                          positive: light ? mix(r.positive, white, 0.45) : r.positive,
                          caution: light ? mix(r.caution, white, 0.55) : r.caution,
                          danger: light ? mix(r.danger, white, 0.4) : r.danger,
                          selection: mark)
        return Room(roles: set, glassTint: light ? r.raised : r.ink)
    }
}

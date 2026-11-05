import XCTest
@testable import MuseCore

/// App-wide polish (workstream 4, plans/ux-audit-mac.md): text contrast of the four themes' tokens and the demo-only wording.
final class UxPolishTests: XCTestCase {
    /// The text/background tokens of Muse/Theme/Theme.swift (`Theme.get`, `link`, `goodInk`, `accentFill`). Keep in step with it.
    private struct Tokens {
        let name: String
        let bg, surface, surface2, ink, muted, good, accent, accentInk, cta, ctaInk, link, goodInk, accentFill: UInt32
        var backgrounds: [UInt32] { [bg, surface, surface2] }
    }

    private let themes: [Tokens] = [
        Tokens(name: "Editorial", bg: 0xEFEBE3, surface: 0xF8F5EF, surface2: 0xE7E1D6, ink: 0x141210, muted: 0x67605A, good: 0x2F6B3A,
               accent: 0xB5121B, accentInk: 0xFFFFFF, cta: 0x141210, ctaInk: 0xF8F5EF, link: 0xB5121B, goodInk: 0x22552B, accentFill: 0xB5121B),
        Tokens(name: "Camera Body", bg: 0x0D0E0F, surface: 0x17191B, surface2: 0x212427, ink: 0xECEAE5, muted: 0xA9A6A0, good: 0x7BD88F,
               accent: 0xF2A93B, accentInk: 0x1A1205, cta: 0xF2A93B, ctaInk: 0x1A1205, link: 0xF2A93B, goodInk: 0x7BD88F, accentFill: 0xF2A93B),
        Tokens(name: "Soft Tactile", bg: 0xE7E2D9, surface: 0xF3F0EA, surface2: 0xEAE5DC, ink: 0x23262A, muted: 0x5E5C57, good: 0x4E6B45,
               accent: 0x6E8465, accentInk: 0xFFFFFF, cta: 0x5A6E52, ctaInk: 0xFFFFFF, link: 0x4E6B45, goodInk: 0x3E5737, accentFill: 0x5A6E52),
        Tokens(name: "Creator Pop", bg: 0xFFF6EC, surface: 0xFFFFFF, surface2: 0xFFEBD8, ink: 0x111111, muted: 0x55504A, good: 0x0E8A4F,
               accent: 0xFF7EB6, accentInk: 0x111111, cta: 0xFF7EB6, ctaInk: 0x111111, link: 0x1F4BFF, goodInk: 0x0A6B3D, accentFill: 0xFF7EB6),
    ]

    func testContrastMaths() {
        XCTAssertEqual(Contrast.ratio(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
        XCTAssertEqual(Contrast.ratio(0xFFFFFF, 0xFFFFFF), 1, accuracy: 0.0001)
        XCTAssertEqual(Contrast.ratio(0x777777, 0xFFFFFF), Contrast.ratio(0xFFFFFF, 0x777777), accuracy: 0.0001)
        XCTAssertEqual(Contrast.ratio(0x767676, 0xFFFFFF), 4.54, accuracy: 0.01) // the classic AA grey
        XCTAssertEqual(Contrast.mix(0xFFFFFF, over: 0x000000, alpha: 0.5), 0x808080)
        XCTAssertEqual(Contrast.mix(0x123456, over: 0xABCDEF, alpha: 1), 0x123456)
    }

    /// Body text (ink) and secondary text (muted) are readable on every surface of every theme.
    func testTextTokensPassAA() {
        for t in themes {
            for bg in t.backgrounds {
                XCTAssertGreaterThanOrEqual(Contrast.ratio(t.ink, bg), Contrast.aaText, "\(t.name) ink on \(String(bg, radix: 16))")
                XCTAssertGreaterThanOrEqual(Contrast.ratio(t.muted, bg), Contrast.aaText, "\(t.name) muted on \(String(bg, radix: 16))")
            }
        }
    }

    /// Links, the `.good` pill's text on its tint, and white/ink text on accent fills (the "Edited" pill, a chip that's on, CTAs).
    func testAccentPairsPassAA() {
        for t in themes {
            for bg in t.backgrounds {
                XCTAssertGreaterThanOrEqual(Contrast.ratio(t.link, bg), Contrast.aaText, "\(t.name) link on \(String(bg, radix: 16))")
                let tint = Contrast.mix(t.good, over: bg, alpha: 0.18)
                XCTAssertGreaterThanOrEqual(Contrast.ratio(t.goodInk, tint), Contrast.aaText, "\(t.name) good pill on \(String(bg, radix: 16))")
            }
            XCTAssertGreaterThanOrEqual(Contrast.ratio(t.accentInk, t.accentFill), Contrast.aaText, "\(t.name) accent pill")
            XCTAssertGreaterThanOrEqual(Contrast.ratio(t.ctaInk, t.cta), Contrast.aaText, "\(t.name) CTA")
        }
    }

    /// The pairs the audit found failing before the fix stay documented: Soft Tactile's and Creator Pop's accents are not text colours.
    func testRawAccentsAreNotTextColours() {
        let soft = themes[2], pop = themes[3]
        XCTAssertLessThan(Contrast.ratio(soft.accent, soft.bg), Contrast.aaText)
        XCTAssertLessThan(Contrast.ratio(soft.accentInk, soft.accent), Contrast.aaText)
        XCTAssertLessThan(Contrast.ratio(pop.accent, pop.bg), Contrast.aaLarge)
    }

    /// Demo mode's simulation note never reaches a real studio.
    func testLoraTimeLeftMentionsTheDemoOnlyInDemoMode() {
        XCTAssertEqual(LoraPricing.timeLeftLine(progress: 0, demo: false), "~100 min left")
        XCTAssertEqual(LoraPricing.timeLeftLine(progress: 58, demo: false), "~42 min left")
        XCTAssertEqual(LoraPricing.timeLeftLine(progress: 100, demo: false), "~1 min left")
        XCTAssertEqual(LoraPricing.timeLeftLine(progress: 58, demo: true), "~42 min left · the demo runs faster")
        for p in stride(from: 0.0, through: 100, by: 7) {
            XCTAssertFalse(LoraPricing.timeLeftLine(progress: p, demo: false).lowercased().contains("demo"))
        }
    }
}

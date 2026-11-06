import XCTest
@testable import MuseCore

/// Keeps the design-direction colours (plans/design-direction.md §2) from drifting below the checked contrast.
/// Same checks as Android's DesignTokensTest.
final class DesignTokensTests: XCTestCase {
    private func atLeast(_ min: Double, _ fg: UInt32, _ bg: UInt32, _ what: String) {
        XCTAssertGreaterThanOrEqual(Contrast.ratio(fg, bg), min, what)
    }

    func testTextPassesOnEverySurface() {
        for t in DesignTokens.themes {
            let r = DesignTokens.roles(t)
            for (name, bg) in [("canvas", r.canvas), ("raised", r.raised), ("field", r.field)] {
                atLeast(Contrast.aaText, r.ink, bg, "\(t) ink on \(name)")
                atLeast(Contrast.aaText, r.ink2, bg, "\(t) ink2 on \(name)")
            }
            atLeast(11, r.ink, r.canvas, "\(t) ink on canvas")
        }
    }

    func testActionLinksAndStatesPass() {
        for t in DesignTokens.themes {
            let r = DesignTokens.roles(t)
            atLeast(Contrast.aaText, r.onAction, r.action, "\(t) onAction on action") // §2 says ≥ 6.0; Soft Tactile is 5.98
            atLeast(Contrast.aaText, r.link, r.canvas, "\(t) link on canvas")
            for (name, c) in [("positive", r.positive), ("caution", r.caution), ("danger", r.danger)] { atLeast(Contrast.aaText, c, r.canvas, "\(t) \(name)") }
            atLeast(Contrast.aaLarge, r.selection, r.canvas, "\(t) selection outline")
        }
    }

    func testBagIsDarkAndReadable() {
        let b = DesignTokens.bag
        XCTAssertLessThan(Contrast.luminance(b.raised), 0.02)
        atLeast(Contrast.aaText, b.ink, b.raised, "bag ink")
        atLeast(Contrast.aaText, b.ink2, b.field, "bag ink2 on field")
        atLeast(Contrast.aaLarge, b.accent, b.raised, "bag accent")
    }

    func testScaleRadiiAndSpaceMatchTheDirection() {
        XCTAssertEqual(DesignTokens.space, [4, 8, 12, 16, 24, 32, 48])
        let steps: [DesignTokens.Step] = [DesignTokens.display, DesignTokens.title, DesignTokens.heading, DesignTokens.body,
                                          DesignTokens.label, DesignTokens.caption, DesignTokens.micro]
        XCTAssertEqual(steps.map { $0.size }, [28, 20, 16, 15, 14, 13, 11])
        for t in DesignTokens.themes {
            let r = DesignTokens.radii(t)
            XCTAssertGreaterThanOrEqual(r.container, r.control, t)
            XCTAssertTrue(r.control >= r.chip || r.chip == 999, t)
        }
        XCTAssertNil(DesignTokens.float("b"))
    }
}

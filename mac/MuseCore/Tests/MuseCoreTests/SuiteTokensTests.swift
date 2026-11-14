import XCTest
@testable import MuseCore

/// The Video suite redesign's tokens (DesignTokens.suite): Editorial unchanged; Camera Body's lifted dark from the approved
/// "Swap filled dark" frame, still readable (WCAG AA) on every tone.
final class SuiteTokensTests: XCTestCase {
    func testLightThemesKeepTheirOwnTokens() {
        for t in ["a", "c", "d"] { XCTAssertEqual(DesignTokens.suite(t), DesignTokens.roles(t), t) }
    }

    func testCameraBodyMatchesTheDarkFrame() {
        let r = DesignTokens.suite("b")
        XCTAssertEqual(r.canvas, 0x17191B)
        XCTAssertEqual(r.raised, 0x212427)
        XCTAssertEqual(r.field, 0x1D2022)
        XCTAssertEqual(r.accent, 0xF2A93B)
        XCTAssertEqual(r.action, 0xF2A93B)
    }

    func testCameraBodyTextPasses() {
        let r = DesignTokens.suite("b")
        for (name, bg) in [("canvas", r.canvas), ("raised", r.raised), ("field", r.field)] {
            XCTAssertGreaterThanOrEqual(Contrast.ratio(r.ink, bg), Contrast.aaText, "text on \(name)")
            XCTAssertGreaterThanOrEqual(Contrast.ratio(r.ink2, bg), Contrast.aaText, "muted text on \(name)")
        }
        XCTAssertGreaterThanOrEqual(Contrast.ratio(r.onAction, r.action), Contrast.aaText, "Generate label")
    }
}

import XCTest
@testable import MuseCore

/// The cinematic Suite's dark room (DesignTokens.room): derived from each theme, dark, and readable (WCAG AA).
/// The values match design/direction/cinematic.py `room()`, which rendered the approved mocks.
final class SuiteRoomTests: XCTestCase {
    private func atLeast(_ min: Double, _ fg: UInt32, _ bg: UInt32, _ what: String) {
        XCTAssertGreaterThanOrEqual(Contrast.ratio(fg, bg), min, what)
    }

    func testRoomIsDarkInEveryTheme() {
        for t in DesignTokens.themes {
            XCTAssertLessThan(Contrast.luminance(DesignTokens.room(t).roles.canvas), 0.03, t)
        }
    }

    func testRoomTextGenerateAndMarksPass() {
        for t in DesignTokens.themes {
            let r = DesignTokens.room(t).roles
            for (name, bg) in [("canvas", r.canvas), ("raised", r.raised), ("field", r.field)] {
                atLeast(Contrast.aaText, r.ink, bg, "\(t) text on \(name)")
                atLeast(Contrast.aaText, r.ink2, bg, "\(t) muted text on \(name)")
                atLeast(Contrast.aaText, r.caution, bg, "\(t) warning on \(name)")
            }
            atLeast(Contrast.aaText, r.onAction, r.action, "\(t) Generate label")
            atLeast(Contrast.aaLarge, r.accent, r.canvas, "\(t) selection mark")
        }
    }

    /// Soft Tactile's room is the approved deep olive (mock: #202721), Camera Body keeps its own dark.
    func testRoomTonesMatchTheMocks() {
        XCTAssertEqual(DesignTokens.room("b").roles.canvas, 0x0D0E0F)
        let c = DesignTokens.room("c").roles.canvas
        XCTAssertEqual(Double((c >> 16) & 0xFF), 0x20, accuracy: 1)
        XCTAssertEqual(Double((c >> 8) & 0xFF), 0x27, accuracy: 1)
        XCTAssertEqual(Double(c & 0xFF), 0x21, accuracy: 1)
        XCTAssertEqual(DesignTokens.mix(0x000000, 0xFFFFFF, 0.5), 0x808080)
    }
}

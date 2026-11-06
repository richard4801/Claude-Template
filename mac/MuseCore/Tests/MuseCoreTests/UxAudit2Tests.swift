import XCTest
@testable import MuseCore

/// The second UX audit (plans/ux-audit-2-mac.md): the logic behind its Mac fixes.
final class UxAudit2Tests: XCTestCase {
    // MARK: Filled tags pick a readable ink (M2-05)

    func testBestInkOnFills() {
        // Camera Body's light fills (good green, amber) take dark text: white on them is under 2:1.
        XCTAssertEqual(Contrast.bestInk(on: 0x7BD88F), Contrast.darkInk)
        XCTAssertEqual(Contrast.bestInk(on: 0xF2A93B), Contrast.darkInk)
        // Dark fills keep white.
        XCTAssertEqual(Contrast.bestInk(on: 0x2F6B3A), 0xFFFFFF)
        XCTAssertEqual(Contrast.bestInk(on: 0xB5121B), 0xFFFFFF)
        XCTAssertEqual(Contrast.bestInk(on: 0x111111), 0xFFFFFF)
        // Whatever it picks passes AA on every theme's tag fills (goodInk for Ready, warn, rec). Creator Pop's plain good
        // #0E8A4F reaches only 4.41 with either ink, which is why the filled Ready tag uses goodInk.
        let fills: [UInt32] = [0x2F6B3A, 0x9A5B00, 0xB5121B, 0x7BD88F, 0xF2A93B, 0xE5483B, 0x4E6B45, 0x9A6B2A, 0xC2362B, 0x0A6B3D, 0xB45A00]
        for f in fills {
            XCTAssertGreaterThanOrEqual(Contrast.ratio(Contrast.bestInk(on: f), f), Contrast.aaText,
                                        String(format: "ink on %06X", f))
        }
    }

    // MARK: Hub tiles (M2-10)

    func testBalancedColumnsAvoidAnOrphanRow() {
        // 6 tiles, ≥160 px, 12 px gaps: 964 px (1100 window) fits 5 → 3 + 3, not 5 + 1.
        XCTAssertEqual(SuiteLayout.balancedColumns(count: 6, width: 964, minimum: 160, spacing: 12), 3)
        XCTAssertEqual(SuiteLayout.balancedColumns(count: 6, width: 988, minimum: 160, spacing: 12), 3)
        // 1440 window: all six in one row.
        XCTAssertEqual(SuiteLayout.balancedColumns(count: 6, width: 1148, minimum: 160, spacing: 12), 6)
        // 7 tiles in room for 5: 4 + 3.
        XCTAssertEqual(SuiteLayout.balancedColumns(count: 7, width: 900, minimum: 160, spacing: 12), 4)
        // Narrow: one column; nothing to lay out: 1; width not measured yet: 3.
        XCTAssertEqual(SuiteLayout.balancedColumns(count: 6, width: 150, minimum: 160, spacing: 12), 1)
        XCTAssertEqual(SuiteLayout.balancedColumns(count: 0, width: 900, minimum: 160, spacing: 12), 1)
        XCTAssertEqual(SuiteLayout.balancedColumns(count: 6, width: 0, minimum: 160, spacing: 12), 3)
        XCTAssertEqual(SuiteLayout.balancedColumns(count: 2, width: 0, minimum: 160, spacing: 12), 2)
    }

    // MARK: Camera stage on the Mac itself (M2-16)

    func testBlenderRowOnThisMacSaysTheRelayIsOff() {
        let off = CameraRelayPresence(online: false, blender: false)
        XCTAssertEqual(CameraStatus.blender(off, thisMac: true).detail, CameraStatus.offlineHere)
        XCTAssertEqual(CameraStatus.blender(nil, thisMac: true).detail, CameraStatus.offlineHere)
        XCTAssertEqual(CameraStatus.blender(off, thisMac: true).tone, .off)
        // Elsewhere (and by default) the wording is unchanged.
        XCTAssertEqual(CameraStatus.blender(off).detail, "Mac app offline")
        // Online rows don't depend on it.
        XCTAssertEqual(CameraStatus.blender(CameraRelayPresence(online: true, blender: false), thisMac: true).detail, "Mac app online · Blender not connected")
        XCTAssertFalse(CameraStatus.offlineHere.contains("offline"))
    }

    // MARK: Text pairs the audit changed (M2-07, M2-11, M2-12, M2-21, M2-22)

    private struct T {
        let name: String
        let bg, surface, surface2, muted, accent, link, rec, good, goodInk, warn, warnInk: UInt32
    }

    private let themes: [T] = [
        T(name: "Editorial", bg: 0xEFEBE3, surface: 0xF8F5EF, surface2: 0xE7E1D6, muted: 0x67605A, accent: 0xB5121B, link: 0xB5121B,
          rec: 0xB5121B, good: 0x2F6B3A, goodInk: 0x22552B, warn: 0x9A5B00, warnInk: 0x5B3600),
        T(name: "Camera Body", bg: 0x0D0E0F, surface: 0x17191B, surface2: 0x212427, muted: 0xA9A6A0, accent: 0xF2A93B, link: 0xF2A93B,
          rec: 0xE5483B, good: 0x7BD88F, goodInk: 0x7BD88F, warn: 0xF2A93B, warnInk: 0xF2B45A),
        T(name: "Soft Tactile", bg: 0xE7E2D9, surface: 0xF3F0EA, surface2: 0xEAE5DC, muted: 0x5E5C57, accent: 0x6E8465, link: 0x4E6B45,
          rec: 0xC2362B, good: 0x4E6B45, goodInk: 0x3E5737, warn: 0x9A6B2A, warnInk: 0x5B3600),
        T(name: "Creator Pop", bg: 0xFFF6EC, surface: 0xFFFFFF, surface2: 0xFFEBD8, muted: 0x55504A, accent: 0xFF7EB6, link: 0x1F4BFF,
          rec: 0xC2362B, good: 0x0E8A4F, goodInk: 0x0A6B3D, warn: 0xB45A00, warnInk: 0x5B3600),
    ]

    func testAuditTextPairsPassAA() {
        for t in themes {
            // The prompt chip's @ / # sigil now uses `link` on the chip plate (surface2); the accent failed in C (3.3) and D (2.0).
            XCTAssertGreaterThanOrEqual(Contrast.ratio(t.link, t.surface2), Contrast.aaText, "\(t.name) sigil")
            // The prompt placeholder now uses `muted` on the composer card (surface); #8C847A was 3.2–3.7 in A, C, D.
            XCTAssertGreaterThanOrEqual(Contrast.ratio(t.muted, t.surface), Contrast.aaText, "\(t.name) placeholder")
            // Claude chat errors and failed tool chips use `rec` on surface (the accent was 2.4 in D, 3.6 in C).
            XCTAssertGreaterThanOrEqual(Contrast.ratio(t.rec, t.surface), 4.4, "\(t.name) chat error")
            // Outline tags (Ready, Locked, Needs close-ups, ● Live) use goodInk / warnInk on bg and surface.
            for b in [t.bg, t.surface] {
                XCTAssertGreaterThanOrEqual(Contrast.ratio(t.goodInk, b), Contrast.aaText, "\(t.name) good tag")
                XCTAssertGreaterThanOrEqual(Contrast.ratio(t.warnInk, b), Contrast.aaText, "\(t.name) warn tag")
            }
            // The sidebar's "Soon" is plain muted now (it was muted at 70 %: 2.9:1 in A and C).
            XCTAssertGreaterThanOrEqual(Contrast.ratio(t.muted, t.bg), Contrast.aaText, "\(t.name) Soon")
        }
        // Why: the old pairs failed.
        XCTAssertLessThan(Contrast.ratio(0xFF7EB6, 0xFFEBD8), 3)  // D accent sigil on surface2
        XCTAssertLessThan(Contrast.ratio(0x8C847A, 0xF3F0EA), 3.5) // C placeholder
        XCTAssertLessThan(Contrast.ratio(0xFFFFFF, 0x7BD88F), 2)   // white on B's filled Ready tag
    }
}

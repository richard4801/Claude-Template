import XCTest
@testable import MuseCore

func fixture(_ name: String) throws -> Any {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try JSONSerialization.jsonObject(with: Data(contentsOf: url))
}

/// Checks the Swift port against values produced by running the prototype JavaScript itself:
/// desktop_fixture.json comes from prototype/desktop/desktop.js (Fixtures/gen_desktop_fixture.js),
/// phone_pricing_fixture.json is the Android app's reference fixture (android/core/src/test/resources/pricing_fixture.json).
final class PricingTests: XCTestCase {
    func testEveryDesktopFixtureRowMatchesTheJS() throws {
        let root = try XCTUnwrap(fixture("desktop_fixture") as? [String: Any])
        let rows = try XCTUnwrap(root["pricing"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 648)
        for o in rows {
            let spec = RenderSpec(engine: Engine(id: o["engine"] as! String), use: ClipUse(id: o["use"] as! String), steps: o["steps"] as! Int,
                                  lipSync: o["lip"] as! Bool, takes: o["takes"] as! Int)
            let ctx = "\(spec)"
            XCTAssertEqual(spec.lengthSec, o["len"] as! Double, ctx)
            XCTAssertEqual(Pricing.estMin(spec), o["estMin"] as! Double, accuracy: 1e-9, ctx)
            XCTAssertEqual(Pricing.estCost(spec), o["estCost"] as! Double, accuracy: 1e-9, ctx)
            XCTAssertEqual(Pricing.totalCost(spec), o["totalCost"] as! Double, accuracy: 1e-9, ctx)
            XCTAssertEqual(Pricing.fmtMin(Pricing.totalMin(spec)), o["time"] as! String, ctx)
            XCTAssertEqual(Pricing.money(Pricing.totalCost(spec)), o["cost"] as! String, ctx)
            XCTAssertEqual(Pricing.prototypeGenLabel(spec), o["genLabel"] as! String, ctx)
            XCTAssertEqual(Pricing.stepsDelta(spec), o["stepsDelta"] as! String, ctx)
        }
    }

    func testEveryAndroidReferenceRowMatches() throws {
        let rows = try XCTUnwrap(fixture("phone_pricing_fixture") as? [[String: Any]])
        XCTAssertEqual(rows.count, 216)
        for o in rows {
            let spec = RenderSpec(engine: Engine(id: o["engine"] as! String), use: ClipUse(id: o["use"] as! String), steps: o["steps"] as! Int, lipSync: o["lip"] as! Bool)
            let ctx = "\(spec)"
            XCTAssertEqual(Pricing.estMin(spec), o["estMin"] as! Double, accuracy: 1e-9, ctx)
            XCTAssertEqual(Pricing.estCost(spec), o["estCost"] as! Double, accuracy: 1e-9, ctx)
            XCTAssertEqual(Pricing.money(Pricing.estCost(spec)), o["costLabel"] as! String, ctx)
            XCTAssertEqual(Pricing.stepsDelta(spec), o["stepsDelta"] as! String, ctx)
        }
    }

    func testRecommendedDefaultIsTenStepsAbout67Cents() {
        let spec = RenderSpec()
        XCTAssertEqual(spec.steps, 10)
        XCTAssertEqual(Pricing.prototypeGenLabel(spec), "Generate · 10 min · $0.67")
        // Members see the price only: no minutes, no steps.
        XCTAssertEqual(Pricing.genLabel(spec), "Generate · 10 min · $0.67")
    }

    func testTakesMultiplyTimeAndCost() {
        var s = RenderSpec()
        s.takes = 3
        XCTAssertEqual(Pricing.totalCost(s), Pricing.estCost(RenderSpec()) * 3, accuracy: 1e-12)
        XCTAssertEqual(Pricing.prototypeGenLabel(s), "Generate 3 takes · 30 min · $2.02")
        XCTAssertEqual(Pricing.genLabel(s), "Generate · 30 min · $2.02 · 3 takes")
    }

    func testFastBetaIsUnderTwoMinutes() {
        let s = RenderSpec(engine: .viggle)
        XCTAssertEqual(Pricing.prototypeGenLabel(s), "Generate · 96s · $0.13")
        XCTAssertEqual(Pricing.genLabel(s), "Generate · 96s · $0.13")
    }

    func testStepsAndTakesAreClamped() {
        XCTAssertEqual(Pricing.clampSteps(1), 4)
        XCTAssertEqual(Pricing.clampSteps(99), 30)
        XCTAssertEqual(Pricing.clampSteps(17), 17)
        XCTAssertEqual(Pricing.clampTakes(0), 1)
        XCTAssertEqual(Pricing.clampTakes(9), 4)
    }

    func testMoneyMatchesJSToFixed() {
        // 1.005 is 1.00499999999999989… in binary, so JS prints 1.00.
        XCTAssertEqual(Pricing.money(1.005), "$1.00")
        // An exact binary tie rounds up, like JS (printf would round to even).
        XCTAssertEqual(Pricing.money(0.125), "$0.13")
        XCTAssertEqual(Pricing.money(6.07), "$6.07")
        XCTAssertEqual(Pricing.money(9.999), "$10.00")
        XCTAssertEqual(Pricing.money(0), "$0.00")
        XCTAssertEqual(Pricing.toFixed(2.25, 1), "2.3")
        XCTAssertEqual(Pricing.toFixed(-0.001, 2), "0.00")
    }

    func testBalanceCountsDraftVideos() {
        // A typical Draft render: 10 s × $0.02 = $0.20.
        XCTAssertEqual(Pricing.typicalVideo, 0.2, accuracy: 1e-12)
        XCTAssertEqual(Pricing.videosLeft(6.07), 30)
        XCTAssertEqual(Pricing.videosLeft(0.6), 3)
        XCTAssertEqual(Pricing.videosLeft(0), 0)
    }

    func testRealClipLengths() {
        XCTAssertEqual(RenderSpec(use: .full, clipSeconds: 22).lengthSec, 15)
        XCTAssertEqual(RenderSpec(use: .first, clipSeconds: 3).lengthSec, 3)
        XCTAssertEqual(RenderSpec(use: .first, clipSeconds: 9).lengthSec, 5.2)
        XCTAssertEqual(RenderSpec(use: .full, clipSeconds: 12).lengthSec, 12)
        let s = RenderSpec(use: .full, clipSeconds: 12)
        XCTAssertEqual(Pricing.estMin(s), 10 * Pricing.secPerLen(12) / 60 + 0.5, accuracy: 1e-12)
    }

    func testClock() {
        XCTAssertEqual(formatClock(335), "05:35")
        XCTAssertEqual(formatClock(-3), "00:00")
    }
}

import XCTest
@testable import MuseCore

/// The drum wheel's maths (RigDrum on the Mac, the same values as the Android port).
final class RigDrumMathTests: XCTestCase {
    typealias M = RigDrumMath

    func testLoopsAndWrap() {
        XCTAssertFalse(M.loops(4))
        XCTAssertTrue(M.loops(5))
        XCTAssertEqual(M.wrap(-1, 6), 5)
        XCTAssertEqual(M.wrap(-7, 6), 5)
        XCTAssertEqual(M.wrap(-6, 6), 0)
        XCTAssertEqual(M.wrap(13, 6), 1)
        XCTAssertEqual(M.wrap(3, 6), 3)
    }

    func testRoundHalfUp() {
        XCTAssertEqual(M.roundHalfUp(2.5), 3)
        XCTAssertEqual(M.roundHalfUp(-2.5), -2)
        XCTAssertEqual(M.roundHalfUp(2.49), 2)
        XCTAssertEqual(M.roundHalfUp(-2.51), -3)
    }

    func testDeltaTakesTheShortWayRoundTheSeam() {
        XCTAssertEqual(M.delta(item: 0, pos: 5, count: 6, loop: true), 1, accuracy: 1e-9)
        XCTAssertEqual(M.delta(item: 5, pos: 0, count: 6, loop: true), -1, accuracy: 1e-9)
        XCTAssertEqual(M.delta(item: 0, pos: 11.5, count: 6, loop: true), 0.5, accuracy: 1e-9)
        XCTAssertEqual(M.delta(item: 2, pos: 2, count: 6, loop: true), 0, accuracy: 1e-9)
        // Without a loop it's the plain difference.
        XCTAssertEqual(M.delta(item: 0, pos: 3, count: 4, loop: false), -3, accuracy: 1e-9)
        XCTAssertEqual(M.delta(item: 3, pos: 0, count: 4, loop: false), 3, accuracy: 1e-9)
    }

    func testNearestClampsOrWraps() {
        XCTAssertEqual(M.nearest(-0.4, count: 4, loop: false), 0)
        XCTAssertEqual(M.nearest(-3, count: 4, loop: false), 0)
        XCTAssertEqual(M.nearest(9, count: 4, loop: false), 3)
        XCTAssertEqual(M.nearest(1.5, count: 4, loop: false), 2)
        XCTAssertEqual(M.nearest(-1, count: 6, loop: true), 5)
        XCTAssertEqual(M.nearest(6.2, count: 6, loop: true), 0)
        XCTAssertEqual(M.nearest(13.6, count: 6, loop: true), 2)
    }

    func testClampSoftRubberBandsAtBothEnds() {
        XCTAssertEqual(M.clampSoft(1.5, count: 4, loop: false), 1.5)
        XCTAssertEqual(M.clampSoft(-1, count: 4, loop: false), -0.35, accuracy: 1e-9)
        XCTAssertEqual(M.clampSoft(-10, count: 4, loop: false), -0.6, accuracy: 1e-9)
        XCTAssertEqual(M.clampSoft(4, count: 4, loop: false), 3.35, accuracy: 1e-9)
        XCTAssertEqual(M.clampSoft(40, count: 4, loop: false), 3.6, accuracy: 1e-9)
        XCTAssertEqual(M.clampSoft(-10, count: 8, loop: true), -10)
    }

    func testFlingTarget() {
        XCTAssertEqual(M.flingTarget(pos: 1, velocity: 6, count: 4, loop: false), 3)
        XCTAssertEqual(M.flingTarget(pos: 1, velocity: -20, count: 4, loop: false), 0)
        XCTAssertEqual(M.flingTarget(pos: 1, velocity: 0.5, count: 4, loop: false), 1)
        // Looping: the target stays unwrapped.
        XCTAssertEqual(M.flingTarget(pos: 1, velocity: -20, count: 8, loop: true), -5)
        XCTAssertEqual(M.flingTarget(pos: 6, velocity: 20, count: 8, loop: true), 13)
    }

    func testDecayEndpoints() {
        XCTAssertEqual(M.decay(start: 2, target: 7, elapsed: 0), 2, accuracy: 1e-9)
        XCTAssertEqual(M.decay(start: 2, target: 7, elapsed: 10), 7, accuracy: 1e-6)
        let mid = M.decay(start: 2, target: 7, elapsed: 0.325)
        XCTAssertGreaterThan(mid, 2)
        XCTAssertLessThan(mid, 7)
    }

    func testSpringSettlesWithoutOvershoot() {
        var x = 1.0, v = 0.0, t = 0.0
        var settledAt: Double?
        while t < 3 {
            let s = M.springStep(x: x, v: v, dt: 1.0 / 60)
            x = s.x
            v = s.v
            t += 1.0 / 60
            XCTAssertGreaterThanOrEqual(x, 0, "critically damped: never crosses the detent")
            if settledAt == nil && M.settled(x: x, v: v) { settledAt = t }
        }
        XCTAssertNotNil(settledAt)
        XCTAssertLessThanOrEqual(settledAt ?? 99, 1.5)
        // A long frame is capped, so a hitch can't throw the drum.
        let big = M.springStep(x: 1, v: 0, dt: 1)
        let capped = M.springStep(x: 1, v: 0, dt: 0.032)
        XCTAssertEqual(big.x, capped.x, accuracy: 1e-12)
        XCTAssertTrue(M.settled(x: 0.001, v: 0.005))
        XCTAssertFalse(M.settled(x: 0.01, v: 0))
    }

    func testLook() {
        let c = M.look(delta: 0, itemHeight: 76, selected: true)
        XCTAssertTrue(c.visible)
        XCTAssertEqual(c.y, 0, accuracy: 1e-9)
        XCTAssertEqual(c.scale, 1, accuracy: 1e-9)
        XCTAssertEqual(c.opacity, 1, accuracy: 1e-9)
        XCTAssertEqual(c.brightness, 1)
        XCTAssertEqual(c.rotationDegrees, 0, accuracy: 1e-9)

        let up = M.look(delta: -1, itemHeight: 76, selected: false)
        let down = M.look(delta: 1, itemHeight: 76, selected: false)
        XCTAssertTrue(up.visible && down.visible)
        XCTAssertEqual(up.y, -down.y, accuracy: 1e-9)
        XCTAssertGreaterThan(down.y, 70, "about one item height below")
        XCTAssertLessThan(down.y, 76)
        XCTAssertEqual(up.scale, down.scale, accuracy: 1e-9)
        XCTAssertLessThan(down.scale, 1)
        XCTAssertEqual(up.opacity, down.opacity, accuracy: 1e-9)
        XCTAssertLessThan(down.opacity, 1)
        XCTAssertEqual(up.rotationDegrees, -down.rotationDegrees, accuracy: 1e-9)
        XCTAssertEqual(down.rotationDegrees, -21, accuracy: 1e-9)
        XCTAssertLessThan(down.brightness, 1)

        XCTAssertFalse(M.look(delta: 5, itemHeight: 76, selected: false).visible)
        XCTAssertFalse(M.look(delta: -5, itemHeight: 76, selected: false).visible)
    }
}

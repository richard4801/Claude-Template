import XCTest
@testable import MuseCore

/// Parity M rows (Swift port of WS8 c8875ec): keyframes on the timeline, curves, auto adjust. Same cases as Android's
/// EditSmallRowsTest and core AutoAdjustTest.
final class EditSuiteKeysTests: XCTestCase {
    typealias E = EditV2

    private func fresh(_ d: Double = 10) -> EditSuiteState {
        EditSuiteState(E.fromV1(EditList(sourceTakeId: "tk", sourceDurationSec: d), E.SourceFacts(width: 1080, height: 1920, fps: 30, hasAudio: true)))
    }
    private func valid(_ s: EditSuiteState, file: StaticString = #filePath, line: UInt = #line) {
        let p = E.problem(s.project)
        XCTAssertNil(p, p?.description ?? "", file: file, line: line)
    }

    func testKeyframesMoveAndJump() {
        var s = fresh()
        let id = s.project.mainClips[0].id
        s.selection = id
        for t in [1.0, 4.0, 8.0] { s.playhead = t; XCTAssertTrue(s.addKeyframe(.scale, value: 1 + t / 10)) }
        XCTAssertEqual(s.keyTimes(id), [1, 4, 8])
        // Drag the 4 s key to 5.5 s: a live drag, then the drop; one undo step.
        s.beginGesture()
        s.updateGesture(s.movingKeys(id, from: 4, by: 0.7))
        s.updateGesture(s.movingKeys(id, from: 4, by: 1.5))
        s.endGesture()
        XCTAssertEqual(s.keyTimes(id), [1, 5.5, 8])
        // It can't pass a neighbour.
        XCTAssertFalse(s.moveKeys(id, from: 5.5, by: 3))
        XCTAssertEqual(s.keyTimes(id), [1, 5.5, 8])
        XCTAssertTrue(s.undo())
        XCTAssertEqual(s.keyTimes(id), [1, 4, 8])
        // Previous / next.
        s.playhead = 5
        XCTAssertEqual(s.adjacentKeyframe(1), 8)
        XCTAssertEqual(s.adjacentKeyframe(-1), 4)
        s.playhead = 0.5
        XCTAssertNil(s.adjacentKeyframe(-1))
        valid(s)
    }

    func testMovingKeysMovesEveryPropertyAtThatTime() {
        var s = fresh()
        let id = s.project.mainClips[0].id
        s.selection = id
        s.playhead = 2; XCTAssertTrue(s.addKeyframesAll())
        s.playhead = 6; XCTAssertTrue(s.addKeyframesAll())
        XCTAssertTrue(s.moveKeys(id, from: 2, by: 1))
        let k = s.project.mainClips[0].keyframes!
        for (_, list) in k.present { XCTAssertEqual(list.map(\.t), [3, 6]) }
        XCTAssertTrue(s.moveKeys(id, from: 6, by: 20), "kept inside the clip")
        XCTAssertEqual(s.keyTimes(id), [3, 10])
        valid(s)
    }

    func testCurves() {
        var s = fresh()
        s.selection = s.project.mainClips[0].id
        XCTAssertTrue(s.setCurve(.rgb, [[0, 0.05], [0.5, 0.62], [1, 0.95]]))
        XCTAssertEqual(s.curve(.rgb)?[1][1], 0.62)
        valid(s)
        // Points out of order are sorted; two at the same x are refused.
        XCTAssertTrue(s.setCurve(.b, [[1, 1], [0, 0.1]]))
        XCTAssertEqual(s.curve(.b)?[0][0], 0)
        XCTAssertFalse(s.setCurve(.g, [[0, 0], [0.5, 0.4], [0.5, 0.6], [1, 1]]))
        XCTAssertEqual(s.lastRefusal?.message, "That curve can't be used · keep points apart")
        XCTAssertNil(s.curve(.g))
        // The straight line (or nil) removes a channel; no curves and nothing else: no look.
        XCTAssertTrue(s.setCurve(.b, [[0, 0], [1, 1]]))
        XCTAssertTrue(s.setCurve(.rgb, nil))
        XCTAssertNil(s.project.mainClips[0].look)
    }

    func testAutoAdjustKeepsToneFields() {
        var s = fresh()
        s.selection = s.project.mainClips[0].id
        XCTAssertTrue(s.changeVisual { $0.adjust = E.Adjust(highlights: 0.3) })
        XCTAssertTrue(s.autoAdjust((0..<300).map { 0.1 + Double($0 % 30) / 300 }))
        let a = s.project.mainClips[0].adjust!
        XCTAssertGreaterThan(a.exposure!, 0)
        XCTAssertEqual(a.highlights, 0.3)
        XCTAssertFalse(s.autoAdjust((0..<300).map { 0.1 + Double($0 % 30) / 300 }), "the same frame again changes nothing")
        valid(s)
    }

    func testAutoAdjustCorrectsADarkWarmGreenFrame() {
        let rgb: [Double] = (0..<900).map { i in
            let k = i / 3, v = 0.15 + 0.1 * Double(k % 10) / 10
            switch i % 3 { case 0: return v * 1.2; case 1: return v * 1.15; default: return v * 0.8 }
        }
        let a = E.autoAdjust(rgb)
        XCTAssertGreaterThan(a.exposure!, 0.3, "brighter")
        XCTAssertGreaterThan(a.contrast!, 0.3, "more contrast")
        XCTAssertLessThan(a.temperature!, 0, "cooler")
        XCTAssertGreaterThan(a.tint!, 0, "less green")
        let m = E.colorMatrix(E.Adjust(temperature: a.temperature, tint: a.tint), nil)
        let px: [Double] = [0.2 * 1.2, 0.2 * 1.15, 0.2 * 0.8]
        let out: [Double] = (0..<3).map { (c: Int) -> Double in
            let a0: Double = m[c * 4] * px[0], a1: Double = m[c * 4 + 1] * px[1], a2: Double = m[c * 4 + 2] * px[2]
            return a0 + a1 + a2 + m[c * 4 + 3]
        }
        XCTAssertGreaterThan(out[2] / out[0], 0.8 / 1.2)
    }

    func testAutoAdjustLeavesABalancedFrame() {
        let rgb: [Double] = (0..<3000).map { i in Double((i / 3) % 100) / 99 * 0.92 + 0.04 }
        let a = E.autoAdjust(rgb, base: E.Adjust(highlights: 0.2))
        XCTAssertEqual(a.highlights, 0.2)
        XCTAssertLessThanOrEqual(abs(a.exposure ?? 0), 0.2)
        XCTAssertNil(a.temperature)
        XCTAssertNil(a.tint)
    }
}

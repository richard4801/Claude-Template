import XCTest
@testable import MuseCore

/// The Recipe's lanes (owner test 2026-11-08): a 29.7 s reference with 7 uneven shots in a 1087 pt lane.
final class RecreateLaneLayoutTests: XCTestCase {
    private let lengths: [Double] = [1.2, 2.5, 6.0, 0.8, 9.4, 3.1, 6.7]
    private let width = 1087.0

    private var spans: [(start: Double, end: Double)] {
        var t = 0.0
        return lengths.map { l in
            defer { t += l }
            return (t, t + l)
        }
    }

    func testTilesSitOnTheirSpansAndNeverOverlap() {
        let duration = lengths.reduce(0, +)
        let tiles = RecreateLaneLayout.tiles(spans, duration: duration, width: width)
        XCTAssertEqual(tiles.count, 7)
        for (i, s) in spans.enumerated() {
            let x0 = s.start / duration * width
            let w = (s.end - s.start) / duration * width
            XCTAssertEqual(tiles[i].x, x0 + 1, accuracy: 0.01)
            XCTAssertEqual(tiles[i].width, w - 2, accuracy: 0.01)
        }
        XCTAssertEqual(RecreateLaneLayout.worstOverlap(tiles), 0)
        XCTAssertLessThanOrEqual(tiles.last?.maxX ?? 0, width)
    }

    func testOverlappingSlotsAreCutAtTheNextStart() {
        let tiles = RecreateLaneLayout.tiles([(0, 2), (1, 3)], duration: 3, width: 300)
        XCTAssertEqual(RecreateLaneLayout.worstOverlap(tiles), 0)
        XCTAssertEqual(tiles[0].width, 98, accuracy: 0.01)
    }

    func testShortTextGetsAMarkerWithoutOverlapping() {
        let items: [(start: Double, end: Double)] = [(0.5, 0.8), (0.9, 1.3), (5, 9), (12.0, 12.4), (12.45, 12.7)]
        let duration = 29.7
        let out = RecreateLaneLayout.texts(items, duration: duration, width: width)
        XCTAssertEqual(RecreateLaneLayout.worstOverlap(out), 0)
        XCTAssertGreaterThanOrEqual(out[0].width, 11)   // 0.3 s is 11 pt: the marker gets the room before the next item
        XCTAssertEqual(out[2].width, 4 / duration * width - 2, accuracy: 0.01)
        XCTAssertTrue(out.allSatisfy { $0.x >= 0 && $0.maxX <= width })
    }

    func testTransitionRoomIsCentredAndShared() {
        let out = RecreateLaneLayout.points([1.2, 1.4, 10, 29.7], duration: 29.7, width: width)
        XCTAssertEqual(RecreateLaneLayout.worstOverlap(out), 0)
        XCTAssertLessThan(out[0].width, 8)
        XCTAssertEqual(out[2].width, 120, accuracy: 0.01)
        XCTAssertEqual(out[3].width, 0)
    }

    func testRulerStepKeepsLabelsApart() {
        XCTAssertEqual(RecreateLaneLayout.rulerStep(duration: 29.7, width: 1087), 2)
        XCTAssertEqual(RecreateLaneLayout.rulerStep(duration: 4.4, width: 1087), 0.5)
        XCTAssertEqual(RecreateLaneLayout.rulerStep(duration: 600, width: 1087), 30)
        for (d, w) in [(29.7, 1087.0), (4.4, 1087.0), (29.7, 300.0), (180.0, 900.0)] {
            let marks = RecreateLaneLayout.rulerMarks(duration: d, width: w)
            let xs = marks.map { RecreateLaneLayout.x($0, duration: d, width: w) }
            for i in xs.indices.dropFirst() { XCTAssertGreaterThanOrEqual(xs[i] - xs[i - 1], 48 - 0.001) }
            XCTAssertTrue(xs.allSatisfy { $0 + 40 <= w })
        }
        XCTAssertEqual(RecreateLaneLayout.rulerLabel(10, step: 2), "0:10")
        XCTAssertEqual(RecreateLaneLayout.rulerLabel(1.5, step: 0.5), "0:01.5")
    }

    func testWorstOverlap() {
        let a = RecreateLaneLayout.Span(x: 0, width: 10)
        let b = RecreateLaneLayout.Span(x: 8, width: 10)
        XCTAssertEqual(RecreateLaneLayout.worstOverlap([b, a]), 2, accuracy: 0.001)
        XCTAssertEqual(RecreateLaneLayout.worstOverlap([a, RecreateLaneLayout.Span(x: 10, width: 5)]), 0)
    }
}

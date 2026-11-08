import XCTest
@testable import MuseCore

/// "Recreate this edit": the Mac's mirror of workstream 1's `muse.recipe/1`, decoded from the server's own fixture
/// (server/api/test/fixtures/recipe-v1.json, copied to Fixtures/recreate).
final class RecreateTests: XCTestCase {
    private func fixture() throws -> RecreateReference {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "recipe-v1", withExtension: "json", subdirectory: "Fixtures/recreate"))
        return try JSONDecoder().decode(RecreateReference.self, from: Data(contentsOf: url))
    }

    func testDecodesTheServerFixture() throws {
        let ref = try fixture()
        XCTAssertEqual(ref.id, "rx_example")
        XCTAssertTrue(ref.isReady)
        XCTAssertNotNil(ref.videoUrl)
        XCTAssertNotNil(ref.posterUrl)
        let r = try XCTUnwrap(ref.recipe)
        XCTAssertEqual(r.schema, "muse.recipe/1")
        XCTAssertEqual(r.slots.count, 3)
        XCTAssertEqual(r.transitions.map(\.kind), ["cut", "crossfade", "flash"])
        XCTAssertEqual(r.text.first?.words, "SUMMER")
        XCTAssertEqual(r.text.first?.fontId, "sans")
        XCTAssertEqual(r.grade?.look?.id, "teal_orange")
        XCTAssertEqual(r.sound?.bpm ?? 0, 120.1, accuracy: 0.001)
        XCTAssertEqual(r.tags, ["example"])
        XCTAssertNotNil(r.summary)
        XCTAssertEqual(r.contactSheet?.tiles?.count, 3)
        XCTAssertEqual(r.slots.first?.rig?.moves?.first?.id, "pan_right")
        XCTAssertNotNil(r.slots.first?.thumbUrl)
    }

    func testSlotsCarryPoseCameraAndSpeed() throws {
        let r = try XCTUnwrap(try fixture().recipe)
        let s2 = r.slots[1]
        XCTAssertEqual(s2.pose?.status, "done")
        XCTAssertEqual(s2.pose?.keypoints?.count, 17)
        XCTAssertEqual(s2.camera?.motion, "zoom_in")
        XCTAssertEqual(RecreateText.camera(s2.camera?.motion), "Push in")
        XCTAssertFalse(s2.speed?.curve?.isEmpty ?? true)
        XCTAssertGreaterThan(s2.length, 0)
        XCTAssertGreaterThanOrEqual(r.durationSec, r.slots.last?.endSec ?? 0)
    }

    func testAnalyzingReferenceAndUnknownFieldsDecode() throws {
        // A reference still being analysed has no recipe; a newer server's extra fields are ignored.
        let json = #"{"id":"rx_1","state":"analyzing","progress":40,"phase":"cuts","somethingNew":{"a":1}}"#
        let ref = try JSONDecoder().decode(RecreateReference.self, from: Data(json.utf8))
        XCTAssertTrue(ref.isAnalyzing)
        XCTAssertNil(ref.recipe)
        XCTAssertEqual(ref.progress, 40)
        let minimal = #"{"id":"rx_2","state":"ready","recipe":{"slots":[{"id":"s1","startSec":0,"endSec":1.5}],"gaps":[{"key":"transition:unknown@1.5","what":"transition","atSec":1.5}]}}"#
        let r = try XCTUnwrap(try JSONDecoder().decode(RecreateReference.self, from: Data(minimal.utf8)).recipe)
        XCTAssertEqual(r.slots.first?.length, 1.5)
        XCTAssertTrue(r.text.isEmpty)
        XCTAssertEqual(r.gaps.first?.key, "transition:unknown@1.5")
    }

    func testFillAndMatch() throws {
        let json = #"""
        {"referenceId":"rx_1","slots":[
          {"slotId":"s1","state":"matched","takeId":"t1","score":0.82,"reason":"Same push-in on a close-up"},
          {"slotId":"s2","state":"to_generate","estimate":{"amount":0.64,"label":"$0.64"}},
          {"slotId":"s3","state":"to_generate","estimate":{"amount":1.2,"label":"$1.20"}}],
         "match":{"overall":0.91,"cuts":0.97,"text":0.88,"ramps":0.8,"grade":0.85,"shots":0.9,"perSlot":[{"slotId":"s1","score":0.93}]}}
        """#
        let fill = try JSONDecoder().decode(RecreateFill.self, from: Data(json.utf8))
        XCTAssertEqual(fill.slots.count, 3)
        XCTAssertEqual(fill.toGenerateTotal, 1.84, accuracy: 1e-9)
        XCTAssertEqual(RecreateText.fill(fill.slots[0].state), "From your takes")
        XCTAssertEqual(RecreateText.percent(fill.match?.overall), "91%")
        XCTAssertEqual(fill.match?.perSlot?.first?.score, 0.93)
    }

    func testPlainWords() {
        XCTAssertEqual(RecreateText.time(1.5), "0:01.5")
        XCTAssertEqual(RecreateText.time(75.3), "1:15.3")
        XCTAssertEqual(RecreateText.transition("unknown"), "Not recognised")
        XCTAssertEqual(RecreateText.speed("speed_up"), "Speeds up")
        XCTAssertNil(RecreateText.speed("none"))
        XCTAssertEqual(RecreateText.percent(nil), "–")
    }
}

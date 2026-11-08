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

    func testDemoFakeServesTheFixtureAndAFill() async throws {
        let api = FakeRecreateAPI()
        let list = try await api.listReferences()
        XCTAssertEqual(list.count, 1)
        let ref = try XCTUnwrap(list.first)
        XCTAssertTrue(ref.isReady)
        XCTAssertNil(ref.videoUrl, "demo mode has no media links")
        XCTAssertEqual(ref.recipe?.slots.count, 3)
        let fill = try await api.fill(ref.id)
        XCTAssertEqual(fill.slots.map(\.state), ["matched", "to_generate", "to_generate"])
        XCTAssertEqual(fill.toGenerateTotal, 1.28, accuracy: 1e-9)
        let applied = try await api.apply(ref.id, RecreateApplyRequest(sessionId: "es_1", baseRevision: 3, slots: ["s1": "t1"]))
        XCTAssertEqual(applied.revision, 4)
        XCTAssertNotNil(applied.match?.overall)
        let kept = try await api.patchReference(ref.id, keep: true, name: "Mine")
        XCTAssertEqual(kept.keep, true)
        XCTAssertEqual(kept.name, "Mine")
        try await api.deleteReference(ref.id)
        let after = try await api.listReferences()
        XCTAssertTrue(after.isEmpty)
    }

    func testReferenceIdsAreChecked() {
        XCTAssertNoThrow(try RecreateIds.check("rx_example"))
        XCTAssertThrowsError(try RecreateIds.check("../v1/admin"))
        XCTAssertThrowsError(try RecreateIds.check("cs_123"))
    }
    /// Owner note 1: the Look swatches are never garish. The fixture's palette has pure green and yellow.
    func testLookSwatchesAreSoftened() throws {
        let raw = try XCTUnwrap(try fixture().recipe?.grade?.swatches)
        XCTAssertTrue(raw.contains { RecreateSwatches.saturation($0) > 0.9 }, "the fixture has a garish colour to soften")
        let shown = RecreateSwatches.soften(raw)
        XCTAssertTrue((3...5).contains(shown.count), "\(shown)")
        let lum = shown.map(RecreateSwatches.luminance)
        XCTAssertEqual(lum, lum.sorted(), "ordered by tone, dark to light")
        for h in shown {
            XCTAssertLessThanOrEqual(RecreateSwatches.saturation(h), RecreateSwatches.maxSaturation, h)
            let v = try XCTUnwrap(RecreateSwatches.rgb(h).map { RecreateSwatches.toHSB($0).v })
            XCTAssertGreaterThanOrEqual(v, RecreateSwatches.brightness.lowerBound - 0.01, h)
            XCTAssertLessThanOrEqual(v, RecreateSwatches.brightness.upperBound + 0.01, h)
        }
        // Hue is kept: the pure green stays a green.
        XCTAssertTrue(shown.contains { h in RecreateSwatches.rgb(h).map { $0.g > $0.r && $0.g > $0.b } ?? false })
        // Short and long palettes still give 3–5; nothing readable gives none.
        XCTAssertEqual(RecreateSwatches.soften(["#00FF00"]).count, 3)
        XCTAssertEqual(RecreateSwatches.soften((0..<8).map { String(format: "#%02X%02X%02X", $0 * 30, 255 - $0 * 30, 128) }).count, 5)
        XCTAssertTrue(RecreateSwatches.soften(["nope"]).isEmpty)
    }

    /// Owner note 2: the total before Build comes from the fill.
    func testMakingLineComesFromTheFill() async throws {
        let api = FakeRecreateAPI()
        let list = try await api.listReferences()
        let ref = try XCTUnwrap(list.first)
        let fill = try await api.fill(ref.id)
        XCTAssertEqual(RecreateText.makingLine(fill), "1 from your takes, 2 to generate · $1.28 in all. You approve before anything is made.")
        XCTAssertEqual(RecreateText.brief(ref.recipe?.slots[1].brief), "Close-up · eye level · flips her hair")
        XCTAssertEqual(RecreateText.analysisStep(phase: "Reading the text", state: "analyzing"), 2)
        XCTAssertEqual(RecreateText.analysisStep(phase: "Waiting", state: "analyzing"), -1)
        XCTAssertEqual(RecreateText.analysisStep(phase: "Done", state: "ready"), RecreateText.analysisSteps.count)
        let applied = try await api.apply(ref.id, RecreateApplyRequest(sessionId: "es_1", slots: [:]))
        XCTAssertEqual(applied.match?.perSlot?.count, 3)
    }

    // MARK: Making the missing shots (estimate → confirm → fill → apply)

    func testSlotEstimateAndFillStartDecode() throws {
        // The server's shapes: a full ShotRequest and ShotEstimate, plus fields this app doesn't know.
        let est = #"""
        {"slotId":"s2","request":{"mode":"reference","prompt":"Close-up, eye level: she flips her hair","duration":2,"quality":"standard"},
         "estimate":{"quality":"standard","label":"Shot · Standard · 768p","resolution":"768p","seconds":2,"takes":1,"mode":"reference",
           "estimate":0.64,"priceLine":"about $0.64 · 2 s","buttonLabel":"Generate · 2 s · $0.64","ok":true,"warnings":["length set to 2 s"],
           "camera":{"moves":[],"guideUsed":false},"test":false,"rig":[],"somethingNew":1}}
        """#
        let e = try JSONDecoder().decode(RecreateSlotEstimate.self, from: Data(est.utf8))
        XCTAssertEqual(e.slotId, "s2")
        XCTAssertEqual(e.estimate.estimate, 0.64, accuracy: 1e-9)
        XCTAssertEqual(e.estimate.priceLine, "about $0.64 · 2 s")
        XCTAssertNil(e.estimate.problem)
        XCTAssertNotNil(e.request)
        // A sparse estimate still decodes (lenient), and a capped one says why.
        let capped = #"{"slotId":"s3","estimate":{"estimate":4.1,"ok":false,"message":"Over the studio's daily limit"}}"#
        let c = try JSONDecoder().decode(RecreateSlotEstimate.self, from: Data(capped.utf8))
        XCTAssertEqual(c.estimate.problem, "Over the studio's daily limit")
        let fill = #"{"slotId":"s2","job":{"id":"job_9","state":"queued","cost":0.64,"engineLabel":"Shot · Standard · 768p","request":{"engine":"suite"},"extra":true}}"#
        let f = try JSONDecoder().decode(RecreateSlotFillStart.self, from: Data(fill.utf8))
        XCTAssertEqual(f.slotId, "s2")
        XCTAssertEqual(f.job.id, "job_9")
        XCTAssertEqual(f.job.cost, 0.64, accuracy: 1e-9)
        XCTAssertTrue(f.job.isActive)
    }

    func testSlotIdsAreChecked() {
        XCTAssertNoThrow(try RecreateIds.slot("s1"))
        XCTAssertNoThrow(try RecreateIds.slot("s1234"))
        XCTAssertThrowsError(try RecreateIds.slot("s12345"))
        XCTAssertThrowsError(try RecreateIds.slot("../fill"))
        XCTAssertThrowsError(try RecreateIds.slot("s1/estimate"))
        XCTAssertThrowsError(try RecreateIds.slot(""))
    }

    /// Demo mode: priced at $0.64 a shot, generating then ready on the following fills, and the build gets job ids.
    func testDemoGeneratesThenBuilds() async throws {
        let api = FakeRecreateAPI()
        let ref = try XCTUnwrap(try await api.listReferences().first)
        let before = try await api.fill(ref.id)
        let toMake = before.slots.filter { $0.state == "to_generate" }.map(\.slotId)
        XCTAssertEqual(toMake, ["s2", "s3"])
        var prices: [String: Double] = [:]
        for s in toMake { prices[s] = try await api.estimateSlot(ref.id, slotId: s, modelId: "m1", quality: nil).estimate.estimate }
        XCTAssertEqual(before.generateTotal(prices: prices), 1.28, accuracy: 1e-9)
        XCTAssertEqual(RecreateText.makingSummary(before, prices: prices, unavailable: ["s3"]), "1 from your takes, 1 to generate, 1 can’t be made · $0.64 in all")
        for s in toMake {
            let started = try await api.fillSlot(ref.id, slotId: s, modelId: "m1", quality: nil)
            XCTAssertEqual(started.slotId, s)
        }
        // Never twice: a slot already being made is refused.
        do {
            _ = try await api.fillSlot(ref.id, slotId: "s2", modelId: "m1", quality: nil)
            XCTFail("filled twice")
        } catch {}
        let generating = try await api.fill(ref.id)
        XCTAssertEqual(generating.slots.map(\.state), ["matched", "generating", "generating"])
        XCTAssertEqual(RecreateText.makingSummary(generating), "1 from your takes, 2 generating")
        var slots: [String: String] = ["s1": "t1"]
        for s in generating.slots where s.state == "generating" { slots[s.slotId] = s.jobId }
        let early = try await api.apply(ref.id, RecreateApplyRequest(sessionId: "es_1", slots: slots))
        XCTAssertEqual(early.waiting, ["s2", "s3"])
        let ready = try await api.fill(ref.id)
        XCTAssertEqual(ready.slots.map(\.state), ["matched", "ready", "ready"])
        XCTAssertEqual(RecreateText.makingSummary(ready), "1 from your takes, 2 generated · nothing to pay")
        slots = ["s1": "t1"]
        for s in ready.slots where s.state == "ready" { slots[s.slotId] = s.jobId }
        XCTAssertEqual(slots["s2"], FakeRecreateAPI.demoJobId("s2"))
        let built = try await api.apply(ref.id, RecreateApplyRequest(sessionId: "es_1", baseRevision: 1, slots: slots))
        XCTAssertEqual(built.waiting ?? [], [])
        XCTAssertEqual(built.revision, 2)
        api.forgetMade()
        let again = try await api.fill(ref.id)
        XCTAssertEqual(again.slots.map(\.state), ["matched", "to_generate", "to_generate"])
        await XCTAssertThrowsErrorAsync { _ = try await api.estimateSlot(ref.id, slotId: "nope", modelId: "m1", quality: nil) }
    }

    private func XCTAssertThrowsErrorAsync(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected an error", file: file, line: line)
        } catch {}
    }
}

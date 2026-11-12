import XCTest
@testable import MuseCore

/// Find layers on the Mac (plans/layers-edit.md): marking things, the price gate above $1, and the result on the clip.
final class EditSuiteLayersTests: XCTestCase {
    typealias E = EditV2

    func testMarkingThings() {
        var k = EditSuite.LayersPick(clipId: "c1", assetId: "src", sourceSec: 2, first: "Her")
        XCTAssertFalse(k.canRun)
        XCTAssertTrue(k.tap(x: 0.5, y: 0.3, aspect: 9.0 / 16))
        XCTAssertTrue(k.canRun)
        XCTAssertTrue(k.add("Dog"))
        XCTAssertFalse(k.canRun, "the dog isn't marked yet")
        XCTAssertTrue(k.box(0.8, 0.9, 0.6, 0.6))
        XCTAssertEqual(k.objects[1].box, LayerObject.Box(x: 0.6, y: 0.6, w: 0.2, h: 0.3, t: 2))
        XCTAssertFalse(k.box(0.1, 0.1, 0.105, 0.3), "a tiny drag is not a box")
        XCTAssertTrue(k.canRun)
        XCTAssertEqual(k.summary, "Her: 1 tap · Dog: box")
        for i in 3...5 { XCTAssertTrue(k.add("T\(i)")) }
        XCTAssertFalse(k.add(), "at most five")
        k.remove(4); k.remove(3); k.remove(2)
        XCTAssertNil(EditSuite.layerObjectsProblem(k.options.objects ?? [], sourceSec: 10))
        XCTAssertEqual(EditSuite.layerObjectsProblem([LayerObject(name: "X", points: [KeepPoint(x: 0.5, y: 0.5, keep: false)])], sourceSec: 10), "Tap X or draw a box round it")
        XCTAssertTrue(EditSuite.layersNeedAsk(1.2)); XCTAssertFalse(EditSuite.layersNeedAsk(1)); XCTAssertFalse(EditSuite.layersNeedAsk(nil))
    }

    func testFakeJobPriceGateAndResult() async throws {
        let api = FakeMuseAPI(speed: 50)
        let takes = try await api.listTakes()
        let take = try XCTUnwrap(takes.first { $0.isVideo })
        let src = EditorSource(takeId: take.id)
        var k = EditSuite.LayersPick(clipId: "c1", assetId: "src", sourceSec: 1, first: "Her")
        k.tap(x: 0.5, y: 0.3)
        await api.setEditorGuardrails(priceUsd: 1.5)
        do { _ = try await api.startEditorJob(EditorJobRequest(kind: .layers, source: src, options: k.options)); XCTFail("above $1 asks first") }
        catch let e as ApiError { XCTAssertEqual(e.code, "price_confirm") }
        var req = EditorJobRequest(kind: .layers, source: src, options: k.options); req.acceptUsd = 1.5
        var job = try await api.startEditorJob(req)
        for _ in 0..<100 where job.isRunning { try await Task.sleep(nanoseconds: 50_000_000); job = try await api.editorJob(id: job.id) }
        let found = try XCTUnwrap(job.result?.layers)
        XCTAssertEqual(found.map(\.name), ["Her"])
        // On the clip: a matte asset, layer l1, the job as its source; a pin to a layer that's gone comes off.
        var p = E.fromV1(EditList(sourceTakeId: take.id, sourceDurationSec: 10), E.SourceFacts(width: 1080, height: 1920, fps: 30))
        let clipId = p.mainClips[0].id
        p.tracks.append(E.Track(id: "tx", kind: .text, items: [.text(E.TextItem(id: "t1", startSec: 0, durationSec: 2, text: "Hi",
            style: E.TextStyle(font: .sans, weight: 700, sizePct: 0.06, color: "#FFFFFF", align: .center)))]))
        let q = try XCTUnwrap(E.applyLayerResults(p, clipId: clipId, jobId: job.id, found: found, sourceAsset: p.assets.first))
        let c = q.mainClips[0]
        XCTAssertEqual(c.layers?.map(\.id), ["l1"])
        XCTAssertEqual(q.assets.first { $0.id == c.layers?[0].matte }?.kind, .video)
        XCTAssertEqual(c.layerSource?.job, job.id)
        XCTAssertNil(E.problem(q, presets: E.filters))
    }
}

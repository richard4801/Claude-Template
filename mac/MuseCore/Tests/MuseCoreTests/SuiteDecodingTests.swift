import XCTest
@testable import MuseCore

/// AI suite (workstream 1): decoding the real API's JSON (captured from server/api in mock mode, `Fixtures/suite`), the
/// pure suite logic, and the member-safety rule (members never see provider or model names).
final class SuiteDecodingTests: XCTestCase {
    private func fixture<T: Decodable>(_ name: String, as: T.Type = T.self) throws -> T {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/suite"), "missing fixture \(name)")
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    func testOwnerCatalog() throws {
        let c: SuiteCatalog = try fixture("catalog_owner")
        XCTAssertTrue(c.enabled)
        XCTAssertTrue(c.test)
        XCTAssertEqual(c.defaultQuality, "draft")
        XCTAssertEqual(c.tiers.map(\.label), ["Draft", "Standard", "HD", "Cinema"])
        XCTAssertEqual(c.tiers[0].models?.first?.name, "MiniMax H3 Lite")
        XCTAssertEqual(c.takesMax, 4)
        XCTAssertEqual(c.recastMaxPeople, 4)
        XCTAssertTrue(c.modes.contains("recast"))
        let cam = c.camera
        XCTAssertEqual(cam.library.count, 16)
        XCTAssertEqual(Array(cam.library.prefix(4)).map(\.tag), ["ugc", "ugc", "ugc", "ugc"], "UGC moves first")
        XCTAssertGreaterThanOrEqual(cam.moves.count, 30)
        let phone = try XCTUnwrap(cam.bodies.first { $0.id == "phone" })
        XCTAssertEqual(phone.render, "body-08-phone")
        XCTAssertEqual(phone.title, "Phone UGC")
        XCTAssertEqual(cam.optics.map { $0.id ?? "" }, ["aperture", "shutter"])
        XCTAssertEqual(cam.grip(for: "dolly_in")?.render, "grip-01-dolly")
        XCTAssertFalse(cam.presets.isEmpty)
        let cine = try XCTUnwrap(cam.presets.first { $0.id == "cinematic" })
        XCTAssertNotNil(cine.spec.rig?.body)
        XCTAssertEqual(cam.limits.paletteColors, 5)
    }

    func testMemberCatalogHasNoEngines() throws {
        let c: SuiteCatalog = try fixture("catalog_member")
        XCTAssertTrue(c.tiers.allSatisfy { $0.models == nil })
        let raw = try String(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "catalog_member", withExtension: "json", subdirectory: "Fixtures/suite")), encoding: .utf8)
        // The tiers say nothing about providers; renders and captions name camera looks only (decision 1).
        let tiers = String(data: try JSONEncoder().encode(c.tiers), encoding: .utf8)!
        XCTAssertTrue(SuiteText.isMemberSafe(tiers), tiers)
        XCTAssertFalse(raw.isEmpty)
    }

    func testEstimates() throws {
        let o: ShotEstimate = try fixture("estimate_owner")
        XCTAssertEqual(o.label, "Shot · HD · 2K")
        XCTAssertEqual(o.buttonLabel, "Generate · 6 s · $1.56 · 2 takes")
        XCTAssertEqual(o.priceLine, "about $1.56 · 6 s · 2 takes")
        XCTAssertEqual(o.estimate, 1.56, accuracy: 1e-9)
        XCTAssertEqual(o.camera.moves, ["dolly_in", "rack_focus"])
        XCTAssertEqual(o.engine?.name, "MiniMax H3")
        XCTAssertEqual(o.caps?.perDay, 25)
        XCTAssertNil(o.problem)

        let m: ShotEstimate = try fixture("estimate_member")
        XCTAssertNil(m.engine)
        XCTAssertNil(m.tried)
        XCTAssertTrue(SuiteText.isMemberSafe(m.label + m.buttonLabel + m.priceLine + m.warnings.joined()))

        let r: ShotEstimate = try fixture("estimate_recast")
        XCTAssertEqual(r.mode, "recast")
        XCTAssertEqual(r.label, "Recast · HD · 1080p")
        XCTAssertEqual(r.cast?.first?.who, "the person on the left")
        XCTAssertEqual(r.keepAudio, true)
    }

    func testShotJobAndDone() throws {
        let j: Job = try fixture("shot_job")
        XCTAssertEqual(j.request.engine, "suite")
        XCTAssertEqual(j.engineLabel, "Shot · Draft · 768p")
        XCTAssertEqual(j.request.quality, "draft")
        XCTAssertTrue(j.isActive)
        let s: SuiteShot = try fixture("shot_done")
        XCTAssertTrue(s.job.isDone)
        XCTAssertEqual(SuiteResultState.of(s.job), .ready)
        XCTAssertEqual(s.engine?.model, "h3-lite")
    }

    func testOwnerSettings() throws {
        let s: SuiteSettings = try fixture("settings")
        XCTAssertEqual(s.mode, "mock")
        XCTAssertEqual(s.caps.perDay, 25)
        XCTAssertEqual(Set(s.ladder.keys), ["draft", "standard", "hd", "cinema"])
        XCTAssertEqual(s.model("h3")?.perSec("768P"), 0.08)
        XCTAssertTrue(s.models.contains { $0.blocked })
    }

    func testRequestEncodingLeavesOutUnset() throws {
        let r = ShotRequest(modelId: "m_demo", prompt: "She waves.", duration: 6, quality: "hd", camera: CameraSpec(rig: CameraRig(body: "super35"), move: SuiteMove(id: "dolly_in", intensity: 0.6)))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
        XCTAssertNil(obj["engineModel"])
        XCTAssertNil(obj["dryRun"])
        XCTAssertNil(obj["mode"])
        let cam = try XCTUnwrap(obj["camera"] as? [String: Any])
        XCTAssertNil(cam["mix"])
        XCTAssertEqual((cam["move"] as? [String: Any])?["id"] as? String, "dolly_in")
        let recast = ShotRequest.recast(clipId: "c1", cast: [CastMember(characterId: "m_demo", personHint: "left")], quality: "standard")
        let ro = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(recast)) as? [String: Any])
        XCTAssertEqual(ro["mode"] as? String, "recast")
        XCTAssertEqual(ro["keepAudio"] as? Bool, true)
        // Directed mode's JSON comes back as a CameraSpec.
        XCTAssertEqual(CameraSpec.fromJSON(#"{"mode":"directed","guide":{"video":{"key":"g.mp4"}}}"#)?.mode, "directed")
    }

    func testMovesMixAtMostTwo() throws {
        let cam = try fixture("catalog_member", as: SuiteCatalog.self).camera
        XCTAssertEqual(SuiteMoves.library(cam, tag: "ugc").map(\.tag).filter { $0 != "ugc" }, [])
        var s = SuiteMoves.toggle("dolly_in", move: nil, mix: nil, catalog: cam)
        XCTAssertEqual(s.move?.id, "dolly_in")
        s = SuiteMoves.toggle("rack_focus", move: s.move, mix: s.mix, catalog: cam)
        XCTAssertEqual(s.mix?.id, "rack_focus")
        XCTAssertEqual(SuiteMoves.mixCount(move: s.move, mix: s.mix), 2)
        // A third move never makes three.
        let third = SuiteMoves.toggle("crane_up", move: s.move, mix: s.mix, catalog: cam)
        XCTAssertEqual(SuiteMoves.mixCount(move: third.move, mix: third.mix), 2)
        // Static doesn't mix: it replaces.
        let st = SuiteMoves.toggle("static", move: SuiteMove(id: "dolly_in"), mix: nil, catalog: cam)
        XCTAssertEqual(st.move?.id, "static")
        XCTAssertNil(st.mix)
        XCTAssertNotNil(st.note)
        // Tapping an active move turns it off.
        XCTAssertNil(SuiteMoves.toggle("dolly_in", move: SuiteMove(id: "dolly_in"), mix: nil, catalog: cam).move)
        XCTAssertEqual(SuiteMoves.line(move: SuiteMove(id: "dolly_in", intensity: 0.6), mix: SuiteMove(id: "rack_focus"), catalog: cam), "Dolly in · 60% + Rack focus")
    }

    func testCameraSummaryAndPresets() throws {
        let cam = try fixture("catalog_member", as: SuiteCatalog.self).camera
        let p = try XCTUnwrap(cam.presets.first { $0.id == "cinematic" })
        let spec = CameraSummary.fromPreset(p)
        XCTAssertEqual(spec.preset, "cinematic")
        XCTAssertEqual(spec.mode, "preset")
        XCTAssertFalse(CameraSummary.line(spec, cam).isEmpty)
        XCTAssertTrue(CameraSummary.renders(spec, cam).allSatisfy { !$0.isEmpty })
        XCTAssertEqual(CameraSummary.line(CameraSpec(), cam), "Auto · the camera follows the scene")
    }

    func testResultStates() {
        XCTAssertEqual(SuiteResultState.of(nil), .empty)
        var j = Job(id: "j", title: "t", modelId: "m", modelName: "M", outfitId: "", request: JobRequest(title: "t", modelId: "m", outfitId: "", clipId: "", engine: "suite"), state: "queued")
        XCTAssertEqual(SuiteResultState.of(j), .queued(position: nil))
        j.state = "running"
        j.progress = 62
        XCTAssertEqual(SuiteResultState.of(j), .rendering(percent: 62, step: 1))
        XCTAssertEqual(SuiteResultState.rendering(percent: 50, step: 1).blur, 22)
        XCTAssertLessThan(SuiteResultState.rendering(percent: 95, step: 2).blur, 22)
        j.state = "failed"
        j.errorCode = "provider_failed"
        if case .failed(let msg) = SuiteResultState.of(j) { XCTAssertTrue(msg.contains("weren't charged")) } else { XCTFail() }
        XCTAssertEqual(SuiteResultState.steps(character: "Noor"), ["Keyframe from Noor’s sheet", "Motion & camera", "Sharpen & finish"])
        XCTAssertEqual(SuiteResultState.queued(position: 2).queueLine, "#2 in line")
    }

    func testStoryboard() {
        var b = Storyboard(title: "Café GRWM", castIds: ["m_demo"], camera: CameraSpec(preset: "cinematic"), quality: "hd",
                           shots: Storyboard.shotList(from: "Street to café door. Order at the counter. Turn to camera, smile."))
        XCTAssertEqual(b.shots.count, 3)
        XCTAssertEqual(b.totalSeconds, 12)
        b.shots[1].moveId = "dolly_in"
        b.shots[1].line = "Oat flat white please!"
        let r = b.request(for: b.shots[1])
        XCTAssertEqual(r.modelId, "m_demo")
        XCTAssertEqual(r.quality, "hd")
        XCTAssertEqual(r.camera?.preset, "cinematic")
        XCTAssertEqual(r.camera?.move?.id, "dolly_in")
        XCTAssertTrue(r.prompt.contains("Oat flat white please!"))
        b.shots[0].jobId = "j1"
        XCTAssertEqual(b.toGenerate.count, 2)
    }

    func testLabelsAndMemberSafety() {
        XCTAssertEqual(SuiteText.shotLabel("hd", resolution: "1080"), "Shot · HD · 1080p")
        XCTAssertEqual(SuiteText.shotLabel("draft", resolution: "768P"), "Shot · Draft · 768p")
        XCTAssertEqual(SuiteText.shotLabel("hd", resolution: "1080p", kind: "Recast"), "Recast · HD · 1080p")
        XCTAssertEqual(SuiteText.buttonLabel(0.78, seconds: 6, takes: 1), "Generate · 6 s · $0.78")
        XCTAssertFalse(SuiteText.isMemberSafe("Kling 4.0 1080p"))
        XCTAssertFalse(SuiteText.isMemberSafe("Rendering on Seedance"))
        XCTAssertTrue(SuiteText.isMemberSafe("Shot · Cinema · 1080p"))
        XCTAssertEqual(SuiteText.tierIds.map(SuiteText.tierLabel), ["Draft", "Standard", "HD", "Cinema"])
    }
}

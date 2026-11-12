import XCTest
@testable import MuseCore

/// Claude sees what is on screen (owner, 2026-11-11): the shared draft's `screen` (server suite/screen.ts) names every
/// input with the id Claude watches or sees it by, and carries the request Generate would send.
final class SuiteScreenTests: XCTestCase {
    func testSlotsBecomeInputsInOrder() {
        let slots = InputSlots()
            .put(SlotId(.image, 0), SlotValue(name: "beach.jpg", image: ImageRef(url: "/uploads/u/beach.jpg"), role: "location"))
            .put(SlotId(.start), SlotValue(name: "open.png", image: ImageRef(url: "/uploads/u/open.png")))
            .put(SlotId(.video), SlotValue(name: "walk.mov", media: SuiteVideoRef(key: "u/walk.mov", seconds: 4), use: "motion"))
            .put(SlotId(.image, 1), SlotValue(name: "late.jpg", progress: 0.4))
        let i = SuiteScreen.inputs(slots)
        XCTAssertEqual(i.map(\.slot), ["start", "reference 1", "reference 2", "video 1"])
        let beach = i.first { $0.label == "beach" }, late = i.first { $0.label == "late" }
        XCTAssertEqual(beach?.role, "location")
        XCTAssertEqual(beach?.url, "/uploads/u/beach.jpg")
        XCTAssertNil(beach?.state)
        XCTAssertEqual(late?.state, "uploading")
        XCTAssertEqual(i[3].key, "u/walk.mov")
        XCTAssertEqual(i[3].kind, "video")
    }

    func testDirectedGuideAndSwapClip() {
        let cam = CameraSpec(mode: "directed", guide: .object(["video": .object(["key": .string("c/grey.mp4"), "seconds": .number(6)]),
                                                               "use": .string("blocking"), "cameraSessionId": .string("cs_1")]))
        let g = SuiteScreen.guide(cam)
        XCTAssertEqual(g?.slot, "guide")
        XCTAssertEqual(g?.cameraSessionId, "cs_1")
        XCTAssertEqual(g?.key, "c/grey.mp4")
        XCTAssertNil(SuiteScreen.guide(CameraSpec(mode: "preset")))
        let c = Clip(id: "cl_1", name: "Dance from a link", durationSec: 6, width: 720, height: 1280, fps: 30, checks: [])
        XCTAssertEqual(SuiteScreen.clip(c, slot: "swap.clip").clipId, "cl_1")
    }

    func testJsonCarriesTheRequestWithoutTheDraftAndTimeOnlyWhenAsked() {
        var r = ShotRequest(mode: "swap", modelId: "m_1", prompt: "", quality: "hd", clipId: "cl_1")
        r.draft = SuiteDraft(tool: "swap")
        let j = SuiteScreen.json(tool: "swap", request: r, inputs: [SuiteScreen.Input(slot: "swap.clip", kind: "video", clipId: "cl_1")], at: nil)
        guard case .object(let o) = j, case .object(let req)? = o["request"] else { return XCTFail("no request") }
        XCTAssertNil(o["at"])
        XCTAssertEqual(req["clipId"], .string("cl_1"))
        XCTAssertNil(req["draft"])
        guard case .object(let t) = SuiteScreen.json(tool: "shot", request: nil, inputs: []) else { return XCTFail() }
        XCTAssertNotNil(t["at"])
        XCTAssertNil(t["request"])
    }

    func testSettingsAndPhotoReferences() {
        let refs = [ShootRef(image: ImageRef(url: "/uploads/u/pose.jpg"), guides: [.pose]), ShootRef(image: ImageRef(url: "/uploads/u/look.jpg"), guides: [.look, .scene])]
        let inputs = SuiteScreen.photoReferences(refs)
        XCTAssertEqual(inputs.map(\.slot), ["reference 1", "reference 2"])
        XCTAssertEqual(inputs[1].role, "look")
        XCTAssertEqual(inputs[1].url, "/uploads/u/look.jpg")
        let s: [String: JSONValue] = ["background": .string("photo"), "backgroundName": .string("Rooftop"), "promptOn": .bool(false)]
        guard case .object(let t) = SuiteScreen.json(tool: "swap", request: nil, inputs: [], settings: s, at: nil) else { return XCTFail() }
        XCTAssertEqual(t["settings"], .object(s))
        guard case .object(let e) = SuiteScreen.json(tool: "swap", request: nil, inputs: [], at: nil) else { return XCTFail() }
        XCTAssertNil(e["settings"]) // none: left out
    }
}

import XCTest
@testable import MuseCore

/// The prompt engine must word things exactly like prototype/desktop/desktop.js (`shootPrompt`, `videoPrompt`).
final class PromptTests: XCTestCase {
    private func siennaIdentity(never: [String]) -> PromptIdentity {
        PromptIdentity(name: "Sienna Vale", look: SampleData.siennaLook, referenceCount: 6, neverAdd: never)
    }

    func testMatchesDesktopJS() throws {
        let root = try XCTUnwrap(fixture("desktop_fixture") as? [String: Any])
        let cases = try XCTUnwrap(root["prompts"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 6)
        var checked = 0
        for c in cases {
            let input = c["input"] as! [String: Any]
            let never = input["never"] as? [String] ?? ["tattoos", "rings"]
            // The JS prints "Never add: , logos" for an empty list; the app drops the blank (tested separately below).
            if never.isEmpty { continue }
            var s = ShootSettings()
            if let v = input["scene"] as? String { s.scene = v }
            if let v = input["sceneCustom"] as? String { s.sceneCustom = v }
            if let v = input["shot"] as? String { s.shot = v }
            if let v = input["lens"] as? Int { s.lens = v }
            if let v = input["aperture"] as? String { s.aperture = v }
            if let v = input["light"] as? String { s.light = v }
            if let v = input["grade"] as? String { s.grade = v }
            if let v = input["direction"] as? String { s.direction = v }
            if let v = input["lockSeed"] as? Bool { s.lockSeed = v }
            let outfit = (input["outfit"] as? Int ?? 0) == 1 ? "Crystal dress" : "Green set"
            let id = siennaIdentity(never: never)

            let expected = c["shoot"] as! [String: String]
            let slots = PromptEngine.shoot(identity: id, outfitName: outfit, settings: s)
            let nonEmpty = expected.filter { !$0.value.isEmpty }
            XCTAssertEqual(Set(slots.map(\.key)), Set(nonEmpty.keys), "\(input)")
            for slot in slots { XCTAssertEqual(slot.text, expected[slot.key], "\(slot.key) \(input)") }
            XCTAssertEqual(slots.map(\.key).first, "identity")
            XCTAssertEqual(slots.map(\.key).last, "seed")

            let spec = RenderSpec(engine: Engine(id: input["engine"] as? String ?? "h3"), use: ClipUse(id: input["use"] as? String ?? "first"),
                                  steps: input["steps"] as? Int ?? 10, takes: input["takes"] as? Int ?? 1)
            let video = PromptEngine.video(VideoPromptInput(identity: id, outfitName: outfit, performer: .sample,
                                                            keepBackground: (input["bg"] as? String ?? "keep") == "keep",
                                                            backgroundMotion: input["motion"] as? String ?? "subtle",
                                                            keepAudio: input["keepAudio"] as? Bool ?? true, spec: spec))
            XCTAssertEqual(video, c["video"] as! String, "\(input)")
            checked += 1
        }
        XCTAssertEqual(checked, 5)
    }

    func testEmptyNeverAddListIsDropped() {
        let id = siennaIdentity(never: [])
        let slots = PromptEngine.shoot(identity: id, outfitName: "Green set", settings: ShootSettings())
        XCTAssertEqual(slots.first { $0.key == "negative" }?.text, "Never add: logos, extra fingers, warped jewellery.")
        let video = PromptEngine.video(VideoPromptInput(identity: id, outfitName: "Green set"))
        XCTAssertTrue(video.contains("from the outfit reference images.\nsteps"), video)
        XCTAssertFalse(video.contains("None of"))
    }

    func testDirectionAndHouseStyleAreDroppedWhenBlank() {
        var s = ShootSettings()
        s.direction = "   "
        let slots = PromptEngine.shoot(identity: siennaIdentity(never: ["tattoos"]), outfitName: "Green set", settings: s, houseStyle: " ")
        XCTAssertNil(slots.first { $0.key == "direction" })
        XCTAssertNil(slots.first { $0.key == "style" })
    }

    func testSlotBodyStripsTheLabel() {
        XCTAssertEqual(PromptSlot("scene", "Scene: café window.").body, "café window.")
        XCTAssertEqual(PromptSlot("camera", "Camera: close shot, 85mm lens").body, "close shot, 85mm lens")
    }

    func testCustomSceneWinsOverChip() {
        var s = ShootSettings()
        s.scene = "Beach noon"
        s.sceneCustom = "  neon arcade "
        XCTAssertEqual(s.effectiveScene, "neon arcade")
        s.resetCamera()
        XCTAssertEqual(s.lens, 35)
    }

    func testSheetShotUsesAngleFraming() {
        let p = PromptEngine.sheetShot(identity: siennaIdentity(never: ["rings"]), angle: .profile)
        XCTAssertTrue(p.contains("face · profile shot on a plain light-grey studio background"))
        XCTAssertTrue(p.contains("Never add: rings, logos, extra fingers, warped jewellery."))
    }

    func testNewModelWithoutLookStillReadsWell() {
        let m = MuseModel(id: "x", name: "Noor", age: 27, niche: "Beauty", slots: [SheetSlot(key: "face", image: .asset("face"))])
        let p = PromptEngine.shootText(identity: m.promptIdentity, outfitName: "Green set", settings: ShootSettings())
        XCTAssertTrue(p.hasPrefix("Noor: 27-year-old woman. Identity from 1 locked reference image."), p)
    }
}

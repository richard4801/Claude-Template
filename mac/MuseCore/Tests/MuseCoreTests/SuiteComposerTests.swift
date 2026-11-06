import XCTest
@testable import MuseCore

/// AI suite (workstream 1): the video composer's pure rules — the catalogue's visible lists (real API JSON), chip
/// summaries, presets into chips, the camera spec, prompt tokens and the Look. Same cases as Android's SuiteComposerTest.
final class SuiteComposerTests: XCTestCase {
    private var cat: CameraCatalog { SuiteDemoCatalog.catalog.camera }
    private func move(_ id: String) -> SuiteMoveOption { cat.moves.first { $0.id == id }! }

    func testTheCatalogueIsTheServersComposerCatalogue() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "catalog_member", withExtension: "json", subdirectory: "Fixtures/suite"))
        let c = try JSONDecoder().decode(SuiteCatalog.self, from: Data(contentsOf: url)).camera
        XCTAssertEqual(ComposerCatalog.visible(c.bodies).map(\.label),
                       ["Phone", "Creator camera", "Cinema camera", "35mm film", "16mm film", "Super 8", "Large format 65mm", "DV camcorder", "Webcam", "CCTV"])
        XCTAssertEqual(ComposerCatalog.visible(c.lenses).count, 9)
        XCTAssertEqual(ComposerCatalog.focalSteps(c), [14, 24, 35, 50, 85, 135])
        XCTAssertEqual(ComposerCatalog.visible(c.apertures).map(\.id), ["f1.4", "f2.8", "f5.6", "f11"])
        XCTAssertTrue(ComposerCatalog.visible(c.frameRates).isEmpty)
        XCTAssertEqual(c.bodies.first { $0.id == "super35" }?.mergedInto, "cinema_digital")
        XCTAssertTrue(c.palettes.allSatisfy { $0.swatches.count == 5 && $0.lut != nil })
        XCTAssertEqual(c.move("motion_blur")?.group, "special")
        XCTAssertEqual(c.moveGroups.first?.label, "Featured")
        XCTAssertEqual(cat.bodies.count, c.bodies.count, "the demo catalogue is the same capture")
    }

    func testAChipShowsOnlyTheNonAutoValues() {
        let s0 = ComposerSettings()
        XCTAssertEqual(ComposerCatalog.summaries(s0, cat).dropFirst().map(\.value), ["Auto", "Auto", "Auto", "Auto"])
        XCTAssertEqual(ComposerCatalog.summary(.references, s0, cat, refs: 0, refsMax: 9).value, "0/9")
        var s = s0
        s.body = "film_35"
        s.lens = "anamorphic"
        XCTAssertEqual(ComposerCatalog.summary(.camera, s, cat).text(), "Camera · 35mm film, Anamorphic")
        var merged = s0
        merged.body = "super35"
        XCTAssertEqual(ComposerCatalog.summary(.camera, merged, cat).value, "Cinema camera")
        var long = s
        long.focalMm = 50
        long.aperture = "f1.4"
        long.height = "low"
        long.shotSize = "mcu"
        let t = ComposerCatalog.summary(.camera, long, cat).text(max: 32)
        XCTAssertLessThanOrEqual(t.count, 32)
        XCTAssertTrue(t.hasSuffix("…"))
        var look = s0
        look.palette = "teal_orange"
        XCTAssertEqual(ComposerCatalog.summary(.look, look, cat).text(), "Look · Teal & orange")
        XCTAssertTrue(long.isSet(.camera))
        XCTAssertFalse(long.reset(.camera).isSet(.camera))
    }

    func testAPresetFillsTheChipsWithVisibleValues() {
        let s = ComposerSettings.fromPreset(cat, "phone_ugc")
        XCTAssertEqual(s.body, "phone")
        XCTAssertEqual(s.focalMm, 24)
        XCTAssertEqual(s.aperture, "f11")
        XCTAssertEqual(s.preset, "phone_ugc")
        XCTAssertEqual(ComposerSettings.fromPreset(cat, "documentary").lens, "warm_vintage")
    }

    func testMovesAndTheCameraSpec() {
        XCTAssertNil(ComposerSettings().cameraSpec())
        var p = PromptTokens.text("Walks in")
        p = p.addMove(move("dolly_in"), catalog: cat).0
        let (same, why) = p.addMove(move("dolly_out"), catalog: cat)
        XCTAssertEqual(same, p)
        XCTAssertEqual(why, "Dolly out reveal can't be combined with Dolly in")
        p = p.addMove(move("rack_focus"), catalog: cat).0
        XCTAssertEqual(p.moves.count, 2)
        XCTAssertEqual(p.addMove(move("pan_left"), catalog: cat).1, "Up to 2 moves · remove one first")
        XCTAssertNotNil(PromptTokens().addMove(move("static"), catalog: cat).0.addMove(move("dolly_in"), catalog: cat).1)
        let spec = ComposerSettings(body: "film_35", palette: "teal_orange").cameraSpec(moves: p.moves)
        XCTAssertEqual(spec?.rig?.body, "film_35")
        XCTAssertEqual(spec?.move?.id, "dolly_in")
        XCTAssertEqual(spec?.mix?.id, "rack_focus")
        XCTAssertNil(spec?.angle)
    }

    func testMentionsRemovalReorderingAndTheServersText() {
        var p = PromptTokens.text(" walks into the café, then smiles.").addMention(kind: "character", id: "m_maya", label: "Maya", at: Caret(0, 0)).0
        XCTAssertEqual(PromptTokens().addMention(kind: "outfit", id: "o1", label: "Green set").1, "Pick a character first")
        p = p.addMention(kind: "outfit", id: "o_green", label: "Green set").0
        p = p.addMove(move("dolly_in"), at: Caret(1, 9), catalog: cat).0
        XCTAssertEqual(p.display(), "@Maya walks in#Dolly into the café, then smiles.@Green set")
        XCTAssertEqual(p.promptText(), "Maya walks in to the café, then smiles. Green set")
        let (r, msg) = p.addMention(kind: "character", id: "m_ivy", label: "Ivy")
        XCTAssertEqual(msg, "Maya replaced by Ivy")
        XCTAssertEqual(r.characterId, "m_ivy")
        let charKey = p.parts.first { if case .mention(let k, _, _, _) = $0 { return k == "character" } else { return false } }!.key!
        let noChar = p.remove(key: charKey)
        XCTAssertNil(noChar.characterId)
        XCTAssertNil(noChar.outfitId)
        XCTAssertFalse(zip(noChar.parts, noChar.parts.dropFirst()).contains { $0.isText && $1.isText })
        let mv = p.moves[0].key!
        XCTAssertEqual(p.reorder(key: mv, to: 0).parts.firstIndex { $0.key == mv }, 0)
        XCTAssertEqual(p.setIntensity(key: mv, 80).moves[0].move?.intensity, 0.8)
    }

    func testTheTriggerBeingTyped() {
        XCTAssertEqual(PromptTokens.activeTrigger("She walks #dol", caret: 14)?.char, "#")
        XCTAssertEqual(PromptTokens.activeTrigger("She walks #dol", caret: 14)?.query, "dol")
        XCTAssertEqual(PromptTokens.activeTrigger("@Ma", caret: 3)?.query, "Ma")
        XCTAssertNil(PromptTokens.activeTrigger("email me@home", caret: 13))
        XCTAssertNil(PromptTokens.activeTrigger("#dolly in", caret: 9))
        XCTAssertEqual(PromptTokens.searchMoves(cat, "dolly").first?.id, "dolly_in")
    }

    func testSearchFindsAliases() throws {
        // "single shot" finds Tempo "One take"; "reveal" finds Rise to reveal (catalog aliases).
        let oneTake = SuiteOption(id: "single_shot", label: "One take", aliases: ["single shot", "oner"])
        XCTAssertTrue(oneTake.matches("Single shot"))
        XCTAssertTrue(oneTake.matches("one"))
        XCTAssertTrue(oneTake.matches(""))
        XCTAssertFalse(oneTake.matches("slow"))
        let rise = SuiteMoveOption(id: "rise_reveal", label: "Rise to reveal", category: "vertical", aliases: ["pedestal up"])
        XCTAssertTrue(rise.matches("pedestal"))
        XCTAssertTrue(rise.matches("rise-to"))
        let json = Data(#"{"id":"single_shot","label":"One take","aliases":["single shot"]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(SuiteOption.self, from: json).aliases, ["single shot"])
        XCTAssertEqual(try JSONDecoder().decode(SuiteOption.self, from: Data(#"{"id":"calm"}"#.utf8)).aliases, [])
    }

    func testTheRequestAndTheLook() async throws {
        let p = PromptTokens.text(" waves").addMention(kind: "character", id: "m_maya", label: "Maya", at: Caret(0, 0)).0
        let r = composerRequest(p, ComposerSettings(palette: "hyper_neon"), quality: "hd")
        XCTAssertEqual(r.modelId, "m_maya")
        XCTAssertEqual(r.prompt, "Maya waves")
        XCTAssertNil(r.gradeLook)
        XCTAssertEqual(composerRequest(p, ComposerSettings(palette: "hyper_neon", gradeLook: false)).gradeLook, false)
        XCTAssertEqual(SuiteLooks.look(for: r, camera: cat)?.lut, "palette:hyper_neon")
        XCTAssertEqual(SuiteLooks.look(for: ShotRequest(camera: CameraSpec(preset: "noir")), camera: cat)?.lut, "pack:cine-noir")
        var off = r
        off.gradeLook = false
        XCTAssertNil(SuiteLooks.look(for: off, camera: cat))
        // Demo mode: the estimate names the Look, like the server.
        let api = FakeMuseAPI(speed: 0, genDelay: 0.01)
        _ = try await api.signIn(SignInRequest(email: "owner@studio.com", password: "x"))
        let e = try await api.suiteEstimate(ShotRequest(modelId: SampleData.demo, prompt: "She waves.", duration: 6, quality: "hd", camera: CameraSpec(palette: CameraPalette(preset: "hyper_neon"))))
        XCTAssertEqual(e.look?.lut, "palette:hyper_neon")
    }
}

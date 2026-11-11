import XCTest
@testable import MuseCore

/// AI suite · the Photo tool (workstream 3, plans/video-composer.md "Photo tool"): the request the composer sends, the
/// estimate and result shapes, the tool on the shell, and demo mode's estimate (priced like its shoot preview, still rig
/// rules only) and stills ("Photo · …" takes).
final class SuitePhotoTests: XCTestCase {
    private let cat = SuiteDemoCatalog.catalog.camera

    private func json<T: Encodable>(_ v: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(v)) as? [String: Any])
    }

    private func api() async throws -> FakeMuseAPI {
        let a = FakeMuseAPI(speed: 0, genDelay: 0.01)
        _ = try await a.signIn(SignInRequest(email: "owner@studio.com", password: "x"))
        return a
    }

    /// "@Maya on a rooftop #Dolly in".
    private func tokens(move: Bool = true) throws -> PromptTokens {
        var t = PromptTokens.text(" on a rooftop at dusk").addMention(kind: "character", id: SampleData.demo, label: "Maya", at: Caret(0, 0)).0
        if move { t = t.addMove(try XCTUnwrap(cat.move("dolly_in")), catalog: cat).0 }
        return t
    }

    private func ref(_ g: ShootGuide, _ n: String = "a") -> ShootRef { ShootRef(image: ImageRef(url: "https://x/\(n).jpg"), guides: [g]) }

    // MARK: The tool on the shell

    func testPhotoIsAToolOnTheShell() {
        let p = ComposerTool.photo
        XCTAssertEqual(p.title, "Photo")
        XCTAssertEqual(p.tagline, "Stills of your character")
        XCTAssertEqual(p.wireId, "photo")
        XCTAssertTrue(ComposerTool.shell.contains(.photo))
        XCTAssertEqual(p.chips, [.style, .camera, .look, .lighting], "no References chip: references are a slot")
        XCTAssertEqual(p.required, [], "a character OR an image (owner 2026-11-11)")
        XCTAssertEqual(p.optional, [.character, .product, .references])
        XCTAssertTrue(p.showsPrompt)
        XCTAssertFalse(p.promptPlaceholder.contains("#"), "no camera moves in a still")
        XCTAssertFalse(p.comingSoon)
        XCTAssertTrue(p.isStill)
        XCTAssertFalse(ComposerTool.shot.isStill)
        // The PRODUCT slot doesn't depend on a video tier's inputs.
        let cards = ComposerSlots.cards(.photo, inputs: .none)
        XCTAssertEqual(cards.map(\.slot), [.character, .product, .references])
        XCTAssertEqual(cards.map(\.optional), [true, true, true])
        XCTAssertEqual(ComposerSlot.references.label, "References")
        // An older catalog without "photo" keeps it available.
        let old = SuiteCatalog(enabled: true, test: false, tiers: [], camera: CameraCatalog(), tools: [SuiteToolStatus(id: "shot", available: true)])
        XCTAssertFalse(ComposerTool.photo.isComingSoon(in: old))
        XCTAssertTrue(ComposerTool.photo.isComingSoon(in: SuiteCatalog(enabled: true, test: false, tiers: [], camera: CameraCatalog(),
                                                                       tools: [SuiteToolStatus(id: "photo", available: false)])))
    }

    func testTheDemoCatalogListsPhoto() {
        XCTAssertEqual(SuiteDemoCatalog.catalog.tools.first { $0.id == "photo" }, SuiteToolStatus(id: "photo", available: true))
    }

    // MARK: Composer → PhotoRequest

    func testTheRequestDropsMovementAndTempo() throws {
        var d = ComposerDraft(tool: .photo, tokens: try tokens(), outfitId: "o_1")
        d.settings = ComposerSettings(body: "film35", focalMm: 85, height: "low", shotSize: "cu", genre: "noir", tempo: "slow_motion", palette: "teal_orange", lighting: "window")
        let r = try XCTUnwrap(d.photoRequest(PhotoDraft(count: 2)))
        XCTAssertEqual(r.modelId, SampleData.demo)
        XCTAssertEqual(r.outfitId, "o_1")
        XCTAssertEqual(r.prompt, "Maya on a rooftop at dusk", "no #move in the prompt")
        XCTAssertEqual(r.count, 2)
        let c = try XCTUnwrap(r.camera)
        XCTAssertNil(c.move)
        XCTAssertNil(c.mix)
        XCTAssertNil(c.style?.tempo, "no tempo in a still")
        XCTAssertEqual(c.style?.genre, "noir")
        XCTAssertEqual(c.rig?.body, "film35")
        XCTAssertEqual(c.rig?.focalMm, 85)
        XCTAssertEqual(c.angle?.shotSize, "cu")
        XCTAssertEqual(c.lighting?.preset, "window")
        XCTAssertEqual(c.palette?.preset, "teal_orange")
        XCTAssertNil(r.presetId)
        XCTAssertNil(r.gradeLook, "on by default: not sent")
        let j = try json(r)
        XCTAssertEqual(Set(j.keys), ["modelId", "outfitId", "prompt", "camera", "count", "title"], "the server is strict: nil fields stay out")
        let cam = try XCTUnwrap(j["camera"] as? [String: Any])
        XCTAssertNil(cam["move"])
        XCTAssertNil((cam["style"] as? [String: Any])?["tempo"])
    }

    func testAPresetSendsItsIdAndOnlyTheLook() throws {
        var d = ComposerDraft(tool: .photo, tokens: try tokens(move: false))
        d.settings = ComposerSettings(body: "phone", stock: "bw_film", gradeLook: false, lighting: "window")
        let r = try XCTUnwrap(d.photoRequest(PhotoDraft(presetId: "tpl_mirror")))
        XCTAssertEqual(r.presetId, "tpl_mirror")
        XCTAssertEqual(r.count, 4, "default 4")
        XCTAssertNil(r.camera?.rig?.body, "the preset sets its own camera")
        XCTAssertNil(r.camera?.lighting, "and light")
        XCTAssertEqual(r.camera?.rig?.look, "bw_film", "the Look still grades the stills")
        XCTAssertEqual(r.gradeLook, false)
        XCTAssertNil(ComposerSettings().photoCameraSpec(preset: true), "all Auto: no camera")
    }

    func testReferencesProductAndLimits() throws {
        let d = ComposerDraft(tool: .photo, tokens: try tokens(move: false))
        var bad = ref(.pose, "b")
        bad.guides = []
        let refs = [ref(.pose), bad, ref(.look, "c"), ref(.scene, "d"), ref(.pose, "e")]
        let r = try XCTUnwrap(d.photoRequest(PhotoDraft(count: 9, references: refs), product: ImageRef(url: "https://x/p.jpg")))
        XCTAssertEqual(r.references?.map(\.image.url), ["https://x/a.jpg", "https://x/c.jpg", "https://x/d.jpg"], "valid ones, up to 3")
        XCTAssertEqual(r.productImage?.url, "https://x/p.jpg")
        XCTAssertEqual(r.count, 4, "clamped to 1–4")
        let j = try json(r)
        let first = try XCTUnwrap((j["references"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["guides"] as? [String], ["pose"])
        XCTAssertNil(ComposerDraft(tool: .photo).photoRequest(PhotoDraft()), "no character and no image, no request")
        XCTAssertEqual(ComposerDraft(tool: .photo).photoMissing(PhotoDraft()), "Pick a character or add an image")
        // No character but an image (owner 2026-11-11): the request goes without modelId, outfit or product.
        let free = try XCTUnwrap(ComposerDraft(tool: .photo).photoRequest(PhotoDraft(references: [ref(.look)]), product: ImageRef(url: "https://x/p.jpg")))
        XCTAssertNil(free.modelId)
        XCTAssertNil(free.productImage)
        XCTAssertNil(try json(free)["modelId"], "left out of the JSON")
        XCTAssertNil(ComposerDraft(tool: .photo).photoMissing(PhotoDraft(references: [ref(.look)])))
        XCTAssertEqual(ComposerDraft(tool: .photo).photoMissing(PhotoDraft(presetId: "t1", references: [ref(.look)])), "Presets need a character · pick one with @")
        XCTAssertNil(ComposerDraft(tool: .photo).photoRequest(PhotoDraft(presetId: "t1", references: [ref(.look)])))
        XCTAssertNil(d.photoMissing(PhotoDraft()))
        XCTAssertEqual(PhotoRequest(modelId: "m", count: 5).problem, "Pick 1 to 4 photos")
        XCTAssertEqual(PhotoRequest(modelId: "m", references: [bad]).problem, "Each reference needs a photo and at least one guide")
    }

    func testADirectedCameraLosesItsMoves() throws {
        var d = ComposerDraft(tool: .photo, tokens: try tokens(move: false))
        d.directed = CameraSpec(mode: "directed", rig: CameraRig(body: "film35"), move: SuiteMove(id: "dolly_in"), style: CameraStyle(genre: "noir", tempo: "calm"))
        let c = try XCTUnwrap(d.photoRequest(PhotoDraft())?.camera)
        XCTAssertNil(c.move)
        XCTAssertNil(c.style?.tempo)
        XCTAssertEqual(c.rig?.body, "film35")
    }

    // MARK: Shapes

    func testTheEstimateDecodesTheServersShape() throws {
        let raw = #"""
        {"tool":"photo","count":4,"perPhoto":0.08,"estimate":0.32,"priceLine":"about $0.32 · 4 photos","buttonLabel":"Generate · 4 photos · $0.32","ok":true,
         "warnings":["Movement doesn’t apply to photos"],"rig":[{"id":"worm_close","severity":"warn","reason":"r","fix":{"label":"Low angle","patch":{"camera":{"angle":{"height":"low"}}}}},{"id":"from_the_future"}],
         "look":{"id":"teal_orange","kind":"palette","label":"Teal & orange","lut":"palette:teal_orange"},"prompt":"Maya: …","extra":1}
        """#
        let e = try JSONDecoder().decode(PhotoEstimate.self, from: Data(raw.utf8))
        XCTAssertEqual(e.count, 4)
        XCTAssertEqual(e.estimate, 0.32, accuracy: 1e-9)
        XCTAssertEqual(e.rig.map(\.id), ["worm_close"], "an unreadable warning is skipped")
        XCTAssertEqual(e.look?.id, "teal_orange")
        XCTAssertNil(e.preset)
        XCTAssertEqual(GeneratePrice.photo(e), .price("Generate · 4 photos · $0.32"))
        XCTAssertEqual(GeneratePrice.photo(nil), .unknown)
        let s = e.asShotEstimate
        XCTAssertEqual(s.priceLine, "about $0.32 · 4 photos")
        XCTAssertEqual(s.label, "Photo · 4 photos")
        XCTAssertEqual(s.look?.id, "teal_orange")
        XCTAssertNil(s.problem)
        // Labels the app builds itself match the server's photoButton.
        XCTAssertEqual(PhotoEstimate.buttonLabel(0.08, count: 1), "Generate · 1 photo · $0.08")
        let minimal = try JSONDecoder().decode(PhotoEstimate.self, from: Data(#"{"count":2,"perPhoto":0.1}"#.utf8))
        XCTAssertEqual(minimal.buttonLabel, "Generate · 2 photos · $0.20")
        let res = try JSONDecoder().decode(PhotoResult.self, from: Data(#"{"tool":"photo","takes":[{"id":"s1","kind":"shot","title":"Photo · Rooftop","label":"x","thumb":{"url":"/u/a.jpg"}}]}"#.utf8))
        XCTAssertEqual(res.takes.map(\.title), ["Photo · Rooftop"])
    }

    func testTheStillRules() {
        let w = { (id: String) in RigWarning(id: id, reason: "", fix: RigFix(label: "", patch: .object([:]))) }
        XCTAssertEqual(PhotoRig.still(["deep_focus", "prompt_move", "talk_move", "no_reveal", "prompt_size"].map(w)).map(\.id), ["deep_focus", "prompt_size"])
        let r = PhotoRequest(modelId: "m", camera: CameraSpec(rig: CameraRig(body: "phone")))
        XCTAssertEqual(RigChoices(r), RigChoices(camera: r.camera, speaking: nil))
    }

    // MARK: Demo mode

    func testTheFakeEstimateIsPricedLikeItsShootPreview() async throws {
        let a = try await api()
        let shoot = try await a.shootPreview(ShootRequest(modelId: SampleData.demo, outfitId: "", scene: "rooftop", prompt: nil, count: 4))
        let e = try await a.suitePhotoEstimate(PhotoRequest(modelId: SampleData.demo, prompt: "rooftop"))
        XCTAssertEqual(e.tool, "photo")
        XCTAssertEqual(e.count, 4)
        XCTAssertEqual(e.estimate, shoot.estimate, accuracy: 1e-9)
        XCTAssertEqual(e.perPhoto * 4, e.estimate, accuracy: 1e-9)
        XCTAssertEqual(e.buttonLabel, PhotoEstimate.buttonLabel(e.estimate, count: 4))
        XCTAssertTrue(e.ok)
        XCTAssertNotNil(e.prompt)
        // References count in the price, as in a shoot.
        let withRefs = try await a.suitePhotoEstimate(PhotoRequest(modelId: SampleData.demo, prompt: "rooftop", references: [ref(.pose), ref(.look, "b")]))
        XCTAssertGreaterThan(withRefs.estimate, e.estimate)
        let one = try await a.suitePhotoEstimate(PhotoRequest(modelId: SampleData.demo, count: 1))
        XCTAssertEqual(one.count, 1)
        XCTAssertTrue(one.buttonLabel.hasPrefix("Generate · 1 photo · "))
    }

    func testTheFakeReturnsOnlyTheStillRules() async throws {
        let a = try await api()
        // Worm's-eye on a close-up (worm_close), and a prompt that names another move than the chip (prompt_move, not a still rule).
        let cam = CameraSpec(mode: "preset", move: SuiteMove(id: "dolly_in"), angle: CameraAngle(height: "worm", shotSize: "cu"), style: CameraStyle(tempo: "calm"))
        let req = PhotoRequest(modelId: SampleData.demo, prompt: "the camera whip pans across her", camera: cam)
        let shotRig = FakeRigCheck.check(prompt: req.prompt, camera: cam, speaking: false)
        XCTAssertTrue(shotRig.contains { $0.id == "prompt_move" }, "a shot would warn about the move")
        let e = try await a.suitePhotoEstimate(req)
        XCTAssertTrue(e.rig.contains { $0.id == "worm_close" })
        XCTAssertTrue(e.rig.allSatisfy { PhotoRig.stillRules.contains($0.id) }, "\(e.rig.map(\.id))")
        XCTAssertEqual(e.warnings, ["Movement doesn’t apply to photos", "Tempo doesn’t apply to photos"])
    }

    func testTheFakeRunsAPresetAndMakesPhotoTakes() async throws {
        let a = try await api()
        let list = await a.listTemplates(TemplateQuery())
        let tpl = try XCTUnwrap(list.first)
        let e = try await a.suitePhotoEstimate(PhotoRequest(modelId: SampleData.demo, camera: CameraSpec(rig: CameraRig(look: "bw_film")), presetId: tpl.id))
        XCTAssertEqual(e.preset, PhotoPresetRef(id: tpl.id, name: tpl.name))
        XCTAssertNil(e.prompt, "no prompt with a preset")
        XCTAssertEqual(e.warnings, ["The preset sets its own camera and light"])
        XCTAssertEqual(e.look?.id, "bw_film")

        let before = await a.balance().balance
        let takes = try await a.suiteCreatePhotos(PhotoRequest(modelId: SampleData.demo, prompt: "Rooftop at dusk", count: 3))
        XCTAssertEqual(takes.count, 3)
        XCTAssertTrue(takes.allSatisfy { $0.title.hasPrefix("Photo · ") && $0.kind == "shot" }, "\(takes.map(\.title))")
        let after = await a.balance().balance
        XCTAssertLessThan(after, before)
        let stored = await a.listTakes().filter { t in takes.contains { $0.id == t.id } }
        XCTAssertEqual(stored.map(\.title), takes.map(\.title), "the library shows them as Photo takes")
        let preset = try await a.suiteCreatePhotos(PhotoRequest(modelId: SampleData.demo, count: 1, presetId: tpl.id))
        XCTAssertEqual(preset.first?.title, "Photo · \(tpl.name)")
        do {
            _ = try await a.suiteCreatePhotos(PhotoRequest(modelId: SampleData.demo, count: 0))
            XCTFail("count 0 is refused")
        } catch let e as ApiError {
            XCTAssertEqual(e.code, "bad_request")
        }
    }
}

/// The Photo tool over HTTP against the real API (`server/api`, fake image engine, no money): the request the composer
/// builds passes the strict schema, the estimate and the stills come back in the shapes the app reads. Skipped unless
/// MUSE_API_URL points at a LOCAL dev server (CI starts one).
final class SuitePhotoApiTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        guard let s = ProcessInfo.processInfo.environment["MUSE_API_URL"], let u = URL(string: s) else { throw XCTSkip("MUSE_API_URL not set") }
        let host = u.host ?? ""
        guard ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".local") else {
            throw XCTSkip("SuitePhotoApiTests only run against a local server (got \(host))")
        }
        base = u
    }

    func testThePhotoToolOverHTTP() async throws {
        let api = HTTPMuseAPI(baseURL: base)
        let auth = try await api.signIn(SignInRequest(email: "jen@studio.com", password: "x"))
        await api.setToken(auth.token)
        try await api.ensureStudioFunds()
        let catalog: SuiteCatalog
        do {
            catalog = try await api.suiteCatalog()
        } catch let e as ApiError where e.code == "not_found" || e.code == "http_404" {
            throw XCTSkip("This server has no /v1/suite")
        }
        guard catalog.tools.contains(where: { $0.id == "photo" }) else { throw XCTSkip("This server has no Photo tool yet") }
        XCTAssertFalse(ComposerTool.photo.isComingSoon(in: catalog))
        let models = try await api.listModels()
        let m = try XCTUnwrap(models.first { $0.slots.contains { $0.image != nil } }, "no character with a sheet")
        let cat = catalog.camera
        var tokens = PromptTokens.text(" laughs on a rooftop in the wind").addMention(kind: "character", id: m.id, label: m.shortName, at: Caret(0, 0)).0
        if let mv = cat.move("dolly_in") { tokens = tokens.addMove(mv, catalog: cat).0 }
        var d = ComposerDraft(tool: .photo, tokens: tokens)
        d.settings = ComposerSettings(body: "phone", focalMm: 85, aperture: "f1.4", shotSize: "cu", tempo: "calm", palette: "teal_orange")
        let req = try XCTUnwrap(d.photoRequest(PhotoDraft(count: 2)))
        let e = try await api.suitePhotoEstimate(req)
        XCTAssertEqual(e.tool, "photo")
        XCTAssertEqual(e.count, 2)
        XCTAssertTrue(e.ok)
        XCTAssertTrue(e.buttonLabel.hasPrefix("Generate · 2 photos · $"), e.buttonLabel)
        XCTAssertTrue(e.rig.allSatisfy { PhotoRig.stillRules.contains($0.id) }, "\(e.rig.map(\.id))")
        XCTAssertTrue(e.rig.contains { $0.id == "deep_focus" }, "Phone at f/1.4")
        XCTAssertFalse(e.warnings.contains("Movement doesn’t apply to photos"), "the app never sends a move")
        let takes = try await api.suiteCreatePhotos(PhotoRequest(modelId: m.id, prompt: "Rooftop at dusk", count: 1))
        XCTAssertEqual(takes.count, 1)
        XCTAssertTrue(takes.allSatisfy { $0.title.hasPrefix("Photo · ") }, "\(takes.map(\.title))")
    }
}

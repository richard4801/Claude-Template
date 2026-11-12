import XCTest
@testable import MuseCore

/// Shoot references, the server-built photoshoot prompt and the owner's prompt library (plans/api.md 2026-11-05):
/// request bodies, decoding, the local fallback preview, placeholder rules, live events and the demo backend's flows.
final class ShootReferencesTests: XCTestCase {
    private func json(_ v: some Encodable) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(v)) as! [String: Any]
    }

    private func decode<T: Decodable>(_ t: T.Type, _ s: String) throws -> T { try JSONDecoder().decode(t, from: Data(s.utf8)) }

    private let ref1 = ShootRef(image: ImageRef(url: "https://x/a.jpg"), guides: [.pose])
    private let ref2 = ShootRef(image: ImageRef(url: "https://x/b.jpg"), guides: [.look, .scene])

    // MARK: Requests

    func testBuiltShootSendsChoicesNotAPrompt() throws {
        var s = ShootSettings()
        s.sceneCustom = "  sunlit rooftop bar "
        s.lens = 85
        s.direction = "  laughing mid-step "
        s.lockSeed = true
        let body = try json(ShootRequest.built(modelId: "m1", outfitId: "o1", settings: s, presets: false, refs: [ref1, ref2]))
        XCTAssertEqual(body["modelId"] as? String, "m1")
        XCTAssertEqual(body["scene"] as? String, "sunlit rooftop bar")
        XCTAssertEqual(body["presets"] as? Bool, false)
        XCTAssertEqual(body["light"] as? String, "Golden hour")
        XCTAssertEqual(body["grade"] as? String, "Phone-natural")
        XCTAssertEqual(body["direction"] as? String, "laughing mid-step")
        XCTAssertEqual(body["lockSeed"] as? Bool, true)
        XCTAssertEqual(body["count"] as? Int, 4)
        XCTAssertNil(body["prompt"], "the server builds the prompt")
        XCTAssertNil(body["seed"], "Lock look is the server's seed now")
        XCTAssertNil(body["templateId"])
        let cam = body["camera"] as? [String: Any]
        XCTAssertEqual(cam?["shot"] as? String, "Medium")
        XCTAssertEqual(cam?["lens"] as? Int, 85)
        XCTAssertEqual(cam?["aperture"] as? String, "f/2.8")
        let refs = body["refs"] as? [[String: Any]]
        XCTAssertEqual(refs?.count, 2)
        XCTAssertEqual((refs?[0]["image"] as? [String: Any])?["url"] as? String, "https://x/a.jpg")
        XCTAssertEqual(refs?[1]["guides"] as? [String], ["look", "scene"])
    }

    func testEditAsTextSendsThePromptAndStillTheRefs() throws {
        let body = try json(ShootRequest.built(modelId: "m", outfitId: "o", settings: ShootSettings(), presets: true, refs: [ref1], prompt: "My own words"))
        XCTAssertEqual(body["prompt"] as? String, "My own words")
        XCTAssertEqual((body["refs"] as? [Any])?.count, 1)
        let blank = try json(ShootRequest.built(modelId: "m", outfitId: "o", settings: ShootSettings(), presets: true, refs: [], prompt: "   "))
        XCTAssertNil(blank["prompt"])
        XCTAssertNil(blank["refs"], "no refs key without references")
        XCTAssertNil(blank["direction"])
    }

    func testTemplateShootCarriesRefs() throws {
        let body = try json(ShootRequest.template("tpl", modelId: "m", outfitId: "o", shuffleSeed: 7, refs: [ref2]))
        XCTAssertEqual(body["templateId"] as? String, "tpl")
        XCTAssertNil(body["scene"])
        XCTAssertNil(body["prompt"])
        XCTAssertEqual(((body["refs"] as? [[String: Any]])?.first?["guides"]) as? [String], ["look", "scene"])
    }

    func testRefsProblem() {
        var r = ShootRequest.built(modelId: "m", outfitId: "o", settings: ShootSettings(), presets: true, refs: [ref1])
        XCTAssertNil(r.refsProblem)
        r.refs = [ref1, ref1, ref1, ref1]
        XCTAssertNotNil(r.refsProblem)
        r.refs = [ShootRef(image: ImageRef(url: "u"), guides: [])]
        XCTAssertNotNil(r.refsProblem)
        r.refs = [ShootRef(image: ImageRef(), guides: [.pose])]
        XCTAssertNotNil(r.refsProblem)
    }

    func testGuideToggleKeepsOneAndOrder() {
        var r = ShootRef(image: ImageRef(url: "u"), guides: [.scene])
        r.toggle(.pose)
        XCTAssertEqual(r.guides, [.pose, .scene])
        r.toggle(.pose)
        r.toggle(.scene)
        XCTAssertEqual(r.guides, [.scene], "the last guide stays on")
        XCTAssertEqual(ShootRef.defaultGuide(after: []), .pose)
        XCTAssertEqual(ShootRef.defaultGuide(after: [ref1]), .look)
        XCTAssertEqual(ShootRef.defaultGuide(after: [ref1, ref2]), .pose)
        XCTAssertEqual(ShootGuide.allCases.map(\.label), ["Pose & framing", "Look & colour", "Scene"])
    }

    // MARK: Decoding

    func testDecodesShootPreview() throws {
        let p = try decode(ShootPreview.self, #"""
        {"slots":[{"layer":"identity","text":"Demo model: x. Identity from 6 locked reference images."},{"layer":"reference","text":"Copy the pose and framing from image 7. Do not take the face, body, hair or clothes from image 7."}],
         "text":"Demo model: x. Identity from 6 locked reference images.\nCopy the pose and framing from image 7. Do not take the face, body, hair or clothes from image 7.",
         "seed":821900,"removed":["with blue eyes"],"images":8,"refs":[{"index":7,"guides":["pose"]},{"index":8,"guides":["look","scene"]},{"index":null,"guides":["scene"],"dropped":true}],
         "estimate":0.27,"estimateLabel":"about $0.27","edited":false,"future":1}
        """#)
        XCTAssertEqual(p.slots.map(\.layer), ["identity", "reference"])
        XCTAssertEqual(p.seed, 821900)
        XCTAssertEqual(p.removed, ["with blue eyes"])
        XCTAssertEqual(p.images, 8)
        XCTAssertEqual(p.refs.map(\.index), [7, 8, nil])
        XCTAssertEqual(p.droppedRefs, 1)
        XCTAssertEqual(p.estimateLabel, "about $0.27")
        XCTAssertFalse(p.edited)
        let minimal = try decode(ShootPreview.self, #"{"slots":[{"layer":"custom","text":"hi"}],"estimate":0.5,"edited":true}"#)
        XCTAssertEqual(minimal.text, "hi")
        XCTAssertEqual(minimal.estimateLabel, "about $0.50")
        XCTAssertTrue(minimal.edited)
    }

    func testDecodesTakeRefsAndPhotoFeatures() throws {
        let t = try decode(Take.self, #"{"id":"s1","kind":"shot","refs":[{"image":{"url":"/files/r.jpg"},"guides":["pose","outfit"]}]}"#)
        XCTAssertEqual(t.refs?.first?.guides, [.pose], "unknown guides are skipped")
        let f = try decode(StudioFeatures.self, #"{"photo":{"perRun":0.015,"maxInputs":8,"references":{"max":3,"guides":[{"id":"pose","label":"Pose & framing"},{"id":"look","label":"Look & colour"},{"id":"scene","label":"Scene"}]}}}"#)
        XCTAssertEqual(f.photo?.maxInputs, 8)
        XCTAssertEqual(f.photo?.references?.max, 3)
        XCTAssertEqual(f.photo?.references?.label(.look), "Look & colour")
        let old = try decode(PhotoPricing.self, #"{"perRun":0.015}"#)
        XCTAssertEqual(old.maxInputs, 8)
        XCTAssertNil(old.references)
    }

    func testDecodesPromptLibrary() throws {
        let lib = try decode(PromptLibrary.self, #"""
        {"groups":[{"id":"photoshoot","label":"Photoshoot"},{"id":"references","label":"References"},{"id":"video","label":"Video"}],
         "prompts":[
          {"key":"refs.pose","group":"references","title":"Pose & framing","description":"","kind":"text","default":"Copy the pose and framing from image {refIndex}.","current":"Match the pose in image {refIndex}.","overridden":true,"allowEmpty":false,"placeholders":[{"name":"refIndex","description":"Its image number","required":true}],"updatedAt":1762300000000,"updatedBy":"jen@studio.com"},
          {"key":"style.house","group":"photoshoot","title":"House style","description":"Added to every photo prompt.","kind":"text","default":"realistic","current":"realistic","overridden":false,"allowEmpty":false,"placeholders":[],"updatedAt":null,"updatedBy":null},
          {"key":"never.base","group":"photoshoot","title":"Never add","kind":"list","default":"logos","current":"logos","overridden":false,"allowEmpty":true,"placeholders":[]},
          {"key":"x.new","group":"brandnew","title":"New","default":"a"}
         ]}
        """#)
        XCTAssertEqual(lib.sections.map(\.group.id), ["photoshoot", "references", "brandnew"], "empty groups are hidden, unknown groups come last")
        XCTAssertEqual(lib.sections[0].entries.map(\.key), ["style.house", "never.base"])
        let pose = try XCTUnwrap(lib.entry("refs.pose"))
        XCTAssertTrue(pose.overridden)
        XCTAssertEqual(pose.defaultText, "Copy the pose and framing from image {refIndex}.")
        XCTAssertEqual(pose.placeholders.first?.required, true)
        XCTAssertEqual(pose.updatedBy, "jen@studio.com")
        XCTAssertEqual(lib.entry("never.base")?.kindHint, "Comma-separated items")
        XCTAssertEqual(lib.entry("x.new")?.current, "a")
        // The PUT body and a round trip keep the "default" key.
        XCTAssertEqual(try json(SetPromptRequest(text: "t"))["text"] as? String, "t")
        XCTAssertEqual(try json(pose)["default"] as? String, pose.defaultText)
        XCTAssertNil(try json(PromptPreviewRequest(key: "k"))["text"])
        let pv = try decode(PromptPreview.self, #"{"key":"refs.pose","text":"Match the pose in image 7.","example":"Demo model: …\nMatch the pose in image 7.","sample":{"refIndex":"7"}}"#)
        XCTAssertEqual(pv.sample["refIndex"], "7")
    }

    func testPromptsEventUpdatesTheLibrary() throws {
        let e = try decode(ApiEvent.self, #"{"type":"prompts","prompt":{"key":"shoot.seed.new","group":"photoshoot","title":"Seed","default":"Seed: new each shot.","current":"Seed: fresh.","overridden":true}}"#)
        var lib: PromptLibrary? = PromptLibrary(groups: PromptLibraryDefaults.groups, prompts: PromptLibraryDefaults.entries)
        let p = LiveEvents.applyPrompts(&lib, e)
        XCTAssertEqual(p?.key, "shoot.seed.new")
        XCTAssertEqual(lib?.entry("shoot.seed.new")?.current, "Seed: fresh.")
        XCTAssertTrue(lib?.entry("shoot.seed.new")?.overridden ?? false)
        XCTAssertNil(LiveEvents.applyPrompts(&lib, ApiEvent(type: "settings")))
    }

    func testPathKeyEncoding() {
        XCTAssertEqual(HTTPMuseAPI.pathKey("shoot.camera.wide"), "shoot.camera.wide")
        XCTAssertEqual(HTTPMuseAPI.pathKey("a/b c"), "a%2Fb%20c")
    }

    // MARK: Placeholders

    func testPlaceholderRules() throws {
        let e = try XCTUnwrap(PromptLibraryDefaults.entries.first { $0.key == "refs.pose" })
        XCTAssertNil(PromptPlaceholders.problem(e, "Match image {refIndex}. {not a placeholder} {}"))
        XCTAssertEqual(PromptPlaceholders.problem(e, "Match image {refIndex} {foo}"), "Unknown placeholder {foo} · this prompt can use {refIndex}")
        XCTAssertEqual(PromptPlaceholders.problem(e, "Match the pose"), "Keep {refIndex} · this prompt needs it")
        XCTAssertNotNil(PromptPlaceholders.problem(e, "  "))
        XCTAssertNotNil(PromptPlaceholders.problem(e, String(repeating: "x", count: 4001) + "{refIndex}"))
        let base = try XCTUnwrap(PromptLibraryDefaults.entries.first { $0.key == "never.base" })
        XCTAssertNil(PromptPlaceholders.problem(base, ""), "allowEmpty")
        XCTAssertEqual(PromptPlaceholders.names(in: "{a} {b2} {a} {2x}"), ["a", "b2"])
        XCTAssertEqual(PromptPlaceholders.fill("{name}: {look}{lora}.\n{lora}\nEnd", ["name": "Ava", "look": "x"]), "Ava: x.\nEnd")
    }

    // MARK: Local fallback preview

    func testLocalPreviewAddsReferenceLinesAfterDirection() {
        var s = ShootSettings()
        s.direction = "laughing"
        s.lockSeed = true
        let id = PromptIdentity(name: "Demo model", look: "early 20s")
        let p = PromptEngine.shootPreview(identity: id, outfitName: "Green set", settings: s, presets: true, refs: [ref1, ref2])
        XCTAssertEqual(p.slots.map(\.layer), ["identity", "outfit", "scene", "camera", "light", "direction", "reference", "reference", "style", "negative", "seed"])
        XCTAssertEqual(p.slots[6].text, "Copy the pose and framing from image 7. Do not take the face, body, hair or clothes from image 7.")
        XCTAssertEqual(p.slots[7].text, "Copy the light, colour grade and camera feel from image 8. Use the place and background from image 8. Do not take the face, body, hair or clothes from image 8.")
        XCTAssertEqual(p.slots.last?.text, "Seed: locked (variations keep the same look).")
        XCTAssertEqual(p.seed, 821900, "the same seed as the server's seedFor")
        XCTAssertEqual(p.images, 8)
        XCTAssertEqual(p.refs.map(\.index), [7, 8])
        XCTAssertEqual(p.text, p.slots.map(\.text).joined(separator: "\n"))
        // 8 images at 0.79 MP each, 4 stills.
        XCTAssertEqual(p.estimate, 4 * (0.015 + 0.015 * 2 + 0.015 * 0.79 * 8), accuracy: 1e-12)
        XCTAssertGreaterThan(p.estimate, PhotoPricing.standard.shoot())

        let off = PromptEngine.shootPreview(identity: id, outfitName: "Green set", settings: s, presets: false, refs: [ref1])
        XCTAssertEqual(off.slots.map(\.layer), ["identity", "outfit", "direction", "reference", "seed"])
        let noDir = PromptEngine.shootPreview(identity: id, outfitName: "Green set", settings: ShootSettings(), presets: true, refs: [ref1])
        XCTAssertEqual(noDir.slots.map(\.layer), ["identity", "outfit", "scene", "camera", "light", "reference", "style", "negative", "seed"])
        XCTAssertEqual(PromptEngine.seedFor("Ava"), 66220)
        XCTAssertEqual(PromptEngine.seedFor("zzzzzzzzzzzz"), 476992)
    }

    func testLocalPreviewDropsWhatTheModelCantTake() {
        let id = PromptIdentity(name: "A", look: "b")
        let three = [ref1, ref2, ShootRef(image: ImageRef(url: "c"), guides: [.scene])]
        // 8 inputs: 6 identity + 3 refs = 9, so identity gives way (5 + 3).
        let p = PromptEngine.shootPreview(identity: id, outfitName: "o", settings: ShootSettings(), presets: true, refs: three)
        XCTAssertEqual(p.images, 8)
        XCTAssertEqual(p.refs.map(\.index), [6, 7, 8])
        XCTAssertEqual(p.slots.filter { $0.layer == "reference" }.count, 3)
        // A 2-image model: the face front and one reference; the rest are dropped with no line.
        var small = PhotoPricing.standard
        small.maxInputs = 2
        let q = PromptEngine.shootPreview(identity: id, outfitName: "o", settings: ShootSettings(), presets: true, refs: three, pricing: small)
        XCTAssertEqual(q.images, 2)
        XCTAssertEqual(q.refs.map(\.index), [2, nil, nil])
        XCTAssertEqual(q.droppedRefs, 2)
        XCTAssertEqual(q.slots.filter { $0.layer == "reference" }.map(\.text).first?.hasSuffix("from image 2."), true)
        // Edit as text: the user's text exactly.
        let e = PromptEngine.shootPreview(identity: id, outfitName: "o", settings: ShootSettings(), presets: true, refs: [ref1], prompt: "Just this")
        XCTAssertTrue(e.edited)
        XCTAssertEqual(e.text, "Just this")
        XCTAssertEqual(e.slots, [PromptSlotView(layer: "custom", text: "Just this")])
    }

    // MARK: Demo backend flows

    func testDemoShootWithReferences() async throws {
        let api = FakeMuseAPI(speed: 0, genDelay: 0)
        _ = try await api.signIn(SignInRequest(email: "you@studio.com", password: ""))
        var s = ShootSettings()
        s.direction = "spinning"
        let req = ShootRequest.built(modelId: SampleData.demo, outfitId: SampleData.green, settings: s, presets: true, refs: [ref1])
        let preview = try await api.shootPreview(req)
        XCTAssertTrue(preview.slots.contains { $0.layer == "reference" })
        let before = try await api.balance().balance
        let shots = try await api.shoot(req)
        XCTAssertEqual(shots.count, 4)
        XCTAssertEqual(shots.first?.prompt, preview.text, "the shot's prompt is what the preview showed")
        XCTAssertEqual(shots.first?.refs, [ref1])
        let after = try await api.balance().balance
        XCTAssertEqual(before - after, preview.estimate, accuracy: 1e-9)

        var edited = req
        edited.prompt = "Hand-written prompt"
        let e = try await api.shootPreview(edited)
        XCTAssertTrue(e.edited)
        let editedShots = try await api.shoot(edited)
        XCTAssertEqual(editedShots.first?.prompt, "Hand-written prompt")

        var tooMany = req
        tooMany.refs = [ref1, ref1, ref1, ref1]
        do {
            _ = try await api.shoot(tooMany)
            XCTFail("expected bad_request")
        } catch let err as ApiError {
            XCTAssertEqual(err.code, "bad_request")
        }
    }

    func testDemoPromptLibrary() async throws {
        let api = FakeMuseAPI(speed: 0, genDelay: 0)
        _ = try await api.signIn(SignInRequest(email: "you@studio.com", password: ""))
        let lib = try await api.prompts()
        XCTAssertEqual(lib.sections.first?.group.label, "Photo")
        XCTAssertTrue(lib.prompts.allSatisfy { !$0.overridden })
        let events = api.events()
        do {
            _ = try await api.setPrompt(key: "shoot.seed.new", text: "Seed: {seed}")
            XCTFail("expected prompt_invalid")
        } catch let e as ApiError {
            XCTAssertEqual(e.code, "prompt_invalid")
            XCTAssertTrue(e.message.contains("Unknown placeholder {seed}"))
        }
        do {
            _ = try await api.previewPrompt(PromptPreviewRequest(key: "refs.pose", text: "no index"))
            XCTFail("expected prompt_invalid")
        } catch let e as ApiError {
            XCTAssertEqual(e.message, "Keep {refIndex} · this prompt needs it")
        }
        let saved = try await api.setPrompt(key: "shoot.seed.new", text: "Seed: fresh every shot.")
        XCTAssertTrue(saved.overridden)
        XCTAssertEqual(saved.current, "Seed: fresh every shot.")
        var it = events.makeAsyncIterator()
        var got: PromptEntry?
        while let e = await it.next() {
            if e.type == "prompts" { got = e.prompt; break }
        }
        XCTAssertEqual(got?.key, "shoot.seed.new")
        // A saved house style reaches the shoot preview.
        let s = ShootSettings()
        let style = try await api.setPrompt(key: "style.realism", text: "film photo")
        XCTAssertTrue(style.overridden)
        let p2 = try await api.shootPreview(ShootRequest.built(modelId: SampleData.demo, outfitId: SampleData.green, settings: s, presets: true, refs: []))
        XCTAssertTrue(p2.slots.contains(PromptSlotView(layer: "style", text: "Style: \(PromptEngine.cameraFeel), film photo.")))
        let pv = try await api.previewPrompt(PromptPreviewRequest(key: "style.camera", text: "grainy film"))
        XCTAssertEqual(pv.text, "grainy film")
        XCTAssertTrue(pv.example.contains("Style: grainy film, film photo."))
        // Saving the default text clears the override; Reset does too.
        let back = try await api.setPrompt(key: "style.realism", text: PromptEngine.realism)
        XCTAssertFalse(back.overridden)
        let reset = try await api.resetPrompt(key: "shoot.seed.new")
        XCTAssertFalse(reset.overridden)
        do {
            _ = try await api.resetPrompt(key: "nope")
            XCTFail("expected not_found")
        } catch let e as ApiError {
            XCTAssertEqual(e.code, "not_found")
        }
    }
}

/// The server's photoshoot prompt (`shoot_prompt_fixture.json`, a byte-for-byte copy of
/// android/core/src/test/resources/shoot_prompt_fixture.json): the app's demo/offline engine must build the same layers.
final class ShootPromptFixtureTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Identity: Decodable {
            var name: String
            var look: String
            var neverAdd: [String]
            var referenceCount: Int
        }
        struct Ref: Decodable {
            var index: Int
            var guides: [ShootGuide]
        }
        struct Input: Decodable {
            var outfit: String
            var scene: String?
            var shot: String
            var lens: Int
            var aperture: String
            var light: String?
            var grade: String?
            var direction: String?
            var lockSeed: Bool?
            var presets: Bool?
            var refs: [Ref]?
        }
        struct Row: Decodable {
            var input: Input
            var slots: [PromptSlotView]
            var seed: Int64?
            var removed: [String]
            var text: String
        }
        var identity: Identity
        var rows: [Row]
    }

    func testLocalEngineMatchesTheServer() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "shoot_prompt_fixture", withExtension: "json", subdirectory: "Fixtures"))
        let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertFalse(f.rows.isEmpty)
        let id = PromptIdentity(name: f.identity.name, look: f.identity.look, referenceCount: f.identity.referenceCount, neverAdd: f.identity.neverAdd)
        for (n, row) in f.rows.enumerated() {
            let i = row.input
            var s = ShootSettings()
            if let sc = i.scene { if ShootSettings.scenes.contains(sc) { s.scene = sc } else { s.sceneCustom = sc } }
            s.shot = i.shot
            s.lens = i.lens
            s.aperture = i.aperture
            s.light = i.light ?? "Golden hour"
            s.grade = i.grade ?? "Phone-natural"
            s.direction = i.direction ?? ""
            s.lockSeed = i.lockSeed ?? false
            let b = PromptEngine.shootSlots(identity: id, outfitName: i.outfit, settings: s, presets: i.presets ?? true,
                                            refs: (i.refs ?? []).map { r in (guides: r.guides, index: r.index) })
            XCTAssertEqual(b.slots, row.slots, "row \(n)")
            XCTAssertEqual(b.removed, row.removed, "row \(n)")
            XCTAssertEqual(b.slots.map(\.text).joined(separator: "\n"), row.text, "row \(n)")
            XCTAssertEqual(s.lockSeed ? PromptEngine.seedFor(id.name) : nil, row.seed, "row \(n)")
        }
    }
}

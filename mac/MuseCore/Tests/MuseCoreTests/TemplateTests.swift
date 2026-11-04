import XCTest
@testable import MuseCore

final class TemplateCodingTests: XCTestCase {
    func testDecodesContractTemplateAndDropsLayersForNonOwners() throws {
        let json = """
        {"id":"t1","name":"Mirror selfie","tags":["Faceless"],"visibility":"public","ownerId":"u9","ownerName":"Jen","isOwner":false,"uses":3,
         "favourite":true,"cover":{"url":"/uploads/a.jpg"},"acceptsProduct":false,"starter":"mirror-selfie","createdAt":5,"updatedAt":6,
         "layers":{"scene":"leak"},"variationPool":{"pose":["leak"]},"recent":[{"id":"s1","thumb":{"asset":"face"},"createdAt":7}]}
        """
        let t = try JSONDecoder().decode(MuseTemplate.self, from: Data(json.utf8))
        XCTAssertEqual(t.name, "Mirror selfie")
        XCTAssertTrue(t.isPublic)
        XCTAssertTrue(t.favourite)
        XCTAssertEqual(t.starter, "mirror-selfie")
        XCTAssertNil(t.layers, "hidden layers are never kept for a non-owner")
        XCTAssertNil(t.variationPool)
        XCTAssertEqual(t.recent?.first?.thumb.asset, "face")
        XCTAssertEqual(t.usesLabel, "3 uses")
    }

    func testDecodesOwnerLayersPoolAndAfterEffects() throws {
        let json = """
        {"id":"t1","name":"Moody","isOwner":true,"layers":{"style":"dark","negative":"flash","product":"","afterEffects":{"grade":"moody-blue","grain":0.3}},
         "variationPool":{"pose":["a","b"],"timeOfDay":["late"],"unknown":["x"]}}
        """
        let t = try JSONDecoder().decode(MuseTemplate.self, from: Data(json.utf8))
        XCTAssertEqual(t.layers?.style, "dark")
        XCTAssertEqual(t.layers?.negative, "flash")
        XCTAssertEqual(t.layers?.afterEffects?.grade, "moody-blue")
        XCTAssertEqual(t.layers?.afterEffects?.summary, "moody blue grade, grain 30%")
        XCTAssertEqual(t.variationPool?[.pose], ["a", "b"])
        XCTAssertEqual(t.variationPool?[.timeOfDay], ["late"])
        XCTAssertEqual(t.visibility, "private")
    }

    func testEncodesOnlyFilledLayersAndSlots() throws {
        let l = TemplateLayers(style: "  soft ", scene: "", afterEffects: TemplateAfterEffects(grade: "none"))
        let s = String(decoding: try JSONEncoder().encode(l), as: UTF8.self)
        XCTAssertEqual(s, #"{"style":"soft"}"#)
        var p = VariationPool()
        p[.hands] = ["one", " ", "two"]
        let ps = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
        XCTAssertEqual(ps, #"{"hands":["one","two"]}"#)
        let d = String(decoding: try JSONEncoder().encode(VariationDraw(picks: [.pose: "x"], direction: "sit")), as: UTF8.self)
        XCTAssertTrue(d.contains(#""pose":"x""#) && d.contains(#""direction":"sit""#), d)
    }

    func testTemplateShootRequestSendsOnlyTheTemplateAndChoices() throws {
        let r = ShootRequest.template("t1", modelId: "m", outfitId: "o", direction: "  ", shuffleSeed: 42, lockSeed: false)
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as! [String: Any]
        XCTAssertEqual(obj["templateId"] as? String, "t1")
        XCTAssertEqual(obj["shuffleSeed"] as? Int, 42)
        XCTAssertEqual(obj["lockSeed"] as? Bool, false)
        XCTAssertNil(obj["direction"], "a blank direction is left out")
        XCTAssertNil(obj["seed"])
        XCTAssertNil(obj["productImage"])
    }

    func testTakeCarriesTemplateFields() throws {
        let json = #"{"id":"s1","kind":"shot","templateId":"t1","templateName":"Mirror selfie","shuffleSeed":9,"variation":{"pose":"p","direction":"d"}}"#
        let t = try JSONDecoder().decode(Take.self, from: Data(json.utf8))
        XCTAssertTrue(t.isTemplateShot)
        XCTAssertEqual(t.templateName, "Mirror selfie")
        XCTAssertEqual(t.variation?[.pose], "p")
        XCTAssertEqual(t.variation?.direction, "d")
    }

    func testTemplatePromptDecodes() throws {
        let json = #"{"slots":[{"layer":"identity","text":"Sienna"},{"layer":"template","text":"Template: X","locked":true}],"text":"Sienna\nTemplate: X","seed":null,"shuffleSeed":7}"#
        let p = try JSONDecoder().decode(TemplatePrompt.self, from: Data(json.utf8))
        XCTAssertTrue(p.isLocked)
        XCTAssertNil(p.seed)
        XCTAssertEqual(p.slots[1].body, "X")
    }
}

final class TemplateEngineTests: XCTestCase {
    func testMulberryMatchesTheServer() {
        var r = Mulberry32(seed: 12345)
        XCTAssertEqual(r.next(), 0.9797282677609473, accuracy: 1e-15)
        XCTAssertEqual(r.next(), 0.3067522644996643, accuracy: 1e-15)
        XCTAssertEqual(r.next(), 0.484205421525985, accuracy: 1e-15)
        // The per-still seed: (shuffleSeed ^ imul(index + 1, 0x9e3779b1)) >>> 0, here index 2.
        var r2 = Mulberry32(seed: UInt32(987_654_321) ^ (UInt32(3) &* 0x9E37_79B1))
        XCTAssertEqual(r2.next(), 0.13896195334382355, accuracy: 1e-15)
        XCTAssertEqual(r2.next(), 0.39400428254157305, accuracy: 1e-15)
    }

    func testDrawsAreStableAndDirectionReplacesPoseAndAngle() {
        let pool = TemplateEngine.suggestPool(layers: TemplateLayers(style: "mirror selfie"), name: "Mirror selfie")
        let a = TemplateEngine.draw(pool, shuffleSeed: 77)
        XCTAssertEqual(a, TemplateEngine.draw(pool, shuffleSeed: 77))
        XCTAssertNotNil(a[.pose])
        XCTAssertNotNil(a[.bodyAngle])
        let d = TemplateEngine.draw(pool, shuffleSeed: 77, direction: "sitting on the steps")
        XCTAssertNil(d[.pose])
        XCTAssertNil(d[.bodyAngle])
        XCTAssertEqual(d[.framing], a[.framing], "the other slots draw the same with or without a direction")
        XCTAssertEqual(d.direction, "sitting on the steps")
        let many = Set((0..<20).map { TemplateEngine.draw(pool, shuffleSeed: Int64($0)).summary })
        XCTAssertGreaterThan(many.count, 10, "Shuffle gives different moments")
        XCTAssertNotEqual(TemplateEngine.draw(pool, shuffleSeed: 5, index: 0), TemplateEngine.draw(pool, shuffleSeed: 5, index: 1))
    }

    func testSuggestedPoolFollowsTheStyle() {
        let mirror = TemplateEngine.suggestPool(layers: TemplateLayers(scene: "bedroom mirror"), name: "Mirror selfie")
        XCTAssertTrue(mirror[.pose].contains("phone held up covering the face"))
        XCTAssertTrue(mirror[.bodyAngle].contains("three-quarter turn to the mirror"))
        let plain = TemplateEngine.suggestPool(layers: TemplateLayers(scene: "a field"), name: "Field")
        XCTAssertEqual(plain[.pose].first, "weight on one leg, relaxed")
        XCTAssertTrue(plain[.hands].isEmpty)
    }

    func testVisibleViewNeverCarriesHiddenLayers() {
        let l = TemplateLayers(style: "SECRET-STYLE", scene: "SECRET-SCENE", camera: "SECRET-CAM", light: "SECRET-LIGHT", negative: "SECRET-NEG")
        let pool = VariationPool(pose: ["SECRET-POSE"], framing: ["SECRET-FRAME"])
        let id = PromptIdentity(name: "Sienna Vale", look: "young woman", neverAdd: ["tattoos"])
        let b = TemplateEngine.build(templateId: "t", templateName: "Mirror selfie", layers: l, pool: pool, identity: id, outfitName: "Green set",
                                     direction: "looking back", shuffleSeed: 3, lockSeed: false, seed: 123)
        XCTAssertFalse(b.visibleText.contains("SECRET"), b.visibleText)
        XCTAssertEqual(b.visible.map(\.layer), ["identity", "outfit", "template", "direction", "negative", "seed"])
        XCTAssertEqual(b.visible.filter(\.locked).map(\.text), ["Template: Mirror selfie"])
        XCTAssertTrue(b.fullText.contains("Scene: SECRET-SCENE."))
        XCTAssertTrue(b.fullText.contains("Camera: SECRET-CAM; SECRET-FRAME."))
        XCTAssertTrue(b.fullText.contains("Never add: tattoos, logos, extra fingers, warped jewellery, SECRET-NEG."))
        XCTAssertFalse(b.fullText.contains("SECRET-POSE"), "direction replaces the pose draw")
        XCTAssertTrue(b.fullText.contains("Seed: 123 (new each shot)."))
        let locked = TemplateEngine.lockedView(templateName: "Mirror selfie", identity: id, outfitName: "Green set", direction: "", lockSeed: false)
        XCTAssertEqual(locked.map(\.layer), ["identity", "outfit", "template", "negative", "seed"])
    }

    func testLayersFromAPhotoshootPrompt() {
        var s = ShootSettings()
        s.scene = "Bedroom mirror"
        s.direction = "laughing"
        let id = PromptIdentity(name: "Sienna Vale", look: "x", neverAdd: ["tattoos", "rings"])
        let prompt = PromptEngine.shootText(identity: id, outfitName: "Green set", settings: s)
        let l = TemplateLayers.from(prompt: prompt, neverAdd: ["tattoos", "rings"])
        XCTAssertEqual(l.scene, "bedroom mirror")
        XCTAssertEqual(l.camera, "medium shot, 35mm lens, f/2.8")
        XCTAssertEqual(l.light, "golden hour; grade: phone-natural")
        XCTAssertEqual(l.style, "", "the house style isn't a template layer")
        XCTAssertEqual(l.negative, "")
    }

    func testQueryScopesSearchAndTags() {
        let now: Int64 = 1_000_000_000
        let all = StarterTemplates.all(ownerId: "u1", ownerName: "Jen", now: now) + StarterTemplates.memberTemplates(now: now).map(\.redacted)
        var favs = all
        favs[1].favourite = true
        XCTAssertEqual(TemplateQuery().apply(favs).count, 9, "mine + public; someone else's private one is hidden")
        XCTAssertEqual(TemplateQuery(scope: .mine).apply(favs).count, 7)
        XCTAssertEqual(TemplateQuery(scope: .public).apply(favs).count, 9)
        XCTAssertEqual(TemplateQuery(scope: .favourites).apply(favs).map(\.name), ["Mirror selfie"])
        XCTAssertEqual(TemplateQuery(q: "MIRROR").apply(favs).map(\.name), ["Mirror selfie"])
        XCTAssertEqual(TemplateQuery(q: "facel").apply(favs).count, 2, "q matches tags too")
        XCTAssertEqual(TemplateQuery(tag: "faceless").apply(favs).count, 2)
        XCTAssertEqual(TemplateQuery(tag: "facel").apply(favs).count, 0, "tag is exact")
        XCTAssertEqual(TemplateQuery(scope: .favourites, q: "x").queryItems.map(\.name), ["scope", "q"])
        XCTAssertEqual(TemplateEngine.allTags(all).first, "Faceless")
    }

    func testStarterPackUsesOnlyBundledSiennaPhotos() {
        let bundled: Set<String> = ["hero", "face", "profile", "g_front", "g_tq", "g_side", "g_back", "c_front", "c_tq", "c_face"]
        let starters = StarterTemplates.all(ownerId: "u1", ownerName: "Jen")
        XCTAssertEqual(starters.compactMap(\.starter), ["motion-blur-face", "mirror-selfie", "harsh-sun-close-up", "moody-low-light", "reflection", "product-moment", "candid-pov"])
        for t in starters + StarterTemplates.memberTemplates() {
            XCTAssertNil(t.cover?.url, t.name)
            XCTAssertTrue(bundled.contains(t.cover?.asset ?? ""), t.name)
            XCTAssertFalse(t.layers?.isEmpty ?? true, t.name)
            XCTAssertFalse(t.variationPool?.isEmpty ?? true, t.name)
        }
        XCTAssertEqual(starters.filter(\.acceptsProduct).map(\.name), ["Product moment"])
        XCTAssertEqual(starters[0].layers?.afterEffects?.faceMotionBlur, 0.7)
    }

    func testFormSavesFromShotUnlessLayersWereEdited() {
        let d = TemplateDraft(name: "Rooftop", layers: TemplateLayers(scene: "rooftop"), variationPool: VariationPool(pose: ["a"]), fromShotId: "s1")
        var f = TemplateForm.from(draft: d)
        XCTAssertEqual(f.visibility, .private, "private by default")
        f.tagsText = "golden hour, Golden Hour, , rooftop"
        XCTAssertEqual(f.tags, ["golden hour", "rooftop"])
        XCTAssertEqual(f.createRequest.fromShotId, "s1")
        XCTAssertNil(f.createRequest.layers)
        f.layers.light = "harder"
        XCTAssertNil(f.createRequest.fromShotId)
        XCTAssertEqual(f.createRequest.coverTakeId, "s1")
        XCTAssertEqual(f.createRequest.layers?.light, "harder")
        f.addOption("  b ", to: .pose)
        f.addOption("b", to: .pose)
        XCTAssertEqual(f.pool[.pose], ["a", "b"])
        f.removeOption(at: 0, from: .pose)
        XCTAssertEqual(f.pool[.pose], ["b"])
        f.name = "  "
        XCTAssertFalse(f.canSave)
    }
}

/// Demo mode's templates behave like the server's.
final class FakeTemplateTests: XCTestCase {
    private func api() async throws -> FakeMuseAPI {
        let api = FakeMuseAPI(speed: 0, genDelay: 0)
        _ = try await api.signIn(SignInRequest(email: "you@studio.com", password: ""))
        return api
    }

    func testLibraryScopesAndRedaction() async throws {
        let api = try await api()
        let all = await api.listTemplates(TemplateQuery())
        XCTAssertEqual(all.count, 9)
        XCTAssertFalse(all.contains { $0.name == "Theo's test look" })
        let mine = await api.listTemplates(TemplateQuery(scope: .mine))
        XCTAssertEqual(mine.count, 7)
        XCTAssertTrue(mine.allSatisfy { $0.isOwner && $0.layers != nil && $0.variationPool != nil })
        let maya = all.first { $0.name == "Golden hour walk" }!
        XCTAssertFalse(maya.isOwner)
        XCTAssertNil(maya.layers)
        XCTAssertNil(maya.variationPool)
        let favs = await api.listTemplates(TemplateQuery(scope: .favourites))
        XCTAssertEqual(favs.map(\.name), ["Mirror selfie"])
        let fav = try await api.setTemplateFavourite(id: maya.id, true)
        XCTAssertTrue(fav.favourite)
        let favs2 = await api.listTemplates(TemplateQuery(scope: .favourites))
        XCTAssertEqual(favs2.count, 2)
        do {
            _ = try await api.template(id: "tpl_theo_private")
            XCTFail("someone else's private template is not_found")
        } catch let e as ApiError { XCTAssertEqual(e.code, "not_found") }
    }

    func testTemplateShootHidesLayersFromNonOwnersAndCountsUses() async throws {
        let api = try await api()
        let before = await api.balance().balance
        let maya = try await api.template(id: "tpl_maya_golden")
        let shots = try await api.shoot(.template(maya.id, modelId: SampleData.sienna, outfitId: SampleData.green, direction: "sitting on the steps", shuffleSeed: 11))
        XCTAssertEqual(shots.count, 4)
        let after0 = await api.balance().balance
        XCTAssertEqual(after0, before - PhotoPricing.standard.shoot(), accuracy: 1e-9)
        for s in shots {
            XCTAssertEqual(s.templateId, maya.id)
            XCTAssertEqual(s.templateName, "Golden hour walk")
            XCTAssertEqual(s.shuffleSeed, 11)
            XCTAssertNil(s.variation, "draws are owner only")
            XCTAssertTrue(s.prompt.contains("Template: Golden hour walk"), s.prompt)
            XCTAssertFalse(s.prompt.contains("residential"), "hidden layers never reach a non-owner")
            XCTAssertTrue(s.prompt.contains("Direction: sitting on the steps."))
            XCTAssertTrue(s.prompt.contains("(new each shot)"))
        }
        XCTAssertEqual(Set(shots.map(\.seed)).count, 4, "a new seed per still")
        let after = try await api.template(id: maya.id)
        XCTAssertEqual(after.uses, maya.uses + 1)
        XCTAssertEqual(after.recent?.count, 4)
        let view = try await api.templatePrompt(id: maya.id, TemplatePromptRequest(modelId: SampleData.sienna, outfitId: SampleData.green, shuffleSeed: 11))
        XCTAssertTrue(view.isLocked)
        XCTAssertNil(view.variation)
        // Saving someone else's template shot as a template is refused.
        do {
            _ = try await api.templateDraft(fromShotId: shots[0].id)
            XCTFail("expected template_hidden")
        } catch let e as ApiError { XCTAssertEqual(e.code, "template_hidden") }
        // Someone else's template can't be changed.
        do {
            _ = try await api.updateTemplate(id: maya.id, TemplatePatch(visibility: "private"))
            XCTFail("expected owner_only")
        } catch let e as ApiError { XCTAssertEqual(e.code, "owner_only") }
    }

    func testOwnerShootAndPromptViewShowEveryLayer() async throws {
        let api = try await api()
        let view = try await api.templatePrompt(id: "tpl_mirror_selfie", TemplatePromptRequest(modelId: SampleData.sienna, outfitId: SampleData.green, shuffleSeed: 5, lockSeed: true))
        XCTAssertFalse(view.isLocked)
        XCTAssertNotNil(view.variation)
        XCTAssertTrue(view.text.contains("Scene: lived-in bedroom"), view.text)
        XCTAssertNotNil(view.seed, "Lock look gives one fixed seed")
        let again = try await api.templatePrompt(id: "tpl_mirror_selfie", TemplatePromptRequest(modelId: SampleData.sienna, outfitId: SampleData.green, shuffleSeed: 5, lockSeed: true))
        XCTAssertEqual(view, again, "the same shuffleSeed gives the same prompt")
        let shots = try await api.shoot(.template("tpl_mirror_selfie", modelId: SampleData.sienna, outfitId: SampleData.green, shuffleSeed: 5, lockSeed: true))
        XCTAssertEqual(Set(shots.map(\.seed)), [view.seed!])
        XCTAssertEqual(shots[0].variation, view.variation, "still 1 drew what the prompt view showed")
        XCTAssertTrue(shots[0].prompt.contains("Pose: "))
    }

    func testSaveAsTemplateEditDuplicateDelete() async throws {
        let api = try await api()
        var s = ShootSettings()
        s.scene = "Café window"
        s.direction = "stirring a coffee"
        let prompt = PromptEngine.shootText(identity: SampleData.models()[0].promptIdentity, outfitName: "Green set", settings: s)
        let shots = try await api.shoot(ShootRequest(modelId: SampleData.sienna, outfitId: SampleData.green, scene: s.effectiveScene, prompt: prompt))
        let draft = try await api.templateDraft(fromShotId: shots[0].id)
        XCTAssertEqual(draft.layers.scene, "café window")
        XCTAssertEqual(draft.variationPool[.pose].first, "stirring a coffee", "the shot's direction becomes the first pose option")
        XCTAssertEqual(draft.cover, shots[0].thumb)
        var form = TemplateForm.from(draft: draft)
        form.name = "Café morning"
        form.tagsText = "Café, Morning"
        let t = try await api.createTemplate(form.createRequest)
        XCTAssertEqual(t.visibility, "private")
        XCTAssertTrue(t.isOwner)
        XCTAssertEqual(t.createdFromShotId, shots[0].id)
        XCTAssertEqual(t.layers?.scene, "café window")
        XCTAssertEqual(t.tags, ["Café", "Morning"])
        let pub = try await api.updateTemplate(id: t.id, TemplatePatch(visibility: "public"))
        XCTAssertTrue(pub.isPublic)
        let copy = try await api.duplicateTemplate(id: t.id)
        XCTAssertEqual(copy.name, "Café morning copy")
        XCTAssertEqual(copy.visibility, "private")
        XCTAssertEqual(copy.layers, t.layers)
        try await api.deleteTemplate(id: t.id)
        let names = await api.listTemplates(TemplateQuery(scope: .mine)).map(\.name)
        XCTAssertFalse(names.contains("Café morning"))
        XCTAssertTrue(names.contains("Café morning copy"))
        do {
            _ = try await api.createTemplate(CreateTemplateRequest(name: " "))
            XCTFail("expected bad_request")
        } catch let e as ApiError { XCTAssertEqual(e.code, "bad_request") }
        // From scratch: an empty pool is auto-suggested.
        let scratch = try await api.createTemplate(CreateTemplateRequest(name: "Night mirror", layers: TemplateLayers(scene: "mirror at night")))
        XCTAssertTrue(scratch.variationPool?[.pose].contains("phone held up covering the face") ?? false)
    }
}

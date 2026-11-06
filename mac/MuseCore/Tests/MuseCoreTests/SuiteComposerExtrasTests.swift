import XCTest
@testable import MuseCore

/// AI suite (workstream 1): the composer's later pieces — Recast's tap-a-face maths, swap's add-on pills, the Era decade
/// slider, UGC ad's format, @locations and their References limit, drag-to-reorder and the owner's engine pin.
final class SuiteComposerExtrasTests: XCTestCase {
    private var catalog: SuiteCatalog { SuiteDemoCatalog.catalog }
    private var cat: CameraCatalog { SuiteDemoCatalog.catalog.camera }
    private func img(_ n: String) -> SlotValue { SlotValue(name: "\(n).jpg", image: ImageRef(url: "https://x/\(n).jpg")) }

    // MARK: Tap a face

    func testATapGivesTheHintByThird() {
        XCTAssertEqual(RecastFaces.hint(x: 0.1), "left")
        XCTAssertEqual(RecastFaces.hint(x: 0.34), "center")
        XCTAssertEqual(RecastFaces.hint(x: 0.5), "center")
        XCTAssertEqual(RecastFaces.hint(x: 0.67), "right")
        XCTAssertEqual(RecastFaces.hint(x: 1), "right")
        XCTAssertEqual(RecastFaces.hint(for: FacePoint(x: 0.1, y: 0.5), chosen: nil), "left")
        XCTAssertEqual(RecastFaces.hint(for: FacePoint(x: 0.1, y: 0.5), chosen: "background"), "background", "a picked chip wins")
        XCTAssertEqual(FacePoint(x: -2, y: 3), FacePoint(x: 0, y: 1), "taps are clamped into the frame")
    }

    func testTheFaceCropIsASquareInsideTheFrame() {
        // 28% of the short side (1080) = 302 px, centred on the tap.
        XCTAssertEqual(RecastFaces.cropRect(FacePoint(x: 0.5, y: 0.5), width: 1080, height: 1920), PixelRect(x: 389, y: 809, width: 302, height: 302))
        // Near the edges it moves inside rather than shrinking.
        XCTAssertEqual(RecastFaces.cropRect(FacePoint(x: 0, y: 0), width: 1080, height: 1920), PixelRect(x: 0, y: 0, width: 302, height: 302))
        XCTAssertEqual(RecastFaces.cropRect(FacePoint(x: 1, y: 1), width: 1080, height: 1920), PixelRect(x: 778, y: 1618, width: 302, height: 302))
        // A landscape frame uses its height.
        let r = RecastFaces.cropRect(FacePoint(x: 0.9, y: 0.2), width: 1920, height: 1080)
        XCTAssertEqual(r.width, 302)
        XCTAssertEqual(r.height, 302)
        XCTAssertEqual(r.x, 1577)
        XCTAssertEqual(r.y, 65)
        XCTAssertLessThanOrEqual(r.x + r.width, 1920)
        // A tiny frame never gets a crop bigger than itself.
        XCTAssertEqual(RecastFaces.cropRect(FacePoint(x: 0.5, y: 0.5), width: 2, height: 2).width, 1)
    }

    func testMarkersAndClashingThirds() {
        let marks: [FacePoint?] = [FacePoint(x: 0.2, y: 0.3), nil, FacePoint(x: 0.8, y: 0.3)]
        XCTAssertEqual(RecastFaces.marker(at: FacePoint(x: 0.21, y: 0.31), in: marks), 0)
        XCTAssertEqual(RecastFaces.marker(at: FacePoint(x: 0.79, y: 0.3), in: marks), 2)
        XCTAssertNil(RecastFaces.marker(at: FacePoint(x: 0.5, y: 0.5), in: marks), "a new face")
        // Two faces tapped in the left third: they are told apart by their order from the left.
        let cast = [CastMember(characterId: "a", personHint: "left"), CastMember(characterId: "b", personHint: "left"), CastMember(characterId: "c", personHint: "center")]
        let out = RecastFaces.resolveClashes(cast, faces: [FacePoint(x: 0.25, y: 0.4), FacePoint(x: 0.1, y: 0.4), FacePoint(x: 0.5, y: 0.4)])
        XCTAssertEqual(out.map(\.personIndex), [2, 1, nil])
        XCTAssertEqual(out.map(\.personHint), ["left", "left", "center"])
        // No clash, nothing changes.
        XCTAssertEqual(RecastFaces.resolveClashes([cast[0], cast[2]], faces: [FacePoint(x: 0.1, y: 0.4), nil]), [cast[0], cast[2]])
    }

    func testTheFaceCropIsSentWithTheCast() throws {
        var m = CastMember(characterId: SampleData.demo, personHint: "right")
        m.faceCrop = ImageRef(url: "https://x/face.jpg")
        let r = ShotRequest.recast(clipId: "c1", cast: [m], quality: "standard")
        let json = String(data: try JSONEncoder().encode(r), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains(#""faceCrop":{"url":"https:\/\/x\/face.jpg"}"#), json)
        XCTAssertTrue(json.contains(#""personHint":"right""#))
        let back = try JSONDecoder().decode(ShotRequest.self, from: Data(json.utf8))
        XCTAssertEqual(back.cast?.first?.faceCrop?.url, "https://x/face.jpg")
    }

    // MARK: Swap add-ons

    func testAddOnPillsAndTheirPrices() throws {
        let f = VideoFeatures.fallback
        let pills = SwapAddOns.pills(f, clipSeconds: 7, takes: 2)
        XCTAssertEqual(pills.map(\.id), ["edit", "fast", "upscale"])
        let edit = try XCTUnwrap(pills.first { $0.id == "edit" })
        let fast = try XCTUnwrap(pills.first { $0.id == "fast" })
        let up = try XCTUnwrap(pills.first { $0.id == "upscale" })
        XCTAssertEqual(edit.quality, .edit)
        XCTAssertEqual(fast.quality, .fast)
        XCTAssertEqual(edit.price, Pricing.totalCost(RenderSpec.addOn(.edit, clipSeconds: 7, takes: 2)))
        XCTAssertEqual(fast.price, Pricing.totalCost(RenderSpec.addOn(.fast, clipSeconds: 7, takes: 2)))
        XCTAssertNotEqual(edit.price, fast.price, "each add-on has its own price")
        XCTAssertEqual(edit.priceText, "about " + Pricing.money(edit.price ?? 0))
        XCTAssertTrue(up.comingSoon)
        XCTAssertFalse(up.available)
        XCTAssertNil(up.price)
        XCTAssertEqual(up.priceText, "Soon")
        // Fast · beta shows only when the server has it.
        var off = f
        off.addons = off.addons.map { a0 -> AddonOption in var a = a0; if a.id == "fast" { a.available = false }; return a }
        XCTAssertEqual(SwapAddOns.pills(off, clipSeconds: 7).map(\.id), ["edit", "upscale"])
    }

    func testAddOnTogglesAndRequests() throws {
        let pills = SwapAddOns.pills(.fallback, clipSeconds: 9)
        let edit = try XCTUnwrap(pills.first { $0.id == "edit" })
        let fast = try XCTUnwrap(pills.first { $0.id == "fast" })
        let up = try XCTUnwrap(pills.first { $0.id == "upscale" })
        XCTAssertEqual(SwapAddOns.toggle(nil, edit), .edit)
        XCTAssertNil(SwapAddOns.toggle(.edit, edit), "tapping it again goes back to the ladder")
        XCTAssertEqual(SwapAddOns.toggle(.edit, fast), .fast, "one add-on at a time")
        XCTAssertEqual(SwapAddOns.toggle(.fast, up), .fast, "Upscale is coming soon")
        // What an add-on sends: the classic job with its engine, the whole clip and the default steps.
        let e = JobRequest.addOn(.edit, title: "Maya · Linen", modelId: "m", outfitId: "o", clipId: "c", takes: 2, clipSeconds: 9)
        XCTAssertEqual(e.engine, "h3")
        XCTAssertEqual(e.use, "full")
        XCTAssertEqual(e.steps, Pricing.stepsDefault)
        XCTAssertNil(e.quality)
        let f = JobRequest.addOn(.fast, title: "Maya · Linen", modelId: "m", outfitId: "o", clipId: "c", lipSync: true, clipSeconds: 9)
        XCTAssertEqual(f.engine, "viggle")
        XCTAssertFalse(f.lipSync, "lip sync is Edit only")
        XCTAssertEqual(f.videoQuality, .fast)
    }

    // MARK: Era slider

    func testTheEraSliderSnapsToDecades() {
        XCTAssertEqual(ComposerEras.stops(cat).map(\.id), ["1960s", "1970s", "1980s", "1990s", "2000s", "2010s", "2020s", "future"])
        XCTAssertEqual(ComposerEras.maxPosition(cat), 8)
        XCTAssertEqual(ComposerEras.position(nil, cat), 0)
        XCTAssertEqual(ComposerEras.position("1980s", cat), 3)
        XCTAssertEqual(ComposerEras.position("nope", cat), 0)
        XCTAssertNil(ComposerEras.era(at: 0, cat), "Auto is off the left end")
        XCTAssertNil(ComposerEras.era(at: 0.4, cat))
        XCTAssertEqual(ComposerEras.era(at: 0.6, cat), "1960s")
        XCTAssertEqual(ComposerEras.era(at: 2.6, cat), "1980s")
        XCTAssertEqual(ComposerEras.era(at: 7.2, cat), "2020s")
        XCTAssertEqual(ComposerEras.era(at: 99, cat), "future")
        XCTAssertNil(ComposerEras.era(at: -3, cat))
        XCTAssertEqual(ComposerEras.label(at: 0, cat), "Auto")
        XCTAssertEqual(ComposerEras.label(at: 8, cat), "Near future")
        for p in 0...8 { XCTAssertEqual(ComposerEras.position(ComposerEras.era(at: Double(p), cat), cat), p) }
    }

    // MARK: UGC format

    func testTheUgcFormatInTheRequestAndSummary() throws {
        XCTAssertEqual(cat.ugcFormats.map(\.id), ["unboxing", "review", "try_on", "before_after", "grwm", "haul", "tutorial", "testimonial"])
        XCTAssertEqual(cat.ugcFormats.map(\.label), ["Unboxing", "Review", "Try-on", "Before & after", "GRWM", "Haul", "Tutorial", "Testimonial"])
        let s = ComposerSettings(genre: "ugc", format: "unboxing")
        XCTAssertEqual(s.cameraSpec()?.style?.format, "unboxing")
        XCTAssertEqual(ComposerCatalog.summary(.style, s, cat).text(), "Style · Unboxing, UGC")
        XCTAssertEqual(ComposerCatalog.summary(.style, ComposerSettings(format: "try_on"), cat).value, "Try-on")
        XCTAssertTrue(s.isSet(.style))
        XCTAssertNil(s.reset(.style).format)
        // UGC ad sends it; other tools leave it out.
        let ugc = ComposerDraft(tool: .ugc, tokens: .text("Opens the parcel"), settings: ComposerSettings(format: "review"))
        let inputs = catalog.tier("draft")?.slots ?? .none
        XCTAssertEqual(ugc.request(InputSlots(), inputs).camera?.style?.format, "review")
        var shot = ugc
        shot.tool = .shot
        XCTAssertNil(shot.request(InputSlots(), inputs).camera)
        let json = try XCTUnwrap(String(data: try JSONEncoder().encode(CameraStyle(format: "grwm")), encoding: .utf8))
        XCTAssertEqual(json, #"{"format":"grwm"}"#)
        // The wheel: Auto first, then the formats.
        let wheel = ComposerWheels.formats(cat)
        XCTAssertNil(wheel.first?.value)
        XCTAssertEqual(wheel.count, 9)
        XCTAssertEqual(Wheel.index(of: "haul", in: wheel), 6)
    }

    func testUgcDecodesOnOlderCatalogs() throws {
        let old = try JSONDecoder().decode(CameraCatalog.self, from: Data(#"{"eras":[{"id":"1980s","label":"1980s"}]}"#.utf8))
        XCTAssertEqual(old.ugcFormats, [])
        XCTAssertEqual(ComposerWheels.formats(old).count, 1)
        XCTAssertEqual(ComposerCatalog.formatLabel(old, "try_on"), "Try on", "an id the catalog doesn't list reads as words")
        XCTAssertEqual(ComposerTool.ugc.required, [.character, .product])
        XCTAssertEqual(ComposerTool.ugc.optional, [.referenceAd])
        XCTAssertEqual(ComposerSlot.referenceAd.slotId, SlotId(.video))
        XCTAssertEqual(ComposerTool.ugc.chips, [.style])
    }

    // MARK: @location

    private let living = SuiteLocation(id: "loc_1", name: "Living room", image: ImageRef(url: "https://x/living.jpg"))
    private let roof = SuiteLocation(id: "loc_2", name: "Rooftop", image: ImageRef(url: "https://x/roof.jpg"))

    func testLocationTokensBecomeLocationReferences() throws {
        let inputs = SuiteInputs(start: true, end: true, images: 6, videos: 3, framesWithRefs: true)
        let slots = InputSlots().put(SlotId(.image), img("prop"))
        let (t, note) = ComposerLocations.add(living, to: .text("She waits in "), slots: slots, inputs: inputs)
        XCTAssertNil(note)
        XCTAssertEqual(ComposerLocations.ids(t), ["loc_1"])
        XCTAssertEqual(t.promptText(), "She waits in Living room", "a location token's text is its name")
        XCTAssertEqual(t.display(), "She waits in @Living room")
        XCTAssertEqual(ComposerLocations.used(t, slots: slots), 2)
        let r = ComposerDraft(tokens: t).request(slots, inputs, locations: [living, roof])
        let images = try XCTUnwrap(r.references?.images)
        XCTAssertEqual(images.map(\.role), ["product", "location"])
        XCTAssertEqual(images.last?.label, "Living room")
        XCTAssertEqual(images.last?.image.url, "https://x/living.jpg")
        // The same place twice is refused.
        XCTAssertEqual(ComposerLocations.add(living, to: t, slots: slots, inputs: inputs).1, "Living room is already in the shot")
        // No locations: no references added.
        XCTAssertNil(ComposerDraft(tokens: .text("x")).request(InputSlots(), inputs, locations: [living]).references)
    }

    func testLocationsCountAgainstTheReferencesLimit() {
        let two = SuiteInputs(start: true, end: true, images: 2)
        let slots = InputSlots().put(SlotId(.image), img("prop"))
        let (t, ok) = ComposerLocations.add(living, to: .text("At "), slots: slots, inputs: two)
        XCTAssertNil(ok)
        let (same, full) = ComposerLocations.add(roof, to: t, slots: slots, inputs: two)
        XCTAssertEqual(full, "References are full (2/2) · remove one to add a location")
        XCTAssertEqual(same, t)
        XCTAssertEqual(ComposerLocations.add(roof, to: .text("x"), slots: InputSlots(), inputs: .none).1, "This quality doesn't take references · try Standard or HD")
        // A quality with less room sends only what fits.
        var many = PromptTokens.text("From ")
        many = many.addMention(kind: "location", id: "loc_1", label: "Living room").0
        many = many.addMention(kind: "location", id: "loc_2", label: "Rooftop").0
        let r = ComposerDraft(tokens: many).request(InputSlots(), SuiteInputs(images: 1), locations: [living, roof])
        XCTAssertEqual(r.references?.images?.map(\.label), ["Living room"])
        XCTAssertEqual(ComposerLocations.cleanName("  rooftop   bar "), "Rooftop bar")
        XCTAssertNil(ComposerLocations.cleanName("   "))
    }

    func testLocationsDecodeAndTheDemoLibrary() async throws {
        let iso = try JSONDecoder().decode(SuiteLocation.self, from: Data(#"{"id":"l1","name":"Studio","image":{"url":"/uploads/x.jpg"},"createdAt":"2026-11-06T10:00:00Z"}"#.utf8))
        XCTAssertEqual(iso.name, "Studio")
        XCTAssertEqual(iso.createdAt, 1_793_959_200_000)
        let ms = try JSONDecoder().decode([SuiteLocation].self, from: Data(#"[{"id":"l2","image":{"asset":"a"},"createdAt":5}]"#.utf8))
        XCTAssertEqual(ms.first?.name, "l2")
        XCTAssertEqual(ms.first?.createdAt, 5)
        let a = FakeMuseAPI(speed: 0, genDelay: 0.01)
        _ = try await a.signIn(SignInRequest(email: "owner@studio.com", password: "x"))
        let list = try await a.suiteLocations()
        XCTAssertEqual(list.count, 2)
        let made = try await a.createSuiteLocation(NewSuiteLocation(name: "  rooftop ", image: ImageRef(url: "https://x/r.jpg")))
        XCTAssertEqual(made.name, "Rooftop")
        let after = try await a.suiteLocations()
        XCTAssertEqual(after.count, 3)
        try await a.deleteSuiteLocation(id: made.id)
        let gone = try await a.suiteLocations()
        XCTAssertEqual(gone.count, 2)
        do {
            _ = try await a.createSuiteLocation(NewSuiteLocation(name: " ", image: ImageRef(url: "https://x/r.jpg")))
            XCTFail("a name is needed")
        } catch let e as ApiError { XCTAssertEqual(e.code, "bad_request") }
    }

    // MARK: Reorder

    func testDragToReorderTokens() {
        let move = PromptPart.move(id: "dolly_in", label: "Dolly in", category: "push", intensity: 50, key: 2)
        let t = PromptTokens([.text("Walks "), .mention(kind: "character", id: "m", label: "Maya", key: 1), .text(" into the bar "), move])
        XCTAssertEqual(t.display(), "Walks @Maya into the bar #Dolly in")
        // The existing rule: by part index.
        XCTAssertEqual(t.reorder(key: 2, to: 0).display(), "#Dolly inWalks @Maya into the bar ")
        // Dropped at a caret: the text is split there.
        XCTAssertEqual(t.move(key: 1, to: Caret(2, 5)).display(), "Walks  into@Maya the bar #Dolly in")
        XCTAssertEqual(t.move(key: 2, to: Caret(0, 0)).display(), "#Dolly inWalks @Maya into the bar ")
        XCTAssertEqual(t.move(key: 1, to: Caret(3, 1)).display(), "Walks  into the bar #Dolly in@Maya")
        XCTAssertEqual(t.move(key: 1, to: Caret(1, 1)), t, "dropped on itself")
        XCTAssertEqual(t.move(key: 9, to: Caret(0, 0)), t)
        // Keys stay with their tokens.
        XCTAssertEqual(t.move(key: 1, to: Caret(0, 0)).index(ofKey: 1), 0)
        // Where a drop lands in the editor's text (a token is one character).
        XCTAssertEqual(t.caret(utf16: 0), Caret(0, 0))
        XCTAssertEqual(t.caret(utf16: 6), Caret(0, 6))
        XCTAssertEqual(t.caret(utf16: 7), Caret(1, 1))
        XCTAssertEqual(t.caret(utf16: 8), Caret(2, 1))
        XCTAssertEqual(t.caret(utf16: 999), t.caretAtEnd)
    }

    // MARK: Engine pin

    func testThePinnedEngineDrivesTheSlots() throws {
        let draft = try XCTUnwrap(catalog.tier("draft"))
        let models = ComposerEngines.options(draft)
        XCTAssertFalse(models.isEmpty)
        let veo = try XCTUnwrap(models.first { $0.inputs?.images == 0 })
        var d = ComposerDraft(tokens: .text("She waves"), quality: "draft")
        XCTAssertEqual(ComposerEngines.label(d, draft), "Engine · Auto")
        XCTAssertEqual(d.inputs(catalog), draft.slots)
        XCTAssertNil(d.request(InputSlots(), d.inputs(catalog)).engineModel)
        d = ComposerEngines.pin(d, veo)
        XCTAssertEqual(d.inputs(catalog), veo.inputs, "the slots follow the pinned engine")
        XCTAssertEqual(ComposerSlots.referencesCaption(d.inputs(catalog)), "Not on this quality")
        XCTAssertEqual(ComposerEngines.label(d, draft), "Engine · \(veo.name) · \(veo.resolution)")
        let r = d.request(InputSlots().put(SlotId(.image), img("ref")), d.inputs(catalog))
        XCTAssertEqual(r.engineModel, veo.model)
        XCTAssertEqual(r.resolution, veo.resolution)
        XCTAssertNil(r.references, "this engine takes no references")
        // Another quality without that engine drops the pin.
        var other = d
        other.quality = "standard"
        if !ComposerEngines.options(catalog.tier("standard")).contains(where: { $0.model == veo.model && $0.resolution == veo.resolution }) {
            XCTAssertNil(ComposerEngines.validated(other, catalog).engineModel)
        }
        XCTAssertEqual(ComposerEngines.validated(d, catalog).engineModel, veo.model)
        XCTAssertNil(ComposerEngines.pin(d, nil).resolution)
    }
}

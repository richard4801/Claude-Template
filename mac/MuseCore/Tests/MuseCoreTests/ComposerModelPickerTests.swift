import XCTest
@testable import MuseCore

/// The owner's model picker (WS6, 2026-11-08): the catalog's `engines[]` (or the registry on an older server) for a tool,
/// their limits applied to the composer, the pin's life across quality changes, and Photo's `imageModel`.
final class ComposerModelPickerTests: XCTestCase {
    private var settings: SuiteSettings { SuiteDemoCatalog.settings! }
    /// An older server: no `engines[]`, the picker works it out from the registry.
    private var oldCatalog: SuiteCatalog { var c = SuiteDemoCatalog.catalog; c.engines = nil; return c }

    private func ownerCatalog() async throws -> SuiteCatalog {
        try await FakeMuseAPI().suiteCatalog() // not signed in as a member: the owner's view
    }

    func testEnginesDecodeFromTheServersShape() throws {
        let json = #"{"enabled":true,"test":false,"tiers":[],"camera":{},"engines":[{"model":"veo-3.1-lite","name":"Veo 3.1 Lite","kind":"video","custom":false,"tier":"draft","tiers":["draft","hd"],"resolution":"720p","resolutions":[{"id":"720p","label":"720p","perSec":0.05},{"id":"1080p","label":"1080p","perSec":0.08}],"perSec":0.05,"perRun":null,"minSeconds":4,"maxSeconds":8,"allowedSeconds":[4,6,8],"aspectRatios":["9:16","16:9"],"inputs":{"start":true,"end":true,"middle":0,"images":0,"videos":0,"audio":false,"framesWithRefs":false},"price":{"basis":"per_second","usd":0.05}},{"model":"c_abc","name":"My FLUX","kind":"image","custom":true,"tier":null,"tiers":[],"resolution":null,"resolutions":[],"perSec":null,"perRun":0.04,"minSeconds":null,"maxSeconds":null,"allowedSeconds":null,"aspectRatios":[],"inputs":{"images":2},"price":{"basis":"per_run","usd":0.04}}]}"#
        let c = try JSONDecoder().decode(SuiteCatalog.self, from: Data(json.utf8))
        XCTAssertEqual(c.engines?.count, 2)
        let veo = c.engines![0]
        XCTAssertEqual(veo.allowedSeconds, [4, 6, 8])
        XCTAssertEqual(veo.tiers, ["draft", "hd"])
        XCTAssertEqual(veo.price?.basis, "per_second")
        XCTAssertTrue(c.engines![1].custom)
        XCTAssertEqual(ComposerModelPicker.price(c.engines![1]), "$0.040 a photo")
        XCTAssertNil(SuiteDemoCatalog.catalog.engines, "the member-shaped demo catalog has none")
    }

    func testOwnerCatalogListsShotAndPhotoModels() async throws {
        let c = try await ownerCatalog()
        let shot = ComposerModelPicker.options(c, nil, tool: .shot, quality: "standard").map(\.model)
        XCTAssertFalse(shot.contains("sora-2"), "removed")
        XCTAssertFalse(shot.contains("h3-open"), "licence-blocked")
        XCTAssertFalse(shot.contains("kling-o1"), "recast only")
        XCTAssertTrue(shot.contains("veo-3.1-lite"), "outside the Standard ladder, still offered")
        // The quality's ladder comes first, in its order.
        let ladder = (c.tier("standard")?.models ?? []).map(\.model).filter { shot.contains($0) }
        XCTAssertEqual(Array(shot.prefix(ladder.count)), ladder)
        let photo = ComposerModelPicker.options(c, nil, tool: .photo, quality: "standard")
        XCTAssertEqual(photo.map(\.kind), ["image", "image"])
        XCTAssertEqual(ComposerModelPicker.options(c, nil, tool: .shot, quality: "draft", search: "seed").map(\.model).sorted(), ["seedance-2.0", "seedance-2.5"])
        XCTAssertTrue(ComposerModelPicker.options(SuiteDemoCatalog.catalog, nil, tool: .shot, quality: "draft").isEmpty, "members get no list")
    }

    func testOlderServerFallsBackToTheRegistry() {
        let shot = ComposerModelPicker.options(oldCatalog, settings, tool: .shot, quality: "standard").map(\.model)
        XCTAssertTrue(shot.contains("veo-3.1-lite"))
        XCTAssertFalse(shot.contains("h3-max-3d"), "guide only: makes no text, frame or reference shot")
        XCTAssertTrue(ComposerModelPicker.options(oldCatalog, settings, tool: .photo, quality: "standard").isEmpty)
    }

    func testPinningAppliesTheModelsLengthsAndShapes() async throws {
        let c = try await ownerCatalog()
        var d = ComposerDraft(duration: 13)
        d.aspect = "1:1"
        let veo = c.engines!.first { $0.model == "veo-3.1-lite" }!
        let p = ComposerModelPicker.pin(d, veo, resolution: "720p", catalog: c, settings: nil)
        XCTAssertEqual(p.engineModel, "veo-3.1-lite")
        XCTAssertEqual(p.resolution, "720p")
        XCTAssertEqual(p.duration, 8, "13 s snaps to Veo's longest allowed length")
        XCTAssertEqual(p.aspect, "9:16", "1:1 isn't one of Veo's shapes")
        XCTAssertEqual(ComposerModelPicker.lengthRange(p, catalog: c, settings: nil), 4...8)
        XCTAssertEqual(ComposerModelPicker.allowedLengths(p, catalog: c, settings: nil), [4, 6, 8])
        XCTAssertEqual(ComposerModelPicker.aspects(p, catalog: c, settings: nil), ["9:16", "16:9"])
        XCTAssertEqual(ComposerModelPicker.label(p, catalog: c, settings: nil), "Veo 3.1 Lite, 720p")
        XCTAssertEqual(ComposerModelPicker.price(veo, resolution: "720p"), "$0.050/s")
        XCTAssertEqual(ComposerModelPicker.limits(veo), "4, 6 or 8 s, 9:16 and 16:9")
        // No resolution named: the one its ladder runs it at; an unknown one: the same.
        XCTAssertEqual(ComposerModelPicker.pin(d, veo, resolution: "8k", catalog: c, settings: nil).resolution, veo.resolution)
        // Kling 4.0 runs 3–30 s: 13 s is kept, 1:1 is one of its shapes.
        let kling = c.engines!.first { $0.model == "kling-v4" }!
        let k = ComposerModelPicker.pin(d, kling, catalog: c, settings: nil)
        XCTAssertEqual(k.duration, 13)
        XCTAssertEqual(k.aspect, "1:1")
        // Auto: back to the quality's limits.
        let auto = ComposerModelPicker.pin(p, nil, catalog: c, settings: nil)
        XCTAssertNil(auto.engineModel)
        XCTAssertNil(auto.resolution)
        XCTAssertEqual(ComposerModelPicker.label(auto, catalog: c, settings: nil), "Auto")
    }

    func testThePinSurvivesAQualityChangeAndFollowsTheModelsInputs() async throws {
        let c = try await ownerCatalog()
        let veo = c.engines!.first { $0.model == "veo-3.1-lite" }!
        var d = ComposerModelPicker.pin(ComposerDraft(duration: 6), veo, catalog: c, settings: nil)
        d.quality = "cinema"
        let v = ComposerModelPicker.validated(d, catalog: c, settings: nil)
        XCTAssertEqual(v.engineModel, "veo-3.1-lite", "a pin isn't tied to the quality")
        XCTAssertEqual(ComposerModelPicker.inputs(v, catalog: c, settings: nil), veo.inputs)
        // Gone from the owner's list (switched off in Settings): back to Auto.
        var off = c
        off.engines?.removeAll { $0.model == "veo-3.1-lite" }
        XCTAssertNil(ComposerModelPicker.validated(d, catalog: off, settings: nil).engineModel)
        // Without any list (a member's view) the tier rules apply as before.
        XCTAssertNil(ComposerModelPicker.validated(d, catalog: SuiteDemoCatalog.catalog, settings: nil).engineModel)
    }

    func testPhotoSendsTheImageModelAndOnlyForTheOwner() async throws {
        let c = try await ownerCatalog()
        let flux = c.engines!.first { $0.kind == "image" }!
        var photo = PhotoDraft(count: 2)
        photo.imageModel = flux.model
        XCTAssertEqual(ComposerModelPicker.imageLabel(photo, catalog: c), flux.name)
        var d = ComposerDraft(tool: .photo)
        d.tokens = PromptTokens.text("on a rooftop at dusk")
        XCTAssertNil(d.photoRequest(photo), "no character yet")
        // An image model the list no longer has is dropped.
        var gone = c
        gone.engines?.removeAll { $0.kind == "image" }
        XCTAssertNil(ComposerModelPicker.validatedImage(photo, gone).imageModel)
        XCTAssertEqual(ComposerModelPicker.validatedImage(photo, c).imageModel, flux.model)
        // The request carries it; nil stays out of the JSON (the server is strict).
        var r = PhotoRequest(modelId: "m_demo", count: 1)
        let plain = String(data: try JSONEncoder().encode(r), encoding: .utf8)!
        XCTAssertFalse(plain.contains("imageModel"))
        r.imageModel = flux.model
        let pinned = String(data: try JSONEncoder().encode(r), encoding: .utf8)!
        XCTAssertTrue(pinned.contains("\"imageModel\""))
    }

    func testToolsThatOfferThePicker() async throws {
        XCTAssertTrue(ComposerModelPicker.offered(.shot))
        XCTAssertTrue(ComposerModelPicker.offered(.photo))
        XCTAssertFalse(ComposerModelPicker.offered(.swap))
        XCTAssertFalse(ComposerModelPicker.offered(.extend))
        let c = try await ownerCatalog()
        let talking = ComposerModelPicker.options(c, nil, tool: .talking, quality: "draft")
        XCTAssertTrue(talking.allSatisfy { $0.inputs?.audio == true })
    }
}

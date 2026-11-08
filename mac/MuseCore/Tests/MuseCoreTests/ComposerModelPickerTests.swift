import XCTest
@testable import MuseCore

/// The owner's model picker (WS6, 2026-11-08): the registry's models for a tool, their limits applied to the composer,
/// and the pin's life across quality changes.
final class ComposerModelPickerTests: XCTestCase {
    private var catalog: SuiteCatalog { SuiteDemoCatalog.catalog }
    private var settings: SuiteSettings { SuiteDemoCatalog.settings! }

    func testRegistryDecodesWhatThePickerNeeds() {
        let veo = settings.models.first { $0.id == "veo-3.1-lite" }!
        XCTAssertEqual(veo.duration?.allowed, [4, 6, 8])
        XCTAssertEqual(veo.aspectRatios, ["9:16", "16:9"])
        XCTAssertTrue(veo.modes.text && veo.modes.image && !veo.modes.reference)
        XCTAssertEqual(veo.kind, "video")
        XCTAssertFalse(veo.custom)
        // inputs like the server's inputSlotsOf: start and end frames, no references
        XCTAssertEqual(veo.inputs, SuiteInputs(start: true, end: true, middle: 0, images: 0, videos: 0, audio: false, framesWithRefs: false))
        let kling = settings.models.first { $0.id == "kling-v4" }!
        XCTAssertEqual(kling.inputs.middle, 8)
        XCTAssertEqual(kling.inputs.images, 6)
        XCTAssertEqual(kling.inputs.videos, 3)
    }

    func testOptionsForShotLeaveOutBlockedRemovedAndRecastOnly() {
        let ids = ComposerModelPicker.options(settings, tool: .shot, tier: catalog.tier("standard")).map(\.id)
        XCTAssertFalse(ids.contains("sora-2"), "removed")
        XCTAssertFalse(ids.contains("h3-open"), "licence-blocked")
        XCTAssertFalse(ids.contains("kling-o1"), "recast only")
        XCTAssertFalse(ids.contains("h3-max-3d"), "guide only: no text, frame or reference shot")
        XCTAssertTrue(ids.contains("veo-3.1-lite"), "outside the Standard ladder, still offered")
        // The quality's ladder comes first, in its order.
        let ladder = (catalog.tier("standard")?.models ?? []).map(\.model).filter { ids.contains($0) }
        XCTAssertEqual(Array(ids.prefix(ladder.count)), ladder)
        XCTAssertEqual(ComposerModelPicker.options(settings, tool: .shot, tier: nil, search: "seed").map(\.id).sorted(), ["seedance-2.0", "seedance-2.5"])
        XCTAssertTrue(ComposerModelPicker.options(nil, tool: .shot, tier: nil).isEmpty, "members get no registry")
    }

    func testPinningAppliesTheModelsLengthsAndShapes() {
        var d = ComposerDraft(duration: 13)
        d.aspect = "1:1"
        let veo = settings.models.first { $0.id == "veo-3.1-lite" }!
        let p = ComposerModelPicker.pin(d, veo, resolution: "720p", catalog: catalog, settings: settings)
        XCTAssertEqual(p.engineModel, "veo-3.1-lite")
        XCTAssertEqual(p.resolution, "720p")
        XCTAssertEqual(p.duration, 8, "13 s snaps to Veo's longest allowed length")
        XCTAssertEqual(p.aspect, "9:16", "1:1 isn't one of Veo's shapes")
        XCTAssertEqual(ComposerModelPicker.lengthRange(p, tier: catalog.tier(p.quality), settings: settings), 4...8)
        XCTAssertEqual(ComposerModelPicker.allowedLengths(p, settings: settings), [4, 6, 8])
        XCTAssertEqual(ComposerModelPicker.aspects(p, catalog: catalog, settings: settings), ["9:16", "16:9"])
        XCTAssertEqual(ComposerModelPicker.label(p, settings: settings, tier: nil), "Veo 3.1 Lite, 720p")
        XCTAssertEqual(ComposerModelPicker.price(veo, resolution: "720p"), "$0.050/s")
        XCTAssertEqual(ComposerModelPicker.limits(veo), "4, 6 or 8 s, 9:16 and 16:9")
        // An unknown resolution falls back to the model's best.
        XCTAssertEqual(ComposerModelPicker.pin(d, veo, resolution: "8k", catalog: catalog, settings: settings).resolution, "1080p")
        // Kling 4.0 runs 3–30 s: 13 s is kept, 1:1 is one of its shapes.
        let kling = settings.models.first { $0.id == "kling-v4" }!
        let k = ComposerModelPicker.pin(d, kling, catalog: catalog, settings: settings)
        XCTAssertEqual(k.duration, 13)
        XCTAssertEqual(k.aspect, "1:1")
        // Auto: back to the quality's limits.
        let auto = ComposerModelPicker.pin(p, nil, catalog: catalog, settings: settings)
        XCTAssertNil(auto.engineModel)
        XCTAssertNil(auto.resolution)
        XCTAssertEqual(ComposerModelPicker.label(auto, settings: settings, tier: nil), "Auto")
    }

    func testThePinSurvivesAQualityChangeAndFollowsTheModelsInputs() {
        let veo = settings.models.first { $0.id == "veo-3.1-lite" }!
        var d = ComposerModelPicker.pin(ComposerDraft(duration: 6), veo, catalog: catalog, settings: settings)
        d.quality = "cinema"
        let v = ComposerModelPicker.validated(d, catalog: catalog, settings: settings)
        XCTAssertEqual(v.engineModel, "veo-3.1-lite", "a registry pin isn't tied to the quality")
        XCTAssertEqual(ComposerModelPicker.inputs(v, catalog: catalog, settings: settings), veo.inputs)
        // Switched off in Settings: the pin goes back to Auto.
        var off = settings
        off.models[off.models.firstIndex { $0.id == "veo-3.1-lite" }!].enabled = false
        XCTAssertNil(ComposerModelPicker.validated(d, catalog: catalog, settings: off).engineModel)
        // Without the registry (a member's view never has one) the tier rules apply as before.
        XCTAssertNil(ComposerModelPicker.validated(d, catalog: catalog, settings: nil).engineModel)
    }

    func testToolsThatOfferThePicker() {
        XCTAssertTrue(ComposerModelPicker.offered(.shot))
        XCTAssertFalse(ComposerModelPicker.offered(.swap))
        XCTAssertFalse(ComposerModelPicker.offered(.photo))
        let talking = ComposerModelPicker.options(settings, tool: .talking, tier: nil).map(\.id)
        XCTAssertTrue(talking.allSatisfy { id in (settings.models.first { $0.id == id }?.refs.audios ?? 0) > 0 })
    }
}

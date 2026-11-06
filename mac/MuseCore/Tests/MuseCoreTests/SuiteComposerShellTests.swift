import XCTest
@testable import MuseCore

/// AI suite (workstream 1): the composer shell's rules — the END FRAME dependency, the tools' slot sets, the
/// preset-collapsed composer, the Generate price states, the wheels (neighbours, Auto, merged ids) and the bottom bar.
final class SuiteComposerShellTests: XCTestCase {
    private var cat: CameraCatalog { SuiteDemoCatalog.catalog.camera }
    private let all = SuiteInputs(start: true, end: true, middle: 8, images: 6, videos: 3, audio: true, framesWithRefs: true)
    private func img(_ n: String) -> SlotValue { SlotValue(name: "\(n).jpg", image: ImageRef(url: "https://x/\(n).jpg")) }

    func testTheEndFrameWaitsForAStartFrame() {
        var s = InputSlots()
        XCTAssertTrue(s.isWaiting(SlotId(.end)))
        XCTAssertEqual(s.waitingCaption(SlotId(.end)), "After a start frame")
        XCTAssertFalse(s.isWaiting(SlotId(.start)))
        XCTAssertNil(s.waitingCaption(SlotId(.start)))
        XCTAssertEqual(SlotKind.end.prerequisite, .start)
        XCTAssertNil(SlotKind.start.prerequisite)
        // An end frame alone is not sent.
        s = s.put(SlotId(.end), img("end"))
        XCTAssertNil(s.apply(to: ShotRequest(prompt: "x"), all).frames)
        s = s.put(SlotId(.start), img("start"))
        XCTAssertFalse(s.isWaiting(SlotId(.end)))
        let r = s.apply(to: ShotRequest(prompt: "x"), all)
        XCTAssertEqual(r.frames?.start?.url, "https://x/start.jpg")
        XCTAssertEqual(r.frames?.end?.url, "https://x/end.jpg")
        // The card follows: greyed with its caption until the start frame is in.
        let empty = ComposerSlots.cards(.shot, inputs: all)
        XCTAssertEqual(empty.map(\.slot), [.character, .startFrame, .endFrame])
        XCTAssertEqual(empty.last?.waiting, true)
        XCTAssertEqual(empty.last?.caption, "After a start frame")
        XCTAssertTrue(empty.allSatisfy(\.optional))
        let filled = ComposerSlots.cards(.shot, inputs: all, slots: InputSlots().put(SlotId(.start), img("s")))
        XCTAssertEqual(filled.last?.waiting, false)
        XCTAssertEqual(filled.last?.caption, "Where it lands")
    }

    func testEachToolsSlots() {
        XCTAssertEqual(ComposerSlots.cards(.swap, inputs: all).map(\.slot), [.clip, .character])
        XCTAssertEqual(ComposerSlots.cards(.recast, inputs: all).map(\.slot), [.clip, .people])
        XCTAssertEqual(ComposerSlots.cards(.talking, inputs: all).map(\.slot), [.character, .audio, .location])
        XCTAssertEqual(ComposerSlots.cards(.ugc, inputs: all).map(\.slot), [.character, .product, .referenceAd])
        XCTAssertEqual(ComposerSlots.cards(.extend, inputs: all).map(\.slot), [.video])
        XCTAssertFalse(ComposerSlots.cards(.swap, inputs: all).contains { $0.optional })
        // A quality that takes no frames shows no frame cards.
        XCTAssertEqual(ComposerSlots.cards(.shot, inputs: .none).map(\.slot), [.character])
        XCTAssertEqual(ComposerTool.shot.chips, ComposerChip.allCases)
        XCTAssertEqual(ComposerTool.swap.chips, [.look])
        XCTAssertEqual(ComposerTool.recast.chips, [.look])
        XCTAssertEqual(ComposerTool.talking.chips, [.camera, .look, .lighting])
        XCTAssertEqual(ComposerTool.shell.filter(\.comingSoon), [.talking, .ugc])
        XCTAssertEqual(ComposerSlot.clip.caption, "Clip 3–30 s")
        XCTAssertEqual(ComposerSlots.referencesCaption(all), "Up to 6 images")
        XCTAssertEqual(ComposerSlots.referencesCaption(.none), "Not on this quality")
    }

    func testThePresetCollapsedComposer() throws {
        XCTAssertEqual(ComposerSlots.collapsed(preset: "cinematic"), [.character])
        XCTAssertEqual(ComposerSlots.collapsed(preset: "product_hero"), [.product])
        XCTAssertEqual(ComposerBar.shapes, ["9:16", "1:1", "16:9"])
        let p = try XCTUnwrap(cat.presets.first { $0.id == "phone_ugc" })
        let d = ComposerDraft(tokens: .text("She laughs")).applying(preset: p, cat)
        XCTAssertEqual(d.collapsed, "phone_ugc")
        XCTAssertEqual(d.settings.body, "phone")
        XCTAssertEqual(d.tokens.moves.compactMap(\.move).map(\.id), ["handheld"], "the preset's move becomes a #move")
        XCTAssertEqual(d.request(InputSlots(), all).camera?.move?.id, "handheld")
        XCTAssertNotNil(ComposerPresets.render(p, cat))
        XCTAssertEqual(ComposerPresets.summary(p, quality: "draft", seconds: 8), "Draft · 8 s · friend-filmed phone, natural light")
    }

    func testGeneratePriceStates() {
        XCTAssertEqual(GeneratePrice.of(nil), .unknown)
        XCTAssertEqual(GeneratePrice.of(nil).buttonText, "Generate · —")
        XCTAssertFalse(GeneratePrice.of(nil).canGenerate)
        let e = ShotEstimate(quality: "draft", label: "Shot · Draft · 768p", resolution: "768P", seconds: 8, takes: 1, mode: "text", estimate: 0.16,
                             priceLine: "about $0.16 · 8 s", buttonLabel: "Generate · 8 s · $0.16")
        XCTAssertEqual(GeneratePrice.of(e), .price("Generate · 8 s · $0.16"))
        XCTAssertTrue(GeneratePrice.of(e).canGenerate)
        var test = e
        test.test = true
        XCTAssertEqual(GeneratePrice.of(test).buttonText, "Generate · Free")
        var capped = e
        capped.ok = false
        capped.message = "Over the studio's $5.00 per-shot limit"
        XCTAssertEqual(GeneratePrice.of(capped).problem, "Over the studio's $5.00 per-shot limit")
        XCTAssertFalse(GeneratePrice.of(capped).canGenerate)
    }

    func testWheelNeighbours() throws {
        let items = ["auto", "a", "b", "c"]
        XCTAssertEqual(Wheel.window(items, selected: 0), WheelWindow(previous: nil, selected: "auto", next: "a"))
        XCTAssertEqual(Wheel.window(items, selected: 2), WheelWindow(previous: "a", selected: "b", next: "c"))
        XCTAssertEqual(Wheel.window(items, selected: 3), WheelWindow(previous: "b", selected: "c", next: nil))
        XCTAssertEqual(Wheel.window(items, selected: 9)?.selected, "c")
        XCTAssertNil(Wheel.window([String](), selected: 0))
        XCTAssertEqual(Wheel.step(0, by: -1, count: 4), 0)
        XCTAssertEqual(Wheel.step(2, by: 1, count: 4), 3)
        XCTAssertEqual(Wheel.step(3, by: 1, count: 4), 3)
        XCTAssertEqual(Wheel.position(4, count: 11), "5 / 11")

        let cams = ComposerWheels.cameras(cat)
        XCTAssertEqual(cams.count, 11, "Auto + the 10 visible bodies")
        XCTAssertEqual(cams.first?.name, "Auto")
        XCTAssertNil(cams.first?.value)
        XCTAssertFalse(cams.contains { $0.value == "super35" }, "merged bodies don't show")
        let i = Wheel.index(of: "super35", in: cams, options: cat.bodies)
        XCTAssertEqual(cams[i].value, "cinema_digital", "a merged id sits on its survivor")
        XCTAssertEqual(Wheel.index(of: nil, in: cams), 0)
        let w = try XCTUnwrap(Wheel.window(cams, selected: Wheel.index(of: "film_35", in: cams)))
        XCTAssertEqual(w.previous?.value, "cinema_digital")
        XCTAssertEqual(w.next?.value, "film_16")

        let focals = ComposerWheels.focals(cat)
        XCTAssertEqual(focals.map(\.value), [nil, "14", "24", "35", "50", "85", "135"])
        XCTAssertEqual(focals[4].name, "50 mm · Natural")
        XCTAssertEqual(ComposerWheels.focalIndex(50, in: focals), 4)
        XCTAssertEqual(ComposerWheels.apertures(cat).count, 5)
        XCTAssertEqual(ComposerWheels.apertures(cat)[1].name, "f/1.4 · Dreamy blur")
        XCTAssertEqual(ComposerWheels.lenses(cat).count, 10)
        XCTAssertEqual(ComposerWheels.heights(cat).first?.name, "Auto")
        XCTAssertGreaterThan(ComposerWheels.fieldOfView(24), ComposerWheels.fieldOfView(85))
    }

    func testTheBottomBarAndMoves() {
        let draft = SuiteTier(id: "draft", label: "Draft", detail: "", maxSeconds: 15, minSeconds: 2)
        XCTAssertEqual(ComposerBar.lengthRange(draft), 2...15)
        XCTAssertEqual(ComposerBar.clampLength(30, draft), 15)
        XCTAssertEqual(ComposerBar.lengthRange(nil), 4...15)
        XCTAssertEqual(ComposerBar.takes(4), [1, 2, 3, 4])
        XCTAssertEqual(ComposerBar.takes(9), [1, 2, 3, 4])
        XCTAssertEqual(ComposerBar.acceptsLine(all), "Start, middle, end · refs · clips · audio")
        XCTAssertEqual(ComposerBar.acceptsLine(SuiteInputs(start: true, end: true, images: 6)), "Start + end frame · refs")
        XCTAssertEqual(ComposerBar.acceptsLine(.none), "Prompt only")
        XCTAssertEqual(SuiteDemoCatalog.catalog.tier("hd")?.minSeconds, 3)
        XCTAssertEqual(ComposerSpeaking.auto.value, nil)
        XCTAssertEqual(ComposerSpeaking.on.value, true)
        XCTAssertEqual(ComposerSpeaking.off.label, "Off")

        let featured = ComposerMoves.list(cat, group: ComposerMoves.featured)
        XCTAssertEqual(featured.map(\.id), cat.library.map(\.id))
        XCTAssertTrue(ComposerMoves.list(cat, group: "orbit").allSatisfy { $0.group == "orbit" })
        XCTAssertEqual(ComposerMoves.list(cat, group: "orbit", query: "dolly").first?.id, "dolly_in")
        XCTAssertEqual(ComposerMoves.groups(cat).first?.id, "featured")
        XCTAssertEqual(PickerPreview.move(featured[0]).still, PickerPreview.neutralMoveStill)
        // The rendered loop now comes with the catalog (design/previews).
        XCTAssertEqual(PickerPreview.move(featured[0]).video, "moves/\(featured[0].id).mp4")
    }

    func testTheDraftsRequest() {
        var d = ComposerDraft(tokens: PromptTokens.text(" walks in").addMention(kind: "character", id: SampleData.demo, label: "Noor", at: Caret(0, 0)).0,
                              outfitId: "o1", quality: "hd", duration: 6, sound: false, speaking: .on, takes: 2)
        var r = d.request(InputSlots(), all)
        XCTAssertEqual(r.modelId, SampleData.demo)
        XCTAssertEqual(r.outfitId, "o1")
        XCTAssertEqual(r.prompt, "Noor walks in")
        XCTAssertEqual(r.quality, "hd")
        XCTAssertEqual(r.duration, 6)
        XCTAssertFalse(r.audio)
        XCTAssertEqual(r.speaking, true)
        XCTAssertEqual(r.takes, 2)
        XCTAssertNil(r.camera)
        XCTAssertEqual(d.title, "Noor walks in")
        d.directed = CameraSpec(mode: "directed")
        r = d.request(InputSlots(), all)
        XCTAssertEqual(r.camera?.mode, "directed")
    }

    func testPickingASuggestionReplacesWhatWasTyped() throws {
        let typed = PromptTokens.text("She walks #dol now")
        let trig = try XCTUnwrap(PromptTokens.activeTrigger("She walks #dol now", caret: 14))
        let (cut, caret) = typed.removingTrigger(trig, part: 0, caret: 14)
        XCTAssertEqual(cut.parts, [.text("She walks  now")])
        XCTAssertEqual(caret, Caret(0, 10))
        let dolly = try XCTUnwrap(cat.move("dolly_in"))
        let (withMove, note) = cut.addMove(dolly, at: caret, catalog: cat)
        XCTAssertNil(note)
        XCTAssertEqual(withMove.display(), "She walks #Dolly in now")
        XCTAssertEqual(withMove.index(ofKey: try XCTUnwrap(withMove.lastKey)), 1)
        XCTAssertEqual(typed.removingTrigger(trig, part: 5, caret: 14).0, typed)
    }
}

import XCTest
@testable import MuseCore

/// AI suite (workstream 1): the Shot's input slots — which show for a tier, filling and clearing, what is sent, the
/// catalog's `inputs` (real API JSON) and demo mode. Same cases as Android's SuiteInputSlotsTest.
final class SuiteInputSlotsTests: XCTestCase {
    private let all = SuiteInputs(start: true, end: true, middle: 8, images: 6, videos: 3, audio: true, framesWithRefs: true)
    private let framesOnly = SuiteInputs(start: true, end: true)
    private func img(_ n: String) -> SlotValue { SlotValue(name: "\(n).jpg", image: ImageRef(url: "https://x/\(n).jpg")) }
    private func vid(_ n: String) -> SlotValue { SlotValue(name: "\(n).mp4", media: SuiteVideoRef(key: "c/\(n).mp4")) }

    func testASlotShowsOnlyWhenTheTierTakesIt() {
        let s = InputSlots()
        XCTAssertEqual(s.visible(.none), [])
        XCTAssertEqual(s.visible(framesOnly), [SlotId(.start), SlotId(.end)])
        XCTAssertEqual(s.visible(all).map(\.kind), SlotKind.allCases, "many-of kinds show one empty add slot each")
    }

    func testManyOfKindsFillFromTheFrontAndStopAtTheTiersCount() {
        var s = InputSlots().put(SlotId(.image, 4), img("a"))
        XCTAssertEqual(s[SlotId(.image, 0)]?.name, "a.jpg")
        s = s.put(SlotId(.image, 1), img("b"))
        XCTAssertEqual(s.visible(all).filter { $0.kind == .image }.map(\.index), [0, 1, 2])
        var two = all
        two.images = 2
        XCTAssertEqual(s.visible(two).filter { $0.kind == .image }.map(\.index), [0, 1])
        XCTAssertEqual(s.hidden(two), [])
        var one = all
        one.images = 1
        XCTAssertEqual(s.hidden(one), [SlotId(.image, 1)])
        XCTAssertEqual(SlotId(.image, 1).title, "Reference 2")
        XCTAssertEqual(SlotId(.start).title, "Start frame")
    }

    func testClearingClosesTheGapAndUploadsFindTheirValueByToken() {
        let tok = UUID()
        var s = InputSlots().put(SlotId(.image), img("a")).put(SlotId(.image, 1), SlotValue(name: "b.jpg", image: ImageRef(url: "https://x/b.jpg"), progress: 0.3, token: tok))
        s = s.clear(SlotId(.image, 0))
        XCTAssertEqual(s[SlotId(.image, 0)]?.name, "b.jpg")
        s = s.update(token: tok) { var v = $0; v.progress = nil; return v }
        XCTAssertTrue(s[SlotId(.image, 0)]?.ready == true)
        XCTAssertEqual(s.update(token: UUID()) { var v = $0; v.name = "x"; return v }, s)
    }

    func testTheRequestCarriesOnlyReadySlotsTheTierTakes() throws {
        var bottle = img("bottle")
        bottle.role = "product"
        var busy = img("busy")
        busy.progress = 0.5
        var walk = vid("walk")
        walk.use = "camera"
        let s = InputSlots()
            .put(SlotId(.start), img("start"))
            .put(SlotId(.middle), img("mid"))
            .put(SlotId(.image), bottle)
            .put(SlotId(.image, 1), busy)
            .put(SlotId(.video), walk)
            .put(SlotId(.audio), vid("beat"))
        let r = s.apply(to: ShotRequest(prompt: "x"), all)
        XCTAssertEqual(r.frames?.start?.url, "https://x/start.jpg")
        XCTAssertEqual(r.frames?.middle?.count, 1)
        XCTAssertNil(r.frames?.end)
        XCTAssertEqual(r.references?.images?.map(\.label), ["bottle"])
        XCTAssertEqual(r.references?.videos?.first?.use, "camera")
        XCTAssertEqual(r.references?.audio?.audio.key, "c/beat.mp4")
        let f = s.apply(to: ShotRequest(prompt: "x"), framesOnly)
        XCTAssertNil(f.references)
        XCTAssertNil(f.frames?.middle)
        let empty = InputSlots().apply(to: ShotRequest(prompt: "x"), all)
        XCTAssertNil(empty.frames)
        let json = String(decoding: try JSONEncoder().encode(empty), as: UTF8.self)
        XCTAssertFalse(json.contains("frames"), "nil slots are left out of the request")
    }

    func testNotes() {
        let s = InputSlots().put(SlotId(.start), img("s")).put(SlotId(.image), img("r"))
        XCTAssertNil(s.note(all))
        var noMix = all
        noMix.framesWithRefs = false
        XCTAssertEqual(s.note(noMix), "On this quality the frames carry the look · references aren't used")
        XCTAssertEqual(s.note(framesOnly), "1 input not used on this quality")
    }

    func testCatalogInputsDecodeOlderServersFallBackAndTheOwnersEngineHasItsOwn() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "catalog_owner", withExtension: "json", subdirectory: "Fixtures/suite"))
        let c = try JSONDecoder().decode(SuiteCatalog.self, from: Data(contentsOf: url))
        let standard = try XCTUnwrap(c.tiers.first { $0.id == "standard" })
        XCTAssertEqual(standard.slots.middle, 8)
        XCTAssertTrue(standard.slots.audio)
        XCTAssertEqual(standard.slots(for: "h3").middle, 0)
        XCTAssertEqual(standard.slots(for: "kling-v4").middle, 8)
        XCTAssertEqual(standard.slots(for: "unknown"), standard.slots)
        let old = try JSONDecoder().decode(SuiteTier.self, from: Data(#"{"id":"draft","canKeyframes":true,"canReferences":false}"#.utf8))
        XCTAssertEqual(old.slots, SuiteInputs(start: true, end: true))
        let member = try JSONDecoder().decode(SuiteCatalog.self, from: Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "catalog_member", withExtension: "json", subdirectory: "Fixtures/suite"))))
        XCTAssertTrue(member.tiers.allSatisfy { $0.inputs != nil && $0.models == nil })
    }

    func testDemoCatalogHasInputsAndUploadsMediaWithoutAServer() async throws {
        let api = FakeMuseAPI(speed: 100_000, genDelay: 0.02)
        let c = try await api.suiteCatalog()
        XCTAssertTrue(c.tiers.allSatisfy { $0.inputs != nil && $0.slots.start })
        let ref = try await api.uploadSuiteMedia(URL(fileURLWithPath: "/tmp/walk.mp4"), contentType: "video/mp4", progress: nil)
        XCTAssertTrue(ref.key?.hasPrefix("c/demo_") == true && ref.key?.hasSuffix(".mp4") == true)
    }
}

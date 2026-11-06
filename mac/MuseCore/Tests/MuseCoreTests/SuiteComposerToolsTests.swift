import XCTest
@testable import MuseCore

/// AI suite (workstream 1): which composer tools are live (`catalog.tools`), and the Talking and UGC ad requests.
final class SuiteComposerToolsTests: XCTestCase {
    private let all = SuiteInputs(start: true, end: true, middle: 8, images: 6, videos: 3, audio: true, framesWithRefs: true)
    private func img(_ n: String) -> SlotValue { SlotValue(name: "\(n).jpg", image: ImageRef(url: "https://x/\(n).jpg")) }
    private func media(_ key: String) -> SlotValue { SlotValue(name: key, media: SuiteVideoRef(key: key)) }
    private func lead() -> PromptTokens {
        PromptTokens.text(" talks about her day").addMention(kind: "character", id: SampleData.demo, label: "Maya", at: Caret(0, 0)).0
    }

    func testComingSoonFollowsTheCatalogsTools() throws {
        let c = SuiteDemoCatalog.catalog
        XCTAssertEqual(c.tools.map(\.id), ["shot", "swap", "recast", "storyboard", "talking", "ugc_ad", "extend"])
        XCTAssertFalse(ComposerTool.talking.isComingSoon(in: c))
        XCTAssertFalse(ComposerTool.ugc.isComingSoon(in: c), "ugc_ad is UGC ad")
        XCTAssertTrue(ComposerTool.extend.isComingSoon(in: c))
        XCTAssertEqual(c.tools.last, SuiteToolStatus(id: "extend", available: false, comingSoon: true))
        // A catalog without tools keeps the app's own list.
        let old = try JSONDecoder().decode(SuiteCatalog.self, from: Data(#"{"enabled":true,"tiers":[]}"#.utf8))
        XCTAssertEqual(old.tools, [])
        XCTAssertEqual(ComposerTool.shell.filter { $0.isComingSoon(in: old) }, [.talking, .ugc, .extend])
        XCTAssertEqual(ComposerTool.shell.filter { $0.isComingSoon(in: nil) }, [.talking, .ugc, .extend])
        // A server that switches a tool off.
        var off = c
        off.tools = [SuiteToolStatus(id: "shot", available: false)]
        XCTAssertTrue(ComposerTool.shot.isComingSoon(in: off))
        XCTAssertTrue(ComposerTool.ugc.isComingSoon(in: off), "not listed: the app's own list")
        let json = String(data: try JSONEncoder().encode(SuiteToolStatus(id: "shot", available: true)), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("comingSoon"), "only sent when true")
    }

    func testTheTalkingRequest() throws {
        var d = ComposerDraft(tool: .talking, tokens: lead())
        XCTAssertEqual(d.missing(InputSlots()), "Add the audio she says")
        XCTAssertEqual(ComposerDraft(tool: .talking).missing(InputSlots()), "Pick a character first")
        let slots = InputSlots().put(SlotId(.audio), media("c/voice.m4a")).put(SlotId(.image), img("kitchen"))
        XCTAssertNil(d.missing(slots))
        let r = d.request(slots, all)
        XCTAssertEqual(r.modelId, SampleData.demo)
        XCTAssertEqual(r.references?.audio?.audio.key, "c/voice.m4a")
        XCTAssertEqual(r.speaking, true, "Talking speaks unless switched off")
        XCTAssertEqual(r.references?.images?.map(\.role), ["location"], "the optional image is where she is")
        d.speaking = .off
        XCTAssertEqual(d.request(slots, all).speaking, false)
        // No location image: none sent.
        XCTAssertNil(ComposerDraft(tool: .talking, tokens: lead()).request(InputSlots().put(SlotId(.audio), media("c/v.m4a")), all).references?.images)
        XCTAssertEqual(ComposerSlot.location.slotId, SlotId(.image))
        XCTAssertEqual(ComposerSlots.cards(.talking, inputs: all).map(\.slot), [.character, .audio, .location])
    }

    func testTheUgcAdRequest() throws {
        var d = ComposerDraft(tool: .ugc, tokens: lead(), settings: ComposerSettings(format: "unboxing"))
        XCTAssertEqual(d.missing(InputSlots()), "Add a photo of the product")
        var product = img("serum")
        product.role = "style"
        let slots = InputSlots().put(SlotId(.image), product).put(SlotId(.video), media("c/ad.mp4"))
        XCTAssertNil(d.missing(slots))
        let r = d.request(slots, all)
        XCTAssertEqual(r.references?.images?.map(\.role), ["product"])
        XCTAssertEqual(r.references?.images?.first?.image.url, "https://x/serum.jpg")
        XCTAssertEqual(r.references?.videos?.map(\.video.key), ["c/ad.mp4"], "the reference ad")
        XCTAssertEqual(r.camera?.style?.format, "unboxing")
        XCTAssertNil(r.speaking)
        // Without the reference ad, no videos.
        XCTAssertNil(d.request(InputSlots().put(SlotId(.image), img("serum")), all).references?.videos)
        d.tool = .shot
        XCTAssertNil(d.missing(InputSlots()), "Shot needs nothing")
    }
}

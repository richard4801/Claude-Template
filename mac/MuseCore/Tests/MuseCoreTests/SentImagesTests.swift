import XCTest
@testable import MuseCore

/// Images sent (server images/sent.ts): estimates decode `sentImages`, and the composer's draft carries Claude's choice.
final class SentImagesTests: XCTestCase {
    func testEstimatesDecodeSentImages() throws {
        let json = #"{"quality":"draft","label":"Shot","estimate":0.4,"priceLine":"","buttonLabel":"Generate","sentImages":{"images":[{"image":{"asset":"g_back"},"role":"person","label":"body, back","why":"chosen by Claude"}],"changed":true,"changedBy":"claude","max":9}}"#
        let e = try JSONDecoder().decode(ShotEstimate.self, from: Data(json.utf8))
        XCTAssertEqual(e.sentImages?.images.first?.image.asset, "g_back")
        XCTAssertEqual(e.sentImages?.tag, "Changed by Claude")
        XCTAssertEqual(e.sentImages?.title, "Images sent (1)")
        let p = try JSONDecoder().decode(PhotoEstimate.self, from: Data(#"{"count":1,"perPhoto":0.1,"sentImages":{"images":[],"changed":false}}"#.utf8))
        XCTAssertEqual(p.asShotEstimate.sentImages?.changed, false)
        XCTAssertNil(try JSONDecoder().decode(ShotEstimate.self, from: Data(#"{"quality":"draft"}"#.utf8)).sentImages) // older server
    }

    func testDraftCarriesTheChoiceAndReset() {
        var d = ComposerDraft(tool: .shot)
        let choice: JSONValue = .object(["excludeImages": .array([.object(["asset": .string("c_face")])]), "sentImagesBy": .string("claude")])
        d.sent = choice
        let s = ComposerDrafts.draft(d)
        XCTAssertEqual(s.raw["sent"], choice)
        XCTAssertEqual(ComposerDrafts.restore(s, into: ComposerDraft(tool: .shot)).sent, choice)
        d.sent = .null // Reset to automatic: sent as null so the server forgets it
        XCTAssertEqual(ComposerDrafts.draft(d).raw["sent"], .null)
        var c = ComposerDraft(tool: .shot)
        c.sent = choice
        XCTAssertTrue(SuiteAssistDraft.changedRows(ComposerDraft(tool: .shot), c).contains("Images sent"))
        XCTAssertFalse(SuiteAssistDraft.changedRows(ComposerDraft(tool: .shot), d).contains("Images sent")) // reset = automatic
    }
}

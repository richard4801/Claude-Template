@testable import MuseCore
import XCTest

/// The outfit page's paging (plans/outfit-head-looks.md §4): 8 per page, newest first, refill and step back on delete.
final class OutfitPagesTests: XCTestCase {
    private func outfits(_ n: Int) -> [Outfit] {
        (0..<n).map { Outfit(id: "o\($0)", modelId: "m", name: "Set \($0)", createdAt: Int64(1_000 + $0)) }
    }

    func testPagesAndLabel() {
        XCTAssertEqual(OutfitPages.count(0), 1)
        XCTAssertEqual(OutfitPages.count(8), 1)
        XCTAssertEqual(OutfitPages.count(9), 2)
        XCTAssertEqual(OutfitPages.count(17), 3)
        XCTAssertEqual(OutfitPages.label(0, items: 17), "1 of 3")
        XCTAssertEqual(OutfitPages.label(5, items: 17), "3 of 3")
    }

    func testNewestFirstAndSlices() {
        let list = OutfitPages.newestFirst(outfits(17))
        XCTAssertEqual(list.first?.id, "o16")
        XCTAssertEqual(OutfitPages.slice(list, page: 0).map(\.id), (9...16).reversed().map { "o\($0)" })
        XCTAssertEqual(OutfitPages.slice(list, page: 2).map(\.id), ["o0"])
    }

    func testDeleteRefillsAndStepsBack() {
        var list = OutfitPages.newestFirst(outfits(9))
        // A delete on page 1 pulls the next page's first outfit up.
        list.removeAll { $0.id == "o5" }
        XCTAssertEqual(OutfitPages.slice(list, page: 0).count, 8)
        XCTAssertEqual(OutfitPages.slice(list, page: 0).last?.id, "o0")
        // The last page emptied: page 2 steps back to page 1.
        XCTAssertEqual(OutfitPages.clamp(1, items: list.count), 0)
        XCTAssertEqual(OutfitPages.slice(list, page: 1).count, 8)
    }

    /// Every outfit's 7 pictures (plans/outfit-faces.md): the angles, then its face close-ups; missing ones are skipped.
    func testSevenPicturesInViewerOrder() {
        var o = Outfit(id: "o", modelId: "m", name: "Linen", angles: [.asset("f"), .asset("t"), nil, .asset("b")], faces: [.asset("ff"), nil, .asset("fs")])
        XCTAssertEqual(OutfitPictures.refs(o).count, 7)
        XCTAssertEqual(OutfitPictures.shown(o).map { $0.index }, [0, 1, 3, 4, 6])
        XCTAssertEqual(OutfitPictures.shown(o).map { $0.label }, ["Front", "Three-quarter", "Back", "Face front", "Face side"])
        XCTAssertEqual(o.madeFaces, 2)
        XCTAssertTrue(o.hasFaces)
        XCTAssertEqual(OutfitPictures.keys[5], "faceTq")
        o.faces = nil // an older outfit: "Add face close-ups"
        XCTAssertEqual(o.madeFaces, 0)
        XCTAssertFalse(o.hasFaces)
        XCTAssertEqual(OutfitPictures.shown(o).count, 3)
    }

    /// Reorder (owner 2026-11-12): moves swap two slots; "Move to…" names the other six.
    func testReorderSwapsAndMenuTitles() {
        let o = Outfit(id: "o", modelId: "m", name: "Linen", angles: [.asset("f"), .asset("t"), .asset("b"), .asset("s")], faces: [.asset("ff"), nil, nil])
        let fixed = OutfitPictures.swapped(OutfitPictures.refs(o), 2, 3)
        XCTAssertEqual(fixed.prefix(4).map { $0?.asset }, ["f", "t", "s", "b"])
        XCTAssertEqual(fixed.compactMap { $0 }.count, 5, "nothing is lost")
        let targets = OutfitPictures.moveTargets(o, from: 2)
        XCTAssertEqual(targets.map { $0.index }, [0, 1, 3, 4, 5, 6])
        XCTAssertEqual(targets.first { $0.index == 3 }?.title, "Swap with Back")
        XCTAssertEqual(targets.first { $0.index == 6 }?.title, "Move to Face side")
    }

    /// A set that came out partly (owner 2026-11-12): the label, and each missing picture has its own Redo.
    func testPartialOutfitDecodesAndNamesMissingPictures() throws {
        let json = #"{"id":"o1","modelId":"m","name":"Red","angles":[{"asset":"c_front"},{"asset":"c_tq"},null,null],"faces":[{"asset":"face"},{"asset":"face"},{"asset":"face"}],"state":"preview","partial":{"made":5,"of":7,"missing":["side","back"],"label":"5 of 7 made · Redo the missing ones"}}"#
        let o = try JSONDecoder().decode(Outfit.self, from: Data(json.utf8))
        XCTAssertEqual(o.partial?.label, "5 of 7 made · Redo the missing ones")
        XCTAssertEqual((0..<7).filter { o.isMissing($0) }, [2, 3])
        let whole = try JSONDecoder().decode(Outfit.self, from: Data(#"{"id":"o2","angles":[null,null,null,null]}"#.utf8))
        XCTAssertNil(whole.partial)
        XCTAssertFalse(whole.isMissing(2))
    }

    /// Upload picture (owner 2026-11-17): the outfit's upload marks and replaced pictures decode; the menu's words.
    func testUploadedPictureDecodesWithPreviousAndWords() throws {
        let json = #"{"id":"o1","angles":[{"asset":"f"},{"asset":"t"},{"url":"https://x/uploads/u/outfit_1.jpg"},{"asset":"b"}],"sources":{"side":"upload"},"replaced":[{"slot":"side","image":{"asset":"s"},"source":"generated","at":1,"by":"u1"}]}"#
        let o = try JSONDecoder().decode(Outfit.self, from: Data(json.utf8))
        XCTAssertTrue(OutfitPictures.isUpload(o, 2))
        XCTAssertFalse(OutfitPictures.isUpload(o, 0))
        XCTAssertEqual(OutfitPictures.previous(o, 2), .asset("s"))
        XCTAssertNil(OutfitPictures.previous(o, 3))
        XCTAssertEqual(OutfitPictures.replaceQuestion(5), "Replace the Face ¾ picture?")
        XCTAssertEqual(OutfitPictures.uploadTitle, "Upload picture…", "free: no price on it")
        let older = try JSONDecoder().decode(Outfit.self, from: Data(#"{"id":"o2","angles":[null,null,null,null]}"#.utf8))
        XCTAssertNil(older.sources)
        XCTAssertNil(OutfitPictures.previous(older, 0))
    }

    /// The demo backend: an upload into a filled slot keeps the old one; putting it back restores it and its mark goes.
    func testFakeSetOutfitPictureReplacesAndPutsBack() async throws {
        let api: any MuseAPI = FakeMuseAPI(speed: 0)
        let o = try await api.listOutfits()[0]
        let mine = ImageRef(url: "https://x/uploads/u/outfit_9.jpg")
        let r = try await api.setOutfitPicture(id: o.id, picture: "side", image: mine)
        XCTAssertEqual(r.replaced, .asset("g_side"))
        XCTAssertEqual(r.outfit.angles[2], mine)
        XCTAssertTrue(OutfitPictures.isUpload(r.outfit, 2))
        XCTAssertEqual(OutfitPictures.previous(r.outfit, 2), .asset("g_side"))
        let back = try await api.setOutfitPicture(id: o.id, picture: "side", image: .asset("g_side"))
        XCTAssertEqual(back.outfit.angles[2], .asset("g_side"))
        XCTAssertFalse(OutfitPictures.isUpload(back.outfit, 2))
        XCTAssertEqual(OutfitPictures.previous(back.outfit, 2), mine)
        let face = try await api.setOutfitPicture(id: o.id, picture: "faceTq", image: mine)
        XCTAssertEqual(face.outfit.faces?.map { $0 != nil }, [false, true, false])
        XCTAssertNil(face.replaced)
    }
}

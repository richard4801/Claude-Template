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
}

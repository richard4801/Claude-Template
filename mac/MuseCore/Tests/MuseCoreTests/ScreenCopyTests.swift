import XCTest
@testable import MuseCore

final class ScreenCopyTests: XCTestCase {
    func testMetaDropsEmptyPartsAndCapsAtThree() {
        XCTAssertEqual(ScreenCopy.meta(["8 s", nil, " ", "9:16", "HD", "seed 4"]), "8 s · 9:16 · HD")
        XCTAssertEqual(ScreenCopy.meta(["a", "b"], limit: 1), "a")
        XCTAssertEqual(ScreenCopy.meta(["a", "b", "c", "d"], limit: 9), "a · b · c")
        XCTAssertEqual(ScreenCopy.meta([nil, ""]), "")
    }

    func testCount() {
        XCTAssertEqual(ScreenCopy.count(1, "take"), "1 take")
        XCTAssertEqual(ScreenCopy.count(0, "take"), "0 takes")
        XCTAssertEqual(ScreenCopy.count(3, "outfit"), "3 outfits")
        XCTAssertEqual(ScreenCopy.count(2, "person", plural: "people"), "2 people")
    }

    func testConfirmNamesTheAction() {
        let many = ScreenCopy.confirm("Delete", 3, "take")
        XCTAssertEqual(many.title, "Delete 3 takes?")
        XCTAssertEqual(many.button, "Delete takes")
        let one = ScreenCopy.confirm("Delete", 1, "model")
        XCTAssertEqual(one.title, "Delete this model?")
        XCTAssertEqual(one.button, "Delete model")
    }

    func testFailureSaysWhenNothingWasCharged() {
        XCTAssertEqual(ScreenCopy.failure("The render stopped", charged: false), "The render stopped · you weren't charged")
        XCTAssertEqual(ScreenCopy.failure("", charged: true), "Something went wrong")
    }

    /// Owner bug 2026-11-11: the Queue said "you weren't charged · you weren't charged".
    func testFailureSaysNotChargedOnce() {
        let server = "This clip was refused by the content filter · you weren't charged"
        XCTAssertEqual(ScreenCopy.failure(server, charged: false), server)
        XCTAssertEqual(ScreenCopy.failure("Busy right now · you weren't charged. Try again in a minute.", charged: false),
                       "Busy right now · you weren't charged. Try again in a minute.")
    }

    /// Retry shows what the server held for the same request, not a local estimate, and is never "free".
    func testRetryLabelUsesTheServerPrice() {
        XCTAssertEqual(ScreenCopy.retryLabel(cost: 0.91, estimate: 0.67), "Retry · $0.91")
        XCTAssertEqual(ScreenCopy.retryLabel(cost: 0, estimate: 0.67), "Retry · $0.67")
    }
}

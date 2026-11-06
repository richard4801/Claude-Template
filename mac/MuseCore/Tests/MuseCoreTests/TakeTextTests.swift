import XCTest
@testable import MuseCore

final class TakeTextTests: XCTestCase {
    func testOldShootTitlesReadPhoto() {
        XCTAssertEqual(TakeText.displayTitle("Shoot · crystal"), "Photo · crystal")
        XCTAssertEqual(TakeText.displayTitle("Photoshoot · Rooftop"), "Photo · Rooftop")
        XCTAssertEqual(TakeText.displayTitle("Shoot"), "Photo")
        XCTAssertEqual(TakeText.displayTitle("Photoshoot"), "Photo")
    }

    func testOtherTitlesAreUnchanged() {
        XCTAssertEqual(TakeText.displayTitle("Living-room dance"), "Living-room dance")
        XCTAssertEqual(TakeText.displayTitle("Shootout at noon"), "Shootout at noon")
        XCTAssertEqual(TakeText.displayTitle("Template · Beach"), "Template · Beach")
        XCTAssertEqual(TakeText.displayTitle(""), "")
    }

    func testCaptionAndLabelUseThePhotoName() {
        let shot = Take(id: "s", kind: "shot", index: 1, title: "Shoot · crystal", label: "Shoot", thumb: ImageRef())
        XCTAssertEqual(shot.caption, "Photo · crystal 1")
        XCTAssertEqual(shot.displayTitle, "Photo · crystal")
        XCTAssertEqual(shot.displayLabel, "Photo")
        let untitled = Take(id: "u", kind: "shot", title: "", label: "Shoot", thumb: ImageRef())
        XCTAssertEqual(untitled.caption, "Photo")
    }
}

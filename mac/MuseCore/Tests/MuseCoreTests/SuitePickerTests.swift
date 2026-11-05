import XCTest
@testable import MuseCore

/// AI suite (workstream 1): the camera as picker groups (any screen's chips and pickers), on the real catalog JSON.
final class SuitePickerTests: XCTestCase {
    private func camera() throws -> CameraCatalog {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "catalog_member", withExtension: "json", subdirectory: "Fixtures/suite"))
        return try JSONDecoder().decode(SuiteCatalog.self, from: Data(contentsOf: url)).camera
    }

    func testGroupsCarryRendersNamesAndCaptions() throws {
        let c = try camera()
        XCTAssertTrue(c.groups.contains(.body))
        XCTAssertTrue(c.groups.contains(.move))
        let phone = try XCTUnwrap(c.items(.body).first { $0.id == "phone" })
        XCTAssertEqual(phone.name, "Phone UGC")
        XCTAssertEqual(phone.render, "body-08-phone")
        XCTAssertEqual(phone.caption, "Phone · 24 mm · deep focus · HDR")
        XCTAssertEqual(c.items(.move).count, 16)
        XCTAssertEqual(c.items(.move).first?.tag, "ugc")
        XCTAssertEqual(c.items(.move).first { $0.id == "dolly_in" }?.render, "grip-01-dolly")
        XCTAssertTrue(c.items(.aperture).allSatisfy { $0.render == "optic-01-iris" })
        XCTAssertTrue(c.items(.palette).contains { $0.render != nil })
    }

    func testChipsAreAutoUntilPicked() throws {
        let c = try camera()
        var s = CameraSpec()
        for g in CameraGroup.allCases { XCTAssertEqual(s.chipLabel(g, c), "Auto", g.rawValue) }
        s.set(.body, "phone")
        XCTAssertEqual(s.chipLabel(.body, c), "Phone UGC")
        XCTAssertEqual(s.render(.body, c), "body-08-phone")
        s.set(.move, "dolly_in")
        s.mix = SuiteMove(id: "rack_focus")
        XCTAssertEqual(s.chipLabel(.move, c), "Dolly in + Rack focus")
        s.set(.height, "eye")
        XCTAssertEqual(s.selected(.height), "eye")
        // Back to Auto clears the part entirely.
        s.set(.body, nil)
        XCTAssertNil(s.rig)
        s.set(.move, nil)
        XCTAssertNil(s.move)
        XCTAssertNil(s.mix)
        s.set(.height, nil)
        XCTAssertNil(s.angle)
        // A preset becomes a custom camera once its rig changes.
        var p = CameraSummary.fromPreset(try XCTUnwrap(c.presets.first))
        p.set(.lens, c.items(.lens).first?.id)
        XCTAssertNil(p.preset)
    }
}

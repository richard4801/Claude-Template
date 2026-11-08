import XCTest
@testable import MuseCore

/// Owner controls for the paid AI editing helpers (GET/PATCH /v1/editor/settings).
final class EditorSettingsTests: XCTestCase {
    func testDecodesTheServerReply() throws {
        let json = #"{"paidHelpers":"on","capPerDayUsd":5,"todayUsd":0.4,"markup":2,"provider":"mock","newField":1}"#
        let s = try JSONDecoder().decode(EditorSettings.self, from: Data(json.utf8))
        XCTAssertTrue(s.isOn)
        XCTAssertEqual(s.capPerDayUsd, 5)
        XCTAssertEqual(s.todayLine, "$0.40 of $5.00 today")
        let off = try JSONDecoder().decode(EditorSettings.self, from: Data(#"{"capPerDayUsd":null}"#.utf8))
        XCTAssertFalse(off.isOn)
        XCTAssertEqual(off.todayLine, "$0.00 today")
    }

    func testPatchSendsNullToResetTheLimit() throws {
        func json(_ p: EditorSettingsPatch) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        }
        let on = try json(EditorSettingsPatch(paidHelpers: true))
        XCTAssertEqual(on["paidHelpers"] as? String, "on")
        XCTAssertNil(on["capPerDayUsd"])
        let cap = try json(EditorSettingsPatch(capPerDayUsd: 7.5))
        XCTAssertEqual(cap["capPerDayUsd"] as? Double, 7.5)
        XCTAssertNil(cap["paidHelpers"])
        let reset = try json(EditorSettingsPatch(resetCap: true))
        XCTAssertTrue(reset.keys.contains("capPerDayUsd"))
        XCTAssertTrue(reset["capPerDayUsd"] is NSNull)
    }

    func testParsesTheLimitField() {
        XCTAssertEqual(EditorSettings.parseLimit("5"), 5)
        XCTAssertEqual(EditorSettings.parseLimit(" $7.256 "), 7.26)
        XCTAssertNil(EditorSettings.parseLimit(""))
        XCTAssertNil(EditorSettings.parseLimit("0"))
        XCTAssertNil(EditorSettings.parseLimit("-2"))
        XCTAssertNil(EditorSettings.parseLimit("five"))
    }

    func testDemoFakeChargesNothingAndRemembers() async throws {
        let api = FakeEditorSettingsAPI()
        var s = try await api.editorSettings()
        XCTAssertFalse(s.isOn)
        XCTAssertEqual(s.todayUsd, 0)
        s = try await api.updateEditorSettings(EditorSettingsPatch(paidHelpers: true, capPerDayUsd: 3))
        XCTAssertTrue(s.isOn)
        XCTAssertEqual(s.capPerDayUsd, 3)
        s = try await api.updateEditorSettings(EditorSettingsPatch(resetCap: true))
        XCTAssertEqual(s.capPerDayUsd, 5)
    }

    func testServerMessagesForTheNewRefusalsArePassedThrough() {
        let off = ApiError("editor_paid_off", "AI editing helpers are switched off for now · try again later")
        XCTAssertEqual(off.friendlyMessage, "AI editing helpers are switched off for now · try again later")
        let cap = ApiError("editor_daily_cap", "Today's AI editing limit ($5.00) is reached · try again tomorrow")
        XCTAssertEqual(cap.friendlyMessage, "Today's AI editing limit ($5.00) is reached · try again tomorrow")
    }
}

import XCTest
@testable import MuseCore

/// The Recreate Claude panel polls GET /v1/edit-sessions/{id}/state (revision + waiting/running helpers) every 3 s
/// instead of the whole session with its project and history (db-traffic-diet, 2026-11-15).
final class EditSessionStateTests: XCTestCase {
    func testTheLightStateDecodesTheServerReply() throws {
        let json = #"{"revision":7,"pending":[{"id":"pd_1","kind":"matte","label":"Remove background","estimateUsd":0.4,"status":"waiting","createdAt":1}]}"#
        let s = try JSONDecoder().decode(EditSessionState.self, from: Data(json.utf8))
        XCTAssertEqual(s.revision, 7)
        XCTAssertEqual(s.pending.map(\.id), ["pd_1"])
        XCTAssertTrue(s.pending[0].isWaiting)
        // No helpers: the key may be missing.
        XCTAssertEqual(try JSONDecoder().decode(EditSessionState.self, from: Data(#"{"revision":2}"#.utf8)), EditSessionState(revision: 2))
    }

    func testTheFakeAnswersLikeTheServer() async throws {
        let api = FakeMuseAPI()
        let s = try await api.openEditSession(EditSessionOpenRequest(takeId: EditV2.blankSourceId))
        let before = try await api.editSessionState(id: s.id)
        XCTAssertEqual(before.revision, s.revision)
        XCTAssertTrue(before.pending.isEmpty)

        // Claude asks for a paid helper: the light state shows it, at the full session's revision.
        let p = try await api.fakeClaudePending(sessionId: s.id, kind: "matte", label: "Remove background", estimateUsd: 0.4)
        let asked = try await api.editSessionState(id: s.id)
        let full = try await api.editSession(id: s.id)
        XCTAssertEqual(asked.revision, full.revision)
        XCTAssertEqual(asked.pending.map(\.id), [p.id])

        // Answered "not now": it leaves the list.
        _ = try await api.answerEditPending(sessionId: s.id, pendingId: p.id, approve: false)
        let answered = try await api.editSessionState(id: s.id)
        XCTAssertTrue(answered.pending.allSatisfy { $0.id != p.id || !$0.isWaiting })
    }
}

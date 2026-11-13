import XCTest
@testable import MuseCore

/// Continue a draft (owner, 2026-11-12): where the editor was left comes back, Recent edits lists the last worked on first,
/// a member's edit is kept on this Mac, and missing media is marked instead of failing.
final class EditRecentTests: XCTestCase {
    typealias E = EditV2

    private func fixture(_ name: String = "pip text image look") throws -> E.Project {
        let c = try XCTUnwrap(editorFixture("projects").array.first { $0["name"].string == name }, name)
        return try c["project"].decode(E.Project.self)
    }

    // MARK: View

    func testViewRoundTripsThroughTheState() throws {
        let p = try fixture()
        var s = EditSuiteState(p)
        s.playhead = 2.25
        s.zoom = 140
        s.tab = .audio
        s.safeArea = .reels
        let id = try XCTUnwrap(p.tracks.flatMap(\.items).last?.id)
        s.selection = id
        let v = s.viewSnapshot(binTab: .uploads, mode: "timeline", title: "Café cut")
        XCTAssertEqual(v.binTab, "uploads")
        XCTAssertEqual(v.safeArea, "reels")

        // Through JSON, as the server and the file keep it.
        let back = try JSONDecoder().decode(EditSessionView.self, from: JSONEncoder().encode(v))
        var fresh = EditSuiteState(p)
        fresh.restore(back)
        XCTAssertEqual(fresh.playhead, 2.25, accuracy: 0.001)
        XCTAssertEqual(fresh.zoom, 140)
        XCTAssertEqual(fresh.tab, .audio)
        XCTAssertEqual(fresh.safeArea, .reels)
        XCTAssertEqual(fresh.selection, id)
        XCTAssertEqual(EditSuite.binTab(back), .uploads)
        XCTAssertTrue(v.samePlace(back))
    }

    func testPlatformViewOffIsRemembered() throws {
        var s = EditSuiteState(try fixture())
        s.safeArea = nil
        let v = s.viewSnapshot()
        XCTAssertEqual(v.safeArea, "off")
        var fresh = EditSuiteState(try fixture())
        XCTAssertNotNil(fresh.safeArea)
        fresh.restore(v)
        XCTAssertNil(fresh.safeArea)
        // The server keeps "off" as null.
        let fromServer = try JSONDecoder().decode(EditSessionView.self, from: Data(#"{"safeArea":null,"zoom":80}"#.utf8))
        XCTAssertEqual(fromServer.safeArea, "off")
        let unsaved = try JSONDecoder().decode(EditSessionView.self, from: Data(#"{"zoom":80}"#.utf8))
        XCTAssertNil(unsaved.safeArea)
    }

    func testAStaleOrStrangeViewNeverBreaksOpening() throws {
        let p = try fixture()
        var s = EditSuiteState(p)
        let before = s
        s.restore(EditSessionView(playhead: 99_999, zoom: 1e9, tab: "from-a-newer-app", binTab: "nope", selection: "deleted-clip", safeArea: "nope"))
        XCTAssertEqual(s.playhead, s.duration, accuracy: 0.001)
        XCTAssertEqual(s.zoom, EditSuiteState.zoomRange.upperBound)
        XCTAssertEqual(s.tab, before.tab)
        XCTAssertEqual(s.selection, before.selection)
        XCTAssertEqual(s.safeArea, before.safeArea)
        XCTAssertNil(EditSuite.binTab(EditSessionView(binTab: "nope")))
        s.restore(EditSessionView(playhead: -.infinity, zoom: .nan))
        XCTAssertEqual(s.zoom, EditSuiteState.zoomRange.upperBound)
        // A view from an older or newer server with odd types still decodes.
        let odd = try JSONDecoder().decode(EditSessionView.self, from: Data(#"{"playhead":"x","zoom":90,"extra":[1]}"#.utf8))
        XCTAssertNil(odd.playhead)
        XCTAssertEqual(odd.zoom, 90)
    }

    // MARK: Missing media

    func testMissingMediaIsMarkedNotFatal() throws {
        let p = try fixture()
        let used = Set(p.tracks.flatMap(\.items).compactMap { $0.videoClip?.asset ?? $0.imageItem?.asset ?? $0.audioClip?.asset })
        let media = p.assets.filter { used.contains($0.id) && $0.contentRef == nil && [.video, .image, .audio].contains($0.kind) }.map(\.id)
        XCTAssertFalse(media.isEmpty)
        XCTAssertEqual(EditSuite.missingAssets(p, have: Set(media)), [])
        let gone = try XCTUnwrap(media.first)
        XCTAssertEqual(EditSuite.missingAssets(p, have: Set(media.dropFirst())), [gone])
        XCTAssertEqual(EditSuite.missingAssets(p, have: []), Set(media))
        // An asset no clip uses isn't "missing" (nothing on the timeline shows it).
        var extra = p
        extra.assets.append(E.Asset(id: "unused", kind: .video, upload: "u9", durationSec: 3))
        XCTAssertFalse(EditSuite.missingAssets(extra, have: Set(media)).contains("unused"))
    }

    // MARK: Recent edits

    private func session(_ id: String, takeId: String, project: E.Project, updatedAt: Double, view: EditSessionView? = nil, status: String = "open") throws -> EditSession {
        EditSession(id: id, takeId: takeId, revision: 1, project: try JSONPatch.encode(project), status: status, updatedAt: updatedAt, view: view)
    }

    func testRecentListsTheLastWorkedOnFirst() throws {
        let p = try fixture()
        var blankEmpty = E.Project.blank()
        blankEmpty.sourceTakeId = E.blankSourceId
        var blankUsed = E.Project.blank()
        blankUsed.assets = [E.Asset(id: "a1", kind: .video, take: "take_b", durationSec: 3)]
        let titles = ["take_a": "Café review", "take_b": "Beach"]
        let sessions = [
            try session("es_1", takeId: "take_a", project: p, updatedAt: 1_000),
            // Changed earlier but left later: it leads.
            try session("es_2", takeId: "take_gone", project: p, updatedAt: 500, view: EditSessionView(title: nil, at: 3_000)),
            try session("es_3", takeId: E.blankSourceId, project: blankUsed, updatedAt: 2_000, view: EditSessionView(title: "Promo")),
            try session("es_4", takeId: E.blankSourceId, project: blankEmpty, updatedAt: 9_000),
            try session("es_5", takeId: "take_a", project: p, updatedAt: 9_500, status: "closed"),
        ]
        let items = EditRecent.items(sessions: sessions, local: [], takeTitle: { titles[$0] })
        XCTAssertEqual(items.map(\.id), ["es_2", "es_3", "es_1"])
        XCTAssertEqual(items[0].title, EditRecent.untitled)      // its take is gone: still listed, still opens
        XCTAssertEqual(items[1].title, "Promo")
        XCTAssertEqual(items[1].thumbTakeId, "take_b")
        XCTAssertTrue(items[1].isBlank)
        XCTAssertEqual(items[2].title, "Café review")
        XCTAssertEqual(items[2].thumbTakeId, "take_a")
        XCTAssertEqual(items[2].sessionId, "es_1")
    }

    func testThisMacsDraftsJoinTheList() throws {
        let p = try fixture()
        let sessions = [try session("es_1", takeId: "take_a", project: p, updatedAt: 1_000)]
        let local = [
            // The owner's newer view of a listed session moves it up and carries the view.
            EditLocalDraft(takeId: "take_a", sessionId: "es_1", view: EditSessionView(playhead: 4), title: "Café review", savedAt: 5_000),
            // A view of a session the server no longer lists (closed) is dropped.
            EditLocalDraft(takeId: "take_x", sessionId: "es_closed", view: EditSessionView(), title: "Old", savedAt: 9_000),
            // A member's edit: listed with its project.
            EditLocalDraft(takeId: "take_m", project: p, view: EditSessionView(), title: "Member cut", savedAt: 4_000),
            // Nothing to reopen (no project, no session): left out.
            EditLocalDraft(takeId: "take_n", view: EditSessionView(), title: "", savedAt: 8_000),
        ]
        let items = EditRecent.items(sessions: sessions, local: local, takeTitle: { _ in nil })
        XCTAssertEqual(items.map(\.id), ["es_1", "local:take_m"])
        XCTAssertEqual(items[0].lastEditedAt, 5_000)
        XCTAssertEqual(items[0].view?.playhead, 4)
        XCTAssertEqual(items[0].view?.at, 5_000)   // so the app can tell it is newer than the server's
        XCTAssertEqual(items[1].title, "Member cut")
        XCTAssertNil(items[1].sessionId)
    }

    func testStoreKeepsTheNewestPerEditAcrossRestarts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("recent.json")
        let p = try fixture()
        let store = EditRecentStore(file: file)
        XCTAssertEqual(store.load(), [])
        store.save(EditLocalDraft(takeId: "take_a", project: p, view: EditSessionView(playhead: 1), title: "A", savedAt: 1))
        store.save(EditLocalDraft(takeId: "take_b", project: p, view: EditSessionView(playhead: 2), title: "B", savedAt: 2))
        store.save(EditLocalDraft(takeId: "take_a", project: p, view: EditSessionView(playhead: 3), title: "A", savedAt: 3))
        // Two blank projects kept on this Mac are two edits.
        store.save(EditLocalDraft(takeId: E.blankSourceId, localId: "l1", project: p, view: EditSessionView(), title: "Blank 1", savedAt: 4))
        store.save(EditLocalDraft(takeId: E.blankSourceId, localId: "l2", project: p, view: EditSessionView(), title: "Blank 2", savedAt: 5))
        // A new store on the same file (the app restarted) reads the same list.
        let again = EditRecentStore(file: file).load()
        XCTAssertEqual(again.map(\.title), ["Blank 2", "Blank 1", "A", "B"])
        XCTAssertEqual(again[2].view.playhead, 3)
        XCTAssertEqual(again[2].project, p)
        for i in 0..<20 { store.save(EditLocalDraft(takeId: "t\(i)", project: p, view: EditSessionView(), title: "\(i)", savedAt: Double(10 + i))) }
        XCTAssertEqual(store.load().count, EditRecent.kept)
        store.remove(key: "t19")
        XCTAssertEqual(store.load().first?.title, "18")
        // A damaged file reads as empty instead of failing.
        try Data("not json".utf8).write(to: file)
        XCTAssertEqual(store.load(), [])
    }

    func testLastEditedText() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_794_500_000) // Thu 12 Nov 2026, 16:13 UTC
        func at(_ secondsAgo: Double) -> Double { (now.timeIntervalSince1970 - secondsAgo) * 1000 }
        XCTAssertEqual(EditRecent.lastEditedText(at(20), now: now, calendar: cal), "Just now")
        XCTAssertEqual(EditRecent.lastEditedText(at(5 * 60), now: now, calendar: cal), "5 min ago")
        XCTAssertEqual(EditRecent.lastEditedText(at(3 * 3600), now: now, calendar: cal), "3 h ago")
        XCTAssertEqual(EditRecent.lastEditedText(at(20 * 3600), now: now, calendar: cal), "Yesterday")
        XCTAssertEqual(EditRecent.lastEditedText(at(3 * 86_400), now: now, calendar: cal), "Monday")
        XCTAssertEqual(EditRecent.lastEditedText(at(30 * 86_400), now: now, calendar: cal), "13 Oct")
        XCTAssertEqual(EditRecent.lastEditedText(at(400 * 86_400), now: now, calendar: cal), "8 Oct 2025")
    }

    // MARK: The fake server (the app's demo mode and walks)

    func testFakeServerKeepsTheViewAndListsRecent() async throws {
        let api = FakeMuseAPI(speed: 0)
        let p = try fixture()
        let a = try await api.openEditSession(EditSessionOpenRequest(takeId: p.sourceTakeId, project: p, device: "mac"))
        let b = try await api.openEditSession(EditSessionOpenRequest(takeId: E.blankSourceId, device: "mac"))
        var recent = try await api.recentEditSessions(limit: 10)
        XCTAssertEqual(Set(recent.map(\.id)), [a.id, b.id])
        try await api.saveEditSessionView(sessionId: a.id, EditSessionView(playhead: -3, zoom: 90, binTab: "uploads"))
        recent = try await api.recentEditSessions(limit: 10)
        XCTAssertEqual(recent.first?.id, a.id)
        XCTAssertEqual(recent.first?.view?.playhead, 0)
        XCTAssertEqual(recent.first?.view?.binTab, "uploads")
        XCTAssertNil(recent.first?.history)
        let one = try await api.editSession(id: a.id)
        XCTAssertEqual(one.view?.zoom, 90)
        try await api.closeEditSession(id: a.id)
        recent = try await api.recentEditSessions(limit: 10)
        XCTAssertEqual(recent.map(\.id), [b.id])
    }
}

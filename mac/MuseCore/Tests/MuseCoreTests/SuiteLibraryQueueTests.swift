import XCTest
@testable import MuseCore

/// Build step 3 (plans/api.md "Library collections and the Suite queue"): the wire types from server-shaped JSON (lenient)
/// and demo mode (FakeMuseAPI), which follows server/api's rules (test/suite-library.test.ts).
final class SuiteLibraryQueueTests: XCTestCase {
    private func api() async throws -> FakeMuseAPI {
        let a = FakeMuseAPI(speed: 0, genDelay: 0.01)
        _ = try await a.signIn(SignInRequest(email: "owner@studio.com", password: "x"))
        return a
    }

    private func decode<T: Decodable>(_ s: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(s.utf8))
    }

    private func expectError(_ code: String, _ f: () async throws -> Void) async {
        do {
            try await f()
            XCTFail("expected \(code)")
        } catch let e as ApiError {
            XCTAssertEqual(e.code, code)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: Decoding

    func testACollectionDecodesLeniently() throws {
        let c = try decode(#"{"id":"col_1","name":"Client picks","userId":"u1","mine":true,"canEdit":true,"count":3,"cover":{"url":"/uploads/a.jpg"},"createdAt":"2026-11-08T10:00:00.000Z","updatedAt":1762600000000,"takeIds":["t1","t2"],"future":1}"#,
                           as: LibraryCollection.self)
        XCTAssertEqual(c.name, "Client picks")
        XCTAssertTrue(c.canEdit)
        XCTAssertEqual(c.count, 3)
        XCTAssertEqual(c.cover?.url, "/uploads/a.jpg")
        XCTAssertEqual(c.takeIds, ["t1", "t2"])
        XCTAssertEqual(c.updatedAt, 1_762_600_000_000)
        let bare = try decode(#"{"id":"col_2"}"#, as: LibraryCollection.self)
        XCTAssertEqual(bare.count, 0)
        XCTAssertFalse(bare.canEdit, "missing canEdit is no")
        XCTAssertNil(bare.takeIds)
    }

    func testAQueuedShotAndItsEstimateDecode() throws {
        let q = try decode(#"{"id":"q_1","kind":"queued","title":"Café","tool":"shot","userId":"u1","mine":true,"estimate":0.4,"buttonLabel":"Run · $0.40","createdAt":1762600000000}"#,
                           as: QueuedShot.self)
        XCTAssertEqual(q.buttonLabel, "Run · $0.40")
        XCTAssertEqual(q.estimate, 0.4, accuracy: 1e-9)
        let noLabel = try decode(#"{"id":"q_2","estimate":1.25}"#, as: QueuedShot.self)
        XCTAssertEqual(noLabel.buttonLabel, QueuedShot.runLabel(1.25))
        XCTAssertEqual(noLabel.kind, "queued")
        let e = try decode(#"{"id":"q_1","title":"Café","estimate":0.5,"buttonLabel":"Run · $0.50","changed":true}"#, as: QueuedEstimate.self)
        XCTAssertTrue(e.changed)
        XCTAssertEqual(e.item.buttonLabel, "Run · $0.50")
        XCTAssertNil(e.estimateView)
    }

    func testTheFeedPageCarriesTheQueuedGroupAndTheQueryTakesACollection() throws {
        let p = try decode(#"{"queued":[{"id":"q_1","estimate":0.4}],"items":[],"nextCursor":null}"#, as: SuiteFeedPage.self)
        XCTAssertEqual(p.queued.map(\.id), ["q_1"])
        let old = try decode(#"{"items":[]}"#, as: SuiteFeedPage.self)
        XCTAssertTrue(old.queued.isEmpty, "an older server sends no queued group")
        XCTAssertEqual(SuiteFeedQuery(collection: "col 1").path, "v1/suite/feed?collection=col%201")
    }

    // MARK: Demo mode

    func testCollectionsInDemoMode() async throws {
        let a = try await api()
        let seeded = try await a.collections()
        XCTAssertEqual(seeded.first?.name, "Client picks")
        let made = try await a.createCollection(name: "  Summer  ", takeIds: ["t_g1"])
        XCTAssertEqual(made.name, "Summer")
        XCTAssertEqual(made.takeIds, ["t_g1"])
        let added = try await a.addToCollection(made.id, takeIds: ["t_g4", "t_g1"])
        XCTAssertEqual(added.count, 2, "each take once")
        let holding = try await a.collections(ofTake: "t_g4")
        XCTAssertTrue(holding.map(\.id).contains(made.id))
        let feed = try await a.suiteFeed(SuiteFeedQuery(collection: made.id))
        XCTAssertEqual(Set(feed.items.compactMap(\.takeId)), ["t_g1", "t_g4"])
        XCTAssertTrue(feed.queued.isEmpty, "a collection's feed has no queue")
        let renamed = try await a.renameCollection(made.id, name: "Summer picks")
        XCTAssertEqual(renamed.name, "Summer picks")
        let removed = try await a.removeFromCollection(made.id, takeIds: ["t_g1"])
        XCTAssertEqual(removed.takeIds, ["t_g4"])
        await expectError("bad_request") { _ = try await a.createCollection(name: " ", takeIds: []) }
        await expectError("bad_request") { _ = try await a.addToCollection(made.id, takeIds: ["nope"]) }
        await expectError("bad_request") { _ = try await a.suiteFeed(SuiteFeedQuery(collection: "col_nope")) }
        try await a.deleteCollection(made.id)
        await expectError("not_found") { _ = try await a.collection(made.id) }
    }

    func testTheQueueHoldsNothingAndRunsAfterAFreshPrice() async throws {
        let a = try await api()
        let before = try await a.balance()
        let req = ShotRequest(title: "Café", modelId: SampleData.demo, prompt: "She waves.", duration: 5, quality: "draft")
        let q = try await a.queueShot(req)
        XCTAssertEqual(q.kind, "queued")
        XCTAssertTrue(q.buttonLabel.hasPrefix("Run · "), q.buttonLabel)
        let listed = try await a.queuedShots()
        XCTAssertEqual(listed.map(\.id), [q.id])
        let after = try await a.balance()
        XCTAssertEqual(after.balance, before.balance, accuracy: 1e-9, "queuing holds nothing")
        let page = try await a.suiteFeed(SuiteFeedQuery())
        XCTAssertEqual(page.queued.map(\.id), [q.id], "the first page carries the Queued group")
        let e = try await a.estimateQueued(q.id)
        XCTAssertFalse(e.changed)
        XCTAssertNotNil(e.estimateView)
        let run = try await a.runQueued(q.id)
        XCTAssertEqual(run.queuedId, q.id)
        XCTAssertEqual(run.job.request.engine, "suite")
        let left = try await a.queuedShots()
        XCTAssertTrue(left.isEmpty, "running takes it off the queue")
        let other = try await a.queueShot(req)
        try await a.removeQueued(other.id)
        await expectError("not_found") { _ = try await a.estimateQueued(other.id) }
    }
}

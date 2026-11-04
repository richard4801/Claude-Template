import XCTest
@testable import MuseCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Identity LoRA, accounts, posts and model-edit endpoints against the real Node mock server (server/mock).
/// Skipped unless MUSE_MOCK_URL is set, and skipped (not failed) if the server predates these endpoints.
final class MockServerSocialTests: XCTestCase {
    private func api() async throws -> HTTPMuseAPI {
        guard let s = ProcessInfo.processInfo.environment["MUSE_MOCK_URL"], let u = URL(string: s) else { throw XCTSkip("MUSE_MOCK_URL not set") }
        let api = HTTPMuseAPI(baseURL: u)
        var r = URLRequest(url: api.url("v1/dev/reset"))
        r.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: r)
        let auth = try await api.signIn(SignInRequest(email: "jen@studio.com", password: "x"))
        await api.setToken(auth.token)
        do {
            _ = try await api.lora(modelId: try await sienna(api).id)
        } catch let e as ApiError where e.code == "http_404" || e.code == "not_found" {
            throw XCTSkip("server/mock has no LoRA endpoints yet")
        }
        return api
    }

    private func sienna(_ api: HTTPMuseAPI) async throws -> MuseModel {
        let models = try await api.listModels()
        return try XCTUnwrap(models.first { $0.name == "Sienna Vale" })
    }

    func testLoraContract() async throws {
        let api = try await api()
        let m = try await sienna(api)
        let none = try await api.lora(modelId: m.id)
        XCTAssertEqual(none.modelId, m.id)
        let b0 = try await api.balance().balance
        let building = try await api.buildLoraCandidates(modelId: m.id)
        XCTAssertTrue(["building", "review"].contains(building.state), building.state)
        let b1 = try await api.balance().balance
        XCTAssertEqual(b0 - b1, LoraPricing.setCost, accuracy: 1e-6, "server and client agree on the training-set price")

        var l = building
        for _ in 0..<80 where l.state != "review" {
            try await Task.sleep(nanoseconds: 250_000_000)
            l = try await api.lora(modelId: m.id)
        }
        XCTAssertEqual(l.state, "review")
        XCTAssertEqual(l.candidates.count, LoraPricing.candidates)
        XCTAssertTrue(l.candidates.filter { $0.flag != nil }.allSatisfy { !$0.keep }, "flagged shots start dropped")
        let c = try XCTUnwrap(l.candidates.first { $0.keep })
        let toggled = try await api.setLoraCandidate(modelId: m.id, candidateId: c.id, keep: false)
        XCTAssertEqual(toggled.kept, l.kept - 1)

        _ = try await api.topUp(TopUpRequest(amount: 20))
        if toggled.kept >= LoraPricing.minKept {
            let before = try await api.balance().balance
            let training = try await api.trainLora(modelId: m.id)
            XCTAssertTrue(["training", "ready"].contains(training.state), training.state)
            let after = try await api.balance().balance
            XCTAssertEqual(before - after, LoraPricing.trainCost, accuracy: 0.011, "server and client agree on the training price")
        }
        do { _ = try await api.retrainLora(modelId: m.id); XCTFail("nothing to retrain yet") } catch let e as ApiError { XCTAssertEqual(e.code, "bad_request") }
        let off = try await api.setLoraUse(modelId: m.id, use: false)
        XCTAssertFalse(off.use)
    }

    func testAccountsPostsAndModelEdits() async throws {
        let api = try await api()
        let m = try await sienna(api)
        let result = try await api.connectAccount(modelId: m.id, platform: .tiktok)
        if case .connected(let a) = result { XCTAssertEqual(a.platform, .tiktok) }
        let accounts = try await api.listAccounts(modelId: m.id)
        XCTAssertTrue(accounts.contains { $0.platform == .tiktok })

        let takes = try await api.listTakes()
        let take = try XCTUnwrap(takes.first)
        let now = try await api.createPost(CreatePostRequest(modelId: m.id, takeId: take.id, platforms: [.tiktok], caption: "hi"))
        XCTAssertFalse(now.aiLabel, "never set automatically")
        XCTAssertFalse(now.paidPartnership, "never set automatically")
        XCTAssertNotEqual(now.state, "scheduled")
        XCTAssertFalse(now.title.isEmpty, "Post.title")
        let later = try await api.createPost(CreatePostRequest(modelId: m.id, takeId: take.id, platforms: [.tiktok], aiLabel: true,
                                                               when: PostTime.string(Date().addingTimeInterval(7200))))
        XCTAssertEqual(later.state, "scheduled")
        XCTAssertTrue(later.aiLabel)
        let scheduled = try await api.listPosts(state: "scheduled")
        XCTAssertTrue(scheduled.contains { $0.id == later.id })
        try await api.deletePost(id: later.id)
        try await api.disconnectAccount(modelId: m.id, platform: .tiktok)

        let edited = try await api.updateModel(id: m.id, UpdateModelRequest(personality: "dry, warm", neverAdd: ["tattoos", "rings", "necklaces"]))
        XCTAssertEqual(edited.personality, "dry, warm")
        XCTAssertEqual(edited.neverAdd, ["tattoos", "rings", "necklaces"])
        let b = try await api.balance()
        XCTAssertNotNil(b.today, "Balance.today")
        try await api.runQueue()

        let doomed = try await api.createModel(CreateModelRequest(name: "Temp", age: 30, niche: "Tech"))
        try await api.deleteModel(id: doomed.id)
        let models = try await api.listModels()
        XCTAssertFalse(models.contains { $0.id == doomed.id })
    }
}

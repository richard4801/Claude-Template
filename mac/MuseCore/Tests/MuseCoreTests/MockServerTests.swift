import XCTest
@testable import MuseCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Runs HTTPMuseAPI against the real Node mock server (server/mock). Skipped unless MUSE_MOCK_URL is set, e.g.
///   (cd server/mock && PORT=8799 node server.js &) ; MUSE_MOCK_URL=http://localhost:8799 swift test
final class MockServerTests: XCTestCase {
    private func api() throws -> HTTPMuseAPI {
        guard let s = ProcessInfo.processInfo.environment["MUSE_MOCK_URL"], let u = URL(string: s) else {
            throw XCTSkip("MUSE_MOCK_URL not set")
        }
        return HTTPMuseAPI(baseURL: u)
    }

    private func reset(_ api: HTTPMuseAPI) async throws {
        var r = URLRequest(url: api.url("v1/dev/reset"))
        r.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: r)
    }

    func testContractRoundTrip() async throws {
        let api = try api()
        try await reset(api)
        do {
            _ = try await api.signUp(SignUpRequest(studioName: "S", email: "a@b.c", password: "x", attestAdultRightsOriginal: true, attestLabelAi: false))
            XCTFail("sign-up without both attestations must fail")
        } catch let e as ApiError { XCTAssertEqual(e.code, "attestation_required") }
        let auth = try await api.signIn(SignInRequest(email: "jen@studio.com", password: "x"))
        await api.setToken(auth.token)

        let models = try await api.listModels()
        XCTAssertTrue(models.contains { $0.isLocked })
        XCTAssertTrue(models.contains { $0.isDraft }, "a second model with an empty sheet")
        let outfits = try await api.listOutfits()
        XCTAssertFalse(outfits.isEmpty)
        let b0 = try await api.balance()
        XCTAssertEqual(Pricing.money(b0.balance), "$6.07")

        let bad = try await api.uploadClip(SampleData.badMeta, file: nil)
        XCTAssertFalse(bad.ok)
        let good = try await api.uploadClip(SampleData.sampleMeta, file: nil)
        XCTAssertEqual(good.checks.map(\.status), ClipRules.checks(SampleData.sampleMeta).map(\.status))

        let demoModel = models.first { $0.isLocked }!
        var req = JobRequest(title: "Mac test", modelId: demoModel.id, outfitId: demoModel.outfitIds[0], clipId: bad.id)
        req.clipId = good.id
        req.steps = 31
        do { _ = try await api.createJob(req); XCTFail() } catch let e as ApiError { XCTAssertEqual(e.code, "bad_request") }
        req.steps = 4
        req.engine = "viggle"
        let job = try await api.createJob(req)
        XCTAssertEqual(job.cost, Pricing.totalCost(req.spec), accuracy: 1e-6, "server and client prices agree")
        let b1 = try await api.balance()
        XCTAssertEqual(b0.balance - b1.balance, job.cost, accuracy: 1e-6)

        // Wait for it to finish (Viggle 5.2 s ≈ 96 s GPU time ≈ 4 s at 24×).
        var done: Job?
        for _ in 0..<80 {
            try await Task.sleep(nanoseconds: 250_000_000)
            if let j = try await api.listJobs().first(where: { $0.id == job.id }), j.isDone { done = j; break }
        }
        XCTAssertNotNil(done)
        let takes = try await api.listTakes()
        let mine = try XCTUnwrap(takes.first { $0.jobId == job.id })
        let approved = try await api.setTakeStatus(id: mine.id, status: "final")
        XCTAssertTrue(approved.isFinal)

        let img = try await api.uploadImage(name: "a.png", data: Data([0x89, 0x50, 0x4E, 0x47]), mime: "image/png")
        XCTAssertTrue(img.url?.hasPrefix("http") == true, "relative upload URLs are made absolute: \(img)")
        let m = try await api.createModel(CreateModelRequest(name: "Mac", age: 30, niche: "Tech"))
        XCTAssertEqual(m.slots.count, 7)  // 3 face close-ups + 4 full-body angles
        let m2 = try await api.setSlot(modelId: m.id, slot: "face", SetSlotRequest(image: img))
        XCTAssertEqual(m2.filled, 1)
        let fill = try await api.fillAngles(modelId: m.id)
        XCTAssertEqual(Pricing.money(fill.cost), "$0.12")  // 6 empty slots × $0.02

        let shots = try await api.shoot(ShootRequest(modelId: demoModel.id, outfitId: demoModel.outfitIds[0], scene: "Café window", prompt: "p", count: 4))
        XCTAssertEqual(shots.count, 4)
        XCTAssertTrue(shots.allSatisfy { !$0.isVideo })
        let topped = try await api.topUp(TopUpRequest(amount: 10, note: "Mac contract test"))
        XCTAssertGreaterThan(topped.balance, 10)
        try await api.runQueue() // not in the contract: must be a harmless no-op
        try await api.setFailNext(false)
        try await api.removeJob(id: job.id)
    }
}

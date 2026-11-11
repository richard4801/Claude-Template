import XCTest
@testable import MuseCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// AI suite (workstream 1): contract tests against the real API (`server/api`) in mock suite mode (test renders, no provider,
/// no money). Skipped unless MUSE_API_URL is set, and only ever run against a LOCAL dev server.
///
///   cd server/api && PORT=8799 PUBLIC_URL=http://127.0.0.1:8799 node --import tsx scripts/test-server.ts &
///   cd mac/MuseCore && MUSE_API_URL=http://127.0.0.1:8799 swift test --filter SuiteApiTests
final class SuiteApiTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        guard let s = ProcessInfo.processInfo.environment["MUSE_API_URL"], let u = URL(string: s) else { throw XCTSkip("MUSE_API_URL not set") }
        let host = u.host ?? ""
        guard ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".local") else {
            throw XCTSkip("SuiteApiTests only run against a local server (got \(host))")
        }
        base = u
    }

    private func client() -> HTTPMuseAPI { HTTPMuseAPI(baseURL: base) }

    /// The owner, signed in. Skips on a server without the AI suite, or with it switched off.
    private func owner() async throws -> HTTPMuseAPI {
        let api = client()
        let auth = try await api.signIn(SignInRequest(email: "jen@studio.com", password: "x"))
        await api.setToken(auth.token)
        try await api.ensureStudioFunds()
        do {
            let c = try await api.suiteCatalog()
            if !c.enabled { throw XCTSkip("SUITE_MODE is off on this server") }
        } catch let e as ApiError where e.code == "not_found" || e.code == "http_404" {
            throw XCTSkip("This server has no /v1/suite")
        }
        return api
    }

    private func member(_ boss: HTTPMuseAPI) async throws -> HTTPMuseAPI {
        let email = "suite+\(UUID().uuidString.prefix(8).lowercased())@test.muse"
        let invite = try await boss.createInvite(InviteRequest(email: email))
        let api = client()
        let auth = try await api.signUp(SignUpRequest(studioName: "", email: email, password: "pw-12345678", inviteCode: invite.code,
                                                      attestAdultRightsOriginal: true, attestLabelAi: true))
        await api.setToken(auth.token)
        return api
    }

    private func character(_ api: HTTPMuseAPI) async throws -> MuseModel {
        let list = try await api.listModels()
        return try XCTUnwrap(list.first { $0.slots.contains { $0.image != nil } }, "no character with a sheet")
    }

    func testCatalogCameraAndMemberSafety() async throws {
        let boss = try await owner()
        let c = try await boss.suiteCatalog()
        XCTAssertEqual(c.tiers.map(\.label), ["Draft", "Standard", "HD", "Cinema"])
        XCTAssertNotNil(c.tiers.first?.models, "the owner sees what each tier runs")
        XCTAssertEqual(c.camera.library.count, 16)
        XCTAssertTrue(c.camera.bodies.contains { $0.render != nil })
        let cam = try await boss.suiteCamera()
        XCTAssertEqual(cam.library.map(\.id), c.camera.library.map(\.id))

        let m = try await member(boss)
        let mc = try await m.suiteCatalog()
        XCTAssertTrue(mc.tiers.allSatisfy { $0.models == nil })
        XCTAssertTrue(SuiteText.isMemberSafe(String(data: try JSONEncoder().encode(mc.tiers), encoding: .utf8)!))
        do {
            _ = try await m.suiteSettings()
            XCTFail("members get owner_only")
        } catch let e as ApiError { XCTAssertEqual(e.code, "owner_only") }
    }

    func testEstimateAndNothingFits() async throws {
        let boss = try await owner()
        let ch = try await character(boss)
        let cam = CameraSpec(preset: "cinematic", move: SuiteMove(id: "dolly_in", intensity: 0.6), mix: SuiteMove(id: "rack_focus", intensity: 0.4, speed: "slow"))
        let e = try await boss.suiteEstimate(ShotRequest(modelId: ch.id, prompt: "She waves at the camera.", duration: 6, quality: "hd", takes: 2, camera: cam))
        XCTAssertTrue(e.label.hasPrefix("Shot · HD"), e.label)
        XCTAssertTrue(e.buttonLabel.hasPrefix("Generate · 6 s · $"), e.buttonLabel)
        XCTAssertGreaterThan(e.estimate, 0)
        XCTAssertNotNil(e.engine)
        XCTAssertTrue(e.test)

        let m = try await member(boss)
        let me = try await m.suiteEstimate(ShotRequest(modelId: ch.id, prompt: "She waves.", duration: 6, quality: "hd"))
        XCTAssertNil(me.engine)
        XCTAssertTrue(SuiteText.isMemberSafe(me.label + me.buttonLabel + me.priceLine))

        // "Adapt, don't block" (server suite/plan.ts pickAdapted): too long is made at the nearest length, said in the warnings.
        let long = try await boss.suiteEstimate(ShotRequest(prompt: "x", duration: 30, quality: "draft"))
        XCTAssertLessThan(long.seconds, 30)
        XCTAssertTrue(long.warnings.contains { $0.range(of: #"made \d+ s, .* max"#, options: .regularExpression) != nil }, "\(long.warnings)")
        // An audio reference with nothing to ride on still can't be made: nothing_fits, with the reasons.
        do {
            _ = try await boss.suiteEstimate(ShotRequest(prompt: "x", references: SuiteReferences(audio: SuiteRefAudio(audio: SuiteVideoRef(url: "https://example.com/a.mp3"))),
                                                         quality: "draft"))
            XCTFail("expected nothing_fits")
        } catch let e as ApiError {
            XCTAssertEqual(e.code, "nothing_fits")
            XCTAssertTrue(e.message.hasPrefix("Can't make this shot"), e.message)
        }
    }

    func testShotJobAndSettings() async throws {
        let boss = try await owner()
        let ch = try await character(boss)
        let set = try await boss.suiteSettings()
        XCTAssertEqual(set.mode, "mock")
        XCTAssertFalse(set.models.isEmpty)
        let after = try await boss.updateSuiteSettings(SuiteSettingsPatch(capPerDay: set.caps.perDay))
        XCTAssertEqual(after.caps.perDay, set.caps.perDay)

        // The mock renderer needs ffmpeg on the server's machine; without it the server answers engine_unavailable.
        let job: Job
        do {
            job = try await boss.suiteCreateShot(ShotRequest(title: "Mac suite test", modelId: ch.id, prompt: "She waves.", duration: 5, quality: "draft"))
        } catch let e as ApiError where e.code == "engine_unavailable" {
            throw XCTSkip("This server can't make test renders here (\(e.message))")
        }
        XCTAssertEqual(job.request.engine, "suite")
        XCTAssertEqual(job.engineLabel, "Shot · Draft · 768p")
        XCTAssertTrue(job.isActive || job.isDone)
        let s = try await boss.suiteShot(id: job.id)
        XCTAssertEqual(s.job.id, job.id)
        // The mock renderer needs ffmpeg on the server's machine; done or failed both end the job (a failure refunds in full).
        var last = s.job
        for _ in 0..<60 where last.isActive {
            try await Task.sleep(nanoseconds: 500_000_000)
            last = try await boss.suiteShot(id: job.id).job
        }
        if last.isDone {
            let takes = try await boss.listTakes().filter { $0.jobId == job.id }
            XCTAssertEqual(takes.first?.label, "Draft")
        }
    }
}

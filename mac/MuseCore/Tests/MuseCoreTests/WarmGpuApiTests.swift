import XCTest
@testable import MuseCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Contract tests for Keep add-on engine ready (was Keep GPU warm) against the real API (`server/api`): GET/POST /v1/gpu/warm,
/// Keep ready, off with `lastOff`, owner only since the app clean-up (older servers: a member's, and the credit floor). Skipped unless MUSE_API_URL is set, and only ever run
/// against a LOCAL dev server (simulated GPU): they switch GPUs on and move credit.
///
///   cd server/api && PORT=8799 PUBLIC_URL=http://127.0.0.1:8799 node --import tsx scripts/test-server.ts &
///   cd mac/MuseCore && MUSE_API_URL=http://127.0.0.1:8799 swift test --filter WarmGpuApiTests
final class WarmGpuApiTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        guard let s = ProcessInfo.processInfo.environment["MUSE_API_URL"], let u = URL(string: s) else { throw XCTSkip("MUSE_API_URL not set") }
        let host = u.host ?? ""
        guard ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".local") else {
            throw XCTSkip("WarmGpuApiTests only run against a local server (got \(host))")
        }
        base = u
    }

    private func client() -> HTTPMuseAPI { HTTPMuseAPI(baseURL: base) }

    /// The owner, signed in. Skips when this server has no Keep GPU warm yet.
    private func owner() async throws -> HTTPMuseAPI {
        let api = client()
        let auth = try await api.signIn(SignInRequest(email: "jen@studio.com", password: "x"))
        await api.setToken(auth.token)
        try await api.ensureStudioFunds()
        do {
            _ = try await api.warmGpu()
        } catch let e as ApiError where e.code == "not_found" || e.code == "http_404" {
            throw XCTSkip("This server has no /v1/gpu/warm")
        }
        return api
    }

    /// A new member with `tokens` from the owner.
    private func member(_ boss: HTTPMuseAPI, tokens: Int) async throws -> (HTTPMuseAPI, String) {
        let email = "warm+\(UUID().uuidString.prefix(8).lowercased())@test.muse"
        let invite = try await boss.createInvite(InviteRequest(email: email))
        let api = client()
        let auth = try await api.signUp(SignUpRequest(studioName: "", email: email, password: "pw-12345678", inviteCode: invite.code,
                                                      attestAdultRightsOriginal: true, attestLabelAi: true))
        await api.setToken(auth.token)
        if tokens > 0 { _ = try await boss.sendTokens(TokenMove(userId: auth.user.id, tokens: tokens, note: "Mac warm GPU test")) }
        return (api, auth.user.id)
    }

    private func expect(_ codes: Set<String>, line: UInt = #line, _ work: () async throws -> Void) async {
        do {
            try await work()
            XCTFail("expected \(codes)", line: line)
        } catch let e as ApiError {
            XCTAssertTrue(codes.contains(e.code), "\(e.code): \(e.message)", line: line)
        } catch {
            XCTFail("unexpected \(error)", line: line)
        }
    }

    /// True on servers with the app clean-up: Keep add-on engine ready is owner-only.
    private func ownerOnly(_ boss: HTTPMuseAPI) async throws -> Bool { try await boss.studioBalanceIfAny() != nil }

    /// off → on (starting or warm) → idempotent on → Keep warm → off with lastOff.reason "user" → Keep warm refused.
    /// The owner's since the app clean-up; a member's on older servers.
    func testSwitchOnKeepWarmAndOff() async throws {
        let boss = try await owner()
        let me = try await ownerOnly(boss) ? boss : try await member(boss, tokens: 150).0 // $1.50: 10 minutes need ~$0.67
        let g0 = try await me.warmGpu()
        XCTAssertEqual(g0.state, "off")
        XCTAssertFalse(g0.isOn)
        XCTAssertTrue(g0.allowed)
        XCTAssertNil(g0.autoOffAt)
        XCTAssertEqual(g0.idleMinutes, 20)
        XCTAssertGreaterThan(g0.ratePerHour, 0)

        let on: WarmGpu
        do {
            on = try await me.setWarmGpu(.turnOn)
        } catch let e as ApiError where e.code == "no_gpu_free" || e.code == "no_gpu_available" {
            throw XCTSkip("The local server has no GPU to warm (\(e.code))")
        }
        XCTAssertTrue(["starting", "warm"].contains(on.state), on.state)
        XCTAssertTrue(on.isOn)
        let started = try XCTUnwrap(on.startedAt)
        let autoOff = try XCTUnwrap(on.autoOffAt)
        XCTAssertGreaterThan(autoOff, started)
        XCTAssertNotNil(on.autoOffReason)
        if let w = on.warningAt { XCTAssertEqual(autoOff - w, 5 * 60_000) }
        XCTAssertTrue(on.canExtend)
        XCTAssertEqual(on.costUsd, 0, accuracy: 0.07)

        // Idempotent while on: the same session.
        let again = try await me.setWarmGpu(.turnOn)
        XCTAssertEqual(again.startedAt, started)
        let got = try await me.warmGpu()
        XCTAssertEqual(got.startedAt, started)
        XCTAssertTrue(got.isOn)

        // Keep warm keeps it on (and, while the cap is next, uses the one extension).
        let kept = try await me.setWarmGpu(.keepWarm)
        XCTAssertTrue(kept.isOn)
        if on.autoOffReason == "cap" {
            XCTAssertFalse(kept.canExtend)
            XCTAssertEqual(kept.maxMinutes, on.maxMinutes * 2)
        }

        let off = try await me.setWarmGpu(.turnOff)
        XCTAssertEqual(off.state, "off")
        XCTAssertFalse(off.isOn)
        let last = try XCTUnwrap(off.lastOff)
        XCTAssertEqual(last.reason, "user")
        XCTAssertGreaterThanOrEqual(last.costUsd, 0)
        XCTAssertFalse(WarmGpuText.offMessage(last).isEmpty)
        // Fine when already off; Keep warm isn't.
        _ = try await me.setWarmGpu(.turnOff)
        await expect(["not_warm"]) { _ = try await me.setWarmGpu(.keepWarm) }
    }

    /// Owner only since the app clean-up: members get owner_only from GET and POST /v1/gpu/warm; the owner may.
    func testOwnerOnly() async throws {
        let boss = try await owner()
        guard try await ownerOnly(boss) else { throw XCTSkip("This server predates the app clean-up (warmGpuAllowed)") }
        let (me, _) = try await member(boss, tokens: 0)
        await expect(["owner_only"]) { _ = try await me.warmGpu() }
        await expect(["owner_only"]) { _ = try await me.setWarmGpu(.turnOn) }
        await expect(["owner_only"]) { _ = try await me.setWarmGpu(.turnOff) }
        let mine = try await boss.warmGpu()
        XCTAssertTrue(mine.allowed)
        let st = try await boss.studioSettings()
        XCTAssertEqual(st.warmIdleMinutes, 20)
        XCTAssertEqual(st.warmMaxMinutes, 120)
        await expect(["owner_only"]) { _ = try await me.updateStudioSettings(StudioSettingsPatch(warmIdleMinutes: 30)) }
    }

    /// It needs credit for 10 minutes (~$0.67).
    func testNeedsCreditForTenMinutes() async throws {
        let boss = try await owner()
        if try await ownerOnly(boss) { throw XCTSkip("Owner only now: the owner's credit floor isn't set up in this test") }
        let (broke, _) = try await member(boss, tokens: 30) // $0.30
        await expect(["insufficient_tokens", "insufficient_balance"]) { _ = try await broke.setWarmGpu(.turnOn) }
        let still = try await broke.warmGpu()
        XCTAssertFalse(still.isOn)
    }
}

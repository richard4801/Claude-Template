import XCTest
@testable import MuseCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Contract tests for the real API (`server/api`): invites, sign-up, the session, token wallets, members, settings and
/// presigned uploads. Skipped unless MUSE_API_URL is set. Run them only against a LOCAL dev server (embedded Postgres,
/// simulated GPU, dev seed), never against the hosted one: they create accounts and move tokens.
///
///   cd server/api && PORT=8799 PUBLIC_URL=http://127.0.0.1:8799 node --import tsx scripts/test-server.ts &
///   cd mac/MuseCore && MUSE_API_URL=http://127.0.0.1:8799 swift test --filter ApiServerTests
final class ApiServerTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        guard let s = ProcessInfo.processInfo.environment["MUSE_API_URL"], let u = URL(string: s) else { throw XCTSkip("MUSE_API_URL not set") }
        let host = u.host ?? ""
        guard ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".local") else {
            throw XCTSkip("ApiServerTests only run against a local server (got \(host))")
        }
        base = u
    }

    private func client() -> HTTPMuseAPI { HTTPMuseAPI(baseURL: base) }

    private func owner() async throws -> HTTPMuseAPI {
        let api = client()
        let auth = try await api.signIn(SignInRequest(email: "jen@studio.com", password: "x"))
        XCTAssertEqual(auth.user.role, "owner")
        await api.setToken(auth.token)
        try await api.ensureStudioFunds()
        return api
    }

    private func expect(_ code: String, _ line: UInt = #line, _ work: () async throws -> Void) async {
        do {
            try await work()
            XCTFail("expected \(code)", line: line)
        } catch let e as ApiError {
            XCTAssertEqual(e.code, code, e.message, line: line)
        } catch {
            XCTFail("unexpected \(error)", line: line)
        }
    }

    private func unique(_ name: String) -> String { "\(name)+\(UUID().uuidString.prefix(8).lowercased())@test.muse" }

    /// invite → sign-up → me → wallet → transfer → a member job charges tokens → insufficient_tokens → reclaim.
    func testInviteSignUpWalletTransferAndCharge() async throws {
        let boss = try await owner()
        let me0 = try await boss.me()
        XCTAssertTrue(me0.isOwner)

        // Invite → sign-up with the code. Wrong codes and reused emails get their own errors.
        let email = unique("member")
        let invite = try await boss.createInvite(InviteRequest(email: email))
        XCTAssertTrue(invite.code.hasPrefix("MUSE-"), invite.code)
        XCTAssertEqual(invite.role, "member")
        let member = client()
        await expect("attestation_required") {
            _ = try await member.signUp(SignUpRequest(studioName: "", email: email, password: "pw-12345678", inviteCode: invite.code, attestAdultRightsOriginal: true, attestLabelAi: false))
        }
        await expect("invite_invalid") {
            _ = try await member.signUp(SignUpRequest(studioName: "", email: email, password: "pw-12345678", inviteCode: "MUSE-AAAA-BBBB-CCCC", attestAdultRightsOriginal: true, attestLabelAi: true))
        }
        await expect("invite_invalid") { // the invite is for a different email
            _ = try await member.signUp(SignUpRequest(studioName: "", email: self.unique("other"), password: "pw-12345678", inviteCode: invite.code, attestAdultRightsOriginal: true, attestLabelAi: true))
        }
        let auth = try await member.signUp(SignUpRequest(studioName: "", email: email, password: "pw-12345678", inviteCode: invite.code, attestAdultRightsOriginal: true, attestLabelAi: true))
        XCTAssertEqual(auth.user.role, "member")
        XCTAssertTrue(auth.token.hasPrefix("muse_"))
        await member.setToken(auth.token)
        await expect("email_taken") {
            _ = try await self.client().signUp(SignUpRequest(studioName: "", email: email, password: "pw-12345678", attestAdultRightsOriginal: true, attestLabelAi: true))
        }
        await expect("invite_invalid") { // a code works once
            _ = try await self.client().signUp(SignUpRequest(studioName: "", email: self.unique("again"), password: "pw-12345678", inviteCode: invite.code, attestAdultRightsOriginal: true, attestLabelAi: true))
        }
        await expect("bad_credentials") { _ = try await self.client().signIn(SignInRequest(email: email, password: "wrong")) }

        // me restores the session from the token alone.
        let restored = client()
        await restored.setToken(auth.token)
        let who = try await restored.me()
        XCTAssertEqual(who.email, email)
        XCTAssertEqual(who.role, "member")
        XCTAssertEqual(who.id, auth.user.id)

        // A new member starts with no tokens, so a render is refused before any GPU starts.
        let w0 = try await member.wallet()
        XCTAssertEqual(w0.tokens, 0)
        XCTAssertEqual(w0.role, "member")
        XCTAssertNil(w0.availableToSend)
        let models = try await member.listModels()
        let sienna = try XCTUnwrap(models.first { $0.name == "Sienna Vale" })
        let clip = try await member.uploadClip(SampleData.sampleMeta, file: nil)
        XCTAssertTrue(clip.ok)
        let req = JobRequest(title: "Member test", modelId: sienna.id, outfitId: sienna.outfitIds[0], clipId: clip.id, engine: "viggle", steps: 4)
        await expect("insufficient_tokens") { _ = try await member.createJob(req) }
        XCTAssertEqual(ApiError("insufficient_tokens", "server text").friendlyMessage, "Not enough credit. Ask the studio owner for more.")
        await expect("owner_only") { _ = try await member.listMembers() }
        await expect("owner_only") { _ = try await member.sendTokens(TokenMove(userId: auth.user.id, tokens: 5)) }

        // The owner sends 100 tokens ($1.00).
        let ownerBefore = try await boss.wallet()
        XCTAssertTrue(ownerBefore.isOwner)
        let canSend = try XCTUnwrap(ownerBefore.tokensToSend)
        XCTAssertGreaterThanOrEqual(canSend, 100)
        await expect("over_allocation") { _ = try await boss.sendTokens(TokenMove(userId: auth.user.id, tokens: canSend + 1_000)) }
        let sent = try await boss.sendTokens(TokenMove(userId: auth.user.id, tokens: 100, note: "Mac contract test"))
        XCTAssertEqual(sent.member.tokens, 100)
        XCTAssertEqual(sent.member.email, email)
        XCTAssertEqual(try XCTUnwrap(sent.wallet.availableToSend), try XCTUnwrap(ownerBefore.availableToSend) - 1, accuracy: 1e-6)
        let w1 = try await member.wallet()
        XCTAssertEqual(w1.tokens, 100)
        XCTAssertEqual(w1.usd, 1, accuracy: 1e-9)
        let b1 = try await member.balance()
        XCTAssertEqual(b1.role, "member")
        XCTAssertEqual(b1.tokenCount, 100)
        XCTAssertEqual(b1.balance, 1, accuracy: 1e-9)

        // A member job holds its price in tokens from the member's own wallet.
        let job = try await member.createJob(req)
        XCTAssertEqual(job.cost, Pricing.totalCost(req.spec), accuracy: 1e-6)
        let held = Int((job.cost / w1.tokenUsd - 1e-6).rounded(.up))
        let w2 = try await member.wallet()
        XCTAssertEqual(w2.tokens, 100 - held)
        XCTAssertEqual(w2.heldTokens, held)
        var done: Job?
        for _ in 0..<120 {
            try await Task.sleep(nanoseconds: 250_000_000)
            if let j = try await member.listJobs().first(where: { $0.id == job.id }), !j.isActive { done = j; break }
        }
        let finished = try XCTUnwrap(done, "the member's job finishes")
        XCTAssertTrue(finished.isDone, finished.error ?? finished.state)
        let w3 = try await member.wallet()
        XCTAssertEqual(w3.heldTokens, 0)
        XCTAssertLessThan(w3.tokens, 100, "the job was paid from the member's tokens")
        XCTAssertGreaterThan(w3.monthUsd, 0)
        let takes = try await member.listTakes()
        let take = try XCTUnwrap(takes.first { $0.jobId == job.id })
        if let v = take.videoUrl { XCTAssertTrue(v.hasPrefix("http"), v) }

        // The owner sees the member's tokens and spend, sets a daily cap, and takes the rest back.
        let list = try await boss.listMembers()
        let row = try XCTUnwrap(list.first { $0.id == auth.user.id })
        XCTAssertEqual(row.tokens, w3.tokens)
        XCTAssertGreaterThan(row.monthUsd, 0)
        XCTAssertTrue(list.contains { $0.isOwner })
        let capped = try await boss.updateMember(id: auth.user.id, MemberPatch(capPerDay: .set(0.05)))
        XCTAssertEqual(capped.capPerDay, 0.05, accuracy: 1e-9)
        await expect("over_user_day_limit") { _ = try await member.createJob(req) }
        let uncapped = try await boss.updateMember(id: auth.user.id, MemberPatch(capPerDay: .reset))
        XCTAssertGreaterThan(uncapped.capPerDay, 0.05)
        let back = try await boss.takeBackTokens(TokenMove(userId: auth.user.id, tokens: w3.tokens, note: "end of test"))
        XCTAssertEqual(back.member.tokens, 0)
        await expect("insufficient_tokens") { _ = try await member.createJob(req) }

        // Switching a member off ends their session.
        _ = try await boss.updateMember(id: auth.user.id, MemberPatch(disabled: true))
        do {
            _ = try await member.wallet()
            XCTFail("a disabled member's session ends")
        } catch let e as ApiError {
            XCTAssertTrue(e.endsSession, e.code)
        }
        await expect("account_disabled") { _ = try await self.client().signIn(SignInRequest(email: email, password: "pw-12345678")) }
        let back2 = try await boss.updateMember(id: auth.user.id, MemberPatch(disabled: false))
        XCTAssertFalse(back2.disabled)

        // Sign-out revokes the session on the server.
        let again = client()
        let a2 = try await again.signIn(SignInRequest(email: email, password: "pw-12345678"))
        await again.setToken(a2.token)
        _ = try await again.me()
        try await again.signOut()
        await expect("unauthorized") { _ = try await again.me() }
        XCTAssertTrue(ApiError("unauthorized", "").endsSession)
    }

    func testStudioSettingsAndImageEngine() async throws {
        let boss = try await owner()
        let s0 = try await boss.studioSettings()
        XCTAssertGreaterThan(s0.capPerJob, 0)
        XCTAssertEqual(s0.tokenUsd, 0.01, accuracy: 1e-9)
        let s1 = try await boss.updateStudioSettings(StudioSettingsPatch(maxGpus: 2, overheadPayer: "owner"))
        XCTAssertEqual(s1.maxGpus, 2)
        XCTAssertEqual(s1.overheadPayer, "owner")
        let s2 = try await boss.updateStudioSettings(StudioSettingsPatch(maxGpus: s0.maxGpus, overheadPayer: s0.overheadPayer))
        XCTAssertEqual(s2.maxGpus, s0.maxGpus)
        XCTAssertEqual(s2.overheadPayer, s0.overheadPayer)
        XCTAssertEqual(s2.capPerJob, s0.capPerJob)
        XCTAssertEqual(s2.features, s0.features)

        let e0 = try await boss.imageEngine()
        XCTAssertEqual(e0.available["simulated"], true)
        await expect("bad_request") { _ = try await boss.setImageEngine(ImageEngineRequest(provider: "custom-http")) }
        let e1 = try await boss.setImageEngine(ImageEngineRequest(provider: "simulated"))
        XCTAssertEqual(e1.provider, "simulated")

        let b = try await boss.balance()
        XCTAssertEqual(b.role, "owner")
        XCTAssertNotNil(b.availableToSend)
    }

    /// The app clean-up (plans/api.md "App clean-up" §4–§6): the owner-loaded studio balance and top-ups, Engines for the owner
    /// only, members' settings without them, Keep add-on engine ready owner-only, Upscale coming soon. Skipped on older servers.
    func testStudioBalanceTopUpsAndOwnerOnlyEngines() async throws {
        let boss = try await owner()
        guard let sb0 = try await boss.studioBalanceIfAny() else { throw XCTSkip("This server predates the studio balance") }
        XCTAssertEqual(sb0.balanceUsd, sb0.toppedUpUsd - sb0.spentUsd, accuracy: 0.011)
        XCTAssertEqual(sb0.availableUsd, sb0.balanceUsd - sb0.membersCreditUsd - sb0.heldUsd, accuracy: 0.011)
        XCTAssertFalse(sb0.needsFirstTopUp, "owner() recorded one")
        let sb1 = try await boss.recordTopUp(TopUpRecord(amountUsd: 12.34, note: "Mac top-up test"))
        XCTAssertEqual(sb1.toppedUpUsd - sb0.toppedUpUsd, 12.34, accuracy: 0.001)
        XCTAssertEqual(sb1.availableUsd - sb0.availableUsd, 12.34, accuracy: 0.011)
        let top = try XCTUnwrap(sb1.topUps.first)
        XCTAssertEqual(top.amountUsd, 12.34, accuracy: 1e-9)
        XCTAssertEqual(top.note, "Mac top-up test")
        await expect("bad_request") { _ = try await boss.recordTopUp(TopUpRecord(amountUsd: 20_000)) }
        let b = try await boss.balance()
        XCTAssertEqual(b.balanceSource, "studio")
        XCTAssertEqual(b.availableToSend ?? 0, sb1.availableUsd, accuracy: 0.011)

        let s = try await boss.studioSettings()
        let engines = try XCTUnwrap(s.engines, "the owner gets Settings → Engines")
        XCTAssertEqual(Set(engines.list.map(\.id)), ["replicate", "runpod"])
        let video = try XCTUnwrap(s.features.video)
        XCTAssertEqual(video.ordered.map(\.id), ["draft", "standard", "hd"])
        XCTAssertEqual(video.addons.map(\.id), ["edit", "fast", "upscale"])
        XCTAssertEqual(video.upscale?.comingSoon, true)
        XCTAssertNotNil(s.features.photo)

        // A member: no engines, no studio balance, no add-on engine; member-safe labels.
        let email = unique("cleanup")
        let invite = try await boss.createInvite(InviteRequest(email: email))
        let member = client()
        let auth = try await member.signUp(SignUpRequest(studioName: "", email: email, password: "pw-12345678", inviteCode: invite.code,
                                                         attestAdultRightsOriginal: true, attestLabelAi: true))
        await member.setToken(auth.token)
        let ms = try await member.studioSettings()
        XCTAssertNil(ms.engines)
        XCTAssertNotNil(ms.features.video)
        await expect("owner_only") { _ = try await member.studioBalance() }
        await expect("owner_only") { _ = try await member.recordTopUp(TopUpRecord(amountUsd: 5)) }
        await expect("owner_only") { _ = try await member.warmGpu() }
        await expect("owner_only") { _ = try await member.setWarmGpu(.turnOn) }
        for o in video.options { XCTAssertTrue(MemberText.isSafe(o.label + " " + o.detail), o.detail) }
        for a in video.addons { XCTAssertTrue(MemberText.isSafe(a.label + " " + a.detail), a.detail) }
    }

    /// presign → PUT → confirm, for an image and a clip file, with progress.
    func testPresignedUploads() async throws {
        let api = try await owner()
        let box = ProgressBox()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])
        let direct: ImageRef? = try await api.presigned(kind: "image", contentType: "image/png", body: .data(png), meta: nil, progress: nil)
        let ref = try XCTUnwrap(direct, "the server offers presigned uploads (start it with PUBLIC_URL=http://127.0.0.1:PORT)")
        XCTAssertTrue(ref.url?.contains("/uploads/") == true, "\(ref)")
        let viaApi = try await api.uploadImage(name: "a.png", data: png, mime: "image/png", progress: { box.add($0) })
        XCTAssertTrue(viaApi.url?.hasPrefix("http") == true, "\(viaApi)")
        XCTAssertEqual(box.last, 1)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("muse-test-\(UUID().uuidString).mp4")
        try Data(repeating: 7, count: 64 * 1024).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let meta = ClipMeta(name: "upload.mp4", durationSec: 6, width: 1080, height: 1920, fps: 30)
        let clipBox = ProgressBox()
        let clip = try await api.uploadClip(meta, file: file, progress: { clipBox.add($0) })
        XCTAssertEqual(clip.name, "upload.mp4")
        XCTAssertEqual(clip.durationSec, 6, accuracy: 1e-9)
        XCTAssertTrue(clip.ok)
        XCTAssertEqual(clipBox.last, 1)
        let presignedClip: Clip? = try await api.presigned(kind: "clip", contentType: "video/mp4", body: .file(file), meta: meta, progress: nil)
        XCTAssertNotNil(presignedClip)
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ v: Double) { lock.lock(); values.append(v); lock.unlock() }
    var last: Double? { lock.lock(); defer { lock.unlock() }; return values.last }
}

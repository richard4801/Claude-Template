import XCTest
@testable import MuseCore

/// Token wallets, members, settings and error wording, without a server.
final class StudioTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    func testDecodesRealApiShapes() throws {
        let me = try decode(User.self, #"{"id":"u_owner","email":"jen@studio.com","studioName":"Jenne Studio","role":"owner"}"#)
        XCTAssertTrue(me.isOwner)
        let mock = try decode(User.self, #"{"id":"u1","email":"a@b.c","studioName":"S"}"#)
        XCTAssertNil(mock.role)
        XCTAssertFalse(mock.isOwner)

        let w = try decode(Wallet.self, #"{"userId":"u_owner","role":"owner","tokenUsd":0.01,"heldTokens":0,"heldUsd":0,"todayUsd":0.13,"monthUsd":18.93,"tokens":607,"usd":6.07,"availableToSend":6.07,"runpodBalance":6.07,"balanceSource":"simulated","membersUnspentUsd":0}"#)
        XCTAssertEqual(w.tokens, 607)
        XCTAssertEqual(w.tokensToSend, 607)
        XCTAssertTrue(w.isOwner)

        let b = try decode(Balance.self, #"{"balance":1,"month":0.13,"today":0.13,"perJobLimit":5,"perDayLimit":10,"perUserDayLimit":10,"videos":1,"tokens":100,"tokenUsd":0.01,"role":"member","heldUsd":0,"balanceSource":"wallet"}"#)
        XCTAssertEqual(b.tokenCount, 100)
        XCTAssertEqual(b.role, "member")
        XCTAssertNil(b.availableToSend)
        let old = try decode(Balance.self, #"{"balance":6.07,"month":18.8}"#)
        XCTAssertEqual(old.tokenCount, 607, "an older server's balance converts to tokens")

        let m = try decode([Member].self, #"[{"id":"u1","email":"m@x.y","role":"member","tokens":87,"usd":0.87,"heldTokens":0,"todayUsd":0.13,"monthUsd":0.13,"disabled":false,"capPerJob":5,"capPerDay":10,"createdAt":1}]"#)
        XCTAssertEqual(m.first?.tokens, 87)
        XCTAssertNil(m.first?.lastActiveAt)

        let j = try decode(Job.self, #"{"id":"j9","state":"running","step":0,"queuePosition":2,"etaSeconds":250,"warmupCost":0.04,"blocked":null,"request":{"engine":"h3","steps":10}}"#)
        XCTAssertTrue(j.isWaiting)
        XCTAssertEqual(j.waitLine, "#2 in line · done in ~5 min")
        XCTAssertEqual(j.warmupCost, 0.04)
        let paused = try decode(Job.self, #"{"id":"j8","state":"running","blocked":"owner_balance_low"}"#)
        XCTAssertTrue(paused.isPaused)
        XCTAssertEqual(paused.waitLine, "Paused: the studio's GPU credit is low")

        let t = try decode(Take.self, #"{"id":"t1","kind":"take","videoUrl":"/uploads/r/take_1.mp4","durationSec":5.2,"width":768,"height":1344}"#)
        XCTAssertEqual(t.mediaLine, "0:05 · 768×1344")
        let api = HTTPMuseAPI(baseURL: URL(string: "https://api.example.com/")!)
        XCTAssertEqual(api.absolutize(t).videoUrl, "https://api.example.com/uploads/r/take_1.mp4")
        XCTAssertNil(try decode(Take.self, #"{"id":"t2"}"#).mediaLine)

        let e = try decode(ApiEvent.self, #"{"type":"wallet","wallet":{"userId":"u","role":"member","tokens":250},"notice":{"code":"owner_balance_low","message":"RunPod balance low: top up to resume"}}"#)
        XCTAssertEqual(e.wallet?.tokens, 250)
        XCTAssertEqual(e.wallet?.usd ?? 0, 2.5, accuracy: 1e-9)
        XCTAssertEqual(e.notice?.code, "owner_balance_low")

        let s = try decode(StudioSettings.self, #"{"maxGpus":3,"overheadPayer":"user","capPerJob":5,"capPerDay":15,"capPerUserDay":10,"tokenUsd":0.01,"minRunpodBalance":2,"lowBalance":false,"features":{"standard":true,"fastBeta":true,"lipSync":true,"loraTraining":true,"replaceAudio":false,"outputSize":{"width":768,"height":1344},"maxClipSec":15},"gpu":{"mode":"simulated","pods":[]}}"#)
        XCTAssertEqual(s.maxGpus, 3)
        XCTAssertFalse(s.features.replaceAudio)
        let eng = try decode(ImageEngine.self, #"{"provider":"simulated","model":"bundled-stills","available":{"simulated":true,"fal":false,"custom-http":true}}"#)
        XCTAssertFalse(eng.isAvailable("fal"))
        XCTAssertTrue(eng.isAvailable("custom-http"))
    }

    func testEncodesRequests() throws {
        func json<T: Encodable>(_ v: T) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(v)) as! [String: Any]
        }
        let up = try json(SignUpRequest(studioName: "", email: "a@b.c", password: "x", inviteCode: "  MUSE-1234-5678-ABCD ", attestAdultRightsOriginal: true, attestLabelAi: true))
        XCTAssertEqual(up["inviteCode"] as? String, "MUSE-1234-5678-ABCD")
        let noCode = try json(SignUpRequest(studioName: "", email: "a@b.c", password: "x", inviteCode: " ", attestAdultRightsOriginal: true, attestLabelAi: true))
        XCTAssertNil(noCode["inviteCode"])

        let reset = try json(MemberPatch(capPerDay: .reset))
        XCTAssertTrue(reset["capPerDay"] is NSNull, "reset sends null: back to the studio default")
        XCTAssertNil(reset["capPerJob"])
        XCTAssertNil(reset["disabled"])
        let set = try json(MemberPatch(capPerJob: .set(2.5), disabled: true))
        XCTAssertEqual(set["capPerJob"] as? Double, 2.5)
        XCTAssertEqual(set["disabled"] as? Bool, true)

        let move = try json(TransferBody(toUserId: "u2", tokens: 50, note: TokenMove(userId: "u2", tokens: 50, note: "  ").note))
        XCTAssertEqual(move["toUserId"] as? String, "u2")
        XCTAssertNil(move["note"])
        let patch = try json(StudioSettingsPatch(overheadPayer: "owner"))
        XCTAssertEqual(patch.count, 1)
    }

    func testFriendlyErrors() {
        XCTAssertEqual(ApiError("insufficient_tokens", "Not enough tokens · ask the studio owner for more (you have 3)").friendlyMessage,
                       "Not enough credit. Ask the studio owner for more.")
        for code in ["insufficient_tokens", "over_allocation", "balance_unavailable", "invite_required"] {
            XCTAssertFalse(ApiError.friendly(code)!.lowercased().contains("token"), "no tokens in the UI: \(code)")
        }
        for code in ["invite_required", "invite_invalid", "email_taken", "bad_credentials", "account_disabled", "rate_limited", "unauthorized"] {
            XCTAssertNotNil(ApiError.friendly(code), code)
        }
        XCTAssertEqual(ApiError("http_429", "Server error 429").friendlyMessage, ApiError("rate_limited", "").friendlyMessage)
        XCTAssertEqual(ApiError("bad_request", "They have 250 unused tokens (13 more are on hold for running jobs)").friendlyMessage,
                       "They have $2.50 unused credit ($0.13 more are on hold for running jobs)")
        XCTAssertEqual(ApiError("bad_request", "The owner's wallet is the RunPod balance; send tokens to members only").friendlyMessage,
                       "The owner's wallet is the RunPod balance; send credit to members only")
        XCTAssertTrue(ApiError("unauthorized", "").endsSession)
        XCTAssertTrue(ApiError("account_disabled", "").endsSession)
        XCTAssertFalse(ApiError("insufficient_tokens", "").endsSession)
        XCTAssertEqual(ApiError("over_day_limit", "Over the studio's $15.00 daily limit").friendlyMessage, "Over the studio's $15.00 daily limit")
    }

    func testDollarsToTokens() {
        XCTAssertEqual(Pricing.tokensForDollars(5), 500)
        XCTAssertEqual(Pricing.tokensForDollars(0.015), 2, "rounds to the nearest cent")
        XCTAssertEqual(Pricing.tokensForDollars(0.014), 1)
        XCTAssertEqual(Pricing.tokensForDollars(19.99), 1999)
        XCTAssertEqual(Pricing.tokensForDollars(1.1), 110, "no float drift")
        XCTAssertEqual(Pricing.parseDollars("$1,250.5"), 1250.5)
        XCTAssertEqual(Pricing.parseDollars(" 2.345 "), 2.35)
        XCTAssertNil(Pricing.parseDollars("abc"))
        XCTAssertNil(Pricing.parseDollars("-3"))
        XCTAssertEqual(TokenMove(userId: "u", usd: 2.5, note: "x").tokens, 250)
    }

    func testInviteShareText() throws {
        let now: Int64 = 1_000_000_000_000
        let inv = Invite(code: "MUSE-AB12-CD34-EF56", id: "i", email: "tess@example.com", expiresAt: now + 14 * 86_400_000)
        XCTAssertEqual(inv.shareMessage(publicURL: "https://muse.example.com/", now: now),
                       "You're invited to MUSE, the AI model studio. 1) Download: https://muse.example.com/get 2) Sign up with this invite code: MUSE-AB12-CD34-EF56 (email: tess@example.com). The code works once and expires in 14 days.")
        let anyone = Invite(code: "MUSE-AB12-CD34-EF56", id: "i", expiresAt: now + 14 * 86_400_000)
        XCTAssertFalse(anyone.shareMessage(publicURL: "https://m.example", now: now).contains("email"))
        let fromServer = try JSONDecoder().decode(Invite.self, from: Data(#"{"code":"MUSE-X","id":"i","role":"member","expiresAt":1,"shareText":"From the server"}"#.utf8))
        XCTAssertEqual(fromServer.shareMessage(publicURL: "https://m.example"), "From the server")
    }

    func testDemoOwnerSendsAndTakesBackTokens() async throws {
        let api = FakeMuseAPI(speed: 0)
        _ = try await api.signIn(SignInRequest(email: "jen@studio.com", password: "x"))
        let me = try await api.me()
        XCTAssertTrue(me.isOwner)
        let b0 = await api.balance()
        XCTAssertEqual(b0.role, "owner")
        XCTAssertEqual(b0.tokenCount, 607)
        let members = await api.listMembers()
        XCTAssertEqual(members.filter { !$0.isOwner }.count, 2)
        let maya = try XCTUnwrap(members.first { $0.email == "maya@studio.com" })

        do {
            _ = try await api.sendTokens(TokenMove(userId: maya.id, tokens: 10_000))
            XCTFail()
        } catch let e as ApiError { XCTAssertEqual(e.code, "over_allocation") }
        let sent = try await api.sendTokens(TokenMove(userId: maya.id, tokens: 100, note: "for the week"))
        XCTAssertEqual(sent.member.tokens, maya.tokens + 100)
        XCTAssertEqual(sent.wallet.tokens, 507)
        let back = try await api.takeBackTokens(TokenMove(userId: maya.id, tokens: 50))
        XCTAssertEqual(back.member.tokens, maya.tokens + 50)
        XCTAssertEqual(back.wallet.tokens, 557)
        let capped = try await api.updateMember(id: maya.id, MemberPatch(capPerDay: .set(3), disabled: true))
        XCTAssertEqual(capped.capPerDay, 3)
        XCTAssertTrue(capped.disabled)

        let invite = await api.createInvite(InviteRequest(email: "new@studio.com"))
        XCTAssertTrue(invite.code.hasPrefix("MUSE-"))
        XCTAssertEqual(invite.code.count, 19)

        let s = try await api.updateStudioSettings(StudioSettingsPatch(maxGpus: 2, overheadPayer: "owner", capPerJob: 4))
        XCTAssertEqual(s.maxGpus, 2)
        XCTAssertEqual(s.overheadPayer, "owner")
        let b1 = await api.balance()
        XCTAssertEqual(b1.perJobLimit, 4)
        let eng = try await api.setImageEngine(ImageEngineRequest(provider: "custom-http", url: "https://img.example.com/gen"))
        XCTAssertEqual(eng.url, "https://img.example.com/gen")
        try await api.signOut()
        do {
            _ = try await api.me()
            XCTFail()
        } catch let e as ApiError { XCTAssertEqual(e.code, "unauthorized") }
    }
}

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

        let w = try decode(Wallet.self, #"{"userId":"u_owner","role":"owner","tokenUsd":0.01,"heldTokens":0,"heldUsd":0,"todayUsd":0.13,"monthUsd":18.93,"tokens":607,"usd":6.07,"availableToSend":6.07,"studioBalance":9.2,"balanceSource":"studio","membersUnspentUsd":3.13}"#)
        XCTAssertEqual(w.tokens, 607)
        XCTAssertEqual(w.tokensToSend, 607)
        XCTAssertEqual(w.studioBalance, 9.2)
        XCTAssertTrue(w.isOwner)
        // Below zero until the first top-up: nothing to send.
        let neg = try decode(Wallet.self, #"{"role":"owner","availableToSend":-3.5,"studioBalance":0,"balanceSource":"studio"}"#)
        XCTAssertEqual(neg.tokensToSend, 0)
        let ob = try decode(Balance.self, #"{"balance":-3.5,"month":0,"role":"owner","balanceSource":"studio","availableToSend":-3.5,"studioBalance":0,"needsFirstTopUp":true}"#)
        XCTAssertEqual(ob.needsFirstTopUp, true)
        XCTAssertEqual(ob.studioBalance, 0)

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
        XCTAssertEqual(j.waitLine, "#2 in line · about 4 min")
        XCTAssertEqual(j.warmupCost, 0.04, "decoded for the owner's ledger, never shown")
        let paused = try decode(Job.self, #"{"id":"j8","state":"running","blocked":"owner_balance_low","phase":"Paused: the studio's GPU credit is low"}"#)
        XCTAssertFalse(paused.isWaiting)
        XCTAssertEqual(paused.statusLine, "Waiting to start", "an older server's paused line isn't shown")

        let t = try decode(Take.self, #"{"id":"t1","kind":"take","videoUrl":"/uploads/r/take_1.mp4","durationSec":5.2,"width":768,"height":1344}"#)
        XCTAssertEqual(t.mediaLine, "0:05 · 768×1344")
        let api = HTTPMuseAPI(baseURL: URL(string: "https://api.example.com/")!)
        XCTAssertEqual(api.absolutize(t).videoUrl, "https://api.example.com/uploads/r/take_1.mp4")
        XCTAssertNil(try decode(Take.self, #"{"id":"t2"}"#).mediaLine)

        let e = try decode(ApiEvent.self, #"{"type":"wallet","wallet":{"userId":"u","role":"owner","tokens":250},"notice":{"code":"provider_out_of_credit","engine":"replicate","message":"An engine is out of credit · see Settings → Engines"}}"#)
        XCTAssertEqual(e.wallet?.tokens, 250)
        XCTAssertEqual(e.wallet?.usd ?? 0, 2.5, accuracy: 1e-9)
        XCTAssertEqual(e.notice?.code, "provider_out_of_credit")
        XCTAssertEqual(e.notice?.engine, "replicate")

        let s = try decode(StudioSettings.self, #"{"maxGpus":3,"overheadPayer":"user","capPerJob":5,"capPerDay":15,"capPerUserDay":10,"tokenUsd":0.01,"minRunpodBalance":2,"lowBalance":false,"features":{"standard":true,"fastBeta":true,"lipSync":true,"loraTraining":true,"replaceAudio":false,"outputSize":{"width":768,"height":1344},"maxClipSec":15},"gpu":{"mode":"simulated","pods":[]}}"#)
        XCTAssertEqual(s.maxGpus, 3)
        XCTAssertFalse(s.features.replaceAudio)
        XCTAssertNil(s.engines)
        XCTAssertNil(s.features.photo)
        // A member's settings: caps and features only.
        let member = try decode(StudioSettings.self, #"{"capPerJob":5,"capPerDay":15,"capPerUserDay":10,"tokenUsd":0.01,"features":{"photo":{"perRun":0.015,"perInputMp":0.015,"perOutputMp":0.015,"perEdit":0.03,"refMp":0.79,"maxRefs":6,"loraShots":30,"estimates":{"shoot":0.4644,"outfitSet":0.1911,"sheetAngle":0.1011,"loraSet":3.033}}}}"#)
        XCTAssertNil(member.engines)
        XCTAssertEqual(member.features.photo?.estimates?.shoot, 0.4644)
        // The owner's Engines block.
        let owner = try decode(StudioSettings.self, #"{"maxGpus":2,"overheadPayer":"owner","warmIdleMinutes":20,"warmMaxMinutes":120,"features":{},"engines":{"list":[{"id":"replicate","name":"Replicate","usedFor":"Draft, Standard and HD video · photos","keySet":true,"status":"out_of_credit","message":"Replicate refused for lack of credit","outOfCreditAt":1762300000000},{"id":"runpod","name":"RunPod","usedFor":"Edit, Fast · beta, Upscale","keySet":false,"status":"no_key"}],"imageEngine":{"provider":"replicate","model":"black-forest-labs/flux-2-pro","label":"FLUX.2 [pro] · Replicate"},"addOn":{"maxGpus":2,"overheadPayer":"owner","gpu":{"mode":"simulated"}},"keepReady":{"idleMinutes":20,"maxMinutes":120,"ratePerHour":3.99}}}"#)
        let en = try XCTUnwrap(owner.engines)
        XCTAssertEqual(en.list.map(\.name), ["Replicate", "RunPod"])
        XCTAssertEqual(en.list[0].statusLabel, "Out of credit")
        XCTAssertTrue(en.list[0].isProblem)
        XCTAssertEqual(en.list[1].statusLabel, "No key")
        XCTAssertFalse(en.list[1].keySet)
        XCTAssertEqual(en.imageEngine?.displayLabel, "FLUX.2 [pro] · Replicate")
        XCTAssertEqual(en.addOn?.overheadPayer, "owner")
        XCTAssertEqual(en.keepReady?.ratePerHour, 3.99)
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
        for code in ["insufficient_tokens", "insufficient_balance", "over_allocation", "balance_unavailable", "invite_required"] {
            XCTAssertFalse(ApiError.friendly(code)!.lowercased().contains("token"), "no tokens in the UI: \(code)")
        }
        for code in ["invite_required", "invite_invalid", "email_taken", "bad_credentials", "account_disabled", "rate_limited", "unauthorized"] {
            XCTAssertNotNil(ApiError.friendly(code), code)
        }
        XCTAssertEqual(ApiError("http_429", "Server error 429").friendlyMessage, ApiError("rate_limited", "").friendlyMessage)
        XCTAssertEqual(ApiError("bad_request", "They have 250 unused tokens (13 more are on hold for running jobs)").friendlyMessage,
                       "They have $2.50 unused credit ($0.13 more are on hold for running jobs)")
        XCTAssertEqual(ApiError("bad_request", "The owner's wallet is the studio balance; send tokens to members only").friendlyMessage,
                       "The owner's wallet is the studio balance; send credit to members only")
        // Retired codes and engine names never reach a member.
        for code in ["owner_balance_low", "balance_unavailable", "topup_unavailable", "over_allocation", "insufficient_balance", "image_engine_failed",
                     "provider_refused", "provider_rate_limited", "provider_out_of_credit", "upscale_unavailable"] {
            XCTAssertTrue(MemberText.isSafe(ApiError.friendly(code)!), code)
        }
        XCTAssertEqual(ApiError("bad_request", "The owner's wallet is the RunPod balance").friendlyMessage, "Something went wrong · you weren't charged")
        XCTAssertEqual(ApiError("insufficient_balance", "").friendlyMessage, "Not enough in the studio balance · add a top-up in Credit")
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

    func testDemoStudioBalanceTopUpsAndOwnerOnlyParts() async throws {
        let api = FakeMuseAPI(speed: 0)
        _ = try await api.signIn(SignInRequest(email: "jen@studio.com", password: "x"))
        let sb0 = try await api.studioBalance()
        XCTAssertFalse(sb0.needsFirstTopUp)
        XCTAssertEqual(sb0.topUps.first?.amountUsd, 25)
        XCTAssertEqual(sb0.availableUsd, 6.07, accuracy: 1e-9)
        XCTAssertEqual(sb0.balanceUsd, sb0.availableUsd + sb0.membersCreditUsd + sb0.heldUsd, accuracy: 0.01)
        let b0 = await api.balance()
        XCTAssertEqual(b0.balanceSource, "studio")
        XCTAssertEqual(b0.studioBalance ?? 0, sb0.balanceUsd, accuracy: 0.01)

        do {
            _ = try await api.recordTopUp(TopUpRecord(amountUsd: 20_000))
            XCTFail()
        } catch let e as ApiError { XCTAssertEqual(e.code, "bad_request") }
        let sb1 = try await api.recordTopUp(TopUpRecord(amountUsd: 20, note: "  Card payment  "))
        XCTAssertEqual(sb1.availableUsd, 26.07, accuracy: 1e-9)
        XCTAssertEqual(sb1.topUps.first?.line, "Added $20.00 · Card payment")
        XCTAssertEqual(sb1.toppedUpUsd, 45, accuracy: 1e-9)
        let w = await api.wallet()
        XCTAssertEqual(w.availableToSend ?? 0, 26.07, accuracy: 1e-9)
        // The older alias records a top-up too.
        let b2 = try await api.topUp(TopUpRequest(amount: 5))
        XCTAssertEqual(b2.balance, 31.07, accuracy: 1e-9)
        XCTAssertEqual(TopUpRecord(amountUsd: 19.999).amountUsd, 20)
        XCTAssertFalse(TopUpRecord(amountUsd: 0).isValid)

        // The owner sees Engines; Keep add-on engine ready answers.
        let owner = try await api.studioSettings()
        XCTAssertEqual(owner.engines?.list.map(\.id), ["replicate", "runpod"])
        XCTAssertNotNil(owner.features.photo)
        _ = try await api.warmGpu()

        // Upscale is coming soon.
        let all = await api.listTakes()
        let take = try XCTUnwrap(all.first { $0.isVideo })
        do {
            _ = try await api.upscale(takeId: take.id, UpscaleRequest(size: "2k"))
            XCTFail()
        } catch let e as ApiError {
            XCTAssertEqual(e.code, "upscale_unavailable")
            XCTAssertEqual(e.friendlyMessage, "Upscale is coming soon")
        }

        // A member: caps and features only, and no add-on engine, studio balance or top-ups.
        await api.setRole("member")
        let member = try await api.studioSettings()
        XCTAssertNil(member.engines)
        XCTAssertNotNil(member.features.video)
        for work in [{ _ = try await api.warmGpu() }, { _ = try await api.setWarmGpu(.turnOn) }, { _ = try await api.studioBalance() },
                     { _ = try await api.recordTopUp(TopUpRecord(amountUsd: 5)) }] as [() async throws -> Void] {
            do {
                try await work()
                XCTFail("members get owner_only")
            } catch let e as ApiError { XCTAssertEqual(e.code, "owner_only") }
        }
    }

    func testDemoChargesPhotoEstimates() async throws {
        let api = FakeMuseAPI(speed: 0, genDelay: 0)
        _ = try await api.signIn(SignInRequest(email: "jen@studio.com", password: "x"))
        let b0 = await api.balance()
        let shots = try await api.shoot(ShootRequest(modelId: SampleData.demo, outfitId: SampleData.green, scene: "Kitchen", prompt: "p"))
        let b1 = await api.balance()
        XCTAssertEqual(b0.balance - b1.balance, PhotoPricing.standard.shoot(), accuracy: 1e-9)
        XCTAssertEqual(shots.reduce(0) { $0 + $1.cost }, PhotoPricing.standard.shoot(), accuracy: 1e-9)
        XCTAssertTrue(shots.allSatisfy { $0.displayEngineLabel.isEmpty })
    }
}

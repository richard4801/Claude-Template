import XCTest
@testable import MuseCore

final class SoundSynthTests: XCTestCase {
    func testEveryThemeAndKindRendersAnAudibleBuffer() {
        for theme in ["a", "b", "c", "d"] {
            for kind in SoundKind.allCases {
                let buf = SoundSynth.render(theme: theme, kind: kind)
                XCTAssertFalse(buf.isEmpty, "\(theme)/\(kind) is empty")
                let peak = SoundSynth.peak(buf)
                XCTAssertGreaterThan(peak, 0.4, "\(theme)/\(kind) peak \(peak)")
                XCTAssertLessThanOrEqual(peak, 0.7001, "\(theme)/\(kind) clips")
                XCTAssertFalse(buf.contains { !$0.isFinite }, "\(theme)/\(kind) has NaN/inf")
                XCTAssertLessThan(Double(buf.count) / SoundSynth.defaultRate, 1.6, "\(theme)/\(kind) too long")
            }
        }
    }

    func testTickIsQuieterAndRenderingIsDeterministic() {
        XCTAssertEqual(SoundSynth.peak(SoundSynth.render(theme: "a", kind: .tick)), 0.45, accuracy: 1e-4)
        XCTAssertEqual(SoundSynth.peak(SoundSynth.render(theme: "a", kind: .tap)), 0.7, accuracy: 1e-4)
        XCTAssertEqual(SoundSynth.render(theme: "b", kind: .nav), SoundSynth.render(theme: "b", kind: .nav))
    }

    func testLengthsFollowThePrototype() {
        // Editorial "done" is three 0.9 s notes 0.12 s apart (+ the 20 ms tail): 0.24 + 0.92 s.
        let done = SoundSynth.render(theme: "a", kind: .done, sampleRate: 1000)
        XCTAssertEqual(done.count, 240 + 920)
        // Camera Body "tick" is a 12 ms noise burst.
        XCTAssertEqual(SoundSynth.render(theme: "b", kind: .tick, sampleRate: 1000).count, 12)
        // Creator Pop "go": a 0.25 s saw sweep with a 20 ms tail.
        XCTAssertEqual(SoundSynth.render(theme: "d", kind: .go, sampleRate: 1000).count, 270)
    }
}

final class LoraPromptTests: XCTestCase {
    private var sienna: MuseModel { SampleData.models().first { $0.id == SampleData.sienna }! }

    func testPricing() {
        XCTAssertEqual(Pricing.money(LoraPricing.setCost), "$0.60")
        XCTAssertEqual(Pricing.money(LoraPricing.trainCost), "$6.65")
        XCTAssertEqual(Pricing.money(LoraPricing.photoCost), "$1.66")
        XCTAssertEqual(Pricing.money(LoraPricing.videoCost), "$4.99")
        XCTAssertEqual(Pricing.money(LoraPricing.totalCost), "$7.25")
        XCTAssertEqual(LoraPricing.timeLabel, "~1 h 40")
        XCTAssertEqual(LoraPricing.photoProgress(10), 40)
        XCTAssertEqual(LoraPricing.videoProgress(10), 0)
        XCTAssertEqual(LoraPricing.videoProgress(62.5), 50)
    }

    func testTokenAndActiveVersion() {
        XCTAssertEqual(Lora.token(modelName: "Sienna Vale", version: 1), "sienna_v1")
        XCTAssertEqual(Lora.token(modelName: "Zoë-Ann K", version: 3), "zoann_v3")
        var l = Lora(modelId: "m", version: 0, state: "review")
        XCTAssertNil(l.promptToken(modelName: "Sienna Vale"), "never trained")
        l.version = 2
        XCTAssertEqual(l.promptToken(modelName: "Sienna Vale"), "sienna_v2", "a retrain keeps using the last ready version")
        l.use = false
        XCTAssertNil(l.promptToken(modelName: "Sienna Vale"), "switched off: references only")
    }

    func testIdentityLayerAddsThePhotoLoRA() {
        let ready = Lora(modelId: sienna.id, version: 1, state: "ready", use: true)
        let slots = PromptEngine.shoot(identity: sienna.promptIdentity(lora: ready), outfitName: "Green set", settings: ShootSettings())
        XCTAssertEqual(slots.first?.text, "Sienna Vale: \(SampleData.siennaLook). Identity from 6 locked reference images + LoRA sienna_v1 (photo).")
        // Off: exactly the references-only wording.
        var off = ready
        off.use = false
        let plain = PromptEngine.shoot(identity: sienna.promptIdentity(lora: off), outfitName: "Green set", settings: ShootSettings())
        XCTAssertEqual(plain.first?.text, "Sienna Vale: \(SampleData.siennaLook). Identity from 6 locked reference images.")
        XCTAssertEqual(PromptEngine.shoot(identity: sienna.promptIdentity, outfitName: "Green set", settings: ShootSettings()), plain)
        // Sheet fills and outfit sets use the photo LoRA too.
        XCTAssertTrue(PromptEngine.sheetShot(identity: sienna.promptIdentity(lora: ready), angle: .back).contains("+ LoRA sienna_v1 (photo)."))
    }

    func testVideoPromptAddsTheVideoLoRA() {
        let ready = Lora(modelId: sienna.id, version: 2, state: "ready", use: true)
        let v = PromptEngine.video(VideoPromptInput(identity: sienna.promptIdentity(lora: ready), outfitName: "Green set"))
        XCTAssertTrue(v.contains("Target: Sienna Vale, \(SampleData.siennaLook) (reference images 1–6, LoRA sienna_v2 video)."), v)
        let plain = PromptEngine.video(VideoPromptInput(identity: sienna.promptIdentity, outfitName: "Green set"))
        XCTAssertTrue(plain.contains("(reference images 1–6).\n"), plain)
        XCTAssertFalse(plain.contains("LoRA"))
    }
}

final class LoraFlowTests: XCTestCase {
    private func waitFor(_ timeout: Double = 5, _ check: () async throws -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if try await check() { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTFail("timed out")
    }

    func testBuildReviewTrainAndUse() async throws {
        let api = FakeMuseAPI(speed: 0, genDelay: 0.05, loraSeconds: 0.4)
        let id = SampleData.sienna
        let b0 = try await api.balance().balance
        let none = try await api.lora(modelId: id)
        XCTAssertEqual(none.state, "none")
        XCTAssertEqual(none.version, 0)

        let building = try await api.buildLoraCandidates(modelId: id)
        XCTAssertEqual(building.state, "building")
        let b1 = try await api.balance().balance
        XCTAssertEqual(b0 - b1, 0.60, accuracy: 1e-9)

        try await waitFor { try await api.lora(modelId: id).state == "review" }
        var l = try await api.lora(modelId: id)
        XCTAssertEqual(l.candidates.count, 30)
        XCTAssertEqual(Set(l.candidates.compactMap(\.flag)), ["tattoo", "ring", "choker", "face drift"])
        XCTAssertTrue(l.candidates.filter { $0.flag != nil }.allSatisfy { !$0.keep }, "flagged shots start dropped")
        XCTAssertEqual(l.kept, 26)

        // The user can bring a flagged shot back, and drop others.
        let flagged = l.candidates.first { $0.flag == "ring" }!
        l = try await api.setLoraCandidate(modelId: id, candidateId: flagged.id, keep: true)
        XCTAssertEqual(l.kept, 27)
        for c in l.candidates.filter(\.keep).prefix(8) { l = try await api.setLoraCandidate(modelId: id, candidateId: c.id, keep: false) }
        XCTAssertEqual(l.kept, 19)
        do { _ = try await api.trainLora(modelId: id); XCTFail("needs 20 kept") } catch let e as ApiError { XCTAssertEqual(e.code, "bad_request") }
        l = try await api.setLoraCandidate(modelId: id, candidateId: l.candidates.first { !$0.keep && $0.flag == nil }!.id, keep: true)
        XCTAssertEqual(l.kept, 20)
        XCTAssertTrue(l.canTrain)

        // $5.47 left is less than $6.65: blocked.
        do { _ = try await api.trainLora(modelId: id); XCTFail("low balance") } catch let e as ApiError { XCTAssertEqual(e.code, "insufficient_balance") }
        _ = try await api.topUp(TopUpRequest(amount: 10))
        let before = try await api.balance().balance
        let training = try await api.trainLora(modelId: id)
        XCTAssertEqual(training.state, "training")
        let after = try await api.balance().balance
        XCTAssertEqual(before - after, LoraPricing.trainCost, accuracy: 1e-9)

        try await waitFor { try await api.lora(modelId: id).state == "ready" }
        l = try await api.lora(modelId: id)
        XCTAssertEqual(l.version, 1)
        XCTAssertTrue(l.use, "Use in new renders is on by default")
        XCTAssertEqual(l.trainedOn, 20)
        XCTAssertEqual(l.photo.progress, 100)
        XCTAssertEqual(l.video.progress, 100)

        // New renders name the LoRA in the exact prompt saved with the job.
        _ = try await api.topUp(TopUpRequest(amount: 10))
        let job = try await api.createJob(JobRequest(title: "t", modelId: id, outfitId: SampleData.green, clipId: SampleData.sampleClip, engine: "viggle", steps: 4))
        XCTAssertTrue(job.prompt.contains("LoRA sienna_v1 video"), job.prompt)
        l = try await api.setLoraUse(modelId: id, use: false)
        XCTAssertNil(l.activeVersion)
        let job2 = try await api.createJob(JobRequest(title: "t", modelId: id, outfitId: SampleData.green, clipId: SampleData.sampleClip, engine: "viggle", steps: 4))
        XCTAssertFalse(job2.prompt.contains("LoRA"))
    }

    func testDeletingAModelDeletesItsLoRAAndAccounts() async throws {
        let api = FakeMuseAPI(speed: 0, genDelay: 0.05)
        let m = try await api.createModel(CreateModelRequest(name: "Del", age: 30, niche: "Tech"))
        _ = try await api.setSlot(modelId: m.id, slot: "face", SetSlotRequest(image: .asset("face")))
        _ = try await api.buildLoraCandidates(modelId: m.id)
        _ = try await api.connectAccount(modelId: m.id, platform: .tiktok)
        try await api.deleteModel(id: m.id)
        let models = try await api.listModels()
        XCTAssertFalse(models.contains { $0.id == m.id })
        do { _ = try await api.lora(modelId: m.id); XCTFail() } catch let e as ApiError { XCTAssertEqual(e.code, "not_found") }
    }

    func testUpdateModel() async throws {
        let api = FakeMuseAPI(speed: 0)
        let m = try await api.updateModel(id: SampleData.sienna, UpdateModelRequest(personality: "dry", neverAdd: ["tattoos", " ", "necklaces"]))
        XCTAssertEqual(m.personality, "dry")
        XCTAssertEqual(m.neverAdd, ["tattoos", "necklaces"])
        XCTAssertEqual(m.name, "Sienna Vale")
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(UpdateModelRequest(notes: "n"))) as! [String: Any]
        XCTAssertEqual(Set(body.keys), ["notes"], "only the fields that are set are sent")
    }
}

final class SocialTests: XCTestCase {
    func testLabelsAreOffUnlessTheUserTurnsThemOn() throws {
        let req = CreatePostRequest(modelId: "m", takeId: "t", platforms: [.tiktok])
        XCTAssertFalse(req.aiLabel)
        XCTAssertFalse(req.paidPartnership)
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as! [String: Any]
        XCTAssertEqual(obj["aiLabel"] as? Bool, false)
        XCTAssertEqual(obj["paidPartnership"] as? Bool, false)
        XCTAssertEqual(obj["platforms"] as? [String], ["tiktok"])
        XCTAssertEqual(obj["when"] as? String, "now")
        // A post decoded without the fields has them off too.
        let p = try JSONDecoder().decode(Post.self, from: Data(#"{"id":"p1","platforms":["instagram","threads"]}"#.utf8))
        XCTAssertFalse(p.aiLabel)
        XCTAssertFalse(p.paidPartnership)
        XCTAssertEqual(p.platforms, [.instagram], "unknown platforms are skipped")
    }

    func testPlatformBadges() {
        XCTAssertEqual(Platform.allCases.map(\.badge), ["TT", "IG", "f", "YT", "X"])
        XCTAssertEqual(Platform.instagram.color, 0xD62976)
        XCTAssertFalse(Platform.x.hasAILabel)
        XCTAssertFalse(Platform.x.hasPaidLabel)
        XCTAssertTrue(Platform.youtube.hasAILabel)
    }

    func testConnectPostScheduleAndCancel() async throws {
        let api = FakeMuseAPI(speed: 0)
        let id = SampleData.sienna
        let take = try await api.listTakes().first!
        do {
            _ = try await api.createPost(CreatePostRequest(modelId: id, takeId: take.id, platforms: [.tiktok]))
            XCTFail("not connected")
        } catch let e as ApiError { XCTAssertEqual(e.code, "bad_request") }

        guard case .connected(let tt) = try await api.connectAccount(modelId: id, platform: .tiktok) else { return XCTFail() }
        XCTAssertEqual(tt.handle, "@sienna.vale")
        XCTAssertFalse(tt.canPostDirect, "stage 1")
        _ = try await api.connectAccount(modelId: id, platform: .youtube)
        _ = try await api.connectAccount(modelId: id, platform: .instagram)
        let accounts = try await api.listAccounts(modelId: id)
        XCTAssertEqual(accounts.map(\.platform), [.tiktok, .instagram, .youtube])
        try await api.disconnectAccount(modelId: id, platform: .instagram)
        let afterDisconnect = try await api.listAccounts(modelId: id)
        XCTAssertEqual(afterDisconnect.count, 2)

        let now = try await api.createPost(CreatePostRequest(modelId: id, takeId: take.id, platforms: [.tiktok, .youtube], caption: "hi #grwm"))
        XCTAssertEqual(now.state, "handoff")
        XCTAssertFalse(now.aiLabel)
        XCTAssertFalse(now.paidPartnership)
        XCTAssertNotNil(now.stats)

        let labelled = try await api.createPost(CreatePostRequest(modelId: id, takeId: take.id, platforms: [.tiktok], aiLabel: true, paidPartnership: true))
        XCTAssertTrue(labelled.aiLabel && labelled.paidPartnership, "kept exactly as the user set them")

        let at = Date().addingTimeInterval(3600)
        let later = try await api.createPost(CreatePostRequest(modelId: id, takeId: take.id, platforms: [.youtube], when: PostTime.string(at)))
        XCTAssertEqual(later.state, "scheduled")
        XCTAssertEqual(later.scheduledDate.map { Int($0.timeIntervalSince1970) }, Int(at.timeIntervalSince1970))
        let scheduled = try await api.listPosts(state: "scheduled")
        XCTAssertEqual(scheduled.map(\.id), [later.id])
        try await api.deletePost(id: later.id)
        let all = try await api.listPosts(state: nil)
        XCTAssertEqual(all.count, 2)
    }

    func testDecodesWireTypes() throws {
        let lora = """
        {"modelId":"m_sienna","version":1,"state":"review","use":true,"progress":0,"cost":0.6,
         "candidates":[{"id":"c1","image":{"asset":"g_front"},"label":"Green set · front","keep":true},
                       {"id":"c2","image":{"url":"/uploads/x.jpg"},"label":"Close-up","flag":"choker","keep":false}],
         "photo":{"state":"none","progress":0},"video":{"state":"none","progress":0}}
        """
        let l = try JSONDecoder().decode(Lora.self, from: Data(lora.utf8))
        XCTAssertEqual(l.kept, 1)
        XCTAssertEqual(l.flagged, 1)
        XCTAssertEqual(HTTPMuseAPI(baseURL: URL(string: "http://h:1")!).absolutize(l).candidates[1].image.url, "http://h:1/uploads/x.jpg")
        let sparse = try JSONDecoder().decode(Lora.self, from: Data(#"{"modelId":"m","state":"building"}"#.utf8))
        XCTAssertTrue(sparse.isBusy)
        XCTAssertEqual(sparse.photo.state, "none")

        let e = try JSONDecoder().decode(ApiEvent.self, from: Data(#"{"type":"post","post":{"id":"p","platforms":["x"],"state":"scheduled","when":"2026-11-05T19:30:00Z"}}"#.utf8))
        XCTAssertEqual(e.post?.platforms, [.x])
        XCTAssertNotNil(e.post?.scheduledDate)
        let le = try JSONDecoder().decode(ApiEvent.self, from: Data(#"{"type":"lora","lora":{"modelId":"m","state":"ready","version":2}}"#.utf8))
        XCTAssertEqual(le.lora?.activeVersion, 2)

        let acc = #"{"modelId":"m","platform":"tiktok","handle":"@s","connectedAt":1,"canPostDirect":false}"#
        XCTAssertEqual(try ConnectResult.decode(Data(acc.utf8)), .connected(Account(modelId: "m", platform: .tiktok, handle: "@s", connectedAt: 1)))
        XCTAssertEqual(try ConnectResult.decode(Data(#"{"account":\#(acc)}"#.utf8)), .connected(Account(modelId: "m", platform: .tiktok, handle: "@s", connectedAt: 1)))
        XCTAssertEqual(try ConnectResult.decode(Data(#"{"authUrl":"https://example.com/oauth"}"#.utf8)), .authorize(URL(string: "https://example.com/oauth")!))
        let b = try JSONDecoder().decode(Balance.self, from: Data(#"{"balance":5,"month":1,"today":0.5}"#.utf8))
        XCTAssertEqual(b.today, 0.5)
    }

    func testScheduleSuggestionsAndLabels() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        // Wednesday 2026-11-04 10:00 UTC.
        let now = Date(timeIntervalSince1970: 1_793_786_400)
        XCTAssertEqual(cal.component(.weekday, from: now), 4)
        let s = PostTime.suggestions(now: now, calendar: cal)
        XCTAssertEqual(s.map { PostTime.label($0, now: now, calendar: cal) }, ["Today · 7:30 PM", "Tomorrow · 12:00 PM", "Fri · 6:00 PM"])
        // After 7:30 PM, "today" moves to tomorrow evening.
        let late = now.addingTimeInterval(11 * 3600)
        XCTAssertEqual(PostTime.label(PostTime.suggestions(now: late, calendar: cal)[0], now: late, calendar: cal), "Tomorrow · 7:30 PM")
        XCTAssertEqual(PostTime.parse(PostTime.string(now)), now)
        XCTAssertNil(PostTime.parse("now"))
    }
}

import XCTest
@testable import MuseCore

/// Render (Draft / Standard / HD) and the add-ons (Edit, Fast · beta, Upscale): plans/api.md "App clean-up" §2 and "Pricing".
/// replicate_pricing_fixture.json is the shared fixture (android/core/src/test/resources/replicate_pricing_fixture.json).
final class ReplicateTests: XCTestCase {
    func testEveryReplicateFixtureRowMatches() throws {
        let rows = try XCTUnwrap(fixture("replicate_pricing_fixture") as? [[String: Any]])
        XCTAssertEqual(rows.count, 135)
        for o in rows {
            let q = try XCTUnwrap(VideoQuality(rawValue: o["quality"] as! String))
            let clip = o["clipSeconds"] as? Double
            let takes = o["takes"] as! Int
            let price = o["pricePerSec"] as! Double
            XCTAssertEqual(q.defaultPricePerSec, price)
            let spec = RenderSpec.replicate(q, clipSeconds: clip, takes: takes, pricePerSec: price)
            let ctx = "\(q) \(String(describing: clip)) ×\(takes)"
            XCTAssertEqual(Pricing.replicateSeconds(clip), o["seconds"] as! Int, ctx)
            XCTAssertEqual(spec.replicateSeconds, o["seconds"] as! Int, ctx)
            XCTAssertEqual(Pricing.totalCost(spec), o["cost"] as! Double, accuracy: 1e-12, ctx)
            XCTAssertEqual(Pricing.money(Pricing.totalCost(spec)), o["costLabel"] as! String, ctx)
            XCTAssertEqual(Pricing.priceLine(spec), o["priceLine"] as! String, ctx)
            XCTAssertEqual(Pricing.genLabel(spec), o["genLabel"] as! String, ctx)
            // The contract defaults give the same numbers without the server's price.
            XCTAssertEqual(Pricing.genLabel(RenderSpec.replicate(q, clipSeconds: clip, takes: takes)), o["genLabel"] as! String, ctx)
        }
    }

    func testSecondsRoundUpBetweenFourAndFifteen() {
        XCTAssertEqual(Pricing.replicateSeconds(7.0), 7)
        XCTAssertEqual(Pricing.replicateSeconds(7.04), 8)
        XCTAssertEqual(Pricing.replicateSeconds(2.5), 4)
        XCTAssertEqual(Pricing.replicateSeconds(14.97), 15)
        XCTAssertEqual(Pricing.replicateSeconds(22), 15)
        XCTAssertEqual(Pricing.replicateSeconds(nil), 10)
    }

    func testStandardSevenSecondsIsAbout56Cents() {
        let s = RenderSpec.replicate(.standard, clipSeconds: 7)
        XCTAssertEqual(Pricing.priceLine(s), "about $0.56 · 7 s")
        XCTAssertEqual(Pricing.genLabel(s), "Generate · 7 s · $0.56")
        var two = s
        two.takes = 2
        XCTAssertEqual(Pricing.priceLine(two), "about $1.12 · 7 s · 2 takes")
        XCTAssertEqual(Pricing.genLabel(two), "Generate · 7 s · $1.12 · 2 takes")
        XCTAssertEqual(Pricing.money(Pricing.totalCost(.replicate(.draft, clipSeconds: 7))), "$0.14")
        XCTAssertEqual(Pricing.money(Pricing.totalCost(.replicate(.hd, clipSeconds: 7))), "$0.91")
        // The server's price wins.
        XCTAssertEqual(Pricing.totalCost(.replicate(.standard, clipSeconds: 7, pricePerSec: 0.1)), 0.7, accuracy: 1e-12)
    }

    func testReplicateAlwaysRendersTheWholeClip() {
        var s = RenderSpec.replicate(.standard, clipSeconds: 12.3)
        s.use = .first
        XCTAssertEqual(s.lengthSec, 12.3)
        XCTAssertEqual(RenderSpec.replicate(.hd, clipSeconds: nil).lengthSec, 9.4)
        XCTAssertEqual(RenderSpec.replicate(.hd, clipSeconds: 20).lengthSec, 15)
    }

    func testEditAndFastAreWholeClipWithNoStepsOrMinutes() {
        let edit = RenderSpec.choice(.edit, clipSeconds: nil)
        XCTAssertEqual(edit.engine, .h3)
        XCTAssertEqual(edit.use, .full)
        XCTAssertEqual(edit.steps, Pricing.stepsDefault)
        XCTAssertEqual(edit.lengthSec, 9.4)
        XCTAssertEqual(edit.videoQuality, .edit)
        // The Exact edit formula with steps 10 and the whole clip; the line is just the price.
        XCTAssertEqual(Pricing.totalCost(edit), Pricing.totalCost(RenderSpec(engine: .h3, use: .full, steps: 10)), accuracy: 1e-12)
        XCTAssertEqual(Pricing.priceLine(edit), "about \(Pricing.money(Pricing.totalCost(edit)))")
        XCTAssertEqual(Pricing.genLabel(edit), "Generate · \(Pricing.fmtMin(Pricing.totalMin(edit))) · \(Pricing.money(Pricing.totalCost(edit)))")
        XCTAssertEqual(Pricing.genLabel(RenderSpec(engine: .h3, use: .first, steps: 10)), "Generate · 10 min · $0.67")
        XCTAssertFalse(Pricing.genLabel(edit).contains("step"))
        XCTAssertFalse(Pricing.priceLine(edit).contains("min"))
        let fast = RenderSpec.choice(.fast, clipSeconds: 5.2, takes: 2)
        XCTAssertEqual(fast.engine, .viggle)
        XCTAssertEqual(fast.use, .full)
        XCTAssertEqual(Pricing.priceLine(fast), "about $0.26 · 2 takes")
        XCTAssertEqual(fast.videoQuality, .fast)
        // Lip sync is Edit only.
        XCTAssertTrue(RenderSpec.choice(.edit, clipSeconds: 7, lipSync: true).lipSync)
        XCTAssertFalse(RenderSpec.choice(.fast, clipSeconds: 7, lipSync: true).lipSync)
        XCTAssertFalse(Engine.replicate.isAddOnEngine)
        XCTAssertTrue(Engine.h3.isAddOnEngine)
        XCTAssertEqual(Engine.h3.label, "Edit")
    }

    func testPickerOptionsAndRequests() {
        XCTAssertEqual(VideoQuality.renders.map(\.label), ["Draft", "Standard", "HD"])
        XCTAssertEqual(VideoQuality.addOns.map(\.label), ["Edit", "Fast · beta"])
        XCTAssertEqual(VideoQuality.draft.detail, "Quick preview · 768P")
        XCTAssertEqual(VideoQuality.default, .draft)
        XCTAssertEqual(VideoQuality.edit.engine, .h3)
        XCTAssertEqual(VideoQuality.fast.engine, .viggle)
        XCTAssertNil(VideoQuality.edit.requestQuality)
        XCTAssertEqual(VideoQuality(id: "exact"), .edit, "older servers and saved settings")
        let r = JobRequest.replicate(title: "t", modelId: "m", outfitId: "o", clipId: "c", quality: .hd, takes: 2, clipSeconds: 7)
        XCTAssertEqual(r.engine, "replicate")
        XCTAssertEqual(r.quality, "hd")
        XCTAssertEqual(r.use, "full")
        XCTAssertFalse(r.lipSync)
        XCTAssertEqual(r.videoQuality, .hd)
        XCTAssertEqual(Pricing.genLabel(r.spec), "Generate · 7 s · $1.82 · 2 takes")
        XCTAssertEqual(Job.engineLabel(for: r), "HD · 2K")
        XCTAssertEqual(Job.engineLabel(for: JobRequest(title: "", modelId: "", outfitId: "", clipId: "", steps: 12)), "Edit")
        XCTAssertEqual(Job.engineLabel(for: JobRequest(title: "", modelId: "", outfitId: "", clipId: "", engine: "viggle")), "Fast · beta")
        XCTAssertEqual(VideoQuality.of(engine: .replicate, quality: nil), .draft)
        XCTAssertEqual(VideoQuality(id: nil), .draft)
        XCTAssertEqual(VideoQuality(id: "bogus"), .draft)
        XCTAssertEqual(RenderSpec(engine: .replicate).quality, .draft)
        XCTAssertEqual(VideoQuality.of(engine: .viggle, quality: "hd"), .fast)
        XCTAssertEqual(VideoQuality.of(engine: .h3, quality: nil), .edit)
        // Edit: {engine: "h3", use: "full", steps: 10}; Fast · beta: {engine: "viggle", use: "full"}.
        let e = JobRequest.addOn(.edit, title: "t", modelId: "m", outfitId: "o", clipId: "c", lipSync: true, background: "photo", clipSeconds: 7)
        XCTAssertEqual(e.engine, "h3")
        XCTAssertEqual(e.use, "full")
        XCTAssertEqual(e.steps, 10)
        XCTAssertTrue(e.lipSync)
        XCTAssertEqual(e.background, "photo")
        XCTAssertNil(e.quality)
        let f = JobRequest.addOn(.fast, title: "t", modelId: "m", outfitId: "o", clipId: "c", lipSync: true, background: "photo")
        XCTAssertEqual(f.engine, "viggle")
        XCTAssertEqual(f.use, "full")
        XCTAssertFalse(f.lipSync)
        XCTAssertEqual(f.background, "keep")
        XCTAssertEqual(f.videoQuality, .fast)
    }

    func testRequestJSONSendsQualityOnlyForReplicate() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let r = JobRequest.replicate(title: "t", modelId: "m", outfitId: "o", clipId: "c", quality: .draft)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: enc.encode(r)) as? [String: Any])
        XCTAssertEqual(obj["engine"] as? String, "replicate")
        XCTAssertEqual(obj["quality"] as? String, "draft")
        let h3 = JobRequest(title: "t", modelId: "m", outfitId: "o", clipId: "c")
        let o2 = try XCTUnwrap(JSONSerialization.jsonObject(with: enc.encode(h3)) as? [String: Any])
        XCTAssertNil(o2["quality"])
        XCTAssertEqual(o2["engine"] as? String, "h3")
    }

    func testDecodesVideoFeatures() throws {
        let json = #"{"features":{"standard":true,"fastBeta":false,"lipSync":true,"loraTraining":true,"replaceAudio":false,"maxClipSec":15,"replicate":true,"video":{"defaultEngine":"replicate","defaultQuality":"standard","minSeconds":4,"maxSeconds":15,"options":[{"id":"draft","label":"Draft","detail":"Quick preview · 768P","engine":"replicate","quality":"draft","resolution":"768P","pricePerSec":0.03,"available":true},{"id":"standard","label":"Standard","detail":"768P","engine":"replicate","quality":"standard","resolution":"768P","pricePerSec":0.08,"available":true},{"id":"hd","label":"HD","detail":"2K","engine":"replicate","quality":"hd","resolution":"2K","pricePerSec":0.13,"available":true}],"addons":[{"id":"edit","label":"Edit","detail":"Swaps her into every frame of the whole clip","available":true,"sends":{"engine":"h3","use":"full","steps":10}},{"id":"fast","label":"Fast · beta","detail":"Quicker and rougher · beta","available":false,"sends":{"engine":"viggle","use":"full"}},{"id":"upscale","label":"Upscale","detail":"Sharper 1080p, 2K or 4K from a finished take","available":false,"comingSoon":true,"sizes":[{"id":"1080p","label":"1080p","width":1080,"height":1920,"available":false,"price":null},{"id":"2k","label":"2K","width":1440,"height":2560,"available":false,"price":null},{"id":"4k","label":"4K","width":2160,"height":3840,"available":false,"price":null}]}]}}}"#
        let s = try JSONDecoder().decode(StudioSettings.self, from: Data(json.utf8))
        XCTAssertTrue(s.features.replicate)
        let v = try XCTUnwrap(s.features.video)
        XCTAssertEqual(v.ordered.map(\.id), ["draft", "standard", "hd"])
        XCTAssertEqual(v.pricePerSec(.draft), 0.03)
        XCTAssertNil(v.pricePerSec(.edit))
        XCTAssertTrue(v.isAvailable(.edit))
        XCTAssertFalse(v.isAvailable(.fast))
        XCTAssertEqual(v.shownAddons.map(\.id), ["edit", "upscale"], "Fast · beta shows only when available")
        let up = try XCTUnwrap(v.upscale)
        XCTAssertTrue(up.comingSoon)
        XCTAssertFalse(up.available)
        XCTAssertEqual(up.sizes.map(\.sizeLine), ["1080×1920", "1440×2560", "2160×3840"])
        XCTAssertTrue(up.sizes.allSatisfy { !$0.available && $0.price == nil })
        XCTAssertNil(up.videoQuality)
        XCTAssertEqual(v.defaultOption, .standard)
        XCTAssertEqual(VideoFeatures(defaultEngine: "h3").defaultOption, .edit)
        // Older servers: no video block → the contract's table, everything available but Upscale.
        let old = try JSONDecoder().decode(StudioSettings.self, from: Data(#"{"features":{"standard":true}}"#.utf8))
        XCTAssertNil(old.features.video)
        XCTAssertFalse(old.features.replicate)
        XCTAssertEqual(VideoFeatures.fallback.ordered.map(\.label), ["Draft", "Standard", "HD"])
        XCTAssertEqual(VideoFeatures.fallback.shownAddons.map(\.label), ["Edit", "Fast · beta", "Upscale"])
        XCTAssertTrue(VideoQuality.allCases.allSatisfy { VideoFeatures.fallback.isAvailable($0) })
        XCTAssertEqual(VideoFeatures.fallback.upscale?.comingSoon, true)
        XCTAssertEqual(VideoFeatures.fallback.defaultQuality, "draft")
        XCTAssertEqual(VideoFeatures.fallback.defaultOption, .draft)
        // The pre-clean-up shape (Exact edit among the options, an engine detail line): Edit takes its availability,
        // and the technical detail is replaced by the app's own.
        let before = try JSONDecoder().decode(VideoFeatures.self, from: Data(#"{"defaultEngine":"replicate","options":[{"id":"draft","label":"Draft","detail":"768P · lite","available":true},{"id":"exact","label":"Exact edit","detail":"Frame-by-frame · slower · GPU start-up","engine":"h3","available":false}]}"#.utf8))
        XCTAssertEqual(before.ordered.map(\.id), ["draft", "standard", "hd"])
        XCTAssertFalse(before.isAvailable(.edit))
        XCTAssertEqual(before.option(.draft).shownDetail, "Quick preview · 768P")
        // A video block without defaultQuality also means Draft.
        let sparse = try JSONDecoder().decode(VideoFeatures.self, from: Data(#"{"defaultEngine":"replicate"}"#.utf8))
        XCTAssertEqual(sparse.defaultOption, .draft)
        XCTAssertEqual(sparse.ordered.map(\.id), ["draft", "standard", "hd"])
        XCTAssertEqual(VideoFeatures.fallback.pricePerSec(.hd), 0.13)
    }

    func testDecodesJobsAndMemberSafeErrors() throws {
        let json = #"{"id":"j1","state":"failed","request":{"title":"Dance","modelId":"m","outfitId":"o","clipId":"c","engine":"replicate","quality":"hd","use":"full","takes":1,"clipSeconds":7},"engineLabel":"HD · 2K","errorCode":"provider_refused","error":"This clip was refused by the content filter · you weren't charged","refunded":0.91,"blocked":"owner_balance_low"}"#
        let j = try JSONDecoder().decode(Job.self, from: Data(json.utf8))
        XCTAssertEqual(j.engine, .replicate)
        XCTAssertEqual(j.videoQuality, .hd)
        XCTAssertEqual(j.engineLabel, "HD · 2K")
        XCTAssertEqual(j.engineName, "HD")
        XCTAssertTrue(j.isRefused)
        XCTAssertFalse(j.isWaiting, "blocked is ignored: nothing pauses on a provider balance")
        XCTAssertEqual(j.failureLine, "This clip was refused by the content filter · you weren't charged")
        let done = try JSONDecoder().decode(Job.self, from: Data(#"{"id":"j2","state":"done","request":{"engine":"replicate"},"billedSeconds":14}"#.utf8))
        XCTAssertEqual(done.billedSeconds, 14)
        XCTAssertEqual(done.engineLabel, "Draft · 768P") // no quality = the default, Draft
        XCTAssertEqual(done.engineName, "Draft")
        XCTAssertEqual(done.videoQuality, .draft)
        var waiting = done
        waiting.state = "running"
        waiting.step = 0
        waiting.queuePosition = 2
        waiting.etaSeconds = 200
        waiting.cost = 0.14
        XCTAssertEqual(waiting.waitLine, "#2 in line · about 3 min")
        XCTAssertEqual(waiting.progressLine, "#2 in line · about 3 min · $0.14")
        waiting.etaSeconds = 540
        XCTAssertEqual(waiting.progressLine, "#2 in line · about 9 min · $0.14")
        waiting.queuePosition = 1
        waiting.etaSeconds = nil
        waiting.secondsLeft = 0
        XCTAssertEqual(waiting.waitLine, "Waiting to start")
        XCTAssertEqual(waiting.progressLine, "Waiting to start · $0.14")
        // Older servers' technical wording is replaced by the contract's.
        let gpu = try JSONDecoder().decode(Job.self, from: Data(#"{"id":"j3","state":"failed","error":"The GPU disconnected at step 3.","phase":"Failed at step 3","engineLabel":"Exact edit · 10 steps","request":{"engine":"h3","steps":10}}"#.utf8))
        XCTAssertEqual(gpu.failureLine, "Something went wrong · you weren't charged")
        XCTAssertEqual(gpu.engineLabel, "Edit")
        XCTAssertEqual(gpu.statusLine, "Failed")
        let old = try JSONDecoder().decode(Job.self, from: Data(#"{"id":"j4","state":"failed","errorCode":"provider_refused","error":"Replicate's safety filter refused this clip"}"#.utf8))
        XCTAssertEqual(old.failureLine, "This clip was refused by the content filter · you weren't charged")
        for (code, text) in [("provider_timeout", "This took too long and was stopped · you weren't charged"),
                             ("provider_rate_limited", "Busy right now · you weren't charged. Try again in a minute."),
                             ("provider_out_of_credit", "Something went wrong · you weren't charged. The studio owner has been told."),
                             ("provider_failed", "Something went wrong · you weren't charged")] {
            XCTAssertEqual(Job.defaultFailure(code), text, code)
        }
        XCTAssertEqual(ApiError("provider_refused", "Replicate's safety filter refused this photo").friendlyMessage,
                       "This photo was refused by the content filter · you weren't charged")
        XCTAssertEqual(ApiError("provider_rate_limited", "x").friendlyMessage, "Busy right now · you weren't charged. Try again in a minute.")
        XCTAssertEqual(ApiError("provider_out_of_credit", "x").friendlyMessage, "Something went wrong · you weren't charged. The studio owner has been told.")
        XCTAssertEqual(ApiError("upscale_unavailable", "x").friendlyMessage, "Upscale is coming soon")
        XCTAssertEqual(ApiError("engine_unavailable", "Edit isn't available right now").friendlyMessage, "Edit isn't available right now")
        XCTAssertEqual(ApiError("engine_unavailable", "The GPU image can't run this yet").friendlyMessage, "Something went wrong · you weren't charged")
    }

    func testRunningLineShowsPhaseAndPrice() throws {
        var j = try JSONDecoder().decode(Job.self, from: Data(#"{"id":"j5","state":"running","step":3,"cost":0.14,"secondsLeft":118,"phase":"Rendering · ~2 min left","request":{"engine":"replicate"}}"#.utf8))
        XCTAssertEqual(j.progressLine, "Rendering · about 2 min · $0.14")
        j.phase = "take 2/3 · Rendering · ~2 min left"
        XCTAssertEqual(j.progressLine, "take 2/3 · Rendering · about 2 min · $0.14")
        j.phase = "step 3/10 · ~6 min left"
        XCTAssertEqual(j.progressLine, "Rendering · about 2 min · $0.14", "an older server's steps phase reads Rendering")
        j.phase = "Rendering on Replicate · ~2 min left"
        XCTAssertEqual(j.progressLine, "Rendering · about 2 min · $0.14")
        j.phase = "Starting GPU · ~4 min left"
        XCTAssertEqual(j.statusLine, "Getting ready")
        j.phase = "Paused: the studio's GPU credit is low"
        XCTAssertEqual(j.statusLine, "Waiting to start")
        j.phase = "Finishing · exact length and audio"
        XCTAssertEqual(j.statusLine, "Finishing")
        j.secondsLeft = 30
        j.phase = "Lip sync · ~1 min left"
        XCTAssertEqual(j.progressLine, "Lip sync · about a minute · $0.14")
        XCTAssertEqual(Job.aboutTime(150), "3 min")
    }

    func testTakeLabelsForMembers() throws {
        let old = try JSONDecoder().decode(Take.self, from: Data(#"{"id":"t1","kind":"take","title":"Dance","label":"10 steps","engineLabel":"Exact edit · 10 steps","videoUrl":"https://x/y.mp4"}"#.utf8))
        XCTAssertEqual(old.caption, "Dance · Edit")
        XCTAssertEqual(old.displayEngineLabel, "Edit")
        XCTAssertTrue(old.canUpscale)
        let shot = try JSONDecoder().decode(Take.self, from: Data(#"{"id":"s1","kind":"shot","title":"Shoot","index":2,"label":"Shoot","engineLabel":"FLUX.2 [pro] · Replicate","cost":0.11711}"#.utf8))
        XCTAssertEqual(shot.displayEngineLabel, "", "the engine is never shown on a photo")
        XCTAssertFalse(shot.canUpscale)
        let draft = try JSONDecoder().decode(Take.self, from: Data(#"{"id":"t2","kind":"take","title":"Dance","label":"Draft","engineLabel":"Draft · 768P"}"#.utf8))
        XCTAssertEqual(draft.caption, "Dance · Draft")
        XCTAssertFalse(draft.canUpscale, "no video yet")
    }

    func testImageEngineLabel() throws {
        let e = try JSONDecoder().decode(ImageEngine.self, from: Data(#"{"provider":"replicate","model":"black-forest-labs/flux-2-pro","editModel":"qwen/qwen-image-edit-2511","label":"FLUX.2 [pro] · Replicate","available":{"replicate":true}}"#.utf8))
        XCTAssertEqual(e.displayLabel, "FLUX.2 [pro] · Replicate")
        XCTAssertEqual(e.editModel, "qwen/qwen-image-edit-2511")
        XCTAssertTrue(e.isAvailable("replicate"))
        XCTAssertEqual(ImageEngine(provider: "fal", model: "seedream").displayLabel, "fal.ai · seedream")
        XCTAssertEqual(ImageEngine.providers.first?.id, "replicate")
    }

    func testReplicateProgressCountsTakes() {
        let r = JobRequest.replicate(title: "t", modelId: "m", outfitId: "o", clipId: "c", quality: .standard, takes: 2, clipSeconds: 7)
        let total = Pricing.totalSeconds(r.spec)
        XCTAssertEqual(JobClock.progress(r, elapsed: 0).phase, "Preparing the clip")
        XCTAssertEqual(JobClock.progress(r, elapsed: 0).totalSteps, 2)
        let mid = JobClock.progress(r, elapsed: total * 0.75)
        XCTAssertEqual(mid.take, 2)
        XCTAssertEqual(mid.step, 1)
        XCTAssertTrue(mid.phase.hasPrefix("take 2/2 · Rendering · "), mid.phase)
        XCTAssertEqual(JobClock.progress(r, elapsed: total * 0.97).phase, "take 2/2 · Finishing")
        XCTAssertEqual(JobClock.progress(r, elapsed: total).step, 2)
        for f in stride(from: 0.0, through: 1.0, by: 0.05) {
            XCTAssertTrue(MemberText.isSafe(JobClock.progress(r, elapsed: total * f).phase))
        }
    }

    func testDemoBackendRunsReplicateJobs() async throws {
        let api: any MuseAPI = FakeMuseAPI(speed: 0)
        let clip = try await api.uploadClip(SampleData.sampleMeta, file: nil)
        var lip = JobRequest.replicate(title: "t", modelId: SampleData.sienna, outfitId: SampleData.green, clipId: clip.id, quality: .standard)
        lip.lipSync = true
        do {
            _ = try await api.createJob(lip)
            XCTFail("lip sync is Edit only")
        } catch let e as ApiError { XCTAssertEqual(e.code, "bad_request") }
        var req = JobRequest.replicate(title: "t", modelId: SampleData.sienna, outfitId: SampleData.green, clipId: clip.id, quality: .standard, clipSeconds: clip.durationSec)
        req.use = "first"
        let j = try await api.createJob(req)
        XCTAssertEqual(j.request.use, "full")
        XCTAssertEqual(j.engineLabel, "Standard · 768P")
        XCTAssertEqual(j.cost, 0.8, accuracy: 1e-9) // 9.4 s → 10 s × $0.08
        let s = try await api.studioSettings()
        XCTAssertTrue(s.features.replicate)
        XCTAssertEqual(s.features.video?.defaultOption, .draft)
        // A replicate request without quality is Draft: 9.4 s → 10 s × $0.02.
        var noQuality = JobRequest.replicate(title: "t", modelId: SampleData.sienna, outfitId: SampleData.green, clipId: clip.id, quality: .hd, clipSeconds: clip.durationSec)
        noQuality.quality = nil
        let d = try await api.createJob(noQuality)
        XCTAssertEqual(d.request.quality, "draft")
        XCTAssertEqual(d.engineLabel, "Draft · 768P")
        XCTAssertEqual(d.cost, 0.2, accuracy: 1e-9)
    }
}

import XCTest
@testable import MuseCore

/// Draft / Standard / HD on Replicate and the Quality picker (plans/api.md "Video engines and quality", "Pricing").
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

    func testExactEditKeepsTheGpuFormula() {
        let exact = RenderSpec(engine: .h3, use: .first, steps: 10)
        XCTAssertEqual(Pricing.genLabel(exact), "Generate · 10 min · $0.67")
        XCTAssertEqual(Pricing.priceLine(exact), "about $0.67 · 10 min")
        XCTAssertEqual(exact.videoQuality, .exact)
        XCTAssertFalse(Engine.replicate.usesOurGpu)
        XCTAssertTrue(Engine.h3.usesOurGpu)
    }

    func testPickerOptionsAndRequests() {
        XCTAssertEqual(VideoQuality.allCases.map(\.label), ["Draft", "Standard", "HD", "Exact edit"])
        XCTAssertEqual(VideoQuality.default, .draft)
        XCTAssertEqual(VideoQuality.exact.engine, .h3)
        XCTAssertNil(VideoQuality.exact.requestQuality)
        let r = JobRequest.replicate(title: "t", modelId: "m", outfitId: "o", clipId: "c", quality: .hd, takes: 2, clipSeconds: 7)
        XCTAssertEqual(r.engine, "replicate")
        XCTAssertEqual(r.quality, "hd")
        XCTAssertEqual(r.use, "full")
        XCTAssertFalse(r.lipSync)
        XCTAssertEqual(r.videoQuality, .hd)
        XCTAssertEqual(Pricing.genLabel(r.spec), "Generate · 7 s · $1.82 · 2 takes")
        XCTAssertEqual(Job.engineLabel(for: r), "HD · 2K")
        XCTAssertEqual(Job.engineLabel(for: JobRequest(title: "", modelId: "", outfitId: "", clipId: "", steps: 12)), "Exact edit · 12 steps")
        XCTAssertEqual(VideoQuality.of(engine: .replicate, quality: nil), .draft)
        XCTAssertEqual(VideoQuality(id: nil), .draft)
        XCTAssertEqual(VideoQuality(id: "bogus"), .draft)
        XCTAssertEqual(RenderSpec(engine: .replicate).quality, .draft)
        XCTAssertEqual(VideoQuality.of(engine: .viggle, quality: "hd"), .exact)
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
        let json = #"{"features":{"standard":true,"fastBeta":false,"lipSync":true,"loraTraining":true,"replaceAudio":false,"maxClipSec":15,"replicate":true,"video":{"defaultEngine":"replicate","defaultQuality":"standard","minSeconds":4,"maxSeconds":15,"options":[{"id":"draft","label":"Draft","detail":"768P · lite","engine":"replicate","quality":"draft","resolution":"768P","pricePerSec":0.03,"available":true},{"id":"standard","label":"Standard","detail":"768P","engine":"replicate","quality":"standard","resolution":"768P","pricePerSec":0.08,"available":true},{"id":"hd","label":"HD","detail":"2K","engine":"replicate","quality":"hd","resolution":"2K","pricePerSec":0.13,"available":true},{"id":"exact","label":"Exact edit","detail":"Frame-by-frame · slower · GPU start-up","engine":"h3","available":false}]}}}"#
        let s = try JSONDecoder().decode(StudioSettings.self, from: Data(json.utf8))
        XCTAssertTrue(s.features.replicate)
        let v = try XCTUnwrap(s.features.video)
        XCTAssertEqual(v.ordered.map(\.id), ["draft", "standard", "hd", "exact"])
        XCTAssertEqual(v.pricePerSec(.draft), 0.03)
        XCTAssertNil(v.pricePerSec(.exact))
        XCTAssertFalse(v.isAvailable(.exact))
        XCTAssertEqual(v.defaultOption, .standard)
        XCTAssertEqual(VideoFeatures(defaultEngine: "h3").defaultOption, .exact)
        // Older servers: no video block → the contract's table, all available.
        let old = try JSONDecoder().decode(StudioSettings.self, from: Data(#"{"features":{"standard":true}}"#.utf8))
        XCTAssertNil(old.features.video)
        XCTAssertFalse(old.features.replicate)
        XCTAssertEqual(VideoFeatures.fallback.ordered.map(\.label), ["Draft", "Standard", "HD", "Exact edit"])
        XCTAssertTrue(VideoQuality.allCases.allSatisfy { VideoFeatures.fallback.isAvailable($0) })
        XCTAssertEqual(VideoFeatures.fallback.defaultQuality, "draft")
        XCTAssertEqual(VideoFeatures.fallback.defaultOption, .draft)
        // A video block without defaultQuality also means Draft.
        let sparse = try JSONDecoder().decode(VideoFeatures.self, from: Data(#"{"defaultEngine":"replicate"}"#.utf8))
        XCTAssertEqual(sparse.defaultOption, .draft)
        XCTAssertEqual(sparse.ordered.map(\.id), ["draft", "standard", "hd", "exact"])
        XCTAssertEqual(VideoFeatures.fallback.pricePerSec(.hd), 0.13)
    }

    func testDecodesReplicateJobsAndErrors() throws {
        let json = #"{"id":"j1","state":"failed","request":{"title":"Dance","modelId":"m","outfitId":"o","clipId":"c","engine":"replicate","quality":"hd","use":"full","takes":1,"clipSeconds":7},"engineLabel":"HD · 2K","errorCode":"provider_refused","error":"Replicate's safety filter refused this clip","refunded":0.91,"blocked":"owner_balance_low"}"#
        let j = try JSONDecoder().decode(Job.self, from: Data(json.utf8))
        XCTAssertEqual(j.engine, .replicate)
        XCTAssertEqual(j.videoQuality, .hd)
        XCTAssertEqual(j.engineLabel, "HD · 2K")
        XCTAssertEqual(j.engineName, "HD")
        XCTAssertTrue(j.isRefused)
        XCTAssertFalse(j.isPaused)
        XCTAssertEqual(j.failureLine, "Replicate's safety filter refused this clip. Try another clip or outfit, or Exact edit.")
        let done = try JSONDecoder().decode(Job.self, from: Data(#"{"id":"j2","state":"done","request":{"engine":"replicate"},"billedSeconds":14}"#.utf8))
        XCTAssertEqual(done.billedSeconds, 14)
        XCTAssertEqual(done.engineLabel, "Draft · 768P") // no quality = the default, Draft
        XCTAssertEqual(done.engineName, "Draft")
        XCTAssertEqual(done.videoQuality, .draft)
        var waiting = done
        waiting.state = "running"
        waiting.queuePosition = 2
        waiting.etaSeconds = 200
        XCTAssertEqual(waiting.waitLine, "#2 in the Replicate line · done in ~4 min")
        let gpu = try JSONDecoder().decode(Job.self, from: Data(#"{"id":"j3","state":"failed","error":"The GPU disconnected at step 3."}"#.utf8))
        XCTAssertEqual(gpu.failureLine, "The GPU disconnected at step 3.")
        XCTAssertEqual(ApiError("provider_refused", "Replicate's safety filter refused this photo").friendlyMessage,
                       "Replicate's safety filter refused this photo. Try other references or wording. You weren't charged.")
        XCTAssertEqual(ApiError("provider_rate_limited", "x").friendlyMessage, "Replicate is busy right now. Try again in a minute. You weren't charged.")
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
        XCTAssertTrue(mid.phase.hasPrefix("take 2/2 · Rendering on Replicate"), mid.phase)
        XCTAssertEqual(JobClock.progress(r, elapsed: total).step, 2)
    }

    func testDemoBackendRunsReplicateJobs() async throws {
        let api: any MuseAPI = FakeMuseAPI(speed: 0)
        let clip = try await api.uploadClip(SampleData.sampleMeta, file: nil)
        var lip = JobRequest.replicate(title: "t", modelId: SampleData.sienna, outfitId: SampleData.green, clipId: clip.id, quality: .standard)
        lip.lipSync = true
        do {
            _ = try await api.createJob(lip)
            XCTFail("lip sync is Exact edit only")
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

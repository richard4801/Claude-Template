import XCTest
@testable import MuseCore

/// "Recreate this edit": the Mac's mirror of workstream 1's `muse.recipe/1`, decoded from the server's own fixture
/// (server/api/test/fixtures/recipe-v1.json, copied to Fixtures/recreate).
final class RecreateTests: XCTestCase {
    private func fixture() throws -> RecreateReference {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "recipe-v1", withExtension: "json", subdirectory: "Fixtures/recreate"))
        return try JSONDecoder().decode(RecreateReference.self, from: Data(contentsOf: url))
    }

    func testDecodesTheServerFixture() throws {
        let ref = try fixture()
        XCTAssertEqual(ref.id, "rx_example")
        XCTAssertTrue(ref.isReady)
        XCTAssertNotNil(ref.videoUrl)
        XCTAssertNotNil(ref.posterUrl)
        let r = try XCTUnwrap(ref.recipe)
        XCTAssertEqual(r.schema, "muse.recipe/1")
        XCTAssertEqual(r.slots.count, 3)
        XCTAssertEqual(r.transitions.map(\.kind), ["cut", "crossfade", "flash"])
        XCTAssertEqual(r.text.first?.words, "SUMMER")
        XCTAssertEqual(r.text.first?.fontId, "sans")
        XCTAssertEqual(r.grade?.look?.id, "teal_orange")
        XCTAssertEqual(r.sound?.bpm ?? 0, 120.1, accuracy: 0.001)
        XCTAssertEqual(r.tags, ["example"])
        XCTAssertNotNil(r.summary)
        XCTAssertEqual(r.contactSheet?.tiles?.count, 3)
        XCTAssertEqual(r.slots.first?.rig?.moves?.first?.id, "pan_right")
        XCTAssertNotNil(r.slots.first?.thumbUrl)
    }

    func testSlotsCarryPoseCameraAndSpeed() throws {
        let r = try XCTUnwrap(try fixture().recipe)
        let s2 = r.slots[1]
        XCTAssertEqual(s2.pose?.status, "done")
        XCTAssertEqual(s2.pose?.keypoints?.count, 17)
        XCTAssertEqual(s2.camera?.motion, "zoom_in")
        XCTAssertEqual(RecreateText.camera(s2.camera?.motion), "Push in")
        XCTAssertFalse(s2.speed?.curve?.isEmpty ?? true)
        XCTAssertGreaterThan(s2.length, 0)
        XCTAssertGreaterThanOrEqual(r.durationSec, r.slots.last?.endSec ?? 0)
    }

    func testAnalyzingReferenceAndUnknownFieldsDecode() throws {
        // A reference still being analysed has no recipe; a newer server's extra fields are ignored.
        let json = #"{"id":"rx_1","state":"analyzing","progress":40,"phase":"cuts","somethingNew":{"a":1}}"#
        let ref = try JSONDecoder().decode(RecreateReference.self, from: Data(json.utf8))
        XCTAssertTrue(ref.isAnalyzing)
        XCTAssertNil(ref.recipe)
        XCTAssertEqual(ref.progress, 40)
        let minimal = #"{"id":"rx_2","state":"ready","recipe":{"slots":[{"id":"s1","startSec":0,"endSec":1.5}],"gaps":[{"key":"transition:unknown@1.5","what":"transition","atSec":1.5}]}}"#
        let r = try XCTUnwrap(try JSONDecoder().decode(RecreateReference.self, from: Data(minimal.utf8)).recipe)
        XCTAssertEqual(r.slots.first?.length, 1.5)
        XCTAssertTrue(r.text.isEmpty)
        XCTAssertEqual(r.gaps.first?.key, "transition:unknown@1.5")
    }

    func testFillAndMatch() throws {
        let json = #"""
        {"referenceId":"rx_1","slots":[
          {"slotId":"s1","state":"matched","takeId":"t1","score":0.82,"reason":"Same push-in on a close-up"},
          {"slotId":"s2","state":"to_generate","estimate":{"amount":0.64,"label":"$0.64"}},
          {"slotId":"s3","state":"to_generate","estimate":{"amount":1.2,"label":"$1.20"}}],
         "match":{"overall":0.91,"cuts":0.97,"text":0.88,"ramps":0.8,"grade":0.85,"shots":0.9,"perSlot":[{"slotId":"s1","score":0.93}]}}
        """#
        let fill = try JSONDecoder().decode(RecreateFill.self, from: Data(json.utf8))
        XCTAssertEqual(fill.slots.count, 3)
        XCTAssertEqual(fill.toGenerateTotal, 1.84, accuracy: 1e-9)
        XCTAssertEqual(RecreateText.fill(fill.slots[0].state), "From your takes")
        XCTAssertEqual(RecreateText.percent(fill.match?.overall), "91%")
        XCTAssertEqual(fill.match?.perSlot?.first?.score, 0.93)
    }

    func testPlainWords() {
        XCTAssertEqual(RecreateText.time(1.5), "0:01.5")
        XCTAssertEqual(RecreateText.time(75.3), "1:15.3")
        XCTAssertEqual(RecreateText.transition("unknown"), "Not recognised")
        XCTAssertEqual(RecreateText.speed("speed_up"), "Speeds up")
        XCTAssertNil(RecreateText.speed("none"))
        XCTAssertEqual(RecreateText.percent(nil), "–")
    }

    func testDemoFakeServesTheFixtureAndAFill() async throws {
        let api = FakeRecreateAPI()
        let list = try await api.listReferences()
        XCTAssertEqual(list.count, 1)
        let ref = try XCTUnwrap(list.first)
        XCTAssertTrue(ref.isReady)
        XCTAssertNil(ref.videoUrl, "demo mode has no media links")
        XCTAssertEqual(ref.recipe?.slots.count, 3)
        let fill = try await api.fill(ref.id)
        XCTAssertEqual(fill.slots.map(\.state), ["matched", "to_generate", "to_generate"])
        XCTAssertEqual(fill.toGenerateTotal, 1.28, accuracy: 1e-9)
        let applied = try await api.apply(ref.id, RecreateApplyRequest(sessionId: "es_1", baseRevision: 3, slots: ["s1": "t1"]))
        XCTAssertEqual(applied.revision, 4)
        XCTAssertNotNil(applied.match?.overall)
        let kept = try await api.patchReference(ref.id, keep: true, name: "Mine")
        XCTAssertEqual(kept.keep, true)
        XCTAssertEqual(kept.name, "Mine")
        try await api.deleteReference(ref.id)
        let after = try await api.listReferences()
        XCTAssertTrue(after.isEmpty)
    }

    func testReferenceIdsAreChecked() {
        XCTAssertNoThrow(try RecreateIds.check("rx_example"))
        XCTAssertThrowsError(try RecreateIds.check("../v1/admin"))
        XCTAssertThrowsError(try RecreateIds.check("cs_123"))
    }
    /// Owner note 1: the Look swatches are never garish. The fixture's palette has pure green and yellow.
    func testLookSwatchesAreSoftened() throws {
        let raw = try XCTUnwrap(try fixture().recipe?.grade?.swatches)
        XCTAssertTrue(raw.contains { RecreateSwatches.saturation($0) > 0.9 }, "the fixture has a garish colour to soften")
        let shown = RecreateSwatches.soften(raw)
        XCTAssertTrue((3...5).contains(shown.count), "\(shown)")
        let lum = shown.map(RecreateSwatches.luminance)
        XCTAssertEqual(lum, lum.sorted(), "ordered by tone, dark to light")
        for h in shown {
            XCTAssertLessThanOrEqual(RecreateSwatches.saturation(h), RecreateSwatches.maxSaturation, h)
            let v = try XCTUnwrap(RecreateSwatches.rgb(h).map { RecreateSwatches.toHSB($0).v })
            XCTAssertGreaterThanOrEqual(v, RecreateSwatches.brightness.lowerBound - 0.01, h)
            XCTAssertLessThanOrEqual(v, RecreateSwatches.brightness.upperBound + 0.01, h)
        }
        // Hue is kept: the pure green stays a green.
        XCTAssertTrue(shown.contains { h in RecreateSwatches.rgb(h).map { $0.g > $0.r && $0.g > $0.b } ?? false })
        // Short and long palettes still give 3–5; nothing readable gives none.
        XCTAssertEqual(RecreateSwatches.soften(["#00FF00"]).count, 3)
        XCTAssertEqual(RecreateSwatches.soften((0..<8).map { String(format: "#%02X%02X%02X", $0 * 30, 255 - $0 * 30, 128) }).count, 5)
        XCTAssertTrue(RecreateSwatches.soften(["nope"]).isEmpty)
    }

    /// Owner note 2: the total before Build comes from the fill.
    func testMakingLineComesFromTheFill() async throws {
        let api = FakeRecreateAPI()
        let list = try await api.listReferences()
        let ref = try XCTUnwrap(list.first)
        let fill = try await api.fill(ref.id)
        XCTAssertEqual(RecreateText.makingLine(fill), "1 from your takes, 2 to generate · $1.28 in all. You approve before anything is made.")
        XCTAssertEqual(RecreateText.brief(ref.recipe?.slots[1].brief), "Close-up · eye level · flips her hair")
        XCTAssertEqual(RecreateText.analysisStep(phase: "Reading the text", state: "analyzing"), 2)
        XCTAssertEqual(RecreateText.analysisStep(phase: "Waiting", state: "analyzing"), -1)
        XCTAssertEqual(RecreateText.analysisStep(phase: "Done", state: "ready"), RecreateText.analysisSteps.count)
        let applied = try await api.apply(ref.id, RecreateApplyRequest(sessionId: "es_1", slots: [:]))
        XCTAssertEqual(applied.match?.perSlot?.count, 3)
    }

    // MARK: Making the missing shots (estimate → confirm → fill → apply)

    func testSlotEstimateAndFillStartDecode() throws {
        // The server's shapes: a full ShotRequest and ShotEstimate, plus fields this app doesn't know.
        let est = #"""
        {"slotId":"s2","request":{"mode":"reference","prompt":"Close-up, eye level: she flips her hair","duration":2,"quality":"standard"},
         "estimate":{"quality":"standard","label":"Shot · Standard · 768p","resolution":"768p","seconds":2,"takes":1,"mode":"reference",
           "estimate":0.64,"priceLine":"about $0.64 · 2 s","buttonLabel":"Generate · 2 s · $0.64","ok":true,"warnings":["length set to 2 s"],
           "camera":{"moves":[],"guideUsed":false},"test":false,"rig":[],"somethingNew":1}}
        """#
        let e = try JSONDecoder().decode(RecreateSlotEstimate.self, from: Data(est.utf8))
        XCTAssertEqual(e.slotId, "s2")
        XCTAssertEqual(e.estimate.estimate, 0.64, accuracy: 1e-9)
        XCTAssertEqual(e.estimate.priceLine, "about $0.64 · 2 s")
        XCTAssertNil(e.estimate.problem)
        XCTAssertNotNil(e.request)
        // A sparse estimate still decodes (lenient), and a capped one says why.
        let capped = #"{"slotId":"s3","estimate":{"estimate":4.1,"ok":false,"message":"Over the studio's daily limit"}}"#
        let c = try JSONDecoder().decode(RecreateSlotEstimate.self, from: Data(capped.utf8))
        XCTAssertEqual(c.estimate.problem, "Over the studio's daily limit")
        let fill = #"{"slotId":"s2","job":{"id":"job_9","state":"queued","cost":0.64,"engineLabel":"Shot · Standard · 768p","request":{"engine":"suite"},"extra":true}}"#
        let f = try JSONDecoder().decode(RecreateSlotFillStart.self, from: Data(fill.utf8))
        XCTAssertEqual(f.slotId, "s2")
        XCTAssertEqual(f.job.id, "job_9")
        XCTAssertEqual(f.job.cost, 0.64, accuracy: 1e-9)
        XCTAssertTrue(f.job.isActive)
    }

    func testSlotIdsAreChecked() {
        XCTAssertNoThrow(try RecreateIds.slot("s1"))
        XCTAssertNoThrow(try RecreateIds.slot("s1234"))
        XCTAssertThrowsError(try RecreateIds.slot("s12345"))
        XCTAssertThrowsError(try RecreateIds.slot("../fill"))
        XCTAssertThrowsError(try RecreateIds.slot("s1/estimate"))
        XCTAssertThrowsError(try RecreateIds.slot(""))
    }

    /// Demo mode: priced at $0.64 a shot, generating then ready on the following fills, and the build gets job ids.
    func testDemoGeneratesThenBuilds() async throws {
        let api = FakeRecreateAPI()
        let refs = try await api.listReferences()
        let ref = try XCTUnwrap(refs.first)
        let before = try await api.fill(ref.id)
        let toMake = before.slots.filter { $0.state == "to_generate" }.map(\.slotId)
        XCTAssertEqual(toMake, ["s2", "s3"])
        var prices: [String: Double] = [:]
        for s in toMake { prices[s] = try await api.estimateSlot(ref.id, slotId: s, modelId: "m1", quality: nil, options: RecreateFillOptions(method: "generate")).estimate.estimate }
        XCTAssertEqual(before.generateTotal(prices: prices), 1.28, accuracy: 1e-9)
        XCTAssertEqual(RecreateText.makingSummary(before, prices: prices, unavailable: ["s3"]), "1 from your takes, 1 to generate, 1 can’t be made · $0.64 in all")
        for s in toMake {
            let started = try await api.fillSlot(ref.id, slotId: s, modelId: "m1", quality: nil)
            XCTAssertEqual(started.slotId, s)
        }
        // Never twice: a slot already being made is refused.
        do {
            _ = try await api.fillSlot(ref.id, slotId: "s2", modelId: "m1", quality: nil)
            XCTFail("filled twice")
        } catch {}
        let generating = try await api.fill(ref.id)
        XCTAssertEqual(generating.slots.map(\.state), ["matched", "generating", "generating"])
        XCTAssertEqual(RecreateText.makingSummary(generating), "1 from your takes, 2 generating")
        // Swapped shots say so (the top bar's summary when the shots will be swapped in).
        XCTAssertEqual(RecreateText.makingSummary(before, prices: prices, swaps: ["s2", "s3"]).hasPrefix("1 from your takes, 2 to swap in"), true)
        XCTAssertEqual(RecreateText.makingSummary(before, prices: prices, swaps: ["s2"]).hasPrefix("1 from your takes, 1 to generate, 1 to swap in"), true)
        var slots: [String: String] = ["s1": "t1"]
        for s in generating.slots where s.state == "generating" { slots[s.slotId] = s.jobId }
        let early = try await api.apply(ref.id, RecreateApplyRequest(sessionId: "es_1", slots: slots))
        XCTAssertEqual(early.waiting, ["s2", "s3"])
        let ready = try await api.fill(ref.id)
        XCTAssertEqual(ready.slots.map(\.state), ["matched", "ready", "ready"])
        XCTAssertEqual(RecreateText.makingSummary(ready), "1 from your takes, 2 generated · nothing to pay")
        slots = ["s1": "t1"]
        for s in ready.slots where s.state == "ready" { slots[s.slotId] = s.jobId }
        XCTAssertEqual(slots["s2"], FakeRecreateAPI.demoJobId("s2"))
        let built = try await api.apply(ref.id, RecreateApplyRequest(sessionId: "es_1", baseRevision: 1, slots: slots))
        XCTAssertEqual(built.waiting ?? [], [])
        XCTAssertEqual(built.revision, 2)
        api.forgetMade()
        let again = try await api.fill(ref.id)
        XCTAssertEqual(again.slots.map(\.state), ["matched", "to_generate", "to_generate"])
        await XCTAssertThrowsErrorAsync { _ = try await api.estimateSlot(ref.id, slotId: "nope", modelId: "m1", quality: nil) }
    }

    // MARK: From a link (Release 1 gap 3)

    func testLinkFieldsDecodeLeniently() throws {
        let json = #"{"id":"rx_9","state":"analyzing","phase":"Fetching the video","source":"link","sourceUrl":"https://www.tiktok.com/@a/video/12345678","cached":true}"#
        let r = try JSONDecoder().decode(RecreateReference.self, from: Data(json.utf8))
        XCTAssertTrue(r.isLink)
        XCTAssertEqual(r.sourceUrl, "https://www.tiktok.com/@a/video/12345678")
        XCTAssertEqual(r.cached, true)
        XCTAssertNil(r.errorCode)
        let failed = #"{"id":"rx_8","state":"failed","error":"Couldn’t fetch this link — save the video and drop the file in","errorCode":"link_blocked","source":"link","cached":"nope"}"#
        let f = try JSONDecoder().decode(RecreateReference.self, from: Data(failed.utf8))
        XCTAssertTrue(f.failedFetchingLink)
        XCTAssertNil(f.cached)   // a wrong type is dropped, never fails the decode
        // A file reference: no link fields at all.
        let file = try JSONDecoder().decode(RecreateReference.self, from: Data(#"{"id":"rx_7","state":"failed","error":"x"}"#.utf8))
        XCTAssertFalse(file.isLink)
        XCTAssertFalse(file.failedFetchingLink)
        // The "Use this sound" reminder, if the server adds it, as a string or an object.
        let s1 = try JSONDecoder().decode(RecreateReference.self, from: Data(#"{"id":"rx_6","state":"ready","soundReminder":"Use the sound"}"#.utf8))
        XCTAssertEqual(RecreateExport.reminder(s1), "Use the sound")
        let s2 = try JSONDecoder().decode(RecreateReference.self, from: Data(#"{"id":"rx_5","state":"ready","useThisSound":{"text":"Tap the sound"}}"#.utf8))
        XCTAssertEqual(s2.soundReminder, "Tap the sound")
        XCTAssertEqual(RecreateExport.reminder(file), "Post with TikTok’s “Use this sound” so the real sound plays.")
        // Round trip keeps the link fields.
        let again = try JSONDecoder().decode(RecreateReference.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(again.sourceUrl, r.sourceUrl)
        XCTAssertEqual(again.source, "link")
    }

    func testLinksAreRecognised() {
        XCTAssertEqual(RecreateLinks.platform("https://www.tiktok.com/@a/video/123456"), "TikTok")
        XCTAssertEqual(RecreateLinks.platform("https://vm.tiktok.com/ZMabc12/"), "TikTok")
        XCTAssertEqual(RecreateLinks.platform("https://www.instagram.com/reel/Cabc123/"), "Instagram")
        XCTAssertEqual(RecreateLinks.platform("https://youtu.be/abcdefghijk"), "YouTube")
        XCTAssertEqual(RecreateLinks.platform("https://m.youtube.com/shorts/abcdefghijk"), "YouTube")
        XCTAssertNil(RecreateLinks.platform("https://vimeo.com/1"))
        XCTAssertNil(RecreateLinks.platform("ftp://tiktok.com/x"))
        XCTAssertNil(RecreateLinks.platform("not a link"))
        // A share sheet's words around the link.
        XCTAssertEqual(RecreateLinks.detect("Check this out! https://www.tiktok.com/@a/video/123456 #fyp"), "https://www.tiktok.com/@a/video/123456")
        XCTAssertEqual(RecreateLinks.detect("(https://youtu.be/abcdefghijk)."), "https://youtu.be/abcdefghijk")
        XCTAssertNil(RecreateLinks.detect("https://example.com/video.mp4"))
        XCTAssertTrue(RecreateLinks.offersFile("link_private"))
        XCTAssertFalse(RecreateLinks.offersFile("too_long"))
        XCTAssertFalse(RecreateLinks.offersFile(nil))
    }

    func testLinkRefusalsSayWhyAndOfferTheFile() {
        let blocked = RecreateLinkProblem(ApiError("link_blocked", "Server error 502"))
        XCTAssertEqual(blocked?.message, RecreateLinks.fallback)
        XCTAssertEqual(blocked?.offersFile, true)
        let priv = RecreateLinkProblem(ApiError("link_private", "This video isn’t public, so MUSE won’t fetch it. Save it yourself and drop the file in"))
        XCTAssertEqual(priv?.message, "This video isn’t public, so MUSE won’t fetch it. Save it yourself and drop the file in")
        XCTAssertEqual(priv?.offersFile, true)
        XCTAssertEqual(RecreateLinkProblem(ApiError("too_long", "References can be up to 60 s for now (this one is 94 s)"))?.offersFile, true)
        XCTAssertNil(RecreateLinkProblem(ApiError("offline", "Can't reach the server")))
        for code in ["link_unsupported", "link_private", "link_downloads_off", "link_too_big", "link_blocked", "too_long"] {
            XCTAssertFalse(RecreateLinks.message(code: code, message: nil).isEmpty)
        }
    }

    /// Demo mode: a link reads the sample at once, the same link again is the cached reference, and each refusal is tried
    /// by a word in the link.
    func testDemoLinks() async throws {
        let api = FakeRecreateAPI()
        let r = try await api.createReference(link: FakeRecreateAPI.demoLink, name: nil)
        XCTAssertTrue(r.isReady)
        XCTAssertTrue(r.isLink)
        XCTAssertNil(r.cached)
        let again = try await api.createReference(link: FakeRecreateAPI.demoLink, name: nil)
        XCTAssertEqual(again.id, r.id)
        XCTAssertEqual(again.cached, true)
        let cases: [(String, String)] = [
            ("https://www.tiktok.com/@a/video/1234567-private", "link_private"),
            ("https://www.tiktok.com/@a/video/1234567-downloads-off", "link_downloads_off"),
            ("https://www.instagram.com/reel/too-big1/", "link_too_big"),
            ("https://youtu.be/too-long-vid", "too_long"),
            ("https://www.tiktok.com/@a/video/blocked", "link_blocked"),
            ("https://vimeo.com/123", "link_unsupported"),
        ]
        for (link, code) in cases {
            do {
                _ = try await api.createReference(link: link, name: nil)
                XCTFail("\(link) was accepted")
            } catch let e as ApiError {
                XCTAssertEqual(e.code, code, link)
                XCTAssertNotNil(RecreateLinkProblem(e), link)
            }
        }
        // Accepted, then the download is blocked: the reference turns failed with link_blocked.
        let later = try await api.createReference(link: "https://www.tiktok.com/@a/video/1234567-fails", name: nil)
        XCTAssertTrue(later.isAnalyzing)
        XCTAssertEqual(later.phase, "Fetching the video")
        let failed = try await api.reference(later.id)
        XCTAssertTrue(failed.failedFetchingLink)
        XCTAssertEqual(failed.error, RecreateLinks.fallback)
        // A file after a failing link still reads the sample.
        let file = try await api.createReference(file: URL(fileURLWithPath: "/tmp/clip.mp4"), contentType: "video/mp4", name: nil, progress: nil)
        XCTAssertTrue(file.isReady)
        XCTAssertFalse(file.isLink)
    }

    // MARK: Assembly (Compare's built edit in demo mode) and export

    func testAssemblyFollowsTheServerRules() throws {
        let r = try XCTUnwrap(try fixture().recipe)
        let take = RecreateAssembly.TakeInfo(id: "t1", durationSec: 15, width: 432, height: 768)
        let built = RecreateAssembly.project(r, sourceTakeId: "t1", takes: ["s1": take, "s2": take, "s3": take],
                                             paletteIds: ["teal_orange"], startAtSlot: true)
        let clips = built.project.mainClips
        XCTAssertEqual(clips.count, 3)
        XCTAssertTrue(built.missing.isEmpty)
        XCTAssertEqual(built.project.canvas.width, 1080)
        XCTAssertEqual(built.project.canvas.height, 1920)
        XCTAssertEqual(built.project.assets.count, 1)
        // Cut → none; crossfade → fade into shot 3; the flash inside shot 3 is not a transition between clips.
        XCTAssertNil(clips[1].transitionIn)
        XCTAssertEqual(clips[2].transitionIn?.kind, .fade)
        // The pan on shot 1 and the push-in on shot 2 are keyframes; the still shot 3 has none.
        XCTAssertNotNil(clips[0].keyframes?.x)
        XCTAssertNotNil(clips[1].keyframes?.scale)
        XCTAssertNil(clips[2].keyframes)
        // The Look at 0.8 (teal & orange is close enough), and the caption on a text track.
        XCTAssertEqual(clips[0].look?.lut, "palette:teal_orange")
        XCTAssertEqual(clips[0].look?.strength, 0.8)
        let text = try XCTUnwrap(built.project.tracks.first { $0.kind == .text }?.items.first?.textItem)
        XCTAssertEqual(text.text, "SUMMER")
        // The edit is as long as the reference (cuts land on its times).
        XCTAssertEqual(built.durationSec, r.durationSec, accuracy: 0.05)
        XCTAssertNil(EditV2.problem(built.project, paletteIds: ["teal_orange"]))
        // Without the Look on this Mac, no LUT; without a take, the slot is left out.
        let partial = RecreateAssembly.project(r, sourceTakeId: "t1", takes: ["s1": take, "s3": take])
        XCTAssertNil(partial.project.mainClips.first?.look)
        XCTAssertEqual(partial.missing, ["s2"])
        // A take shorter than its slot plays slower to fill it.
        let short = RecreateAssembly.TakeInfo(id: "t2", durationSec: 0.75, width: 432, height: 768)
        let slow = RecreateAssembly.project(r, sourceTakeId: "t2", takes: ["s1": short])
        XCTAssertLessThan(slow.project.mainClips[0].speed, 1)
        XCTAssertEqual(EditV2.clipLength(slow.project.mainClips[0]), r.slots[0].length, accuracy: 0.01)
    }

    func testExportWordsAndGuideRange() {
        XCTAssertEqual(RecreateExport.guideRange(editSec: 4.4, referenceSec: 10)?.duration, 4.4)
        XCTAssertEqual(RecreateExport.guideRange(editSec: 12, referenceSec: 4.4)?.duration, 4.4)
        XCTAssertNil(RecreateExport.guideRange(editSec: 0, referenceSec: 4))
        XCTAssertNil(RecreateExport.guideRange(editSec: .nan, referenceSec: 4))
        XCTAssertEqual(RecreateExport.fileName("Summer/cut", sound: .guide), "Summer-cut recreated.mp4")
        XCTAssertEqual(RecreateExport.fileName(nil, sound: .silent), "Recreated edit recreated silent.mp4")
        for s in RecreateExport.Sound.allCases { XCTAssertFalse(s.label.isEmpty); XCTAssertFalse(s.hint.isEmpty) }
    }

    func testClaudeContextAndSuggestions() throws {
        let ref = try fixture()
        let msg = RecreateClaude.message("Explain shot 2", reference: ref, sessionId: "es_1")
        XCTAssertTrue(msg.contains("rx_example"))
        XCTAssertTrue(msg.contains("es_1"))
        XCTAssertEqual(RecreateClaude.stripContext(msg), "Explain shot 2")
        XCTAssertEqual(RecreateClaude.stripContext("plain"), "plain")
        let chips = RecreateClaude.suggestions(selectedShot: 1, weakestShot: nil, hasRecipe: true).map(\.label)
        XCTAssertEqual(chips, ["Explain shot 2", "Fix the weakest shot", "Analyse a new video"])
        XCTAssertEqual(RecreateClaude.suggestions(selectedShot: 0, weakestShot: 2, hasRecipe: true)[1].label, "Fix shot 3")
        XCTAssertEqual(RecreateClaude.suggestions(selectedShot: nil, weakestShot: nil, hasRecipe: false).map(\.label), ["Analyse a new video"])
        // A fix never spends on its own: the prompt asks for the price and says the owner confirms.
        let fix = RecreateClaude.suggestions(selectedShot: 0, weakestShot: 1, hasRecipe: true)[1].prompt
        XCTAssertTrue(fix.contains("I confirm before anything is spent"))
    }

    // MARK: Server renders (Compare's preview, export)

    func testPreviewAndExportDecodeLeniently() throws {
        let p = try JSONDecoder().decode(EditPreviewRender.self, from: Data(#"{"sessionId":"es_1","revision":3,"state":"ready","url":"/v1/edit-sessions/es_1/preview.mp4?revision=3","durationSec":4.4,"width":406,"height":720,"unsupported":["captions"],"new":1}"#.utf8))
        XCTAssertTrue(p.isReady)
        XCTAssertTrue(p.isCutOnly)
        let none = try JSONDecoder().decode(EditPreviewRender.self, from: Data(#"{"sessionId":"es_1","state":"none"}"#.utf8))
        XCTAssertFalse(none.isReady)
        XCTAssertFalse(none.isCutOnly)
        let e = try JSONDecoder().decode(RecreateServerExport.self, from: Data(#"""
        {"referenceId":"rx_1","sessionId":"es_1","revision":2,"sound":"guide","state":"ready","url":"/v1/recreate/references/rx_1/export.mp4?sessionId=es_1&sound=guide",
         "durationSec":4.4,"unsupported":[],"useThisSound":{"platform":"tiktok","sourceUrl":"https://www.tiktok.com/@a/video/1","startAtSec":0,"durationSec":4.4,
         "title":"Post with the original sound","steps":["Tap the sound","Tap Use this sound"],"note":"Only for timing"}}
        """#.utf8))
        XCTAssertTrue(e.isReady)
        XCTAssertEqual(e.useThisSound?.platform, "tiktok")
        let lines = RecreateExport.reminderLines(e.useThisSound, reference: nil)
        XCTAssertEqual(lines.title, "Post with the original sound")
        XCTAssertEqual(lines.steps.count, 2)
        XCTAssertEqual(lines.note, "Only for timing")
        let plain = RecreateExport.reminderLines(nil, reference: nil)
        XCTAssertEqual(plain.steps, ["Post with TikTok’s “Use this sound” so the real sound plays."])
        let sparse = try JSONDecoder().decode(RecreateServerExport.self, from: Data(#"{"state":"rendering","useThisSound":{"platform":null}}"#.utf8))
        XCTAssertTrue(sparse.isRendering)
        XCTAssertEqual(sparse.useThisSound?.title, "Post with the original sound")
        XCTAssertTrue(RecreateExport.serverLacksRender(ApiError("http_404", "Server error 404")))
        XCTAssertFalse(RecreateExport.serverLacksRender(ApiError("not_found", "Edit session not found")))
        XCTAssertFalse(RecreateExport.serverLacksRender(ApiError("no_reference_sound", "x")))
        XCTAssertThrowsError(try EditSessionIds.check("../x"))
    }

    func testDemoRendersLikeTheServer() async throws {
        let api = FakeRecreateAPI()
        let p0 = try await api.preview(sessionId: "es_1", revision: nil)
        XCTAssertEqual(p0.state, "none")
        let p1 = try await api.startPreview(sessionId: "es_1")
        XCTAssertTrue(p1.isRendering)
        let p2 = try await api.preview(sessionId: "es_1", revision: nil)
        XCTAssertTrue(p2.isReady)
        // The demo reference has no video: a guide export is refused, silent works.
        do {
            _ = try await api.startExport("rx_demo", sessionId: "es_1", sound: "guide")
            XCTFail("guide without the reference's sound")
        } catch let e as ApiError {
            XCTAssertEqual(e.code, "no_reference_sound")
        }
        let s1 = try await api.startExport("rx_demo", sessionId: "es_1", sound: "silent")
        XCTAssertTrue(s1.isRendering)
        let s2 = try await api.exportState("rx_demo", sessionId: "es_1", sound: "silent")
        XCTAssertTrue(s2.isReady)
        XCTAssertFalse(s2.useThisSound?.steps.isEmpty ?? true)
        // A link reference names its platform's steps.
        let link = try await api.createReference(link: FakeRecreateAPI.demoLink, name: nil)
        let g = try await api.startExport(link.id, sessionId: "es_1", sound: "guide")
        XCTAssertEqual(g.useThisSound?.platform, "tiktok")
        XCTAssertTrue(g.useThisSound?.steps.contains { $0.contains("Use this sound") } ?? false)
    }

    // MARK: Fix shot N (replace one shot in the built edit)

    func testReplaceDecodesLeniently() throws {
        let r = try JSONDecoder().decode(RecreateReplaceResult.self, from: Data(#"{"sessionId":"es_1","revision":4,"slotId":"s2","itemId":"c2","takeId":"t9","inSec":1.2,"label":"Replaced shot s2","note":"plays at 80%","x":1}"#.utf8))
        XCTAssertEqual(r.revision, 4)
        XCTAssertEqual(r.note, "plays at 80%")
        let sparse = try JSONDecoder().decode(RecreateReplaceResult.self, from: Data(#"{"slotId":"s1"}"#.utf8))
        XCTAssertNil(sparse.revision)
    }

    func testDemoReplaceFollowsTheServerRules() async throws {
        let api = FakeRecreateAPI()
        // Not built in this session yet.
        await assertCode("not_built_here") { _ = try await api.replaceSlot("rx_demo", slotId: "s2", sessionId: "es_1", take: "t1", baseRevision: nil) }
        // Built with s1 and s2 only: s3 isn't in the edit.
        _ = try await api.apply("rx_demo", RecreateApplyRequest(sessionId: "es_1", baseRevision: 1, slots: ["s1": "t1", "s2": "t1"]))
        await assertCode("slot_not_in_edit") { _ = try await api.replaceSlot("rx_demo", slotId: "s3", sessionId: "es_1", take: "t1", baseRevision: nil) }
        await assertCode("bad_request") { _ = try await api.replaceSlot("rx_demo", slotId: "s2", sessionId: "es_1", take: "unknown_take", baseRevision: nil) }
        let a = try await api.replaceSlot("rx_demo", slotId: "s2", sessionId: "es_1", take: "t7", baseRevision: 2)
        XCTAssertEqual(a.revision, 3)
        XCTAssertEqual(a.takeId, "t7")
        XCTAssertEqual(a.itemId, "c2")
        // Regenerate: the job must be done first (job_not_done while generating), then its take goes in.
        _ = try await api.fillSlot("rx_demo", slotId: "s2", modelId: "m1", quality: nil)
        let job = FakeRecreateAPI.demoJobId("s2")
        await assertCode("job_not_done") { _ = try await api.replaceSlot("rx_demo", slotId: "s2", sessionId: "es_1", take: job, baseRevision: nil) }
        _ = try await api.fill("rx_demo")
        _ = try await api.fill("rx_demo")
        let b = try await api.replaceSlot("rx_demo", slotId: "s2", sessionId: "es_1", take: job, baseRevision: nil)
        XCTAssertEqual(b.revision, 4)
        XCTAssertEqual(b.takeId, "t_rx_s2")
    }

    private func assertCode(_ code: String, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(code)", file: file, line: line)
        } catch let e as ApiError {
            XCTAssertEqual(e.code, code, file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    // MARK: Swap fill (G2)

    func testSwapEstimateAndFillDecode() throws {
        let est = #"""
        {"slotId":"s2","method":"swap","keepBackground":true,"segment":{"startSec":1.25,"endSec":2.92},"baked":["camera","speed","look"],"request":{},
         "estimate":{"method":"swap","label":"Swap · 2.0 s","seconds":2,"takes":1,"estimate":0.41,"priceLine":"about $0.41 · 2.0 s","buttonLabel":"Swap in · 2.0 s · $0.41","ok":true,"warnings":[]}}
        """#
        let e = try JSONDecoder().decode(RecreateSlotEstimate.self, from: Data(est.utf8))
        XCTAssertTrue(e.isSwap)
        XCTAssertEqual(e.segment?.endSec, 2.92)
        XCTAssertEqual(e.baked, ["camera", "speed", "look"])
        XCTAssertEqual(e.estimate.buttonLabel, "Swap in · 2.0 s · $0.41")
        let gen = try JSONDecoder().decode(RecreateSlotEstimate.self, from: Data(#"{"slotId":"s3","method":"generate","promptFrom":"summary","swapUnavailable":"The reference video is gone","estimate":{"estimate":0.64,"ok":true}}"#.utf8))
        XCTAssertFalse(gen.isSwap)
        XCTAssertEqual(gen.swapUnavailable, "The reference video is gone")
        let fill = try JSONDecoder().decode(RecreateFill.self, from: Data(#"""
        {"referenceId":"rx_1","slots":[{"slotId":"s2","state":"to_generate","method":"generate","fallback":"generate","failedJobId":"job_9","reason":"The swap didn’t work"},{"slotId":"s3"}],
         "applied":{"sessionId":"es_1","baked":{"s1":["camera","speed","look"]}}}
        """#.utf8))
        XCTAssertEqual(fill.slots[0].fallback, "generate")
        XCTAssertEqual(fill.slots[0].failedJobId, "job_9")
        XCTAssertEqual(fill.slots[1].state, "empty")
        XCTAssertEqual(fill.baked["s1"], ["camera", "speed", "look"])
        XCTAssertEqual(RecreateBaked.words(["camera", "speed", "look"]), "camera, speed and look")
        let apply = try JSONDecoder().decode(RecreateApplyResult.self, from: Data(#"{"sessionId":"es_1","baked":{"s2":["look"]}}"#.utf8))
        XCTAssertEqual(apply.baked?["s2"], ["look"])
    }

    func testDemoSwapsByDefaultAndFallsBack() async throws {
        let api = FakeRecreateAPI()
        let swap = try await api.estimateSlot("rx_demo", slotId: "s2", modelId: "m1", quality: nil)
        XCTAssertTrue(swap.isSwap)
        XCTAssertEqual(swap.estimate.estimate, FakeRecreateAPI.demoSwapPrice, accuracy: 1e-9)
        XCTAssertTrue(swap.estimate.buttonLabel.hasPrefix("Swap in"))
        let own = try await api.estimateSlot("rx_demo", slotId: "s2", modelId: "m1", quality: nil, options: RecreateFillOptions(method: "swap", keepBackground: false))
        XCTAssertEqual(own.keepBackground, false)
        let gen = try await api.estimateSlot("rx_demo", slotId: "s2", modelId: "m1", quality: nil, options: RecreateFillOptions(method: "generate"))
        XCTAssertFalse(gen.isSwap)
        // Swap can't run: the default falls back with a reason; an explicit swap is refused.
        api.swapAvailable = false
        let fallback = try await api.estimateSlot("rx_demo", slotId: "s2", modelId: "m1", quality: nil)
        XCTAssertEqual(fallback.method, "generate")
        XCTAssertNotNil(fallback.swapUnavailable)
        await assertCode("swap_unavailable") { _ = try await api.estimateSlot("rx_demo", slotId: "s2", modelId: "m1", quality: nil, options: RecreateFillOptions(method: "swap")) }
        api.swapAvailable = true
        // A swap fill: generating with its method, ready, and baked when built.
        let started = try await api.fillSlot("rx_demo", slotId: "s2", modelId: "m1", quality: nil)
        XCTAssertEqual(started.method, "swap")
        XCTAssertNotNil(started.segment)
        _ = try await api.fill("rx_demo")
        let ready = try await api.fill("rx_demo")
        XCTAssertEqual(ready.slots[1].state, "ready")
        XCTAssertEqual(ready.slots[1].method, "swap")
        let built = try await api.apply("rx_demo", RecreateApplyRequest(sessionId: "es_1", slots: ["s1": "t1", "s2": FakeRecreateAPI.demoJobId("s2")]))
        XCTAssertEqual(built.baked?["s2"], ["camera", "speed", "look"])
        let swapped = try await api.replaceSlot("rx_demo", slotId: "s2", sessionId: "es_1", take: FakeRecreateAPI.demoJobId("s2"), baseRevision: nil)
        XCTAssertEqual(swapped.baked, ["camera", "speed", "look"])
        let plain = try await api.replaceSlot("rx_demo", slotId: "s2", sessionId: "es_1", take: "t5", baseRevision: nil)
        XCTAssertNil(plain.baked)
        // A failed swap: refunded, offered as generate with the reason.
        api.failSwaps = true
        _ = try await api.fillSlot("rx_demo", slotId: "s3", modelId: "m1", quality: nil)
        _ = try await api.fill("rx_demo")
        let failed = try await api.fill("rx_demo")
        let s3 = try XCTUnwrap(failed.slots.first { $0.slotId == "s3" })
        XCTAssertEqual(s3.state, "to_generate")
        XCTAssertEqual(s3.fallback, "generate")
        XCTAssertEqual(s3.reason, FakeRecreateAPI.swapFailedReason)
    }

    // MARK: Use your own setting (a location, or a plate from the brief)

    func testOwnSettingBackground() async throws {
        let json = #"""
        {"slotId":"s2","method":"swap","keepBackground":false,"background":{"source":"generated","setting":"a rooftop at dusk","usd":0.06},
         "estimate":{"estimate":0.47,"swapUsd":0.41,"backgroundUsd":0.06,"buttonLabel":"Swap in · 2.0 s · $0.47","priceLine":"about $0.47","ok":true}}
        """#
        let e = try JSONDecoder().decode(RecreateSlotEstimate.self, from: Data(json.utf8))
        XCTAssertEqual(e.backgroundUsd, 0.06)
        XCTAssertEqual(e.swapUsd, 0.41)
        XCTAssertEqual(e.background?.line, "background made from the brief, +$0.06")
        let loc = try JSONDecoder().decode(RecreateBackground.self, from: Data(#"{"source":"location","locationId":"loc1","name":"Rooftop","matched":true,"usd":0}"#.utf8))
        XCTAssertEqual(loc.line, "in Rooftop")
        let api = FakeRecreateAPI()
        let plain = try await api.estimateSlot("rx_demo", slotId: "s2", modelId: "m1", quality: nil)
        XCTAssertNil(plain.background)
        let plate = try await api.estimateSlot("rx_demo", slotId: "s2", modelId: "m1", quality: nil, options: RecreateFillOptions(method: "swap", keepBackground: false))
        XCTAssertEqual(plate.background?.source, "generated")
        XCTAssertEqual(plate.backgroundUsd ?? 0, FakeRecreateAPI.demoPlatePrice, accuracy: 1e-9)
        XCTAssertEqual(plate.estimate.estimate, FakeRecreateAPI.demoSwapPrice + FakeRecreateAPI.demoPlatePrice, accuracy: 1e-9)
        let locId = try XCTUnwrap(FakeMuseAPI.demoLocations.first?.id)
        let onLoc = try await api.estimateSlot("rx_demo", slotId: "s2", modelId: "m1", quality: nil,
                                               options: RecreateFillOptions(method: "swap", keepBackground: false, locationId: locId))
        XCTAssertEqual(onLoc.background?.source, "location")
        XCTAssertNil(onLoc.backgroundUsd)
        XCTAssertEqual(onLoc.estimate.estimate, FakeRecreateAPI.demoSwapPrice, accuracy: 1e-9)
        // The confirmed price: lower than the swap and plate → price_changed; a failed plate → background_failed.
        await assertCode("price_changed") {
            _ = try await api.fillSlot("rx_demo", slotId: "s2", modelId: "m1", quality: nil,
                                       options: RecreateFillOptions(method: "swap", keepBackground: false, maxUsd: FakeRecreateAPI.demoSwapPrice))
        }
        api.failBackground = true
        await assertCode("background_failed") {
            _ = try await api.fillSlot("rx_demo", slotId: "s3", modelId: "m1", quality: nil, options: RecreateFillOptions(method: "swap", keepBackground: false))
        }
        api.failBackground = false
        _ = try await api.fillSlot("rx_demo", slotId: "s3", modelId: "m1", quality: nil, options: RecreateFillOptions(method: "swap", keepBackground: false, maxUsd: 0.47))
        let again = try await api.estimateSlot("rx_demo", slotId: "s3", modelId: "m1", quality: nil, options: RecreateFillOptions(method: "swap", keepBackground: false))
        XCTAssertEqual(again.background?.reused, true)
        XCTAssertEqual(again.estimate.estimate, FakeRecreateAPI.demoSwapPrice, accuracy: 1e-9)
    }

    // MARK: Write the shot briefs (G8)

    func testBriefsEstimateAndWrite() async throws {
        let e = try JSONDecoder().decode(RecreateBriefsEstimate.self, from: Data(#"{"available":true,"slots":2,"estimateUsd":0.02,"label":"Write the shot briefs · about $0.02","priceLine":"about $0.02"}"#.utf8))
        XCTAssertTrue(e.available)
        XCTAssertEqual(e.slots, 2)
        let off = try JSONDecoder().decode(RecreateBriefsEstimate.self, from: Data(#"{"available":false,"reason":"Turn on Claude in Settings","slots":["s1","s3"]}"#.utf8))
        XCTAssertFalse(off.available)
        XCTAssertEqual(off.slots, 2)
        XCTAssertEqual(off.label, "Write the shot briefs")
        let api = FakeRecreateAPI()
        let ref = try await api.reference("rx_demo")
        XCTAssertEqual(ref.recipe?.slotsWithoutBriefs, ["s1", "s3"])
        let est = try await api.briefsEstimate("rx_demo")
        XCTAssertEqual(est.label, "Write the shot briefs · about $0.02")
        XCTAssertEqual(est.slots, 2)
        let done = try await api.writeBriefs("rx_demo")
        XCTAssertEqual(done.written, ["s1", "s3"])
        XCTAssertEqual(done.reference?.recipe?.slotsWithoutBriefs, [])
        api.briefsAvailable = false
        let none = try await api.briefsEstimate("rx_demo")
        XCTAssertFalse(none.available)
        XCTAssertNotNil(none.reason)
        await assertCode("briefs_unavailable") { _ = try await api.writeBriefs("rx_demo") }
    }

    // MARK: Claude's recreate thread (workstream 1's brief)

    func testRecreateThreadBriefSeedsClaudeCode() async throws {
        let json = #"{"id":"ct_1","contextKind":"recreate","contextId":"rx_1","createdAt":1,"updatedAt":2,"brief":{"prompt":"You recreate edits.","tools":["get_recipe","fill_slot"],"referenceId":"rx_1"}}"#
        let t = try JSONDecoder().decode(ClaudeThread.self, from: Data(json.utf8))
        XCTAssertEqual(t.brief?.tools, ["get_recipe", "fill_slot"])
        XCTAssertEqual(t.brief?.systemPrompt, "You recreate edits.\n\nThe reference: rx_1.")
        // An older server: no brief, odd fields; never fails.
        let old = try JSONDecoder().decode(ClaudeThread.self, from: Data(#"{"id":"ct_2","contextKind":"edit","contextId":"es_1","createdAt":1,"updatedAt":2,"brief":"?"}"#.utf8))
        XCTAssertNil(old.brief)
        XCTAssertNil(ClaudeBrief(prompt: "  ").systemPrompt)
        let cmd = ClaudeCommand(mcpURL: "u", token: "t", resume: "s1", appendSystemPrompt: "Brief")
        let args = cmd.arguments(configPath: "/c.json")
        XCTAssertEqual(Array(args.suffix(4)), ["--append-system-prompt", "Brief", "--resume", "s1"])
        XCTAssertFalse(ClaudeCommand(mcpURL: "u", token: "t").arguments(configPath: "/c.json").contains("--append-system-prompt"))
        // The demo fake: a recreate thread needs a reference id, and carries the brief.
        let api = FakeClaudeAPI()
        let th = try await api.thread(contextKind: "recreate", contextId: "rx_demo")
        XCTAssertEqual(th.brief?.referenceId, "rx_demo")
        do {
            _ = try await api.thread(contextKind: "recreate", contextId: "start")
            XCTFail("a recreate thread without a reference")
        } catch {}
    }

    private func XCTAssertThrowsErrorAsync(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected an error", file: file, line: line)
        } catch {}
    }
}

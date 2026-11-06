import XCTest
@testable import MuseCore

/// AI suite (workstream 1): the composer's Extend tool (the request, its sources, tools availability) and Upscale on a
/// finished take (sizes, price × the take's length, the 409), in pure rules and in demo mode.
final class SuiteExtendUpscaleTests: XCTestCase {
    private func json(_ r: ShotRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
    }

    private func take(_ id: String = "t1", kind: String = "take", url: String?, seconds: Double? = 8) -> Take {
        var t = Take(id: id, kind: kind, jobId: "j1", title: "Café", label: "Draft", thumb: ImageRef(url: "https://x/t.jpg"))
        t.videoUrl = url
        t.durationSec = seconds
        return t
    }

    private func api(speed: Double = 0) async throws -> FakeMuseAPI {
        let a = FakeMuseAPI(speed: speed, genDelay: 0.01)
        _ = try await a.signIn(SignInRequest(email: "owner@studio.com", password: "x"))
        return a
    }

    // MARK: Extend · keys and sources

    func testTheSourceKeyComesFromTheTakesVideoUrl() throws {
        XCTAssertEqual(SuiteKeys.key(fromUrl: "https://api.muse.app/uploads/r/j_src/take_1.mp4"), "r/j_src/take_1.mp4")
        XCTAssertEqual(SuiteKeys.key(fromUrl: "/uploads/r/j_1/take_2.mp4"), "r/j_1/take_2.mp4")
        XCTAssertEqual(SuiteKeys.key(fromUrl: "http://127.0.0.1:8798/uploads/c/up_x.mov?sig=1#t"), "c/up_x.mov", "no query or fragment")
        // Only keys the server accepts.
        XCTAssertNil(SuiteKeys.key(fromUrl: "https://cdn.example.com/video.mp4"), "not one of the studio's files")
        XCTAssertNil(SuiteKeys.key(fromUrl: "https://x/uploads/"))
        XCTAssertNil(SuiteKeys.key(fromUrl: "https://x/uploads/_hidden.mp4"), "a letter or digit first")
        XCTAssertNil(SuiteKeys.key(fromUrl: "https://x/uploads/r/a b.mp4"))
        XCTAssertNil(SuiteKeys.key(fromUrl: "https://x/uploads/r/../secret.mp4"))
        XCTAssertNil(SuiteKeys.key(fromUrl: "https://x/uploads/r/é.mp4"))
        XCTAssertNil(SuiteKeys.key(fromUrl: nil))
        XCTAssertTrue(SuiteKeys.isAccepted("r/j_1/take_1.mp4"))
        XCTAssertFalse(SuiteKeys.isAccepted(String(repeating: "a", count: 301)))

        let s = try XCTUnwrap(ExtendSource.take(take(url: "https://h/uploads/r/j1/take_1.mp4")))
        XCTAssertEqual(s.key, "r/j1/take_1.mp4")
        XCTAssertEqual(s.takeId, "t1")
        XCTAssertEqual(s.seconds, 8)
        XCTAssertEqual(s.videoRef, SuiteVideoRef(key: "r/j1/take_1.mp4"), "a take's length is the server's: no seconds sent")
        XCTAssertEqual(s.caption, "0:08 · take")
        XCTAssertNil(ExtendSource.take(take(url: nil)), "no video file")
        XCTAssertNil(ExtendSource.take(take(kind: "shot", url: "https://h/uploads/s/a.jpg")), "photos don't extend")
        XCTAssertNil(ExtendSource.take(take(url: "https://elsewhere/v.mp4")))
        // Demo takes carry their key without a URL.
        var demo = take(url: nil)
        demo.mediaKey = "r/jl_1/take_1.mp4"
        XCTAssertEqual(ExtendSource.take(demo)?.key, "r/jl_1/take_1.mp4")

        // An upload sends its length (rounded to the millisecond), within the server's 60 s.
        let up = try XCTUnwrap(ExtendSource.upload(SuiteVideoRef(key: "c/up_1.mp4"), seconds: 4.12345, name: "beach"))
        XCTAssertEqual(up.videoRef, SuiteVideoRef(key: "c/up_1.mp4", seconds: 4.123))
        XCTAssertTrue(up.isUpload)
        XCTAssertEqual(ExtendSource.upload(SuiteVideoRef(url: "https://h/uploads/c/up_2.mov"), seconds: 3, name: "x")?.key, "c/up_2.mov")
        XCTAssertNil(ExtendSource.upload(SuiteVideoRef(key: "c/up_1.mp4"), seconds: nil, name: "x"))
        XCTAssertNil(ExtendSource.upload(SuiteVideoRef(key: "c/up_1.mp4"), seconds: 61, name: "x"))
        XCTAssertNil(ExtendSource.upload(SuiteVideoRef(url: "https://elsewhere/v.mp4"), seconds: 3, name: "x"))
        XCTAssertEqual(ExtendSource.uploadProblem(seconds: 75), "Pick a video up to 60 s")
        XCTAssertNotNil(ExtendSource.uploadProblem(seconds: 0))

        // The VIDEO slot's takes: video takes with a file, newest first.
        var a = take(id: "a", url: "https://h/uploads/r/a/take_1.mp4")
        a.createdAt = 1
        var b = take(id: "b", url: "https://h/uploads/r/b/take_1.mp4")
        b.createdAt = 2
        XCTAssertEqual(ComposerExtend.takes([a, take(id: "c", url: nil), b]).map(\.id), ["b", "a"])
    }

    // MARK: Extend · the request

    func testTheExtendRequestHasNoExplicitNulls() throws {
        var d = ComposerDraft(tool: .extend, quality: "standard", duration: 6, takes: 2)
        XCTAssertNil(d.extendRequest(), "no video yet")
        XCTAssertEqual(d.missing(InputSlots()), "Pick a take or upload a video to extend")
        d = d.extending(try XCTUnwrap(ExtendSource.take(take(url: "https://h/uploads/r/j1/take_1.mp4"))))
        d.extend.prompt = "  She waves goodbye.  "
        XCTAssertNil(d.missing(InputSlots()))
        let r = try XCTUnwrap(d.extendRequest())
        let raw = String(data: try JSONEncoder().encode(r), encoding: .utf8) ?? ""
        XCTAssertFalse(raw.contains("null"), raw)
        let j = try json(r)
        XCTAssertEqual(j["mode"] as? String, "extend")
        XCTAssertEqual(j["prompt"] as? String, "She waves goodbye.")
        XCTAssertEqual(j["duration"] as? Int, 6)
        XCTAssertEqual(j["quality"] as? String, "standard")
        XCTAssertEqual(j["takes"] as? Int, 2)
        XCTAssertEqual(j["aspectRatio"] as? String, "9:16")
        let x = try XCTUnwrap(j["extend"] as? [String: Any])
        XCTAssertEqual(x["direction"] as? String, "after")
        XCTAssertNil(x["join"], "the server's default: one joined clip")
        XCTAssertEqual(x["video"] as? [String: String], ["key": "r/j1/take_1.mp4"])
        // Only what the strict schema knows: no shot-only fields.
        for k in ["modelId", "frames", "references", "camera", "clipId", "cast", "engineModel", "resolution", "speaking"] { XCTAssertNil(j[k], k) }

        // Before; an upload sends seconds; the owner's shot-engine pin isn't sent.
        d.extend.direction = .before
        d.engineModel = "h3"
        d.extend.source = ExtendSource.upload(SuiteVideoRef(key: "c/up_9.mp4"), seconds: 5, name: "clip")
        let b = try json(try XCTUnwrap(d.extendRequest()))
        let bx = try XCTUnwrap(b["extend"] as? [String: Any])
        XCTAssertEqual(bx["direction"] as? String, "before")
        let bv = try XCTUnwrap(bx["video"] as? [String: Any])
        XCTAssertEqual(bv["key"] as? String, "c/up_9.mp4")
        XCTAssertEqual(bv["seconds"] as? Double, 5)
        XCTAssertEqual(bv.count, 2)
        XCTAssertNil(b["engineModel"])
        XCTAssertEqual(ExtendDirection.after.promptTitle, "What happens next")
        XCTAssertEqual(ExtendDirection.before.promptTitle, "What happens before")
        // It decodes back.
        let back = try JSONDecoder().decode(ShotRequest.self, from: JSONEncoder().encode(try XCTUnwrap(d.extendRequest())))
        XCTAssertEqual(back.extend?.video.key, "c/up_9.mp4")
    }

    func testExtendAvailabilityFollowsTheCatalogsTools() throws {
        XCTAssertFalse(ComposerTool.extend.comingSoon, "the app's own list no longer holds Extend back")
        XCTAssertFalse(ComposerTool.extend.isComingSoon(in: nil))
        XCTAssertFalse(ComposerTool.extend.isComingSoon(in: SuiteDemoCatalog.catalog), "demo mode: available")
        var off = SuiteDemoCatalog.catalog
        off.tools = [SuiteToolStatus(id: "extend", available: false, comingSoon: true)]
        XCTAssertTrue(ComposerTool.extend.isComingSoon(in: off), "a server without an extend engine")
        XCTAssertEqual(ComposerSlots.cards(.extend, inputs: .none).map(\.slot), [.video])
        XCTAssertEqual(ComposerTool.extend.required, [.video])
    }

    // MARK: Upscale

    func testUpscalePricesAreThePriceTimesTheTakesLength() throws {
        let f = VideoFeatures.demo
        XCTAssertTrue(UpscaleOffer.isLive(f))
        let c = UpscaleOffer.choices(f, seconds: 8)
        XCTAssertEqual(c.map(\.id), ["1080p", "2k", "4k"])
        XCTAssertEqual(c[0].price ?? 0, 0.16, accuracy: 1e-9)
        XCTAssertEqual(c[1].price ?? 0, 0.32, accuracy: 1e-9, "the server's own example: 2K × 8 s at $0.04")
        XCTAssertEqual(c[1].priceText, "$0.32")
        XCTAssertTrue(c[1].canPick)
        XCTAssertFalse(c[2].available)
        XCTAssertEqual(c[2].priceText, "Soon", "4K greyed")
        XCTAssertFalse(c[2].canPick)
        // Rounded as the server holds it: price × seconds (to the ms), to $0.0001.
        XCTAssertEqual(UpscaleOffer.cost(UpscaleOffer.demoSizes[1], seconds: 7.3333333) ?? 0, 0.2933, accuracy: 1e-12)
        // An unknown length: offered but no price yet.
        let unknown = UpscaleOffer.choices(f, seconds: nil)
        XCTAssertTrue(unknown[0].available)
        XCTAssertEqual(unknown[0].priceText, "—")
        XCTAssertFalse(unknown[0].canPick)
        // Coming soon (the contract's fallback): every size greyed.
        XCTAssertFalse(UpscaleOffer.isLive(.fallback))
        XCTAssertEqual(UpscaleOffer.choices(.fallback, seconds: 8).map(\.priceText), ["Soon", "Soon", "Soon"])
        // A size the server lists as available but without a price stays greyed.
        var odd = f
        odd.addons = odd.addons.map { a0 -> AddonOption in
            var a = a0
            if a.id == "upscale" { a.sizes = [UpscaleSize(id: "1080p", label: "1080p", width: 1080, height: 1920, available: true, price: nil)] }
            return a
        }
        XCTAssertFalse(UpscaleOffer.isLive(odd))
        XCTAssertEqual(UpscaleOffer.choices(odd, seconds: 8).first?.priceText, "Soon")

        // The swap tool's Upscale pill: live, priced from its cheapest size once the take is done.
        let pills = SwapAddOns.pills(f, clipSeconds: 8)
        let up = try XCTUnwrap(pills.first { $0.id == "upscale" })
        XCTAssertTrue(up.available)
        XCTAssertEqual(up.priceText, "on the take")
        let done = try XCTUnwrap(SwapAddOns.pills(f, clipSeconds: 8, upscaleSeconds: 8).first { $0.id == "upscale" })
        XCTAssertEqual(done.priceText, "from $0.16")

        // Decoding the server's add-on.
        let raw = #"{"id":"upscale","label":"Upscale","detail":"Sharper","available":true,"sizes":[{"id":"1080p","label":"1080p","width":1080,"height":1920,"available":true,"price":0.02},{"id":"2k","label":"2K","width":1440,"height":2560,"available":true,"price":0.04},{"id":"4k","label":"4K","width":2160,"height":3840,"available":false,"price":null}]}"#
        let a = try JSONDecoder().decode(AddonOption.self, from: Data(raw.utf8))
        XCTAssertFalse(a.comingSoon)
        XCTAssertEqual(a.sizes.map(\.price), [0.02, 0.04, nil])
    }

    func testTheUpscale409() async throws {
        let e = ApiError("upscale_unavailable", "Upscale is coming soon")
        XCTAssertEqual(e.friendlyMessage, "Upscale is coming soon")
        XCTAssertNotNil(UpscaleOffer.refusal(e))
        XCTAssertNil(UpscaleOffer.refusal(ApiError("bad_request", "x")))
        // Demo mode refuses 4K (not priced) the same way.
        let a = try await api()
        let all = await a.listTakes()
        let t = try XCTUnwrap(all.first { $0.kind == "take" })
        do {
            _ = try await a.upscale(takeId: t.id, UpscaleRequest(size: "4k"))
            XCTFail("4K isn't offered")
        } catch let e as ApiError { XCTAssertEqual(e.code, "upscale_unavailable") }
        let shot = try XCTUnwrap(all.first { $0.kind == "shot" })
        do {
            _ = try await a.upscale(takeId: shot.id, UpscaleRequest(size: "2k"))
            XCTFail("photos don't upscale")
        } catch let e as ApiError { XCTAssertEqual(e.code, "bad_request") }
    }

    // MARK: Demo mode

    func testDemoUpscaleRunsAsAJob() async throws {
        let a = try await api(speed: 600)
        let s = try await a.studioSettings()
        let up = try XCTUnwrap(s.features.video?.upscale)
        XCTAssertTrue(up.available)
        XCTAssertEqual(up.sizes.map(\.id), ["1080p", "2k", "4k"])
        XCTAssertEqual(up.sizes.map(\.price), [0.02, 0.04, nil])
        let all = await a.listTakes()
        let t = try XCTUnwrap(all.first { $0.kind == "take" && $0.canUpscale })
        let seconds = try XCTUnwrap(t.durationSec)
        let events = a.events()
        let j = try await a.upscale(takeId: t.id, UpscaleRequest(size: "2k"))
        XCTAssertEqual(j.engineLabel, "Upscale · 2K")
        XCTAssertTrue(j.request.isUpscale)
        XCTAssertEqual(j.cost, UpscaleOffer.cost(UpscaleOffer.demoSizes[1], seconds: seconds) ?? -1, accuracy: 1e-9)
        var made: [Take] = []
        for await e in events {
            guard let x = e.job, x.id == j.id, x.isDone else { continue }
            made = e.takes ?? []
            break
        }
        let out = try XCTUnwrap(made.first)
        XCTAssertEqual(out.label, "Upscale · 2K")
        XCTAssertEqual(out.durationSec ?? 0, seconds, accuracy: 1e-9)
    }

    func testDemoExtendEstimatesByTheServersRulesAndMakesALongerTake() async throws {
        let a = try await api(speed: 600)
        let c = try await a.suiteCatalog()
        XCTAssertFalse(ComposerTool.extend.isComingSoon(in: c))
        let ref = try await a.uploadSuiteMedia(URL(fileURLWithPath: "/tmp/clip.mp4"), contentType: "video/mp4", progress: nil)
        let upload = try XCTUnwrap(ExtendSource.upload(ref, seconds: 4, name: "clip"))
        var d = ComposerDraft(tool: .extend, quality: "draft", duration: 5).extending(upload)
        d.extend.prompt = "She turns away."

        // Draft, after: the true continuation first (720p).
        let e = try await a.suiteEstimate(try XCTUnwrap(d.extendRequest()))
        XCTAssertEqual(e.mode, "extend")
        XCTAssertEqual(e.label, "Extend · Draft · 720p")
        XCTAssertEqual(e.seconds, 5)
        XCTAssertEqual(e.estimate, 0.5, accuracy: 1e-9)
        XCTAssertTrue(SuiteText.isMemberSafe(e.label + e.buttonLabel + e.priceLine))
        // Draft, before: a reference model (480p, video input pricing).
        d.extend.direction = .before
        let eb = try await a.suiteEstimate(try XCTUnwrap(d.extendRequest()))
        XCTAssertEqual(eb.label, "Extend · Draft · 480p")
        XCTAssertEqual(eb.estimate, 2.15, accuracy: 0.006)
        // A too-short source can't go backwards on the reference model, but the frame bridge can.
        XCTAssertEqual(FakeSuitePrices.pickExtend("draft", direction: "before", sourceSeconds: 1, seconds: 5)?.0.model, "kling-v4")
        XCTAssertNil(FakeSuitePrices.pickExtend("draft", direction: "after", sourceSeconds: 1, seconds: 40), "nothing fits")
        // Too long for every model on Draft: nothing_fits.
        d.duration = 40
        do {
            _ = try await a.suiteEstimate(try XCTUnwrap(d.extendRequest()))
            XCTFail("nothing fits")
        } catch let e as ApiError {
            XCTAssertEqual(e.code, "nothing_fits")
            XCTAssertTrue(e.message.contains("backwards"), e.message)
        }
        // A video that isn't the studio's, or an upload without its length.
        do {
            _ = try await a.suiteEstimate(.extendShot(SuiteVideoRef(key: "c/elsewhere.mp4", seconds: 4), duration: 5, quality: "draft"))
            XCTFail()
        } catch let e as ApiError { XCTAssertEqual(e.code, "bad_request") }
        do {
            _ = try await a.suiteEstimate(.extendShot(SuiteVideoRef(key: upload.key), duration: 5, quality: "draft"))
            XCTFail()
        } catch let e as ApiError { XCTAssertEqual(e.code, "bad_request") }

        // Generate on a take: the result is the whole longer clip (source + extension).
        let all = await a.listTakes()
        let src = try XCTUnwrap(all.compactMap { ExtendSource.take($0) }.first)
        let srcSeconds = try XCTUnwrap(src.seconds)
        var dt = ComposerDraft(tool: .extend, quality: "draft", duration: 3).extending(src)
        dt.extend.prompt = "She waves."
        let events = a.events()
        let j = try await a.suiteCreateShot(try XCTUnwrap(dt.extendRequest()))
        XCTAssertEqual(j.engineLabel, "Extend · Draft · 720p")
        XCTAssertEqual(j.request.engine, "suite")
        var made: [Take] = []
        for await ev in events {
            guard let x = ev.job, x.id == j.id, x.isDone else { continue }
            made = ev.takes ?? []
            break
        }
        let out = try XCTUnwrap(made.first)
        XCTAssertEqual(out.durationSec ?? 0, srcSeconds + 3, accuracy: 1e-9)
        XCTAssertNotNil(ExtendSource.take(out), "a new take extends again")
    }
}

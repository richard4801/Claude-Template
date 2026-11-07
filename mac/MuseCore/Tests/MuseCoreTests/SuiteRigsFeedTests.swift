import XCTest
@testable import MuseCore

/// AI suite (workstream 1, build step 2): drafts per job and photo ("Reuse settings"), saved rigs, a model's default rig and
/// the takes feed: the wire types from server-shaped JSON, the pure rules (rig ↔ chips, the default rig, the caption line,
/// the query string) and demo mode (FakeMuseAPI), which must behave like server/api (test/suite-drafts.test.ts).
final class SuiteRigsFeedTests: XCTestCase {
    private func api(speed: Double = 0) async throws -> FakeMuseAPI {
        let a = FakeMuseAPI(speed: speed, genDelay: 0.01)
        _ = try await a.signIn(SignInRequest(email: "owner@studio.com", password: "x"))
        return a
    }

    private func decode<T: Decodable>(_ s: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(s.utf8))
    }

    private func object(_ data: Data) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    private func expectError(_ code: String, message: String? = nil, _ f: () async throws -> Void) async {
        do {
            try await f()
            XCTFail("expected \(code)")
        } catch let e as ApiError {
            XCTAssertEqual(e.code, code)
            if let m = message { XCTAssertEqual(e.message, m) }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    /// The server test's draft plus keys a newer app might send.
    private let draftJson = #"{"v":1,"tool":"shot","quality":"draft","aspect":"9:16","duration":5,"takes":1,"sound":true,"speaking":null,"rig":{"body":"film_35","lens":"anamorphic","focalMm":85,"aperture":"f1.4","height":"low","shotSize":"mcu","lighting":"contre_jour","palette":"golden_warmth","gradeLook":true,"genre":"fashion","era":"1990s","tempo":"calm","moves":[{"id":"dolly_in","intensity":0.4}]},"tokens":[{"text":"She walks out to the street "},{"key":3,"move":{"id":"dolly_in","label":"Dolly in"}}],"slots":{"start":null},"composerTab":"camera","future":{"list":[1,2.5,"a",false,null],"deep":{"x":-3}}}"#

    private var shotDraft: SuiteDraft { SuiteDraft(tool: "shot", quality: "draft", aspect: "9:16", duration: 5, takes: 1, sound: true) }

    // MARK: Decoding server-shaped JSON

    func testADraftKeepsEveryKeyAndRoundTripsExactly() throws {
        let d = try decode(draftJson, as: SuiteDraft.self)
        XCTAssertEqual(d.v, 1)
        XCTAssertEqual(d.tool, "shot")
        XCTAssertEqual(d.quality, "draft")
        XCTAssertEqual(d.aspect, "9:16")
        XCTAssertEqual(d.duration, 5)
        XCTAssertEqual(d.takes, 1)
        XCTAssertNil(d.count)
        XCTAssertEqual(d.sound, true)
        XCTAssertNil(d.speaking, "null is auto")
        XCTAssertEqual(d.raw["speaking"], .null, "and stays null on the wire")
        XCTAssertEqual(d.rig?.lens, "anamorphic")
        XCTAssertEqual(d.rig?.focalMm, 85)
        XCTAssertEqual(d.rig?.moves, [SuiteRigMove(id: "dolly_in", intensity: 0.4)])
        XCTAssertEqual(d.tokens?.count, 2)
        XCTAssertEqual(d.slots, .object(["start": .null]))
        XCTAssertEqual(Set(d.extra.keys), ["composerTab", "future"])
        XCTAssertNil(d.problem)

        // Encoding gives back exactly what was sent: the same JSON object, unknown keys and nulls included.
        let again = try JSONEncoder().encode(d)
        XCTAssertEqual(try object(again), try object(Data(draftJson.utf8)))
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: again), try decode(draftJson, as: JSONValue.self))
        XCTAssertEqual(try JSONDecoder().decode(SuiteDraft.self, from: again), d)

        // Inside a job and a take ("Reuse settings"), and absent → nil.
        let job = try decode(#"{"id":"j_1","title":"Café","state":"queued","draft":"# + draftJson + #"}"#, as: Job.self)
        XCTAssertEqual(job.draft, d)
        let take = try decode(#"{"id":"t_1","kind":"take","jobId":"j_1","draft":"# + draftJson + #"}"#, as: Take.self)
        XCTAssertEqual(take.draft, d)
        XCTAssertNil(try decode(#"{"id":"j_2"}"#, as: Job.self).draft)
        XCTAssertNil(try decode(#"{"id":"t_2"}"#, as: Take.self).draft)
        XCTAssertNil(try decode(#"{"id":"t_3","draft":"nope"}"#, as: Take.self).draft, "tolerant: a draft that isn't an object is nil")
        XCTAssertEqual(try object(JSONEncoder().encode(job))["draft"] as? NSDictionary, try object(Data(draftJson.utf8)))
        XCTAssertNil(try object(JSONEncoder().encode(try decode(#"{"id":"j_2"}"#, as: Job.self)))["draft"], "no draft, no key")
    }

    func testDraftAccessorsAndTheServersChecks() throws {
        var d = SuiteDraft(tool: "photo", aspect: "4:5", count: 4, rig: SuiteRig(lighting: "window"), extra: ["custom": .object(["x": .number(1)]), "tool": .string("ignored")])
        XCTAssertEqual(d.tool, "photo", "a known key in extra doesn't override")
        XCTAssertEqual(d.v, 1)
        XCTAssertEqual(d.extra, ["custom": .object(["x": .number(1)])])
        XCTAssertEqual(d.rig, SuiteRig(lighting: "window"))
        XCTAssertEqual(d.raw["rig"], .object(["lighting": .string("window")]), "the rig without nulls")
        d.aspect = nil
        XCTAssertNil(d.raw["aspect"], "nil removes the key")
        d.extra = ["other": .bool(true)]
        XCTAssertEqual(Set(d.raw.keys), ["v", "tool", "count", "rig", "other"])
        XCTAssertNil(d.problem)

        XCTAssertEqual(SuiteDraft(raw: ["quality": .string("hd")]).problem, "tool: Required")
        XCTAssertNotNil(SuiteDraft(raw: ["tool": .string("video")]).problem)
        XCTAssertNotNil(SuiteDraft(raw: ["tool": .string("photo"), "tokens": .string("nope")]).problem)
        XCTAssertNotNil(SuiteDraft(raw: ["tool": .string("shot"), "takes": .number(9)]).problem)
        XCTAssertNotNil(SuiteDraft(raw: ["tool": .string("shot"), "tokens": .array(Array(repeating: .string("x"), count: 401))]).problem)
        XCTAssertNotNil(SuiteDraft(raw: ["tool": .string("shot"), "tokens": .array([.string(String(repeating: "x", count: 70_000))])]).problem, "at most 64 KB")
        XCTAssertNil(SuiteDraft(raw: ["tool": .string("shot"), "speaking": .null]).problem)

        // Sent with a shot or photo request only when set.
        var shot = ShotRequest(modelId: "m_1", prompt: "She waves.")
        XCTAssertNil(try object(JSONEncoder().encode(shot))["draft"])
        shot.draft = shotDraft
        XCTAssertEqual((try object(JSONEncoder().encode(shot))["draft"] as? NSDictionary)?["tool"] as? String, "shot")
        var photo = PhotoRequest(modelId: "m_1", count: 2)
        XCTAssertNil(try object(JSONEncoder().encode(photo))["draft"])
        photo.draft = SuiteDraft(tool: "photo", count: 2)
        XCTAssertEqual((try object(JSONEncoder().encode(photo))["draft"] as? NSDictionary)?["count"] as? Int, 2)
    }

    func testRigsAndRigViewsDecodeAndEncodeWithoutNulls() throws {
        let rig = try decode(#"{"body":"film_35","focalMm":85,"gradeLook":false,"moves":[{"id":"dolly_in","intensity":0.4},{"id":"orbit_left"}]}"#, as: SuiteRig.self)
        XCTAssertEqual(rig, SuiteRig(body: "film_35", focalMm: 85, gradeLook: false, moves: [SuiteRigMove(id: "dolly_in", intensity: 0.4), SuiteRigMove(id: "orbit_left")]))
        XCTAssertEqual(try decode("{}", as: SuiteRig.self), SuiteRig())
        XCTAssertTrue(SuiteRig().isEmpty)
        XCTAssertFalse(SuiteRig(moves: []).isEmpty, "an empty moves list is a key, as on the server")
        // The server refuses unknown fields and accepts missing ones: nil fields are left out.
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(SuiteRig(body: "phone")), as: UTF8.self), #"{"body":"phone"}"#)
        XCTAssertEqual(try object(JSONEncoder().encode(SuiteRig(moves: [SuiteRigMove(id: "tilt_up")]))), ["moves": [["id": "tilt_up"]]] as NSDictionary)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(SuiteRig()), as: UTF8.self), "{}")
        XCTAssertEqual(try object(JSONEncoder().encode(SuiteRigPatch(name: "x"))), ["name": "x"] as NSDictionary)
        // The default rig PATCH always sends the key; null clears.
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(DefaultRigPatch(defaultRig: nil)), as: UTF8.self), #"{"defaultRig":null}"#)
        XCTAssertEqual(try object(JSONEncoder().encode(DefaultRigPatch(defaultRig: SuiteRig(era: "1970s")))), ["defaultRig": ["era": "1970s"]] as NSDictionary)

        let view = try decode(#"{"id":"rig_1","name":"Golden film","rig":{"palette":"golden_warmth"},"userId":"u_1","mine":true,"createdAt":1762300000000,"updatedAt":1762300000500}"#,
                              as: SuiteRigView.self)
        XCTAssertEqual(view, SuiteRigView(id: "rig_1", name: "Golden film", rig: SuiteRig(palette: "golden_warmth"), userId: "u_1", mine: true,
                                          createdAt: 1_762_300_000_000, updatedAt: 1_762_300_000_500))
        let sparse = try decode(#"{"id":"rig_2","createdAt":1762300000000.0}"#, as: SuiteRigView.self)
        XCTAssertEqual(sparse.rig, SuiteRig())
        XCTAssertFalse(sparse.mine)
        XCTAssertEqual(sparse.createdAt, 1_762_300_000_000)

        // A model's default rig: decoded when present, nil when absent, and left out of the JSON when nil.
        let m = try decode(#"{"id":"m_1","name":"Demo model","defaultRig":{"body":"film_35","palette":"golden_warmth","moves":[{"id":"orbit_left"}]}}"#, as: MuseModel.self)
        XCTAssertEqual(m.defaultRig, SuiteRig(body: "film_35", palette: "golden_warmth", moves: [SuiteRigMove(id: "orbit_left")]))
        let plain = try decode(#"{"id":"m_2","name":"Demo model B"}"#, as: MuseModel.self)
        XCTAssertNil(plain.defaultRig)
        XCTAssertNil(try object(JSONEncoder().encode(plain))["defaultRig"])
    }

    func testFeedItemsAndPagesDecodeTolerantly() throws {
        let page = try decode(#"""
        {"items":[
          {"id":"j_1","kind":"job","status":"running","tool":"shot","jobId":"j_1","title":"Café","modelId":"m_1","modelName":"Demo model","createdAt":1762300002000,
           "poster":{"url":"/files/a.jpg"},"aspect":"9:16","durationSec":5,"takes":1,"price":0.1,"progress":42,"phase":"Rendering","secondsLeft":30,
           "label":"Shot · Draft · 768p","summary":"9:16, 5 s, 1 take, sound on"},
          {"id":"j_0","kind":"job","status":"failed","tool":"swap","jobId":"j_0","title":"Mirror","createdAt":1762300001500,"price":0.19,"progress":18,
           "error":"Something went wrong","errorCode":"provider_failed","refunded":0.19,"takes":1,"summary":"9:16"},
          {"id":"t_1","kind":"take","status":"done","tool":"shot","jobId":"j_9","takeId":"t_1","title":"Café","label":"Draft","modelId":"m_1","createdAt":1762300001000,
           "poster":{"url":"/files/t.jpg"},"videoUrl":"/uploads/r/j_9/take_1.mp4","aspect":"9:16","durationSec":5.04,"index":1,"of":2,"price":0.05,"final":true,
           "summary":"9:16, 5 s, 2 takes, sound on"},
          {"id":"s_1","kind":"photo"}
        ],"nextCursor":"WzE3NjIzMDAwMDAwMDAsInNfMSJd"}
        """#, as: SuiteFeedPage.self)
        XCTAssertEqual(page.items.count, 4)
        XCTAssertEqual(page.nextCursor, "WzE3NjIzMDAwMDAwMDAsInNfMSJd")
        let job = page.items[0]
        XCTAssertTrue(job.isJob && job.isActive)
        XCTAssertEqual(job.createdAt, 1_762_300_002_000)
        XCTAssertEqual(job.poster, ImageRef(url: "/files/a.jpg"))
        XCTAssertEqual(job.progress, 42)
        XCTAssertEqual(job.secondsLeft, 30)
        XCTAssertEqual(job.label, "Shot · Draft · 768p")
        XCTAssertEqual(job.summary, "9:16, 5 s, 1 take, sound on")
        XCTAssertNil(job.takeId)
        let failed = page.items[1]
        XCTAssertTrue(failed.isFailed)
        XCTAssertEqual(failed.error, "Something went wrong")
        XCTAssertEqual(failed.errorCode, "provider_failed")
        XCTAssertEqual(failed.refunded, 0.19)
        XCTAssertNil(failed.modelId)
        let take = page.items[2]
        XCTAssertTrue(take.isVideoTake)
        XCTAssertEqual(take.takeId, "t_1")
        XCTAssertEqual(take.videoUrl, "/uploads/r/j_9/take_1.mp4")
        XCTAssertEqual(take.durationSec, 5.04)
        XCTAssertEqual(take.index, 1)
        XCTAssertEqual(take.of, 2)
        XCTAssertTrue(take.isFinal)
        let bare = page.items[3]
        XCTAssertTrue(bare.isPhoto)
        XCTAssertEqual(bare.status, "done")
        XCTAssertEqual(bare.tool, "photo")
        XCTAssertEqual(bare.price, 0)
        XCTAssertFalse(bare.isFinal)
        XCTAssertNil(try decode(#"{"items":[],"nextCursor":null}"#, as: SuiteFeedPage.self).nextCursor)
        XCTAssertEqual(try decode("{}", as: SuiteFeedPage.self).items, [])
        // Encodes back with the server's key for final, and no nulls.
        let back = try object(JSONEncoder().encode(take))
        XCTAssertEqual(back["final"] as? Bool, true)
        XCTAssertNil(back["progress"])
    }

    // MARK: Pure rules

    func testRigAndComposerSettingsConvertBothWays() {
        let rig = SuiteRig(body: "film_35", lens: "anamorphic", focalMm: 85, aperture: "f1.4", height: "low", shotSize: "mcu", lighting: "contre_jour",
                           palette: "golden_warmth", stock: "portrait_negative", gradeLook: false, genre: "fashion", era: "1990s", tempo: "calm", format: "review",
                           moves: [SuiteRigMove(id: "dolly_in")])
        let s = rig.settings
        XCTAssertEqual(s, ComposerSettings(body: "film_35", lens: "anamorphic", focalMm: 85, aperture: "f1.4", height: "low", shotSize: "mcu", genre: "fashion",
                                           era: "1990s", tempo: "calm", palette: "golden_warmth", stock: "portrait_negative", gradeLook: false,
                                           lighting: "contre_jour", format: "review"))
        var back = SuiteRig(s)
        XCTAssertNil(back.moves, "moves aside: they are # chips")
        back.moves = rig.moves
        XCTAssertEqual(back, rig)
        XCTAssertEqual(SuiteRig(s, moves: rig.moves), rig)
        // Settings → rig → settings is exact (the preset is not part of a rig); grading on is the default and left out.
        let chips = ComposerSettings(lens: "clean", palette: "hyper_neon", gradeLook: true, lighting: "neon")
        XCTAssertEqual(SuiteRig(chips), SuiteRig(lens: "clean", lighting: "neon", palette: "hyper_neon"))
        XCTAssertEqual(SuiteRig(chips).settings, chips)
        XCTAssertEqual(SuiteRig().settings, ComposerSettings())
        XCTAssertTrue(SuiteRig(ComposerSettings()).isEmpty)
        var preset = chips
        preset.preset = "golden_hour_portrait"
        XCTAssertEqual(SuiteRig(preset), SuiteRig(chips))
    }

    func testTheDefaultRigFillsOnlyAutoRows() {
        let rig = SuiteRig(body: "film_35", lens: "warm_vintage", focalMm: 50, lighting: "window", palette: "golden_warmth", gradeLook: false, era: "1970s",
                           moves: [SuiteRigMove(id: "dolly_in")])
        // Everything Auto: every row of the rig fills (moves aside).
        let (all, filled) = applyDefaultRig(rig, to: ComposerSettings())
        XCTAssertEqual(all, ComposerSettings(body: "film_35", lens: "warm_vintage", focalMm: 50, era: "1970s", palette: "golden_warmth", gradeLook: false, lighting: "window"))
        XCTAssertEqual(filled, ["body", "lens", "focalMm", "lighting", "palette", "gradeLook", "era"])

        // Rows the user set are never overwritten; the Look was set, so its grading stays as the user left it.
        let mine = ComposerSettings(body: "phone", stock: "bw_film", gradeLook: true, lighting: "ring_light", preset: "p1")
        let (out, f2) = applyDefaultRig(rig, to: mine)
        XCTAssertEqual(out.body, "phone")
        XCTAssertEqual(out.lighting, "ring_light")
        XCTAssertEqual(out.stock, "bw_film")
        XCTAssertEqual(out.palette, "golden_warmth", "palette was still Auto")
        XCTAssertTrue(out.gradeLook)
        XCTAssertEqual(out.lens, "warm_vintage")
        XCTAssertEqual(out.preset, "p1")
        XCTAssertEqual(f2, ["lens", "focalMm", "palette", "era"])

        // Nothing to fill: nothing applied (no "Applied …'s rig · Undo").
        let (same, none) = applyDefaultRig(rig, to: all)
        XCTAssertEqual(same, all)
        XCTAssertEqual(none, [])
        XCTAssertEqual(applyDefaultRig(SuiteRig(), to: mine).filled, [])
    }

    func testTheCaptionLineAndTheAspect() {
        XCTAssertEqual(SuiteFeedText.summary(try? decode(draftJson, as: SuiteDraft.self)), "9:16, 5 s, 1 take, sound on")
        XCTAssertEqual(SuiteFeedText.summary(SuiteDraft(tool: "shot", aspect: "16:9", duration: 7.5, takes: 2, sound: false)), "16:9, 7.5 s, 2 takes, sound off")
        XCTAssertEqual(SuiteFeedText.summary(SuiteDraft(tool: "photo", aspect: "4:5", count: 1)), "4:5, 1 photo")
        XCTAssertEqual(SuiteFeedText.summary(nil, aspect: "9:16", count: 3), "9:16, 3 photos")
        XCTAssertEqual(SuiteFeedText.summary(nil, seconds: 10, takes: 1), "10 s, 1 take")
        XCTAssertEqual(SuiteFeedText.summary(SuiteDraft(tool: "shot"), aspect: "9:16", seconds: 6.04, takes: 2, sound: true), "9:16, 6 s, 2 takes, sound on",
                       "the request fills what the draft leaves out")
        XCTAssertEqual(SuiteFeedText.aspect(width: 768, height: 1344), "9:16")
        XCTAssertEqual(SuiteFeedText.aspect(width: 1920, height: 1080), "16:9")
        XCTAssertEqual(SuiteFeedText.aspect(width: 1080, height: 1350), "4:5")
        XCTAssertNil(SuiteFeedText.aspect(width: 0, height: 10))
        XCTAssertNil(SuiteFeedText.aspect(width: nil, height: 10))
    }

    func testTheFeedQueryString() {
        XCTAssertEqual(SuiteFeedQuery().path, "v1/suite/feed")
        XCTAssertEqual(SuiteFeedQuery().queryString, "")
        let q = SuiteFeedQuery(tool: ["shot", "photo"], status: ["done"], model: "m_demo", cursor: "WzE3NjIsInRfMSJd", limit: 10)
        XCTAssertEqual(q.path, "v1/suite/feed?tool=shot,photo&status=done&model=m_demo&cursor=WzE3NjIsInRfMSJd&limit=10")
        XCTAssertEqual(SuiteFeedQuery(tool: [" swap ", ""], status: [], model: "").queryString, "tool=swap", "blanks are left out")
        XCTAssertEqual(SuiteFeedQuery(model: "a b&c=d").queryString, "model=a%20b%26c%3Dd")
        XCTAssertEqual(SuiteFeedQuery(status: ["queued", "running"], limit: 60).next("abc-_").queryString, "status=queued,running&cursor=abc-_&limit=60")
        XCTAssertEqual(q.next(nil).queryString, "tool=shot,photo&status=done&model=m_demo&limit=10")
        // The demo's cursor is the server's: base64url JSON of [createdAt, id].
        let c = SuiteFeedCursor.encode(1_762_300_000_000, "s_1")
        XCTAssertEqual(c, "WzE3NjIzMDAwMDAwMDAsInNfMSJd")
        XCTAssertEqual(SuiteFeedCursor.decode(c)?.0, 1_762_300_000_000)
        XCTAssertEqual(SuiteFeedCursor.decode(c)?.1, "s_1")
        XCTAssertNil(SuiteFeedCursor.decode("bm9wZQ"))
    }

    func testRigsAreCheckedAgainstTheCameraCatalog() {
        let cat = SuiteDemoCatalog.catalog.camera
        XCTAssertNil(SuiteRig(body: "film_35", lens: "anamorphic", focalMm: 85, aperture: "f1.4", height: "low", shotSize: "mcu", lighting: "contre_jour",
                              palette: "golden_warmth", stock: "slide_film", gradeLook: true, genre: "fashion", era: "1990s", tempo: "calm", format: "unboxing",
                              moves: [SuiteRigMove(id: "dolly_in", intensity: 0.4)]).problem(in: cat))
        XCTAssertNil(SuiteRig(body: "super35", lens: "vintage", aperture: "f2", moves: [SuiteRigMove(id: "rise_reveal")]).problem(in: cat), "hidden and merged ids are fine")
        XCTAssertEqual(SuiteRig(lens: "fisheye_9000").problem(in: cat), #"rig.lens: unknown lens "fisheye_9000""#)
        XCTAssertEqual(SuiteRig(era: "2077s").problem(in: cat), #"rig.era: unknown era "2077s""#)
        XCTAssertEqual(SuiteRig(body: "vhs_9000").problem(in: cat, field: "defaultRig"), #"defaultRig.body: unknown camera body "vhs_9000""#)
        XCTAssertNotNil(SuiteRig(focalMm: 400).problem(in: cat))
        XCTAssertNotNil(SuiteRig(moves: [SuiteRigMove(id: "dolly_in"), SuiteRigMove(id: "orbit_left"), SuiteRigMove(id: "tilt_up")]).problem(in: cat))
        XCTAssertNotNil(SuiteRig(moves: [SuiteRigMove(id: "dolly_in", intensity: 1.5)]).problem(in: cat))
        XCTAssertNotNil(SuiteRig(moves: [SuiteRigMove(id: "moonwalk")]).problem(in: cat))
    }

    // MARK: Demo mode

    func testDemoRigsMemberAndOwnerViewsAndPermissions() async throws {
        let a = try await api()
        // The owner sees the whole studio's rigs, theirs first, most recently changed first.
        let start = try await a.suiteRigs()
        XCTAssertEqual(start.map(\.name), ["Golden film", "Talking head", "Neon night"])
        XCTAssertEqual(start.map(\.mine), [true, true, false])
        for r in start { XCTAssertNil(r.rig.problem(in: SuiteDemoCatalog.catalog.camera), "demo rigs use catalog ids") }

        let made = try await a.createSuiteRig(name: "  Window light  ", rig: SuiteRig(lighting: "window", palette: "naturalistic"))
        XCTAssertEqual(made.name, "Window light", "trimmed")
        XCTAssertTrue(made.mine)
        XCTAssertEqual(made.userId, "u1")
        let newest = try await a.suiteRigs()
        XCTAssertEqual(newest.first?.id, made.id, "newest first")

        await expectError("bad_request", message: #"rig.lens: unknown lens "fisheye_9000""#) { _ = try await a.createSuiteRig(name: "x", rig: SuiteRig(lens: "fisheye_9000")) }
        await expectError("bad_request", message: "Give the rig a name") { _ = try await a.createSuiteRig(name: "   ", rig: SuiteRig()) }
        await expectError("bad_request") { _ = try await a.createSuiteRig(name: String(repeating: "a", count: 61), rig: SuiteRig()) }
        _ = try await a.createSuiteRig(name: String(repeating: "a", count: 60), rig: SuiteRig())
        await expectError("not_found") { _ = try await a.updateSuiteRig(id: "rig_nope", name: "x", rig: nil) }

        // A member keeps her own rigs; the owner's read as not found.
        await a.setUser(id: "u_maya", role: "member")
        let hers = try await a.suiteRigs()
        XCTAssertEqual(hers.map(\.name), ["Neon night"])
        XCTAssertEqual(hers.first?.mine, true)
        await expectError("not_found") { _ = try await a.updateSuiteRig(id: made.id, name: "Mine now", rig: nil) }
        await expectError("not_found") { try await a.deleteSuiteRig(id: made.id) }
        let renamed = try await a.updateSuiteRig(id: "rig_demo_neon", name: "Neon", rig: SuiteRig(palette: "cyber_magenta"))
        XCTAssertEqual(renamed.name, "Neon")
        XCTAssertEqual(renamed.rig, SuiteRig(palette: "cyber_magenta"), "rig replaces the whole rig")
        XCTAssertGreaterThanOrEqual(renamed.updatedAt, start[2].updatedAt)
        let untouched = try await a.updateSuiteRig(id: "rig_demo_neon", name: nil, rig: nil)
        XCTAssertEqual(untouched, renamed)

        // The owner may tidy any rig.
        await a.setUser(id: "u1", role: "owner")
        let all = try await a.suiteRigs()
        XCTAssertEqual(all.last?.name, "Neon")
        XCTAssertEqual(all.last?.mine, false)
        let tidied = try await a.updateSuiteRig(id: "rig_demo_neon", name: "Neon 2", rig: nil)
        XCTAssertEqual(tidied.name, "Neon 2")
        try await a.deleteSuiteRig(id: "rig_demo_neon")
        await a.setUser(id: "u_maya", role: "member")
        let none = try await a.suiteRigs()
        XCTAssertEqual(none, [])
    }

    func testAtMostAHundredRigsPerPerson() async throws {
        let a = try await api()
        await a.setUser(id: "u_theo", role: "member")
        for i in 1...SuiteRigView.maxPerUser { _ = try await a.createSuiteRig(name: "Rig \(i)", rig: SuiteRig(era: "1990s")) }
        await expectError("too_many_rigs") { _ = try await a.createSuiteRig(name: "One more", rig: SuiteRig()) }
        // The cap is per person: the owner can still save one.
        await a.setUser(id: "u1", role: "owner")
        _ = try await a.createSuiteRig(name: "One more", rig: SuiteRig())
        let everyone = try await a.suiteRigs()
        XCTAssertEqual(everyone.count, 3 + SuiteRigView.maxPerUser + 1)
    }

    func testAModelsDefaultRigIsSetAndCleared() async throws {
        let a = try await api()
        let models = try await a.listModels()
        let demo = try XCTUnwrap(models.first { $0.id == SampleData.demo })
        XCTAssertNotNil(demo.defaultRig, "the demo model starts with one")
        XCTAssertNil(demo.defaultRig?.problem(in: SuiteDemoCatalog.catalog.camera))

        let rig = SuiteRig(body: "film_35", palette: "golden_warmth", moves: [SuiteRigMove(id: "orbit_left")])
        let set = try await a.setModelDefaultRig(modelId: SampleData.demoB, rig: rig)
        XCTAssertEqual(set.defaultRig, rig)
        var listed = try await a.listModels()
        XCTAssertEqual(listed.first { $0.id == SampleData.demoB }?.defaultRig, rig)
        await expectError("bad_request", message: #"defaultRig.body: unknown camera body "vhs_9000""#) {
            _ = try await a.setModelDefaultRig(modelId: SampleData.demoB, rig: SuiteRig(body: "vhs_9000"))
        }
        listed = try await a.listModels()
        XCTAssertEqual(listed.first { $0.id == SampleData.demoB }?.defaultRig, rig, "a refused change leaves it")
        // Other edits leave it alone.
        _ = try await a.updateModel(id: SampleData.demoB, UpdateModelRequest(name: "Demo model B"))
        listed = try await a.listModels()
        XCTAssertEqual(listed.first { $0.id == SampleData.demoB }?.defaultRig, rig)
        let cleared = try await a.setModelDefaultRig(modelId: SampleData.demoB, rig: nil)
        XCTAssertNil(cleared.defaultRig, "null clears")
        _ = try await a.setModelDefaultRig(modelId: SampleData.demoB, rig: rig)
        let autoAll = try await a.setModelDefaultRig(modelId: SampleData.demoB, rig: SuiteRig())
        XCTAssertNil(autoAll.defaultRig, "all Auto = none")
        await expectError("not_found") { _ = try await a.setModelDefaultRig(modelId: "m_nope", rig: nil) }
        // Members may set it too, like her other fields.
        await a.setRole("member")
        let byMember = try await a.setModelDefaultRig(modelId: SampleData.demoB, rig: rig)
        XCTAssertEqual(byMember.defaultRig, rig)
    }

    func testDraftsAreKeptAndABadOneIsRefusedFirst() async throws {
        let a = try await api()
        let before = try await a.balance().balance
        await expectError("bad_request") {
            var r = ShotRequest(modelId: SampleData.demo, prompt: "x", duration: 5)
            r.draft = SuiteDraft(raw: ["tool": .string("hologram")])
            _ = try await a.suiteCreateShot(r)
        }
        await expectError("bad_request") {
            var p = PhotoRequest(modelId: SampleData.demo, count: 1)
            p.draft = SuiteDraft(raw: ["tool": .string("photo"), "tokens": .string("nope")])
            _ = try await a.suiteCreatePhotos(p)
        }
        let after = try await a.balance().balance
        XCTAssertEqual(before, after, accuracy: 1e-9, "nothing was held")

        let draft = try decode(draftJson, as: SuiteDraft.self)
        var r = ShotRequest(modelId: SampleData.demo, prompt: "She walks out to the street.", duration: 5)
        r.draft = draft
        let job = try await a.suiteCreateShot(r)
        XCTAssertEqual(job.draft, draft)
        let jobs = try await a.listJobs()
        XCTAssertEqual(jobs.first { $0.id == job.id }?.draft, draft)

        var p = PhotoRequest(modelId: SampleData.demo, prompt: "A café window seat.", count: 2)
        let photoDraft = SuiteDraft(tool: "photo", aspect: "9:16", count: 2, rig: SuiteRig(lighting: "window"), tokens: [.object(["text": .string("A café window seat.")])])
        p.draft = photoDraft
        let stills = try await a.suiteCreatePhotos(p)
        XCTAssertEqual(stills.count, 2)
        XCTAssertTrue(stills.allSatisfy { $0.draft == photoDraft })
        let stored = try await a.listTakes().filter { t in stills.contains { $0.id == t.id } }
        XCTAssertEqual(stored.count, 2)
        XCTAssertTrue(stored.allSatisfy { $0.draft == photoDraft })
        let plain = try await a.suiteCreatePhotos(PhotoRequest(modelId: SampleData.demo, count: 1))
        XCTAssertNil(plain.first?.draft, "no draft stays no draft")

        // A swap keeps its draft too.
        let clip = try await a.uploadClip(SampleData.sampleMeta, file: nil)
        var swap = ShotRequest(mode: "swap", modelId: SampleData.demo, clipId: clip.id)
        swap.draft = SuiteDraft(tool: "swap", aspect: "9:16")
        let sj = try await a.suiteCreateShot(swap)
        XCTAssertEqual(sj.draft?.tool, "swap")
        let jobsAfter = try await a.listJobs()
        XCTAssertEqual(jobsAfter.first { $0.id == sj.id }?.draft?.tool, "swap")
    }

    func testAFinishedShotsTakesCarryItsDraftIntoTheFeed() async throws {
        let a = try await api(speed: 300)
        let events = a.events()
        var r = ShotRequest(title: "Café morning", modelId: SampleData.demo, prompt: "She waves.", duration: 5, quality: "draft")
        r.draft = shotDraft
        let job = try await a.suiteCreateShot(r)
        var done: [Take] = []
        for await e in events {
            guard let j = e.job, j.id == job.id else { continue }
            if j.isDone { done = e.takes ?? []; break }
            if j.isFailed { XCTFail("the shot failed"); break }
        }
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(done.first?.draft, shotDraft)
        let takes = try await a.listTakes()
        XCTAssertEqual(takes.first { $0.jobId == job.id }?.draft, shotDraft)

        // The job's card gives way to its take.
        let feed = try await a.suiteFeed(SuiteFeedQuery(tool: ["shot"]))
        XCTAssertFalse(feed.items.contains { $0.id == job.id })
        let take = try XCTUnwrap(feed.items.first { $0.jobId == job.id })
        XCTAssertEqual(take.kind, "take")
        XCTAssertEqual(take.status, "done")
        XCTAssertEqual(take.tool, "shot")
        XCTAssertEqual(take.takeId, take.id)
        XCTAssertEqual(take.summary, "9:16, 5 s, 1 take, sound on")
        XCTAssertEqual(take.modelName, SampleData.demoName)
        XCTAssertEqual(take.label, "Draft")
    }

    func testTheDemoFeedOrderFiltersAndPaging() async throws {
        let a = try await api()
        var r = ShotRequest(title: "Café morning", modelId: SampleData.demo, prompt: "She waves.", duration: 5, quality: "draft")
        r.draft = shotDraft
        let shot = try await a.suiteCreateShot(r)
        var p = PhotoRequest(modelId: SampleData.demo, prompt: "A café window seat.", count: 2)
        p.draft = SuiteDraft(tool: "photo", aspect: "4:5", count: 2)
        let stills = try await a.suiteCreatePhotos(p)

        let f = try await a.suiteFeed(SuiteFeedQuery())
        XCTAssertNil(f.nextCursor)
        let kinds = f.items.map { "\($0.kind):\($0.tool):\($0.status)" }
        // The two photos (newest), the queued shot, then the seeded queued and failed jobs, then the seeded takes and photos.
        XCTAssertEqual(Array(kinds.prefix(5)), ["photo:photo:done", "photo:photo:done", "job:shot:queued", "job:swap:queued", "job:swap:failed"])
        XCTAssertEqual(Set(f.items.prefix(2).map(\.id)), Set(stills.map(\.id)))
        XCTAssertEqual(kinds.filter { $0 == "photo:photo:done" }.count, 5)
        XCTAssertEqual(kinds.filter { $0 == "take:swap:done" }.count, 4)
        XCTAssertEqual(f.items.count, 2 + 1 + 2 + 7)
        let times = f.items.map(\.createdAt)
        XCTAssertEqual(times, times.sorted(by: >), "newest first")
        XCTAssertEqual(Set(f.items.map(\.id)).count, f.items.count)

        let photo = f.items[0]
        XCTAssertEqual(photo.summary, "4:5, 2 photos")
        XCTAssertEqual(photo.aspect, "4:5")
        XCTAssertEqual(photo.modelId, SampleData.demo)
        XCTAssertEqual(photo.modelName, SampleData.demoName)
        XCTAssertNil(photo.videoUrl)
        XCTAssertNil(photo.durationSec)
        let card = f.items[2]
        XCTAssertEqual(card.id, shot.id)
        XCTAssertEqual(card.jobId, shot.id)
        XCTAssertEqual(card.title, "Café morning")
        XCTAssertEqual(card.summary, "9:16, 5 s, 1 take, sound on")
        XCTAssertEqual(card.label, "Shot · Draft · 768p")
        XCTAssertEqual(card.price, shot.cost, accuracy: 1e-9)
        XCTAssertEqual(card.modelName, SampleData.demoName)
        XCTAssertNil(card.secondsLeft, "only while running")
        let failed = try XCTUnwrap(f.items.first { $0.isFailed })
        XCTAssertNotNil(failed.error)
        XCTAssertEqual(failed.refunded, 0.19)
        // Member-safe: no providers or engine names.
        let all = String(decoding: try JSONEncoder().encode(f), as: UTF8.self)
        XCTAssertNil(all.range(of: #"\b(replicate|fal|runpod|minimax|kling|seedance|veo|wan-2|ltx)\b"#, options: [.regularExpression, .caseInsensitive]))

        // Filters: tool, status, model; combinable; comma lists.
        func only(_ q: SuiteFeedQuery) async throws -> [String] { try await a.suiteFeed(q).items.map { "\($0.kind):\($0.tool):\($0.status)" } }
        let photos = try await only(SuiteFeedQuery(tool: ["photo"]))
        XCTAssertEqual(Set(photos), ["photo:photo:done"])
        XCTAssertEqual(photos.count, 5)
        let queued = try await a.suiteFeed(SuiteFeedQuery(status: ["queued"]))
        XCTAssertEqual(queued.items.map(\.id), [shot.id, "j3"])
        let doneVideo = try await only(SuiteFeedQuery(tool: ["shot", "swap"], status: ["done"]))
        XCTAssertEqual(Set(doneVideo), ["take:swap:done"])
        let shots = try await only(SuiteFeedQuery(tool: ["shot"]))
        XCTAssertEqual(shots, ["job:shot:queued"])
        let running = try await only(SuiteFeedQuery(status: ["running"]))
        XCTAssertEqual(running, [])
        let ofB = try await only(SuiteFeedQuery(model: SampleData.demoB))
        XCTAssertEqual(ofB, [])
        let ofDemo = try await only(SuiteFeedQuery(model: SampleData.demo))
        XCTAssertEqual(ofDemo.count, f.items.count)
        await expectError("bad_request") { _ = try await a.suiteFeed(SuiteFeedQuery(status: ["lost"])) }
        await expectError("bad_request") { _ = try await a.suiteFeed(SuiteFeedQuery(tool: ["video"])) }
        await expectError("bad_request") { _ = try await a.suiteFeed(SuiteFeedQuery(limit: 61)) }
        await expectError("bad_request") { _ = try await a.suiteFeed(SuiteFeedQuery(limit: 0)) }
        await expectError("bad_request", message: "Invalid cursor") { _ = try await a.suiteFeed(SuiteFeedQuery(cursor: "bm9wZQ")) }

        // Paging: every item once, in order, until nextCursor is nil.
        let ids = f.items.map(\.id)
        for size in [1, 2, 5] {
            var seen: [String] = []
            var cursor: String?
            var pages = 0
            repeat {
                let page = try await a.suiteFeed(SuiteFeedQuery(cursor: cursor, limit: size))
                XCTAssertLessThanOrEqual(page.items.count, size)
                seen += page.items.map(\.id)
                cursor = page.nextCursor
                pages += 1
            } while cursor != nil && pages < 50
            XCTAssertEqual(seen, ids, "limit \(size)")
            XCTAssertEqual(pages, (ids.count + size - 1) / size)
        }
        // Filters page too.
        let first = try await a.suiteFeed(SuiteFeedQuery(tool: ["photo"], limit: 3))
        XCTAssertEqual(first.items.count, 3)
        let rest = try await a.suiteFeed(SuiteFeedQuery(tool: ["photo"], limit: 3).next(first.nextCursor))
        XCTAssertEqual(rest.items.count, 2)
        XCTAssertNil(rest.nextCursor)

        // The default page is 30.
        for i in 0..<12 { _ = try await a.createSuiteRig(name: "unused \(i)", rig: SuiteRig()) } // rigs never appear in the feed
        for _ in 0..<6 { _ = try await a.suiteCreatePhotos(PhotoRequest(modelId: SampleData.demo, count: 4)) }
        let big = try await a.suiteFeed(SuiteFeedQuery())
        XCTAssertEqual(big.items.count, SuiteFeedQuery.defaultLimit)
        XCTAssertNotNil(big.nextCursor)
        let most = try await a.suiteFeed(SuiteFeedQuery(limit: 60))
        XCTAssertEqual(most.items.count, f.items.count + 24)

        // Jobs deleted from Queue drop out with their takes.
        await a.removeJob(id: "j1")
        let withoutJ1 = try await a.suiteFeed(SuiteFeedQuery(limit: 60))
        XCTAssertFalse(withoutJ1.items.contains { $0.jobId == "j1" })
        await a.removeJob(id: shot.id)
        let queuedAfter = try await a.suiteFeed(SuiteFeedQuery(status: ["queued"]))
        XCTAssertEqual(queuedAfter.items.map(\.id), ["j3"])
    }
}

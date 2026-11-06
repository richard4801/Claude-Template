import XCTest
@testable import MuseCore

final class ClipAndClockTests: XCTestCase {
    func testSampleClipPassesAndBadClipFails() {
        let good = ClipRules.checks(SampleData.sampleMeta)
        XCTAssertEqual(good.map(\.label), ["One person in frame", "Watermark", "1080×1920 · 30fps", "Length 9.4s", "Performer talking"])
        XCTAssertFalse(good.contains { $0.status == "bad" })
        let bad = ClipRules.checks(SampleData.badMeta)
        XCTAssertEqual(bad[0].value, "2 found")
        XCTAssertEqual(bad[1].fix, "Use the original file, not a download")
        XCTAssertEqual(bad[3].label, "Length 22s")
        XCTAssertEqual(bad[3].value, "Over 15s")
        XCTAssertEqual(bad.filter { $0.status == "bad" }.count, 3)
    }

    func testLandscapeAndLowResAreFlagged() {
        XCTAssertEqual(ClipRules.checks(ClipMeta(name: "x", durationSec: 5, width: 1920, height: 1080, fps: 30))[2].value, "Landscape")
        XCTAssertEqual(ClipRules.checks(ClipMeta(name: "x", durationSec: 5, width: 480, height: 854, fps: 30))[2].value, "Low res")
    }

    func testJobClockPhases() {
        let req = JobRequest(title: "t", modelId: "m", outfitId: "o", clipId: "c")
        let total = Pricing.totalSeconds(req.spec)
        XCTAssertEqual(JobClock.progress(req, elapsed: 0).phase, "Getting ready · ~11 min left")
        let mid = JobClock.progress(req, elapsed: total / 2)
        XCTAssertEqual(mid.step, 5, "step is kept for progress maths")
        XCTAssertTrue(mid.phase.hasPrefix("Rendering · "), mid.phase)
        XCTAssertEqual(JobClock.progress(req, elapsed: total).phase, "Done")
        XCTAssertEqual(JobClock.progress(req, elapsed: total).progress, 100)
        var two = req
        two.takes = 2
        XCTAssertTrue(JobClock.progress(two, elapsed: Pricing.totalSeconds(two.spec) * 0.75).phase.hasPrefix("take 2/2 · Rendering"))
        var lip = req
        lip.lipSync = true
        XCTAssertTrue(JobClock.progress(lip, elapsed: Pricing.totalSeconds(lip.spec) - 60).phase.hasPrefix("Lip sync · "))
        // Every phase is member-safe: no GPU, steps or start-up.
        for r in [req, two, lip, JobRequest(title: "t", modelId: "m", outfitId: "o", clipId: "c", engine: "viggle")] {
            let t = Pricing.totalSeconds(r.spec)
            for f in stride(from: 0.0, through: 1.0, by: 0.02) { XCTAssertTrue(MemberText.isSafe(JobClock.progress(r, elapsed: t * f).phase)) }
        }
        XCTAssertEqual(JobClock.leftText(40.2), "~41s left")
        XCTAssertEqual(JobClock.leftText(300), "~5 min left")
        XCTAssertEqual(JobClock.progress(req, elapsed: JobClock.failAt(req)).step, 3)
    }
}

final class CodingTests: XCTestCase {
    func testDecodesSparseServerJSON() throws {
        let json = """
        {"id":"j9","title":"Dance","state":"running","progress":42.5,"request":{"title":"Dance","modelId":"m_demo","outfitId":"o_green","clipId":"c1","steps":15},
         "createdAt":1762243200000,"thumb":{"url":"/files/a.jpg"},"unknownField":true}
        """
        let j = try JSONDecoder().decode(Job.self, from: Data(json.utf8))
        XCTAssertEqual(j.request.steps, 15)
        XCTAssertEqual(j.request.engine, "h3")
        XCTAssertEqual(j.engineLabel, "Edit")
        XCTAssertTrue(j.isRunning)
        XCTAssertEqual(j.createdAt, 1_762_243_200_000)
        XCTAssertNil(j.error)
        XCTAssertEqual(HTTPMuseAPI(baseURL: URL(string: "http://localhost:8787/")!).absolutize(j.thumb!).url, "http://localhost:8787/files/a.jpg")
    }

    func testDecodesEventsAndModels() throws {
        let json = """
        {"type":"model","model":{"id":"m1","name":"Noor","age":27,"niche":"Beauty","slots":[{"key":"face","image":{"asset":"face"}},{"key":"profile"}]}}
        """
        let e = try JSONDecoder().decode(ApiEvent.self, from: Data(json.utf8))
        XCTAssertEqual(e.type, "model")
        XCTAssertEqual(e.model?.filled, 1)
        XCTAssertEqual(e.model?.slots[1].source, "upload")
        XCTAssertEqual(e.takes, [])
        let o = try JSONDecoder().decode(Outfit.self, from: Data(#"{"id":"o1","modelId":"m1","name":"Set","angles":[{"asset":"g_front"},null,null,null]}"#.utf8))
        XCTAssertEqual(o.front?.asset, "g_front")
        XCTAssertNil(o.angles[1])
    }

    func testEncodesRequestsWithAndroidFieldNames() throws {
        let req = JobRequest(title: "t", modelId: "m", outfitId: "o", clipId: "c", engine: "viggle", steps: 4, takes: 2)
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as! [String: Any]
        XCTAssertEqual(Set(obj.keys), ["title", "modelId", "outfitId", "clipId", "engine", "steps", "use", "takes", "keepAudio", "lipSync", "background", "backgroundMotion"])
        let su = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SignUpRequest(studioName: "S", email: "e", password: "p", attestAdultRightsOriginal: true, attestLabelAi: false))) as! [String: Any]
        XCTAssertEqual(su["attestLabelAi"] as? Bool, false)
        XCTAssertNotNil(su["attestAdultRightsOriginal"])
    }

    func testSSEParser() {
        var p = SSEParser()
        XCTAssertNil(p.feed(": keep-alive"))
        XCTAssertNil(p.feed("event: job"))
        XCTAssertEqual(p.eventType, "job")
        XCTAssertNil(p.feed("data: {\"a\":1,"))
        XCTAssertNil(p.feed("data:\"b\":2}\r"))
        XCTAssertEqual(p.feed(""), "{\"a\":1,\n\"b\":2}")
        XCTAssertNil(p.eventType)
        XCTAssertNil(p.feed(""))
    }

    func testMultipartBody() {
        var m = Multipart()
        m.addField("meta", value: Data("{}".utf8), mime: "application/json")
        m.addFile("file", filename: "a\".mp4", mime: "video/mp4", data: Data([1, 2]))
        let s = String(decoding: m.finish(), as: UTF8.self)
        XCTAssertTrue(s.contains("name=\"meta\""))
        XCTAssertTrue(s.contains("filename=\"a.mp4\""))
        XCTAssertTrue(s.hasSuffix("--\(m.boundary)--\r\n"))
    }
}

final class FakeAPITests: XCTestCase {
    func fast() -> any MuseAPI { FakeMuseAPI(speed: 100_000, genDelay: 0.05) }

    func testSeedMatchesThePrototype() async throws {
        let api: any MuseAPI = FakeMuseAPI(speed: 0)
        let b = try await api.balance()
        XCTAssertEqual(Pricing.money(b.balance), "$6.07")
        XCTAssertEqual(Pricing.money(b.month), "$18.93")
        let jobs = try await api.listJobs()
        XCTAssertEqual(jobs.filter(\.isQueued).map(\.title), ["Living room dance"])
        XCTAssertEqual(jobs.filter(\.isFailed).first?.refunded, 0.19)
        let models = try await api.listModels()
        XCTAssertEqual(models.map(\.name), ["Demo model", "Demo model B"])
        XCTAssertTrue(models[0].isLocked)
        XCTAssertTrue(models[1].isDraft)
    }

    func testSignUpNeedsBothAttestations() async throws {
        let api = fast()
        do {
            _ = try await api.signUp(SignUpRequest(studioName: "", email: "a@b.c", password: "x", attestAdultRightsOriginal: true, attestLabelAi: false))
            XCTFail("should throw")
        } catch let e as ApiError {
            XCTAssertEqual(e.code, "attestation_required")
        }
        let ok = try await api.signUp(SignUpRequest(studioName: "", email: "jen@b.c", password: "x", attestAdultRightsOriginal: true, attestLabelAi: true))
        XCTAssertEqual(ok.user.studioName, "Jen's studio")
    }

    func testJobChargesRunsAndProducesTakes() async throws {
        let api = fast()
        let events = api.events()
        let before = try await api.balance().balance
        var req = JobRequest(title: "Dance", modelId: SampleData.demo, outfitId: SampleData.green, clipId: SampleData.sampleClip)
        req.takes = 2
        let job = try await api.createJob(req)
        XCTAssertEqual(job.cost, Pricing.totalCost(req.spec), accuracy: 1e-12)
        let after = try await api.balance().balance
        XCTAssertEqual(before - after, job.cost, accuracy: 1e-9)
        XCTAssertTrue(job.prompt.contains("Demo model wears the green set"))

        // The seeded queued job runs first (one GPU), then ours.
        var finished: Job?
        var newTakes: [Take] = []
        for await e in events {
            if let j = e.job, j.id == job.id, j.isDone {
                finished = j
                newTakes = e.takes
                break
            }
        }
        XCTAssertEqual(finished?.progress, 100)
        XCTAssertEqual(newTakes.count, 2)
        XCTAssertEqual(newTakes.map(\.status), ["test", "test"])
        let takes = try await api.listTakes()
        XCTAssertTrue(takes.contains { $0.id == newTakes[0].id })
        let living = try await api.listJobs().first { $0.id == "j3" }
        XCTAssertEqual(living?.state, "done")
    }

    func testFailedJobIsRefunded() async throws {
        let api = fast()
        try await api.setFailNext(true)
        let events = api.events()
        try await api.removeJob(id: "j3")
        let before = try await api.balance().balance
        let job = try await api.createJob(JobRequest(title: "x", modelId: SampleData.demo, outfitId: SampleData.green, clipId: SampleData.sampleClip))
        var failed: Job?
        for await e in events where e.job?.id == job.id && e.job?.isFailed == true {
            failed = e.job
            break
        }
        XCTAssertEqual(failed?.error, "Something went wrong · you weren't charged")
        XCTAssertEqual(failed?.failureLine, "Something went wrong · you weren't charged")
        XCTAssertEqual(failed?.refunded ?? 0, job.cost, accuracy: 1e-12)
        let after = try await api.balance().balance
        XCTAssertEqual(after, before, accuracy: 1e-9)
    }

    func testGenerateIsBlockedByLowBalance() async throws {
        let api: any MuseAPI = FakeMuseAPI(speed: 0)
        var req = JobRequest(title: "x", modelId: SampleData.demo, outfitId: SampleData.green, clipId: SampleData.badClip)
        req.clipId = SampleData.sampleClip
        req.steps = 30
        req.takes = 4
        do { _ = try await api.createJob(req); XCTFail() } catch let e as ApiError { XCTAssertEqual(e.code, "insufficient_balance") }
        req.steps = 31
        req.takes = 1
        do { _ = try await api.createJob(req); XCTFail() } catch let e as ApiError { XCTAssertEqual(e.code, "bad_request") }
    }

    func testUploadedClipIsChecked() async throws {
        let api: any MuseAPI = FakeMuseAPI(speed: 0)
        let c = try await api.uploadClip(ClipMeta(name: "mine.mov", durationSec: 12.25, width: 1080, height: 1920, fps: 60), file: nil)
        XCTAssertTrue(c.ok)
        XCTAssertEqual(c.checks[3].label, "Length 12.3s")
        let c2 = try await api.uploadClip(SampleData.badMeta, file: nil)
        XCTAssertEqual(c2.id, SampleData.badClip)
        XCTAssertFalse(c2.ok)
    }

    func testCharacterSheetFlow() async throws {
        let api = fast()
        let events = api.events()
        let m = try await api.createModel(CreateModelRequest(name: "  Ada ", age: 15, niche: "Tech", personality: "dry"))
        XCTAssertEqual(m.name, "Ada")
        XCTAssertEqual(m.age, 18)
        XCTAssertEqual(m.slots.map(\.key), ["face", "profile", "front", "tq", "side", "back", "faceTq"], "7 slots, face ¾ appended")
        let img = try await api.uploadImage(name: "a.jpg", data: Data([0xFF, 0xD8]), mime: "image/jpeg")
        let m2 = try await api.setSlot(modelId: m.id, slot: "face", SetSlotRequest(image: img))
        XCTAssertEqual(m2.filled, 1)
        let fill = try await api.fillAngles(modelId: m.id)
        XCTAssertEqual(PhotoPricing.label(fill.cost), "about $0.61", "6 angles (face ¾ too) × about $0.10")
        XCTAssertEqual(fill.model.slots.filter(\.busy).count, 6)
        var done: MuseModel?
        for await e in events where e.type == "model" {
            done = e.model
            break
        }
        XCTAssertEqual(done?.filled, 7)
        XCTAssertEqual(done?.slots.filter(\.isAI).count, 6)
        XCTAssertEqual(done?.isLocked, true)
    }

    func testOutfitPreviewThenSave() async throws {
        let api = fast()
        let events = api.events()
        let o = try await api.createOutfit(CreateOutfitRequest(modelId: SampleData.demo, name: "", mode: "describe", description: "red satin slip dress"))
        XCTAssertEqual(o.state, "generating")
        XCTAssertEqual(o.name, "red satin slip dress")
        var preview: Outfit?
        for await e in events where e.type == "outfit" {
            preview = e.outfit
            break
        }
        XCTAssertEqual(preview?.state, "preview")
        XCTAssertEqual(preview?.angles.compactMap { $0 }.count, 4)
        let saved = try await api.saveOutfit(outfitId: o.id)
        XCTAssertEqual(saved.state, "ready")
        let demoModel = try await api.listModels().first { $0.id == SampleData.demo }
        XCTAssertEqual(demoModel?.outfitIds.last, o.id)
    }

    func testShootAndTakeStatus() async throws {
        let api = fast()
        let shots = try await api.shoot(ShootRequest(modelId: SampleData.demo, outfitId: SampleData.crystal, scene: "Rooftop · golden hour", prompt: "p", seed: 48213))
        XCTAssertEqual(shots.count, 4)
        XCTAssertEqual(shots[0].title, "Photo · Rooftop")
        XCTAssertEqual(shots[0].caption, "Photo · Rooftop 1")
        let t = try await api.setTakeStatus(id: shots[0].id, status: "final")
        XCTAssertTrue(t.isFinal)
        try await api.deleteTake(id: shots[1].id)
        let all = try await api.listTakes()
        XCTAssertFalse(all.contains { $0.id == shots[1].id })
        let b = try await api.topUp(TopUpRequest(amount: 25))
        XCTAssertEqual(Pricing.money(b.balance), "$30.61", "6.07 − about 0.46 for the shoot + 25")
    }
}

import Foundation
import XCTest
@testable import MuseCore

/// The video studio's stage (its right pane): idle → queued → rendering → ready / failed, driven by the same live job and
/// take events the app already applies, with member-safe wording only.
final class StudioStageTests: XCTestCase {
    private let req = JobRequest.replicate(title: "Kitchen", modelId: "m", outfitId: "o", clipId: "clip_1", quality: .draft, clipSeconds: 7)

    private func job(_ state: String, id: String = "j1", progress: Double = 0, phase: String = "", left: Double = 0, queue: Int? = nil, eta: Double? = nil,
                     clip: String = "clip_1", model: String = "m", outfit: String = "o") -> Job {
        var r = req
        r.clipId = clip
        r.modelId = model
        r.outfitId = outfit
        var j = Job(id: id, title: "Kitchen", modelId: model, modelName: "Demo model", outfitId: outfit, request: r, state: state, progress: progress,
                    phase: phase, secondsLeft: left, cost: 0.14)
        j.queuePosition = queue
        j.etaSeconds = eta
        return j
    }

    private func take(_ id: String, job: String = "j1", index: Int, of: Int = 2, kind: String = "take", video: String? = "https://x/take.mp4") -> Take {
        var t = Take(id: id, kind: kind, jobId: job, index: index, of: of, title: "Kitchen", label: "Draft", engineLabel: "Draft · 768P", cost: 0.07,
                     thumb: ImageRef(asset: "g_front"), createdAt: Int64(index))
        t.videoUrl = video
        return t
    }

    private func resolve(_ jobs: [Job], _ takes: [Take] = [], started: [String] = ["j1"], clip: String? = "clip_1", model: String? = "m", outfit: String? = "o") -> StudioStage {
        StudioStage.resolve(jobs: jobs, takes: takes, started: started, clipId: clip, modelId: model, outfitId: outfit)
    }

    func testNothingStartedFromTheStudioIsIdle() {
        XCTAssertEqual(resolve([job("running", progress: 40)], started: []).phase, .idle)
        XCTAssertEqual(resolve([], started: ["j1"]).phase, .idle) // removed on another device
        XCTAssertEqual(StudioStage.of(nil, takes: []), .idle)
        XCTAssertFalse(StudioStage.idle.isBusy)
    }

    func testTheWholeRunFromLiveEvents() {
        var jobs: [Job] = []
        var takes: [Take] = []
        func apply(_ e: ApiEvent) {
            LiveEvents.applyJobs(&jobs, e)
            LiveEvents.applyTakes(&takes, e)
        }
        // Waiting in line on the real API: state running, a place in line, nothing rendered yet.
        apply(ApiEvent(type: "job", job: job("running", phase: "Waiting to start", queue: 2, eta: 540)))
        var s = resolve(jobs, takes)
        XCTAssertEqual(s.phase, .queued)
        XCTAssertEqual(s.headline, "#2 in line · about 9 min")
        XCTAssertEqual(s.price, "$0.14")
        XCTAssertEqual(s.percent, "0%")
        XCTAssertTrue(s.isBusy)

        apply(ApiEvent(type: "job", job: job("running", phase: "Waiting to start", queue: 1)))
        XCTAssertEqual(resolve(jobs, takes).headline, "Waiting to start")

        apply(ApiEvent(type: "job", job: job("running", progress: 42, phase: "Rendering · ~2 min left", left: 110)))
        s = resolve(jobs, takes)
        XCTAssertEqual(s.phase, .rendering)
        XCTAssertEqual(s.headline, "Rendering · about 2 min")
        XCTAssertEqual(s.percent, "42%")
        XCTAssertEqual(s.progress, 0.42, accuracy: 1e-9)

        // Done: the job event carries its takes.
        var done = job("done", progress: 100, phase: "Done")
        done.finishedAt = 10
        apply(ApiEvent(type: "job", job: done, takes: [take("t2", index: 2), take("t1", index: 1)]))
        s = resolve(jobs, takes)
        XCTAssertEqual(s.phase, .ready)
        XCTAssertEqual(s.takes.map(\.id), ["t1", "t2"])
        XCTAssertEqual(s.percent, "100%")
        XCTAssertFalse(s.isBusy)
        XCTAssertEqual(s.take(nil)?.id, "t1")
        XCTAssertEqual(s.take("t2")?.id, "t2")
        XCTAssertEqual(s.take("gone")?.id, "t1")
        XCTAssertEqual(s.takeLabel(s.takes[1]), "Take 2 of 2")

        // An edited version of a take isn't a take of the render.
        apply(ApiEvent(type: "take", take: take("v1", index: 1, of: 1, kind: "edit")))
        XCTAssertEqual(resolve(jobs, takes).takes.map(\.id), ["t1", "t2"])
        // A take deleted elsewhere leaves the switcher.
        apply(ApiEvent(type: "take", op: "delete", id: "t2"))
        s = resolve(jobs, takes)
        XCTAssertEqual(s.takes.map(\.id), ["t1"])
        XCTAssertNil(s.takeLabel(s.takes[0]))
    }

    func testParkedAndOlderServerWaitsReadAsQueued() {
        // The demo backend parks a new job as "queued" before it starts: no place in line, no time.
        var s = StudioStage.of(job("queued", phase: "Queued", left: 600), takes: [])
        XCTAssertEqual(s.phase, .queued)
        XCTAssertEqual(s.headline, "Waiting to start")
        // An older server only says so in the phase.
        s = StudioStage.of(job("running", phase: "Waiting for a GPU · starts in ~2 min"), takes: [])
        XCTAssertEqual(s.phase, .queued)
        XCTAssertEqual(s.headline, "Waiting to start")
        // Getting ready is rendering already (progress moves).
        s = StudioStage.of(job("running", progress: 3, phase: "Starting GPU · ~6 min left", left: 330), takes: [])
        XCTAssertEqual(s.phase, .rendering)
        XCTAssertEqual(s.headline, "Getting ready · about 6 min")
    }

    func testFailureIsMemberSafeWithTryAgain() {
        var f = job("failed", progress: 18, phase: "Failed")
        f.refunded = 0.14
        f.errorCode = "provider_refused"
        f.error = "Replicate: NSFW detected by the safety filter"
        var s = StudioStage.of(f, takes: [])
        XCTAssertEqual(s.phase, .failed)
        XCTAssertEqual(s.failure, "This clip was refused by the content filter · you weren't charged")
        XCTAssertTrue(MemberText.isSafe(s.headline))
        f.errorCode = "provider_failed"
        f.error = "The GPU disconnected at step 3."
        s = StudioStage.of(f, takes: [])
        XCTAssertEqual(s.failure, MemberText.wentWrong)
    }

    func testEveryLineIsMemberSafe() {
        let phases = ["Waiting for RunPod", "Starting GPU · ~4 min left", "step 3/10 · ~6 min left", "Rendering on Replicate", "take 2/3 · Finishing",
                      "Loading H3 weights", "Warm-up", "Preparing the clip"]
        for p in phases {
            let s = StudioStage.of(job("running", progress: 30, phase: p, left: 200), takes: [])
            XCTAssertTrue(MemberText.isSafe(s.headline), "\(p) → \(s.headline)")
        }
    }

    func testChangingTheClipModelOrOutfitGoesBackToTheTarget() {
        let jobs = [job("running", progress: 50, phase: "Rendering")]
        XCTAssertEqual(resolve(jobs).phase, .rendering)
        XCTAssertEqual(resolve(jobs, clip: "clip_2").phase, .idle)
        XCTAssertEqual(resolve(jobs, model: "m2").phase, .idle)
        XCTAssertEqual(resolve(jobs, outfit: "o2").phase, .idle)
        // Picking them again brings the render back.
        XCTAssertEqual(resolve(jobs).phase, .rendering)
    }

    func testGenerateAgainFollowsTheNewestRender() {
        var first = job("done", progress: 100, phase: "Done")
        first.finishedAt = 1
        let second = job("running", id: "j2", progress: 10, phase: "Rendering · ~3 min left", left: 170)
        var s = resolve([second, first], [take("t1", index: 1, of: 1)], started: ["j1", "j2"])
        XCTAssertEqual(s.jobId, "j2")
        XCTAssertEqual(s.phase, .rendering)
        // The newer render was for another outfit: the stage shows the latest one that matches.
        let other = job("running", id: "j3", outfit: "o2")
        s = resolve([other, second, first], started: ["j1", "j2", "j3"])
        XCTAssertEqual(s.jobId, "j2")
    }

    func testNeverAddLineHidesWhenEmpty() {
        XCTAssertNil(StudioText.neverAdd([]))
        XCTAssertNil(StudioText.neverAdd(["", "  "]))
        XCTAssertEqual(StudioText.neverAdd(["tattoos", " rings "]), "Never add: tattoos, rings. Removed automatically.")
    }

    /// The demo backend end to end: a render started from the studio moves through the stage by its live events alone.
    func testDemoBackendDrivesTheStage() async throws {
        let req = JobRequest.replicate(title: "Living room", modelId: SampleData.demo, outfitId: SampleData.green, clipId: SampleData.sampleClip, quality: .draft,
                                       clipSeconds: SampleData.sampleMeta.durationSec)
        // About 1.5 s of real time, so the 250 ms ticks see it rendering.
        let api = FakeMuseAPI(speed: max(1, Pricing.totalSeconds(req.spec) / 1.5), genDelay: 0)
        let clip = try await api.uploadClip(SampleData.sampleMeta, file: nil)
        try await api.removeJob(id: "j3") // the seeded queued job would go first
        var jobs = try await api.listJobs()
        var takes = try await api.listTakes()
        let stream = api.events()
        var r = req
        r.clipId = clip.id
        let j = try await api.createJob(r)
        LiveEvents.applyJobs(&jobs, ApiEvent(type: "job", job: j))
        var seen: [StagePhase] = []
        for await e in stream {
            LiveEvents.applyJobs(&jobs, e)
            LiveEvents.applyTakes(&takes, e)
            let s = StudioStage.resolve(jobs: jobs, takes: takes, started: [j.id], clipId: clip.id, modelId: SampleData.demo, outfitId: SampleData.green)
            if seen.last != s.phase { seen.append(s.phase) }
            XCTAssertTrue(MemberText.isSafe(s.headline), s.headline)
            if s.phase == .ready {
                XCTAssertEqual(s.takes.count, 1)
                XCTAssertEqual(s.takes.first?.jobId, j.id)
                break
            }
        }
        XCTAssertEqual(seen.last, .ready)
        XCTAssertTrue(seen.contains(.rendering), "\(seen)")
    }
}

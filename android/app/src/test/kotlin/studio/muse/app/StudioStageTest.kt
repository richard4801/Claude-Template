package studio.muse.app

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.ApiEvent
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.Job
import studio.muse.app.data.JobRequest
import studio.muse.app.data.LiveEvents
import studio.muse.app.data.SampleData
import studio.muse.app.data.StudioState
import studio.muse.app.data.Take
import studio.muse.app.ui.screens.StageJobs
import studio.muse.app.ui.screens.StagePhase
import studio.muse.app.ui.screens.StudioStage
import studio.muse.app.ui.screens.StudioText
import studio.muse.core.Engine
import studio.muse.core.Pricing

/**
 * The Video studio's stage: idle → queued → rendering → ready / failed, driven by the same live job and take events the app
 * already applies, with member-safe wording only (the same rules as the Mac's StudioStageTests).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class StudioStageTest {
    private val req = JobRequest("Kitchen", "m", "o", "clip_1", Engine.REPLICATE.id, quality = "draft", clipSeconds = 7.0)

    private fun job(
        state: String, id: String = "j1", progress: Double = 0.0, phase: String = "", left: Double = 0.0, queue: Int? = null, eta: Double? = null,
        clip: String = "clip_1", model: String = "m", outfit: String = "o",
    ) = Job(id, "Kitchen", model, "Demo model", outfit, req.copy(clipId = clip, modelId = model, outfitId = outfit), state, progress, phase = phase, secondsLeft = left,
        cost = 0.14, queuePosition = queue, etaSeconds = eta)

    private fun take(id: String, job: String = "j1", index: Int, of: Int = 2, kind: String = "take") =
        Take(id, kind, job, index, of, "Kitchen", "Draft", "Draft · 768P", 0.07, createdAt = index.toLong(), videoUrl = "https://x/take.mp4")

    private fun resolve(jobs: List<Job>, takes: List<Take> = emptyList(), started: List<String> = listOf("j1"), clip: String? = "clip_1", model: String? = "m", outfit: String? = "o") =
        StudioStage.resolve(jobs, takes, started, clip, model, outfit)

    private val technical = Regex("(?i)\\bgpus?\\b|warm|runpod|replicate|\\bh(100|200|3)\\b|\\bsteps?\\b|start-?up|\\bpods?\\b|viggle|minimax|cuda")

    @Test fun nothingStartedFromTheStudioIsIdle() {
        assertEquals(StagePhase.IDLE, resolve(listOf(job("running", progress = 40.0)), started = emptyList()).phase)
        assertEquals(StagePhase.IDLE, resolve(emptyList()).phase) // removed on another device
        assertEquals(StudioStage.IDLE, StudioStage.of(null, emptyList()))
        assertFalse(StudioStage.IDLE.busy)
    }

    @Test fun theWholeRunFromLiveEvents() {
        var s = StudioState(loaded = true)
        fun apply(e: ApiEvent) { s = LiveEvents.apply(s, e, owner = false) }
        // Waiting in line on the real API: running, a place in line, nothing rendered yet.
        apply(ApiEvent("job", job = job("running", phase = "Waiting to start", queue = 2, eta = 540.0)))
        var st = resolve(s.jobs, s.takes)
        assertEquals(StagePhase.QUEUED, st.phase)
        assertEquals("#2 in line · about 9 min", st.headline)
        assertEquals("$0.14", st.price)
        assertTrue(st.busy)

        apply(ApiEvent("job", job = job("running", phase = "Waiting to start", queue = 1)))
        assertEquals("Waiting to start", resolve(s.jobs, s.takes).headline)

        apply(ApiEvent("job", job = job("running", progress = 42.0, phase = "Rendering · ~2 min left", left = 110.0)))
        st = resolve(s.jobs, s.takes)
        assertEquals(StagePhase.RENDERING, st.phase)
        assertEquals("Rendering · about 2 min", st.headline)
        assertEquals("42%", st.percent)
        assertEquals(.42f, st.progress, 1e-6f)

        // Done: the job event carries its takes.
        apply(ApiEvent("job", job = job("done", progress = 100.0, phase = "Done"), takes = listOf(take("t2", index = 2), take("t1", index = 1))))
        st = resolve(s.jobs, s.takes)
        assertEquals(StagePhase.READY, st.phase)
        assertEquals(listOf("t1", "t2"), st.takes.map { it.id })
        assertEquals("100%", st.percent)
        assertFalse(st.busy)
        assertEquals("t1", st.take(null)?.id)
        assertEquals("t2", st.take("t2")?.id)
        assertEquals("t1", st.take("gone")?.id)
        assertEquals("Take 2 of 2", st.takeLabel(st.takes[1]))

        // An edited version isn't a take of the render; a take deleted elsewhere leaves the switcher.
        apply(ApiEvent("take", take = take("v1", index = 1, of = 1, kind = "edit")))
        assertEquals(listOf("t1", "t2"), resolve(s.jobs, s.takes).takes.map { it.id })
        apply(ApiEvent("take", op = "delete", id = "t2"))
        st = resolve(s.jobs, s.takes)
        assertEquals(listOf("t1"), st.takes.map { it.id })
        assertNull(st.takeLabel(st.takes[0]))
    }

    @Test fun parkedAndOlderServerWaitsReadAsQueued() {
        var st = StudioStage.of(job("queued", phase = "Queued", left = 600.0), emptyList())
        assertEquals(StagePhase.QUEUED, st.phase)
        assertEquals("Waiting to start", st.headline)
        st = StudioStage.of(job("running", phase = "Waiting for a GPU · starts in ~2 min"), emptyList())
        assertEquals(StagePhase.QUEUED, st.phase)
        assertEquals("Waiting to start", st.headline)
        st = StudioStage.of(job("running", progress = 3.0, phase = "Starting GPU · ~6 min left", left = 330.0), emptyList())
        assertEquals(StagePhase.RENDERING, st.phase)
        assertEquals("Getting ready · about 6 min", st.headline)
    }

    @Test fun failureIsMemberSafe() {
        var f = job("failed", progress = 18.0, phase = "Failed").copy(refunded = .14, errorCode = "provider_refused", error = "Replicate: NSFW detected by the safety filter")
        var st = StudioStage.of(f, emptyList())
        assertEquals(StagePhase.FAILED, st.phase)
        assertEquals("This clip was refused by the content filter · you weren't charged", st.failure)
        f = f.copy(errorCode = "provider_failed", error = "The GPU disconnected at step 3.")
        assertEquals("Something went wrong · you weren't charged", StudioStage.of(f, emptyList()).failure)
        f = f.copy(errorCode = null, error = "Busy right now · you weren't charged. Try again in a minute.")
        assertEquals(f.error, StudioStage.of(f, emptyList()).failure)
    }

    @Test fun everyLineIsMemberSafe() {
        listOf("Waiting for RunPod", "Starting GPU · ~4 min left", "step 3/10 · ~6 min left", "take 2/3 · Finishing", "Getting ready", "Preparing the clip").forEach { p ->
            val st = StudioStage.of(job("running", progress = 30.0, phase = p, left = 200.0), emptyList())
            assertFalse("$p → ${st.headline}", technical.containsMatchIn(st.headline))
        }
    }

    @Test fun changingTheClipModelOrOutfitGoesBackToTheTarget() {
        val jobs = listOf(job("running", progress = 50.0, phase = "Rendering"))
        assertEquals(StagePhase.RENDERING, resolve(jobs).phase)
        assertEquals(StagePhase.IDLE, resolve(jobs, clip = "clip_2").phase)
        assertEquals(StagePhase.IDLE, resolve(jobs, model = "m2").phase)
        assertEquals(StagePhase.IDLE, resolve(jobs, outfit = "o2").phase)
        assertEquals(StagePhase.RENDERING, resolve(jobs).phase)
    }

    @Test fun generateAgainFollowsTheNewestRender() {
        val first = job("done", progress = 100.0, phase = "Done")
        val second = job("running", id = "j2", progress = 10.0, phase = "Rendering · ~3 min left", left = 170.0)
        var st = resolve(listOf(second, first), listOf(take("t1", index = 1, of = 1)), started = listOf("j1", "j2"))
        assertEquals("j2", st.jobId)
        assertEquals(StagePhase.RENDERING, st.phase)
        st = resolve(listOf(job("running", id = "j3", outfit = "o2"), second, first), started = listOf("j1", "j2", "j3"))
        assertEquals("j2", st.jobId)
        // The tracker keeps the order and forgets the picked take on a new render.
        val t = StageJobs()
        t.started("j1"); t.take.value = "t1"; t.started("j2"); t.started("j1")
        assertEquals(listOf("j2", "j1"), t.ids.value)
        assertNull(t.take.value)
    }

    @Test fun neverAddLineHidesWhenEmpty() {
        assertNull(StudioText.neverAdd(emptyList()))
        assertNull(StudioText.neverAdd(null))
        assertNull(StudioText.neverAdd(listOf("", "  ")))
        assertEquals("Never add: tattoos, rings. Removed automatically.", StudioText.neverAdd(listOf("tattoos", " rings ")))
    }

    /** The demo backend end to end: a render started from the studio moves through the stage by its live events alone. */
    @Test fun demoBackendDrivesTheStage() = runTest {
        val api = FakeMuseApi(backgroundScope, now = { testScheduler.currentTime })
        val clip = api.uploadClip(SampleData.sampleMeta, null)
        var s = StudioState(jobs = api.listJobs(), takes = api.listTakes(), loaded = true)
        val seen = mutableListOf<StagePhase>()
        var started = emptyList<String>()
        fun look() {
            val st = StudioStage.resolve(s.jobs, s.takes, started, clip.id, SampleData.DEMO, SampleData.GREEN)
            if (seen.lastOrNull() != st.phase) seen += st.phase
            assertFalse(st.headline, technical.containsMatchIn(st.headline))
        }
        backgroundScope.launch { api.events().collect { e -> s = LiveEvents.apply(s, e, owner = true); look() } }
        runCurrent()
        val r = JobRequest("Living room", SampleData.DEMO, SampleData.GREEN, clip.id, Engine.REPLICATE.id, quality = "draft", clipSeconds = clip.durationSec)
        val j = api.createJob(r)
        started = listOf(j.id)
        s = LiveEvents.apply(s, ApiEvent("job", job = j), owner = true)
        look()
        val realMs = (Pricing.totalSeconds(r.spec()) / 24 * 1000).toLong()
        advanceTimeBy(realMs / 2)
        look()
        advanceTimeBy(realMs * 2)
        runCurrent()
        look()
        assertEquals(StagePhase.READY, seen.last())
        assertTrue(seen.toString(), StagePhase.RENDERING in seen)
        val st = StudioStage.resolve(s.jobs, s.takes, started, clip.id, SampleData.DEMO, SampleData.GREEN)
        assertEquals(1, st.takes.size)
        assertEquals(j.id, st.takes.first().jobId)
    }
}

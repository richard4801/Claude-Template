package studio.muse.app

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import studio.muse.app.data.ApiException
import studio.muse.app.data.ClipRules
import studio.muse.app.data.CreateModelRequest
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.JobClock
import studio.muse.app.data.JobRequest
import studio.muse.app.data.SampleData
import studio.muse.app.data.SignUpRequest
import studio.muse.app.data.TopUpRequest
import studio.muse.core.Engine
import studio.muse.core.Pricing

@OptIn(ExperimentalCoroutinesApi::class)
class FakeMuseApiTest {
    private fun req(steps: Int = 10, takes: Int = 1, engine: Engine = Engine.H3) =
        JobRequest("Living-room dance", SampleData.DEMO, SampleData.GREEN, SampleData.SAMPLE_CLIP, engine.id, steps, takes = takes)

    @Test fun seedMatchesThePrototype() = runTest {
        val api = FakeMuseApi(backgroundScope, now = { testScheduler.currentTime })
        assertEquals(6.07, api.balance().balance, 1e-9)
        assertEquals(18.93, api.balance().month, 1e-9)
        assertEquals(listOf("Demo model", "Noor Ellis"), api.listModels().map { it.name })
        assertTrue(api.listModels()[0].locked)
        assertEquals(0, api.listModels()[1].filled)
        assertTrue(api.listJobs().any { it.failed && it.refunded == 0.19 })
    }

    @Test fun signUpNeedsBothAttestations() = runTest {
        val api = FakeMuseApi(backgroundScope)
        try { api.signUp(SignUpRequest("S", "a@b.c", "x", true, false)); fail() } catch (e: ApiException) { assertEquals("attestation_required", e.code) }
        assertEquals("S", api.signUp(SignUpRequest("S", "a@b.c", "x", true, true)).user.studioName)
    }

    @Test fun jobChargesUpFrontRunsAt24xAndProducesTakes() = runTest {
        val api = FakeMuseApi(backgroundScope, now = { testScheduler.currentTime })
        api.uploadClip(SampleData.sampleMeta, null)
        val job = api.createJob(req(takes = 2))
        val cost = Pricing.totalCost(req(takes = 2).spec())
        assertEquals(6.07 - cost, api.balance().balance, 1e-9)
        val realSeconds = Pricing.totalSeconds(req(takes = 2).spec()) / 24
        advanceTimeBy((realSeconds * 1000 / 2).toLong())
        val mid = api.listJobs().first { it.id == job.id }
        assertEquals("running", mid.state)
        assertTrue(mid.phase, mid.phase.contains("Rendering") || mid.phase.contains("Getting ready"))
        assertTrue(mid.phase, !Regex("(?i)gpu|step").containsMatchIn(mid.phase))
        advanceTimeBy((realSeconds * 1000).toLong())
        val done = api.listJobs().first { it.id == job.id }
        assertEquals("done", done.state)
        assertEquals(2, api.listTakes().count { it.jobId == job.id })
    }

    @Test fun failedJobIsRefunded() = runTest {
        val api = FakeMuseApi(backgroundScope, now = { testScheduler.currentTime })
        api.setFailNext(true)
        val job = api.createJob(req())
        advanceTimeBy(60_000)
        val j = api.listJobs().first { it.id == job.id }
        assertEquals("failed", j.state)
        assertEquals(j.cost, j.refunded, 1e-9)
        assertEquals(6.07, api.balance().balance, 1e-9)
        assertEquals("Something went wrong · you weren't charged", j.error)
        assertEquals("Failed", j.phase)
    }

    @Test fun generateIsBlockedWhenBalanceIsTooLow() = runTest {
        val api = FakeMuseApi(backgroundScope)
        try { api.createJob(req(steps = 30, takes = 4)); fail() } catch (e: ApiException) { assertTrue(e.code == "insufficient_balance" || e.code == "over_job_limit") }
        // Drain the balance, then even a cheap job is refused.
        repeat(9) { runCatching { api.createJob(req()) } }
        try { api.createJob(req()); fail() } catch (e: ApiException) { assertEquals("insufficient_balance", e.code) }
        api.topUp(TopUpRequest(25.0))
        api.createJob(req())
    }

    @Test fun failingClipIsStillAccepted() = runTest {
        // Clip checks are advice only (2026-11-05): the studio shows a disclaimer, the job goes ahead.
        val api = FakeMuseApi(backgroundScope)
        val bad = api.uploadClip(SampleData.badMeta, null)
        assertFalse(bad.ok)
        assertEquals(3, bad.checks.count { it.status == "bad" })
        val job = api.createJob(req().copy(clipId = bad.id))
        assertEquals(bad.id, job.request.clipId)
    }

    @Test fun clipRulesMatchThePrototypeCopy() {
        val good = ClipRules.checks(SampleData.sampleMeta)
        assertEquals(listOf("One person in frame", "Watermark", "1080×1920 · 30fps", "Length 9.4s", "Performer talking"), good.map { it.label })
        assertEquals(listOf("Yes", "None", "OK", "Max 15s", "No"), good.map { it.value })
        val bad = ClipRules.checks(SampleData.badMeta)
        assertEquals("Trim to 15s or less", bad[3].fix)
        assertEquals("TikTok logo", bad[1].value)
    }

    @Test fun progressTextReadsLikeTheSpec() {
        val r = JobRequest("x", "m", "o", "c", steps = 20)
        val total = Pricing.totalSeconds(r.spec())
        val p = JobClock.progress(r, 30 + (total - 30) * 0.55)
        assertTrue(p.phase, Regex("Rendering · ~\\d+ min left").matches(p.phase))
        assertEquals(12, p.step)
        assertEquals("Getting ready · ~20 min left", JobClock.progress(r, 1.0).phase)
        val two = JobClock.progress(r.copy(takes = 2), total * 1.5)
        assertTrue(two.phase.startsWith("take 2/2 · "))
    }

    @Test fun fillAnglesHoldsThePassThroughEstimateAndFillsLater() = runTest {
        val api = FakeMuseApi(backgroundScope, genDelayMs = 1000)
        val m = api.createModel(CreateModelRequest("Noor", 27, "Beauty"))
        val r = api.fillAngles(m.id)
        assertEquals(7 * (0.015 + 0.015), r.cost, 1e-9) // 7 angles at 1 MP, no references yet
        assertTrue(r.model.slots.all { it.busy })
        advanceTimeBy(1500)
        val after = api.listModels().first { it.id == m.id }
        assertEquals(7, after.filled)
        assertTrue(after.slots.all { it.source == "generated" })
    }

    @Test fun loraBuildReviewTrainAndPrompt() = runTest {
        val api = FakeMuseApi(backgroundScope, now = { testScheduler.currentTime }, genDelayMs = 1000)
        assertEquals("none", api.lora(SampleData.DEMO).state)
        assertEquals("building", api.buildLoraSet(SampleData.DEMO).state)
        assertEquals(6.07 - studio.muse.core.PhotoPricing.loraSet(studio.muse.core.PhotoPrices()), api.balance().balance, 1e-9)
        advanceTimeBy(1500)
        val review = api.lora(SampleData.DEMO)
        assertEquals("review", review.state)
        assertEquals(30, review.candidates.size)
        assertEquals(3, review.flagged)
        assertTrue(review.candidates.filter { it.flag != null }.none { it.keep })
        assertEquals(27, review.kept)
        assertTrue(review.candidates.all { it.image.asset != null && !it.image.asset!!.startsWith("vid_") })
        // $5.47 < $6.65: blocked
        try { api.trainLora(SampleData.DEMO); fail() } catch (e: ApiException) { assertEquals("insufficient_balance", e.code) }
        api.topUp(TopUpRequest(25.0))
        review.candidates.filter { it.keep }.take(8).forEach { api.keepCandidate(SampleData.DEMO, it.id, false) }
        try { api.trainLora(SampleData.DEMO); fail() } catch (e: ApiException) { assertEquals("bad_request", e.code) }
        val flagged = review.candidates.first { it.flag != null }
        assertEquals(20, api.keepCandidate(SampleData.DEMO, flagged.id, true).kept)
        val before = api.balance().balance
        val t = api.trainLora(SampleData.DEMO)
        assertEquals("training", t.state)
        assertEquals(before - 6.65, api.balance().balance, 1e-9)
        // 100 min at 24 × 5 = 120× → 50 s
        advanceTimeBy(20_000)
        val mid = api.lora(SampleData.DEMO)
        assertEquals(100.0, mid.photo.progress, 1e-9)
        assertTrue(mid.video.progress in 1.0..99.0)
        advanceTimeBy(40_000)
        val done = api.lora(SampleData.DEMO)
        assertEquals("ready", done.state)
        assertEquals(1, done.version)
        assertEquals(20, done.trainedOn)
        assertTrue(done.use)
        api.uploadClip(SampleData.sampleMeta, null)
        assertTrue(api.createJob(req()).prompt.contains("with LoRA demo_v1 video"))
        api.patchLora(SampleData.DEMO, studio.muse.app.data.PatchLoraRequest(use = false))
        assertFalse(api.createJob(req(steps = 4, engine = Engine.VIGGLE)).prompt.contains("LoRA"))
        assertEquals("review", api.patchLora(SampleData.DEMO, studio.muse.app.data.PatchLoraRequest(state = "review", use = true)).state)
        api.trainLora(SampleData.DEMO)
        advanceTimeBy(60_000)
        assertEquals(2, api.lora(SampleData.DEMO).version)
    }

    @Test fun accountsAndPostsKeepLabelsOffByDefault() = runTest {
        val api = FakeMuseApi(backgroundScope, now = { testScheduler.currentTime }, genDelayMs = 1000)
        val req = studio.muse.app.data.CreatePostRequest(SampleData.DEMO, "t_j1", listOf("tiktok"), "Kick #dance")
        try { api.createPost(req); fail() } catch (e: ApiException) { assertEquals("bad_request", e.code) }
        val a = api.connectAccount(SampleData.DEMO, "tiktok").account!!
        assertEquals("@demo.model", a.handle)
        assertFalse(a.canPostDirect)
        assertEquals("Demo model (Page)", api.connectAccount(SampleData.DEMO, "facebook").account!!.handle)
        assertEquals(listOf("tiktok", "facebook"), api.listAccounts(SampleData.DEMO).map { it.platform })
        assertTrue(api.listAccounts(SampleData.NOOR).isEmpty())
        api.disconnectAccount(SampleData.DEMO, "facebook")
        assertEquals(listOf("tiktok"), api.listAccounts(SampleData.DEMO).map { it.platform })
        val now = api.createPost(req)
        assertEquals("handoff", now.state)
        assertFalse(now.aiLabel); assertFalse(now.paidPartnership)
        assertTrue(api.createPost(req.copy(aiLabel = true, paidPartnership = true)).let { it.aiLabel && it.paidPartnership })
        val at = java.time.Instant.ofEpochMilli(testScheduler.currentTime + 3_600_000).toString()
        val sched = api.createPost(req.copy(`when` = at))
        assertEquals("scheduled", sched.state)
        advanceTimeBy(1500)
        assertTrue(api.listPosts("posted").first { it.id == now.id }.stats!!.views > 0)
        assertEquals(listOf(sched.id), api.listPosts("scheduled").map { it.id })
        advanceTimeBy(3_600_000)
        assertEquals("posted", api.listPosts().first { it.id == sched.id }.state)
        api.deletePost(sched.id)
        assertTrue(api.listPosts().none { it.id == sched.id })
    }

    @Test fun queueRunAndModelEditDelete() = runTest {
        val api = FakeMuseApi(backgroundScope, now = { testScheduler.currentTime })
        val q = api.createJob(req().copy(queue = true))
        assertEquals("queued", q.state)
        assertEquals(6.07, api.balance().balance, 1e-9)
        assertEquals(listOf(q.id), api.runQueue().map { it.id })
        assertTrue(api.balance().balance < 6.07)
        assertEquals(0.13 + q.cost, api.balance().today, 1e-9)
        val m = api.updateModel(SampleData.DEMO, studio.muse.app.data.UpdateModelRequest(personality = "Warm", notes = "No gym", neverAdd = listOf("tattoos", "rings", "chokers")))
        assertEquals("Warm", m.personality); assertEquals("Demo model", m.name)
        api.connectAccount(SampleData.NOOR, "x")
        api.deleteModel(SampleData.NOOR)
        assertEquals(listOf("Demo model"), api.listModels().map { it.name })
        try { api.lora(SampleData.NOOR); fail() } catch (e: ApiException) { assertEquals("not_found", e.code) }
    }
}

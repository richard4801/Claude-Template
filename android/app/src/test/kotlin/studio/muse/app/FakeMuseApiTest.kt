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
        JobRequest("Living-room dance", SampleData.SIENNA, SampleData.GREEN, SampleData.SAMPLE_CLIP, engine.id, steps, takes = takes)

    @Test fun seedMatchesThePrototype() = runTest {
        val api = FakeMuseApi(backgroundScope, now = { testScheduler.currentTime })
        assertEquals(6.07, api.balance().balance, 1e-9)
        assertEquals(18.93, api.balance().month, 1e-9)
        assertEquals(listOf("Sienna Vale", "Noor Ellis"), api.listModels().map { it.name })
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
        assertTrue(mid.phase, mid.phase.contains("step") || mid.phase.contains("Starting"))
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
        assertTrue(j.error!!.contains("step 3"))
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

    @Test fun failingClipBlocksTheJob() = runTest {
        val api = FakeMuseApi(backgroundScope)
        val bad = api.uploadClip(SampleData.badMeta, null)
        assertFalse(bad.ok)
        assertEquals(3, bad.checks.count { it.status == "bad" })
        try { api.createJob(req().copy(clipId = bad.id)); fail() } catch (e: ApiException) { assertEquals("clip_failed_checks", e.code) }
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
        assertTrue(p.phase, Regex("step 12/20 · ~\\d+ min left").matches(p.phase))
        assertEquals("Starting GPU · ~20 min left", JobClock.progress(r, 1.0).phase)
        val two = JobClock.progress(r.copy(takes = 2), total * 1.5)
        assertTrue(two.phase.startsWith("take 2/2 · "))
    }

    @Test fun fillAnglesChargesTwoCentsPerAngleAndFillsLater() = runTest {
        val api = FakeMuseApi(backgroundScope, genDelayMs = 1000)
        val m = api.createModel(CreateModelRequest("Noor", 27, "Beauty"))
        val r = api.fillAngles(m.id)
        assertEquals(0.12, r.cost, 1e-9)
        assertTrue(r.model.slots.all { it.busy })
        advanceTimeBy(1500)
        val after = api.listModels().first { it.id == m.id }
        assertEquals(6, after.filled)
        assertTrue(after.slots.all { it.source == "generated" })
    }
}

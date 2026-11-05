package studio.muse.app

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import studio.muse.app.data.ApiException
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.SampleData
import studio.muse.app.data.SuiteCatalog
import studio.muse.app.data.SuiteClock
import studio.muse.app.data.SuiteEstimate
import studio.muse.app.data.SuiteRules
import studio.muse.app.ui.screens.suite.RecastDraft
import studio.muse.app.ui.screens.suite.RecastPerson
import studio.muse.app.ui.screens.suite.ShotDraft

/** Demo mode's suite end to end (no server), and the member-safety rules on every answer a member gets. */
@OptIn(ExperimentalCoroutinesApi::class)
class SuiteDemoTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true }
    private fun res(name: String) = javaClass.getResource("/suite/$name.json")!!.readText()

    @Test fun demoShotEstimatesRendersAndSettlesFree() = runTest {
        val api = FakeMuseApi(backgroundScope, now = { testScheduler.currentTime })
        val cat = api.suiteCatalog()
        assertTrue(cat.enabled && cat.test)
        assertEquals(16, cat.camera.library.size)
        val req = ShotDraft(modelId = SampleData.DEMO, outfitId = SampleData.GREEN, scene = "She orders at the counter.", duration = 6, quality = "standard", takes = 2).request()
        val e = api.suiteEstimate(req)
        assertEquals("Shot · Standard · 768p", e.label)
        assertEquals("Generate · 6 s · $0.96 · 2 takes", e.buttonLabel) // the server's price for the same shot
        assertEquals("h3", e.engine!!.model) // demo is the owner
        val before = api.balance().balance
        val job = api.createSuiteShot(req)
        assertEquals(SuiteRules.ENGINE, job.request.engine)
        assertEquals("Shot · Standard · 768p", job.engineLabel)
        assertEquals(before - 0.96, api.balance().balance, 1e-9)
        advanceTimeBy((SuiteClock.total(job.request) / 24 * 1000 / 2).toLong())
        val mid = api.listJobs().first { it.id == job.id }
        assertEquals("running", mid.state)
        assertTrue(mid.phase, mid.phase.startsWith("take 2/2") || mid.phase.startsWith("take 1/2"))
        advanceTimeBy((SuiteClock.total(job.request) / 24 * 1000).toLong())
        val done = api.listJobs().first { it.id == job.id }
        assertEquals("done", done.state)
        val takes = api.listTakes().filter { it.jobId == job.id }
        assertEquals(listOf("Standard", "Standard"), takes.map { it.label })
        assertEquals(before, api.balance().balance, 1e-9) // test renders settle at $0
    }

    @Test fun demoRecastAndItsRefusals() = runTest {
        val api = FakeMuseApi(backgroundScope, now = { testScheduler.currentTime })
        val ok = RecastDraft(SampleData.SAMPLE_CLIP, listOf(RecastPerson("left", SampleData.DEMO, speaking = true)), quality = "hd").request()
        val e = api.suiteEstimate(ok)
        assertEquals("Recast · HD · 1080p", e.label)
        assertEquals("the person on the left", e.cast!!.single().who)
        assertEquals("yes", e.cast!!.single().speaking)
        // Noor has no character sheet yet: refused like the server.
        try { api.suiteEstimate(ok.copy(cast = listOf(ok.cast!![0].copy(characterId = SampleData.NOOR)))); fail() } catch (x: ApiException) { assertEquals("Each recast character needs a character sheet", x.message) }
        try { api.suiteEstimate(ok.copy(cast = ok.cast!! + ok.cast!!)); fail() } catch (x: ApiException) { assertEquals("bad_request", x.code) }
        try { api.suiteEstimate(ok.copy(quality = "draft", duration = 30, mode = null, cast = null, clipId = null, prompt = "x")); fail() } catch (x: ApiException) { assertEquals("nothing_fits", x.code) }
    }

    @Test fun suiteOffAndCaps() = runTest {
        val api = FakeMuseApi(backgroundScope)
        api.suiteEnabled = false
        assertFalse(api.suiteCatalog().enabled)
        try { api.suiteEstimate(ShotDraft(scene = "x").request()); fail() } catch (x: ApiException) { assertEquals("engine_unavailable", x.code) }
        api.suiteEnabled = true
        val big = api.suiteEstimate(ShotDraft(scene = "x", quality = "cinema", duration = 10, takes = 4).request())
        assertFalse(big.ok)
        assertEquals("suite_over_job_limit", big.code)
        assertTrue(big.message!!.contains("per-shot limit"))
    }

    @Test fun membersNeverSeeProviderOrModelNames() = runTest {
        // The server's member answers.
        for (f in listOf("suite_catalog_member", "suite_estimate_member", "suite_recast_estimate_member", "suite_shot_member", "suite_nothing_fits_member"))
            assertFalse(f, SuiteRules.PROVIDER_WORDS.containsMatchIn(res(f)))
        // The owner's answers do name them; the app's member filter removes every one.
        val owner = json.decodeFromString(SuiteEstimate.serializer(), res("suite_estimate_owner"))
        assertTrue(SuiteRules.PROVIDER_WORDS.containsMatchIn(json.encodeToString(SuiteEstimate.serializer(), owner)))
        val safe = SuiteRules.memberSafe(owner)
        assertNull(safe.engine); assertNull(safe.tried)
        assertFalse(SuiteRules.PROVIDER_WORDS.containsMatchIn(json.encodeToString(SuiteEstimate.serializer(), safe)))
        val cat = SuiteRules.memberSafe(json.decodeFromString(SuiteCatalog.serializer(), res("suite_catalog_owner")))
        assertFalse(SuiteRules.PROVIDER_WORDS.containsMatchIn(json.encodeToString(SuiteCatalog.serializer(), cat)))
        // Demo mode as a member: no engine, no settings.
        val api = FakeMuseApi(backgroundScope)
        api.suiteOwner = false
        assertFalse(SuiteRules.PROVIDER_WORDS.containsMatchIn(json.encodeToString(SuiteCatalog.serializer(), api.suiteCatalog())))
        val e = api.suiteEstimate(ShotDraft(modelId = SampleData.DEMO, scene = "x").request())
        assertNull(e.engine)
        assertFalse(SuiteRules.PROVIDER_WORDS.containsMatchIn(json.encodeToString(SuiteEstimate.serializer(), e)))
        try { api.suiteSettings(); fail() } catch (x: ApiException) { assertEquals("owner_only", x.code) }
        assertNotNull(FakeMuseApi(backgroundScope).suiteSettings().models.firstOrNull())
    }
}

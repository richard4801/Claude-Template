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
import studio.muse.app.data.SuiteInputs
import studio.muse.app.ui.screens.suite.InputSlots
import studio.muse.app.ui.screens.suite.composer.ComposerDraft
import studio.muse.app.ui.screens.suite.composer.PromptTokens

/** Demo mode's suite end to end (no server), and the member-safety rules on every answer a member gets. */
@OptIn(ExperimentalCoroutinesApi::class)
class SuiteDemoTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true }
    private fun res(name: String) = javaClass.getResource("/suite/$name.json")!!.readText()

    /** A composer Shot's request (no slots), as Generate sends it. */
    private fun shot(scene: String, modelId: String? = null, outfitId: String? = null, duration: Int = 5, quality: String = "draft", takes: Int = 1) =
        ComposerDraft(tokens = PromptTokens().withText(scene), modelId = modelId, outfitId = outfitId, duration = duration, quality = quality, takes = takes)
            .request(InputSlots(), SuiteInputs.NONE, RecastDraft())

    @Test fun demoShotEstimatesRendersAndSettlesFree() = runTest {
        val api = FakeMuseApi(backgroundScope, now = { testScheduler.currentTime })
        val cat = api.suiteCatalog()
        assertTrue(cat.enabled && cat.test)
        assertEquals(16, cat.camera.library.size)
        val req = shot("She orders at the counter.", SampleData.DEMO, SampleData.GREEN, duration = 6, quality = "standard", takes = 2)
            .copy(camera = kotlinx.serialization.json.Json.parseToJsonElement("""{"mode":"preset","palette":{"preset":"hyper_neon"}}"""))
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
        // Look grading: the estimate names the Look and both takes carry it (the Edit suite opens with it applied).
        assertEquals("palette:hyper_neon", e.look?.lut)
        assertEquals(listOf("palette:hyper_neon", "palette:hyper_neon"), takes.map { it.look?.lut })
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
        try { api.suiteEstimate(shot("x")); fail() } catch (x: ApiException) { assertEquals("engine_unavailable", x.code) }
        api.suiteEnabled = true
        val big = api.suiteEstimate(shot("x", quality = "cinema", duration = 10, takes = 4))
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
        val e = api.suiteEstimate(shot("x", SampleData.DEMO))
        assertNull(e.engine)
        assertFalse(SuiteRules.PROVIDER_WORDS.containsMatchIn(json.encodeToString(SuiteEstimate.serializer(), e)))
        try { api.suiteSettings(); fail() } catch (x: ApiException) { assertEquals("owner_only", x.code) }
        assertNotNull(FakeMuseApi(backgroundScope).suiteSettings().models.firstOrNull())
    }
}

package studio.muse.app.ui.screens.edit

import kotlinx.coroutines.MainScope
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import studio.muse.app.data.ApiException
import studio.muse.app.data.ErrorText
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.MuseApi

/** The server restarting mid-analysis (owner's first real run of 0.1.2): Reconnecting…, then Try again; never "Server error 502". */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class RecipeRestartTest {
    private val noWait: suspend (Long) -> Unit = {}

    /** The fake, with [outages] transient failures on reference reads before it answers again. */
    private class Flaky(val api: FakeMuseApi, var outages: Int, val code: String = "server_restarting") : MuseApi by api {
        var reads = 0
        override suspend fun reference(id: String) = api.reference(id).also { reads++ }.let { if (outages-- > 0) throw ApiException(code, ErrorText.http(502)) else it }
    }

    private fun fake() = FakeMuseApi(MainScope(), null, speed = 0.0, genDelayMs = 0)

    @Test fun aShortRestartIsRiddenOut() = runBlocking {
        val api = Flaky(fake(), outages = 3)
        val start = api.createReference("up_1", "Café", null)
        val steps = mutableListOf<String>()
        val ui = follow(api, start, "up_1", pause = noWait) { (it.phase as? RecipePhase.Analysing)?.step?.let(steps::add) }
        assertTrue(ui.phase is RecipePhase.Ready)
        assertTrue("Reconnecting…" in steps)
    }

    @Test fun aLongRestartEndsInTryAgainWhichPicksItBackUp() = runBlocking {
        val api = Flaky(fake(), outages = 1000)
        val start = api.createReference("up_1", "Café", null)
        val ui = follow(api, start, "up_1", maxWaitMs = 10_000, pause = noWait) {}
        val failed = ui.phase as RecipePhase.Failed
        assertEquals(RECIPE_RESTARTED, failed.message)
        assertEquals(RecipeRetry(start.id, "up_1", "Café"), failed.retry)
        api.outages = 0 // the server is back
        assertTrue(resume(api, failed.retry!!, noWait) {}.phase is RecipePhase.Ready)
    }

    @Test fun aLostReferenceIsMadeAgainFromTheSameUpload() = runBlocking {
        val f = fake()
        var made = 0
        val api = object : MuseApi by f {
            override suspend fun reference(id: String) = if (id == "rx_gone") throw ApiException("not_found", "Reference not found") else f.reference(id)
            override suspend fun createReference(uploadId: String, name: String?, sourceUrl: String?) = f.createReference(uploadId, name, sourceUrl).also { made++ }
        }
        assertTrue(resume(api, RecipeRetry("rx_gone", "up_1", "Café"), noWait) {}.phase is RecipePhase.Ready)
        assertEquals(1, made)
    }

    @Test fun otherErrorsAreNotRetried() = runBlocking {
        val api = Flaky(fake(), outages = 1, code = "owner_only")
        val start = api.createReference("up_1", "Café", null)
        try { follow(api, start, pause = noWait) {}; throw AssertionError("expected owner_only") } catch (e: ApiException) { assertEquals("owner_only", e.code) }
    }

    @Test fun rawHttpErrorsReadAsPlainWords() {
        assertEquals("server_restarting", ErrorText.codeOf(502))
        assertTrue(ApiException(ErrorText.codeOf(503), ErrorText.http(503)).transient)
        assertEquals(ErrorText.RESTARTING, ErrorText.of("http_502", "Server error 502"))
        assertEquals(ErrorText.RESTARTING, ErrorText.of("server_restarting", null))
        assertEquals("Something went wrong on the studio server. Try again.", ErrorText.of("http_500", "Server error 500"))
        for (s in listOf(400, 404, 409, 500, 502, 503, 504, 520)) assertTrue(!ErrorText.http(s).contains(Regex("""\d{3}""")))
    }
}

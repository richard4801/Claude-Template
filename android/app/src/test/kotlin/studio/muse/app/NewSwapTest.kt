package studio.muse.app

import kotlinx.coroutines.MainScope
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.AppPrefs
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.MemoryPrefs
import studio.muse.app.data.RemixDraft
import studio.muse.app.data.RemixModels
import studio.muse.app.data.SampleData
import studio.muse.app.data.SuiteShotRequest
import studio.muse.app.data.SuiteWireJson
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject

/** New Swap on Android (Remix.kt, NewSwapState.kt): the Mac's request contract, what's missing, and no spend without a price. */
@org.junit.runner.RunWith(org.robolectric.RobolectricTestRunner::class)
@org.robolectric.annotation.Config(sdk = [35])
class NewSwapTest {
    @Test fun requestCarriesOnlyTheTogglesThatAreOn() {
        val d = RemixDraft(backgroundOn = true, backgroundWords = "  a rooftop  ", lookOn = false, keepAudio = false, range = studio.muse.app.data.RemixRange(1.0, 6.0))
        val r = d.request("clip_1", "Dance")!!
        assertEquals("remix", r.mode); assertEquals("clip_1", r.clipId); assertEquals(false, r.keepAudio); assertEquals(listOf(1.0, 6.0), r.range)
        val o = SuiteWireJson.encodeToJsonElement(SuiteShotRequest.serializer(), r).jsonObject
        val remix = o["remix"]!!.jsonObject
        assertEquals(setOf("background"), remix.keys)
        assertEquals("a rooftop", (remix["background"] as JsonObject)["words"].toString().trim('"'))
        assertNull(o["engineModel"]) // Auto: left out
    }

    @Test fun missingSaysWhatEachToggleNeedsAndBlocksTheRequest() {
        assertEquals("Turn on a change: Background, Outfit, Character or Look & light", RemixDraft().missing)
        assertEquals("Outfit: pick one of her outfits", RemixDraft(outfitOn = true).missing)
        assertNull(RemixDraft(outfitOn = true).request("c", "x"))
        assertNull(RemixDraft(lookOn = true, lookWords = "night").request(null, null)) // no clip, no request
        assertNotNull(RemixDraft(lookOn = true, lookWords = "night").request("c", "x"))
    }

    @Test fun clampRangeKeepsTheWholeClipAsNull() {
        assertNull(RemixDraft.clampRange(0.0, 9.4, 9.4))
        assertEquals(studio.muse.app.data.RemixRange(1.2, 5.0), RemixDraft.clampRange(1.23, 5.0, 9.4))
    }

    @Test fun aBadModelRowIsLeftOutAlone() {
        val e = Json.parseToJsonElement("""{"toggles":["look"],"models":[{"model":"a","label":"A · P"},{"bad":1},{"model":"b","label":"B · P","auto":true}]}""")
        val m = RemixModels.parse(e)
        assertEquals(listOf("a", "b"), m.models.map { it.model })
        assertEquals("auto", m.models[1].groupId)
    }

    @Test fun demoEstimateIsPricedAndGenerateNeedsIt() = runBlocking {
        val scope = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Default)
        val fake = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
        val c = AppContainer(scope, MemoryPrefs(AppPrefs(useFake = true, token = "t", role = "owner")), fake, null)
        val ns = c.suite.newSwap
        ns.useSample()
        assertNull(ns.generate()) // nothing on, no estimate: nothing runs
        ns.draft.value = RemixDraft(characterOn = true, modelId = SampleData.DEMO)
        assertNull(ns.generate()) // no estimate yet: nothing runs
        ns.refresh()
        val e = ns.estimate.value!!
        assertEquals("remix", e.mode); assertTrue(e.test)
        assertNotNull(ns.models.value)
    }
}

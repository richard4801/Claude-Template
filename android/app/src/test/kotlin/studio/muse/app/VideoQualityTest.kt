package studio.muse.app

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import studio.muse.app.data.ApiException
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.Job
import studio.muse.app.data.SampleData
import studio.muse.app.data.StudioSettings
import studio.muse.app.data.VideoDraft
import studio.muse.app.data.VideoFeatures
import studio.muse.core.ClipUse
import studio.muse.core.Engine
import studio.muse.core.Pricing
import studio.muse.core.Quality
import studio.muse.core.VideoOption

/** The video quality picker (plans/api.md "Video engines and quality"): Draft by default, Replicate vs Exact edit requests. */
@OptIn(ExperimentalCoroutinesApi::class)
class VideoQualityTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test fun draftIsTheDefault() {
        val d = VideoDraft()
        assertEquals(Engine.REPLICATE, d.engine)
        assertEquals(Quality.DRAFT, d.quality)
        assertEquals(VideoOption.DRAFT, d.option)
        assertEquals("draft", VideoFeatures().defaultQuality)
        assertEquals(listOf("draft", "standard", "hd"), VideoFeatures.DEFAULT.options.map { it.id })
        assertEquals(listOf("edit", "fast", "upscale"), VideoFeatures.DEFAULT.addons.map { it.id })
    }

    @Test fun replicateRequestIsWholeClipWithoutExactEditOptions() {
        val d = VideoDraft(lipSync = true, background = "photo", use = ClipUse.FIRST).pick(VideoOption.HD)
        val r = d.request("Kitchen", "m", "o", "c", 7.0)
        assertEquals("replicate", r.engine)
        assertEquals("hd", r.quality)
        assertEquals("full", r.use)
        assertFalse(r.lipSync)
        assertEquals("keep", r.background)
        assertEquals("about \$0.91 · 7 s", Pricing.priceLine(r.spec()))
    }

    @Test fun editAlwaysUsesTheWholeClipAndTheDefaultSteps() {
        val d = VideoDraft(steps = 14, use = ClipUse.FIRST, lipSync = true).pick(VideoOption.EDIT)
        val r = d.request("Kitchen", "m", "o", "c", 7.0)
        assertEquals("h3", r.engine)
        assertNull(r.quality)
        assertEquals(10, r.steps)
        assertEquals("full", r.use)
        assertTrue(r.lipSync)
        assertEquals("Edit", Pricing.engineLabel(r.spec()))
        assertEquals("Edit", VideoDraft(engine = studio.muse.core.Engine.H3, steps = 30).option.label)
        // Back to a Replicate quality keeps the last one picked.
        assertEquals(VideoOption.DRAFT, d.pick(VideoOption.DRAFT).option)
    }

    @Test fun livePriceFromTheServerFeatures() {
        val st = json.decodeFromString(StudioSettings.serializer(), """{"features":{"replicate":true,"video":{"defaultEngine":"replicate","defaultQuality":"draft","minSeconds":4,"maxSeconds":15,
            "options":[{"id":"draft","label":"Draft","detail":"768P · lite","engine":"replicate","quality":"draft","resolution":"768P","pricePerSec":0.03,"available":true},
            {"id":"exact","label":"Exact edit","detail":"x","engine":"h3","available":false}]}}}""")
        val v = st.features.video!!
        assertTrue(st.features.replicate)
        assertEquals(0.03, v.pricePerSec(Quality.DRAFT)!!, 0.0)
        assertFalse(v.available("exact"))
        assertTrue(v.available("hd")) // not listed: assumed available
        val spec = VideoDraft(clip = null).spec(v.pricePerSec(Quality.DRAFT))
        assertEquals("about \$0.30 · 10 s", Pricing.priceLine(spec)) // sample clip: 9.4 s → 10 s
    }

    @Test fun jobLabelsAndErrorCodesFromTheServer() {
        val j = json.decodeFromString(Job.serializer(), """{"id":"j","title":"t","modelId":"m","modelName":"M","outfitId":"o","state":"failed",
            "request":{"title":"t","modelId":"m","outfitId":"o","clipId":"c","engine":"replicate","quality":"standard","pricePerSec":0.08},
            "engineLabel":"Standard · 768P","errorCode":"provider_refused","error":"Replicate's safety filter refused this clip"}""")
        assertEquals("Standard · 768P", j.engineLabel)
        assertEquals("provider_refused", j.errorCode)
        val noLabel = j.copy(serverEngineLabel = null)
        assertEquals("Standard · 768P", noLabel.engineLabel)
    }

    @Test fun demoStudioRunsReplicateJobs() = runTest {
        val api = FakeMuseApi(backgroundScope, now = { testScheduler.currentTime })
        val job = api.createJob(VideoDraft().request("Living-room dance", SampleData.SIENNA, SampleData.GREEN, SampleData.SAMPLE_CLIP, null))
        assertEquals("draft", job.request.quality)
        assertEquals(0.02 * 10, job.cost, 1e-9)
        assertEquals("Draft · 768P", job.engineLabel)
        try {
            api.createJob(VideoDraft().request("x", SampleData.SIENNA, SampleData.GREEN, SampleData.SAMPLE_CLIP, null).copy(lipSync = true))
            fail("lip sync on Replicate should be refused")
        } catch (e: ApiException) { assertEquals("bad_request", e.code) }
    }
}

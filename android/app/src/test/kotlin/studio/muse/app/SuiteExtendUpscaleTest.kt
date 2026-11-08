package studio.muse.app

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import studio.muse.app.data.AddonInfo
import studio.muse.app.data.ApiException
import studio.muse.app.data.ExtendRules
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.SuiteCatalog
import studio.muse.app.data.SuiteClock
import studio.muse.app.data.SuiteInputs
import studio.muse.app.data.SuiteMediaRef
import studio.muse.app.data.SuiteRules
import studio.muse.app.data.SuiteShotRequest
import studio.muse.app.data.Take
import studio.muse.app.data.UpscaleOffer
import studio.muse.app.data.UpscaleSizeInfo
import studio.muse.app.data.VideoFeatures
import studio.muse.app.ui.screens.suite.InputSlots
import studio.muse.app.ui.screens.suite.RecastDraft
import studio.muse.app.ui.screens.suite.SlotValue
import studio.muse.app.ui.screens.suite.TakeActions
import studio.muse.app.ui.screens.suite.composer.ComposerDraft
import studio.muse.app.ui.screens.suite.composer.ComposerTool
import studio.muse.app.ui.screens.suite.composer.ExtendSlot
import studio.muse.app.ui.screens.suite.composer.PromptTokens
import studio.muse.app.ui.screens.suite.composer.SwapAddon
import studio.muse.app.ui.screens.suite.composer.SwapAddons
import studio.muse.app.ui.screens.suite.composer.ToolSlots

/** Extend on the composer and Upscale on finished takes: the requests, the tools' availability, the prices and demo mode. */
@OptIn(ExperimentalCoroutinesApi::class)
class SuiteExtendUpscaleTest {
    /** HttpMuseApi's encoder: nulls are left out, defaults are sent. */
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true; coerceInputValues = true }
    private fun res(name: String) = javaClass.getResource("/suite/$name.json")!!.readText()

    /** The keys server/api's ShotRequestSchema (.strict()) accepts, and those of extend and its VideoRef. */
    private val SHOT_KEYS = setOf("draft", "mode", "extend", "cast", "title", "modelId", "outfitId", "prompt", "frames", "references", "duration", "aspectRatio", "quality", "takes",
        "audio", "speaking", "camera", "gradeLook", "seed", "engineModel", "resolution", "clipId", "keepAudio", "direction", "dryRun")
    private val EXTEND_KEYS = setOf("video", "direction", "join")
    private val VIDEO_KEYS = setOf("key", "url", "seconds")

    private val serverTake = Take("t_77", "take", "j_77", 1, 1, "Café morning", "Draft", "Shot · Draft · 768p", videoUrl = "https://api.muse.studio/uploads/takes/j_77/take_1.mp4?sig=abc", durationSec = 4.0)

    private fun extendDraft(direction: String = "after", duration: Int = 5, text: String = "She turns away and walks out.") =
        ComposerDraft(tool = ComposerTool.EXTEND, extendDirection = direction, duration = duration, tokens = PromptTokens().withText(text))

    private fun own(v: SlotValue) = InputSlots().put(ToolSlots.EXTEND_VIDEO, v)

    private fun encoded(r: SuiteShotRequest): JsonObject = json.encodeToJsonElement(SuiteShotRequest.serializer(), r).jsonObject

    // ---------------------------------------------------------------- the request

    @Test fun `a take's stored key is the part after uploads in its videoUrl`() {
        assertEquals("takes/j_77/take_1.mp4", ExtendRules.keyOf(serverTake.videoUrl))
        assertEquals("clips/src.mp4", ExtendRules.keyOf("http://10.0.2.2:8787/uploads/clips/src.mp4"))
        assertNull(ExtendRules.keyOf(null))
        assertNull(ExtendRules.keyOf("file:///data/edit.mp4")) // an edit saved on the phone has no stored key
        assertEquals("takes/j_77/take_1.mp4", ExtendRules.keyOf(serverTake, demo = false))
        // A simulated take has no file: only demo mode stands one in; photo shots are never extended.
        val sim = serverTake.copy(id = "t_sim", videoUrl = null)
        assertNull(ExtendRules.keyOf(sim, demo = false))
        assertEquals(ExtendRules.demoKey("t_sim"), ExtendRules.keyOf(sim, demo = true))
        assertNull(ExtendRules.keyOf(sim.copy(kind = "shot"), demo = true))
        assertTrue(TakeActions.canExtend(serverTake, false)); assertFalse(TakeActions.canExtend(sim, false))
    }

    @Test fun `Extend sends the take key, the direction and the new part, with only keys the server accepts`() {
        val slot = own(ExtendSlot.fromTake(serverTake, ExtendRules.keyOf(serverTake, false)!!))
        val d = extendDraft("before", 4)
        assertNull(d.problem(InputSlots(), RecastDraft(), slot))
        val r = d.request(InputSlots(), SuiteInputs.NONE, RecastDraft(), slot)
        assertEquals("extend", r.mode)
        assertEquals(SuiteMediaRef(key = "takes/j_77/take_1.mp4"), r.extend!!.video) // a take: its key only, the server reads its length
        assertEquals("before", r.extend!!.direction)
        assertEquals(4, r.duration)
        assertEquals("She turns away and walks out.", r.prompt)
        val o = encoded(r)
        assertTrue("${o.keys - SHOT_KEYS}", SHOT_KEYS.containsAll(o.keys))
        assertEquals(setOf("mode", "extend", "prompt", "duration", "quality", "takes", "draft"), o.keys) // no shape, camera, sound or engine; draft: Reuse settings
        val ex = o["extend"]!!.jsonObject
        assertTrue(EXTEND_KEYS.containsAll(ex.keys)); assertFalse("join" in ex.keys) // the server's default joins source + new part
        assertEquals(setOf("key"), ex["video"]!!.jsonObject.keys)
        assertTrue(VIDEO_KEYS.containsAll(ex["video"]!!.jsonObject.keys))
        // After is the default direction; the placeholder follows it.
        assertEquals("after", extendDraft().request(InputSlots(), SuiteInputs.NONE, RecastDraft(), slot).extend!!.direction)
        assertEquals("What happens next", extendDraft().placeholder); assertEquals("What happens before", extendDraft("before").placeholder)
    }

    @Test fun `an upload sends its key and seconds, nothing is sent before the slot is ready`() {
        val up = own(SlotValue(name = "beach.mp4", media = SuiteMediaRef(key = "uploads/u_1.mp4", seconds = 6.4321), use = ExtendSlot.UPLOAD))
        val r = extendDraft().request(InputSlots(), SuiteInputs.NONE, RecastDraft(), up)
        assertEquals(SuiteMediaRef(key = "uploads/u_1.mp4", seconds = 6.43), r.extend!!.video)
        assertEquals(setOf("key", "seconds"), encoded(r)["extend"]!!.jsonObject["video"]!!.jsonObject.keys)
        // What stops Generate, in plain words.
        val d = extendDraft()
        assertEquals("Pick the video to extend", d.problem(InputSlots(), RecastDraft(), InputSlots()))
        assertEquals("Waiting for the upload", d.problem(InputSlots(), RecastDraft(), own(SlotValue(name = "a.mp4", progress = .4f))))
        assertEquals("Pick a video up to 60 s", d.problem(InputSlots(), RecastDraft(), own(SlotValue(media = SuiteMediaRef(key = "k", seconds = 75.0), use = ExtendSlot.UPLOAD))))
        assertEquals("Couldn't read that video's length", d.problem(InputSlots(), RecastDraft(), own(SlotValue(media = SuiteMediaRef(key = "k"), use = ExtendSlot.UPLOAD))))
        assertNull(d.request(InputSlots(), SuiteInputs.NONE, RecastDraft(), own(SlotValue(name = "a.mp4", progress = .4f))).extend)
    }

    @Test fun `the catalog tools drive Extend, an older or coming-soon catalog keeps it off`() {
        val member = json.decodeFromString(SuiteCatalog.serializer(), res("suite_catalog_member"))
        assertFalse(ComposerTool.EXTEND.isLive(member)) // the fixture says comingSoon
        val live = member.copy(tools = member.tools!!.map { if (it.id == "extend") it.copy(available = true, comingSoon = false) else it })
        assertTrue(ComposerTool.EXTEND.isLive(live))
        assertFalse(ComposerTool.EXTEND.isLive(member.copy(tools = null))) // a server from before tools
        assertEquals(listOf("video"), ToolSlots.of(ComposerTool.EXTEND, SuiteInputs.NONE, InputSlots()).map { it.kind })
        assertEquals(ToolSlots.EXTEND_VIDEO, ToolSlots.ownSlot(ComposerTool.EXTEND, "video"))
        assertEquals("Extend", ComposerTool.EXTEND.title)
    }

    // ---------------------------------------------------------------- Upscale prices

    @Test fun `upscale price is dollars per second times the take seconds, unpriced sizes say Soon`() {
        val demo = VideoFeatures.DEMO.upscale
        val c = UpscaleOffer.choices(demo, 8.0)
        assertEquals(listOf("1080p", "2K", "4K"), c.map { it.label })
        assertEquals(listOf(0.16, 0.32, null), c.map { it.price })
        assertEquals(listOf("$0.16", "$0.32", "Soon"), c.map { it.priceText })
        assertEquals(listOf(true, true, false), c.map { it.available })
        assertEquals("1440 × 2560", c[1].frame)
        assertEquals(0.1734, UpscaleOffer.price(UpscaleSizeInfo("2k", price = 0.04, available = true), 4.335)!!, 1e-9)
        // No length, no price; the server's coming-soon features: every size greyed.
        assertTrue(UpscaleOffer.choices(demo, null).none { it.available })
        assertTrue(UpscaleOffer.choices(VideoFeatures.DEFAULT.upscale, 8.0).all { !it.available && it.priceText == "Soon" })
        assertFalse(UpscaleOffer.live(VideoFeatures.DEFAULT.upscale)); assertTrue(UpscaleOffer.live(demo))
        // After a 409 the sheet greys everything.
        assertTrue(UpscaleOffer.choices(demo, 8.0, soon = true).none { it.available })
        // The take's own length wins; else its job's seconds.
        assertEquals(4.0, UpscaleOffer.seconds(serverTake, null)!!, 0.0)
        // A size that is available but the add-on isn't (a half-shipped server) stays Soon.
        assertTrue(UpscaleOffer.choices(AddonInfo("upscale", available = false, sizes = demo.sizes), 8.0).none { it.available })
        // Upscale is offered on finished renders, never on an upscale or a photo.
        assertTrue(UpscaleOffer.canUpscale(serverTake, false))
        assertFalse(UpscaleOffer.canUpscale(serverTake.copy(videoUrl = null), false)); assertTrue(UpscaleOffer.canUpscale(serverTake.copy(videoUrl = null), true))
        assertFalse(UpscaleOffer.canUpscale(serverTake.copy(label = "Upscale · 2K"), false))
        assertFalse(UpscaleOffer.canUpscale(serverTake.copy(kind = "shot"), true))
    }

    @Test fun `the swap tool's Upscale pill goes live with priced sizes`() {
        assertEquals("Soon", SwapAddons.pills(VideoFeatures.DEFAULT, false, 1, 9.4).first { it.addon == SwapAddon.UPSCALE }.price)
        val live = SwapAddons.pills(VideoFeatures.DEMO, false, 1, 9.4).first { it.addon == SwapAddon.UPSCALE }
        assertTrue(live.available); assertEquals("On the take", live.price)
    }

    // ---------------------------------------------------------------- demo mode

    @Test fun `demo Extend estimates like the server and the take is source plus the new part`() = runTest {
        val api = FakeMuseApi(backgroundScope, now = { testScheduler.currentTime })
        assertTrue(ComposerTool.EXTEND.isLive(api.suiteCatalog()))
        api.debugPutTake(serverTake.copy(id = "t_src", jobId = null, videoUrl = null, durationSec = 4.0))
        val key = ExtendRules.demoKey("t_src")
        val d = extendDraft(duration = 3)
        val req = d.request(InputSlots(), SuiteInputs.NONE, RecastDraft(), own(SlotValue(name = "Café", media = SuiteMediaRef(key = key), use = ExtendSlot.TAKE)))
        val e = api.suiteEstimate(req)
        assertEquals("Extend · Draft · 720p", e.label)
        assertEquals("extend", e.mode)
        assertEquals(3.0, e.seconds, 0.0)
        assertEquals(0.3, e.estimate, 1e-9) // $0.10/s × 3 s
        assertEquals("Generate · 3 s · $0.30", e.buttonLabel)
        // Before can't use the after-only engine: the 480p reference engine, 4 s at least.
        val b = api.suiteEstimate(req.copy(extend = req.extend!!.copy(direction = "before")))
        assertEquals("Extend · Draft · 480p", b.label); assertEquals(4.0, b.seconds, 0.0)
        // Members never see engines.
        api.suiteOwner = false
        val me = api.suiteEstimate(req)
        assertNull(me.engine); assertFalse(SuiteRules.PROVIDER_WORDS.containsMatchIn(json.encodeToString(studio.muse.app.data.SuiteEstimate.serializer(), me)))
        api.suiteOwner = true
        // Refusals, like the server's.
        try { api.suiteEstimate(req.copy(extend = req.extend!!.copy(video = SuiteMediaRef(key = "clips/other.mp4", seconds = 4.0)))); fail() } catch (x: ApiException) { assertTrue(x.message!!.contains("isn’t in this studio")) }
        try { api.suiteEstimate(req.copy(extend = null)); fail() } catch (x: ApiException) { assertTrue(x.message!!.contains("needs the video")) }
        try { api.suiteEstimate(req.copy(duration = 20)); fail() } catch (x: ApiException) { assertEquals("nothing_fits", x.code) }
        // Render: the take is the whole longer clip.
        val job = api.createSuiteShot(req)
        assertEquals("Extend · Draft · 720p", job.engineLabel)
        advanceTimeBy((SuiteClock.total(job.request) / 24 * 1000 * 2).toLong())
        assertEquals("done", api.listJobs().first { it.id == job.id }.state)
        val take = api.listTakes().first { it.jobId == job.id }
        assertEquals(7.0, take.durationSec!!, 1e-9)
        // An upload of the studio extends with its own seconds.
        val up = api.uploadSuiteMedia("beach.mp4", ByteArray(4), "video/mp4")
        val ue = api.suiteEstimate(req.copy(extend = req.extend!!.copy(video = up.copy(seconds = 6.0))))
        assertEquals("Extend · Draft · 720p", ue.label)
        try { api.suiteEstimate(req.copy(extend = req.extend!!.copy(video = up))); fail() } catch (x: ApiException) { assertTrue(x.message!!.contains("length")) }
    }

    @Test fun `demo Upscale posts a job at price times seconds, 4K and a coming-soon server answer 409`() = runTest {
        val api = FakeMuseApi(backgroundScope, now = { testScheduler.currentTime })
        val up = api.studioSettings().features.video!!.upscale
        assertEquals(listOf(0.02, 0.04, null), up.sizes.map { it.price })
        assertEquals(listOf(true, true, false), up.sizes.map { it.available })
        api.debugPutTake(serverTake.copy(id = "t_up", jobId = null, videoUrl = null, durationSec = 8.0))
        val before = api.balance().balance
        val j = api.upscale("t_up", "2k")
        assertEquals("Upscale · 2K", j.engineLabel)
        assertEquals("upscale", j.request.engine); assertEquals("t_up", j.request.takeId); assertEquals("2k", j.request.size)
        assertEquals(0.32, j.cost, 1e-9)
        assertEquals(before - 0.32, api.balance().balance, 1e-9)
        advanceTimeBy((SuiteClock.total(j.request) / 24 * 1000 * 2).toLong())
        val t = api.listTakes().first { it.jobId == j.id }
        assertEquals("Upscale · 2K", t.label); assertEquals(8.0, t.durationSec!!, 0.0)
        try { api.upscale("t_up", "4k"); fail() } catch (x: ApiException) { assertEquals("upscale_unavailable", x.code); assertEquals("Upscale is coming soon", x.message) }
        api.debugSetUpscale(false)
        try { api.upscale("t_up", "1080p"); fail() } catch (x: ApiException) { assertEquals("upscale_unavailable", x.code) }
        try { api.upscale("nope", "2k"); fail() } catch (x: ApiException) { assertEquals("not_found", x.code) }
        assertEquals("Upscale is coming soon.", studio.muse.app.data.ErrorText.of(ApiException("upscale_unavailable", "Upscale is coming soon")))
    }
}

package studio.muse.app

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.CameraCatalog
import studio.muse.app.data.Job
import studio.muse.app.data.JobRequest
import studio.muse.app.data.SuiteRules
import studio.muse.app.data.SuiteShotRequest
import studio.muse.app.ui.screens.StagePhase
import studio.muse.app.ui.screens.suite.RecastDraft
import studio.muse.app.ui.screens.suite.StoryShot
import studio.muse.app.ui.screens.suite.Storyboard
import studio.muse.app.ui.screens.suite.SuitePane
import studio.muse.app.ui.screens.suite.nextTier
import studio.muse.app.ui.screens.suite.storyStatus
import studio.muse.app.ui.screens.suite.composer.ComposerSettings

/** The suite's pure state: the Recast and Storyboard requests, storyboard and pane states. */
class SuiteStateTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true; coerceInputValues = true }
    private val cat = json.decodeFromString(CameraCatalog.serializer(), javaClass.getResource("/suite/suite_camera.json")!!.readText())

    @Test fun recastUpToFourPeople() {
        var d = RecastDraft(clipId = "clip_1")
        assertEquals("Pick who each person becomes", d.problem())
        d = d.add()
        assertEquals(listOf("left", "right"), d.people.map { it.hint })
        d = d.add().add()
        assertEquals(4, d.people.size)
        assertEquals(d, d.add())
        d = d.update(0) { it.copy(characterId = "m_demo", speaking = true) }.update(1) { it.copy(characterId = "m_noor", speaking = false) }
            .update(2) { it.copy(characterId = "m_demo") }.update(3) { it.copy(characterId = "m_noor") }
        assertNull(d.problem())
        val r = d.request()
        assertEquals("recast", r.mode); assertEquals("clip_1", r.clipId); assertEquals(true, r.keepAudio)
        assertEquals(listOf("left", "right", "center", "foreground"), r.cast!!.map { it.personHint })
        assertEquals(listOf(true, false, null, null), r.cast!!.map { it.speaking })
        assertEquals("Two people point at the same spot", d.update(1) { it.copy(hint = "left") }.problem())
        assertEquals(3, d.remove(3).people.size)
        assertEquals("Choose the source clip", RecastDraft().problem())
    }

    private fun job(state: String, progress: Double, take: Int = 1, takes: Int = 2, queue: Int? = null) = Job("j", "Café", "m", "Demo model", "", JobRequest(engine = SuiteRules.ENGINE, takes = takes, quality = "hd", seconds = 8.0),
        state, progress, take, phase = if (state == "running") "take $take/$takes · Rendering · ~2 min left" else "Done", secondsLeft = 120.0, cost = 2.08, queuePosition = queue,
        serverEngineLabel = "Shot · HD · 2K")

    @Test fun paneStates() {
        assertEquals(StagePhase.IDLE, SuitePane.of(null, emptyList(), null).phase)
        val r = SuitePane.of(job("running", 62.0, take = 2), emptyList(), "Demo model")
        assertEquals(StagePhase.RENDERING, r.phase)
        assertEquals("Rendering take 2 of 2", r.headline)
        assertEquals("62%", r.percent)
        assertEquals("Motion & camera · ~2 min", r.step)
        assertEquals("Keyframe from Demo’s sheet", SuitePane.of(job("running", 52.0, take = 2), emptyList(), "Demo model").step.substringBefore(" ·"))
        val q = SuitePane.of(job("running", 0.0, queue = 2), emptyList(), null)
        assertEquals(StagePhase.QUEUED, q.phase); assertEquals("#2 in line", q.badge)
        val f = SuitePane.of(job("failed", 18.0).copy(errorCode = "provider_failed"), emptyList(), null)
        assertEquals(StagePhase.FAILED, f.phase)
        assertTrue(f.failure!!.contains("weren't charged"))
        assertEquals("standard", nextTier("draft")); assertNull(nextTier("cinema"))
    }

    @Test fun storyboardGeneratesThePendingShotsWithOneCastAndLook() {
        val b = Storyboard("Café GRWM", listOf("m_demo"), shots = listOf(StoryShot("s1", "Door", "walks in", "handheld", 3, jobId = "j"), StoryShot("s2", "Counter", "orders", "dolly_in", 4)))
        assertEquals(7, b.seconds)
        val jobs = listOf(job("done", 100.0))
        assertEquals(listOf("s2"), b.pending(jobs).map { it.id })
        assertEquals(listOf("s1", "s2"), b.pending(listOf(job("failed", 10.0))).map { it.id })
        val r = b.request(b.shots[1], ComposerSettings(body = "film_35", lens = "anamorphic"), 1)
        assertEquals("Café GRWM · 2", r.title); assertEquals("m_demo", r.modelId); assertEquals(4, r.duration); assertEquals("hd", r.quality)
        val cam = r.camera as JsonObject
        assertEquals("dolly_in", cam["move"]!!.jsonObject["id"]!!.jsonPrimitive.content)
        assertTrue("mix" !in cam)
        assertEquals(0.6, cam["move"]!!.jsonObject["intensity"]!!.jsonPrimitive.content.toDouble(), 1e-9)
        assertEquals("film_35", cam["rig"]!!.jsonObject["body"]!!.jsonPrimitive.content) // the look lock: same rig on every shot
        assertEquals("Ready", storyStatus(b.shots[0], jobs).label)
        assertEquals("Not made", storyStatus(b.shots[1], jobs).label)
        assertEquals("40%", storyStatus(b.shots[0], listOf(job("running", 40.0))).label)
        assertEquals("s2", b.withJob("s2", "j2").shots[1].let { it.id }); assertEquals("j2", b.withJob("s2", "j2").shots[1].jobId)
    }
}

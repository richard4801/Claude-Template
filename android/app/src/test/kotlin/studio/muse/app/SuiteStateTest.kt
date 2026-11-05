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
import studio.muse.app.ui.screens.suite.CAMERA_AUTO
import studio.muse.app.ui.screens.suite.CameraDraft
import studio.muse.app.ui.screens.suite.CameraGroups
import studio.muse.app.ui.screens.suite.RecastDraft
import studio.muse.app.ui.screens.suite.ShotDraft
import studio.muse.app.ui.screens.suite.StoryShot
import studio.muse.app.ui.screens.suite.Storyboard
import studio.muse.app.ui.screens.suite.SuitePane
import studio.muse.app.ui.screens.suite.applyPreset
import studio.muse.app.ui.screens.suite.chipLabel
import studio.muse.app.ui.screens.suite.nextTier
import studio.muse.app.ui.screens.suite.pick
import studio.muse.app.ui.screens.suite.selected
import studio.muse.app.ui.screens.suite.storyStatus

/** The suite's pure state: camera rules (Mix 2/2), picker groups, the requests each draft sends, storyboard and pane states. */
class SuiteStateTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true; coerceInputValues = true }
    private val cat = json.decodeFromString(CameraCatalog.serializer(), javaClass.getResource("/suite/suite_camera.json")!!.readText())

    @Test fun movesMixAtMostTwoCompatibleOnes() {
        var d = CAMERA_AUTO
        d = d.toggleMove("dolly_in", cat).first
        assertEquals(listOf("dolly_in"), d.moves.map { it.id })
        // Two moves of the same kind don't mix: the new one replaces move 1, with a reason.
        val (same, why) = d.toggleMove("dolly_out", cat)
        assertEquals(listOf("dolly_out"), same.moves.map { it.id })
        assertNotNull(why)
        d = d.toggleMove("rack_focus", cat).first
        assertEquals(listOf("dolly_in", "rack_focus"), d.moves.map { it.id })
        assertEquals("Mix 2/2", d.mixLabel)
        assertEquals(1, d.active)
        val (full, msg) = d.toggleMove("crane_up", cat)
        assertEquals(d, full)
        assertTrue(msg!!.startsWith("Mix 2/2"))
        // Static and aerial never mix.
        assertTrue(!SuiteRules.canMix(cat.move("static"), cat.move("dolly_in")))
        assertTrue(!SuiteRules.canMix(cat.move("fpv"), cat.move("rack_focus")))
        // Tapping a picked move takes it out.
        assertEquals(listOf("rack_focus"), d.toggleMove("dolly_in", cat).first.moves.map { it.id })
        val tuned = d.setActive(0).tune(intensity = 80, speed = "slow")
        assertEquals(80, tuned.moves[0].intensity); assertEquals("slow", tuned.moves[0].speed); assertEquals(60, tuned.moves[1].intensity)
    }

    @Test fun cameraSpecAndSummary() {
        val d = CameraDraft()
        val spec = d.spec().jsonObject
        assertEquals("preset", spec["mode"]!!.jsonPrimitive.content)
        assertEquals("super35", spec["rig"]!!.jsonObject["body"]!!.jsonPrimitive.content)
        assertEquals(0.6, spec["move"]!!.jsonObject["intensity"]!!.jsonPrimitive.content.toDouble(), 1e-9)
        assertEquals("rack_focus", spec["mix"]!!.jsonObject["id"]!!.jsonPrimitive.content)
        assertEquals("Super 35 · Anamorphic 40 mm · T2 · Soft Cross · Teal & Orange", d.summary(cat))
        assertEquals("Dolly in · 60%", d.moveTitle(cat))
        assertEquals("+ Rack focus · Eye · MCU", d.moveSub(cat))
        // Auto sends only the mode; unknown ids are dropped by fit().
        assertEquals(setOf("mode"), CAMERA_AUTO.spec().jsonObject.keys)
        assertNull(d.copy(body = "teleport_cam").fit(cat).body)
        // Directed mode's JSON is sent as applied.
        val directed = Json.parseToJsonElement("""{"mode":"directed","guide":{"video":{"key":"cam/g.mp4"}}}""")
        assertEquals(directed, d.copy(directed = directed).spec())
    }

    @Test fun pickerGroupsShowRendersAndStartOnAuto() {
        val groups = CameraGroups.all(cat)
        val body = groups.first { it.id == CameraGroups.BODY }
        assertEquals("body-02-super35", body.options.first { it.id == "super35" }.render)
        assertTrue(body.options.first().render != null) // hardware first
        assertEquals(2, groups.first { it.id == CameraGroups.MOVE }.max)
        assertEquals(16, groups.first { it.id == CameraGroups.MOVE }.options.size)
        assertEquals("Auto", CAMERA_AUTO.chipLabel(cat, CameraGroups.LIGHTING))
        val lit = CAMERA_AUTO.pick(CameraGroups.LIGHTING, "contre_jour")
        assertEquals(listOf("contre_jour"), lit.selected(CameraGroups.LIGHTING))
        assertEquals("Contre-jour", lit.chipLabel(cat, CameraGroups.LIGHTING))
        val cine = CAMERA_AUTO.applyPreset(cat.presets.first { it.id == "cinematic" })
        assertEquals("film_35", cine.body); assertEquals("dolly_in", cine.moves.single().id); assertEquals(50, cine.moves.single().intensity)
    }

    @Test fun shotRequest() {
        val d = ShotDraft(modelId = "m_demo", outfitId = "o_green", scene = "  She smiles.  ", duration = 6, quality = "hd", takes = 2, speaking = false)
        val r = d.request()
        assertEquals("m_demo", r.modelId); assertEquals("o_green", r.outfitId); assertEquals("She smiles.", r.prompt)
        assertEquals(6, r.duration); assertEquals("hd", r.quality); assertEquals(2, r.takes); assertEquals(false, r.speaking)
        assertNull(r.mode)
        // Nulls are left out on the wire, so the server's defaults apply.
        val wire = json.encodeToJsonElement(SuiteShotRequest.serializer(), ShotDraft(scene = "x").request()).jsonObject
        assertTrue("modelId" !in wire && "cast" !in wire && "engineModel" !in wire)
        assertEquals("Pick a character or describe the shot", ShotDraft().problem())
    }

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
        val r = b.request(b.shots[1], CameraDraft(), 1)
        assertEquals("Café GRWM · 2", r.title); assertEquals("m_demo", r.modelId); assertEquals(4, r.duration); assertEquals("hd", r.quality)
        val cam = r.camera as JsonObject
        assertEquals("dolly_in", cam["move"]!!.jsonObject["id"]!!.jsonPrimitive.content)
        assertTrue("mix" !in cam)
        assertEquals("super35", cam["rig"]!!.jsonObject["body"]!!.jsonPrimitive.content) // the look lock: same rig on every shot
        assertEquals("Ready", storyStatus(b.shots[0], jobs).label)
        assertEquals("Not made", storyStatus(b.shots[1], jobs).label)
        assertEquals("40%", storyStatus(b.shots[0], listOf(job("running", 40.0))).label)
        assertEquals("s2", b.withJob("s2", "j2").shots[1].let { it.id }); assertEquals("j2", b.withJob("s2", "j2").shots[1].jobId)
    }
}

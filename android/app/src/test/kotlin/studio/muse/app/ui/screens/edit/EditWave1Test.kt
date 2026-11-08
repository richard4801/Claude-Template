package studio.muse.app.ui.screens.edit

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.EditorEstimate
import studio.muse.app.data.EditorJob
import studio.muse.app.data.EditorSourceDto
import studio.muse.core.edit.AnimKind
import studio.muse.core.edit.AudioClip
import studio.muse.core.edit.CanvasFill
import studio.muse.core.edit.Ease
import studio.muse.core.edit.EditJson
import studio.muse.core.edit.EditProject
import studio.muse.core.edit.Fit
import studio.muse.core.edit.Font
import studio.muse.core.edit.KfProp
import studio.muse.core.edit.LayerRole
import studio.muse.core.edit.MediaInfo
import studio.muse.core.edit.SourceSize
import studio.muse.core.edit.TextItem
import studio.muse.core.edit.TrackKind
import studio.muse.core.edit.Transform
import studio.muse.core.edit.VideoClip
import studio.muse.core.edit.durationSec
import studio.muse.core.edit.planRender
import studio.muse.core.edit.problemOf
import studio.muse.core.edit.timeline

/**
 * Wave 1 of the Edit parity work (plans/edit-parity.md), driven through the editor's state machine: moving and
 * reordering, trimming any item, text (add, style, animation), opacity / volume keyframes and easing, frame steps,
 * background colour and blur fill, clip fit, mirror and freeze frames. Each asserts the project, that it stays valid,
 * and, where it shows, the render plan the preview and export are built from.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class EditWave1Test {
    private object NoBackend : EditBackend {
        override suspend fun estimate(kind: String, source: EditorSourceDto, options: JsonObject?): Pair<EditorEstimate?, String?> = null to "off"
        override suspend fun run(kind: String, source: EditorSourceDto, options: JsonObject?, onProgress: (EditorJob) -> Unit): Pair<JsonObject?, String?> = null to "off"
    }

    private val infos = mapOf("src" to MediaInfo(15.0, 1080, 1920, 30.0, true))

    private fun TestScope.controller() = EditSuiteController(this, NoBackend).also {
        it.load(EditSuiteViewModel.newProject("take_1", 15.0, SourceSize(1080, 1920, 30.0, true)), "Take", "take_1", null, reopened = false)
    }

    private fun EditSuiteController.p() = project!!
    private fun valid(p: EditProject) { assertNull(problemOf(p)?.message, problemOf(p)); EditJson.parse(EditJson.stringify(p)).let { assertEquals(p, it) } }
    private fun EditSuiteController.splitAt(t: Double) { act(EditAction.Scrub(t, end = true)); act(EditAction.Split) }

    // ------------------------------------------------------------------ moving, reordering, trimming
    @Test fun longPressMoveSnapsToThePlayheadAndIsOneStep() = runTest {
        val c = controller()
        c.act(EditAction.Scrub(2.0, end = true)); c.act(EditAction.AddText)
        val id = c.ui.value.selectedId!!
        c.act(EditAction.Scrub(6.0, end = true))
        c.act(EditAction.MoveBy(id, 1.0, done = false))
        c.act(EditAction.MoveBy(id, 3.95, snapSec = 0.1, done = false)) // 2 + 3.95 = 5.95 → snaps to the playhead at 6
        c.act(EditAction.MoveBy(id, 3.95, snapSec = 0.1, done = true))
        val t = c.p().tracks.first { it.kind == TrackKind.TEXT }.items.single() as TextItem
        assertEquals(6.0, t.startSec, 1e-9)
        c.act(EditAction.Undo)
        assertEquals(2.0, (c.p().tracks.first { it.kind == TrackKind.TEXT }.items.single() as TextItem).startSec, 1e-9)
        valid(c.p())
    }

    @Test fun reorderMainClips() = runTest {
        val c = controller()
        c.splitAt(5.0); c.splitAt(10.0)
        val ids = c.p().mainClips.map { it.id }
        c.act(EditAction.Reorder(ids[0], 2, done = false)); c.act(EditAction.Reorder(ids[0], 2, done = true))
        assertEquals(listOf(ids[1], ids[2], ids[0]), c.p().mainClips.map { it.id })
        assertEquals(15.0, durationSec(c.p()), 1e-6)
        c.act(EditAction.Undo); assertEquals(ids, c.p().mainClips.map { it.id })
    }

    @Test fun trimAnyItemByItsEdges() = runTest {
        val c = controller()
        c.act(EditAction.AddAudio("up_m", 20.0, voiceOver = false))
        val m = c.p().tracks.first { it.kind == TrackKind.MUSIC }.items.single() as AudioClip
        // Audio left edge 2 s in: the sound starts 2 s later and 2 s further into the file.
        c.act(EditAction.TrimBy(m.id, left = true, deltaSec = 2.0))
        (c.p().tracks.first { it.kind == TrackKind.MUSIC }.items.single() as AudioClip).let { assertEquals(2.0, it.startSec, 1e-9); assertEquals(2.0, it.inSec, 1e-9) }
        // Text right edge: longer.
        c.act(EditAction.Scrub(1.0, end = true)); c.act(EditAction.AddText)
        val t = c.ui.value.selectedId!!
        c.act(EditAction.TrimBy(t, left = false, deltaSec = 1.5))
        assertEquals(4.5, (c.p().tracks.first { it.kind == TrackKind.TEXT }.items.single() as TextItem).durationSec, 1e-9)
        // Main clip right edge: shorter edit.
        c.act(EditAction.TrimBy(c.p().mainClips[0].id, left = false, deltaSec = -3.0))
        assertEquals(12.0, c.ui.value.duration, 1e-9)
        valid(c.p())
    }

    // ------------------------------------------------------------------ text
    @Test fun addTextStyleItAndAnimateIt() = runTest {
        val c = controller()
        c.act(EditAction.Scrub(3.0, end = true)); c.act(EditAction.AddText)
        val id = c.ui.value.selectedId!!
        val t0 = c.p().tracks.first { it.kind == TrackKind.TEXT }.items.single() as TextItem
        assertEquals(3.0, t0.startSec, 1e-9); assertEquals("Your text", t0.text)
        c.act(EditAction.EditText(id, "Day one"))
        c.act(EditAction.SetTextStyle(id, t0.style.copy(font = Font.SERIF, weight = 900, sizePct = .08, color = "#FFE600", stroke = studio.muse.core.edit.Stroke("#000000", .1),
            background = studio.muse.core.edit.TextBackground("#000000", .6, .25, .2), uppercase = true, letterSpacing = .05)))
        c.act(EditAction.SetAnim(id, studio.muse.core.edit.Anim(AnimKind.TYPEWRITER, 1.0), studio.muse.core.edit.Anim(AnimKind.ZOOM, .5)))
        val t = c.p().tracks.first { it.kind == TrackKind.TEXT }.items.single() as TextItem
        assertEquals("Day one", t.text); assertEquals(Font.SERIF, t.style.font); assertEquals("#FFE600", t.style.color); assertEquals(true, t.style.uppercase)
        assertEquals(AnimKind.TYPEWRITER, t.animIn?.kind); assertEquals(AnimKind.ZOOM, t.animOut?.kind)
        // The text moves with its own Transform panel (before 2026-11-08 it moved the clip under it).
        c.act(EditAction.SetTransform(Transform(x = .3, y = .2)))
        assertEquals(.3, (c.p().tracks.first { it.kind == TrackKind.TEXT }.items.single() as TextItem).transform?.x!!, 1e-9)
        assertNull(c.p().mainClips[0].transform)
        valid(c.p())
        val plan = planRender(c.p(), infos)
        assertEquals("DAY ONE".take(1), plan.textFrame(plan.overlays.filterIsInstance<studio.muse.core.edit.TextPiece>().single(), 3.1)!!.text.take(1))
    }

    // ------------------------------------------------------------------ keyframes
    @Test fun opacityAndVolumeKeyframesWithEasing() = runTest {
        val c = controller()
        c.act(EditAction.SetOpacity(.6)); assertEquals(.6, c.p().mainClips[0].opacity!!, 1e-9)
        c.act(EditAction.KeyEase(Ease.EASE_OUT))
        c.act(EditAction.Scrub(1.0, end = true)); c.act(EditAction.AddKeyframe(KfProp.OPACITY))
        c.act(EditAction.Scrub(3.0, end = true)); c.act(EditAction.SetOpacity(.2)) // keyed now: a key at 3 s
        val ok = c.p().mainClips[0].keyframes!![KfProp.OPACITY]!!
        assertEquals(listOf(1.0, 3.0), ok.map { it.t }); assertEquals(.2, ok[1].v, 1e-9); assertEquals(Ease.EASE_OUT, ok[0].ease)
        c.act(EditAction.KeyEase(Ease.HOLD)) // eases the key at the playhead
        assertEquals(Ease.HOLD, c.p().mainClips[0].keyframes!![KfProp.OPACITY]!![1].ease)
        c.act(EditAction.RemoveKeyframes(KfProp.OPACITY)); assertEquals(1, c.p().mainClips[0].keyframes!![KfProp.OPACITY]!!.size)
        // Volume: a key at the playhead, then the slider sets it.
        c.act(EditAction.AddKeyframe(KfProp.VOLUME)); c.act(EditAction.Volume(-6.0))
        val vk = c.p().mainClips[0].keyframes!![KfProp.VOLUME]!!
        assertEquals(3.0, vk.single().t, 1e-9); assertEquals(SuiteOps.dbToGain(-6.0), vk.single().v, .01)
        valid(c.p())
        // Keyed position: the slider writes a key, not the ignored static value.
        c.act(EditAction.AddKeyframe(KfProp.X)); c.act(EditAction.SetTransform(Transform(x = .25)))
        assertEquals(.25, c.p().mainClips[0].keyframes!![KfProp.X]!!.single().v, 1e-9)
        assertNull(c.p().mainClips[0].transform?.x)
    }

    @Test fun frameSteps() = runTest {
        val c = controller()
        c.act(EditAction.Scrub(2.0, end = true))
        c.act(EditAction.StepFrame(1)); assertEquals(2.0 + 1 / 30.0, c.ui.value.playheadSec, 1e-9)
        c.act(EditAction.StepFrame(-1)); c.act(EditAction.StepFrame(-1)); assertEquals(2.0 - 1 / 30.0, c.ui.value.playheadSec, 1e-9)
    }

    // ------------------------------------------------------------------ canvas
    @Test fun backgroundColourBlurFillAndClipFit() = runTest {
        val c = controller()
        c.act(EditAction.Background("#1B1916")); assertEquals("#1B1916", c.p().canvas.background)
        c.act(EditAction.ClipFit(Fit.CONTAIN)); assertEquals(Fit.CONTAIN, c.p().mainClips[0].fit)
        c.act(EditAction.Fill(CanvasFill.BLUR)); assertEquals(CanvasFill.BLUR, c.p().canvas.fill)
        valid(c.p())
        val plan = planRender(c.p(), infos)
        val fill = plan.layers.single { it.role == LayerRole.FILL }
        assertTrue(plan.layers.indexOf(fill) > plan.layers.indexOfFirst { it.role == LayerRole.MAIN }) // behind the main clips
        assertEquals(studio.muse.core.edit.blurFillRadius(1080, 1920), fill.clips.single().look?.fillBlur)
        assertFalse(fill.clips.single().withAudio)
        assertEquals(1.0, plan.placement(plan.layers.indexOf(fill), 5.0).alpha, 0.0)
        c.act(EditAction.Fill(CanvasFill.COLOR)); assertNull(c.p().canvas.fill)
    }

    // ------------------------------------------------------------------ mirror and freeze frames
    @Test fun mirrorReachesThePlacement() = runTest {
        val c = controller()
        c.act(EditAction.Mirror(x = true)); assertEquals(true, c.p().mainClips[0].transform?.flipX)
        c.act(EditAction.Mirror(y = true)); assertEquals(true, c.p().mainClips[0].transform?.flipY)
        valid(c.p())
        val plan = planRender(c.p(), infos)
        val pl = plan.placement(plan.layers.indexOfFirst { it.role == LayerRole.MAIN }, 1.0)
        assertTrue(pl.flipX); assertTrue(pl.flipY)
        c.act(EditAction.Mirror(x = false)); assertNull(c.p().mainClips[0].transform?.flipX)
    }

    @Test fun freezeFrameCutsInAHoldThatRendersAsOneSlowFrame() = runTest {
        val c = controller()
        c.act(EditAction.Scrub(6.0, end = true)); c.act(EditAction.Freeze(1.5))
        val clips = c.p().mainClips
        assertEquals(3, clips.size)
        val hold = clips[1]
        assertEquals(1.5, hold.holdSec!!, 1e-9); assertEquals(6.0, hold.inSec, 1e-9); assertEquals(hold.id, c.ui.value.selectedId)
        assertEquals(16.5, c.ui.value.duration, 1e-6)
        assertEquals(6.0, timeline(c.p())[1].startSec, 1e-6)
        valid(c.p())
        val plan = planRender(c.p(), infos)
        val pc = plan.layers.first { it.role == LayerRole.MAIN }.clips.first { it.itemId == hold.id }
        assertFalse(pc.withAudio)
        assertEquals(1.5, (pc.clipEndUs - pc.clipStartUs) / 1e6 / pc.speed, 1e-3) // one frame stretched to the hold
        assertEquals(1, pc.pieces.size)
        // Its length: the slider and its edges.
        c.act(EditAction.HoldLength(2.0)); assertEquals(2.0, c.p().mainClips[1].holdSec!!, 1e-9)
        c.act(EditAction.TrimBy(hold.id, left = false, deltaSec = .5)); assertEquals(2.5, c.p().mainClips[1].holdSec!!, 1e-9)
        // Splitting a hold makes two holds.
        c.act(EditAction.Scrub(7.0, end = true)); c.act(EditAction.Split)
        assertEquals(2, c.p().mainClips.count { it.holdSec != null })
        // Speed can't be changed on a hold (refused, project unchanged).
        val before = c.p()
        c.act(EditAction.Select(c.p().mainClips[1].id)); c.act(EditAction.Speed(2.0))
        assertEquals(before, c.p()); assertNotNull(c.ui.value.message)
    }
}

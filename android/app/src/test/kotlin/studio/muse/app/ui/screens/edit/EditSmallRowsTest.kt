package studio.muse.app.ui.screens.edit

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.EditorEstimate
import studio.muse.app.data.EditorJob
import studio.muse.app.data.EditorSourceDto
import studio.muse.app.data.FakeEditorResults
import studio.muse.core.edit.AudioClip
import studio.muse.core.edit.EditProject
import studio.muse.core.edit.ExportResolution
import studio.muse.core.edit.ExportSettings
import studio.muse.core.edit.Mask
import studio.muse.core.edit.MaskShape
import studio.muse.core.edit.MediaInfo
import studio.muse.core.edit.SourceSize
import studio.muse.core.edit.TrackKind
import studio.muse.core.edit.clipLength
import studio.muse.core.edit.exportProject
import studio.muse.core.edit.planRender
import studio.muse.core.edit.problemOf

/** The parity doc's small rows (plans/edit-parity.md, S), each driven through the editor and asserted on the project. */
@OptIn(ExperimentalCoroutinesApi::class)
class EditSmallRowsTest {
    private class Stub : EditBackend {
        override suspend fun estimate(kind: String, source: EditorSourceDto, options: JsonObject?) = EditorEstimate(kind, 0.02) to null
        override suspend fun run(kind: String, source: EditorSourceDto, options: JsonObject?, onProgress: (EditorJob) -> Unit): Pair<JsonObject?, String?> =
            FakeEditorResults.result(kind, source.durationSec ?: 15.0, "j", options) to null
    }

    private fun TestScope.controller() = EditSuiteController(this, Stub()).also {
        it.load(EditSuiteViewModel.newProject("take_1", 15.0, SourceSize(1080, 1920, 30.0, true)), "T", "take_1", null, false)
    }
    private fun EditSuiteController.p() = project!!
    private fun valid(p: EditProject) = assertNull(problemOf(p)?.message, problemOf(p))
    private val infos = mapOf("src" to MediaInfo(15.0, 1080, 1920, 30.0, true))

    @Test fun lookEffectSliders() = runTest {
        val c = controller()
        for ((f, v) in listOf("vignette" to .4, "sharpen" to .3, "fade" to .2, "halation" to .5, "leak" to .3, "chromatic" to .1, "grain" to .25)) c.act(EditAction.AdjustField(f, v))
        val l = c.p().mainClips[0].look!!
        assertEquals(.4, l.vignette!!.amount, 1e-9); assertEquals(.3, l.sharpen!!, 1e-9); assertEquals(.2, l.lift!!, 1e-9)
        assertEquals(.5, l.halation!!.amount, 1e-9); assertEquals(.3, l.leak!!.amount, 1e-9); assertEquals(.1, l.chromatic!!, 1e-9); assertEquals(.25, l.grain!!.amount, 1e-9)
        c.act(EditAction.AdjustField("vignette", -.3)); assertEquals(-.3, c.p().mainClips[0].look!!.vignette!!.amount, 1e-9) // negative lightens the edges
        valid(c.p())
        assertTrue(planRender(c.p(), infos).layers.flatMap { it.clips }.first().look?.look?.halation != null)
        for (f in listOf("vignette", "sharpen", "fade", "halation", "leak", "chromatic", "grain")) c.act(EditAction.AdjustField(f, 0.0))
        assertNull(c.p().mainClips[0].look)
    }

    @Test fun slipLengthReplaceAndMaskPosition() = runTest {
        val c = controller()
        c.act(EditAction.TrimBy(c.p().mainClips[0].id, left = false, deltaSec = -10.0)) // 0–5 s of 15
        c.act(EditAction.Slip(6.0)); c.p().mainClips[0].let { assertEquals(6.0, it.inSec, 1e-9); assertEquals(11.0, it.outSec, 1e-9) }
        c.act(EditAction.Slip(99.0)); assertEquals(10.0, c.p().mainClips[0].inSec, 1e-9) // up to the file's end
        // Length → speed: 5 s of video in 2.5 s is 2×.
        c.act(EditAction.Speed(2.0)); assertEquals(2.5, clipLength(c.p().mainClips[0]), 1e-9)
        c.act(EditAction.ReplaceClip(TakeChoice("t2", "B", "Edit", null, 3.0, false, true)))
        c.p().mainClips[0].let { assertEquals("t2", c.p().asset(it.asset)!!.take); assertEquals(0.0, it.inSec, 0.0); assertEquals(3.0, it.outSec, 1e-9); assertEquals(2.0, it.speed, 0.0) }
        c.act(EditAction.SetMask(Mask(MaskShape.CIRCLE, x = .3, y = .7, rotation = 45.0)))
        c.p().mainClips[0].mask!!.let { assertEquals(.3, it.x!!, 0.0); assertEquals(.7, it.y!!, 0.0); assertEquals(45.0, it.rotation!!, 0.0) }
        valid(c.p())
    }

    @Test fun beatMarksSoundFromATakeLoopAndCaptionWords() = runTest {
        val c = controller()
        c.act(EditAction.AddAudio("up_m", 4.0, voiceOver = false))
        c.act(EditAction.Scrub(1.5, end = true)); c.act(EditAction.MarkBeat)
        c.act(EditAction.Scrub(3.0, end = true)); c.act(EditAction.MarkBeat)
        val m = c.p().tracks.first { it.kind == TrackKind.MUSIC }.items.single() as AudioClip
        assertEquals(listOf(1.5, 3.0), m.beats)
        assertEquals(listOf(1.5, 3.0), SuiteOps.beatTimes(c.p(), false))
        c.act(EditAction.Select(m.id)); c.act(EditAction.LoopAudio)
        val music = c.p().tracks.first { it.kind == TrackKind.MUSIC }.items.map { it as AudioClip }
        assertEquals(4, music.size) // 0–4, 4–8, 8–12, 12–15
        assertEquals(15.0, music.last().startSec + clipLength(music.last()), 1e-6)
        c.act(EditAction.ClearBeats); assertNull((c.p().tracks.first { it.kind == TrackKind.MUSIC }.items.first() as AudioClip).beats)
        c.act(EditAction.Scrub(2.0, end = true)); c.act(EditAction.AddTakeSound(TakeChoice("t3", "C", "Edit", null, 5.0, false, true)))
        val s = c.p().tracks.first { it.kind == TrackKind.SFX }.items.single() as AudioClip
        assertEquals(2.0, s.startSec, 1e-9); assertEquals("t3", c.p().asset(s.asset)!!.take)
        c.act(EditAction.AutoCaptions); advanceUntilIdle()
        c.act(EditAction.CaptionWordText(0, "Hey"))
        assertEquals("Hey", c.ui.value.captionTrack!!.caption!!.words[0].text)
        valid(c.p())
    }

    @Test fun phoneTrackTogglesAnd2kExport() = runTest {
        val c = controller()
        c.act(EditAction.ToggleTrackMuted("main")); assertEquals(true, c.p().main.muted)
        val out = exportProject(c.p(), ExportSettings(resolution = ExportResolution.QHD))
        assertEquals(1440, minOf(out.canvas.width, out.canvas.height))
    }
}

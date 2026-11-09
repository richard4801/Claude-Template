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
import studio.muse.core.edit.locate
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

    @Test fun videoFromALinkGoesOnTheEnd() = runTest {
        val c = controller()
        c.act(EditAction.AppendUpload("up_9", 6.5, 720, 1280, hasAudio = false))
        val p = c.p()
        assertEquals(2, p.mainClips.size)
        val a = p.assets.first { it.id == p.mainClips[1].asset }
        assertEquals("up_9", a.upload); assertNull(a.take); assertEquals(false, a.hasAudio)
        assertEquals(6.5, clipLength(p.mainClips[1]), 1e-9)
        assertEquals(p.mainClips[1].id, c.ui.value.selectedId)
        valid(p)
        // The same import again reuses its asset.
        c.act(EditAction.AppendUpload("up_9", 6.5)); assertEquals(1, c.p().assets.count { it.upload == "up_9" })
        c.act(EditAction.AppendUpload("up_x", 0.01)); assertEquals(3, c.p().mainClips.size) // too short: refused
    }

    @Test fun clipsMoveBetweenTheMainTrackAndAnOverlay() = runTest {
        val c = controller()
        c.act(EditAction.Scrub(6.0, end = true)); c.act(EditAction.Split)
        val second = c.p().mainClips[1].id
        c.act(EditAction.Select(second)); c.act(EditAction.SwapTrack)
        var p = c.p()
        assertEquals(1, p.mainClips.size)
        val (t, _) = p.locate(second)!!
        assertEquals(TrackKind.VIDEO, t.kind)
        assertEquals(6.0, (t.items.single() as studio.muse.core.edit.VideoClip).startSec!!, 1e-6) // where it played
        valid(p)
        // The last main clip can't leave.
        c.act(EditAction.Select(p.mainClips[0].id)); c.act(EditAction.SwapTrack); assertEquals(1, c.p().mainClips.size)
        // Back: placed at the nearest boundary (the end), overlay placing dropped, its empty overlay track gone.
        c.act(EditAction.Select(second)); c.act(EditAction.SetOpacity(.5)); c.act(EditAction.SwapTrack)
        p = c.p()
        assertEquals(listOf(second), p.mainClips.drop(1).map { it.id })
        assertNull(p.mainClips[1].opacity); assertNull(p.mainClips[1].startSec)
        assertTrue(p.tracks.none { it.kind == TrackKind.VIDEO })
        assertEquals(15.0, studio.muse.core.edit.durationSec(p), 1e-6)
        valid(p)
    }

    @Test fun fourThreeAndCinemaRatios() = runTest {
        val c = controller()
        c.act(EditAction.Ratio(studio.muse.core.edit.ExportShape.FOUR_THREE))
        assertEquals(1440 to 1080, c.p().canvas.width to c.p().canvas.height)
        c.act(EditAction.Ratio(studio.muse.core.edit.ExportShape.CINEMA))
        assertEquals(2538 to 1080, c.p().canvas.width to c.p().canvas.height)
        valid(c.p())
        // 4K cinema: the long side capped at the contract's 4096 px, the shape kept.
        val (w, h) = ExportSettings(shape = studio.muse.core.edit.ExportShape.CINEMA, resolution = ExportResolution.UHD).size
        assertEquals(4096, w); assertEquals(2.35, w.toDouble() / h, .01)
    }

    @Test fun cutClipsToTheBeat() = runTest {
        val c = controller()
        c.act(EditAction.Scrub(4.1, end = true)); c.act(EditAction.Split)
        c.act(EditAction.Scrub(9.2, end = true)); c.act(EditAction.Split)
        c.act(EditAction.CutToBeats); assertEquals("Detect beats in Audio first", c.ui.value.message)
        c.act(EditAction.AddAudio("up_m", 15.0, voiceOver = false))
        for (b in listOf(2.0, 4.0, 6.0, 8.0, 10.0, 12.0, 14.0)) { c.act(EditAction.Scrub(b, end = true)); c.act(EditAction.MarkBeat) }
        c.act(EditAction.CutToBeats)
        val ends = studio.muse.core.edit.timeline(c.p()).map { Math.round(it.endSec * 1000) / 1000.0 }
        assertEquals(listOf(4.0, 10.0), ends.take(2)) // 4.1 → 4, then 4 + 5.1 = 9.1 → 10 (the source reaches)
        valid(c.p())
    }

    @Test fun evenOutVolume() = runTest {
        val c = controller()
        c.act(EditAction.Scrub(5.0, end = true)); c.act(EditAction.Split)
        c.act(EditAction.Scrub(10.0, end = true)); c.act(EditAction.Split)
        // The source: quiet for 0–5 s, loud 5–10 s, medium 10–15 s (50 slices a second).
        val w = Peaks(50f, FloatArray(750) { i -> when { i < 250 -> .1f; i < 500 -> .8f; else -> .3f } })
        c.act(EditAction.EvenVolume(mapOf("src" to w)))
        val v = c.p().mainClips.map { it.volume ?: 1.0 }
        assertEquals(listOf(2.0, .38, 1.0), v) // to the median (0.3): 3× capped at 2, 0.375 → 0.38, unchanged
        valid(c.p())
        c.act(EditAction.EvenVolume(emptyMap())); assertEquals("Nothing to even out · it needs two or more clips with sound", c.ui.value.message)
    }

    @Test fun splitScreenLayouts() = runTest {
        val c = controller()
        c.act(EditAction.Scrub(2.0, end = true))
        c.act(EditAction.SplitScreen(SuiteOps.SplitLayout.TOP_BOTTOM)); assertTrue(c.ui.value.message!!.startsWith("Add an overlay"))
        c.act(EditAction.AddPip(TakeChoice("t2", "B", "Edit", null, 5.0, false, true)))
        c.act(EditAction.SplitScreen(SuiteOps.SplitLayout.TOP_BOTTOM))
        val p = c.p()
        val main = p.mainClips[0]; val pip = p.tracks.first { it.kind == TrackKind.VIDEO }.items.single() as studio.muse.core.edit.VideoClip
        // 9:16 into a 9:8 half: a quarter off the top and bottom; contain-fitted 1080 wide, so scale 1, centred in its half.
        assertEquals(.25, main.crop!!.top!!, 1e-9); assertNull(main.crop!!.left)
        assertEquals(studio.muse.core.edit.Transform(.5, .25, 1.0), main.transform)
        assertEquals(.75, pip.transform!!.y!!, 1e-9); assertEquals(studio.muse.core.edit.Fit.CONTAIN, pip.fit)
        valid(p)
        c.act(EditAction.SplitScreen(SuiteOps.SplitLayout.SIDE_BY_SIDE))
        val m2 = c.p().mainClips[0]
        assertEquals(.25, m2.crop!!.left!!, 1e-9) // 9:16 into a 540 × 1920 cell (9:32): a quarter off each side
        assertEquals(studio.muse.core.edit.Transform(.25, .5, 1.0), m2.transform)
        valid(c.p())
    }

    @Test fun tintSlider() = runTest {
        val c = controller()
        c.act(EditAction.AdjustField("tint", .5))
        assertEquals(.5, c.p().mainClips[0].adjust!!.tint!!, 1e-9)
        val m = studio.muse.core.edit.colorMatrix(c.p().mainClips[0].adjust, null)
        assertEquals(1.025, m[0], 1e-6); assertEquals(.95, m[5], 1e-6) // magenta: less green
        valid(c.p())
        c.act(EditAction.AdjustField("tint", 0.0)); assertNull(c.p().mainClips[0].adjust)
    }
}

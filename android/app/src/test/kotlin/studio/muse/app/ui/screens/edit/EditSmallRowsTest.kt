package studio.muse.app.ui.screens.edit

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
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

    @Test fun keyframesListMoveAndJump() = runTest {
        val c = controller()
        val id = c.p().mainClips[0].id
        c.act(EditAction.Select(id))
        for (t in listOf(1.0, 4.0, 8.0)) { c.act(EditAction.Scrub(t, end = true)); c.act(EditAction.AddKeyframe(studio.muse.core.edit.KfProp.SCALE)) }
        assertEquals(listOf(1.0, 4.0, 8.0), SuiteOps.keyTimes(c.p().mainClips[0]))
        // Drag the 4 s key to 5.5 s (a live drag, then the drop: one undo step).
        c.act(EditAction.MoveKey(id, 4.0, 0.7, done = false)); c.act(EditAction.MoveKey(id, 4.0, 1.5, done = true))
        assertEquals(listOf(1.0, 5.5, 8.0), SuiteOps.keyTimes(c.p().mainClips[0]))
        // It can't pass a neighbour.
        c.act(EditAction.MoveKey(id, 5.5, 3.0)); assertEquals(listOf(1.0, 5.5, 8.0), SuiteOps.keyTimes(c.p().mainClips[0]))
        c.act(EditAction.Undo); assertEquals(listOf(1.0, 4.0, 8.0), SuiteOps.keyTimes(c.p().mainClips[0]))
        // Previous / next.
        c.act(EditAction.Scrub(5.0, end = true))
        c.act(EditAction.KeyNav(next = true)); assertEquals(8.0, c.ui.value.playheadSec, 1e-6)
        c.act(EditAction.KeyNav(next = false)); assertEquals(4.0, c.ui.value.playheadSec, 1e-6)
        c.act(EditAction.KeyNav(next = false)); c.act(EditAction.KeyNav(next = false)); assertEquals("No keyframe before the playhead", c.ui.value.message)
        valid(c.p())
    }

    @Test fun curvesAndAutoAdjust() = runTest {
        val c = controller()
        fun cp(x: Double, y: Double) = studio.muse.core.edit.CurvePoint(x, y)
        c.act(EditAction.SetCurve(studio.muse.core.edit.CurveChannel.RGB, listOf(cp(0.0, 0.05), cp(0.5, 0.6), cp(1.0, 0.95)), done = false))
        c.act(EditAction.SetCurve(studio.muse.core.edit.CurveChannel.RGB, listOf(cp(0.0, 0.05), cp(0.5, 0.62), cp(1.0, 0.95)), done = true))
        assertEquals(.62, c.p().mainClips[0].look!!.curves!![studio.muse.core.edit.CurveChannel.RGB]!![1].y, 1e-9)
        valid(c.p())
        // Points out of order are sorted; two at the same x are refused by validation.
        c.act(EditAction.SetCurve(studio.muse.core.edit.CurveChannel.B, listOf(cp(1.0, 1.0), cp(0.0, 0.1))))
        assertEquals(0.0, c.p().mainClips[0].look!!.curves!![studio.muse.core.edit.CurveChannel.B]!![0].x, 0.0)
        c.act(EditAction.SetCurve(studio.muse.core.edit.CurveChannel.G, listOf(cp(0.0, 0.0), cp(0.5, 0.4), cp(0.5, 0.6), cp(1.0, 1.0))))
        assertNull(c.p().mainClips[0].look!!.curves!![studio.muse.core.edit.CurveChannel.G])
        // The straight line (or null) removes a channel; no curves and nothing else: no look.
        c.act(EditAction.SetCurve(studio.muse.core.edit.CurveChannel.B, listOf(cp(0.0, 0.0), cp(1.0, 1.0))))
        c.act(EditAction.SetCurve(studio.muse.core.edit.CurveChannel.RGB, null))
        assertNull(c.p().mainClips[0].look)
        // Auto adjust from a dark frame: brighter, highlights kept.
        c.act(EditAction.AdjustField("highlights", .3))
        c.act(EditAction.AutoAdjust(DoubleArray(300) { 0.1 + (it % 30) / 300.0 }))
        val a = c.p().mainClips[0].adjust!!
        assertTrue(a.exposure!! > 0); assertEquals(.3, a.highlights!!, 1e-9)
        valid(c.p())
    }

    @Test fun videoClipAnimations() = runTest {
        val c = controller()
        val id = c.p().mainClips[0].id
        c.act(EditAction.SetAnim(id, studio.muse.core.edit.Anim(studio.muse.core.edit.AnimKind.FADE, 0.5), studio.muse.core.edit.Anim(studio.muse.core.edit.AnimKind.ZOOM, 0.4)))
        val clip = c.p().mainClips[0]
        assertEquals(studio.muse.core.edit.AnimKind.FADE, clip.animIn!!.kind)
        valid(c.p())
        // The plan fades it in from nothing and zooms it out.
        val plan = planRender(c.p(), infos)
        val main = plan.layers.first { it.role == studio.muse.core.edit.LayerRole.MAIN }.index
        assertEquals(0.0, plan.placement(main, 0.0).alpha, 1e-9)
        assertEquals(1.0, plan.placement(main, 5.0).alpha, 1e-9)
        assertTrue(plan.placement(main, 14.9).scale > 1.0)
        // Round trip through the contract's JSON.
        assertEquals(c.p(), studio.muse.core.edit.EditJson.parse(studio.muse.core.edit.EditJson.encode(c.p())))
        // A typewriter isn't a video animation.
        c.act(EditAction.SetAnim(id, studio.muse.core.edit.Anim(studio.muse.core.edit.AnimKind.TYPEWRITER, 1.0), null))
        assertEquals(studio.muse.core.edit.AnimKind.FADE, c.p().mainClips[0].animIn!!.kind)
    }

    @Test fun colourKeyframes() = runTest {
        val c = controller()
        val id = c.p().mainClips[0].id
        c.act(EditAction.Select(id))
        c.act(EditAction.Scrub(1.0, end = true)); c.act(EditAction.AddKeyframe(studio.muse.core.edit.KfProp.EXPOSURE))
        c.act(EditAction.Scrub(5.0, end = true)); c.act(EditAction.AddKeyframe(studio.muse.core.edit.KfProp.EXPOSURE))
        // A keyed slider sets the key at the playhead.
        c.act(EditAction.AdjustField("exposure", .6))
        val keys = c.p().mainClips[0].keyframes!![studio.muse.core.edit.KfProp.EXPOSURE]!!
        assertEquals(listOf(1.0 to 0.0, 5.0 to 0.6), keys.map { it.t to it.v })
        assertNull(c.p().mainClips[0].adjust) // the static value stays as it was
        valid(c.p())
        // The plan: a per-frame matrix that brightens over time.
        val plan = planRender(c.p(), infos)
        val look = plan.layers.flatMap { it.clips }.first { it.itemId == id }.look!!
        val keysOf = look.colorKeys!!
        assertEquals(1.0, keysOf.matrixAt(1.0)[0], 1e-9)
        assertEquals(Math.pow(2.0, .6), keysOf.matrixAt(5.0)[0], 1e-6)
        // Unkeyed fields still take the static value.
        c.act(EditAction.AdjustField("contrast", .2)); assertEquals(.2, c.p().mainClips[0].adjust!!.contrast!!, 1e-9)
    }

    @Test fun styleKitsApplyToTheWholeEdit() = runTest {
        val c = controller()
        c.act(EditAction.Scrub(6.0, end = true)); c.act(EditAction.Split)
        val kit = studio.muse.core.edit.StyleKit(adjust = studio.muse.core.edit.Adjust(contrast = .2), transition = studio.muse.core.edit.Transition(studio.muse.core.edit.TransitionKind.FADE, .5),
            background = "#202020", fill = studio.muse.core.edit.CanvasFill.BLUR)
        c.act(EditAction.ApplyKit(KitChoice("k1", "Warm", kit)))
        val p = c.p()
        assertTrue(p.mainClips.all { it.adjust?.contrast == .2 })
        assertEquals(.5, p.mainClips[1].transitionIn!!.durationSec, 1e-9)
        assertEquals("#202020", p.canvas.background)
        assertEquals("Applied “Warm”", c.ui.value.message)
        valid(p)
        // The same again changes nothing; undo puts the edit back in one step.
        c.act(EditAction.ApplyKit(KitChoice("k1", "Warm", kit))); assertEquals("This edit already has that style", c.ui.value.message)
        c.act(EditAction.Undo); assertNull(c.p().mainClips[0].adjust)
        assertEquals("Colour, transition, background", KitChoice("k1", "Warm", kit).parts)
    }

    @Test fun captionLanguageAndTrimSnapping() = runTest {
        val sent = ArrayList<JsonObject?>()
        val c = EditSuiteController(this, object : EditBackend {
            override suspend fun estimate(kind: String, source: EditorSourceDto, options: JsonObject?) = EditorEstimate(kind, 0.02) to null
            override suspend fun run(kind: String, source: EditorSourceDto, options: JsonObject?, onProgress: (EditorJob) -> Unit): Pair<JsonObject?, String?> {
                if (kind == "captions") sent += options
                return FakeEditorResults.result(kind, source.durationSec ?: 15.0, "j", options) to null
            }
        }).also { it.load(EditSuiteViewModel.newProject("take_1", 15.0, SourceSize(1080, 1920, 30.0, true)), "T", "take_1", null, false) }
        c.act(EditAction.CaptionLanguage("es")); c.act(EditAction.AutoCaptions); advanceUntilIdle()
        assertEquals("\"es\"", sent.single()!!["language"].toString())
        c.act(EditAction.CaptionLanguage(null)); c.act(EditAction.AutoCaptions); advanceUntilIdle()
        assertNull(sent.last())
        // Trimming snaps the dragged edge to the playhead within the snap distance.
        c.act(EditAction.Scrub(6.0, end = true)); c.act(EditAction.Split)
        c.act(EditAction.Scrub(3.0, end = true))
        val first = c.p().mainClips[0].id
        c.act(EditAction.TrimBy(first, left = false, deltaSec = -2.9, snapSec = 0.2))
        assertEquals(3.0, studio.muse.core.edit.timeline(c.p())[0].endSec, 1e-6)
        valid(c.p())
    }

    @Test fun maskAndLookKeyframes() = runTest {
        val c = controller()
        val id = c.p().mainClips[0].id
        c.act(EditAction.Select(id))
        c.act(EditAction.AddKeyframe(studio.muse.core.edit.KfProp.MASK_X)); assertEquals("Add a mask first", c.ui.value.message)
        c.act(EditAction.SetMask(Mask(MaskShape.CIRCLE)))
        c.act(EditAction.Scrub(1.0, end = true)); c.act(EditAction.AddKeyframe(studio.muse.core.edit.KfProp.MASK_X))
        c.act(EditAction.Scrub(4.0, end = true)); c.act(EditAction.AddKeyframe(studio.muse.core.edit.KfProp.MASK_X))
        // At 4 s the keyed x moves its key; the unkeyed feather changes the mask itself.
        c.act(EditAction.SetMask(Mask(MaskShape.CIRCLE, x = .8, feather = .3)))
        val clip = c.p().mainClips[0]
        assertEquals(listOf(1.0 to .5, 4.0 to .8), clip.keyframes!![studio.muse.core.edit.KfProp.MASK_X]!!.map { it.t to it.v })
        assertEquals(.3, clip.mask!!.feather!!, 1e-9); assertNull(clip.mask!!.x)
        // Look keys: vignette from nothing; the slider at the playhead sets the key.
        c.act(EditAction.AddKeyframe(studio.muse.core.edit.KfProp.VIGNETTE))
        c.act(EditAction.AdjustField("vignette", -.5))
        assertEquals(-.5, c.p().mainClips[0].keyframes!![studio.muse.core.edit.KfProp.VIGNETTE]!!.single().v, 1e-9)
        valid(c.p())
        val look = planRender(c.p(), infos).layers.flatMap { it.clips }.first { it.itemId == id }.look!!
        val mk = look.motionKeys!!
        assertTrue(mk.masked && mk.looked)
        assertEquals(.65, mk.maskAt(2.5)!!.x!!, .1)
        assertEquals(-.5, mk.lookAt(4.0).vignette!!.amount, 1e-9)
    }

    @Test fun chromaEyedropper() = runTest {
        val c = controller()
        val id = c.p().mainClips[0].id
        c.act(EditAction.Select(id)); c.act(EditAction.Scrub(2.0, end = true))
        c.act(EditAction.PickColor(true))
        assertEquals(id, c.ui.value.pick!!.clipId); assertTrue(!c.ui.value.playing)
        // A 4 × 4 frame: the left half green screen, the right half grey.
        c.act(EditAction.PickFrame(4, 4, IntArray(16) { i -> if (i % 4 < 2) 0xFF2BD15F.toInt() else 0xFF808080.toInt() }))
        c.act(EditAction.PickAt(.75, .5, done = false)); assertEquals("#808080", c.ui.value.pick!!.hex)
        c.act(EditAction.PickAt(.2, .5, done = true))
        assertNull(c.ui.value.pick)
        assertEquals("#2BD15F", c.p().mainClips[0].chroma!!.color)
        valid(c.p())
        // Cancel leaves the key as it was.
        c.act(EditAction.PickColor(true)); c.act(EditAction.PickColor(false)); assertNull(c.ui.value.pick)
    }

    @Test fun addAPhoto() = runTest {
        val c = controller()
        c.act(EditAction.Scrub(4.0, end = true)); c.act(EditAction.AddImage("up_photo", 1600, 1200))
        val p = c.p()
        val t = p.tracks.first { it.kind == TrackKind.IMAGE }
        val im = t.items.single() as studio.muse.core.edit.ImageItem
        assertEquals(4.0, im.startSec, 1e-9); assertEquals(3.0, im.durationSec, 1e-9)
        assertEquals(studio.muse.core.edit.Fit.CONTAIN, im.fit); assertEquals(.4, im.transform!!.scale!!, 1e-9)
        assertEquals("up_photo", p.asset(im.asset)!!.upload); assertEquals(1600, p.asset(im.asset)!!.width)
        assertEquals(im.id, c.ui.value.selectedId); assertEquals(Panel.TRANSFORM, c.ui.value.panel)
        valid(p)
        // Near the end it's shorter; a second photo at the same time goes on its own track.
        c.act(EditAction.Scrub(13.5, end = true)); c.act(EditAction.AddImage("up_2", 800, 800))
        assertEquals(1.5, (c.p().tracks.last { it.kind == TrackKind.IMAGE }.items.last() as studio.muse.core.edit.ImageItem).durationSec, 1e-9)
        c.act(EditAction.Scrub(4.5, end = true)); c.act(EditAction.AddImage("up_3", 800, 800))
        assertEquals(2, c.p().tracks.count { it.kind == TrackKind.IMAGE })
        valid(c.p())
    }

    @Test fun reframeFollowsTheFace() = runTest {
        val c = controller()
        val clip = c.p().mainClips[0]
        val keys = listOf(studio.muse.core.edit.Keyframe(0.0, 1.2, studio.muse.core.edit.Ease.EASE_IN_OUT), studio.muse.core.edit.Keyframe(3.0, 0.4, studio.muse.core.edit.Ease.EASE_IN_OUT))
        c.act(EditAction.ApplyReframe(clip.id, keys))
        var now = c.p().mainClips[0]
        assertEquals(keys, now.keyframes!![studio.muse.core.edit.KfProp.X]); assertEquals(1.2, now.transform!!.x!!, 1e-9); assertNull(now.fit)
        valid(c.p())
        // A still result: one position, no x keys left.
        c.act(EditAction.ApplyReframe(clip.id, listOf(studio.muse.core.edit.Keyframe(0.0, 0.8, studio.muse.core.edit.Ease.EASE_IN_OUT))))
        now = c.p().mainClips[0]
        assertNull(now.keyframes?.get(studio.muse.core.edit.KfProp.X)); assertEquals(0.8, now.transform!!.x!!, 1e-9)
    }

    @Test fun contentStickersSoundsAndCaptionTemplates() = runTest {
        val c = controller()
        c.act(EditAction.Scrub(2.0, end = true)); c.act(EditAction.AddSticker("content:twemoji/1f600", 160, 160))
        val st = c.p().assets.single { it.library == "content:twemoji/1f600" }
        val item = c.p().tracks.first { it.kind == TrackKind.IMAGE }.items.single() as studio.muse.core.edit.ImageItem
        assertEquals(st.id, item.asset); assertEquals(2.0, item.startSec, 1e-9); assertEquals(.3, item.transform!!.scale!!, 1e-9)
        // The same sticker again reuses the asset.
        c.act(EditAction.Scrub(6.0, end = true)); c.act(EditAction.AddSticker("content:twemoji/1f600", 160, 160))
        assertEquals(1, c.p().assets.count { it.library == "content:twemoji/1f600" })
        c.act(EditAction.Scrub(1.0, end = true)); c.act(EditAction.AddSoundEffect("content:uisfx/glass-notification", 0.509, "Select"))
        val fx = c.p().tracks.single { it.kind == TrackKind.SFX }.items.single() as AudioClip
        assertEquals(1.0, fx.startSec, 1e-9); assertEquals(0.509, fx.outSec, 1e-9)
        assertEquals("content:uisfx/glass-notification", c.p().asset(fx.asset)!!.library)
        valid(c.p())
        // A caption template needs captions; with them, it replaces the style (here in a content font).
        c.act(EditAction.CaptionTemplate(studio.muse.core.edit.Presets.CAPTION_STYLES.values.first().let { it.copy(text = it.text.copy(font = studio.muse.core.edit.Font.MONTSERRAT, weight = 900)) }, "Bold"))
        assertTrue(c.p().tracks.none { it.kind == TrackKind.CAPTION && it.caption?.style?.text?.font == studio.muse.core.edit.Font.MONTSERRAT })
    }

    @Test fun reverse() = runTest {
        val c = controller()
        val clip = c.p().mainClips[0]
        val src = c.p().asset(clip.asset)!!
        c.act(EditAction.Select(clip.id))
        c.act(EditAction.Reverse(true)); advanceUntilIdle()
        val rev = c.p().assets.single { it.reverseOf == src.id }
        var now = c.p().mainClips[0]
        assertEquals(rev.id, now.asset)
        assertEquals(src.durationSec!! - clip.outSec, now.inSec, 1e-6); assertEquals(src.durationSec!! - clip.inSec, now.outSec, 1e-6)
        valid(c.p())
        // Back, then forwards again without a new job (the reversed copy is reused).
        c.act(EditAction.Reverse(false))
        now = c.p().mainClips[0]
        assertEquals(clip.asset, now.asset); assertEquals(clip.inSec, now.inSec, 1e-6); assertEquals(clip.outSec, now.outSec, 1e-6)
        c.act(EditAction.Reverse(true))
        assertEquals(rev.id, c.p().mainClips[0].asset)
        assertEquals(1, c.p().assets.count { it.reverseOf != null })
    }

    @Test fun stabilizeThenReverse() = runTest {
        val c = controller()
        val clip = c.p().mainClips[0]
        val src = c.p().asset(clip.asset)!!
        c.act(EditAction.Select(clip.id))
        c.act(EditAction.Stabilize(true)); advanceUntilIdle()
        val st = c.p().assets.single { it.derivedFrom?.asset == src.id }
        assertEquals(studio.muse.core.edit.DerivedOp.STABILIZE, st.derivedFrom!!.op)
        var now = c.p().mainClips[0]
        assertEquals(st.id, now.asset); assertEquals(clip.inSec, now.inSec, 1e-6); assertEquals(clip.outSec, now.outSec, 1e-6)
        valid(c.p())
        // Steadied, then reversed: both steps stack; stabilise can't switch off under the reverse.
        c.act(EditAction.Reverse(true)); advanceUntilIdle()
        assertEquals("Steadied, reversed", studio.muse.core.edit.derivedLabel(c.p(), c.p().mainClips[0].asset))
        assertEquals(src.id, studio.muse.core.edit.sourceOf(c.p(), c.p().mainClips[0].asset))
        valid(c.p())
        c.act(EditAction.Stabilize(false))
        assertEquals("Steadied, reversed", studio.muse.core.edit.derivedLabel(c.p(), c.p().mainClips[0].asset))
        c.act(EditAction.Reverse(false)); c.act(EditAction.Stabilize(false))
        now = c.p().mainClips[0]
        assertEquals(clip.asset, now.asset); assertEquals(clip.inSec, now.inSec, 1e-6)
        // On again without a new job: the steadied copy is reused.
        c.act(EditAction.Stabilize(true))
        assertEquals(st.id, c.p().mainClips[0].asset)
        assertEquals(1, c.p().assets.count { it.derivedFrom != null })
    }

    @Test fun smoothSlowMotion() = runTest {
        val c = controller()
        val clip = c.p().mainClips[0]
        val n = c.p().mainClips.size
        c.act(EditAction.Select(clip.id))
        c.act(EditAction.SlowmoPrice(4, 1.0)); advanceUntilIdle()
        assertTrue(c.ui.value.ai["slowmo"]?.price != null)
        c.act(EditAction.Slowmo(4, 1.0)); advanceUntilIdle()
        val slow = c.p().assets.single { it.derivedFrom?.op == studio.muse.core.edit.DerivedOp.SLOWMO }
        val d = slow.derivedFrom!!
        assertEquals(1.0, d.endSec!! - d.startSec!!, 1e-6); assertEquals(4, d.factor)
        val mid = c.p().mainClips.single { it.asset == slow.id }
        assertEquals(4.0, mid.outSec - mid.inSec, 1e-6); assertEquals(true, mid.muted); assertEquals(1.0, mid.speed, 0.0)
        assertTrue(c.p().mainClips.size in n + 1..n + 2)
        assertEquals("Smooth 4×", studio.muse.core.edit.derivedLabel(c.p(), slow.id))
        valid(c.p())
    }

    @Test fun translatedCaptions() = runTest {
        val c = controller()
        c.act(EditAction.AutoCaptions); advanceUntilIdle()
        fun ct() = c.p().tracks.first { it.kind == TrackKind.CAPTION }.caption!!
        val en = ct().words
        assertEquals("en", ct().language)
        c.act(EditAction.TranslatePrice("es", false)); advanceUntilIdle()
        assertTrue(c.ui.value.ai["translate"]?.price != null)
        c.act(EditAction.Translate("es", false)); advanceUntilIdle()
        assertEquals("es", ct().language); assertEquals(en, ct().original!!.words); assertEquals("en", ct().original!!.language)
        assertTrue(ct().words.first().text.endsWith("·es"))
        valid(c.p())
        // Show the original, then translate into French from there: English stays the original.
        c.act(EditAction.CaptionOriginal("en"))
        assertEquals(en, ct().words); assertEquals("es", ct().original!!.language)
        c.act(EditAction.Translate("fr", true)); advanceUntilIdle()
        assertEquals("fr", ct().language); assertEquals(en, ct().original!!.words)
        c.act(EditAction.CaptionOriginal("en")); assertEquals(en, ct().words)
        valid(c.p())
    }

    @Test fun lyricCaptions() = runTest {
        val c = controller()
        c.act(EditAction.LyricCaptions); assertEquals("Add a song from your files to the music track first", c.ui.value.message)
        // A song from the member's files on the music track.
        val p0 = c.p()
        val song = studio.muse.core.edit.Asset("song_up", studio.muse.core.edit.AssetKind.AUDIO, upload = "up_song", durationSec = 12.0)
        val withSong = p0.copy(assets = p0.assets + song, tracks = p0.tracks.filter { it.kind != TrackKind.MUSIC } +
            studio.muse.core.edit.Track("mus", TrackKind.MUSIC, items = listOf(AudioClip("m1", song.id, 0.0, 0.0, 8.0))))
        c.load(withSong, "T", "take_1", null, false)
        assertTrue(c.ui.value.songCaptionable)
        c.act(EditAction.LyricCaptions); advanceUntilIdle()
        val ct = c.p().tracks.first { it.kind == TrackKind.CAPTION }.caption!!
        assertEquals(song.id, ct.asset); assertEquals(studio.muse.core.edit.CaptionPreset.KARAOKE, ct.style.preset)
        assertTrue(studio.muse.core.edit.captionWords(c.p()).isNotEmpty())
        valid(c.p())
    }

    @Test fun overlayDissolve() = runTest {
        val c = controller()
        val p0 = c.p()
        val logo = studio.muse.core.edit.Asset("logo", studio.muse.core.edit.AssetKind.IMAGE, upload = "up_logo", width = 512, height = 512)
        val imgs = studio.muse.core.edit.Track("imgs", TrackKind.IMAGE, items = listOf(
            studio.muse.core.edit.ImageItem("i1", "logo", 1.0, 2.0), studio.muse.core.edit.ImageItem("i2", "logo", 3.0, 2.0)))
        c.load(p0.copy(assets = p0.assets + logo, tracks = p0.tracks + imgs), "T", "take_1", null, false)
        c.act(EditAction.OverlayDissolve("i2", .5))
        fun i2() = c.p().tracks.first { it.id == "imgs" }.items[1] as studio.muse.core.edit.ImageItem
        assertEquals(2.5, i2().startSec, 1e-9); assertEquals(.5, i2().transitionIn!!.durationSec, 1e-9)
        valid(c.p())
        c.act(EditAction.OverlayDissolve("i2", 5.0)) // capped at half of each item
        assertEquals(1.0, i2().transitionIn!!.durationSec, 1e-9); assertEquals(2.0, i2().startSec, 1e-9)
        valid(c.p())
        c.act(EditAction.OverlayDissolve("i2", null))
        assertEquals(3.0, i2().startSec, 1e-9); assertNull(i2().transitionIn)
        c.act(EditAction.OverlayDissolve("i1", .5)); assertEquals("A dissolve needs a clip right before this one on its track", c.ui.value.message)
    }

    @Test fun splitVoiceAndMusic() = runTest {
        val c = controller()
        val clip = c.p().mainClips[0]
        c.act(EditAction.Select(clip.id))
        c.act(EditAction.SeparatePrice); advanceUntilIdle()
        assertTrue(c.ui.value.ai["separate"]?.price != null)
        c.act(EditAction.Separate(studio.muse.core.edit.SeparationKeep.BOTH)); advanceUntilIdle()
        assertEquals(true, c.p().mainClips[0].muted)
        val voc = c.p().tracks.first { it.kind == TrackKind.VOICE }.items.single() as AudioClip
        assertEquals(clip.inSec, voc.inSec, 1e-9); assertEquals(clip.outSec, voc.outSec, 1e-9); assertEquals(0.0, voc.startSec, 1e-9)
        assertTrue(c.p().tracks.any { t -> t.kind == TrackKind.MUSIC && t.items.any { (it as AudioClip).asset == c.p().assets.last().id } })
        valid(c.p())
    }

    @Test fun cutOutAPhoto() = runTest {
        val c = controller()
        val p0 = c.p()
        val photo = studio.muse.core.edit.Asset("ph", studio.muse.core.edit.AssetKind.IMAGE, upload = "up_ph", width = 1200, height = 1600)
        val imgs = studio.muse.core.edit.Track("imgs", TrackKind.IMAGE, items = listOf(studio.muse.core.edit.ImageItem("i1", "ph", 0.0, 3.0, transform = studio.muse.core.edit.Transform(.5, .5, .5))))
        c.load(p0.copy(assets = p0.assets + photo, tracks = p0.tracks + imgs), "T", "take_1", null, false)
        c.act(EditAction.Select("i1"))
        c.act(EditAction.CutoutPrice); advanceUntilIdle()
        assertTrue(c.ui.value.ai["cutout"]?.price != null)
        c.act(EditAction.Cutout); advanceUntilIdle()
        val im = c.p().tracks.first { it.id == "imgs" }.items[0] as studio.muse.core.edit.ImageItem
        assertTrue(im.asset.startsWith("cutout"))
        // The subject was centred in the photo, so it stays centred; half as wide as the photo → half the size.
        assertEquals(.5, im.transform!!.x!!, 1e-6); assertEquals(.5, im.transform!!.y!!, 1e-6)
        valid(c.p())
    }

    @Test fun pictureEffect() = runTest {
        val c = controller()
        val id = c.p().mainClips[0].id
        c.act(EditAction.Select(id))
        c.act(EditAction.SetEffect(studio.muse.core.edit.Effect(studio.muse.core.edit.EffectId.GLITCH, .5, 2.0)))
        assertEquals(studio.muse.core.edit.EffectId.GLITCH, c.p().mainClips[0].effect!!.id)
        c.act(EditAction.SetEffect(studio.muse.core.edit.Effect(studio.muse.core.edit.EffectId.DUOTONE, 1.0, colors = listOf("#003344", "#FFE600"))))
        valid(c.p())
        // The plan carries it to the engine (and a cover clip isn't pre-cropped then).
        assertEquals(studio.muse.core.edit.EffectId.DUOTONE, studio.muse.core.edit.planRender(c.p(), emptyMap()).layers.flatMap { it.clips }.first { it.itemId == id }.look!!.effect!!.id)
        c.act(EditAction.SetEffect(null)); assertNull(c.p().mainClips[0].effect)
    }

    @Test fun cutToTheMusic() = runTest {
        val c = controller()
        val p0 = c.p()
        val src = p0.mainClips[0]
        val song = studio.muse.core.edit.Asset("song_up", studio.muse.core.edit.AssetKind.AUDIO, upload = "up_song", durationSec = 30.0)
        val two = p0.copy(assets = p0.assets + song, tracks = p0.tracks.map { t -> if (t.kind == TrackKind.MAIN) t.copy(items = listOf(src.copy(id = "a", inSec = 0.0, outSec = 6.0), src.copy(id = "b", inSec = 6.0, outSec = 12.0, transitionIn = studio.muse.core.edit.Transition(studio.muse.core.edit.TransitionKind.FADE, .4)))) else t } +
            studio.muse.core.edit.Track("mus", TrackKind.MUSIC, items = listOf(AudioClip("m1", song.id, 0.0, 0.0, 20.0))))
        c.load(two, "T", "take_1", null, false)
        // No beats yet: the free helper runs first, then the cut.
        c.act(EditAction.CutToMusic(studio.muse.core.edit.MusicPace.FAST)); advanceUntilIdle()
        val beats = studio.muse.core.edit.musicBeatTimes(c.p())
        assertTrue(beats.isNotEmpty())
        val first = c.p().mainClips[0]
        val end = first.outSec - first.inSec
        assertTrue("the first cut lands on a beat", beats.any { kotlin.math.abs(it - end) < 1e-3 })
        assertNull(c.p().mainClips[1].transitionIn)
        assertEquals(studio.muse.core.edit.MusicPace.FAST, c.ui.value.musicPace)
        valid(c.p())
    }

    @Test fun hslPerHue() = runTest {
        val c = controller()
        val id = c.p().mainClips[0].id
        c.act(EditAction.Select(id))
        c.act(EditAction.SetHsl(studio.muse.core.edit.HueBand.ORANGE, "sat", -.4))
        c.act(EditAction.SetHsl(studio.muse.core.edit.HueBand.ORANGE, "light", .25))
        c.act(EditAction.SetHsl(studio.muse.core.edit.HueBand.BLUE, "hue", .5))
        fun look() = (c.p().mainClips[0]).look
        assertEquals(studio.muse.core.edit.HslBand(sat = -.4, light = .25), look()!!.hsl!![studio.muse.core.edit.HueBand.ORANGE])
        assertEquals(.5, look()!!.hsl!![studio.muse.core.edit.HueBand.BLUE]!!.hue!!, 1e-9)
        valid(c.p())
        // Back to 0 drops the band; reset drops the rest (and the empty look).
        c.act(EditAction.SetHsl(studio.muse.core.edit.HueBand.BLUE, "hue", 0.0))
        assertNull(look()!!.hsl!![studio.muse.core.edit.HueBand.BLUE])
        c.act(EditAction.SetHsl(null))
        assertNull(look())
    }

    @Test fun ownFonts() = runTest {
        val c = controller()
        c.act(EditAction.Scrub(1.0, end = true)); c.act(EditAction.AddText)
        val tid = c.ui.value.selectedId!!
        c.act(EditAction.AddFont("up_font_1", "Figtree Bold"))
        fun text() = c.p().tracks.first { it.kind == TrackKind.TEXT }.items.single() as studio.muse.core.edit.TextItem
        val font = c.p().assets.single { it.kind == studio.muse.core.edit.AssetKind.FONT }
        assertEquals("up_font_1", font.upload); assertEquals("Figtree Bold", font.name)
        assertEquals(font.id, text().style.fontAsset)
        valid(c.p())
        // The same upload again reuses the asset; a built-in family clears the own font (the asset stays for the chip).
        c.act(EditAction.AddFont("up_font_1", "Figtree Bold"))
        assertEquals(1, c.p().assets.count { it.kind == studio.muse.core.edit.AssetKind.FONT })
        c.act(EditAction.SetTextStyle(tid, text().style.copy(font = studio.muse.core.edit.Font.SERIF, fontAsset = null)))
        assertNull(text().style.fontAsset); assertEquals(1, c.p().assets.count { it.kind == studio.muse.core.edit.AssetKind.FONT })
        // A kit from this edit carries the family only.
        c.act(EditAction.SetTextStyle(tid, text().style.copy(fontAsset = font.id)))
        assertNull(studio.muse.core.edit.kitOf(c.p()).textStyle!!.fontAsset)
        valid(c.p())
    }

    @Test fun adjustmentLayer() = runTest {
        val c = controller()
        c.act(EditAction.Scrub(2.0, end = true)); c.act(EditAction.AddAdjustLayer)
        val tr = c.p().tracks.single { it.kind == TrackKind.ADJUST }
        val layer = tr.items.single() as studio.muse.core.edit.AdjustItem
        assertEquals(2.0, layer.startSec, 1e-9); assertEquals(3.0, layer.durationSec, 1e-9)
        assertEquals(layer.id, c.ui.value.selectedId); assertEquals(Panel.FILTERS, c.ui.value.panel)
        assertTrue(lanesOf(c.p()).any { it.track?.kind == TrackKind.ADJUST }); assertEquals("Adjustment", trackName(tr))
        // Colour and strength on the layer; the graded frame changes only inside its span.
        c.act(EditAction.LayerField("exposure", .5)); c.act(EditAction.LayerField("opacity", .5))
        c.act(EditAction.LayerFilter("warm", .8))
        var l = c.p().tracks.single { it.kind == TrackKind.ADJUST }.items.single() as studio.muse.core.edit.AdjustItem
        assertEquals(.5, l.adjust!!.exposure!!, 1e-9); assertEquals(.5, l.opacity!!, 1e-9); assertEquals(studio.muse.core.edit.FilterRef("warm", .8), l.filter)
        assertNotNull(studio.muse.core.edit.adjustLayerMatrix(c.p(), 3.0)); assertNull(studio.muse.core.edit.adjustLayerMatrix(c.p(), 6.0))
        valid(c.p())
        // ◆ keys exposure at the playhead; the slider then sets the key there.
        c.act(EditAction.Scrub(2.5, end = true)); c.act(EditAction.AddKeyframe(studio.muse.core.edit.KfProp.EXPOSURE))
        c.act(EditAction.Scrub(4.0, end = true)); c.act(EditAction.AddKeyframe(studio.muse.core.edit.KfProp.EXPOSURE)); c.act(EditAction.LayerField("exposure", -.4))
        l = c.p().tracks.single { it.kind == TrackKind.ADJUST }.items.single() as studio.muse.core.edit.AdjustItem
        val keys = l.keyframes!![studio.muse.core.edit.KfProp.EXPOSURE]!!
        assertEquals(listOf(.5, 2.0), keys.map { it.t }); assertEquals(listOf(.5, -.4), keys.map { it.v })
        assertEquals(.5, l.adjust!!.exposure!!, 1e-9)
        valid(c.p())
        // A transform key does nothing on a layer; trims work like an image's.
        c.act(EditAction.AddKeyframe(studio.muse.core.edit.KfProp.SCALE))
        assertNull(l.keyframes!![studio.muse.core.edit.KfProp.SCALE])
        val trimmed = SuiteOps.trimBy(c.p(), l.id, left = false, deltaSec = -1.0)!!
        assertEquals(2.0, (trimmed.tracks.single { it.kind == TrackKind.ADJUST }.items.single() as studio.muse.core.edit.AdjustItem).durationSec, 1e-9)
    }

    @Test fun loopAnimations() = runTest {
        val c = controller()
        c.act(EditAction.Scrub(1.0, end = true)); c.act(EditAction.AddText)
        val tid = c.ui.value.selectedId!!
        c.act(EditAction.SetLoop(tid, studio.muse.core.edit.AnimLoop(studio.muse.core.edit.LoopKind.PULSE, 0.123, 1.7)))
        val l = (c.p().tracks.first { it.kind == TrackKind.TEXT }.items.single() as studio.muse.core.edit.TextItem).animLoop!!
        assertEquals(.2, l.periodSec, 1e-9); assertEquals(1.0, l.amount!!, 1e-9) // clamped
        valid(c.p())
        // A text frame pulses: bigger half a period in.
        val plan = planRender(c.p(), infos)
        val piece = plan.overlays.filterIsInstance<studio.muse.core.edit.TextPiece>().first()
        assertTrue(plan.textFrame(piece, 2.1)!!.scale > plan.textFrame(piece, 2.0)!!.scale)
        // Main clips can't loop.
        c.act(EditAction.SetLoop(c.p().mainClips[0].id, studio.muse.core.edit.AnimLoop(studio.muse.core.edit.LoopKind.SWAY, 1.0)))
        assertNull(c.p().mainClips[0].animLoop); assertEquals("Loop animations are for overlays, photos and text", c.ui.value.message)
        c.act(EditAction.SetLoop(tid, null)); assertNull((c.p().tracks.first { it.kind == TrackKind.TEXT }.items.single() as studio.muse.core.edit.TextItem).animLoop)
    }

    @Test fun audioSpeed() = runTest {
        val c = controller()
        c.act(EditAction.AddAudio("up_m", 8.0, voiceOver = false))
        val m = c.p().tracks.first { it.kind == TrackKind.MUSIC }.items.single() as AudioClip
        c.act(EditAction.MarkBeat.let { EditAction.Scrub(2.0, end = true) }); c.act(EditAction.MarkBeat)
        c.act(EditAction.AudioSpeed(m.id, 2.0))
        val m2 = c.p().tracks.first { it.kind == TrackKind.MUSIC }.items.single() as AudioClip
        assertEquals(2.0, m2.speed!!, 1e-9); assertEquals(4.0, clipLength(m2), 1e-9)
        assertEquals(listOf(1.0), SuiteOps.beatTimes(c.p(), false)) // the beat at source 2 s plays at 1 s
        valid(c.p())
        c.act(EditAction.AudioSpeed(m.id, 5.0)); assertEquals(2.0, (c.p().tracks.first { it.kind == TrackKind.MUSIC }.items.single() as AudioClip).speed!!, 1e-9) // clamped
        c.act(EditAction.AudioSpeed(m.id, 1.0)); assertNull((c.p().tracks.first { it.kind == TrackKind.MUSIC }.items.single() as AudioClip).speed)
    }
}

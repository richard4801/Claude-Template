package studio.muse.app.ui.screens.edit

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.EditedVideo
import studio.muse.app.data.EditorEstimate
import studio.muse.app.data.EditorJob
import studio.muse.app.data.EditorSourceDto
import studio.muse.app.data.FakeEditorResults
import studio.muse.app.data.FakeMuseApi
import studio.muse.core.edit.AudioClip
import studio.muse.core.edit.CaptionExport
import studio.muse.core.edit.CaptionPreset
import studio.muse.core.edit.Chroma
import studio.muse.core.edit.Crop
import studio.muse.core.edit.EditJson
import studio.muse.core.edit.EditProject
import studio.muse.core.edit.ExportCodec
import studio.muse.core.edit.ExportResolution
import studio.muse.core.edit.ExportSettings
import studio.muse.core.edit.ExportShape
import studio.muse.core.edit.Font
import studio.muse.core.edit.ImageItem
import studio.muse.core.edit.KfProp
import studio.muse.core.edit.Mask
import studio.muse.core.edit.MaskShape
import studio.muse.core.edit.MediaInfo
import studio.muse.core.edit.Presets
import studio.muse.core.edit.SourceSize
import studio.muse.core.edit.SpeedPreset
import studio.muse.core.edit.TextItem
import studio.muse.core.edit.Track
import studio.muse.core.edit.TrackKind
import studio.muse.core.edit.Transform
import studio.muse.core.edit.TransitionKind
import studio.muse.core.edit.VideoClip
import studio.muse.core.edit.VoiceEffect
import studio.muse.core.edit.clipLength
import studio.muse.core.edit.durationSec
import studio.muse.core.edit.exportProject
import studio.muse.core.edit.planRender
import studio.muse.core.edit.problemOf
import studio.muse.core.edit.toSrt
import java.io.File

/**
 * The Android Edit audit (plans/android-edit-audit.md): every control in Edit is driven through the editor's state
 * machine, and the project it leaves is asserted (and still valid, and still renders: [planRender] is what the preview
 * player and the export are built from). One test per panel; the audit lists which test covers each control.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class EditAuditTest {
    private class Stub : EditBackend {
        val runs = ArrayList<String>()
        override suspend fun estimate(kind: String, source: EditorSourceDto, options: JsonObject?) = EditorEstimate(kind, 0.02) to null
        override suspend fun run(kind: String, source: EditorSourceDto, options: JsonObject?, onProgress: (EditorJob) -> Unit): Pair<JsonObject?, String?> {
            runs += kind
            return FakeEditorResults.result(kind, source.durationSec ?: 15.0, "j1", options) to null
        }
    }

    private val infos = mapOf("src" to MediaInfo(15.0, 1080, 1920, 30.0, true))

    private fun TestScope.controller(b: EditBackend = Stub()) = EditSuiteController(this, b).also {
        it.load(EditSuiteViewModel.newProject("take_1", 15.0, SourceSize(1080, 1920, 30.0, true)), "Take", "take_1", null, reopened = false)
    }

    private fun EditSuiteController.p() = project!!

    /** Valid, and the preview/export plan builds from it. */
    private fun renders(p: EditProject, more: Map<String, MediaInfo> = emptyMap()) {
        assertNull(problemOf(p)?.message, problemOf(p))
        planRender(p, infos + more)
    }

    private fun EditSuiteController.splitAt(t: Double) { act(EditAction.Scrub(t, end = true)); act(EditAction.Split) }

    // ------------------------------------------------------------------ Edit panel and transport
    @Test fun editPanelSplitDeleteDuplicateRippleUndoRedo() = runTest {
        val c = controller()
        c.splitAt(5.0); c.splitAt(10.0)
        assertEquals(3, c.p().mainClips.size)
        c.act(EditAction.Select(c.p().mainClips[1].id)); c.act(EditAction.Delete)
        assertEquals(2, c.p().mainClips.size); assertEquals(10.0, c.ui.value.duration, 1e-6)
        c.act(EditAction.Select(c.p().mainClips[0].id)); c.act(EditAction.Duplicate)
        assertEquals(3, c.p().mainClips.size); assertEquals(15.0, c.ui.value.duration, 1e-6)
        c.act(EditAction.Undo); assertEquals(2, c.p().mainClips.size)
        c.act(EditAction.Redo); assertEquals(3, c.p().mainClips.size)
        c.act(EditAction.Ripple(false)); assertFalse(c.ui.value.ripple)
        // The last clip can't be deleted.
        val one = controller(); one.act(EditAction.Delete); assertEquals(1, one.p().mainClips.size); assertNotNull(one.ui.value.message)
        renders(c.p())
    }

    @Test fun transportPlayPauseFullscreenAndSafeArea() = runTest {
        val c = controller()
        c.act(EditAction.PlayPause); assertTrue(c.ui.value.playing)
        c.act(EditAction.PlayPause); assertFalse(c.ui.value.playing)
        c.act(EditAction.Fullscreen); assertTrue(c.ui.value.fullscreen)
        // Edit's view (plans/edit-platform-preview.md): Clean with the box by default; a view the person picks is told
        // to the screen (remembered per project) once; a view the canvas lacks shows as Clean.
        val told = ArrayList<studio.muse.core.edit.EditPreview>()
        c.onPreviewChanged = { told += it }
        assertEquals(studio.muse.core.edit.EditPreview(), c.ui.value.preview)
        val portrait = c.p().canvas.height > c.p().canvas.width
        c.act(EditAction.PreviewOf(studio.muse.core.edit.EditPreview(studio.muse.core.edit.PreviewView.TIKTOK)))
        assertEquals(if (portrait) studio.muse.core.edit.PreviewView.TIKTOK else studio.muse.core.edit.PreviewView.CLEAN, c.ui.value.preview.view)
        c.act(EditAction.PreviewOf(c.ui.value.preview.copy(safeArea = false))); assertFalse(c.ui.value.preview.safeArea)
        c.act(EditAction.PreviewOf(c.ui.value.preview)) // no change: not told again
        assertEquals(if (portrait) 2 else 1, told.size)
        c.act(EditAction.Seek(7.0)); assertEquals(7.0, c.ui.value.playheadSec, 1e-9)
        c.act(EditAction.Zoom(80f)); assertEquals(80f, c.ui.value.pxPerSec)
    }

    @Test fun speedConstantAndCurves() = runTest {
        val c = controller()
        c.act(EditAction.Speed(2.0)); assertEquals(2.0, c.p().mainClips[0].speed, 0.0); assertEquals(7.5, c.ui.value.duration, 1e-6)
        c.act(EditAction.CurvePreset(SpeedPreset.MONTAGE)); assertEquals(SpeedPreset.MONTAGE, c.p().mainClips[0].speedCurve?.preset)
        val before = clipLength(c.p().mainClips[0])
        c.act(EditAction.CurvePoint(1, .5, 4.0, done = true))
        assertEquals(SpeedPreset.CUSTOM, c.p().mainClips[0].speedCurve?.preset)
        assertNotEquals(before, clipLength(c.p().mainClips[0]), 1e-6)
        c.act(EditAction.AddCurvePoint(.9)); assertTrue(c.p().mainClips[0].speedCurve!!.points.any { kotlin.math.abs(it.x - .9) < 1e-6 })
        c.act(EditAction.Speed(1.0)); assertNull(c.p().mainClips[0].speedCurve)
        renders(c.p())
    }

    @Test fun transformKeyframesAndCrop() = runTest {
        val c = controller()
        c.act(EditAction.SetTransform(Transform(x = .3, y = .6, scale = 1.4, rotation = 10.0)))
        assertEquals(Transform(x = .3, y = .6, scale = 1.4, rotation = 10.0), c.p().mainClips[0].transform)
        c.act(EditAction.Seek(2.0)); c.act(EditAction.AddKeyframe(KfProp.SCALE))
        assertEquals(1, c.p().mainClips[0].keyframes?.get(KfProp.SCALE)?.size)
        c.act(EditAction.SetCrop(Crop(left = .1, right = .2)))
        assertEquals(Crop(left = .1, right = .2), c.p().mainClips[0].crop)
        c.act(EditAction.SetCrop(Crop(left = .9))) // clamped to 45 %
        assertEquals(.45, c.p().mainClips[0].crop?.left!!, 1e-9)
        c.act(EditAction.SetCrop(null)); assertNull(c.p().mainClips[0].crop)
        c.act(EditAction.SetCrop(Crop(top = .2)))
        renders(c.p())
        assertNotNull(planRender(c.p(), infos).layers.flatMap { it.clips }.first { it.itemId == c.p().mainClips[0].id }.look?.crop)
    }

    // ------------------------------------------------------------------ Effects: transitions, masks, chroma
    @Test fun transitionsAllKindsDurationAndApplyToAll() = runTest {
        val c = controller()
        c.splitAt(5.0); c.splitAt(10.0)
        c.act(EditAction.Select(c.p().mainClips[0].id)); c.act(EditAction.SetTransition(TransitionKind.FADE))
        assertNotNull(c.ui.value.message) // the first clip can't take one
        c.act(EditAction.Select(c.p().mainClips[1].id))
        for (k in listOf(TransitionKind.FADE, TransitionKind.ZOOM, TransitionKind.WHIP, TransitionKind.SLIDE_LEFT, TransitionKind.WHITE, TransitionKind.GLITCH, TransitionKind.SPIN, TransitionKind.BLACK)) {
            c.act(EditAction.SetTransition(k, .4)); assertEquals(k, c.p().mainClips[1].transitionIn?.kind)
        }
        c.act(EditAction.SetTransition(TransitionKind.FADE, 1.0)); assertEquals(1.0, c.p().mainClips[1].transitionIn!!.durationSec, 1e-9)
        c.act(EditAction.TransitionToAll); assertEquals(TransitionKind.FADE, c.p().mainClips[2].transitionIn?.kind)
        c.act(EditAction.SetTransition(null)); assertNull(c.p().mainClips[1].transitionIn)
        renders(c.p())
    }

    @Test fun masksAndChromaKey() = runTest {
        val c = controller()
        c.act(EditAction.SetMask(Mask(MaskShape.CIRCLE))); assertEquals(MaskShape.CIRCLE, c.p().mainClips[0].mask?.shape)
        c.act(EditAction.SetMask(Mask(MaskShape.STAR, feather = .3, invert = true))); assertEquals(true, c.p().mainClips[0].mask?.invert)
        c.act(EditAction.SetMask(null)); assertNull(c.p().mainClips[0].mask)
        // Chroma key: on, blue, strength / edge / spill, off.
        c.act(EditAction.SetChroma(Chroma("#2BD15F", .4, .08, .5))); assertEquals("#2BD15F", c.p().mainClips[0].chroma?.color)
        c.act(EditAction.SetChroma(c.p().mainClips[0].chroma!!.copy(color = "#2B5BD1", similarity = .55, smoothness = .2, spill = .7)))
        assertEquals(Chroma("#2B5BD1", .55, .2, .7), c.p().mainClips[0].chroma)
        renders(c.p())
        assertNotNull(planRender(c.p(), infos).layers.flatMap { it.clips }.first().look?.chroma)
        c.act(EditAction.SetChroma(null)); assertNull(c.p().mainClips[0].chroma)
    }

    // ------------------------------------------------------------------ Filters
    @Test fun looksStrengthApplyToAllAndAdjust() = runTest {
        val c = controller()
        c.splitAt(7.0)
        c.act(EditAction.Select(c.p().mainClips[0].id))
        c.act(EditAction.PickLook("natural-clean", null)); assertEquals("pack:natural-clean", c.p().mainClips[0].look?.lut)
        c.act(EditAction.LookStrength(.6)); assertEquals(.6, c.p().mainClips[0].look?.strength!!, 1e-9)
        c.act(EditAction.LookToAll); assertEquals("pack:natural-clean", c.p().mainClips[1].look?.lut)
        for (f in listOf("exposure", "contrast", "saturation", "temperature", "highlights", "shadows")) c.act(EditAction.AdjustField(f, .3))
        val a = c.p().mainClips[0].adjust!!
        assertEquals(.3, a.exposure!!, 1e-9); assertEquals(.3, a.contrast!!, 1e-9); assertEquals(.3, a.saturation!!, 1e-9)
        assertEquals(.3, a.temperature!!, 1e-9); assertEquals(.3, a.highlights!!, 1e-9); assertEquals(.3, a.shadows!!, 1e-9)
        c.act(EditAction.AdjustField("grain", .5)); assertEquals(.5, c.p().mainClips[0].look?.grain?.amount!!, 1e-9)
        c.act(EditAction.PickLook(null, null)); assertNull(c.p().mainClips[0].look?.lut)
        renders(c.p())
    }

    // ------------------------------------------------------------------ Audio
    @Test fun audioVolumeFadesMuteVoiceAndEnhance() = runTest {
        val c = controller()
        c.act(EditAction.Volume(-6.0)); assertEquals(SuiteOps.dbToGain(-6.0), c.p().mainClips[0].volume!!, .01)
        c.act(EditAction.Fades(.5, 1.5)); assertEquals(.5, c.p().mainClips[0].fadeInSec!!, 0.0); assertEquals(1.5, c.p().mainClips[0].fadeOutSec!!, 0.0)
        c.act(EditAction.Voice(VoiceEffect.RADIO)); assertEquals(VoiceEffect.RADIO, c.p().mainClips[0].voiceEffect)
        c.act(EditAction.Enhance(true)); assertEquals(true, c.p().mainClips[0].enhance)
        c.act(EditAction.MuteClip(true)); assertEquals(true, c.p().mainClips[0].muted)
        c.act(EditAction.MuteClip(false))
        renders(c.p())
        val clip = planRender(c.p(), infos).layers.flatMap { it.clips }.first()
        assertTrue(clip.withAudio); assertTrue(clip.envelope.first().gain < .01) // the fade-in starts silent
    }

    @Test fun musicVoiceOverDuckingAndBeats() = runTest {
        val b = Stub()
        val c = controller(b)
        c.act(EditAction.AutoDuck(true)); assertEquals("Add music first · Audio → Music", c.ui.value.message)
        c.act(EditAction.AddAudio("up_music", 40.0, voiceOver = false))
        val music = c.p().tracks.single { it.kind == TrackKind.MUSIC }
        assertEquals(15.0, (music.items.single() as AudioClip).let { it.outSec - it.inSec }.coerceAtMost(15.0), 1e-9)
        c.act(EditAction.AddAudio("up_vo", 4.0, voiceOver = true, atSec = 3.0))
        val vo = c.p().tracks.single { it.kind == TrackKind.VOICE }.items.single() as AudioClip
        assertEquals(3.0, vo.startSec, 1e-9)
        c.act(EditAction.AutoDuck(true)); assertNotNull(SuiteOps.musicTrack(c.p())!!.duck)
        c.act(EditAction.DuckTimes(.3, .9)); assertEquals(.9, SuiteOps.musicTrack(c.p())!!.duck!!.releaseSec!!, 1e-9)
        c.act(EditAction.DetectBeats); advanceUntilIdle()
        assertTrue("beats" in b.runs); assertTrue((SuiteOps.musicTrack(c.p())!!.items.single() as AudioClip).beats.orEmpty().isNotEmpty())
        c.act(EditAction.Beats(BeatMarks.ALL)); assertEquals(BeatMarks.ALL, c.ui.value.beatMarks)
        c.act(EditAction.SnapToBeats(true)); c.act(EditAction.Scrub(4.03, end = true)); c.act(EditAction.Split)
        val cut = c.p().mainClips[0].outSec
        assertTrue(SuiteOps.beatTimes(c.p(), false).any { kotlin.math.abs(it - cut) < 1e-3 })
        renders(c.p(), mapOf(c.p().assets.first { it.upload == "up_music" }.id to MediaInfo(40.0, 0, 0, 0.0, true), c.p().assets.first { it.upload == "up_vo" }.id to MediaInfo(4.0, 0, 0, 0.0, true)))
    }

    @Test fun noiseReductionUsesTheCleanedVoice() = runTest {
        val b = Stub()
        val c = controller(b)
        c.act(EditAction.NoiseReduction(true)); advanceUntilIdle()
        assertTrue("denoise" in b.runs)
        assertNotNull(c.p().mainClips[0].audioAsset)
        c.act(EditAction.NoiseReduction(false)); assertNull(c.p().mainClips[0].audioAsset)
    }

    // ------------------------------------------------------------------ Text and captions
    @Test fun hooksAndTextEditing() = runTest {
        val c = controller()
        c.act(EditAction.AddHook(Presets.HOOKS.first().id))
        val t = c.p().tracks.single { it.kind == TrackKind.TEXT }.items.single() as TextItem
        assertEquals(t.id, c.ui.value.selectedId)
        c.act(EditAction.EditText(t.id, "Three things nobody tells you"))
        assertEquals("Three things nobody tells you", (c.p().tracks.single { it.kind == TrackKind.TEXT }.items.single() as TextItem).text)
        c.act(EditAction.Delete); assertTrue(c.p().tracks.none { it.kind == TrackKind.TEXT && it.items.isNotEmpty() })
        renders(c.p())
    }

    @Test fun captionsStylesFontColoursPositionWordsAndCuts() = runTest {
        val b = Stub()
        val c = controller(b)
        c.act(EditAction.CaptionStyleOf(CaptionPreset.BOX)); assertEquals("Make captions first · Auto-captions", c.ui.value.message)
        c.act(EditAction.AutoCaptions); advanceUntilIdle()
        assertNotNull(c.ui.value.captionTrack)
        c.act(EditAction.CaptionStyleOf(CaptionPreset.KARAOKE)); assertEquals(CaptionPreset.KARAOKE, c.ui.value.captionPreset)
        c.act(EditAction.CaptionFont(Font.SERIF)); assertEquals(Font.SERIF, c.ui.value.captionTrack!!.caption!!.style.text.font)
        c.act(EditAction.CaptionColors(text = "#FFE600", highlight = "#22D3EE"))
        assertEquals("#FFE600", c.ui.value.captionTrack!!.caption!!.style.text.color); assertEquals("#22D3EE", c.ui.value.captionTrack!!.caption!!.style.highlightColor)
        c.act(EditAction.CaptionY(.2)); assertEquals(.2, c.ui.value.captionTrack!!.caption!!.style.y!!, 1e-9)
        c.act(EditAction.CaptionWordsPerPage(1)); assertEquals(1, c.ui.value.captionTrack!!.caption!!.style.wordsPerPage)
        c.act(EditAction.WordHighlight(false)); assertEquals(c.ui.value.captionTrack!!.caption!!.style.text.color, c.ui.value.captionTrack!!.caption!!.style.highlightColor)
        val before = c.ui.value.duration
        c.act(EditAction.DeleteWord(0)); assertTrue(c.ui.value.duration < before)
        c.act(EditAction.CutSilences); advanceUntilIdle(); assertTrue("cuts" in b.runs)
        renders(c.p())
        assertTrue(toSrt(c.p()).contains("-->"))
    }

    // ------------------------------------------------------------------ Overlay, ratio, track headers
    @Test fun overlayAddToEndAndOverlayAtThePlayhead() = runTest {
        val c = controller()
        val take = TakeChoice("t2", "Counter", "Edit", null, 4.0, false, true)
        c.act(EditAction.AppendTake(take))
        assertEquals(2, c.p().mainClips.size); assertEquals(19.0, c.ui.value.duration, 1e-6)
        val asset = c.p().asset(c.p().mainClips[1].asset)!!; assertEquals("t2", asset.take)
        c.act(EditAction.Scrub(2.0, end = true)); c.act(EditAction.AddPip(take))
        val pip = c.p().tracks.single { it.kind == TrackKind.VIDEO }.items.single() as VideoClip
        assertEquals(2.0, pip.startSec!!, 1e-9); assertEquals(asset.id, pip.asset) // shares the take's asset
        renders(c.p(), mapOf(asset.id to MediaInfo(4.0, 1080, 1920, 30.0, true)))
    }

    @Test fun ratioAndTrackHeaders() = runTest {
        val c = controller()
        c.act(EditAction.Ratio(ExportShape.SQUARE)); assertEquals(c.p().canvas.width, c.p().canvas.height)
        assertEquals(ExportShape.SQUARE, c.ui.value.export.shape)
        c.act(EditAction.Ratio(ExportShape.LANDSCAPE)); assertTrue(c.p().canvas.width > c.p().canvas.height)
        c.act(EditAction.ToggleTrackHidden("main")); assertEquals(true, c.p().main.hidden)
        c.act(EditAction.ToggleTrackHidden("main")); assertNull(c.p().main.hidden)
        renders(c.p())
    }

    // ------------------------------------------------------------------ Export
    @Test fun exportSettingsShapeTheRenderedProject() = runTest {
        val b = Stub()
        val c = controller(b)
        c.act(EditAction.AutoCaptions); advanceUntilIdle()
        val s = ExportSettings(ExportShape.FOUR_FIVE, ExportResolution.HD, 24, ExportCodec.HEVC, CaptionExport.SRT, aiLabel = true)
        c.act(EditAction.ExportOf(s))
        assertEquals(s, c.ui.value.export)
        assertEquals(ExportShape.FOUR_FIVE, ExportShape.of(c.p().canvas.width, c.p().canvas.height))
        val out = exportProject(c.p(), s)
        assertEquals(720, minOf(out.canvas.width, out.canvas.height)); assertEquals(24.0, out.canvas.fps, 0.0)
        assertEquals(true, out.tracks.single { it.kind == TrackKind.CAPTION }.hidden) // .SRT: captions not burnt in
        val plan = planRender(out, infos)
        assertEquals(24.0, plan.fps, 0.0); assertTrue(plan.overlays.none { it is studio.muse.core.edit.CaptionPiece })
        val burn = planRender(exportProject(c.p(), s.copy(captions = CaptionExport.BURN_IN)), infos)
        assertTrue(burn.overlays.any { it is studio.muse.core.edit.CaptionPiece })
    }

    /** Save: the version keeps the project and the "Label as AI-generated" choice (before 2026-11-08 the label was dropped). */
    @Test fun savingAVersionKeepsTheProjectAndTheAiLabel(): Unit = runBlocking {
        val scope = kotlinx.coroutines.MainScope()
        val api = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
        val src = object { val id = "t_j1" }
        val p = EditSuiteViewModel.newProject(src.id, 12.0, SourceSize(1080, 1920, 30.0, true))
        val f = File.createTempFile("edit", ".mp4").apply { writeBytes(ByteArray(64)) }
        val labelled = api.saveProjectVersion(src.id, EditedVideo(f, null, 12.0, 1080, 1920, 30.0), EditJson.encode(p), aiLabel = true)
        assertTrue(labelled.aiLabel); assertEquals("edit", labelled.kind); assertEquals(src.id, labelled.parentTakeId)
        val plain = api.saveProjectVersion(src.id, EditedVideo(f, null, 12.0, 1080, 1920, 30.0), EditJson.encode(p))
        assertFalse(plain.aiLabel)
        // The request the real API sends: aiLabel only when true.
        val json = kotlinx.serialization.json.Json { explicitNulls = false; encodeDefaults = true }
        assertTrue(json.encodeToString(studio.muse.app.data.TakeVersionV2Request.serializer(), studio.muse.app.data.TakeVersionV2Request("u", null, EditJson.encode(p), 12.0, 1080, 1920, aiLabel = true)).contains("\"aiLabel\":true"))
        assertFalse(json.encodeToString(studio.muse.app.data.TakeVersionV2Request.serializer(), studio.muse.app.data.TakeVersionV2Request("u", null, EditJson.encode(p), 12.0, 1080, 1920)).contains("aiLabel"))
        f.delete(); scope.cancel()
    }

    /** Nothing in Edit is a placeholder (owner rule 2026-11-08): no "Coming soon" controls in the panels. */
    @Test fun noComingSoonControlsInTheEditPanels() {
        val src = File("src/main/kotlin/studio/muse/app/ui/screens/edit/SuiteSheets.kt").readText()
        assertFalse(src.contains("Smooth slow-mo")); assertFalse(src.contains("C2PA"))
    }
}

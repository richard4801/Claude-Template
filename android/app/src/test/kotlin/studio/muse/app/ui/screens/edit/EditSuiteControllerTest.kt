package studio.muse.app.ui.screens.edit

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.data.EditListDto
import studio.muse.app.data.EditedVideo
import studio.muse.app.data.EditorEstimate
import studio.muse.app.data.EditorJob
import studio.muse.app.data.EditorJobRequest
import studio.muse.app.data.EditorSourceDto
import studio.muse.app.data.FakeEditorResults
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.Take
import studio.muse.core.edit.CaptionPreset
import studio.muse.core.edit.EditJson
import studio.muse.core.edit.ExportShape
import studio.muse.core.edit.KfProp
import studio.muse.core.edit.SourceSize
import studio.muse.core.edit.SpeedPreset
import studio.muse.core.edit.TrackKind
import studio.muse.core.edit.TransitionKind
import studio.muse.core.edit.VoiceEffect
import studio.muse.core.edit.clipLength
import studio.muse.core.edit.durationSec
import studio.muse.core.edit.problemOf
import java.io.File

/** The Edit suite's state machine (EditSuiteController) and its data side, without Android. */
@OptIn(ExperimentalCoroutinesApi::class)
class EditSuiteControllerTest {
    /** A backend answering like the demo one: prices from the estimate rules, results at once. */
    private class StubBackend : EditBackend {
        val runs = ArrayList<String>()
        override suspend fun estimate(kind: String, source: EditorSourceDto, options: JsonObject?) =
            EditorEstimate(kind, if (kind == "beats" || options?.get("silenceOnly") != null) 0.0 else 0.02, free = kind == "beats" || options?.get("silenceOnly") != null) to null
        override suspend fun run(kind: String, source: EditorSourceDto, options: JsonObject?, onProgress: (EditorJob) -> Unit): Pair<JsonObject?, String?> {
            runs += kind + (if (options?.get("silenceOnly") != null) ":silence" else "")
            onProgress(EditorJob("j", kind, "running", 50, "Listening"))
            return FakeEditorResults.result(kind, source.durationSec ?: 18.0, "j1", options) to null
        }
    }

    private fun project() = EditSuiteViewModel.newProject("take_1", 18.0, SourceSize(1080, 1920, 30.0, true))

    private fun TestScope.controller(b: EditBackend = StubBackend()) = EditSuiteController(this, b).also {
        it.load(project(), "Morning café", "take_1", null, reopened = false)
    }

    private fun EditSuiteController.p() = project!!

    @Test fun splitDeleteUndoRedo() = runTest {
        val c = controller()
        c.act(EditAction.Seek(6.0)); c.act(EditAction.Split)
        assertEquals(2, c.p().mainClips.size)
        assertTrue(c.ui.value.canUndo)
        c.act(EditAction.Select(c.p().mainClips[0].id)); c.act(EditAction.Delete)
        assertEquals(1, c.p().mainClips.size)
        assertEquals(12.0, durationSec(c.p()), 1e-6)
        c.act(EditAction.Undo); assertEquals(2, c.p().mainClips.size)
        c.act(EditAction.Undo); assertEquals(1, c.p().mainClips.size); assertFalse(c.ui.value.canUndo)
        c.act(EditAction.Redo); assertEquals(2, c.p().mainClips.size); assertTrue(c.ui.value.canRedo)
        c.act(EditAction.Duplicate)
        assertEquals(3, c.p().mainClips.size)
        assertNull(problemOf(c.p()))
    }

    @Test fun refusedEditsSayWhy() = runTest {
        val c = controller()
        c.act(EditAction.Seek(0.02)); c.act(EditAction.Split)
        assertEquals(1, c.p().mainClips.size)
        assertNotNull(c.ui.value.message)
        c.act(EditAction.ClearMessage); assertNull(c.ui.value.message)
        c.act(EditAction.Delete) // the only clip
        assertEquals(1, c.p().mainClips.size); assertNotNull(c.ui.value.message)
    }

    @Test fun speedAndCurvesAreOneUndoStepPerDrag() = runTest {
        val c = controller()
        c.act(EditAction.Speed(2.0, done = false)); c.act(EditAction.Speed(3.0, done = false)); c.act(EditAction.Speed(4.0, done = true))
        assertEquals(4.5, durationSec(c.p()), 1e-6)
        c.act(EditAction.Undo)
        assertEquals("the whole drag undoes at once", 18.0, durationSec(c.p()), 1e-6)
        c.act(EditAction.CurvePreset(SpeedPreset.HERO))
        val clip = c.p().mainClips[0]
        assertEquals(SpeedPreset.HERO, clip.speedCurve!!.preset)
        assertTrue("hero shortens the clip", clipLength(clip) < 18.0)
        c.act(EditAction.CurvePoint(2, 0.42, 9.0, done = false)); c.act(EditAction.CurvePoint(2, 0.45, 10.0, done = true))
        assertEquals(SpeedPreset.CUSTOM, c.p().mainClips[0].speedCurve!!.preset)
        assertEquals(10.0, c.p().mainClips[0].speedCurve!!.points[2].speed, 1e-9)
        c.act(EditAction.Undo); assertEquals(SpeedPreset.HERO, c.p().mainClips[0].speedCurve!!.preset)
        c.act(EditAction.AddCurvePoint(0.85)); assertEquals(7, c.p().mainClips[0].speedCurve!!.points.size)
        // A split keeps the curve on both pieces.
        c.act(EditAction.Seek(2.0)); c.act(EditAction.Split)
        assertTrue(c.p().mainClips.all { it.speedCurve != null })
        assertNull(problemOf(c.p()))
    }

    @Test fun captionsShowTheirPriceFirstThenRunAndStyle() = runTest {
        val b = StubBackend()
        val c = controller(b)
        c.act(EditAction.Open(Panel.CAPTIONS)); advanceUntilIdle()
        assertEquals("about $0.02", c.ui.value.ai["captions"]?.price)
        assertEquals("Free", c.ui.value.ai["silences"]?.price)
        assertTrue(b.runs.isEmpty())
        c.act(EditAction.AutoCaptions); advanceUntilIdle()
        val ct = c.ui.value.captionTrack!!.caption!!
        assertTrue(ct.words.size > 20)
        assertEquals(CaptionPreset.POP, ct.style.preset)
        c.act(EditAction.CaptionStyleOf(CaptionPreset.HIGHLIGHTER))
        assertEquals(CaptionPreset.HIGHLIGHTER, c.ui.value.captionPreset)
        c.act(EditAction.CaptionY(0.2)); assertEquals(0.2, c.ui.value.captionTrack!!.caption!!.style.y!!, 1e-9)
        c.act(EditAction.WordHighlight(false))
        val s = c.ui.value.captionTrack!!.caption!!.style
        assertEquals(s.text.color, s.highlightColor)
        // Fillers come from the transcript, on the device; deleting a word cuts the video.
        val before = durationSec(c.p())
        val fillers = SuiteOps.words(c.p()).count { it.kept && it.filler }
        assertTrue(fillers >= 2)
        c.act(EditAction.RemoveFillers)
        assertEquals(0, SuiteOps.words(c.p()).count { it.kept && it.filler })
        assertTrue(durationSec(c.p()) < before)
        val word = SuiteOps.words(c.p()).first { it.kept && it.text == "honestly" }
        c.act(EditAction.DeleteWord(word.index))
        assertFalse(SuiteOps.words(c.p()).first { it.index == word.index }.kept)
        assertNull(problemOf(c.p()))
    }

    @Test fun silenceCutsAreFreeAndNeedNoTranscript() = runTest {
        val b = StubBackend()
        val c = controller(b)
        c.act(EditAction.CutSilences); advanceUntilIdle()
        assertEquals(listOf("cuts:silence"), b.runs)
        assertTrue(durationSec(c.p()) < 18.0)
        assertTrue(c.p().mainClips.size >= 2)
    }

    @Test fun transitionsAndApplyToAll() = runTest {
        val c = controller()
        c.act(EditAction.Seek(6.0)); c.act(EditAction.Split); c.act(EditAction.Seek(12.0)); c.act(EditAction.Split)
        c.act(EditAction.Select(c.p().mainClips[1].id))
        c.act(EditAction.SetTransition(TransitionKind.WHIP, 0.4))
        assertEquals(TransitionKind.WHIP, c.p().mainClips[1].transitionIn?.kind)
        c.act(EditAction.TransitionToAll)
        assertEquals(listOf(null, TransitionKind.WHIP, TransitionKind.WHIP), c.p().mainClips.map { it.transitionIn?.kind })
        c.act(EditAction.SetTransition(null)); c.act(EditAction.TransitionToAll)
        assertTrue(c.p().mainClips.all { it.transitionIn == null })
    }

    @Test fun audioMusicDuckBeatsAndSnap() = runTest {
        val c = controller()
        c.act(EditAction.AutoDuck(true)); assertNotNull("needs music first", c.ui.value.message)
        c.act(EditAction.AddAudio("up_music_1", 30.0, voiceOver = false))
        val music = c.p().tracks.first { it.kind == TrackKind.MUSIC }
        assertEquals(18.0, durationSec(c.p()), 1e-6)
        c.act(EditAction.AutoDuck(true))
        val duck = c.p().track(music.id)!!.duck!!
        assertEquals(SuiteOps.dbToGain(-12.0), duck.level!!, 1e-3)
        c.act(EditAction.DuckTimes(0.3, 0.8))
        assertEquals(0.3, c.p().track(music.id)!!.duck!!.attackSec!!, 1e-9)
        c.act(EditAction.DetectBeats); advanceUntilIdle()
        assertTrue(SuiteOps.beatTimes(c.p(), false).size > 20)
        assertEquals(118.0, c.ui.value.bpm!!, 1e-9)
        c.act(EditAction.SnapToBeats(true)); c.act(EditAction.Beats(BeatMarks.ALL))
        c.act(EditAction.Seek(5.0)); c.act(EditAction.Split)
        val cut = c.p().mainClips[0].outSec
        assertTrue("split landed on a beat", SuiteOps.beatTimes(c.p(), false).any { kotlin.math.abs(it - cut) < 1e-3 })
        c.act(EditAction.Volume(-6.0)); assertEquals(SuiteOps.dbToGain(-6.0), c.ui.value.activeClip!!.volume!!, 0.01)
        c.act(EditAction.Voice(VoiceEffect.RADIO)); c.act(EditAction.Enhance(true))
        assertEquals(VoiceEffect.RADIO, c.ui.value.activeClip!!.voiceEffect); assertEquals(true, c.ui.value.activeClip!!.enhance)
        c.act(EditAction.NoiseReduction(true)); advanceUntilIdle()
        assertNotNull(c.p().mainClips.first().audioAsset)
        assertNull(problemOf(c.p()))
    }

    @Test fun looksAdjustMaskTransformAndRatio() = runTest {
        val c = controller()
        c.act(EditAction.PickLook("film-gold", studio.muse.core.edit.Look(lut = "pack:film-gold", strength = 1.0)))
        // The picker passes the id; the look itself comes from the pack in the app. Here: set it directly.
        c.act(EditAction.LookStrength(0.7))
        c.act(EditAction.AdjustField("highlights", -0.12)); c.act(EditAction.AdjustField("grain", 0.2))
        val clip = c.p().mainClips[0]
        assertEquals(-0.12, clip.adjust!!.highlights!!, 1e-9)
        assertEquals(0.2, clip.look!!.grain!!.amount, 1e-9)
        c.act(EditAction.SetMask(studio.muse.core.edit.Mask(studio.muse.core.edit.MaskShape.CIRCLE, feather = 0.3)))
        assertEquals(studio.muse.core.edit.MaskShape.CIRCLE, c.p().mainClips[0].mask!!.shape)
        c.act(EditAction.SetTransform(studio.muse.core.edit.Transform(scale = 1.12)))
        c.act(EditAction.Seek(3.0)); c.act(EditAction.AddKeyframe(KfProp.SCALE))
        assertEquals(1, c.p().mainClips[0].keyframes!![KfProp.SCALE]!!.size)
        c.act(EditAction.Ratio(ExportShape.SQUARE))
        assertEquals(1080, c.p().canvas.width); assertEquals(1080, c.p().canvas.height)
        assertEquals(ExportShape.SQUARE, c.ui.value.export.shape)
        assertNull(problemOf(c.p()))
        // Everything survives the JSON the server stores.
        val back = EditJson.parse(EditJson.stringify(c.p()))
        assertEquals(c.p(), back)
    }

    @Test fun suiteLooksNeedTheShippedPalettes() = runTest {
        val c = controller()
        val suite = studio.muse.core.edit.Look(lut = "palette:teal_neon", strength = 1.0)
        // No palettes shipped: a palette look is refused like the reference ("unknown look").
        c.act(EditAction.PickLook(null, suite))
        assertNull(c.p().mainClips[0].look)
        assertNotNull(c.ui.value.message)
        // Shipped: it applies, its intensity changes, and it can be swapped or removed like any look.
        c.update { it.copy(suiteLooks = mapOf("teal_neon" to "Teal Neon")) }
        c.act(EditAction.PickLook(null, suite))
        assertEquals("teal_neon", c.p().mainClips[0].look!!.paletteId)
        c.act(EditAction.LookStrength(0.6))
        assertEquals(0.6, c.p().mainClips[0].look!!.strength!!, 1e-9)
        c.act(EditAction.PickLook("film-gold", studio.muse.core.edit.Look(lut = "pack:film-gold", strength = 1.0)))
        assertEquals("film-gold", c.p().mainClips[0].look!!.packId)
        c.act(EditAction.Undo)
        assertEquals("teal_neon", c.p().mainClips[0].look!!.paletteId)
        c.act(EditAction.PickLook(null, null))
        assertNull(c.p().mainClips[0].look)
    }

    @Test fun hooksTextAndPip() = runTest {
        val c = controller()
        c.act(EditAction.Seek(1.0)); c.act(EditAction.AddHook("hook-list"))
        val id = c.ui.value.selectedId!!
        c.act(EditAction.EditText(id, "3 things I wish I knew"))
        val text = c.p().tracks.first { it.kind == TrackKind.TEXT }.items.single() as studio.muse.core.edit.TextItem
        assertEquals("3 things I wish I knew", text.text); assertEquals("hook-list", text.template)
        c.act(EditAction.AddPip(TakeChoice("t2", "Counter", "Edit", null, 4.2, false, true)))
        val pip = c.p().tracks.first { it.kind == TrackKind.VIDEO }.items.single() as studio.muse.core.edit.VideoClip
        assertEquals(4.2, pip.outSec, 1e-9)
        assertNull(problemOf(c.p()))
    }

    @Test fun exportDisclosureIsOffByDefault() = runTest {
        val c = controller()
        val s = c.ui.value.export
        assertFalse(s.aiLabel); assertFalse(s.contentCredentials)
        assertEquals(1080 to 1920, s.size)
        assertTrue(s.estimatedBytes(18.0) in 10_000_000L..40_000_000L)
        c.act(EditAction.ExportOf(s.copy(shape = ExportShape.LANDSCAPE)))
        assertEquals(1920, c.p().canvas.width)
    }

    @Test fun priceText() {
        assertEquals("Free", EditSuiteController.priceOf(EditorEstimate("beats", 0.0, free = true)))
        assertEquals("about $0.02", EditSuiteController.priceOf(EditorEstimate("captions", 0.02)))
    }

    @Test fun takeEditsKeepAV2Project() {
        val json = Json { ignoreUnknownKeys = true; explicitNulls = false; coerceInputValues = true }
        val p = project()
        val take = """{"id":"t9","kind":"edit","title":"Café","label":"Edited","parentTakeId":"take_1","edits":${EditJson.stringify(p)}}"""
        val t = json.decodeFromString(Take.serializer(), take)
        assertNotNull(t.edits!!.project)
        assertNull("v1 code sees no segments", t.edits!!.toEdit())
        assertEquals(p, EditJson.parse(t.edits!!.project!!))
        // v1 lists still decode as before.
        val v1 = json.decodeFromString(Take.serializer(), """{"id":"t8","kind":"edit","title":"x","label":"Edited","edits":{"version":1,"sourceTakeId":"a","sourceDurationSec":5,"segments":[{"inSec":0,"outSec":2}]}}""")
        assertNull(v1.edits!!.project); assertEquals(1, v1.edits!!.toEdit()!!.segments.size)
        // And encode back unchanged.
        assertTrue(json.encodeToString(Take.serializer(), t).contains("\"canvas\""))
    }

    @Test fun demoBackendRunsHelpersAndSavesVersions(): Unit = runBlocking {
        val scope = MainScope()
        try {
            val api = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
            val src = EditorSourceDto(takeId = "t_j1", durationSec = 12.0)
            assertTrue(api.editorEstimate(EditorJobRequest("cuts", src, JsonObject(mapOf("silenceOnly" to JsonPrimitive(true))))).free)
            assertFalse(api.editorEstimate(EditorJobRequest("captions", src)).free)
            val j = api.startEditorJob(EditorJobRequest("captions", src))
            assertEquals("running", j.state)
            val done = api.editorJob(j.id)
            assertEquals("done", done.state)
            assertTrue(done.result!!.containsKey("words"))
            val f = File.createTempFile("edit", ".mp4")
            val p = EditSuiteViewModel.newProject("t_j1", 12.0, SourceSize(1080, 1920, 30.0, true))
            val t = api.saveProjectVersion("t_j1", EditedVideo(f, null, 12.0, 1080, 1920, 30.0), EditJson.encode(p))
            assertEquals("edit", t.kind); assertEquals("t_j1", t.parentTakeId)
            assertEquals(p, EditJson.parse(t.edits!!.project!!))
            f.delete()
        } finally { scope.cancel() }
    }

    @Suppress("unused") private val keepDto = EditListDto::class
}

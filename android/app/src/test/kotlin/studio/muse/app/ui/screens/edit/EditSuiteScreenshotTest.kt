package studio.muse.app.ui.screens.edit

import android.graphics.Bitmap
import android.os.Looper
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.test.core.app.ApplicationProvider
import com.github.takahirom.roborazzi.captureRoboImage
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import studio.muse.app.data.FakeEditorResults
import studio.muse.app.data.ImageRef
import studio.muse.app.platform.edit.LookLibrary
import studio.muse.app.platform.edit.LookThumbnails
import studio.muse.app.ui.components.RefImage
import studio.muse.app.ui.theme.MuseTheme
import studio.muse.app.ui.theme.ThemeId
import studio.muse.core.edit.Asset
import studio.muse.core.edit.AssetKind
import studio.muse.core.edit.AudioClip
import studio.muse.core.edit.CaptionWord
import studio.muse.core.edit.EditProject
import studio.muse.core.edit.ExportSettings
import studio.muse.core.edit.Presets
import studio.muse.core.edit.SPEED_PRESETS
import studio.muse.core.edit.SourceSize
import studio.muse.core.edit.SpeedCurve
import studio.muse.core.edit.SpeedPreset
import studio.muse.core.edit.Track
import studio.muse.core.edit.TrackKind
import studio.muse.core.edit.Transition
import studio.muse.core.edit.TransitionKind
import studio.muse.core.edit.VideoClip
import studio.muse.core.edit.problemOf

/**
 * The Edit suite (designs EM1–EM5) in all four themes: the editor, the captions, audio, speed-curve, looks and export
 * sheets, and the Edit home. PNGs land in app/build/outputs/roborazzi/edit_<theme>_<state>.png.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class EditSuiteScreenshotTest(private val theme: String, private val state: String) {
    companion object {
        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}_{1}")
        fun params(): List<Array<Any>> = listOf("a", "b", "c", "d").flatMap { t ->
            listOf("editor", "editor_360", "captions", "audio", "speed", "looks", "export", "home",
                // The approved Edit layout (plans/edit-layout.md) on a tablet: landscape 1280 × 800 and portrait 800 × 1280; the
                // inspector hidden.
                "tablet", "tablet_captions", "tablet_portrait", "tablet_collapsed",
                // Remove background → tap what to keep (workstream 1's tracked cut-out), phone and tablet.
                "keep", "tablet_keep",
                // The cut-out isn't live yet (the server's matte.available is false): "Coming soon".
                "matte_soon").map { arrayOf<Any>(t, it) }
        }

        /** The design's project: four takes (3.0 / 4.2 / 5.2 / 5.6 s), captions, a hook, music with beats, a voice-over. */
        fun sampleProject(): EditProject {
            val base = EditSuiteViewModel.newProject("take_1", 18.0, SourceSize(1080, 1920, 30.0, true))
            val cuts = listOf(0.0, 3.0, 7.2, 12.4, 18.0)
            val clips = (0 until 4).map { i ->
                VideoClip("c${i + 1}", "src", cuts[i], cuts[i + 1], 1.0,
                    transitionIn = if (i == 1) Transition(TransitionKind.WHIP, .3) else if (i == 3) Transition(TransitionKind.FADE, .4) else null)
            }
            var p = base.copy(tracks = listOf(base.main.copy(items = clips)))
            val words = FakeEditorResults.words(18.0).map { (w, s, e) -> CaptionWord(w, s, e) }
            p = SuiteOps.withCaptions(p, "src", words)
            p = p.copy(assets = p.assets + Asset("music1", AssetKind.AUDIO, upload = "up_music", durationSec = 40.0) + Asset("vo1", AssetKind.AUDIO, upload = "up_vo", durationSec = 16.0))
            val beats = generateSequence(0.21) { it + 60.0 / 118 }.takeWhile { it < 18 }.map { Math.round(it * 1000) / 1000.0 }.toList()
            p = p.copy(tracks = p.tracks + Track("music", TrackKind.MUSIC, items = listOf(AudioClip("m1", "music1", 0.0, 0.0, 18.0, beats = beats, strongBeats = beats.filterIndexed { i, _ -> i % 4 == 0 })))
                + Track("voice", TrackKind.VOICE, items = listOf(AudioClip("v1", "vo1", 0.4, 0.0, 15.0))))
            val hook = Presets.hook("hook-box")!!
            p = p.copy(tracks = p.tracks + Track("text", TrackKind.TEXT, items = listOf(hook.toItem("t1", 0.0, "3 things I wish I knew before my first café shoot").copy(durationSec = 6.0))))
            check(problemOf(p) == null) { problemOf(p)!!.message!! }
            return p
        }
    }

    @get:Rule val compose = createComposeRule()

    /** Stand-in frames: soft colour bands, so the strip reads like video frames. */
    private fun frames(): Map<String, List<ImageBitmap>> = mapOf("src" to List(12) { i ->
        val b = Bitmap.createBitmap(32, 52, Bitmap.Config.ARGB_8888)
        b.eraseColor(android.graphics.Color.HSVToColor(floatArrayOf(200f + i * 12f, .45f, .35f + (i % 4) * .1f)))
        b.asImageBitmap()
    })

    /** The 32 looks rendered on a stand-in frame by the real CPU renderer. */
    private fun thumbs(): Map<String, ImageBitmap> {
        val w = 72; val h = 48
        val frame = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        for (y in 0 until h) for (x in 0 until w) {
            val r = (60 + 150 * x / w); val g = (70 + 90 * y / h); val bl = (120 + 100 * (w - x) / w)
            frame.setPixel(x, y, android.graphics.Color.rgb(r.coerceAtMost(255), g, bl.coerceAtMost(255)))
        }
        val lib = LookLibrary(ApplicationProvider.getApplicationContext())
        return runBlocking { LookThumbnails.renderPack(frame, lib, heightPx = 48, dispatcher = kotlinx.coroutines.Dispatchers.Unconfined) }.mapValues { it.value.asImageBitmap() }
    }

    @Test fun capture() {
        if (state == "editor_360") org.robolectric.RuntimeEnvironment.setQualifiers("w360dp-h780dp-xhdpi")
        if (state == "tablet" || state == "tablet_captions" || state == "tablet_collapsed" || state == "tablet_keep") org.robolectric.RuntimeEnvironment.setQualifiers("w1280dp-h800dp-mdpi")
        if (state == "tablet_portrait") org.robolectric.RuntimeEnvironment.setQualifiers("w800dp-h1280dp-mdpi")
        var p = sampleProject()
        val lib = LookLibrary(ApplicationProvider.getApplicationContext())
        val looks = lib.pack.looks.map { LookChoice(it.id, it.name, it.category) }
        var ui = EditSuiteUi(
            title = "Morning café", sourceTakeId = "take_1", poster = ImageRef.asset("g_front"), project = p, playheadSec = 6.6, canUndo = true,
            phase = SuitePhase.Ready, export = ExportSettings.forProject(p), bpm = 118.0, looks = looks,
            takes = listOf(TakeChoice("t2", "Counter", "Edit", ImageRef.asset("c_front"), 4.2, false, true)),
        )
        var host = SuiteHost()
        when (state) {
            "captions" -> ui = ui.copy(panel = Panel.CAPTIONS, ai = mapOf("silences" to AiTask("silences", price = "Free")))
            "audio" -> {
                p = SuiteOps.duck(p, true)!!
                ui = ui.copy(project = p, panel = Panel.AUDIO, ai = mapOf("denoise" to AiTask("denoise", price = "about $0.02")))
            }
            "speed" -> {
                p = SuiteOps.setCurve(p, "c2", SpeedCurve(SpeedPreset.HERO, SPEED_PRESETS.getValue(SpeedPreset.HERO)))!!
                ui = ui.copy(project = p, panel = Panel.SPEED, selectedId = "c2", speedCurveTab = true)
            }
            "looks" -> {
                p = SuiteOps.setLook(p, listOf("c2"), lib.pack.packLook("cine-teal-orange")!!.copy(strength = .7))!!
                ui = ui.copy(project = p, panel = Panel.FILTERS, selectedId = "c2")
                host = host.copy(lookThumbs = thumbs())
            }
            "export" -> ui = ui.copy(panel = Panel.EXPORT)
            "editor", "editor_360", "tablet", "tablet_portrait" -> ui = ui.copy(selectedId = "c2")
            "tablet_captions" -> ui = ui.copy(panel = Panel.CAPTIONS, ai = mapOf("silences" to AiTask("silences", price = "Free")))
            "tablet_collapsed" -> ui = ui.copy(selectedId = "c2", inspectorHidden = true)
            "matte_soon" -> ui = ui.copy(panel = Panel.EFFECTS, effectsTab = "Mask", selectedId = "c2", matteOff = "Coming soon")
            "keep", "tablet_keep" -> ui = ui.copy(panel = Panel.EFFECTS, effectsTab = "Mask", selectedId = "c2",
                keep = KeepUi(listOf(KeepTap(.48, .34, 6.6), KeepTap(.52, .62, 6.6), KeepTap(.84, .5, 6.6, keep = false))),
                ai = mapOf("matte" to AiTask("matte", price = "about $0.03"), "matte_keep" to AiTask("matte_keep", price = "about $0.04")))
        }
        compose.setContent {
            MuseTheme(ThemeId.fromKey(theme)) {
                if (state == "home") EditHomeContent(
                    listOf(
                        TakeChoice("e1", "Morning café", "Edited", ImageRef.asset("g_front"), 18.0, true, true),
                        TakeChoice("t1", "Morning café", "HD", ImageRef.asset("g_tq"), 18.4, false, true),
                        TakeChoice("t2", "Bathroom trend", "Edit", ImageRef.asset("c_front"), 9.6, false, true),
                        TakeChoice("t3", "Living-room dance", "Edit", ImageRef.asset("g_side"), 7.0, false, false),
                    ), onBack = {}, onOpen = {},
                )
                else EditSuiteContent(ui, frames(), host, act = {}, onClose = {}) { mod -> RefImage(ui.poster, mod, 30) }
            }
        }
        shadowOf(Looper.getMainLooper()).idle()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/edit_${theme}_$state.png")
    }
}

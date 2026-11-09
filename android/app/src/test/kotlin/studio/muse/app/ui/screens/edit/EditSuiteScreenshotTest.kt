package studio.muse.app.ui.screens.edit

import android.graphics.Bitmap
import android.os.Looper
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.background
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
                "matte_soon",
                // The owner's report (2026-11-08): one 15 s 9:16 take — the start state, a split with the second clip
                // selected (trim handles), and its sound detached to its own lane.
                "take_start", "take_split", "take_detached",
                // Wave 1 (plans/edit-parity.md): text style editor, transform with mirror and opacity, ratio with the
                // blur fill, and a timeline with a freeze frame and a selected text item.
                "w1_text", "w1_transform", "w1_ratio", "w1_timeline",
                // S rows: GIF and sound-only export; the overlay panel with "Add a video from a link".
                "export_gif", "export_sound", "overlay_link",
                // M rows: a top-and-bottom split screen with the overlay panel open.
                "m_split", "m_curves", "m_kits", "m_caption_lang", "d_pick", "m_adjust_layer", "m_own_font", "m_hsl", "m_reverse").map { arrayOf<Any>(t, it) }
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

    /** Stand-in sound levels (speech-like bursts), so the sound lanes show real-looking waveforms from [Peaks]. */
    private fun waves(): Map<String, Peaks> = listOf("src" to 1, "music1" to 2, "vo1" to 3).associate { (id, seed) ->
        id to Peaks(50f, FloatArray(50 * 40) { i ->
            val t = i / 50.0
            val env = (0.35 + 0.65 * kotlin.math.abs(kotlin.math.sin(t * (1.3 + seed * .4)))).toFloat()
            val n = (((i * 1103515245 + seed * 12345) ushr 8) and 1023) / 1023f
            (env * (0.25f + 0.75f * n)).coerceIn(0f, 1f)
        })
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
        var host = SuiteHost(waves = waves())
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
            "export_gif" -> ui = ui.copy(panel = Panel.EXPORT, export = ui.export.copy(format = studio.muse.core.edit.ExportFormat.GIF))
            "export_sound" -> ui = ui.copy(panel = Panel.EXPORT, export = ui.export.copy(format = studio.muse.core.edit.ExportFormat.SOUND))
            "overlay_link" -> { ui = ui.copy(panel = Panel.OVERLAY); host = host.copy(importLink = {}) }
            "w1_text", "w1_transform", "w1_ratio", "w1_timeline" -> {
                val one = EditSuiteViewModel.newProject("take_1", 15.0, SourceSize(1080, 1920, 30.0, true))
                val c = EditSuiteController(kotlinx.coroutines.MainScope(), object : EditBackend {
                    override suspend fun estimate(kind: String, source: studio.muse.app.data.EditorSourceDto, options: kotlinx.serialization.json.JsonObject?) = null to "off"
                    override suspend fun run(kind: String, source: studio.muse.app.data.EditorSourceDto, options: kotlinx.serialization.json.JsonObject?, onProgress: (studio.muse.app.data.EditorJob) -> Unit) = null to "off"
                }, ui.copy(project = one, playheadSec = 0.0, selectedId = null))
                c.act(EditAction.Scrub(4.0, end = true)); c.act(EditAction.Freeze(1.5))
                c.act(EditAction.Scrub(1.0, end = true)); c.act(EditAction.AddText)
                val tid = c.ui.value.selectedId!!
                val st = (c.project!!.tracks.first { it.kind == TrackKind.TEXT }.items.single() as studio.muse.core.edit.TextItem).style
                c.act(EditAction.EditText(tid, "Day one in Lisbon"))
                c.act(EditAction.SetTextStyle(tid, st.copy(stroke = studio.muse.core.edit.Stroke("#000000", .08), uppercase = true)))
                when (state) {
                    "w1_text" -> c.act(EditAction.Open(Panel.TEXT))
                    "w1_transform" -> { c.act(EditAction.Select(c.project!!.mainClips[0].id)); c.act(EditAction.Mirror(x = true)); c.act(EditAction.SetOpacity(.8)); c.act(EditAction.Open(Panel.TRANSFORM)) }
                    "w1_ratio" -> { c.act(EditAction.Select(c.project!!.mainClips[0].id)); c.act(EditAction.ClipFit(studio.muse.core.edit.Fit.CONTAIN)); c.act(EditAction.Fill(studio.muse.core.edit.CanvasFill.BLUR)); c.act(EditAction.Open(Panel.RATIO)) }
                    else -> c.act(EditAction.Scrub(2.0, end = true))
                }
                ui = c.ui.value.copy(message = null)
            }
            "d_pick" -> {
                // The eyedropper mid-drag over a green frame: the loupe, its hex, and the chroma controls below.
                val one = EditSuiteViewModel.newProject("take_1", 15.0, SourceSize(1080, 1920, 30.0, true))
                val c = EditSuiteController(kotlinx.coroutines.MainScope(), object : EditBackend {
                    override suspend fun estimate(kind: String, source: studio.muse.app.data.EditorSourceDto, options: kotlinx.serialization.json.JsonObject?) = null to "off"
                    override suspend fun run(kind: String, source: studio.muse.app.data.EditorSourceDto, options: kotlinx.serialization.json.JsonObject?, onProgress: (studio.muse.app.data.EditorJob) -> Unit) = null to "off"
                }, ui.copy(project = one, playheadSec = 2.0, selectedId = null))
                c.act(EditAction.Select(one.mainClips[0].id)); c.act(EditAction.SetChroma(studio.muse.core.edit.Chroma("#2BD15F", .4, .08, .5)))
                c.act(EditAction.Open(Panel.EFFECTS)); c.act(EditAction.EffectsTab("Mask")); c.act(EditAction.PickColor(true))
                c.act(EditAction.PickFrame(90, 160, IntArray(90 * 160) { i -> val x = i % 90; val y = i / 90; if ((x - 45) * (x - 45) + (y - 70) * (y - 70) < 500) 0xFFD9A07A.toInt() else 0xFF31C65E.toInt() + ((x + y) % 7) * 0x000100 }))
                c.act(EditAction.PickAt(.3, .55, done = false))
                ui = c.ui.value.copy(message = null)
            }
            "m_reverse" -> {
                // The reversed copy already in the edit: the toggle swaps to it.
                val one = EditSuiteViewModel.newProject("take_1", 15.0, SourceSize(1080, 1920, 30.0, true)).let { o ->
                    o.copy(assets = o.assets + o.assets.first().copy(id = "src_rev", take = null, upload = "up_rev", reverseOf = o.assets.first().id))
                }
                val c = EditSuiteController(kotlinx.coroutines.MainScope(), object : EditBackend {
                    override suspend fun estimate(kind: String, source: studio.muse.app.data.EditorSourceDto, options: kotlinx.serialization.json.JsonObject?) = null to "off"
                    override suspend fun run(kind: String, source: studio.muse.app.data.EditorSourceDto, options: kotlinx.serialization.json.JsonObject?, onProgress: (studio.muse.app.data.EditorJob) -> Unit) = null to "off"
                }, ui.copy(project = one, playheadSec = 1.0, selectedId = null))
                c.act(EditAction.Select(one.mainClips[0].id)); c.act(EditAction.Reverse(true)); c.act(EditAction.Speed(1.5))
                c.act(EditAction.Open(Panel.SPEED))
                ui = c.ui.value.copy(message = null)
            }
            "m_hsl" -> {
                val one = EditSuiteViewModel.newProject("take_1", 15.0, SourceSize(1080, 1920, 30.0, true))
                val c = EditSuiteController(kotlinx.coroutines.MainScope(), object : EditBackend {
                    override suspend fun estimate(kind: String, source: studio.muse.app.data.EditorSourceDto, options: kotlinx.serialization.json.JsonObject?) = null to "off"
                    override suspend fun run(kind: String, source: studio.muse.app.data.EditorSourceDto, options: kotlinx.serialization.json.JsonObject?, onProgress: (studio.muse.app.data.EditorJob) -> Unit) = null to "off"
                }, ui.copy(project = one, playheadSec = 0.0, selectedId = null))
                c.act(EditAction.Select(one.mainClips[0].id))
                c.act(EditAction.SetHsl(studio.muse.core.edit.HueBand.RED, "sat", -.3)); c.act(EditAction.SetHsl(studio.muse.core.edit.HueBand.RED, "light", .2))
                c.act(EditAction.SetHsl(studio.muse.core.edit.HueBand.BLUE, "hue", .4))
                c.act(EditAction.Open(Panel.FILTERS))
                ui = c.ui.value.copy(message = null, filtersTab = "Adjust")
            }
            "m_own_font" -> {
                val one = EditSuiteViewModel.newProject("take_1", 15.0, SourceSize(1080, 1920, 30.0, true))
                val c = EditSuiteController(kotlinx.coroutines.MainScope(), object : EditBackend {
                    override suspend fun estimate(kind: String, source: studio.muse.app.data.EditorSourceDto, options: kotlinx.serialization.json.JsonObject?) = null to "off"
                    override suspend fun run(kind: String, source: studio.muse.app.data.EditorSourceDto, options: kotlinx.serialization.json.JsonObject?, onProgress: (studio.muse.app.data.EditorJob) -> Unit) = null to "off"
                }, ui.copy(project = one, playheadSec = 0.0, selectedId = null))
                c.act(EditAction.Scrub(1.0, end = true)); c.act(EditAction.AddText)
                c.act(EditAction.EditText(c.ui.value.selectedId!!, "Day one in Lisbon"))
                studio.muse.app.platform.edit.OwnFonts.register("up_font_1", java.io.File("../../server/api/assets/fonts/instrument_serif_400.ttf"))
                c.act(EditAction.AddFont("up_font_1", "Instrument Serif Regular"))
                c.act(EditAction.Open(Panel.TEXT))
                ui = c.ui.value.copy(message = null)
                host = host.copy(addFont = {})
            }
            "m_adjust_layer" -> {
                val one = EditSuiteViewModel.newProject("take_1", 15.0, SourceSize(1080, 1920, 30.0, true))
                val c = EditSuiteController(kotlinx.coroutines.MainScope(), object : EditBackend {
                    override suspend fun estimate(kind: String, source: studio.muse.app.data.EditorSourceDto, options: kotlinx.serialization.json.JsonObject?) = null to "off"
                    override suspend fun run(kind: String, source: studio.muse.app.data.EditorSourceDto, options: kotlinx.serialization.json.JsonObject?, onProgress: (studio.muse.app.data.EditorJob) -> Unit) = null to "off"
                }, ui.copy(project = one, playheadSec = 0.0, selectedId = null))
                c.act(EditAction.Scrub(3.0, end = true)); c.act(EditAction.AddAdjustLayer)
                c.act(EditAction.LayerFilter("warm", .8)); c.act(EditAction.LayerField("contrast", .2)); c.act(EditAction.LayerField("saturation", -.3))
                c.act(EditAction.Scrub(3.5, end = true)); c.act(EditAction.AddKeyframe(studio.muse.core.edit.KfProp.OPACITY))
                ui = c.ui.value.copy(message = null)
            }
            "m_caption_lang" -> {
                val one = EditSuiteViewModel.newProject("take_1", 15.0, SourceSize(1080, 1920, 30.0, true))
                ui = ui.copy(project = one, panel = Panel.CAPTIONS, captionLanguage = "es", selectedId = null)
            }
            "m_kits" -> ui = ui.copy(panel = Panel.EDIT, kits = listOf(
                KitChoice("k1", "Warm vlog", studio.muse.core.edit.StyleKit(look = studio.muse.core.edit.Look(lut = "pack:film-gold"), adjust = studio.muse.core.edit.Adjust(contrast = .1), transition = studio.muse.core.edit.Transition(studio.muse.core.edit.TransitionKind.FADE, .4), captionStyle = studio.muse.core.edit.Presets.CAPTION_STYLES.values.first())),
                KitChoice("k2", "Clean product", studio.muse.core.edit.StyleKit(textStyle = studio.muse.core.edit.Presets.HOOKS[1].style, background = "#FFFFFF")),
            ))
            "m_curves" -> {
                val one = EditSuiteViewModel.newProject("take_1", 15.0, SourceSize(1080, 1920, 30.0, true))
                val c = EditSuiteController(kotlinx.coroutines.MainScope(), object : EditBackend {
                    override suspend fun estimate(kind: String, source: studio.muse.app.data.EditorSourceDto, options: kotlinx.serialization.json.JsonObject?) = null to "off"
                    override suspend fun run(kind: String, source: studio.muse.app.data.EditorSourceDto, options: kotlinx.serialization.json.JsonObject?, onProgress: (studio.muse.app.data.EditorJob) -> Unit) = null to "off"
                }, ui.copy(project = one, playheadSec = 0.0, selectedId = null))
                c.act(EditAction.SetCurve(studio.muse.core.edit.CurveChannel.RGB, listOf(studio.muse.core.edit.CurvePoint(0.0, 0.06), studio.muse.core.edit.CurvePoint(0.3, 0.24), studio.muse.core.edit.CurvePoint(0.72, 0.8), studio.muse.core.edit.CurvePoint(1.0, 0.96))))
                c.act(EditAction.Open(Panel.FILTERS))
                ui = c.ui.value.copy(message = null, filtersTab = "Adjust")
            }
            "m_split" -> {
                val one = EditSuiteViewModel.newProject("take_1", 15.0, SourceSize(1080, 1920, 30.0, true))
                val c = EditSuiteController(kotlinx.coroutines.MainScope(), object : EditBackend {
                    override suspend fun estimate(kind: String, source: studio.muse.app.data.EditorSourceDto, options: kotlinx.serialization.json.JsonObject?) = null to "off"
                    override suspend fun run(kind: String, source: studio.muse.app.data.EditorSourceDto, options: kotlinx.serialization.json.JsonObject?, onProgress: (studio.muse.app.data.EditorJob) -> Unit) = null to "off"
                }, ui.copy(project = one, playheadSec = 0.0, selectedId = null))
                c.act(EditAction.Scrub(2.0, end = true)); c.act(EditAction.AddPip(ui.takes.first()))
                c.act(EditAction.SplitScreen(SuiteOps.SplitLayout.TOP_BOTTOM)); c.act(EditAction.Open(Panel.OVERLAY))
                ui = c.ui.value.copy(message = null)
            }
            "take_start", "take_split", "take_detached" -> {
                val one = EditSuiteViewModel.newProject("take_1", 15.0, SourceSize(1080, 1920, 30.0, true))
                ui = ui.copy(project = one, playheadSec = 0.0, canUndo = false, selectedId = null)
                if (state != "take_start") {
                    val c = EditSuiteController(kotlinx.coroutines.MainScope(), object : EditBackend {
                        override suspend fun estimate(kind: String, source: studio.muse.app.data.EditorSourceDto, options: kotlinx.serialization.json.JsonObject?) = null to "off"
                        override suspend fun run(kind: String, source: studio.muse.app.data.EditorSourceDto, options: kotlinx.serialization.json.JsonObject?, onProgress: (studio.muse.app.data.EditorJob) -> Unit) = null to "off"
                    }, ui)
                    c.act(EditAction.Scrub(6.0, end = true)); c.act(EditAction.Split)
                    c.act(EditAction.Select(c.project!!.mainClips[1].id))
                    if (state == "take_detached") { c.act(EditAction.Scrub(8.0, end = true)); c.act(EditAction.DetachAudio) }
                    ui = c.ui.value.copy(message = null)
                }
            }
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
                else if (state == "m_kits") androidx.compose.foundation.layout.Column(androidx.compose.ui.Modifier.fillMaxSize().background(studio.muse.app.ui.theme.muse.t.bg).padding(16.dp),
                    verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(12.dp)) {
                    // The kits section on its own (it closes the Edit panel, below the fold in the phone sheet).
                    KitsSection(ui, host) {}
                }
                else if (state == "m_curves") androidx.compose.foundation.layout.Box(androidx.compose.ui.Modifier.fillMaxSize().background(studio.muse.app.ui.theme.muse.t.bg).padding(16.dp)) {
                    // The curves editor on its own (in the phone sheet it sits below the fold).
                    CurvesEditor(ui.project!!.mainClips[0].look?.curves, true) {}
                }
                else if (state == "m_hsl") androidx.compose.foundation.layout.Box(androidx.compose.ui.Modifier.fillMaxSize().background(studio.muse.app.ui.theme.muse.t.bg).padding(16.dp)) {
                    // The HSL section on its own (in the phone sheet it sits below the fold), on the red band.
                    androidx.compose.foundation.layout.Column(verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(12.dp)) {
                        HslSection(ui.project!!.mainClips[0].look?.hsl, true) {}
                    }
                }
                else EditSuiteContent(ui, frames(), host, act = {}, onClose = {}) { mod -> RefImage(ui.poster, mod, 30) }
            }
        }
        shadowOf(Looper.getMainLooper()).idle()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/edit_${theme}_$state.png")
    }
}

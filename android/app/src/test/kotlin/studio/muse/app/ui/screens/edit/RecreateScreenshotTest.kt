package studio.muse.app.ui.screens.edit

import android.os.Looper
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import com.github.takahirom.roborazzi.captureRoboImage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.ui.theme.MuseTheme
import studio.muse.app.ui.theme.ThemeId

/**
 * Recreate phases 2–3, built: Recipe with the total beside Build, the one confirmation, the shots generating, Compare,
 * and "Use one of my takes", on a phone and a tablet in all four themes. The states come from demo mode's fake run
 * through [RecreateBuildModel] (nothing spent). PNGs: app/build/outputs/roborazzi/recreate_<theme>_<state>.png.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class RecreateScreenshotTest(private val theme: String, private val state: String) {
    companion object {
        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}_{1}")
        fun params(): List<Array<Any>> = listOf("a", "b", "c", "d").flatMap { t ->
            listOf("recipe", "confirm", "generating", "waiting", "compare", "picker", "recipe_tablet", "confirm_tablet", "generating_tablet", "waiting_tablet", "compare_tablet", "export", "export_saved", "own_setting_tablet", "confirm_picked", "briefs_tablet", "briefs_confirm").map { arrayOf<Any>(t, it) }
        }
    }

    @get:Rule val compose = createComposeRule()
    init { compose.mainClock.autoAdvance = false } // the indeterminate progress animates forever

    private fun ui(): RecreateBuildUi = runBlocking {
        val scope = MainScope(); val work = CoroutineScope(Dispatchers.Default)
        try {
            val api = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
            var ref = api.createReference("up_1", "Café morning")
            while (ref.state == "analyzing") ref = api.reference(ref.id)
            val takes = api.listTakes().filter { it.kind == "take" }.map { RecreateTakeChoice(it.id, it.title, it.durationSec, it.thumb, label = it.label) }
            val model = RecreateBuildModel(api, work, RecreateBuildUi(ref.id, ref.recipe!!, "Café morning", takes = takes, kept = ref.keptLine(),
                cast = api.listModels().map { RecreateCastChoice(it.id, it.name) }, castId = api.listModels().firstOrNull()?.id), defaultModelId = { "m_demo" }, pollMs = 60_000)
            model.load()
            model.select(1)
            val base = model.ui.value
            when (state.removeSuffix("_tablet")) {
                "confirm" -> { model.requestBuild(); model.ui.value }
                // Pick which shots to make: one unticked, the total follows.
                "confirm_picked" -> { model.requestBuild(); model.toggleConfirmShot(model.ui.value.confirmSlots!!.last()); model.ui.value }
                // Use your own setting on the first shot to make: the location chips and the background's price.
                "own_setting" -> {
                    api.createSuiteLocation(studio.muse.app.data.SuiteLocationCreate("Café counter", studio.muse.app.data.ImageRef.asset("g_tq")))
                    val first = base.toGenerate.first()
                    model.select(base.slots.indexOfFirst { it.id == first }); model.setKeepBackground(first, false); model.ui.value
                }
                // Confirmed: the new shots are generating; the edit is built when they're ready.
                // Shot 2's job reports 42% (the studio's live jobs); "waiting": its job isn't listed, a calm indeterminate state.
                "generating", "waiting" -> base.copy(buildWhenReady = true, building = true, jobProgress = if (state.startsWith("generating")) mapOf("job_rx_s2" to 42) else emptyMap(),
                    fill = base.fill!!.copy(slots = base.fill!!.slots.map { if (it.state == "to_generate") it.copy(state = "generating", jobId = "job_rx_${it.slotId}") else it }))
                "compare", "export", "export_saved" -> {
                    val f = base.fill!!.copy(slots = base.fill!!.slots.map { if (it.state == "to_generate") it.copy(state = "ready", jobId = "job_rx_${it.slotId}") else it })
                    val r = api.applyRecipe(ref.id, "es_demo", 0, f.slots.associate { it.slotId to (it.jobId ?: it.takeId!!) })
                    base.copy(fill = f, match = r.match, mode = RecreateMode.Compare, builtTakeId = takes.firstOrNull()?.id,
                        export = when (state) {
                            "export" -> RecreateExportUi(guide = true, progress = .4f)
                            // The server's export, saved, with its reminder to post with the original sound.
                            "export_saved" -> RecreateExportUi(saved = "Saved to this phone, in Movies/MUSE", useThisSound = studio.muse.core.edit.RecreateUseSound("tiktok", "Post with the original sound",
                                listOf("Open the original on TikTok", "Tap the sound, then Use this sound", "Add this video and line it up at the start"),
                                "The guide sound is only for timing. Post with the platform's own sound so it counts toward the trend."))
                            else -> null
                        })
                }
                "briefs", "briefs_confirm" -> base.copy(briefs = studio.muse.core.edit.RecreateBriefsEstimate(true, slots = 7, estimateUsd = .02, label = "Write the shot briefs · about $0.02"),
                    askBriefs = state == "briefs_confirm")
                else -> base
            }
        } finally { scope.cancel(); work.cancel() }
    }

    @Test fun capture() {
        if (state.endsWith("_tablet")) RuntimeEnvironment.setQualifiers("w1280dp-h800dp-mdpi")
        val ui = ui()
        compose.setContent {
            MuseTheme(ThemeId.fromKey(theme)) {
                RecreateBuildScreen(ui, RecreateActions(onClaude = {}), picking = if (state == "picker") "s2" else null)
            }
        }
        shadowOf(Looper.getMainLooper()).idle()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/recreate_${theme}_${if (state == "compare") "compare_phone" else state}.png")
    }
}

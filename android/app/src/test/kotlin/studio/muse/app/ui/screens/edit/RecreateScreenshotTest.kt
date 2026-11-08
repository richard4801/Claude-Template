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
            listOf("recipe", "confirm", "generating", "waiting", "compare", "picker", "recipe_tablet", "confirm_tablet", "generating_tablet", "waiting_tablet", "compare_tablet", "export").map { arrayOf<Any>(t, it) }
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
            val takes = api.listTakes().filter { it.kind == "take" }.map { RecreateTakeChoice(it.id, it.title, it.durationSec, label = it.label) }
            val model = RecreateBuildModel(api, work, RecreateBuildUi(ref.id, ref.recipe!!, "Café morning", takes = takes, kept = ref.keptLine(),
                cast = api.listModels().map { RecreateCastChoice(it.id, it.name) }, castId = api.listModels().firstOrNull()?.id), defaultModelId = { "m_demo" }, pollMs = 60_000)
            model.load()
            model.select(1)
            val base = model.ui.value
            when (state.removeSuffix("_tablet")) {
                "confirm" -> { model.requestBuild(); model.ui.value }
                // Confirmed: the new shots are generating; the edit is built when they're ready.
                // Shot 2's job reports 42% (the studio's live jobs); "waiting": its job isn't listed, a calm indeterminate state.
                "generating", "waiting" -> base.copy(buildWhenReady = true, building = true, jobProgress = if (state.startsWith("generating")) mapOf("job_rx_s2" to 42) else emptyMap(),
                    fill = base.fill!!.copy(slots = base.fill!!.slots.map { if (it.state == "to_generate") it.copy(state = "generating", jobId = "job_rx_${it.slotId}") else it }))
                "compare", "export" -> {
                    val f = base.fill!!.copy(slots = base.fill!!.slots.map { if (it.state == "to_generate") it.copy(state = "ready", jobId = "job_rx_${it.slotId}") else it })
                    val r = api.applyRecipe(ref.id, "es_demo", 0, f.slots.associate { it.slotId to (it.jobId ?: it.takeId!!) })
                    base.copy(fill = f, match = r.match, mode = RecreateMode.Compare, builtTakeId = takes.firstOrNull()?.id,
                        export = if (state == "export") RecreateExportUi(guide = true, progress = .4f) else null)
                }
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

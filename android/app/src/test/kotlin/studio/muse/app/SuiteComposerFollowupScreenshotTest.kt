package studio.muse.app

import android.os.Looper
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import com.github.takahirom.roborazzi.captureRoboImage
import kotlinx.coroutines.MainScope
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import studio.muse.app.data.AppPrefs
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.ImageRef
import studio.muse.app.data.MemoryPrefs
import studio.muse.app.data.SampleData
import studio.muse.app.ui.MuseApp
import studio.muse.app.ui.Routes
import studio.muse.app.ui.screens.suite.RecastDraft
import studio.muse.app.ui.screens.suite.RecastPerson
import studio.muse.app.ui.screens.suite.composer.ComposerDraft
import studio.muse.app.ui.screens.suite.composer.ComposerSettings
import studio.muse.app.ui.screens.suite.composer.ComposerSheet
import studio.muse.app.ui.screens.suite.composer.ComposerTool
import studio.muse.app.ui.screens.suite.composer.PromptTokens
import studio.muse.app.ui.screens.suite.composer.SheetKind

/**
 * The composer's follow-ups in all four themes at 360, 390 and 840 dp: Recast's tap-a-face picker, Character swap with
 * its add-on pills, Style with the era slider, UGC ad's format wheel, the @ menu with locations, and the owner's Settings
 * with the engine row. Pickers are always dark. Demo mode, the demo studio's own models.
 * PNGs: app/build/outputs/roborazzi/suite_followup_<theme>_<screen>_<width>.png.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class SuiteComposerFollowupScreenshotTest(private val theme: String, private val screen: String, private val width: Int) {
    companion object {
        val SCREENS = listOf("faces", "swap_addons", "style_era", "ugc_format", "at_locations", "settings_engine")

        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}_{1}_{2}")
        fun params(): List<Array<Any>> = listOf("a", "b", "c", "d").flatMap { t -> SCREENS.flatMap { s -> listOf(360, 390, 840).map { w -> arrayOf<Any>(t, s, w) } } }
    }

    @get:Rule val compose = createComposeRule()

    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    @Test fun capture() {
        when (width) {
            360 -> RuntimeEnvironment.setQualifiers("w360dp-h740dp-xhdpi")
            840 -> RuntimeEnvironment.setQualifiers("w840dp-h1180dp-mdpi")
        }
        val scope = MainScope()
        val fake = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
        val c = AppContainer(scope, MemoryPrefs(AppPrefs(theme = theme, useFake = true, token = "t", studioName = "Jenne Studio", role = "owner", email = "jenne@studio.com")), fake, null)
        c.suite.newSwap.on.value = false // the classic Swap screen (New Swap has SuiteNewSwapScreenshotTest)
        val s = c.suite
        when (screen) {
            "faces" -> {
                s.composer.value = ComposerDraft(tool = ComposerTool.RECAST, quality = "standard")
                var r = RecastDraft(clipId = SampleData.SAMPLE_CLIP, people = listOf(RecastPerson("center", SampleData.DEMO)))
                r = r.tapFace(.5f, .4f, 4, 1).first.setCrop(1, ImageRef.asset("face"))
                r = r.tapFace(.15f, .7f, 4, 2).first.update(1) { it.copy(characterId = SampleData.NOOR) }
                s.recast.value = r
                s.sheet.value = ComposerSheet(SheetKind.PEOPLE)
            }
            "swap_addons" -> {
                s.composer.value = ComposerDraft(tool = ComposerTool.SWAP, modelId = SampleData.DEMO, outfitId = SampleData.GREEN, quality = "standard", addon = "edit")
                s.recast.value = RecastDraft(clipId = SampleData.SAMPLE_CLIP)
            }
            "style_era" -> {
                s.composer.value = ComposerDraft(modelId = SampleData.DEMO, settings = ComposerSettings(genre = "ugc", era = "1990s"))
                s.sheet.value = ComposerSheet(SheetKind.STYLE, "era")
            }
            "ugc_format" -> {
                s.composer.value = ComposerDraft(tool = ComposerTool.UGC, modelId = SampleData.DEMO, settings = ComposerSettings(format = "unboxing", tempo = "calm"))
                s.sheet.value = ComposerSheet(SheetKind.STYLE, "tempo")
            }
            "at_locations" -> {
                var t = PromptTokens().withText(" walks into the @")
                t = t.addMention("character", SampleData.DEMO, "Demo", t.caretAtEnd.copy(part = 0, offset = 0)).first
                s.composer.value = ComposerDraft(tokens = t, modelId = SampleData.DEMO, quality = "standard")
            }
            "settings_engine" -> {
                val tier = fake.suite.catalog(owner = true).tier("standard")!!
                s.composer.value = ComposerDraft(modelId = SampleData.DEMO, quality = "standard").pin(tier.models!!.first())
                s.sheet.value = ComposerSheet(SheetKind.SETTINGS)
            }
        }
        compose.mainClock.autoAdvance = false
        val route = when (screen) { "faces" -> Routes.suiteCompose("recast"); "swap_addons" -> Routes.SUITE_SWAP; "ugc_format" -> Routes.suiteCompose("ugc"); else -> Routes.SUITE_SHOT }
        compose.setContent { MuseApp(c, route) }
        repeat(8) { idle(); compose.mainClock.advanceTimeBy(400) }
        idle()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/suite_followup_${theme}_${screen}_$width.png")
    }
}

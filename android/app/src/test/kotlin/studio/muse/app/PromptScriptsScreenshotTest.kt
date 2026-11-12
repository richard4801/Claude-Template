package studio.muse.app

import android.os.Looper
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.semantics.SemanticsActions
import com.github.takahirom.roborazzi.captureRoboImage
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import studio.muse.app.data.AppPrefs
import studio.muse.app.data.Clip
import studio.muse.app.data.ClipAudio
import studio.muse.app.data.ClipMeta
import studio.muse.app.data.ClipRules
import studio.muse.app.data.FakeMuseApi
import studio.muse.app.data.MemoryPrefs
import studio.muse.app.data.SampleData
import studio.muse.app.data.VideoDraft
import studio.muse.app.ui.MuseApp
import studio.muse.app.ui.Routes

/**
 * Prompt scripts (plans/api.md "Prompt scripts") in all four themes: owner Settings → Prompts → Scripts, one script
 * (inputs, rules by place, blocks, preview), the rule form, and the video studio's "Performer is speaking" switch (on, off).
 * PNGs land in app/build/outputs/roborazzi/scripts_<theme>_<screen>.png.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class PromptScriptsScreenshotTest(private val theme: String, private val screen: String) {
    companion object {
        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}_{1}")
        fun params(): List<Array<Any>> = listOf("a", "b", "c", "d").flatMap { t ->
            listOf("scripts", "script", "rule", "direct_speaking", "direct_not_speaking").map { arrayOf<Any>(t, it) }
        }
    }

    @get:Rule val compose = createComposeRule()
    private fun idle() = shadowOf(Looper.getMainLooper()).idle()

    @Test fun capture() {
        val scope = MainScope()
        val fake = FakeMuseApi(scope, null, speed = 0.0, genDelayMs = 0)
        val c = AppContainer(scope, MemoryPrefs(AppPrefs(theme = theme, useFake = true, token = "t", studioName = "Jenne Studio", role = "owner", email = "jenne@studio.com")), fake, null)
        // One edited script (the not-speaking summary switched off) so the list shows an "Edited" badge.
        runBlocking {
            val s = fake.getPromptScript("video.edit")
            fake.savePromptScript(s.id, s.rules.map { if (!it.isLocked && it.target == "summary") it.copy(enabled = false) else it })
        }
        val checks = ClipRules.checks(ClipMeta("Talking to camera", 7.0, 1080, 1920, 30, talking = true))
        val clip = Clip("clip_talk", "Talking to camera", 7.0, 1080, 1920, 30, checks, audio = ClipAudio("speech", true, true))
        when (screen) {
            "scripts" -> c.drafts.promptsTab.value = "scripts"
            "direct_speaking" -> c.drafts.video.update { VideoDraft(tool = "audio").withClip(clip) }
            "direct_not_speaking" -> c.drafts.video.update {
                VideoDraft(tool = "audio").withClip(Clip(SampleData.SAMPLE_CLIP, "Living-room dance", 9.4, 1080, 1920, 30, ClipRules.checks(SampleData.sampleMeta), audio = ClipAudio("music", false, true)))
            }
        }
        val route = when (screen) { "scripts" -> Routes.PROMPTS; "script", "rule" -> Routes.SETTINGS; else -> Routes.DIRECT }
        val pending = if (screen == "script" || screen == "rule") Routes.promptScript("video.replicate") else null
        compose.mainClock.autoAdvance = false
        compose.setContent { MuseApp(c, route, pending) }
        repeat(6) { idle(); compose.mainClock.advanceTimeBy(400) }
        idle()
        if (screen == "rule") {
            // The row can sit below the fold; its click action works without scrolling (a scroll animates and the clock is manual).
            compose.onNodeWithText("Not speaking: no lip-sync").performSemanticsAction(SemanticsActions.OnClick)
            repeat(3) { idle(); compose.mainClock.advanceTimeBy(400) }
            compose.onNodeWithText("Reads as", substring = true, ignoreCase = true).assertExists()
        }
        if (screen == "script") check(compose.onAllNodesWithText("Performer is speaking", substring = true).fetchSemanticsNodes().isNotEmpty())
        if (screen == "direct_speaking") compose.onNodeWithText("She talks or sings: her lips follow the clip's sound").assertExists()
        if (screen == "direct_not_speaking") compose.onNodeWithText("Her mouth follows the clip; she won't lip-sync to the music").assertExists()
        repeat(2) { idle(); compose.mainClock.advanceTimeBy(400) }
        idle()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/scripts_${theme}_$screen.png")
    }
}

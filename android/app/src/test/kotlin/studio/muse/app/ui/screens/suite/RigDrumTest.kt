package studio.muse.app.ui.screens.suite

import androidx.compose.foundation.layout.width
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeDown
import androidx.compose.ui.test.swipeUp
import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import studio.muse.app.ui.screens.suite.composer.Preview
import studio.muse.app.ui.screens.suite.composer.PreviewDraw
import studio.muse.app.ui.screens.suite.composer.RigDrum
import studio.muse.app.ui.screens.suite.composer.WheelItem
import studio.muse.app.ui.theme.MuseTheme
import studio.muse.app.ui.theme.ThemeId

/** Workstream 4: the hardware drum turns on a swipe, lands on a detent and reports the item; TalkBack can set it. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class RigDrumTest {
    @get:Rule val compose = createComposeRule()

    private val items = listOf(WheelItem(null, "Auto", "Picks for the shot", Preview(draw = PreviewDraw.Auto))) +
        listOf(14, 24, 35, 50, 85, 135).map { WheelItem("$it", "$it mm", "", Preview(draw = PreviewDraw.Focal(it))) }

    private fun mount(start: Int, picked: MutableList<String?>) {
        compose.setContent {
            var sel by remember { mutableIntStateOf(start) }
            MuseTheme(ThemeId.fromKey("b")) {
                RigDrum("Focal", items, sel, { w -> picked += w.id; sel = items.indexOf(w) }, Modifier.width(120.dp))
            }
        }
    }

    @Test fun swipeUpTurnsToALaterItemAndCommitsOnce() {
        val picked = mutableListOf<String?>()
        mount(2, picked)
        compose.onNodeWithContentDescription("Focal").performTouchInput { swipeUp(startY = centerY + 60f, endY = centerY - 60f, durationMillis = 400) }
        compose.waitForIdle()
        assertEquals("one commit when the drum settles", 1, picked.size)
        assertTrue("moved forward from 24 mm: ${picked[0]}", (picked[0]?.toInt() ?: 0) > 24)
    }

    @Test fun talkBackCanSetTheDrum() {
        val picked = mutableListOf<String?>()
        mount(0, picked)
        compose.onNodeWithContentDescription("Focal").assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Auto, Picks for the shot"))
        compose.onNodeWithContentDescription("Focal").performSemanticsAction(SemanticsActions.SetProgress) { it(4f) }
        compose.waitForIdle()
        assertEquals(listOf<String?>("50"), picked)
    }

    @Test fun sevenItemsLoopSoTheFirstHasANeighbourAbove() {
        val picked = mutableListOf<String?>()
        mount(0, picked)
        compose.onNodeWithContentDescription("Focal").performTouchInput { swipeDown(startY = centerY - 50f, endY = centerY + 50f, durationMillis = 600) }
        compose.waitForIdle()
        assertEquals("from Auto, one step back is the last item", listOf<String?>("135"), picked)
    }
}

package studio.muse.app

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.dp
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import studio.muse.app.data.ImageRef
import studio.muse.app.data.SuiteInputs
import studio.muse.app.data.SuiteMediaRef
import studio.muse.app.ui.screens.suite.InputSlotTile
import studio.muse.app.ui.screens.suite.InputSlots
import studio.muse.app.ui.screens.suite.SlotId
import studio.muse.app.ui.screens.suite.SlotKind
import studio.muse.app.ui.screens.suite.SlotValue
import studio.muse.app.ui.theme.MuseTheme
import studio.muse.app.ui.theme.ThemeId
import studio.muse.app.ui.theme.muse

/**
 * The input slot tiles in all four themes at 390 and 360 dp: empty, filled image, uploading, failed, video and audio.
 * The grid here is only a test harness; screens lay the tiles out themselves.
 * PNGs: app/build/outputs/roborazzi/suite_<theme>_input_slots_<width>.png.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class SuiteInputSlotsScreenshotTest(private val theme: String, private val width: Int) {
    companion object {
        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}_{1}")
        fun params(): List<Array<Any>> = listOf("a", "b", "c", "d").flatMap { t -> listOf(390, 360).map { w -> arrayOf<Any>(t, w) } }
    }

    @get:Rule val compose = createComposeRule()

    @Test fun capture() {
        if (width == 360) RuntimeEnvironment.setQualifiers("w360dp-h740dp-xhdpi")
        val slots = InputSlots()
            .put(SlotId(SlotKind.START), SlotValue("front.jpg", image = ImageRef.asset("g_front")))
            .put(SlotId(SlotKind.IMAGE), SlotValue("bottle.jpg", image = ImageRef.asset("g_tq"), progress = .45f))
            .put(SlotId(SlotKind.IMAGE, 1), SlotValue("label.jpg", error = "That file is over 20 MB"))
            .put(SlotId(SlotKind.VIDEO), SlotValue("walk-in.mp4", media = SuiteMediaRef(key = "c/a.mp4")))
        val inputs = SuiteInputs(start = true, end = true, middle = 0, images = 6, videos = 3, audio = true, framesWithRefs = true)
        compose.setContent {
            MuseTheme(ThemeId.fromKey(theme)) {
                Box(Modifier.fillMaxSize().background(muse.t.bg).padding(16.dp)) {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        slots.visible(inputs).chunked(3).forEach { row ->
                            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                row.forEach { id -> InputSlotTile(id, slots[id], {}, {}, Modifier.weight(1f).aspectRatio(.8f)) }
                                repeat(3 - row.size) { Box(Modifier.weight(1f)) }
                            }
                        }
                    }
                }
            }
        }
        compose.waitForIdle()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/suite_${theme}_input_slots_$width.png")
    }
}

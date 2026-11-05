package studio.muse.app

import android.os.Looper
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import studio.muse.app.data.ImageRef
import studio.muse.app.data.Take
import studio.muse.app.ui.screens.EditVideoRow
import studio.muse.app.ui.screens.EditorPhase
import studio.muse.app.ui.screens.EditorUi
import studio.muse.app.ui.screens.VideoEditorContent
import studio.muse.app.ui.components.RefImage
import studio.muse.app.ui.theme.MuseTheme
import studio.muse.app.ui.theme.ThemeId
import studio.muse.core.VideoEdit

/**
 * The video editor (plans/video-editor.md) in all four themes: editing (split, a cut, a slow part, a muted part, the
 * trim handles moved), exporting on the phone, and the Edit row on a take's page.
 * PNGs land in app/build/outputs/roborazzi/editor_<theme>_<state>.png.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class VideoEditorScreenshotTest(private val theme: String, private val state: String) {
    companion object {
        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}_{1}")
        fun params(): List<Array<Any>> = listOf("a", "b", "c", "d").flatMap { t -> listOf("editing", "exporting", "untouched", "edit_row").map { arrayOf<Any>(t, it) } }
    }

    @get:Rule val compose = createComposeRule()

    /** Stand-in frames: soft colour bands, so the strip reads like video frames. */
    private fun frames(): List<ImageBitmap?> = List(10) { i ->
        val b = android.graphics.Bitmap.createBitmap(32, 56, android.graphics.Bitmap.Config.ARGB_8888)
        val hue = 20f + i * 9f
        b.eraseColor(android.graphics.Color.HSVToColor(floatArrayOf(hue, .35f, .55f + (i % 3) * .1f)))
        b.asImageBitmap()
    }

    @Test fun capture() {
        val edited = VideoEdit.untouched(9.6).trimStart(0.4)!!.split(3.0)!!.split(4.2)!!.delete(1)!!.split(6.5)!!
            .speed(1, 0.5)!!.muteSegment(2, true)!!.trimEnd(9.2)!!
        val ui = when (state) {
            "editing" -> EditorUi("Beach walk", ImageRef.asset("g_front"), edited, selected = 1, scopeAll = false, playheadSec = 5.1, canUndo = true, phase = EditorPhase.Ready)
            "exporting" -> EditorUi("Beach walk", ImageRef.asset("g_front"), edited, selected = 1, playheadSec = 0.4, canUndo = true, phase = EditorPhase.Exporting(.42f), reopened = true)
            else -> EditorUi("Beach walk", ImageRef.asset("g_front"), VideoEdit.untouched(9.6), selected = 0, playheadSec = 2.0, phase = EditorPhase.Ready)
        }
        compose.setContent {
            MuseTheme(ThemeId.fromKey(theme)) {
                if (state == "edit_row") {
                    Box(Modifier.fillMaxSize().background(studio.muse.app.ui.theme.muse.t.bg).padding(16.dp)) {
                        androidx.compose.foundation.layout.Column(Modifier.background(studio.muse.app.ui.theme.muse.t.bg), verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(12.dp)) {
                            val t = Take("t1", "take", "j1", 1, 1, "Beach walk", "HD", videoUrl = "https://x/a.mp4")
                            EditVideoRow(t, emptyList()) {}
                            EditVideoRow(t, listOf(t.copy(id = "v1", kind = "edit"), t.copy(id = "v2", kind = "edit"))) {}
                            EditVideoRow(t.copy(kind = "edit", parentTakeId = "t0"), emptyList()) {}
                        }
                    }
                } else VideoEditorContent(ui, frames(), onBack = {}, act = {}) { mod ->
                    Box(mod.background(Brush.verticalGradient(listOf(Color(0xFF3A4A5A), Color(0xFF1B2228))))) { RefImage(ui.poster, Modifier.matchParentSize(), 30) }
                }
            }
        }
        shadowOf(Looper.getMainLooper()).idle()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/editor_${theme}_$state.png")
    }

    private val Int.dp get() = androidx.compose.ui.unit.Dp(this.toFloat())
}

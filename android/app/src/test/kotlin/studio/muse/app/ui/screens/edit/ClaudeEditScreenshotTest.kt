package studio.muse.app.ui.screens.edit

import android.graphics.Bitmap
import android.os.Looper
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
import studio.muse.app.data.EditHistoryEntry
import studio.muse.app.data.EditPending
import studio.muse.app.data.ImageRef
import studio.muse.app.ui.components.RefImage
import studio.muse.app.ui.theme.MuseTheme
import studio.muse.app.ui.theme.ThemeId
import studio.muse.core.edit.ExportSettings

/**
 * Edit sessions (workstream 3): Claude in the owner's Edit suite, in all four themes — the history sheet with a
 * Claude-badged entry, the "Claude edited this" note, the confirmation sheet for a paid helper Claude asks for, and the
 * Claude panel (placeholder chat host). PNGs: app/build/outputs/roborazzi/edit_claude_<theme>_<state>.png.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-xhdpi")
class ClaudeEditScreenshotTest(private val theme: String, private val state: String) {
    companion object {
        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0}_{1}")
        fun params(): List<Array<Any>> = listOf("a", "b", "c", "d").flatMap { t ->
            listOf("history", "note", "pending", "panel").map { arrayOf<Any>(t, it) }
        }

        fun history(): List<EditHistoryEntry> = listOf(
            EditHistoryEntry(6, 5, "claude", true, "edit", "Trimmed 0:00.5–0:06.0", createdAt = 6),
            EditHistoryEntry(5, 4, "claude", true, "tool", "Looked at the frame at 0:02.0", createdAt = 5),
            EditHistoryEntry(4, 4, "app:android-1", false, "edit", "Split", createdAt = 4),
            EditHistoryEntry(3, 3, "claude", true, "edit", "Look · warm-honey 70 %", undone = true, createdAt = 3),
            EditHistoryEntry(2, 2, "app:android-1", false, "undo", "Undo: Look · warm-honey 70 %", undoes = 3, createdAt = 2),
            EditHistoryEntry(1, 1, "claude", true, "edit", "Added hook “3 things”", createdAt = 1),
        )
    }

    @get:Rule val compose = createComposeRule()

    private fun frames(): Map<String, List<ImageBitmap>> = mapOf("src" to List(12) { i ->
        val b = Bitmap.createBitmap(32, 52, Bitmap.Config.ARGB_8888)
        b.eraseColor(android.graphics.Color.HSVToColor(floatArrayOf(200f + i * 12f, .45f, .35f + (i % 4) * .1f)))
        b.asImageBitmap()
    })

    @Test fun capture() {
        val p = EditSuiteScreenshotTest.sampleProject()
        var session = SessionUi("es_1", 5, history())
        var ui = EditSuiteUi(
            title = "Morning café", sourceTakeId = "take_1", poster = ImageRef.asset("g_front"), project = p, playheadSec = 6.6, canUndo = true,
            phase = SuitePhase.Ready, export = ExportSettings.forProject(p), selectedId = "c2",
        )
        when (state) {
            "history" -> ui = ui.copy(panel = Panel.HISTORY)
            "note" -> session = session.copy(claudeNote = "Claude · Trimmed 0:00.5–0:06.0")
            "pending" -> session = session.copy(pending = listOf(EditPending("pa_1", "matte", "Remove background", 0.04)))
            "panel" -> session = session.copy(chatOpen = true)
        }
        ui = ui.copy(session = session)
        compose.setContent {
            MuseTheme(ThemeId.fromKey(theme)) {
                EditSuiteContent(ui, frames(), SuiteHost(), act = {}, onClose = {}) { mod -> RefImage(ui.poster, mod, 30) }
            }
        }
        shadowOf(Looper.getMainLooper()).idle()
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/edit_claude_${theme}_$state.png")
    }
}

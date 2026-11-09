package studio.muse.app.platform.edit

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.dp
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import studio.muse.app.ui.screens.edit.CaptionLine
import studio.muse.app.ui.theme.MuseTheme
import studio.muse.app.ui.theme.ThemeId
import studio.muse.core.edit.CaptionPreset
import studio.muse.core.edit.CaptionTrack
import studio.muse.core.edit.CaptionWord
import studio.muse.core.edit.EditListV1
import studio.muse.core.edit.Presets
import studio.muse.core.edit.SourceSize
import studio.muse.core.edit.Track
import studio.muse.core.edit.TrackKind
import studio.muse.core.edit.V1Segment
import studio.muse.core.edit.fromV1
import studio.muse.core.edit.planRender

/**
 * Captions in other scripts (translated captions): Chinese, Japanese, Korean, Arabic (right to left, joined letters),
 * Hindi and Thai, drawn by the export engine's overlay and by the editor preview, with the bundled fonts and the
 * phone's fallbacks. Writes both as images for review; checks every language leaves ink and unspaced ones join.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w400dp-h900dp-xxhdpi")
class CaptionScriptsTest {
    @get:Rule val compose = createComposeRule()

    private val samples = listOf(
        "zh" to listOf("今天", "天气", "很好"),
        "ja" to listOf("今日は", "いい", "天気", "です"),
        "ko" to listOf("오늘", "날씨가", "좋네요"),
        "ar" to listOf("الطقس", "جميل", "اليوم"),
        "hi" to listOf("आज", "मौसम", "अच्छा", "है"),
        "th" to listOf("วันนี้", "อากาศ", "ดี", "มาก"),
        "ru" to listOf("Сегодня", "хорошая", "погода"),
    )
    private val style = Presets.CAPTION_STYLES.getValue(CaptionPreset.HIGHLIGHT).let { it.copy(wordsPerPage = 6, text = it.text.copy(sizePct = .05)) }

    /** The engine's overlay for one language's page at 360×200 (dark), as drawn into an export frame. */
    private fun engine(lang: String, words: List<String>): Bitmap {
        val base = fromV1(EditListV1(sourceTakeId = "t", sourceDurationSec = 4.0, segments = listOf(V1Segment(0.0, 4.0, 1.0)), mute = false), SourceSize(360, 640, 30.0, true))
        val cw = words.mapIndexed { i, w -> CaptionWord(w, .2 + i * .3, .5 + i * .3) }
        val p = base.copy(tracks = base.tracks + Track("cap", TrackKind.CAPTION, items = emptyList(), caption = CaptionTrack(base.assets.first().id, cw, style.copy(y = .5), language = lang)))
        val bmp = Bitmap.createBitmap(360, 640, Bitmap.Config.ARGB_8888)
        EditOverlay(planRender(p, emptyMap())).onDraw(Canvas(bmp), 1_000_000L)
        return Bitmap.createBitmap(bmp, 0, 220, 360, 200)
    }

    private fun inkWidth(b: Bitmap): Int {
        var x0 = Int.MAX_VALUE; var x1 = -1
        for (y in 0 until b.height) for (x in 0 until b.width) if ((b.getPixel(x, y) ushr 24) > 128) { x0 = minOf(x0, x); x1 = maxOf(x1, x) }
        return if (x1 < 0) 0 else x1 - x0 + 1
    }

    @Test fun engineDrawsEveryScript() {
        val sheet = Bitmap.createBitmap(360, 200 * samples.size, Bitmap.Config.ARGB_8888)
        val c = Canvas(sheet); c.drawColor(Color.rgb(30, 34, 32))
        samples.forEachIndexed { i, (lang, words) ->
            val b = engine(lang, words)
            assertTrue("$lang leaves ink", inkWidth(b) > 40)
            c.drawBitmap(b, 0f, (i * 200).toFloat(), null)
        }
        java.io.File("build/outputs/roborazzi").mkdirs()
        java.io.FileOutputStream("build/outputs/roborazzi/scripts_engine.png").use { sheet.compress(Bitmap.CompressFormat.PNG, 100, it) }
        // Unspaced: the Japanese page is narrower than the same words with spaces would be (joined, no gaps).
        val two = listOf("今日は", "いい"); val joined = inkWidth(engine("ja", two)); val spaced = inkWidth(engine("en", two))
        assertTrue("ja joins without spaces ($joined < $spaced)", joined < spaced)
    }

    @Test fun previewDrawsEveryScript() {
        compose.setContent {
            MuseTheme(ThemeId.entries.first()) {
                Column(Modifier.background(androidx.compose.ui.graphics.Color(0xFF1E2220)).padding(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    samples.forEach { (lang, words) -> CaptionLine(words, 1, style, 640.dp, 360.dp, lang) }
                }
            }
        }
        compose.onRoot().captureRoboImage("build/outputs/roborazzi/scripts_preview.png")
    }
}

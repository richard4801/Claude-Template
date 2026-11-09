package studio.muse.app.platform.edit

import android.graphics.Bitmap
import android.graphics.Canvas
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import studio.muse.core.edit.EditListV1
import studio.muse.core.edit.Presets
import studio.muse.core.edit.SourceSize
import studio.muse.core.edit.TextItem
import studio.muse.core.edit.Track
import studio.muse.core.edit.TrackKind
import studio.muse.core.edit.Transform
import studio.muse.core.edit.V1Segment
import studio.muse.core.edit.fromV1
import studio.muse.core.edit.planRender

/** A scaled text item is the same block made bigger (as on the Mac and the server), never re-wrapped. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [35])
class EditOverlayScaleTest {
    /** The ink's bounding box (width, height) of the text drawn at [scale]. */
    private fun ink(scale: Double): Pair<Int, Int> {
        val base = fromV1(EditListV1(sourceTakeId = "t", sourceDurationSec = 4.0, segments = listOf(V1Segment(0.0, 4.0, 1.0)), mute = false), SourceSize(360, 640, 30.0, true))
        val style = Presets.HOOKS[0].style.copy(sizePct = .04, maxWidthPct = .9, stroke = null, shadow = null, background = null)
        val p = base.copy(tracks = base.tracks + Track("txt", TrackKind.TEXT, items = listOf(TextItem("x", 0.0, 4.0, "Day one in Lisbon", style, transform = Transform(.5, .5, scale)))))
        val bmp = Bitmap.createBitmap(360, 640, Bitmap.Config.ARGB_8888)
        EditOverlay(planRender(p, emptyMap())).onDraw(Canvas(bmp), 1_000_000L)
        var x0 = Int.MAX_VALUE; var x1 = -1; var y0 = Int.MAX_VALUE; var y1 = -1
        for (y in 0 until bmp.height) for (x in 0 until bmp.width) if ((bmp.getPixel(x, y) ushr 24) > 128) {
            x0 = minOf(x0, x); x1 = maxOf(x1, x); y0 = minOf(y0, y); y1 = maxOf(y1, y)
        }
        return (x1 - x0 + 1) to (y1 - y0 + 1)
    }

    @Test fun scalingMakesTheBlockBiggerWithoutRewrapping() {
        val (w1, h1) = ink(1.0)
        val (w2, h2) = ink(1.8)
        // One line at both sizes: both sides grow by the scale (re-wrapping would break it onto two lines: narrower, taller).
        assertEquals(1.8, w2.toDouble() / w1, 0.12)
        assertEquals(1.8, h2.toDouble() / h1, 0.25)
    }
}

package studio.muse.core.edit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import javax.imageio.ImageIO
import kotlin.math.abs

/** The GIF export's writer (read back with the JDK's own GIF decoder) and the export format / bitrate settings. */
class GifAndExportFormatTest {
    private fun frame(w: Int, h: Int, k: Int) = IntArray(w * h) { i ->
        val x = i % w; val y = i / w
        (0xFF shl 24) or (((x * 255 / w + k * 20) and 0xFF) shl 16) or ((y * 255 / h) shl 8) or ((x * y + k * 7) and 0xFF)
    }

    private fun gif(w: Int, h: Int, frames: List<IntArray>): ByteArray {
        val bytes = ByteArrayOutputStream()
        GifWriter(bytes, w, h).apply { frames.forEach { add(it, 7) }; finish() }
        return bytes.toByteArray()
    }

    @Test fun readsBackAsAnAnimatedLoopingGif() {
        val (w, h) = 120 to 90
        val frames = (0 until 4).map { frame(w, h, it) }
        val data = gif(w, h, frames)
        val reader = ImageIO.getImageReadersByFormatName("gif").next()
        reader.input = ImageIO.createImageInputStream(ByteArrayInputStream(data))
        assertEquals(4, reader.getNumImages(true))
        for (n in 0 until 4) {
            val img = reader.read(n)
            assertEquals(w, img.width); assertEquals(h, img.height)
            // Each pixel within the 5-bit quantization (and the palette's averaging) of the source.
            var err = 0.0
            for (y in 0 until h) for (x in 0 until w) {
                val a = frames[n][y * w + x]; val b = img.getRGB(x, y)
                for (s in listOf(16, 8, 0)) err += abs(((a shr s) and 0xFF) - ((b shr s) and 0xFF))
            }
            assertTrue("frame $n mean error ${err / (w * h * 3)}", err / (w * h * 3) < 12.0)
        }
        assertTrue(String(data, 0, 6, Charsets.US_ASCII) == "GIF89a" && String(data).contains("NETSCAPE2.0") && data.last() == 0x3B.toByte())
    }

    @Test fun flatAndTinyFramesAndManyColoursDecode() {
        // One colour (a 1-entry palette), 1×1, and noise that fills the LZW table and forces clear codes.
        val rnd = java.util.Random(4)
        for ((w, h, f) in listOf(Triple(64, 64, IntArray(64 * 64) { 0xFF336699.toInt() }), Triple(1, 1, intArrayOf(0xFFFFFFFF.toInt())),
            Triple(300, 200, IntArray(300 * 200) { rnd.nextInt() or (0xFF shl 24) }))) {
            val img = ImageIO.read(ByteArrayInputStream(gif(w, h, listOf(f))))
            assertNotNull(img); assertEquals(w, img.width)
            if (w == 64) { val c = img.getRGB(10, 10); for ((sh, want) in listOf(16 to 0x33, 8 to 0x66, 0 to 0x99)) assertTrue(abs(((c shr sh) and 0xFF) - want) <= 4) }
        }
    }

    @Test fun formatsAndBitrates() {
        val s = ExportSettings(resolution = ExportResolution.FULL_HD, fps = 30)
        assertEquals(1080 to 1920, s.size)
        val rec = videoBitrate(1080, 1920, 30)
        assertEquals((rec * 0.6).toInt().toDouble(), videoBitrate(1080, 1920, 30, ExportBitrate.LOWER).toDouble(), 1.0)
        assertEquals((rec * 1.6).toInt().toDouble(), videoBitrate(1080, 1920, 30, ExportBitrate.HIGHER).toDouble(), 1.0)
        assertTrue(s.copy(bitrate = ExportBitrate.HIGHER).estimatedBytes(10.0) > s.estimatedBytes(10.0))
        // GIF: 480 px short side at 15 fps, whatever the resolution; captions always burned in.
        val g = s.copy(format = ExportFormat.GIF, captions = CaptionExport.SRT, resolution = ExportResolution.UHD)
        assertEquals(480 to 854, g.size); assertEquals(GIF_FPS, g.outFps)
        assertEquals("GIFs are up to 30 s · trim the edit or export a video", g.refusal(31.0, true)); assertNull(g.refusal(30.0, false))
        // Sound only: 192 kbit/s, and refused without sound.
        val a = s.copy(format = ExportFormat.SOUND)
        assertEquals(240_000L, a.estimatedBytes(10.0)); assertEquals("This edit has no sound to export", a.refusal(5.0, false))
    }
}

/** Auto adjust: a dark, flat, warm-and-green frame gets brighter, more contrast, cooler and less green. */
class AutoAdjustTest {
    @Test fun correctsADarkWarmGreenFrame() {
        val rgb = DoubleArray(300 * 3) { i -> val k = i / 3; val v = 0.15 + 0.1 * (k % 10) / 10.0; when (i % 3) { 0 -> v * 1.2; 1 -> v * 1.15; else -> v * 0.8 } }
        val a = autoAdjust(rgb)
        assertTrue("brighter ${a.exposure}", a.exposure!! > 0.3)
        assertTrue("more contrast ${a.contrast}", a.contrast!! > 0.3)
        assertTrue("cooler ${a.temperature}", a.temperature!! < 0)
        assertTrue("less green ${a.tint}", a.tint!! > 0)
        // Its white balance (temperature and tint alone) brings blue up against red.
        val m = colorMatrix(Adjust(temperature = a.temperature, tint = a.tint), null)
        val out = DoubleArray(3) { c -> m[c * 4] * 0.2 * 1.2 + m[c * 4 + 1] * 0.2 * 1.15 + m[c * 4 + 2] * 0.2 * 0.8 + m[c * 4 + 3] }
        assertTrue(out[2] / out[0] > 0.8 / 1.2)
    }

    @Test fun aBalancedFrameStaysAlmostAsItIs() {
        val rgb = DoubleArray(1000 * 3) { i -> val k = i / 3; (k % 100) / 99.0 * 0.92 + 0.04 }
        val a = autoAdjust(rgb, Adjust(highlights = .2))
        assertEquals(.2, a.highlights!!, 0.0)
        assertTrue("${a}", kotlin.math.abs(a.exposure ?: 0.0) <= 0.2 && a.temperature == null && a.tint == null)
    }
}

package studio.muse.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import studio.muse.app.platform.SoundFx
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files

/** Every theme's sounds are pre-rendered to valid, clearly audible WAV files for the SoundPool. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class SoundFxTest {
    @Test fun rendersAudibleWavsForEveryThemeAndKind() {
        val dir = Files.createTempDirectory("sfx").toFile()
        SoundFx(enabled = { true }, theme = { "d" }, cacheDir = dir)
        val expected = listOf("a", "b", "c", "d").flatMap { t -> SoundFx.Kind.entries.map { "sfx_v2_$t${it.name}.wav" } }
        val deadline = System.currentTimeMillis() + 20_000
        while (System.currentTimeMillis() < deadline && expected.any { !File(dir, it).exists() }) Thread.sleep(50)
        expected.forEach { name ->
            val bytes = File(dir, name).readBytes()
            assertEquals("RIFF", String(bytes, 0, 4)); assertEquals("WAVE", String(bytes, 8, 4))
            val bb = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            assertEquals(22050, bb.getInt(24))
            var peak = 0
            for (i in 44 until bytes.size - 1 step 2) peak = maxOf(peak, kotlin.math.abs(bb.getShort(i).toInt()))
            assertTrue("$name is too quiet (peak $peak)", peak > 32767 * 0.4)
        }
    }
}

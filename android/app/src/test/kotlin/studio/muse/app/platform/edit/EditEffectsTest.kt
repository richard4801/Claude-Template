package studio.muse.app.platform.edit

import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import studio.muse.core.edit.Adjust
import studio.muse.core.edit.Asset
import studio.muse.core.edit.AssetKind
import studio.muse.core.edit.Canvas
import studio.muse.core.edit.EditProject
import studio.muse.core.edit.FilterRef
import studio.muse.core.edit.GainPoint
import studio.muse.core.edit.MediaInfo
import studio.muse.core.edit.Track
import studio.muse.core.edit.TrackKind
import studio.muse.core.edit.Transform
import studio.muse.core.edit.Transition
import studio.muse.core.edit.TransitionKind
import studio.muse.core.edit.VideoClip
import studio.muse.core.edit.colorMatrix
import studio.muse.core.edit.planRender
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** The thin Media3 pieces of the composition engine that run without a device. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class EditEffectsTest {
    @Test fun colorMatrixIsColumnMajorWithTheOffsetColumn() {
        val m = colorMatrix(Adjust(exposure = 0.3, contrast = 0.2, temperature = -0.4), FilterRef("film", 0.7))
        val gl = ColorMatrixEffect(m).getMatrix(0, false)
        val rgb = doubleArrayOf(0.2, 0.5, 0.9)
        for (row in 0 until 3) {
            val want = m[row * 4] * rgb[0] + m[row * 4 + 1] * rgb[1] + m[row * 4 + 2] * rgb[2] + m[row * 4 + 3]
            // GLSL: uRgbMatrix * vec4(rgb, 1) with a column-major mat4.
            val got = gl[row] * rgb[0] + gl[4 + row] * rgb[1] + gl[8 + row] * rgb[2] + gl[12 + row]
            assertEquals(want, got, 1e-6)
        }
        assertEquals(1f, gl[15], 0f)
    }

    @Test fun envelopeProcessorAppliesTheGainByTimelineTime() {
        // A clip starting at 2 s on the timeline: gain ramps 0 → 2 over its first second (sample rate 10 Hz for clarity).
        val p = EnvelopeAudioProcessor(2.0, listOf(GainPoint(2.0, 0.0), GainPoint(3.0, 2.0), GainPoint(5.0, 2.0)))
        p.configure(AudioProcessor.AudioFormat(10, 1, C.ENCODING_PCM_16BIT))
        p.flush(AudioProcessor.StreamMetadata.DEFAULT)
        val input = ByteBuffer.allocateDirect(2 * 12).order(ByteOrder.nativeOrder())
        repeat(12) { input.putShort(20_000) }
        input.flip()
        p.queueInput(input)
        val out = p.output
        val got = (0 until 12).map { out.short.toInt() }
        assertEquals(0, got[0])
        assertEquals(4_000, got[1])        // 0.1 s in: gain 0.2
        assertEquals(20_000, got[5])       // gain 1
        assertEquals(32_767, got[11])      // gain 2 clamps instead of wrapping
    }

    @Test fun compositorPlacesLayersFromThePlan() {
        val src = Asset("src", AssetKind.VIDEO, take = "t", durationSec = 10.0, width = 1080, height = 1920, hasAudio = true)
        val p = EditProject(
            sourceTakeId = "t", canvas = Canvas(1080, 1920, 30.0), assets = listOf(src),
            tracks = listOf(Track("main", TrackKind.MAIN, items = listOf(
                VideoClip("c1", "src", 0.0, 4.0, transform = Transform(x = 0.25, scale = 0.5, rotation = 90.0)),
                VideoClip("c2", "src", 4.0, 8.0, transitionIn = Transition(TransitionKind.SLIDE_LEFT, 1.0)),
            ))),
        )
        val plan = planRender(p, mapOf("src" to MediaInfo(10.0, 1080, 1920, 30.0, true)))
        val s = PlanCompositorSettings(plan)
        assertEquals(1080, s.getOutputSize(emptyList()).width)
        assertEquals(0f, s.getOverlaySettings(0, 1_000_000).alphaScale, 0f)                 // the clock never shows
        val c1 = s.getOverlaySettings(1, 1_000_000)
        assertEquals(1f, c1.alphaScale, 0f)
        assertEquals(-0.5f, c1.backgroundFrameAnchor.first, 1e-6f)                             // x 0.25 → NDC −0.5
        assertEquals(0f, c1.backgroundFrameAnchor.second, 1e-6f)
        assertEquals(-90f, c1.rotationDegrees, 0f)                                             // clockwise → Media3 CCW
        // Mid slide (3.5 s, eased 0.5): c2 is half in from the right → centre x 1.0 → NDC 1.0; beyond −1…1 is fine.
        assertEquals(1f, s.getOverlaySettings(2, 3_500_000).backgroundFrameAnchor.first, 1e-6f)
        assertEquals(0f, s.getOverlaySettings(2, 1_000_000).alphaScale, 0f)                  // c2's layer is a gap here
    }
}

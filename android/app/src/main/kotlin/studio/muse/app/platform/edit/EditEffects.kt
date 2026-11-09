package studio.muse.app.platform.edit

import android.content.Context
import android.opengl.GLES20
import android.util.Pair
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.OverlaySettings
import androidx.media3.common.VideoCompositorSettings
import androidx.media3.common.VideoFrameProcessingException
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.common.util.Util
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import androidx.media3.effect.RgbMatrix
import studio.muse.core.edit.Chroma
import studio.muse.core.edit.ChromaKey
import studio.muse.core.edit.EnvelopeCursor
import studio.muse.core.edit.GainPoint
import studio.muse.core.edit.RenderPlan
import studio.muse.core.edit.hexRgb
import java.nio.ByteBuffer

/**
 * The look of an item: the plan's 3×4 affine colour matrix (studio.muse.core.edit.colorMatrix, row-major, offset in
 * the 4th column) as a Media3 [RgbMatrix]. Media3's shader computes `uRgbMatrix * vec4(rgb, 1)` with a column-major
 * 4×4, so the offset column fits as-is (no custom shader needed). With the default SDR working colour space the
 * values are the gamma-encoded ones, as the contract assumes; the 8-bit output clamps.
 */
@OptIn(UnstableApi::class)
class ColorMatrixEffect(rowMajor3x4: List<Double>) : RgbMatrix {
    private val m: FloatArray = FloatArray(16).also { out ->
        for (row in 0 until 3) for (col in 0 until 4) out[col * 4 + row] = rowMajor3x4[row * 4 + col].toFloat()
        out[15] = 1f
    }

    override fun getMatrix(presentationTimeUs: Long, useHdr: Boolean): FloatArray = m
}

/** The chroma key (studio.muse.core.edit.ChromaKey, same formula) as a GL shader effect. */
@OptIn(UnstableApi::class)
class ChromaKeyEffect(private val key: Chroma) : GlEffect {
    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram = ChromaKeyProgram(key, useHdr)
}

@OptIn(UnstableApi::class)
private class ChromaKeyProgram(key: Chroma, useHdr: Boolean) : BaseGlShaderProgram(useHdr, 1) {
    private val program: GlProgram = try { GlProgram(VERTEX, FRAGMENT) } catch (e: GlUtil.GlException) { throw VideoFrameProcessingException(e) }

    init {
        val rgb = hexRgb(key.color)
        val (kb, kr) = ChromaKey.cbCr(rgb[0], rgb[1], rgb[2])
        program.setBufferAttribute("aFramePosition", GlUtil.getNormalizedCoordinateBounds(), GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE)
        program.setFloatsUniform("uKeyCbCr", floatArrayOf(kb.toFloat(), kr.toFloat()))
        program.setFloatUniform("uSimilarity", (key.similarity ?: ChromaKey.DEFAULT_SIMILARITY).toFloat())
        program.setFloatUniform("uSmoothness", maxOf(key.smoothness ?: ChromaKey.DEFAULT_SMOOTHNESS, 1e-4).toFloat())
        program.setFloatUniform("uSpill", maxOf(key.spill ?: ChromaKey.DEFAULT_SPILL, 1e-4).toFloat())
    }

    override fun configure(inputWidth: Int, inputHeight: Int) = Size(inputWidth, inputHeight)

    override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
        try {
            program.use()
            program.setSamplerTexIdUniform("uTexSampler", inputTexId, 0)
            program.bindAttributesAndUniforms()
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        } catch (e: GlUtil.GlException) {
            throw VideoFrameProcessingException(e, presentationTimeUs)
        }
    }

    override fun release() {
        super.release()
        try { program.delete() } catch (e: GlUtil.GlException) { throw VideoFrameProcessingException(e) }
    }

    companion object {
        const val VERTEX = """
attribute vec4 aFramePosition;
varying vec2 vTexSamplingCoord;
void main() {
  gl_Position = aFramePosition;
  vTexSamplingCoord = vec2(aFramePosition.x * 0.5 + 0.5, aFramePosition.y * 0.5 + 0.5);
}"""
        const val FRAGMENT = """
precision mediump float;
uniform sampler2D uTexSampler;
uniform vec2 uKeyCbCr;
uniform float uSimilarity;
uniform float uSmoothness;
uniform float uSpill;
varying vec2 vTexSamplingCoord;
void main() {
  vec4 c = texture2D(uTexSampler, vTexSamplingCoord);
  float cb = -0.168736 * c.r - 0.331264 * c.g + 0.5 * c.b;
  float cr = 0.5 * c.r - 0.418688 * c.g - 0.081312 * c.b;
  float base = distance(vec2(cb, cr), uKeyCbCr) - uSimilarity;
  float alpha = pow(clamp(base / uSmoothness, 0.0, 1.0), 1.5);
  float s = pow(clamp(base / uSpill, 0.0, 1.0), 1.5);
  float l = dot(c.rgb, vec3(0.2126, 0.7152, 0.0722));
  gl_FragColor = vec4(mix(vec3(l), c.rgb, s), c.a * alpha);
}"""
    }
}

/**
 * Multiplies a clip's sound by its gain envelope (studio.muse.core.edit.audioEnvelope, timeline seconds).
 * Speed changes happen before item effects in Media3, so sample n of this item plays at timeline
 * [startSec] + n / sampleRate. Unlike Media3's GainProcessor (which wraps 16-bit samples above gain 1) it clamps,
 * so volumes up to 2× are safe. A flush with a position offset (seek in preview) restarts from that position.
 */
@OptIn(UnstableApi::class)
class EnvelopeAudioProcessor(private val startSec: Double, envelope: List<GainPoint>) : BaseAudioProcessor() {
    private val cursor = EnvelopeCursor(envelope)
    private var frames = 0L

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT && inputAudioFormat.encoding != C.ENCODING_PCM_FLOAT)
            throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
        return inputAudioFormat
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        if (!inputBuffer.hasRemaining()) return
        val f = inputAudioFormat
        val out = replaceOutputBuffer(inputBuffer.remaining())
        val rate = f.sampleRate.toDouble()
        while (inputBuffer.remaining() >= f.bytesPerFrame) {
            val g = cursor.gainAt(startSec + frames / rate).toFloat()
            repeat(f.channelCount) {
                if (f.encoding == C.ENCODING_PCM_16BIT) out.putShort((inputBuffer.short * g).coerceIn(-32768f, 32767f).toInt().toShort())
                else out.putFloat((inputBuffer.float * g).coerceIn(-1f, 1f))
            }
            frames++
        }
        out.flip()
    }

    override fun onFlush(streamMetadata: AudioProcessor.StreamMetadata) {
        frames = if (inputAudioFormat.sampleRate > 0) Util.durationUsToSampleCount(streamMetadata.positionOffsetUs, inputAudioFormat.sampleRate) else 0
    }

    override fun onReset() { frames = 0 }
}

/**
 * Overlay settings with any anchor. Media3's StaticOverlaySettings.Builder only accepts anchors in −1…1, but a slide
 * transition or a keyframed position moves a layer's centre off the canvas, so this implements the interface directly.
 */
@OptIn(UnstableApi::class)
class LayerOverlaySettings(
    private val alpha: Float, private val anchorX: Float, private val anchorY: Float, private val scale: Float, private val rotationCcw: Float,
    /** Wave 1, mirror: −1 flips that axis (about the picture's centre, before the rotation). */
    private val signX: Float = 1f, private val signY: Float = 1f,
    /** Wave 1: the blend mode (BlendMode.ordinal; 0 = normal), read by MuseCompositorGlProgram. */
    private val blendMode: Int = 0,
) : OverlaySettings, androidx.media3.effect.MuseBlendOverlay {
    override fun getBlendMode() = blendMode
    override fun getAlphaScale() = alpha
    override fun getBackgroundFrameAnchor(): Pair<Float, Float> = Pair.create(anchorX, anchorY)
    override fun getOverlayFrameAnchor(): Pair<Float, Float> = Pair.create(0f, 0f)
    override fun getScale(): Pair<Float, Float> = Pair.create(scale * signX, scale * signY)
    override fun getRotationDegrees() = rotationCcw
}

/**
 * The compositor settings for a [RenderPlan]: output at the canvas size, and each input (= sequence = plan layer)
 * placed per frame by [RenderPlan.placement] — centre (canvas fractions → NDC anchor, y up), scale × the texture's
 * base scale, rotation (the contract is clockwise, Media3 counter-clockwise) and alpha (transitions, keyframes,
 * gaps hidden).
 *
 * Media3 1.11 calls getOverlaySettings with the input frame's own presentation time when the frame is queued (not
 * the output frame's); with the clock layer at the canvas fps the two are within a frame of each other.
 */
@OptIn(UnstableApi::class)
class PlanCompositorSettings(private val plan: RenderPlan) : VideoCompositorSettings {
    override fun getOutputSize(inputSizes: List<Size>) = Size(plan.width, plan.height)

    override fun getOverlaySettings(inputId: Int, presentationTimeUs: Long): OverlaySettings {
        val t = presentationTimeUs / 1_000_000.0
        val p = plan.placement(inputId, t)
        if (p.alpha <= 0.0) return HIDDEN
        val base = plan.clipAt(inputId, t)?.look?.baseScale ?: 1.0
        return LayerOverlaySettings(
            alpha = p.alpha.coerceIn(0.0, 1.0).toFloat(), anchorX = (2 * p.centerX - 1).toFloat(), anchorY = (1 - 2 * p.centerY).toFloat(),
            scale = (p.scale * base).toFloat(), rotationCcw = (-p.rotationCw).toFloat(),
            signX = if (p.flipX) -1f else 1f, signY = if (p.flipY) -1f else 1f,
            blendMode = p.blend?.ordinal ?: 0,
        )
    }

    private companion object {
        val HIDDEN = LayerOverlaySettings(0f, 0f, 0f, 1f, 0f)
    }
}

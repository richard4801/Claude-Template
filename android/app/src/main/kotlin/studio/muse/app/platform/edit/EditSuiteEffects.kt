package studio.muse.app.platform.edit

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import studio.muse.core.edit.BiquadChain
import studio.muse.core.edit.Mask
import studio.muse.core.edit.MaskShape
import studio.muse.core.edit.VoiceEffect
import studio.muse.core.edit.voiceChain
import java.nio.ByteBuffer

/*
 * Edit suite (workstream 3) engine effects: shape masks, the whip/glitch transition looks (motion blur and RGB split),
 * and voice effects/enhance as an AudioProcessor. The maths is the core's (maskAlpha, transitionState, voiceChain);
 * these classes only run it on the GPU / audio thread.
 */

/** A shape mask (studio.muse.core.edit.maskAlpha, same formula) multiplied into the frame's alpha. */
@OptIn(UnstableApi::class)
class MaskEffect(private val mask: Mask) : GlEffect {
    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram =
        SinglePassProgram(useHdr, EditSuiteShaders.MASK) { p, _, _, _ ->
            p.setIntUniform("uShape", MaskShape.entries.indexOf(mask.shape))
            p.setFloatsUniform("uCenter", floatArrayOf((mask.x ?: 0.5).toFloat(), (mask.y ?: 0.5).toFloat()))
            p.setFloatsUniform("uSize", floatArrayOf(maxOf(0.01, mask.width ?: 0.5).toFloat(), maxOf(0.01, mask.height ?: 0.5).toFloat()))
            p.setFloatUniform("uRot", ((mask.rotation ?: 0.0) * Math.PI / 180).toFloat())
            p.setFloatUniform("uFeather", maxOf(1e-4, mask.feather ?: 0.1).toFloat())
            p.setFloatUniform("uInvert", if (mask.invert == true) 1f else 0f)
        }
}

/**
 * The look half of the Edit suite transitions on one clip: [fx] gives (blur 0–1, rgbSplit 0–1) at a composition time
 * (RenderPlan.placement of the clip's layer). Whip = a horizontal motion blur up to 4 % of the frame; glitch = red and
 * blue sampled apart by up to 2 %. Outside a transition both are 0 and the pass copies the frame.
 */
@OptIn(UnstableApi::class)
class TransitionFxEffect(private val fx: (Long) -> Pair<Double, Double>) : GlEffect {
    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram =
        SinglePassProgram(useHdr, EditSuiteShaders.TRANSITION_FX) { p, _, _, timeUs ->
            val (blur, split) = fx(timeUs)
            p.setFloatUniform("uBlur", (blur.coerceIn(0.0, 1.0) * 0.04).toFloat())
            p.setFloatUniform("uSplit", (split.coerceIn(0.0, 1.0) * 0.02).toFloat())
        }
}

internal object EditSuiteShaders {
    /** maskAlpha in GLSL (shapes in MaskShape order: linear, mirror, circle, rect, heart, star). */
    const val MASK = """
precision highp float;
uniform sampler2D uTexSampler;
uniform int uShape;
uniform vec2 uCenter;
uniform vec2 uSize;
uniform float uRot;
uniform float uFeather;
uniform float uInvert;
varying vec2 vTexSamplingCoord;
float soft(float d) { return 1.0 - smoothstep(-uFeather / 2.0, uFeather / 2.0, d); }
void main() {
  vec4 c = texture2D(uTexSampler, vTexSamplingCoord);
  vec2 uv = vec2(vTexSamplingCoord.x, 1.0 - vTexSamplingCoord.y);
  vec2 d = uv - uCenter;
  float x = d.x * cos(uRot) + d.y * sin(uRot);
  float y = -d.x * sin(uRot) + d.y * cos(uRot);
  float w = uSize.x; float h = uSize.y; float m = min(w, h);
  float a = 1.0;
  if (uShape == 0) a = soft(y);
  else if (uShape == 1) a = soft(abs(y) - h / 2.0);
  else if (uShape == 2) { float r = length(vec2(x / (w / 2.0), y / (h / 2.0))); a = soft((r - 1.0) * m / 2.0); }
  else if (uShape == 3) a = soft(max(abs(x) - w / 2.0, abs(y) - h / 2.0));
  else if (uShape == 4) {
    float X = (x / (w / 2.0)) * 1.15; float Y = (-y / (h / 2.0)) * 1.15 + 0.25;
    float q = X * X + Y * Y - 1.0;
    float F = q * q * q - X * X * Y * Y * Y;
    a = soft(F * 0.6 * m);
  } else {
    float X = x / (w / 2.0); float Y = y / (h / 2.0); float r = length(vec2(X, Y));
    float ang = mod(degrees(atan(X, -Y)) + 360.0, 72.0);
    float t = abs(ang - 36.0) / 36.0;
    a = soft((r - (0.45 + 0.55 * t)) * m / 2.0);
  }
  if (uInvert > 0.5) a = 1.0 - a;
  gl_FragColor = vec4(c.rgb, c.a * a);
}"""

    /** Horizontal motion blur (16 taps over ±uBlur) and an RGB split of ±uSplit. */
    const val TRANSITION_FX = """
precision highp float;
uniform sampler2D uTexSampler;
uniform float uBlur;
uniform float uSplit;
varying vec2 vTexSamplingCoord;
void main() {
  vec2 p = vTexSamplingCoord;
  vec4 c = texture2D(uTexSampler, p);
  if (uBlur > 0.0001) {
    vec3 s = vec3(0.0);
    for (int k = 0; k < 16; k++) s += texture2D(uTexSampler, p + vec2((float(k) / 15.0 - 0.5) * 2.0 * uBlur, 0.0)).rgb;
    c.rgb = s / 16.0;
  }
  if (uSplit > 0.0001) {
    c.r = texture2D(uTexSampler, p + vec2(uSplit, 0.0)).r;
    c.b = texture2D(uTexSampler, p - vec2(uSplit, 0.0)).b;
  }
  gl_FragColor = c;
}"""
}

/**
 * Voice effects and "enhance" (studio.muse.core.edit.voiceChain: RBJ biquads, the reference's coefficients) on a
 * clip's sound, one streaming chain per channel. Inactive (passes through) when the chain is empty. Runs before the
 * gain envelope; a flush (seek) clears the filter state.
 */
@OptIn(UnstableApi::class)
class VoiceAudioProcessor(private val effect: VoiceEffect?, private val enhance: Boolean?) : BaseAudioProcessor() {
    private var chains: List<BiquadChain> = emptyList()

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT && inputAudioFormat.encoding != C.ENCODING_PCM_FLOAT)
            throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
        val chain = voiceChain(effect, enhance, inputAudioFormat.sampleRate.toDouble())
        if (chain.isEmpty()) return AudioProcessor.AudioFormat.NOT_SET
        chains = List(inputAudioFormat.channelCount) { BiquadChain(chain) }
        return inputAudioFormat
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        if (!inputBuffer.hasRemaining()) return
        val f = inputAudioFormat
        val out = replaceOutputBuffer(inputBuffer.remaining())
        while (inputBuffer.remaining() >= f.bytesPerFrame) {
            for (ch in 0 until f.channelCount) {
                if (f.encoding == C.ENCODING_PCM_16BIT) {
                    val y = chains[ch].process(inputBuffer.short / 32768.0)
                    out.putShort((y * 32768.0).coerceIn(-32768.0, 32767.0).toInt().toShort())
                } else out.putFloat(chains[ch].process(inputBuffer.float.toDouble()).coerceIn(-1.0, 1.0).toFloat())
            }
        }
        out.flip()
    }

    override fun onFlush(streamMetadata: AudioProcessor.StreamMetadata) { chains.forEach { it.reset() } }

    override fun onReset() { chains = emptyList() }
}

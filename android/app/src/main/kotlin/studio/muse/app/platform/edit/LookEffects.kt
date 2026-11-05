package studio.muse.app.platform.edit

import android.content.Context
import android.opengl.GLES20
import androidx.annotation.OptIn
import androidx.media3.common.Effect
import androidx.media3.common.VideoFrameProcessingException
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import androidx.media3.effect.SingleColorLut
import studio.muse.core.edit.ColorStack
import studio.muse.core.edit.Grain
import studio.muse.core.edit.HALATION_TINT
import studio.muse.core.edit.Halation
import studio.muse.core.edit.LEAK_COLORS
import studio.muse.core.edit.Leak
import studio.muse.core.edit.Look
import studio.muse.core.edit.Lut
import studio.muse.core.edit.Vignette
import studio.muse.core.edit.grainCell
import studio.muse.core.edit.halationRadius
import studio.muse.core.edit.sharpenRadius
import kotlin.math.PI
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/**
 * An item's look (plans/video-editor.md "Looks") as Media3 GL effects, in the contract's pipeline order:
 *
 *   sharpen → chromatic aberration → ONE baked colour LUT (colour matrix → curves → LUT × strength → lift) → halation
 *   → leak + vignette + grain (one pass)
 *
 * Steps 3–6 are all per-pixel and consecutive, so they are baked on the CPU ([ColorStack.bakeCube], the same code the
 * CPU renderer and the fixtures use) into one 33³ cube and drawn with Media3's [SingleColorLut] — one texture lookup
 * per pixel whatever the look, strength included (it is mixed into the bake). Exact at the grid points; between them
 * the GPU's trilinear lookup (and the LUT texture's 8 bits) is within ~1/255 of the CPU. A 17³ pack cube nests in the
 * 33³ grid, so a pack LUT alone is reproduced exactly up to 8-bit rounding. With no curves/LUT/lift only the colour
 * matrix runs ([ColorMatrixEffect], exact).
 *
 * The spatial steps are custom shader programs that size their blur radii from the frame they get (the fitted item
 * texture), like the reference does from the picture's short side. Box blurs are separable: a horizontal pass into a
 * private texture, then the vertical pass combined with the input in the program's output (clamp-to-edge sampling at
 * texel centres = the reference's clamped indices).
 */
object LookEffects {
    /** The look's stages (pure; [effects] turns them into Media3 effects). */
    sealed interface Stage {
        data class Sharpen(val amount: Double) : Stage
        data class Chromatic(val amount: Double) : Stage
        /** The colour matrix alone (3×4 row-major). */
        data class Matrix(val rowMajor3x4: List<Double>) : Stage
        /** Steps 3–6 baked: [cube] is [size]³ rgb triples in Media3's [R][G][B] order. */
        class BakedLut(val size: Int, val cube: FloatArray) : Stage
        data class Halo(val halation: Halation) : Stage
        /** Leak, vignette and grain in one pass; [fps] turns presentation time into the grain's frame number. */
        data class Finish(val leak: Leak?, val vignette: Vignette?, val grain: Grain?, val fps: Double) : Stage
    }

    const val BAKE_SIZE = 33

    /**
     * The stages for an item: [matrix] = its colour matrix (null = identity), [look] its look, [lut] the resolved LUT of
     * `look.lut` (null when it has none or it could not be loaded — the rest of the look still applies).
     */
    fun stages(matrix: List<Double>?, look: Look?, lut: Lut?, fps: Double): List<Stage> = buildList {
        val l = look ?: Look()
        (l.sharpen ?: 0.0).coerceIn(0.0, 1.0).takeIf { it > 0 }?.let { add(Stage.Sharpen(it)) }
        (l.chromatic ?: 0.0).coerceIn(0.0, 1.0).takeIf { it > 0 }?.let { add(Stage.Chromatic(it)) }
        val colour = ColorStack(null, l, lut)
        if (!colour.isIdentity) add(Stage.BakedLut(BAKE_SIZE, ColorStack(matrix, l, lut).bakeCube(BAKE_SIZE)))
        else if (matrix != null) add(Stage.Matrix(matrix))
        l.halation?.takeIf { it.amount > 0 }?.let { add(Stage.Halo(it)) }
        val leak = l.leak?.takeIf { it.amount > 0 }
        val vignette = l.vignette?.takeIf { it.amount != 0.0 }
        val grain = l.grain?.takeIf { it.amount > 0 }
        if (leak != null || vignette != null || grain != null) add(Stage.Finish(leak, vignette, grain, fps))
    }

    @OptIn(UnstableApi::class)
    fun effects(stages: List<Stage>): List<Effect> = stages.map { s ->
        when (s) {
            is Stage.Sharpen -> SharpenEffect(s.amount)
            is Stage.Chromatic -> ChromaticEffect(s.amount)
            is Stage.Matrix -> ColorMatrixEffect(s.rowMajor3x4)
            is Stage.BakedLut -> SingleColorLut.createFromCube(argbCube(s.size, s.cube))
            is Stage.Halo -> HalationEffect(s.halation)
            is Stage.Finish -> LookFinishEffect(s.leak, s.vignette, s.grain, s.fps)
        }
    }

    /** A baked cube as Media3's `int[R][G][B]` opaque ARGB colours (8 bits per channel, rounded). */
    fun argbCube(size: Int, cube: FloatArray): Array<Array<IntArray>> = Array(size) { r ->
        Array(size) { g ->
            IntArray(size) { b ->
                val i = ((r * size + g) * size + b) * 3
                fun c(k: Int) = (cube[i + k].coerceIn(0f, 1f) * 255f).roundToInt()
                (0xff shl 24) or (c(0) shl 16) or (c(1) shl 8) or c(2)
            }
        }
    }

    /** The timeline frame number at a composition presentation time: round(timeline s × canvas fps) (grain, leak). */
    fun frameAt(presentationTimeUs: Long, fps: Double): Int = ((presentationTimeUs / 1_000_000.0) * fps).roundToLong().toInt()
}

// ------------------------------------------------------------------ effects
@OptIn(UnstableApi::class)
class SharpenEffect(private val amount: Double) : GlEffect {
    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram =
        TwoPassBlurProgram(useHdr, LookShaders.SHARPEN, radius = { w, h -> sharpenRadius(min(w, h)) }) { p ->
            p.setFloatUniform("uAmount", amount.toFloat())
        }
}

@OptIn(UnstableApi::class)
class HalationEffect(private val halation: Halation) : GlEffect {
    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram =
        TwoPassBlurProgram(useHdr, LookShaders.HALATION, radius = { w, h -> halationRadius(min(w, h), halation) }) { p ->
            p.setFloatUniform("uAmount", halation.amount.coerceIn(0.0, 1.0).toFloat())
            p.setFloatUniform("uThreshold", (halation.threshold ?: 0.7).coerceIn(0.0, 0.99).toFloat())
            p.setFloatsUniform("uTint", floatArrayOf(HALATION_TINT[0].toFloat(), HALATION_TINT[1].toFloat(), HALATION_TINT[2].toFloat()))
        }
}

@OptIn(UnstableApi::class)
class ChromaticEffect(private val amount: Double) : GlEffect {
    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram =
        SinglePassProgram(useHdr, LookShaders.CHROMATIC) { p, _, _, _ -> p.setFloatUniform("uShift", (amount.coerceIn(0.0, 1.0) * 0.006).toFloat()) }
}

/** Steps 8–10: light leak (drifts with time), vignette and grain (a new pattern every frame). */
@OptIn(UnstableApi::class)
class LookFinishEffect(private val leak: Leak?, private val vignette: Vignette?, private val grain: Grain?, private val fps: Double) : GlEffect {
    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram =
        SinglePassProgram(useHdr, LookShaders.FINISH) { p, w, h, timeUs ->
            // The contract's frame is the TIMELINE frame (round(timeline s × canvas fps)) and the leak's t = frame / fps.
            // Item effects see the composition (sequence) presentation time, which is the timeline time.
            val frame = LookEffects.frameAt(timeUs, fps)
            val t = frame / fps
            val lk = leak?.takeIf { it.amount > 0 }
            p.setFloatUniform("uLeakAmount", (lk?.amount ?: 0.0).coerceIn(0.0, 1.0).toFloat())
            p.setFloatUniform("uLeakAngle", (((lk?.angle ?: 30.0) * PI / 180) + 0.25 * kotlin.math.sin(t * 0.6)).toFloat())
            val cs = LEAK_COLORS.getValue(lk?.kind ?: studio.muse.core.edit.LeakKind.WARM)
            p.setFloatsUniform("uLeak0", FloatArray(3) { cs[0][it].toFloat() })
            p.setFloatsUniform("uLeak1", FloatArray(3) { cs[1][it].toFloat() })
            val vg = vignette?.takeIf { it.amount != 0.0 }
            p.setFloatUniform("uVigAmount", (vg?.amount ?: 0.0).coerceIn(-1.0, 1.0).toFloat())
            val size = (vg?.size ?: 0.45).coerceIn(0.0, 1.0)
            p.setFloatUniform("uVigSize", size.toFloat())
            p.setFloatUniform("uVigSoft", maxOf(0.05, (vg?.softness ?: 0.5).coerceIn(0.0, 1.0)).toFloat())
            val gr = grain?.takeIf { it.amount > 0 }
            p.setFloatUniform("uGrainAmount", ((gr?.amount ?: 0.0).coerceIn(0.0, 1.0) * 0.18).toFloat())
            p.setFloatUniform("uGrainCell", (if (gr != null) grainCell(min(w, h), gr) else 1).toFloat())
            p.setFloatUniform("uFrame", (frame % 4096).toFloat())
            p.setFloatsUniform("uSize", floatArrayOf(w.toFloat(), h.toFloat()))
        }
}

// ------------------------------------------------------------------ programs
/** One full-frame pass of [fragment]; [setUniforms] runs before every frame with the frame size and time. */
@OptIn(UnstableApi::class)
private class SinglePassProgram(
    useHdr: Boolean, fragment: String, private val setUniforms: (GlProgram, Int, Int, Long) -> Unit,
) : BaseGlShaderProgram(useHdr, 1) {
    private val program = glProgram(LookShaders.VERTEX, fragment)
    private var w = 0
    private var h = 0

    override fun configure(inputWidth: Int, inputHeight: Int): Size { w = inputWidth; h = inputHeight; return Size(inputWidth, inputHeight) }

    override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
        try {
            program.use()
            program.setSamplerTexIdUniform("uTexSampler", inputTexId, 0)
            program.setFloatsUniformIfPresent("uTexel", floatArrayOf(1f / w, 1f / h))
            setUniforms(program, w, h, presentationTimeUs)
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
}

/**
 * A separable box blur of radius [radius] (pixels, from the frame size) in two passes: horizontal into a private
 * texture, then [finalFragment] (which blurs that vertically and combines it with the input) into the output.
 */
@OptIn(UnstableApi::class)
private class TwoPassBlurProgram(
    useHdr: Boolean,
    finalFragment: String,
    private val radius: (Int, Int) -> Int,
    private val setUniforms: (GlProgram) -> Unit,
) : BaseGlShaderProgram(useHdr, 1) {
    private val horizontal = glProgram(LookShaders.VERTEX, LookShaders.BLUR_H)
    private val final = glProgram(LookShaders.VERTEX, finalFragment)
    private var w = 0
    private var h = 0
    private var tmpTex = -1
    private var tmpFbo = -1

    override fun configure(inputWidth: Int, inputHeight: Int): Size {
        if (inputWidth != w || inputHeight != h || tmpTex < 0) {
            freeTmp()
            w = inputWidth; h = inputHeight
            try {
                tmpTex = GlUtil.createTexture(w, h, /* useHighPrecisionColorComponents = */ false)
                tmpFbo = GlUtil.createFboForTexture(tmpTex)
            } catch (e: GlUtil.GlException) { throw VideoFrameProcessingException(e) }
        }
        return Size(inputWidth, inputHeight)
    }

    override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
        try {
            val r = radius(w, h).toFloat()
            val texel = floatArrayOf(1f / w, 1f / h)
            val prev = IntArray(1)
            GLES20.glGetIntegerv(GLES20.GL_FRAMEBUFFER_BINDING, prev, 0)
            GlUtil.focusFramebufferUsingCurrentContext(tmpFbo, w, h)
            horizontal.use()
            horizontal.setSamplerTexIdUniform("uTexSampler", inputTexId, 0)
            horizontal.setFloatsUniform("uTexel", texel)
            horizontal.setFloatUniform("uRadius", r)
            horizontal.bindAttributesAndUniforms()
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
            GlUtil.focusFramebufferUsingCurrentContext(prev[0], w, h)
            final.use()
            final.setSamplerTexIdUniform("uTexSampler", inputTexId, 0)
            final.setSamplerTexIdUniform("uBlurH", tmpTex, 1)
            final.setFloatsUniform("uTexel", texel)
            final.setFloatUniform("uRadius", r)
            setUniforms(final)
            final.bindAttributesAndUniforms()
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        } catch (e: GlUtil.GlException) {
            throw VideoFrameProcessingException(e, presentationTimeUs)
        }
    }

    private fun freeTmp() {
        try {
            if (tmpFbo >= 0) GlUtil.deleteFbo(tmpFbo)
            if (tmpTex >= 0) GlUtil.deleteTexture(tmpTex)
        } catch (e: GlUtil.GlException) { throw VideoFrameProcessingException(e) }
        tmpFbo = -1; tmpTex = -1
    }

    override fun release() {
        super.release()
        freeTmp()
        try { horizontal.delete(); final.delete() } catch (e: GlUtil.GlException) { throw VideoFrameProcessingException(e) }
    }
}

@OptIn(UnstableApi::class)
private fun glProgram(vertex: String, fragment: String): GlProgram = try {
    GlProgram(vertex, fragment).also { it.setBufferAttribute("aFramePosition", GlUtil.getNormalizedCoordinateBounds(), GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE) }
} catch (e: GlUtil.GlException) { throw VideoFrameProcessingException(e) }

/**
 * The shaders (GLSL ES 1.00). Texture coordinates have y up (GL), so the reference's top-down v is 1 − y; frames
 * arrive with straight (not premultiplied) alpha, which every pass keeps from the input.
 */
internal object LookShaders {
    const val VERTEX = """
attribute vec4 aFramePosition;
varying vec2 vTexSamplingCoord;
void main() {
  gl_Position = aFramePosition;
  vTexSamplingCoord = vec2(aFramePosition.x * 0.5 + 0.5, aFramePosition.y * 0.5 + 0.5);
}"""

    /** Up to 2·255 + 1 taps; radii are ≤ 164 px for a 4096 px short side. */
    private const val MAX_TAPS = "511"

    const val BLUR_H = """
precision highp float;
uniform sampler2D uTexSampler;
uniform vec2 uTexel;
uniform float uRadius;
varying vec2 vTexSamplingCoord;
void main() {
  vec3 s = vec3(0.0);
  float n = 2.0 * uRadius + 1.0;
  for (int k = 0; k < $MAX_TAPS; k++) {
    float o = float(k) - uRadius;
    if (o > uRadius) break;
    s += texture2D(uTexSampler, vTexSamplingCoord + vec2(o * uTexel.x, 0.0)).rgb;
  }
  gl_FragColor = vec4(s / n, 1.0);
}"""

    private const val BLUR_V_FN = """
uniform sampler2D uBlurH;
uniform vec2 uTexel;
uniform float uRadius;
vec3 blurV(vec2 p) {
  vec3 s = vec3(0.0);
  float n = 2.0 * uRadius + 1.0;
  for (int k = 0; k < $MAX_TAPS; k++) {
    float o = float(k) - uRadius;
    if (o > uRadius) break;
    s += texture2D(uBlurH, p + vec2(0.0, o * uTexel.y)).rgb;
  }
  return s / n;
}"""

    /** 1 sharpen: v + 1.5·s·(v − box(v)). */
    const val SHARPEN = """
precision highp float;
uniform sampler2D uTexSampler;
uniform float uAmount;
varying vec2 vTexSamplingCoord;
$BLUR_V_FN
void main() {
  vec4 c = texture2D(uTexSampler, vTexSamplingCoord);
  vec3 bl = blurV(vTexSamplingCoord);
  gl_FragColor = vec4(clamp(c.rgb + 1.5 * uAmount * (c.rgb - bl), 0.0, 1.0), c.a);
}"""

    /** 7 halation: highlights of box(v) above the threshold, tinted, screened. */
    const val HALATION = """
precision highp float;
uniform sampler2D uTexSampler;
uniform float uAmount;
uniform float uThreshold;
uniform vec3 uTint;
varying vec2 vTexSamplingCoord;
$BLUR_V_FN
void main() {
  vec4 c = texture2D(uTexSampler, vTexSamplingCoord);
  vec3 bl = blurV(vTexSamplingCoord);
  float l = dot(bl, vec3(0.2126, 0.7152, 0.0722));
  float hgl = clamp((l - uThreshold) / (1.0 - uThreshold), 0.0, 1.0) * uAmount;
  gl_FragColor = vec4(1.0 - (1.0 - c.rgb) * (1.0 - uTint * hgl), c.a);
}"""

    /** 2 chromatic aberration: red sampled outward, blue inward, from the centre (bilinear, clamp to edge). */
    const val CHROMATIC = """
precision highp float;
uniform sampler2D uTexSampler;
uniform float uShift;
varying vec2 vTexSamplingCoord;
void main() {
  vec2 p = vTexSamplingCoord;
  vec2 d = (p - 0.5) * uShift;
  vec4 c = texture2D(uTexSampler, p);
  float r = texture2D(uTexSampler, p + d).r;
  float b = texture2D(uTexSampler, p - d).b;
  gl_FragColor = vec4(r, c.g, b, c.a);
}"""

    /** 8 leak (screen), 9 vignette, 10 grain (mono, mid-tones, a float hash per cell and frame). */
    const val FINISH = """
precision highp float;
uniform sampler2D uTexSampler;
uniform vec2 uSize;
uniform float uLeakAmount;
uniform float uLeakAngle;
uniform vec3 uLeak0;
uniform vec3 uLeak1;
uniform float uVigAmount;
uniform float uVigSize;
uniform float uVigSoft;
uniform float uGrainAmount;
uniform float uGrainCell;
uniform float uFrame;
varying vec2 vTexSamplingCoord;
float hash13(vec3 p3) {
  p3 = fract(p3 * 0.1031);
  p3 += dot(p3, p3.zyx + 31.32);
  return fract((p3.x + p3.y) * p3.z);
}
void main() {
  vec4 c = texture2D(uTexSampler, vTexSamplingCoord);
  vec3 v = c.rgb;
  vec2 uv = vec2(vTexSamplingCoord.x, 1.0 - vTexSamplingCoord.y);
  if (uLeakAmount > 0.0) {
    vec2 cc = vec2(0.5 + 0.75 * cos(uLeakAngle), 0.5 - 0.75 * sin(uLeakAngle));
    float d = distance(uv, cc);
    float k = uLeakAmount * (1.0 - smoothstep(0.15, 0.95, d));
    vec3 lc = k * mix(uLeak0, uLeak1, smoothstep(0.1, 0.8, d));
    v = 1.0 - (1.0 - v) * (1.0 - lc);
  }
  if (uVigAmount != 0.0) {
    float r = length((uv - 0.5) * 2.0) / 1.41421356;
    float m = smoothstep(uVigSize, uVigSize + uVigSoft, r);
    v = uVigAmount > 0.0 ? v * (1.0 - uVigAmount * m) : v + (-uVigAmount) * m * (1.0 - v);
  }
  if (uGrainAmount > 0.0) {
    vec2 cell = floor(uv * uSize / uGrainCell);
    float n = hash13(vec3(cell, uFrame)) - 0.5;
    float l = dot(v, vec3(0.2126, 0.7152, 0.0722));
    v += uGrainAmount * n * (1.0 - abs(2.0 * l - 1.0) * 0.5);
  }
  gl_FragColor = vec4(clamp(v, 0.0, 1.0), c.a);
}"""
}

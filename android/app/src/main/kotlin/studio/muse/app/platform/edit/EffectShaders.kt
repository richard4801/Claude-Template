package studio.muse.app.platform.edit

import android.content.Context
import android.opengl.GLES20
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import studio.muse.core.edit.Effect
import studio.muse.core.edit.EffectId
import studio.muse.core.edit.Effects
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * The effects library on the GPU (studio.muse.core.edit.Effects is the reference, pixel for pixel): one pass, the
 * effect chosen by uId. Noise reads Perlin's permutation from a 256×1 texture (exact, as on the CPU and the server).
 * [startUs] is the item's start on the timeline (t = item-local seconds).
 */
@OptIn(UnstableApi::class)
class PictureEffect(private val e: Effect, private val startUs: Long) : GlEffect {
    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram {
        var perm = -1
        return SinglePassProgram(useHdr, EffectShaders.FRAGMENT) { p, w, h, timeUs ->
            if (perm < 0) perm = permTexture()
            val t = ((timeUs - startUs) / 1e6).coerceAtLeast(0.0)
            p.setSamplerTexIdUniform("uPerm", perm, 1)
            p.setIntUniform("uId", e.id.ordinal)
            p.setFloatUniform("uA", e.amount.coerceIn(0.0, 1.0).toFloat())
            p.setFloatUniform("uT", t.toFloat())
            p.setFloatUniform("uTs", (t * (e.speed ?: 1.0)).toFloat())
            p.setFloatsUniform("uSize", floatArrayOf(w.toFloat(), h.toFloat()))
            val cs = (e.colors ?: Effects.DUOTONE_DEFAULT).map { c -> floatArrayOf(c.substring(1, 3).toInt(16) / 255f, c.substring(3, 5).toInt(16) / 255f, c.substring(5, 7).toInt(16) / 255f) }
            p.setFloatsUniform("uDark", cs[0]); p.setFloatsUniform("uLight", cs[1])
        }
    }

    /** Perlin's permutation as a 256×1 texture (R = the value), nearest sampling. */
    private fun permTexture(): Int {
        val ids = IntArray(1); GLES20.glGenTextures(1, ids, 0)
        val buf = ByteBuffer.allocateDirect(256 * 4).order(ByteOrder.nativeOrder())
        for (v in Effects.PERM) { buf.put(v.toByte()); buf.put(0); buf.put(0); buf.put(-1) }
        buf.position(0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, ids[0])
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_NEAREST)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_NEAREST)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, 256, 1, 0, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, buf)
        return ids[0]
    }
}

internal object EffectShaders {
    /** Ids in EffectId order: glitch 0, vhs 1, film 2, blur 3, zoomBlur 4, mirror 5, pixelate 6, posterize 7, duotone 8, shake 9, flash 10, rain 11. */
    const val FRAGMENT = """
precision highp float;
uniform sampler2D uTexSampler;
uniform sampler2D uPerm;
uniform int uId;
uniform float uA;
uniform float uT;
uniform float uTs;
uniform vec2 uSize;
uniform vec3 uDark;
uniform vec3 uLight;
varying vec2 vTexSamplingCoord;
const float PI = 3.141592653589793;
// u, v with v down (the reference's frame); texture y is up.
vec3 S(float u, float v) { return texture2D(uTexSampler, vec2(clamp(u, 0.0, 1.0), 1.0 - clamp(v, 0.0, 1.0))).rgb; }
float P(float i) { return floor(texture2D(uPerm, vec2((mod(floor(i), 256.0) + 0.5) / 256.0, 0.5)).r * 255.0 + 0.5); }
float hash3(float i, float j, float k) { return P(P(P(i) + floor(j)) + floor(k)) / 255.0; }
void main() {
  vec4 src = texture2D(uTexSampler, vTexSamplingCoord);
  float u = vTexSamplingCoord.x; float v = 1.0 - vTexSamplingCoord.y;
  float a = clamp(uA, 0.0, 1.0); float ts = uTs; float W = uSize.x; float H = uSize.y;
  vec3 c = src.rgb;
  if (a <= 0.0) { gl_FragColor = src; return; }
  if (uId == 0) {
    float n = floor(ts * 12.0); float b = floor(v * 16.0);
    float u2 = hash3(b, n, 1.0) > 1.0 - 0.5 * a ? u + (hash3(b, n, 2.0) - 0.5) * 0.2 * a : u;
    float sp = 0.015 * a;
    c = vec3(S(u2 + sp, v).r, S(u2, v).g, S(u2 - sp, v).b);
  } else if (uId == 1) {
    float u2 = u + sin(40.0 * v + 6.0 * ts) * 0.004 * a;
    c = vec3(S(u2 + 0.006 * a, v).r, S(u2, v).g, S(u2 - 0.006 * a, v).b);
    float scan = 1.0 - 0.2 * a * (0.5 + 0.5 * cos(2.0 * PI * 240.0 * v));
    float nz = (hash3(floor(320.0 * u), floor(240.0 * v), floor(24.0 * ts)) - 0.5) * 0.1 * a;
    c = clamp(c * scan + nz, 0.0, 1.0);
  } else if (uId == 2) {
    c = S(u + sin(7.0 * ts) * 0.002 * a, v + cos(5.0 * ts) * 0.002 * a);
    float g = (hash3(floor(480.0 * u), floor(480.0 * v), floor(24.0 * uT)) - 0.5) * 0.16 * a;
    float dust = hash3(floor(160.0 * u), floor(160.0 * v), floor(12.0 * ts) + 7.0) >= 1.0 - 0.02 * a ? 0.35 : 1.0;
    c = clamp(vec3((c.r + g) * dust * (1.0 + 0.05 * a), (c.g + g) * dust, (c.b + g) * dust * (1.0 - 0.05 * a)), 0.0, 1.0);
  } else if (uId == 3) {
    float R = 0.02 * a; vec3 acc = vec3(0.0); float sum = 0.0;
    for (int i = 0; i < 13; i++) { float d = (float(i) - 6.0) / 3.0; sum += exp(-0.5 * d * d); }
    for (int i = 0; i < 13; i++) for (int j = 0; j < 13; j++) {
      float di = (float(i) - 6.0) / 3.0; float dj = (float(j) - 6.0) / 3.0;
      float k = exp(-0.5 * di * di) / sum * exp(-0.5 * dj * dj) / sum;
      acc += k * S(u + ((float(i) - 6.0) * R / 6.0) * H / W, v + (float(j) - 6.0) * R / 6.0);
    }
    c = acc;
  } else if (uId == 4) {
    vec3 acc = vec3(0.0);
    for (int k = 0; k < 10; k++) { float z = 1.0 - 0.15 * a * float(k) / 9.0; acc += S(0.5 + (u - 0.5) * z, 0.5 + (v - 0.5) * z) / 10.0; }
    c = acc;
  } else if (uId == 5) {
    float u2 = u < 0.5 ? u : 1.0 - u; float v2 = a >= 0.5 ? (v < 0.5 ? v : 1.0 - v) : v;
    c = S(u2, v2);
  } else if (uId == 6) {
    float n = floor(160.0 - 150.0 * a + 0.5); float cw = 1.0 / n; float ch = cw * W / H;
    c = S((floor(u / cw) + 0.5) * cw, (floor(v / ch) + 0.5) * ch);
  } else if (uId == 7) {
    float L = floor(16.0 - 13.0 * a + 0.5);
    c = floor(c * (L - 1.0) + 0.5) / (L - 1.0);
  } else if (uId == 8) {
    float y = dot(c, vec3(0.2126, 0.7152, 0.0722));
    c = mix(c, mix(uDark, uLight, y), a);
  } else if (uId == 9) {
    float n = floor(15.0 * ts); float z = 1.0 + 0.05 * a;
    c = S(0.5 + (u - 0.5) / z + (hash3(n, 3.0, 0.0) - 0.5) * 0.04 * a, 0.5 + (v - 0.5) / z + (hash3(n, 4.0, 0.0) - 0.5) * 0.04 * a);
  } else if (uId == 10) {
    float f = max(0.0, 1.0 - 4.0 * fract(ts));
    c = c + (1.0 - c) * f * a;
  } else {
    float cx = floor(48.0 * u);
    bool on = hash3(cx, 5.0, 0.0) < 0.6;
    float sp = 0.4 + 0.8 * hash3(cx, 6.0, 0.0);
    float y0 = fract(hash3(cx, 7.0, 0.0) + ts * sp);
    float d = fract(v - y0);
    float i = (on && d < 0.08) ? 1.0 - d / 0.08 : 0.0;
    c = clamp(S(u + 0.006 * a * i, v) + 0.12 * a * i, 0.0, 1.0);
  }
  gl_FragColor = vec4(c, src.a);
}"""
}

/** The effects tiles: each effect at 80 % on a small frame, with the CPU reference (Effects.pixel). */
object EffectThumbnails {
    fun render(frame: android.graphics.Bitmap, t: Double): Map<String, android.graphics.Bitmap> {
        val w = frame.width; val h = frame.height
        val px = IntArray(w * h); frame.getPixels(px, 0, w, 0, 0, w, h)
        val rgb = px.map { c -> doubleArrayOf(((c shr 16) and 255) / 255.0, ((c shr 8) and 255) / 255.0, (c and 255) / 255.0) }
        val sample = Effects.sampler(w, h, rgb)
        val out = HashMap<String, android.graphics.Bitmap>()
        out["none"] = frame
        for (id in EffectId.entries) {
            val e = Effect(id, 0.8)
            val o = IntArray(w * h)
            for (y in 0 until h) for (x in 0 until w) {
                val c = Effects.pixel(e, t, w, h, (x + 0.5) / w, (y + 0.5) / h, sample)
                fun ch(v: Double) = (v.coerceIn(0.0, 1.0) * 255 + 0.5).toInt()
                o[y * w + x] = (0xFF shl 24) or (ch(c[0]) shl 16) or (ch(c[1]) shl 8) or ch(c[2])
            }
            out[id.wire] = android.graphics.Bitmap.createBitmap(o, w, h, android.graphics.Bitmap.Config.ARGB_8888)
        }
        return out
    }
}

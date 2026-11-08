package studio.muse.app.platform.edit

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.opengl.GLES20
import androidx.annotation.OptIn
import androidx.media3.common.VideoFrameProcessingException
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import studio.muse.core.edit.PlannedClip
import studio.muse.core.edit.sourceUsAt
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Background removal's alpha matte (workstream 1, plans/api.md "VideoClip.alphaMatte"): the clip's alpha is the luma of
 * a matte video aligned with its source (white = opaque; [invert] flips it). It runs first in the clip's effects, on the
 * source frame, so the crop, look, mask and transform that follow see the cut-out subject.
 *
 * Media3 has no way to sample a second video inside an item's effect, so the effect decodes the matte itself
 * ([MatteFrames]: MediaExtractor + MediaCodec, the Y plane only) at the source time this frame shows
 * ([PlannedClip.sourceUsAt]: trims and speed pieces), and uploads it as a luminance texture. The presentation time an
 * effect sees is taken to be the composition's, as [TransitionFxEffect] does. Needs a real device to confirm: that
 * timing, and matte rotation against the source's.
 */
@OptIn(UnstableApi::class)
class AlphaMatteEffect(private val matte: File, private val clip: PlannedClip, private val invert: Boolean) : GlEffect {
    override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram = AlphaMatteProgram(MatteFrames(matte), clip, invert, useHdr)
}

@OptIn(UnstableApi::class)
private class AlphaMatteProgram(private val frames: MatteFrames, private val clip: PlannedClip, invert: Boolean, useHdr: Boolean) : BaseGlShaderProgram(useHdr, 1) {
    private val program: GlProgram = try { GlProgram(VERTEX, FRAGMENT) } catch (e: GlUtil.GlException) { throw VideoFrameProcessingException(e) }
    private var matteTex = 0
    private var texW = 0
    private var texH = 0

    init {
        program.setBufferAttribute("aFramePosition", GlUtil.getNormalizedCoordinateBounds(), GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE)
        program.setFloatUniform("uInvert", if (invert) 1f else 0f)
        program.setIntUniform("uRotation", (frames.rotation / 90) and 3)
    }

    override fun configure(inputWidth: Int, inputHeight: Int) = Size(inputWidth, inputHeight)

    override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
        try {
            val f = frames.at(clip.sourceUsAt(presentationTimeUs))
            if (f != null) upload(f)
            program.use()
            program.setSamplerTexIdUniform("uTexSampler", inputTexId, 0)
            // No matte frame (the file couldn't be read): the clip shows unmatted, as an app that doesn't know the field.
            program.setFloatUniform("uHasMatte", if (matteTex != 0) 1f else 0f)
            if (matteTex != 0) program.setSamplerTexIdUniform("uMatte", matteTex, 1)
            program.bindAttributesAndUniforms()
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        } catch (e: GlUtil.GlException) {
            throw VideoFrameProcessingException(e, presentationTimeUs)
        }
    }

    private fun upload(f: MatteFrame) {
        if (matteTex == 0) {
            val ids = IntArray(1)
            GLES20.glGenTextures(1, ids, 0)
            matteTex = ids[0]
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, matteTex)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        } else GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, matteTex)
        GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 1)
        if (f.width != texW || f.height != texH) {
            GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_LUMINANCE, f.width, f.height, 0, GLES20.GL_LUMINANCE, GLES20.GL_UNSIGNED_BYTE, f.luma)
            texW = f.width; texH = f.height
        } else GLES20.glTexSubImage2D(GLES20.GL_TEXTURE_2D, 0, 0, 0, f.width, f.height, GLES20.GL_LUMINANCE, GLES20.GL_UNSIGNED_BYTE, f.luma)
        GlUtil.checkGlError()
    }

    override fun release() {
        super.release()
        frames.close()
        try {
            if (matteTex != 0) GLES20.glDeleteTextures(1, intArrayOf(matteTex), 0)
            program.delete()
        } catch (e: GlUtil.GlException) { throw VideoFrameProcessingException(e) }
    }

    companion object {
        const val VERTEX = """
attribute vec4 aFramePosition;
varying vec2 vTexSamplingCoord;
void main() {
  gl_Position = aFramePosition;
  vTexSamplingCoord = vec2(aFramePosition.x * 0.5 + 0.5, aFramePosition.y * 0.5 + 0.5);
}"""
        // The matte's rows are top first (decoder memory order) and GL's v runs bottom up, so v is flipped; its stored
        // rotation (0/90/180/270, clockwise for display) turns the display coordinates back into the stored frame's.
        const val FRAGMENT = """
precision mediump float;
uniform sampler2D uTexSampler;
uniform sampler2D uMatte;
uniform float uInvert;
uniform float uHasMatte;
uniform int uRotation;
varying vec2 vTexSamplingCoord;
void main() {
  vec4 c = texture2D(uTexSampler, vTexSamplingCoord);
  vec2 d = vec2(vTexSamplingCoord.x, 1.0 - vTexSamplingCoord.y);
  vec2 s = d;
  if (uRotation == 1) s = vec2(d.y, 1.0 - d.x);
  else if (uRotation == 2) s = vec2(1.0 - d.x, 1.0 - d.y);
  else if (uRotation == 3) s = vec2(1.0 - d.y, d.x);
  float a = texture2D(uMatte, s).r;
  if (uInvert > 0.5) a = 1.0 - a;
  a = mix(1.0, a, uHasMatte);
  gl_FragColor = vec4(c.rgb, c.a * a);
}"""
    }
}

/** One matte frame: its luma, tightly packed, top row first. */
internal class MatteFrame(val width: Int, val height: Int, val luma: ByteBuffer, val timeUs: Long)

/**
 * Decodes a matte video's luma at requested source times. Frames are asked for in order while exporting, so it decodes
 * forward; a jump back (or more than a second ahead) seeks to the previous sync frame first. Returns the last frame at or
 * before the time, and keeps it when the time doesn't move.
 */
internal class MatteFrames(file: File) : AutoCloseable {
    private val extractor = MediaExtractor()
    private var codec: MediaCodec? = null
    private var current: MatteFrame? = null
    private var inputDone = false
    private var outputDone = false
    var rotation = 0
        private set

    init {
        runCatching {
            extractor.setDataSource(file.absolutePath)
            val track = (0 until extractor.trackCount).firstOrNull { extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true }
                ?: error("no video track")
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            if (format.containsKey(MediaFormat.KEY_ROTATION)) rotation = ((format.getInteger(MediaFormat.KEY_ROTATION) % 360) + 360) % 360
            codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!).apply { configure(format, null, null, 0); start() }
        }.onFailure { close() }
    }

    fun at(timeUs: Long): MatteFrame? {
        val c = codec ?: return null
        val cur = current
        if (cur != null && timeUs < cur.timeUs || cur != null && timeUs > cur.timeUs + 1_000_000) {
            extractor.seekTo(timeUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            c.flush(); inputDone = false; outputDone = false; current = null
        } else if (cur == null && !inputDone) extractor.seekTo(timeUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
        val info = MediaCodec.BufferInfo()
        var guard = 0
        while (!outputDone && guard++ < 600) {
            if (!inputDone) {
                val i = c.dequeueInputBuffer(10_000)
                if (i >= 0) {
                    val n = extractor.readSampleData(c.getInputBuffer(i)!!, 0)
                    if (n < 0) { c.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inputDone = true }
                    else { c.queueInputBuffer(i, 0, n, extractor.sampleTime, 0); extractor.advance() }
                }
            }
            val o = c.dequeueOutputBuffer(info, 10_000)
            if (o < 0) continue
            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
            if (info.size > 0) {
                val frame = c.getOutputImage(o)?.use { img ->
                    val y = img.planes[0]
                    val w = img.width; val h = img.height
                    val out = ByteBuffer.allocateDirect(w * h).order(ByteOrder.nativeOrder())
                    val row = ByteArray(w)
                    val src = y.buffer
                    for (r in 0 until h) {
                        src.position(r * y.rowStride)
                        if (y.pixelStride == 1) src.get(row, 0, w) else for (x in 0 until w) row[x] = src.get(r * y.rowStride + x * y.pixelStride)
                        out.put(row)
                    }
                    out.position(0)
                    MatteFrame(w, h, out, info.presentationTimeUs)
                }
                c.releaseOutputBuffer(o, false)
                if (frame != null) {
                    if (frame.timeUs <= timeUs || current == null) current = frame
                    if (frame.timeUs >= timeUs) break
                }
            } else c.releaseOutputBuffer(o, false)
        }
        return current
    }

    override fun close() {
        runCatching { codec?.stop() }; runCatching { codec?.release() }; codec = null
        runCatching { extractor.release() }
    }
}

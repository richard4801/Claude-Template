package studio.muse.core.edit

import kotlin.math.roundToInt

/*
 * Edit suite export settings (designs EM5 / E4; plans/video-editor.md "Edit suite additions" → Export): shape,
 * resolution, frame rate, codec, captions burned in or as an .SRT sidecar, and the Disclosure switches (both OFF by
 * default, per export — owner rule). Pure: the app turns the result into a render plan and a Transformer run.
 */

enum class ExportShape(val label: String, val w: Int, val h: Int) {
    PORTRAIT("9:16", 9, 16), SQUARE("1:1", 1, 1), FOUR_FIVE("4:5", 4, 5), FOUR_THREE("4:3", 4, 3), LANDSCAPE("16:9", 16, 9), CINEMA("2.35:1", 47, 20);

    /** [short] px on the short side at this shape (even numbers), scaled down to fit the contract's 4096 px long side. */
    fun sizeAt(short: Int): Pair<Int, Int> {
        fun even(v: Double) = maxOf(16, (v / 2).roundToInt() * 2)
        val r = w.toDouble() / h
        val long = maxOf(r, 1 / r) * short
        val k = if (long > 4096) 4096 / long else 1.0
        return if (w <= h) even(short * k) to even(short * k / r) else even(short * k * r) to even(short * k)
    }

    companion object {
        /** The shape closest to a canvas. */
        fun of(width: Int, height: Int): ExportShape = entries.minBy { kotlin.math.abs(it.w.toDouble() / it.h - width.toDouble() / height) }
    }
}

enum class ExportResolution(val label: String, val shortSide: Int) { HD("720p", 720), FULL_HD("1080p", 1080), QHD("2K", 1440), UHD("4K", 2160) }
enum class ExportCodec(val label: String) { H264("MP4 · H.264"), HEVC("MP4 · HEVC") }
enum class CaptionExport { BURN_IN, SRT }

/** What the export makes: the video (saved as a version), its sound alone (.m4a) or a GIF (both saved to the phone only). */
enum class ExportFormat(val label: String) { VIDEO("Video"), SOUND("Sound only"), GIF("GIF") }

/** The video bitrate against the recommended one (~0.12 bit per pixel per frame). */
enum class ExportBitrate(val label: String, val factor: Double) { LOWER("Smaller file", 0.6), RECOMMENDED("Recommended", 1.0), HIGHER("Higher quality", 1.6) }

/** GIF exports: short side, frame rate and the longest edit they take (longer GIFs get too big to share). */
const val GIF_SHORT_SIDE = 480
const val GIF_FPS = 15
const val GIF_MAX_SEC = 30.0
/** Sound-only exports: AAC at this bitrate. */
const val SOUND_BITRATE = 192_000

/** The video encoder's bitrate for a [w]×[h] canvas at [fps]: 4–40 Mbit/s recommended, scaled by [bitrate]; HEVC ≈ 60 %. */
fun videoBitrate(w: Int, h: Int, fps: Int, bitrate: ExportBitrate = ExportBitrate.RECOMMENDED, codec: ExportCodec = ExportCodec.H264): Int =
    ((w.toDouble() * h * fps * 0.12).coerceIn(4_000_000.0, 40_000_000.0) * bitrate.factor * (if (codec == ExportCodec.HEVC) 0.6 else 1.0)).roundToInt()

data class ExportSettings(
    val shape: ExportShape = ExportShape.PORTRAIT,
    val resolution: ExportResolution = ExportResolution.FULL_HD,
    val fps: Int = 30,
    val codec: ExportCodec = ExportCodec.H264,
    val captions: CaptionExport = CaptionExport.BURN_IN,
    /** Disclosure: "Label as AI-generated" — off by default. */
    val aiLabel: Boolean = false,
    /** Disclosure: "Content Credentials (C2PA)" — off by default; signing is not built yet ("Coming soon"). */
    val contentCredentials: Boolean = false,
    val format: ExportFormat = ExportFormat.VIDEO,
    val bitrate: ExportBitrate = ExportBitrate.RECOMMENDED,
) {
    /** The output size (even numbers, short side = the resolution; a GIF's is [GIF_SHORT_SIDE]). */
    val size: Pair<Int, Int>
        get() {
            return shape.sizeAt(if (format == ExportFormat.GIF) GIF_SHORT_SIDE else resolution.shortSide)
        }

    /** The frame rate of what's made (a GIF's is [GIF_FPS]). */
    val outFps: Int get() = if (format == ExportFormat.GIF) GIF_FPS else fps

    /**
     * Estimated file size in bytes over [durationSec]: video at [videoBitrate] plus 128 kbit/s of audio; sound only at
     * [SOUND_BITRATE]; a GIF at about a third of a byte per pixel per frame (8-bit LZW on video footage).
     */
    fun estimatedBytes(durationSec: Double): Long {
        val (w, h) = size
        return when (format) {
            ExportFormat.VIDEO -> ((videoBitrate(w, h, fps, bitrate, codec) + 128_000.0) * durationSec / 8).toLong()
            ExportFormat.SOUND -> (SOUND_BITRATE * durationSec / 8).toLong()
            ExportFormat.GIF -> (w.toDouble() * h * 0.33 * GIF_FPS * durationSec).toLong()
        }
    }

    /** Why this export can't be made from an edit of [durationSec] (with or without sound), or null. */
    fun refusal(durationSec: Double, hasSound: Boolean): String? = when {
        format == ExportFormat.SOUND && !hasSound -> "This edit has no sound to export"
        format == ExportFormat.GIF && durationSec > GIF_MAX_SEC + 1e-6 -> "GIFs are up to ${GIF_MAX_SEC.roundToInt()} s · trim the edit or export a video"
        else -> null
    }

    companion object {
        val FPS = listOf(24, 30, 60)

        /** Settings that match a project's canvas (shape and nearest resolution/fps). */
        fun forProject(p: EditProject): ExportSettings {
            val cv = p.canvas
            val short = minOf(cv.width, cv.height)
            return ExportSettings(
                shape = ExportShape.of(cv.width, cv.height),
                resolution = ExportResolution.entries.minBy { kotlin.math.abs(it.shortSide - short) },
                fps = FPS.minBy { kotlin.math.abs(it - cv.fps) },
            )
        }
    }
}

/**
 * The project as it is exported with [s]: the canvas set to the shape/resolution/fps (clips keep their fit, so
 * re-framing centres them; face-aware re-framing is a device step), and with captions as a sidecar the caption track
 * hidden (the .SRT comes from [toSrt] of the original). Validation still applies to the result.
 */
fun exportProject(p: EditProject, s: ExportSettings): EditProject {
    val (w, h) = s.size
    val tracks = if (s.captions == CaptionExport.SRT && s.format == ExportFormat.VIDEO) p.tracks.map { if (it.kind == TrackKind.CAPTION) it.copy(hidden = true) else it } else p.tracks
    return p.copy(canvas = p.canvas.copy(width = w, height = h, fps = s.outFps.toDouble()), tracks = tracks)
}

/** A byte count as "48 MB" / "1.2 GB". */
fun formatBytes(bytes: Long): String = when {
    bytes >= 1_000_000_000 -> String.format(java.util.Locale.ROOT, "%.1f GB", bytes / 1e9)
    bytes >= 1_000_000 -> "${(bytes / 1e6).roundToInt()} MB"
    else -> "${maxOf(1, (bytes / 1e3).roundToInt())} KB"
}

package studio.muse.core.edit

import kotlin.math.roundToInt

/*
 * Edit suite export settings (designs EM5 / E4; plans/video-editor.md "Edit suite additions" → Export): shape,
 * resolution, frame rate, codec, captions burned in or as an .SRT sidecar, and the Disclosure switches (both OFF by
 * default, per export — owner rule). Pure: the app turns the result into a render plan and a Transformer run.
 */

enum class ExportShape(val label: String, val w: Int, val h: Int) {
    PORTRAIT("9:16", 9, 16), SQUARE("1:1", 1, 1), FOUR_FIVE("4:5", 4, 5), LANDSCAPE("16:9", 16, 9);

    companion object {
        /** The shape closest to a canvas. */
        fun of(width: Int, height: Int): ExportShape = entries.minBy { kotlin.math.abs(it.w.toDouble() / it.h - width.toDouble() / height) }
    }
}

enum class ExportResolution(val label: String, val shortSide: Int) { HD("720p", 720), FULL_HD("1080p", 1080), QHD("2K", 1440), UHD("4K", 2160) }
enum class ExportCodec(val label: String) { H264("MP4 · H.264"), HEVC("MP4 · HEVC") }
enum class CaptionExport { BURN_IN, SRT }

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
) {
    /** The output size (even numbers, short side = the resolution). */
    val size: Pair<Int, Int>
        get() {
            val s = resolution.shortSide
            fun even(v: Double) = (v / 2).roundToInt() * 2
            return if (shape.w <= shape.h) s to even(s.toDouble() * shape.h / shape.w) else even(s.toDouble() * shape.w / shape.h) to s
        }

    /**
     * Estimated file size in bytes: the engine's bitrate (~0.12 bit per pixel per frame, 4–40 Mbit/s; HEVC ≈ 60 %) plus
     * 128 kbit/s of audio, over [durationSec].
     */
    fun estimatedBytes(durationSec: Double): Long {
        val (w, h) = size
        val video = (w.toDouble() * h * fps * 0.12).coerceIn(4_000_000.0, 40_000_000.0) * (if (codec == ExportCodec.HEVC) 0.6 else 1.0)
        return ((video + 128_000) * durationSec / 8).toLong()
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
    val tracks = if (s.captions == CaptionExport.SRT) p.tracks.map { if (it.kind == TrackKind.CAPTION) it.copy(hidden = true) else it } else p.tracks
    return p.copy(canvas = p.canvas.copy(width = w, height = h, fps = s.fps.toDouble()), tracks = tracks)
}

/** A byte count as "48 MB" / "1.2 GB". */
fun formatBytes(bytes: Long): String = when {
    bytes >= 1_000_000_000 -> String.format(java.util.Locale.ROOT, "%.1f GB", bytes / 1e9)
    bytes >= 1_000_000 -> "${(bytes / 1e6).roundToInt()} MB"
    else -> "${maxOf(1, (bytes / 1e3).roundToInt())} KB"
}

package studio.muse.app.data

import kotlinx.serialization.Serializable
import studio.muse.core.EditSegment
import studio.muse.core.VideoEdit

/**
 * Edited versions of a video take (plans/api.md "Video editor", plans/video-editor.md): the edit list as JSON and the
 * request that saves a device-encoded video as a new take (kind "edit") linked to its source.
 */
@Serializable
data class EditSegmentDto(val inSec: Double, val outSec: Double, val speed: Double = 1.0, val muted: Boolean? = null)

@Serializable
data class EditListDto(
    val version: Int = 1,
    val sourceTakeId: String,
    val sourceDurationSec: Double,
    val segments: List<EditSegmentDto>,
    val mute: Boolean = false,
) {
    fun toEdit(): VideoEdit? = segments.takeIf { it.isNotEmpty() }?.let { s ->
        VideoEdit(sourceDurationSec, s.map { EditSegment(it.inSec, it.outSec, it.speed, it.muted == true) }, mute)
    }

    companion object {
        /** Times rounded to milliseconds, so the JSON stays short and exact. */
        fun of(sourceTakeId: String, e: VideoEdit) = EditListDto(
            1, sourceTakeId, ms(e.sourceDurationSec),
            e.segments.map { EditSegmentDto(ms(it.inSec), ms(it.outSec), it.speed, if (it.muted) true else null) }, e.mute,
        )
        private fun ms(v: Double) = Math.round(v * 1000) / 1000.0
    }
}

/** POST /v1/takes/{id}/versions. `uploadId` = a presigned "clip" upload (PUT done, not confirmed). */
@Serializable
data class TakeVersionRequest(
    val uploadId: String,
    val thumbUploadId: String? = null,
    val edits: EditListDto,
    val durationSec: Double,
    val width: Int,
    val height: Int,
    val fps: Double? = null,
)

/** What the device made: the encoded MP4, a JPEG frame, and the file's real size, length and frame rate. */
data class EditedVideo(val file: java.io.File, val thumbJpeg: ByteArray?, val durationSec: Double, val width: Int, val height: Int, val fps: Double?)

/**
 * Which video an editor opens on, and which edit list (plans/video-editor.md "Where it opens"): an edited version
 * re-opens its edit list on its source take when that still exists; otherwise its own video, untouched.
 */
data class EditTarget(val source: Take, val initial: EditListDto?)

fun editTargetFor(take: Take, takes: List<Take>): EditTarget? {
    if (take.videoUrl == null) return null
    if (take.kind == "edit") {
        val src = takes.firstOrNull { it.id == take.parentTakeId && it.videoUrl != null }
        if (src != null) return EditTarget(src, take.edits?.takeIf { it.sourceTakeId == src.id })
    }
    return EditTarget(take, null)
}

/** The takes that can be opened in the editor: real videos only (renders and edited versions). */
val Take.editable: Boolean get() = (kind == "take" || kind == "edit") && videoUrl != null

/** A file body for a presigned PUT that reports how much has gone up (0..1), without loading the file into memory. */
internal class FileProgressBody(private val file: java.io.File, private val type: okhttp3.MediaType?, private val onProgress: (Float) -> Unit) : okhttp3.RequestBody() {
    override fun contentType() = type
    override fun contentLength() = file.length()
    override fun writeTo(sink: okio.BufferedSink) {
        val total = file.length().coerceAtLeast(1)
        var sent = 0L
        val buf = ByteArray(256 * 1024)
        onProgress(0f)
        file.inputStream().use { input ->
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                sink.write(buf, 0, n)
                sent += n
                onProgress(sent.toFloat() / total)
            }
        }
        sink.flush()
    }
}

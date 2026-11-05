package studio.muse.core

import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.round

/**
 * The on-device video editor's edit list (plans/video-editor.md, plans/api.md "Video editor"). Pure and immutable:
 * every operation returns a new [VideoEdit] (or null when it isn't allowed), so undo/redo is a list of values.
 * Times are seconds of the SOURCE video; the output plays the segments in order, each at its speed.
 */
object EditRules {
    val SPEEDS = listOf(0.5, 0.75, 1.0, 1.25, 1.5, 2.0)
    const val MAX_SEGMENTS = 50
    const val MIN_SEGMENT_SEC = 0.1
    const val MIN_OUTPUT_SEC = 0.5
    const val MAX_OUTPUT_SEC = 600.0
    const val HISTORY = 100

    fun speedLabel(s: Double): String = when (s) { 0.5 -> "0.5×"; 0.75 -> "0.75×"; 1.0 -> "1×"; 1.25 -> "1.25×"; 1.5 -> "1.5×"; 2.0 -> "2×"; else -> "${s}×" }

    /** "0:03.40" (minutes, seconds, hundredths). */
    fun time(sec: Double): String {
        val cs = round(sec.coerceAtLeast(0.0) * 100).toLong()
        val m = cs / 6000; val s = (cs / 100) % 60; val h = cs % 100
        return "$m:${s.toString().padStart(2, '0')}.${h.toString().padStart(2, '0')}"
    }

    /** Snaps a time to the nearest frame boundary (1/fps). */
    fun snap(sec: Double, fps: Double): Double = if (fps <= 0) sec else round(sec * fps) / fps
}

data class EditSegment(val inSec: Double, val outSec: Double, val speed: Double = 1.0, val muted: Boolean = false) {
    val sourceSec: Double get() = outSec - inSec
    val outputSec: Double get() = sourceSec / speed
    operator fun contains(t: Double) = t >= inSec && t < outSec
}

data class VideoEdit(val sourceDurationSec: Double, val segments: List<EditSegment>, val mute: Boolean = false) {
    init { require(segments.isNotEmpty()) { "an edit needs a segment" } }

    companion object {
        /** The source untouched: one segment, 1×, sound on. */
        fun untouched(durationSec: Double) = VideoEdit(durationSec, listOf(EditSegment(0.0, durationSec)))
    }

    val outputSec: Double get() = segments.sumOf { it.outputSec }
    val trimIn: Double get() = segments.first().inSec
    val trimOut: Double get() = segments.last().outSec
    val isUntouched: Boolean get() = this == untouched(sourceDurationSec)
    /** True when segment [i] plays silent (whole video or its own switch). */
    fun silent(i: Int) = mute || segments[i].muted

    /** The kept segment containing source time [t], or null when [t] is in a cut part (or trimmed off). */
    fun segmentAt(t: Double): Int? = segments.indexOfFirst { t in it }.takeIf { it >= 0 }
        ?: if (abs(t - trimOut) < 1e-9) segments.lastIndex else null

    /** Where source time [t] lands in the output (a cut part maps to the start of the next kept segment). */
    fun outputAt(t: Double): Double {
        var acc = 0.0
        for (s in segments) {
            if (t < s.inSec) return acc
            if (t < s.outSec) return acc + (t - s.inSec) / s.speed
            acc += s.outputSec
        }
        return acc
    }

    /** Source time at output time [o]: (segment index, source seconds). */
    fun sourceAt(o: Double): Pair<Int, Double> {
        var acc = 0.0
        segments.forEachIndexed { i, s ->
            if (o < acc + s.outputSec) return i to (s.inSec + (o - acc).coerceAtLeast(0.0) * s.speed)
            acc += s.outputSec
        }
        return segments.lastIndex to trimOut
    }

    /** Splits the segment under source time [t]; null when [t] is in a cut, too close (< 0.1 s) to an edge, or at the limit. */
    fun split(t: Double): VideoEdit? {
        val i = segments.indexOfFirst { t in it }.takeIf { it >= 0 } ?: return null
        val s = segments[i]
        if (t - s.inSec < EditRules.MIN_SEGMENT_SEC - 1e-9 || s.outSec - t < EditRules.MIN_SEGMENT_SEC - 1e-9) return null
        if (segments.size >= EditRules.MAX_SEGMENTS) return null
        return copy(segments = segments.toMutableList().apply { set(i, s.copy(outSec = t)); add(i + 1, s.copy(inSec = t)) })
    }

    /** Cuts segment [i] out. The last remaining segment can't be deleted. */
    fun delete(i: Int): VideoEdit? {
        if (segments.size <= 1 || i !in segments.indices) return null
        val next = copy(segments = segments.filterIndexed { k, _ -> k != i })
        return next.takeIf { it.outputSec >= EditRules.MIN_OUTPUT_SEC - 1e-9 }
    }

    /** Speed of segment [i], or of every segment when [i] is null. */
    fun speed(i: Int?, speed: Double): VideoEdit? {
        require(speed in EditRules.SPEEDS) { "speed $speed" }
        val next = copy(segments = segments.mapIndexed { k, s -> if (i == null || k == i) s.copy(speed = speed) else s })
        return next.takeIf { it != this && it.outputSec in EditRules.MIN_OUTPUT_SEC - 1e-9..EditRules.MAX_OUTPUT_SEC }
    }

    fun muteAll(on: Boolean): VideoEdit? = copy(mute = on).takeIf { it != this }
    fun muteSegment(i: Int, on: Boolean): VideoEdit? =
        copy(segments = segments.mapIndexed { k, s -> if (k == i) s.copy(muted = on) else s }).takeIf { it != this }

    /** The least source seconds an end segment can keep: 0.1 s, and enough for the whole output to stay ≥ 0.5 s. */
    private fun minLength(s: EditSegment): Double =
        maxOf(EditRules.MIN_SEGMENT_SEC, (EditRules.MIN_OUTPUT_SEC - (outputSec - s.outputSec)) * s.speed).coerceAtMost(s.sourceSec)

    /** Moves the start handle (clamped: ≥ 0, and the first segment keeps [minLength]). */
    fun trimStart(t: Double): VideoEdit? {
        val f = segments.first()
        val v = t.coerceIn(0.0, f.outSec - minLength(f))
        return copy(segments = listOf(f.copy(inSec = v)) + segments.drop(1)).takeIf { it != this && it.outputSec >= EditRules.MIN_OUTPUT_SEC - 1e-9 }
    }

    /** Moves the end handle (clamped: ≤ the source's end, and the last segment keeps [minLength]). */
    fun trimEnd(t: Double): VideoEdit? {
        val l = segments.last()
        val v = t.coerceIn(l.inSec + minLength(l), sourceDurationSec)
        return copy(segments = segments.dropLast(1) + l.copy(outSec = v)).takeIf { it != this && it.outputSec >= EditRules.MIN_OUTPUT_SEC - 1e-9 }
    }

    /** The server's rules (plans/video-editor.md "Edit list"); null when valid, else the reason. */
    fun problem(): String? {
        if (segments.size > EditRules.MAX_SEGMENTS) return "At most ${EditRules.MAX_SEGMENTS} parts"
        var prev = 0.0
        segments.forEachIndexed { i, s ->
            if (s.speed !in EditRules.SPEEDS) return "Speed ${s.speed} isn't allowed"
            if (s.sourceSec < EditRules.MIN_SEGMENT_SEC - 1e-9) return "Part ${i + 1} is too short"
            if (s.inSec < 0 || s.outSec > sourceDurationSec + 0.05) return "Part ${i + 1} is outside the video"
            if (i > 0 && s.inSec < prev - 1e-9) return "Parts overlap"
            prev = s.outSec
        }
        if (outputSec < EditRules.MIN_OUTPUT_SEC - 1e-9) return "The edit must be at least ${EditRules.MIN_OUTPUT_SEC} s"
        if (outputSec > EditRules.MAX_OUTPUT_SEC) return "The edit must be at most ${EditRules.MAX_OUTPUT_SEC.toInt()} s"
        return null
    }

    /** Each segment's bounds snapped to frames (export and save use the snapped list). */
    fun snapped(fps: Double): VideoEdit = if (fps <= 0) this else copy(segments = segments.map {
        it.copy(inSec = EditRules.snap(it.inSec, fps), outSec = minOf(EditRules.snap(it.outSec, fps), sourceDurationSec))
    })
}

/** Undo / redo over edit values (every change; Reset is a change too, so it can be undone). */
class EditHistory(initial: VideoEdit, private val limit: Int = EditRules.HISTORY) {
    private val past = ArrayDeque<VideoEdit>()
    private val future = ArrayDeque<VideoEdit>()
    var current: VideoEdit = initial
        private set
    val canUndo get() = past.isNotEmpty()
    val canRedo get() = future.isNotEmpty()

    /** Applies [next] when it's a change (null = not allowed, nothing happens). Returns whether it applied. */
    fun apply(next: VideoEdit?): Boolean {
        if (next == null || next == current) return false
        past.addLast(current)
        while (past.size > limit) past.removeFirst()
        future.clear()
        current = next
        return true
    }

    fun undo(): Boolean { val p = past.removeLastOrNull() ?: return false; future.addLast(current); current = p; return true }
    fun redo(): Boolean { val n = future.removeLastOrNull() ?: return false; past.addLast(current); current = n; return true }
    fun reset(): Boolean = apply(VideoEdit.untouched(current.sourceDurationSec))
}

/** Thumbnail times for the timeline strip: [count] frames spread over the source, at each tile's middle. */
fun stripTimes(durationSec: Double, count: Int): List<Double> =
    if (count <= 0 || durationSec <= 0) emptyList() else List(count) { i -> floor(((i + 0.5) * durationSec / count) * 1000) / 1000 }

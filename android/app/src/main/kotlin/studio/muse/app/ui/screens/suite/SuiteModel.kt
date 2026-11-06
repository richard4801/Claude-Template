package studio.muse.app.ui.screens.suite

import studio.muse.app.data.Job
import studio.muse.app.data.SuiteCastMember
import studio.muse.app.data.SuiteRules
import studio.muse.app.data.SuiteShotRequest
import studio.muse.app.data.Take
import studio.muse.app.ui.screens.StagePhase
import studio.muse.app.ui.screens.StudioStage
import studio.muse.app.ui.screens.suite.composer.ComposerSettings
import studio.muse.app.ui.screens.suite.composer.PromptPart
import kotlin.math.ceil
import kotlin.math.roundToInt

// The AI suite's state, pure (no Compose, no I/O), so the rules are unit-tested: the Recast and Storyboard drafts and the
// requests they send, and the result pane's member-safe wording. The composer's state is in composer/ComposerModel.kt.

/**
 * Recast: one person of the source clip and who they become. [hint]: left / center / right / foreground / background.
 * [tap] is where the face was tapped on the clip's first frame (0..1 of the frame), [faceCrop] the uploaded square around
 * it (sent as `cast[i].faceCrop`); [hintPicked] = the user chose a position chip, which wins over the tap's third.
 */
data class RecastPerson(
    val hint: String,
    val characterId: String? = null,
    val outfitId: String? = null,
    val speaking: Boolean? = null,
    val tap: FaceTap? = null,
    val faceCrop: studio.muse.app.data.ImageRef? = null,
    val hintPicked: Boolean = false,
    /** The face crop is uploading. */
    val cropping: Boolean = false,
)

/** A tapped face on the first frame: x and y as fractions of the frame; [id] tells this tap's crop upload apart. */
data class FaceTap(val x: Float, val y: Float, val id: Long = 0)

/** The square cut around a tapped face, in frame pixels. */
data class FaceCrop(val left: Int, val top: Int, val side: Int)

/** "Tap a face": the maths from a tap on the first frame to the person's position and crop. Pure, unit-tested. */
object FaceMath {
    /** The crop's side as a share of the frame's short side. */
    const val CROP_SHARE = .28f
    /** A tap this close (fraction of the frame) to a marker picks that person instead of adding one. */
    const val NEAR = .08f

    /** The position a tap reads as: the frame's left, middle or right third. */
    fun hint(x: Float): String = when {
        x < 1f / 3 -> "left"
        x < 2f / 3 -> "center"
        else -> "right"
    }

    /** A square of about 28% of the frame's short side centred on the tap, moved inside the frame at the edges. */
    fun crop(width: Int, height: Int, x: Float, y: Float): FaceCrop {
        val short = minOf(width, height).coerceAtLeast(1)
        val side = kotlin.math.round(short * CROP_SHARE).toInt().coerceIn(1, short)
        val left = kotlin.math.round(x.coerceIn(0f, 1f) * width - side / 2f).toInt().coerceIn(0, (width - side).coerceAtLeast(0))
        val top = kotlin.math.round(y.coerceIn(0f, 1f) * height - side / 2f).toInt().coerceIn(0, (height - side).coerceAtLeast(0))
        return FaceCrop(left, top, side)
    }
}

/** Character swap (M6) with Recast inside: up to 4 people of one clip, each → a studio character. */
data class RecastDraft(
    val clipId: String? = null,
    val people: List<RecastPerson> = listOf(RecastPerson("center")),
    val quality: String = "standard",
    val keepAudio: Boolean = true,
    val takes: Int = 1,
) {
    val canAdd: Boolean get() = people.size < SuiteRules.MAX_CAST
    /** Room for one more under the catalog's `recastMaxPeople`. */
    fun canAdd(max: Int): Boolean = people.size < max.coerceIn(1, SuiteRules.MAX_CAST)

    fun add(): RecastDraft = if (!canAdd) this else {
        // Two people read left and right; a third and fourth take the next free spot.
        val spread = if (people.size == 1 && people[0].hint == "center" && people[0].tap == null && !people[0].hintPicked) listOf(people[0].copy(hint = "left")) else people
        val free = ADD_ORDER.firstOrNull { h -> spread.none { it.hint == h } } ?: "center"
        copy(people = spread + RecastPerson(free))
    }

    fun remove(i: Int) = if (people.size <= 1) this else copy(people = people.filterIndexed { k, _ -> k != i })
    fun update(i: Int, f: (RecastPerson) -> RecastPerson) = copy(people = people.mapIndexed { k, p -> if (k == i) f(p) else p })

    /** A position chip: from now on it wins over the tapped third. */
    fun pickHint(i: Int, h: String) = update(i) { it.copy(hint = h, hintPicked = true) }

    /**
     * A tap on the first frame at ([x], [y]). Near a marker: that person (unchanged). Otherwise the first person without a
     * face takes it, or a new person is added while there is room ([max], the catalog's `recastMaxPeople`). The position
     * follows the tap's third unless a chip was picked. Returns the new draft and the person's index (null = full).
     */
    fun tapFace(x: Float, y: Float, max: Int, id: Long = 0): Pair<RecastDraft, Int?> {
        people.indexOfFirst { p -> p.tap != null && kotlin.math.abs(p.tap.x - x) < FaceMath.NEAR && kotlin.math.abs(p.tap.y - y) < FaceMath.NEAR }
            .takeIf { it >= 0 }?.let { return this to it }
        val tap = FaceTap(x, y, id)
        fun placed(p: RecastPerson) = p.copy(tap = tap, faceCrop = null, cropping = true, hint = if (p.hintPicked) p.hint else FaceMath.hint(x))
        val free = people.indexOfFirst { it.tap == null }
        if (free >= 0) return update(free) { placed(it) } to free
        if (!canAdd(max)) return this to null
        return copy(people = people + placed(RecastPerson(FaceMath.hint(x)))) to people.size
    }

    /** The uploaded crop of tap [tapId] (null = the upload failed: the marker stays and the position still points at them). */
    fun setCrop(tapId: Long, ref: studio.muse.app.data.ImageRef?) =
        copy(people = people.map { if (it.tap?.id == tapId) it.copy(faceCrop = ref, cropping = false) else it })

    /** Forgets a tapped face (the marker goes; the person and their character stay). */
    fun clearTap(i: Int) = update(i) { it.copy(tap = null, faceCrop = null, cropping = false) }

    /** What stops Generate (null = ready). People with a face crop may share a third; the others must point at different spots. */
    fun problem(): String? {
        val loose = people.filter { it.faceCrop == null }
        return when {
            clipId == null -> "Choose the source clip"
            people.any { it.characterId == null } -> "Pick who each person becomes"
            people.any { it.cropping } -> "Waiting for the face upload"
            loose.map { it.hint }.toSet().size != loose.size -> "Two people point at the same spot"
            else -> null
        }
    }

    fun request(): SuiteShotRequest = SuiteShotRequest(
        mode = "recast", clipId = clipId, quality = quality, keepAudio = keepAudio, takes = takes,
        cast = people.mapNotNull { p ->
            p.characterId?.let { SuiteCastMember(it, p.outfitId, personHint = p.hint, speaking = if (people.size == 1 && p.speaking == null) null else p.speaking, faceCrop = p.faceCrop) }
        },
    )

    companion object {
        val HINTS = listOf("center", "left", "right", "foreground", "background")
        private val ADD_ORDER = listOf("left", "right", "center", "foreground", "background")
        fun hintLabel(h: String) = when (h) { "center" -> "Centre"; "foreground" -> "Front"; "background" -> "Back"; else -> h.replaceFirstChar { it.uppercase() } }
    }
}

/** One shot of a storyboard: its own words, move and length; cast, look and lens are locked across the board. */
data class StoryShot(val id: String, val title: String, val prompt: String, val move: String, val seconds: Int, val jobId: String? = null)

/** Storyboard (M7): shots with one cast and a look lock. */
data class Storyboard(
    val title: String,
    val cast: List<String>,
    val lookLock: String = "cinematic",
    val quality: String = "hd",
    val shots: List<StoryShot> = emptyList(),
) {
    val seconds: Int get() = shots.sumOf { it.seconds }

    /** Shots Generate makes: never made, or failed (refunded). */
    fun pending(jobs: List<Job>): List<StoryShot> = shots.filter { s -> s.jobId == null || jobs.firstOrNull { it.id == s.jobId }?.failed == true }

    /** One shot's request: the board's cast and quality, the composer's chips as the look lock, the shot's own move. */
    fun request(s: StoryShot, look: ComposerSettings, index: Int): SuiteShotRequest = SuiteShotRequest(
        title = "$title · ${index + 1}", modelId = cast.firstOrNull(), prompt = s.prompt, duration = s.seconds, quality = quality,
        camera = look.cameraJson(listOf(PromptPart.Move(s.move, s.move, "", 60, 1))),
    )

    fun withJob(shotId: String, jobId: String) = copy(shots = shots.map { if (it.id == shotId) it.copy(jobId = jobId) else it })
}

/** A storyboard shot's badge: READY, 40%, #2 IN LINE, FAILED or NOT MADE. kind: good | busy | warn | bad | "" */
data class StoryStatus(val label: String, val kind: String)

fun storyStatus(s: StoryShot, jobs: List<Job>): StoryStatus {
    val j = s.jobId?.let { id -> jobs.firstOrNull { it.id == id } } ?: return StoryStatus("Not made", "")
    val st = SuitePane.of(j, emptyList(), null)
    return when (st.phase) {
        StagePhase.READY -> StoryStatus("Ready", "good")
        StagePhase.FAILED -> StoryStatus("Failed · free retry", "bad")
        StagePhase.QUEUED -> StoryStatus(st.badge, "warn")
        StagePhase.RENDERING -> StoryStatus(st.percent, "busy")
        StagePhase.IDLE -> StoryStatus("Not made", "")
    }
}

/**
 * The result pane (D10 / M8) for one shot job: empty, in line, rendering (take n of N, %, the named step and time left),
 * ready (its takes) or failed (plain words, no charge). Member-safe: built on [StudioStage], never engine words.
 */
data class SuitePane(
    val phase: StagePhase = StagePhase.IDLE,
    /** "Rendering take 2 of 2", "#2 in line · ~1 min", "Ready", "Failed". */
    val headline: String = "",
    val percent: String = "",
    val progress: Float = 0f,
    /** "#2 in line" for small badges. */
    val badge: String = "",
    /** The named step and time ("Motion & camera · ~2 min"). */
    val step: String = "",
    /** The three named steps and where the take is (0 keyframe, 1 motion & camera, 2 sharpen & finish). */
    val stepIndex: Int = 0,
    val price: String = "",
    val takes: List<Take> = emptyList(),
    val failure: String? = null,
) {
    companion object {
        val STEPS = listOf("Keyframe from %s’s sheet", "Motion & camera", "Sharpen & finish")

        fun stepNames(lead: String?) = listOf(if (lead.isNullOrBlank()) "Keyframe" else STEPS[0].format(lead.substringBefore(' ')), STEPS[1], STEPS[2])

        fun of(job: Job?, takes: List<Take>, lead: String?): SuitePane {
            val st = StudioStage.of(job, takes)
            val j = job ?: return SuitePane()
            val left = j.etaSeconds ?: j.secondsLeft
            val time = if (left > 0) " · ~${about(left)}" else ""
            return when (st.phase) {
                StagePhase.IDLE -> SuitePane()
                StagePhase.READY -> SuitePane(StagePhase.READY, "Ready", "100%", 1f, "Ready", price = st.price, takes = st.takes)
                StagePhase.FAILED -> SuitePane(StagePhase.FAILED, "Failed", st.percent, st.progress, "Failed", price = st.price, failure = st.failure)
                StagePhase.QUEUED -> {
                    val pos = j.queuePosition
                    val badge = if (pos != null && pos > 1) "#$pos in line" else "In line"
                    SuitePane(StagePhase.QUEUED, badge + time, "0%", 0f, badge, "Leaving is safe · we'll tell you when it's ready", price = st.price)
                }
                StagePhase.RENDERING -> {
                    val n = j.request.takes.coerceAtLeast(1)
                    val take = j.take.coerceIn(1, n)
                    val inTake = (st.progress * n - (take - 1)).coerceIn(0f, 1f)
                    val idx = when { inTake < .2f -> 0; inTake < .85f -> 1; else -> 2 }
                    val head = if (n > 1) "Rendering take $take of $n" else "Rendering"
                    SuitePane(StagePhase.RENDERING, head, st.percent, st.progress, st.percent, stepNames(lead)[idx] + time, idx, st.price)
                }
            }
        }

        /** "2 min", "40 s". */
        fun about(sec: Double): String = if (sec >= 60) "${ceil(sec / 60).toInt()} min" else "${ceil(sec).toInt().coerceAtLeast(1)} s"
    }
}

/** The quality ladder's next step up ("Try Standard" after a failed Draft), or null at Cinema. */
fun nextTier(id: String?): String? = SuiteRules.TIERS.indexOf(id ?: "draft").let { i -> SuiteRules.TIERS.getOrNull(i + 1) }

/** "62%" as a whole number. */
fun pct(p: Float) = "${(p * 100).roundToInt()}%"

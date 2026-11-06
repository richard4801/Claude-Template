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

/** Recast: one person of the source clip and who they become. [hint]: left / center / right / foreground / background. */
data class RecastPerson(val hint: String, val characterId: String? = null, val outfitId: String? = null, val speaking: Boolean? = null)

/** Character swap (M6) with Recast inside: up to 4 people of one clip, each → a studio character. */
data class RecastDraft(
    val clipId: String? = null,
    val people: List<RecastPerson> = listOf(RecastPerson("center")),
    val quality: String = "standard",
    val keepAudio: Boolean = true,
    val takes: Int = 1,
) {
    val canAdd: Boolean get() = people.size < SuiteRules.MAX_CAST

    fun add(): RecastDraft = if (!canAdd) this else {
        // Two people read left and right; a third and fourth take the next free spot.
        val spread = if (people.size == 1 && people[0].hint == "center") listOf(people[0].copy(hint = "left")) else people
        val free = ADD_ORDER.first { h -> spread.none { it.hint == h } }
        copy(people = spread + RecastPerson(free))
    }

    fun remove(i: Int) = if (people.size <= 1) this else copy(people = people.filterIndexed { k, _ -> k != i })
    fun update(i: Int, f: (RecastPerson) -> RecastPerson) = copy(people = people.mapIndexed { k, p -> if (k == i) f(p) else p })

    /** What stops Generate (null = ready). */
    fun problem(): String? = when {
        clipId == null -> "Choose the source clip"
        people.any { it.characterId == null } -> "Pick who each person becomes"
        people.map { it.hint }.toSet().size != people.size -> "Two people point at the same spot"
        else -> null
    }

    fun request(): SuiteShotRequest = SuiteShotRequest(
        mode = "recast", clipId = clipId, quality = quality, keepAudio = keepAudio, takes = takes,
        cast = people.mapIndexedNotNull { i, p ->
            p.characterId?.let { SuiteCastMember(it, p.outfitId, personHint = p.hint, speaking = if (people.size == 1 && p.speaking == null) null else p.speaking) }
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

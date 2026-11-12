package studio.muse.app.ui.screens

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import studio.muse.app.data.ErrorText
import studio.muse.app.data.Job
import studio.muse.app.data.Take
import studio.muse.core.Pricing
import kotlin.math.roundToInt

/** Where the Video studio's stage (its preview canvas) is: the target, a render waiting or running, its takes, or a failure. */
enum class StagePhase { IDLE, QUEUED, RENDERING, READY, FAILED }

/**
 * The Video studio's live stage (owner request 2026-11-05, same as the Mac's `StudioStage`). Pure: built from the job and
 * take lists the live events keep up to date, so it moves idle → queued → rendering → ready / failed by itself.
 * Member-safe wording only: results, time and price, never providers, models or GPUs.
 */
data class StudioStage(
    val phase: StagePhase = StagePhase.IDLE,
    val jobId: String? = null,
    /** "Waiting to start", "#2 in line · about 9 min", "Rendering · about 2 min", "Ready", or what went wrong. */
    val headline: String = "",
    /** 0..1. */
    val progress: Float = 0f,
    /** "42%". */
    val percent: String = "",
    /** The render's price ("$0.14"). */
    val price: String = "",
    /** Ready: the render's takes, take 1 first (edited versions aren't takes of the render). */
    val takes: List<Take> = emptyList(),
    /** Failed: what went wrong, in member words. */
    val failure: String? = null,
) {
    /** Waiting or rendering: the blurred, animated preview. */
    val busy: Boolean get() = phase == StagePhase.QUEUED || phase == StagePhase.RENDERING

    /** The take to play: the one picked in the take switcher while it's still there, else take 1. */
    fun take(id: String?): Take? = takes.firstOrNull { it.id == id } ?: takes.firstOrNull()

    /** "Take 1 of 2" (null for a single take). */
    fun takeLabel(t: Take): String? = if (takes.size > 1) "Take ${t.index} of ${maxOf(t.of, takes.size)}" else null

    companion object {
        val IDLE = StudioStage()

        /** The stage for one render (null = idle). */
        fun of(job: Job?, takes: List<Take>): StudioStage {
            val j = job ?: return IDLE
            val price = Pricing.money(j.cost)
            val p = (j.progress / 100.0).coerceIn(0.0, 1.0).toFloat()
            if (j.failed) {
                val why = failure(j)
                return StudioStage(StagePhase.FAILED, j.id, why, p, percent(p), price, failure = why)
            }
            if (j.done) {
                val mine = takes.filter { it.jobId == j.id && it.kind == "take" }.sortedBy { it.index }
                return StudioStage(StagePhase.READY, j.id, "Ready", 1f, "100%", price, mine)
            }
            if (j.state != "running" && j.state != "queued") return IDLE
            val left = j.etaSeconds ?: j.secondsLeft
            val time = if (left > 0) " · about ${aboutTime(left)}" else ""
            // Parked, or waiting in line on the real API (a place in line): nothing has rendered yet.
            if (j.state == "queued" || j.queuePosition != null) {
                val pos = j.queuePosition
                val line = (if (pos != null && pos > 1) "#$pos in line" else WAITING) + (if (pos != null) time else "")
                return StudioStage(StagePhase.QUEUED, j.id, line, 0f, "0%", price)
            }
            val phase = memberPhase(j.phase)
            // Older servers only say they're waiting in the phase ("Waiting for a GPU" → "Waiting to start").
            if (phase.endsWith(WAITING) || Regex("#\\d+ in line$").containsMatchIn(phase)) {
                return StudioStage(StagePhase.QUEUED, j.id, phase, p, percent(p), price)
            }
            return StudioStage(StagePhase.RENDERING, j.id, phase + time, p, percent(p), price)
        }

        /**
         * The render the stage follows: the newest one started from the studio ([started], oldest first) that is still for
         * this clip, model and outfit. Picking another clip, model or outfit puts the stage back to idle (the target);
         * picking them again brings that render back.
         */
        fun job(jobs: List<Job>, started: List<String>, clipId: String?, modelId: String?, outfitId: String?): Job? {
            for (id in started.asReversed()) {
                val j = jobs.firstOrNull { it.id == id } ?: continue
                if (modelId != null && j.modelId != modelId) continue
                if (outfitId != null && j.outfitId != outfitId && j.request.outfitId != outfitId) continue
                if (clipId != null && j.request.clipId.isNotEmpty() && j.request.clipId != clipId) continue
                return j
            }
            return null
        }

        fun resolve(jobs: List<Job>, takes: List<Take>, started: List<String>, clipId: String?, modelId: String?, outfitId: String?): StudioStage =
            of(job(jobs, started, clipId, modelId, outfitId), takes)

        /** What went wrong: the server's message when it's member-safe, else the contract's wording for its code. */
        fun failure(j: Job): String {
            val e = j.error?.trim()?.takeIf { it.isNotEmpty() && !TECHNICAL.containsMatchIn(it) }
            return e ?: when (j.errorCode) {
                "provider_refused" -> "This clip was refused by the content filter · you weren't charged"
                "provider_rate_limited" -> "Busy right now · you weren't charged. Try again in a minute."
                "provider_timeout" -> "This took too long and was stopped · you weren't charged"
                "provider_out_of_credit" -> "Something went wrong · you weren't charged. The studio owner has been told."
                "provider_paid_unsaved" -> "Your video was made (the provider charged the studio) but MUSE couldn't save it · it can be recovered for free"
                "provider_unconfirmed" -> "The provider didn't finish in time and may still charge the studio · it can be recovered for free if it finishes"
                else -> ErrorText.WENT_WRONG
            }
        }

        private fun percent(p: Float) = "${(p * 100).roundToInt()}%"
        private const val WAITING = "Waiting to start"

        /** Words members never see (the same list as the Mac's `MemberText`). */
        private val TECHNICAL = Regex(
            "(?i)\\bgpus?\\b|warm[- ]?up|\\bwarm\\b|runpod|replicate|\\bh(100|200|3)\\b|\\blite\\b|seedvr|\\bsteps?\\b|start-?up|\\bpods?\\b|latentsync|viggle|minimax|flux|qwen|safety filter|cuda",
        )
    }
}

/** Fixed studio wording. */
object StudioText {
    /** The empty source area before a clip is uploaded (the phone has no drop, so it says choose). */
    const val CHOOSE_TITLE = "Choose a clip"
    const val CHOOSE_HINT = "Up to 15s works best · 9:16 · one person"

    /** "Never add: tattoos, rings. Removed automatically." under the outfit, or null when the model has nothing on the list. */
    fun neverAdd(items: List<String>?): String? {
        val list = items.orEmpty().map { it.trim() }.filter { it.isNotEmpty() }
        return if (list.isEmpty()) null else "Never add: ${list.joinToString(", ")}. Removed automatically."
    }
}

/** The renders started from the Video studio this session (oldest first), and the take picked in the stage's switcher. */
class StageJobs {
    val ids = MutableStateFlow<List<String>>(emptyList())
    val take = MutableStateFlow<String?>(null)

    fun started(jobId: String) {
        ids.update { (it - jobId) + jobId }
        take.value = null
    }

    fun clear() {
        ids.value = emptyList()
        take.value = null
    }
}

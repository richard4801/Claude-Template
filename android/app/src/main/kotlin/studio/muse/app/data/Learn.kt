package studio.muse.app.data

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

/*
 * The learning editor (workstream 3, plans/api.md "Learning editor", `/v1/learn`, owner only): the playbook of rules
 * Claude follows, the lessons and corrections they come from, the recipe library and the effects MUSE can't make yet.
 * Screens: ui/screens/edit/learn (plans/learning-editor-ui.md, the owner-approved mocks).
 */

/** The server's areas, in the order the playbook groups them. */
val LEARN_AREAS = listOf("captions", "text", "pacing", "transition", "look", "motion", "speed", "timing", "audio", "ratio", "other")

/** An area as the screens name it. */
fun learnAreaLabel(a: String): String = when (a) {
    "captions" -> "Captions"; "text" -> "Text"; "pacing" -> "Pacing"; "transition" -> "Transitions"; "look" -> "Look"; "motion" -> "Motion"
    "speed" -> "Speed"; "timing" -> "Timing"; "audio" -> "Sound"; "ratio" -> "Shape"; else -> "Other"
}

/** An area inside a sentence ("You changed Claude's look 4 times"). */
fun learnAreaNoun(a: String): String = when (a) {
    "captions" -> "captions"; "text" -> "text"; "pacing" -> "pacing"; "transition" -> "transitions"; "look" -> "look"; "motion" -> "camera moves"
    "speed" -> "speed"; "timing" -> "timing"; "audio" -> "sound"; "ratio" -> "shape"; else -> "edits"
}

@Serializable
data class LearnEvidence(val kind: String, val id: String? = null, val note: String? = null, val at: Long? = null)

@Serializable
data class LearnRule(
    val id: String,
    val text: String,
    val area: String = "other",
    /** "owner" | "claude" | "learned". */
    val source: String = "owner",
    val pinned: Boolean = false,
    val evidence: List<LearnEvidence> = emptyList(),
    val createdAt: Long = 0,
    val updatedAt: Long = 0,
) {
    /** Who wrote it and its evidence, in words ("From Claude · 3 corrections"). */
    val byline: String get() {
        val corrections = evidence.count { it.kind == "correction" }
        val posts = evidence.count { it.kind == "post" }
        fun n(k: Int, one: String) = "$k $one${if (k == 1) "" else "s"}"
        return when (source) {
            "claude" -> if (corrections > 0) "From Claude · ${n(corrections, "correction")}" else "From Claude"
            "learned" -> if (posts > 0) "Learned · ${n(posts, "post")}" else if (corrections > 0) "Learned · ${n(corrections, "correction")}" else "Learned"
            else -> "Yours"
        }
    }
}

@Serializable
data class LearnRuleRequest(val text: String? = null, val area: String? = null, val evidence: List<LearnEvidence>? = null, val pinned: Boolean? = null)

/** Corrections grouped by area and Claude's change: what Claude keeps getting wrong. */
@Serializable
data class LearnLesson(
    val area: String,
    val claudeChange: String = "",
    val count: Int = 0,
    val undos: Int = 0,
    val last: Long = 0,
    val examples: List<String> = emptyList(),
    val ids: List<Long> = emptyList(),
) {
    /** Plain words: "You changed Claude's look 4 times" ("undid" when every one was an undo). */
    val sentence: String get() {
        val verb = if (undos == count && count > 0) "undid" else "changed"
        return "You $verb Claude's ${learnAreaNoun(area)} ${if (count == 1) "once" else "$count times"}"
    }
}

@Serializable
data class LearnCorrection(
    val id: Long,
    val sessionId: String? = null,
    val takeId: String? = null,
    /** "undo" | "change". */
    val kind: String = "change",
    val area: String = "other",
    val what: String,
    val createdAt: Long = 0,
)

@Serializable
data class LearnPerformance(
    val posts: Int = 0,
    val views: Long = 0,
    val likes: Long = 0,
    val comments: Long = 0,
    val saves: Long? = null,
    val avgWatchSec: Double? = null,
    /** 0–1. */
    val completion: Double? = null,
)

@Serializable
data class LearnRecipeEntry(
    val id: String,
    /** "reference" | "edit". */
    val origin: String,
    val referenceId: String? = null,
    val takeId: String? = null,
    val name: String,
    val summary: String = "",
    val tags: List<String> = emptyList(),
    val features: Map<String, Double> = emptyMap(),
    val performance: LearnPerformance? = null,
    val createdAt: Long = 0,
    val updatedAt: Long = 0,
    /** The `muse.recipe/1` body (the detail only). */
    val recipe: JsonObject? = null,
    /** Nearest only: 0 = the same. */
    val distance: Double? = null,
) {
    val isReference: Boolean get() = origin == "reference"
}

@Serializable
data class LearnRecipePatch(val name: String? = null, val tags: List<String>? = null)

@Serializable
data class LearnNearest(val recipeId: String, val nearest: List<LearnRecipeEntry> = emptyList())

@Serializable
data class LearnGapExample(val recipeId: String? = null, val referenceId: String? = null, val atSec: Double? = null, val note: String = "", val at: Long = 0)

@Serializable
data class LearnGap(val key: String, val kind: String = "other", val what: String, val count: Int = 1, val examples: List<LearnGapExample> = emptyList(), val lastAt: Long = 0)

/** "2 h ago", "Yesterday", "3 days ago". */
fun relativeTime(at: Long, now: Long = System.currentTimeMillis()): String {
    val m = ((now - at) / 60_000).coerceAtLeast(0)
    return when {
        m < 1 -> "Just now"
        m < 60 -> "$m min ago"
        m < 24 * 60 -> "${m / 60} h ago"
        m < 48 * 60 -> "Yesterday"
        m < 30L * 24 * 60 -> "${m / (24 * 60)} days ago"
        else -> "${m / (30L * 24 * 60)} months ago"
    }
}

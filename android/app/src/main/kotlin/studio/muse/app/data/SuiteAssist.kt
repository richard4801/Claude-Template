package studio.muse.app.data

import kotlinx.serialization.Serializable

/**
 * Claude in the AI Suite (WS1 1eda187, plans/api.md "Claude in the AI Suite"): a composer draft shared by the owner and
 * Claude. Claude's changes arrive as `suiteAssist` events and are applied like Reuse settings; the owner's own edits go
 * back with PATCH. Claude never generates by itself: its Generate is a [SuitePending] the owner approves or declines.
 */
@Serializable
data class SuiteAssist(
    val id: String,
    val userId: String = "",
    val draft: SuiteDraft = SuiteDraft(kotlinx.serialization.json.JsonObject(emptyMap())),
    val revision: Int = 0,
    val pending: List<SuitePending> = emptyList(),
    val updatedAt: Long = 0,
) {
    /** The approval waiting for the owner, if any (the newest). */
    val waiting: SuitePending? get() = pending.lastOrNull { it.status == "waiting" }
}

/** Claude's Generate, waiting for the owner: [maxUsd] is the price being approved; it never runs above it. */
@Serializable
data class SuitePending(
    val id: String,
    val kind: String = "suite_request_shot",
    val label: String = "",
    val estimateUsd: Double = 0.0,
    val maxUsd: Double = 0.0,
    /** waiting | declined | done | failed */
    val status: String = "waiting",
    val jobId: String? = null,
    val error: String? = null,
    val createdAt: Long = 0,
)

/** A reference image on the shared draft (Claude adds the owner's attached photos): "pose" | "style" | "location" | "outfit". */
data class DraftReference(val uploadId: String, val url: String, val use: String, val label: String? = null) {
    val useLabel: String get() = when (use) { "pose" -> "Pose"; "style" -> "Style"; "location" -> "Location"; "outfit" -> "Outfit"; else -> use.replaceFirstChar { it.uppercase() } }
}

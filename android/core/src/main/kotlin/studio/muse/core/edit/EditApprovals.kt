package studio.muse.core.edit

import java.util.Locale

// Paid helpers Claude asked for, across ALL of the owner's open edit sessions (owner issue ci_e546642a4026, 2026-11-12:
// an Approve card for a helper on another edit never showed while a different edit was open). Edit's Claude sheet lists
// the other edits' waiting helpers, each naming its edit, and answers them by session id
// (POST /v1/edit-sessions/{id}/pending/{pid}) without switching edits. The Mac twin is MuseCore EditApprovals.swift.

/** One paid helper waiting for the owner's yes, and the edit it belongs to. */
data class EditApproval(
    val sessionId: String,
    val takeId: String,
    val pendingId: String,
    val label: String,
    val estimateUsd: Double,
    val createdAt: Long,
) {
    val id: String get() = "$sessionId/$pendingId"

    /** "Allow · $0.40": the price on the action. */
    val allowLabel: String get() = "Allow · $" + String.format(Locale.US, "%.2f", estimateUsd)
}

/** One session's paid helper as the API sends it (status: waiting | approved | declined | running | done | failed). */
data class SessionPending(val sessionId: String, val takeId: String, val pendingId: String, val label: String,
    val estimateUsd: Double, val createdAt: Long, val status: String) {
    val waiting: Boolean get() = status == "waiting"
}

/** The waiting ones, oldest first (the order Claude asked). */
data class EditApprovalList(val items: List<EditApproval> = emptyList()) {
    val size: Int get() = items.size
    fun isEmpty() = items.isEmpty()

    /** Those of every edit except [sessionId] (the open edit asks with its own sheet). */
    fun except(sessionId: String?): List<EditApproval> = items.filter { it.sessionId != sessionId }

    /** A live `pending` event: waiting → listed (or updated), anything else → gone. [takeIdKnown] false: the event had no take, keep the one listed. */
    fun apply(p: SessionPending, takeIdKnown: Boolean = true): EditApprovalList {
        val key = "${p.sessionId}/${p.pendingId}"
        val rest = items.filter { it.id != key }
        if (!p.waiting) return copy(items = rest)
        val take = if (takeIdKnown) p.takeId else items.firstOrNull { it.sessionId == p.sessionId }?.takeId ?: p.takeId
        return copy(items = sorted(rest + EditApproval(p.sessionId, take, p.pendingId, p.label, p.estimateUsd, p.createdAt)))
    }

    fun remove(id: String): EditApprovalList = copy(items = items.filter { it.id != id })

    companion object {
        /** Everything waiting in these sessions (GET /v1/edit-sessions: open sessions with their pending helpers). */
        fun of(all: List<SessionPending>): EditApprovalList =
            EditApprovalList(sorted(all.filter { it.waiting }.map { EditApproval(it.sessionId, it.takeId, it.pendingId, it.label, it.estimateUsd, it.createdAt) }))

        private fun sorted(l: List<EditApproval>) = l.sortedWith(compareBy<EditApproval>({ it.createdAt }, { it.id }))

        /** The edit's name as the card says it: the take's title, "New project" for a blank one, "an edit" when unknown. */
        fun editName(takeId: String, title: String?): String = when {
            takeId == BLANK_SOURCE -> "New project"
            !title.isNullOrBlank() -> title.trim()
            else -> "an edit"
        }
    }
}

package studio.muse.app.ui.screens.suite

import kotlinx.coroutines.flow.update
import studio.muse.app.data.ApiException
import studio.muse.app.data.SuiteAssist
import studio.muse.app.data.SuitePending
import studio.muse.app.ui.screens.suite.composer.ComposerDrafts

/**
 * Claude in the AI Suite (owner-approved 2026-11-08; WS1 1eda187, plans/api.md "Claude in the AI Suite"). The owner
 * describes a shot; Claude fills in the composer through a shared draft. Claude's changes arrive as `suiteAssist` events
 * and are applied like Reuse settings; the owner's own edits go back (PATCH), so Claude sees them. Claude never
 * generates: its Generate waits as a [SuitePending] until the owner approves it at the price shown.
 */
data class SuiteAssistUi(val id: String, val revision: Int, val pending: SuitePending? = null, val answering: Boolean = false, val message: String? = null)

/** The shared draft for the Claude sheet: the open one, or a new one from the composer as it is. Null (with a toast) when the server can't. */
suspend fun SuiteStore.openClaude(): String? {
    assist.value?.let { return it.id }
    val (a, err) = app.repo.attemptInline { createSuiteAssist(ComposerDrafts.draft(composer.value)) }
    if (a == null) { app.repo.toast(err ?: "Claude in the Suite isn't available on this server yet"); return null }
    assist.value = SuiteAssistUi(a.id, a.revision, a.waiting)
    assistSynced = ComposerDrafts.draft(composer.value).json.toString()
    return a.id
}

/** A `suiteAssist` event (or a fresh read): Claude's newer draft goes into the composer, as Reuse settings does. */
fun SuiteStore.applyAssist(a: SuiteAssist) {
    val cur = assist.value ?: return
    if (a.id != cur.id) return
    if (a.revision > cur.revision) {
        composer.value = ComposerDrafts.restore(a.draft, composer.value)
        assistSynced = ComposerDrafts.draft(composer.value).json.toString()
    }
    assist.update { it?.copy(revision = maxOf(it.revision, a.revision), pending = a.waiting) }
}

/** The owner's own edit in the composer: sent so Claude sees it. When Claude changed the draft meanwhile, Claude's wins. */
suspend fun SuiteStore.pushComposerToAssist() {
    val cur = assist.value ?: return
    val d = ComposerDrafts.draft(composer.value)
    if (d.json.toString() == assistSynced) return
    try {
        val a = app.repo.api.patchSuiteAssist(cur.id, d, cur.revision)
        assistSynced = d.json.toString()
        assist.update { it?.copy(revision = a.revision, pending = a.waiting) }
    } catch (e: ApiException) {
        if (e.code == "stale") runCatching { app.repo.api.suiteAssist(cur.id) }.getOrNull()?.let { applyAssist(it) }
    }
}

/**
 * The owner's answer to Claude's Generate. Yes runs it at the approved price (the server re-prices and refuses with
 * `price_changed` if it rose); the new render joins the composer's renders. No declines it.
 */
suspend fun SuiteStore.answerClaude(approve: Boolean) {
    val cur = assist.value ?: return
    val p = cur.pending ?: return
    if (cur.answering) return
    assist.update { it?.copy(answering = true, message = null) }
    try {
        val r = app.repo.api.answerSuitePending(cur.id, p.id, approve)
        r.jobId?.let { id -> shotJobs.update { it + id }; runCatching { app.repo.refresh() } }
        val msg = when (r.status) { "failed" -> r.error ?: "That shot didn't start · you weren't charged"; else -> null }
        assist.update { it?.copy(answering = false, pending = null, message = msg) }
    } catch (e: ApiException) {
        val msg = if (e.code == "price_changed") "${e.message ?: "The price changed"} · ask Claude again or press Generate yourself" else e.message ?: "Couldn't answer Claude"
        assist.update { it?.copy(answering = false, pending = if (e.code == "price_changed") null else it.pending, message = msg) }
    }
}

/** Removes a reference chip from the composer (and so from the shared draft on the next sync). */
fun SuiteStore.removeDraftReference(uploadId: String, url: String) =
    composer.update { d -> d.copy(references = d.references.filterNot { it.uploadId == uploadId && it.url == url }) }

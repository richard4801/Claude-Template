package studio.muse.app.ui.screens.suite

import kotlinx.coroutines.flow.update
import studio.muse.app.data.SuiteFeedQuery
import studio.muse.app.data.SuiteRig
import studio.muse.app.data.SuiteRigView
import studio.muse.app.data.Take
import studio.muse.app.data.applyDefaultRig
import studio.muse.app.ui.screens.suite.composer.ComposerDraft
import studio.muse.app.ui.screens.suite.composer.ComposerDrafts
import studio.muse.app.ui.screens.suite.composer.ComposerTool

/*
 * The AI suite plan in the current Suite (plans/ai-suite-design.md, owner yes 2026-11-08; the Mac's AppStore+SuiteRigs):
 * Reuse settings, Vary, Use as start frame, Compare, saved rigs, a model's default rig (fills only Auto rows; never
 * overwrites the user) and the results feed (GET /v1/suite/feed). Nothing here spends: Vary and Reuse settings only fill
 * the composer; Generate still shows the price.
 */

/** The feed's filter: All, Rendering, Finished, Failed. */
enum class SuiteFeedFilter(val label: String, val statuses: List<String>) {
    ALL("All", emptyList()), RENDERING("Rendering", listOf("queued", "running")), FINISHED("Finished", listOf("done")), FAILED("Failed", listOf("failed"));
}

/** A take's label in toasts: its title and number ("Morning café, take 2"). */
private fun Take.toastName(): String = if (of > 1) "$title, take $index" else title

/**
 * Reuse settings: the take's composer comes back exactly (prompt with its chips, rig, bar values). Slots are not restored.
 * Returns the tool to open, or null when the take has no stored draft (made before Reuse settings).
 */
fun SuiteStore.reuseSettings(take: Take, toast: Boolean = true): ComposerTool? {
    val d = take.draft ?: app.repo.state.value.job(take.jobId)?.draft ?: return null
    val restored = ComposerDrafts.restore(d, composer.value)
    composer.value = restored
    if (toast) app.repo.toast("Settings from ${take.toastName()} are back")
    return restored.tool
}

/** Vary: the take's settings back in the composer, ready for another take. Nothing renders until Generate. */
fun SuiteStore.vary(take: Take): ComposerTool? = reuseSettings(take, toast = false).also { t ->
    app.repo.toast(if (t != null) "Ready for a variation: press Generate" else "This take was made before Reuse settings")
}

/** Use as start frame: the take's frame goes into the Shot composer's start frame. */
fun SuiteStore.useAsStartFrame(take: Take) {
    composer.update { if (it.tool == ComposerTool.SHOT) it else it.withTool(ComposerTool.SHOT) }
    composerSlots.update { it.put(SlotId(SlotKind.START), SlotValue(name = take.toastName(), image = take.thumb)) }
    app.repo.toast("Start frame set from ${take.toastName()}")
}

/** Compare: adds the take (or takes it out); with two, the side-by-side opens. A third replaces the older one. */
fun SuiteStore.compare(take: Take): Boolean {
    val ids = compareIds.value
    if (take.id in ids) { compareIds.value = ids - take.id; return false }
    compareIds.value = (ids + take.id).takeLast(2)
    if (compareIds.value.size < 2) app.repo.toast("Pick a second take to compare")
    return compareIds.value.size == 2
}

// ---------------------------------------------------------------- saved rigs

suspend fun SuiteStore.loadSavedRigs() {
    runCatching { app.repo.api.suiteRigs() }.getOrNull()?.let { savedRigs.value = it }
}

/** The composer's rig (and its #moves) saved under a name (1–40 characters). */
suspend fun SuiteStore.saveRig(raw: String): Boolean {
    val name = raw.trim()
    if (name.isEmpty() || name.length > 40) { app.repo.toast("Give the rig a name of up to 40 characters"); return false }
    val d = composer.value
    val (saved, err) = app.repo.attemptInline { createSuiteRig(name, SuiteRig.from(d.settings, ComposerDrafts.rigMoves(d.tokens))) }
    if (saved == null) { app.repo.toast(err ?: "Couldn't save the rig"); return false }
    savedRigs.update { listOf(saved) + it.filter { r -> r.id != saved.id } }
    app.repo.toast("Saved ${saved.name}")
    return true
}

suspend fun SuiteStore.deleteSavedRig(r: SuiteRigView) {
    val (_, err) = app.repo.attemptInline { deleteSuiteRig(r.id) }
    if (err != null) return app.repo.toast(err)
    savedRigs.update { it.filter { x -> x.id != r.id } }
    app.repo.toast("Deleted ${r.name}")
}

/** A saved rig replaces the rig rows; its moves become #chips only while the prompt has none. "Undo" puts it back. */
fun SuiteStore.applySavedRig(r: SuiteRigView) {
    val before = composer.value
    composer.value = withMoves(before.copy(settings = r.rig.toSettings()), r.rig)
    rigUndo.value = "Applied ${r.name}" to before
}

fun SuiteStore.undoRig() { rigUndo.value?.let { composer.value = it.second }; rigUndo.value = null }

/** The one character @-mentioned in the prompt (a default rig applies, or can be set, only with exactly one). */
fun SuiteStore.soleMentioned(): studio.muse.app.data.Model? =
    ComposerDrafts.characterIds(composer.value.tokens).distinct().singleOrNull()?.let { app.repo.state.value.model(it) }

/**
 * A model's default rig: when exactly one character is @-mentioned and has one, it fills only the rows still on Auto
 * (and adds its moves while the prompt has none), then "Applied <name>'s rig · Undo". Nothing applies with two.
 */
fun SuiteStore.applyDefaultRigIfAny(): Boolean {
    val m = soleMentioned() ?: return false
    val rig = m.defaultRig ?: return false
    val before = composer.value
    val (s, filled) = applyDefaultRig(rig, before.settings)
    val next = withMoves(before.copy(settings = s), rig)
    if (filled.isEmpty() && next.tokens == before.tokens) return false
    composer.value = next
    rigUndo.value = "Applied ${m.name.substringBefore(' ')}'s rig" to before
    return true
}

/** The composer's rig becomes this character's default (an all-Auto rig clears it). */
suspend fun SuiteStore.setDefaultRig(m: studio.muse.app.data.Model) {
    val d = composer.value
    val rig = SuiteRig.from(d.settings, ComposerDrafts.rigMoves(d.tokens)).takeIf { it != SuiteRig() }
    val (_, err) = app.repo.attemptInline { setModelDefaultRig(m.id, rig) }
    if (err != null) return app.repo.toast(err)
    app.repo.refresh()
    app.repo.toast(if (rig == null) "Cleared ${m.name.substringBefore(' ')}'s default rig" else "This rig is now ${m.name.substringBefore(' ')}'s default")
}

private fun SuiteStore.withMoves(d: ComposerDraft, rig: SuiteRig): ComposerDraft {
    if (d.tool == ComposerTool.PHOTO || d.tokens.moves.isNotEmpty()) return d
    val cat = catalog.value?.camera ?: return d
    var t = d.tokens
    rig.moves.orEmpty().take(3).forEach { mv -> cat.move(mv.id)?.let { opt -> t = t.addMove(opt, t.caretAtEnd, ((mv.intensity ?: .5) * 100).toInt()).first } }
    return d.copy(tokens = t)
}

// ---------------------------------------------------------------- the results feed

/** The tools a composer's feed shows: the video tools' takes, or Photo's stills. */
fun feedTools(photo: Boolean): List<String> = if (photo) listOf("photo") else listOf("shot", "extend", "upscale", "swap", "recast")

/** First page ([reset]) or the next one. False when the server has no feed (an older server: the recent jobs stand in). */
suspend fun SuiteStore.loadFeed(photo: Boolean, reset: Boolean = true): Boolean {
    if (!reset && feedCursor == null) return true
    val q = SuiteFeedQuery(tool = feedTools(photo), status = feedFilter.value.statuses, cursor = if (reset) null else feedCursor, collection = feedCollection.value)
    val page = runCatching { app.repo.api.suiteFeed(q) }.onFailure { if (it is kotlinx.coroutines.CancellationException) throw it }.getOrNull() ?: return false
    feed.value = if (reset) page.items else feed.value.orEmpty().let { have -> have + page.items.filter { i -> have.none { it.id == i.id } } }
    if (reset) queued.value = if (feedCollection.value == null) page.queued else emptyList()
    feedCursor = page.nextCursor
    return true
}

// ---------------------------------------------------------------- the Suite queue (build step 3)

/** Queue the composer's shot to run later: checked and priced, nothing held. */
suspend fun SuiteStore.queueShot(req: studio.muse.app.data.SuiteShotRequest): Boolean {
    val (q, err) = app.repo.attemptInline { queueSuiteShot(req) }
    if (q == null) { app.repo.toast(err ?: "Couldn't queue the shot"); return false }
    queued.update { listOf(q) + it.filter { x -> x.id != q.id } }
    app.repo.toast("Queued. Run it from Takes when you're ready")
    return true
}

/** Run · $x: today's price first (it may have changed), then one confirmation. */
suspend fun SuiteStore.askRun(q: studio.muse.app.data.QueuedShot) {
    val (e, err) = app.repo.attemptInline { estimateQueuedShot(q.id) }
    if (e == null) return app.repo.toast(err ?: "Couldn't price the shot")
    runAsk.value = q to e
}

/** The yes: it runs as a normal shot (held and charged); the queue entry goes. */
suspend fun SuiteStore.confirmRun(): studio.muse.app.data.Job? {
    val (q, _) = runAsk.value ?: return null
    runAsk.value = null
    val (r, err) = app.repo.attemptInline { runQueuedShot(q.id) }
    if (r == null) { app.repo.toast(err ?: "Couldn't run the shot"); return null }
    queued.update { it.filter { x -> x.id != q.id } }
    shotJobs.update { (it - r.job.id) + r.job.id }
    return r.job
}

suspend fun SuiteStore.discardQueued(q: studio.muse.app.data.QueuedShot) {
    val (_, err) = app.repo.attemptInline { deleteQueuedShot(q.id) }
    if (err != null) return app.repo.toast(err)
    queued.update { it.filter { x -> x.id != q.id } }
}

// ---------------------------------------------------------------- Library collections (build step 3)

suspend fun SuiteStore.loadCollections() { runCatching { app.repo.api.libraryCollections() }.getOrNull()?.let { collections.value = it } }

suspend fun SuiteStore.createCollection(name: String, takeIds: List<String> = emptyList()): Boolean {
    val n = name.trim()
    if (n.isEmpty() || n.length > 60) { app.repo.toast("Name the collection (up to 60 characters)"); return false }
    val (col, err) = app.repo.attemptInline { createLibraryCollection(n, takeIds) }
    if (col == null) { app.repo.toast(err ?: "Couldn't make the collection"); return false }
    collections.update { listOf(col) + it.filter { c -> c.id != col.id } }
    return true
}

/** Adds the take to the collection, or takes it out when it's in. */
suspend fun SuiteStore.toggleInCollection(collectionId: String, takeId: String, inIt: Boolean): Boolean {
    val (col, err) = app.repo.attemptInline { if (inIt) removeFromLibraryCollection(collectionId, listOf(takeId)) else addToLibraryCollection(collectionId, listOf(takeId)) }
    if (col == null) { app.repo.toast(err ?: "Couldn't change the collection"); return false }
    collections.update { it.map { c -> if (c.id == col.id) col else c } }
    return true
}

suspend fun SuiteStore.renameCollection(id: String, name: String) {
    val (col, err) = app.repo.attemptInline { renameLibraryCollection(id, name.trim().take(60)) }
    if (col == null) return app.repo.toast(err ?: "Couldn't rename it")
    collections.update { it.map { c -> if (c.id == col.id) col else c } }
}

suspend fun SuiteStore.deleteCollection(id: String) {
    val (_, err) = app.repo.attemptInline { deleteLibraryCollection(id) }
    if (err != null) return app.repo.toast(err)
    collections.update { it.filter { c -> c.id != id } }
    if (feedCollection.value == id) feedCollection.value = null
}

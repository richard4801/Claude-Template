package studio.muse.app.ui.screens.edit

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import studio.muse.app.data.ApiEvent
import studio.muse.app.data.ApiException
import studio.muse.app.data.EditAppRequest
import studio.muse.app.data.EditHistoryEntry
import studio.muse.app.data.EditPatchRequest
import studio.muse.app.data.EditPending
import studio.muse.app.data.EditPresence
import studio.muse.app.data.EditPresencePreview
import studio.muse.app.data.EditRequestAnswer
import studio.muse.app.data.EditSessionDto
import studio.muse.app.data.EditUndoRequest
import studio.muse.app.data.MuseApi
import studio.muse.app.data.OpenEditSessionRequest
import studio.muse.core.edit.EditJson
import studio.muse.core.edit.EditProject
import studio.muse.core.edit.JsonPatch
import studio.muse.core.edit.PatchException
import studio.muse.core.edit.PatchOp
import studio.muse.core.edit.SessionSync
import studio.muse.core.edit.problemOf

/**
 * What the session sync asks the platform for when Claude asks (plans/claude-editing.md A "See" / "Finish"): an exact
 * frame, a saved version, an export. Each answers (value, null) or (null, the reason). Tests use a stub.
 */
interface SessionHost {
    /** A PNG of the composition at timeline [t] seconds, [width] pixels wide. */
    suspend fun renderFrame(project: EditProject, t: Double, width: Int): Pair<ByteArray?, String?>
    /** The suite's "Save to Library" (render + save as a version): the new version's take id. */
    suspend fun saveVersion(name: String?): Pair<String?, String?>
    /**
     * Never unattended ([OwnerExportGate]): the export sheet opens with [preset] (the owner's AI-label / C2PA switches
     * untouched) and this answers when the owner's export finishes (the new version's take id) or the sheet is closed.
     */
    suspend fun export(preset: JsonObject?): Pair<String?, String?>
}

/**
 * Edit sessions (workstream 3, plans/claude-editing.md A; plans/api.md "Edit sessions"): keeps the owner's Edit suite
 * in step with the server's session for the take, which Claude edits too. Members never get one (their editor stays
 * purely local).
 *  - [start] opens/creates the session; the app's project is sent only when it was built from a saved version.
 *  - Every local change (debounced [debounceMs], coalesced) goes up as `diff(lastSynced, current)` with its labels; on
 *    409 `stale_revision` the session is fetched again, the local change rebased on it (kept if it still applies,
 *    else the server's wins) and sent again.
 *  - `edit` events: a patch whose `baseRevision` is ours is applied (Claude's are badged and announced); one from
 *    further ahead refetches. Frame requests, save/export requests and paid helpers waiting for the owner are answered.
 *  - Presence every [presenceMs] while open; [stop] says goodbye.
 * All server work is serialised by one mutex, so a push, an event and a refetch never interleave.
 */
@OptIn(FlowPreview::class)
class EditSessionSync(
    private val scope: CoroutineScope,
    private val api: () -> MuseApi,
    private val events: Flow<ApiEvent>,
    private val controller: EditSuiteController,
    private val host: SessionHost,
    val device: String,
    private val deviceLabel: String,
    private val paletteIds: Set<String> = emptySet(),
    private val debounceMs: Long = 500,
    private val presenceMs: Long = 30_000,
    /** Where this device's unsent edits are kept per take (survive the app closing); null = not kept. */
    private val drafts: EditDrafts? = null,
) : SessionActions {
    private var draftTake: String? = null
    private val mutex = Mutex()
    private val jobs = ArrayList<Job>()
    var sessionId: String? = null
        private set
    var revision: Int = 0
        private set
    /** The project as the server has it at [revision]. */
    private var synced: JsonElement? = null

    /** The owner hasn't yet picked between this device's edits and the session's latest: nothing is sent or merged. */
    private var conflict = false
    /** The last [start] failed for lack of a connection (worth trying again), not because there is no session to have. */
    var offline = false
        private set

    /**
     * Opens the session for [takeId]. False when there is none to be had (no server, a member: the editor stays local)
     * or no connection ([offline]). When this device already has edits the session doesn't, the owner is asked first
     * ([SessionUi.conflict]): nothing is dropped silently.
     */
    suspend fun start(takeId: String, initial: JsonObject? = null, baseVersionId: String? = null, attach: String? = null): Boolean {
        offline = false
        // [attach]: join that session (a blank project continued, whose take id "blank" would open a new one).
        val s = try { if (attach != null) api().editSession(attach) else api().openEditSession(OpenEditSessionRequest(takeId, initial, baseVersionId, device)) }
            catch (_: ApiException) { return false } catch (_: java.io.IOException) { offline = true; return false }
        val server = parse(s.project) ?: return false
        mutex.withLock {
            sessionId = s.id; revision = s.revision; synced = s.project
            val local = controller.project
            if (local != server) {
                // This device's edits on the very project the session still has: nothing to ask, they just go up.
                // On a session that moved on: ask. No edits here: the session's project.
                if (controller.editedLocally && local != null) { if (server != controller.loadedProject) conflict = true }
                else controller.replaceProject(server)
            }
            controller.update { it.copy(session = SessionUi(s.id, s.revision, s.history, s.pending, conflict = conflict)) }
            controller.sessionActions = this
        }
        jobs += scope.launch { events.collect { ev -> if (ev.type == "edit" && ev.sessionId == s.id) onEvent(ev) } }
        jobs += scope.launch { controller.ui.map { it.project }.distinctUntilChanged().debounce(debounceMs).collect { flush() } }
        jobs += scope.launch { while (isActive) { presence(); delay(presenceMs) } }
        // Edit's view changed: Claude hears it at once, not at the next 30 s ping.
        jobs += scope.launch { controller.ui.map { it.preview }.distinctUntilChanged().drop(1).collect { presence() } }
        return true
    }

    /** [start], tried again every [retryMs] while there is no connection (the editor keeps working locally meanwhile). */
    suspend fun connect(takeId: String, initial: JsonObject? = null, baseVersionId: String? = null, retryMs: Long = 15_000, attach: String? = null): Boolean {
        // A blank project is new every time: no kept drafts (they are per take).
        if (drafts != null && draftTake == null && takeId != studio.muse.core.edit.BLANK_SOURCE) {
            draftTake = takeId
            // Unsent edits from last time come back first (then the session decides whether to ask).
            drafts.read(takeId)?.let { (b, p) ->
                val base = parse(b); val proj = parse(p)
                if (base != null && proj != null) controller.restoreDraft(base, proj) else drafts.clear(takeId)
            }
            jobs += scope.launch { controller.ui.map { it.project }.distinctUntilChanged().collect { saveDraft() } }
        }
        while (true) {
            if (start(takeId, initial, baseVersionId, attach)) return true
            if (!offline) return false
            delay(retryMs)
        }
    }

    /** Stops syncing and leaves (presence removed) on [leaveScope], which outlives the editor. */
    fun stop(leaveScope: CoroutineScope) {
        jobs.forEach { it.cancel() }; jobs.clear()
        val id = sessionId ?: return
        controller.sessionActions = null
        leaveScope.launch { runCatching { api().leaveEditSession(id, device) } }
    }

    /** Keeps this device's unsent edits on disk (on every change); none kept once the session has them all. */
    private fun saveDraft() {
        val store = drafts ?: return
        val take = draftTake ?: return
        if (!controller.editedLocally) return
        val now = local() ?: return
        val base = (synced ?: controller.loadedProject?.let(EditJson::encode)) as? JsonObject ?: return
        if (JsonPatch.jsonEqual(base, now)) store.clear(take) else store.write(take, base, now)
    }

    private fun draftSent() { val t = draftTake ?: return; drafts?.clear(t) }

    private suspend fun presence() {
        val id = sessionId ?: return
        val pv = controller.ui.value.preview
        runCatching { api().editPresence(id, EditPresence(device, deviceLabel, "android", canRender = true,
            preview = EditPresencePreview(pv.view.id, pv.safeArea))) }
    }

    private fun parse(el: JsonElement): EditProject? = runCatching { EditJson.parse(el) }.getOrNull()?.takeIf { problemOf(it, paletteIds = paletteIds, draft = true) == null }
    private fun valid(el: JsonElement) = parse(el) != null
    private fun local(): JsonObject? = controller.project?.let(EditJson::encode)

    private fun addEntries(list: List<EditHistoryEntry>, undone: Long? = null) = controller.updateSession { s ->
        val ids = list.map { it.id }.toSet()
        val merged = (list + s.history.filter { it.id !in ids }).sortedByDescending { it.id }.take(60)
        s.copy(revision = revision, history = if (undone != null) merged.map { if (it.id == undone) it.copy(undone = true) else it } else merged)
    }

    // ------------------------------------------------------------------ local → server
    /** Sends the local change (if any). Called after the debounce; also usable directly (tests, before a save). */
    suspend fun flush() {
        if (controller.dragging) { scope.launch { delay(debounceMs); flush() }; return }
        mutex.withLock { pushLocked() }
    }

    private suspend fun pushLocked(labelOverride: String? = null) {
        val id = sessionId ?: return
        if (conflict) return
        repeat(3) {
            val base = synced ?: return
            val now = local() ?: return
            val patch = JsonPatch.diff(base, now)
            if (patch.isEmpty()) return
            val label = controller.takeLabels().let { labelOverride ?: it }
            try {
                val r = api().pushEditPatch(id, EditPatchRequest(revision, JsonPatch.encode(patch), label, device))
                revision = r.revision; synced = now
                if (JsonPatch.jsonEqual(local(), now)) draftSent() // the session has everything this device made
                addEntries(listOfNotNull(r.entry))
                return
            } catch (e: ApiException) {
                when (e.code) {
                    "stale_revision" -> if (!refetchLocked()) return // rebased: try again
                    "bad_request" -> { // the server refused the result: take its project back
                        controller.update { it.copy(message = "Couldn't share that change · ${e.message}") }
                        refetchLocked(keepLocal = false); return
                    }
                    else -> return // offline or the server is away: the next change tries again
                }
            } catch (_: java.io.IOException) { return }
        }
    }

    /**
     * Fetches the session and rebases the local change on it ([keepLocal]): the local diff re-applied on the server's
     * project when it still applies and stays valid, else the server's. False when the fetch failed.
     */
    private suspend fun refetchLocked(keepLocal: Boolean = true): Boolean {
        val id = sessionId ?: return false
        val s: EditSessionDto = try { api().editSession(id) } catch (_: ApiException) { return false } catch (_: java.io.IOException) { return false }
        adoptLocked(s.project, s.revision, keepLocal)
        controller.updateSession { it.copy(revision = s.revision, history = s.history.ifEmpty { it.history }, pending = s.pending) }
        return true
    }

    /**
     * The server's project moved from [synced] to [server] (someone else's change): the local project gets it (with the
     * local pending change rebased on top when [keepLocal]), and so does every local undo/redo state, so local undo
     * never takes back someone else's change. While the owner hasn't resolved a conflict, only the server side moves.
     */
    private fun adoptLocked(server: JsonElement, rev: Int, keepLocal: Boolean) {
        val base = synced ?: server
        synced = server; revision = rev
        if (conflict) return
        val now = local() ?: return
        val (merged, _) = if (keepLocal) SessionSync.rebase(base, now, server, ::valid) else server to false
        val remote = JsonPatch.diff(base, server)
        val carry: (EditProject) -> EditProject? = { st ->
            if (remote.isEmpty()) st
            else try { parse(JsonPatch.apply(EditJson.encode(st), remote)) } catch (_: PatchException) { null }
        }
        if (!JsonPatch.jsonEqual(merged, now) || remote.isNotEmpty()) parse(merged)?.let { controller.applyRemote(it, carry) }
    }

    // ------------------------------------------------------------------ server → local
    private suspend fun onEvent(ev: ApiEvent) = mutex.withLock {
        when (ev.op) {
            "patch" -> onPatch(ev)
            "log" -> ev.entry?.let { addEntries(listOf(it)) }
            "pending" -> ev.pending?.let(::onPending)
            "frame_request" -> if (ev.device.isNullOrEmpty() || ev.device == device) scope.launch { answerFrame(ev) }
            "app_request" -> ev.request?.let { r ->
                if (r.status == "sent" && (r.device.isEmpty() || r.device == device)) scope.launch { answerRequest(r) }
            }
            "closed" -> {
                jobs.forEach { it.cancel() }; jobs.clear()
                controller.sessionActions = null
                controller.update { it.copy(session = null) }
            }
        }
    }

    private suspend fun onPatch(ev: ApiEvent) {
        val rev = ev.revision ?: return
        val entry = ev.entry
        if (rev <= revision) { entry?.let { addEntries(listOf(it)) }; return } // ours, or already fetched
        val base = synced
        val server = if (ev.baseRevision == revision && base != null && ev.patch != null) {
            try { JsonPatch.apply(base, PatchOp.listOf(ev.patch)) } catch (_: PatchException) { null }
        } else null
        if (server == null) { refetchLocked(); entry?.let { addEntries(listOf(it), it.undoes) }; return }
        adoptLocked(server, rev, keepLocal = true)
        if (entry != null) {
            addEntries(listOf(entry), entry.undoes)
            if (entry.byClaude) controller.updateSession { it.copy(claudeNote = "Claude · ${entry.label}") }
        }
    }

    private fun onPending(p: EditPending) = controller.updateSession { s ->
        val rest = s.pending.filter { it.id != p.id }
        s.copy(pending = if (p.status == "waiting" || p.status == "running") rest + p else rest, answering = s.answering?.takeIf { it != p.id })
    }

    // ------------------------------------------------------------------ Claude's requests
    private suspend fun answerFrame(ev: ApiEvent) {
        val id = sessionId ?: return
        val rid = ev.requestId ?: return
        val p = controller.project ?: return
        val (png, _) = host.renderFrame(p, ev.t ?: 0.0, (ev.width ?: 540).coerceIn(64, 2160))
        png ?: return // no answer: the server falls back to its approximate frame after its wait
        runCatching {
            val up = api().uploadEditFrame(png)
            api().answerEditFrame(id, rid, up)
        }
    }

    private suspend fun answerRequest(r: EditAppRequest) {
        val id = sessionId ?: return
        flush() // the saved / exported edit is the one Claude sees
        val (version, err) = when (r.kind) {
            "save" -> host.saveVersion(r.name)
            "export" -> host.export(r.preset)
            else -> null to "Unknown request"
        }
        val answer = if (version != null) EditRequestAnswer("done", versionId = version) else EditRequestAnswer("failed", error = err ?: "Couldn't finish")
        runCatching { api().answerEditRequest(id, r.id, answer) }
    }

    // ------------------------------------------------------------------ the owner's actions
    override fun undoEntry(entryId: Long) {
        scope.launch {
            mutex.withLock {
                val id = sessionId ?: return@withLock
                pushLocked() // the server undoes on top of everything this app has
                try {
                    val r = api().undoEditEntry(id, EditUndoRequest(entryId, device))
                    val s = api().editSession(id)
                    adoptLocked(s.project, s.revision, keepLocal = true) // like any change from the session
                    controller.updateSession { it.copy(revision = s.revision, history = s.history.ifEmpty { it.history }) }
                    addEntries(listOfNotNull(r.entry), entryId)
                } catch (e: ApiException) {
                    controller.update { it.copy(message = e.message ?: "Couldn't undo that") }
                } catch (_: java.io.IOException) {
                    controller.update { it.copy(message = "Couldn't reach the studio · try again") }
                }
            }
        }
    }

    /**
     * The owner's pick after [start] found edits on this device the session doesn't have: keep them (sent as one change
     * on top of the latest revision) or use the latest (this device's edits are dropped).
     */
    override fun resolveConflict(keepLocal: Boolean) {
        scope.launch {
            mutex.withLock {
                if (!conflict) return@withLock
                conflict = false
                controller.updateSession { it.copy(conflict = false) }
                if (keepLocal) {
                    // This device's edits (since it loaded the project) on top of the latest; where they no longer
                    // apply, the device's whole project goes up as it is.
                    val base = controller.loadedProject?.let(EditJson::encode)
                    val now = local(); val server = synced
                    if (base != null && now != null && server != null) {
                        val (merged, kept) = SessionSync.rebase(base, now, server, ::valid)
                        val remote = JsonPatch.diff(base, server)
                        if (kept) parse(merged)?.let { p ->
                            controller.applyRemote(p) { st -> try { parse(JsonPatch.apply(EditJson.encode(st), remote)) } catch (_: PatchException) { null } }
                        }
                    }
                    pushLocked(labelOverride = "This device's changes")
                }
                else {
                    controller.takeLabels()
                    synced?.let(::parse)?.let(controller::replaceProject)
                    draftSent() // discarded on purpose
                }
            }
        }
    }

    override fun answerPending(id: String, approve: Boolean) {
        val sid = sessionId ?: return
        controller.updateSession { it.copy(answering = id) }
        scope.launch {
            try {
                val p = api().answerEditPending(sid, id, approve)
                mutex.withLock { onPending(p) }
                if (approve) controller.update { it.copy(message = "${p.label} is running") }
            } catch (e: ApiException) {
                controller.updateSession { s -> s.copy(answering = null, pending = s.pending.filter { it.id != id }) }
                controller.update { it.copy(message = e.message ?: "Couldn't answer · try again") }
            } catch (_: java.io.IOException) {
                controller.updateSession { it.copy(answering = null) }
            }
        }
    }
}

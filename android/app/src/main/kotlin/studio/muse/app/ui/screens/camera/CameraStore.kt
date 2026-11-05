package studio.muse.app.ui.screens.camera

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import studio.muse.app.data.ApiEvent
import studio.muse.app.data.ApiException
import studio.muse.app.data.CameraApi
import studio.muse.app.data.CameraAsset
import studio.muse.app.data.CameraMessage
import studio.muse.app.data.CameraSession
import studio.muse.app.data.ChatEvent
import studio.muse.app.data.Connections
import studio.muse.app.data.NewCameraSession
import studio.muse.app.data.NewCast
import studio.muse.app.data.PathUpdate

/** What the camera screens show. */
data class CameraUi(
    val sessions: List<CameraSession> = emptyList(),
    val listLoaded: Boolean = false,
    val openId: String? = null,
    /** The open session (without messages: they are in [messages]). */
    val session: CameraSession? = null,
    val messages: List<CameraMessage> = emptyList(),
    val connections: Connections? = null,
    /** The chat turn while it streams. */
    val turn: ChatTurn? = null,
    val notice: ChatNotice? = null,
    /** Texts sent from this device ("YOU · PHONE"). */
    val sentHere: Set<String> = emptySet(),
    /** Live events are connected. */
    val live: Boolean = true,
    val playhead: Double = 0.0,
    val error: String? = null,
) {
    val busy get() = turn != null || session?.claude?.chatBusy == true
}

/** Live `camera` and `blender` events applied to the camera screens. Pure. */
object CameraLive {
    private fun <T> List<T>.upsert(item: T, front: Boolean = true, same: (T) -> Boolean): List<T> =
        if (any(same)) map { if (same(it)) item else it } else if (front) listOf(item) + this else this + item

    private fun withAsset(s: CameraSession, a: CameraAsset) = s.copy(assets = s.assets.upsert(a, front = false) { it.id == a.id })

    fun apply(ui: CameraUi, ev: ApiEvent): CameraUi = when (ev.type) {
        "camera" -> when (ev.op) {
            "upsert" -> ev.session?.let { s0 ->
                val s = s0.copy(messages = null)
                val older = ui.sessions.firstOrNull { it.id == s.id }
                if (older != null && older.revision > s.revision) ui
                else ui.copy(
                    sessions = ui.sessions.upsert(s) { it.id == s.id }.sortedByDescending { it.updatedAt },
                    session = if (ui.openId == s.id && (ui.session == null || ui.session.revision <= s.revision)) s else ui.session,
                )
            } ?: ui
            "delete" -> ui.copy(
                sessions = ui.sessions.filterNot { it.id == ev.id },
                session = if (ui.openId == ev.id) null else ui.session,
                error = if (ui.openId == ev.id) "This camera session was deleted" else ui.error,
            )
            "message" -> {
                val m = ev.message
                if (m == null || ev.sessionId != ui.openId || ui.messages.any { it.id == m.id }) ui else ui.copy(messages = ui.messages + m)
            }
            "asset" -> ev.asset?.let { a ->
                ui.copy(
                    sessions = ui.sessions.map { if (it.id == ev.sessionId) withAsset(it, a) else it },
                    session = ui.session?.let { if (it.id == ev.sessionId) withAsset(it, a) else it },
                )
            } ?: ui
            else -> ui
        }
        "blender" -> if (ev.op == "relay" && ev.online != null) {
            fun r(s: CameraSession) = s.copy(relay = s.relay.copy(online = ev.online, blender = ev.blender ?: false, addonVersion = ev.addonVersion))
            ui.copy(sessions = ui.sessions.map(::r), session = ui.session?.let(::r),
                connections = ui.connections?.let { c -> c.copy(relay = c.relay.copy(online = ev.online, blender = ev.blender ?: false, addonVersion = ev.addonVersion)) })
        } else ui
        else -> ui
    }

    /** One chat event applied to the streaming turn. */
    fun turn(t: ChatTurn, ev: ChatEvent): ChatTurn = when (ev.type) {
        "text" -> t.copy(text = t.text + ev.delta.orEmpty())
        "tool" -> when (ev.status) {
            "running" -> t.copy(toolsSeen = t.toolsSeen + 1, lastStep = toolChipName(ev.name ?: "tool").lowercase().replace('_', ' ') + "…", waitingMac = false)
            else -> t.copy(toolsDone = (t.toolsDone + 1).coerceAtMost(t.toolsSeen.coerceAtLeast(t.toolsDone + 1)),
                lastStep = ev.summary ?: t.lastStep, waitingMac = false, renderProgress = null)
        }
        "waiting" -> t.copy(waitingMac = true)
        else -> t
    }
}

/**
 * The camera screens' state holder: the session list, the open session with its transcript, the chat stream, drag edits
 * (debounced PUT …/path) and Connections. [api] is read at each call (the app can switch between the server and the demo).
 */
class CameraStore(private val api: () -> CameraApi, private val scope: CoroutineScope) {
    private val _ui = MutableStateFlow(CameraUi())
    val ui: StateFlow<CameraUi> = _ui.asStateFlow()
    private var pathJob: Job? = null
    private var chatJob: Job? = null

    /** Tests and previews. */
    fun set(ui: CameraUi) { _ui.value = ui }

    fun onLive(ev: ApiEvent) = _ui.update { CameraLive.apply(it, ev) }

    private fun fail(e: Throwable) = _ui.update { it.copy(error = e.message ?: "Something went wrong") }

    fun loadList() = scope.launch {
        runCatching { api().sessions() }.onSuccess { l -> _ui.update { it.copy(sessions = l, listLoaded = true, error = null) } }
            .onFailure { e -> _ui.update { it.copy(listLoaded = true, error = e.message) } }
    }

    fun loadConnections() = scope.launch { runCatching { api().connections() }.onSuccess { c -> _ui.update { it.copy(connections = c) } } }

    fun open(id: String) {
        _ui.update { it.copy(openId = id, session = it.sessions.firstOrNull { s -> s.id == id }, messages = emptyList(), notice = null, error = null, turn = null) }
        scope.launch { reload(id) }
        loadConnections()
    }

    private suspend fun reload(id: String) {
        runCatching { api().session(id) }.onSuccess { s ->
            _ui.update { u ->
                if (u.openId != id) u else u.copy(session = s.copy(messages = null), messages = s.messages.orEmpty(),
                    playhead = if (u.session?.id == id) u.playhead.coerceIn(0.0, s.durationSec) else s.durationSec / 2,
                    sessions = u.sessions.map { if (it.id == id) s.copy(messages = null) else it })
            }
        }.onFailure(::fail)
    }

    fun close() { chatJob = null; _ui.update { it.copy(openId = null, session = null, messages = emptyList(), turn = null, notice = null) } }

    fun setPlayhead(t: Double) = _ui.update { u -> u.copy(playhead = t.coerceIn(0.0, u.session?.durationSec ?: t)) }

    fun dismissNotice() = _ui.update { it.copy(notice = null) }

    fun newSession(title: String, cast: List<String>, onOpen: (String) -> Unit) = scope.launch {
        runCatching { api().createSession(NewCameraSession(title = title, characters = cast.take(4).map { NewCast(it) })) }
            .onSuccess { s -> _ui.update { u -> u.copy(sessions = listOf(s.copy(messages = null)) + u.sessions.filterNot { it.id == s.id }) }; onOpen(s.id) }
            .onFailure(::fail)
    }

    /** Direct with Claude: one message, streamed. Refused while a turn runs ("Claude is still working on this shot"). */
    fun send(text: String): Boolean {
        val u = _ui.value
        val s = u.session ?: return false
        if (text.isBlank()) return false
        if (u.busy) { _ui.update { it.copy(notice = ChatNotice.of("chat_busy", null)) }; return false }
        _ui.update { it.copy(turn = ChatTurn(text, s.revision), notice = null, sentHere = it.sentHere + text) }
        chatJob = scope.launch {
            try {
                api().chat(s.id, text).collect { ev ->
                    when (ev.type) {
                        "message" -> ev.message?.let { m -> _ui.update { it.copy(messages = if (it.messages.any { x -> x.id == m.id }) it.messages else it.messages + m) } }
                        "error" -> _ui.update { it.copy(notice = ChatNotice.of(ev.code, ev.error), turn = null) }
                        "done" -> _ui.update { it.copy(turn = null) }
                        else -> _ui.update { it.copy(turn = it.turn?.let { t -> CameraLive.turn(t, ev) }) }
                    }
                }
            } catch (e: ApiException) {
                _ui.update { it.copy(notice = ChatNotice.of(e.code, e.message)) }
            } finally {
                _ui.update { it.copy(turn = null) }
                if (_ui.value.openId == s.id) reload(s.id)
            }
        }
        return true
    }

    /** Re-render: the chat message the spec names. */
    fun rerender() = send("Re-render the guides for this revision.")

    /** Drag a character token at the playhead: moves or inserts its key, then PUT …/path after 400 ms of quiet. */
    fun dragCharacter(modelId: String, to: P2) {
        _ui.update { u ->
            val s = u.session ?: return@update u
            val tracks = Drag.moveCharacter(s.blocking?.characters.orEmpty(), modelId, u.playhead, to)
            u.copy(session = s.copy(blocking = (s.blocking ?: studio.muse.app.data.Blocking()).copy(characters = tracks)))
        }
        savePath(characters = true)
    }

    fun dragCamera(to: P2) {
        _ui.update { u ->
            val s = u.session ?: return@update u
            u.copy(session = s.copy(cameraPath = Drag.moveCamera(s.cameraPath ?: studio.muse.app.data.CameraPath(), u.playhead, to)))
        }
        savePath(camera = true)
    }

    private var pendingCamera = false
    private var pendingChars = false

    private fun savePath(camera: Boolean = false, characters: Boolean = false) {
        pendingCamera = pendingCamera || camera
        pendingChars = pendingChars || characters
        pathJob?.cancel()
        pathJob = scope.launch {
            delay(DEBOUNCE_MS)
            val s = _ui.value.session ?: return@launch
            val req = PathUpdate(if (pendingCamera) s.cameraPath else null, if (pendingChars) s.blocking?.characters else null)
            pendingCamera = false; pendingChars = false
            runCatching { api().putPath(s.id, req) }
                .onSuccess { saved -> _ui.update { u -> if (u.openId == saved.id) u.copy(session = u.session?.copy(revision = saved.revision, status = saved.status, updatedAt = saved.updatedAt)) else u } }
                .onFailure(::fail)
        }
    }

    /** The guide for the Shot builder: the draft's `request.camera`, making a draft first when there is none. */
    suspend fun handoff(): Result<CameraGuideHandoff> = runCatching {
        val s = _ui.value.session ?: throw ApiException("not_found", "Open a camera session first")
        CameraGuideHandoff.of(s) ?: run {
            val d = api().shotDraft(s.id)
            val withDraft = s.copy(shotDraft = d)
            _ui.update { it.copy(session = withDraft) }
            CameraGuideHandoff.of(withDraft) ?: throw ApiException("no_guides", "No guides yet · ask Claude to render them, or render from your Claude app")
        }
    }

    companion object { const val DEBOUNCE_MS = 400L }
}

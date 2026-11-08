package studio.muse.app.ui.screens.claude

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import studio.muse.app.data.ApiEvent
import studio.muse.app.data.ApiException
import studio.muse.app.data.ClaudeApi
import studio.muse.app.data.ClaudeSend

/**
 * One chat thread (a camera or edit session): loads it, sends the phone's messages to the Mac, follows the live `claude`
 * events, stops a turn, and runs the studio-API fallback when the owner picks it. [api] is read at each call.
 */
class ClaudeChatStore(private val api: () -> ClaudeApi, private val scope: CoroutineScope, contextKind: String, contextId: String) {
    private val _ui = MutableStateFlow(ClaudeChatUi(contextKind, contextId))
    val ui: StateFlow<ClaudeChatUi> = _ui.asStateFlow()
    private var apiJob: Job? = null

    /** Tests and previews. */
    fun set(ui: ClaudeChatUi) { _ui.value = ui }

    fun onLive(ev: ApiEvent) {
        if (ev.type == ApiEvent.CONNECTED) { scope.launch { reload() }; return }
        val l = ev.claude ?: return
        val before = _ui.value.turn
        _ui.update { ChatReducer.live(it, l) }
        // A turn just ended: the stored messages are the truth.
        val after = _ui.value.turn
        if (before?.active == true && after?.active != true) scope.launch { reload() }
    }

    fun load() = scope.launch {
        runCatching { api().status() }.onSuccess { s -> _ui.update { it.copy(status = s) } }
        runCatching { api().thread(_ui.value.contextKind, _ui.value.contextId) }
            .onSuccess { t -> _ui.update { u -> ChatReducer.loaded(u, t) }; reload() }
            .onFailure { e -> _ui.update { it.copy(loaded = true, error = e.message ?: "Couldn't open the chat") } }
    }

    suspend fun reload() {
        val id = _ui.value.thread?.id ?: return
        runCatching { api().getThread(id) }.onSuccess { t -> _ui.update { u -> ChatReducer.loaded(u, t) } }
    }

    fun refreshStatus() = scope.launch { runCatching { api().status() }.onSuccess { s -> _ui.update { it.copy(status = s, refusal = if (s.mac.ready) null else it.refusal) } } }

    fun edit(text: String) = _ui.update { it.copy(draft = text) }

    fun dismissNotice() = _ui.update { it.copy(notice = null) }

    /** An image for the next message (≤ 4): shown at once from [preview], sent once [upload] gives its upload id. */
    fun attach(preview: String, upload: suspend () -> String) {
        if (!_ui.value.canAttach) return
        if (_ui.value.attachments.size >= MAX_IMAGES) { _ui.update { it.copy(notice = "Up to $MAX_IMAGES images per message") }; return }
        val key = "att${++attachSeq}"
        _ui.update { it.copy(attachments = it.attachments + ChatAttachment(key, preview)) }
        scope.launch {
            val r = runCatching { upload() }
            if (r.exceptionOrNull() is kotlinx.coroutines.CancellationException) throw r.exceptionOrNull()!!
            _ui.update { u -> u.copy(attachments = u.attachments.map { a ->
                if (a.key != key) a else r.fold({ a.copy(uploadId = it) }, { e -> a.copy(error = e.message ?: "Couldn't upload this image") })
            }) }
        }
    }

    fun removeAttachment(key: String) = _ui.update { u -> u.copy(attachments = u.attachments.filter { it.key != key }) }

    private var attachSeq = 0

    /** Sends [text] (default: the composer) to the Mac. False when there is nothing to send or a turn runs. */
    fun send(text: String = _ui.value.draft): Boolean {
        val u = _ui.value
        val t = text.trim()
        val thread = u.thread ?: return false
        val images = u.attachments.mapNotNull { it.uploadId }
        if (t.isEmpty() && images.isEmpty()) return false
        if (u.busy) { _ui.update { it.copy(notice = "Claude is still answering · wait or press Stop") }; return false }
        if (u.uploading) { _ui.update { it.copy(notice = "Wait for the images to finish uploading") }; return false }
        val sent = u.attachments
        _ui.update { it.copy(turn = LiveTurn(null, "queued", "phone", t), draft = if (text == u.draft || t == u.draft.trim()) "" else it.draft, notice = null, refusedText = null,
            attachments = emptyList()) }
        scope.launch {
            try {
                when (val r = api().post(thread.id, t, images)) {
                    is ClaudeSend.Sent -> _ui.update { x ->
                        val cur = x.turn
                        // Live events may have overtaken the answer.
                        val turn = if (cur != null && cur.id == null) cur.copy(id = r.turn.id, state = if (cur.state == "queued") r.turn.state else cur.state) else cur
                        ChatReducer.message(x.copy(turn = turn, refusal = null), r.message)
                    }
                    // Refused: the text and the images stay, for "Use the studio API key" or another try.
                    is ClaudeSend.MacOffline -> _ui.update { it.copy(turn = null, refusal = r.fallback, refusedText = t, draft = it.draft.ifEmpty { t }, attachments = sent + it.attachments,
                        status = it.status?.let { s -> s.copy(mac = s.mac.copy(online = false)) }) }
                    ClaudeSend.Busy -> _ui.update { it.copy(turn = null, draft = it.draft.ifEmpty { t }, attachments = sent + it.attachments, notice = "Claude is still answering on your Mac") }
                }
            } catch (e: ApiException) {
                _ui.update { it.copy(turn = null, draft = it.draft.ifEmpty { t }, attachments = sent + it.attachments, notice = e.message) }
            }
        }
        return true
    }

    /** Retry a failed reply: the owner's last message goes again (on the studio key if that's what answered it). */
    fun retry(): Boolean {
        val u = _ui.value
        if (u.busy || u.turn?.state != "failed") return false
        val text = ChatReducer.lastUserText(u) ?: return false
        return if (u.turn.api) { _ui.update { it.copy(refusedText = text) }; useApiKey() } else send(text)
    }

    /** Stop: the Mac interrupts the turn; the API fallback's stream is cancelled. */
    fun stop() {
        val t = _ui.value.turn ?: return
        if (!t.active) return
        if (t.api) { apiJob?.cancel(); _ui.update { it.copy(turn = t.copy(state = "stopped")) }; scope.launch { reload() }; return }
        val id = t.id ?: return
        _ui.update { it.copy(turn = t.copy(stopping = true)) }
        scope.launch { runCatching { api().stop(id) }.onFailure { e -> _ui.update { it.copy(notice = e.message, turn = it.turn?.copy(stopping = false)) } } }
    }

    /** "Use the studio API key": the refused text (or the composer) through POST …/api-turn, billed per use. */
    fun useApiKey(): Boolean {
        val u = _ui.value
        val thread = u.thread ?: return false
        val t = (u.refusedText ?: u.draft).trim()
        val images = u.attachments.mapNotNull { it.uploadId }
        if ((t.isEmpty() && images.isEmpty()) || u.busy || u.uploading) return false
        _ui.update { it.copy(turn = LiveTurn(null, "running", "phone", t, api = true), draft = "", refusedText = null, refusal = null, notice = null, attachments = emptyList()) }
        apiJob = scope.launch {
            try {
                api().apiTurn(thread.id, t, images).collect { ev -> _ui.update { ChatReducer.api(it, ev) } }
            } finally {
                _ui.update { x -> x.turn?.takeIf { it.api && it.active }?.let { x.copy(turn = it.copy(state = "done")) } ?: x }
                reload()
            }
        }
        return true
    }

    companion object { const val MAX_IMAGES = 4 }
}

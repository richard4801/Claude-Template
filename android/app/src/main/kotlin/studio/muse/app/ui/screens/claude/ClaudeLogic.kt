package studio.muse.app.ui.screens.claude

// Pure logic of the Claude chat (plans/claude-editing.md parts D and E): the transcript reducer (stored messages + live
// `claude` events), the status line, tool chip words, and what to offer when the Mac is offline. No Compose here.

import studio.muse.app.data.ChatEvent
import studio.muse.app.data.ClaudeEvent
import studio.muse.app.data.ClaudeFallback
import studio.muse.app.data.ClaudeLive
import studio.muse.app.data.ClaudeMessage
import studio.muse.app.data.ClaudePlanStatus
import studio.muse.app.data.ClaudeThread
import studio.muse.app.data.ClaudeTurn
import java.util.Locale

// ---------------------------------------------------------------- chips

object ChipText {
    /** `mcp__muse__set_camera_path` → `set_camera_path` (any MCP server prefix). */
    fun bare(name: String): String = if (name.startsWith("mcp__")) name.removePrefix("mcp__").substringAfter("__") else name

    private val USD = Regex("""\$\s?(\d+(?:\.\d+)?)""")

    /** "$1.92" from a summary like "Shot draft · estimate $1.92", or null. */
    fun usd(summary: String?): String? = summary?.let { USD.find(it) }?.groupValues?.get(1)?.toDoubleOrNull()?.let { String.format(Locale.US, "$%.2f", it) }

    /** Tool name in words: `cut_silences` → "Cut silences". */
    fun words(name: String): String = bare(name).removePrefix("blender_").replace('_', ' ').trim().replaceFirstChar { it.uppercase() }.ifEmpty { "Tool" }

    /**
     * The chip's words: the summary the Mac sent, as is ("Trimmed to 0:00.5–0:06.0", "Shot draft · estimate $1.92"); without
     * one, the same mapping as the Mac (`set_camera_path` → "Saved camera path", editing tools in words), else the name in words.
     */
    fun of(name: String, summary: String? = null, running: Boolean = false): String {
        val n = bare(name)
        val s = summary?.trim()?.takeIf { it.isNotEmpty() }
        if (running) return when (n) {
            "set_camera_path" -> "Saving camera path…"
            "create_shot_draft" -> "Making a shot draft…"
            "get_frame" -> "Grabbing a frame…"
            else -> words(n) + "…"
        }
        // The Mac (and the server) fill the summary from the tool result's label: shown as is.
        if (s != null) return s
        return when (n) {
            "set_camera_path" -> "Saved camera path"
            "create_shot_draft" -> "Shot draft"
            "attach_guide_media" -> "Upload link ready"
            "blender_render_guides" -> "Rendered guides"
            "list_takes" -> "Looked at your takes"
            "open_edit" -> "Opened the edit"
            "get_edit" -> "Read the edit"
            "apply_edit_ops" -> "Edited"
            "undo_edit" -> "Undid an edit"
            "list_looks" -> "Looked at the Looks"
            "list_caption_styles" -> "Looked at caption styles"
            "auto_captions" -> "Added captions"
            "cut_silences" -> "Cut silences"
            "cut_fillers" -> "Cut filler words"
            "remove_background" -> "Removed the background"
            "detect_beats" -> "Found the beats"
            "denoise" -> "Cleaned up the audio"
            "get_frame" -> "Grabbed a frame"
            "get_contact_sheet" -> "Checked a contact sheet"
            "save_version" -> "Saved a version"
            "export_video" -> "Started an export"
            else -> words(n)
        }
    }
}

// ---------------------------------------------------------------- the transcript

/** What streams in before it is stored: text, a tool chip, a frame (base64). */
sealed interface LivePart {
    data class Text(val text: String) : LivePart
    data class Tool(val id: String, val name: String, val status: String, val summary: String? = null) : LivePart
    data class Image(val data: String, val mimeType: String) : LivePart
}

/** The turn in flight on this thread: relayed to the Mac (a [ClaudeTurn]) or on the studio API key ([api]). */
data class LiveTurn(
    val id: String?, val state: String = "queued", val from: String = "phone", val text: String = "",
    val parts: List<LivePart> = emptyList(), val stopping: Boolean = false, val api: Boolean = false, val error: String? = null,
) {
    val active get() = state == "queued" || state == "running"
}

/** One row of the transcript. */
sealed interface ChatItem {
    val key: String
    /** [images]: the attached images' links (thumbnails). */
    data class User(override val key: String, val text: String, val source: String, val images: List<String> = emptyList(), val at: Long = 0) : ChatItem
    data class Assistant(override val key: String, val text: String, val streaming: Boolean = false, val at: Long = 0) : ChatItem
    /** [detail]: the short line a tap shows ("Set camera path, done"). */
    data class Tool(override val key: String, val text: String, val ok: Boolean, val running: Boolean = false, val detail: String = "") : ChatItem
    /** A frame Claude grabbed: [url] when stored, [data] (base64) while it streams. */
    data class Image(override val key: String, val url: String? = null, val data: String? = null, val mimeType: String? = null) : ChatItem
}

/** The chat's state for one thread. */
/** An image picked for the next message: its local [preview] and, once uploaded, its [uploadId]. */
/** [unsupported]: the server refused the format (415 unsupported_image), so the chip offers "Send as JPEG". */
data class ChatAttachment(val key: String, val preview: String, val uploadId: String? = null, val error: String? = null, val unsupported: Boolean = false)

data class ClaudeChatUi(
    val contextKind: String = "camera",
    val contextId: String = "",
    val thread: ClaudeThread? = null,
    val messages: List<ClaudeMessage> = emptyList(),
    val turn: LiveTurn? = null,
    val status: ClaudePlanStatus? = null,
    /** The last `mac_offline` refusal (cleared once the Mac is back). */
    val refusal: ClaudeFallback? = null,
    /** The text the Mac couldn't take, for "Use the studio API key". */
    val refusedText: String? = null,
    val draft: String = "",
    val notice: String? = null,
    val loaded: Boolean = false,
    val error: String? = null,
    /** Images picked for the next message (Recreate, Edit and Suite threads; ≤ 4): uploading until [ChatAttachment.uploadId]. */
    val attachments: List<ChatAttachment> = emptyList(),
) {
    val busy get() = turn?.active == true
    /** Attaching images: not in Camera stage yet (the server refuses them there). */
    val canAttach get() = contextKind != "camera"
    val uploading get() = attachments.any { it.uploadId == null && it.error == null }
    val canSend get() = loaded && thread != null && !busy && !uploading && (draft.isNotBlank() || attachments.any { it.uploadId != null && it.error == null })
    val items get() = ChatReducer.items(this)
}

object ChatReducer {
    fun loaded(ui: ClaudeChatUi, t: ClaudeThread): ClaudeChatUi {
        val active = t.activeTurn
        val turn = when {
            active != null && ui.turn?.id == active.id -> ui.turn.copy(state = active.state)
            active != null -> LiveTurn(active.id, active.state, active.from, active.text)
            // Stored now: the live parts are in the messages.
            ui.turn?.api == true && ui.turn.active -> ui.turn
            // Keep "Stopped" / the failure under the transcript; the parts are stored now.
            else -> ui.turn?.takeIf { it.state == "stopped" || it.state == "failed" }?.copy(parts = emptyList())
        }
        return ui.copy(thread = t.copy(messages = null, activeTurn = null), messages = t.messages ?: ui.messages, turn = turn, loaded = true, error = null)
    }

    /** One live `claude` event. Events of other threads are ignored. */
    fun live(ui: ClaudeChatUi, l: ClaudeLive): ClaudeChatUi {
        val tid = ui.thread?.id
        return when (l.op) {
            "status" -> l.status?.let { s -> ui.copy(status = s, refusal = if (s.mac.ready) null else ui.refusal) } ?: ui
            "thread" -> l.thread?.let { t -> if (t.id == tid) ui.copy(thread = t.copy(messages = null, activeTurn = null)) else ui } ?: ui
            "message" -> { val m = l.message; if (m == null || tid == null || (l.threadId ?: m.threadId) != tid) ui else message(ui, m) }
            "event" -> { val e = l.event; if (e == null || tid == null || l.threadId != tid) ui else event(ui, l.turnId, e) }
            "turn" -> l.turn?.let { t -> if (t.threadId != tid) ui else turn(ui, t) } ?: ui
            "stop" -> if (l.turnId != null && ui.turn?.id == l.turnId) ui.copy(turn = ui.turn.copy(stopping = true)) else ui
            else -> ui
        }
    }

    /** A stored message: added once (by id); it replaces the live part it stands for. */
    fun message(ui: ClaudeChatUi, m: ClaudeMessage): ClaudeChatUi {
        if (ui.messages.any { it.id == m.id }) return ui
        val t = ui.turn
        val parts = t?.parts.orEmpty().let { ps ->
            when {
                m.role == "assistant" && m.text.isNotBlank() -> ps.filterNot { it is LivePart.Text && it.text.trim().let { x -> x.isEmpty() || m.text.contains(x) } }
                m.image != null -> { val i = ps.indexOfFirst { it is LivePart.Image }; if (i >= 0) ps.filterIndexed { j, _ -> j != i } else ps }
                m.tool != null -> ps.filterNot { it is LivePart.Tool && it.id == m.tool.id }
                else -> ps
            }
        }
        return ui.copy(messages = ui.messages + m, turn = t?.copy(parts = parts))
    }

    fun event(ui: ClaudeChatUi, turnId: String?, e: ClaudeEvent): ClaudeChatUi {
        val t0 = ui.turn
        // The Mac's own turn (no turnId) or one this device didn't start: follow it.
        val t = when {
            t0 != null && ((turnId != null && t0.id == turnId) || (t0.active && (turnId == null || t0.id == null))) -> t0.copy(id = t0.id ?: turnId)
            e.type == "done" -> return ui
            else -> LiveTurn(turnId, "running", if (turnId == null) "mac" else "phone")
        }
        val running = if (t.state == "queued") t.copy(state = "running") else t
        return when (e.type) {
            "text" -> ui.copy(turn = running.copy(parts = appendText(running.parts, e.delta.orEmpty())))
            "tool" -> {
                val id = e.id ?: return ui
                if (ui.messages.any { it.tool?.id == id }) return ui.copy(turn = running)
                val part = LivePart.Tool(id, e.name ?: "tool", e.status ?: "running", e.summary)
                val i = running.parts.indexOfFirst { it is LivePart.Tool && it.id == id }
                ui.copy(turn = running.copy(parts = if (i >= 0) running.parts.toMutableList().also { it[i] = part } else running.parts + part))
            }
            "image" -> e.data?.let { d -> ui.copy(turn = running.copy(parts = running.parts + LivePart.Image(d, e.mimeType ?: "image/png"))) } ?: ui
            "done" -> ui.copy(turn = running.copy(state = if (e.ok == false) (if (running.stopping) "stopped" else "failed") else "done", error = e.error))
            // user / assistant arrive as stored messages.
            else -> ui.copy(turn = running)
        }
    }

    fun turn(ui: ClaudeChatUi, t: ClaudeTurn): ClaudeChatUi {
        val cur = ui.turn
        return when {
            cur != null && cur.id == t.id -> ui.copy(turn = cur.copy(state = t.state, error = t.error ?: cur.error))
            t.active -> ui.copy(turn = LiveTurn(t.id, t.state, t.from, t.text))
            else -> ui
        }
    }

    private fun appendText(parts: List<LivePart>, delta: String): List<LivePart> {
        if (delta.isEmpty()) return parts
        val last = parts.lastOrNull()
        return if (last is LivePart.Text) parts.dropLast(1) + LivePart.Text(last.text + delta) else parts + LivePart.Text(delta)
    }

    /** The studio-API fallback's stream (camera chat ChatEvents) applied to the live turn. */
    fun api(ui: ClaudeChatUi, ev: ChatEvent): ClaudeChatUi {
        val t = ui.turn ?: return ui
        return when (ev.type) {
            "text" -> ui.copy(turn = t.copy(state = "running", parts = appendText(t.parts, ev.delta.orEmpty())))
            "tool" -> {
                val id = ev.id ?: return ui
                val part = LivePart.Tool(id, ev.name ?: "tool", if (ev.status == "running") "running" else if (ev.status == "error") "error" else "done", ev.summary)
                val i = t.parts.indexOfFirst { it is LivePart.Tool && it.id == id }
                ui.copy(turn = t.copy(state = "running", parts = if (i >= 0) t.parts.toMutableList().also { it[i] = part } else t.parts + part))
            }
            "error" -> ui.copy(turn = t.copy(state = "failed", error = ev.error), notice = ev.error ?: "Claude couldn't finish")
            "done" -> ui.copy(turn = t.copy(state = "done"))
            else -> ui
        }
    }

    /** Stored messages, then (while a turn runs, or until the stored messages replace them) the live parts. */
    fun items(ui: ClaudeChatUi): List<ChatItem> {
        val out = mutableListOf<ChatItem>()
        for (m in ui.messages) when {
            m.role == "user" -> out += ChatItem.User(m.id, ChatClean.userText(m.text), m.source, m.attachments.map { it.url }, m.createdAt)
            m.image != null -> out += ChatItem.Image(m.id, url = m.image.url)
            m.role == "tool" || m.tool != null -> m.tool?.let { tl -> out += tool(m.id, tl.name, ChatClean.summary(tl.summary ?: m.text), if (tl.ok == false) "error" else "done") }
            m.text.isNotBlank() -> out += ChatItem.Assistant(m.id, ChatClean.assistantText(m.text), at = m.createdAt)
        }
        val t = ui.turn ?: return out
        // The phone's message before it is stored (the API fallback stores it with the turn).
        if (t.text.isNotBlank() && ui.messages.none { it.role == "user" && (it.turnId == t.id && t.id != null || it.text == t.text) })
            out += ChatItem.User("live-user", ChatClean.userText(t.text), if (t.api) "api" else "phone")
        t.parts.forEachIndexed { i, p ->
            out += when (p) {
                is LivePart.Text -> ChatItem.Assistant("live-$i", ChatClean.assistantText(p.text).trimEnd(), streaming = t.active && i == t.parts.lastIndex)
                is LivePart.Tool -> tool("live-${p.id}", p.name, ChatClean.summary(p.summary), p.status)
                is LivePart.Image -> ChatItem.Image("live-img-$i", data = p.data, mimeType = p.mimeType)
            }
        }
        return out.filterNot { it is ChatItem.Assistant && it.text.isBlank() || it is ChatItem.User && it.text.isBlank() && it.images.isEmpty() }
    }

    /** A tool row: its words, and the line a tap shows. Never the raw name, input or output. */
    private fun tool(key: String, name: String, summary: String?, status: String): ChatItem.Tool {
        val running = status == "running"
        val ok = status != "error"
        val text = ChipText.of(name, summary, running)
        val what = ChipText.words(name)
        val detail = ChatClean.toolDetail(what, summary, if (running) "running" else if (!ok) "error" else "done")
        return ChatItem.Tool(key, if (!ok) "$what didn't work" else text, ok, running, detail)
    }

    /** The owner's last message (for Retry): the live turn's, else the newest stored one. */
    fun lastUserText(ui: ClaudeChatUi): String? =
        ui.turn?.text?.takeIf { it.isNotBlank() } ?: ui.messages.lastOrNull { it.role == "user" && it.text.isNotBlank() }?.text?.let(ChatClean::userText)
}

// ---------------------------------------------------------------- the status line

enum class Tone { GOOD, WAIT, OFF }

data class StatusLineText(val text: String, val tone: Tone)

object ClaudeText {
    const val MODE = "On your Claude plan, answered by your Mac"
    const val ANSWERING = "Your Mac is answering"
    const val WAITING = "Waiting for your Mac…"
    const val OFFLINE = "Claude on your Mac is offline"
    const val API = "Answering on the studio API key, billed per use"
    const val STOPPING = "Stopping…"
    const val CONNECTOR_NOTE = "MUSE has to be added to Claude as a connector first."
    const val FALLBACK_NOTE = "Turn on the API fallback in Settings → Connections"
    const val NO_KEY_NOTE = "The API fallback isn't set up on the server yet"
    const val EDIT_NO_API = "The studio API key works in Camera stage and the Suite for now"

    /** The empty chat's line, per context. */
    fun empty(contextKind: String) = when (contextKind) {
        "edit" -> "Tell Claude what to change: trims, captions, the look, the music. Every change can be undone."
        "recreate" -> "Ask Claude about this reference: which takes fit, what each new shot would cost, how to write the briefs."
        "suite" -> "Describe the shot you want. Claude sets up the composer: the model, the prompt and the rig. You approve the price before anything is made."
        else -> "Tell Claude what happens in the shot: who moves where, when, and how the camera moves."
    }

    fun placeholder(contextKind: String) = when (contextKind) {
        "edit" -> "Ask Claude to edit…"
        "suite" -> "Describe the shot…"
        "camera" -> "Direct the shot…"
        else -> "Message Claude…"
    }

    fun status(ui: ClaudeChatUi): StatusLineText {
        val t = ui.turn
        val mac = ui.status?.mac
        return when {
            t != null && t.active && t.stopping -> StatusLineText(STOPPING, Tone.WAIT)
            t != null && t.active && t.api -> StatusLineText(API, Tone.WAIT)
            t != null && t.state == "queued" -> StatusLineText(WAITING, Tone.WAIT)
            t != null && t.state == "running" -> StatusLineText(ANSWERING, Tone.GOOD)
            ui.refusal != null -> StatusLineText(OFFLINE, Tone.OFF)
            mac == null -> StatusLineText(MODE, Tone.GOOD)
            !mac.online -> StatusLineText(OFFLINE, Tone.OFF)
            !mac.claudeCode.installed -> StatusLineText("Claude Code isn't installed on your Mac", Tone.OFF)
            !mac.claudeCode.signedIn -> StatusLineText("Sign in to Claude Code on your Mac", Tone.OFF)
            else -> StatusLineText(MODE, Tone.GOOD)
        }
    }

    /** A finished turn's line under the transcript ("Stopped", "Your Mac didn't pick this up"), or null. */
    fun ended(t: LiveTurn?): String? = when (t?.state) {
        "stopped" -> "Stopped. Send a message to carry on."
        "failed" -> ChatClean.turnError(t.error)
        else -> null
    }

    /** "YOU · PHONE" / "YOU · MAC" / "YOU · API KEY". */
    fun youLabel(source: String) = when (source) { "mac" -> "You · Mac"; "api" -> "You · API key"; else -> "You · Phone" }
}

// ---------------------------------------------------------------- Mac offline: what to offer

/** What the "Mac offline" card shows. [openInClaude] null hides the card. */
data class FallbackChoice(val openInClaude: String?, val useApiKey: Boolean, val note: String?)

object Fallback {
    /**
     * Nothing while the Mac with Claude Code is ready and nothing was refused. Otherwise Open in Claude (the refusal's URL,
     * else the status's), plus "Use the studio API key" only when the fallback is on and the key is set (camera threads only
     * for now), else a quiet note.
     */
    fun decide(status: ClaudePlanStatus?, refusal: ClaudeFallback?, contextKind: String): FallbackChoice? {
        if (refusal == null && (status == null || status.mac.ready)) return null
        val url = refusal?.openInClaudeUrl?.takeIf { it.isNotBlank() } ?: status?.openInClaudeUrl?.takeIf { it.isNotBlank() } ?: "https://claude.ai/new"
        val api = refusal?.apiFallback ?: (status?.apiFallback?.usable == true)
        return when {
            // The studio API key answers Camera stage and Claude in the Suite (WS1 1eda187: api-turn with the Suite tools).
            contextKind != "camera" && contextKind != "suite" -> FallbackChoice(url, false, EDIT_NOTE)
            api -> FallbackChoice(url, true, null)
            status != null && !status.apiFallback.available -> FallbackChoice(url, false, ClaudeText.NO_KEY_NOTE)
            else -> FallbackChoice(url, false, ClaudeText.FALLBACK_NOTE)
        }
    }

    private const val EDIT_NOTE = ClaudeText.EDIT_NO_API
}

// ---------------------------------------------------------------- what the chat may show (plans/claude-chat-android.md)

/**
 * Keeps internal content out of the chat, one to one with the Mac's ChatLeakFilter (WS11, MuseCore): system briefs and
 * thinking markup, the context line the Mac puts before a message ("[Suite · …]"), raw JSON and json fences, stack
 * traces, file paths (shown as the file name, else "a file"), internal ids and MCP tool names. What's left is plain language.
 */
object ChatClean {
    private val TAGS = listOf("system-reminder", "system", "thinking", "context", "brief", "instructions", "muse_context", "suite_context",
        "tool_use", "tool_result", "function_calls", "function_results", "invoke", "parameter", "env", "command-name",
        "local-command-stdout", "user-prompt-submit-hook")
    private val CONTEXT_HEADS = setOf("Suite", "Recreate", "Camera", "Edit", "MUSE", "Muse", "Context", "System")
    private val TRACE = Regex(listOf(
        """^at\s+\S.*[:(]\d+(:\d+)?\)?$""", """^Traceback \(most recent call last\)""", """^File ".+", line \d+""",
        """^\d+\s+\S+\s+0x[0-9a-fA-F]+\s""", """^#\d+\s+0x[0-9a-fA-F]+""",
        """^(Fatal error|Thread \d+ Crashed|Exception Type|Uncaught|UnhandledPromiseRejection)""",
        """^\w*(Error|Exception): .+ at .+:\d+""", """^\s*node:internal/""", """^at [\w.$]+\(""", """^\w+(\.\w+)+(Exception|Error)(:|$)""",
    ).joinToString("|"))
    private val PATH = Regex("""(?<![\w.:/~-])(?:~|/(?:Users|home|private|var|tmp|opt|Volumes|Library|Applications|usr|etc|srv|app|workspace|root|mnt|data|sdcard|storage))(?:/[^\s/`'"()<>\[\],;]+)+/?|[A-Za-z]:\\(?:[^\s\\]+\\)*[^\s\\]+""")
    private val MCP = Regex("""\bmcp__[A-Za-z0-9_-]+""")
    private val UPLOAD_ID = Regex("""\s*\((?:upload ?id|id|thread|session|turn)[: ]+[A-Za-z0-9_-]*\d[A-Za-z0-9_-]*\)""", RegexOption.IGNORE_CASE)
    private val UUID = Regex("""\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b""")
    /** "cs_1a2b3c", "up_1", "toolu_01ABC": a short lowercase prefix, an underscore, and letters with a digit. */
    private val ID = Regex("""`?\b(?:[a-z]{1,8}_)+(?=[A-Za-z0-9]*\d)[A-Za-z0-9]{1,40}\b`?""")
    private val HEX = Regex("""\b(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{16,}\b""")
    private val LABELLED_ID = Regex("""(?i)\b(?:upload ?id|thread ?id|session ?id|turn ?id|id)\s*[:=]?\s*$""")
    private val TOOL_WORD = Regex("""\b[a-z]+(?:_[a-z]+)+\b""")

    /** Claude's reply, ready for ChatMarkdown. Safe mid-stream: an unfinished brief or JSON line is hidden. */
    fun assistantText(text: String): String = tidy(scrub(stripLines(stripTags(text), dropContext = true)))

    /** The owner's message as typed: no context line, no attached-image list, no sentence that only instructs Claude. */
    fun userText(text: String): String {
        var t = stripTags(text)
        while (t.startsWith("[")) {
            val nl = t.indexOf('\n')
            if (nl < 0) { if (contextLine(t)) t = ""; break }
            if (!contextLine(t.substring(0, nl))) break
            t = t.substring(nl + 1)
        }
        t.indexOf("Attached images (Read each one):").takeIf { it >= 0 }?.let { t = t.substring(0, it) }
        t = dropToolSentences(t)
        return tidy(scrub(t)).trim()
    }

    /** A tool's summary as one short line, or null when nothing usable is left (the row then uses the tool's name in words). */
    fun summary(s: String?): String? {
        val t = s?.let { tidy(scrub(stripTags(it))).trim() }?.takeIf { it.isNotEmpty() } ?: return null
        if (looksLikeJson(t) || t.startsWith("{") || t.startsWith("[{") || t.contains("\":") || TRACE.containsMatchIn(t.lineSequence().first().trim())) return null
        val line = t.lineSequence().first().trim()
        return if (line.length > 80) line.take(77).trimEnd() + "…" else line
    }

    /** The row's expanded line (the Mac's wording): what the step was and how it ended. */
    fun toolDetail(what: String, summary: String?, status: String): String {
        val head = if (summary == null || summary.equals(what, ignoreCase = true)) what else "$what: $summary"
        return when (status) {
            "running" -> "$head. Still running."
            "error" -> "$head. This step didn't work; Claude usually tries another way."
            else -> "$head. Finished."
        }
    }

    /** A failed turn's error in plain words (the Mac's errorWords): what happened and what to do. */
    fun turnError(raw: String?): String {
        val r = raw?.trim().orEmpty()
        val l = r.lowercase()
        fun has(vararg xs: String) = xs.any { it in l }
        return when {
            r.isEmpty() -> FAILED
            // The server's silent-turn timeout ("Your Mac stopped answering"): not the owner's Stop.
            has("mac stopped answering", "stopped responding") -> "Your Mac stopped answering. Check MUSE on your Mac, then try again."
            has("stopped", "interrupt", "cancel", "aborted") -> "Stopped. Send a message to carry on."
            has("isn't ready", "not installed", "enoent", "command not found") -> "Claude Code isn't ready on your Mac. Open MUSE on your Mac to set it up, then try again."
            has("rate limit", "usage limit", "429", "overloaded", "quota") -> "Your Claude plan has reached its limit for now. Try again in a little while."
            has("not signed in", "login", "log in", "401", "unauthor") -> "Claude Code is signed out on your Mac. Sign in again, then try again."
            has("timed out", "timeout", "took too long") -> "Claude took too long to answer. Try again."
            has("offline", "network", "connection", "econnrefused", "econnreset", "enotfound", "unable to resolve host", "dns", "unreachable", "failed to connect") -> NETWORK
            has("turn_expired", "expired") -> "That message waited too long and expired. Send it again."
            else -> plainOr(r, FAILED, strict = true)
        }
    }

    /** A notice or load error as one plain sentence; [fallback] when it is technical. */
    fun error(raw: String?, fallback: String = FAILED): String {
        val r = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return fallback
        val l = r.lowercase()
        return when {
            "timed out" in l || "timeout" in l -> "Claude took too long to answer. Try again."
            listOf("unable to resolve host", "failed to connect", "econnrefused", "econnreset", "connection reset", "enotfound").any { it in l } ||
                "network" in l && "error" in l -> NETWORK
            "rate limit" in l || "429" in l || "overloaded" in l -> "Claude is busy right now. Try again in a minute."
            else -> plainOr(r, fallback, strict = false)
        }
    }

    /** Is this error about the connection (the "You're offline" state)? */
    fun isNetwork(raw: String?): Boolean = error(raw, "") == NETWORK

    private fun plainOr(r: String, fallback: String, strict: Boolean): String {
        val cleaned = tidy(scrub(stripLines(stripTags(r), dropContext = true))).trim()
        val technical = cleaned.isEmpty() || cleaned.length > 160 || looksLikeJson(cleaned) || cleaned.startsWith("{") || cleaned.contains("\":") ||
            TRACE.containsMatchIn(r) || PATH.containsMatchIn(r) || r.startsWith("Error:") || cleaned.contains('\n') ||
            Regex("""\bE[A-Z]{4,}\b|(?i)\b(exception|errno|exit code|status \d{3}|http \d{3}|traceback|panic|fatal|undefined|null pointer|stderr)\b""").containsMatchIn(cleaned) ||
            (strict && Regex("""(?i)\b(error|null|nil)\b""").containsMatchIn(cleaned))
        if (technical) return fallback
        return if (strict && !cleaned.endsWith(".")) "$cleaned." else cleaned
    }

    // ---------------------------------------------------------------- pieces

    /** `<system-reminder>…</system-reminder>`, `<thinking>…`, tool markup: removed with what they hold; an unclosed one hides the rest. */
    fun stripTags(text: String): String {
        if ('<' !in text) return text
        var s = text
        for (name in TAGS) {
            while (true) {
                val open = s.indexOf("<$name", ignoreCase = true)
                if (open < 0) break
                val after = s.getOrNull(open + name.length + 1)
                if (after != null && after != '>' && after != ' ' && after != '\n') break
                val close = s.indexOf("</$name>", open + 1, ignoreCase = true)
                s = if (close >= 0) s.removeRange(open, close + name.length + 3) else s.substring(0, open)
            }
        }
        return s
    }

    private fun contextLine(line: String): Boolean {
        val t = line.trim()
        if (!t.startsWith("[") || !t.endsWith("]")) return false
        return t.drop(1).takeWhile { it.isLetter() } in CONTEXT_HEADS
    }

    /** Line by line: context lines, raw JSON, stack traces. Code fences stay, except one that holds only JSON. */
    private fun stripLines(text: String, dropContext: Boolean): String {
        val lines = text.split('\n')
        val out = ArrayList<String>(lines.size)
        var i = 0
        var inTrace = false
        while (i < lines.size) {
            val line = lines[i]
            val t = line.trim()
            if (t.startsWith("```") || t.startsWith("~~~")) {
                val marker = t.take(3)
                val lang = t.drop(3).trim().lowercase()
                var j = i + 1
                val body = mutableListOf<String>()
                while (j < lines.size && !lines[j].trim().startsWith(marker)) { body += lines[j]; j++ }
                val joined = body.joinToString("\n").trim()
                if (lang == "json" || lang == "jsonc" || (lang.isEmpty() && looksLikeJson(joined))) { i = j + 1; continue }
                out += line; out += body
                if (j < lines.size) out += lines[j]
                i = j + 1; continue
            }
            if (dropContext && contextLine(t)) { i++; continue }
            if (t.startsWith("{\"") || t.startsWith("[{\"") || (looksLikeJson(t) && t.length > 2)) { i++; continue }
            if (TRACE.containsMatchIn(t) || (inTrace && (line.startsWith("  ") || line.startsWith("\t")) && t.isNotEmpty())) { inTrace = true; i++; continue }
            inTrace = false
            out += line
            i++
        }
        return out.joinToString("\n")
    }

    private fun looksLikeJson(t: String): Boolean {
        val obj = t.startsWith("{") && t.endsWith("}")
        val arr = t.startsWith("[") && t.endsWith("]") && t.contains("{")
        if (!obj && !arr) return false
        return runCatching { kotlinx.serialization.json.Json.parseToJsonElement(t); true }.getOrDefault(false)
    }

    /** Paths, ids and MCP tool names out of running text (code blocks keep paths: a script needs them). */
    private fun scrub(text: String): String {
        var inFence = false
        return text.split('\n').joinToString("\n") { line ->
            val t = line.trim()
            if (t.startsWith("```") || t.startsWith("~~~")) { inFence = !inFence; return@joinToString line }
            var s = MCP.replace(line) { ChipText.words(it.value).lowercase() }
            s = UPLOAD_ID.replace(s, "")
            if (!inFence) s = PATH.replace(s) { m ->
                val tail = m.value.takeLastWhile { it in ".,;:!?" }
                fileName(m.value.dropLast(tail.length)) + tail
            }
            s = UUID.replace(s, "")
            s = HEX.replace(s, "")
            if (!inFence) s = ID.replace(s, "")
            LABELLED_ID.replace(s, "")
        }
    }

    /** A path as its file name when that reads as a name ("Final cut.mp4"), else "a file". */
    private fun fileName(path: String): String {
        val last = path.split('/', '\\').lastOrNull { it.isNotEmpty() }.orEmpty()
        val stem = last.substringBeforeLast('.', last)
        val ext = if ('.' in last) last.substringAfterLast('.') else ""
        val idLike = Regex("""^(?:[a-z]{1,8}_)+[A-Za-z0-9]*\d|^[0-9a-fA-F-]{12,}$|^\d+$""").containsMatchIn(stem)
        return if (last.isEmpty() || ext.isEmpty() || idLike || stem.length > 48) "a file" else last
    }

    /** A suggestion's instructions for Claude ("Use get_recipe.") aren't the owner's words: sentences naming a tool go. */
    private fun dropToolSentences(text: String): String {
        if (!TOOL_WORD.containsMatchIn(text)) return text
        val sentences = mutableListOf<String>()
        val cur = StringBuilder()
        text.forEachIndexed { i, c ->
            cur.append(c)
            val next = text.getOrNull(i + 1)
            if (c == '\n' || (c in ".?!" && (next == null || next == ' ' || next == '\n'))) { sentences += cur.toString(); cur.clear() }
        }
        if (cur.isNotEmpty()) sentences += cur.toString()
        val kept = sentences.filterNot { TOOL_WORD.containsMatchIn(it) }.joinToString("").trim()
        return kept.ifEmpty { text }
    }

    /** Spaces and blank lines left where something was removed; code fences keep their whitespace. */
    private fun tidy(s: String): String {
        val out = mutableListOf<String>()
        var inFence = false
        var blank = 0
        for (raw in s.split('\n')) {
            val t = raw.trim()
            if (t.startsWith("```") || t.startsWith("~~~")) { inFence = !inFence; blank = 0; out += raw; continue }
            if (inFence) { out += raw; continue }
            if (t.isEmpty()) { blank++; if (blank <= 1 && out.isNotEmpty()) out += ""; continue }
            blank = 0
            val indent = raw.takeWhile { it == ' ' || it == '\t' }
            var body = raw.drop(indent.length)
            while ("  " in body) body = body.replace("  ", " ")
            for (p in listOf(" .", " ,", " ;", " :", " )")) body = body.replace(p, p.drop(1))
            body = body.replace("( ", "(").replace(" ()", "")
            out += indent + body.trim()
        }
        while (out.lastOrNull() == "") out.removeAt(out.lastIndex)
        return out.joinToString("\n")
    }

    const val FAILED = "Claude couldn't finish this reply."
    const val NETWORK = "Couldn't reach the server. Check your connection, then try again."
}

/** Time labels between messages: "Today 14:05", "Yesterday 09:12", "Mon 3 Nov, 18:40" (24 h, the phone's zone). */
object ChatTime {
    /** A label goes above a message when it's the first, or more than [GAP_MS] after the one before. */
    const val GAP_MS = 30 * 60 * 1000L

    fun needsLabel(prevAt: Long, at: Long): Boolean = at > 0 && (prevAt <= 0 || at - prevAt >= GAP_MS)

    fun label(at: Long, now: Long, zone: java.util.TimeZone = java.util.TimeZone.getDefault()): String {
        val c = java.util.Calendar.getInstance(zone, Locale.UK).apply { timeInMillis = at }
        val n = java.util.Calendar.getInstance(zone, Locale.UK).apply { timeInMillis = now }
        val time = String.format(Locale.UK, "%02d:%02d", c.get(java.util.Calendar.HOUR_OF_DAY), c.get(java.util.Calendar.MINUTE))
        fun dayIndex(x: java.util.Calendar) = x.get(java.util.Calendar.YEAR) * 400 + x.get(java.util.Calendar.DAY_OF_YEAR)
        val diff = dayIndex(n) - dayIndex(c)
        return when {
            diff == 0 -> "Today $time"
            diff == 1 -> "Yesterday $time"
            c.get(java.util.Calendar.YEAR) == n.get(java.util.Calendar.YEAR) ->
                java.text.SimpleDateFormat("EEE d MMM", Locale.UK).apply { timeZone = zone }.format(java.util.Date(at)) + ", $time"
            else -> java.text.SimpleDateFormat("d MMM yyyy", Locale.UK).apply { timeZone = zone }.format(java.util.Date(at)) + ", $time"
        }
    }
}

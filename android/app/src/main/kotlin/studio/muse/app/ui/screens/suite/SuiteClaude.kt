package studio.muse.app.ui.screens.suite

import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import studio.muse.app.data.ClaudeSessions
import studio.muse.app.data.ClaudeThread
import studio.muse.app.ui.screens.claude.ClaudeChatStore
import studio.muse.app.data.ApiException
import studio.muse.app.data.SuiteAssist
import studio.muse.app.data.SuitePending
import studio.muse.app.ui.screens.suite.composer.ComposerDrafts
import studio.muse.app.ui.screens.suite.composer.ComposerTool

/**
 * Claude in the AI Suite (owner-approved 2026-11-08; WS1 1eda187, plans/api.md "Claude in the AI Suite"). The owner
 * describes a shot; Claude fills in the composer through a shared draft. Claude's changes arrive as `suiteAssist` events
 * and are applied like Reuse settings; the owner's own edits go back (PATCH), so Claude sees them. Claude never
 * generates: its Generate waits as a [SuitePending] until the owner approves it at the price shown.
 */
data class SuiteAssistUi(val id: String, val revision: Int, val pending: SuitePending? = null, val answering: Boolean = false, val message: String? = null,
    /** WS18: the mode's list of chats this draft belongs to (`suite:photo`…). */
    val key: String? = null,
    /** What Claude sees here, as the context strip reads it ({request, inputs, settings}). */
    val screen: kotlinx.serialization.json.JsonObject? = null)

/** The context strip's screen from the server's view of the shared draft. */
fun SuiteAssist.contextScreen(): kotlinx.serialization.json.JsonObject? {
    val r = request ?: return null
    val o = onScreen
    return kotlinx.serialization.json.JsonObject(buildMap {
        put("request", r)
        o?.get("inputs")?.let { put("inputs", it) }
        o?.get("settings")?.let { put("settings", it) }
    })
}

/** WS18: the composer's mode's list of chats. */
val SuiteStore.claudeKey: String get() = ClaudeSessions.suiteKey(composer.value.tool.id)

/**
 * The shared draft for the Claude sheet (WS18): the mode's latest chat (the one open last on this device, else the newest on
 * the server) with its draft laid over the composer, so the chat and the composer are one draft; a mode with no chat yet
 * shares the composer as it is. Null (with a toast) when the server can't.
 */
suspend fun SuiteStore.openClaude(): String? {
    val key = claudeKey
    assist.value?.takeIf { it.key == key || it.key == null && key == ClaudeSessions.suiteKey("shot") }?.let { return it.id }
    val list = runCatching { app.repo.api.claude.threads(key) }.getOrNull().orEmpty()
    ClaudeSessions.pick(list, ClaudeSessions.remembered(key))?.let { t -> if (bindClaudeChat(t)) return assist.value?.id }
    return newClaudeChat()
}

/** A chat picked from the mode's list: its shared draft becomes the composer's. False when the draft is gone. */
suspend fun SuiteStore.bindClaudeChat(t: ClaudeThread): Boolean {
    if (t.contextKind != "suite") return false
    val a = runCatching { app.repo.api.suiteAssist(t.contextId) }.getOrNull() ?: return false
    assist.value = SuiteAssistUi(a.id, 0, a.waiting, key = claudeKey, screen = a.contextScreen())
    assistSynced = null
    applyAssist(a)
    ClaudeSessions.remember(claudeKey, t.id)
    return true
}

/** New chat in this mode: a new shared draft from the composer as it is now (the composer stays). */
suspend fun SuiteStore.newClaudeChat(): String? {
    val (a, err) = app.repo.attemptInline { createSuiteAssist(ComposerDrafts.draft(composer.value)) }
    if (a == null) { app.repo.toast(err ?: "Claude in the Suite isn't available on this server yet"); return null }
    assist.value = SuiteAssistUi(a.id, a.revision, a.waiting, key = claudeKey, screen = a.contextScreen())
    assistSynced = null // the screen goes up with the next sync
    return a.id
}

/** The chat's sessions in the Suite: New chat is a new shared draft; switching or deleting binds another chat's. */
fun SuiteStore.claudeHooks(scope: kotlinx.coroutines.CoroutineScope) = ClaudeChatStore.SessionHooks(
    newChat = { newClaudeChat() },
    open = { t -> if (!bindClaudeChat(t)) app.repo.toast("That chat's shot is gone. Start a new chat.") },
    deleted = { next -> if (next == null || !bindClaudeChat(next)) newClaudeChat() },
)

/** Claude's tool step finished: a draft change is read again at once, even if the live event was missed. */
fun SuiteStore.claudeToolDone(name: String, scope: kotlinx.coroutines.CoroutineScope) {
    if (!(name.endsWith("suite_set_draft") || name.endsWith("suite_add_reference") || name.endsWith("suite_request_shot"))) return
    val id = assist.value?.id ?: return
    scope.launch { runCatching { app.repo.api.suiteAssist(id) }.getOrNull()?.let { applyAssist(it) } }
}

/** A `suiteAssist` event (or a fresh read): Claude's newer draft goes into the composer, as Reuse settings does. */
fun SuiteStore.applyAssist(a: SuiteAssist) {
    val cur = assist.value ?: return
    if (a.id != cur.id) return
    if (a.revision > cur.revision) {
        val before = composer.value
        // The composer keeps its mode (WS18): a draft an older server set to Shot doesn't switch Photo or Talking to Shot.
        composer.value = ComposerDrafts.restore(a.draft, before).copy(tool = before.tool)
        assistSynced = null // the composer as Claude left it goes back up with its screen
        // "Claude set Camera and Light", with Undo (the Rigs row's Undo; undoing goes back to Claude as the owner's edit).
        SuiteClaudeWords.claudeSet(SuiteClaudeWords.changed(before, composer.value))?.let { rigUndo.value = it to before }
        // Swap / Recast's Background, set by Claude (suite_set_draft background): the panel takes it, as the model is taken.
        val bg = (a.draft.json["background"] as? kotlinx.serialization.json.JsonPrimitive)?.takeIf { it.isString }?.content
        if ((before.tool == ComposerTool.SWAP || before.tool == ComposerTool.RECAST) && bg in setOf("keep", "photo", "describe") && bg != recast.value.background) {
            val r = recast.value.copy(background = bg!!)
            recast.value = r
            app.repo.toast(when {
                bg == "photo" && r.backgroundImage == null -> "Claude set Background: New photo · pick the picture"
                bg == "describe" && r.place.isBlank() -> "Claude set Background: Describe it · write the new place"
                else -> "Claude set Background: ${SuiteClaudeWords.background(bg)}"
            })
        }
    }
    assist.update { it?.copy(revision = maxOf(it.revision, a.revision), pending = a.waiting, screen = a.contextScreen() ?: it.screen) }
}

/** The owner's own edit in the composer: sent so Claude sees it. When Claude changed the draft meanwhile, Claude's wins. */
suspend fun SuiteStore.pushComposerToAssist(screen: ((Long?) -> kotlinx.serialization.json.JsonObject)? = null) {
    val cur = assist.value ?: return
    // Another mode's draft (WS18): the composer switched tools; that mode's chat is bound when Claude opens there.
    if (cur.key != null && cur.key != claudeKey) return
    val base = ComposerDrafts.draft(composer.value)
    // Everything on screen (owner, 2026-11-11): the clip, guides and slot pictures and the request Generate would send.
    val key = screen?.let { kotlinx.serialization.json.JsonObject(base.json + ("screen" to it(null))) } ?: base.json
    if (key.toString() == assistSynced) return
    val d = screen?.let { studio.muse.app.data.SuiteDraft(kotlinx.serialization.json.JsonObject(base.json + ("screen" to it(System.currentTimeMillis())))) } ?: base
    try {
        val a = app.repo.api.patchSuiteAssist(cur.id, d, cur.revision)
        assistSynced = key.toString()
        assist.update { it?.copy(revision = a.revision, pending = a.waiting, screen = a.contextScreen() ?: it.screen) }
    } catch (e: ApiException) {
        if (e.code == "stale") runCatching { app.repo.api.suiteAssist(cur.id) }.getOrNull()?.let { applyAssist(it) }
    }
}

/**
 * The owner's answer to Claude's Generate. Yes runs it at the approved price (the server re-prices and refuses with
 * `price_changed` if it rose); the new render joins the composer's renders. No declines it.
 */
suspend fun SuiteStore.answerClaude(approve: Boolean, pendingId: String? = null): String? {
    val cur = assist.value ?: return null
    val p = cur.pending ?: return "Already answered"
    if (pendingId != null && p.id != pendingId) return "Already answered"
    if (cur.answering) return null
    assist.update { it?.copy(answering = true, message = null) }
    try {
        val r = app.repo.api.answerSuitePending(cur.id, p.id, approve)
        r.jobId?.let { id -> shotJobs.update { it + id }; runCatching { app.repo.refresh() } }
        val msg = when (r.status) { "failed" -> r.error ?: "That shot didn't start · you weren't charged"; else -> null }
        assist.update { it?.copy(answering = false, pending = null, message = msg) }
        if (!approve) app.repo.toast(SuiteClaudeWords.NOT_NOW)
        // The Approve card's words (the chat shows them in place of its buttons).
        return msg ?: if (approve) "Approved, rendering" else "Declined"
    } catch (e: ApiException) {
        val msg = if (e.code == "price_changed") "${e.message ?: "The price changed"} · ask Claude again or press Generate yourself" else e.message ?: "Couldn't answer Claude"
        assist.update { it?.copy(answering = false, pending = if (e.code == "price_changed") null else it.pending, message = msg) }
        return if (e.code == "price_changed") msg else null
    }
}

/** The Suite's Claude words, as on the Mac (WS2's SuiteAssistClaude, SuiteAssistDraft, SuiteClaudePanel). */
object SuiteClaudeWords {
    const val SUBTITLE = "Fills in this composer"
    const val NOT_NOW = "Told Claude not now"
    fun toggle(open: Boolean) = if (open) "Hide Claude" else "Show Claude"
    fun background(b: String) = when (b) { "photo" -> "New photo"; "describe" -> "Describe it"; else -> "Keep" }

    /** The chips: what each sends to Claude. */
    val suggestions = listOf(
        "Fill this in from my idea" to "Fill in the composer from my idea in the prompt: the character, the prompt and every Setup row, using only options the composer offers (suite_options, then suite_set_draft). Then tell me in a few lines what you set.",
        "Make it more cinematic" to "Make this shot more cinematic: change the camera, light, look and style rows with suite_set_draft. Keep my prompt and character. Tell me briefly what you changed.",
        "Explain the settings" to "Explain the settings in the composer now, row by row, in plain words. Don't change anything.",
    )

    /** "Claude set Camera", "Claude set Camera and Light", "Claude set Camera, Light and Length"; null when nothing changed. */
    fun claudeSet(changed: List<String>): String? {
        if (changed.isEmpty()) return null
        val list = if (changed.size == 1) changed[0] else changed.dropLast(1).joinToString(", ") + " and " + changed.last()
        return "Claude set $list"
    }

    /** The composer's rows that differ, by their names in the composer. */
    fun changed(a: studio.muse.app.ui.screens.suite.composer.ComposerDraft, b: studio.muse.app.ui.screens.suite.composer.ComposerDraft): List<String> = buildList {
        val x = a.settings; val y = b.settings
        if (a.tokens.character?.id != b.tokens.character?.id) add("Character")
        if (a.tokens != b.tokens) add("Prompt")
        if (a.directed != b.directed) add("Movement")
        if (a.engineModel != b.engineModel || a.resolution != b.resolution) add("Model")
        if (listOf(x.body, x.lens, x.focalMm, x.aperture, x.height, x.shotSize) != listOf(y.body, y.lens, y.focalMm, y.aperture, y.height, y.shotSize)) add("Camera")
        if (x.lighting != y.lighting) add("Light")
        if (listOf(x.palette, x.stock, x.gradeLook) != listOf(y.palette, y.stock, y.gradeLook)) add("Look")
        if (listOf(x.genre, x.era, x.tempo, x.format) != listOf(y.genre, y.era, y.tempo, y.format)) add("Style")
        if (a.quality != b.quality) add("Quality")
        if (a.aspect != b.aspect) add("Shape")
        if (a.duration != b.duration) add("Length")
        if (a.takes != b.takes) add("Takes")
        if (a.sound != b.sound) add("Sound")
        if (a.references != b.references) add("References")
    }
}

/** A chip's words sent to Claude on the Suite thread (the chat shows it as the owner's message). */
suspend fun SuiteStore.askClaude(text: String) {
    val id = assist.value?.id ?: return
    val (r, err) = app.repo.attemptInline { claude.post(claude.thread("suite", id).id, text) }
    if (r == null) app.repo.toast(err ?: "Couldn't reach Claude")
    else if (r is studio.muse.app.data.ClaudeSend.MacOffline) app.repo.toast("Claude isn't answering on your Mac · open the chat for other ways")
}

/** Removes a reference chip from the composer (and so from the shared draft on the next sync). */
fun SuiteStore.removeDraftReference(uploadId: String, url: String) =
    composer.update { d -> d.copy(references = d.references.filterNot { it.uploadId == uploadId && it.url == url }) }

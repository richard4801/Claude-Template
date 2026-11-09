package studio.muse.app.ui.screens.claude

// Workstream 2's chat component (plans/claude-editing.md part E), used by Camera stage (Direct with Claude) and, placed by
// workstream 3, the Edit suite:
//  - ClaudeChat(contextKind, contextId, title, modifier): the whole chat (a right panel on tablets, a full screen).
//  - ClaudeChatSheet(open, onDismiss, contextKind, contextId, title, modifier): the phone's sheet over the screen, opened from
//    ClaudeButton ("Claude"). Put it last in a full-size Box.
// contextKind is "camera" or "edit"; contextId is the camera session id or the edit session id. Owner only.

import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Base64
import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import coil3.compose.AsyncImage
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import studio.muse.app.data.ApiException
import studio.muse.app.data.ImageRef
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.components.ImageViewer
import studio.muse.app.ui.components.RefImage
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.ViewerImage
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.Caption
import studio.muse.app.ui.screens.PrimaryButton
import studio.muse.app.ui.screens.SecondaryButton
import studio.muse.app.ui.screens.TextAction
import studio.muse.app.ui.screens.camera.ConnectionsScreen
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.MuseSpace
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.museFloat
import studio.muse.app.ui.theme.radii
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale

/** What the chat can do (the store's actions, or test stubs). */
class ClaudeChatActions(
    val edit: (String) -> Unit = {},
    val send: () -> Unit = {},
    val stop: () -> Unit = {},
    val openInClaude: (String) -> Unit = {},
    val useApiKey: () -> Unit = {},
    val openConnections: () -> Unit = {},
    val dismissNotice: () -> Unit = {},
    /** The thread couldn't load: try again. */
    val retry: () -> Unit = {},
    /** The last reply failed: send the owner's message again. */
    val retryTurn: () -> Unit = {},
    /** Attach images (the photo picker); null hides the button. */
    val attach: (() -> Unit)? = null,
    val removeAttachment: (String) -> Unit = {},
    /** An image the server couldn't read: convert it to JPEG and upload it again. */
    val sendAsJpeg: (String) -> Unit = {},
    /** WS18: New chat, switch, rename and delete (shown once the server keeps lists). */
    val sessions: ChatSessionActions = ChatSessionActions(),
)

/** A store for one thread, fed by the app's live `claude` events, loaded once. */
@Composable
fun rememberClaudeChatStore(contextKind: String, contextId: String): ClaudeChatStore {
    val c = LocalContainer.current
    val scope = rememberCoroutineScope()
    val store = remember(c, contextKind, contextId) { ClaudeChatStore({ c.repo.api.claude }, scope, contextKind, contextId) }
    LaunchedEffect(store) { store.load() }
    LaunchedEffect(store) { c.repo.live.collect { store.onLive(it) } }
    return store
}

/** The chat for a camera or edit session, on the owner's Claude plan (answered by their Mac). */
@Composable
fun ClaudeChat(contextKind: String, contextId: String, title: String, modifier: Modifier = Modifier, onOpenConnections: (() -> Unit)? = null) =
    ClaudeChat(rememberClaudeChatStore(contextKind, contextId), title, modifier, onOpenConnections)

/** The same with a store the screen holds (Camera stage sends "Re-render the guides" through it). */
@Composable
fun ClaudeChat(store: ClaudeChatStore, title: String, modifier: Modifier = Modifier, onOpenConnections: (() -> Unit)? = null) {
    val ui by store.ui.collectAsState()
    val context = LocalContext.current
    val c = LocalContainer.current
    var connections by remember { mutableStateOf(false) }
    if (connections) Dialog({ connections = false; store.refreshStatus() }, DialogProperties(usePlatformDefaultWidth = false)) {
        ConnectionsScreen { connections = false; store.refreshStatus() }
    }
    // Images for Claude (≤ 4 per message): the photo picker, then presign → PUT → confirm for each.
    val picker = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.PickMultipleVisualMedia(ClaudeChatStore.MAX_IMAGES)) { uris ->
        val room = (ClaudeChatStore.MAX_IMAGES - store.ui.value.attachments.size).coerceAtLeast(0)
        if (uris.size > room) c.repo.toast(ClaudeChatStore.LIMITS)
        uris.take(room).forEach { uri ->
            store.attachAs(uri.toString()) { asJpeg ->
                val media = c.media ?: throw ApiException("unsupported", "Images can't be read on this device")
                val bytes = media.bytes(uri) ?: throw ApiException("bad_request", "Couldn't read that image")
                val mime = media.mime(uri).lowercase()
                // HEIC and WebP go as JPEG up front, as on the Mac; "Send as JPEG" converts anything.
                val convert = asJpeg || mime in ChatImages.CONVERT
                val out = if (convert) ChatImages.toJpeg(bytes) ?: throw ApiException("bad_request", "Couldn't read that image") else bytes
                if (out.size > ChatImages.MAX_BYTES) throw ApiException("bad_request", ClaudeChatStore.LIMITS)
                val name = media.displayName(uri).let { n -> if (convert) n.substringBeforeLast('.') + ".jpg" else n }
                c.repo.api.uploadClaudeImage(name, out, if (convert) "image/jpeg" else mime)
            }
        }
    }
    ClaudeChatContent(ui, title, ClaudeChatActions(
        attach = if (ui.canAttach) ({ picker.launch(androidx.activity.result.PickVisualMediaRequest(androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia.ImageOnly)) }) else null,
        removeAttachment = store::removeAttachment,
        sendAsJpeg = store::sendAsJpeg,
        edit = store::edit, send = { store.send() }, stop = store::stop,
        openInClaude = { url ->
            runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
                .onFailure { c.repo.toast("Couldn't open Claude. Install the Claude app or open claude.ai") }
        },
        useApiKey = { store.useApiKey() },
        openConnections = onOpenConnections ?: { connections = true },
        dismissNotice = store::dismissNotice,
        retry = { store.load() },
        retryTurn = { store.retry() },
        sessions = ChatSessionActions(newChat = { store.newChat() }, open = { store.open(it) }, rename = { t, n -> store.rename(t, n) }, delete = { store.delete(it) }),
    ), modifier)
}

/** One row of the list: a transcript item, a time label, or the footer lines under the transcript. */
private sealed interface ChatRow {
    val key: String
    data class Item(val item: ChatItem, val first: Boolean) : ChatRow { override val key get() = item.key }
    data class Time(override val key: String, val text: String) : ChatRow
    data class Thinking(val text: String) : ChatRow { override val key get() = "thinking" }
    data class Ended(val text: String, val failed: Boolean) : ChatRow { override val key get() = "ended" }
    data object Offline : ChatRow { override val key get() = "offline" }
    data class Notice(val text: String) : ChatRow { override val key get() = "notice" }
}

/** The rows, oldest first: time labels where the conversation paused, then the footer lines. */
private fun rows(ui: ClaudeChatUi, items: List<ChatItem>, now: Long): List<ChatRow> {
    val out = ArrayList<ChatRow>(items.size + 6)
    var prevAt = 0L
    var prev: ChatItem? = null
    for (it in items) {
        val at = when (it) { is ChatItem.User -> it.at; is ChatItem.Assistant -> it.at; else -> 0L }
        if (at > 0 && ChatTime.needsLabel(prevAt, at)) out += ChatRow.Time("time-${it.key}", ChatTime.label(at, now))
        if (at > 0) prevAt = at
        // [first]: the start of an answer (after the owner's message), which gets the wider gap; no labels, as in the Claude app.
        out += ChatRow.Item(it, first = it !is ChatItem.User && (prev == null || prev is ChatItem.User))
        prev = it
    }
    val t = ui.turn
    if (t != null && t.active && (prev == null || prev is ChatItem.User)) out += ChatRow.Thinking(if (t.state == "queued" && !t.api) ClaudeText.WAITING else "Claude is working…")
    ClaudeText.ended(t)?.let { out += ChatRow.Ended(it, t?.state == "failed") }
    if (Fallback.decide(ui.status, ui.refusal, ui.contextKind) != null && t?.active != true) out += ChatRow.Offline
    ui.notice?.let { out += ChatRow.Notice(ChatClean.error(it, "Couldn't send that. Try again.")) }
    return out
}

/**
 * The chat, stateless: the header with the mode line, the transcript (newest at the bottom, kept above the keyboard), the
 * offline block, and the composer (Send / Stop). [now] dates the time labels.
 */
@Composable
fun ClaudeChatContent(ui: ClaudeChatUi, title: String, actions: ClaudeChatActions, modifier: Modifier = Modifier, horizontal: Dp = 16.dp,
    now: Long = remember { System.currentTimeMillis() }) {
    val m = muse
    val items = ui.items
    val rows = remember(ui, now) { rows(ui, items, now) }
    // Newest first in a reversed list: the bottom stays anchored when the keyboard opens or a reply grows.
    val reversed = remember(rows) { rows.asReversed() }
    val list = rememberLazyListState()
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current
    val atBottom by remember { derivedStateOf { list.firstVisibleItemIndex == 0 && list.firstVisibleItemScrollOffset < with(density) { 48.dp.roundToPx() } } }
    // Follow new messages while the owner is at the bottom; scrolling up stops following until they come back down.
    var follow by remember { mutableStateOf(true) }
    LaunchedEffect(list) {
        snapshotFlow { list.isScrollInProgress to atBottom }.collect { (moving, bottom) -> if (moving) follow = bottom else if (bottom) follow = true }
    }
    val lastLen = (items.lastOrNull() as? ChatItem.Assistant)?.text?.length ?: 0
    LaunchedEffect(rows.size, lastLen, ui.turn?.state) { if (follow && rows.isNotEmpty()) list.scrollToItem(0) }
    // The keyboard opening: keep the latest message in view.
    val ime = WindowInsets.ime.getBottom(density)
    LaunchedEffect(ime > 0) { if (ime > 0 && follow && rows.isNotEmpty()) list.scrollToItem(0) }
    val clip = LocalClipboardManager.current
    val haptics = LocalHapticFeedback.current
    var copied by remember { mutableStateOf(0) }
    LaunchedEffect(copied) { if (copied > 0) { delay(1500); copied = 0 } }
    val copy: (String) -> Unit = { text -> clip.setText(AnnotatedString(text)); haptics.performHapticFeedback(HapticFeedbackType.LongPress); copied++ }
    var expanded by remember { mutableStateOf(setOf<String>()) }
    var viewer by remember { mutableStateOf<Pair<List<ViewerImage>, Int>?>(null) }
    viewer?.let { (imgs, i) -> ImageViewer(imgs, i) { viewer = null } }

    BoxWithConstraints(modifier.background(m.roles.canvas).imePadding()) {
    // Short (a phone on its side with the keyboard up): the header drops to its one status line.
    val compact = maxHeight < 360.dp
    Column(Modifier.fillMaxSize()) {
        ChatHeader(ui, title, horizontal, compact)
        if (ui.sessions && ui.thread != null && !compact) ChatSessionsRow(ui, actions.sessions, horizontal)
        Box(Modifier.weight(1f).fillMaxWidth()) {
            when {
                !ui.loaded -> ChatSkeleton(Modifier.padding(horizontal = horizontal, vertical = MuseSpace.s3))
                ui.error != null && ui.thread == null -> Column(Modifier.fillMaxWidth().padding(horizontal = horizontal, vertical = MuseSpace.s4),
                    verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
                    val offline = ChatClean.isNetwork(ui.error)
                    T(if (offline) "You're offline" else "Can't open the chat", m.scale.heading, m.roles.ink)
                    T(if (offline) "The chat comes back when the connection does." else ChatClean.error(ui.error, "Check your connection, then try again."), m.scale.body, m.roles.ink2)
                    Spacer(Modifier.height(MuseSpace.s1))
                    SecondaryButton("Try again", { actions.retry() }, icon = "retry")
                }
                else -> {
                    LazyColumn(Modifier.fillMaxSize().semantics { contentDescription = "Conversation" }, state = list, reverseLayout = true,
                        contentPadding = PaddingValues(horizontal = horizontal, vertical = MuseSpace.s3)) {
                        items(reversed, key = { it.key }, contentType = { it::class }) { r ->
                            // reverseLayout: the gap goes under each row (toward the newer one).
                            Box(Modifier.fillMaxWidth().padding(top = rowGap(r))) {
                                RowView(r, ui, actions, copy, expanded, { k -> expanded = if (k in expanded) expanded - k else expanded + k },
                                    { imgs, i -> viewer = imgs to i })
                            }
                        }
                    }
                    if (items.isEmpty() && rows.none { it is ChatRow.Offline || it is ChatRow.Thinking }) EmptyState(ui.contextKind, Modifier.padding(horizontal = horizontal, vertical = MuseSpace.s4))
                }
            }
            // Scrolled up: one quiet button back to the newest message.
            androidx.compose.animation.AnimatedVisibility(!atBottom && ui.loaded && rows.isNotEmpty(), Modifier.align(Alignment.BottomCenter).padding(bottom = MuseSpace.s3),
                enter = fadeIn(tween(200)), exit = fadeOut(tween(200))) {
                Row(Modifier.heightIn(min = 40.dp).museFloat(m, CircleShape).clip(CircleShape).background(m.roles.raised).border(1.dp, m.roles.hairline, CircleShape)
                    .press { follow = true; scope.launch { list.animateScrollToItem(0) } }.padding(horizontal = MuseSpace.s4)
                    .semantics { role = Role.Button; contentDescription = "Jump to latest" },
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Ic("arrow-down", 16.dp, m.roles.ink)
                    T("Jump to latest", m.scale.label, m.roles.ink, maxLines = 1)
                }
            }
            androidx.compose.animation.AnimatedVisibility(copied > 0, Modifier.align(Alignment.BottomCenter).padding(bottom = MuseSpace.s3),
                enter = fadeIn(tween(120)), exit = fadeOut(tween(200))) {
                Box(Modifier.clip(CircleShape).background(m.roles.ink).padding(horizontal = MuseSpace.s4, vertical = MuseSpace.s2).semantics { liveRegion = LiveRegionMode.Polite }) {
                    T("Copied", m.scale.label, m.roles.canvas, maxLines = 1)
                }
            }
        }
        ChatComposer(ui, actions, horizontal, compact)
    }
    }
}

/** Space above a row: tight inside one answer, wider where the speaker changes or a label starts. */
private fun rowGap(r: ChatRow): Dp = when (r) {
    is ChatRow.Item -> if (r.item is ChatItem.User || r.first) MuseSpace.s5 else MuseSpace.s2
    is ChatRow.Time -> MuseSpace.s5
    else -> MuseSpace.s3
}

@Composable
private fun RowView(r: ChatRow, ui: ClaudeChatUi, actions: ClaudeChatActions, copy: (String) -> Unit, expanded: Set<String>, toggle: (String) -> Unit,
    view: (List<ViewerImage>, Int) -> Unit) {
    val m = muse
    when (r) {
        is ChatRow.Time -> T(r.text, m.scale.caption.copy(fontFeatureSettings = "tnum"), m.roles.ink2, Modifier.fillMaxWidth(), align = TextAlign.Center, maxLines = 1)
        is ChatRow.Item -> when (val it = r.item) {
            is ChatItem.User -> UserBubble(it, copy, view)
            is ChatItem.Assistant -> AssistantText(it, r.first, copy)
            is ChatItem.Tool -> ToolRow(it, r.first, it.key in expanded) { toggle(it.key) }
            is ChatItem.Image -> FrameView(it, r.first, view)
        }
        is ChatRow.Thinking -> Thinking(r.text)
        is ChatRow.Ended -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
            if (r.failed) Ic("warning", 16.dp, m.roles.danger)
            T(r.text, m.scale.caption, if (r.failed) m.roles.danger else m.roles.ink2, Modifier.weight(1f, fill = false))
            if (r.failed && !ui.busy && ui.thread != null) TextAction("Try again", actions.retryTurn)
        }
        ChatRow.Offline -> Fallback.decide(ui.status, ui.refusal, ui.contextKind)?.let { OfflineCard(it, ui, actions) }
        is ChatRow.Notice -> Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).press(onClick = actions.dismissNotice).semantics(mergeDescendants = true) {
            role = Role.Button; contentDescription = "${r.text}. Dismiss" }, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
            Ic("warning", 16.dp, m.roles.danger)
            T(r.text, m.scale.caption, m.roles.danger, Modifier.weight(1f))
            Ic("x", 16.dp, m.roles.ink2)
        }
    }
}

/** No messages yet: what this chat does, in one line. The composer is the one action. */
@Composable
private fun EmptyState(contextKind: String, modifier: Modifier) {
    val m = muse
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
        T("Chat with Claude", m.scale.heading, m.roles.ink)
        T(ClaudeText.empty(contextKind), m.scale.body, m.roles.ink2)
    }
}

/** Opening the chat: a few lines shaped like the transcript. */
@Composable
private fun ChatSkeleton(modifier: Modifier = Modifier) {
    val m = muse
    Column(modifier.fillMaxWidth().semantics { contentDescription = "Opening the chat" }, verticalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
        Box(Modifier.align(Alignment.End).width(180.dp).height(40.dp).clip(bubbleShape(true)).background(m.roles.field))
        repeat(3) { i -> Box(Modifier.fillMaxWidth(if (i == 2) .5f else .9f).height(14.dp).clip(RoundedCornerShape(4.dp)).background(m.roles.field)) }
    }
}

@Composable
private fun ChatHeader(ui: ClaudeChatUi, title: String, horizontal: Dp, compact: Boolean = false) {
    val m = muse
    // No plan status yet (opening, or the thread couldn't load): don't claim "answered by your Mac" with a green dot.
    val s = if (ui.status == null && (!ui.loaded || ui.error != null)) StatusLineText(if (ui.loaded) "Not connected" else "Connecting…", Tone.OFF) else ClaudeText.status(ui)
    Column(Modifier.fillMaxWidth().padding(horizontal = horizontal, vertical = if (compact) MuseSpace.s1 else MuseSpace.s3).semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
        verticalArrangement = Arrangement.spacedBy(2.dp)) {
        if (title.isNotBlank() && !compact) T(title, m.scale.title, m.roles.ink, Modifier.semantics { heading() }, maxLines = 1)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2), modifier = Modifier.heightIn(min = 24.dp)) {
            Box(Modifier.size(8.dp).clip(CircleShape).background(toneColor(s.tone)))
            T(s.text, m.scale.caption, if (s.tone == Tone.OFF) m.roles.ink else m.roles.ink2, maxLines = 2)
        }
    }
}

@Composable
private fun toneColor(t: Tone): Color = muse.roles.let { r -> when (t) { Tone.GOOD -> r.positive; Tone.WAIT -> r.caution; Tone.OFF -> r.ink2 } }

/** The user's bubble side: on the right, the bubble's top-right corner tighter (the Claude app's shape). */
@Composable
private fun bubbleShape(mine: Boolean): RoundedCornerShape {
    val r = (muse.radii.container).coerceAtLeast(12.dp)
    val tight = (r / 3).coerceAtLeast(4.dp)
    return if (mine) RoundedCornerShape(r, tight, r, r) else RoundedCornerShape(tight, r, r, r)
}

/** Long-press copies; TalkBack gets the same as a named action. */
private fun Modifier.copyable(text: String, copy: (String) -> Unit, label: String): Modifier =
    this.pointerInput(text) { detectTapGestures(onLongPress = { copy(text) }) }
        .semantics { customActions = listOf(CustomAccessibilityAction("Copy $label") { copy(text); true }) }

@Composable
private fun UserBubble(u: ChatItem.User, copy: (String) -> Unit, view: (List<ViewerImage>, Int) -> Unit) {
    val m = muse
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val maxW = (maxWidth * .82f).coerceAtMost(520.dp)
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(MuseSpace.s1)) {
            if (u.images.isNotEmpty()) Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                val all = u.images.mapIndexed { i, url -> ViewerImage(ImageRef(url = url), "Image ${i + 1}") }
                u.images.forEachIndexed { i, url ->
                    RefImage(ImageRef(url = url), Modifier.size(if (u.images.size == 1) 160.dp else 76.dp).clip(RoundedCornerShape(m.radii.control))
                        .press { view(all, i) }.semantics { contentDescription = "Your image ${i + 1}. Open"; role = Role.Image })
                }
            }
            if (u.text.isNotBlank()) Box(Modifier.widthIn(max = maxW).clip(bubbleShape(true)).background(m.roles.field)
                .copyable(u.text, copy, "message").semantics(mergeDescendants = true) { contentDescription = "You: ${u.text}" }
                .padding(horizontal = 14.dp, vertical = 10.dp)) {
                T(u.text, m.scale.body, m.roles.ink)
            }
        }
    }
}

@Composable
private fun AssistantText(a: ChatItem.Assistant, label: Boolean, copy: (String) -> Unit) {
    val m = muse
    Column(Modifier.fillMaxWidth().copyable(a.text, copy, "reply"), verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
        ChatMarkdownText(a.text, a.streaming, Modifier.fillMaxWidth())
    }
}


/** Waiting for the first words: a pulsing dot (progress) and what's happening. */
@Composable
private fun Thinking(text: String) {
    val m = muse
    val pulse = rememberInfiniteTransition(label = "thinking")
    val a by pulse.animateFloat(.35f, 1f, infiniteRepeatable(tween(700), RepeatMode.Reverse), label = "dot")
    Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
        Row(Modifier.semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite }, verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
            Box(Modifier.size(8.dp).graphicsLayer { alpha = a }.clip(CircleShape).background(m.roles.ink2))
            T(text, m.scale.caption, m.roles.ink2, maxLines = 1)
        }
    }
}

/**
 * A tool step as one compact row: a pulsing dot while it runs, a check when done, a warning when it failed, and its words
 * ("Saved camera path"). A tap shows the short line under it; raw input and output are never shown.
 */
@Composable
private fun ToolRow(t: ChatItem.Tool, label: Boolean, open: Boolean, onToggle: () -> Unit) {
    val m = muse
    val r = m.roles
    val col = if (!t.ok) r.danger else if (t.running) r.ink else r.ink2
    Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s1)) {
        Row(Modifier.heightIn(min = 32.dp).clip(RoundedCornerShape(m.radii.chip)).background(r.field).press(onClick = onToggle).padding(horizontal = 10.dp, vertical = 6.dp)
            .semantics(mergeDescendants = true) {
                role = Role.Button
                contentDescription = (if (t.running) "In progress: " else if (!t.ok) "Failed: " else "Done: ") + t.text + if (open) ". Hide details" else ". Show details"
            },
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            when {
                t.running -> {
                    val pulse = rememberInfiniteTransition(label = "tool")
                    val a by pulse.animateFloat(.35f, 1f, infiniteRepeatable(tween(700), RepeatMode.Reverse), label = "dot")
                    Box(Modifier.size(16.dp), contentAlignment = Alignment.Center) { Box(Modifier.size(7.dp).graphicsLayer { alpha = a }.clip(CircleShape).background(r.caution)) }
                }
                !t.ok -> Ic("warning", 16.dp, col)
                else -> Ic("check", 16.dp, col)
            }
            T(t.text, m.scale.caption, col, Modifier.weight(1f, fill = false), maxLines = 1)
            Ic(if (open) "caret-up" else "caret-down", 14.dp, r.ink2)
        }
        androidx.compose.animation.AnimatedVisibility(open, enter = fadeIn(tween(120)) + expandVertically(tween(200)), exit = fadeOut(tween(120)) + shrinkVertically(tween(200))) {
            T(t.detail, m.scale.caption, r.ink2, Modifier.padding(start = MuseSpace.s3, top = 2.dp))
        }
    }
}

@Composable
private fun FrameView(f: ChatItem.Image, label: Boolean, view: (List<ViewerImage>, Int) -> Unit) {
    val m = muse
    val bmp = remember(f.data) {
        f.data?.let { d -> runCatching { Base64.decode(d, Base64.DEFAULT).let { b -> BitmapFactory.decodeByteArray(b, 0, b.size)?.asImageBitmap() } }.getOrNull() }
    }
    Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s1)) {
        Box(Modifier.width(200.dp).height(113.dp).clip(RoundedCornerShape(m.radii.control)).background(m.roles.field)
            .press(enabled = f.url != null) { f.url?.let { view(listOf(ViewerImage(ImageRef(url = it), "Frame Claude looked at")), 0) } }
            .semantics { contentDescription = "Frame Claude looked at"; role = Role.Image }, contentAlignment = Alignment.Center) {
            when {
                bmp != null -> Image(bmp, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                f.url != null -> AsyncImage(f.url, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            }
        }
        Caption("Frame Claude looked at")
    }
}

/** Claude on the Mac is offline: what to do, Open in Claude (+ the connector line), and the studio API key when it's on. No box. */
@Composable
private fun OfflineCard(f: FallbackChoice, ui: ClaudeChatUi, actions: ClaudeChatActions) {
    val m = muse
    val mac = ui.status?.mac
    val why = when {
        mac == null || !mac.online || ui.refusal != null && mac.ready -> "Open MUSE on your Mac to answer here on your Claude plan, or carry on in the Claude app."
        !mac.claudeCode.installed -> "Install Claude Code from MUSE on your Mac (Settings, Claude), or carry on in the Claude app."
        else -> "Sign in to Claude Code from MUSE on your Mac, or carry on in the Claude app."
    }
    Column(Modifier.fillMaxWidth().padding(top = MuseSpace.s2), verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
            Ic("wifi-slash", 20.dp, m.roles.ink)
            T(if (mac != null && mac.online && !mac.ready) ClaudeText.status(ui.copy(refusal = null)).text else ClaudeText.OFFLINE, m.scale.heading, m.roles.ink,
                Modifier.semantics { heading() })
        }
        T(if (f.useApiKey) "$why You can also answer with the studio API key." else why, m.scale.body, m.roles.ink2)
        Spacer(Modifier.height(MuseSpace.s1))
        if (f.useApiKey) PrimaryButton("Use the studio API key", { actions.useApiKey() }, Modifier.fillMaxWidth())
        f.openInClaude?.let { url ->
            if (f.useApiKey) SecondaryButton("Open in Claude", { actions.openInClaude(url) }, Modifier.fillMaxWidth())
            else PrimaryButton("Open in Claude", { actions.openInClaude(url) }, Modifier.fillMaxWidth())
        }
        T(ClaudeText.CONNECTOR_NOTE, m.scale.caption, m.roles.ink2)
        TextAction("Add MUSE in Connections", actions.openConnections)
        if (f.useApiKey) Caption("The studio API key is billed per use.")
        f.note?.let { Caption(it) }
    }
}

/**
 * The composer: attach, a field that grows to 6 lines and then scrolls, and Send (Stop while Claude answers). Enter adds a
 * line; the Send button sends.
 */
@Composable
private fun ChatComposer(ui: ClaudeChatUi, actions: ClaudeChatActions, horizontal: Dp, compact: Boolean = false) {
    val m = muse
    Column(Modifier.fillMaxWidth().background(m.roles.canvas).padding(horizontal = horizontal).padding(top = if (compact) MuseSpace.s1 else MuseSpace.s2, bottom = if (compact) MuseSpace.s1 else MuseSpace.s3).navigationBarsPadding(),
        verticalArrangement = Arrangement.spacedBy(6.dp)) {
        val shape = RoundedCornerShape((m.radii.container).coerceIn(8.dp, 22.dp))
        Column(Modifier.fillMaxWidth().clip(shape).background(m.roles.raised).border(1.dp, m.roles.hairline, shape)) {
            if (ui.attachments.isNotEmpty()) Row(Modifier.padding(start = MuseSpace.s3, end = MuseSpace.s3, top = MuseSpace.s3), horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
                ui.attachments.forEach { a -> PickedImage(a, { actions.removeAttachment(a.key) }, { actions.sendAsJpeg(a.key) }) }
            }
            val attach: @Composable () -> Unit = {
                actions.attach?.let { pick ->
                    val full = ui.attachments.size >= ClaudeChatStore.MAX_IMAGES
                    Box(Modifier.size(48.dp).clip(CircleShape).press(!full, pick).semantics { contentDescription = if (full) "Attach images, ${ClaudeChatStore.MAX_IMAGES} attached already" else "Attach images"; role = Role.Button },
                        contentAlignment = Alignment.Center) {
                        Ic("paperclip", 20.dp, if (full) m.roles.ink2 else m.roles.ink)
                    }
                }
            }
            // While the offline block offers its own primary action, Send steps back to a tonal button (one `action` fill per screen).
            val quiet = Fallback.decide(ui.status, ui.refusal, ui.contextKind) != null
            val send: @Composable () -> Unit = { if (ui.busy) StopButton(ui.turn?.stopping == true, actions.stop) else SendButton(ui.canSend, actions.send, quiet) }
            if (compact) Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.Bottom) {
                attach()
                ChatField(ui.draft, actions.edit, ClaudeText.placeholder(ui.contextKind), Modifier.weight(1f), maxLines = 3)
                send()
            } else {
                ChatField(ui.draft, actions.edit, ClaudeText.placeholder(ui.contextKind), Modifier.fillMaxWidth())
                Row(Modifier.fillMaxWidth().padding(start = 4.dp, end = 6.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    attach()
                    Spacer(Modifier.weight(1f))
                    send()
                }
            }
        }
        // The header carries the mode line; here only the billed-per-use reminder while the studio key answers.
        if (ui.turn?.api == true && ui.busy) Caption(ClaudeText.API, maxLines = 1)
    }
}

/** A picked image: its thumbnail, dimmed while it uploads, with a 48 dp remove target. */
@Composable
private fun PickedImage(a: ChatAttachment, onRemove: () -> Unit, onSendAsJpeg: () -> Unit) {
    val m = muse
    val desc = when { a.error != null -> "Image: ${ChatClean.error(a.error, "couldn't upload")}"; a.uploadId == null -> "Image, uploading"; else -> "Image" }
    Column(verticalArrangement = Arrangement.spacedBy(2.dp), horizontalAlignment = Alignment.CenterHorizontally) {
    Box(Modifier.size(64.dp).semantics(mergeDescendants = true) { contentDescription = desc }) {
        RefImage(ImageRef(url = a.preview),
            Modifier.align(Alignment.BottomStart).size(56.dp).clip(RoundedCornerShape(m.radii.control)).border(1.dp, if (a.error != null) m.roles.danger else m.roles.hairline, RoundedCornerShape(m.radii.control)),
            colorFilter = if (a.uploadId == null && a.error == null) androidx.compose.ui.graphics.ColorFilter.tint(Color.White.copy(alpha = .4f), androidx.compose.ui.graphics.BlendMode.SrcOver) else null)
        Box(Modifier.align(Alignment.TopEnd).size(28.dp).press(onClick = onRemove).semantics { contentDescription = "Remove image"; role = Role.Button }, contentAlignment = Alignment.Center) {
            Box(Modifier.size(22.dp).clip(CircleShape).background(m.roles.ink), contentAlignment = Alignment.Center) { Ic("x", 12.dp, m.roles.canvas) }
        }
    }
    // The server couldn't read this format: convert it here and send it again.
    if (a.unsupported) Box(Modifier.heightIn(min = 48.dp).press(onClick = onSendAsJpeg).semantics { role = Role.Button; contentDescription = "Send as JPEG" },
        contentAlignment = Alignment.Center) { T("Send as JPEG", m.scale.caption, m.roles.link, maxLines = 1) }
    }
}

/** The composer's field: multi-line, 1 to 6 lines tall, then it scrolls inside. Enter adds a line. */
@Composable
private fun ChatField(value: String, onChange: (String) -> Unit, placeholder: String, modifier: Modifier, maxLines: Int = 6) {
    val m = muse
    androidx.compose.foundation.text.BasicTextField(
        value, onChange, modifier.heightIn(min = 48.dp).semantics { contentDescription = "Message" },
        textStyle = m.scale.body.copy(color = m.roles.ink), singleLine = false, minLines = 1, maxLines = maxLines,
        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Default),
        cursorBrush = androidx.compose.ui.graphics.SolidColor(m.roles.accent),
        decorationBox = { inner ->
            Box(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp), contentAlignment = Alignment.CenterStart) {
                if (value.isEmpty()) T(placeholder, m.scale.body, m.roles.ink2, maxLines = 1)
                inner()
            }
        },
    )
}

/** Send: the one action in the chat, an arrow in the `action` fill. Quiet while there's nothing to send. */
@Composable
private fun SendButton(enabled: Boolean, onClick: () -> Unit, quiet: Boolean = false) {
    val m = muse
    val filled = enabled && !quiet
    Box(Modifier.size(48.dp).press(enabled, onClick).semantics { contentDescription = "Send"; role = Role.Button }, contentAlignment = Alignment.Center) {
        Box(Modifier.size(36.dp).clip(CircleShape).background(if (filled) m.roles.action else m.roles.field)
            .let { if (m.isD && filled) it.border(2.dp, m.roles.ink, CircleShape) else it }, contentAlignment = Alignment.Center) {
            Ic("arrow-up", 18.dp, if (filled) m.roles.onAction else if (enabled) m.roles.ink else m.roles.ink2)
        }
    }
}

/** Stop while Claude answers: the same place as Send, a square in ink. */
@Composable
private fun StopButton(stopping: Boolean, onClick: () -> Unit) {
    val m = muse
    Box(Modifier.size(48.dp).press(!stopping, onClick).semantics { contentDescription = if (stopping) "Stopping" else "Stop"; role = Role.Button }, contentAlignment = Alignment.Center) {
        Box(Modifier.size(36.dp).clip(CircleShape).background(if (stopping) m.roles.field else m.roles.ink), contentAlignment = Alignment.Center) {
            Box(Modifier.size(12.dp).clip(RoundedCornerShape(2.dp)).background(if (stopping) m.roles.ink2 else m.roles.canvas))
        }
    }
}

// ---------------------------------------------------------------- the phone's sheet

/** The "Claude" button that opens [ClaudeChatSheet] (48 dp tall). */
@Composable
fun ClaudeButton(onClick: () -> Unit, modifier: Modifier = Modifier) =
    SecondaryButton("Claude", onClick, modifier, label = "Claude", height = 48.dp)

/** The chat as a sheet over the screen (88% of the height), with a scrim; Back and the scrim close it. */
@Composable
fun ClaudeChatSheet(open: Boolean, onDismiss: () -> Unit, contextKind: String, contextId: String, title: String = "Claude", modifier: Modifier = Modifier,
    /** The sheet's share of the screen (the Suite keeps its composer in view above a shorter sheet). */
    heightFraction: Float = .88f,
    /** Shown above the chat (the Suite's "Claude wants to generate" approval). */
    above: (@Composable () -> Unit)? = null,
    /** WS18: the Suite's own sessions (each chat bound to a shared draft) and its tool-step hook. */
    hooks: ClaudeChatStore.SessionHooks? = null,
    onToolDone: ((String) -> Unit)? = null) {
    if (!open) return
    val store = rememberClaudeChatStore(contextKind, contextId)
    store.hooks = hooks
    store.onToolDone = onToolDone
    ClaudeSheetFrame(onDismiss, modifier, heightFraction) {
        Column(Modifier.fillMaxSize()) {
            above?.invoke()
            ClaudeChat(store, title, Modifier.weight(1f).fillMaxWidth())
        }
    }
}

/** The sheet's frame (scrim, handle, the container radius on top, the float shadow); [content] fills it. */
@Composable
fun ClaudeSheetFrame(onDismiss: () -> Unit, modifier: Modifier = Modifier, heightFraction: Float = .88f, content: @Composable () -> Unit) {
    val m = muse
    BackHandler(onBack = onDismiss)
    // The keyboard: the sheet sits on top of it and grows to most of what's left, so the composer and the latest message stay in view.
    val keyboard = WindowInsets.ime.getBottom(LocalDensity.current) > 0
    Box(modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = .38f)).press(onClick = onDismiss).semantics { contentDescription = "Close Claude" })
        BoxWithConstraints(Modifier.fillMaxSize().imePadding()) {
        val shape = RoundedCornerShape(topStart = m.radii.container, topEnd = m.radii.container)
        Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(maxHeight * (if (keyboard) maxOf(heightFraction, .92f) else heightFraction))
            .museFloat(m, shape).clip(shape).background(m.roles.canvas)) {
            Box(Modifier.fillMaxWidth().height(20.dp), contentAlignment = Alignment.Center) {
                Box(Modifier.width(40.dp).height(4.dp).clip(CircleShape).background(m.roles.hairline))
            }
            Box(Modifier.weight(1f).fillMaxWidth()) { content() }
        }
        }
    }
}

/** Tablet: the chat as a right panel of [width] with a hairline on its left. */
@Composable
fun ClaudeChatPanel(contextKind: String, contextId: String, title: String = "Claude", width: Dp = 380.dp, modifier: Modifier = Modifier) {
    val m = muse
    ClaudeChat(contextKind, contextId, title, modifier.width(width).fillMaxHeight().drawBehind { drawLine(m.roles.hairline, Offset(0f, 0f), Offset(0f, size.height), 1f) })
}

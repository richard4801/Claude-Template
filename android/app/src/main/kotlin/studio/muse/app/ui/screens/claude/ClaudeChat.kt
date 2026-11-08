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
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import coil3.compose.AsyncImage
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.components.Lbl
import studio.muse.app.ui.components.T
import studio.muse.app.data.ApiException
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.camera.ConnectionsScreen
import studio.muse.app.ui.screens.Caption
import studio.muse.app.ui.screens.PrimaryButton
import studio.muse.app.ui.screens.SecondaryButton
import studio.muse.app.ui.screens.TextAction
import studio.muse.app.ui.screens.containerShape
import studio.muse.app.ui.screens.controlShape
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
    /** Attach images (the photo picker); null hides the button. */
    val attach: (() -> Unit)? = null,
    val removeAttachment: (String) -> Unit = {},
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
        uris.take(room).forEach { uri ->
            store.attach(uri.toString()) {
                val media = c.media ?: throw ApiException("unsupported", "Images can't be read on this device")
                val bytes = media.bytes(uri) ?: throw ApiException("bad_request", "Couldn't read that image")
                if (bytes.size > 10 * 1024 * 1024) throw ApiException("bad_request", "Images can be up to 10 MB")
                c.repo.api.uploadClaudeImage(media.displayName(uri), bytes, media.mime(uri))
            }
        }
    }
    ClaudeChatContent(ui, title, ClaudeChatActions(
        attach = if (ui.canAttach) ({ picker.launch(androidx.activity.result.PickVisualMediaRequest(androidx.activity.result.contract.ActivityResultContracts.PickVisualMedia.ImageOnly)) }) else null,
        removeAttachment = store::removeAttachment,
        edit = store::edit, send = { store.send() }, stop = store::stop,
        openInClaude = { url ->
            runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
                .onFailure { c.repo.toast("Couldn't open Claude · install the Claude app or open claude.ai") }
        },
        useApiKey = { store.useApiKey() },
        openConnections = onOpenConnections ?: { connections = true },
        dismissNotice = store::dismissNotice,
        retry = { store.load() },
    ), modifier)
}

/** The chat, stateless: header with the mode line, the transcript, the Mac-offline block and the composer (Send / Stop). */
@Composable
fun ClaudeChatContent(ui: ClaudeChatUi, title: String, actions: ClaudeChatActions, modifier: Modifier = Modifier, horizontal: Dp = 16.dp) {
    val m = muse
    val items = ui.items
    val scroll = rememberScrollState()
    val lastLen = (items.lastOrNull() as? ChatItem.Assistant)?.text?.length ?: 0
    LaunchedEffect(items.size, lastLen) { scroll.animateScrollTo(scroll.maxValue) }
    Column(modifier.background(m.roles.canvas).imePadding()) {
        ChatHeader(ui, title, horizontal)
        Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(scroll).padding(horizontal = horizontal, vertical = MuseSpace.s3), verticalArrangement = Arrangement.spacedBy(MuseSpace.s4)) {
            if (!ui.loaded) ChatSkeleton()
            else if (ui.error != null && ui.thread == null) Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
                T("Can't open the chat", m.scale.heading, m.roles.ink)
                T(ui.error, m.scale.body, m.roles.ink2)
                SecondaryButton("Try again", { actions.retry() }, icon = "retry")
            }
            else if (items.isEmpty()) T(ClaudeText.empty(ui.contextKind), m.scale.body, m.roles.ink2)
            Transcript(items)
            ClaudeText.ended(ui.turn)?.let { T(it, m.scale.caption, if (ui.turn?.state == "stopped") m.roles.ink2 else m.roles.danger) }
            Fallback.decide(ui.status, ui.refusal, ui.contextKind)?.takeIf { ui.turn?.active != true }?.let { OfflineCard(it, ui, actions) }
            ui.notice?.let { n ->
                Box(Modifier.heightIn(min = 48.dp).press(onClick = actions.dismissNotice).semantics { role = Role.Button; contentDescription = "$n. Dismiss" }, contentAlignment = Alignment.CenterStart) {
                    T(n, m.scale.caption, m.roles.danger)
                }
            }
        }
        ChatComposer(ui, actions, horizontal)
    }
}

/** Opening the chat: a few lines shaped like the transcript. */
@Composable
private fun ChatSkeleton() {
    val m = muse
    Column(Modifier.semantics { contentDescription = "Opening the chat" }, verticalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
        Box(Modifier.align(Alignment.End).width(180.dp).height(40.dp).clip(controlShape()).background(m.roles.field))
        repeat(3) { i -> Box(Modifier.fillMaxWidth(if (i == 2) .5f else .9f).height(14.dp).clip(RoundedCornerShape(4.dp)).background(m.roles.field)) }
    }
}

@Composable
private fun ChatHeader(ui: ClaudeChatUi, title: String, horizontal: Dp) {
    val m = muse
    // No plan status yet (opening, or the thread couldn't load): don't claim "answered by your Mac" with a green dot.
    val s = if (ui.status == null && (!ui.loaded || ui.error != null)) StatusLineText(if (ui.loaded) "Not connected" else "Connecting…", Tone.OFF) else ClaudeText.status(ui)
    Column(Modifier.fillMaxWidth().padding(horizontal = horizontal, vertical = MuseSpace.s3), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        if (title.isNotBlank()) T(title, m.scale.title, m.roles.ink, maxLines = 1)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2), modifier = Modifier.height(24.dp)) {
            Box(Modifier.size(8.dp).clip(CircleShape).background(toneColor(s.tone)))
            T(s.text, m.scale.caption, if (s.tone == Tone.OFF) m.roles.ink else m.roles.ink2, maxLines = 1)
        }
    }
}

@Composable
private fun toneColor(t: Tone): Color = muse.roles.let { r -> when (t) { Tone.GOOD -> r.positive; Tone.WAIT -> r.caution; Tone.OFF -> r.ink2 } }

@Composable
private fun Transcript(items: List<ChatItem>) {
    var i = 0
    var prev: ChatItem? = null
    while (i < items.size) {
        val it = items[i]
        when (it) {
            is ChatItem.User -> UserBubble(it)
            is ChatItem.Assistant -> AssistantText(it, label = prev !is ChatItem.Assistant && prev !is ChatItem.Tool && prev !is ChatItem.Image)
            is ChatItem.Image -> FrameView(it)
            is ChatItem.Tool -> {
                // Consecutive tool steps share one row of chips.
                val run = items.drop(i).takeWhile { x -> x is ChatItem.Tool }.filterIsInstance<ChatItem.Tool>()
                Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s1)) {
                    if (prev is ChatItem.User || prev == null) Caption("Claude")
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) { run.forEach { t -> ToolChipWords(t) } }
                }
                i += run.size - 1
            }
        }
        prev = items[i]
        i++
    }
}

@Composable
private fun UserBubble(u: ChatItem.User) {
    val m = muse
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(MuseSpace.s1)) {
        Caption(ClaudeText.youLabel(u.source))
        if (u.images.isNotEmpty()) Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            u.images.forEachIndexed { i, url ->
                studio.muse.app.ui.components.RefImage(studio.muse.app.data.ImageRef(url = url), Modifier.size(72.dp).clip(controlShape()).semantics { contentDescription = "Image ${i + 1}" })
            }
        }
        if (u.text.isNotBlank()) Box(Modifier.widthIn(max = 300.dp).clip(controlShape()).background(m.roles.field).padding(horizontal = MuseSpace.s3, vertical = 10.dp)) {
            T(u.text, m.scale.body, m.roles.ink)
        }
    }
}

@Composable
private fun AssistantText(a: ChatItem.Assistant, label: Boolean) {
    val m = muse
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(MuseSpace.s1)) {
        if (label) Caption("Claude")
        T(if (a.streaming) a.text + " ▍" else a.text, m.scale.body, m.roles.ink)
    }
}

/** A tool step in words ("Saved camera path", "Shot draft · $1.92"): a dot while it runs, a check when done, danger text when it failed. */
@Composable
private fun ToolChipWords(t: ChatItem.Tool) {
    val m = muse
    val r = m.roles
    val col = if (!t.ok) r.danger else if (t.running) r.ink else r.ink2
    Row(Modifier.height(28.dp).clip(RoundedCornerShape(m.radii.chip)).background(r.field).padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        if (t.running) Box(Modifier.size(7.dp).clip(CircleShape).background(r.caution)) else if (t.ok) Ic("check", 16.dp, col)
        T(t.text, m.scale.caption, col, maxLines = 1)
    }
}

@Composable
private fun FrameView(f: ChatItem.Image) {
    val m = muse
    val bmp = remember(f.data) {
        f.data?.let { d -> runCatching { Base64.decode(d, Base64.DEFAULT).let { b -> BitmapFactory.decodeByteArray(b, 0, b.size)?.asImageBitmap() } }.getOrNull() }
    }
    Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s1)) {
        Box(Modifier.width(180.dp).height(102.dp).clip(containerShape()).background(m.roles.field), contentAlignment = Alignment.Center) {
            when {
                bmp != null -> Image(bmp, "Frame Claude grabbed", Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                f.url != null -> AsyncImage(f.url, "Frame Claude grabbed", Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            }
        }
        Caption("Frame Claude checked")
    }
}

/** "Your Mac is offline": what to do, Open in Claude (+ the connector line), and the studio API key when it is on. No box. */
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
        T(if (mac != null && mac.online && !mac.ready) ClaudeText.status(ui.copy(refusal = null)).text else ClaudeText.OFFLINE, m.scale.heading, m.roles.ink)
        T(why, m.scale.body, m.roles.ink2)
        Spacer(Modifier.height(MuseSpace.s1))
        f.openInClaude?.let { url -> PrimaryButton("Open in Claude", { actions.openInClaude(url) }, Modifier.fillMaxWidth()) }
        if (f.useApiKey) SecondaryButton("Use the studio API key", { actions.useApiKey() }, Modifier.fillMaxWidth())
        T(ClaudeText.CONNECTOR_NOTE, m.scale.caption, m.roles.ink2)
        TextAction("Add MUSE in Connections", actions.openConnections)
        if (f.useApiKey) Caption("The studio API key is billed per use.")
        f.note?.let { Caption(it) }
    }
}

@Composable
private fun ChatComposer(ui: ClaudeChatUi, actions: ClaudeChatActions, horizontal: Dp) {
    val m = muse
    Column(Modifier.fillMaxWidth().background(m.roles.canvas).padding(horizontal = horizontal, vertical = MuseSpace.s2).navigationBarsPadding(),
        verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (ui.attachments.isNotEmpty()) Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
            ui.attachments.forEach { a -> PickedImage(a, { actions.removeAttachment(a.key) }) }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
            actions.attach?.let { pick ->
                val full = ui.attachments.size >= ClaudeChatStore.MAX_IMAGES
                Box(Modifier.size(48.dp).clip(controlShape()).press(!full, pick).semantics { contentDescription = "Attach images"; role = Role.Button }, contentAlignment = Alignment.Center) {
                    Ic("image", 22.dp, if (full) m.roles.ink2 else m.roles.ink)
                }
            }
            ChatField(ui.draft, actions.edit, ClaudeText.placeholder(ui.contextKind), Modifier.weight(1f))
            if (ui.busy) SecondaryButton("Stop", actions.stop, label = "Stop", height = 48.dp)
            else SendButton(ui.canSend, actions.send)
        }
        // The header carries the mode line; here only the billed-per-use reminder while the studio key answers.
        if (ui.turn?.api == true && ui.busy) Caption(ClaudeText.API, maxLines = 1)
    }
}

/** A picked image: its thumbnail, dimmed while it uploads, with a 48 dp remove target. */
@Composable
private fun PickedImage(a: ChatAttachment, onRemove: () -> Unit) {
    val m = muse
    val desc = when { a.error != null -> "Image: ${a.error}"; a.uploadId == null -> "Image, uploading"; else -> "Image" }
    Box(Modifier.size(56.dp).semantics(mergeDescendants = true) { contentDescription = desc }) {
        studio.muse.app.ui.components.RefImage(studio.muse.app.data.ImageRef(url = a.preview),
            Modifier.size(56.dp).clip(controlShape()).border(1.dp, if (a.error != null) m.roles.danger else m.roles.hairline, controlShape()),
            colorFilter = if (a.uploadId == null && a.error == null) androidx.compose.ui.graphics.ColorFilter.tint(Color.White.copy(alpha = .4f), androidx.compose.ui.graphics.BlendMode.SrcOver) else null)
        Box(Modifier.align(Alignment.TopEnd).size(24.dp).clip(CircleShape).background(m.roles.canvas).border(1.dp, m.roles.hairline, CircleShape)
            .press(onClick = onRemove).semantics { contentDescription = "Remove image"; role = Role.Button }, contentAlignment = Alignment.Center) {
            Ic("x", 14.dp, m.roles.ink)
        }
    }
}

/** The composer's field: `raised`, a hairline edge, the control radius. */
@Composable
private fun ChatField(value: String, onChange: (String) -> Unit, placeholder: String, modifier: Modifier) {
    val m = muse
    val shape = controlShape()
    androidx.compose.foundation.text.BasicTextField(
        value, onChange, modifier.height(48.dp).clip(shape).background(m.roles.raised).border(1.dp, m.roles.hairline, shape),
        textStyle = m.scale.body.copy(color = m.roles.ink), singleLine = true,
        cursorBrush = androidx.compose.ui.graphics.SolidColor(m.roles.accent),
        decorationBox = { inner ->
            Box(Modifier.fillMaxSize().padding(horizontal = MuseSpace.s3), contentAlignment = Alignment.CenterStart) {
                if (value.isEmpty()) T(placeholder, m.scale.body, m.roles.ink2, maxLines = 1)
                inner()
            }
        },
    )
}

/** Send: the one action in the chat, an arrow in the `action` fill. Quiet while there's nothing to send. */
@Composable
private fun SendButton(enabled: Boolean, onClick: () -> Unit) {
    val m = muse
    val shape = controlShape()
    Box(Modifier.size(48.dp).clip(shape).background(if (enabled) m.roles.action else m.roles.field).let { if (m.isD && enabled) it.border(2.dp, m.roles.ink, shape) else it }
        .press(enabled, onClick).semantics { contentDescription = "Send"; role = Role.Button }, contentAlignment = Alignment.Center) {
        Ic("upload", 20.dp, if (enabled) m.roles.onAction else m.roles.ink2)
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
    above: (@Composable () -> Unit)? = null) {
    if (!open) return
    val store = rememberClaudeChatStore(contextKind, contextId)
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
    BoxWithConstraints(modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = .38f)).press(onClick = onDismiss).semantics { contentDescription = "Close Claude" })
        val shape = RoundedCornerShape(topStart = m.radii.container, topEnd = m.radii.container)
        Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(maxHeight * heightFraction).museFloat(m, shape).clip(shape).background(m.roles.canvas)) {
            Box(Modifier.fillMaxWidth().height(20.dp), contentAlignment = Alignment.Center) {
                Box(Modifier.width(40.dp).height(4.dp).clip(CircleShape).background(m.roles.hairline))
            }
            Box(Modifier.weight(1f).fillMaxWidth()) { content() }
        }
    }
}

/** Tablet: the chat as a right panel of [width] with a hairline on its left. */
@Composable
fun ClaudeChatPanel(contextKind: String, contextId: String, title: String = "Claude", width: Dp = 380.dp, modifier: Modifier = Modifier) {
    val m = muse
    ClaudeChat(contextKind, contextId, title, modifier.width(width).fillMaxHeight().drawBehind { drawLine(m.roles.hairline, Offset(0f, 0f), Offset(0f, size.height), 1f) })
}

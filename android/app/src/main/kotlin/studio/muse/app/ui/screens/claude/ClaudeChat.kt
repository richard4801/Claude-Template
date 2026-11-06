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
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
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
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.camera.CamField
import studio.muse.app.ui.screens.camera.CamIc
import studio.muse.app.ui.screens.camera.ConnectionsScreen
import studio.muse.app.ui.screens.camera.SendButton
import studio.muse.app.ui.screens.camera.camBox
import studio.muse.app.ui.theme.muse

/** What the chat can do (the store's actions, or test stubs). */
class ClaudeChatActions(
    val edit: (String) -> Unit = {},
    val send: () -> Unit = {},
    val stop: () -> Unit = {},
    val openInClaude: (String) -> Unit = {},
    val useApiKey: () -> Unit = {},
    val openConnections: () -> Unit = {},
    val dismissNotice: () -> Unit = {},
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
    ClaudeChatContent(ui, title, ClaudeChatActions(
        edit = store::edit, send = { store.send() }, stop = store::stop,
        openInClaude = { url ->
            runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
                .onFailure { c.repo.toast("Couldn't open Claude · install the Claude app or open claude.ai") }
        },
        useApiKey = { store.useApiKey() },
        openConnections = onOpenConnections ?: { connections = true },
        dismissNotice = store::dismissNotice,
    ), modifier)
}

/** The chat, stateless: header with the mode line, the transcript, the Mac-offline card and the composer (Send / Stop). */
@Composable
fun ClaudeChatContent(ui: ClaudeChatUi, title: String, actions: ClaudeChatActions, modifier: Modifier = Modifier, horizontal: Dp = 16.dp) {
    val m = muse
    val items = ui.items
    val scroll = rememberScrollState()
    val lastLen = (items.lastOrNull() as? ChatItem.Assistant)?.text?.length ?: 0
    LaunchedEffect(items.size, lastLen) { scroll.animateScrollTo(scroll.maxValue) }
    Column(modifier.background(m.t.bg).imePadding()) {
        ChatHeader(ui, title, horizontal)
        Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(scroll).padding(horizontal = horizontal, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (!ui.loaded) T("Opening the chat…", m.type.tiny, m.t.muted)
            else if (ui.error != null && ui.thread == null) T(ui.error, m.type.tiny, m.t.accent)
            else if (items.isEmpty()) T(if (ui.contextKind == "edit") "Tell Claude what to change: trims, captions, the look, the music. Every change can be undone."
                else "Tell Claude what happens in the shot: who moves where, when, and how the camera moves.", m.type.tiny, m.t.muted)
            Transcript(items)
            ClaudeText.ended(ui.turn)?.let { T(it, m.type.tiny, if (ui.turn?.state == "stopped") m.t.muted else m.t.accent) }
            Fallback.decide(ui.status, ui.refusal, ui.contextKind)?.takeIf { ui.turn?.active != true }?.let { OfflineCard(it, ui, actions) }
            ui.notice?.let { n -> T(n, m.type.tiny, m.t.accent, Modifier.press(onClick = actions.dismissNotice)) }
        }
        ChatComposer(ui, actions, horizontal)
    }
}

@Composable
private fun ChatHeader(ui: ClaudeChatUi, title: String, horizontal: Dp) {
    val m = muse
    val s = ClaudeText.status(ui)
    Column(Modifier.fillMaxWidth().drawBehind { drawLine(m.t.line, Offset(0f, size.height), Offset(size.width, size.height), 1f) }
        .padding(horizontal = horizontal, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        if (title.isNotBlank()) T(title, m.type.h3, m.t.ink, maxLines = 1)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.height(24.dp)) {
            Box(Modifier.size(8.dp).clip(CircleShape).background(toneColor(s.tone)))
            T(s.text, m.type.tiny, if (s.tone == Tone.OFF) m.t.ink else m.t.muted, maxLines = 1, weight = if (s.tone == Tone.OFF) FontWeight.SemiBold else null)
        }
    }
}

@Composable
private fun toneColor(t: Tone): Color = when (t) { Tone.GOOD -> muse.t.good; Tone.WAIT -> Color(0xFFE08A1E); Tone.OFF -> muse.t.muted.copy(alpha = .6f) }

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
                if (prev is ChatItem.User || prev == null) Lbl("Claude")
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) { run.forEach { t -> ToolChipWords(t) } }
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
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Lbl(ClaudeText.youLabel(u.source))
        Box(Modifier.widthIn(max = 300.dp).clip(RoundedCornerShape(if (m.isA) 0.dp else m.t.r * .6f)).background(m.t.ink).padding(horizontal = 12.dp, vertical = 10.dp)) {
            T(u.text, m.type.body.copy(fontSize = 13.5.sp, lineHeight = 19.sp), m.t.bg)
        }
    }
}

@Composable
private fun AssistantText(a: ChatItem.Assistant, label: Boolean) {
    val m = muse
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (label) Lbl("Claude")
        T(if (a.streaming) a.text + " ▍" else a.text, m.type.body.copy(fontSize = 13.5.sp, lineHeight = 19.sp), m.t.ink)
    }
}

/** A tool step in words ("Saved camera path", "Shot draft · $1.92"); a spinner dot while it runs, red when it failed. */
@Composable
private fun ToolChipWords(t: ChatItem.Tool) {
    val m = muse
    val col = if (!t.ok) m.t.accent else if (t.running) m.t.ink else m.t.muted
    val shape = RoundedCornerShape(if (m.isA) 2.dp else 999.dp)
    Row(Modifier.height(28.dp).clip(shape).background(if (t.running) m.t.surface2 else m.t.surface).border(1.dp, if (t.ok) m.t.line else m.t.accent, shape).padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        if (t.running) Box(Modifier.size(7.dp).clip(CircleShape).background(Color(0xFFE08A1E))) else CamIc(if (t.ok) "cube" else "stop", 12.dp, col)
        T(t.text, m.type.tiny.copy(fontSize = 12.sp), col, maxLines = 1)
    }
}

@Composable
private fun FrameView(f: ChatItem.Image) {
    val m = muse
    val bmp = remember(f.data) {
        f.data?.let { d -> runCatching { Base64.decode(d, Base64.DEFAULT).let { b -> BitmapFactory.decodeByteArray(b, 0, b.size)?.asImageBitmap() } }.getOrNull() }
    }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(Modifier.width(180.dp).height(102.dp).camBox(m.t.surface2), contentAlignment = Alignment.Center) {
            CamIc("film", 20.dp, m.t.muted)
            when {
                bmp != null -> Image(bmp, "Frame Claude grabbed", Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                f.url != null -> AsyncImage(f.url, "Frame Claude grabbed", Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            }
        }
        T("Frame Claude checked", m.type.tiny.copy(fontSize = 11.5.sp), m.t.muted)
    }
}

/** "Your Mac is offline": Open in Claude (+ the connector line), and the studio API key when it is on. */
@Composable
private fun OfflineCard(f: FallbackChoice, ui: ClaudeChatUi, actions: ClaudeChatActions) {
    val m = muse
    val mac = ui.status?.mac
    val why = when {
        mac == null || !mac.online || ui.refusal != null && mac.ready -> "Open MUSE on your Mac to answer here on your Claude plan, or carry on in the Claude app."
        !mac.claudeCode.installed -> "Install Claude Code from MUSE on your Mac (Settings → Claude), or carry on in the Claude app."
        else -> "Sign in to Claude Code from MUSE on your Mac, or carry on in the Claude app."
    }
    Column(Modifier.fillMaxWidth().camBox(m.t.surface2).padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.size(8.dp).clip(CircleShape).background(m.t.muted.copy(alpha = .6f)))
            T(if (mac != null && mac.online && !mac.ready) ClaudeText.status(ui.copy(refusal = null)).text else ClaudeText.OFFLINE, m.type.body.copy(fontSize = 14.sp), m.t.ink, weight = FontWeight.Bold)
        }
        T(why, m.type.tiny, m.t.muted)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            f.openInClaude?.let { url -> ChatBtn("Open in Claude", primary = true, icon = "open") { actions.openInClaude(url) } }
            if (f.useApiKey) ChatBtn("Use the studio API key") { actions.useApiKey() }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            T(ClaudeText.CONNECTOR_NOTE + " ", m.type.tiny.copy(fontSize = 12.sp), m.t.muted, Modifier.weight(1f, fill = false))
        }
        T("Add MUSE in Connections →", m.type.tiny.copy(fontSize = 12.sp), m.link, Modifier.press(onClick = actions.openConnections), weight = FontWeight.SemiBold)
        if (f.useApiKey) T("The studio API key is billed per use.", m.type.tiny.copy(fontSize = 12.sp), m.t.muted)
        f.note?.let { T(it, m.type.tiny.copy(fontSize = 12.sp), m.t.muted) }
    }
}

@Composable
private fun ChatBtn(text: String, primary: Boolean = false, icon: String? = null, onClick: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(if (m.isA) 2.dp else 999.dp)
    Row(Modifier.height(44.dp).clip(shape).background(if (primary) m.t.cta else m.t.surface).border(1.dp, if (primary) m.t.cta else m.t.line, shape)
        .press(onClick = onClick).semantics { role = Role.Button }.padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        if (icon != null) CamIc(icon, 15.dp, if (primary) m.t.ctaInk else m.t.ink)
        T(text, m.type.body.copy(fontSize = 13.sp), if (primary) m.t.ctaInk else m.t.ink, weight = FontWeight.SemiBold, maxLines = 1)
    }
}

@Composable
private fun ChatComposer(ui: ClaudeChatUi, actions: ClaudeChatActions, horizontal: Dp) {
    val m = muse
    Column(Modifier.fillMaxWidth().background(m.t.bg).drawBehind { drawLine(m.t.line, Offset(0f, 0f), Offset(size.width, 0f), 1f) }
        .padding(horizontal = horizontal, vertical = 10.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            CamField(ui.draft, actions.edit, if (ui.contextKind == "edit") "Ask Claude to edit…" else "Direct the shot…", Modifier.weight(1f))
            if (ui.busy) StopButton(actions.stop)
            else SendButton(ui.loaded && ui.thread != null && ui.draft.isNotBlank(), actions.send)
        }
        T(if (ui.turn?.api == true && ui.busy) ClaudeText.API else ClaudeText.MODE, m.type.tiny.copy(fontSize = 11.5.sp), m.t.muted, maxLines = 1)
    }
}

@Composable
private fun StopButton(onClick: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(if (m.isA) 2.dp else 999.dp)
    Row(Modifier.height(48.dp).clip(shape).background(m.t.surface).border(1.dp, m.t.ink, shape).press(onClick = onClick)
        .semantics { contentDescription = "Stop"; role = Role.Button }.padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        CamIc("stop", 14.dp, m.t.ink)
        T("Stop", m.type.body.copy(fontSize = 13.sp), m.t.ink, weight = FontWeight.SemiBold, maxLines = 1)
    }
}

// ---------------------------------------------------------------- the phone's sheet

/** The "Claude" button that opens [ClaudeChatSheet] (48 dp tall). */
@Composable
fun ClaudeButton(onClick: () -> Unit, modifier: Modifier = Modifier) {
    val m = muse
    val shape = RoundedCornerShape(if (m.isA) 2.dp else 999.dp)
    Row(modifier.height(48.dp).clip(shape).background(m.t.surface).border(1.dp, m.t.line, shape).press(onClick = onClick)
        .semantics { contentDescription = "Claude"; role = Role.Button }.padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        CamIc("claude", 16.dp, m.t.accent)
        T("Claude", m.type.body.copy(fontSize = 14.sp), m.t.ink, weight = FontWeight.SemiBold, maxLines = 1)
    }
}

/** The chat as a sheet over the screen (88% of the height), with a scrim; Back and the scrim close it. */
@Composable
fun ClaudeChatSheet(open: Boolean, onDismiss: () -> Unit, contextKind: String, contextId: String, title: String = "Claude", modifier: Modifier = Modifier) {
    if (!open) return
    val store = rememberClaudeChatStore(contextKind, contextId)
    ClaudeSheetFrame(onDismiss, modifier) { ClaudeChat(store, title, Modifier.fillMaxSize()) }
}

/** The sheet's frame (scrim, handle, rounded top); [content] fills it. */
@Composable
fun ClaudeSheetFrame(onDismiss: () -> Unit, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    val m = muse
    BackHandler(onBack = onDismiss)
    BoxWithConstraints(modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = .38f)).press(onClick = onDismiss).semantics { contentDescription = "Close Claude" })
        val shape = RoundedCornerShape(topStart = if (m.isA) 2.dp else m.t.rLg, topEnd = if (m.isA) 2.dp else m.t.rLg)
        Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(maxHeight * .88f).clip(shape).background(m.t.bg)
            .let { if (m.isD) it.border(2.5.dp, Color(0xFF111111), shape) else it }) {
            Box(Modifier.fillMaxWidth().height(20.dp), contentAlignment = Alignment.Center) {
                Box(Modifier.width(40.dp).height(4.dp).clip(CircleShape).background(m.t.line))
            }
            Box(Modifier.weight(1f).fillMaxWidth()) { content() }
        }
    }
}

/** Tablet: the chat as a right panel of [width] with a hairline on its left. */
@Composable
fun ClaudeChatPanel(contextKind: String, contextId: String, title: String = "Claude", width: Dp = 380.dp, modifier: Modifier = Modifier) {
    val m = muse
    ClaudeChat(contextKind, contextId, title, modifier.width(width).fillMaxHeight().drawBehind { drawLine(m.t.line, Offset(0f, 0f), Offset(0f, size.height), 1f) })
}

package studio.muse.app.ui.screens.camera

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import studio.muse.app.data.CameraSession
import studio.muse.app.ui.components.Bar
import studio.muse.app.ui.components.Lbl
import studio.muse.app.ui.components.MenuItem
import studio.muse.app.ui.components.MoreMenu
import studio.muse.app.ui.components.Pill
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.TopBar
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.claude.ClaudeChat
import studio.muse.app.ui.screens.claude.ClaudeChatStore
import studio.muse.app.ui.screens.claude.rememberClaudeChatStore
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.scale

/** What the chat screens can do (the store's actions, or test stubs). */
class ChatActions(
    val send: (String) -> Boolean = { false },
    val back: () -> Unit = {},
    val openConnections: () -> Unit = {},
    val copyId: (String) -> Unit = {},
    /** "Use for Shot 01 →" (null hides the link). */
    val use: (() -> Unit)? = null,
    val useLabel: String = "Use for Shot 01",
    val dismissNotice: () -> Unit = {},
    /** The session's Claude thread (held by the screen so the pane's Re-render goes through it); null: the chat makes its own. */
    val chat: ClaudeChatStore? = null,
)

/**
 * Phone M5 · Direct with Claude: session card, status, read-only plan and guides on top (scrolls, at most 45% of the height),
 * then the Claude chat on the owner's plan (claude-editing.md part E). Blender runs on the Mac, never on the phone.
 */
@Composable
fun DirectWithClaudeContent(ui: CameraUi, now: Long, actions: ChatActions) {
    val m = muse
    val s = ui.session
    Column(Modifier.fillMaxSize().background(m.t.bg)) {
        TopBar("Direct with Claude", onBack = actions.back, right = {
            MoreMenu(listOf(
                MenuItem("check", "Copy session id") { s?.let { actions.copyId(it.id) } },
                MenuItem("lock", "Open in Settings → Connections") { actions.openConnections() },
            ))
        })
        if (s == null) {
            Box(Modifier.weight(1f).fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) {
                T(ui.error ?: "Opening the camera session…", m.type.tiny, m.t.muted, align = TextAlign.Center)
            }
            return@Column
        }
        val chat = actions.chat ?: rememberClaudeChatStore("camera", s.id)
        val chatUi by chat.ui.collectAsState()
        BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()) {
            val top = maxHeight * .45f
            Column(Modifier.fillMaxSize()) {
                Column(Modifier.fillMaxWidth().heightIn(max = top).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SessionHeader(s)
                    Column(Modifier.fillMaxWidth().camBox().padding(horizontal = 12.dp, vertical = 6.dp)) {
                        SessionText.rows(s, ui.connections, chatUi.busy, now).forEach { StatusLine(it) }
                    }
                    PlanView(s, ui.playhead, Modifier.fillMaxWidth().height(160.dp).camBox(), compact = true)
                    if (SessionText.hasGuides(s)) GuidesRow(s, actions)
                    T(SessionText.footer(s), m.type.tiny.copy(fontSize = 12.sp), m.t.muted)
                }
                ClaudeChat(chat, "", Modifier.weight(1f).fillMaxWidth().drawBehind { drawLine(m.t.line, Offset(0f, 0f), Offset(size.width, 0f), 1f) },
                    onOpenConnections = actions.openConnections)
            }
        }
    }
}

@Composable
fun SessionHeader(s: CameraSession) {
    val m = muse
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(s.title, m.type.body.copy(fontSize = 15.sp), m.t.ink, weight = FontWeight.Bold, maxLines = 1)
            T(SessionText.subtitle(s), m.scale.caption.copy(fontFeatureSettings = "tnum"), m.t.muted, maxLines = 1)
        }
        val (label, kind) = SessionText.pill(s)
        Pill(label, kind)
    }
}

/** Phone: three guide thumbnails and "rev 4 guides · Greybox · depth · pose · 3 keyframes · Use for Shot 01 →". */
@Composable
fun GuidesRow(s: CameraSession, actions: ChatActions) {
    val m = muse
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        listOf("greybox", "depth", "pose").forEach { k -> GuideThumb(k, s.assets.lastOrNull { it.kind == k && it.ready }, Modifier.width(46.dp).height(82.dp)) }
        Column(Modifier.weight(1f).padding(start = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            T("rev ${s.revision} guides", m.type.body.copy(fontSize = 13.5.sp), m.t.ink, weight = FontWeight.Bold)
            T(SessionText.guidesLine(s.assets), m.type.tiny, m.t.muted)
            actions.use?.let { u -> T("${actions.useLabel} →", m.type.tiny, m.t.accent, Modifier.press(onClick = u), weight = FontWeight.SemiBold) }
        }
    }
}

// ---------------------------------------------------------------- the panel (wide windows, D6 right column)

/** D6's right column: header with LIVE and the status rows, the guides card, then the Claude chat on the owner's plan. */
@Composable
fun ChatPanel(ui: CameraUi, now: Long, actions: ChatActions, modifier: Modifier = Modifier) {
    val m = muse
    val s = ui.session ?: return
    val chat = actions.chat ?: rememberClaudeChatStore("camera", s.id)
    val chatUi by chat.ui.collectAsState()
    Column(modifier.fillMaxHeight().background(m.t.bg).drawBehind { drawLine(m.t.line, Offset(0f, 0f), Offset(0f, size.height), 1f) }) {
        Column(Modifier.fillMaxWidth().drawBehind { drawLine(m.t.line, Offset(0f, size.height), Offset(size.width, size.height), 1f) }.padding(horizontal = 18.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                T("Direct with Claude", m.type.h3, m.t.ink, Modifier.weight(1f), maxLines = 1)
                LivePill(ui.live)
            }
            SessionText.rows(s, ui.connections, chatUi.busy, now).forEach { StatusLine(it) }
        }
        if (SessionText.hasGuides(s)) Box(Modifier.padding(horizontal = 18.dp, vertical = 12.dp)) { GuidesCard(s, actions) }
        ClaudeChat(chat, "", Modifier.weight(1f).fillMaxWidth(), onOpenConnections = actions.openConnections)
    }
}

/** "Guides ready · rev 4": greybox, depth, pose | START, MID, END, and Use for Shot. */
@Composable
fun GuidesCard(s: CameraSession, actions: ChatActions) {
    val m = muse
    Column(Modifier.fillMaxWidth().camBox().padding(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            T("Guides ready · rev ${s.revision}", m.type.body.copy(fontSize = 13.5.sp), m.t.ink, Modifier.weight(1f), weight = FontWeight.Bold)
            T("${SessionText.seconds(s.durationSec)} · ${s.fps} fps", m.scale.caption.copy(fontFeatureSettings = "tnum"), m.t.muted)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf("greybox" to "GREYBOX", "depth" to "DEPTH", "pose" to "POSE").forEach { (k, l) ->
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    GuideThumb(k, s.assets.lastOrNull { it.kind == k && it.ready }, Modifier.width(44.dp).height(78.dp))
                    T(l, m.scale.caption.copy(fontFeatureSettings = "tnum"), m.t.muted)
                }
            }
            Box(Modifier.width(1.dp).height(78.dp).background(m.t.line))
            listOf("keyframe_start" to "START", "keyframe_mid" to "MID", "keyframe_end" to "END").forEachIndexed { i, (k, l) ->
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    GuideThumb("greybox", s.assets.lastOrNull { it.kind == k && it.ready }, Modifier.width(32.dp).height(56.dp), frame = i)
                    T(l, m.scale.caption.copy(fontFeatureSettings = "tnum"), m.t.muted)
                }
            }
        }
        actions.use?.let { u -> SmallBtn(actions.useLabel, primary = true, onClick = u) }
    }
}

@Composable
fun SmallBtn(text: String, primary: Boolean = false, icon: String? = null, onClick: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(if (m.isA) 2.dp else 999.dp)
    Row(Modifier.height(34.dp).clip(shape).background(if (primary) m.t.cta else m.t.surface).border(1.dp, if (primary) m.t.cta else m.t.line, shape)
        .press(onClick = onClick).padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        if (icon != null) CamIc(icon, 14.dp, if (primary) m.t.ctaInk else m.t.ink)
        T(text, m.type.body.copy(fontSize = 12.5.sp), if (primary) m.t.ctaInk else m.t.ink, weight = FontWeight.SemiBold, maxLines = 1)
    }
}

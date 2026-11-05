package studio.muse.app.ui.screens.camera

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import studio.muse.app.ui.theme.muse

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
)

/**
 * Phone M5 · Direct with Claude: session card, status, read-only plan, the last exchange or the working strip, the guides
 * row and the composer. Blender runs on the Mac, never on the phone.
 */
@Composable
fun DirectWithClaudeContent(ui: CameraUi, now: Long, actions: ChatActions) {
    val m = muse
    val s = ui.session
    Column(Modifier.fillMaxSize().background(m.t.bg).imePadding()) {
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
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            SessionHeader(s)
            Column(Modifier.fillMaxWidth().camBox().padding(horizontal = 12.dp, vertical = 6.dp)) {
                SessionText.rows(s, ui.connections, ui.turn != null, now).forEach { StatusLine(it) }
            }
            PlanView(s, ui.playhead, Modifier.fillMaxWidth().height(196.dp).camBox(), compact = true)
            val turns = Transcript.turns(ui.messages, ui.sentHere)
            val lastYou = ui.turn?.message ?: turns.filterIsInstance<Turn.You>().lastOrNull()?.text
            if (lastYou != null) YouBubble(lastYou, null, 290.dp)
            val t = ui.turn
            if (t != null) WorkingBlock(t, compact = true)
            else turns.lastOrNull()?.let { if (it is Turn.Claude) ClaudeBlock(it) }
            ui.notice?.let { NoticeView(it, actions) }
            if (SessionText.hasGuides(s)) GuidesRow(s, actions)
        }
        Composer(placeholder = "Direct the shot…", busy = ui.busy, footer = SessionText.footer(s), onSend = actions.send, horizontal = 16.dp)
    }
}

@Composable
fun SessionHeader(s: CameraSession) {
    val m = muse
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(s.title, m.type.body.copy(fontSize = 15.sp), m.t.ink, weight = FontWeight.Bold, maxLines = 1)
            T(SessionText.subtitle(s), m.type.mono.copy(fontSize = 12.sp), m.t.muted, maxLines = 1)
        }
        val (label, kind) = SessionText.pill(s)
        Pill(label, kind)
    }
}

@Composable
fun YouBubble(text: String, label: String?, maxW: Dp) {
    val m = muse
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        if (label != null) Lbl(label)
        Box(Modifier.widthIn(max = maxW).clip(RoundedCornerShape(if (m.isA) 0.dp else m.t.r * .6f)).background(m.t.ink).padding(horizontal = 12.dp, vertical = 10.dp)) {
            T(text, m.type.body.copy(fontSize = 13.5.sp, lineHeight = 19.sp), m.t.bg)
        }
    }
}

@Composable
fun ClaudeBlock(c: Turn.Claude) {
    val m = muse
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Lbl("Claude")
        if (c.text.isNotBlank()) T(c.text, m.type.body.copy(fontSize = 13.5.sp, lineHeight = 19.sp), m.t.ink)
        if (c.tools.isNotEmpty()) androidx.compose.foundation.layout.FlowRow(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            c.tools.forEach { ToolChipView(it) }
        }
    }
}

/** CLAUDE · WORKING (phone) / CLAUDE · WORKING ON REV n+1 (panel): the quote, the progress bar and the percent. */
@Composable
fun WorkingBlock(t: ChatTurn, compact: Boolean) {
    val m = muse
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Lbl(if (compact) "Claude · working" else t.title, Modifier.weight(1f), color = if (compact) m.t.muted else m.t.ink)
            if (!compact) T(t.percent, m.type.mono.copy(fontSize = 12.sp), m.t.ink)
        }
        T(if (compact) t.quote else "↳ “${t.message.take(60)}” — ${t.quote}", m.type.body.copy(fontSize = 13.5.sp, lineHeight = 19.sp), m.t.ink)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Bar(t.progress, Modifier.weight(1f), color = m.t.accent, height = 3.dp, track = m.t.line)
            T(if (compact) t.percent else if (t.waitingMac) "waiting for the Mac" else "step ${t.toolsDone} / ${t.toolsSeen.coerceAtLeast(1)}", m.type.mono.copy(fontSize = 12.sp), if (compact) m.t.ink else m.t.muted)
        }
    }
}

@Composable
fun NoticeView(n: ChatNotice, actions: ChatActions) {
    val m = muse
    Column(Modifier.fillMaxWidth().camBox(if (n.directorUnavailable) m.t.surface else m.t.surface2).padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        T(n.text, m.type.tiny, if (n.directorUnavailable) m.t.ink else m.t.accent)
        if (n.directorUnavailable) T("Open Connections →", m.type.tiny, m.t.accent, Modifier.press(onClick = actions.openConnections), weight = FontWeight.SemiBold)
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

/** The composer: field + send (disabled while Claude works), and the "never spends" footer. */
@Composable
fun Composer(placeholder: String, busy: Boolean, footer: String?, onSend: (String) -> Boolean, horizontal: Dp, surface: Boolean = false) {
    val m = muse
    var text by rememberSaveable { mutableStateOf("") }
    Column(Modifier.fillMaxWidth().background(m.t.bg).drawBehind { drawLine(m.t.line, Offset(0f, 0f), Offset(size.width, 0f), 1f) }
        .padding(horizontal = horizontal, vertical = 10.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            CamField(text, { text = it }, placeholder, Modifier.weight(1f))
            SendButton(!busy && text.isNotBlank()) { if (onSend(text.trim())) text = "" }
        }
        if (busy) T(ChatNotice.BUSY, m.type.tiny.copy(fontSize = 12.sp), m.t.muted)
        if (footer != null) T(footer, m.type.tiny.copy(fontSize = 12.sp), m.t.muted)
    }
}

// ---------------------------------------------------------------- the panel (wide windows, D6 right column)

/** D6's right column: header with LIVE and the status rows, the whole transcript, the guides card, the working strip, the composer. */
@Composable
fun ChatPanel(ui: CameraUi, now: Long, actions: ChatActions, modifier: Modifier = Modifier) {
    val m = muse
    val s = ui.session ?: return
    Column(modifier.fillMaxHeight().background(m.t.bg).drawBehind { drawLine(m.t.line, Offset(0f, 0f), Offset(0f, size.height), 1f) }) {
        Column(Modifier.fillMaxWidth().drawBehind { drawLine(m.t.line, Offset(0f, size.height), Offset(size.width, size.height), 1f) }.padding(horizontal = 18.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                T("Direct with Claude", m.type.h3, m.t.ink, Modifier.weight(1f), maxLines = 1)
                LivePill(ui.live)
            }
            SessionText.rows(s, ui.connections, ui.turn != null, now).forEach { StatusLine(it) }
        }
        val scroll = rememberScrollState()
        LaunchedEffect(ui.messages.size, ui.turn?.text?.length) { scroll.animateScrollTo(scroll.maxValue) }
        Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(scroll).padding(horizontal = 18.dp, vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            val turns = Transcript.turns(ui.messages, ui.sentHere)
            if (turns.isEmpty() && ui.turn == null) T("Tell Claude what happens in the shot: who moves where, when, and how the camera moves.", m.type.tiny, m.t.muted)
            turns.forEach { t ->
                when (t) {
                    is Turn.You -> YouBubble(t.text, t.label, 300.dp)
                    is Turn.Claude -> ClaudeBlock(t)
                }
            }
            ui.turn?.let { if (turns.filterIsInstance<Turn.You>().lastOrNull()?.text != it.message) YouBubble(it.message, "YOU · PHONE", 300.dp) }
            if (SessionText.hasGuides(s)) GuidesCard(s, actions)
            ui.notice?.let { NoticeView(it, actions) }
        }
        ui.turn?.let { t ->
            Box(Modifier.fillMaxWidth().background(m.t.surface2).drawBehind { drawLine(m.t.line, Offset(0f, 0f), Offset(size.width, 0f), 1f) }.padding(horizontal = 18.dp, vertical = 10.dp)) {
                WorkingBlock(t, compact = false)
            }
        }
        Composer(placeholder = "Direct the shot… “lower the camera, lens 50”", busy = ui.busy, footer = SessionText.footer(s), onSend = actions.send, horizontal = 18.dp)
    }
}

/** "Guides ready · rev 4": greybox, depth, pose | START, MID, END, and Use for Shot. */
@Composable
fun GuidesCard(s: CameraSession, actions: ChatActions) {
    val m = muse
    Column(Modifier.fillMaxWidth().camBox().padding(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            T("Guides ready · rev ${s.revision}", m.type.body.copy(fontSize = 13.5.sp), m.t.ink, Modifier.weight(1f), weight = FontWeight.Bold)
            T("${SessionText.seconds(s.durationSec)} · ${s.fps} fps", m.type.mono.copy(fontSize = 11.5.sp), m.t.muted)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf("greybox" to "GREYBOX", "depth" to "DEPTH", "pose" to "POSE").forEach { (k, l) ->
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    GuideThumb(k, s.assets.lastOrNull { it.kind == k && it.ready }, Modifier.width(44.dp).height(78.dp))
                    T(l, m.type.mono.copy(fontSize = 9.sp), m.t.muted)
                }
            }
            Box(Modifier.width(1.dp).height(78.dp).background(m.t.line))
            listOf("keyframe_start" to "START", "keyframe_mid" to "MID", "keyframe_end" to "END").forEachIndexed { i, (k, l) ->
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    GuideThumb("greybox", s.assets.lastOrNull { it.kind == k && it.ready }, Modifier.width(32.dp).height(56.dp), frame = i)
                    T(l, m.type.mono.copy(fontSize = 9.sp), m.t.muted)
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

/** The composer's field: one line, a smaller placeholder so the example fits the 404 dp panel. */
@Composable
fun CamField(value: String, onChange: (String) -> Unit, placeholder: String, modifier: Modifier = Modifier) {
    val m = muse
    androidx.compose.foundation.text.BasicTextField(
        value, onChange, modifier.height(46.dp).camBox(m.t.surface),
        textStyle = m.type.body.copy(fontSize = 14.sp, color = m.t.ink), singleLine = true,
        cursorBrush = androidx.compose.ui.graphics.SolidColor(m.t.accent),
        decorationBox = { inner ->
            Box(Modifier.fillMaxSize().padding(horizontal = 12.dp), contentAlignment = Alignment.CenterStart) {
                if (value.isEmpty()) T(placeholder, m.type.body.copy(fontSize = 14.sp), m.t.muted, maxLines = 1)
                inner()
            }
        },
    )
}

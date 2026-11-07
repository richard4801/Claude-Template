package studio.muse.app.ui.screens.camera

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import studio.muse.app.data.CameraAsset
import studio.muse.app.data.CameraMessage
import studio.muse.app.data.CameraSession
import studio.muse.app.ui.components.Lbl
import studio.muse.app.ui.components.Seg
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.TbBtn
import studio.muse.app.ui.components.press
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.scale

/** The editing actions of the Directed pane. */
class PaneActions(
    val playhead: (Double) -> Unit = {},
    val dragCharacter: ((String, P2) -> Unit)? = null,
    val dragCamera: ((P2) -> Unit)? = null,
    val rerender: () -> Unit = {},
    val back: (() -> Unit)? = null,
)

/**
 * D6 for wide windows (tablet, desktop-size): tabs Blocking · Guides · History, the session strip, the plan with drag
 * (or Camera view / Side), the legend and the keyframe timeline; Direct with Claude on the right.
 */
@Composable
fun DirectedCameraPaneContent(ui: CameraUi, now: Long, chat: ChatActions, pane: PaneActions, modifier: Modifier = Modifier) {
    val m = muse
    val s = ui.session
    var tab by rememberSaveable { mutableStateOf("Blocking") }
    Column(modifier.fillMaxSize().background(m.t.bg)) {
        Row(Modifier.fillMaxWidth().drawBehind { drawLine(m.t.line, Offset(0f, size.height), Offset(size.width, size.height), 1f) }.padding(horizontal = 20.dp),
            verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(28.dp)) {
            pane.back?.let { TbBtn("back", it, Modifier.padding(bottom = 2.dp)) }
            listOf("Blocking", "Guides", "History").forEach { t ->
                Column(Modifier.press { tab = t }.padding(top = 12.dp), verticalArrangement = Arrangement.spacedBy(9.dp)) {
                    T(t, m.type.body.copy(fontSize = 14.5.sp), if (t == tab) m.t.ink else m.t.muted, weight = if (t == tab) FontWeight.SemiBold else null)
                    Box(Modifier.width(56.dp).height(2.dp).background(if (t == tab) m.t.accent else androidx.compose.ui.graphics.Color.Transparent))
                }
            }
        }
        if (s == null) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { T(ui.error ?: "Opening the camera session…", m.type.tiny, m.t.muted) }
            return@Column
        }
        Row(Modifier.weight(1f).fillMaxWidth()) {
            Column(Modifier.weight(1f).fillMaxSize()) {
                when (tab) {
                    "Guides" -> GuidesTab(s, now, Modifier.weight(1f))
                    "History" -> HistoryTab(s, ui.messages, now, Modifier.weight(1f))
                    else -> BlockingTab(ui, pane, Modifier.weight(1f))
                }
            }
            ChatPanel(ui, now, chat, Modifier.width(404.dp))
        }
    }
}

@Composable
private fun BlockingTab(ui: CameraUi, pane: PaneActions, modifier: Modifier) {
    val m = muse
    val s = ui.session ?: return
    var view by rememberSaveable { mutableStateOf("plan") }
    Column(modifier.fillMaxWidth()) {
        Column(Modifier.weight(1f).padding(start = 28.dp, end = 24.dp, top = 14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(Modifier.fillMaxWidth().height(44.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                IdChip(s.id)
                T(s.title, m.type.body.copy(fontSize = 14.5.sp, lineHeight = 18.sp), m.t.ink, Modifier.widthIn(max = 150.dp), weight = FontWeight.Bold, maxLines = 2)
                T(SessionText.specLine(s), m.scale.caption.copy(fontFeatureSettings = "tnum"), m.t.muted, Modifier.weight(1f), maxLines = 2)
                Seg(listOf("plan" to "Plan", "camera" to "Camera view", "side" to "Side"), view, { view = it }, Modifier.width(300.dp), small = true)
                SmallBtn("Re-render", icon = "refresh", onClick = pane.rerender)
            }
            val box = Modifier.fillMaxWidth().weight(1f).camBox()
            when (view) {
                "camera" -> CameraStill(s, ui.playhead, box)
                "side" -> PlanView(s, ui.playhead, box, side = true)
                else -> PlanView(s, ui.playhead, box, onDragCharacter = pane.dragCharacter, onDragCamera = pane.dragCamera)
            }
            PlanLegend(s, Modifier.padding(bottom = 10.dp), note = view == "plan" && pane.dragCharacter != null)
        }
        TimelineView(s, ui.playhead, pane.playhead, Modifier.drawBehind { drawLine(m.t.line, Offset(0f, 0f), Offset(size.width, 0f), 1f) })
    }
}

@Composable
private fun GuidesTab(s: CameraSession, now: Long, modifier: Modifier) {
    val m = muse
    val uri = LocalUriHandler.current
    val ready = s.assets.filter { it.ready }.sortedWith(compareBy<CameraAsset> { SessionText.GUIDE_ORDER.indexOf(it.kind).let { i -> if (i < 0) 99 else i } }.thenByDescending { it.createdAt })
    val pending = s.assets.filter { !it.ready }
    Column(modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 28.dp, vertical = 18.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            T("Guides · rev ${s.revision}", m.type.h3, m.t.ink, Modifier.weight(1f))
            T(SessionText.guidesLine(s.assets).ifEmpty { "None yet" }, m.type.tiny, m.t.muted)
        }
        if (ready.isEmpty() && pending.isEmpty()) T("No guides yet · ask Claude to render them, or render from your Claude app into ~/MUSE/CameraSessions/${s.id}/out/ (the Mac app uploads them).", m.type.tiny, m.t.muted)
        (pending + ready).forEach { a ->
            Row(Modifier.fillMaxWidth().camBox().padding(10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                val visual = a.contentType.startsWith("video/") || a.contentType.startsWith("image/")
                if (visual) GuideThumb(if (a.kind.startsWith("keyframe")) "greybox" else a.kind, a, Modifier.width(36.dp).height(64.dp))
                else Box(Modifier.size(36.dp, 64.dp).background(m.t.surface2), contentAlignment = Alignment.Center) { CamIc(if (a.kind == "blend") "cube" else "film", 16.dp, m.t.muted) }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    T(SessionText.assetLabel(a.kind), m.type.body.copy(fontSize = 13.5.sp), m.t.ink, weight = FontWeight.SemiBold)
                    T(listOf(SessionText.bytes(a.bytes), SessionText.sourceLabel(a.source), SessionText.ago(a.createdAt, now)).filter { it.isNotEmpty() }.joinToString(" · "), m.type.tiny, m.t.muted)
                }
                if (!a.ready) Lbl("Uploading…", color = m.t.warn)
                else if (a.contentType.startsWith("video/") && a.url != null) SmallBtn("Play", icon = null) { runCatching { uri.openUri(a.url) } }
            }
        }
    }
}

/** One History line: who · what · when. */
data class HistoryLine(val at: Long, val who: String, val what: String, val failed: Boolean = false)

object History {
    fun who(m: CameraMessage) = when {
        m.role == "user" -> "You"
        m.source == "mcp" -> "Claude (your Claude app)"
        else -> "Claude (chat)"
    }

    /** Newest first: tool steps, notes and messages, and the assets by time. */
    fun lines(messages: List<CameraMessage>, assets: List<CameraAsset>): List<HistoryLine> = (
        messages.map { m ->
            val what = when {
                m.tool != null -> toolChipName(m.tool.name).lowercase().replace('_', ' ') + (m.tool.summary.takeIf { it.isNotBlank() }?.let { " · $it" } ?: "")
                else -> m.text.lines().first().take(120)
            }
            HistoryLine(m.createdAt, who(m), what, m.tool?.ok == false)
        } + assets.map { a -> HistoryLine(a.createdAt, SessionText.sourceLabel(a.source).replaceFirstChar { it.uppercase() }, (if (a.ready) "uploaded " else "uploading ") + SessionText.assetLabel(a.kind)) }
        ).sortedByDescending { it.at }
}

@Composable
private fun HistoryTab(s: CameraSession, messages: List<CameraMessage>, now: Long, modifier: Modifier) {
    val m = muse
    Column(modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 28.dp, vertical = 18.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        T("rev ${s.revision} · now", m.scale.caption.copy(fontFeatureSettings = "tnum"), m.t.muted)
        Spacer(Modifier.height(8.dp))
        History.lines(messages, s.assets).forEach { l ->
            Row(Modifier.fillMaxWidth().drawBehind { drawLine(m.t.line, Offset(0f, size.height), Offset(size.width, size.height), 1f) }.padding(vertical = 9.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                T(l.who, m.type.body.copy(fontSize = 13.sp), m.t.ink, Modifier.width(170.dp), weight = FontWeight.SemiBold, maxLines = 1)
                T(l.what, m.type.body.copy(fontSize = 13.sp), if (l.failed) m.t.accent else m.t.ink, Modifier.weight(1f), maxLines = 2)
                T(SessionText.ago(l.at, now), m.scale.caption.copy(fontFeatureSettings = "tnum"), m.t.muted, maxLines = 1)
            }
        }
    }
}

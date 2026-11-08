package studio.muse.app.ui.screens.edit

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import studio.muse.app.ui.components.Bar
import studio.muse.app.ui.components.Cta2
import studio.muse.app.ui.components.NoteBox
import studio.muse.app.ui.components.Pill
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.ScreenBox
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.scale
import kotlin.math.floor

/** "0:04.2" (minutes, seconds, tenths). */
fun suiteTime(sec: Double): String {
    val t = floor(sec.coerceAtLeast(0.0) * 10) / 10
    val m = (t / 60).toInt(); val s = t - m * 60
    return "$m:" + String.format(java.util.Locale.ROOT, "%04.1f", s)
}

/** "0:04.27" (minutes, seconds, hundredths): the playhead while editing, fine enough to place a cut on a frame. */
fun playheadTime(sec: Double): String {
    val cs = kotlin.math.round(sec.coerceAtLeast(0.0) * 100).toLong()
    val m = cs / 6000; val s = (cs % 6000) / 100; val h = cs % 100
    return "$m:" + s.toString().padStart(2, '0') + "." + h.toString().padStart(2, '0')
}

/**
 * The editor (EM1): top bar (✕ · title · EXPORT), the preview with its safe area, the transport (time, play, undo,
 * redo, fullscreen), the multitrack timeline and the tool row; the open panel as a bottom sheet over it. On a wide
 * screen (tablet) the panel stays open as an inspector on the right instead.
 */
@Composable
fun EditSuiteContent(
    ui: EditSuiteUi,
    frames: Map<String, List<ImageBitmap>>,
    host: SuiteHost,
    act: (EditAction) -> Unit,
    onClose: () -> Unit,
    drawText: Boolean = true,
    picture: @Composable (Modifier) -> Unit,
) {
    val m = muse
    ScreenBox(statusPad = true) {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val wide = maxWidth >= 720.dp // tablets in portrait too (800 dp) get the approved layout
            val editor = @Composable { mod: Modifier ->
                Column(mod) {
                    TopRow(ui, act, onClose)
                    SuitePreview(ui, act, Modifier.fillMaxWidth().weight(1f), drawText, picture)
                    Transport(ui, act)
                    if (!ui.fullscreen) {
                        Box(Modifier.fillMaxWidth().height(1.dp).background(m.t.line))
                        if (ui.project != null) SuiteTimeline(ui, frames, act, waves = host.waves)
                        Toolbar(ui, act)
                    }
                }
            }
            if (wide) {
                // The approved Edit layout (plans/edit-layout.md, WS2's Mac design adapted): EditTablet.kt.
                EditTabletLayout(ui, frames, host, act, onClose, drawText, picture)
            } else {
                editor(Modifier.fillMaxSize())
                val panel = ui.panel
                if (ui.session?.chatOpen == true) EditClaudeSheet(ui, act) // workstream 2's sheet: its own scrim and frame
                else if (panel != null && ui.project != null) {
                    // Tap to keep: no scrim and a shorter sheet, so the picture above it takes the taps.
                    if (ui.keep == null) Box(Modifier.fillMaxSize().background(Color(0x40141210)).press { act(EditAction.Open(null)) })
                    SuiteSheet(ui, panel, host, act, Modifier.align(Alignment.BottomCenter).heightIn(max = maxHeight * (if (ui.keep != null) .42f else .62f)).navigationBarsPadding())
                }
            }
            // Edit sessions (workstream 3): Claude's change landed; a paid helper Claude asked for waits for the owner.
            ui.session?.claudeNote?.let { note ->
                androidx.compose.runtime.LaunchedEffect(note) { kotlinx.coroutines.delay(4000); act(EditAction.ClearClaudeNote) }
                ClaudeNote(note, { act(EditAction.ClearClaudeNote) }, Modifier.align(Alignment.TopCenter).padding(top = 58.dp, start = 16.dp, end = 16.dp))
            }
            if (ui.session?.conflict == true) {
                Box(Modifier.fillMaxSize().background(Color(0x40141210)).press { })
                ConflictSheet(act, Modifier.align(Alignment.BottomCenter).widthIn(max = 560.dp).navigationBarsPadding())
            } else ui.session?.asking?.let { p ->
                Scrim { act(EditAction.AnswerPending(p.id, false)) }
                PendingSheet(p, act, Modifier.align(Alignment.BottomCenter).widthIn(max = 560.dp).navigationBarsPadding())
            }
            // Loading / failure over everything.
            when (val ph = ui.phase) {
                is SuitePhase.Loading -> Status(if (ph.progress != null) "Getting the video · ${(ph.progress * 100).toInt()} %" else "Getting the video…", ph.progress)
                is SuitePhase.Failed -> if (ui.project == null) Box(Modifier.fillMaxSize().background(m.t.bg).padding(24.dp), contentAlignment = Alignment.Center) {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        NoteBox(ph.message, icon = "shield", warn = true)
                        Cta2("Back", onClose, Modifier.fillMaxWidth(), height = 46.dp)
                    }
                }
                else -> {}
            }
        }
    }
}

@Composable
private fun Status(text: String, progress: Float?) {
    val m = muse
    Box(Modifier.fillMaxSize().background(m.t.bg.copy(alpha = .6f)), contentAlignment = Alignment.Center) {
        Column(Modifier.width(260.dp).clip(RoundedCornerShape(m.t.r)).background(m.t.surface).padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            T(text, m.type.body.copy(fontSize = 14.sp), m.t.ink)
            Bar(progress ?: .15f)
        }
    }
}

@Composable
private fun TopRow(ui: EditSuiteUi, act: (EditAction) -> Unit, onClose: () -> Unit) {
    val m = muse
    Row(Modifier.fillMaxWidth().height(56.dp).padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(48.dp).press(onClick = onClose).semantics { contentDescription = "Close" }, contentAlignment = Alignment.CenterStart) { EIc("x", 22.dp, m.t.ink) }
        // The title over its status line (plans/edit-layout.md), on the type scale.
        Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
            studio.muse.app.ui.components.FitText(ui.title.ifBlank { "Edit" }, m.scale.heading, m.t.ink)
            T(if (ui.reopened) "Edited version" else "Not exported yet", m.scale.caption, m.t.muted, maxLines = 1)
        }
        if (ui.session != null) Box(Modifier.size(44.dp, 48.dp).press { act(EditAction.Open(if (ui.panel == Panel.HISTORY) null else Panel.HISTORY)) }.semantics { contentDescription = "History" }, contentAlignment = Alignment.Center) {
            EIc("clock", 20.dp, if (ui.panel == Panel.HISTORY) m.t.accent else m.t.ink)
        }
        if (ui.claudeOwner || ui.session != null) { EditClaudeButton(ui, act); Spacer(Modifier.width(8.dp)) }
        val shape = RoundedCornerShape(if (m.isA) 0.dp else if (m.isB) 8.dp else 999.dp)
        Box(
            Modifier.height(36.dp).clip(shape).background(m.t.cta).press(enabled = ui.project != null) { act(EditAction.Open(Panel.EXPORT)) }.padding(horizontal = 14.dp)
                .semantics { contentDescription = "Export" },
            contentAlignment = Alignment.Center,
        ) { T("Export", m.scale.label, m.t.ctaInk, maxLines = 1) }
    }
}

@Composable
private fun Transport(ui: EditSuiteUi, act: (EditAction) -> Unit) {
    val m = muse
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        // Narrow phones show the playhead time only; the edit's length is on the ruler.
        val time = if (maxWidth < 380.dp) playheadTime(ui.playheadSec) else "${playheadTime(ui.playheadSec)} / ${playheadTime(ui.duration)}"
        Row(Modifier.fillMaxWidth().height(48.dp).padding(horizontal = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            T(time, m.scale.label.tabular(), m.t.ink, Modifier.weight(1f), maxLines = 1)
            @Composable
            fun b(icon: String, label: String, enabled: Boolean, tint: androidx.compose.ui.graphics.Color = m.t.ink, size: androidx.compose.ui.unit.Dp = 18.dp, onClick: () -> Unit) =
                Box(Modifier.size(42.dp, 48.dp).press(enabled = enabled, onClick = onClick).semantics { contentDescription = label }, contentAlignment = Alignment.Center) {
                    EIc(icon, size, if (enabled) tint else m.t.muted)
                }
            // Split at the playhead, one tap away (owner report 2026-11-08: placing a cut must be direct).
            b("scissors", "Split at playhead", ui.project != null, size = 20.dp) { act(EditAction.Split) }
            b("caret-left", "Previous frame", ui.project != null) { act(EditAction.StepFrame(-1)) }
            b(if (ui.playing) "pause" else "play", if (ui.playing) "Pause" else "Play", ui.ready, size = 20.dp) { act(EditAction.PlayPause) }
            b("caret-right", "Next frame", ui.project != null) { act(EditAction.StepFrame(1)) }
            b("undo", "Undo", ui.canUndo) { act(EditAction.Undo) }
            b("redo", "Redo", ui.canRedo) { act(EditAction.Redo) }
        }
    }
}

@Composable
private fun Toolbar(ui: EditSuiteUi, act: (EditAction) -> Unit) {
    val m = muse
    val lit = ui.panel?.tool
    // A scrolling row (CapCut-style): every tool keeps a 64 dp wide, 60 dp tall target, however narrow the phone.
    Row(
        Modifier.fillMaxWidth().height(66.dp).navigationBarsPadding().horizontalScroll(rememberScrollState()).padding(horizontal = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        EditTool.entries.forEach { tool ->
            val on = tool == lit
            val c = if (on) m.t.accent else m.t.ink
            Column(
                Modifier.widthIn(min = 64.dp).height(60.dp).press(enabled = ui.project != null)
 { act(EditAction.Open(if (on) null else tool.panel)) }.semantics { contentDescription = tool.label },
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                EIc(tool.icon, 20.dp, c)
                T(tool.label, m.scale.micro, c, maxLines = 1) // `micro` 11, full words (plans/edit-layout.md)
            }
        }
    }
}

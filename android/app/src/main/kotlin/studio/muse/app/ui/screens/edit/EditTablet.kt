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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.scale
import studio.muse.core.edit.ExportShape

// The Edit suite on a tablet (≥ 720 dp, portrait included): WS2's approved layout (plans/edit-layout.md), adapted to Android. A 56 dp top bar
// (back, the title over its status line, the shape as one segmented control, Hook ideas, Claude, Export as the one primary);
// the viewer with "Safe area" as one segmented control and the transport under it; the inspector on the right (its sections
// as a 3 × 2 grid of labelled buttons, then that section's settings), which hides; and the timeline below with a labelled
// toolbar and named tracks. Android has no media bin: takes and overlays come in through the toolbar's Add.

/** The inspector's sections (the Mac's names). Video holds the picture side (looks, adjustments); Animate the transitions and effects. */
enum class InspectorSection(val label: String, val icon: String, val panel: Panel) {
    CAPTIONS("Captions", "closed-captioning", Panel.CAPTIONS), TEXT("Text", "text-t", Panel.TEXT), VIDEO("Video", "film-strip", Panel.FILTERS),
    AUDIO("Audio", "waveform", Panel.AUDIO), SPEED("Speed", "gauge", Panel.SPEED), ANIMATE("Animate", "sparkle", Panel.EFFECTS);

    companion object {
        fun of(p: Panel?): InspectorSection? = entries.firstOrNull { it.panel == p }
    }
}

/** The inspector's panel: the open one, else Captions (the Mac starts there). */
fun inspectorPanel(ui: EditSuiteUi): Panel = ui.panel ?: Panel.CAPTIONS

/** The 4/8 grid's panel padding and the inspector's width. */
private val Pad = 16.dp
private val InspectorWidth = 368.dp

@Composable
fun EditTabletLayout(ui: EditSuiteUi, frames: Map<String, List<ImageBitmap>>, host: SuiteHost, act: (EditAction) -> Unit, onClose: () -> Unit,
                     drawText: Boolean, picture: @Composable (Modifier) -> Unit) {
    val m = muse
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val roomy = maxWidth >= 1200.dp
        Column(Modifier.fillMaxSize()) {
            TabletTopBar(ui, act, onClose)
            Hairline()
            Row(Modifier.fillMaxWidth().weight(1f)) {
                Column(Modifier.weight(1f).fillMaxHeight()) {
                    SafeAreaRow(ui, act)
                    SuitePreview(ui, act, Modifier.fillMaxWidth().weight(1f).padding(horizontal = Pad).clip(RoundedCornerShape(if (m.isA) 0.dp else 12.dp)), drawText, picture, safeChip = false)
                    TabletTransport(ui, act)
                }
                if (!ui.inspectorHidden) {
                    VHairline()
                    Box(Modifier.width(InspectorWidth).fillMaxHeight()) {
                        // Edit sessions (workstream 3): the Claude panel takes the inspector's place while open.
                        if (ui.session?.chatOpen == true) EditClaudePanel(ui, Modifier.fillMaxSize())
                        else if (ui.project != null) Inspector(ui, host, act)
                    }
                }
            }
            if (!ui.fullscreen) {
                Hairline()
                TimelineToolbar(ui, act, labels = roomy)
                Hairline()
                if (ui.project != null) SuiteTimeline(ui, frames, act, headers = true, waves = host.waves)
            }
        }
    }
}

@Composable private fun Hairline() = Box(Modifier.fillMaxWidth().height(1.dp).background(muse.t.line))
@Composable private fun VHairline() = Box(Modifier.width(1.dp).fillMaxHeight().background(muse.t.line))

// ------------------------------------------------------------------------------------------------------------ Top bar

@Composable
private fun TabletTopBar(ui: EditSuiteUi, act: (EditAction) -> Unit, onClose: () -> Unit) {
    val m = muse
    Row(Modifier.fillMaxWidth().height(56.dp).padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(48.dp).press(onClick = onClose).semantics { contentDescription = "Back"; role = Role.Button }, contentAlignment = Alignment.Center) {
            EIc("caret-left", 20.dp, m.t.ink)
        }
        Column(Modifier.weight(1f).padding(start = 4.dp, end = 12.dp)) {
            T(ui.title.ifBlank { "Edit" }, m.scale.heading, m.t.ink, maxLines = 1)
            T(if (ui.reopened) "Edited version" else "Not exported yet", m.scale.caption, m.t.muted, maxLines = 1)
        }
        ui.project?.let { p ->
            val cur = ExportShape.of(p.canvas.width, p.canvas.height)
            Segmented(ExportShape.entries.map { it.label }, ExportShape.entries.indexOf(cur), "Shape") { i -> act(EditAction.Ratio(ExportShape.entries[i])) }
        }
        Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.End), verticalAlignment = Alignment.CenterVertically) {
            if (ui.claudeOwner || ui.session != null) EditClaudeButton(ui, act)
            Quiet("Hook ideas", "lightbulb-filament", enabled = ui.project != null) { act(EditAction.Open(Panel.TEXT)); act(EditAction.InspectorHidden(false)) }
            if (ui.inspectorHidden) Quiet("Show inspector", "sidebar-simple") { act(EditAction.InspectorHidden(false)) }
            val shape = RoundedCornerShape(if (m.isA) 0.dp else if (m.isB) 8.dp else 999.dp)
            Row(
                Modifier.padding(start = 4.dp).height(40.dp).clip(shape).background(m.t.cta)
                    .press(enabled = ui.project != null) { act(EditAction.Open(Panel.EXPORT)); act(EditAction.InspectorHidden(false)) }
                    .padding(horizontal = 16.dp).semantics { contentDescription = "Export"; role = Role.Button },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                EIc("export", 18.dp, m.t.ctaInk)
                T("Export", m.scale.label, m.t.ctaInk, maxLines = 1)
            }
        }
    }
}

/** A quiet top-bar button: icon and label, no fill. */
@Composable
private fun Quiet(label: String, icon: String, enabled: Boolean = true, onClick: () -> Unit) {
    val m = muse
    Row(
        Modifier.heightIn(min = 48.dp).press(enabled = enabled, onClick = onClick).padding(horizontal = 10.dp).semantics(mergeDescendants = true) { role = Role.Button },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        EIc(icon, 18.dp, if (enabled) m.t.ink else m.t.muted)
        T(label, m.scale.label, if (enabled) m.t.ink else m.t.muted, maxLines = 1)
    }
}

/** One segmented control (the shape, the safe area): text segments in a soft track, the picked one raised. */
@Composable
private fun Segmented(labels: List<String>, picked: Int, what: String, onPick: (Int) -> Unit) {
    val m = muse
    val outer = RoundedCornerShape(if (m.isA) 0.dp else 10.dp)
    val inner = RoundedCornerShape(if (m.isA) 0.dp else 8.dp)
    Row(Modifier.height(36.dp).clip(outer).background(m.t.surface2).padding(3.dp), verticalAlignment = Alignment.CenterVertically) {
        labels.forEachIndexed { i, l ->
            val on = i == picked
            Box(
                Modifier.fillMaxHeight().widthIn(min = 48.dp).clip(inner).background(if (on) m.t.surface else m.t.surface2)
                    .let { if (on && m.isD) it.border(1.5.dp, m.t.line, inner) else it }
                    .press { onPick(i) }.padding(horizontal = 12.dp)
                    .semantics { contentDescription = "$what $l"; selected = on; role = Role.RadioButton },
                contentAlignment = Alignment.Center,
            ) { T(l, m.scale.label.copy(fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal), if (on) m.t.ink else m.t.muted, maxLines = 1) }
        }
    }
}

// ------------------------------------------------------------------------------------------------------------- Viewer

@Composable
private fun SafeAreaRow(ui: EditSuiteUi, act: (EditAction) -> Unit) {
    val m = muse
    val options = listOf<SafeArea?>(null) + SafeArea.entries
    Row(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = Pad), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        T("Safe area", m.scale.caption, m.t.muted, maxLines = 1)
        Segmented(options.map { it?.label ?: "Off" }, options.indexOf(ui.safeArea), "Safe area") { i -> act(EditAction.SafeAreaOf(options[i])) }
    }
}

@Composable
private fun TabletTransport(ui: EditSuiteUi, act: (EditAction) -> Unit) {
    val m = muse
    Row(Modifier.fillMaxWidth().height(60.dp).padding(horizontal = Pad), verticalAlignment = Alignment.CenterVertically) {
        T("${playheadTime(ui.playheadSec)} / ${playheadTime(ui.duration)}", m.scale.label.tabular(), m.t.ink, Modifier.weight(1f), maxLines = 1)
        Icon48("rewind", "Go to start", enabled = ui.ready) { act(EditAction.Seek(0.0)) }
        Icon48("caret-left", "Previous frame", enabled = ui.project != null) { act(EditAction.StepFrame(-1)) }
        Box(Modifier.size(48.dp).press(enabled = ui.ready) { act(EditAction.PlayPause) }.semantics { contentDescription = if (ui.playing) "Pause" else "Play"; role = Role.Button }, contentAlignment = Alignment.Center) {
            Box(Modifier.size(40.dp).clip(CircleShape).background(m.t.ink), contentAlignment = Alignment.Center) { EIc(if (ui.playing) "pause" else "play", 18.dp, m.t.bg) }
        }
        Icon48("caret-right", "Next frame", enabled = ui.project != null) { act(EditAction.StepFrame(1)) }
        Icon48("fast-forward", "Go to end", enabled = ui.ready) { act(EditAction.Seek(ui.duration)) }
        Row(Modifier.weight(1f), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) {
            if (ui.session != null) Icon48("clock", "History", lit = ui.panel == Panel.HISTORY) {
                act(EditAction.Open(if (ui.panel == Panel.HISTORY) null else Panel.HISTORY)); act(EditAction.InspectorHidden(false))
            }
            Icon48("arrows-out", "Fullscreen", lit = ui.fullscreen) { act(EditAction.Fullscreen) }
        }
    }
}

@Composable
private fun Icon48(icon: String, label: String, enabled: Boolean = true, lit: Boolean = false, size: Dp = 20.dp, onClick: () -> Unit) {
    val m = muse
    Box(Modifier.size(48.dp).press(enabled = enabled, onClick = onClick).semantics { contentDescription = label; role = Role.Button }, contentAlignment = Alignment.Center) {
        EIc(icon, size, if (!enabled) m.t.muted else if (lit) m.t.accent else m.t.ink)
    }
}

// ---------------------------------------------------------------------------------------------------------- Inspector

@Composable
private fun Inspector(ui: EditSuiteUi, host: SuiteHost, act: (EditAction) -> Unit) {
    val m = muse
    val panel = inspectorPanel(ui)
    val section = InspectorSection.of(panel)
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().height(52.dp).padding(start = Pad, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            T("Inspector", m.scale.heading, m.t.ink, Modifier.weight(1f), maxLines = 1)
            Icon48("sidebar-simple", "Hide inspector", size = 18.dp) { act(EditAction.InspectorHidden(true)) }
        }
        // The sections as a 3 × 2 grid of labelled buttons: no tab ever breaks.
        Column(Modifier.padding(horizontal = 12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            InspectorSection.entries.chunked(3).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    row.forEach { s ->
                        val on = s == section
                        val shape = RoundedCornerShape(if (m.isA) 0.dp else 8.dp)
                        Row(
                            Modifier.weight(1f).height(44.dp).clip(shape).background(if (on) m.t.surface2 else m.t.bg).press(enabled = ui.project != null) { act(EditAction.Open(s.panel)) }
                                .padding(horizontal = 8.dp).semantics(mergeDescendants = true) { selected = on; role = Role.Tab },
                            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            EIc(s.icon, 18.dp, m.t.ink)
                            T(s.label, m.scale.label.copy(fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal), m.t.ink, maxLines = 1)
                        }
                    }
                }
            }
        }
        Spacer(Modifier.height(12.dp))
        Hairline()
        Column(Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()).padding(Pad), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            // A panel outside the six (the clip tools, keyframes, export, history) shows its own title.
            if (section == null) Row(verticalAlignment = Alignment.CenterVertically) {
                T(panel.title, m.scale.heading, m.t.ink, Modifier.weight(1f), maxLines = 1)
                T("Done", m.scale.label, m.t.ink, Modifier.press { act(EditAction.Open(null)) }.padding(horizontal = 8.dp, vertical = 12.dp).semantics { role = Role.Button }, maxLines = 1)
            }
            PanelBody(ui, panel, host, act)
        }
    }
}

// ----------------------------------------------------------------------------------------------------------- Timeline

/**
 * The timeline's toolbar: Split, Delete, Speed, Keyframe and Crop (labels when there is room, else the icon with its
 * label read out), Undo / Redo, Ripple and Snap to beat as toggles, Add, and zoom.
 */
@Composable
private fun TimelineToolbar(ui: EditSuiteUi, act: (EditAction) -> Unit, labels: Boolean) {
    val m = muse
    val ok = ui.ready
    fun open(p: Panel) { act(EditAction.Open(p)); act(EditAction.InspectorHidden(false)) }
    Row(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        Tool("scissors", "Split", labels, ok) { act(EditAction.Split) }
        Tool("trash", "Delete", labels, ok) { act(EditAction.Delete) }
        Tool("gauge", "Speed", labels, ok, lit = ui.panel == Panel.SPEED) { open(Panel.SPEED) }
        Tool("diamond", "Keyframe", labels, ok, lit = ui.panel == Panel.TRANSFORM) { open(Panel.TRANSFORM) }
        Tool("crop", "Crop", labels, ok) { open(Panel.TRANSFORM) }
        Divider()
        Tool("undo", "Undo", false, ui.canUndo) { act(EditAction.Undo) }
        Tool("redo", "Redo", false, ui.canRedo) { act(EditAction.Redo) }
        Divider()
        Toggle("Ripple", null, ui.ripple) { act(EditAction.Ripple(!ui.ripple)) }
        // Cut silences (free): removes long pauses; the sheet (Captions) has the rest.
        val cutting = ui.ai["silences"]?.running == true
        Tool("waveform", if (cutting) "Cutting" else "Cut silences", labels, ok && !cutting) { act(EditAction.CutSilences) }
        Toggle("Snap to beat", "magnet", ui.snapToBeats) { act(EditAction.SnapToBeats(!ui.snapToBeats)) }
        Tool("plus", "Add", true, ui.project != null, lit = ui.panel == Panel.OVERLAY) { open(Panel.OVERLAY) }
        Spacer(Modifier.weight(1f))
        Tool("minus-circle", "Zoom out", false, ok) { act(EditAction.Zoom(ui.pxPerSec / 1.25f)) }
        Tool("plus-circle", "Zoom in", false, ok) { act(EditAction.Zoom(ui.pxPerSec * 1.25f)) }
    }
}

@Composable private fun Divider() = Box(Modifier.padding(horizontal = 6.dp).width(1.dp).height(24.dp).background(muse.t.line))

@Composable
private fun Tool(icon: String, label: String, showLabel: Boolean, enabled: Boolean, lit: Boolean = false, onClick: () -> Unit) {
    val m = muse
    val c = if (!enabled) m.t.muted else if (lit) m.t.accent else m.t.ink
    Row(
        Modifier.heightIn(min = 48.dp).widthIn(min = 44.dp).press(enabled = enabled, onClick = onClick).padding(horizontal = 8.dp)
            .semantics(mergeDescendants = true) { contentDescription = label; role = Role.Button },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
    ) {
        EIc(icon, 18.dp, c)
        if (showLabel) T(label, m.scale.label, c, maxLines = 1)
    }
}

/** A labelled toggle: filled while on. */
@Composable
private fun Toggle(label: String, icon: String?, on: Boolean, onClick: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(if (m.isA) 0.dp else 999.dp)
    Box(Modifier.heightIn(min = 48.dp).press(onClick = onClick).semantics(mergeDescendants = true) { selected = on; role = Role.Switch; contentDescription = label }, contentAlignment = Alignment.Center) {
        Row(
            Modifier.height(34.dp).clip(shape).background(if (on) m.t.ink else m.t.bg).border(1.dp, if (on) m.t.ink else m.t.line, shape).padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            if (icon != null) EIc(icon, 16.dp, if (on) m.t.bg else m.t.ink)
            T(label, m.scale.label, if (on) m.t.bg else m.t.ink, maxLines = 1)
        }
    }
}

/** Time in tabular figures (no monospace, plans/edit-layout.md). */
fun androidx.compose.ui.text.TextStyle.tabular(): androidx.compose.ui.text.TextStyle = copy(fontFeatureSettings = "tnum")

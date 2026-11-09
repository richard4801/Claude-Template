package studio.muse.app.ui.screens.edit

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import studio.muse.app.ui.components.FlowRow
import studio.muse.app.ui.components.RefImage
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.Toggle
import studio.muse.app.ui.components.press
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale
import studio.muse.app.ui.theme.muse
import studio.muse.core.edit.CaptionExport
import studio.muse.core.edit.CaptionPreset
import studio.muse.core.edit.EditProject
import studio.muse.core.edit.ExportBitrate
import studio.muse.core.edit.ExportCodec
import studio.muse.core.edit.ExportFormat
import studio.muse.core.edit.GIF_FPS
import studio.muse.core.edit.GIF_MAX_SEC
import studio.muse.core.edit.GIF_SHORT_SIDE
import studio.muse.core.edit.SOUND_BITRATE
import studio.muse.core.edit.ExportResolution
import studio.muse.core.edit.ExportSettings
import studio.muse.core.edit.ExportShape
import studio.muse.core.edit.AnimKind
import studio.muse.core.edit.Font
import studio.muse.core.edit.Ease
import studio.muse.core.edit.KfProp
import studio.muse.core.edit.Mask
import studio.muse.core.edit.MaskShape
import studio.muse.core.edit.MediaClip
import studio.muse.core.edit.Presets
import studio.muse.core.edit.SpeedPreset
import studio.muse.core.edit.TextItem
import studio.muse.core.edit.TrackKind
import studio.muse.core.edit.Transform
import studio.muse.core.edit.TransitionKind
import studio.muse.core.edit.VideoClip
import studio.muse.core.edit.Visual
import studio.muse.core.edit.VoiceEffect
import studio.muse.core.edit.clipLength
import studio.muse.core.edit.curveSpeed
import studio.muse.core.edit.formatBytes
import studio.muse.core.edit.itemSpan
import studio.muse.core.edit.locate
import kotlin.math.ln
import kotlin.math.log10
import kotlin.math.pow
import kotlin.math.roundToInt

/** Things a sheet asks the platform for (files, the recorder, rendering). Screenshots pass the defaults. */
data class SuiteHost(
    val pickAudio: () -> Unit = {},
    val recordVo: () -> Unit = {},
    val importCube: () -> Unit = {},
    /** Renders and saves as a new edited version; [toPhone] also keeps a copy in the phone's Movies (and the .srt). */
    val export: (toPhone: Boolean) -> Unit = {},
    val cancelExport: () -> Unit = {},
    val lookThumbs: Map<String, ImageBitmap> = emptyMap(),
    /** Decoded sound levels per asset id, for the timeline's sound lanes. */
    val waves: Map<String, Peaks> = emptyMap(),
    /**
     * WS13 (owner): the model row for a helper ([purpose] captions / matte / track / denoise), shown before its Run.
     * The app's shared ModelChoiceRow (it hides itself for members and when the server lists no models); null in screenshots.
     */
    val modelRow: (@Composable (purpose: String) -> Unit)? = null,
    /** Saves the frame under the playhead as a photo on the phone (Pictures/MUSE). */
    val saveFrame: () -> Unit = {},
    /** Whether headphones (wired, USB or Bluetooth) are connected: "Play the video while recording" defaults to it. */
    val headphones: Boolean = false,
    /** "Add a photo": the system photo picker, then the upload (null where it isn't offered). */
    val addPhoto: (() -> Unit)? = null,
    /** Style kits: save this edit's style under a name; delete a saved one. */
    val saveKit: (String) -> Unit = {},
    val deleteKit: (String) -> Unit = {},
    /** Auto adjust from the frame under the playhead (the view model reads the frame). */
    val autoAdjust: () -> Unit = {},
    /** "Add a video from a link" (WS7's import, then added at the end); null where imports aren't offered. */
    val importLink: (() -> Unit)? = null,
)

/** The open panel as a bottom sheet. */
@Composable
fun SuiteSheet(ui: EditSuiteUi, panel: Panel, host: SuiteHost, act: (EditAction) -> Unit, modifier: Modifier = Modifier) {
    val close = { act(EditAction.Open(null)) }
    val back = { act(EditAction.Open(Panel.EDIT)) }
    SheetFrame(panel.title, if (panel == Panel.SPEED || panel == Panel.TRANSFORM) back else close, modifier) { PanelBody(ui, panel, host, act) }
}

/**
 * A panel's settings without the sheet around them: the tablet inspector (plans/edit-layout.md) shows them under its own
 * section grid, scrolling inside the inspector.
 */
@Composable
fun ColumnScope.PanelBody(ui: EditSuiteUi, panel: Panel, host: SuiteHost, act: (EditAction) -> Unit) {
    run {
        when (panel) {
            Panel.EDIT -> EditBody(ui, host, act)
            Panel.SPEED -> SpeedBody(ui, act)
            Panel.TRANSFORM -> TransformBody(ui, act)
            Panel.AUDIO -> AudioBody(ui, host, act)
            Panel.TEXT -> TextBody(ui, act)
            Panel.CAPTIONS -> CaptionsBody(ui, host, act)
            Panel.EFFECTS -> EffectsBody(ui, host, act)
            Panel.FILTERS -> FiltersBody(ui, host, act)
            Panel.OVERLAY -> OverlayBody(ui, host, act)
            Panel.RATIO -> RatioBody(ui, act)
            Panel.EXPORT -> ExportBody(ui, host, act)
            Panel.HISTORY -> HistoryBody(ui, act) // Edit sessions (workstream 3)
        }
    }
}

private val BLENDS = listOf(studio.muse.core.edit.BlendMode.NORMAL to "Normal", studio.muse.core.edit.BlendMode.MULTIPLY to "Multiply", studio.muse.core.edit.BlendMode.SCREEN to "Screen",
    studio.muse.core.edit.BlendMode.OVERLAY to "Overlay", studio.muse.core.edit.BlendMode.SOFT_LIGHT to "Soft light", studio.muse.core.edit.BlendMode.DARKEN to "Darken",
    studio.muse.core.edit.BlendMode.LIGHTEN to "Lighten", studio.muse.core.edit.BlendMode.ADD to "Add")

/** Auto-captions' language choices (ISO 639-1; "auto" lets the transcriber detect it). */
private val CAPTION_LANGUAGES = listOf("auto" to "Detect", "en" to "English", "es" to "Spanish", "pt" to "Portuguese", "fr" to "French", "de" to "German",
    "it" to "Italian", "ru" to "Russian", "uk" to "Ukrainian", "tr" to "Turkish", "ar" to "Arabic", "hi" to "Hindi", "ja" to "Japanese", "ko" to "Korean", "zh" to "Chinese")

private const val GREEN_KEY = "#2BD15F"
private const val BLUE_KEY = "#2B5BD1"

private fun fmt1(v: Double) = String.format(java.util.Locale.ROOT, "%.1f", v)
private fun signed(v: Int) = if (v > 0) "+$v" else if (v < 0) "−${-v}" else "0"

// ======================================================================= Edit
@Composable
private fun EditBody(ui: EditSuiteUi, host: SuiteHost, act: (EditAction) -> Unit) {
    val m = muse
    val sel = ui.selection?.second
    val clip = ui.activeClip
    T(
        when (sel) {
            null -> clip?.let { "Clip ${(ui.project?.mainClips?.indexOf(it) ?: 0) + 1} · ${fmt1(clipLength(it))} s" } ?: "No clip"
            is TextItem -> "Text · “${sel.text.take(24)}”"
            is MediaClip -> "${if (sel is VideoClip) "Clip" else "Audio"} · ${fmt1(clipLength(sel))} s"
            else -> "Image"
        },
        m.type.body.copy(fontSize = 13.sp), m.t.muted,
    )
    val tools = listOf(
        Triple("split", "Split", EditAction.Split), Triple("trash", "Delete", EditAction.Delete), Triple("copy", "Duplicate", EditAction.Duplicate),
        Triple("gauge", "Speed", EditAction.Open(Panel.SPEED)), Triple("move", "Transform", EditAction.Open(Panel.TRANSFORM)), Triple("trans", "Transition", EditAction.Open(Panel.EFFECTS)),
    )
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        tools.forEach { (icon, label, a) -> ToolTile(icon, label, false, { act(a) }, Modifier.weight(1f)) }
    }
    T("Hold a clip on the timeline to move it; drag the edges of the selected one to trim.", m.type.tiny.copy(fontSize = 12.sp), m.t.muted)
    val main = (sel as? VideoClip)?.takeIf { s -> ui.project?.main?.items?.any { it.id == s.id } == true } ?: clip
    val dur = main?.let { ui.project?.asset(it.asset)?.durationSec }
    if (main != null && main.holdSec == null && dur != null && dur - (main.outSec - main.inSec) > 0.05) {
        val room = dur - (main.outSec - main.inSec)
        SuiteSlider((main.inSec / room).toFloat(), { f, done -> act(EditAction.Slip(f * room, done)) }, label = "Slip · which part plays", valueText = "${fmt1(main.inSec)}–${fmt1(main.outSec)} s")
    }
    val hold = (sel as? VideoClip)?.holdSec
    if (hold != null) SuiteSlider(((hold - .1) / 9.9).toFloat(), { f, done -> act(EditAction.HoldLength(.1 + f * 9.9, done)) }, label = "Freeze frame length", valueText = "${fmt1(hold)} s")
    SuiteButton("Freeze frame", { act(EditAction.Freeze()) }, Modifier.fillMaxWidth(), icon = "pause")
    // Main track ⇄ overlay: the selected video clip (a main clip when there's more than one).
    ui.project?.let { p ->
        val selVideo = sel as? VideoClip
        val onMain = selVideo == null || p.main.items.any { it.id == selVideo.id }
        if (!onMain) SuiteButton("Move to main track", { act(EditAction.SwapTrack) }, Modifier.fillMaxWidth(), icon = "layers")
        else if (p.main.items.size > 1 && (selVideo != null || clip != null)) SuiteButton("Move to an overlay track", { act(EditAction.SwapTrack) }, Modifier.fillMaxWidth(), icon = "layers")
    }
    SuiteButton("Save frame as photo", host.saveFrame, Modifier.fillMaxWidth(), icon = "image")
    OptRow("Ripple", "Deleting closes the gap on that track", ui.ripple, { act(EditAction.Ripple(!ui.ripple)) })
    // Tracks (the tablet has these on its track headers): sound on/off for sound lanes, shown/hidden for picture lanes.
    ui.project?.let { p ->
        SuiteLabel("Tracks")
        lanesOf(p).filter { it.track != null && it.track.kind != TrackKind.CAPTION || it.kind == LaneKind.CLIP_SOUND }.forEach { lane ->
            val t = lane.track!!
            val sound = lane.kind == LaneKind.CLIP_SOUND || t.kind.isAudio
            if (sound) OptRow(laneName(lane), if (t.muted == true) "Silent" else "Plays", t.muted != true, { act(EditAction.ToggleTrackMuted(t.id)) })
            else OptRow(laneName(lane), if (t.hidden == true) "Hidden" else "Shown", t.hidden != true, { act(EditAction.ToggleTrackHidden(t.id)) })
        }
    }
    OptRow("Snap cuts to beats", if (ui.project?.let { SuiteOps.beatTimes(it, false).isNotEmpty() } == true) "Split lands on the nearest beat" else "Detect beats in Audio first", ui.snapToBeats,
        { act(EditAction.SnapToBeats(!ui.snapToBeats)) })
    KitsSection(ui, host, act)
}

/**
 * Style kits (plans/edit-parity.md, M): save this edit's look, colour, transition, caption and text styles and
 * background under a name; apply a saved kit to the whole edit (undo puts it back); delete one with a second tap.
 */
@Composable
internal fun KitsSection(ui: EditSuiteUi, host: SuiteHost, act: (EditAction) -> Unit) {
    val m = muse
    SuiteLabel("Style kits")
    T("Save this edit's look, colour, transition, captions and text, then use them on another edit.", m.type.tiny.copy(fontSize = 12.sp), m.t.muted)
    var name by remember { mutableStateOf("") }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.weight(1f).height(44.dp).background(m.t.surface).border(1.dp, m.t.line).padding(horizontal = 12.dp), contentAlignment = Alignment.CenterStart) {
            BasicTextField(name, { name = it.take(60) }, Modifier.fillMaxWidth().semantics { contentDescription = "Style kit name" }, singleLine = true,
                textStyle = m.type.body.copy(color = m.t.ink, fontSize = 14.sp), cursorBrush = SolidColor(m.t.accent),
                decorationBox = { inner -> Box { if (name.isEmpty()) T("${ui.title.ifEmpty { "This edit" }.take(30)} style", m.type.body.copy(fontSize = 14.sp), m.t.muted, maxLines = 1); inner() } })
        }
        SuiteButton("Save style", { host.saveKit(name); name = "" }, height = 44.dp, enabled = ui.project != null)
    }
    ui.kitsNote?.let { T(it, m.type.tiny.copy(fontSize = 12.sp), m.t.muted) }
    var confirm by remember { mutableStateOf<String?>(null) }
    ui.kits.forEach { k ->
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Column(Modifier.weight(1f)) {
                T(k.name, m.type.body.copy(fontSize = 13.5.sp, fontWeight = FontWeight.Bold), m.t.ink, maxLines = 1)
                T(k.parts, m.type.tiny.copy(fontSize = 12.sp), m.t.muted, maxLines = 1)
            }
            if (confirm == k.id) {
                SuiteButton("Keep", { confirm = null }, height = 34.dp)
                SuiteButton("Delete kit", { confirm = null; host.deleteKit(k.id) }, height = 34.dp)
            } else {
                SuiteButton("Apply", { act(EditAction.ApplyKit(k)) }, height = 34.dp, enabled = ui.project != null)
                Box(Modifier.size(40.dp).press { confirm = k.id }.semantics { contentDescription = "Delete ${k.name}" }, contentAlignment = Alignment.Center) { EIc("trash", 18.dp, m.t.muted) }
            }
        }
    }
}

@Composable
private fun ToolTile(icon: String, label: String, on: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val m = muse
    Column(modifier.press(onClick = onClick).semantics { contentDescription = label }, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Box(Modifier.fillMaxWidth().height(46.dp).background(if (on) m.t.ink else m.t.surface).border(1.dp, if (on) m.t.ink else m.t.line), contentAlignment = Alignment.Center) {
            EIc(icon, 20.dp, if (on) m.t.bg else m.t.ink)
        }
        T(label, m.type.tiny.copy(fontSize = 11.5.sp), m.t.muted, maxLines = 1)
    }
}

// ======================================================================= Speed (EM4)
private fun speedToFrac(s: Double) = ((log10(s) + 1) / 2).toFloat()        // 0.1 → 0, 1 → .5, 10 → 1
private fun fracToSpeed(f: Float) = 10.0.pow(f * 2.0 - 1).let { (it * 100).roundToInt() / 100.0 }

@Composable
private fun SpeedBody(ui: EditSuiteUi, act: (EditAction) -> Unit) {
    val m = muse
    val c = ui.activeClip ?: return T("Pick a clip", m.type.body, m.t.muted)
    SuiteSeg(listOf("normal" to "Normal", "curve" to "Curve"), if (ui.speedCurveTab) "curve" else "normal", {
        act(EditAction.SpeedTab(it == "curve"))
        if (it == "curve" && c.speedCurve == null) act(EditAction.CurvePreset(SpeedPreset.HERO))
        if (it == "normal" && c.speedCurve != null) act(EditAction.Speed(1.0))
    }, Modifier.fillMaxWidth(), height = 34.dp, fill = true)
    if (ui.speedCurveTab && c.speedCurve != null) {
        val curve = c.speedCurve!!
        CurveGraph(ui, c, act)
        val presets = listOf(SpeedPreset.MONTAGE to "Montage", SpeedPreset.HERO to "Hero", SpeedPreset.BULLET to "Bullet", SpeedPreset.FLASH_IN to "Flash in", SpeedPreset.FLASH_OUT to "Flash out", SpeedPreset.CUSTOM to "Custom")
        SuiteChips(presets.map { it.first.wire to it.second }, curve.preset.wire, { w -> act(EditAction.CurvePreset(SpeedPreset.entries.first { it.wire == w })) })
        Row(verticalAlignment = Alignment.CenterVertically) {
            T("${fmt1(c.outSec - c.inSec)} s → ${fmt1(clipLength(c))} s", m.type.body.copy(fontSize = 13.sp), m.t.ink, Modifier.weight(1f))
            T("Drag points · double-tap to add", m.type.tiny.copy(fontSize = 12.sp), m.t.muted)
        }
    } else {
        SuiteSlider(speedToFrac(c.speed), { f, done -> act(EditAction.Speed(fracToSpeed(f), done)) }, label = "Speed", valueText = "${c.speed}×")
        SuiteChips(listOf("0.5", "1", "1.5", "2", "3").map { it to "$it×" }, c.speed.let { if (it == it.toInt().toDouble()) it.toInt().toString() else it.toString() }, { act(EditAction.Speed(it.toDouble())) })
        // Length: the speed is worked out from the length you want (0.1×–10×).
        val src = c.outSec - c.inSec
        val lenFrac = ((log10(clipLength(c) / (src / 10)) / 2)).toFloat()
        SuiteSlider(lenFrac.coerceIn(0f, 1f), { f, done -> val target = (src / 10) * 10.0.pow(f * 2.0); act(EditAction.Speed(((src / target) * 100).roundToInt() / 100.0, done)) },
            label = "Length", valueText = "${fmt1(clipLength(c))} s")
        T("${fmt1(src)} s of video → ${fmt1(clipLength(c))} s · pitch kept", m.type.body.copy(fontSize = 13.sp), m.t.ink)
    }
}

/** The speed curve editor: log scale 0.1×–10×, points draggable, double-tap adds one, the playhead as a line. */
@Composable
private fun CurveGraph(ui: EditSuiteUi, c: VideoClip, act: (EditAction) -> Unit) {
    val m = muse
    val curve = c.speedCurve ?: return
    val measurer = rememberTextMeasurer()
    val pts by rememberUpdatedState(curve.points)
    val actNow by rememberUpdatedState(act)
    var dragging by remember { mutableIntStateOf(-1) }
    // Where the playhead is inside this clip (0–1 of its source), when it is.
    val px = ui.project?.let { p -> p.locate(c.id)?.let { (t, i) -> itemSpan(p, t, t.items[i]) } }?.let { s ->
        if (ui.playheadSec >= s.startSec && ui.playheadSec <= s.endSec) ((studio.muse.core.edit.clipSourceAt(c, ui.playheadSec - s.startSec) - c.inSec) / (c.outSec - c.inSec)).toFloat() else null
    }
    fun yOf(speed: Double, h: Float) = h * (1 - speedToFrac(speed))
    Canvas(
        Modifier.fillMaxWidth().height(120.dp).background(m.t.surface).semantics { contentDescription = "Speed curve" }
            .pointerInput(Unit) {
                detectTapGestures(onDoubleTap = { o -> actNow(EditAction.AddCurvePoint((o.x / size.width).toDouble().coerceIn(0.02, 0.98))) })
            }
            .pointerInput(Unit) {
                detectDragGestures(
                    onDragStart = { o ->
                        dragging = pts.indices.minByOrNull { i -> Offset(pts[i].x.toFloat() * size.width, yOf(pts[i].speed, size.height.toFloat())).minus(o).getDistance() }
                            ?.takeIf { i -> Offset(pts[i].x.toFloat() * size.width, yOf(pts[i].speed, size.height.toFloat())).minus(o).getDistance() < 40 * density } ?: -1
                    },
                    onDragEnd = { if (dragging >= 0) { val p = pts[dragging]; actNow(EditAction.CurvePoint(dragging, p.x, p.speed, true)) }; dragging = -1 },
                ) { ch, _ ->
                    if (dragging < 0) return@detectDragGestures
                    ch.consume()
                    val x = (ch.position.x / size.width).toDouble().coerceIn(0.0, 1.0)
                    val sp = fracToSpeed(1 - (ch.position.y / size.height).coerceIn(0f, 1f))
                    actNow(EditAction.CurvePoint(dragging, x, sp, false))
                }
            },
    ) {
        val w = size.width; val h = size.height
        val dash = PathEffect.dashPathEffect(floatArrayOf(2 * density, 4 * density))
        for ((s, label) in listOf(10.0 to "10×", 1.0 to "1×", 0.1 to "0.1×")) {
            val y = yOf(s, h).coerceIn(6 * density, h - 6 * density)
            drawLine(m.t.line, Offset(0f, y), Offset(w, y), 1 * density, pathEffect = dash)
            drawText(measurer, label, Offset(4 * density, (y - 12 * density).coerceAtLeast(0f)), TextStyle(fontFamily = m.t.mono, fontSize = 8.5.sp, color = m.t.muted))
        }
        val path = Path()
        val n = 96
        for (i in 0..n) {
            val x = i / n.toDouble()
            val y = yOf(curveSpeed(curve, x), h)
            if (i == 0) path.moveTo(0f, y) else path.lineTo((x * w).toFloat(), y)
        }
        drawPath(path, m.t.accent, style = Stroke(2 * density))
        px?.let { drawLine(m.t.ink, Offset(it * w, 0f), Offset(it * w, h), 1.5f * density) }
        curve.points.forEach { p ->
            val o = Offset((p.x * w).toFloat(), yOf(p.speed, h))
            drawCircle(m.t.surface, 5 * density, o)
            drawCircle(m.t.accent, 5 * density, o, style = Stroke(1.6f * density))
        }
    }
}

// ======================================================================= Transform & keyframes (E2)
@Composable
private fun TransformBody(ui: EditSuiteUi, act: (EditAction) -> Unit) {
    val m = muse
    val p = ui.project ?: return
    val id = (ui.selection?.second?.takeIf { it is Visual || it is TextItem } ?: ui.activeClip)?.id ?: return
    val item = p.tracks.flatMap { it.items }.firstOrNull { it.id == id } ?: return
    val tr = when (item) { is Visual -> item.transform; is TextItem -> item.transform; else -> null } ?: Transform()
    val keys = when (item) { is Visual -> item.keyframes; is TextItem -> item.keyframes; else -> null }

    @Composable
    fun line(label: String, prop: KfProp, value: String, frac: Float, set: (Float) -> Transform?) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SuiteSlider(frac, { f, done -> set(f)?.let { act(EditAction.SetTransform(it, done)) } }, Modifier.weight(1f), label = label, valueText = value)
            Spacer(Modifier.width(10.dp))
            Box(Modifier.size(48.dp).press { act(EditAction.AddKeyframe(prop)) }.semantics { contentDescription = "Keyframe $label" }, contentAlignment = Alignment.Center) {
                EIc(if (keys?.get(prop).isNullOrEmpty()) "keyframe" else "diamond", 14.dp, if (keys?.get(prop).isNullOrEmpty()) m.t.muted else m.t.accent)
            }
        }
    }
    // Values at the playhead: a keyframed property shows its curve's value there (moving the slider sets that key).
    val span = p.locate(id)?.let { (t, i) -> itemSpan(p, t, t.items[i]) }
    val local = span?.let { (ui.playheadSec - it.startSec).coerceIn(0.0, it.endSec - it.startSec) } ?: 0.0
    fun at(prop: KfProp, static: Double) = studio.muse.core.edit.propAt(keys, prop, static, local)
    val x = at(KfProp.X, tr.x ?: .5); val y = at(KfProp.Y, tr.y ?: .5); val sc = at(KfProp.SCALE, tr.scale ?: 1.0); val rot = at(KfProp.ROTATION, tr.rotation ?: 0.0)
    val op = at(KfProp.OPACITY, when (item) { is Visual -> item.opacity; is TextItem -> item.opacity; else -> null } ?: 1.0)
    line("Position x", KfProp.X, "${((x - .5) * 200).roundToInt()}", ((x + .5) / 2).toFloat()) { f -> tr.copy(x = r2(f * 2.0 - .5)) }
    line("Position y", KfProp.Y, "${((y - .5) * 200).roundToInt()}", ((y + .5) / 2).toFloat()) { f -> tr.copy(y = r2(f * 2.0 - .5)) }
    line("Scale", KfProp.SCALE, "${(sc * 100).roundToInt()}%", ((sc - .1) / 2.9).toFloat()) { f -> tr.copy(scale = r2(.1 + f * 2.9)) }
    line("Rotation", KfProp.ROTATION, "${rot.roundToInt()}°", ((rot + 180) / 360).toFloat()) { f -> tr.copy(rotation = (f * 360.0 - 180).roundToInt().toDouble()) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        SuiteSlider(op.toFloat(), { f, done -> act(EditAction.SetOpacity(f.toDouble(), done)) }, Modifier.weight(1f), label = "Opacity", valueText = "${(op * 100).roundToInt()}%")
        Spacer(Modifier.width(10.dp))
        Box(Modifier.size(48.dp).press { act(EditAction.AddKeyframe(KfProp.OPACITY)) }.semantics { contentDescription = "Keyframe Opacity" }, contentAlignment = Alignment.Center) {
            EIc(if (keys?.get(KfProp.OPACITY).isNullOrEmpty()) "keyframe" else "diamond", 14.dp, if (keys?.get(KfProp.OPACITY).isNullOrEmpty()) m.t.muted else m.t.accent)
        }
    }
    // Blend (overlays only): how the picture combines with what is below it.
    val overlayTrack = p.tracks.firstOrNull { t -> t.items.any { it.id == id } }?.kind?.let { it == TrackKind.VIDEO || it == TrackKind.IMAGE } == true
    if (overlayTrack && item is Visual) {
        SuiteLabel("Blend")
        val cur = when (item) { is VideoClip -> item.blend; is studio.muse.core.edit.ImageItem -> item.blend; else -> null } ?: studio.muse.core.edit.BlendMode.NORMAL
        SuiteChips(BLENDS.map { it.first.wire to it.second }, cur.wire, { w -> act(EditAction.SetBlend(studio.muse.core.edit.BlendMode.entries.first { it.wire == w })) })
    }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        SuiteChip("Flip horizontally", tr.flipX == true, { act(EditAction.Mirror(x = tr.flipX != true)) })
        SuiteChip("Flip vertically", tr.flipY == true, { act(EditAction.Mirror(y = tr.flipY != true)) })
    }
    // In / out animations of a picture (text has its own in the Text panel).
    when (item) {
        is VideoClip -> AnimPicker(item.id, item.animIn, item.animOut, clipLength(item), text = false, act = act)
        is studio.muse.core.edit.ImageItem -> AnimPicker(item.id, item.animIn, item.animOut, item.durationSec, text = false, act = act)
        else -> {}
    }
    T("◆ adds a keyframe at the playhead; a keyframed slider sets the key there", m.type.tiny.copy(fontSize = 12.sp), m.t.muted)
    if (!keys.isNullOrEmpty()) {
        SuiteLabel("Easing")
        SuiteChips(listOf(Ease.LINEAR to "Linear", Ease.EASE_IN to "Ease in", Ease.EASE_OUT to "Ease out", Ease.EASE_IN_OUT to "Smooth", Ease.HOLD to "Hold").map { it.first.wire to it.second },
            ui.keyEase.wire, { w -> act(EditAction.KeyEase(Ease.entries.first { it.wire == w })) })
        val here = keys.values.flatten().any { kotlin.math.abs(it.t - local) <= .05 }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            SuiteButton("Previous", { act(EditAction.KeyNav(next = false)) }, height = 34.dp, icon = "back")
            SuiteButton("Next", { act(EditAction.KeyNav(next = true)) }, height = 34.dp, icon = "chev-r")
            Spacer(Modifier.weight(1f))
            if (here) SuiteLink("Remove keyframes here") { act(EditAction.RemoveKeyframes()) }
        }
        T("Drag a ◆ on the timeline to move it.", m.type.tiny.copy(fontSize = 12.sp), m.t.muted)
    }
    // Crop (pictures only): how much is cut from each side, 0–45 %.
    if (item is Visual) {
        val cr = item.crop ?: studio.muse.core.edit.Crop()
        Row(verticalAlignment = Alignment.CenterVertically) {
            SuiteLabel("Crop", Modifier.weight(1f))
            if (item.crop != null) SuiteLink("Reset crop") { act(EditAction.SetCrop(null)) }
        }
        @Composable
        fun side(label: String, v: Double?, set: (Double) -> studio.muse.core.edit.Crop) =
            SuiteSlider(((v ?: 0.0) / .45).toFloat(), { f, done -> act(EditAction.SetCrop(set(f * .45), done)) }, label = label, valueText = "${((v ?: 0.0) * 100).roundToInt()}%")
        side("Left", cr.left) { cr.copy(left = it) }
        side("Right", cr.right) { cr.copy(right = it) }
        side("Top", cr.top) { cr.copy(top = it) }
        side("Bottom", cr.bottom) { cr.copy(bottom = it) }
    }
}

private fun r2(v: Double) = Math.round(v * 100) / 100.0

// ======================================================================= Audio (EM3)
@Composable
private fun AudioBody(ui: EditSuiteUi, host: SuiteHost, act: (EditAction) -> Unit) {
    val m = muse
    val p = ui.project ?: return
    val clip = SuiteOps.soundClip(p, ui.selectedId, ui.activeClip)
    val music = SuiteOps.musicTrack(p)
    val name = if (clip is VideoClip) "clip sound" else "clip"
    // With volume keyframes, the gain at the playhead (the clip's volume × the curve there).
    val keyGain = clip?.keyframes?.get(KfProp.VOLUME)?.takeIf { it.isNotEmpty() }?.let { k ->
        p.locate(clip.id)?.let { (t, i) -> itemSpan(p, t, t.items[i]) }?.let { sp -> studio.muse.core.edit.keyframeValue(k, (ui.playheadSec - sp.startSec).coerceAtLeast(0.0)) }
    } ?: 1.0
    val gain = clip?.let { if (it.muted == true) 0.0 else (it.volume ?: 1.0) * keyGain } ?: 1.0
    // The clip's own sound (owner report 2026-11-08): on/off, and detach it to its own lane.
    if (clip != null) {
        val on = clip.muted != true
        val what = when { clip is VideoClip -> "Clip ${(p.mainClips.indexOfFirst { it.id == clip.id } + 1).takeIf { it > 0 } ?: ""}".trim(); else -> "This sound" }
        val hasSound = clip !is VideoClip || SuiteOps.hasSound(p, clip)
        OptRow("Sound", if (!hasSound) "$what has no sound" else if (on) "$what plays its sound" else "$what is silent", on && hasSound, { if (hasSound) act(EditAction.MuteClip(on)) })
        if (clip is VideoClip && hasSound && p.main.items.any { it.id == clip.id })
            SuiteButton("Detach audio", { act(EditAction.DetachAudio) }, Modifier.fillMaxWidth(), icon = "waveform", enabled = on)
    }
    val db = SuiteOps.gainToDb(gain).coerceIn(-24.0, 6.0)
    Row(verticalAlignment = Alignment.CenterVertically) {
        SuiteSlider(((db + 24) / 30).toFloat(), { f, done -> act(EditAction.Volume(f * 30.0 - 24, done)) }, Modifier.weight(1f), label = "Volume · $name",
            valueText = if (gain <= 0) "Muted" else "${if (db < -0.05) "−" else if (db > 0.05) "+" else ""}${fmt1(kotlin.math.abs(db)).removeSuffix(".0")} dB")
        Spacer(Modifier.width(10.dp))
        val vk = clip?.keyframes?.get(KfProp.VOLUME)
        Box(Modifier.size(48.dp).press(enabled = clip != null) { act(EditAction.AddKeyframe(KfProp.VOLUME)) }.semantics { contentDescription = "Keyframe Volume" }, contentAlignment = Alignment.Center) {
            EIc(if (vk.isNullOrEmpty()) "keyframe" else "diamond", 14.dp, if (vk.isNullOrEmpty()) m.t.muted else m.t.accent)
        }
    }
    // Spoken clips evened out to one level (from the decoded sound levels the timeline draws).
    SuiteButton("Even out volume", { act(EditAction.EvenVolume(host.waves)) }, Modifier.fillMaxWidth(), icon = "waveform", enabled = host.waves.isNotEmpty())
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        val fi = clip?.fadeInSec ?: 0.0; val fo = clip?.fadeOutSec ?: 0.0
        SuiteSlider((fi / 3).toFloat(), { f, done -> act(EditAction.Fades(r1(f * 3.0), fo, done)) }, Modifier.weight(1f), label = "Fade in", valueText = "${fmt1(fi)} s")
        SuiteSlider((fo / 3).toFloat(), { f, done -> act(EditAction.Fades(fi, r1(f * 3.0), done)) }, Modifier.weight(1f), label = "Fade out", valueText = "${fmt1(fo)} s")
    }
    val duck = music?.duck
    OptRow("Auto-duck music", if (music == null) "Add music first" else "Under voice · ${duck?.level?.let { "−${(-SuiteOps.gainToDb(it)).roundToInt()}" } ?: "−12"} dB", duck != null, { act(EditAction.AutoDuck(duck == null)) })
    if (duck != null) Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        val a = duck.attackSec ?: duck.fadeSec ?: .25; val r = duck.releaseSec ?: duck.fadeSec ?: .25
        SuiteSlider((a / 2).toFloat(), { f, done -> act(EditAction.DuckTimes(r2(f * 2.0), r, done)) }, Modifier.weight(1f), label = "Attack", valueText = "${fmt1(a)} s")
        SuiteSlider((r / 3).toFloat(), { f, done -> act(EditAction.DuckTimes(a, r2(f * 3.0), done)) }, Modifier.weight(1f), label = "Release", valueText = "${fmt1(r)} s")
    }
    val denoise = ui.ai["denoise"]
    val cleaned = (clip as? VideoClip)?.audioAsset != null
    // Paid helpers off (or not available): a plain line; already cleaned audio keeps its toggle, to turn it off.
    val denoiseOff = ui.helpersOff["denoise"]?.takeIf { !cleaned }
    if (denoiseOff == null && !cleaned) host.modelRow?.invoke("denoise")
    if (denoiseOff != null) ComingSoon("Noise reduction", denoiseOff) else OptRow(
        "Noise reduction",
        when { denoise?.running == true -> "Cleaning the voice · ${denoise.progress} %"; cleaned -> "Background noise removed"; else -> "Removes background noise · ${denoise?.price ?: "AI"}" },
        cleaned, { act(EditAction.NoiseReduction(!cleaned)) },
    )
    val enh = (clip as? VideoClip)?.enhance ?: (clip as? studio.muse.core.edit.AudioClip)?.enhance ?: false
    OptRow("Voice enhance", "Clearer speech", enh == true, { act(EditAction.Enhance(enh != true)) })
    SuiteLabel("Voice effect")
    val ve = (clip as? VideoClip)?.voiceEffect ?: (clip as? studio.muse.core.edit.AudioClip)?.voiceEffect ?: VoiceEffect.NONE
    SuiteChips(VoiceEffect.entries.map { it.wire to it.wire.replaceFirstChar(Char::uppercase) }, ve.wire, { w -> act(EditAction.Voice(VoiceEffect.entries.first { it.wire == w })) })
    val hasBeats = SuiteOps.beatTimes(p, false).isNotEmpty()
    if (hasBeats) Row(verticalAlignment = Alignment.CenterVertically) {
        T("Beat markers${ui.bpm?.let { " · ${it.roundToInt()} BPM" } ?: ""}", m.type.body.copy(fontSize = 13.5.sp, fontWeight = FontWeight.Bold), m.t.ink, Modifier.weight(1f))
        SuiteSeg(listOf("all" to "All", "strong" to "Strong"), if (ui.beatMarks == BeatMarks.ALL) "all" else "strong", { act(EditAction.Beats(if (it == "all") BeatMarks.ALL else BeatMarks.STRONG)) })
    } else if (music != null) AiButton("Beat markers", ui.ai["beats"], { act(EditAction.DetectBeats) }, icon = "beat")
    if (hasBeats) OptRow("Snap cuts to beats", "Split lands on the nearest beat", ui.snapToBeats, { act(EditAction.SnapToBeats(!ui.snapToBeats)) })
    if (hasBeats) SuiteButton("Cut clips to the beat", { act(EditAction.CutToBeats) }, Modifier.fillMaxWidth(), icon = "beat")
    if (music != null) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        SuiteButton("Mark a beat here", { act(EditAction.MarkBeat) }, Modifier.weight(1f), icon = "beat")
        if (hasBeats) SuiteButton("Clear beat marks", { act(EditAction.ClearBeats) }, Modifier.weight(1f))
    }
    if (ui.selection?.second is studio.muse.core.edit.AudioClip) SuiteButton("Loop to the end", { act(EditAction.LoopAudio) }, Modifier.fillMaxWidth(), icon = "arrows-clockwise")
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        SuiteButton("Music from uploads", host.pickAudio, Modifier.weight(1f), icon = "music")
        SuiteButton(if (ui.recordingAt != null) "Stop recording" else "Record VO", host.recordVo, Modifier.weight(1f), icon = "mic", primary = ui.recordingAt != null)
    }
    // Hearing the video while recording (owner-approved design pass): on by default with headphones, off on the speaker.
    val playAlong = ui.voPlayback ?: host.headphones
    OptRow("Play the video while recording", if (host.headphones) "You'll hear it in your headphones" else "Off on the speaker, so the mic doesn't pick it up", playAlong,
        { act(EditAction.VoPlayback(!playAlong)) })
}

private fun r1(v: Double) = Math.round(v * 10) / 10.0

// ======================================================================= Text & hooks (E3)
@Composable
private fun TextBody(ui: EditSuiteUi, act: (EditAction) -> Unit) {
    val m = muse
    val sel = ui.selection?.second as? TextItem
    SuiteButton("Add text", { act(EditAction.AddText) }, Modifier.fillMaxWidth(), icon = "text-t", primary = sel == null)
    if (sel != null) {
        SuiteLabel("Text")
        var text by remember(sel.id) { mutableStateOf(sel.text) }
        BasicTextField(
            text, { text = it; act(EditAction.EditText(sel.id, it)) },
            Modifier.fillMaxWidth().background(m.t.surface).border(1.dp, m.t.line).padding(12.dp).semantics { contentDescription = "Text" },
            textStyle = m.type.body.copy(color = m.t.ink), cursorBrush = SolidColor(m.t.accent),
        )
        TextStyleEditor(sel, act)
        AnimPicker(sel.id, sel.animIn, sel.animOut, sel.durationSec, text = true, act = act)
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        SuiteLabel("Hook templates", Modifier.weight(1f))
        T("First 2 seconds", m.type.tiny.copy(fontSize = 12.sp), m.t.muted)
    }
    Presets.HOOKS.forEach { h ->
        Row(
            Modifier.fillMaxWidth().press { act(EditAction.AddHook(h.id)) }.padding(vertical = 2.dp).semantics { contentDescription = "Add ${h.label}" },
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Box(Modifier.size(96.dp, 30.dp).background(Color(0xFF151311)), contentAlignment = Alignment.Center) {
                StyledText(h.label.uppercase(), h.style.copy(sizePct = .4, uppercase = true, maxWidthPct = 1.0, lineHeight = 1.0), 30.dp, 1f, 92.dp)
            }
            T(h.text, m.type.body.copy(fontSize = 13.5.sp), m.t.ink, Modifier.weight(1f), maxLines = 1)
            EIc("plus", 16.dp, m.t.ink)
        }
    }
}

private val TEXT_COLOURS = listOf("#FFFFFF", "#111111", "#FFE600", "#FF2D87", "#22D3EE", "#4ADE80")

/** Font, weight, size, colour, alignment, outline, shadow and background of a text item (every field of the contract's TextStyle). */
@Composable
private fun TextStyleEditor(t: TextItem, act: (EditAction) -> Unit) {
    val m = muse
    val st = t.style
    fun set(n: studio.muse.core.edit.TextStyle, done: Boolean = true) = act(EditAction.SetTextStyle(t.id, n, done))
    SuiteLabel("Font")
    SuiteChips(Font.entries.map { it.wire to it.wire.replaceFirstChar(Char::uppercase) }, st.font.wire, { w -> set(st.copy(font = Font.entries.first { it.wire == w })) })
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        SuiteSeg(listOf("400" to "Regular", "700" to "Bold", "900" to "Black"), st.weight.toString(), { set(st.copy(weight = it.toInt())) }, Modifier.weight(1f), height = 34.dp, fill = true)
        SuiteSeg(listOf("left" to "Left", "center" to "Centre", "right" to "Right"), st.align.wire, { w -> set(st.copy(align = studio.muse.core.edit.Align.entries.first { it.wire == w })) }, Modifier.weight(1f), height = 34.dp, fill = true)
    }
    SuiteSlider(((st.sizePct - .015) / (.25 - .015)).toFloat(), { f, done -> set(st.copy(sizePct = r3s(.015 + f * (.25 - .015))), done) }, label = "Size", valueText = "${(st.sizePct * 1000).roundToInt() / 10.0}%")
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        T("Colour", m.type.body.copy(fontSize = 13.sp), m.t.muted, Modifier.width(64.dp))
        TEXT_COLOURS.forEach { c -> Swatch(c, st.color.equals(c, true)) { set(st.copy(color = c)) } }
    }
    SuiteSlider((((st.letterSpacing ?: 0.0) + .1) / .6).toFloat(), { f, done -> set(st.copy(letterSpacing = r3s(-.1 + f * .6)), done) }, label = "Letter spacing", valueText = "${((st.letterSpacing ?: 0.0) * 100).roundToInt()}")
    OptRow("Capitals", "Shows the text in capitals", st.uppercase == true, { set(st.copy(uppercase = if (st.uppercase == true) null else true)) })
    OptRow("Outline", "A line around each letter", st.stroke != null, { set(st.copy(stroke = if (st.stroke != null) null else studio.muse.core.edit.Stroke("#000000", .08))) })
    st.stroke?.let { k ->
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            T("Outline", m.type.body.copy(fontSize = 13.sp), m.t.muted, Modifier.width(64.dp))
            TEXT_COLOURS.forEach { c -> Swatch(c, k.color.equals(c, true)) { set(st.copy(stroke = k.copy(color = c))) } }
        }
        SuiteSlider((k.widthPct / .3).toFloat(), { f, done -> set(st.copy(stroke = k.copy(widthPct = r3s(f * .3))), done) }, label = "Outline width", valueText = "${(k.widthPct * 100).roundToInt()}")
    }
    OptRow("Shadow", "A soft shadow under the text", st.shadow != null, { set(st.copy(shadow = if (st.shadow != null) null else studio.muse.core.edit.Shadow("#000000", .5, .08, .04))) })
    OptRow("Background", "A box behind the text", st.background != null, { set(st.copy(background = if (st.background != null) null else studio.muse.core.edit.TextBackground("#000000", .6, .25, .2))) })
    st.background?.let { b ->
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            T("Box", m.type.body.copy(fontSize = 13.sp), m.t.muted, Modifier.width(64.dp))
            TEXT_COLOURS.forEach { c -> Swatch(c, b.color.equals(c, true)) { set(st.copy(background = b.copy(color = c))) } }
        }
        SuiteSlider(b.opacity.toFloat(), { f, done -> set(st.copy(background = b.copy(opacity = r3s(f.toDouble()))), done) }, label = "Box opacity", valueText = "${(b.opacity * 100).roundToInt()}%")
    }
}

private fun r3s(v: Double) = Math.round(v * 1000) / 1000.0

private val ANIMS = listOf(AnimKind.NONE to "None", AnimKind.FADE to "Fade", AnimKind.POP to "Pop", AnimKind.SLIDE_UP to "Slide up", AnimKind.SLIDE_DOWN to "Slide down", AnimKind.ZOOM to "Zoom", AnimKind.TYPEWRITER to "Typewriter")

/** In / out animation of a text or image item: kind and duration (typewriter is for text only). */
@Composable
fun AnimPicker(id: String, animIn: studio.muse.core.edit.Anim?, animOut: studio.muse.core.edit.Anim?, itemSec: Double, text: Boolean, act: (EditAction) -> Unit) {
    val kinds = ANIMS.filter { text || it.first != AnimKind.TYPEWRITER }
    val maxD = minOf(2.0, itemSec / 2).coerceAtLeast(.1)
    @Composable
    fun side(label: String, cur: studio.muse.core.edit.Anim?, set: (studio.muse.core.edit.Anim?, Boolean) -> Unit) {
        SuiteLabel(label)
        SuiteChips(kinds.map { it.first.wire to it.second }, (cur?.kind ?: AnimKind.NONE).wire, { w ->
            val k = AnimKind.entries.first { it.wire == w }
            set(if (k == AnimKind.NONE) null else studio.muse.core.edit.Anim(k, minOf(cur?.durationSec ?: .4, maxD)), true)
        })
        if (cur != null) SuiteSlider(((cur.durationSec - .1) / (maxD - .1).coerceAtLeast(.01)).toFloat(), { f, done -> set(cur.copy(durationSec = r3s(.1 + f * (maxD - .1))), done) },
            label = "$label length", valueText = "${fmt1(cur.durationSec)} s")
    }
    side("Animation in", animIn) { a, done -> act(EditAction.SetAnim(id, a, animOut, done)) }
    side("Animation out", animOut) { a, done -> act(EditAction.SetAnim(id, animIn, a, done)) }
}

// ======================================================================= Captions (EM2, E3)
@Composable
private fun CaptionsBody(ui: EditSuiteUi, host: SuiteHost, act: (EditAction) -> Unit) {
    val m = muse
    val p = ui.project ?: return
    val ct = ui.captionTrack?.caption
    if (ct == null) {
        T("Word-timed captions from the speech, in the style you pick.", m.type.body.copy(fontSize = 13.5.sp), m.t.muted)
        if (ui.helpersOff["captions"] == null) {
            host.modelRow?.invoke("captions")
            SuiteLabel("Spoken language")
            // One scrolling row (15 languages as wrapped chips took four rows).
            val cur = ui.captionLanguage ?: "auto"
            Row(Modifier.fillMaxWidth().horizontalScroll(androidx.compose.foundation.rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                CAPTION_LANGUAGES.forEach { (code, label) -> SuiteChip(label, code == cur, { act(EditAction.CaptionLanguage(code.takeIf { it != "auto" })) }) }
            }
        }
        ui.helpersOff["captions"]?.let { ComingSoon("Auto-captions", it) } ?: AiButton("Auto-captions", ui.ai["captions"], { act(EditAction.AutoCaptions) }, icon = "cc")
        AiButton("Cut silences", ui.ai["silences"], { act(EditAction.CutSilences) }, icon = "scissors")
        return
    }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(20.dp)) {
        listOf("Style", "Font", "Animation", "Words").forEach { tab ->
            val on = ui.captionTab == tab
            Column(Modifier.press { act(EditAction.CaptionTab(tab)) }) {
                T(tab, m.type.body.copy(fontSize = 13.5.sp, fontWeight = if (on) FontWeight.Bold else FontWeight.Normal), if (on) m.t.ink else m.t.muted)
                Spacer(Modifier.height(8.dp))
                Box(Modifier.width(if (on) (tab.length * 8).dp else 0.dp).height(2.dp).background(m.t.accent))
            }
        }
    }
    when (ui.captionTab) {
        "Font" -> {
            SuiteLabel("Font")
            SuiteChips(Font.entries.map { it.wire to it.wire.replaceFirstChar(Char::uppercase) }, ct.style.text.font.wire, { w -> act(EditAction.CaptionFont(Font.entries.first { it.wire == w })) })
            SuiteLabel("Colours")
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                T("Text", m.type.body.copy(fontSize = 13.sp), m.t.muted)
                listOf("#FFFFFF", "#FFE600", "#111111").forEach { c -> Swatch(c, ct.style.text.color.equals(c, true)) { act(EditAction.CaptionColors(text = c)) } }
                Spacer(Modifier.width(10.dp))
                T("Highlight", m.type.body.copy(fontSize = 13.sp), m.t.muted)
                listOf("#FFE600", "#4ADE80", "#22D3EE", "#FF2D87").forEach { c -> Swatch(c, ct.style.highlightColor.equals(c, true)) { act(EditAction.CaptionColors(highlight = c)) } }
            }
        }
        "Animation" -> {
            Row(verticalAlignment = Alignment.CenterVertically) {
                T("Words per caption", m.type.body.copy(fontSize = 13.5.sp, fontWeight = FontWeight.Bold), m.t.ink, Modifier.weight(1f))
                SuiteSeg(listOf("1", "2", "3", "4", "6").map { it to it }, (ct.style.wordsPerPage ?: 3).toString(), { act(EditAction.CaptionWordsPerPage(it.toInt())) })
            }
            T("Pages break at pauses and sentence ends too.", m.type.tiny.copy(fontSize = 12.sp), m.t.muted)
        }
        "Words" -> WordsBody(ui, p, act)
        else -> {
            val labels = Presets.CAPTION_STYLE_LABELS.take(6)
            labels.chunked(3).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    row.forEach { (preset, label) ->
                        CaptionTile(Presets.CAPTION_STYLES.getValue(preset), label, ct.style.preset == preset, { act(EditAction.CaptionStyleOf(preset)) }, Modifier.weight(1f))
                    }
                }
            }
            OptRow("Word-by-word highlight", "Active word pops", !ct.style.highlightColor.equals(ct.style.text.color, true), {
                act(EditAction.WordHighlight(ct.style.highlightColor.equals(ct.style.text.color, true)))
            })
            Row(verticalAlignment = Alignment.CenterVertically) {
                T("Position", m.type.body.copy(fontSize = 13.5.sp, fontWeight = FontWeight.Bold), m.t.ink, Modifier.weight(1f))
                val y = ct.style.y ?: .72
                SuiteSeg(listOf("top" to "Top", "mid" to "Mid", "lower" to "Lower ⅓"), when { y < .35 -> "top"; y < .62 -> "mid"; else -> "lower" },
                    { act(EditAction.CaptionY(when (it) { "top" -> .2; "mid" -> .5; else -> .72 })) })
            }
            val fillers = SuiteOps.words(p).count { it.kept && it.filler }
            if (fillers > 0) SuiteButton("Remove $fillers filler word${if (fillers == 1) "" else "s"}", { act(EditAction.RemoveFillers) }, Modifier.fillMaxWidth(), icon = "scissors")
            AiButton("Cut silences", ui.ai["silences"], { act(EditAction.CutSilences) }, icon = "scissors")
        }
    }
}

@Composable
private fun Swatch(hex: String, on: Boolean, onClick: () -> Unit) {
    val m = muse
    Box(Modifier.size(26.dp).border(if (on) 2.dp else 1.dp, if (on) m.t.accent else m.t.line).padding(3.dp).background(colorOf(hex)).press(onClick = onClick).semantics { contentDescription = hex })
}

/** Edit by text: the transcript, word-timed; tapping a word cuts it out of the video (fillers in red, cut words struck). */
@Composable
private fun WordsBody(ui: EditSuiteUi, p: EditProject, act: (EditAction) -> Unit) {
    val m = muse
    val words = SuiteOps.words(p)
    // Tap a word to cut it with the video, or (Fix text) to correct how it's spelled in the captions.
    var fixing by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<Int?>(null) }
    SuiteSeg(listOf("cut" to "Tap to cut", "fix" to "Tap to fix text"), if (fixing) "fix" else "cut", { fixing = it == "fix"; editing = null }, Modifier.fillMaxWidth(), height = 34.dp, fill = true)
    FlowRow(hGap = 6.dp, vGap = 6.dp) {
        words.forEach { w ->
            val color = when { !w.kept -> m.t.muted; w.filler -> m.t.accent; else -> m.t.ink }
            if (editing == w.index) {
                var text by remember(w.index) { mutableStateOf(w.text) }
                BasicTextField(text, { text = it }, Modifier.background(m.t.surface).border(1.dp, m.t.accent).padding(horizontal = 6.dp, vertical = 2.dp).semantics { contentDescription = "Word" },
                    textStyle = m.type.body.copy(color = m.t.ink, fontSize = 15.sp), cursorBrush = SolidColor(m.t.accent), singleLine = true,
                    keyboardActions = androidx.compose.foundation.text.KeyboardActions(onDone = { act(EditAction.CaptionWordText(w.index, text)); editing = null }),
                    keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(imeAction = androidx.compose.ui.text.input.ImeAction.Done))
            } else T(w.text, m.type.body.copy(fontSize = 15.sp, textDecoration = if (!w.kept || w.filler) TextDecoration.LineThrough.takeIf { !w.kept } else null), color,
                Modifier.press(enabled = w.kept) { if (fixing) editing = w.index else act(EditAction.DeleteWord(w.index)) }.padding(vertical = 2.dp))
        }
    }
    T(if (fixing) "Tap a word, type the fix, then Done on the keyboard." else "Red = filler words. Tap a word to cut it with the video (jump cut) · undo brings it back.", m.type.tiny.copy(fontSize = 12.sp), m.t.muted)
    val fillers = words.count { it.kept && it.filler }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (fillers > 0) SuiteButton("Remove $fillers filler${if (fillers == 1) "" else "s"}", { act(EditAction.RemoveFillers) }, Modifier.weight(1f), icon = "scissors", primary = true)
        AiButton("Cut silences", ui.ai["silences"], { act(EditAction.CutSilences) }, Modifier.weight(1f), icon = "scissors")
    }
}

// ======================================================================= Effects: transitions, mask & green screen (E2)
@Composable
private fun EffectsBody(ui: EditSuiteUi, host: SuiteHost, act: (EditAction) -> Unit) {
    val m = muse
    SuiteSeg(listOf("Transitions" to "Transitions", "Mask" to "Mask & key"), ui.effectsTab, { act(EditAction.EffectsTab(it)) }, Modifier.fillMaxWidth(), height = 34.dp, fill = true)
    if (ui.effectsTab == "Mask") return MaskBody(ui, host, act)
    val c = ui.activeClip
    val idx = ui.project?.mainClips?.indexOfFirst { it.id == c?.id } ?: -1
    val cur = c?.transitionIn
    val icons = mapOf("cut" to "scissors", "fade" to "xfade", "zoom" to "expand", "whip" to "whip", "slideLeft" to "chev-r", "white" to "sun", "glitch" to "fx", "spin" to "refresh")
    T(if (idx <= 0) "Pick the second clip or later: a transition plays into it" else "Into clip ${idx + 1}", m.type.body.copy(fontSize = 13.sp), m.t.muted)
    Presets.TRANSITION_LABELS.filter { it.first in icons }.chunked(4).forEach { row ->
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            row.forEach { (wire, label) ->
                val on = if (wire == "cut") cur == null else cur?.kind?.wire == wire
                ToolTile(icons.getValue(wire), label, on, { act(EditAction.SetTransition(Presets.transitionOf(wire), cur?.durationSec ?: .4)) }, Modifier.weight(1f))
            }
        }
    }
    SuiteChip("Dip to black", cur?.kind == TransitionKind.BLACK, { act(EditAction.SetTransition(TransitionKind.BLACK, cur?.durationSec ?: .4)) })
    val d = cur?.durationSec ?: .4
    SuiteSlider(((d - .1) / 1.9).toFloat(), { f, done -> cur?.let { act(EditAction.SetTransition(it.kind, r2(.1 + f * 1.9), done)) } }, label = "Duration", valueText = "${fmt1(d)} s", enabled = cur != null)
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        SuiteButton("Apply to all cuts", { act(EditAction.TransitionToAll) })
        T("Whip pans live here, not in the AI shot", m.type.tiny.copy(fontSize = 12.sp), m.t.muted, Modifier.weight(1f))
    }
}

@Composable
private fun MaskBody(ui: EditSuiteUi, host: SuiteHost, act: (EditAction) -> Unit) {
    val m = muse
    val p = ui.project ?: return
    val id = (ui.selection?.second?.takeIf { it is Visual } ?: ui.activeClip)?.id ?: return
    val v = p.tracks.flatMap { it.items }.firstOrNull { it.id == id } as? Visual ?: return
    // Tap to keep is on: only its controls, so they sit right under the picture being tapped.
    ui.keep?.let { k -> if (v is VideoClip) { SuiteLabel("Tap what to keep"); KeepPanel(ui, k, host, act); return } }
    // Mask keyframes: the mask at the playhead; ◆ keys a field there.
    val local = (v as? studio.muse.core.edit.Item)?.id?.let { iid -> p.locate(iid)?.let { (t, i) -> itemSpan(p, t, t.items[i]) } }
        ?.let { sp -> (ui.playheadSec - sp.startSec).takeIf { it >= -1e-6 && ui.playheadSec <= sp.endSec + 1e-6 } }
    val mask = if (local != null) studio.muse.core.edit.maskAt(v.mask, v.keyframes, local) else v.mask
    @Composable
    fun keyed(label: String, vararg props: KfProp, slider: @Composable (Modifier) -> Unit) = Row(verticalAlignment = Alignment.CenterVertically) {
        slider(Modifier.weight(1f))
        Spacer(Modifier.width(10.dp))
        val on = props.any { !v.keyframes?.get(it).isNullOrEmpty() }
        Box(Modifier.size(48.dp).press(enabled = local != null) { props.forEach { act(EditAction.AddKeyframe(it)) } }.semantics { contentDescription = "Keyframe $label" }, contentAlignment = Alignment.Center) {
            EIc(if (on) "diamond" else "keyframe", 14.dp, if (on) m.t.accent else m.t.muted)
        }
    }
    SuiteLabel("Mask")
    SuiteChips(listOf("none" to "None") + MaskShape.entries.map { it.wire to it.wire.replaceFirstChar(Char::uppercase) }, mask?.shape?.wire ?: "none", { w ->
        act(EditAction.SetMask(MaskShape.entries.firstOrNull { it.wire == w }?.let { s -> (mask ?: Mask(s)).copy(shape = s) }))
    })
    if (mask != null) {
        val f = mask.feather ?: .1
        keyed("Feather", KfProp.MASK_FEATHER) { md -> SuiteSlider(f.toFloat(), { x, done -> act(EditAction.SetMask(mask.copy(feather = r2(x.toDouble())), done)) }, md, label = "Feather", valueText = "${(f * 100).roundToInt()}") }
        val sz = mask.width ?: .5
        keyed("Size", KfProp.MASK_WIDTH, KfProp.MASK_HEIGHT) { md -> SuiteSlider(((sz - .1) / 1.4).toFloat(), { x, done -> val s = r2(.1 + x * 1.4); act(EditAction.SetMask(mask.copy(width = s, height = s * ((mask.height ?: .5) / (mask.width ?: .5))), done)) }, md, label = "Size", valueText = "${(sz * 100).roundToInt()}%") }
        val mx = mask.x ?: .5; val my = mask.y ?: .5; val mr = mask.rotation ?: 0.0
        keyed("Position x", KfProp.MASK_X) { md -> SuiteSlider(((mx + 1) / 3).toFloat(), { f, done -> act(EditAction.SetMask(mask.copy(x = r2(f * 3.0 - 1)), done)) }, md, label = "Position x", valueText = "${((mx - .5) * 200).roundToInt()}") }
        keyed("Position y", KfProp.MASK_Y) { md -> SuiteSlider(((my + 1) / 3).toFloat(), { f, done -> act(EditAction.SetMask(mask.copy(y = r2(f * 3.0 - 1)), done)) }, md, label = "Position y", valueText = "${((my - .5) * 200).roundToInt()}") }
        keyed("Rotation", KfProp.MASK_ROTATION) { md -> SuiteSlider(((mr + 180) / 360).toFloat(), { f, done -> act(EditAction.SetMask(mask.copy(rotation = (f * 360.0 - 180).roundToInt().toDouble()), done)) }, md, label = "Rotation", valueText = "${mr.roundToInt()}°") }
        OptRow("Invert", "Show outside the shape", mask.invert == true, { act(EditAction.SetMask(mask.copy(invert = if (mask.invert == true) null else true))) })
    }
    val clip = v as? VideoClip
    if (clip != null) {
        // Chroma key (green or blue screen): on/off, the key colour, how much around it goes, the edge and the spill.
        val ck = clip.chroma
        OptRow("Chroma key", if (ck == null) "Removes a green or blue screen" else "Removing ${if (ck.color.equals(BLUE_KEY, true)) "blue" else if (ck.color.equals(GREEN_KEY, true)) "green" else "a picked colour"}", ck != null, {
            act(EditAction.SetChroma(if (ck == null) studio.muse.core.edit.Chroma(GREEN_KEY, .4, .08, .5) else null))
        })
        if (ck != null) {
            SuiteSeg(listOf(GREEN_KEY to "Green screen", BLUE_KEY to "Blue screen"), if (ck.color.equals(BLUE_KEY, true)) BLUE_KEY else if (ck.color.equals(GREEN_KEY, true)) GREEN_KEY else null,
                { act(EditAction.SetChroma(ck.copy(color = it))) }, Modifier.fillMaxWidth(), height = 34.dp, fill = true)
            // The eyedropper (owner-approved 2026-11-09): touch the colour to remove on the paused picture.
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                val sw = runCatching { Color(android.graphics.Color.parseColor(ck.color)) }.getOrDefault(Color.Transparent)
                Box(Modifier.size(28.dp).background(sw).border(1.dp, m.t.line).semantics { contentDescription = "Key colour ${ck.color}" })
                T(ck.color.uppercase(), m.type.mono.copy(fontSize = 12.5.sp), m.t.ink, Modifier.weight(1f))
                val picking = ui.pick != null
                SuiteButton(if (picking) "Cancel" else "Pick from video", { act(EditAction.PickColor(!picking)) }, height = 34.dp, icon = if (picking) null else "drop", primary = picking)
            }
            if (ui.pick != null) T("Touch the colour to remove on the picture, then lift your finger.", m.type.tiny.copy(fontSize = 12.sp), m.t.muted)
            val sim = ck.similarity ?: .4; val sm = ck.smoothness ?: .08; val sp = ck.spill ?: .5
            SuiteSlider(sim.toFloat(), { f, done -> act(EditAction.SetChroma(ck.copy(similarity = f.toDouble()), done)) }, label = "Strength", valueText = "${(sim * 100).roundToInt()}")
            SuiteSlider(sm.toFloat(), { f, done -> act(EditAction.SetChroma(ck.copy(smoothness = f.toDouble()), done)) }, label = "Edge softness", valueText = "${(sm * 100).roundToInt()}")
            SuiteSlider(sp.toFloat(), { f, done -> act(EditAction.SetChroma(ck.copy(spill = f.toDouble()), done)) }, label = "Spill", valueText = "${(sp * 100).roundToInt()}")
        }
        // The cut-out isn't live yet (the server says so): both read "Coming soon", plainly, with nothing to press.
        val keyed = clip.alphaMatte != null
        // A clip already cut out keeps its toggle, so it can be turned off (WS3's contract; the Mac does the same).
        if (!keyed) ui.matteOff?.let { note ->
            ComingSoon("Remove background", note)
            ComingSoon("Tap what to keep", note)
            return
        }
        val matte = ui.ai["matte"]
        if (!keyed && ui.keep == null) host.modelRow?.invoke("matte")
        OptRow("Remove background", when { matte?.running == true -> "Cutting out · ${matte.progress} %"; keyed -> "Done · the background is gone"; else -> "The person stays · ${matte?.price ?: "priced next"}" },
            matte?.done == true || keyed, {
                when {
                    keyed -> act(EditAction.KeepBackground)
                    matte?.running != true && ui.keep == null -> act(EditAction.RemoveBackground)
                }
            })
        // Tap what to keep (workstream 1's tracked cut-out): a pet, a product, one of two people.
        val k = ui.keep
        if (ui.matteOff != null) ComingSoon("Tap what to keep", ui.matteOff)
        else if (k == null) {
            SuiteLink("Tap what to keep instead") { act(EditAction.TapToKeep(true)) }
        } else KeepPanel(ui, k, host, act)
    }
}

/** A helper that isn't available yet: its name and a plain line, greyed, not a button. */
@Composable
private fun ComingSoon(title: String, note: String) {
    val m = muse
    Column(Modifier.fillMaxWidth().semantics(mergeDescendants = true) { stateDescription = "Not available yet" }, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        T(title, m.type.body.copy(fontSize = 13.5.sp, fontWeight = FontWeight.Bold), m.t.muted)
        T(note, m.type.tiny.copy(fontSize = 12.sp), m.t.muted)
    }
}

// ======================================================================= Filters: looks + adjust (E2)
private val CATEGORIES = listOf("all" to "All", "natural" to "Natural", "film" to "Film", "moody" to "Moody", "warm" to "Warm", "cool" to "Cool", "bw" to "B&W", "vintage" to "Vintage", "cinematic" to "Cinematic")

@Composable
private fun FiltersBody(ui: EditSuiteUi, host: SuiteHost, act: (EditAction) -> Unit) {
    val m = muse
    SuiteSeg(listOf("Looks" to "Looks", "Adjust" to "Adjust"), ui.filtersTab, { act(EditAction.FiltersTab(it)) }, Modifier.fillMaxWidth(), height = 34.dp, fill = true)
    val p = ui.project ?: return
    val id = (ui.selection?.second?.takeIf { it is Visual } ?: ui.activeClip)?.id
    val v = id?.let { i -> p.tracks.flatMap { it.items }.firstOrNull { it.id == i } } as? Visual
    if (ui.filtersTab == "Adjust") {
        // Item-local playhead, for colour keyframes.
        val local = ui.project?.let { p -> (v as? studio.muse.core.edit.Item)?.id?.let { id -> p.locate(id)?.let { (t, i) -> itemSpan(p, t, t.items[i]) } } }
            ?.let { sp -> (ui.playheadSec - sp.startSec).takeIf { it >= -1e-6 && ui.playheadSec <= sp.endSec + 1e-6 } }
        return AdjustBody(v, host, act, local)
    }
    val look = v?.look
    val current = look?.lut?.removePrefix("pack:")
    androidx.compose.foundation.lazy.LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        items(CATEGORIES.size) { i -> val (k, l) = CATEGORIES[i]; SuiteChip(l, ui.lookCategory == k, { act(EditAction.LookCategory(k)) }) }
    }
    val shown = listOf(LookChoice("none", "Original", "all")) + ui.looks.filter { ui.lookCategory == "all" || it.category == ui.lookCategory }
    shown.chunked(3).forEach { row ->
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            row.forEach { l ->
                val on = if (l.id == "none") look?.lut == null else current == l.id
                Column(Modifier.weight(1f).press { act(EditAction.PickLook(l.id.takeIf { it != "none" }, null)) }.semantics { contentDescription = l.name }, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Box(Modifier.fillMaxWidth().aspectRatio(1.5f).background(m.t.surface2).border(if (on) 2.dp else 0.dp, if (on) m.t.ink else Color.Transparent)) {
                        val bmp = host.lookThumbs[l.id]
                        if (bmp != null) Image(bmp, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                        else Box(Modifier.fillMaxSize().background(Brush.linearGradient(lookSwatch(l))))
                    }
                    T(l.name, m.type.tiny.copy(fontSize = 11.5.sp), if (on) m.t.ink else m.t.muted, maxLines = 1)
                }
            }
            repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
        }
    }
    // A suite look (generated from a palette or film stock) isn't in the picker: show it as the current look, with a way
    // to remove it (picking any look above swaps it; the intensity slider below works on it like on any look).
    look?.paletteId?.let { pid ->
        val name = "Suite look · ${ui.suiteLooks[pid] ?: pid}"
        Row(
            Modifier.fillMaxWidth().background(m.t.surface2).border(2.dp, m.t.ink).padding(10.dp).semantics { contentDescription = "Current look: $name" },
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Column(Modifier.weight(1f)) {
                T("Current look", m.type.tiny.copy(fontSize = 11.5.sp), m.t.muted, maxLines = 1)
                T(name, m.type.body.copy(fontSize = 13.5.sp, fontWeight = FontWeight.Bold), m.t.ink, maxLines = 1)
            }
            SuiteButton("Remove", { act(EditAction.PickLook(null, null)) }, height = 34.dp)
        }
    }
    val strength = look?.strength ?: 1.0
    SuiteSlider(strength.toFloat(), { f, done -> act(EditAction.LookStrength(f.toDouble(), done)) }, label = "Intensity", valueText = "${(strength * 100).roundToInt()}%", enabled = look != null)
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        SuiteButton(".cube import", host.importCube, Modifier.weight(1f), icon = "upload")
        SuiteButton("Apply to all clips", { act(EditAction.LookToAll) }, Modifier.weight(1f), enabled = look != null)
    }
    ui.cubeNote?.let { T(it, m.type.tiny.copy(fontSize = 12.sp), m.t.muted) }
    T("Same looks as the Camera bag palettes", m.type.tiny.copy(fontSize = 12.sp), m.t.muted)
}

/** A stand-in swatch per category while thumbnails render. */
private fun lookSwatch(l: LookChoice): List<Color> = when (l.category) {
    "film" -> listOf(Color(0xFF6B5A3E), Color(0xFFD9B98A)); "moody" -> listOf(Color(0xFF1F2B2E), Color(0xFF51666B)); "warm" -> listOf(Color(0xFF8A4B22), Color(0xFFF2B36B))
    "cool" -> listOf(Color(0xFF243A57), Color(0xFF9CC3E0)); "bw" -> listOf(Color(0xFF222222), Color(0xFFBBBBBB)); "vintage" -> listOf(Color(0xFF6E5A4A), Color(0xFFE3C9A8))
    "cinematic" -> listOf(Color(0xFF15343B), Color(0xFFE09A55)); else -> listOf(Color(0xFF4A4A44), Color(0xFFD8D2C4))
}

@Composable
private fun AdjustBody(v: Visual?, host: SuiteHost, act: (EditAction) -> Unit, local: Double? = null) {
    val m = muse
    val a = v?.adjust
    SuiteButton("Auto adjust", host.autoAdjust, Modifier.fillMaxWidth(), icon = "sliders", enabled = v != null)
    @Composable
    fun row(label: String, field: String, static: Double) {
        // A colour field with keyframes shows (and sets) its value at the playhead; ◆ adds a key there.
        val kp = (KfProp.COLOR + KfProp.LOOK).firstOrNull { it.wire == field }
        val keys = kp?.let { v?.keyframes?.get(it) }
        val value = if (!keys.isNullOrEmpty() && local != null) studio.muse.core.edit.keyframeValue(keys, local) else static
        val n = (value * 100).roundToInt()
        Row(verticalAlignment = Alignment.CenterVertically) {
            SuiteSlider(((value + 1) / 2).toFloat(), { f, done -> act(EditAction.AdjustField(field, f * 2.0 - 1, done)) }, Modifier.weight(1f), label = label, valueText = signed(n), enabled = v != null)
            if (kp != null) {
                Spacer(Modifier.width(10.dp))
                Box(Modifier.size(48.dp).press(enabled = v != null && local != null) { act(EditAction.AddKeyframe(kp)) }.semantics { contentDescription = "Keyframe $label" }, contentAlignment = Alignment.Center) {
                    EIc(if (keys.isNullOrEmpty()) "keyframe" else "diamond", 14.dp, if (keys.isNullOrEmpty()) m.t.muted else m.t.accent)
                }
            }
        }
    }
    row("Exposure", "exposure", a?.exposure ?: 0.0)
    row("Contrast", "contrast", a?.contrast ?: 0.0)
    row("Saturation", "saturation", a?.saturation ?: 0.0)
    row("Temperature", "temperature", a?.temperature ?: 0.0)
    row("Tint", "tint", a?.tint ?: 0.0)
    row("Highlights", "highlights", a?.highlights ?: 0.0)
    row("Shadows", "shadows", a?.shadows ?: 0.0)
    // The look's effects (0 = off).
    val lk = v?.look
    @Composable
    fun eff(label: String, field: String, static: Double) {
        // Grain and light leak take keyframes (their amount over time), like the colour rows.
        val kp = KfProp.LOOK.firstOrNull { it.wire == field }
        val keys = kp?.let { v?.keyframes?.get(it) }
        val value = if (!keys.isNullOrEmpty() && local != null) studio.muse.core.edit.keyframeValue(keys, local) else static
        Row(verticalAlignment = Alignment.CenterVertically) {
            SuiteSlider(value.toFloat(), { f, done -> act(EditAction.AdjustField(field, f.toDouble(), done)) }, Modifier.weight(1f), label = label, valueText = "${(value * 100).roundToInt()}", enabled = v != null)
            if (kp != null) {
                Spacer(Modifier.width(10.dp))
                Box(Modifier.size(48.dp).press(enabled = v != null && local != null) { act(EditAction.AddKeyframe(kp)) }.semantics { contentDescription = "Keyframe $label" }, contentAlignment = Alignment.Center) {
                    EIc(if (keys.isNullOrEmpty()) "keyframe" else "diamond", 14.dp, if (keys.isNullOrEmpty()) m.t.muted else m.t.accent)
                }
            }
        }
    }
    eff("Grain", "grain", lk?.grain?.amount ?: 0.0)
    row("Vignette", "vignette", lk?.vignette?.amount ?: 0.0)
    eff("Sharpen", "sharpen", lk?.sharpen ?: 0.0)
    eff("Fade", "fade", lk?.lift ?: 0.0)
    eff("Glow", "halation", lk?.halation?.amount ?: 0.0)
    eff("Light leak", "leak", lk?.leak?.amount ?: 0.0)
    eff("Colour fringe", "chromatic", lk?.chromatic ?: 0.0)
    CurvesEditor(lk?.curves, v != null, act)
}

// ======================================================================= Overlay (PiP) and clips
@Composable
private fun OverlayBody(ui: EditSuiteUi, host: SuiteHost, act: (EditAction) -> Unit) {
    val m = muse
    T("Your takes and edited versions. Add one to the end of the video, or over it as an overlay at the playhead.", m.type.body.copy(fontSize = 13.sp), m.t.muted)
    if (ui.takes.isEmpty()) T("No other videos yet", m.type.body, m.t.muted)
    ui.takes.forEach { t ->
        // Name and length on top, the four actions under them (four buttons beside the name crushed it on phones).
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.size(40.dp, 56.dp).clip(RoundedCornerShape(2.dp)).background(m.t.surface2)) { RefImage(t.thumb, Modifier.fillMaxSize()) }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                T(t.title, m.type.body.copy(fontSize = 13.5.sp, fontWeight = FontWeight.Bold), m.t.ink, maxLines = 1)
                T(listOfNotNull(t.label, t.durationSec?.let { "${fmt1(it)} s" }).joinToString(" · "), m.type.tiny.copy(fontSize = 12.sp), m.t.muted, maxLines = 1)
                androidx.compose.foundation.layout.FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    SuiteButton("Add to end", { act(EditAction.AppendTake(t)) }, height = 34.dp, enabled = t.hasVideo)
                    SuiteButton("Overlay", { act(EditAction.AddPip(t)) }, height = 34.dp, icon = "layers", enabled = t.hasVideo)
                    SuiteButton("Replace", { act(EditAction.ReplaceClip(t)) }, height = 34.dp, enabled = t.hasVideo)
                    SuiteButton("Sound", { act(EditAction.AddTakeSound(t)) }, height = 34.dp, enabled = t.hasVideo)
                }
            }
        }
    }
    // Split screen: the clips on screen at the playhead, arranged.
    val onScreen = ui.project?.let { SuiteOps.clipsAt(it, ui.playheadSec).size } ?: 0
    SuiteLabel("Split screen")
    T(if (onScreen < 2) "Add an overlay at the playhead, then pick a layout." else "Arranges the $onScreen clips on screen at the playhead.", m.type.tiny.copy(fontSize = 12.sp), m.t.muted)
    SuiteChips(SuiteOps.SplitLayout.entries.map { it.name to it.label }, null, { n -> act(EditAction.SplitScreen(SuiteOps.SplitLayout.valueOf(n))) }, enabled = onScreen >= 2)
    host.importLink?.let { SuiteButton("Add a video from a link", it, Modifier.fillMaxWidth(), icon = "link") }
    host.addPhoto?.let { SuiteButton("Add a photo", it, Modifier.fillMaxWidth(), icon = "image") }
    SuiteButton("Music from uploads", host.pickAudio, Modifier.fillMaxWidth(), icon = "music")
}

// ======================================================================= Ratio and export (EM5, E4)
@Composable
private fun ShapeTiles(selected: ExportShape, onPick: (ExportShape) -> Unit) {
    val m = muse
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        ExportShape.entries.forEach { s ->
            val on = s == selected
            Column(
                Modifier.weight(1f).height(76.dp).background(if (on) m.t.surface2 else m.t.surface).border(1.dp, if (on) m.t.ink else m.t.line).press { onPick(s) }
                    .semantics { contentDescription = "Shape ${s.label}" },
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
            ) {
                // The shape inside a 34 × 34 box.
                val r = s.w.toFloat() / s.h
                val (w, h) = if (r >= 1f) 34f to 34f / r else 34f * r to 34f
                Box(Modifier.size(w.dp, h.dp).border(2.dp, m.t.ink).background(if (on) m.t.ink else Color.Transparent))
                Spacer(Modifier.height(6.dp))
                T(s.label, m.type.mono.copy(fontSize = 12.sp), m.t.ink)
            }
        }
    }
}

@Composable
private fun RatioBody(ui: EditSuiteUi, act: (EditAction) -> Unit) {
    val m = muse
    val p = ui.project ?: return
    ShapeTiles(ExportShape.of(p.canvas.width, p.canvas.height)) { act(EditAction.Ratio(it)) }
    T("Changing shape re-frames each clip to keep it centred. Captions move with the safe area.", m.type.tiny.copy(fontSize = 12.sp), m.t.muted)
    SuiteLabel("Background")
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        listOf("#000000", "#FFFFFF", "#1B1916", "#F2EDE4", "#0E3B2E", "#3A2A5A", "#B4483A").forEach { c ->
            Swatch(c, (p.canvas.background ?: "#000000").equals(c, true)) { act(EditAction.Background(c)) }
        }
    }
    SuiteSeg(listOf("color" to "Colour", "blur" to "Blur of the clip"), if (p.canvas.fill == studio.muse.core.edit.CanvasFill.BLUR) "blur" else "color",
        { act(EditAction.Fill(if (it == "blur") studio.muse.core.edit.CanvasFill.BLUR else studio.muse.core.edit.CanvasFill.COLOR)) }, Modifier.fillMaxWidth(), height = 34.dp, fill = true)
    T("Shows where the picture doesn't fill the frame", m.type.tiny.copy(fontSize = 12.sp), m.t.muted)
    val clip = (ui.selection?.second as? VideoClip)?.takeIf { s -> p.main.items.any { it.id == s.id } } ?: ui.activeClip
    if (clip != null) {
        SuiteLabel("This clip")
        SuiteSeg(listOf("cover" to "Fill the frame", "contain" to "Whole picture"), if (clip.fit == studio.muse.core.edit.Fit.CONTAIN) "contain" else "cover",
            { act(EditAction.ClipFit(if (it == "contain") studio.muse.core.edit.Fit.CONTAIN else studio.muse.core.edit.Fit.COVER)) }, Modifier.fillMaxWidth(), height = 34.dp, fill = true)
    }
}

@Composable
private fun ExportBody(ui: EditSuiteUi, host: SuiteHost, act: (EditAction) -> Unit) {
    val m = muse
    val s = ui.export
    fun set(n: ExportSettings) = act(EditAction.ExportOf(n))
    SuiteSeg(ExportFormat.entries.map { it.name to it.label }, s.format.name, { set(s.copy(format = ExportFormat.valueOf(it))) }, Modifier.fillMaxWidth(), fill = true)
    if (s.format != ExportFormat.SOUND) ShapeTiles(s.shape) { set(s.copy(shape = it)) }
    when (s.format) {
        ExportFormat.VIDEO -> {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    SuiteLabel("Resolution")
                    SuiteSeg(ExportResolution.entries.map { it.name to it.label }, s.resolution.name, { set(s.copy(resolution = ExportResolution.valueOf(it))) }, Modifier.fillMaxWidth(), fill = true)
                }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    SuiteLabel("FPS")
                    SuiteSeg(ExportSettings.FPS.map { it.toString() to it.toString() }, s.fps.toString(), { set(s.copy(fps = it.toInt())) }, Modifier.fillMaxWidth(), fill = true)
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    SuiteLabel("Codec")
                    SuiteSeg(listOf(ExportCodec.H264.name to "H.264", ExportCodec.HEVC.name to "HEVC"), s.codec.name, { set(s.copy(codec = ExportCodec.valueOf(it))) }, Modifier.fillMaxWidth(), fill = true)
                }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    SuiteLabel("Captions")
                    SuiteSeg(listOf(CaptionExport.BURN_IN.name to "Burn in", CaptionExport.SRT.name to ".SRT file"), s.captions.name, { set(s.copy(captions = CaptionExport.valueOf(it))) }, Modifier.fillMaxWidth(), fill = true)
                }
            }
            SuiteLabel("Bitrate")
            SuiteSeg(ExportBitrate.entries.map { it.name to it.label }, s.bitrate.name, { set(s.copy(bitrate = ExportBitrate.valueOf(it))) }, Modifier.fillMaxWidth(), fill = true)
            OptRow("Label as AI-generated", "Your choice, per export", s.aiLabel, { set(s.copy(aiLabel = !s.aiLabel)) })
        }
        ExportFormat.GIF -> T("Loops, $GIF_FPS frames a second, $GIF_SHORT_SIDE\u00A0px on the short side. Up to ${GIF_MAX_SEC.roundToInt()}\u00A0s; captions are burned in.", m.type.body.copy(fontSize = 13.sp), m.t.muted)
        ExportFormat.SOUND -> T("The edit's mix on its own, as an .m4a file (AAC, ${SOUND_BITRATE / 1000}\u00A0kbit/s).", m.type.body.copy(fontSize = 13.sp), m.t.muted)
    }
    val (w, h) = s.size
    val d = ui.duration
    Row(verticalAlignment = Alignment.CenterVertically) {
        val len = "${(d / 60).toInt()}:${"%02d".format((d % 60).roundToInt().coerceAtMost(59))}"
        T(if (s.format == ExportFormat.SOUND) "$len · AAC" else "$len · ${w} × $h · ${s.outFps} fps", m.type.body.copy(fontSize = 13.sp), m.t.ink, Modifier.weight(1f))
        T("≈ ${formatBytes(s.estimatedBytes(d))}", m.type.mono.copy(fontSize = 12.5.sp), m.t.ink)
    }
    val refusal = ui.project?.let { s.refusal(d, SuiteOps.editHasSound(it)) }
    when (val ph = ui.phase) {
        is SuitePhase.Exporting, is SuitePhase.Saving -> {
            val making = when (s.format) { ExportFormat.VIDEO -> "Making your video on this phone"; ExportFormat.SOUND -> "Making the sound file"; ExportFormat.GIF -> "Making the GIF" }
            val (label, prog) = if (ph is SuitePhase.Exporting) making to ph.progress else (if (s.format == ExportFormat.VIDEO) "Saving to Library" else "Saving to this phone") to (ph as SuitePhase.Saving).progress
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    T("$label · ${(prog * 100).roundToInt()} %", m.type.body.copy(fontSize = 13.sp), m.t.ink, Modifier.weight(1f))
                    SuiteButton("Cancel", host.cancelExport, height = 34.dp)
                }
                Box(Modifier.fillMaxWidth().height(4.dp).background(m.t.surface2)) { Box(Modifier.fillMaxWidth(prog.coerceIn(0f, 1f)).height(4.dp).background(m.t.accent)) }
            }
        }
        else -> {
            if (refusal != null) T(refusal, m.type.tiny.copy(fontSize = 12.sp), m.t.warn)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (s.format == ExportFormat.VIDEO) {
                    SuiteButton("Save to Library", { host.export(false) }, height = 54.dp, enabled = ui.ready)
                    SuiteButton("Export", { host.export(true) }, Modifier.weight(1f), primary = true, height = 54.dp, enabled = ui.ready)
                } else SuiteButton(if (s.format == ExportFormat.SOUND) "Save sound to phone" else "Save GIF to phone", { host.export(true) }, Modifier.weight(1f), primary = true, height = 54.dp,
                    enabled = ui.ready && refusal == null)
            }
        }
    }
    if (ui.phase is SuitePhase.Failed) T((ui.phase as SuitePhase.Failed).message, m.type.tiny.copy(fontSize = 12.sp), m.t.warn)
}



/**
 * Tap to keep (workstream 1, plans/api.md "KeepPoint"): tap the paused picture on what to keep, switch to "Leave out" for
 * what to drop (1–10 taps, at least one keep). The run's price is on its button: one run per press.
 */
@Composable
private fun KeepPanel(ui: EditSuiteUi, k: KeepUi, host: SuiteHost, act: (EditAction) -> Unit) {
    val m = muse
    val task = ui.ai["matte_keep"]
    T("Pause on a frame, then tap what to keep. Switch to Leave out and tap anything that should go.", m.scale.caption, m.t.muted)
    SuiteSeg(listOf("keep" to "Keep", "out" to "Leave out"), if (k.keepNext) "keep" else "out", { act(EditAction.KeepNext(it == "keep")) }, Modifier.fillMaxWidth(), height = 34.dp, fill = true)
    Row(verticalAlignment = Alignment.CenterVertically) {
        val keeps = k.taps.count { it.keep }; val outs = k.taps.size - keeps
        T(if (k.taps.isEmpty()) "No taps yet" else listOfNotNull("$keeps to keep", outs.takeIf { it > 0 }?.let { "$it to leave out" }).joinToString(" · "),
            m.scale.label, m.t.ink, Modifier.weight(1f), maxLines = 1)
        if (k.taps.isNotEmpty()) SuiteLink("Undo tap") { act(EditAction.UndoKeepTap) }
    }
    task?.error?.let { T(it, m.scale.caption, m.t.warn) }
    val label = when {
        task?.running == true -> "Cutting out · ${task.progress} %"
        !k.ready -> "Tap something to keep"
        else -> "Cut out" + (task?.price?.let { " · $it" } ?: "")
    }
    host.modelRow?.invoke("track")
    SuiteButton(label, { act(EditAction.RunTapToKeep) }, Modifier.fillMaxWidth(), primary = true, enabled = k.ready && task?.running != true && task?.price != null)
    SuiteLink("Cancel") { act(EditAction.TapToKeep(false)) }
}

/** A quiet text action (sentence case, the link colour), 48 dp tall. */
@Composable
internal fun SuiteLink(text: String, onClick: () -> Unit) {
    val m = muse
    Box(Modifier.heightIn(min = 48.dp).press(onClick = onClick).semantics { role = androidx.compose.ui.semantics.Role.Button }, contentAlignment = Alignment.CenterStart) {
        T(text, m.scale.label, m.roles.link, maxLines = 1)
    }
}

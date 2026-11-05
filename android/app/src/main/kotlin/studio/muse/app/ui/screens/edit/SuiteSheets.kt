package studio.muse.app.ui.screens.edit

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
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
import studio.muse.app.ui.theme.muse
import studio.muse.core.edit.CaptionExport
import studio.muse.core.edit.CaptionPreset
import studio.muse.core.edit.EditProject
import studio.muse.core.edit.ExportCodec
import studio.muse.core.edit.ExportResolution
import studio.muse.core.edit.ExportSettings
import studio.muse.core.edit.ExportShape
import studio.muse.core.edit.Font
import studio.muse.core.edit.KfProp
import studio.muse.core.edit.Mask
import studio.muse.core.edit.MaskShape
import studio.muse.core.edit.MediaClip
import studio.muse.core.edit.Presets
import studio.muse.core.edit.SpeedPreset
import studio.muse.core.edit.TextItem
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
)

/** The open panel as a bottom sheet. */
@Composable
fun SuiteSheet(ui: EditSuiteUi, panel: Panel, host: SuiteHost, act: (EditAction) -> Unit, modifier: Modifier = Modifier) {
    val close = { act(EditAction.Open(null)) }
    val back = { act(EditAction.Open(Panel.EDIT)) }
    SheetFrame(panel.title, if (panel == Panel.SPEED || panel == Panel.TRANSFORM) back else close, modifier) {
        when (panel) {
            Panel.EDIT -> EditBody(ui, act)
            Panel.SPEED -> SpeedBody(ui, act)
            Panel.TRANSFORM -> TransformBody(ui, act)
            Panel.AUDIO -> AudioBody(ui, host, act)
            Panel.TEXT -> TextBody(ui, act)
            Panel.CAPTIONS -> CaptionsBody(ui, act)
            Panel.EFFECTS -> EffectsBody(ui, act)
            Panel.FILTERS -> FiltersBody(ui, host, act)
            Panel.OVERLAY -> OverlayBody(ui, host, act)
            Panel.RATIO -> RatioBody(ui, act)
            Panel.EXPORT -> ExportBody(ui, host, act)
        }
    }
}

private fun fmt1(v: Double) = String.format(java.util.Locale.ROOT, "%.1f", v)
private fun signed(v: Int) = if (v > 0) "+$v" else if (v < 0) "−${-v}" else "0"

// ======================================================================= Edit
@Composable
private fun EditBody(ui: EditSuiteUi, act: (EditAction) -> Unit) {
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
    OptRow("Ripple", "Deleting closes the gap on that track", ui.ripple, { act(EditAction.Ripple(!ui.ripple)) })
    OptRow("Snap cuts to beats", if (ui.project?.let { SuiteOps.beatTimes(it, false).isNotEmpty() } == true) "Split lands on the nearest beat" else "Detect beats in Audio first", ui.snapToBeats,
        { act(EditAction.SnapToBeats(!ui.snapToBeats)) })
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
        T("${fmt1(c.outSec - c.inSec)} s → ${fmt1(clipLength(c))} s · pitch kept", m.type.body.copy(fontSize = 13.sp), m.t.ink)
    }
    OptRow("Smooth slow-mo", "Fills in frames (AI) · Coming soon", false, {}, trailing = { Box(Modifier.semantics { contentDescription = "Coming soon" }) { Toggle(false, {}, Modifier) } })
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
    val x = tr.x ?: .5; val y = tr.y ?: .5; val sc = tr.scale ?: 1.0; val rot = tr.rotation ?: 0.0
    line("Position x", KfProp.X, "${((x - .5) * 200).roundToInt()}", ((x + .5) / 2).toFloat()) { f -> tr.copy(x = r2(f * 2.0 - .5)) }
    line("Position y", KfProp.Y, "${((y - .5) * 200).roundToInt()}", ((y + .5) / 2).toFloat()) { f -> tr.copy(y = r2(f * 2.0 - .5)) }
    line("Scale", KfProp.SCALE, "${(sc * 100).roundToInt()}%", ((sc - .1) / 2.9).toFloat()) { f -> tr.copy(scale = r2(.1 + f * 2.9)) }
    line("Rotation", KfProp.ROTATION, "${rot.roundToInt()}°", ((rot + 180) / 360).toFloat()) { f -> tr.copy(rotation = (f * 360.0 - 180).roundToInt().toDouble()) }
    T("◆ adds a keyframe at the playhead", m.type.tiny.copy(fontSize = 12.sp), m.t.muted)
}

private fun r2(v: Double) = Math.round(v * 100) / 100.0

// ======================================================================= Audio (EM3)
@Composable
private fun AudioBody(ui: EditSuiteUi, host: SuiteHost, act: (EditAction) -> Unit) {
    val m = muse
    val p = ui.project ?: return
    val clip = SuiteOps.soundClip(p, ui.selectedId, ui.activeClip)
    val music = SuiteOps.musicTrack(p)
    val name = if (clip is VideoClip) "voice" else "clip"
    val gain = clip?.let { if (it.muted == true) 0.0 else it.volume ?: 1.0 } ?: 1.0
    val db = SuiteOps.gainToDb(gain).coerceIn(-24.0, 6.0)
    SuiteSlider(((db + 24) / 30).toFloat(), { f, done -> act(EditAction.Volume(f * 30.0 - 24, done)) }, label = "Volume · $name",
        valueText = if (gain <= 0) "Muted" else "${if (db < -0.05) "−" else if (db > 0.05) "+" else ""}${fmt1(kotlin.math.abs(db)).removeSuffix(".0")} dB")
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
    OptRow(
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
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        SuiteButton("Music from uploads", host.pickAudio, Modifier.weight(1f), icon = "music")
        SuiteButton("Record VO", host.recordVo, Modifier.weight(1f), icon = "mic")
    }
}

private fun r1(v: Double) = Math.round(v * 10) / 10.0

// ======================================================================= Text & hooks (E3)
@Composable
private fun TextBody(ui: EditSuiteUi, act: (EditAction) -> Unit) {
    val m = muse
    val sel = ui.selection?.second as? TextItem
    if (sel != null) {
        SuiteLabel("Text")
        var text by remember(sel.id) { mutableStateOf(sel.text) }
        BasicTextField(
            text, { text = it; act(EditAction.EditText(sel.id, it)) },
            Modifier.fillMaxWidth().background(m.t.surface).border(1.dp, m.t.line).padding(12.dp),
            textStyle = m.type.body.copy(color = m.t.ink), cursorBrush = SolidColor(m.t.accent),
        )
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

// ======================================================================= Captions (EM2, E3)
@Composable
private fun CaptionsBody(ui: EditSuiteUi, act: (EditAction) -> Unit) {
    val m = muse
    val p = ui.project ?: return
    val ct = ui.captionTrack?.caption
    if (ct == null) {
        T("Word-timed captions from the speech, in the style you pick.", m.type.body.copy(fontSize = 13.5.sp), m.t.muted)
        AiButton("Auto-captions", ui.ai["captions"], { act(EditAction.AutoCaptions) }, icon = "cc")
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
    FlowRow(hGap = 6.dp, vGap = 6.dp) {
        words.forEach { w ->
            val color = when { !w.kept -> m.t.muted; w.filler -> m.t.accent; else -> m.t.ink }
            T(w.text, m.type.body.copy(fontSize = 15.sp, textDecoration = if (!w.kept || w.filler) TextDecoration.LineThrough.takeIf { !w.kept } else null), color,
                Modifier.press(enabled = w.kept) { act(EditAction.DeleteWord(w.index)) }.padding(vertical = 2.dp))
        }
    }
    T("Red = filler words. Tap a word to cut it with the video (jump cut) · undo brings it back.", m.type.tiny.copy(fontSize = 12.sp), m.t.muted)
    val fillers = words.count { it.kept && it.filler }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (fillers > 0) SuiteButton("Remove $fillers filler${if (fillers == 1) "" else "s"}", { act(EditAction.RemoveFillers) }, Modifier.weight(1f), icon = "scissors", primary = true)
        AiButton("Cut silences", ui.ai["silences"], { act(EditAction.CutSilences) }, Modifier.weight(1f), icon = "scissors")
    }
}

// ======================================================================= Effects: transitions, mask & green screen (E2)
@Composable
private fun EffectsBody(ui: EditSuiteUi, act: (EditAction) -> Unit) {
    val m = muse
    SuiteSeg(listOf("Transitions" to "Transitions", "Mask" to "Mask & key"), ui.effectsTab, { act(EditAction.EffectsTab(it)) }, Modifier.fillMaxWidth(), height = 34.dp, fill = true)
    if (ui.effectsTab == "Mask") return MaskBody(ui, act)
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
private fun MaskBody(ui: EditSuiteUi, act: (EditAction) -> Unit) {
    val m = muse
    val p = ui.project ?: return
    val id = (ui.selection?.second?.takeIf { it is Visual } ?: ui.activeClip)?.id ?: return
    val v = p.tracks.flatMap { it.items }.firstOrNull { it.id == id } as? Visual ?: return
    val mask = v.mask
    SuiteLabel("Mask")
    SuiteChips(listOf("none" to "None") + MaskShape.entries.map { it.wire to it.wire.replaceFirstChar(Char::uppercase) }, mask?.shape?.wire ?: "none", { w ->
        act(EditAction.SetMask(MaskShape.entries.firstOrNull { it.wire == w }?.let { s -> (mask ?: Mask(s)).copy(shape = s) }))
    })
    if (mask != null) {
        val f = mask.feather ?: .1
        SuiteSlider(f.toFloat(), { x, done -> act(EditAction.SetMask(mask.copy(feather = r2(x.toDouble())), done)) }, label = "Feather", valueText = "${(f * 100).roundToInt()}")
        val sz = mask.width ?: .5
        SuiteSlider(((sz - .1) / 1.4).toFloat(), { x, done -> val s = r2(.1 + x * 1.4); act(EditAction.SetMask(mask.copy(width = s, height = s * ((mask.height ?: .5) / (mask.width ?: .5))), done)) }, label = "Size", valueText = "${(sz * 100).roundToInt()}%")
        OptRow("Invert", "Show outside the shape", mask.invert == true, { act(EditAction.SetMask(mask.copy(invert = if (mask.invert == true) null else true))) })
    }
    val clip = v as? VideoClip
    if (clip != null) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            SuiteLabel("Chroma key", Modifier.weight(1f))
            Box(Modifier.size(20.dp).background(colorOf(clip.chroma?.color ?: "#2BD15F")))
            T(clip.chroma?.color ?: "Off", m.type.mono.copy(fontSize = 12.sp), m.t.muted)
        }
        val matte = ui.ai["matte"]
        OptRow("Remove background", when { matte?.running == true -> "Cutting out · ${matte.progress} %"; else -> "No green screen needed · ${matte?.price ?: "AI"}" }, matte?.done == true,
            { if (matte?.done != true) act(EditAction.RemoveBackground) })
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
    if (ui.filtersTab == "Adjust") return AdjustBody(v, act)
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
private fun AdjustBody(v: Visual?, act: (EditAction) -> Unit) {
    val a = v?.adjust
    @Composable
    fun row(label: String, field: String, value: Double) {
        val n = (value * 100).roundToInt()
        SuiteSlider(((value + 1) / 2).toFloat(), { f, done -> act(EditAction.AdjustField(field, f * 2.0 - 1, done)) }, label = label, valueText = signed(n), enabled = v != null)
    }
    row("Exposure", "exposure", a?.exposure ?: 0.0)
    row("Contrast", "contrast", a?.contrast ?: 0.0)
    row("Saturation", "saturation", a?.saturation ?: 0.0)
    row("Temperature", "temperature", a?.temperature ?: 0.0)
    row("Highlights", "highlights", a?.highlights ?: 0.0)
    row("Shadows", "shadows", a?.shadows ?: 0.0)
    val g = v?.look?.grain?.amount ?: 0.0
    SuiteSlider(g.toFloat(), { f, done -> act(EditAction.AdjustField("grain", f.toDouble(), done)) }, label = "Grain", valueText = "${(g * 100).roundToInt()}", enabled = v != null)
}

// ======================================================================= Overlay (PiP) and clips
@Composable
private fun OverlayBody(ui: EditSuiteUi, host: SuiteHost, act: (EditAction) -> Unit) {
    val m = muse
    T("Your takes and edited versions. Add one to the end of the video, or over it as picture-in-picture.", m.type.body.copy(fontSize = 13.sp), m.t.muted)
    if (ui.takes.isEmpty()) T("No other videos yet", m.type.body, m.t.muted)
    ui.takes.forEach { t ->
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.size(40.dp, 56.dp).clip(RoundedCornerShape(2.dp)).background(m.t.surface2)) { RefImage(t.thumb, Modifier.fillMaxSize()) }
            Column(Modifier.weight(1f)) {
                T(t.title, m.type.body.copy(fontSize = 13.5.sp, fontWeight = FontWeight.Bold), m.t.ink, maxLines = 1)
                T(listOfNotNull(t.label, t.durationSec?.let { "${fmt1(it)} s" }).joinToString(" · "), m.type.tiny.copy(fontSize = 12.sp), m.t.muted, maxLines = 1)
            }
            SuiteButton("PiP", { act(EditAction.AddPip(t)) }, height = 34.dp, icon = "layers")
        }
    }
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
                val (w, h) = when (s) { ExportShape.PORTRAIT -> 20 to 36; ExportShape.SQUARE -> 30 to 30; ExportShape.FOUR_FIVE -> 27 to 34; ExportShape.LANDSCAPE -> 38 to 22 }
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
}

@Composable
private fun ExportBody(ui: EditSuiteUi, host: SuiteHost, act: (EditAction) -> Unit) {
    val m = muse
    val s = ui.export
    fun set(n: ExportSettings) = act(EditAction.ExportOf(n))
    ShapeTiles(s.shape) { set(s.copy(shape = it)) }
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
            SuiteLabel("Format")
            SuiteSeg(listOf(ExportCodec.H264.name to "H.264", ExportCodec.HEVC.name to "HEVC"), s.codec.name, { set(s.copy(codec = ExportCodec.valueOf(it))) }, Modifier.fillMaxWidth(), fill = true)
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            SuiteLabel("Captions")
            SuiteSeg(listOf(CaptionExport.BURN_IN.name to "Burn in", CaptionExport.SRT.name to ".SRT file"), s.captions.name, { set(s.copy(captions = CaptionExport.valueOf(it))) }, Modifier.fillMaxWidth(), fill = true)
        }
    }
    OptRow("Label as AI-generated", "Your choice, per export", s.aiLabel, { set(s.copy(aiLabel = !s.aiLabel)) })
    OptRow("Content Credentials (C2PA)", if (s.contentCredentials) "Coming soon · not added to this file yet" else "Signed provenance in the file", s.contentCredentials, { set(s.copy(contentCredentials = !s.contentCredentials)) })
    val (w, h) = s.size
    Row(verticalAlignment = Alignment.CenterVertically) {
        val d = ui.duration
        T("${(d / 60).toInt()}:${"%02d".format((d % 60).roundToInt().coerceAtMost(59))} · ${w} × $h · ${s.fps} fps", m.type.body.copy(fontSize = 13.sp), m.t.ink, Modifier.weight(1f))
        T("≈ ${formatBytes(s.estimatedBytes(d))}", m.type.mono.copy(fontSize = 12.5.sp), m.t.ink)
    }
    when (val ph = ui.phase) {
        is SuitePhase.Exporting, is SuitePhase.Saving -> {
            val (label, prog) = if (ph is SuitePhase.Exporting) "Making your video on this phone" to ph.progress else "Saving to Gallery" to (ph as SuitePhase.Saving).progress
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    T("$label · ${(prog * 100).roundToInt()} %", m.type.body.copy(fontSize = 13.sp), m.t.ink, Modifier.weight(1f))
                    SuiteButton("Cancel", host.cancelExport, height = 34.dp)
                }
                Box(Modifier.fillMaxWidth().height(4.dp).background(m.t.surface2)) { Box(Modifier.fillMaxWidth(prog.coerceIn(0f, 1f)).height(4.dp).background(m.t.accent)) }
            }
        }
        else -> Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            SuiteButton("Save to Gallery", { host.export(false) }, height = 54.dp, enabled = ui.ready)
            SuiteButton("Export", { host.export(true) }, Modifier.weight(1f), primary = true, height = 54.dp, enabled = ui.ready)
        }
    }
    if (ui.phase is SuitePhase.Failed) T((ui.phase as SuitePhase.Failed).message, m.type.tiny.copy(fontSize = 12.sp), m.t.warn)
}



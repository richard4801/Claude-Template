package studio.muse.app.ui.screens.edit

import androidx.compose.ui.geometry.Size
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import studio.muse.core.edit.EditSafeBox
import studio.muse.core.edit.EditSafeCheck
import studio.muse.core.edit.PreviewView
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.Path
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredWidthIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import studio.muse.app.ui.components.FlowRow
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.theme.Fonts
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.scale
import studio.muse.core.edit.CaptionPreset
import studio.muse.core.edit.CaptionStyle
import studio.muse.core.edit.EditProject
import studio.muse.core.edit.Font
import studio.muse.core.edit.KfProp
import studio.muse.core.edit.TextItem
import studio.muse.core.edit.TextStyle as EditTextStyle
import studio.muse.core.edit.TrackKind
import studio.muse.core.edit.animState
import studio.muse.core.edit.captionAt
import studio.muse.core.edit.captionPages
import studio.muse.core.edit.ease
import studio.muse.core.edit.Ease
import studio.muse.core.edit.hexArgb
import studio.muse.core.edit.propAt

/** The dark stage behind the picture (`.stage`). */
val StageColor = Color(0xFF1B1916)

/**
 * The preview (EM1): the canvas at its aspect on the dark stage, the picture from [picture] (the player on a phone, a
 * still in screenshots), and — when [drawText] — the text, hooks and captions at the playhead in Compose (the player
 * draws its own), plus Edit's platform view (an app's generic chrome) and the red safe box, the phone's view chip and the
 * warning line when captions or text sit outside the box (plans/edit-platform-preview.md).
 */
@Composable
fun SuitePreview(ui: EditSuiteUi, act: (EditAction) -> Unit, modifier: Modifier = Modifier, drawText: Boolean = true, picture: @Composable (Modifier) -> Unit,
    /** The phone's safe-area chip over the picture; the tablet has its own segmented control (plans/edit-layout.md). */
    safeChip: Boolean = true) {
    val p = ui.project
    BoxWithConstraints(modifier.background(StageColor), contentAlignment = Alignment.Center) {
        val aspect = p?.let { it.canvas.width.toFloat() / it.canvas.height } ?: (9f / 16f)
        val availH = maxHeight - 24.dp
        val availW = maxWidth - 24.dp
        val (w, h) = if (availW / availH > aspect) (availH * aspect) to availH else availW to (availW / aspect)
        Box(Modifier.size(w, h).clip(RoundedCornerShape(2.dp)).background(Color.Black)) {
            picture(Modifier.fillMaxSize())
            if (p != null && drawText) Overlays(p, ui.playheadSec, w, h)
            if (p != null) {
                val pv = ui.preview.resolved(p.canvas.width, p.canvas.height)
                EditPlatformChrome(pv.view, PreviewView.isLandscape(p.canvas.width, p.canvas.height), w, h)
                EditSafeBox.zone(ui.preview, p.canvas.width, p.canvas.height, ui.previewLayouts)?.let { z ->
                    SafeBoxGuide(z, EditSafeBox.name(ui.preview, p.canvas.width, p.canvas.height))
                }
            }
            // Remove background → tap what to keep: taps on the paused picture, and where they are.
            ui.keep?.let { k -> KeepTaps(k, act) }
            // The chroma eyedropper: touch the colour to remove; a loupe shows the source pixels under the finger.
            ui.pick?.let { pk -> PickOverlay(pk, act) }
        }
        // Captions or text outside the red box: one line and the fix (both layouts).
        if (p != null) SafeWarning(ui, act, Modifier.align(Alignment.BottomCenter).padding(bottom = 6.dp))
        if (!safeChip) return@BoxWithConstraints
        // Fullscreen (the phone): hides the timeline and tools; tap again to bring them back.
        Box(Modifier.align(Alignment.TopEnd).padding(4.dp).size(48.dp).press { act(EditAction.Fullscreen) }.semantics { contentDescription = if (ui.fullscreen) "Exit fullscreen" else "Fullscreen" },
            contentAlignment = Alignment.Center) {
            Box(Modifier.size(32.dp).clip(RoundedCornerShape(2.dp)).background(Color.Black.copy(alpha = .45f)), contentAlignment = Alignment.Center) {
                EIc("expand", 16.dp, Color.White)
            }
        }
        // The phone's view chip: the view and the switch in one small menu.
        ViewChip(ui, act, Modifier.align(Alignment.TopStart).padding(4.dp))
    }
}

/** The phone's view picker: a chip ("TikTok", "Clean") that opens the views and the Safe area switch. */
@Composable
private fun ViewChip(ui: EditSuiteUi, act: (EditAction) -> Unit, modifier: Modifier) {
    val p = ui.project ?: return
    var open by remember { mutableStateOf(false) }
    val shown = ui.preview.resolved(p.canvas.width, p.canvas.height)
    Box(modifier) {
        Box(Modifier.size(width = 112.dp, height = 48.dp).press { open = true }
            .semantics { contentDescription = "View: ${shown.view.label}${if (shown.safeArea) ", safe area on" else ""}. Change the view" },
            contentAlignment = Alignment.CenterStart) {
            Row(Modifier.padding(start = 6.dp).clip(RoundedCornerShape(2.dp)).background(Color.Black.copy(alpha = .45f))
                .border(1.dp, if (shown.view != PreviewView.CLEAN || shown.safeArea) muse.t.accent else Color.White.copy(alpha = .3f), RoundedCornerShape(2.dp))
                .padding(horizontal = 8.dp, vertical = 5.dp), verticalAlignment = Alignment.CenterVertically) {
                T(shown.view.label, muse.scale.micro, Color.White, maxLines = 1)
            }
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            PreviewView.options(p.canvas.width, p.canvas.height).forEach { v ->
                DropdownMenuItem(text = { T(v.label, muse.scale.label, muse.t.ink, maxLines = 1) },
                    trailingIcon = { if (v == shown.view) EIc("check", 18.dp, muse.t.accent) },
                    onClick = { act(EditAction.PreviewOf(ui.preview.copy(view = v))); open = false })
            }
            HorizontalDivider()
            DropdownMenuItem(text = { T("Safe area", muse.scale.label, muse.t.ink, maxLines = 1) },
                trailingIcon = { studio.muse.app.ui.components.Toggle(shown.safeArea, { act(EditAction.PreviewOf(ui.preview.copy(safeArea = !ui.preview.safeArea))) }) },
                onClick = { act(EditAction.PreviewOf(ui.preview.copy(safeArea = !ui.preview.safeArea))) })
        }
    }
}

/** "Captions sit under TikTok's caption and buttons (0:01–0:09)." and "Move into the safe area". */
@Composable
fun SafeWarning(ui: EditSuiteUi, act: (EditAction) -> Unit, modifier: Modifier = Modifier) {
    val p = ui.project ?: return
    val line = remember(p, ui.preview, ui.previewLayouts) {
        val z = EditSafeBox.zone(ui.preview, p.canvas.width, p.canvas.height, ui.previewLayouts) ?: return@remember null
        EditSafeCheck.line(EditSafeCheck.issues(p, z), EditSafeBox.covers(ui.preview, p.canvas.width, p.canvas.height))
    } ?: return
    Row(modifier.padding(horizontal = 8.dp).clip(RoundedCornerShape(8.dp)).background(Color.Black.copy(alpha = .72f)).padding(start = 10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        EIc("warning", 14.dp, SafeRed)
        T(line, muse.scale.micro, Color.White, Modifier.weight(1f, fill = false), maxLines = 2)
        Box(Modifier.height(48.dp).press { act(EditAction.MoveIntoSafeArea) }.padding(horizontal = 10.dp)
            .semantics { contentDescription = "Move into the safe area" }, contentAlignment = Alignment.Center) {
            T("Move into the safe area", muse.scale.micro, muse.t.accent, maxLines = 1)
        }
    }
}

/** Text/hook items and the caption page at [t], drawn at their positions on a [w]×[h] canvas. */
@Composable
private fun Overlays(p: EditProject, t: Double, w: Dp, h: Dp) {
    for (track in p.tracks) {
        if (track.hidden == true) continue
        when (track.kind) {
            TrackKind.TEXT -> for (it in track.items) {
                val item = it as TextItem
                if (t < item.startSec || t >= item.startSec + item.durationSec) continue
                val local = t - item.startSec
                val a = animState(item, local)
                val k = item.keyframes; val tr = item.transform
                val alpha = (propAt(k, KfProp.OPACITY, item.opacity ?: 1.0, local) * a.opacity).toFloat()
                var text = if (item.style.uppercase == true) item.text.uppercase() else item.text
                a.chars?.let { n -> text = text.take(n) }
                if (alpha <= 0f || text.isEmpty()) continue
                Placed(propAt(k, KfProp.X, tr?.x ?: .5, local), propAt(k, KfProp.Y, tr?.y ?: .5, local) + a.dy, w, h,
                    (propAt(k, KfProp.SCALE, tr?.scale ?: 1.0, local) * a.scale).toFloat(), propAt(k, KfProp.ROTATION, tr?.rotation ?: 0.0, local).toFloat(), tr?.flipX == true, tr?.flipY == true) {
                    StyledText(text, item.style, h, alpha, w * (item.style.maxWidthPct ?: .85).toFloat(), studio.muse.app.platform.edit.OwnFonts.family(studio.muse.app.platform.edit.OwnFonts.uploadOf(p, item.style)))
                }
            }
            TrackKind.CAPTION -> {
                val c = track.caption ?: continue
                val pages = captionPages(p)
                val at = captionAt(pages, t) ?: continue
                val page = pages[at.page]
                val scale = when (c.style.preset) {
                    CaptionPreset.POP -> 1f
                    CaptionPreset.SINGLE -> (0.6 + 0.4 * ease(Ease.EASE_OUT, (t - page.startSec) / 0.15)).toFloat()
                    else -> 1f
                }
                Placed(.5, c.style.y ?: .72, w, h, scale, 0f) { CaptionLine(page.words.map { it.text }, at.word, c.style, h, w * .85f, c.language) }
            }
            else -> {}
        }
    }
}

/** Puts [content] centred on (x, y) of the canvas (fractions). */
@Composable
private fun Placed(x: Double, y: Double, w: Dp, h: Dp, scale: Float, rotation: Float, flipX: Boolean = false, flipY: Boolean = false, content: @Composable () -> Unit) {
    androidx.compose.ui.layout.Layout(content = { Box(Modifier.rotate(rotation).scale(if (flipX) -scale else scale, if (flipY) -scale else scale)) { content() } }, modifier = Modifier.size(w, h)) { ms, c ->
        val pl = ms.first().measure(androidx.compose.ui.unit.Constraints(maxWidth = c.maxWidth))
        layout(c.maxWidth, c.maxHeight) { pl.place((x * c.maxWidth - pl.width / 2.0).toInt(), (y * c.maxHeight - pl.height / 2.0).toInt()) }
    }
}

/** A family for Compose: a content family's file for [weight] once downloaded, else its bundled fallback. */
fun fontFamilyOf(f: Font, weight: Int = 400): FontFamily = studio.muse.app.platform.edit.ContentLibrary.family(f, weight) ?: when (f.fallback) {
    Font.SANS -> Fonts.archivo
    Font.ROUNDED -> Fonts.outfit
    Font.SERIF -> Fonts.instrumentSerif
    Font.CONDENSED -> Fonts.barlowCondensed
    Font.MONO -> Fonts.plexMono
    else -> Fonts.marker
}

/** Whether [f] draws from its own downloaded weight file (so Compose mustn't embolden it again). */
private fun ownWeight(f: Font, weight: Int) = studio.muse.app.platform.edit.ContentLibrary.family(f, weight) != null

private fun weightOf(w: Int) = when { w >= 900 -> FontWeight.Black; w >= 700 -> FontWeight.Bold; else -> FontWeight.Normal }

fun colorOf(hex: String): Color = Color(hexArgb(hex))

/** A text item in its style (fill, stroke, shadow, box) at a canvas [h] tall. */
@Composable
fun StyledText(text: String, s: EditTextStyle, h: Dp, alpha: Float = 1f, maxW: Dp, family: FontFamily? = null) {
    val size: TextUnit = (h.value * s.sizePct).sp
    val base = TextStyle(fontFamily = family ?: fontFamilyOf(s.font, s.weight), fontWeight = if (family != null || ownWeight(s.font, s.weight)) FontWeight.Normal else weightOf(s.weight), fontSize = size, lineHeight = size * (s.lineHeight ?: 1.15).toFloat(),
        textAlign = when (s.align) { studio.muse.core.edit.Align.LEFT -> TextAlign.Start; studio.muse.core.edit.Align.RIGHT -> TextAlign.End; else -> TextAlign.Center },
        shadow = s.shadow?.let { sh -> Shadow(colorOf(sh.color).copy(alpha = sh.opacity.toFloat()), Offset(0f, (sh.dyPct * h.value * s.sizePct).toFloat()), (sh.blurPct * h.value * s.sizePct * 2).toFloat()) })
    val bg = s.background
    Box(
        Modifier.requiredWidthIn(max = maxW).let { m ->
            if (bg != null) m.clip(RoundedCornerShape((bg.radiusPct * size.value).dp)).background(colorOf(bg.color).copy(alpha = bg.opacity.toFloat() * alpha))
                .padding(horizontal = (bg.paddingPct * size.value).dp, vertical = (bg.paddingPct * size.value * .6).dp) else m
        },
    ) {
        s.stroke?.takeIf { it.widthPct > 0 }?.let { st ->
            androidx.compose.material3.Text(text, style = base.copy(color = colorOf(st.color).copy(alpha = alpha), shadow = null, drawStyle = Stroke((st.widthPct * size.value * 2.6).toFloat())))
        }
        androidx.compose.material3.Text(text, style = base.copy(color = colorOf(s.color).copy(alpha = alpha)))
    }
}

/**
 * A caption page drawn like the engine does (RenderPlan.captionFrame): highlight/pop/neon = the active word in the
 * highlight colour, karaoke = every word up to it, box = a box behind it, highlighter = a marker stripe behind it.
 */
@Composable
fun CaptionLine(words: List<String>, active: Int, style: CaptionStyle, h: Dp, maxW: Dp, language: String? = null) {
    // Right-to-left languages read from the right (words keep their order); unspaced ones sit without gaps.
    if (studio.muse.core.edit.isRtlLanguage(language)) {
        androidx.compose.runtime.CompositionLocalProvider(androidx.compose.ui.platform.LocalLayoutDirection provides androidx.compose.ui.unit.LayoutDirection.Rtl) {
            CaptionWords(words, active, style, h, maxW, unspaced = false)
        }
    } else CaptionWords(words, active, style, h, maxW, unspaced = studio.muse.core.edit.captionJoiner(language).isEmpty())
}

@Composable
private fun CaptionWords(words: List<String>, active: Int, style: CaptionStyle, h: Dp, maxW: Dp, unspaced: Boolean) {
    val s = style.text
    val size: TextUnit = (h.value * s.sizePct).sp
    val up = s.uppercase == true
    val hl = colorOf(style.highlightColor)
    val glow = style.preset == CaptionPreset.NEON
    FlowRow(Modifier.requiredWidthIn(max = maxW), hGap = if (unspaced) 0.dp else (size.value * .28f).dp, vGap = 0.dp) {
        words.forEachIndexed { k, w0 ->
            val w = if (up) w0.uppercase() else w0
            val on = when (style.preset) {
                CaptionPreset.HIGHLIGHT, CaptionPreset.POP, CaptionPreset.NEON -> k == active
                CaptionPreset.KARAOKE -> k <= active
                else -> false
            }
            val color = if (on) hl else colorOf(s.color)
            val boxed = style.preset == CaptionPreset.BOX && k == active
            val stripe = style.preset == CaptionPreset.HIGHLIGHTER && k == active
            val scale = if (style.preset == CaptionPreset.POP && k == active) 1.15f else 1f
            val ts = TextStyle(
                fontFamily = fontFamilyOf(s.font, s.weight), fontWeight = if (ownWeight(s.font, s.weight)) FontWeight.Normal else weightOf(s.weight), fontSize = size * scale,
                shadow = when {
                    glow -> Shadow(hl.copy(alpha = .9f), Offset.Zero, size.value * 1.2f)
                    s.shadow != null -> Shadow(colorOf(s.shadow!!.color).copy(alpha = s.shadow!!.opacity.toFloat()), Offset(0f, (s.shadow!!.dyPct * size.value).toFloat()), (s.shadow!!.blurPct * size.value * 2).toFloat())
                    else -> null
                },
            )
            Box(
                Modifier.let { m -> if (boxed) m.clip(RoundedCornerShape((size.value * .2f).dp)).background(hl).padding(horizontal = (size.value * .2f).dp) else m }
                    .let { m ->
                        if (stripe) m.drawBehind { drawRect(hl, Offset(-size.value * .08f, this.size.height * .55f), androidx.compose.ui.geometry.Size(this.size.width + size.value * .16f, this.size.height * .45f)) } else m
                    },
            ) {
                s.stroke?.takeIf { it.widthPct > 0 && !boxed }?.let { st -> androidx.compose.material3.Text(w, style = ts.copy(color = colorOf(st.color), shadow = null, drawStyle = Stroke((st.widthPct * size.value * 2.6).toFloat()))) }
                androidx.compose.material3.Text(w, style = ts.copy(color = if (boxed) colorOf(s.color) else color))
            }
        }
    }
}

/** A caption style tile (EM2): "I ALWAYS ORDER" in the style on black, the active word second. */
@Composable
fun CaptionTile(style: CaptionStyle, label: String, on: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val m = muse
    Column(modifier.press(onClick = onClick), verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Box(
            Modifier.fillMaxWidth().height(60.dp).background(Color(0xFF151311)).border(if (on) 2.dp else 0.dp, if (on) m.t.accent else Color.Transparent),
            contentAlignment = Alignment.Center,
        ) {
            val words = if (style.preset == CaptionPreset.PLAIN) listOf("I", "always", "order", "the") else listOf("I", "always", "order")
            CaptionLine(words, 1, style.copy(text = style.text.copy(sizePct = when (style.preset) { CaptionPreset.PLAIN -> .16; CaptionPreset.POP -> .17; else -> .2 })), 60.dp, 108.dp)
        }
        T(label, m.type.tiny.copy(fontSize = 12.sp), if (on) m.t.ink else m.t.muted, weight = if (on) FontWeight.Bold else null, maxLines = 1)
    }
}



/**
 * The eyedropper over the picture (owner-approved design pass): dims it slightly, follows the finger with a loupe of
 * the clip's source pixels (about 4×) and the colour's hex above it; lifting the finger sets the key colour.
 */
@Composable
private fun PickOverlay(pk: PickUi, act: (EditAction) -> Unit) {
    val m = muse
    val frame = androidx.compose.runtime.remember(pk.argb) {
        pk.argb?.let { px -> android.graphics.Bitmap.createBitmap(px, pk.w, pk.h, android.graphics.Bitmap.Config.ARGB_8888).asImageBitmap() }
    }
    val measurer = rememberTextMeasurer()
    Canvas(
        Modifier.fillMaxSize()
            .pointerInput(Unit) {
                awaitEachGesture {
                    val down = awaitFirstDown()
                    fun at(o: Offset) = (o.x / size.width).toDouble().coerceIn(0.0, 1.0) to (o.y / size.height).toDouble().coerceIn(0.0, 1.0)
                    var last = down.position
                    at(last).let { (x, y) -> act(EditAction.PickAt(x, y, done = false)) }
                    while (true) {
                        val ev = awaitPointerEvent()
                        val ch = ev.changes.firstOrNull { it.id == down.id } ?: break
                        if (!ch.pressed) break
                        last = ch.position; ch.consume()
                        at(last).let { (x, y) -> act(EditAction.PickAt(x, y, done = false)) }
                    }
                    at(last).let { (x, y) -> act(EditAction.PickAt(x, y, done = true)) }
                }
            }
            .semantics { contentDescription = "Picture · touch the colour to remove" },
    ) {
        drawRect(Color.Black.copy(alpha = .18f))
        val a = pk.at ?: return@Canvas
        val c = Offset((a.first * size.width).toFloat(), (a.second * size.height).toFloat())
        val r = 44.dp.toPx()
        // Above the finger (below it near the top edge).
        val lc = Offset(c.x.coerceIn(r, size.width - r), if (c.y - r * 2.2f > r) c.y - r * 1.8f else c.y + r * 1.8f)
        val src = pk.src
        if (frame != null && src != null) {
            val half = 11
            val sx = (src.first * pk.w).toInt().coerceIn(half, maxOf(half, pk.w - half - 1)) - half
            val sy = (src.second * pk.h).toInt().coerceIn(half, maxOf(half, pk.h - half - 1)) - half
            val clip = Path().apply { addOval(androidx.compose.ui.geometry.Rect(lc, r)) }
            clipPath(clip) {
                drawImage(frame, androidx.compose.ui.unit.IntOffset(sx, sy), androidx.compose.ui.unit.IntSize(half * 2 + 1, half * 2 + 1),
                    androidx.compose.ui.unit.IntOffset((lc.x - r).toInt(), (lc.y - r).toInt()), androidx.compose.ui.unit.IntSize((r * 2).toInt(), (r * 2).toInt()),
                    filterQuality = androidx.compose.ui.graphics.FilterQuality.None)
            }
        } else drawCircle(Color.Black.copy(alpha = .5f), r, lc)
        drawCircle(Color.White, r, lc, style = Stroke(3.dp.toPx()))
        drawLine(Color.White, Offset(lc.x - 6.dp.toPx(), lc.y), Offset(lc.x + 6.dp.toPx(), lc.y), 1.5f.dp.toPx())
        drawLine(Color.White, Offset(lc.x, lc.y - 6.dp.toPx()), Offset(lc.x, lc.y + 6.dp.toPx()), 1.5f.dp.toPx())
        drawCircle(Color.White, 6.dp.toPx(), c, style = Stroke(2.dp.toPx()))
        pk.hex?.let { hx ->
            val tl = measurer.measure(hx, TextStyle(fontFamily = m.t.body, fontSize = 12.sp, color = Color.White, fontFeatureSettings = "tnum"))
            val tx = lc.x - tl.size.width / 2f; val ty = lc.y + r + 6.dp.toPx()
            drawRect(Color.Black.copy(alpha = .6f), Offset(tx - 6.dp.toPx(), ty - 2.dp.toPx()), Size(tl.size.width + 12.dp.toPx(), tl.size.height + 4.dp.toPx()))
            drawText(tl, topLeft = Offset(tx, ty))
        }
    }
}

/** Tap to keep: a tap adds a point (0–1 of the frame); keep taps are filled rings, leave-out taps are crossed. */
@Composable
private fun KeepTaps(k: KeepUi, act: (EditAction) -> Unit) {
    val accent = muse.t.accent
    Canvas(
        Modifier.fillMaxSize()
            .pointerInput(Unit) { detectTapGestures { o -> act(EditAction.KeepTapAt((o.x / size.width).toDouble(), (o.y / size.height).toDouble())) } }
            .semantics { contentDescription = "Picture · tap what to ${if (k.keepNext) "keep" else "leave out"}" },
    ) {
        val r = 11.dp.toPx()
        for (t in k.taps) {
            val c = Offset((t.x * size.width).toFloat(), (t.y * size.height).toFloat())
            drawCircle(Color.Black.copy(alpha = .35f), r + 2.dp.toPx(), c)
            if (t.keep) {
                drawCircle(accent, r, c)
                drawCircle(Color.White, r, c, style = Stroke(2.dp.toPx()))
            } else {
                drawCircle(Color.White, r, c, style = Stroke(2.dp.toPx()))
                val d = r * .6f
                drawLine(Color.White, Offset(c.x - d, c.y - d), Offset(c.x + d, c.y + d), 2.dp.toPx())
                drawLine(Color.White, Offset(c.x - d, c.y + d), Offset(c.x + d, c.y - d), 2.dp.toPx())
            }
        }
    }
}

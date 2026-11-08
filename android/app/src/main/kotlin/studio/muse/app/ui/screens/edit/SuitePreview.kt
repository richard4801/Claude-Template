package studio.muse.app.ui.screens.edit

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
 * draws its own), plus the platform safe area and its switch.
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
            ui.safeArea?.let { SafeAreaGuides(it) }
            // Remove background → tap what to keep: taps on the paused picture, and where they are.
            ui.keep?.let { k -> KeepTaps(k, act) }
        }
        // Safe-area switch: TikTok → Reels → Shorts → off.
        if (!safeChip) return@BoxWithConstraints
        // Fullscreen (the phone): hides the timeline and tools; tap again to bring them back.
        Box(Modifier.align(Alignment.TopEnd).padding(4.dp).size(48.dp).press { act(EditAction.Fullscreen) }.semantics { contentDescription = if (ui.fullscreen) "Exit fullscreen" else "Fullscreen" },
            contentAlignment = Alignment.Center) {
            Box(Modifier.size(32.dp).clip(RoundedCornerShape(2.dp)).background(Color.Black.copy(alpha = .45f)), contentAlignment = Alignment.Center) {
                EIc("expand", 16.dp, Color.White)
            }
        }
        val next = when (ui.safeArea) { SafeArea.TIKTOK -> SafeArea.REELS; SafeArea.REELS -> SafeArea.SHORTS; SafeArea.SHORTS -> null; null -> SafeArea.TIKTOK }
        Row(
            Modifier.align(Alignment.TopStart).padding(10.dp).clip(RoundedCornerShape(2.dp)).background(Color.Black.copy(alpha = .45f))
                .border(1.dp, if (ui.safeArea != null) muse.t.accent else Color.White.copy(alpha = .3f), RoundedCornerShape(2.dp))
                .press { act(EditAction.SafeAreaOf(next)) }.padding(horizontal = 8.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) { T(ui.safeArea?.label?.let { "$it safe area" } ?: "Safe area off", muse.scale.micro, Color.White, maxLines = 1) }
    }
}

/** The platform's UI zones as dashed lines and its side buttons. */
@Composable
private fun SafeAreaGuides(area: SafeArea) {
    Canvas(Modifier.fillMaxSize()) {
        val dash = PathEffect.dashPathEffect(floatArrayOf(5.dp.toPx(), 4.dp.toPx()))
        val c = Color.White.copy(alpha = .55f)
        val top = size.height * area.top; val bottom = size.height * (1 - area.bottom); val right = size.width * (1 - area.right)
        drawLine(c, Offset(0f, top), Offset(size.width, top), 1.dp.toPx(), pathEffect = dash)
        drawLine(c, Offset(0f, bottom), Offset(size.width, bottom), 1.dp.toPx(), pathEffect = dash)
        drawLine(c, Offset(right, top), Offset(right, bottom), 1.dp.toPx(), pathEffect = dash)
    }
    Column(Modifier.fillMaxSize().padding(end = 6.dp), horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.Center) {
        listOf("heart", "msg", "send").forEach { EIc(it, 15.dp, Color.White.copy(alpha = .85f), Modifier.padding(vertical = 5.dp)) }
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
                    StyledText(text, item.style, h, alpha, w * (item.style.maxWidthPct ?: .85).toFloat())
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
                Placed(.5, c.style.y ?: .72, w, h, scale, 0f) { CaptionLine(page.words.map { it.text }, at.word, c.style, h, w * .85f) }
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

fun fontFamilyOf(f: Font): FontFamily = when (f) {
    Font.SANS -> Fonts.archivo
    Font.ROUNDED -> Fonts.outfit
    Font.SERIF -> Fonts.instrumentSerif
    Font.CONDENSED -> Fonts.barlowCondensed
    Font.MONO -> Fonts.plexMono
    Font.MARKER -> Fonts.marker
}

private fun weightOf(w: Int) = when { w >= 900 -> FontWeight.Black; w >= 700 -> FontWeight.Bold; else -> FontWeight.Normal }

fun colorOf(hex: String): Color = Color(hexArgb(hex))

/** A text item in its style (fill, stroke, shadow, box) at a canvas [h] tall. */
@Composable
fun StyledText(text: String, s: EditTextStyle, h: Dp, alpha: Float = 1f, maxW: Dp) {
    val size: TextUnit = (h.value * s.sizePct).sp
    val base = TextStyle(fontFamily = fontFamilyOf(s.font), fontWeight = weightOf(s.weight), fontSize = size, lineHeight = size * (s.lineHeight ?: 1.15).toFloat(),
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
fun CaptionLine(words: List<String>, active: Int, style: CaptionStyle, h: Dp, maxW: Dp) {
    val s = style.text
    val size: TextUnit = (h.value * s.sizePct).sp
    val up = s.uppercase == true
    val hl = colorOf(style.highlightColor)
    val glow = style.preset == CaptionPreset.NEON
    FlowRow(Modifier.requiredWidthIn(max = maxW), hGap = (size.value * .28f).dp, vGap = 0.dp) {
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
                fontFamily = fontFamilyOf(s.font), fontWeight = weightOf(s.weight), fontSize = size * scale,
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

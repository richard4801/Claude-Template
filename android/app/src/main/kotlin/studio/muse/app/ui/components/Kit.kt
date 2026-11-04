package studio.muse.app.ui.components

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.BiasAlignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.em
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties
import coil3.compose.AsyncImage
import studio.muse.app.R
import studio.muse.app.data.ImageRef
import studio.muse.app.platform.SoundFx
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse
import kotlin.math.roundToInt

/** Plays a UI sound for the current theme. */
val LocalSfx = staticCompositionLocalOf<(SoundFx.Kind) -> Unit> { {} }

val Ink = Color(0xFF111111)

// ---------------------------------------------------------------- modifiers

/** Theme D's offset "sticker" shadow. */
fun Modifier.hardShadow(dx: Dp = 3.dp, radius: Dp = 14.dp, color: Color = Ink, dy: Dp = dx): Modifier = drawBehind {
    drawRoundRect(color, topLeft = Offset(dx.toPx(), dy.toPx()), size = size, cornerRadius = CornerRadius(radius.toPx()))
}

/** Theme C's raised tile: inset highlight + soft drop shadow. */
fun Modifier.softShadow(radius: Dp, elevation: Dp = 8.dp, color: Color = Color(0x2E50463A)): Modifier =
    shadow(elevation, RoundedCornerShape(radius), ambientColor = color, spotColor = color)

/** Press feedback (scale .96, like the prototype's .pressed) plus the theme's tap sound. */
@Composable
fun Modifier.press(sound: SoundFx.Kind? = SoundFx.Kind.TAP, enabled: Boolean = true, onClick: () -> Unit): Modifier {
    val src = remember { MutableInteractionSource() }
    val pressed by src.collectIsPressedAsState()
    val s by animateFloatAsState(if (pressed) .96f else 1f, tween(120), label = "press")
    val sfx = LocalSfx.current
    return this.scale(s).clickable(src, indication = null, enabled = enabled) { sound?.let(sfx); onClick() }
}

/** Shimmer sweep for "busy" states. */
@Composable
fun Modifier.shimmer(active: Boolean = true): Modifier {
    if (!active) return this
    val tr = rememberInfiniteTransition(label = "shim")
    val x by tr.animateFloat(-1f, 2f, infiniteRepeatable(tween(1100, easing = LinearEasing), RepeatMode.Restart), label = "x")
    return drawWithContent {
        drawContent()
        val w = size.width
        drawRect(Brush.linearGradient(listOf(Color.Transparent, Color.White.copy(alpha = .45f), Color.Transparent), start = Offset(w * x - w * .3f, 0f), end = Offset(w * x + w * .3f, size.height)))
    }
}

// ---------------------------------------------------------------- text

@Composable
fun T(
    text: String, style: TextStyle = muse.type.body, color: Color = Color.Unspecified, modifier: Modifier = Modifier,
    upper: Boolean = false, align: TextAlign? = null, maxLines: Int = Int.MAX_VALUE, weight: FontWeight? = null,
) {
    Text(
        if (upper) text.uppercase() else text, modifier = modifier, style = style, color = color, textAlign = align, maxLines = maxLines,
        overflow = if (maxLines == Int.MAX_VALUE) TextOverflow.Clip else TextOverflow.Ellipsis, fontWeight = weight,
    )
}

/** Small uppercase label (`.lbl`). */
@Composable
fun Lbl(text: String, modifier: Modifier = Modifier, color: Color = muse.t.muted) {
    T(text, muse.type.lbl, color, modifier, upper = !muse.isC)
}

@Composable
fun Tiny(text: String, modifier: Modifier = Modifier, color: Color = muse.t.muted, weight: FontWeight? = null) = T(text, muse.type.tiny, color, modifier, weight = weight)

@Composable
fun H2(text: String, modifier: Modifier = Modifier) = T(text, muse.type.h2, muse.t.ink, modifier, upper = muse.isA || muse.isB)

@Composable
fun H3(text: String, modifier: Modifier = Modifier) = T(text, muse.type.h3, muse.t.ink, modifier)

@Composable
fun Wordmark(modifier: Modifier = Modifier, size: String = "sm", color: Color = Color.Unspecified) {
    val st = when (size) { "md" -> muse.type.wmMd; "xl" -> muse.type.wmXl; else -> muse.type.wm }
    T("MUSE", st, color, modifier)
}

// ---------------------------------------------------------------- buttons

/** Primary call to action (`.cta`). [off] dims it but keeps it tappable so it can explain why. */
@Composable
fun Cta(
    text: String, onClick: () -> Unit, modifier: Modifier = Modifier, icon: String? = null, off: Boolean = false,
    busy: Boolean = false, big: Boolean = false, sound: SoundFx.Kind? = SoundFx.Kind.TAP,
) {
    val m = muse
    val r = if (m.isA) 2.dp else 999.dp
    val shape = RoundedCornerShape(r)
    var mod = modifier.height(if (big) 62.dp else 54.dp)
    mod = when {
        m.isD -> mod.hardShadow(4.dp, 999.dp)
        m.isC -> mod.shadow(10.dp, shape, ambientColor = Color(0x596E8465), spotColor = Color(0x596E8465))
        else -> mod
    }
    mod = mod.clip(shape).background(m.t.cta).let { if (m.isD) it.border(2.5.dp, Ink, shape) else it }
    Row(
        mod.graphicsLayer { alpha = if (off) .45f else 1f }.shimmer(busy).press(sound, onClick = onClick).padding(horizontal = 20.dp),
        horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) { Ic(icon, if (big) 22.dp else 18.dp, m.t.ctaInk); Spacer(Modifier.width(8.dp)) }
        T(text, if (big) m.type.cta.copy(fontSize = 22.sp) else m.type.cta, m.t.ctaInk, upper = m.isA, maxLines = 1)
    }
}

/** Secondary button (`.cta-2`). */
@Composable
fun Cta2(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, icon: String? = null, height: Dp = 54.dp, sound: SoundFx.Kind? = SoundFx.Kind.TAP) {
    val m = muse
    val shape = RoundedCornerShape(if (m.isA) 2.dp else 999.dp)
    var mod = modifier.height(height).widthIn(min = height)
    mod = when {
        m.isD -> mod.hardShadow(3.dp, 999.dp).clip(shape).background(m.t.surface).border(2.5.dp, Ink, shape)
        m.isC -> mod.softShadow(999.dp).clip(shape).background(m.t.surface)
        else -> mod.clip(shape).background(m.t.surface).border(m.t.stroke, m.t.line, shape)
    }
    Row(mod.press(sound, onClick = onClick).padding(horizontal = 16.dp), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
        if (icon != null) { Ic(icon, 18.dp); if (text.isNotEmpty()) Spacer(Modifier.width(8.dp)) }
        if (text.isNotEmpty()) T(text, m.type.cta2, m.t.ink, maxLines = 1)
    }
}

/** Round 44dp icon button in top bars. */
@Composable
fun TbBtn(icon: String, onClick: () -> Unit, modifier: Modifier = Modifier, tint: Color = Color.Unspecified, sound: SoundFx.Kind? = SoundFx.Kind.TAP) {
    Box(modifier.size(44.dp).clip(CircleShape).press(sound, onClick = onClick), contentAlignment = Alignment.Center) {
        Ic(icon, 22.dp, if (tint == Color.Unspecified) androidx.compose.material3.LocalContentColor.current else tint)
    }
}

// ---------------------------------------------------------------- controls

@Composable
fun Chip(text: String, on: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val m = muse
    val shape = RoundedCornerShape(if (m.isA) 2.dp else 999.dp)
    val (bg, fg) = when {
        !on -> (if (m.isB) m.t.surface2 else m.t.surface) to m.t.ink
        m.isA -> m.t.accent to Color.White
        m.isB -> m.t.accent to m.t.accentInk
        m.isC -> m.t.accent to Color.White
        m.isD -> m.t.blue to Color.White
        else -> m.t.ink to m.t.bg
    }
    var mod = modifier.height(36.dp)
    mod = if (m.isC && !on) mod.shadow(3.dp, shape, ambientColor = Color(0x1450463A), spotColor = Color(0x1450463A)) else mod
    mod = mod.clip(shape).background(bg)
    mod = when {
        m.isD -> mod.border(2.5.dp, Ink, shape)
        m.isC -> mod
        else -> mod.border(m.t.stroke, if (on) bg else m.t.line, shape)
    }
    Box(mod.press(SoundFx.Kind.TICK, onClick = onClick).padding(horizontal = 14.dp), contentAlignment = Alignment.Center) {
        T(text, m.type.chip, fg, maxLines = 1)
    }
}

@Composable
fun ChipRow(items: List<String>, selected: String?, onSelect: (String) -> Unit, label: (String) -> String = { it }) {
    FlowRow(hGap = 8.dp, vGap = 8.dp) { items.forEach { Chip(label(it), it == selected, { onSelect(it) }) } }
}

/** Segmented control (`.seg`). */
@Composable
fun Seg(options: List<Pair<String, String>>, selected: String, onSelect: (String) -> Unit, modifier: Modifier = Modifier, small: Boolean = false) {
    val m = muse
    val shape = RoundedCornerShape(if (m.isA) 2.dp else 999.dp)
    var mod = modifier.clip(shape).background(if (m.isC) m.t.surface2 else m.t.surface)
    mod = when {
        m.isD -> mod.border(2.5.dp, Ink, shape)
        m.isC -> mod
        else -> mod.border(m.t.stroke, m.t.line, shape)
    }
    Row(mod.padding(3.dp)) {
        options.forEach { (k, l) ->
            val on = k == selected
            val (bg, fg) = when {
                !on -> Color.Transparent to m.t.muted
                m.isB || m.isC -> m.t.accent to (if (m.isC) Color.White else m.t.accentInk)
                m.isD -> m.t.blue to Color.White
                else -> m.t.ink to m.t.bg
            }
            Box(
                Modifier.weight(l.length.coerceAtLeast(6).toFloat()).height(if (small) 28.dp else 38.dp).clip(shape).background(bg).press(SoundFx.Kind.TICK) { onSelect(k) }.padding(horizontal = 8.dp),
                contentAlignment = Alignment.Center,
            ) { T(l, (if (small) m.type.seg.copy(fontSize = 12.sp) else m.type.seg).let { if (m.isA) it.copy(fontSize = it.fontSize * .88f, letterSpacing = .06.em) else it }, fg, upper = m.isA, maxLines = 1) }
        }
    }
}

@Composable
fun Pill(text: String, kind: String = "", modifier: Modifier = Modifier, icon: String? = null) {
    val m = muse
    val (bg, fg) = when (kind) {
        "good" -> m.t.good.copy(alpha = .16f) to m.t.good
        "warn" -> m.t.warnPillBg to m.t.warnPillInk
        else -> m.t.surface2 to m.t.muted
    }
    val shape = RoundedCornerShape(999.dp)
    Row(
        modifier.height(24.dp).clip(shape).background(bg).let { if (m.isD) it.border(1.5.dp, Ink, shape) else it }.padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        if (icon != null) Ic(icon, 12.dp, fg)
        T(text, m.type.pill, fg, upper = m.isA, maxLines = 1)
    }
}

@Composable
fun Toggle(on: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val m = muse
    val x by animateFloatAsState(if (on) 20f else 0f, tween(180, easing = FastOutSlowInEasing), label = "tog")
    Box(
        modifier.size(48.dp, 28.dp).clip(RoundedCornerShape(14.dp)).background(if (on) m.t.accent else m.t.surface2)
            .border(m.t.stroke, if (m.isD) Ink else m.t.line, RoundedCornerShape(14.dp)).press(SoundFx.Kind.TICK, onClick = onClick),
    ) {
        Box(Modifier.offset(x = (3 + x).dp, y = 3.dp).size(20.dp).clip(CircleShape).background(if (on) m.t.accentInk else m.t.muted).align(Alignment.CenterStart))
    }
}

/**
 * The themed slider (`.slider`). Reports integer values in [min]..[max]. Drag or tap anywhere on the generous hit area.
 */
@Composable
fun MuseSlider(value: Int, min: Int, max: Int, onChange: (Int) -> Unit, modifier: Modifier = Modifier) {
    val m = muse
    val frac = ((value - min).toFloat() / (max - min)).coerceIn(0f, 1f)
    val trackH = when { m.isA -> 2.dp; m.isC -> 10.dp; m.isD -> 12.dp; else -> 6.dp }
    val thumb = when { m.isA -> 22.dp; m.isC -> 30.dp; m.isD -> 28.dp; else -> 24.dp }
    val trackBg = when { m.isA -> m.t.line; m.isD -> Color.White; else -> m.t.surface2 }
    val fill = when { m.isA -> m.t.ink; m.isD -> m.t.blue; else -> m.t.accent }
    val w = remember { androidx.compose.runtime.mutableFloatStateOf(1f) }
    fun at(x: Float) = (min + ((x / w.floatValue).coerceIn(0f, 1f) * (max - min))).roundToInt()
    Box(
        modifier.fillMaxWidth().height(40.dp).onSizeChanged { w.floatValue = it.width.toFloat().coerceAtLeast(1f) }
            .pointerInput(min, max) { detectTapGestures { onChange(at(it.x)) } }
            .pointerInput(min, max) { detectDragGestures(onDragStart = { onChange(at(it.x)) }) { c, _ -> onChange(at(c.position.x)) } },
        contentAlignment = Alignment.CenterStart,
    ) {
        val tshape = RoundedCornerShape(trackH / 2)
        Box(Modifier.fillMaxWidth().height(trackH).clip(tshape).background(trackBg).let { if (m.isD) it.border(2.dp, Ink, tshape) else it }) {
            Box(Modifier.fillMaxWidth(frac).height(trackH).background(fill))
        }
        val density = LocalDensity.current
        Box(
            Modifier.offset { IntOffset(((w.floatValue * frac) - with(density) { thumb.toPx() } / 2).roundToInt(), 0) }.size(thumb)
                .let { if (m.isC) it.shadow(6.dp, CircleShape) else it }
                .clip(CircleShape)
                .background(when { m.isA -> m.t.ink; m.isC -> m.t.accent; else -> m.t.surface })
                .border(
                    when { m.isA -> 0.dp; m.isC -> 4.dp; m.isD -> 2.5.dp; else -> 2.dp },
                    when { m.isC -> m.t.surface; m.isD -> Ink; else -> m.t.accent }, CircleShape,
                ),
        )
    }
}

@Composable
fun Scale(vararg labels: String) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) { labels.forEach { T(it, muse.type.mono.copy(fontSize = 11.5.sp), muse.t.muted) } }
}

/** Option card (`.opt`). */
@Composable
fun Opt(title: String, sub: String, on: Boolean = false, icon: String? = null, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val m = muse
    val shape = RoundedCornerShape(m.t.r)
    var mod = modifier.fillMaxWidth()
    mod = when {
        m.isC && !on -> mod.softShadow(m.t.r).clip(shape).background(m.t.surface)
        else -> mod.clip(shape).background(if (m.isA) Color.Transparent else m.t.surface)
            .border(if (on) 2.dp else if (m.isD) 2.5.dp else m.t.stroke, if (on) m.t.accent else m.t.line, shape)
    }
    Column(mod.press(onClick = onClick).padding(14.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            if (icon != null) Ic(icon, 16.dp)
            T(title, m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink)
        }
        Tiny(sub)
    }
}

@Composable
fun NoteBox(text: String, modifier: Modifier = Modifier, icon: String = "shield", warn: Boolean = false, content: (@Composable RowScope.() -> Unit)? = null) {
    val m = muse
    val shape = RoundedCornerShape(m.t.r)
    val bg = if (warn) lerpColor(m.t.surface, m.t.warn, .14f) else m.t.surface2
    Row(
        modifier.fillMaxWidth().clip(shape).background(bg).let { if (m.isD) it.border(2.5.dp, Ink, shape) else it }.padding(horizontal = 14.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = if (content != null) Alignment.CenterVertically else Alignment.Top,
    ) {
        Ic(icon, 18.dp)
        if (content != null) content() else T(text, m.type.body.copy(fontSize = 13.sp, lineHeight = 18.sp), m.t.ink, Modifier.weight(1f))
    }
}

fun lerpColor(a: Color, b: Color, t: Float) = androidx.compose.ui.graphics.lerp(a, b, t)

@Composable
fun Field(label: String, modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) { Lbl(label); content() }
}

/** Text input (`.inp`). */
@Composable
fun Input(
    value: String, onChange: (String) -> Unit, modifier: Modifier = Modifier, placeholder: String = "", area: Boolean = false,
    password: Boolean = false, keyboard: KeyboardType = KeyboardType.Text, trailing: (@Composable () -> Unit)? = null,
) {
    val m = muse
    val shape = RoundedCornerShape(m.t.r)
    var mod = modifier.fillMaxWidth().let { if (area) it.heightIn(min = 84.dp) else it.height(52.dp) }
    mod = when {
        m.isC -> mod.softShadow(m.t.r).clip(shape).background(m.t.surface)
        else -> mod.clip(shape).background(m.t.surface).border(if (m.isD) 2.5.dp else m.t.stroke, m.t.line, shape)
    }
    Box(mod.padding(horizontal = 16.dp, vertical = if (area) 14.dp else 0.dp), contentAlignment = if (area) Alignment.TopStart else Alignment.CenterStart) {
        BasicTextField(
            value, onChange, Modifier.fillMaxWidth().padding(end = if (trailing != null) 64.dp else 0.dp),
            textStyle = m.type.body.copy(fontSize = 15.5.sp, color = m.t.ink, lineHeight = 22.sp), singleLine = !area,
            cursorBrush = SolidColor(m.t.accent), visualTransformation = if (password) PasswordVisualTransformation('•') else VisualTransformation.None,
            keyboardOptions = KeyboardOptions(keyboardType = if (password) KeyboardType.Password else keyboard),
            decorationBox = { inner ->
                if (value.isEmpty() && placeholder.isNotEmpty()) T(placeholder, m.type.body.copy(fontSize = 15.5.sp), m.t.muted.copy(alpha = .8f))
                inner()
            },
        )
        if (trailing != null) Box(Modifier.align(Alignment.CenterEnd)) { trailing() }
    }
}

/** Attestation checkbox (`.chk`): unticked by default. */
@Composable
fun Check(text: String, on: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val m = muse
    Row(modifier.fillMaxWidth().press(SoundFx.Kind.TICK, onClick = onClick), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        val shape = RoundedCornerShape(6.dp)
        Box(
            Modifier.size(22.dp).clip(shape).background(if (on) m.t.accent else Color.Transparent).border(1.5.dp, if (on) m.t.accent else m.t.line, shape),
            contentAlignment = Alignment.Center,
        ) { if (on) Ic("check", 16.dp, m.t.accentInk) }
        T(text, m.type.body.copy(fontSize = 13.5.sp, lineHeight = 19.sp), m.t.ink, Modifier.weight(1f))
    }
}

// ---------------------------------------------------------------- structure

/** Top bar (`.top`): back · title · action. */
@Composable
fun TopBar(title: String = "", onBack: (() -> Unit)? = null, backIcon: String = "back", over: Boolean = false, right: (@Composable () -> Unit)? = null) {
    val m = muse
    val color = if (over) Color.White else m.t.ink
    CompositionLocalProvider(androidx.compose.material3.LocalContentColor provides color) {
        Row(
            Modifier.fillMaxWidth().height(52.dp).let { if (m.isA && !over) it.drawBehind { drawLine(m.t.line, Offset(0f, size.height), Offset(size.width, size.height), 1.dp.toPx()) } else it }
                .padding(horizontal = 14.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (onBack != null) TbBtn(backIcon, onBack, sound = SoundFx.Kind.NAV) else Spacer(Modifier.size(44.dp))
            T(title, m.type.topTitle, color, Modifier.weight(1f), upper = m.isB, align = TextAlign.Center, maxLines = 1)
            if (right != null) right() else Spacer(Modifier.size(44.dp))
        }
    }
}

/** Bottom action area (`.dock`) fading into the background. */
@Composable
fun BoxScope.Dock(tight: Boolean = false, content: @Composable RowScope.() -> Unit) {
    val bg = muse.t.bg
    Row(
        Modifier.align(Alignment.BottomCenter).fillMaxWidth()
            .background(Brush.verticalGradient(0f to bg.copy(alpha = 0f), .3f to bg, 1f to bg))
            .navigationBarsPadding().padding(start = 20.dp, end = 20.dp, top = if (tight) 8.dp else 12.dp, bottom = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically, content = content,
    )
}

/** Theme D sticker. Renders nothing in other themes. */
@Composable
fun Sticker(text: String, color: String = "yellow", rotation: Float = -6f, modifier: Modifier = Modifier, size: Float = 15f) {
    val m = muse
    if (!m.isD) return
    val bg = when (color) { "pink" -> m.t.pink; "mint" -> m.t.mint; else -> m.t.yellow }
    val shape = RoundedCornerShape(12.dp)
    Box(modifier.rotate(rotation).hardShadow(3.dp, 12.dp).clip(shape).background(bg).border(2.5.dp, Ink, shape).padding(horizontal = 12.dp, vertical = 6.dp)) {
        T(text, m.type.hand.copy(fontSize = size.sp, lineHeight = (size * 1.15f).sp), Ink, upper = true)
    }
}

/** Theme B viewfinder corners. */
@Composable
fun BoxScope.Viewfinder(inset: Dp = 12.dp, bottomInset: Dp = inset) {
    if (!muse.isB) return
    Box(
        Modifier.matchParentSize().padding(start = inset, end = inset, top = inset, bottom = bottomInset).drawBehind {
            val l = 22.dp.toPx(); val sw = 2.dp.toPx(); val c = Color.White.copy(alpha = .85f)
            val w = size.width; val h = size.height
            fun corner(x: Float, y: Float, dx: Float, dy: Float) {
                drawLine(c, Offset(x, y), Offset(x + dx * l, y), sw)
                drawLine(c, Offset(x, y), Offset(x, y + dy * l), sw)
            }
            corner(0f, 0f, 1f, 1f); corner(w, 0f, -1f, 1f); corner(0f, h, 1f, -1f); corner(w, h, -1f, -1f)
        },
    )
}

/** Theme D doodles from the prototype (crown, heart, spark). */
object Doodles {
    private fun vec(name: String, w: Float, h: Float, d: String, fill: Color?, sw: Float = 3f) = ImageVector.Builder(name, w.dp, h.dp, w, h).apply {
        addPath(addPathNodes(d), fill = fill?.let { SolidColor(it) }, stroke = SolidColor(Ink), strokeLineWidth = sw, strokeLineCap = StrokeCap.Round,
            strokeLineJoin = androidx.compose.ui.graphics.StrokeJoin.Round)
    }.build()
    val crown by lazy { vec("crown", 56f, 44f, "M4 38L8 10l14 14L28 4l6 20 14-14 4 28z", Color(0xFFFFE14D)) }
    val heart by lazy { vec("heart", 44f, 40f, "M22 36S4 25 4 13a9 9 0 0118-3 9 9 0 0118 3c0 12-18 23-18 23z", Color(0xFFFF7EB6)) }
    val spark by lazy { vec("spark", 40f, 40f, "M20 2v10M20 28v10M2 20h10M28 20h10M7 7l7 7M26 26l7 7M33 7l-7 7M14 26l-7 7", null) }
}

@Composable
fun Doodle(v: ImageVector, modifier: Modifier = Modifier) {
    if (!muse.isD) return
    Image(v, null, modifier)
}

// ---------------------------------------------------------------- images

private val ASSETS = mapOf(
    "hero" to R.drawable.ref_hero, "face" to R.drawable.ref_face, "profile" to R.drawable.ref_profile,
    "g_front" to R.drawable.ref_g_front, "g_tq" to R.drawable.ref_g_tq, "g_side" to R.drawable.ref_g_side, "g_back" to R.drawable.ref_g_back,
    "c_front" to R.drawable.ref_c_front, "c_tq" to R.drawable.ref_c_tq, "c_face" to R.drawable.ref_c_face,
)

/** CSS `background-position: center Y%` as a Compose alignment. */
fun topBias(pct: Int) = BiasAlignment(0f, pct / 50f - 1f)

/** A reference image (bundled sample or uploaded). Crops to fill like `background-size: cover`. */
@Composable
fun RefImage(ref: ImageRef?, modifier: Modifier = Modifier, alignPct: Int = 15) {
    val align = topBias(alignPct)
    val res = ref?.asset?.let { ASSETS[it] }
    when {
        res != null -> Image(painterResource(res), null, modifier, alignment = align, contentScale = ContentScale.Crop)
        ref?.url != null -> AsyncImage(ref.url, null, modifier.background(muse.t.surface2), alignment = align, contentScale = ContentScale.Crop)
        else -> Box(modifier.background(muse.t.surface2))
    }
}

@Composable
fun AssetImage(key: String, modifier: Modifier = Modifier, alignPct: Int = 15) = RefImage(ImageRef.asset(key), modifier, alignPct)

/**
 * Neutral placeholder for source-clip thumbnails. Third-party footage is never bundled, so clips show a gradient
 * with a play glyph (or the picked clip's own frame when available).
 */
@Composable
fun ClipPlaceholder(modifier: Modifier = Modifier, seed: Int = 0, label: String? = null, showPlay: Boolean = true) {
    val palettes = listOf(
        listOf(Color(0xFF6B7A8F), Color(0xFF2E3440)), listOf(Color(0xFF9C8A78), Color(0xFF3B3129)),
        listOf(Color(0xFF7F9A8A), Color(0xFF26332C)), listOf(Color(0xFF8E7FA0), Color(0xFF2D2638)),
    )
    val p = palettes[((seed % palettes.size) + palettes.size) % palettes.size]
    Box(modifier.background(Brush.linearGradient(p)), contentAlignment = Alignment.Center) {
        if (showPlay) Box(Modifier.size(40.dp).clip(CircleShape).background(Color.White.copy(alpha = .22f)), contentAlignment = Alignment.Center) { Ic("play", 18.dp, Color.White) }
        if (label != null) T(label, muse.type.tiny.copy(fontSize = 11.sp), Color.White.copy(alpha = .9f), Modifier.align(Alignment.BottomStart).padding(8.dp))
    }
}

/** "Video" marker over a render thumbnail. */
@Composable
fun BoxScope.PlayBadge() {
    Box(Modifier.align(Alignment.Center).size(34.dp).clip(CircleShape).background(Color.Black.copy(alpha = .35f)), contentAlignment = Alignment.Center) {
        Ic("play", 16.dp, Color.White)
    }
}

// ---------------------------------------------------------------- layout helpers

/** Minimal flow row (chips wrap like CSS flex-wrap). */
@Composable
fun FlowRow(modifier: Modifier = Modifier, hGap: Dp = 8.dp, vGap: Dp = 8.dp, content: @Composable () -> Unit) {
    androidx.compose.foundation.layout.FlowRow(modifier, horizontalArrangement = Arrangement.spacedBy(hGap), verticalArrangement = Arrangement.spacedBy(vGap)) { content() }
}

@Composable
fun RowB(modifier: Modifier = Modifier, align: Alignment.Vertical = Alignment.CenterVertically, content: @Composable RowScope.() -> Unit) {
    Row(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = align) { content() }
}

/** Progress bar (`.bar`). */
@Composable
fun Bar(progress: Float, modifier: Modifier = Modifier, color: Color = muse.t.accent, height: Dp = 4.dp, track: Color = muse.t.surface2) {
    val p by animateFloatAsState(progress.coerceIn(0f, 1f), tween(450, easing = LinearEasing), label = "bar")
    val shape = RoundedCornerShape(height / 2)
    Box(modifier.height(height).clip(shape).background(track)) { Box(Modifier.fillMaxWidth(p).height(height).clip(shape).background(color)) }
}

/** The menu shown by ⋯ buttons (never jumps to Settings). */
data class MenuItem(val icon: String, val label: String, val danger: Boolean = false, val onClick: () -> Unit)

@Composable
fun MuseMenu(expanded: Boolean, onDismiss: () -> Unit, items: List<MenuItem>) {
    if (!expanded) return
    val m = muse
    val density = LocalDensity.current
    val gap = with(density) { 4.dp.roundToPx() }
    val provider = remember(gap) {
        object : androidx.compose.ui.window.PopupPositionProvider {
            override fun calculatePosition(anchorBounds: androidx.compose.ui.unit.IntRect, windowSize: androidx.compose.ui.unit.IntSize, layoutDirection: androidx.compose.ui.unit.LayoutDirection, popupContentSize: androidx.compose.ui.unit.IntSize): IntOffset {
                val x = (anchorBounds.right - popupContentSize.width).coerceIn(0, (windowSize.width - popupContentSize.width).coerceAtLeast(0))
                val below = anchorBounds.bottom + gap
                val y = if (below + popupContentSize.height <= windowSize.height) below else (anchorBounds.top - gap - popupContentSize.height).coerceAtLeast(0)
                return IntOffset(x, y)
            }
        }
    }
    Popup(popupPositionProvider = provider, onDismissRequest = onDismiss, properties = PopupProperties(focusable = true)    ) {
        val shape = RoundedCornerShape(if (m.isA) 2.dp else if (m.isC) 20.dp else if (m.isD) 16.dp else m.t.r)
        var mod = Modifier.widthIn(min = 220.dp)
        mod = if (m.isD) mod.hardShadow(5.dp, 16.dp) else mod.shadow(14.dp, shape)
        mod = mod.clip(shape).background(if (m.isB) Color(0xFF1B1E20) else m.t.surface)
        mod = when {
            m.isD -> mod.border(2.5.dp, Ink, shape)
            m.isC -> mod
            else -> mod.border(m.t.stroke, if (m.isB) Color(0xFF33373A) else m.t.line, shape)
        }
        Column(mod.padding(6.dp)) {
            items.forEach { it ->
                if (it.danger) Box(Modifier.fillMaxWidth().padding(vertical = 4.dp).height(m.t.stroke).background(m.t.line))
                Row(
                    Modifier.fillMaxWidth().height(44.dp).clip(RoundedCornerShape(m.t.r * .6f)).clickable { onDismiss(); it.onClick() }.padding(horizontal = 12.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    val c = if (it.danger) Color(0xFFC2362B) else m.t.ink
                    Ic(it.icon, 18.dp, c)
                    T(it.label, m.type.menu, c, upper = m.isA)
                }
            }
        }
    }
}

/** ⋯ button with its dropdown. */
@Composable
fun MoreMenu(items: List<MenuItem>, tint: Color = Color.Unspecified, icon: String = "more") {
    val open = remember { androidx.compose.runtime.mutableStateOf(false) }
    Box {
        TbBtn(icon, { open.value = true }, tint = tint)
        MuseMenu(open.value, { open.value = false }, items)
    }
}

/** Outlined display text with a hard drop shadow (Creator Pop names and the splash wordmark). */
@Composable
fun StrokeText(text: String, style: TextStyle, fill: Color, modifier: Modifier = Modifier, strokeWidth: Dp = 3.dp, shadow: Dp = 5.dp) {
    val d = LocalDensity.current
    Box(modifier) {
        val sw = with(d) { strokeWidth.toPx() }
        val so = with(d) { shadow.toPx() }
        T(text, style.copy(color = Ink, drawStyle = Stroke(sw * 2, join = androidx.compose.ui.graphics.StrokeJoin.Round), shadow = androidx.compose.ui.graphics.Shadow(Ink, Offset(so, so), 0f)))
        T(text, style.copy(color = fill))
    }
}

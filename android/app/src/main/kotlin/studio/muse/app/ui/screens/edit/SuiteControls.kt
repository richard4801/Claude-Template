package studio.muse.app.ui.screens.edit

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import studio.muse.app.ui.components.FlowRow
import studio.muse.app.ui.components.Ink
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.Toggle
import studio.muse.app.ui.components.press
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.scale
import kotlin.math.roundToInt

/*
 * The Edit suite's sheet controls, drawn after the approved designs (EM2–EM5): mono labels, thin sliders with a value
 * on the right, bordered chips, option rows with a switch. Themed through the app tokens, so all four themes work.
 */

/** The bottom sheet (dimmed backdrop, grab handle, title + ✓). [onDone] closes it. */
@Composable
fun SheetFrame(title: String, onDone: () -> Unit, modifier: Modifier = Modifier, scroll: Boolean = true, body: @Composable ColumnScope.() -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(topStart = m.t.rLg.coerceAtMost(20.dp), topEnd = m.t.rLg.coerceAtMost(20.dp))
    Column(
        modifier.fillMaxWidth().clip(shape).background(m.t.bg).let { if (m.isD) it.border(2.5.dp, Ink, shape) else it }
            .pointerInput(Unit) { detectTapGestures { } }
            .padding(horizontal = 16.dp),
    ) {
        Box(Modifier.fillMaxWidth().padding(top = 8.dp), contentAlignment = Alignment.Center) { Box(Modifier.size(40.dp, 4.dp).clip(RoundedCornerShape(2.dp)).background(m.t.line)) }
        Row(Modifier.fillMaxWidth().height(44.dp), verticalAlignment = Alignment.CenterVertically) {
            T(title, m.type.h3, m.t.ink, Modifier.weight(1f), maxLines = 1)
            Box(Modifier.size(48.dp).press(onClick = onDone).semantics { contentDescription = "Done" }, contentAlignment = Alignment.CenterEnd) { EIc("check", 20.dp, m.t.ink) }
        }
        Column(
            (if (scroll) Modifier.verticalScroll(rememberScrollState()) else Modifier).padding(bottom = 28.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp), content = body,
        )
    }
}

/** A section label: sentence case on the type scale (design direction; was mono caps). */
@Composable
fun SuiteLabel(text: String, modifier: Modifier = Modifier, color: Color = muse.t.ink) {
    val m = muse
    T(text, m.scale.label, color, modifier, maxLines = 1)
}

/** A value in mono (`0.5 s`, `−3 dB`). */
@Composable
fun SuiteValue(text: String, modifier: Modifier = Modifier) = T(text, muse.type.mono.copy(fontSize = 12.sp), muse.t.ink, modifier, maxLines = 1)

/**
 * A slider 0–1 with an optional label row ("VOLUME · VOICE … −3 dB"). [onChange] gets (value, done): done = the finger
 * lifted (that is when a drag becomes one undo step).
 */
@Composable
fun SuiteSlider(value: Float, onChange: (Float, Boolean) -> Unit, modifier: Modifier = Modifier, label: String? = null, valueText: String? = null, enabled: Boolean = true) {
    val m = muse
    val cb by rememberUpdatedState(onChange)
    Column(modifier.fillMaxWidth()) {
        if (label != null || valueText != null) Row(verticalAlignment = Alignment.CenterVertically) {
            if (label != null) SuiteLabel(label, Modifier.weight(1f), m.t.ink) else Spacer(Modifier.weight(1f))
            if (valueText != null) SuiteValue(valueText)
        }
        val w = remember { mutableFloatStateOf(1f) }
        val last = remember { mutableFloatStateOf(value) }
        fun at(x: Float) = (x / w.floatValue).coerceIn(0f, 1f)
        val frac = value.coerceIn(0f, 1f)
        val trackH = when { m.isA -> 2.dp; m.isC -> 8.dp; m.isD -> 8.dp; else -> 4.dp }
        val thumb = when { m.isA -> 16.dp; m.isC -> 22.dp; m.isD -> 20.dp; else -> 18.dp }
        val fill = when { m.isD -> m.t.blue; else -> m.t.accent }
        Box(
            Modifier.fillMaxWidth().height(28.dp).onSizeChanged { w.floatValue = it.width.toFloat().coerceAtLeast(1f) }
                .let { if (!enabled) it else it.pointerInput(Unit) { detectTapGestures { o -> cb(at(o.x), true) } }
                    .pointerInput(Unit) {
                        detectDragGestures(
                            onDragStart = { o -> last.floatValue = at(o.x); cb(last.floatValue, false) },
                            onDragEnd = { cb(last.floatValue, true) }, onDragCancel = { cb(last.floatValue, true) },
                        ) { c, _ -> last.floatValue = at(c.position.x); cb(last.floatValue, false) }
                    } },
            contentAlignment = Alignment.CenterStart,
        ) {
            val shape = RoundedCornerShape(trackH / 2)
            Box(Modifier.fillMaxWidth().height(trackH).clip(shape).background(if (m.isA) m.t.line else m.t.surface2).let { if (m.isD) it.border(1.5.dp, Ink, shape) else it }) {
                Box(Modifier.fillMaxWidth(frac).height(trackH).background(if (enabled) fill else m.t.muted))
            }
            val density = LocalDensity.current
            Box(
                Modifier.offset { IntOffset(((w.floatValue * frac) - with(density) { thumb.toPx() } / 2).roundToInt(), 0) }.size(thumb).clip(CircleShape)
                    .background(m.t.surface).border(2.dp, if (enabled) fill else m.t.muted, CircleShape),
            )
        }
    }
}

/** A bordered chip; selected = filled (ink on theme A like the design, the theme's accent elsewhere). */
@Composable
fun SuiteChip(text: String, on: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    val m = muse
    val shape = RoundedCornerShape(if (m.isA) 2.dp else if (m.isB) 8.dp else 999.dp)
    val (bg, fg) = when {
        !on -> m.t.surface to (if (enabled) m.t.ink else m.t.muted)
        m.isA -> m.t.ink to m.t.bg
        m.isD -> m.t.blue to Color.White
        m.isC -> m.t.accent to Color.White
        else -> m.t.accent to m.t.accentInk
    }
    Box(
        modifier.height(48.dp).clip(shape).background(bg).border(if (m.isD) 2.dp else 1.dp, if (on) bg else if (m.isD) Ink else m.t.line, shape)
            .press(enabled = enabled, onClick = onClick).padding(horizontal = 12.dp),
        contentAlignment = Alignment.Center,
    ) { T(text, m.type.body.copy(fontSize = 13.sp), fg, maxLines = 1) }
}

@Composable
fun SuiteChips(items: List<Pair<String, String>>, selected: String?, onSelect: (String) -> Unit, enabled: Boolean = true) {
    FlowRow(hGap = 6.dp, vGap = 6.dp) { items.forEach { (k, l) -> SuiteChip(l, k == selected, { onSelect(k) }, enabled = enabled) } }
}

/** A segmented control in the design's style (mono caps on theme A). */
@Composable
fun SuiteSeg(options: List<Pair<String, String>>, selected: String?, onSelect: (String) -> Unit, modifier: Modifier = Modifier, height: Dp = 30.dp, fill: Boolean = false) {
    val m = muse
    val shape = RoundedCornerShape(if (m.isA) 0.dp else if (m.isB) 8.dp else 999.dp)
    Row(modifier.clip(shape).background(m.t.surface).border(if (m.isD) 2.dp else 1.dp, if (m.isD) Ink else m.t.line, shape)) {
        options.forEach { (k, l) ->
            val on = k == selected
            val (bg, fg) = when {
                !on -> Color.Transparent to m.t.muted
                m.isA -> m.t.ink to m.t.bg
                m.isD -> m.t.blue to Color.White
                m.isC -> m.t.accent to Color.White
                else -> m.t.accent to m.t.accentInk
            }
            Box(
                (if (fill) Modifier.weight(1f) else Modifier.width((l.length * 9 + 22).dp.coerceAtLeast(48.dp))).minimumInteractiveComponentSize().height(height).background(bg).press { onSelect(k) },
                contentAlignment = Alignment.Center,
            ) {
                T(l, m.scale.label, fg, maxLines = 1, align = TextAlign.Center)
            }
        }
    }
}

/** Title + subtitle + switch (`opt_row`). */
@Composable
fun OptRow(title: String, sub: String?, on: Boolean, onToggle: () -> Unit, modifier: Modifier = Modifier, trailing: (@Composable () -> Unit)? = null) {
    val m = muse
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(title, m.type.body.copy(fontSize = 13.5.sp, fontWeight = FontWeight.Bold), m.t.ink)
            if (sub != null) T(sub, m.type.tiny.copy(fontSize = 12.sp), m.t.muted)
        }
        if (trailing != null) trailing() else Toggle(on, onToggle)
    }
}

/** A full-width bordered action (`.btn`), with an icon. */
@Composable
fun SuiteButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, icon: String? = null, primary: Boolean = false, enabled: Boolean = true, height: Dp = 48.dp) {
    val m = muse
    val shape = RoundedCornerShape(if (m.isA) 2.dp else if (m.isB) 10.dp else 999.dp)
    val bg = if (primary) m.t.cta else m.t.surface
    val fg = if (primary) m.t.ctaInk else m.t.ink
    Row(
        modifier.height(height).clip(shape).background(bg).border(if (m.isD) 2.dp else 1.dp, if (primary) bg else if (m.isD) Ink else m.t.line, shape)
            .press(enabled = enabled, onClick = onClick).padding(horizontal = 14.dp),
        horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) { EIc(icon, 15.dp, if (enabled) fg else m.t.muted); Spacer(Modifier.width(8.dp)) }
        T(text, m.scale.label, if (enabled) fg else m.t.muted, maxLines = 1)
    }
}

/**
 * An AI helper's button with its price shown before it runs ("Auto-captions · about $0.02" / "… · Free"), its progress
 * while it runs, and its error after.
 */
@Composable
fun AiButton(label: String, task: AiTask?, onRun: () -> Unit, modifier: Modifier = Modifier, icon: String? = null) { // AI has no icon (design-direction §5)
    val m = muse
    val running = task?.running == true
    val price = task?.price
    Column(modifier, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        SuiteButton(
            when {
                running -> "$label · ${task?.phase?.ifBlank { null } ?: "Working"} ${task?.progress ?: 0} %"
                price != null -> "$label · $price"
                else -> label
            },
            onRun, Modifier.fillMaxWidth(), icon = icon, enabled = !running,
        )
        task?.error?.let { T(it, m.type.tiny.copy(fontSize = 12.sp), m.t.warn) }
    }
}

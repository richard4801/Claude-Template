package studio.muse.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import studio.muse.app.ui.components.Ink
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.hardShadow
import studio.muse.app.ui.components.press
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse

val VIDEO_TOOLS = listOf("model" to "Model", "outfit" to "Outfit", "bg" to "Background", "audio" to "Sound", "quality" to "Quality")
val SHOOT_TOOLS = listOf("model" to "Model", "outfit" to "Outfit", "bg" to "Scene", "camera" to "Camera", "light" to "Light", "spark" to "Prompt")

/** The tool strip under the canvas (`.tools`), styled per theme. */
@Composable
fun ToolStrip(tools: List<Pair<String, String>>, current: String, onSelect: (String) -> Unit) {
    val m = muse
    val dColors = listOf(m.t.accent, Color.White, Color(0xFF8FB2FF), m.t.yellow, Color.White, Color.White)
    Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 4.dp), horizontalArrangement = Arrangement.SpaceBetween) {
        tools.forEachIndexed { i, (k, l) ->
            val on = k == current
            val labelStyle = m.type.tool.copy(
                fontWeight = if (on && m.isD) FontWeight.ExtraBold else null,
                textDecoration = if (on && (m.isB || m.isD)) TextDecoration.Underline else null,
            )
            when {
                m.isC -> {
                    val shape = RoundedCornerShape(16.dp)
                    // Five tools get wider tiles so "Background" isn't cut on a 360 dp phone; six (Photoshoot) still fit.
                    Column(
                        Modifier.width(if (tools.size <= 5) 62.dp else 54.dp).height(64.dp).shadow(6.dp, shape, ambientColor = Color(0x1A50463A), spotColor = Color(0x1A50463A)).clip(shape)
                            .background(if (on) m.t.accent else m.t.surface).press { onSelect(k) },
                        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
                    ) {
                        val c = if (on) Color.White else m.t.muted
                        Ic(k, 20.dp, c); T(l, labelStyle.copy(fontSize = 10.5.sp), c, maxLines = 1)
                    }
                }
                m.isD -> Column(Modifier.width(54.dp).press { onSelect(k) }, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    val shape = RoundedCornerShape(12.dp)
                    Box(
                        Modifier.size(42.dp).let { if (on) it.hardShadow(3.dp, 12.dp) else it }.alpha(if (on) 1f else .75f).clip(shape)
                            .background(dColors[i % dColors.size]).border(2.5.dp, Ink, shape),
                        contentAlignment = Alignment.Center,
                    ) { Ic(k, 20.dp, Ink) }
                    androidx.compose.material3.Text(l, style = labelStyle, color = if (on) Ink else m.t.muted, maxLines = 1, softWrap = false, overflow = androidx.compose.ui.text.style.TextOverflow.Visible, modifier = Modifier.wrapContentWidth(unbounded = true))
                }
                // Six tools (Photoshoot) share the width equally so labels don't run together at 360 dp (UX audit A-ToolStrip).
                else -> Column((if (tools.size > 5) Modifier.weight(1f) else Modifier.width(62.dp)).press { onSelect(k) }, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    val c = if (on) m.t.accent else m.t.muted
                    Ic(k, 20.dp, c)
                    androidx.compose.material3.Text(if (m.isA) l.uppercase() else l, style = labelStyle, color = c, maxLines = 1, softWrap = false, overflow = androidx.compose.ui.text.style.TextOverflow.Visible, modifier = Modifier.wrapContentWidth(unbounded = true))
                }
            }
        }
    }
}

/** Bottom sheet that holds the current tool's controls (`.bsheet`). */
@Composable
fun ColumnScope.BSheet(gap: Dp = 12.dp, content: @Composable ColumnScope.() -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(topStart = if (m.isA) 0.dp else m.t.rLg, topEnd = if (m.isA) 0.dp else m.t.rLg)
    var mod = Modifier.weight(1f).fillMaxWidth().padding(top = 10.dp)
    if (!m.isA && !m.isD) mod = mod.shadow(if (m.isB) 24.dp else 16.dp, shape)
    mod = mod.clip(shape).background(
        when {
            m.isB -> Brush.verticalGradient(listOf(Color(0xFF1C1F21), Color(0xFF141617)))
            m.isC -> Brush.verticalGradient(listOf(m.t.bg, m.t.bg))
            else -> Brush.verticalGradient(listOf(m.t.surface, m.t.surface))
        },
    )
    mod = mod.drawBehind {
        val (c, w) = when {
            m.isA -> m.t.ink to 1.dp
            m.isD -> Ink to 2.5.dp
            m.isC -> Color.Transparent to 0.dp
            else -> m.t.line to 1.dp
        }
        if (w > 0.dp) drawLine(c, Offset(0f, 0f), Offset(size.width, 0f), w.toPx())
    }
    Column(mod.verticalScroll(rememberScrollState()).padding(start = 20.dp, end = 20.dp, top = 10.dp, bottom = 140.dp), verticalArrangement = Arrangement.spacedBy(gap)) {
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { Box(Modifier.size(40.dp, 5.dp).clip(RoundedCornerShape(3.dp)).background(m.t.line)) }
        content()
    }
}

/** The preview canvas (`.canvas`). */
@Composable
fun Canvas(height: Dp, content: @Composable BoxScope.() -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(m.t.rLg)
    Box(
        Modifier.fillMaxWidth().padding(horizontal = 14.dp).height(height).let { if (m.isD) it.hardShadow(5.dp, m.t.rLg) else it }.clip(shape)
            .let { if (m.isD) it.border(2.5.dp, Ink, shape) else it },
        content = content,
    )
}

/** Mono readout text over the canvas (Camera Body). */
@Composable
fun Readout(text: String, modifier: Modifier = Modifier) {
    T(text, muse.type.mono.copy(fontSize = 11.5.sp), Color.White, modifier)
}

@Composable
fun BoxScope.FullImage(content: @Composable BoxScope.() -> Unit) = Box(Modifier.fillMaxSize(), content = content)

package studio.muse.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import studio.muse.app.AppContainer
import studio.muse.app.data.WarmGpu
import studio.muse.app.data.WarmUi
import studio.muse.app.data.WarmWarning
import studio.muse.app.ui.components.Cta
import studio.muse.app.ui.components.Cta2
import studio.muse.app.ui.components.H3
import studio.muse.app.ui.components.Ink
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.Tiny
import studio.muse.app.ui.components.Toggle
import studio.muse.app.ui.components.hardShadow
import studio.muse.app.ui.components.lerpColor
import studio.muse.app.ui.components.press
import studio.muse.app.ui.components.softShadow
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse
import studio.muse.core.Pricing
import kotlin.math.max
import kotlin.math.roundToInt

// Keep GPU warm (plans/backend.md): the persistent bar, the 5-minute warning banner, the nudge and the confirm dialog,
// and the switch in the video studio. MuseApp hosts the bar, banner and dialogs on every screen.

/** "About $4/hour from your credit while it's on, and it turns off by itself after 20 min without renders." */
fun warmCostLine(w: WarmGpu?): String {
    val rate = (w?.ratePerHour ?: 3.99).roundToInt().coerceAtLeast(1)
    return "About $$rate/hour from your credit while it's on, and it turns off by itself after ${w?.idleMinutes ?: 20} min without renders."
}

/** Minutes since the start and the cost so far, computed live between the server's per-minute ticks. */
fun warmLive(w: WarmGpu, now: Long): Pair<Int, Double> {
    val minutes = max(w.minutes, w.startedAt?.let { ((now - it) / 60_000).toInt() } ?: 0)
    return minutes to max(w.costUsd, w.ratePerHour * minutes / 60.0)
}

/** "GPU warm · 42 min · $2.80 so far · Turn off" ("Starting… · 2 min · $0.13 so far" while the pod boots). */
@Composable
fun WarmBar(w: WarmGpu, onTurnOff: () -> Unit, modifier: Modifier = Modifier, statusPad: Boolean = true) {
    val m = muse
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(w.startedAt) { while (true) { delay(5_000); now = System.currentTimeMillis() } }
    val (minutes, cost) = warmLive(w, now)
    val bg = if (m.isD) m.t.yellow else m.t.ink
    val fg = if (m.isD) Ink else m.t.bg
    val dot = if (w.starting) m.t.warn else if (m.isD) m.t.blue else m.t.accent
    val label = (if (w.starting) "Starting…" else if (w.state == "stopping") "Turning off…" else "GPU warm") + " · $minutes min · ${Pricing.money(cost)} so far"
    Row(
        modifier.fillMaxWidth().background(bg).let { if (statusPad) it.statusBarsPadding() else it }.padding(horizontal = 16.dp, vertical = 9.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(8.dp).clip(CircleShape).background(dot))
        T(label, m.type.tiny.copy(fontSize = 13.sp, fontWeight = FontWeight.SemiBold), fg, Modifier.weight(1f), maxLines = 1)
        T("Turn off", m.type.tiny.copy(fontSize = 13.sp, fontWeight = FontWeight.Bold, textDecoration = TextDecoration.Underline), fg,
            Modifier.press(onClick = onTurnOff).padding(vertical = 4.dp, horizontal = 2.dp), maxLines = 1)
    }
}

/** The 5-minute warning: "Warm GPU turns off in 5 min (no renders)" [Keep warm]. */
@Composable
fun WarmWarningBanner(w: WarmWarning, onKeepWarm: () -> Unit, onDismiss: () -> Unit, modifier: Modifier = Modifier) {
    val m = muse
    val shape = RoundedCornerShape(m.t.r)
    var mod = modifier.padding(horizontal = 12.dp, vertical = 8.dp).fillMaxWidth()
    mod = when {
        m.isD -> mod.hardShadow(3.dp, m.t.r).clip(shape).background(Color.White).border(2.5.dp, Ink, shape)
        m.isC -> mod.softShadow(m.t.r).clip(shape).background(m.t.surface)
        else -> mod.clip(shape).background(lerpColor(m.t.surface, m.t.warn, .16f)).border(m.t.stroke, m.t.line, shape)
    }
    Row(mod.padding(start = 14.dp, end = 8.dp, top = 10.dp, bottom = 10.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
        Ic("light", 18.dp, m.t.ink)
        Column(Modifier.weight(1f)) {
            T(w.message.ifBlank { "Warm GPU turns off in 5 min" }, m.type.body.copy(fontSize = 13.5.sp, fontWeight = FontWeight.SemiBold), m.t.ink, maxLines = 2)
            Tiny(if (w.reason == "cap") "Keep warm extends its time limit once." else "No renders on it lately.")
        }
        Cta2("Keep warm", onKeepWarm, height = 40.dp)
        Box(Modifier.size(32.dp).press(onClick = onDismiss), contentAlignment = Alignment.Center) { T("✕", m.type.tiny, m.t.muted) }
    }
}

/**
 * The nudge ([WarmUi.NUDGE]) when creating starts, or the cost warning ([WarmUi.CONFIRM]) on every manual switch-on.
 * Drawn inside the app (not a system dialog) so it themes with the app; tapping outside is "Not now" / "Cancel".
 */
@Composable
fun BoxScope.WarmPrompt(kind: String, w: WarmGpu?, onYes: () -> Unit, onNo: () -> Unit) {
    val m = muse
    val nudge = kind == WarmUi.NUDGE
    Box(
        Modifier.matchParentSize().background(Color.Black.copy(alpha = .45f))
            .clickable(remember { MutableInteractionSource() }, null, role = Role.Button, onClick = onNo),
        contentAlignment = Alignment.Center,
    ) {
        val shape = RoundedCornerShape(if (m.isA) 2.dp else m.t.r * 1.4f)
        var card = Modifier.padding(24.dp).widthIn(max = 420.dp).fillMaxWidth()
        card = when {
            m.isD -> card.hardShadow(5.dp, m.t.r * 1.4f).clip(shape).background(Color.White).border(2.5.dp, Ink, shape)
            m.isC -> card.softShadow(m.t.r * 1.4f, 18.dp).clip(shape).background(m.t.surface)
            m.isB -> card.clip(shape).background(m.t.surface).border(1.dp, m.t.line, shape)
            else -> card.clip(shape).background(m.t.bg).border(1.dp, m.t.ink, shape)
        }
        Column(
            card.clickable(remember { MutableInteractionSource() }, null) {}.padding(22.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                Ic("light", 22.dp, if (m.isD) m.t.blue else m.t.accent)
                H3(if (nudge) "Warm up a GPU?" else "Keep GPU warm?")
            }
            T(if (nudge) "Warm up a GPU now so your render starts right away? ${warmCostLine(w)}" else warmCostLine(w), m.type.body, m.t.ink)
            Tiny("It bills from the moment it starts booting (3–6 min). Renders on it aren't charged again.")
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Cta2(if (nudge) "Not now" else "Cancel", onNo, Modifier.weight(1f), height = 50.dp)
                Cta(if (nudge) "Warm up" else "Turn on", onYes, Modifier.weight(1f))
            }
        }
    }
}

/** The manual switch in the video studio. Every switch-on asks first ([WarmUi.confirm]); switching off is immediate. */
@Composable
fun WarmSwitchRow(container: AppContainer, w: WarmGpu?, modifier: Modifier = Modifier) {
    w ?: return // a server without Keep GPU warm
    val m = muse
    val scope = rememberCoroutineScope()
    val (_, cost) = warmLive(w, System.currentTimeMillis())
    val sub = when {
        !w.allowed && !w.on -> "Only the studio owner can turn this on"
        w.starting -> "Starting… usually 3–6 min · ${Pricing.money(cost)} so far"
        w.on -> "On · renders start right away · ${Pricing.money(cost)} so far"
        else -> "Renders start right away · about ${Pricing.money(w.ratePerHour)}/hour"
    }
    Row(
        modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        Ic("light", 20.dp, if (w.on) (if (m.isD) m.t.blue else m.t.accent) else m.t.muted)
        Column(Modifier.weight(1f)) {
            T("Keep GPU warm", m.type.body.copy(fontSize = 14.5.sp, fontWeight = FontWeight.SemiBold), m.t.ink, maxLines = 1)
            T(sub, m.type.tiny, m.t.muted, maxLines = 1)
        }
        Toggle(w.on, {
            when {
                w.on -> scope.launch { container.repo.setWarm(false) }
                !w.allowed -> container.repo.toast("Only the studio owner can keep a GPU warm")
                else -> container.warmUi.confirm()
            }
        }, Modifier.graphicsLayer { alpha = if (!w.allowed && !w.on) .45f else 1f })
    }
}

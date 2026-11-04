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

// Keep add-on engine ready (was Keep GPU warm; plans/api.md "App clean-up" §6), owner only: the small indicator while
// it's on, the 5-minute warning, the cost warning on switch-on, and the switch in Settings → Engines.
// MuseApp hosts the indicator, banner and dialog for the owner; members never see any of it.

/** "About $4/hour from the studio balance while it's on, and it turns off by itself after 20 min without renders." */
fun warmCostLine(w: WarmGpu?): String {
    val rate = (w?.ratePerHour ?: 3.99).roundToInt().coerceAtLeast(1)
    return "Keeps the add-on engine ready so Edit renders start right away. About $$rate/hour from the studio balance while it's on, and it turns off by itself after ${w?.idleMinutes ?: 20} min without renders."
}

/** Minutes since the start and the cost so far, computed live between the server's per-minute ticks. */
fun warmLive(w: WarmGpu, now: Long): Pair<Int, Double> {
    val minutes = max(w.minutes, w.startedAt?.let { ((now - it) / 60_000).toInt() } ?: 0)
    return minutes to max(w.costUsd, w.ratePerHour * minutes / 60.0)
}

/** "Add-on engine ready · 42 min · $2.80 · Turn off" ("Getting ready… · 2 min · $0.13" while it starts). Owner only. */
@Composable
fun WarmBar(w: WarmGpu, onTurnOff: () -> Unit, modifier: Modifier = Modifier, statusPad: Boolean = true) {
    val m = muse
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(w.startedAt) { while (true) { delay(5_000); now = System.currentTimeMillis() } }
    val (minutes, cost) = warmLive(w, now)
    val bg = if (m.isD) m.t.yellow else m.t.ink
    val fg = if (m.isD) Ink else m.t.bg
    val dot = if (w.starting) m.t.warn else if (m.isD) m.t.blue else m.t.accent
    val label = (if (w.starting) "Getting ready…" else if (w.state == "stopping") "Turning off…" else "Add-on engine ready") + " · $minutes min · ${Pricing.money(cost)}"
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

/** The 5-minute warning (owner): "Add-on engine turns off in 5 min (no renders)" [Keep ready]. */
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
            T(w.message.ifBlank { "Add-on engine turns off in 5 min" }.replace("Warm GPU", "Add-on engine"), m.type.body.copy(fontSize = 13.5.sp, fontWeight = FontWeight.SemiBold), m.t.ink, maxLines = 2)
            Tiny(if (w.reason == "cap") "Keep ready extends its time limit once." else "No renders on it lately.")
        }
        Cta2("Keep ready", onKeepWarm, height = 40.dp)
        Box(Modifier.size(32.dp).press(onClick = onDismiss), contentAlignment = Alignment.Center) { T("✕", m.type.tiny, m.t.muted) }
    }
}

/**
 * The cost warning ([WarmUi.CONFIRM]) on every switch-on (owner). Drawn inside the app (not a system dialog) so it themes
 * with the app; tapping outside is "Cancel".
 */
@Composable
fun BoxScope.WarmPrompt(kind: String, w: WarmGpu?, onYes: () -> Unit, onNo: () -> Unit) {
    val m = muse
    val nudge = false
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
                H3("Keep add-on engine ready?")
            }
            T(warmCostLine(w), m.type.body, m.t.ink)
            Tiny("It bills from the moment it starts getting ready (3–6 min). Renders on it aren't charged again.")
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Cta2(if (nudge) "Not now" else "Cancel", onNo, Modifier.weight(1f), height = 50.dp)
                Cta("Turn on", onYes, Modifier.weight(1f))
            }
        }
    }
}

/** The owner's switch in Settings → Engines. Every switch-on asks first ([WarmUi.confirm]); switching off is immediate. */
@Composable
fun WarmSwitchRow(container: AppContainer, w: WarmGpu?, modifier: Modifier = Modifier) {
    w ?: return // a server without it, or not the owner
    val m = muse
    val scope = rememberCoroutineScope()
    val (_, cost) = warmLive(w, System.currentTimeMillis())
    val sub = when {
        !w.allowed && !w.on -> "Only the studio owner can turn this on"
        w.starting -> "Getting ready… usually 3–6 min · ${Pricing.money(cost)} so far"
        w.on -> "On · Edit renders start right away · ${Pricing.money(cost)} so far"
        else -> "Edit renders start right away · about ${Pricing.money(w.ratePerHour)}/hour"
    }
    Row(
        modifier.fillMaxWidth().padding(vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        Ic("light", 20.dp, if (w.on) (if (m.isD) m.t.blue else m.t.accent) else m.t.muted)
        Column(Modifier.weight(1f)) {
            T("Keep add-on engine ready", m.type.body.copy(fontSize = 14.5.sp, fontWeight = FontWeight.SemiBold), m.t.ink, maxLines = 1)
            T(sub, m.type.tiny, m.t.muted, maxLines = 1)
        }
        Toggle(w.on, {
            when {
                w.on -> scope.launch { container.repo.setWarm(false) }
                !w.allowed -> container.repo.toast("Only the studio owner can do that")
                else -> container.warmUi.confirm()
            }
        }, Modifier.graphicsLayer { alpha = if (!w.allowed && !w.on) .45f else 1f })
    }
}

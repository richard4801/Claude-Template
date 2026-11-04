package studio.muse.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
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
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import studio.muse.app.AppContainer
import studio.muse.app.data.Balance
import studio.muse.app.data.Job
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Nav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.TabBar
import studio.muse.app.ui.components.*
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse
import studio.muse.core.Pricing
import studio.muse.core.formatClock
import studio.muse.core.formatTimecode

data class QueueState(
    val running: List<Job> = emptyList(),
    val done: List<Job> = emptyList(),
    val failed: Job? = null,
    val balance: Balance = Balance(0.0, 0.0),
    val loaded: Boolean = false,
) {
    val all get() = running + done
    val empty get() = loaded && running.isEmpty() && done.isEmpty() && failed == null
}

class QueueViewModel(private val c: AppContainer) : ViewModel() {
    val state: StateFlow<QueueState> = combine(c.repo.state, c.drafts.dismissedFails) { s, dismissed ->
        QueueState(
            s.jobs.filter { it.running }, s.jobs.filter { it.done }, s.jobs.firstOrNull { it.failed && it.id !in dismissed }, s.balance, s.loaded,
        )
    }.stateIn(viewModelScope, SharingStarted.Eagerly, QueueState())

    fun open(j: Job, nav: Nav) {
        if (j.done) nav.go(Routes.result(j.id))
        else c.repo.toast("Still rendering · ${j.phase.ifBlank { "starting" }}")
    }

    fun retry(j: Job, nav: Nav) {
        c.drafts.dismissedFails.update { it + j.id }
        c.drafts.loadJob(j)
        c.repo.toast("Retrying · settings loaded")
        nav.go(Routes.DIRECT)
    }

    fun rerun(j: Job, nav: Nav) { c.drafts.loadJob(j); c.repo.toast("Settings loaded · tap Generate"); nav.go(Routes.DIRECT) }
    fun remove(j: Job) = viewModelScope.launch { if (c.repo.removeJob(j.id) != null) c.repo.toast("Removed") }
    fun toast(s: String) = c.repo.toast(s)
}

@Composable
fun QueueScreen() {
    val c = LocalContainer.current
    val vm: QueueViewModel = viewModel { QueueViewModel(c) }
    val s by vm.state.collectAsState()
    val m = muse
    ScreenBox {
        when {
            m.isA -> QueueA(vm, s)
            m.isB -> QueueB(vm, s)
            m.isC -> QueueC(vm, s)
            else -> QueueD(vm, s)
        }
        TabBar(Routes.QUEUE)
    }
}

@Composable
private fun jobMenu(vm: QueueViewModel, j: Job): List<MenuItem> {
    val nav = LocalNav.current
    val clip = LocalClipboardManager.current
    return listOf(
        MenuItem("play", "Watch") { if (j.done) nav.go(Routes.result(j.id)) else vm.toast("Still rendering") },
        MenuItem("retry", "Run again with same settings") { vm.rerun(j, nav) },
        MenuItem("spark", "Copy prompt") { clip.setText(AnnotatedString(j.prompt.ifBlank { j.title })); vm.toast("Prompt copied") },
        MenuItem("shield", "Remove from list", danger = true) { vm.remove(j) },
    )
}

/** Failed render: refund shown, one-tap Retry with the same settings. */
@Composable
private fun FailCard(vm: QueueViewModel, j: Job) {
    val m = muse
    val nav = LocalNav.current
    NoteBox("", warn = true) {
        Column(Modifier.weight(1f)) {
            T("Render failed · ${j.title}", m.type.body.copy(fontSize = 13.sp, fontWeight = FontWeight.Bold), m.t.ink)
            Tiny("${j.error ?: "The GPU disconnected."} ${Pricing.money(j.refunded)} refunded.", color = m.t.ink)
        }
        Cta2("Retry", { vm.retry(j, nav) }, height = 40.dp)
    }
}

@Composable
private fun EmptyQueue() {
    val m = muse
    val nav = LocalNav.current
    val shape = RoundedCornerShape(m.t.r)
    Column(
        Modifier.fillMaxWidth().let { if (m.isC) it.softShadow(m.t.r) else it }.clip(shape).background(m.t.surface)
            .let { if (m.isC) it else it.border(if (m.isD) 2.5.dp else m.t.stroke, m.t.line, shape) }.padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        T("Queue", m.type.body, m.t.muted)
        T("Nothing rendering right now", m.type.body.copy(fontSize = 22.sp, fontWeight = FontWeight.Medium, lineHeight = 26.sp), m.t.ink)
        Tiny("You're not being charged.")
        Cta2("New video", { nav.go(Routes.SOURCE) }, Modifier.fillMaxWidth().padding(top = 6.dp), icon = "plus")
    }
}

private fun Job.clockText() = if (done) formatTimecode(totalSeconds) else formatClock(etaSeconds ?: secondsLeft)

/** "#2 in line · done in ~6:30", "Paused: the studio's GPU credit is low", or the server's phase line. */
fun Job.statusLine(): String = when {
    paused -> studio.muse.app.data.ErrorText.PAUSED_LOW_BALANCE
    state == "running" && queuePosition != null -> "#$queuePosition in line for a GPU" + (etaSeconds?.let { " · done in ~${formatClock(it)}" } ?: "")
    else -> phase
}

/** The job's cost; GPU warm-up (charged separately when the member pays it) gets its own line. */
fun Job.costLines(): List<String> = listOfNotNull(
    "Render ${Pricing.money(cost)}${if (refunded > 0) " · ${Pricing.money(refunded)} refunded" else ""}",
    warmupCost?.takeIf { it > 0 }?.let { "GPU warm-up ${Pricing.money(it)}" },
)

@Composable
private fun JobMeta(j: Job) {
    val m = muse
    if (j.running) T(j.statusLine(), m.type.tiny, if (j.paused) m.t.warn else m.t.muted, maxLines = 2)
    j.costLines().forEach { Tiny(it) }
}

// ---------------- A · Editorial: big serif title, hairline rows
@Composable
private fun QueueA(vm: QueueViewModel, s: QueueState) {
    val m = muse
    val nav = LocalNav.current
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().height(52.dp).drawBehind { drawLine(m.t.line, Offset(0f, size.height), Offset(size.width, size.height), 1.dp.toPx()) }.padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically) {
            Wordmark(); Spacer(Modifier.weight(1f))
            T("RENDER QUEUE ", m.type.mono.copy(fontSize = 12.5.sp, letterSpacing = .12.em), m.t.ink); T("●", m.type.mono, m.t.accent)
        }
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 120.dp)) {
            Row(Modifier.fillMaxWidth().padding(top = 6.dp), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.SpaceBetween) {
                T("YOUR\nRENDERS", m.type.h2.copy(fontSize = 58.sp, lineHeight = 52.sp), m.t.ink)
                T("${if (s.running.isNotEmpty()) "${s.running.size} RUNNING · " else ""}${s.done.size} DONE", m.type.mono.copy(fontSize = 12.5.sp), m.t.ink)
            }
            if (s.empty) { Spacer(Modifier.height(16.dp)); EmptyQueue() }
            s.failed?.let { Spacer(Modifier.height(14.dp)); FailCard(vm, it) }
            s.all.forEach { j ->
                Row(
                    Modifier.fillMaxWidth().drawBehind { drawLine(m.t.line, Offset(0f, size.height), Offset(size.width, size.height), 1.dp.toPx()) }.press { vm.open(j, nav) }.padding(vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    Box(Modifier.size(56.dp, 70.dp)) { RefImage(j.thumb, Modifier.fillMaxSize(), 20) }
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        T(j.title, m.type.body.copy(fontWeight = FontWeight.Medium), m.t.ink)
                        T("9:16 · ${j.engineLabel.uppercase()}", m.type.mono.copy(fontSize = 11.5.sp, letterSpacing = .08.em), m.t.muted)
                        RowB { Bar((j.progress / 100).toFloat(), Modifier.weight(1f), m.t.ink, 2.dp, m.t.line); Spacer(Modifier.width(8.dp)); T("${Pricing.jsRound(j.progress)}%", m.type.mono.copy(fontSize = 12.5.sp), m.t.ink) }
                        JobMeta(j)
                    }
                    MoreMenu(jobMenu(vm, j), tint = m.t.muted)
                }
            }
            Cta2("New video", { nav.go(Routes.SOURCE) }, Modifier.fillMaxWidth().padding(top = 16.dp), icon = "plus")
        }
    }
}

// ---------------- B · Camera Body: time codes, tally lights, KPIs
@Composable
private fun QueueB(vm: QueueViewModel, s: QueueState) {
    val m = muse
    val nav = LocalNav.current
    Column(Modifier.fillMaxSize()) {
        TopBar("Render queue")
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 120.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            RowB {
                T(if (s.running.isNotEmpty()) "${s.running.size} ACTIVE" else "NOTHING RUNNING", m.type.mono.copy(fontSize = 12.5.sp), m.t.accent)
                Pill(if (s.running.isNotEmpty()) "● Rendering" else "Idle", if (s.running.isNotEmpty()) "good" else "")
            }
            if (s.empty) EmptyQueue()
            s.all.forEach { j ->
                val shape = RoundedCornerShape(m.t.r)
                Row(
                    Modifier.fillMaxWidth().clip(shape).background(m.t.surface).border(1.dp, m.t.line, shape).press { vm.open(j, nav) }.padding(10.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Box(Modifier.size(54.dp, 72.dp).clip(RoundedCornerShape(m.t.r * .5f))) { RefImage(j.thumb, Modifier.fillMaxSize(), 20) }
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        RowB {
                            T(j.clockText(), m.type.mono.copy(fontSize = 15.sp), m.t.ink)
                            T("● ${if (j.done) "DONE" else "RENDERING"}", m.type.mono.copy(fontSize = 11.sp, letterSpacing = .08.em), if (j.done) m.t.ink else m.t.accent)
                        }
                        Tiny("${j.modelName} · ${j.title}")
                        T(if (j.running) j.statusLine() else "9:16 · 24fps · ${j.engineLabel}", m.type.mono.copy(fontSize = 12.sp), if (j.paused) m.t.warn else m.t.muted, maxLines = 1)
                        RowB { Bar((j.progress / 100).toFloat(), Modifier.weight(1f)); Spacer(Modifier.width(8.dp)); T("${Pricing.jsRound(j.progress)}%", m.type.mono.copy(fontSize = 12.5.sp), m.t.ink) }
                        j.costLines().forEach { Tiny(it) }
                    }
                }
            }
            s.failed?.let { FailCard(vm, it) }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Kpi("Month", Pricing.money(s.balance.month), Modifier.weight(1f))
                Kpi("Balance", Pricing.money(s.balance.balance), Modifier.weight(1f))
                Kpi("GPU", if (s.running.isNotEmpty()) "H100" else "Off", Modifier.weight(1f))
            }
        }
    }
}

@Composable
fun Kpi(label: String, value: String, modifier: Modifier = Modifier) {
    val m = muse
    val shape = RoundedCornerShape(m.t.r)
    var mod = modifier
    mod = when {
        m.isA -> mod.drawBehind { drawLine(m.t.ink, Offset(0f, 0f), Offset(size.width, 0f), 1.dp.toPx()) }.padding(vertical = 8.dp)
        m.isC -> mod.softShadow(m.t.r).clip(shape).background(m.t.surface).padding(12.dp)
        m.isD -> mod.hardShadow(3.dp, m.t.r).clip(shape).background(m.t.surface).border(2.5.dp, Ink, shape).padding(12.dp)
        else -> mod.clip(shape).background(m.t.surface).border(m.t.stroke, m.t.line, shape).padding(12.dp)
    }
    Column(mod, verticalArrangement = Arrangement.spacedBy(2.dp)) { Lbl(label); T(value, m.type.mono.copy(fontSize = 17.sp, fontWeight = FontWeight.Bold), m.t.ink) }
}

// ---------------- C · Soft Tactile: countdown with stages, or idle card + finished list
@Composable
private fun QueueC(vm: QueueViewModel, s: QueueState) {
    val m = muse
    val nav = LocalNav.current
    val r = s.running.firstOrNull()
    if (r == null) {
        Column(Modifier.fillMaxSize()) {
            Row(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                Wordmark(); Spacer(Modifier.weight(1f)); TbBtn("user", { nav.tab(Routes.SETTINGS) })
            }
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 120.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                H2("Render queue")
                EmptyQueue()
                s.failed?.let { FailCard(vm, it) }
                if (s.done.isNotEmpty()) Lbl("Finished")
                s.done.forEach { j ->
                    Row(Modifier.fillMaxWidth().softShadow(m.t.r).clip(RoundedCornerShape(m.t.r)).background(m.t.surface).press { vm.open(j, nav) }.padding(10.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Box(Modifier.size(54.dp, 72.dp).clip(RoundedCornerShape(m.t.r * .5f))) { RefImage(j.thumb, Modifier.fillMaxSize(), 20) }
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            RowB { T(j.title, m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink); T(Pricing.money(j.cost), m.type.mono.copy(fontSize = 12.5.sp), m.t.ink) }
                            Tiny("${j.engineLabel} · took ${formatTimecode(j.totalSeconds)}")
                            j.warmupCost?.takeIf { it > 0 }?.let { Tiny("GPU warm-up ${Pricing.money(it)}") }
                            Pill("Done", "good")
                        }
                    }
                }
            }
        }
        return
    }
    val stages = listOf("Model processing" to 30.0, "Outfit generation" to 55.0, "Video rendering" to 92.0, "Finalizing" to 100.0)
    Column(Modifier.fillMaxSize()) {
        TopBar("Render queue")
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 120.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            T("Time left", m.type.body, m.t.muted, Modifier.padding(top = 8.dp))
            T(formatClock(r.etaSeconds ?: r.secondsLeft), m.type.body.copy(fontSize = 104.sp, fontWeight = FontWeight.SemiBold, letterSpacing = (-.04).em, lineHeight = 104.sp), m.t.ink)
            T(if (r.paused || r.queuePosition != null) r.statusLine() else "Generating your video… ${r.phase.substringBefore(" · ~")}", m.type.body, if (r.paused) m.t.warn else m.t.muted)
            r.costLines().forEach { Tiny(it) }
            stages.forEachIndexed { i, (name, lim) ->
                val prev = if (i == 0) 0.0 else stages[i - 1].second
                val sp = ((r.progress - prev) / (lim - prev) * 100).coerceIn(0.0, 100.0)
                val st = if (sp >= 100) "done" else if (sp > 0) "run" else ""
                Row(Modifier.fillMaxWidth().softShadow(20.dp).clip(RoundedCornerShape(20.dp)).background(m.t.surface).padding(14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Box(
                        Modifier.size(28.dp).clip(CircleShape).background(if (st == "done") m.t.accent else if (st == "run") Color.Transparent else m.t.surface2).drawBehind {
                            if (st == "run") {
                                drawCircle(m.t.surface2, style = Stroke(3.dp.toPx()), radius = size.minDimension / 2 - 1.5.dp.toPx())
                                drawArc(m.t.accent, -90f, 90f, false, style = Stroke(3.dp.toPx()), topLeft = Offset(1.5.dp.toPx(), 1.5.dp.toPx()),
                                    size = androidx.compose.ui.geometry.Size(size.width - 3.dp.toPx(), size.height - 3.dp.toPx()))
                            }
                        },
                        contentAlignment = Alignment.Center,
                    ) { if (st == "done") Ic("check", 14.dp, Color.White) }
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        RowB { T(name, m.type.body, m.t.ink); T("${Pricing.jsRound(sp)}%", m.type.mono.copy(fontSize = 12.5.sp), m.t.ink) }
                        Bar((sp / 100).toFloat())
                    }
                }
            }
            RowB { Tiny("${s.done.size} finished · see Gallery"); T("Open ›", m.type.tiny, m.t.accent, Modifier.press { nav.tab(Routes.GALLERY) }) }
        }
    }
}

// ---------------- D · Creator Pop: marker header, chunky cards, big percentages
@Composable
private fun QueueD(vm: QueueViewModel, s: QueueState) {
    val m = muse
    val nav = LocalNav.current
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically) {
            Wordmark(); T("RENDER QUEUE", m.type.tiny.copy(fontWeight = FontWeight.Bold), m.t.ink, Modifier.weight(1f), align = androidx.compose.ui.text.style.TextAlign.End)
            TbBtn("quality", { nav.go(Routes.CREDITS) })
        }
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 120.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(Modifier.fillMaxWidth()) {
                Box(Modifier.padding(top = 6.dp).rotate(-4f).hardShadow(4.dp, 14.dp, m.t.accent).clip(RoundedCornerShape(14.dp)).background(Ink).padding(horizontal = 14.dp, vertical = 10.dp)) {
                    T("YOUR RENDERS", m.type.hand.copy(fontSize = 30.sp, lineHeight = 30.sp), Color.White)
                }
                Doodle(Doodles.crown, Modifier.align(Alignment.TopEnd).padding(end = 4.dp))
            }
            if (s.empty) EmptyQueue()
            s.failed?.let { FailCard(vm, it) }
            s.all.forEach { j ->
                val shape = RoundedCornerShape(16.dp)
                Row(
                    Modifier.fillMaxWidth().hardShadow(3.dp, 16.dp).clip(shape).background(Color.White).border(2.5.dp, Ink, shape).press { vm.open(j, nav) }.padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    val ts = RoundedCornerShape(10.dp)
                    Box(Modifier.size(56.dp, 74.dp).clip(ts).border(2.dp, Ink, ts)) { RefImage(j.thumb, Modifier.fillMaxSize(), 20) }
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        T("${j.modelName} · ${j.title}", m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink, maxLines = 1)
                        T(if (j.running) j.statusLine() else j.engineLabel, m.type.tiny, if (j.paused) m.t.warn else m.t.muted, maxLines = 2)
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            val bs = RoundedCornerShape(9.dp)
                            Box(Modifier.weight(1f).height(16.dp).clip(bs).background(Color.White).border(2.dp, Ink, bs)) {
                                Bar((j.progress / 100).toFloat(), Modifier.fillMaxWidth(), if (j.done) m.t.accent else m.t.blue, 16.dp, Color.Transparent)
                            }
                            T("${Pricing.jsRound(j.progress)}%", m.type.h2.copy(fontSize = 28.sp, lineHeight = 30.sp), m.t.ink)
                        }
                        Tiny(if (j.done) "Done · ${Pricing.money(j.cost)}" else "~${formatClock(j.etaSeconds ?: j.secondsLeft)} left · ${Pricing.money(j.cost)}")
                        j.warmupCost?.takeIf { it > 0 }?.let { Tiny("+ GPU warm-up ${Pricing.money(it)}") }
                    }
                }
            }
            Cta("New video", { nav.go(Routes.SOURCE) }, Modifier.fillMaxWidth().padding(top = 6.dp), icon = "plus", big = true)
        }
    }
}

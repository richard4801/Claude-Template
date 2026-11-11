package studio.muse.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
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
import studio.muse.app.ui.theme.MuseSpace
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale
import studio.muse.core.Pricing
import studio.muse.core.formatClock
import studio.muse.core.formatTimecode

data class QueueState(
    val running: List<Job> = emptyList(),
    val done: List<Job> = emptyList(),
    val failed: Job? = null,
    /** How many failed jobs are still showing (for "Clear all failed"). */
    val failedCount: Int = 0,
    val balance: Balance = Balance(0.0, 0.0),
    val loaded: Boolean = false,
) {
    /** Running first, then done; one row per job id (the lazy list's keys). */
    val all: List<Job> by lazy { (running + done).distinctBy { it.id } }
    val empty get() = loaded && running.isEmpty() && done.isEmpty() && failed == null
}

class QueueViewModel(private val c: AppContainer) : ViewModel() {
    val state: StateFlow<QueueState> = combine(c.repo.state, c.drafts.dismissedFails) { s, dismissed ->
        QueueState(
            s.jobs.filter { it.running }, s.jobs.filter { it.done }, s.jobs.firstOrNull { it.failed && it.id !in dismissed },
            s.jobs.count { it.failed && it.id !in dismissed }, s.balance, s.loaded,
        )
    }.stateIn(viewModelScope, SharingStarted.Eagerly, QueueState())

    fun open(j: Job, nav: Nav) {
        if (j.done) nav.go(Routes.result(j.id))
        else c.repo.toast("Still rendering · ${j.statusLine()}")
    }

    fun retry(j: Job, nav: Nav) {
        c.drafts.dismissedFails.update { it + j.id }
        c.drafts.loadJob(j)
        c.repo.toast("Retrying · settings loaded")
        nav.go(Routes.DIRECT)
    }

    /** Dismiss is stored on the server (the job's hiddenAt), so it holds after a restart (owner bug 2026-11-11). */
    fun dismiss(j: Job) = viewModelScope.launch {
        c.drafts.dismissedFails.update { it + j.id }
        if (c.repo.removeJob(j.id) == null) c.drafts.dismissedFails.update { it - j.id }
    }
    fun clearFailed() = viewModelScope.launch { c.repo.clearFailedJobs()?.let { c.repo.toast("Cleared ${it.size} failed") } }

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
    val nav = LocalNav.current
    ScreenBox(bg = m.roles.canvas) {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = MuseSpace.gutter, end = MuseSpace.gutter, top = MuseSpace.s4, bottom = 120.dp)) {
            item(key = "head", contentType = "head") {
                Column(Modifier.padding(bottom = MuseSpace.s4), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    DisplayTitle("Queue")
                    if (!s.empty && s.loaded) Caption(listOfNotNull(s.running.size.takeIf { it > 0 }?.let { "$it rendering" }, "${s.done.size} done").joinToString(" · "))
                }
            }
            if (!s.loaded && s.all.isEmpty()) items(3, key = { "skeleton$it" }, contentType = { "skeleton" }) {
                Row(Modifier.padding(vertical = MuseSpace.s2), horizontalArrangement = Arrangement.spacedBy(MuseSpace.s3), verticalAlignment = Alignment.CenterVertically) {
                    Skeleton(Modifier.size(56.dp, 72.dp)); SkeletonLines(3, Modifier.weight(1f))
                }
            }
            if (s.empty) item(key = "empty", contentType = "empty") {
                EmptyState("Nothing rendering", "Videos you start show up here while they render, with their price and time left. You're not being charged.",
                    "New shot", { studio.muse.app.ui.screens.suite.composer.openShot(c, nav) })
            }
            s.failed?.let { f -> item(key = "failed", contentType = "failed") { FailCard(vm, f, s.failedCount) } }
            items(s.all, key = { it.id }, contentType = { "job" }) { j -> JobRow(vm, j) }
            if (!s.empty && s.loaded) item(key = "new", contentType = "cta") {
                PrimaryButton("New shot", { studio.muse.app.ui.screens.suite.composer.openShot(c, nav) }, Modifier.fillMaxWidth().padding(top = MuseSpace.s5), icon = "plus")
            }
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
        MenuItem("export", "Copy prompt") { clip.setText(AnnotatedString(j.prompt.ifBlank { j.title })); vm.toast("Prompt copied") },
        MenuItem("shield", "Remove from list", danger = true) { vm.remove(j) },
    )
}

/** Failed render: what happened, the refund, and one way to try again with the same settings. */
@Composable
private fun FailCard(vm: QueueViewModel, j: Job, count: Int) {
    val m = muse
    val nav = LocalNav.current
    Column {
        Row(Modifier.fillMaxWidth().padding(vertical = MuseSpace.s3), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                T("${j.title} didn't render", m.scale.heading, m.roles.danger)
                Caption(j.failLine())
            }
            SecondaryButton("Try again", { vm.retry(j, nav) }, height = 48.dp)
            SecondaryButton("Dismiss", { vm.dismiss(j) }, height = 48.dp)
        }
        if (count > 1) Caption("Clear all $count failed", Modifier.press { vm.clearFailed() }.padding(vertical = MuseSpace.s2))
    }
}

/** One render: thumbnail, title, one status line, progress while it runs. No box. */
@Composable
private fun JobRow(vm: QueueViewModel, j: Job) {
    val m = muse
    val nav = LocalNav.current
    Row(
        Modifier.fillMaxWidth().press { vm.open(j, nav) }.padding(vertical = MuseSpace.s2),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(MuseSpace.s3),
    ) {
        Box(Modifier.size(56.dp, 72.dp).clip(controlShape()).background(m.roles.field)) { RefImage(j.thumb, Modifier.fillMaxSize(), 20) }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(MuseSpace.s1)) {
            T(j.title, m.scale.body.copy(fontWeight = FontWeight.Medium), m.roles.ink, maxLines = 1)
            if (j.running) {
                T(j.statusLine(), m.scale.caption.tabular(), if (j.paused) m.roles.caution else m.roles.ink2, maxLines = 2)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
                    ProgressLine((j.progress / 100).toFloat(), Modifier.weight(1f))
                    RowValue("${Pricing.jsRound(j.progress)}%", m.roles.ink)
                }
            } else T(j.costLines().joinToString(" · "), m.scale.caption.tabular(), m.roles.ink2, maxLines = 1)
        }
        MoreMenu(jobMenu(vm, j), tint = m.roles.ink2)
    }
}

/**
 * What a running job is doing, in outcomes (plans/api.md "App clean-up" §1): "Rendering · about 2 min · $0.14",
 * "Waiting to start · $0.14", "#2 in line · about 9 min · $0.14".
 */
fun Job.statusLine(): String {
    val price = Pricing.money(cost)
    val left = etaSeconds ?: secondsLeft
    val time = if (left > 0) " · about ${aboutTime(left)}" else ""
    if (state == "running" && queuePosition != null) return "${if (queuePosition <= 1) "Waiting to start" else "#$queuePosition in line"}$time · $price"
    return "${memberPhase(phase)}$time · $price"
}

/** "about 2 min", "under a minute". */
fun aboutTime(seconds: Double): String = if (seconds < 60) "a minute" else "${Pricing.jsRound(seconds / 60).coerceAtLeast(1)} min"

/**
 * The server's phase without its time ("Rendering · ~6 min left" → "Rendering"). Older servers said "step 3/10",
 * "Starting GPU" or "Waiting for Replicate": those read as Rendering / Getting ready / Waiting to start.
 */
fun memberPhase(phase: String): String {
    val head = phase.substringBefore(" · ~").substringBefore(" · starts in")
    val prefix = Regex("^take \\d+/\\d+ · ").find(head)?.value.orEmpty()
    val rest = head.removePrefix(prefix)
    val clean = when {
        rest.isBlank() || Regex("(?i)paused|waiting|in line|queued|busy").containsMatchIn(rest) -> if (Regex("^#\\d+ in line").containsMatchIn(rest)) rest.substringBefore(" · ") else "Waiting to start"
        Regex("(?i)gpu|starting|load|getting ready").containsMatchIn(rest) -> "Getting ready"
        Regex("(?i)step|render|denois").containsMatchIn(rest) -> "Rendering"
        Regex("(?i)finish|upload|trim").containsMatchIn(rest) -> "Finishing"
        else -> rest
    }
    return prefix + clean
}

/** "Something went wrong · you weren't charged. $0.14 refunded." (the server's message is already member-safe). */
fun Job.failLine(): String {
    val e = error?.takeUnless { Regex("(?i)gpu|runpod|replicate|cuda|step \\d").containsMatchIn(it) } ?: studio.muse.app.data.ErrorText.WENT_WRONG
    return "$e${if (refunded > 0) " · ${Pricing.money(refunded)} back" else ""}"
}

/** The job's cost, and what came back if it failed. */
fun Job.costLines(): List<String> = listOf(
    "Render ${Pricing.money(cost)}${if (refunded > 0) " · ${Pricing.money(refunded)} refunded" else ""}",
)

/** A figure with its label above it: no box, tabular so a row of them lines up. */
@Composable
fun Kpi(label: String, value: String, modifier: Modifier = Modifier) {
    val m = muse
    Column(modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Caption(label)
        T(value, m.scale.heading.tabular(), m.roles.ink, maxLines = 1)
    }
}

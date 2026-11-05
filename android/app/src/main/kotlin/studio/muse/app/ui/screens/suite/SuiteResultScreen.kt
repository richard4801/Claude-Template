package studio.muse.app.ui.screens.suite

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import studio.muse.app.data.Take
import studio.muse.app.data.SuiteRules
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.TabBar
import studio.muse.app.ui.components.MenuItem
import studio.muse.app.ui.components.MoreMenu
import studio.muse.app.ui.components.RefImage
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.Tiny
import studio.muse.app.ui.components.TopBar
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.BlurredStageArt
import studio.muse.app.ui.screens.ScreenBox
import studio.muse.app.ui.screens.StagePhase
import studio.muse.app.ui.screens.StageVideo
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse

/**
 * M8 · a shot's result (D10's states in one place): the take playing inline, the takes strip (finished takes, and the one
 * still rendering with its %), and Keep · Retake · Edit · Share. In line, rendering and failed show the result pane.
 */
@Composable
fun SuiteResultScreen(jobId: String) {
    val c = LocalContainer.current
    val nav = LocalNav.current
    val m = muse
    val store = c.suite
    val st by c.repo.state.collectAsState()
    val scope = rememberCoroutineScope()
    val job = st.job(jobId)
    val takes = st.takes.filter { it.jobId == jobId && it.kind == "take" }.sortedBy { it.index }
    var picked by remember { mutableStateOf<String?>(null) }
    val take = takes.firstOrNull { it.id == picked } ?: takes.firstOrNull()
    val pane = SuitePane.of(job, st.takes, job?.modelName)
    val retake: () -> Unit = {
        scope.launch {
            when (jobId) {
                in store.shotJobs.value -> store.generate(store.shot.value.request(), store.shotJobs)?.let { nav.go(Routes.suiteTake(it.id)) }
                in store.swapJobs.value -> store.generate(store.recast.value.request(), store.swapJobs)?.let { nav.go(Routes.suiteTake(it.id)) }
                else -> nav.go(Routes.SUITE_SHOT)
            }
        }
    }
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar(job?.title ?: "Take", onBack = { nav.back() }) {
                MoreMenu(listOfNotNull(
                    MenuItem("grid", "Gallery") { nav.tab(Routes.GALLERY) },
                    if (store.owner) MenuItem("quality", "Engines (owner)") { nav.go(Routes.SUITE_ENGINES) } else null,
                ))
            }
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(top = 12.dp, bottom = 100.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                if (job == null) { Tiny("This shot isn't here any more."); return@Column }
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (take != null) SBadge("Take ${take.index}", "ink")
                    SBadge(listOfNotNull(job.request.seconds?.let { "${studio.muse.app.data.FakeSuite.fmtSeconds(it)} s" }, take?.label ?: SuiteRules.tierLabel(job.request.quality)).joinToString(" · "))
                    Spacer(Modifier.weight(1f))
                    T(when (pane.phase) { StagePhase.READY -> "Ready" + (job.finishedAt?.let { " · ${ago(it)}" } ?: ""); StagePhase.FAILED -> "Failed · not charged"; else -> pane.badge }, m.type.tiny, m.t.muted, maxLines = 1)
                }
                Box(Modifier.fillMaxWidth(.66f).widthIn(max = 280.dp).aspectRatio(9f / 16f).clip(RoundedCornerShape(if (m.isA) 0.dp else 12.dp))) {
                    if (take != null) {
                        val url = take.videoUrl
                        if (url != null) StageVideo(url, take.thumb, true, Modifier.fillMaxSize()) else RefImage(take.thumb, Modifier.fillMaxSize(), 20)
                        if (url == null) Box(Modifier.align(Alignment.Center).size(48.dp).clip(RoundedCornerShape(999.dp)).background(Color.White.copy(alpha = .9f)), contentAlignment = Alignment.Center) { Ic("play", 20.dp, Color(0xFF141210)) }
                    } else SuiteResultPane(pane, job.thumb, onRetry = retake, compact = true)
                }
                if (takes.isNotEmpty() || pane.phase == StagePhase.RENDERING) Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    takes.forEach { t -> TakeThumb(t, t.id == take?.id) { picked = t.id } }
                    if (pane.phase == StagePhase.RENDERING || pane.phase == StagePhase.QUEUED) {
                        Box(Modifier.size(56.dp, 100.dp).clip(RoundedCornerShape(if (m.isA) 0.dp else 8.dp))) {
                            BlurredStageArt(job.thumb, moving = false)
                            T(pane.percent, m.type.body.copy(fontSize = 18.sp), Color.White, Modifier.align(Alignment.Center))
                        }
                        Column(Modifier.padding(start = 6.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            T("Take ${(job.take).coerceAtLeast(takes.size + 1).coerceAtMost(job.request.takes)} · ${pane.percent}", m.type.body.copy(fontSize = 13.5.sp, fontWeight = FontWeight.Bold), m.t.ink)
                            Tiny(pane.step)
                        }
                    }
                }
            }
        }
        // Keep · Retake · Edit · Share above the tab bar.
        Row(Modifier.align(Alignment.BottomCenter).padding(bottom = 92.dp).fillMaxWidth().background(m.t.bg).drawBehind {
            drawLine(m.t.line, Offset(0f, 0f), Offset(size.width, 0f), 1.dp.toPx()) }.padding(horizontal = 16.dp, vertical = 10.dp), horizontalArrangement = Arrangement.SpaceBetween) {
            Action("heart", if (take?.final == true) "Kept" else "Keep", take != null) { take?.let { t -> scope.launch { c.repo.setTakeStatus(t.id, if (t.final) "test" else "final") } } }
            Action("refresh", "Retake", true, retake)
            Action("scissors", "Edit", take != null) { take?.let { nav.go(Routes.editTake(it.id)) } }
            Action("share", "Share", take != null) { take?.let { nav.go(Routes.post(it.id)) } }
        }
        TabBar(Routes.SUITE)
    }
}

@Composable
private fun TakeThumb(t: Take, on: Boolean, onClick: () -> Unit) {
    val m = muse
    Box(Modifier.size(56.dp, 100.dp).clip(RoundedCornerShape(if (m.isA) 0.dp else 8.dp)).border(if (on) 2.dp else 0.dp, if (on) m.t.ink else Color.Transparent)
        .press(onClick = onClick).semantics { contentDescription = "Take ${t.index}" }) {
        RefImage(t.thumb, Modifier.fillMaxSize(), 20)
        Box(Modifier.align(Alignment.Center).size(26.dp).clip(RoundedCornerShape(999.dp)).background(Color.White.copy(alpha = .9f)), contentAlignment = Alignment.Center) { Ic("play", 12.dp, Color(0xFF141210)) }
    }
}

@Composable
private fun Action(icon: String, label: String, enabled: Boolean, onClick: () -> Unit) {
    val m = muse
    Column(Modifier.width(72.dp).press(enabled = enabled, onClick = onClick).semantics(mergeDescendants = true) { contentDescription = label },
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        SIc(icon, 20.dp, if (enabled) m.t.ink else m.t.muted.copy(alpha = .5f))
        T(label.uppercase(), m.type.mono.copy(fontSize = 9.5.sp, letterSpacing = .8.sp), if (enabled) m.t.muted else m.t.muted.copy(alpha = .5f))
    }
}

/** "4 min ago". */
fun ago(t: Long, now: Long = System.currentTimeMillis()): String {
    val s = ((now - t) / 1000).coerceAtLeast(0)
    return when { s < 60 -> "just now"; s < 3600 -> "${s / 60} min ago"; s < 86_400 -> "${s / 3600} h ago"; else -> "${s / 86_400} d ago" }
}

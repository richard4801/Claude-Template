package studio.muse.app.ui.screens.suite

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import studio.muse.app.data.SuiteRules
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.components.Cta2
import studio.muse.app.ui.components.MenuItem
import studio.muse.app.ui.components.MoreMenu
import studio.muse.app.ui.components.RefImage
import studio.muse.app.ui.components.Seg
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.Tiny
import studio.muse.app.ui.components.TopBar
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.BlurredStageArt
import studio.muse.app.ui.screens.ScreenBox
import studio.muse.app.ui.screens.StagePhase
import studio.muse.app.ui.theme.muse

/**
 * M7 · Storyboard: shots with one cast and a look lock (the Shot's camera: body, lens and look stay the same; each shot
 * has its own move and length). Generate makes every shot not made yet, at one quality, for the sum of their estimates.
 */
@Composable
fun SuiteStoryboardScreen() {
    val c = LocalContainer.current
    val nav = LocalNav.current
    val m = muse
    val store = c.suite
    val cat by store.catalog.collectAsState()
    val b0 by store.board.collectAsState()
    val shot by store.shot.collectAsState()
    val st by c.repo.state.collectAsState()
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { if (store.catalog.value == null) store.load() }
    val catalog = cat
    if (catalog != null && !catalog.enabled) { SuiteOffScreen("Storyboard"); return }
    val cam = catalog?.camera ?: studio.muse.app.data.CameraCatalog()
    val board = b0
    val pending = board?.pending(st.jobs).orEmpty()
    val reqs = board?.let { b -> pending.map { s -> s.id to b.request(s, shot.camera, b.shots.indexOf(s)) } }.orEmpty()
    // The price of every shot Generate makes: the sum of their estimates.
    val total = produceState<Pair<Double?, String?>>(null to null, reqs, catalog?.enabled) {
        if (reqs.isEmpty() || catalog?.enabled != true) { value = null to null; return@produceState }
        delay(300)
        var sum = 0.0
        for ((_, r) in reqs) { val (e, err) = store.estimate(r); if (e == null) { value = null to err; return@produceState }; sum += e.estimate; if (!e.ok) { value = null to e.message; return@produceState } }
        value = sum to null
    }.value
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar("Storyboard", onBack = { nav.back() }) {
                MoreMenu(listOf(MenuItem("plus", "Add the current Shot") {
                    val s = StoryShot("s" + System.nanoTime(), shot.title.ifBlank { shot.scene.take(32).ifBlank { "New shot" } }, shot.scene, shot.camera.moves.firstOrNull()?.id ?: "static", shot.duration)
                    store.board.update { b -> (b ?: Storyboard("Untitled storyboard", listOfNotNull(shot.modelId))).let { it.copy(shots = it.shots + s) } }
                }))
            }
            if (board == null || board.shots.isEmpty()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    T("No storyboard yet", m.type.h2, m.t.ink, upper = m.isB)
                    Tiny("Build a Shot, then add it here. Every shot keeps the same cast, look and lens; each has its own move and length.")
                    Cta2("Build a Shot", { nav.go(Routes.SUITE_SHOT) }, Modifier.fillMaxWidth())
                }
                return@Column
            }
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(top = 10.dp, bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                T("${board.title} · ${board.seconds} s", m.type.h2, m.t.ink, upper = m.isB, maxLines = 2)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    board.cast.forEach { id -> RefImage(st.model(id)?.cover, Modifier.size(26.dp, 32.dp).background(m.t.surface2)) }
                    SBadge("Look lock · ${cam.presets.firstOrNull { it.id == board.lookLock }?.label ?: board.lookLock}", "ink")
                    Tiny("${board.shots.size} shots")
                }
                board.shots.forEachIndexed { i, s -> StoryRow(i, s, st, cam) }
                SLbl("Quality")
                Seg(SuiteRules.TIERS.map { it to SuiteRules.tierLabel(it).let { l -> if (l == "Standard") "Std" else l } }, board.quality, { q -> store.board.update { it?.copy(quality = q) } }, Modifier.fillMaxWidth(), small = true)
                Tiny("Same cast, look and lens across all shots.")
            }
            Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 12.dp)) {
                val n = pending.size
                val label = if (n == 0) "All shots made" else "Generate $n shot${if (n > 1) "s" else ""} · ${SuiteRules.tierLabel(board.quality)}" +
                    (total.first?.let { " · ${studio.muse.core.Pricing.money(it)}" } ?: "")
                GenerateBar(label, {
                    if (n > 0 && total.first != null) scope.launch {
                        reqs.forEach { (id, r) -> store.generate(r)?.let { j -> store.board.update { b -> b?.withJob(id, j.id) } } }
                    }
                }, off = n == 0 || total.first == null, note = total.second)
            }
        }
    }
}

@Composable
private fun StoryRow(i: Int, s: StoryShot, st: studio.muse.app.data.StudioState, cam: studio.muse.app.data.CameraCatalog) {
    val m = muse
    val nav = LocalNav.current
    val job = s.jobId?.let { id -> st.jobs.firstOrNull { it.id == id } }
    val status = storyStatus(s, st.jobs)
    val pane = SuitePane.of(job, st.takes, null)
    Row(Modifier.fillMaxWidth().drawBehind { drawLine(m.t.line, Offset(0f, size.height), Offset(size.width, size.height), 1.dp.toPx()) }
        .press { job?.let { nav.go(Routes.suiteTake(it.id)) } }.padding(vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(Modifier.size(62.dp, 104.dp)) {
            val art = st.takes.firstOrNull { it.jobId == job?.id }?.thumb ?: st.models.firstOrNull()?.cover
            if (pane.phase == StagePhase.READY) RefImage(art, Modifier.fillMaxSize(), 20) else BlurredStageArt(art, moving = false)
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                T("${i + 1}", m.type.h2.copy(fontSize = 22.sp, lineHeight = 22.sp), m.t.ink, Modifier.weight(1f))
                SBadge(status.label, status.kind)
            }
            T(s.title, m.type.body.copy(fontSize = 13.5.sp, fontWeight = FontWeight.Bold), m.t.ink, maxLines = 2)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Box(Modifier.size(46.dp, 26.dp).border(1.dp, m.t.line)) { MovePictogram(s.move, cam.move(s.move)?.category ?: "", Modifier.fillMaxSize()) }
                Tiny("${cam.moveLabel(s.move)} · ${s.seconds} s")
            }
        }
    }
}

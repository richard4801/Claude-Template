package studio.muse.app.ui.screens

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import studio.muse.app.AppContainer
import studio.muse.app.data.Job
import studio.muse.app.data.Take
import studio.muse.app.ui.LocalCelebrate
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Nav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.TabBar
import studio.muse.app.ui.components.*
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse
import studio.muse.core.Pricing

data class ResultState(val takes: List<Take> = emptyList(), val job: Job? = null, val retryCost: Double = 0.0, val posts: List<studio.muse.app.data.Post> = emptyList())

class ResultViewModel(private val c: AppContainer, private val id: String) : ViewModel() {
    val state: StateFlow<ResultState> = c.repo.state.map { s ->
        val direct = s.takes.firstOrNull { it.id == id }
        val jobId = direct?.jobId ?: id
        val takes = if (direct != null && direct.jobId == null) listOf(direct) else s.takes.filter { it.jobId == jobId }.sortedBy { it.index }
        val job = s.job(jobId)
        ResultState(takes, job, job?.let { Pricing.totalCost(it.request.spec()) } ?: 0.0, s.posts.filter { p -> takes.any { it.id == p.takeId } })
    }.stateIn(viewModelScope, SharingStarted.Eagerly, ResultState())

    fun approve(t: Take, celebrate: () -> Unit) = viewModelScope.launch {
        if (t.final) return@launch
        if (c.repo.setTakeStatus(t.id, "final") != null) { celebrate(); c.repo.toast("Moved to Final gallery") }
    }

    fun discard(t: Take, nav: Nav) = viewModelScope.launch {
        if (c.repo.deleteTake(t.id) != null) {
            c.repo.toast("Discarded")
            if (state.value.takes.size <= 1) nav.back()
        }
    }

    fun retry(nav: Nav) {
        val j = state.value.job ?: return c.repo.toast("This one was a photoshoot · shoot again from Photoshoot")
        c.drafts.loadJob(j)
        nav.go(Routes.DIRECT)
    }

    fun toast(s: String) = c.repo.toast(s)
    fun export() = c.repo.toast("Exported 1080×1920")
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ResultScreen(id: String) {
    val c = LocalContainer.current
    val vm: ResultViewModel = viewModel(key = "result-$id") { ResultViewModel(c, id) }
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    val m = muse
    val celebrate = LocalCelebrate.current
    val clip = LocalClipboardManager.current
    var compare by remember { mutableStateOf(false) }
    val pager = rememberPagerState { s.takes.size.coerceAtLeast(1) }
    val take = s.takes.getOrNull(pager.currentPage) ?: s.takes.firstOrNull()
    ScreenBox(statusPad = false) {
        Column(Modifier.fillMaxSize()) {
            Box(Modifier.fillMaxWidth().weight(1f)) {
                if (compare && s.takes.size > 1) {
                    Row(Modifier.fillMaxSize().statusBarsPadding().padding(top = 52.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        s.takes.forEach { t -> Box(Modifier.weight(1f).fillMaxHeight()) { RefImage(t.thumb, Modifier.fillMaxSize(), 30); T("Take ${t.index}", m.type.tiny, Color.White, Modifier.align(Alignment.BottomStart).padding(8.dp)) } }
                    }
                } else {
                    HorizontalPager(pager, Modifier.fillMaxSize()) { p ->
                        val t = s.takes.getOrNull(p)
                        Box(Modifier.fillMaxSize()) {
                            val url = t?.videoUrl
                            // A real render plays with Media3; simulated renders have no video, so the still stays.
                            if (url != null) TakeVideo(url, t.thumb, p == pager.currentPage, Modifier.fillMaxSize())
                            else {
                                RefImage(t?.thumb, Modifier.fillMaxSize(), 30)
                                if (t?.kind == "take") PlayBadge()
                            }
                        }
                    }
                }
                Box(Modifier.fillMaxWidth().height(160.dp).background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = .4f), Color.Transparent))))
                Column(Modifier.statusBarsPadding()) {
                    TopBar(if (s.takes.size > 0) "Take ${(take?.index ?: 1)} of ${take?.of ?: s.takes.size}" else "", onBack = { nav.back() }, over = true) {
                        MoreMenu(listOf(
                            MenuItem("export", "Download") { vm.export() },
                            MenuItem("upload", "Post") { take?.let { nav.go(Routes.post(it.id)) } },
                            MenuItem("grid", "Save as template") { take?.let { if (it.shot) nav.go(Routes.saveTemplate(it.id)) else vm.toast("Templates are for photos · video templates come later") } },
                            MenuItem("spark", "Copy prompt") { clip.setText(AnnotatedString(take?.prompt?.ifBlank { null } ?: s.job?.prompt ?: "")); vm.toast("Prompt copied") },
                            MenuItem("grid", "Compare takes") { if (s.takes.size > 1) compare = !compare else vm.toast("Compare takes · needs 2+ takes") },
                            MenuItem("bell", "Report a problem") { vm.toast("Thanks · report sent with the prompt and seed") },
                            MenuItem("shield", "Delete take", danger = true) { take?.let { vm.discard(it, nav) } },
                        ), tint = Color.White)
                    }
                }
                Box(Modifier.fillMaxSize()) { Viewfinder(bottomInset = 30.dp) }
                Column(Modifier.align(Alignment.BottomEnd).padding(end = 14.dp, bottom = 40.dp), verticalArrangement = Arrangement.spacedBy(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    SideAction("retry", if (s.job != null) "Retry · ${Pricing.money(s.retryCost)}" else "Retry") { vm.retry(nav) }
                    SideAction("export", "Export") { vm.export() }
                    SideAction("upload", "Post") { take?.let { nav.go(Routes.post(it.id)) } }
                    if (take?.shot == true) SideAction("grid", "Save look") { nav.go(Routes.saveTemplate(take.id)) }
                }
            }
            val shape = RoundedCornerShape(topStart = if (m.isA) 0.dp else m.t.rLg, topEnd = if (m.isA) 0.dp else m.t.rLg)
            Column(
                Modifier.fillMaxWidth().offset(y = (-20).dp).clip(shape).background(m.t.bg).navigationBarsPadding().padding(start = 20.dp, end = 20.dp, top = 20.dp, bottom = 4.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (take == null) {
                    T("Nothing here any more.", m.type.body, m.t.muted)
                    Cta("Back to Gallery", { nav.tab(Routes.GALLERY) }, Modifier.fillMaxWidth())
                } else {
                    RowB(align = Alignment.Top) {
                        Column(Modifier.weight(1f)) {
                            H3(take.title)
                            take.templateName?.let { Tiny("Template: $it", weight = FontWeight.Bold) }
                            Tiny(listOf(take.engineLabel, Pricing.money(take.cost)).filter { it.isNotBlank() }.joinToString(" · "))
                            takeSpecs(take)?.let { T(it, m.type.mono.copy(fontSize = 11.5.sp), m.t.muted) }
                            s.job?.warmupCost?.takeIf { it > 0 }?.let { Tiny("GPU warm-up ${Pricing.money(it)} (charged with this render)") }
                        }
                        Pill(if (take.final) "Final" else "Test", if (take.final) "good" else "")
                    }
                    s.posts.firstOrNull { it.takeId == take.id && it.stats != null }?.let { p ->
                        Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                            p.platforms.mapNotNull { studio.muse.app.data.Platform.of(it) }.forEach { PlatformBadge(it, 16.dp) }
                            p.stats?.let { st -> T(" ${String.format(java.util.Locale.US, "%,d", st.views)} views · ${String.format(java.util.Locale.US, "%,d", st.likes)} likes", m.type.mono.copy(fontSize = 11.5.sp), m.t.muted) }
                        }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Cta2("Discard", { vm.discard(take, nav) }, Modifier.weight(1f))
                        Cta(if (take.final) "Approved ✓" else "Approve", { vm.approve(take, celebrate) }, Modifier.weight(1f))
                    }
                }
            }
        }
    }
}

@Composable
private fun SideAction(icon: String, label: String, onClick: () -> Unit) {
    Column(Modifier.press(onClick = onClick), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Ic(icon, 22.dp, Color.White)
        T(label, muse.type.tiny.copy(fontSize = 11.sp, fontWeight = FontWeight.SemiBold, shadow = androidx.compose.ui.graphics.Shadow(Color.Black.copy(alpha = .5f), blurRadius = 3f)), Color.White)
    }
}

// ======================================================================= Gallery

data class GalleryState(val tab: String = "tests", val tests: List<Take> = emptyList(), val finals: List<Take> = emptyList(), val fresh: Int = 0)

class GalleryViewModel(private val c: AppContainer) : ViewModel() {
    val state: StateFlow<GalleryState> = combine(c.repo.state, c.drafts.galleryTab, c.drafts.freshShots) { s, tab, fresh ->
        GalleryState(tab, s.takes.filter { !it.final }, s.takes.filter { it.final }, fresh)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, GalleryState())

    fun tab(t: String) { c.drafts.galleryTab.value = t }
    fun seen() { c.drafts.freshShots.value = 0 }
}

@Composable
fun GalleryScreen() {
    val c = LocalContainer.current
    val vm: GalleryViewModel = viewModel { GalleryViewModel(c) }
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    val m = muse
    val fresh = remember { s.fresh }
    LaunchedEffect(Unit) { vm.seen() }
    val list = if (s.tab == "final") s.finals else s.tests
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            Row(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                Wordmark(); Spacer(Modifier.weight(1f)); TbBtn("grid", {})
            }
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 120.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                if (m.isA) T("GALLERY", m.type.h2.copy(fontSize = 56.sp, lineHeight = 52.sp), m.t.ink) else H2("Gallery")
                Seg(listOf("tests" to "Tests · ${s.tests.size}", "final" to "Final · ${s.finals.size}"), s.tab, vm::tab)
                if (list.isEmpty()) {
                    NoteBox(if (s.tab == "final") "Nothing approved yet. Approve a take to move it here." else "No test renders yet. Make a video or a photoshoot.", icon = "spark")
                } else {
                    list.chunked(3).forEachIndexed { r, row ->
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            row.forEachIndexed { i, t ->
                                val idx = r * 3 + i
                                val isNew = s.tab == "tests" && idx < fresh
                                val shape = RoundedCornerShape(m.t.r * .6f)
                                Box(
                                    Modifier.weight(1f).height(170.dp).let { if (isNew) it.border(3.dp, m.t.accent, shape) else it }.clip(shape)
                                        .let { if (m.isD) it.border(2.5.dp, Ink, shape) else it }.press { nav.go(Routes.result(t.jobId ?: t.id)) },
                                ) {
                                    RefImage(t.thumb, Modifier.fillMaxSize(), 20)
                                    if (t.kind == "take") PlayBadge()
                                    Box(Modifier.align(Alignment.BottomStart).padding(6.dp).clip(RoundedCornerShape(4.dp)).background(Color.Black.copy(alpha = .55f)).padding(horizontal = 6.dp, vertical = 2.dp)) {
                                        T((if (isNew) "New · " else "") + t.label, m.type.tiny.copy(fontSize = 11.5.sp, fontWeight = FontWeight.Bold), Color.White, maxLines = 1)
                                    }
                                }
                            }
                            repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
                        }
                    }
                }
                Tiny("Test renders stay separate from your Final gallery.")
            }
        }
        TabBar(Routes.GALLERY)
    }
}

/** "8.0 s · 768 × 1344" for a real render, or null. */
fun takeSpecs(t: Take): String? {
    val parts = listOfNotNull(
        t.durationSec?.let { String.format(java.util.Locale.US, "%.1f s", it) },
        if (t.width != null && t.height != null) "${t.width} × ${t.height}" else null,
    )
    return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")
}

/** Plays a take's video (Media3 ExoPlayer), looping, only while its page is showing and the app is in front. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@Composable
fun TakeVideo(url: String, poster: studio.muse.app.data.ImageRef?, active: Boolean, modifier: Modifier = Modifier) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val player = remember(url) {
        androidx.media3.exoplayer.ExoPlayer.Builder(context).build().apply {
            setMediaItem(androidx.media3.common.MediaItem.fromUri(url))
            repeatMode = androidx.media3.common.Player.REPEAT_MODE_ONE
            prepare()
        }
    }
    androidx.compose.runtime.DisposableEffect(player) { onDispose { player.release() } }
    androidx.lifecycle.compose.LifecycleResumeEffect(player, active) {
        player.playWhenReady = active
        onPauseOrDispose { player.pause() }
    }
    Box(modifier) {
        RefImage(poster, Modifier.fillMaxSize(), 30)
        androidx.compose.ui.viewinterop.AndroidView(
            factory = { ctx ->
                androidx.media3.ui.PlayerView(ctx).apply {
                    this.player = player
                    useController = true
                    resizeMode = androidx.media3.ui.AspectRatioFrameLayout.RESIZE_MODE_ZOOM
                    setShutterBackgroundColor(android.graphics.Color.TRANSPARENT)
                }
            },
            modifier = Modifier.fillMaxSize(),
            update = { it.player = player },
        )
    }
}

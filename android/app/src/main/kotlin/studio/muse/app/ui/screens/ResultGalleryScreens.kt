package studio.muse.app.ui.screens

import androidx.compose.ui.layout.onVisibilityChanged
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
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
import androidx.compose.ui.graphics.graphicsLayer
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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.foundation.layout.widthIn
import androidx.compose.ui.semantics.semantics
import studio.muse.app.AppContainer
import studio.muse.app.data.Job
import studio.muse.app.data.editable
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
import studio.muse.app.ui.theme.MuseSpace
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale
import studio.muse.app.ui.theme.radii
import studio.muse.core.Pricing

data class ResultState(val takes: List<Take> = emptyList(), val job: Job? = null, val retryCost: Double = 0.0, val posts: List<studio.muse.app.data.Post> = emptyList(),
    /** The Upscale add-on (coming soon until the server says otherwise). */
    val upscale: studio.muse.app.data.AddonInfo = studio.muse.app.data.VideoFeatures.DEFAULT.upscale,
    /** Every take of the studio, for the edited versions of a video (plans/video-editor.md). */
    val all: List<Take> = emptyList()) {
    fun versions(t: Take) = all.filter { it.kind == "edit" && it.parentTakeId == t.id }.sortedByDescending { it.createdAt }
}

class ResultViewModel(private val c: AppContainer, private val id: String) : ViewModel() {
    val state: StateFlow<ResultState> = c.repo.state.map { s ->
        val direct = s.takes.firstOrNull { it.id == id }
        val jobId = direct?.jobId ?: id
        val takes = if (direct != null && direct.jobId == null) listOf(direct) else s.takes.filter { it.jobId == jobId }.sortedBy { it.index }
        val job = s.job(jobId)
        ResultState(takes, job, job?.let { Pricing.totalCost(it.request.spec()) } ?: 0.0, s.posts.filter { p -> takes.any { it.id == p.takeId } },
            (s.video ?: studio.muse.app.data.VideoFeatures.DEFAULT).upscale, s.takes)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, ResultState())

    fun approve(t: Take, celebrate: () -> Unit) = viewModelScope.launch {
        if (t.final) return@launch
        if (c.repo.setTakeStatus(t.id, "final") != null) { celebrate(); c.repo.toast("Moved to Final") }
    }

    fun discard(t: Take, nav: Nav) = viewModelScope.launch {
        if (c.repo.deleteTake(t.id) != null) {
            c.repo.toast("Discarded")
            if (state.value.takes.size <= 1) nav.back()
        }
    }

    fun retry(nav: Nav) {
        // A still has no job: Retry opens Suite → Photo (Photoshoot moved there).
        val j = state.value.job ?: return studio.muse.app.ui.screens.suite.composer.openPhoto(c, nav, null, null)
        c.drafts.loadJob(j)
        nav.go(Routes.DIRECT)
    }

    fun toast(s: String) = c.repo.toast(s)
    /** Saves the take's video (or photo) to Downloads. Demo takes are bundled stills with no file behind them. */
    fun export(context: android.content.Context, t: Take?) {
        val url = t?.videoUrl ?: t?.thumb?.url ?: return c.repo.toast(if (c.repo.demo) "Demo takes have no file to download" else "Nothing to download yet")
        c.repo.toast(studio.muse.app.platform.Downloads.save(context, url, t?.title ?: "MUSE"))
    }

    /** Upscale a finished render to 1080p / 2K / 4K (plans/api.md "App clean-up" §2). Coming soon for now. */
    fun upscale(t: Take, size: studio.muse.app.data.UpscaleSizeInfo) {
        val up = state.value.upscale
        if (!up.available || !size.available) return c.repo.toast("Upscale is coming soon")
        viewModelScope.launch { c.repo.upscale(t.id, size.id)?.let { c.repo.toast("Upscaling to ${size.label}") } }
    }
}

/** The Upscale add-on on a finished render: 1080p / 2K / 4K, greyed with "Coming soon" until it ships. */
@Composable
private fun UpscaleRow(up: studio.muse.app.data.AddonInfo, seconds: Double?, onPick: (studio.muse.app.data.UpscaleSizeInfo) -> Unit) {
    val m = muse
    val sizes = up.sizes.ifEmpty { studio.muse.app.data.VideoFeatures.DEFAULT.upscale.sizes }
    // Each size's price is the server's $ per output second × this take's length (UpscaleOffer), or "Soon".
    val choices = studio.muse.app.data.UpscaleOffer.choices(up, seconds)
    Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
        Heading(up.label.ifBlank { "Upscale" }) { if (!studio.muse.app.data.UpscaleOffer.live(up)) Caption("Coming soon") }
        Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
            sizes.zip(choices).forEach { (z, ch) ->
                SecondaryButton("${ch.label} · ${ch.priceText}", { onPick(z) }, Modifier.weight(1f).graphicsLayer { alpha = if (ch.available) 1f else .45f }, height = 48.dp)
            }
        }
        Caption(up.detail.ifBlank { "Sharper 1080p, 2K or 4K from a finished take" })
    }
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
    val context = androidx.compose.ui.platform.LocalContext.current
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
                                if (t?.kind == "take" || t?.kind == "edit") PlayBadge()
                            }
                        }
                    }
                }
                Box(Modifier.fillMaxWidth().height(160.dp).background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = .4f), Color.Transparent))))
                Column(Modifier.statusBarsPadding()) {
                    TopBar(if (s.takes.size > 0) "Take ${(take?.index ?: 1)} of ${take?.of ?: s.takes.size}" else "", onBack = { nav.back() }, over = true) {
                        MoreMenu(listOf(
                            MenuItem("export", "Download") { vm.export(context, take) },
                            MenuItem("upload", "Post") { take?.let { nav.go(Routes.post(it.id)) } },
                            MenuItem("retry", "Edit video") { take?.let { if (it.editable) nav.go(Routes.editVideo(it.id)) else vm.toast("Only finished videos can be edited") } },
                            MenuItem("grid", "Save as template") { take?.let { if (it.shot) nav.go(Routes.saveTemplate(it.id)) else vm.toast("Templates are for photos · video templates come later") } },
                            MenuItem("export", "Copy prompt") { clip.setText(AnnotatedString(take?.prompt?.ifBlank { null } ?: s.job?.prompt ?: "")); vm.toast("Prompt copied") },
                            MenuItem("grid", "Compare takes") { if (s.takes.size > 1) compare = !compare else vm.toast("Compare takes · needs 2+ takes") },
                            MenuItem("shield", "Delete take", danger = true) { take?.let { vm.discard(it, nav) } },
                        ), tint = Color.White)
                    }
                }
                // A real video has the player's own controls along the bottom: keep the side actions above them.
                Column(Modifier.align(Alignment.BottomEnd).padding(end = 14.dp, bottom = if (take?.videoUrl != null) 96.dp else 40.dp), verticalArrangement = Arrangement.spacedBy(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    SideAction("retry", if (s.job != null) "Retry · ${Pricing.money(s.retryCost)}" else "Retry") { vm.retry(nav) }
                    SideAction("export", "Download") { vm.export(context, take) }
                    if (take?.editable == true) SideAction("retry", "Edit") { nav.go(Routes.editVideo(take.id)) }
                    SideAction("upload", "Post") { take?.let { nav.go(Routes.post(it.id)) } }
                    if (take?.shot == true) SideAction("grid", "Save look") { nav.go(Routes.saveTemplate(take.id)) }
                }
            }
            Column(
                Modifier.fillMaxWidth().background(m.roles.canvas).navigationBarsPadding()
                    .padding(start = MuseSpace.gutter, end = MuseSpace.gutter, top = MuseSpace.s4, bottom = MuseSpace.s1),
                verticalArrangement = Arrangement.spacedBy(MuseSpace.s4),
            ) {
                if (take == null) {
                    ErrorState("This take isn't here any more", "It may have been discarded. Your other takes are in the Library.", null)
                    PrimaryButton("Back to Library", { nav.tab(Routes.GALLERY) }, Modifier.fillMaxWidth())
                } else {
                    Row(verticalAlignment = Alignment.Top) {
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            T(take.shownTitle, m.scale.heading, m.roles.ink)
                            take.templateName?.let { Caption("Template: $it") }
                            Caption(listOf(take.engineLabel, Pricing.money(take.cost)).filter { it.isNotBlank() }.joinToString(" · "))
                            takeSpecs(take)?.let { T(it, m.scale.caption.tabular(), m.roles.ink2) }
                        }
                        RowValue(if (take.final) "Final" else "Test", if (take.final) m.roles.positive else m.roles.ink2)
                    }
                    s.posts.firstOrNull { it.takeId == take.id && it.stats != null }?.let { p ->
                        Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s1), verticalAlignment = Alignment.CenterVertically) {
                            p.platforms.mapNotNull { studio.muse.app.data.Platform.of(it) }.forEach { PlatformBadge(it, 16.dp) }
                            p.stats?.let { st -> T(" ${String.format(java.util.Locale.US, "%,d", st.views)} views · ${String.format(java.util.Locale.US, "%,d", st.likes)} likes", m.scale.caption.tabular(), m.roles.ink2) }
                        }
                    }
                    if (take.kind == "take" && take.videoUrl != null) UpscaleRow(s.upscale, take.durationSec) { z -> vm.upscale(take, z) }
                    if (take.editable) EditVideoRow(take, s.versions(take)) { nav.go(Routes.editVideo(take.id)) }
                    Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
                        SecondaryButton("Discard", { vm.discard(take, nav) }, Modifier.weight(1f))
                        PrimaryButton(if (take.final) "Approved" else "Approve", { vm.approve(take, celebrate) }, Modifier.weight(1f))
                    }
                }
            }
        }
    }
}

@Composable
private fun SideAction(icon: String, label: String, onClick: () -> Unit) {
    Column(Modifier.widthIn(min = 48.dp).press(onClick = onClick).semantics(mergeDescendants = true) {}, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Ic(icon, 22.dp, Color.White)
        T(label, muse.scale.micro.copy(shadow = androidx.compose.ui.graphics.Shadow(Color.Black.copy(alpha = .5f), blurRadius = 3f)).tabular(), Color.White)
    }
}

// ======================================================================= Gallery

data class GalleryState(val tab: String = "tests", val tests: List<Take> = emptyList(), val finals: List<Take> = emptyList(), val fresh: Int = 0,
    val loaded: Boolean = true, val error: String? = null)

class GalleryViewModel(private val c: AppContainer) : ViewModel() {
    val state: StateFlow<GalleryState> = combine(c.repo.state, c.drafts.galleryTab, c.drafts.freshShots) { s, tab, fresh ->
        GalleryState(tab, s.takes.filter { !it.final }, s.takes.filter { it.final }, fresh, s.loaded, s.error)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, GalleryState())

    fun tab(t: String) { c.drafts.galleryTab.value = t }
    fun seen() { c.drafts.freshShots.value = 0 }
    fun retry() = viewModelScope.launch { c.repo.refresh() }
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
    ScreenBox(bg = m.roles.canvas) {
        // Performance: a lazy list (only the rows on screen are composed and their thumbnails loaded), keyed by take.
        val rows = remember(list) { list.chunked(3) }
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = MuseSpace.gutter, end = MuseSpace.gutter, top = MuseSpace.s4, bottom = 120.dp),
            verticalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
            item(key = "title", contentType = "title") { DisplayTitle("Library") }
            item(key = "tabs", contentType = "tabs") {
                Segmented(listOf("tests" to "Tests · ${s.tests.size}", "final" to "Final · ${s.finals.size}"), s.tab, vm::tab, Modifier.padding(bottom = MuseSpace.s2))
            }
            if (list.isEmpty() && !s.loaded) items(2, key = { "skeleton$it" }, contentType = { "row" }) {
                Row(Modifier.semantics { contentDescription = "Loading your renders" }, horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
                    repeat(3) { Skeleton(Modifier.weight(1f).height(170.dp), containerShape()) }
                }
            }
            else if (list.isEmpty() && s.error != null) item(key = "error", contentType = "note") {
                ErrorState("Can't load your renders", s.error ?: "", onAction = { vm.retry() })
            } else if (list.isEmpty()) item(key = "empty", contentType = "note") {
                if (s.tab == "final") EmptyState("Nothing approved yet", "Approve a take you want to keep and it moves here.", "Show test renders", { vm.tab("tests") }, primary = false)
                else EmptyState("No test renders yet", "Videos and photos you make land here first. Approve the ones you keep.", "New shot", { studio.muse.app.ui.screens.suite.composer.openShot(c, nav) })
            } else {
                itemsIndexed(rows, key = { _, row -> row.first().id }, contentType = { _, _ -> "row" }) { r, row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
                        row.forEachIndexed { i, t ->
                            val idx = r * 3 + i
                            val isNew = s.tab == "tests" && idx < fresh
                            val shape = containerShape()
                            Box(
                                Modifier.weight(1f).height(170.dp).clip(shape).background(m.roles.field).let { if (isNew) it.border(2.dp, m.roles.selection, shape) else it }
                                    .press { nav.go(Routes.result(t.jobId ?: t.id)) }
                                    .semantics(mergeDescendants = true) { contentDescription = "${t.shownTitle} · ${t.shownLabel}" },
                            ) {
                                RefImage(t.thumb, Modifier.fillMaxSize(), 20)
                                // One caption on a scrim: what it is (duration or Photo), and New for the ones just made.
                                Box(Modifier.align(Alignment.BottomStart).padding(MuseSpace.s1).clip(RoundedCornerShape(m.radii.chip)).background(Color.Black.copy(alpha = .55f))
                                    .padding(horizontal = 6.dp, vertical = 2.dp)) {
                                    T((if (isNew) "New · " else "") + t.shownLabel, m.scale.micro.tabular(), Color.White, maxLines = 1)
                                }
                            }
                        }
                        repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
                    }
                }
            }
            if (list.isNotEmpty()) item(key = "footer", contentType = "note") { Caption("Test renders stay separate from your Final takes.", Modifier.padding(top = MuseSpace.s2)) }
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
    // Performance: plays only on the page showing, while it is on screen and the app is in front.
    var onScreen by remember { mutableStateOf(true) }
    androidx.lifecycle.compose.LifecycleResumeEffect(player, active, onScreen) {
        player.playWhenReady = active && onScreen
        onPauseOrDispose { player.pause() }
    }
    Box(modifier.onVisibilityChanged(minFractionVisible = .2f) { onScreen = it }) {
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

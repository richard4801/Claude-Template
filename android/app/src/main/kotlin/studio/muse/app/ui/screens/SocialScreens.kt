package studio.muse.app.ui.screens

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import studio.muse.app.AppContainer
import studio.muse.app.data.Account
import studio.muse.app.data.CreatePostRequest
import studio.muse.app.data.Model
import studio.muse.app.data.Platform
import studio.muse.app.data.Post
import studio.muse.app.data.Take
import studio.muse.app.platform.Handoff
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.components.*
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.temporal.TemporalAdjusters
import java.util.Locale

// ======================================================================= shared bits

/** Platform badge: a coloured rounded square with letters (never a brand logo). */
@Composable
fun PlatformBadge(p: Platform, size: Dp = 28.dp) {
    Box(Modifier.size(size).clip(RoundedCornerShape(size * .28f)).background(Color(p.color)), contentAlignment = Alignment.Center) {
        T(p.badge, androidx.compose.ui.text.TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.ExtraBold, fontSize = (size.value * .38f).sp, letterSpacing = (-.02).em), Color.White, maxLines = 1)
    }
}

/** Time labels: "Today · 7:30 PM", "Tomorrow · 12:00 PM", "Fri · 6:00 PM". */
object PostTime {
    private val time = DateTimeFormatter.ofPattern("h:mm a", Locale.US)
    private val day = DateTimeFormatter.ofPattern("EEE", Locale.US)

    fun label(at: Long, now: Long = System.currentTimeMillis(), zone: ZoneId = ZoneId.systemDefault()): String {
        val t = Instant.ofEpochMilli(at).atZone(zone)
        val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
        val d = when (t.toLocalDate()) { today -> "Today"; today.plusDays(1) -> "Tomorrow"; else -> t.format(day) }
        return "$d · ${t.format(time)}"
    }

    /** The three schedule chips: the next 7:30 PM, tomorrow at noon, and Friday 6 PM (at least a day out). */
    fun slots(now: Long = System.currentTimeMillis(), zone: ZoneId = ZoneId.systemDefault()): List<Long> {
        val n = Instant.ofEpochMilli(now).atZone(zone)
        fun at(d: LocalDate, h: Int, m: Int) = ZonedDateTime.of(d, LocalTime.of(h, m), zone).toInstant().toEpochMilli()
        val evening = at(n.toLocalDate(), 19, 30).let { if (it > now + 15 * 60_000) it else at(n.toLocalDate().plusDays(1), 19, 30) }
        val noon = at(n.toLocalDate().plusDays(1), 12, 0)
        val friday = at(n.toLocalDate().plusDays(2).with(TemporalAdjusters.nextOrSame(DayOfWeek.FRIDAY)), 18, 0)
        return listOf(evening, noon, friday).distinct()
    }

    fun ago(at: Long?, now: Long = System.currentTimeMillis()): String {
        if (at == null) return "just now"
        val min = (now - at) / 60_000
        return when { min < 1 -> "just now"; min < 60 -> "${min}m ago"; min < 60 * 24 -> "${min / 60}h ago"; else -> "${min / 60 / 24}d ago" }
    }

    fun iso(at: Long): String = Instant.ofEpochMilli(at).toString()
}

private fun Long.grouped() = String.format(Locale.US, "%,d", this)
fun statsLine(p: Post) = p.stats?.let { "${it.views.grouped()} views · ${it.likes.grouped()} likes · ${it.comments.grouped()} comments" }

/** Opens the handoff for one platform of a post and reports what happened. */
fun openHandoff(context: android.content.Context, c: AppContainer, p: Post, platform: Platform) {
    val r = Handoff.open(context, platform, p.caption, p.thumb)
    val rest = p.platforms.mapNotNull { Platform.of(it) }.filter { it != platform }
    c.repo.toast(r.message + if (rest.isNotEmpty()) " · then ${rest.first().label} from Posts" else "", Routes.POSTS)
}

private fun firstName(m: Model?) = m?.name?.split(" ")?.firstOrNull() ?: "Her"

// ======================================================================= Accounts

data class AccountsState(val model: Model? = null, val accounts: List<Account> = emptyList(), val posts: Int = 0, val busy: Set<String> = emptySet())

class AccountsViewModel(private val c: AppContainer) : ViewModel() {
    private val busy = MutableStateFlow(emptySet<String>())
    val state: StateFlow<AccountsState> = combine(c.repo.state, c.drafts.modelId, busy) { s, mid, b ->
        val m = s.model(mid) ?: s.models.firstOrNull()
        AccountsState(m, s.accountsOf(m?.id), s.posts.count { it.modelId == m?.id }, b)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, AccountsState())

    fun connect(p: Platform) = viewModelScope.launch {
        val m = state.value.model ?: return@launch
        if (p.id in busy.value) return@launch
        busy.update { it + p.id }
        val r = c.repo.connect(m.id, p.id)
        busy.update { it - p.id }
        when {
            r?.account != null -> c.repo.toast("${p.label} connected")
            r?.authUrl != null -> c.repo.toast("Finish signing in to ${p.label} in the browser")
        }
    }

    fun disconnect(p: Platform) = viewModelScope.launch {
        val m = state.value.model ?: return@launch
        if (c.repo.disconnect(m.id, p.id) != null) c.repo.toast("${p.label} disconnected")
    }
}

@Composable
fun AccountsScreen() {
    val c = LocalContainer.current
    val vm: AccountsViewModel = viewModel { AccountsViewModel(c) }
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    val m = muse
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar("Accounts", onBack = { nav.back() })
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 6.dp, bottom = 120.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                T("${firstName(s.model)}'s own accounts. Posts from her renders go here, not to your personal accounts.", m.type.body.copy(fontSize = 14.sp, lineHeight = 20.sp), m.t.ink)
                ListGroup {
                    Platform.entries.forEachIndexed { i, p ->
                        if (i > 0) ListDivider()
                        val a = s.accounts.firstOrNull { it.platform == p.id }
                        TwoLineRow(p.label, a?.handle ?: "Not connected", lead = { PlatformBadge(p, 32.dp) }) {
                            when {
                                a != null -> T("Disconnect", m.type.tiny.copy(fontWeight = FontWeight.SemiBold), m.link, Modifier.press { vm.disconnect(p) }.padding(vertical = 8.dp))
                                p.id in s.busy -> Cta2("Signing in…", {}, Modifier.shimmer(), height = 36.dp)
                                else -> Cta2("Connect", { vm.connect(p) }, height = 36.dp)
                            }
                        }
                    }
                }
                NoteBox("For now MUSE opens each app with your video and caption ready to post. Direct posting and auto-scheduling switch on per platform once it approves MUSE.")
                ListGroup { Li("queue", "Scheduled and posted", onClick = { nav.go(Routes.POSTS) }) { Tiny("${s.posts}"); Ic("chev", 16.dp) } }
            }
        }
    }
}

// ======================================================================= Post

data class PostDraft(
    val platforms: List<String> = emptyList(),
    val caption: String = "",
    val aiLabel: Boolean = false,
    val paidPartnership: Boolean = false,
    val later: Boolean = false,
    val slot: Int = 0,
)

data class PostState(val take: Take? = null, val model: Model? = null, val connected: List<Platform> = emptyList(), val draft: PostDraft = PostDraft(), val slots: List<Long> = emptyList())

class PostViewModel(private val c: AppContainer, private val takeId: String) : ViewModel() {
    private val draft = MutableStateFlow<PostDraft?>(null)
    private val startLater = c.drafts.postStartScheduled.value.also { c.drafts.postStartScheduled.value = false }
    private val slots = PostTime.slots()
    val state: StateFlow<PostState> = combine(c.repo.state, draft) { s, d ->
        val take = s.takes.firstOrNull { it.id == takeId } ?: s.takes.firstOrNull { it.jobId == takeId }
        val modelId = take?.jobId?.let { s.job(it)?.modelId } ?: c.drafts.modelId.value
        val model = s.model(modelId) ?: s.models.firstOrNull()
        val connected = Platform.entries.filter { p -> s.account(model?.id, p.id) != null }
        // Like the prototype: the first two connected accounts start selected. Labels always start off.
        val dd = (d ?: PostDraft(platforms = connected.take(2).map { it.id }, later = startLater)).let { it.copy(platforms = it.platforms.filter { p -> connected.any { c -> c.id == p } }) }
        PostState(take, model, connected, dd, slots)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, PostState())

    private fun edit(f: (PostDraft) -> PostDraft) { draft.value = f(state.value.draft) }
    fun platform(p: Platform) = edit { d -> d.copy(platforms = if (p.id in d.platforms) d.platforms - p.id else d.platforms + p.id) }
    fun caption(v: String) = edit { it.copy(caption = v) }
    fun ai() = edit { it.copy(aiLabel = !it.aiLabel) }
    fun paid() = edit { it.copy(paidPartnership = !it.paidPartnership) }
    fun later(v: Boolean) = edit { it.copy(later = v) }
    fun slot(i: Int) = edit { it.copy(slot = i) }
    fun toast(s: String) = c.repo.toast(s)

    fun go(context: android.content.Context, done: () -> Unit) = viewModelScope.launch {
        val s = state.value
        val d = s.draft
        val take = s.take ?: return@launch c.repo.toast("This take is gone")
        val model = s.model ?: return@launch
        if (d.platforms.isEmpty()) return@launch c.repo.toast("Pick at least one account")
        val at = if (d.later) s.slots.getOrNull(d.slot) else null
        val req = CreatePostRequest(model.id, take.id, d.platforms, d.caption.trim(), d.aiLabel, d.paidPartnership, at?.let { PostTime.iso(it) } ?: "now")
        val post = c.repo.createPost(req) ?: return@launch
        if (at == null) {
            Platform.of(post.platforms.first())?.let { openHandoff(context, c, post, it) }
        } else {
            c.postAlarms?.schedule(post)
            c.repo.toast("Scheduled for ${PostTime.label(at)} · we'll remind you", Routes.POSTS)
        }
        done()
    }
}

@Composable
fun PostScreen(takeId: String) {
    val c = LocalContainer.current
    val vm: PostViewModel = viewModel(key = "post-$takeId") { PostViewModel(c, takeId) }
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    val context = LocalContext.current
    val m = muse
    val d = s.draft
    val notif = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { vm.go(context) { nav.back() } }
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar("Post", onBack = { nav.back() })
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 6.dp, bottom = 130.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    val shape = RoundedCornerShape(m.t.r * .6f)
                    RefImage(s.take?.thumb, Modifier.size(54.dp, 72.dp).clip(shape).let { if (m.isD) it.border(2.5.dp, Ink, shape) else it }, 20)
                    Column(Modifier.weight(1f)) {
                        T(s.take?.title ?: "", m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink)
                        Tiny("${s.model?.name ?: ""} · 1080×1920")
                    }
                }
                Field("Post to") {
                    if (s.connected.isNotEmpty()) FlowRow {
                        s.connected.forEach { p -> PlatformChip(p, p.id in d.platforms) { vm.platform(p) } }
                    }
                    if (s.connected.size < 5) T(
                        if (s.connected.isEmpty()) "+ Connect ${firstName(s.model)}'s accounts" else "+ Connect more accounts",
                        m.type.tiny.copy(fontWeight = FontWeight.SemiBold), m.link, Modifier.press { nav.go(Routes.ACCOUNTS) }.padding(vertical = 4.dp),
                    )
                }
                Field("Caption") { Input(d.caption, vm::caption, placeholder = "Write a caption and hashtags", area = true) }
                ListGroup {
                    TwoLineRow("Mark as AI-generated", "Turns on the platform's own AI label") { Toggle(d.aiLabel, vm::ai) }
                    ListDivider()
                    TwoLineRow("Paid partnership", "Turns on the platform's branded-content tag") { Toggle(d.paidPartnership, vm::paid) }
                }
                val noField = d.platforms.filter { it == Platform.X.id }
                if ((d.aiLabel || d.paidPartnership) && noField.isNotEmpty()) Tiny("X has no field for these labels, so they won't be set there.")
                Field("When") {
                    Seg(listOf("now" to "Now", "later" to "Schedule"), if (d.later) "later" else "now", { vm.later(it == "later") })
                    if (d.later) {
                        FlowRow { s.slots.forEachIndexed { i, at -> Chip(PostTime.label(at), d.slot == i, { vm.slot(i) }) } }
                        Tiny("We'll notify you at that time and open each app with the post ready.")
                    }
                }
            }
        }
        Dock {
            val n = d.platforms.size
            val label = if (!d.later) (if (n == 0) "Pick an account to post" else "Post to $n account${if (n == 1) "" else "s"}") else "Schedule · ${s.slots.getOrNull(d.slot)?.let { PostTime.label(it) } ?: ""}"
            Cta(label, {
                when {
                    n == 0 -> vm.toast("Pick at least one account")
                    d.later && Build.VERSION.SDK_INT >= 33 &&
                        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED ->
                        notif.launch(Manifest.permission.POST_NOTIFICATIONS)
                    else -> vm.go(context) { nav.back() }
                }
            }, Modifier.weight(1f), off = n == 0)
        }
    }
}

@Composable
private fun PlatformChip(p: Platform, on: Boolean, onClick: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(if (m.isA) 2.dp else 999.dp)
    val (bg, fg) = when {
        !on -> (if (m.isB) m.t.surface2 else m.t.surface) to m.t.ink
        m.isD -> m.t.blue to Color.White
        m.isB -> m.t.accent to m.t.accentInk
        else -> m.t.accent to Color.White
    }
    var mod = Modifier.height(36.dp).clip(shape).background(bg)
    mod = when { m.isD -> mod.border(2.5.dp, Ink, shape); m.isC -> mod; else -> mod.border(m.t.stroke, if (on) bg else m.t.line, shape) }
    Row(mod.press(onClick = onClick).padding(start = 6.dp, end = 14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        PlatformBadge(p, 20.dp)
        T(p.label, m.type.chip, fg, maxLines = 1)
    }
}

// ======================================================================= Posts

data class PostsState(val tab: String = "scheduled", val scheduled: List<Post> = emptyList(), val out: List<Post> = emptyList())

class PostsViewModel(private val c: AppContainer) : ViewModel() {
    private val tab = c.drafts.postsTab
    val state: StateFlow<PostsState> = combine(c.repo.state, tab) { s, t ->
        PostsState(t, s.posts.filter { it.scheduled }.sortedBy { it.whenMillis ?: 0 }, s.posts.filter { it.out }.sortedByDescending { it.postedAt ?: it.createdAt })
    }.stateIn(viewModelScope, SharingStarted.Eagerly, PostsState())

    fun tab(t: String) { tab.value = t }
    fun cancel(p: Post) = viewModelScope.launch {
        if (c.repo.deletePost(p.id) != null) { c.postAlarms?.cancel(p); c.repo.toast("Scheduled post cancelled") }
    }
}

@Composable
fun PostsScreen() {
    val c = LocalContainer.current
    val vm: PostsViewModel = viewModel { PostsViewModel(c) }
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    val context = LocalContext.current
    val m = muse
    val list = if (s.tab == "scheduled") s.scheduled else s.out
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar("Posts", onBack = { nav.back() })
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 6.dp, bottom = 120.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                item(key = "tabs", contentType = "tabs") { Seg(listOf("scheduled" to "Scheduled · ${s.scheduled.size}", "posted" to "Posted · ${s.out.size}"), s.tab, vm::tab) }
                if (list.isEmpty()) item(key = "empty", contentType = "note") { NoteBox(if (s.tab == "scheduled") "Nothing scheduled. Open a finished take and tap Post." else "Nothing posted yet.", icon = "spark") }
                items(list.distinctBy { it.id }, key = { it.id }, contentType = { "post" }) { p ->
                    var menu by remember { mutableStateOf(false) }
                    Box {
                        PostRow(p) { menu = true }
                        MuseMenu(menu, { menu = false }, p.platforms.mapNotNull { Platform.of(it) }.map { pl ->
                            MenuItem("export", "Open ${pl.label}") { openHandoff(context, c, p, pl) }
                        } + if (p.scheduled) listOf(MenuItem("shield", "Cancel post", danger = true) { vm.cancel(p) }) else emptyList())
                    }
                }
            }
        }
    }
}

@Composable
private fun PostRow(p: Post, onClick: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(m.t.r)
    var mod = Modifier.fillMaxWidth()
    mod = when {
        m.isC -> mod.softShadow(m.t.r).clip(shape).background(m.t.surface)
        m.isD -> mod.hardShadow(3.dp, m.t.r).clip(shape).background(m.t.surface).border(2.5.dp, Ink, shape)
        else -> mod.clip(shape).background(m.t.surface).border(m.t.stroke, m.t.line, shape)
    }
    Row(mod.press(onClick = onClick).padding(10.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
        RefImage(p.thumb, Modifier.size(54.dp, 72.dp).clip(RoundedCornerShape(m.t.r * .6f)), 20)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            T(p.title, m.type.body.copy(fontSize = 14.sp, fontWeight = FontWeight.Bold), m.t.ink, maxLines = 1)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                p.platforms.mapNotNull { Platform.of(it) }.forEach { PlatformBadge(it, 18.dp) }
                Spacer(Modifier.width(4.dp))
                Tiny(when {
                    p.scheduled -> p.whenMillis?.let { PostTime.label(it) } ?: "Scheduled"
                    p.state == "handoff" -> "Handed off ${PostTime.ago(p.createdAt)}"
                    else -> "Posted ${PostTime.ago(p.postedAt)}"
                })
            }
            statsLine(p)?.let { T(it, m.type.mono.copy(fontSize = 11.5.sp), m.t.muted) }
        }
    }
}

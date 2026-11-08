package studio.muse.app.ui.screens

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.wrapContentSize
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
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
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import studio.muse.app.AppContainer
import studio.muse.app.BuildConfig
import studio.muse.app.data.AppPrefs
import studio.muse.app.data.Balance
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.TabBar
import studio.muse.app.ui.components.*
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.MuseTheme
import studio.muse.app.ui.theme.ThemeId
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.MuseSpace
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import studio.muse.core.Pricing
import studio.muse.core.RenderSpec

data class SettingsState(
    val prefs: AppPrefs = AppPrefs(), val balance: Balance = Balance(0.0, 0.0), val videos: Int = 0, val failNext: Boolean = false,
    val modelName: String? = null, val connected: Int = 0, val scheduled: Int = 0, val wallet: studio.muse.app.data.Wallet? = null,
)

class SettingsViewModel(val c: AppContainer) : ViewModel() {
    private val failNext = kotlinx.coroutines.flow.MutableStateFlow(false)
    val state: StateFlow<SettingsState> = combine(c.prefs, c.repo.state, failNext, c.drafts.modelId) { p, s, f, mid ->
        val m = s.model(mid) ?: s.models.firstOrNull()
        SettingsState(p, s.balance, s.jobs.count { it.done } + 9, f, m?.name?.split(" ")?.first(), s.accountsOf(m?.id).size, s.posts.count { it.scheduled }, s.wallet)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, SettingsState(c.prefs.value))

    private fun upd(f: (AppPrefs) -> AppPrefs) = viewModelScope.launch { c.prefsStore.update(f) }

    fun theme(t: ThemeId) {
        if (t.key == c.prefs.value.theme) return
        upd { it.copy(theme = t.key) }
    }

    /** Demo mode and the server are separate studios: switching signs out (the token belongs to one of them). */
    fun useFake(v: Boolean, onSwitched: () -> Unit) = viewModelScope.launch {
        c.prefsStore.update { it.copy(useFake = v, token = if (v) "demo" else null, role = if (v) "owner" else "member", studioName = if (v) "Jenne Studio" else "") }
        c.drafts.forgetAccount()
        c.repo.toast(if (v) "Demo mode · the sample studio, no server" else "Using the server at ${c.prefs.value.serverUrl.removeSuffix("/")} · sign in")
        onSwitched()
    }
    fun serverUrl(v: String) = upd { it.copy(serverUrl = v) }
    fun resetServer(onSwitched: () -> Unit) = viewModelScope.launch {
        if (c.prefs.value.serverUrl == BuildConfig.DEFAULT_SERVER_URL) return@launch
        c.prefsStore.update { it.copy(serverUrl = BuildConfig.DEFAULT_SERVER_URL, token = null) }
        c.repo.toast("Back to the MUSE server · sign in")
        onSwitched()
    }
    val demo get() = c.repo.demo
    fun fastBeta() = upd { it.copy(fastBeta = !it.fastBeta) }
    fun failNext() = viewModelScope.launch {
        val v = !failNext.value
        if (c.repo.setFailNext(v) != null) { failNext.value = v; c.repo.toast(if (v) "Next render will fail partway" else "Renders back to normal") }
    }
    fun signOut(onDone: () -> Unit) = viewModelScope.launch { c.repo.signOut(); c.drafts.forgetAccount(); onDone() }
    fun topUp(amount: Double, method: String) = viewModelScope.launch {
        if (c.repo.topUp(amount, method) != null) c.repo.toast("Added ${Pricing.money(amount)} · demo, no payment taken")
    }
    fun notifStatus() = c.notifier?.canPost() ?: false
    fun openNotificationSettings(from: android.content.Context) = c.notifier?.openSettings(from)
    fun toast(s: String) = c.repo.toast(s)
}

@Composable
private fun settingsVm(): SettingsViewModel {
    val c = LocalContainer.current
    return viewModel { SettingsViewModel(c) }
}

@Composable
fun SettingsScreen() {
    val vm = settingsVm()
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    val m = muse
    val context = LocalContext.current
    var notifOn by remember { mutableStateOf(vm.notifStatus()) }
    var notifAskedHere by remember { mutableStateOf(false) }
    // Re-read on return from system settings.
    LifecycleResumeEffect(Unit) { notifOn = vm.notifStatus(); onPauseOrDispose {} }
    val notifLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { notifOn = it }
    val studio by vm.c.repo.state.collectAsState()
    val preview = remember(studio.models, studio.outfits) { previewProfileState(studio, vm.demo) }
    ScreenBox(bg = m.roles.canvas) {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = MuseSpace.gutter).padding(top = MuseSpace.s4, bottom = 120.dp),
            verticalArrangement = Arrangement.spacedBy(MuseSpace.s6),
        ) {
            DisplayTitle("Settings")
            Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
                Heading("Theme")
                ThemeId.entries.chunked(2).forEach { row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
                        row.forEach { t -> ThemeCard(t, t.key == s.prefs.theme, Modifier.weight(1f), preview) { vm.theme(t) } }
                    }
                }
            }
            Column {
                RowItem("Notifications", "Sound and alerts follow your phone's notification settings", onClick = {
                    // Off on Android 13+: ask once from here; after that (or when on) open the system page.
                    if (!notifOn && Build.VERSION.SDK_INT >= 33 && !notifAskedHere) { notifAskedHere = true; notifLauncher.launch(Manifest.permission.POST_NOTIFICATIONS) }
                    else vm.openNotificationSettings(context)
                }) { RowValue(if (notifOn) "On" else "Off"); Chevron() }
                s.modelName?.let { name -> RowItem("$name's accounts", onClick = { nav.go(Routes.ACCOUNTS) }) { RowValue("${s.connected} of 5"); Chevron() } }
                RowItem("Scheduled posts", onClick = { nav.go(Routes.POSTS) }) { RowValue("${s.scheduled}"); Chevron() }
                RowItem("Credit", onClick = { nav.go(Routes.CREDITS) }) { RowValue(creditLabel(s.wallet, s.balance)); Chevron() }
            }
            if (s.prefs.owner) Column {
                Heading("Studio")
                RowItem("Members", "Send credit, set caps, switch accounts off", onClick = { nav.go(Routes.MEMBERS) }) { Chevron() }
                RowItem("Invite someone", onClick = { nav.go(Routes.INVITE) }) { Chevron() }
                RowItem("Studio settings", "Caps and engines", onClick = { nav.go(Routes.STUDIO) }) { Chevron() }
                RowItem("Default models", "What Auto uses for shots, photos, swaps and the rest", onClick = { nav.go(Routes.DEFAULT_MODELS) }) { Chevron() } // WS7
                RowItem("Prompts", "Every prompt the studio sends: edit or reset", onClick = { nav.go(Routes.PROMPTS) }) { Chevron() }
                RowItem("Connections", "Claude, MCP and the Blender relay", onClick = { nav.go(Routes.CONNECTIONS) }) { Chevron() } // AI suite (workstream 1 → 2)
            }
            Column {
                Heading("Developer")
                RowItem("Demo mode", "The sample studio, in the app, no server", onClick = { vm.useFake(!s.prefs.useFake) { nav.reset(if (s.prefs.useFake) Routes.WELCOME else Routes.HOME) } }) {
                    Toggle(s.prefs.useFake, { vm.useFake(!s.prefs.useFake) { nav.reset(if (s.prefs.useFake) Routes.WELCOME else Routes.HOME) } })
                }
                if (!s.prefs.useFake) Labeled("Server", Modifier.padding(vertical = MuseSpace.s2)) {
                    Input(s.prefs.serverUrl, vm::serverUrl, placeholder = BuildConfig.DEFAULT_SERVER_URL, keyboard = androidx.compose.ui.text.input.KeyboardType.Uri, calm = true)
                    if (s.prefs.serverUrl != BuildConfig.DEFAULT_SERVER_URL) TextAction("Use the MUSE server", { vm.resetServer { nav.reset(Routes.WELCOME) } })
                }
                RowItem("Fast · beta", onClick = { vm.fastBeta() }) { Toggle(s.prefs.fastBeta, { vm.fastBeta() }) }
                // A demo-studio test switch: the real server has no such thing.
                if (vm.demo) RowItem("Next render fails (test)", onClick = { vm.failNext() }) { Toggle(s.failNext, { vm.failNext() }) }
            }
            Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
                SecondaryButton("Sign out", { vm.signOut { nav.reset(Routes.WELCOME) } }, Modifier.fillMaxWidth())
                if (s.prefs.email.isNotBlank()) Caption("Signed in as ${s.prefs.email}")
            }
            Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s1)) {
                // Model names are owner-only (plans/app-cleanup.md); the owner sees the licence attribution.
                if (s.prefs.owner) Caption("Video model: MiniMax H3. Lip sync: LatentSync.")
                Caption("MUSE ${BuildConfig.VERSION_NAME}. " + if (s.prefs.owner) "MiniMax H3 licence terms apply." else "Third-party model licence terms apply.")
            }
        }
        TabBar(Routes.SETTINGS)
    }
}

/** Live preview: the real profile layout rendered in that theme, scaled down. The chosen one has the selection outline. */
@Composable
private fun ThemeCard(t: ThemeId, on: Boolean, modifier: Modifier, preview: ProfileState, onClick: () -> Unit) {
    val m = muse
    val shape = containerShape()
    Column(modifier.press(onClick = onClick).semantics { selected = on; contentDescription = "${t.label} theme" }, verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
        // The chosen theme has the selection outline; the others a hairline edge (none in Creator Pop, whose hairline is ink).
        val edge = Modifier.let { if (on) it.border(2.dp, m.roles.selection, shape).padding(2.dp) else if (m.isD) it else it.border(1.dp, m.roles.hairline, shape).padding(1.dp) }
        Box(Modifier.fillMaxWidth().height(170.dp).clip(shape).then(edge)) {
            ThemePreview(t, preview, Modifier.fillMaxSize())
        }
        T(t.label, m.scale.label.copy(fontWeight = if (on) FontWeight.SemiBold else FontWeight.Medium), if (on) m.roles.ink else m.roles.ink2)
    }
}

@Composable
fun ThemePreview(t: ThemeId, modifier: Modifier) = ThemePreview(t, sampleProfileState(), modifier)

/** The theme cards show the studio's own first ready model; the bundled sample only in Demo mode, unnamed otherwise. */
fun previewProfileState(st: studio.muse.app.data.StudioState, demo: Boolean): ProfileState =
    st.models.firstOrNull { it.locked }?.let { md -> ProfileState(md, st.outfitsOf(md.id), 0) }
        ?: sampleProfileState().let { if (demo) it else it.copy(model = it.model?.copy(name = "Your model")) }

@Composable
fun ThemePreview(t: ThemeId, state: ProfileState, modifier: Modifier) {
    BoxWithConstraints(modifier) {
        val scale = maxWidth.value / 390f
        Box(Modifier.wrapContentSize(Alignment.TopStart, unbounded = true).requiredSize(390.dp, 844.dp).graphicsLayer {
            scaleX = scale; scaleY = scale; transformOrigin = TransformOrigin(0f, 0f)
        }) {
            MuseTheme(t) { ProfileContent(state, ProfileActions(menu = false)) }
        }
    }
}

@Composable
fun ListGroup(content: @Composable ColumnScope.() -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(m.t.r)
    var mod = Modifier.fillMaxWidth()
    mod = when {
        m.isC -> mod.softShadow(m.t.r).clip(shape).background(m.t.surface)
        m.isA -> mod.clip(shape).border(1.dp, m.t.line, shape)
        else -> mod.clip(shape).background(m.t.surface).border(if (m.isD) 2.5.dp else m.t.stroke, m.t.line, shape)
    }
    Column(mod, content = content)
}

@Composable
fun Li(icon: String, label: String, onClick: () -> Unit, sub: String? = null, trailing: @Composable () -> Unit) {
    val m = muse
    Row(
        Modifier.fillMaxWidth().heightIn(min = 54.dp).drawBehind { drawLine(m.t.line, Offset(0f, size.height), Offset(size.width, size.height), m.t.stroke.toPx()) }
            .press(onClick = onClick).padding(horizontal = 14.dp, vertical = if (sub != null) 10.dp else 0.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Ic(icon, 20.dp)
        if (sub == null) T(label, m.type.body, m.t.ink, Modifier.weight(1f))
        else Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) { T(label, m.type.body, m.t.ink); Tiny(sub) }
        trailing()
    }
}

/** The balance pill and the Credit row: always dollars ("$12.50"). The owner sees what they can spend or send. */
fun creditLabel(w: studio.muse.app.data.Wallet?, b: Balance): String = when {
    w == null -> Pricing.money(b.balance)
    w.owner -> Pricing.money(w.availableToSend ?: w.usd)
    else -> Pricing.money(w.usd)
}

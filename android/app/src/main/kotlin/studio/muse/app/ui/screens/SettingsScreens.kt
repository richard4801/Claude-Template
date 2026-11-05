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
import studio.muse.core.Pricing
import studio.muse.core.RenderSpec

data class SettingsState(
    val prefs: AppPrefs = AppPrefs(), val balance: Balance = Balance(0.0, 0.0), val videos: Int = 0, val failNext: Boolean = false,
    val modelName: String = "Demo model", val connected: Int = 0, val scheduled: Int = 0, val wallet: studio.muse.app.data.Wallet? = null,
)

class SettingsViewModel(val c: AppContainer) : ViewModel() {
    private val failNext = kotlinx.coroutines.flow.MutableStateFlow(false)
    val state: StateFlow<SettingsState> = combine(c.prefs, c.repo.state, failNext, c.drafts.modelId) { p, s, f, mid ->
        val m = s.model(mid) ?: s.models.firstOrNull()
        SettingsState(p, s.balance, s.jobs.count { it.done } + 9, f, m?.name?.split(" ")?.first() ?: "Model", s.accountsOf(m?.id).size, s.posts.count { it.scheduled }, s.wallet)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, SettingsState(c.prefs.value))

    private fun upd(f: (AppPrefs) -> AppPrefs) = viewModelScope.launch { c.prefsStore.update(f) }

    fun theme(t: ThemeId) {
        if (t.key == c.prefs.value.theme) return
        upd { it.copy(theme = t.key) }
    }

    /** Demo mode and the server are separate studios: switching signs out (the token belongs to one of them). */
    fun useFake(v: Boolean, onSwitched: () -> Unit) = viewModelScope.launch {
        c.prefsStore.update { it.copy(useFake = v, token = if (v) "demo" else null, role = if (v) "owner" else "member", studioName = if (v) "Jenne Studio" else "") }
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
        if (c.repo.setFailNext(v) != null) { failNext.value = v; c.repo.toast(if (v) "Next render will fail at step 3" else "Renders back to normal") }
    }
    fun signOut(onDone: () -> Unit) = viewModelScope.launch { c.repo.signOut(); onDone() }
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
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar("Settings")
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 120.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Field("Theme") {
                    ThemeId.entries.chunked(2).forEach { row ->
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            row.forEach { t -> ThemeCard(t, t.key == s.prefs.theme, Modifier.weight(1f)) { vm.theme(t) } }
                        }
                    }
                }
                ListGroup {
                    Li("bell", "Notifications", sub = "Sound and alerts follow your phone's notification settings", onClick = {
                        // Off on Android 13+: ask once from here; after that (or when on) open the system page.
                        if (!notifOn && Build.VERSION.SDK_INT >= 33 && !notifAskedHere) { notifAskedHere = true; notifLauncher.launch(Manifest.permission.POST_NOTIFICATIONS) }
                        else vm.openNotificationSettings(context)
                    }) { Tiny(if (notifOn) "On" else "Off"); Ic("chev", 16.dp) }
                    Li("export", "${s.modelName}'s accounts", onClick = { nav.go(Routes.ACCOUNTS) }) { Tiny("${s.connected}/5"); Ic("chev", 16.dp) }
                    Li("queue", "Scheduled posts", onClick = { nav.go(Routes.POSTS) }) { Tiny("${s.scheduled}"); Ic("chev", 16.dp) }
                    Li("wallet", "Credit", onClick = { nav.go(Routes.CREDITS) }) { Tiny(creditLabel(s.wallet, s.balance)); Ic("chev", 16.dp) }
                    Li("user", "Sign out", sub = s.prefs.email.ifBlank { null }, onClick = { vm.signOut { nav.reset(Routes.WELCOME) } }) { Ic("chev", 16.dp) }
                }
                if (s.prefs.owner) {
                    Lbl("Studio")
                    ListGroup {
                        Li("model", "Members", sub = "Send credit, caps, switch accounts off", onClick = { nav.go(Routes.MEMBERS) }) { Ic("chev", 16.dp) }
                        Li("mail", "Invite someone", onClick = { nav.go(Routes.INVITE) }) { Ic("chev", 16.dp) }
                        Li("quality", "Studio settings", sub = "Caps and engines", onClick = { nav.go(Routes.STUDIO) }) { Ic("chev", 16.dp) }
                    }
                }
                Lbl("Developer")
                ListGroup {
                    Li("studio", "Demo mode", sub = "The sample studio, in the app, no server", onClick = { vm.useFake(!s.prefs.useFake) { nav.reset(if (s.prefs.useFake) Routes.WELCOME else Routes.HOME) } }) {
                        Toggle(s.prefs.useFake, { vm.useFake(!s.prefs.useFake) { nav.reset(if (s.prefs.useFake) Routes.WELCOME else Routes.HOME) } })
                    }
                    if (!s.prefs.useFake) Column(Modifier.padding(horizontal = 14.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Tiny("Server")
                        Input(s.prefs.serverUrl, vm::serverUrl, placeholder = BuildConfig.DEFAULT_SERVER_URL, keyboard = androidx.compose.ui.text.input.KeyboardType.Uri)
                        if (s.prefs.serverUrl != BuildConfig.DEFAULT_SERVER_URL) T("Use the MUSE server", m.type.tiny.copy(fontWeight = FontWeight.Bold), if (m.isD) m.t.blue else m.t.accent,
                            Modifier.press { vm.resetServer { nav.reset(Routes.WELCOME) } }.padding(vertical = 4.dp))
                    }
                    Li("quality", "Fast · beta", onClick = { vm.fastBeta() }) { Toggle(s.prefs.fastBeta, { vm.fastBeta() }) }
                    Li("shield", "Next render fails (test)", onClick = { vm.failNext() }) { Toggle(s.failNext, { vm.failNext() }) }
                }
                Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    // Model names are owner-only (plans/app-cleanup.md); the owner sees the licence attribution.
                    if (s.prefs.owner) Tiny("Video model: MiniMax H3 · Lip sync: LatentSync")
                    Tiny("MUSE ${BuildConfig.VERSION_NAME}" + if (s.prefs.owner) " · MiniMax H3 licence terms apply" else " · third-party model licence terms apply")
                }
            }
        }
        TabBar(Routes.SETTINGS)
    }
}

/** Live preview: the real profile layout rendered in that theme, scaled down. */
@Composable
private fun ThemeCard(t: ThemeId, on: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(m.t.r)
    var mod = modifier
    mod = when {
        m.isD -> mod.hardShadow(3.dp, m.t.r).clip(shape).background(m.t.surface).border(if (on) 3.dp else 2.5.dp, if (on) m.t.accent else Ink, shape)
        m.isC -> mod.softShadow(m.t.r).clip(shape).background(m.t.surface).let { if (on) it.border(2.dp, m.t.accent, shape) else it }
        else -> mod.clip(shape).background(m.t.surface).border(if (on) 2.dp else m.t.stroke, if (on) m.t.accent else m.t.line, shape)
    }
    Box(mod.press(onClick = onClick).padding(10.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            ThemePreview(t, Modifier.fillMaxWidth().height(150.dp).clip(RoundedCornerShape(m.t.r * .6f)).border(1.dp, Color.Black.copy(alpha = .12f), RoundedCornerShape(m.t.r * .6f)))
            T(t.label, m.type.body.copy(fontSize = 13.sp, fontWeight = FontWeight.SemiBold), m.t.ink)
        }
        if (on) Box(Modifier.align(Alignment.TopEnd).size(22.dp).clip(CircleShape).background(m.t.accent), contentAlignment = Alignment.Center) { Ic("check", 14.dp, m.t.accentInk) }
    }
}

@Composable
fun ThemePreview(t: ThemeId, modifier: Modifier) {
    BoxWithConstraints(modifier) {
        val scale = maxWidth.value / 390f
        Box(Modifier.wrapContentSize(Alignment.TopStart, unbounded = true).requiredSize(390.dp, 844.dp).graphicsLayer {
            scaleX = scale; scaleY = scale; transformOrigin = TransformOrigin(0f, 0f)
        }) {
            MuseTheme(t) { ProfileContent(sampleProfileState(), ProfileActions(menu = false)) }
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

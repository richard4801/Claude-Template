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
    val modelName: String = "Sienna", val connected: Int = 0, val scheduled: Int = 0,
)

class SettingsViewModel(private val c: AppContainer) : ViewModel() {
    private val failNext = kotlinx.coroutines.flow.MutableStateFlow(false)
    val state: StateFlow<SettingsState> = combine(c.prefs, c.repo.state, failNext, c.drafts.modelId) { p, s, f, mid ->
        val m = s.model(mid) ?: s.models.firstOrNull()
        SettingsState(p, s.balance, s.jobs.count { it.done } + 9, f, m?.name?.split(" ")?.first() ?: "Model", s.accountsOf(m?.id).size, s.posts.count { it.scheduled })
    }.stateIn(viewModelScope, SharingStarted.Eagerly, SettingsState(c.prefs.value))

    private fun upd(f: (AppPrefs) -> AppPrefs) = viewModelScope.launch { c.prefsStore.update(f) }

    fun theme(t: ThemeId) {
        if (t.key == c.prefs.value.theme) return
        upd { it.copy(theme = t.key) }
    }

    fun useFake(v: Boolean) = upd { it.copy(useFake = v) }.also { c.repo.toast(if (v) "Using the in-app mock" else "Using the mock server at ${c.prefs.value.serverUrl}") }
    fun serverUrl(v: String) = upd { it.copy(serverUrl = v) }
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
                    Li("wallet", "Credits & billing", onClick = { nav.go(Routes.CREDITS) }) { Tiny(Pricing.money(s.balance.balance)); Ic("chev", 16.dp) }
                    Li("user", "Sign out", onClick = { vm.signOut { nav.reset(Routes.WELCOME) } }) { Ic("chev", 16.dp) }
                }
                Lbl("Developer")
                ListGroup {
                    Li("studio", "In-app mock (no server)", onClick = { vm.useFake(!s.prefs.useFake) }) { Toggle(s.prefs.useFake, { vm.useFake(!s.prefs.useFake) }) }
                    if (!s.prefs.useFake) Box(Modifier.padding(horizontal = 14.dp, vertical = 10.dp)) { Input(s.prefs.serverUrl, vm::serverUrl, placeholder = "http://10.0.2.2:8787/") }
                    Li("quality", "Fast · beta engine (Viggle)", onClick = { vm.fastBeta() }) { Toggle(s.prefs.fastBeta, { vm.fastBeta() }) }
                    Li("shield", "Next render fails (test)", onClick = { vm.failNext() }) { Toggle(s.failNext, { vm.failNext() }) }
                }
                Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Tiny("Video model: MiniMax H3 · Lip sync: LatentSync")
                    Tiny("MUSE ${BuildConfig.VERSION_NAME} · MiniMax H3 licence terms apply")
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

// ======================================================================= Credits

@Composable
fun CreditsScreen() {
    val vm = settingsVm()
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    val m = muse
    var amount by remember { mutableStateOf("25") }
    var payOpen by remember { mutableStateOf(false) }
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar("Credits", onBack = { nav.back() })
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 130.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                val shape = RoundedCornerShape(m.t.rLg)
                val (bg, fg) = when { m.isB -> m.t.surface2 to m.t.ink; m.isC -> m.t.cta to Color.White; m.isD -> m.t.blue to Color.White; else -> m.t.ink to m.t.bg }
                Box(Modifier.fillMaxWidth().let { if (m.isD) it.hardShadow(5.dp, m.t.rLg) else it }.clip(shape).background(bg).let { if (m.isD) it.border(2.5.dp, Ink, shape) else if (m.isB) it.border(1.dp, m.t.line, shape) else it }.padding(20.dp)) {
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Lbl("GPU balance", color = fg.copy(alpha = .8f))
                        T(Pricing.money(s.balance.balance), m.type.mono.copy(fontSize = 46.sp, fontWeight = FontWeight.SemiBold, lineHeight = 50.sp), if (m.isB) m.t.accent else fg)
                        Tiny("≈ ${Pricing.videosLeft(s.balance.balance)} videos at 10 steps", color = fg)
                    }
                    Sticker("top up!", "yellow", -6f, Modifier.align(Alignment.TopEnd))
                }
                Field("Top up") { Seg(listOf("10", "25", "50", "100").map { it to "$$it" }, amount, { amount = it }) }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Kpi("This month", Pricing.money(s.balance.month), Modifier.weight(1f))
                    Kpi("Per video", "~${Pricing.money(Pricing.estCost(RenderSpec()))}", Modifier.weight(1f))
                    Kpi("Videos", "${s.videos}", Modifier.weight(1f))
                }
                Field("Spend limits") {
                    LimitRow("Per job", Pricing.money(s.balance.perJobLimit))
                    LimitRow("Per day", Pricing.money(s.balance.perDayLimit))
                }
                Tiny("Renders are charged when they start and refunded in full if the GPU fails.")
            }
        }
        Dock {
            Box(Modifier.weight(1f)) {
                Cta("Add $$amount", { payOpen = true }, Modifier.fillMaxWidth())
                MuseMenu(payOpen, { payOpen = false }, listOf(
                    MenuItem("wallet", "Card · Visa / Mastercard") { vm.topUp(amount.toDouble(), "card") },
                    MenuItem("wallet", "USDT (TRC-20)") { vm.topUp(amount.toDouble(), "usdt") },
                    MenuItem("wallet", "Virtual dollar card") { vm.topUp(amount.toDouble(), "virtual") },
                ))
            }
        }
    }
}

@Composable
private fun LimitRow(label: String, value: String) {
    val m = muse
    val shape = RoundedCornerShape(m.t.r)
    Row(
        Modifier.fillMaxWidth().height(54.dp).let { if (m.isC) it.softShadow(m.t.r) else it }.clip(shape).background(m.t.surface)
            .let { if (m.isC) it else it.border(if (m.isD) 2.5.dp else m.t.stroke, m.t.line, shape) }.padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Ic("shield", 20.dp); T(label, m.type.body, m.t.ink, Modifier.weight(1f)); T(value, m.type.mono.copy(fontSize = 12.5.sp), m.t.ink)
    }
}

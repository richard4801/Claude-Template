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
import androidx.compose.ui.platform.testTag
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
    // Settings redesign (2026-11-09)
    fun showAdvanced(v: Boolean) = upd { it.copy(showAdvanced = v) }
    fun startAt(q: String) = upd { it.copy(startAt = q) }
    fun reload() = viewModelScope.launch { c.repo.refresh(); c.repo.toast("Reloaded") }
}

@Composable
internal fun settingsVm(): SettingsViewModel {
    val c = LocalContainer.current
    return viewModel { SettingsViewModel(c) }
}

/**
 * The Settings tab (redesign, 2026-11-09): who you are, then the sections this person sees, each with its one line.
 * Members: Account, Studio, AI & spending. The owner also gets Members, Providers, Apps & devices and, once turned on,
 * Advanced.
 */
@Composable
fun SettingsScreen() {
    val vm = settingsVm()
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    val m = muse
    ScreenBox(bg = m.roles.canvas) {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = MuseSpace.gutter).padding(top = MuseSpace.s4, bottom = 120.dp),
            verticalArrangement = Arrangement.spacedBy(MuseSpace.s5),
        ) {
            DisplayTitle("Settings")
            if (s.prefs.email.isNotBlank()) Caption(s.prefs.email + if (s.prefs.owner) ", owner" else ", member of ${s.prefs.studioName.ifBlank { "the studio" }}")
            Column {
                SettingsSection.visible(s.prefs.owner, s.prefs.showAdvanced).forEach { sec ->
                    RowItem(sec.title, sec.line, onClick = { nav.go(sec.route) }, modifier = Modifier.testTag("section_${sec.name.lowercase()}")) {
                        if (sec == SettingsSection.AI) RowValue(creditLabel(s.wallet, s.balance))
                        Chevron()
                    }
                }
            }
        }
        TabBar(Routes.SETTINGS)
    }
}

/** Live preview: the real profile layout rendered in that theme, scaled down. The chosen one has the selection outline. */
@Composable
internal fun ThemeCard(t: ThemeId, on: Boolean, modifier: Modifier, preview: ProfileState, onClick: () -> Unit) {
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

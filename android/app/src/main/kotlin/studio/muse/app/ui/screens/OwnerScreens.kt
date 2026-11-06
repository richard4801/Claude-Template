package studio.muse.app.ui.screens

import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
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
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import studio.muse.app.AppContainer
import studio.muse.app.data.ImageEngine
import studio.muse.app.data.ImageEnginePatch
import studio.muse.app.data.InviteCreated
import studio.muse.app.data.InviteInfo
import studio.muse.app.data.Member
import studio.muse.app.data.MemberPatch
import studio.muse.app.data.StudioSettings
import studio.muse.app.data.StudioSettingsPatch
import studio.muse.app.data.Wallet
import studio.muse.app.data.Credit
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.components.*
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.MuseSpace
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale
import studio.muse.core.Pricing
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

// ======================================================================= Owner state

data class OwnerState(
    val members: List<Member> = emptyList(),
    val invites: List<InviteInfo> = emptyList(),
    val settings: StudioSettings? = null,
    val engine: ImageEngine? = null,
    val busy: Boolean = false,
    /** Inline result of the last action: (memberId or screen, message, isError). */
    val note: Triple<String, String, Boolean>? = null,
)

class OwnerViewModel(private val c: AppContainer) : ViewModel() {
    private val _s = MutableStateFlow(OwnerState())
    val state: StateFlow<OwnerState> = _s
    val wallet get() = c.repo.state
    val memberOpen = c.drafts.memberOpen
    val lastInvite = c.drafts.lastInvite

    init {
        // Live: a member's credit moves, someone joins, an invite is made or used, settings change on another device.
        viewModelScope.launch {
            c.repo.live.collect { ev ->
                when (ev.type) {
                    "member" -> ev.member?.let { m -> _s.update { s -> s.copy(members = if (s.members.any { it.id == m.id }) s.members.map { if (it.id == m.id) m else it } else s.members + m) } }
                    "invite" -> loadInvites()
                    "settings" -> when {
                        ev.settings != null -> _s.update { it.copy(settings = ev.settings) }
                        _s.value.settings != null -> loadSettings()
                    }
                }
            }
        }
    }

    fun loadMembers() = viewModelScope.launch { c.repo.members()?.let { m -> _s.update { it.copy(members = m) } }; c.repo.refreshWallet() }
    fun loadInvites() = viewModelScope.launch { c.repo.invites()?.let { i -> _s.update { it.copy(invites = i) } } }
    fun loadSettings() = viewModelScope.launch {
        val st = c.repo.studioSettings()
        val en = c.repo.imageEngine()
        _s.update { it.copy(settings = st ?: it.settings, engine = en ?: it.engine) }
    }

    fun toggleOpen(id: String) { memberOpen.value = if (memberOpen.value == id) null else id; _s.update { it.copy(note = null) } }

    private fun note(key: String, msg: String, err: Boolean) = _s.update { it.copy(note = Triple(key, msg, err), busy = false) }
    private fun putMember(m: Member) = _s.update { s -> s.copy(members = s.members.map { if (it.id == m.id) m else it }) }

    /** [amount] is dollars ("5", "5.50"); the API moves whole tokens at the studio's rate, rounded to the nearest cent. */
    fun send(m: Member, amount: String, note: String, takeBack: Boolean) {
        val usd = Credit.parseUsd(amount) ?: return note(m.id, "Enter an amount in dollars, like 5 or 5.50", true)
        val rate = c.repo.state.value.wallet?.tokenUsd ?: Credit.DEFAULT_TOKEN_USD
        val n = Credit.tokensFor(usd, rate)
        if (n <= 0) return note(m.id, "Enter an amount in dollars, like 5 or 5.50", true)
        if (takeBack && n > m.tokens) return note(m.id, "They have ${Pricing.money(m.usd)} of unused credit", true)
        _s.update { it.copy(busy = true, note = null) }
        viewModelScope.launch {
            val (r, err) = if (takeBack) c.repo.reclaim(m, n, note) else c.repo.transfer(m, n, note)
            if (r != null) {
                putMember(r.member)
                val sent = Pricing.money(Credit.usdOf(n, rate))
                note(m.id, if (takeBack) "Took back $sent" else "Sent $sent to ${m.email.substringBefore('@')}", false)
            } else note(m.id, err ?: "Something went wrong", true)
        }
    }

    fun setCap(m: Member, cap: String) {
        val clear = cap.isBlank()
        val v = cap.trim().removePrefix("$").toDoubleOrNull()
        if (!clear && (v == null || v < 0)) return note(m.id, "Enter a dollar amount, or leave it empty for the studio default", true)
        patch(m, MemberPatch(capPerDay = v, clearCapPerDay = clear), if (clear) "Daily cap back to the studio default" else "Daily cap set to ${Pricing.money(v!!)}")
    }

    fun setEnabled(m: Member, on: Boolean) = patch(m, MemberPatch(disabled = !on), if (on) "${m.email} can sign in again" else "${m.email} is switched off and signed out")

    private fun patch(m: Member, p: MemberPatch, ok: String) {
        _s.update { it.copy(busy = true, note = null) }
        viewModelScope.launch {
            val (r, err) = c.repo.patchMember(m.id, p)
            if (r != null) { putMember(r); note(m.id, ok, false) } else note(m.id, err ?: "Something went wrong", true)
        }
    }

    fun invite(email: String) {
        if (email.isNotBlank() && !email.contains('@')) return note("invite", "Enter a valid email, or leave it empty for an open code", true)
        _s.update { it.copy(busy = true, note = null) }
        viewModelScope.launch {
            val (r, err) = c.repo.createInvite(email)
            if (r != null) { lastInvite.value = r; _s.update { it.copy(busy = false, note = null) }; loadInvites() } else note("invite", err ?: "Something went wrong", true)
        }
    }

    fun saveStudio(p: StudioSettingsPatch) {
        _s.update { it.copy(busy = true, note = null) }
        viewModelScope.launch {
            val (r, err) = c.repo.patchStudioSettings(p)
            if (r != null) { _s.update { it.copy(settings = r) }; note("studio", "Studio settings saved", false) } else note("studio", err ?: "Something went wrong", true)
        }
    }

    fun saveEngine(p: ImageEnginePatch) {
        _s.update { it.copy(busy = true, note = null) }
        viewModelScope.launch {
            val (r, err) = c.repo.setImageEngine(p)
            if (r != null) { _s.update { it.copy(engine = r) }; note("engine", "Image engine: ${engineLabel(r.provider)}", false) } else note("engine", err ?: "Something went wrong", true)
        }
    }

    fun toast(s: String) = c.repo.toast(s)
}

@Composable
private fun ownerVm(): OwnerViewModel {
    val c = LocalContainer.current
    return viewModel { OwnerViewModel(c) }
}

/** "$4.20", or "−$1.30" when the studio balance is below zero. */
fun signedMoney(v: Double) = if (v < -0.004) "−" + Pricing.money(-v) else Pricing.money(kotlin.math.max(v, 0.0))

fun engineLabel(p: String) = when (p) { "replicate" -> "Replicate"; "fal" -> "fal.ai"; "custom-http" -> "Custom (HTTP)"; else -> "Simulated" }

/** "25 min ago", "3 days ago". */
fun ago(ms: Long?, now: Long = System.currentTimeMillis()): String {
    if (ms == null || ms <= 0) return "never"
    val s = ((now - ms) / 1000).coerceAtLeast(0)
    return when {
        s < 90 -> "just now"
        s < 3600 -> "${s / 60} min ago"
        s < 86_400 -> "${s / 3600} h ago"
        s < 2 * 86_400 -> "yesterday"
        else -> "${s / 86_400} days ago"
    }
}

/** A themed card like the Credits card (`.card`). */
@Composable
fun Card(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(m.t.r)
    var mod = modifier.fillMaxWidth()
    mod = when {
        m.isC -> mod.softShadow(m.t.r).clip(shape).background(m.t.surface)
        m.isD -> mod.hardShadow(3.dp, m.t.r).clip(shape).background(m.t.surface).border(2.5.dp, Ink, shape)
        m.isA -> mod.clip(shape).border(1.dp, m.t.line, shape)
        else -> mod.clip(shape).background(m.t.surface).border(m.t.stroke, m.t.line, shape)
    }
    Box(mod.padding(14.dp)) { content() }
}

@Composable
fun InlineNote(text: String, error: Boolean) {
    Notice(text, tone = if (error) NoticeTone.DANGER else NoticeTone.POSITIVE)
}

// ======================================================================= Owner balance (the studio balance + available to send)

/** The owner-loaded studio balance (top-ups − spending) and what's free to spend or send (plans/api.md "App clean-up" §4). */
@Composable
fun OwnerBalanceCard(w: Wallet, modifier: Modifier = Modifier, studio: studio.muse.app.data.StudioBalance? = null) {
    val m = muse
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(MuseSpace.s1)) {
        Caption("Studio balance")
        T(signedMoney(studio?.balanceUsd ?: w.studioBalance ?: w.usd), m.scale.display.copy(fontFamily = m.scale.textFamily, fontWeight = FontWeight.SemiBold).tabular(), m.roles.ink)
        Caption("Free to spend or send ${signedMoney(w.availableToSend ?: 0.0)}")
        w.membersUnspentUsd?.let { Caption("Members hold ${Pricing.money(it)} in unspent credit${if (w.heldUsd > 0) ", ${Pricing.money(w.heldUsd)} on hold" else ""}") }
        studio?.let { Caption("Added ${Pricing.money(it.toppedUpUsd)}, spent ${Pricing.money(it.spentUsd)}") }
    }
}

// ======================================================================= Members

@Composable
fun MembersScreen() {
    val vm = ownerVm()
    val s by vm.state.collectAsState()
    val studio by vm.wallet.collectAsState()
    val open by vm.memberOpen.collectAsState()
    val nav = LocalNav.current
    val m = muse
    LaunchedEffect(Unit) { vm.loadMembers() }
    ScreenBox(bg = muse.roles.canvas) {
        Column(Modifier.fillMaxSize()) {
            CalmTopBar("Members", onBack = { nav.back() }, right = { BarButton("plus", "Invite someone", { nav.go(Routes.INVITE) }) })
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = MuseSpace.gutter).padding(top = MuseSpace.s2, bottom = 60.dp), verticalArrangement = Arrangement.spacedBy(MuseSpace.s5)) {
                studio.wallet?.takeIf { it.owner }?.let { OwnerBalanceCard(it) }
                val people = s.members.filterNot { it.owner }
                if (people.isEmpty()) EmptyState("No members yet", "Invite someone, then send them credit to render with.", "Invite someone", { nav.go(Routes.INVITE) }, primary = false)
                people.forEach { mem -> MemberCard(vm, mem, open == mem.id, s) }
                if (people.isNotEmpty()) SecondaryButton("Invite someone", { nav.go(Routes.INVITE) }, Modifier.fillMaxWidth(), icon = "plus")
                Caption("Amounts are in US dollars. You can't send more than the studio balance has free. Add top-ups in Credit.")
            }
        }
    }
}

@Composable
private fun MemberCard(vm: OwnerViewModel, mem: Member, open: Boolean, s: OwnerState) {
    val m = muse
    val rate = vm.wallet.collectAsState().value.wallet?.tokenUsd ?: Credit.DEFAULT_TOKEN_USD
    Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
        Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).press { vm.toggleOpen(mem.id) }, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                T(mem.email, m.scale.heading, m.roles.ink, maxLines = 1)
                T("${Pricing.money(mem.usd)}${if (mem.disabled) " · switched off" else ""}", m.scale.body.tabular(), if (mem.disabled) m.roles.caution else m.roles.ink)
                Caption("Today ${Pricing.money(mem.todayUsd)} · this month ${Pricing.money(mem.monthUsd)} · active ${ago(mem.lastActiveAt)}")
                Caption("Daily cap " + (mem.capPerDay?.let { Pricing.money(it) } ?: "is the studio default") + if (mem.heldTokens > 0) ", ${Pricing.money(Credit.usdOf(mem.heldTokens, rate))} on hold" else "")
            }
            Ic(if (open) "check" else "chev", 16.dp, m.roles.ink2)
        }
        if (open) MemberEditor(vm, mem, s)
    }
}

@Composable
private fun MemberEditor(vm: OwnerViewModel, mem: Member, s: OwnerState) {
    val m = muse
    var mode by remember(mem.id) { mutableStateOf("send") }
    var amount by remember(mem.id) { mutableStateOf("5") }
    var note by remember(mem.id) { mutableStateOf("") }
    var cap by remember(mem.id) { mutableStateOf(mem.capPerDay?.let { Pricing.toFixed(it, 2) } ?: "") }
    Column(Modifier.padding(top = 6.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Segmented(listOf("send" to "Send credit", "back" to "Take back"), mode, { mode = it })
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Labeled("Amount ($)", Modifier.weight(1f)) { Input(amount, { amount = Credit.filterInput(it) }, keyboard = KeyboardType.Decimal, placeholder = "5.00", calm = true) }
            Labeled("Note (optional)", Modifier.weight(1.6f)) { Input(note, { note = it.take(200) }, placeholder = "For the dance set", calm = true) }
        }
        val usd = Pricing.money(Credit.parseUsd(amount) ?: 0.0)
        PrimaryButton(
            if (s.busy) "Working…" else if (mode == "send") "Send $usd" else "Take back $usd",
            { vm.send(mem, amount, note, mode == "back") }, Modifier.fillMaxWidth(), busy = s.busy,
        )
        if (mode == "back") Caption("Only unused credit comes back. Credit on hold for a running render stays with it.")
        Labeled("Daily cap ($)") {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Input(cap, { cap = it.filter { c -> c.isDigit() || c == '.' } }, Modifier.weight(1f), placeholder = "Studio default", keyboard = KeyboardType.Decimal, calm = true)
                SecondaryButton("Save cap", { vm.setCap(mem, cap) }, height = 48.dp)
            }
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Column(Modifier.weight(1f)) {
                T("Account on", m.scale.body, m.roles.ink)
                Caption(if (mem.disabled) "Switched off: can't sign in or render" else "Can sign in and render")
            }
            Toggle(!mem.disabled, { vm.setEnabled(mem, mem.disabled) })
        }
        s.note?.takeIf { it.first == mem.id }?.let { InlineNote(it.second, it.third) }
    }
}

// ======================================================================= Invite someone

@Composable
fun InviteScreen() {
    val vm = ownerVm()
    val s by vm.state.collectAsState()
    val created by vm.lastInvite.collectAsState()
    val nav = LocalNav.current
    val m = muse
    var email by remember { mutableStateOf("") }
    LaunchedEffect(Unit) { vm.loadInvites() }
    ScreenBox(bg = muse.roles.canvas) {
        Column(Modifier.fillMaxSize()) {
            CalmTopBar("Invite someone", onBack = { nav.back() })
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = MuseSpace.gutter).padding(top = MuseSpace.s2, bottom = 60.dp), verticalArrangement = Arrangement.spacedBy(MuseSpace.s5)) {
                T("MUSE is invite-only. Make a code, then send it to them. It works once, for that email, for 14 days.", m.scale.body, m.roles.ink2)
                Labeled("Their email") { Input(email, { email = it.trim() }, keyboard = KeyboardType.Email, placeholder = "name@example.com", calm = true) }
                PrimaryButton(if (s.busy) "Making a code…" else "Create invite code", { vm.invite(email) }, Modifier.fillMaxWidth(), busy = s.busy)
                s.note?.takeIf { it.first == "invite" }?.let { InlineNote(it.second, it.third) }
                created?.let { InviteCodeCard(it) }
                if (s.invites.isNotEmpty()) {
                    Heading("Invites")
                    Column {
                        s.invites.take(12).forEach { i ->
                            RowItem(i.email ?: "Any email", inviteStatus(i)) {
                                val expired = i.usedAt == null && i.expiresAt < System.currentTimeMillis()
                                RowValue(if (i.usedAt != null) "Joined" else if (expired) "Expired" else "Waiting", if (i.usedAt != null) m.roles.positive else m.roles.ink2)
                            }
                        }
                    }
                }
            }
        }
    }
}

private fun inviteStatus(i: InviteInfo): String {
    val d = SimpleDateFormat("d MMM", Locale.US)
    return when {
        i.usedAt != null -> "Joined ${d.format(Date(i.usedAt))}"
        else -> "${i.role.replaceFirstChar { it.uppercase() }} · expires ${d.format(Date(i.expiresAt))}"
    }
}

@Composable
private fun InviteCodeCard(inv: InviteCreated) {
    val m = muse
    val clip = LocalClipboardManager.current
    val context = LocalContext.current
    val repo = LocalContainer.current.repo
    val serverUrl = LocalContainer.current.prefs.collectAsState().value.serverUrl
    val message = inv.shareMessage(serverUrl)
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
        Caption("Invite code${inv.email?.let { " for $it" } ?: ""}")
        T(inv.code, m.scale.title.tabular(), m.roles.ink)
        Caption("Shown once. Share sends the download link with the code. Copy copies the code only.")
        Row(Modifier.padding(top = MuseSpace.s2), horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
            SecondaryButton("Copy code", { clip.setText(AnnotatedString(inv.code)); repo.toast("Invite code copied") }, Modifier.weight(1f))
            SecondaryButton("Share", {
                val send = Intent(Intent.ACTION_SEND).apply { type = "text/plain"; putExtra(Intent.EXTRA_TEXT, message); putExtra(Intent.EXTRA_SUBJECT, "Your MUSE invite") }
                runCatching { context.startActivity(Intent.createChooser(send, "Share invite").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            }, Modifier.weight(1f), icon = "export")
        }
    }
}

// ======================================================================= Studio settings + image engine

@Composable
fun StudioSettingsScreen() {
    val vm = ownerVm()
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    val m = muse
    LaunchedEffect(Unit) { vm.loadSettings() }
    ScreenBox(bg = muse.roles.canvas) {
        Column(Modifier.fillMaxSize()) {
            CalmTopBar("Studio settings", onBack = { nav.back() })
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = MuseSpace.gutter).padding(top = MuseSpace.s2, bottom = 60.dp), verticalArrangement = Arrangement.spacedBy(MuseSpace.s5)) {
                val st = s.settings
                if (st == null) repeat(3) { SkeletonLines(3) } else {
                    StudioForm(vm, st, s)
                    // Engines: the only place provider names, GPUs and start-up appear (owner only; plans/api.md "App clean-up" §5).
                    EnginesSection(vm, st, s)
                }
            }
        }
    }
}

@Composable
private fun StudioForm(vm: OwnerViewModel, st: StudioSettings, s: OwnerState) {
    var perJob by remember(st) { mutableStateOf(Pricing.toFixed(st.capPerJob, 2)) }
    var perDay by remember(st) { mutableStateOf(Pricing.toFixed(st.capPerDay, 2)) }
    var perUser by remember(st) { mutableStateOf(Pricing.toFixed(st.capPerUserDay, 2)) }
    val m = muse
    Labeled("Spending caps ($)") {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            CapInput("Per job", perJob, { perJob = it }, Modifier.weight(1f))
            CapInput("Studio / day", perDay, { perDay = it }, Modifier.weight(1f))
            CapInput("Member / day", perUser, { perUser = it }, Modifier.weight(1f))
        }
    }
    PrimaryButton(if (s.busy) "Saving…" else "Save caps", {
        vm.saveStudio(StudioSettingsPatch(capPerJob = perJob.toDoubleOrNull(), capPerDay = perDay.toDoubleOrNull(), capPerUserDay = perUser.toDoubleOrNull()))
    }, Modifier.fillMaxWidth(), busy = s.busy)
    s.note?.takeIf { it.first == "studio" }?.let { InlineNote(it.second, it.third) }
    if (!st.features.replaceAudio) Caption("Replace audio isn't available yet: turning Keep audio off gives a silent take.", color = m.roles.ink2)
}

/**
 * Owner Settings → Engines: each engine's status and whether its key is set, the add-on GPU limits, who pays start-up,
 * Keep add-on engine ready, and the image engine. The only screen that names providers.
 */
@Composable
private fun EnginesSection(vm: OwnerViewModel, st: StudioSettings, s: OwnerState) {
    val m = muse
    val c = LocalContainer.current
    val studio by c.repo.state.collectAsState()
    var gpus by remember(st) { mutableStateOf(st.maxGpus) }
    var payer by remember(st) { mutableStateOf(st.overheadPayer) }
    Column(Modifier.padding(top = MuseSpace.s4), verticalArrangement = Arrangement.spacedBy(MuseSpace.s1)) {
        Heading("Engines")
        Caption("Members only ever see results, time and price. Engines, keys and GPUs live here.")
    }
    val list = st.engines?.list.orEmpty()
    if (list.isEmpty()) Caption("This server doesn't report engine status.")
    else Column {
        list.forEach { e ->
            RowItem(e.name.ifBlank { e.id }, listOfNotNull(e.usedFor.ifBlank { null }, if (e.keySet) "key set" else "no key",
                e.balanceUsd?.let { "balance ${Pricing.money(it)}" }).joinToString(" · ") + (e.message?.let { ". $it" } ?: "")) {
                RowValue(engineStatusLabel(e.status), if (e.status == "ready") m.roles.positive else if (e.status == "simulated") m.roles.ink2 else m.roles.caution)
            }
        }
    }
    val navX = LocalNav.current
    Column {
        RowItem("Image models", "Any Replicate model for new shots, edits, Enhance and Dress up", onClick = { navX.go(Routes.IMAGE_MODELS) }) { Chevron() }
        RowItem("Archived models", "Hidden models you can restore any time", onClick = { navX.go(Routes.ARCHIVED) }) { Chevron() }
    }
    Heading("Add-on engine (Edit, Fast · beta, Upscale)")
    WarmSwitchRow(c, studio.warm)
    Caption("Turns off after ${st.engines?.keepReady?.idleMinutes ?: st.warmIdleMinutes} min without renders, and after ${(st.engines?.keepReady?.maxMinutes ?: st.warmMaxMinutes) / 60.0} h at most (Keep ready extends it once).".replace(".0 h", " h"))
    Labeled("Add-on GPUs at once · $gpus") {
        MuseSlider(gpus, 0, 8, { gpus = it })
        Caption(if (gpus == 0) "0 pauses Edit and Fast · beta." else "Each member's Edit renders run on their own H100 while it's free.")
    }
    Labeled("Who pays start-up") {
        Segmented(listOf("user" to "The member", "owner" to "The studio (me)"), payer, { payer = it })
        Caption("Starting an add-on GPU costs about ${Pricing.money(0.5 / 60 * 3.99)}. It's charged with the render, never shown to members as its own line.")
    }
    SecondaryButton(if (s.busy) "Saving…" else "Save engine settings", { vm.saveStudio(StudioSettingsPatch(maxGpus = gpus, overheadPayer = payer)) }, Modifier.fillMaxWidth())
    Column(Modifier.padding(top = MuseSpace.s4), verticalArrangement = Arrangement.spacedBy(MuseSpace.s1)) {
        Heading("Image engine")
        Caption("Makes character-sheet angles, outfit sets and photoshoots. Members pay exactly what each photo costs.")
    }
    val en = s.engine
    if (en != null) EngineForm(vm, en, s)
}

fun engineStatusLabel(status: String) = when (status) {
    "ready" -> "Ready"; "no_key" -> "No key"; "simulated" -> "Simulated"; "out_of_credit" -> "Out of credit"; "no_gpu" -> "No GPU free"; else -> status
}

@Composable
private fun CapInput(label: String, value: String, onChange: (String) -> Unit, modifier: Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Caption(label)
        Input(value, { onChange(it.filter { c -> c.isDigit() || c == '.' }) }, keyboard = KeyboardType.Decimal, calm = true)
    }
}

@Composable
private fun EngineForm(vm: OwnerViewModel, en: ImageEngine, s: OwnerState) {
    var provider by remember(en) { mutableStateOf(en.provider) }
    var model by remember(en) { mutableStateOf(en.model) }
    var url by remember(en) { mutableStateOf(en.url ?: "") }
    val providers = listOf("replicate", "simulated", "fal", "custom-http")
    Segmented(providers.map { it to (engineLabel(it) + if (en.available[it] == false) " ·  off" else "") }, provider, { p ->
        provider = p
        model = if (p == en.provider) en.model else when (p) { "fal" -> "fal-ai/bytedance/seedream/v4/edit"; "simulated" -> "bundled-stills"; else -> "" } // replicate: the server's default
    })
    if (en.available[provider] == false) Notice(if (provider == "fal") "fal isn't set up on the server. Add FAL_KEY to the server's variables first." else if (provider == "replicate") "Replicate isn't set up on the server (REPLICATE_API_TOKEN)." else "This engine isn't set up on the server.", tone = NoticeTone.CAUTION)
    when (provider) {
        "simulated" -> Caption("Free stand-in stills from the bundled references. Good for testing.")
        "replicate" -> Caption(if (en.provider == "replicate") "${en.label ?: "FLUX.2 [pro] · Replicate"}: new shots from the model's reference photos; outfit angles are edits of the front." else "FLUX.2 [pro] for new shots and Qwen edit for outfit angles, hosted on Replicate.")
        "fal" -> Labeled("fal model id") { Input(model, { model = it.trim() }, placeholder = "fal-ai/bytedance/seedream/v4/edit", calm = true) }
        else -> {
            Labeled("Engine URL (https)") { Input(url, { url = it.trim() }, keyboard = KeyboardType.Uri, placeholder = "https://images.example.com/v1/generate", calm = true) }
            Labeled("Model (optional)") { Input(model, { model = it.trim() }, placeholder = "my-model", calm = true) }
        }
    }
    SecondaryButton(if (s.busy) "Saving…" else "Use ${engineLabel(provider)}", {
        vm.saveEngine(ImageEnginePatch(provider, model.ifBlank { null }, url.ifBlank { null }.takeIf { provider == "custom-http" }))
    }, Modifier.fillMaxWidth())
    s.note?.takeIf { it.first == "engine" }?.let { InlineNote(it.second, it.third) }
}

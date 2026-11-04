package studio.muse.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.launch
import studio.muse.app.data.Balance
import studio.muse.app.data.StudioBalance
import studio.muse.app.data.Wallet
import studio.muse.app.data.Credit
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.components.*
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse
import studio.muse.core.Pricing
import studio.muse.core.RenderSpec

// ======================================================================= Credit (balance in dollars)

/**
 * GET /v1/wallet, shown in dollars only (the API's usd fields). A member sees their balance, holds and their own spend. The owner sees the
 * studio balance they load (top-ups − spending), what's free to send, and records top-ups here (plans/api.md "App clean-up" §4).
 */
@Composable
fun CreditsScreen() {
    val c = LocalContainer.current
    val vm: SettingsViewModel = viewModel { SettingsViewModel(c) }
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var studio by remember { mutableStateOf<StudioBalance?>(null) }
    var amount by remember { mutableStateOf("20") }
    var note by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var err by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) { c.repo.refreshWallet() }
    val w = s.wallet
    LaunchedEffect(w?.owner, w?.usd) { if (w?.owner == true) studio = c.repo.studioBalance().first }
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar("Credit", onBack = { nav.back() })
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 130.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                when {
                    w == null -> LegacyBalance(s.balance, s.videos)
                    w.owner -> {
                        OwnerTokens(w, s.balance, studio)
                        Field("Add a top-up") {
                            Tiny("Record money you loaded into the studio, e.g. after paying the engines. Every render and photo is spent from it.")
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Field("Amount ($)", Modifier.weight(1f)) { Input(amount, { amount = Credit.filterInput(it) }, keyboard = androidx.compose.ui.text.input.KeyboardType.Decimal, placeholder = "20") }
                                Field("Note (optional)", Modifier.weight(1.6f)) { Input(note, { note = it.take(200) }, placeholder = "Card, 4 Nov") }
                            }
                        }
                        err?.let { NoteBox(it, warn = true) }
                        studio?.topUps?.takeIf { it.isNotEmpty() }?.let { list ->
                            Lbl("Top-ups")
                            ListGroup {
                                list.take(8).forEach { t ->
                                    Li("wallet", "Added ${Pricing.money(t.amountUsd)}", sub = listOfNotNull(t.note, java.text.SimpleDateFormat("d MMM", java.util.Locale.US).format(java.util.Date(t.paidAt))).joinToString(" · "), onClick = {}) {}
                                }
                            }
                        }
                    }
                    else -> MemberTokens(w, s.balance)
                }
            }
        }
        if (w?.owner == true) Dock {
            val usd = Credit.parseUsd(amount) ?: 0.0
            Cta(if (busy) "Adding…" else "Add ${Pricing.money(usd)}", {
                if (!busy && usd > 0) scope.launch {
                    busy = true; err = null
                    val (r, e) = c.repo.addTopUp(usd, note)
                    busy = false
                    if (r != null) { studio = r; note = ""; c.repo.toast("Added ${Pricing.money(usd)} to the studio balance") } else err = e
                }
            }, Modifier.weight(1f), busy = busy, off = usd <= 0)
        }
    }
}

@Composable
private fun BigCard(label: String, value: String, sub: String, sub2: String? = null, sticker: String? = null) {
    val m = muse
    val shape = RoundedCornerShape(m.t.rLg)
    val (bg, fg) = when { m.isB -> m.t.surface2 to m.t.ink; m.isC -> m.t.cta to Color.White; m.isD -> m.t.blue to Color.White; else -> m.t.ink to m.t.bg }
    Box(Modifier.fillMaxWidth().let { if (m.isD) it.hardShadow(5.dp, m.t.rLg) else it }.clip(shape).background(bg).let { if (m.isD) it.border(2.5.dp, Ink, shape) else if (m.isB) it.border(1.dp, m.t.line, shape) else it }.padding(20.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Lbl(label, color = fg.copy(alpha = .8f))
            T(value, m.type.mono.copy(fontSize = 46.sp, fontWeight = FontWeight.SemiBold, lineHeight = 50.sp), if (m.isB) m.t.accent else fg)
            Tiny(sub, color = fg)
            sub2?.let { Tiny(it, color = fg.copy(alpha = .85f)) }
        }
        sticker?.let { Sticker(it, "yellow", -6f, Modifier.align(Alignment.TopEnd)) }
    }
}

@Composable
private fun MemberTokens(w: Wallet, b: Balance) {
    BigCard(
        "Balance", Pricing.money(w.usd), "≈ ${Pricing.draftVideosLeft(w.usd)} Draft videos",
        if (w.heldTokens > 0) "${Pricing.money(if (w.heldUsd > 0) w.heldUsd else Credit.usdOf(w.heldTokens, w.tokenUsd))} on hold for running renders" else null,
    )
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Kpi("Today", Pricing.money(w.todayUsd), Modifier.weight(1f))
        Kpi("This month", Pricing.money(w.monthUsd), Modifier.weight(1f))
        Kpi("Per video", "~${Pricing.money(Pricing.estCost(Pricing.typicalVideo))}", Modifier.weight(1f))
    }
    Field("Spend limits") {
        LimitRow("Per job", Pricing.money(b.perJobLimit))
        LimitRow("Per day (you)", Pricing.money(b.perUserDayLimit ?: b.perDayLimit))
    }
    NoteBox("Your credit comes from the studio owner. When you run low, ask them for more.", icon = "wallet")
    Tiny("Videos and photos hold about their price when they start, then cost exactly what they took. If something goes wrong, you aren't charged.")
}

@Composable
private fun OwnerTokens(w: Wallet, b: Balance, studio: StudioBalance?) {
    val nav = LocalNav.current
    if (studio?.needsFirstTopUp ?: (b.needsFirstTopUp == true)) NoteBox("Add your first top-up: record what you loaded into the studio, then send members credit from it.", icon = "wallet")
    OwnerBalanceCard(w, studio = studio)
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Kpi("Studio today", Pricing.money(b.today), Modifier.weight(1f))
        Kpi("This month", Pricing.money(b.month), Modifier.weight(1f))
        Kpi("Per video", "~${Pricing.money(Pricing.estCost(Pricing.typicalVideo))}", Modifier.weight(1f))
    }
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Cta2("Members", { nav.go(Routes.MEMBERS) }, Modifier.weight(1f), icon = "model")
        Cta("Send credit", { nav.go(Routes.MEMBERS) }, Modifier.weight(1f), icon = "wallet")
    }
    Field("Spend limits") {
        LimitRow("Per job", Pricing.money(b.perJobLimit))
        LimitRow("Studio per day", Pricing.money(b.perDayLimit))
        b.perUserDayLimit?.let { LimitRow("Each member per day", Pricing.money(it)) }
    }
}

@Composable
private fun LegacyBalance(b: Balance, videos: Int) {
    BigCard("Balance", Pricing.money(b.balance), "≈ ${Pricing.draftVideosLeft(b.balance)} Draft videos")
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Kpi("This month", Pricing.money(b.month), Modifier.weight(1f))
        Kpi("Per video", "~${Pricing.money(Pricing.estCost(Pricing.typicalVideo))}", Modifier.weight(1f))
        Kpi("Videos", "$videos", Modifier.weight(1f))
    }
    Field("Spend limits") {
        LimitRow("Per job", Pricing.money(b.perJobLimit))
        LimitRow("Per day", Pricing.money(b.perDayLimit))
    }
    Tiny("Videos are charged when they start and refunded in full if something goes wrong.")
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

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
import studio.muse.app.ui.theme.MuseSpace
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale
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
    /** The studio balance card, kept live by `studio` events (a top-up or a spend on another device). */
    val live by c.repo.state.collectAsState()
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
    ScreenBox(bg = muse.roles.canvas) {
        Column(Modifier.fillMaxSize()) {
            CalmTopBar("Credit", onBack = { nav.back() })
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = MuseSpace.gutter).padding(top = MuseSpace.s2, bottom = 120.dp),
                verticalArrangement = Arrangement.spacedBy(MuseSpace.s6),
            ) {
                when {
                    w == null -> LegacyBalance(s.balance, s.videos)
                    w.owner -> {
                        OwnerTokens(w, s.balance, live.studioBalance ?: studio)
                        Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
                            Heading("Add a top-up")
                            Caption("Record money you loaded into the studio, for example after paying the engines. Every render and photo is spent from it.")
                            Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
                                Labeled("Amount ($)", Modifier.weight(1f)) { Input(amount, { amount = Credit.filterInput(it) }, keyboard = androidx.compose.ui.text.input.KeyboardType.Decimal, placeholder = "20", calm = true) }
                                Labeled("Note (optional)", Modifier.weight(1.6f)) { Input(note, { note = it.take(200) }, placeholder = "Card, 4 Nov", calm = true) }
                            }
                            err?.let { Notice(it, tone = NoticeTone.DANGER) }
                        }
                        studio?.topUps?.takeIf { it.isNotEmpty() }?.let { list ->
                            Column {
                                Heading("Top-ups")
                                list.take(8).forEach { t ->
                                    RowItem("Added ${Pricing.money(t.amountUsd)}", listOfNotNull(t.note, java.text.SimpleDateFormat("d MMM", java.util.Locale.US).format(java.util.Date(t.paidAt))).joinToString(" · "))
                                }
                            }
                        }
                    }
                    else -> MemberTokens(w, s.balance)
                }
            }
        }
        if (w?.owner == true) ActionDock {
            val usd = Credit.parseUsd(amount) ?: 0.0
            PrimaryButton(if (busy) "Adding…" else "Add ${Pricing.money(usd)}", {
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

/** The balance: a label, the figure large and tabular, and the lines that explain it. No card. */
@Composable
private fun BigFigure(label: String, value: String, vararg lines: String?) {
    val m = muse
    Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s1)) {
        Caption(label)
        T(value, m.scale.display.copy(fontFamily = m.scale.textFamily, fontWeight = FontWeight.SemiBold).tabular(), m.roles.ink)
        lines.filterNotNull().forEach { Caption(it) }
    }
}

@Composable
private fun MemberTokens(w: Wallet, b: Balance) {
    BigFigure(
        "Balance", Pricing.money(w.usd), "About ${Pricing.draftVideosLeft(w.usd)} Draft videos",
        if (w.heldTokens > 0) "${Pricing.money(if (w.heldUsd > 0) w.heldUsd else Credit.usdOf(w.heldTokens, w.tokenUsd))} on hold for running renders" else null,
    )
    Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
        Kpi("Today", Pricing.money(w.todayUsd), Modifier.weight(1f))
        Kpi("This month", Pricing.money(w.monthUsd), Modifier.weight(1f))
        Kpi("Per video", "~${Pricing.money(Pricing.estCost(Pricing.typicalVideo))}", Modifier.weight(1f))
    }
    Column {
        Heading("Spend limits")
        LimitRow("Per job", Pricing.money(b.perJobLimit))
        LimitRow("Per day (you)", Pricing.money(b.perUserDayLimit ?: b.perDayLimit))
    }
    Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
        Body("Your credit comes from the studio owner. When you run low, ask them for more.", color = muse.roles.ink)
        Caption("Videos and photos hold about their price when they start, then cost exactly what they took. If something goes wrong, you aren't charged.")
    }
}

@Composable
private fun OwnerTokens(w: Wallet, b: Balance, studio: StudioBalance?) {
    val nav = LocalNav.current
    if (studio?.needsFirstTopUp ?: (b.needsFirstTopUp == true)) Notice("Add your first top-up: record what you loaded into the studio, then send members credit from it.", tone = NoticeTone.CAUTION)
    BigFigure(
        "Studio balance", signedMoney(studio?.balanceUsd ?: w.studioBalance ?: w.usd),
        "Free to spend or send ${signedMoney(w.availableToSend ?: 0.0)}",
        w.membersUnspentUsd?.let { "Members hold ${Pricing.money(it)} in unspent credit${if (w.heldUsd > 0) ", ${Pricing.money(w.heldUsd)} on hold" else ""}" },
        studio?.let { "Added ${Pricing.money(it.toppedUpUsd)}, spent ${Pricing.money(it.spentUsd)}" },
    )
    Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
        Kpi("Today", Pricing.money(b.today), Modifier.weight(1f))
        Kpi("This month", Pricing.money(b.month), Modifier.weight(1f))
        Kpi("Per video", "~${Pricing.money(Pricing.estCost(Pricing.typicalVideo))}", Modifier.weight(1f))
    }
    SecondaryButton("Send credit to members", { nav.go(Routes.MEMBERS) }, Modifier.fillMaxWidth())
    Column {
        Heading("Spend limits")
        LimitRow("Per job", Pricing.money(b.perJobLimit))
        LimitRow("Studio per day", Pricing.money(b.perDayLimit))
        b.perUserDayLimit?.let { LimitRow("Each member per day", Pricing.money(it)) }
    }
}

@Composable
private fun LegacyBalance(b: Balance, videos: Int) {
    BigFigure("Balance", Pricing.money(b.balance), "About ${Pricing.draftVideosLeft(b.balance)} Draft videos")
    Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
        Kpi("This month", Pricing.money(b.month), Modifier.weight(1f))
        Kpi("Per video", "~${Pricing.money(Pricing.estCost(Pricing.typicalVideo))}", Modifier.weight(1f))
        Kpi("Videos", "$videos", Modifier.weight(1f))
    }
    Column {
        Heading("Spend limits")
        LimitRow("Per job", Pricing.money(b.perJobLimit))
        LimitRow("Per day", Pricing.money(b.perDayLimit))
    }
    Caption("Videos are charged when they start and refunded in full if something goes wrong.")
}

@Composable
private fun LimitRow(label: String, value: String) = RowItem(label) { RowValue(value, muse.roles.ink) }

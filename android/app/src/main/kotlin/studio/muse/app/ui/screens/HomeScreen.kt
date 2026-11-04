package studio.muse.app.ui.screens

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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import studio.muse.app.AppContainer
import studio.muse.app.data.Balance
import studio.muse.app.data.Model
import studio.muse.app.data.Outfit
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.TabBar
import studio.muse.app.ui.components.*
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse
import studio.muse.core.Pricing
import java.util.Calendar

data class HomeState(
    val models: List<Model> = emptyList(),
    val featured: Model? = null,
    val featuredOutfits: List<Outfit> = emptyList(),
    val balance: Balance = Balance(0.0, 0.0),
    val firstName: String = "Jenne",
    val runningLeft: String? = null,
)

class HomeViewModel(private val c: AppContainer) : ViewModel() {
    val state: StateFlow<HomeState> = combine(c.repo.state, c.prefs) { s, p ->
        val featured = s.models.firstOrNull { it.locked } ?: s.models.firstOrNull()
        HomeState(
            s.models, featured, s.outfitsOf(featured?.id), s.balance,
            p.studioName.substringBefore(' ').ifBlank { "Jenne" },
            s.running?.let { studio.muse.core.formatClock(it.secondsLeft) },
        )
    }.stateIn(viewModelScope, SharingStarted.Eagerly, HomeState())

    fun open(m: Model, nav: studio.muse.app.ui.Nav) {
        c.drafts.modelId.value = m.id
        c.repo.state.value.outfitsOf(m.id).firstOrNull()?.let { c.drafts.outfitId.value = it.id }
        nav.go(if (m.locked) Routes.PROFILE else Routes.CREATE3)
    }

    fun bell() = c.repo.toast(state.value.runningLeft?.let { "Rendering · $it left" } ?: "No new notifications")
}

private fun greeting(): String = when (Calendar.getInstance().get(Calendar.HOUR_OF_DAY)) {
    in 5..11 -> "Good morning"
    in 12..17 -> "Good afternoon"
    else -> "Good evening"
}

@Composable
fun HomeScreen() {
    val c = LocalContainer.current
    val vm: HomeViewModel = viewModel { HomeViewModel(c) }
    val s by vm.state.collectAsState()
    val m = muse
    val nav = LocalNav.current
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            Row(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                Wordmark()
                Spacer(Modifier.weight(1f))
                TbBtn("bell", { vm.bell() })
                if (m.isC) TbBtn("user", { nav.tab(Routes.SETTINGS) })
            }
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 120.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                RowB {
                    Box(Modifier.weight(1f)) { when {
                        m.isA -> T("YOUR\nMODELS", m.type.h2.copy(fontSize = 56.sp, lineHeight = 50.sp), m.t.ink)
                        m.isB -> H2("Models")
                        m.isC -> H2("${greeting()}, ${s.firstName}")
                        else -> H2("Your crew")
                    } }
                    val wallet = LocalContainer.current.repo.state.collectAsState().value.wallet
                    BalancePill(tokensLabel(wallet, s.balance)) { nav.go(Routes.CREDITS) }
                }
                s.featured?.let { f -> FeatureCard(f, s.featuredOutfits) { vm.open(f, nav) } }
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    QuickAction("studio", "New video", Modifier.weight(1f)) { nav.go(Routes.SOURCE) }
                    QuickAction("camera", "Photoshoot", Modifier.weight(1f)) { nav.go(Routes.SHOOT) }
                    QuickAction("model", "New model", Modifier.weight(1f)) { nav.go(Routes.CREATE1) }
                }
                RowB { H3("All models"); Tiny("${s.models.size} models") }
                s.models.chunked(2).forEach { row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        row.forEach { model -> ModelCard(model, c.repo.state.value.outfitsOf(model.id).lastOrNull()?.front, Modifier.weight(1f)) { vm.open(model, nav) } }
                        if (row.size == 1) Spacer(Modifier.weight(1f))
                    }
                }
            }
        }
        TabBar(Routes.HOME)
    }
}

@Composable
fun BalancePill(balance: Double, onClick: () -> Unit) = BalancePill(Pricing.money(balance), onClick)

@Composable
fun BalancePill(text: String, onClick: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(999.dp)
    Box(Modifier.clip(shape).border(if (m.isD) 2.5.dp else m.t.stroke, m.t.line, shape).press(onClick = onClick).padding(horizontal = 10.dp, vertical = 4.dp)) {
        T(text, m.type.mono.copy(fontSize = 13.sp), m.t.ink)
    }
}

@Composable
private fun FeatureCard(model: Model, outfits: List<Outfit>, onClick: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(m.t.rLg)
    Box(
        Modifier.fillMaxWidth().height(300.dp).let { if (m.isD) it.hardShadow(5.dp, m.t.rLg) else it }.clip(shape)
            .background(if (m.isD) m.t.blue else m.t.surface2).let { if (m.isD) it.border(2.5.dp, Ink, shape) else it }.press(onClick = onClick),
    ) {
        RefImage(outfits.firstOrNull()?.front ?: model.cover, Modifier.fillMaxSize(), 18)
        Viewfinder()
        Column(
            Modifier.align(Alignment.BottomStart).fillMaxWidth().background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = .7f)))).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Lbl("Featured", color = Color.White.copy(alpha = .8f))
            T(model.name, m.type.featName, Color.White, upper = m.isA || m.isB)
            Tiny("${if (model.locked) "Identity locked" else "Draft"} · ${outfits.size} outfits", color = Color.White)
        }
        Sticker("ready to shoot", "mint", -5f, Modifier.align(Alignment.TopEnd).padding(14.dp))
    }
}

@Composable
private fun QuickAction(icon: String, label: String, modifier: Modifier, onClick: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(m.t.r)
    var mod = modifier.height(84.dp)
    mod = when {
        m.isD -> mod.hardShadow(3.dp, m.t.r).clip(shape).background(m.t.surface).border(2.5.dp, Ink, shape)
        m.isC -> mod.softShadow(m.t.r).clip(shape).background(m.t.surface)
        m.isA -> mod.clip(shape).border(1.dp, m.t.line, shape)
        else -> mod.clip(shape).background(m.t.surface).border(m.t.stroke, m.t.line, shape)
    }
    Column(mod.press(onClick = onClick).padding(12.dp), verticalArrangement = Arrangement.SpaceBetween) {
        Ic(icon, 22.dp)
        T(label, m.type.body.copy(fontSize = 13.sp, fontWeight = FontWeight.SemiBold), m.t.ink, maxLines = 1)
    }
}

@Composable
private fun ModelCard(model: Model, img: studio.muse.app.data.ImageRef?, modifier: Modifier, onClick: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(m.t.r)
    var mod = modifier
    mod = when {
        m.isD -> mod.hardShadow(3.dp, m.t.r).clip(shape).background(m.t.surface).border(2.5.dp, Ink, shape)
        m.isC -> mod.softShadow(m.t.r).clip(shape).background(m.t.surface)
        m.isA -> mod.clip(shape).border(1.dp, m.t.line, shape)
        else -> mod.clip(shape).background(m.t.surface).border(m.t.stroke, m.t.line, shape)
    }
    Column(mod.press(onClick = onClick)) {
        Box(Modifier.fillMaxWidth().height(150.dp)) {
            if (model.locked && img != null) { RefImage(img, Modifier.fillMaxSize(), 15); Viewfinder() }
            else if (model.cover != null) RefImage(model.cover, Modifier.fillMaxSize(), 15)
            else ModelInitial(model, Modifier.fillMaxSize())
        }
        Column(Modifier.padding(horizontal = 12.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            T(model.name, m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink, maxLines = 1)
            Tiny("${model.niche} · ${model.age}")
            if (model.locked) Pill("Locked", "good") else Pill("Draft · ${model.filled}/6 shots", "warn")
        }
    }
}

package studio.muse.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.width
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
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.heightIn
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
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
import studio.muse.app.data.Take
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.TabBar
import studio.muse.app.ui.components.*
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.MuseSpace
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.radii
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale
import studio.muse.core.Pricing
import java.util.Calendar
import kotlinx.coroutines.launch

data class HomeState(
    val models: List<Model> = emptyList(),
    val featured: Model? = null,
    val featuredOutfits: List<Outfit> = emptyList(),
    val balance: Balance = Balance(0.0, 0.0),
    val firstName: String = "",
    val runningLeft: String? = null,
    /** The first load has answered (models may still be empty: a new studio). */
    val loaded: Boolean = false,
    /** The last load failed (server unreachable): shown when there's nothing to show yet. */
    val error: String? = null,
    val wallet: studio.muse.app.data.Wallet? = null,
    /** Each model's latest outfit front (the card image of a locked model), by model id. */
    val outfitFronts: Map<String, studio.muse.app.data.ImageRef?> = emptyMap(),
    /** The newest takes (at most [RECENT_TAKES]), from the same studio state the Library lists: no request of its own. */
    val recent: List<Take> = emptyList(),
)

/** How many takes Home's "Recent takes" row shows. */
const val RECENT_TAKES = 8

class HomeViewModel(private val c: AppContainer) : ViewModel() {
    val state: StateFlow<HomeState> = combine(c.repo.state, c.prefs) { s, p ->
        val featured = s.models.firstOrNull { it.locked } ?: s.models.firstOrNull()
        HomeState(
            s.models, featured, s.outfitsOf(featured?.id), s.balance,
            p.studioName.substringBefore(' '),
            s.running?.let { studio.muse.core.formatClock(it.secondsLeft) },
            s.loaded, s.error, s.wallet,
            s.models.associate { m -> m.id to s.outfitsOf(m.id).lastOrNull()?.front },
            s.takes.take(RECENT_TAKES),
        )
    }.stateIn(viewModelScope, SharingStarted.Eagerly, HomeState())

    fun open(m: Model, nav: studio.muse.app.ui.Nav) {
        c.drafts.modelId.value = m.id
        c.repo.state.value.outfitsOf(m.id).firstOrNull()?.let { c.drafts.outfitId.value = it.id }
        nav.go(if (m.locked) Routes.PROFILE else Routes.CREATE3)
    }

    fun retry() = viewModelScope.launch { c.repo.refresh() }

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
    ScreenBox(bg = m.roles.canvas) {
        Column(Modifier.fillMaxSize()) {
            Row(Modifier.fillMaxWidth().height(56.dp).padding(start = MuseSpace.gutter, end = MuseSpace.s1), verticalAlignment = Alignment.CenterVertically) {
                T("MUSE", m.scale.title.copy(fontFamily = m.scale.displayFamily), m.roles.ink)
                Spacer(Modifier.weight(1f))
                // Performance: from HomeState (equal states are skipped), not the whole studio state, which changes on every live event.
                BalancePill(creditLabel(s.wallet, s.balance)) { nav.go(Routes.CREDITS) }
                BarButton("bell", "Notifications", { vm.bell() })
            }
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = MuseSpace.gutter).padding(top = MuseSpace.s2, bottom = 120.dp),
                verticalArrangement = Arrangement.spacedBy(MuseSpace.s5),
            ) {
                DisplayTitle("Models")
                when {
                    s.models.isEmpty() && !s.loaded -> HomeSkeleton()
                    s.models.isEmpty() && s.error != null -> ErrorState("Can't load your models", s.error ?: "", onAction = { vm.retry() })
                    s.models.isEmpty() -> EmptyState(
                        "No models yet", "Create her once: a name and a few photos for the character sheet. Then she's ready for photos and videos.",
                        "New model", { nav.go(Routes.CREATE1) },
                    )
                    else -> {
                        s.featured?.let { f ->
                            Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s4)) {
                                Featured(f, s.featuredOutfits) { vm.open(f, nav) }
                                PrimaryButton("New shot", { studio.muse.app.ui.screens.suite.composer.openShot(c, nav, f.id) }, Modifier.fillMaxWidth(), icon = "studio")
                            }
                        }
                        if (s.recent.isNotEmpty()) RecentTakes(s.recent, onLibrary = { nav.tab(Routes.GALLERY) }) { t -> nav.go(Routes.result(t.jobId ?: t.id)) }
                        Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
                            Heading("All models") { BarButton("plus", "New model", { nav.go(Routes.CREATE1) }) }
                            s.models.chunked(2).forEach { row ->
                                Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
                                    row.forEach { model -> key(model.id) { ModelTile(model, s.outfitFronts[model.id], Modifier.weight(1f)) { vm.open(model, nav) } } }
                                    if (row.size == 1) Spacer(Modifier.weight(1f))
                                }
                            }
                        }
                    }
                }
            }
        }
        TabBar(Routes.HOME)
    }
}

@Composable
fun BalancePill(balance: Double, onClick: () -> Unit) = BalancePill(Pricing.money(balance), onClick)

/** The balance at the top of Home: a quiet tabular figure that opens Credit. */
@Composable
fun BalancePill(text: String, onClick: () -> Unit) {
    val m = muse
    Box(
        Modifier.heightIn(min = 48.dp).press(onClick = onClick)
            .semantics { contentDescription = "Credit $text"; role = androidx.compose.ui.semantics.Role.Button }.padding(horizontal = MuseSpace.s2),
        contentAlignment = Alignment.Center,
    ) { T(text, m.scale.label.tabular(), m.roles.ink2, maxLines = 1) }
}

/** "1 model", "3 models". */
fun plural(n: Int, word: String) = "$n $word${if (n == 1) "" else "s"}"

/** The first load: the featured picture, its name and the grid, as blocks. */
@Composable
private fun HomeSkeleton() {
    Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s4), modifier = Modifier.semantics { contentDescription = "Loading your models" }) {
        Skeleton(Modifier.fillMaxWidth().height(360.dp), containerShape())
        SkeletonLines(2)
        Skeleton(Modifier.fillMaxWidth().height(52.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
            repeat(2) { Skeleton(Modifier.weight(1f).aspectRatio(3f / 4f), containerShape()) }
        }
    }
}

/** The featured model: her picture, then her name and one meta line. No overlay on the photo. */
@Composable
private fun Featured(model: Model, outfits: List<Outfit>, onClick: () -> Unit) {
    val m = muse
    Column(Modifier.press(onClick = onClick), verticalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
        Box(Modifier.fillMaxWidth().height(360.dp).clip(containerShape()).background(m.roles.field)) {
            RefImage(outfits.firstOrNull()?.front ?: model.cover, Modifier.fillMaxSize(), 18)
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                T(model.name, m.scale.title, m.roles.ink, maxLines = 1)
                Caption("${plural(outfits.size, "outfit")} · ${if (model.locked) "identity locked" else "draft"}")
            }
            Chevron()
        }
    }
}

/** A model in the grid: picture plus caption, no box. */
@Composable
private fun ModelTile(model: Model, img: studio.muse.app.data.ImageRef?, modifier: Modifier, onClick: () -> Unit) {
    val m = muse
    Column(modifier.press(onClick = onClick), verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
        Box(Modifier.fillMaxWidth().aspectRatio(3f / 4f).clip(containerShape()).background(m.roles.field), contentAlignment = Alignment.Center) {
            when {
                model.locked && img != null -> RefImage(img, Modifier.fillMaxSize(), 15)
                model.cover != null -> RefImage(model.cover, Modifier.fillMaxSize(), 15)
                else -> T(model.initial, m.scale.display, m.roles.ink2)
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(model.name, m.scale.label.copy(fontWeight = FontWeight.SemiBold), m.roles.ink, maxLines = 1)
            Caption(if (model.locked) "${model.niche} · ${model.age}" else "Draft · ${model.filled} of 7 shots", maxLines = 1)
        }
    }
}

/**
 * "Recent takes": the newest takes as pictures with one caption on a scrim (duration or Photo), as in the Library. "Library"
 * on the right opens the whole Library; a tile opens its take. Lazy and keyed, so only the tiles on screen load thumbnails.
 */
@Composable
private fun RecentTakes(takes: List<Take>, onLibrary: () -> Unit, onOpen: (Take) -> Unit) {
    val m = muse
    Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
        Heading("Recent takes") { TextAction("Library", onLibrary, color = m.roles.ink2) }
        LazyRow(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
            items(takes, key = { it.id }, contentType = { "take" }) { t ->
                Box(
                    Modifier.size(width = 104.dp, height = 140.dp).clip(containerShape()).background(m.roles.field).press { onOpen(t) }
                        .semantics(mergeDescendants = true) { contentDescription = "${t.shownTitle} · ${t.shownLabel}"; role = androidx.compose.ui.semantics.Role.Button },
                ) {
                    RefImage(t.thumb, Modifier.fillMaxSize(), 12)
                    Box(Modifier.align(Alignment.BottomStart).padding(MuseSpace.s1).clip(RoundedCornerShape(m.radii.chip)).background(Color.Black.copy(alpha = .55f))
                        .padding(horizontal = 6.dp, vertical = 2.dp)) {
                        T(t.shownLabel, m.scale.micro.tabular(), Color.White, maxLines = 1)
                    }
                }
            }
        }
    }
}

package studio.muse.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import studio.muse.app.AppContainer
import studio.muse.app.data.Model
import kotlinx.coroutines.launch
import studio.muse.app.data.Outfit
import studio.muse.app.data.SampleData
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.components.*
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.MuseSpace
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics

data class ProfileState(
    val model: Model? = null, val outfits: List<Outfit> = emptyList(), val selected: Int = 0,
    val lora: studio.muse.app.data.Lora = studio.muse.app.data.Lora(""), val connected: Int = 0,
    /** Her world (plans/model-world.md): her places, newest first. */
    val places: List<studio.muse.app.data.SuiteLocation> = emptyList(),
)

/** Her page's tabs (mockup 7). People and Pets come in later phases; their tabs say what they'll hold. */
enum class ProfileTab(val title: String) { PROFILE("Profile"), WARDROBE("Wardrobe"), PLACES("Places"), PEOPLE("People"), PETS("Pets") }

class ProfileViewModel(private val c: AppContainer) : ViewModel() {
    val state: StateFlow<ProfileState> = combine(c.repo.state, c.drafts.modelId, c.drafts.outfitId, c.suite.locations) { s, mid, oid, locs ->
        val model = s.model(mid) ?: s.models.firstOrNull()
        val outfits = s.outfitsOf(model?.id)
        ProfileState(model, outfits, outfits.indexOfFirst { it.id == oid }.coerceAtLeast(0), s.lora(model?.id), s.accountsOf(model?.id).size, placesOf(locs, model))
    }.stateIn(viewModelScope, SharingStarted.Eagerly, ProfileState())

    init { viewModelScope.launch { c.suite.loadLocations() } }

    /** "Add a place" (or a quick start): hers alone; opens it. */
    fun addPlace(name: String, open: (String) -> Unit) = viewModelScope.launch {
        val id = state.value.model?.id ?: return@launch
        newPlace(c, id, name)?.let { open(it.id) }
    }

    /** Owner: archive her (hidden everywhere, nothing deleted; restore in Settings → Engines → Archived models). */
    fun archive(md: Model, done: () -> Unit) = viewModelScope.launch {
        if (c.repo.archiveModel(md.id, true) != null) { c.repo.toast("${md.name} archived · restore her in Settings"); done() }
    }

    fun select(i: Int) {
        val o = state.value.outfits
        if (o.isEmpty()) return
        c.drafts.outfitId.value = o[((i % o.size) + o.size) % o.size].id
    }
}

/** Callbacks for [ProfileContent], so the same layout renders live in Settings theme previews. */
data class ProfileActions(
    val select: (Int) -> Unit = {}, val addOutfit: () -> Unit = {}, val allOutfits: () -> Unit = {}, val video: () -> Unit = {}, val shoot: () -> Unit = {},
    val back: () -> Unit = {}, val settings: () -> Unit = {}, val sheet: () -> Unit = {}, val menu: Boolean = true,
    val lora: () -> Unit = {}, val accounts: () -> Unit = {},
    val enhance: () -> Unit = {}, val archive: (() -> Unit)? = null,
    /** Her world: open a place, or add one by name. */
    val openPlace: (String) -> Unit = {}, val addPlace: (String) -> Unit = {},
)

@Composable
fun ProfileScreen() {
    val c = LocalContainer.current
    val vm: ProfileViewModel = viewModel { ProfileViewModel(c) }
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    ProfileContent(
        s,
        ProfileActions(
            select = vm::select, addOutfit = { nav.go(Routes.OUTFIT) }, allOutfits = { nav.go(Routes.OUTFITS) }, video = { studio.muse.app.ui.screens.suite.composer.openShot(c, nav, s.model?.id) }, shoot = { studio.muse.app.ui.screens.suite.composer.openPhoto(c, nav, s.model?.id, s.outfits.getOrNull(s.selected)?.id) },
            back = { nav.back() }, settings = { nav.tab(Routes.SETTINGS) }, sheet = { nav.go(Routes.CREATE3) },
            lora = { nav.go(Routes.LORA) }, accounts = { nav.go(Routes.ACCOUNTS) },
            enhance = { nav.go(Routes.ENHANCE) },
            archive = if (c.repo.demo || c.prefs.value.owner) ({ s.model?.let { md -> vm.archive(md) { nav.reset(Routes.HOME) } } }) else null,
            openPlace = { nav.go(placeRoute(it)) }, addPlace = { n -> vm.addPlace(n) { nav.go(placeRoute(it)) } },
        ),
    )
}

/** Sample state for the Settings previews. */
fun sampleProfileState() = ProfileState(SampleData.models().first(), SampleData.outfits(), 0)

@Composable
fun ProfileContent(s: ProfileState, a: ProfileActions, initialTab: ProfileTab = ProfileTab.PROFILE) {
    val m = muse
    val model = s.model ?: return ScreenBox(bg = m.roles.canvas) {
        Column(Modifier.fillMaxSize()) {
            CalmTopBar("Model", onBack = a.back)
            ErrorState("This model isn't here any more", "She may have been archived. The owner can restore her in Settings, Archived models.", "Back", a.back,
                Modifier.padding(horizontal = MuseSpace.gutter))
        }
    }
    val menu = if (a.menu) profileMenu(a.sheet, a.addOutfit, a.lora, a.accounts, a.enhance, a.archive) else emptyList()
    var tab by androidx.compose.runtime.saveable.rememberSaveable(model.id) { androidx.compose.runtime.mutableStateOf(initialTab) }
    var naming by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(false) }
    ScreenBox(bg = m.roles.canvas) {
        Column(Modifier.fillMaxSize().padding(bottom = 88.dp)) {
            CalmTopBar(model.name, onBack = a.back, right = if (a.menu) ({ MoreMenu(menu, tint = m.roles.ink) }) else null)
            ProfileTabs(tab, s) { tab = it }
            when (tab) {
                ProfileTab.PROFILE -> {
                    Box(Modifier.weight(1f).fillMaxWidth().padding(start = MuseSpace.gutter, end = MuseSpace.gutter, top = MuseSpace.s4).clip(containerShape()).background(m.roles.field)) {
                        RefImage(model.cover, Modifier.fillMaxSize(), 18)
                    }
                    Column(Modifier.padding(start = MuseSpace.gutter, end = MuseSpace.gutter, top = MuseSpace.s4), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        DisplayTitle(model.name)
                        Caption("${if (model.locked) "Identity locked" else "Draft"} · ${model.filled} of 7 shots")
                    }
                    ProfileExtras(s.lora, s.connected, a.lora, a.accounts, Modifier.padding(horizontal = MuseSpace.gutter))
                }
                ProfileTab.WARDROBE -> Column(Modifier.weight(1f)) {
                    Heading("Outfits", Modifier.padding(start = MuseSpace.gutter, end = MuseSpace.gutter, top = MuseSpace.s4)) {
                        // §4: every outfit as a folder (name, date, rename, delete), 8 per page.
                        if (s.outfits.isNotEmpty()) TextAction("See all", a.allOutfits)
                    }
                    OutfitStrip(s, a)
                }
                ProfileTab.PLACES -> PlacesTab(s.places, a.openPlace, { naming = true }, a.addPlace, Modifier.weight(1f))
                ProfileTab.PEOPLE -> WorldEmpty("users", "No people yet", "Her sister, a brother, a best friend. Each gets a few photos and their own outfits, and you can @tag them.")
                ProfileTab.PETS -> WorldEmpty("paw-print", "No pets yet", "Her dog or cat: a few photos and a name to @tag in a prompt.")
            }
        }
        ActionDock {
            if (tab == ProfileTab.PLACES && s.places.isNotEmpty()) PrimaryButton("Add a place", { naming = true }, Modifier.weight(1f), icon = "plus")
            else {
                PrimaryButton("Shot", a.video, Modifier.weight(1f))
                SecondaryButton("Photo", a.shoot, icon = "camera")
            }
        }
        if (naming) PlaceTextDialog("Add a place", "", "Café by the gym", "Add place") { n -> naming = false; if (!n.isNullOrBlank()) a.addPlace(n) }
    }
}

/** The tab row (mockup 7): the selected tab in ink with the accent underline; counts where there are some. */
@Composable
private fun ProfileTabs(tab: ProfileTab, s: ProfileState, pick: (ProfileTab) -> Unit) {
    val m = muse
    Column {
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = MuseSpace.gutter), horizontalArrangement = Arrangement.spacedBy(MuseSpace.s5)) {
            ProfileTab.entries.forEach { k ->
                val on = k == tab
                val n = when (k) { ProfileTab.WARDROBE -> s.outfits.size; ProfileTab.PLACES -> s.places.size; else -> 0 }
                Column(Modifier.width(androidx.compose.foundation.layout.IntrinsicSize.Max).heightIn(min = 48.dp).press { pick(k) }.semantics(mergeDescendants = true) { contentDescription = if (n > 0) "${k.title}, $n" else k.title },
                    horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Bottom) {
                    Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s1), verticalAlignment = Alignment.CenterVertically) {
                        T(k.title, m.scale.label, if (on) m.roles.ink else m.roles.ink2, maxLines = 1)
                        if (n > 0) T("$n", m.scale.caption, m.roles.ink2, maxLines = 1)
                    }
                    Spacer(Modifier.height(MuseSpace.s2))
                    Box(Modifier.fillMaxWidth().height(2.dp).background(if (on) m.roles.accent else Color.Transparent))
                }
            }
        }
        Box(Modifier.fillMaxWidth().height(1.dp).background(m.roles.hairline))
    }
}

/** Her outfits: pictures only; the chosen one carries the selection outline. The last tile adds one. */
@Composable
private fun OutfitStrip(s: ProfileState, a: ProfileActions) {
    val m = muse
    val shape = androidx.compose.foundation.shape.RoundedCornerShape(studio.muse.app.ui.theme.MuseRadii.of(m.id).control)
    LazyRow(contentPadding = PaddingValues(horizontal = MuseSpace.gutter), horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
        itemsIndexed(s.outfits, key = { _, o -> o.id }) { i, o ->
            Box(
                Modifier.size(64.dp, 84.dp).clip(shape).background(m.roles.field).let { if (i == s.selected) it.border(2.dp, m.roles.selection, shape) else it }
                    .press { a.select(i) }.semantics { contentDescription = o.name },
            ) { RefImage(o.front, Modifier.fillMaxSize()) }
        }
        item(key = "add") {
            Box(Modifier.size(64.dp, 84.dp).clip(shape).background(m.roles.field).press(onClick = a.addOutfit).semantics { contentDescription = "Add outfit" },
                contentAlignment = Alignment.Center) { Ic("plus", 20.dp, m.roles.ink2) }
        }
    }
}

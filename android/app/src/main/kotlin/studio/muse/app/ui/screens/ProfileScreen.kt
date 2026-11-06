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
)

class ProfileViewModel(private val c: AppContainer) : ViewModel() {
    val state: StateFlow<ProfileState> = combine(c.repo.state, c.drafts.modelId, c.drafts.outfitId) { s, mid, oid ->
        val model = s.model(mid) ?: s.models.firstOrNull()
        val outfits = s.outfitsOf(model?.id)
        ProfileState(model, outfits, outfits.indexOfFirst { it.id == oid }.coerceAtLeast(0), s.lora(model?.id), s.accountsOf(model?.id).size)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, ProfileState())

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
    val select: (Int) -> Unit = {}, val addOutfit: () -> Unit = {}, val video: () -> Unit = {}, val shoot: () -> Unit = {},
    val back: () -> Unit = {}, val settings: () -> Unit = {}, val sheet: () -> Unit = {}, val menu: Boolean = true,
    val lora: () -> Unit = {}, val accounts: () -> Unit = {},
    val enhance: () -> Unit = {}, val dressUp: () -> Unit = {}, val archive: (() -> Unit)? = null,
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
            select = vm::select, addOutfit = { nav.go(Routes.OUTFIT) }, video = { nav.go(Routes.SOURCE) }, shoot = { nav.go(Routes.SHOOT) },
            back = { nav.back() }, settings = { nav.tab(Routes.SETTINGS) }, sheet = { nav.go(Routes.CREATE3) },
            lora = { nav.go(Routes.LORA) }, accounts = { nav.go(Routes.ACCOUNTS) },
            enhance = { nav.go(Routes.ENHANCE) }, dressUp = { nav.go(Routes.DRESSUP) },
            archive = if (c.repo.demo || c.prefs.value.owner) ({ s.model?.let { md -> vm.archive(md) { nav.reset(Routes.HOME) } } }) else null,
        ),
    )
}

/** Sample state for the Settings previews. */
fun sampleProfileState() = ProfileState(SampleData.models().first(), SampleData.outfits(), 0)

@Composable
fun ProfileContent(s: ProfileState, a: ProfileActions) {
    val m = muse
    val model = s.model ?: return ScreenBox(bg = m.roles.canvas) {
        Column(Modifier.fillMaxSize()) {
            CalmTopBar("Model", onBack = a.back)
            ErrorState("This model isn't here any more", "She may have been archived. The owner can restore her in Settings, Archived models.", "Back", a.back,
                Modifier.padding(horizontal = MuseSpace.gutter))
        }
    }
    val menu = if (a.menu) profileMenu(a.sheet, a.addOutfit, a.lora, a.accounts, a.enhance, a.dressUp, a.archive) else emptyList()
    ScreenBox(bg = m.roles.canvas) {
        Column(Modifier.fillMaxSize().padding(bottom = 88.dp)) {
            CalmTopBar(onBack = a.back, right = if (a.menu) ({ MoreMenu(menu, tint = m.roles.ink) }) else null)
            Box(Modifier.weight(1f).fillMaxWidth().padding(horizontal = MuseSpace.gutter).clip(containerShape()).background(m.roles.field)) {
                RefImage(model.cover, Modifier.fillMaxSize(), 18)
            }
            Column(Modifier.padding(start = MuseSpace.gutter, end = MuseSpace.gutter, top = MuseSpace.s4), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                DisplayTitle(model.name)
                Caption("${if (model.locked) "Identity locked" else "Draft"} · ${model.filled} of 7 shots")
            }
            Heading("Outfits", Modifier.padding(start = MuseSpace.gutter, end = MuseSpace.gutter, top = MuseSpace.s4)) {
                s.outfits.getOrNull(s.selected)?.let { Caption(it.name, maxLines = 1) }
            }
            OutfitStrip(s, a)
            ProfileExtras(s.lora, s.connected, a.lora, a.accounts, Modifier.padding(horizontal = MuseSpace.gutter))
        }
        ActionDock {
            PrimaryButton("Make a video", a.video, Modifier.weight(1f))
            SecondaryButton("Shoot", a.shoot, icon = "camera")
        }
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

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
            select = vm::select, addOutfit = { nav.go(Routes.OUTFIT) }, video = { nav.go(Routes.SOURCE) }, shoot = { studio.muse.app.ui.screens.suite.composer.openPhoto(c, nav, s.model?.id, s.outfits.getOrNull(s.selected)?.id) },
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
    val model = s.model ?: return ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar("Model", onBack = a.back)
            Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                NoteBox("This model isn't here any more. It may have been archived.", icon = "model")
                Cta2("Back", a.back, Modifier.fillMaxWidth())
            }
        }
    }
    val menu = if (a.menu) profileMenu(a.sheet, a.addOutfit, a.lora, a.accounts, a.enhance, a.dressUp, a.archive) else emptyList()
    when {
        m.isA -> ProfileA(model, s, a, menu)
        m.isB -> ProfileB(model, s, a, menu)
        m.isC -> ProfileC(model, s, a, menu)
        else -> ProfileD(model, s, a, menu)
    }
}

@Composable
private fun BoxScope.ProfileDock(a: ProfileActions) {
    Dock {
        Cta("Make a video", a.video, Modifier.weight(1f))
        Cta2("Photo", a.shoot, icon = "camera")
    }
}

private fun Model.twoLines() = name.split(" ").let { if (it.size > 1) it[0] + "\n" + it.drop(1).joinToString(" ") else name }

// ---------------- A · Editorial: strip, tall photo with giant serif name, outfit carousel with arrows
@Composable
private fun ProfileA(model: Model, s: ProfileState, a: ProfileActions, menu: List<MenuItem>) {
    val m = muse
    ScreenBox {
        Column(Modifier.fillMaxSize().padding(bottom = 96.dp)) {
            Row(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                TbBtn("back", a.back); Wordmark(); Spacer(Modifier.weight(1f)); if (a.menu) MoreMenu(menu)
            }
            Row(
                Modifier.fillMaxWidth().drawBehind {
                    drawLine(m.t.ink, Offset(0f, 0f), Offset(size.width, 0f), 1.dp.toPx())
                    drawLine(m.t.line, Offset(0f, size.height), Offset(size.width, size.height), 1.dp.toPx())
                }.padding(horizontal = 18.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically,
            ) {
                val st = m.type.mono.copy(fontSize = 11.5.sp, letterSpacing = .12.em)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Ic("lock", 12.dp); T("Identity locked · ${model.filled}/7", st, m.t.ink, upper = true)
                }
                T("Model profile", st, m.t.ink, upper = true)
            }
            Box(Modifier.weight(1f).fillMaxWidth().padding(horizontal = 18.dp).padding(top = 0.dp).press(onClick = a.video)) {
                RefImage(model.cover, Modifier.fillMaxSize(), 20)
                Column(Modifier.align(Alignment.BottomStart).padding(start = 14.dp, bottom = 14.dp)) {
                    T(model.twoLines(), m.type.h2.copy(fontSize = 108.sp, lineHeight = 88.sp), Color(0xFFF8F5EF), upper = true)
                    Spacer(Modifier.height(12.dp))
                    T("THE FACE OF YOUR VISION", m.type.mono.copy(fontSize = 11.5.sp, letterSpacing = .14.em), Color(0xFFF8F5EF))
                }
            }
            Row(Modifier.padding(start = 6.dp, end = 6.dp, top = 14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TbBtn("back", { a.select(s.selected - 1) })
                s.outfits.forEachIndexed { i, o ->
                    Box(Modifier.size(60.dp, 78.dp).let { if (i == s.selected) it.border(1.5.dp, m.t.accent).padding(3.dp) else it.padding(3.dp) }.press { a.select(i) }) {
                        RefImage(o.front, Modifier.fillMaxSize())
                    }
                }
                Box(Modifier.size(60.dp, 78.dp).padding(3.dp).dashed(m.t.line, 0.dp).press(onClick = a.addOutfit), contentAlignment = Alignment.Center) { T("+", m.type.body.copy(fontSize = 24.sp), m.t.ink) }
                TbBtn("chev", { a.select(s.selected + 1) })
            }
            Box(
                Modifier.fillMaxWidth().padding(start = 18.dp, end = 18.dp, top = 10.dp).drawBehind {
                    drawLine(m.t.line, Offset(0f, size.height), Offset(size.width, size.height), 1.dp.toPx())
                    drawLine(m.t.ink, Offset(0f, size.height), Offset(size.width * .24f, size.height), 2.dp.toPx())
                }.padding(bottom = 8.dp),
            ) {
                val o = s.outfits.getOrNull(s.selected)
                T("Outfits ${s.selected + 1} / ${s.outfits.size}${o?.let { " · " + it.name } ?: ""}", m.type.mono.copy(fontSize = 11.5.sp, letterSpacing = .12.em), m.t.ink, upper = true)
            }
            ProfileExtras(s.lora, s.connected, a.lora, a.accounts)
        }
        ProfileDock(a)
    }
}

// ---------------- B · Camera Body: viewfinder card with readouts, mono name row, outfit strip
@Composable
private fun ProfileB(model: Model, s: ProfileState, a: ProfileActions, menu: List<MenuItem>) {
    val m = muse
    ScreenBox {
        Column(Modifier.fillMaxSize().padding(bottom = 96.dp)) {
            Row(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                TbBtn("back", a.back); Box(Modifier.weight(1f), contentAlignment = Alignment.Center) { Wordmark() }; if (a.menu) MoreMenu(menu) else Spacer(Modifier.size(44.dp))
            }
            Box(Modifier.weight(1f).fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 4.dp).clip(RoundedCornerShape(8.dp))) {
                RefImage(model.cover, Modifier.fillMaxSize(), 18)
                Viewfinder()
                val ro = m.type.mono.copy(fontSize = 11.5.sp, letterSpacing = .06.em)
                T("${model.filled}/7", ro, Color.White, Modifier.align(Alignment.TopStart).padding(start = 16.dp, top = 14.dp))
                T("768×1344", ro, Color.White, Modifier.align(Alignment.TopEnd).padding(end = 16.dp, top = 14.dp))
                T("REF · FACE FRONT", ro, Color.White, Modifier.align(Alignment.BottomStart).padding(start = 16.dp, bottom = 14.dp))
                T("${s.outfits.size} OUTFITS", ro, Color.White, Modifier.align(Alignment.BottomEnd).padding(end = 16.dp, bottom = 14.dp))
                Box(Modifier.align(Alignment.Center).size(20.dp).drawBehind {
                    val c = Color.White.copy(alpha = .7f); val w = 1.5.dp.toPx()
                    drawLine(c, Offset(size.width / 2, 0f), Offset(size.width / 2, size.height), w)
                    drawLine(c, Offset(0f, size.height / 2), Offset(size.width, size.height / 2), w)
                })
            }
            Row(Modifier.fillMaxWidth().padding(start = 18.dp, end = 18.dp, top = 14.dp), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.Bottom) {
                T(model.name, m.type.mono.copy(fontSize = 22.sp, fontWeight = FontWeight.Medium), m.t.ink)
                T("● ACTIVE", m.type.mono.copy(fontSize = 11.sp, letterSpacing = .1.em), m.t.accent)
            }
            T("Identity locked · every shoot and video uses these shots · never add: ${model.neverAdd.joinToString(", ").ifBlank { "nothing yet" }}",
                m.type.mono.copy(fontSize = 12.sp, lineHeight = 16.sp), m.t.muted, Modifier.padding(start = 18.dp, end = 18.dp, top = 2.dp))
            Column(Modifier.padding(start = 20.dp, end = 20.dp, top = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                RowB { Lbl("Outfit"); T("${s.selected + 1} / ${s.outfits.size}", m.type.mono.copy(fontSize = 12.5.sp), m.t.muted) }
                OutfitStrip(s, a)
            }
            ProfileExtras(s.lora, s.connected, a.lora, a.accounts)
        }
        ProfileDock(a)
    }
}

@Composable
private fun OutfitStrip(s: ProfileState, a: ProfileActions) {
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        s.outfits.forEachIndexed { i, o -> OutfitTile(o, i == s.selected, { a.select(i) }) }
        AddOutfitTile(a.addOutfit)
    }
}

// ---------------- C · Soft Tactile: rounded photo card, name + menu, sage pill, rounded carousel
@Composable
private fun ProfileC(model: Model, s: ProfileState, a: ProfileActions, menu: List<MenuItem>) {
    val m = muse
    ScreenBox {
        Column(Modifier.fillMaxSize().padding(bottom = 96.dp)) {
            Row(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                TbBtn("back", a.back); Box(Modifier.weight(1f), contentAlignment = Alignment.Center) { Wordmark() }; TbBtn("user", a.settings)
            }
            Box(Modifier.weight(1f).heightIn(max = 290.dp).fillMaxWidth().padding(start = 20.dp, end = 20.dp, top = 4.dp).clip(RoundedCornerShape(28.dp))) {
                RefImage(model.cover, Modifier.fillMaxSize(), 18)
            }
            Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 14.dp, top = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                T(model.name, m.type.h2.copy(fontSize = 30.sp), m.t.ink, Modifier.weight(1f))
                if (a.menu) MoreMenu(menu)
            }
            Row(
                Modifier.padding(start = 20.dp, top = 8.dp).clip(RoundedCornerShape(999.dp)).background(Color(0xFFDCE3D5)).padding(horizontal = 12.dp, vertical = 5.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Ic("lock", 13.dp, Color(0xFF4E6B45)); T("Identity locked · used by every shoot and video", m.type.body.copy(fontSize = 13.sp), Color(0xFF4E6B45))
            }
            RowB(Modifier.padding(start = 20.dp, end = 20.dp, top = 14.dp)) { T("Outfit", m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink); Tiny("${s.selected + 1} / ${s.outfits.size} ›") }
            Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 14.dp, top = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                s.outfits.forEachIndexed { i, o ->
                    val shape = RoundedCornerShape(16.dp)
                    Box(Modifier.size(68.dp, 92.dp).let { if (i == s.selected) it.border(2.dp, m.t.accent, shape) else it }.clip(shape).press { a.select(i) }) { RefImage(o.front, Modifier.fillMaxSize()) }
                }
                Box(Modifier.size(68.dp, 92.dp).clip(RoundedCornerShape(16.dp)).background(m.t.surface).press(onClick = a.addOutfit), contentAlignment = Alignment.Center) {
                    T("+", m.type.body.copy(fontSize = 26.sp), m.t.muted)
                }
                Spacer(Modifier.weight(1f))
                Box(Modifier.size(36.dp).softShadow(999.dp).clip(CircleShape).background(m.t.surface).press { a.select(s.selected + 1) }, contentAlignment = Alignment.Center) { Ic("chev", 16.dp) }
            }
            ProfileExtras(s.lora, s.connected, a.lora, a.accounts)
        }
        ProfileDock(a)
    }
}

// ---------------- D · Creator Pop: cobalt block, tilted cut-out photo, stickers and doodles
@Composable
private fun ProfileD(model: Model, s: ProfileState, a: ProfileActions, menu: List<MenuItem>) {
    val m = muse
    ScreenBox(statusPad = false) {
        Column(Modifier.fillMaxSize().padding(bottom = 96.dp)) {
            Box(Modifier.fillMaxWidth().background(m.t.blue).statusBarsPadding().padding(bottom = 48.dp)) {
                Column {
                    CompositionLocalProvider(androidx.compose.material3.LocalContentColor provides Color.White) {
                        Row(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                            TbBtn("back", a.back, tint = Color.White); Wordmark(color = Color.White)
                            T("CREATE · DIRECT\nYOUR AI MODEL", m.type.tiny.copy(fontWeight = FontWeight.Bold, lineHeight = 13.sp), Color.White, Modifier.weight(1f).padding(end = 4.dp), align = TextAlign.End)
                            if (a.menu) MoreMenu(menu, tint = Color.White)
                        }
                    }
                    Box(Modifier.fillMaxWidth().height(340.dp).padding(start = 26.dp, end = 26.dp, top = 6.dp)) {
                        val shape = RoundedCornerShape(22.dp)
                        Box(Modifier.fillMaxSize().rotate(-2f).hardShadow(6.dp, 22.dp).clip(shape).border(2.5.dp, Ink, shape).padding(2.5.dp).clip(shape).border(4.dp, Color.White, shape)) {
                            RefImage(model.cover, Modifier.fillMaxSize(), 18)
                        }
                        StrokeText(model.twoLines(), m.type.h2.copy(fontSize = 66.sp, lineHeight = 57.sp), Color.White, Modifier.align(Alignment.BottomStart).offset(x = 18.dp, y = 34.dp))
                    }
                }
                Sticker("Real looks\n+ AI power", "yellow", -10f, Modifier.statusBarsPadding().padding(start = 14.dp, top = 72.dp), size = 13f)
                Doodle(Doodles.crown, Modifier.align(Alignment.TopEnd).statusBarsPadding().padding(end = 24.dp, top = 48.dp))
                Doodle(Doodles.heart, Modifier.statusBarsPadding().padding(start = 22.dp, top = 212.dp))
                Sticker("Identity\nlocked", "pink", -7f, Modifier.align(Alignment.BottomEnd).padding(end = 16.dp, bottom = 30.dp), size = 18f)
            }
            Column(Modifier.padding(start = 20.dp, end = 20.dp, top = 34.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                T("AI ${model.niche.uppercase()} MODEL", m.type.body.copy(fontWeight = FontWeight.ExtraBold, letterSpacing = .04.em), m.t.blue)
                RowB { T("OUTFIT", m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink); T("${s.outfits.size} LOOKS ›", m.type.tiny.copy(fontWeight = FontWeight.Bold), m.t.ink) }
                OutfitStrip(s, a)
            }
            ProfileExtras(s.lora, s.connected, a.lora, a.accounts)
        }
        ProfileDock(a)
    }
}

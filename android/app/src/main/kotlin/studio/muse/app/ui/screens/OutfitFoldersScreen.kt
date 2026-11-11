package studio.muse.app.ui.screens

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import studio.muse.app.AppContainer
import studio.muse.app.data.Model
import studio.muse.app.data.ImageRef
import studio.muse.app.data.Outfit
import studio.muse.app.data.OutfitPictures
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.components.ImageViewer
import studio.muse.app.ui.components.Input
import studio.muse.app.ui.components.MenuItem
import studio.muse.app.ui.components.MuseMenu
import studio.muse.app.ui.components.RefImage
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.ViewerAction
import studio.muse.app.ui.components.ViewerImage
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.edit.learn.LearnConfirm
import studio.muse.app.ui.theme.MuseSpace
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.radii
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale
import studio.muse.core.OutfitNaming
import studio.muse.core.OutfitPages
import studio.muse.core.Pricing
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/** "11 Nov" (the suggested name's date). */
fun outfitDay(ms: Long): String = SimpleDateFormat("d MMM", Locale.UK).format(Date(ms))

/** The folder's date line: "11 Nov" this year, "11 Nov 2025" before. */
fun outfitDate(ms: Long?): String? {
    if (ms == null || ms <= 0) return null
    val year = { t: Long -> Calendar.getInstance().apply { timeInMillis = t }.get(Calendar.YEAR) }
    return if (year(ms) == year(System.currentTimeMillis())) outfitDay(ms) else SimpleDateFormat("d MMM yyyy", Locale.UK).format(Date(ms))
}

data class OutfitsState(val model: Model? = null, val folders: List<Outfit> = emptyList(), val page: Int = 0, val filling: Set<String> = emptySet(),
    /** Pictures being made (Add face close-ups, Redo): outfit id → [OutfitPictures] indexes. */
    val making: Map<String, Set<Int>> = emptyMap())

/** Her outfits as folders and one outfit open (plans/outfit-head-looks.md §4/§5): paging, rename, delete, missing angles. */
class OutfitsViewModel(private val c: AppContainer) : ViewModel() {
    private val filling = kotlinx.coroutines.flow.MutableStateFlow<Set<String>>(emptySet())
    val state: StateFlow<OutfitsState> = combine(c.repo.state, c.drafts.modelId, c.drafts.outfitPage, filling, c.repo.outfitMaking) { s, mid, page, f, making ->
        val model = s.model(mid) ?: s.models.firstOrNull()
        val folders = OutfitPages.newestFirst(s.outfitsOf(model?.id).filter { it.state == "ready" }) { it.createdAt }
        // An outfit that came back whole stops showing "Making angles".
        OutfitsState(model, folders, OutfitPages.clamp(page, folders.size), f.filterTo(mutableSetOf()) { id -> s.outfit(id)?.let { it.madeAngles < 4 } ?: false }, making)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, OutfitsState())

    fun outfit(id: String): Outfit? = c.repo.state.value.outfit(id)

    fun step(d: Int) { c.drafts.outfitPage.value = OutfitPages.clamp(state.value.page + d, state.value.folders.size) }

    /** The owner or whoever made it may rename or delete it (the server checks too). */
    fun canChange(o: Outfit): Boolean { val p = c.prefs.value; return c.repo.demo || p.owner || o.createdBy == null || o.createdBy == p.userId }

    fun rename(o: Outfit, raw: String) = viewModelScope.launch {
        val name = raw.trim()
        if (name.isEmpty()) { c.repo.toast("Give the outfit a name"); return@launch }
        if (name != o.name) c.repo.renameOutfit(o.id, name.take(OutfitNaming.MAX))
    }

    fun delete(o: Outfit, done: () -> Unit = {}) = viewModelScope.launch {
        if (o.id in filling.value) { c.repo.toast("This outfit is still being made · delete it when it finishes"); return@launch }
        if (c.repo.deleteOutfit(o.id) != null) {
            if (c.drafts.outfitId.value == o.id) c.drafts.outfitId.value = state.value.folders.firstOrNull { it.id != o.id }?.id ?: ""
            c.repo.toast("Outfit deleted")
            done()
        }
    }

    fun fill(o: Outfit) = viewModelScope.launch {
        if (o.front == null) { c.repo.toast("Its front picture is missing · make a new outfit instead"); return@launch }
        filling.value = filling.value + o.id
        if (c.repo.fillOutfit(o.id, null) == null) filling.value = filling.value - o.id
    }

    fun fillEstimate(o: Outfit): Double = (4 - o.madeAngles) * photoPrices(c).perEdit

    /** "Add face close-ups" (an older outfit, plans/outfit-faces.md): its missing face front, ¾ and side. */
    fun addFaces(o: Outfit) = viewModelScope.launch {
        if (o.front == null) { c.repo.toast("Its front picture is missing · make a new outfit instead"); return@launch }
        c.repo.addOutfitFaces(o.id)
    }
    fun facesEstimate(o: Outfit): Double = OutfitPictures.facesEstimate(photoPrices(c), o)

    /** Redo one of the 7 pictures ([index] into [OutfitPictures.KEYS]). */
    fun redo(o: Outfit, index: Int) = viewModelScope.launch {
        if (o.id in state.value.filling || state.value.making[o.id]?.contains(index) == true) return@launch
        c.repo.redoOutfit(o.id, index)
    }
    fun redoEstimate(index: Int): Double = OutfitPictures.redoEstimate(photoPrices(c), index)
}

private fun photoPrices(c: AppContainer): studio.muse.core.PhotoPrices = c.repo.state.value.photo

/** Her outfits as folders: the front, name and date; two per row, 8 per page, newest first, "‹ 1 of 3 ›". */
@Composable
fun OutfitFoldersScreen() {
    val c = LocalContainer.current
    val vm: OutfitsViewModel = viewModel { OutfitsViewModel(c) }
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    val m = muse
    var renaming by remember { mutableStateOf<Outfit?>(null) }
    var deleting by remember { mutableStateOf<Outfit?>(null) }
    val who = s.model?.name?.substringBefore(' ')
    ScreenBox(bg = m.roles.canvas) {
        Column(Modifier.fillMaxSize()) {
            CalmTopBar(if (who != null) "$who's outfits" else "Outfits", onBack = { nav.back() }, right = { BarButton("plus", "Add outfit", { nav.go(Routes.OUTFIT) }) })
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = MuseSpace.gutter).padding(top = MuseSpace.s2, bottom = 48.dp),
                verticalArrangement = Arrangement.spacedBy(MuseSpace.s4),
            ) {
                if (s.folders.isEmpty()) {
                    EmptyState("No outfits yet", "Describe one, use a product photo, or bring in your own four angles.", "Add outfit", { nav.go(Routes.OUTFIT) })
                } else {
                    OutfitPages.slice(s.folders, s.page).chunked(2).forEach { row ->
                        Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
                            row.forEach { o ->
                                OutfitFolder(o, o.id in s.filling || o.id in s.making, vm.canChange(o), Modifier.weight(1f),
                                    open = { nav.go(Routes.outfitView(o.id)) }, rename = { renaming = o }, delete = { deleting = o })
                            }
                            if (row.size == 1) Spacer(Modifier.weight(1f))
                        }
                    }
                    val pages = OutfitPages.count(s.folders.size)
                    if (pages > 1) {
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                            PagerArrow("back", "Previous page", s.page > 0) { vm.step(-1) }
                            T(OutfitPages.label(s.page, s.folders.size), m.scale.label, m.roles.ink, Modifier.padding(horizontal = MuseSpace.s3))
                            PagerArrow("caret-right", "Next page", s.page < pages - 1) { vm.step(1) }
                        }
                    }
                }
            }
        }
        renaming?.let { o -> RenameOutfit(o.name, { renaming = null }) { vm.rename(o, it); renaming = null } }
        deleting?.let { o ->
            LearnConfirm("Delete this outfit?", "Takes and photos already made with it are kept.", "Delete", { vm.delete(o); deleting = null }, { deleting = null })
        }
    }
}

@Composable
private fun PagerArrow(icon: String, label: String, on: Boolean, onClick: () -> Unit) {
    val m = muse
    Box(Modifier.heightIn(min = 48.dp).widthIn(min = 48.dp).press(enabled = on, onClick = onClick).semantics { contentDescription = label; role = Role.Button },
        contentAlignment = Alignment.Center) {
        studio.muse.app.ui.theme.Ic(icon, 20.dp, if (on) m.roles.ink else m.roles.ink2.copy(alpha = .4f))
    }
}

/** One folder: the front only, the name and the date. Tap opens it; long-press renames or deletes. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun OutfitFolder(o: Outfit, filling: Boolean, canChange: Boolean, modifier: Modifier, open: () -> Unit, rename: () -> Unit, delete: () -> Unit) {
    val m = muse
    var menu by remember { mutableStateOf(false) }
    Column(modifier.combinedClickable(onClickLabel = "Open", onLongClickLabel = if (canChange) "Rename or delete" else null,
        onLongClick = { if (canChange) menu = true }, onClick = open).semantics { contentDescription = o.name },
        verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
        Box(Modifier.fillMaxWidth().aspectRatio(3f / 4f).clip(containerShape()).background(m.roles.field)) {
            RefImage(o.front, Modifier.fillMaxSize())
            val note = if (filling) "Making angles" else if (o.madeAngles < 4) "${o.madeAngles} of 4 angles" else null
            if (note != null) T(note, m.scale.caption, Color.White,
                Modifier.align(Alignment.TopStart).padding(MuseSpace.s2).clip(RoundedCornerShape(m.radii.control)).background(Color.Black.copy(alpha = .55f)).padding(horizontal = 6.dp, vertical = 2.dp))
            MuseMenu(menu, { menu = false }, listOf(MenuItem("pencil-simple", "Rename", onClick = rename), MenuItem("trash", "Delete", danger = true, onClick = delete)))
        }
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(o.name, m.scale.label, m.roles.ink, maxLines = 1)
            outfitDate(o.createdAt)?.let { Caption(it, maxLines = 1) }
        }
    }
}

/** Rename: the name in a field, Rename saves. */
@Composable
fun RenameOutfit(current: String, onKeep: () -> Unit, onSave: (String) -> Unit) {
    val m = muse
    var name by remember { mutableStateOf(current) }
    Box(Modifier.fillMaxWidth().fillMaxHeight().background(Color.Black.copy(alpha = .32f)).press(onClick = onKeep), contentAlignment = Alignment.Center) {
        Column(
            Modifier.padding(32.dp).widthIn(max = 360.dp).fillMaxWidth().clip(RoundedCornerShape(m.radii.container)).background(m.roles.raised).press { }.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            T("Rename outfit", m.scale.title, m.roles.ink)
            Input(name, { name = it.take(OutfitNaming.MAX) }, calm = true)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End), verticalAlignment = Alignment.CenterVertically) {
                TextAction("Cancel", onKeep)
                PrimaryButton("Rename", { onSave(name) }, off = name.isBlank())
            }
        }
    }
}

/** One outfit open: its 4 body angles and 3 face close-ups (tap one to view it full size and swipe between all 7) and its actions. */
@Composable
fun OutfitOpenScreen(id: String) {
    val c = LocalContainer.current
    val vm: OutfitsViewModel = viewModel { OutfitsViewModel(c) }
    val s by vm.state.collectAsState()
    val nav = LocalNav.current
    val m = muse
    val o = c.repo.state.collectAsState().value.outfit(id)
    var viewing by remember { mutableStateOf<Int?>(null) }
    var renaming by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    if (o == null) {
        ScreenBox(bg = m.roles.canvas) {
            Column(Modifier.fillMaxSize()) {
                CalmTopBar("Outfit", onBack = { nav.back() })
                ErrorState("This outfit isn't here any more", "It may have been deleted on another device.", "Back", { nav.back() }, Modifier.padding(horizontal = MuseSpace.gutter))
            }
        }
        return
    }
    val filling = o.id in s.filling
    val canChange = vm.canChange(o)
    val making = s.making[o.id].orEmpty()
    val pictures = OutfitPictures.all(o)
    val shownAt = OutfitPictures.shown(pictures)
    val shown = shownAt.map { (i, r) -> ViewerImage(r, OutfitPictures.LABELS[i]) }
    // Full size: "Redo · $0.03" for the picture shown (the owner or whoever made the outfit).
    val redoAction: ((Int) -> ViewerAction?)? = if (canChange) ({ page: Int ->
        shownAt.getOrNull(page)?.let { (i, _) ->
            ViewerAction("Redo · ${Pricing.money(vm.redoEstimate(i))}", { vm.redo(o, i); viewing = null }, enabled = i !in making && !filling)
        }
    }) else null
    val facesMissing = OutfitPictures.FACES - OutfitPictures.madeFaces(o)
    val makingFaces = (OutfitPictures.BODY until OutfitPictures.KEYS.size).any { it in making }
    // "Make missing angles": the empty ¾ / side / back show as skeletons until they come back.
    val fillingAt: List<Int> = if (filling) (1 until OutfitPictures.BODY).filter { pictures[it] == null } else emptyList()
    ScreenBox(bg = m.roles.canvas) {
        Column(Modifier.fillMaxSize()) {
            CalmTopBar(onBack = { nav.back() }, right = if (canChange) ({ BarButton("trash", "Delete outfit", { deleting = true }) }) else null)
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = MuseSpace.gutter).padding(bottom = 120.dp),
                verticalArrangement = Arrangement.spacedBy(MuseSpace.s4),
            ) {
                Column(
                    Modifier.let { if (canChange) it.press { renaming = true }.semantics { contentDescription = "${o.name}, rename"; role = Role.Button } else it },
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    DisplayTitle(o.name)
                    Caption(listOfNotNull(s.model?.name?.substringBefore(' ')?.let { "For $it" }, outfitDate(o.createdAt)?.let { "made $it" }).joinToString(", "))
                }
                OutfitPictureGrid(pictures, making + fillingAt, busy = false) { i ->
                    viewing = OutfitPictures.pageOf(pictures, i)
                }
                if (filling) Notice("Making the missing angles from the front.")
                else if (o.madeAngles < 4 && o.front != null && canChange) {
                    Notice("${o.madeAngles} of 4 angles. The others came back empty.", tone = NoticeTone.CAUTION)
                    SecondaryButton("Make missing angles · ${studio.muse.core.PhotoPricing.about(vm.fillEstimate(o))}", { vm.fill(o) }, Modifier.fillMaxWidth())
                }
                // An older outfit (made before every outfit had face close-ups), or faces that came back empty.
                if (facesMissing > 0 && !makingFaces) {
                    Notice(
                        if (facesMissing == OutfitPictures.FACES) "No face close-ups yet. Shots with this outfit use her base face."
                        else "${OutfitPictures.FACES - facesMissing} of 3 face close-ups. The others came back empty.",
                        tone = if (facesMissing == OutfitPictures.FACES) NoticeTone.NEUTRAL else NoticeTone.CAUTION,
                    )
                    if (canChange && o.front != null) SecondaryButton(
                        "${if (facesMissing == OutfitPictures.FACES) "Add face close-ups" else "Make missing face close-ups"} · ${Pricing.money(vm.facesEstimate(o))}",
                        { vm.addFaces(o) }, Modifier.fillMaxWidth(),
                    )
                }
            }
        }
        viewing?.let { start -> if (shown.isNotEmpty()) ImageViewer(shown, start, action = redoAction) { viewing = null } }
        ActionDock {
            PrimaryButton("Use in Photo", { studio.muse.app.ui.screens.suite.composer.openPhoto(c, nav, o.modelId, o.id) }, Modifier.weight(1f))
        }
        if (renaming) RenameOutfit(o.name, { renaming = false }) { vm.rename(o, it); renaming = false }
        if (deleting) LearnConfirm("Delete this outfit?", "Takes and photos already made with it are kept.", "Delete", { deleting = false; vm.delete(o) { nav.back() } }, { deleting = false })
    }
}

/**
 * An outfit's 7 pictures (plans/outfit-faces.md): the 4 body angles, then the 3 face close-ups in the same columns, grouped
 * by space with their captions ("Face front"). 2 columns on a phone, 4 when wide. A picture in [making] (or, while [busy],
 * any not made yet) shows a skeleton; a tap opens [onOpen] with its index into [OutfitPictures.KEYS].
 */
@Composable
fun OutfitPictureGrid(pictures: List<ImageRef?>, making: Collection<Int>, busy: Boolean, onOpen: (Int) -> Unit) {
    val m = muse
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val cols = if (maxWidth >= 600.dp) 4 else 2
        Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s6)) {
            listOf((0 until OutfitPictures.BODY).toList(), (OutfitPictures.BODY until OutfitPictures.KEYS.size).toList()).forEach { group ->
                Column(verticalArrangement = Arrangement.spacedBy(MuseSpace.s4)) {
                    group.chunked(cols).forEach { row ->
                        Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
                            row.forEach { i ->
                                val ref = pictures.getOrNull(i)
                                val label = OutfitPictures.LABELS[i]
                                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
                                    val tile = Modifier.fillMaxWidth().aspectRatio(3f / 4f)
                                    if (i in making || (busy && ref == null)) Skeleton(tile.semantics { contentDescription = "$label, being made" }, containerShape())
                                    else Box(tile.clip(containerShape()).background(m.roles.field).let { t ->
                                        if (ref == null) t.semantics { contentDescription = "$label missing" }
                                        else t.press { onOpen(i) }.semantics { contentDescription = "$label, view full size"; role = Role.Button }
                                    }) { if (ref != null) RefImage(ref, Modifier.fillMaxSize()) }
                                    Caption(label, maxLines = 1)
                                }
                            }
                            repeat(cols - row.size) { Spacer(Modifier.weight(1f)) }
                        }
                    }
                }
            }
        }
    }
}

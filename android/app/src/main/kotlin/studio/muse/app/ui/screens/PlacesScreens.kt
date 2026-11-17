package studio.muse.app.ui.screens

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import studio.muse.app.AppContainer
import studio.muse.app.data.ImageRef
import studio.muse.app.data.Model
import studio.muse.app.data.PlaceCreate
import studio.muse.app.data.PlacePatch
import studio.muse.app.data.PlacePhotoEstimate
import studio.muse.app.data.PlacePhotoRequest
import studio.muse.app.data.Places
import studio.muse.app.data.SuiteLocation
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.components.MenuItem
import studio.muse.app.ui.components.MoreMenu
import studio.muse.app.ui.components.RefImage
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.MuseSpace
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.radii
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale

// Her world, phase 1 (plans/model-world.md, mockups 7 and 8): the Places tab on her page, a place, and Add photo with
// each way's price. One photo per Generate, priced on the button, never charged above it.

/** The route of one place. */
fun placeRoute(id: String) = "place/$id"
const val PLACE_ROUTE = "place/{id}"

// ---------------------------------------------------------------- actions (shared with the composer's @ list)

private fun keep(c: AppContainer, l: SuiteLocation) =
    c.suite.locations.update { list -> if (list.any { it.id == l.id }) list.map { if (it.id == l.id) l else it } else listOf(l) + list }

/** "Add a place": hers alone, by name; photos come next on the place. */
suspend fun newPlace(c: AppContainer, modelId: String, name: String): SuiteLocation? {
    val n = name.trim().take(60)
    if (n.isEmpty()) { c.repo.toast("Give the place a name"); return null }
    return c.repo.attempt { createPlace(PlaceCreate(n, modelId = modelId)) }?.also { keep(c, it) }
}

suspend fun patchPlace(c: AppContainer, id: String, patch: PlacePatch) { c.repo.attempt { updatePlace(id, patch) }?.let { keep(c, it) } }

/** Add photo → Upload photos (free), up to the place's room. */
suspend fun uploadPlacePhotos(c: AppContainer, place: SuiteLocation, uris: List<Uri>) {
    val media = c.media ?: return
    val room = Places.MAX_IMAGES - place.photos.size
    if (room <= 0) { c.repo.toast("A place keeps up to ${Places.MAX_IMAGES} photos · remove one first"); return }
    if (uris.size > room) c.repo.toast("Added the first $room · a place keeps up to ${Places.MAX_IMAGES} photos")
    for (u in uris.take(room)) {
        val bytes = media.bytes(u) ?: run { c.repo.toast("Couldn't read that image"); null } ?: continue
        val ref = c.repo.uploadImage(media.displayName(u), bytes, media.mime(u)) ?: return
        c.repo.attempt { addPlaceImage(place.id, ref) }?.let { keep(c, it) } ?: return
    }
}

suspend fun removePlacePhoto(c: AppContainer, id: String, index: Int) { c.repo.attempt { removePlaceImage(id, index) }?.let { keep(c, it) } }

/** Makes one photo at the price on the button; true when it was made. */
suspend fun makePlacePhoto(c: AppContainer, id: String, req: PlacePhotoRequest): Boolean =
    c.repo.attempt { makePlacePhoto(id, req) }?.also { keep(c, it.place) } != null

// ---------------------------------------------------------------- the Places tab

/** Her places as folders (mockup 7). Empty: what places are, one action and quick starts. */
@Composable
fun PlacesTab(places: List<SuiteLocation>, open: (String) -> Unit, add: () -> Unit, starter: (String) -> Unit, modifier: Modifier = Modifier) {
    val m = muse
    if (places.isEmpty()) {
        Column(modifier.fillMaxWidth().padding(horizontal = MuseSpace.gutter, vertical = MuseSpace.s5), verticalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
            Ic("map-pin", 22.dp, m.roles.ink2)
            EmptyState("No places yet", "Add her apartment, gym, a café… A few photos of each keep the background the same in every video.", "Add a place", add)
            Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2)) { Places.STARTERS.forEach { n -> ChoiceChip(n, false, { starter(n) }) } }
        }
        return
    }
    LazyVerticalGrid(
        GridCells.Fixed(2), modifier.fillMaxWidth(),
        contentPadding = PaddingValues(start = MuseSpace.gutter, end = MuseSpace.gutter, top = MuseSpace.s3, bottom = 96.dp),
        horizontalArrangement = Arrangement.spacedBy(MuseSpace.s3), verticalArrangement = Arrangement.spacedBy(MuseSpace.s4),
    ) {
        item(span = { androidx.compose.foundation.lazy.grid.GridItemSpan(2) }) { Caption("Type @ and a place name in any prompt.") }
        items(places, key = { it.id }) { p ->
            Column(Modifier.press { open(p.id) }.semantics(mergeDescendants = true) { role = Role.Button; contentDescription = "${p.name}, @${p.atTag}, ${p.photos.size} photos" },
                verticalArrangement = Arrangement.spacedBy(MuseSpace.s1)) {
                Box(Modifier.fillMaxWidth().aspectRatio(4f / 3f).clip(containerShape()).background(m.roles.field), contentAlignment = Alignment.Center) {
                    val c = p.coverImage
                    if (c != null) RefImage(c, Modifier.fillMaxSize()) else Ic("folder-simple", 22.dp, m.roles.ink2)
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    T(p.name, m.scale.label, m.roles.ink, Modifier.weight(1f), maxLines = 1)
                    T("${p.photos.size}", m.scale.caption, m.roles.ink2, maxLines = 1)
                }
                T("@${p.atTag}", m.scale.caption, m.roles.ink2, maxLines = 1)
            }
        }
    }
}

/** A small name dialog (Add a place, Rename, Change tag). [done] gets the text, or null on Cancel. */
@Composable
fun PlaceTextDialog(title: String, initial: String, placeholder: String, action: String, done: (String?) -> Unit) {
    val m = muse
    var text by remember { mutableStateOf(initial) }
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = .32f)).press { done(null) }, contentAlignment = Alignment.Center) {
        Column(Modifier.padding(24.dp).widthIn(max = 420.dp).fillMaxWidth().clip(RoundedCornerShape(m.radii.container)).background(m.roles.canvas).press { }.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            T(title, m.scale.title, m.roles.ink, Modifier.semantics { heading() })
            Box(Modifier.fillMaxWidth().heightIn(min = 48.dp).clip(RoundedCornerShape(m.radii.control)).background(m.roles.field).padding(horizontal = 12.dp),
                contentAlignment = Alignment.CenterStart) {
                BasicTextField(text, { text = it.take(600) }, Modifier.fillMaxWidth().semantics { contentDescription = title },
                    textStyle = m.scale.body.copy(color = m.roles.ink), cursorBrush = SolidColor(m.roles.accent),
                    decorationBox = { inner -> Box { if (text.isEmpty()) T(placeholder, m.scale.body, m.roles.ink2, maxLines = 1); inner() } })
            }
            Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2), verticalAlignment = Alignment.CenterVertically) {
                Spacer(Modifier.weight(1f))
                TextAction("Cancel", { done(null) })
                PrimaryButton(action, { done(text) }, off = text.isBlank())
            }
        }
    }
}

// ---------------------------------------------------------------- one place

@Composable
fun PlaceScreen(id: String) {
    val c = LocalContainer.current
    val nav = LocalNav.current
    val m = muse
    val scope = rememberCoroutineScope()
    val all by c.suite.locations.collectAsState()
    val repo by c.repo.state.collectAsState()
    LaunchedEffect(id) { if (all.none { it.id == id }) c.suite.loadLocations() }
    val place = all.firstOrNull { it.id == id }
    var sheet by remember { mutableStateOf(false) }
    var making by remember { mutableStateOf<String?>(null) }
    var dialog by remember { mutableStateOf<String?>(null) }
    var photoMenu by remember { mutableStateOf<Int?>(null) }
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(Places.MAX_IMAGES)) { uris ->
        val p = place
        if (uris.isNotEmpty() && p != null) scope.launch { uploadPlacePhotos(c, p, uris) }
    }
    ScreenBox(bg = m.roles.canvas) {
        if (place == null) {
            Column(Modifier.fillMaxSize()) {
                CalmTopBar("Place", onBack = { nav.back() })
                ErrorState("This place isn't here any more", "It may have been deleted.", "Back", { nav.back() }, Modifier.padding(horizontal = MuseSpace.gutter))
            }
            return@ScreenBox
        }
        val others = repo.models.filter { it.id != place.modelId && !it.archived }
        val menu = buildList {
            add(MenuItem("pencil-simple", "Rename") { dialog = "rename" })
            add(MenuItem("at", "Change tag") { dialog = "tag" })
            add(MenuItem("text-aa", "Edit description") { dialog = "description" })
            others.forEach { o -> add(MenuItem("copy", "Copy to ${o.name}") { scope.launch { c.repo.attempt { copyPlace(place.id, o.id) }?.let { keep(c, it); c.repo.toast("Copied to ${o.name} as @${it.atTag}") } } }) }
            add(MenuItem("trash", "Delete place", danger = true) { dialog = "delete" })
        }
        Column(Modifier.fillMaxSize()) {
            CalmTopBar(place.name, onBack = { nav.back() }, right = { MoreMenu(menu, tint = m.roles.ink) })
            Row(Modifier.padding(horizontal = MuseSpace.gutter), horizontalArrangement = Arrangement.spacedBy(MuseSpace.s3), verticalAlignment = Alignment.CenterVertically) {
                T("@${place.atTag}", m.scale.label, m.roles.ink, Modifier.clip(RoundedCornerShape(m.radii.chip)).background(m.roles.field).padding(horizontal = 10.dp, vertical = 6.dp), maxLines = 1)
                T("${place.photos.size} photo${if (place.photos.size == 1) "" else "s"}", m.scale.caption, m.roles.ink2, maxLines = 1)
            }
            if (place.description.isNotBlank()) Caption(place.description, Modifier.padding(start = MuseSpace.gutter, end = MuseSpace.gutter, top = MuseSpace.s3))
            LazyVerticalGrid(
                GridCells.Fixed(2), Modifier.weight(1f).fillMaxWidth(),
                contentPadding = PaddingValues(start = MuseSpace.gutter, end = MuseSpace.gutter, top = MuseSpace.s4, bottom = 104.dp),
                horizontalArrangement = Arrangement.spacedBy(MuseSpace.s3), verticalArrangement = Arrangement.spacedBy(MuseSpace.s3),
            ) {
                itemsIndexed(place.photos) { i, img ->
                    Column(Modifier.press { photoMenu = i }.semantics(mergeDescendants = true) { contentDescription = img.caption + if (i == place.cover) ", cover" else "" },
                        verticalArrangement = Arrangement.spacedBy(MuseSpace.s1)) {
                        Box(Modifier.fillMaxWidth().aspectRatio(1f).clip(containerShape()).background(m.roles.field)) {
                            RefImage(img.ref, Modifier.fillMaxSize())
                            if (i == place.cover) T("Cover", m.scale.caption, Color.White,
                                Modifier.padding(8.dp).clip(RoundedCornerShape(m.radii.chip)).background(Color.Black.copy(alpha = .55f)).padding(horizontal = 8.dp, vertical = 2.dp))
                        }
                        T(img.caption, m.scale.caption, m.roles.ink2, maxLines = 1)
                    }
                }
                item(span = { androidx.compose.foundation.lazy.grid.GridItemSpan(2) }) {
                    Caption("Sent as the scene picture when you type @${place.atTag}. Her photos go first; if a model has no room left, the place is described in words.",
                        Modifier.padding(top = MuseSpace.s3))
                }
            }
        }
        ActionDock { PrimaryButton("Add photo", { sheet = true }, Modifier.weight(1f), icon = "plus", off = place.photos.size >= Places.MAX_IMAGES) }

        photoMenu?.let { i ->
            ChoiceOverlay(listOfNotNull(
                if (i != place.cover) "Make cover" else null, "Remove photo",
            ), close = { photoMenu = null }) { choice ->
                photoMenu = null
                scope.launch { if (choice == "Make cover") patchPlace(c, place.id, PlacePatch(cover = i)) else removePlacePhoto(c, place.id, i) }
            }
        }
        if (sheet) AddPhotoSheet(place, close = { sheet = false }, upload = { sheet = false; pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
            mode = { sheet = false; making = it })
        making?.let { mode -> PlacePhotoConfirm(place, mode) { making = null } }
        when (dialog) {
            "rename" -> PlaceTextDialog("Rename place", place.name, "Café by the gym", "Save") { t -> dialog = null; if (t != null) scope.launch { patchPlace(c, place.id, PlacePatch(name = t.trim())) } }
            "tag" -> PlaceTextDialog("Change tag", place.atTag, "cafe", "Save tag") { t -> dialog = null; if (t != null) scope.launch { patchPlace(c, place.id, PlacePatch(tag = t.trim().removePrefix("@").lowercase())) } }
            "description" -> PlaceTextDialog("Describe the place", place.description, "Corner café with a striped awning", "Save") { t ->
                dialog = null; if (t != null) scope.launch { patchPlace(c, place.id, PlacePatch(description = t.trim())) }
            }
            "delete" -> ChoiceOverlay(listOf("Delete place"), title = "Delete ${place.name}? Its photos go too.", close = { dialog = null }) {
                dialog = null
                scope.launch {
                    if (c.repo.attempt { deleteSuiteLocation(place.id) } != null) { c.suite.locations.update { l -> l.filter { it.id != place.id } }; nav.back() }
                }
            }
        }
    }
}

/** A few choices over the screen (a photo's actions, a confirmation). */
@Composable
private fun ChoiceOverlay(choices: List<String>, title: String? = null, close: () -> Unit, pick: (String) -> Unit) {
    val m = muse
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = .32f)).press(onClick = close), contentAlignment = Alignment.BottomCenter) {
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(topStart = m.radii.container, topEnd = m.radii.container)).background(m.roles.canvas).press { }
            .navigationBarsPadding().padding(MuseSpace.gutter), verticalArrangement = Arrangement.spacedBy(MuseSpace.s1)) {
            if (title != null) T(title, m.scale.label, m.roles.ink, Modifier.padding(bottom = MuseSpace.s2))
            choices.forEach { ch ->
                Box(Modifier.fillMaxWidth().heightIn(min = 52.dp).press { pick(ch) }.semantics { role = Role.Button }, contentAlignment = Alignment.CenterStart) {
                    T(ch, m.scale.body, if (ch.startsWith("Delete") || ch.startsWith("Remove")) m.roles.danger else m.roles.ink)
                }
            }
            Box(Modifier.fillMaxWidth().heightIn(min = 52.dp).press(onClick = close), contentAlignment = Alignment.CenterStart) { T("Cancel", m.scale.body, m.roles.link) }
        }
    }
}

/** Add photo (mockup 8): Upload (free), then the three ways to make one, each with its price first. */
@Composable
private fun AddPhotoSheet(place: SuiteLocation, close: () -> Unit, upload: () -> Unit, mode: (String) -> Unit) {
    val c = LocalContainer.current
    val m = muse
    val prices = remember { mutableStateMapOf<String, Double>() }
    LaunchedEffect(place.id) {
        for (md in Places.MODES) if (!(md == "random" && place.photos.isEmpty()))
            runCatching { c.repo.api.placePhotoEstimate(place.id, PlacePhotoRequest(md)) }.onSuccess { prices[md] = it.estimate }
    }
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = .32f)).press(onClick = close), contentAlignment = Alignment.BottomCenter) {
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(topStart = m.radii.container, topEnd = m.radii.container)).background(m.roles.canvas).press { }
            .navigationBarsPadding().padding(MuseSpace.gutter), verticalArrangement = Arrangement.spacedBy(MuseSpace.s1)) {
            T("Add photo", m.scale.title, m.roles.ink, Modifier.padding(bottom = MuseSpace.s2).semantics { heading() })
            SheetRow("upload-simple", "Upload photos", "From your phone", "Free", true, upload)
            Places.MODES.forEach { md ->
                val noPhotos = md == "random" && place.photos.isEmpty()
                SheetRow(Places.icon(md), Places.title(md), if (noPhotos) "Add a photo first" else Places.line(md), prices[md]?.let(Places::money) ?: "…", !noPhotos) { mode(md) }
            }
            Caption("You approve the price before anything is made.", Modifier.padding(top = MuseSpace.s2))
        }
    }
}

@Composable
private fun SheetRow(icon: String, title: String, line: String, price: String, enabled: Boolean, onClick: () -> Unit) {
    val m = muse
    Row(Modifier.fillMaxWidth().heightIn(min = 64.dp).press(enabled = enabled, onClick = onClick).semantics(mergeDescendants = true) { role = Role.Button },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(MuseSpace.s4)) {
        Ic(icon, 24.dp, if (enabled) m.roles.ink else m.roles.ink2)
        Column(Modifier.weight(1f)) {
            T(title, m.scale.label, if (enabled) m.roles.ink else m.roles.ink2, maxLines = 1)
            T(line, m.scale.caption, m.roles.ink2, maxLines = 1)
        }
        T(price, m.scale.caption, m.roles.ink2, maxLines = 1)
    }
}

/** One photo, priced first: the button carries the price; the photo is made only when it is pressed. */
@Composable
private fun PlacePhotoConfirm(place: SuiteLocation, mode: String, close: () -> Unit) {
    val c = LocalContainer.current
    val m = muse
    val scope = rememberCoroutineScope()
    var words by remember { mutableStateOf(place.description) }
    var reference by remember { mutableStateOf<ImageRef?>(null) }
    var estimate by remember { mutableStateOf<PlacePhotoEstimate?>(null) }
    var busy by remember { mutableStateOf(false) }
    val pickRef = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        val media = c.media
        if (uri != null && media != null) scope.launch {
            val bytes = media.bytes(uri) ?: return@launch c.repo.toast("Couldn't read that image")
            c.repo.uploadImage(media.displayName(uri), bytes, media.mime(uri))?.let { reference = it }
        }
    }
    fun request(max: Double? = null) = PlacePhotoRequest(mode, description = if (mode == "description") words.trim().ifEmpty { null } else null,
        reference = if (mode == "reference") reference else null, maxUsd = max)
    LaunchedEffect(place.id, mode) { estimate = c.repo.attempt { placePhotoEstimate(place.id, PlacePhotoRequest(mode)) } }
    val ready = !busy && estimate != null && when (mode) { "description" -> words.isNotBlank(); "reference" -> reference != null; else -> true }
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = .32f)).press(onClick = close), contentAlignment = Alignment.BottomCenter) {
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(topStart = m.radii.container, topEnd = m.radii.container)).background(m.roles.canvas).press { }
            .navigationBarsPadding().padding(MuseSpace.gutter), verticalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
            T(Places.title(mode), m.scale.title, m.roles.ink, Modifier.semantics { heading() })
            when (mode) {
                "random" -> Body("Another view of ${place.name} from its photos, in the same light. No people.")
                "description" -> Box(Modifier.fillMaxWidth().heightIn(min = 96.dp).clip(RoundedCornerShape(m.radii.control)).background(m.roles.field).padding(12.dp)) {
                    BasicTextField(words, { words = it.take(600) }, Modifier.fillMaxWidth().semantics { contentDescription = "What the place looks like" },
                        textStyle = m.scale.body.copy(color = m.roles.ink), cursorBrush = SolidColor(m.roles.accent),
                        decorationBox = { inner -> Box { if (words.isEmpty()) T("The counter from inside, morning", m.scale.body, m.roles.ink2); inner() } })
                }
                else -> Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s3), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(96.dp).clip(containerShape()).background(m.roles.field), contentAlignment = Alignment.Center) {
                        val r = reference
                        if (r != null) RefImage(r, Modifier.fillMaxSize()) else Ic("image", 22.dp, m.roles.ink2)
                    }
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
                        Caption("A photo you like, rebuilt as this place. People in it are removed.")
                        SecondaryButton(if (reference == null) "Choose picture" else "Choose another", { pickRef.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) })
                    }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2), verticalAlignment = Alignment.CenterVertically) {
                TextAction("Cancel", close)
                Spacer(Modifier.width(MuseSpace.s2))
                PrimaryButton(estimate?.buttonLabel?.ifBlank { null } ?: "Generate", {
                    val e = estimate ?: return@PrimaryButton
                    busy = true
                    scope.launch {
                        val ok = makePlacePhoto(c, place.id, request(e.estimate))
                        busy = false
                        if (ok) close() else estimate = c.repo.attempt { placePhotoEstimate(place.id, PlacePhotoRequest(mode)) }
                    }
                }, Modifier.weight(1f), off = !ready, busy = busy)
            }
            Spacer(Modifier.height(MuseSpace.s1))
        }
    }
}

/** The People and Pets tabs until they arrive (mockup 6): what they will hold. No button that does nothing. */
@Composable
fun WorldEmpty(icon: String, title: String, body: String, modifier: Modifier = Modifier) {
    val m = muse
    Column(modifier.fillMaxWidth().padding(horizontal = MuseSpace.gutter, vertical = MuseSpace.s6), verticalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
        Ic(icon, 22.dp, m.roles.ink2)
        EmptyState(title, body)
    }
}

/** Her places for a model (newest first). */
fun placesOf(all: List<SuiteLocation>, model: Model?) = Places.forModel(model?.id, all).first

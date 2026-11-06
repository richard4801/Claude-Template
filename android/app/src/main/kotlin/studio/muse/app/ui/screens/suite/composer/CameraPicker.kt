package studio.muse.app.ui.screens.suite.composer

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.snapping.SnapPosition
import androidx.compose.foundation.gestures.snapping.rememberSnapFlingBehavior
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.filter
import studio.muse.app.data.CameraCatalog
import studio.muse.app.data.SuiteMoveOption
import studio.muse.app.data.SuiteOption
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.suite.SIc
import studio.muse.app.ui.theme.muse
import kotlin.math.abs

// AI suite (workstream 1): the Camera picker (plans/video-composer.md "Camera picker"): Setup (four three-card wheels),
// Angle (Height and Framing wheels with line diagrams), Movement (category chips, search, a grid of previews; a tap adds a
// #move to the prompt) and Directed (owner only, the camera stage's panel).

/** One card of a wheel: null id = Auto. */
data class WheelItem(val id: String?, val name: String, val caption: String, val preview: Preview)

private val AUTO_CARD = WheelItem(null, "Auto", "The engine decides", Preview(draw = PreviewDraw.Auto))

/** The wheels' cards, from the catalog's visible options (merged ids show as their survivor). */
object CameraWheels {
    private fun opt(o: SuiteOption) = WheelItem(o.id, o.label, o.description, Preview(o.render, o.loop))
    fun bodies(c: CameraCatalog) = listOf(AUTO_CARD) + ComposerCatalog.visible(c.bodies).map(::opt)
    fun lenses(c: CameraCatalog) = listOf(AUTO_CARD) + ComposerCatalog.visible(c.lenses).map(::opt)
    fun focals(c: CameraCatalog) = listOf(AUTO_CARD) + ComposerCatalog.focalSteps(c).map { mm ->
        val f = c.focals.firstOrNull { it.mm == mm }
        WheelItem("$mm", "$mm mm" + (f?.description?.ifBlank { null }?.let { " · $it" } ?: ""), FOCAL_LINES[mm] ?: "", Preview(draw = PreviewDraw.Focal(mm)))
    }
    fun apertures(c: CameraCatalog) = listOf(AUTO_CARD) + ComposerCatalog.visible(c.apertures).map { o ->
        WheelItem(o.id, o.label + (o.description.ifBlank { null }?.let { " · $it" } ?: ""), APERTURE_LINES[o.id] ?: "", Preview(draw = PreviewDraw.Iris(o.id.removePrefix("f").toDoubleOrNull() ?: 4.0)))
    }
    fun heights(c: CameraCatalog) = listOf(AUTO_CARD) + ComposerCatalog.visible(c.heights).map { WheelItem(it.id, it.label, it.description, Preview(draw = PreviewDraw.Height(it.id))) }
    fun framings(c: CameraCatalog) = listOf(AUTO_CARD) + ComposerCatalog.visible(c.shotSizes).map { WheelItem(it.id, it.label, it.description, Preview(draw = PreviewDraw.Framing(it.id))) }

    private val FOCAL_LINES = mapOf(14 to "Huge space, bent edges", 24 to "Room and context", 35 to "Everyday, a touch wide", 50 to "Like your eye sees", 85 to "Flattering, tighter faces", 135 to "Compressed, far away")
    private val APERTURE_LINES = mapOf("f1.4" to "Background melts away", "f2.8" to "Subject pops, gentle blur", "f5.6" to "Most of the scene sharp", "f11" to "Front to back in focus")

    /** The selected card's index (0 = Auto) for an id, through merges. */
    fun index(items: List<WheelItem>, id: String?, survivors: List<SuiteOption>? = null): Int {
        val s = if (survivors != null) ComposerCatalog.survivor(survivors, id) else id
        return items.indexOfFirst { it.id == s && s != null }.coerceAtLeast(0)
    }
}

/**
 * A wheel on the phone: a horizontal snap row with three cards visible, the selection centred and outlined, the others
 * dimmed. Scrolling to a card or tapping it picks it at once.
 */
@Composable
fun WheelRow(title: String, items: List<WheelItem>, selected: Int, onSelect: (WheelItem) -> Unit, previewHeight: Dp = 62.dp) {
    val m = muse
    val pick by rememberUpdatedState(onSelect)
    Column(Modifier.fillMaxWidth().padding(top = 14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SheetLabel(title, "${selected + 1} / ${items.size}", Modifier.padding(horizontal = 20.dp))
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val cardW = (maxWidth - 28.dp) / 2.6f
            val side = (maxWidth - cardW) / 2
            val state = rememberLazyListState(initialFirstVisibleItemIndex = selected)
            // Settled on a card: that card is the choice (choices apply instantly).
            LaunchedEffect(state, items) {
                snapshotFlow { state.isScrollInProgress }.distinctUntilChanged().drop(1).filter { !it }.collect {
                    val info = state.layoutInfo
                    val mid = (info.viewportStartOffset + info.viewportEndOffset) / 2
                    val c = info.visibleItemsInfo.minByOrNull { abs(it.offset + it.size / 2 - mid) }?.index ?: return@collect
                    items.getOrNull(c)?.let { pick(it) }
                }
            }
            // An outside change (Reset all, a preset): bring the selection to the centre.
            LaunchedEffect(selected) { if (state.firstVisibleItemIndex != selected || state.firstVisibleItemScrollOffset != 0) state.animateScrollToItem(selected) }
            LazyRow(state = state, contentPadding = PaddingValues(horizontal = side), horizontalArrangement = Arrangement.spacedBy(14.dp),
                flingBehavior = rememberSnapFlingBehavior(state, SnapPosition.Center)) {
                itemsIndexed(items, key = { i, it -> it.id ?: "auto$i" }) { i, it ->
                    WheelCard(it, i == selected, Modifier.width(cardW), previewHeight) { pick(it) }
                }
            }
        }
    }
}

@Composable
private fun WheelCard(it: WheelItem, on: Boolean, modifier: Modifier, previewHeight: Dp, onClick: () -> Unit) {
    val m = muse
    Column(modifier.alpha(if (on) 1f else .42f).press(onClick = onClick).semantics(mergeDescendants = true) { selected = on; role = Role.Button; contentDescription = it.name }) {
        Box(Modifier.fillMaxWidth().picked(on, m.t.accent)) {
            PreviewTile(it.preview, Modifier.fillMaxWidth().height(previewHeight).clip(RoundedCornerShape(10.dp))) { if (on) CheckBadge() }
        }
        T(it.name, m.type.body.copy(fontSize = 14.sp, fontWeight = FontWeight.SemiBold, lineHeight = 17.sp), m.t.ink, Modifier.padding(top = 6.dp, start = 3.dp), maxLines = 1)
        if (it.caption.isNotBlank()) T(it.caption, m.type.body.copy(fontSize = 12.sp, lineHeight = 15.sp), m.t.muted, Modifier.padding(start = 3.dp), maxLines = 2)
    }
}

/** The Camera picker's body for [tab]. */
@Composable
fun ColumnScope.CameraPickerBody(tab: String, d: ComposerDraft, cat: CameraCatalog, wide: Boolean, owner: Boolean, update: ((ComposerDraft) -> ComposerDraft) -> Unit, onMove: (SuiteMoveOption) -> Unit) {
    val s = d.settings
    fun set(f: (ComposerSettings) -> ComposerSettings) = update { it.copy(settings = f(it.settings)) }
    when (tab) {
        "angle" -> Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(bottom = 16.dp)) {
            val h = CameraWheels.heights(cat); val f = CameraWheels.framings(cat)
            WheelRow("Height", h, CameraWheels.index(h, s.height), { w -> set { it.copy(height = w.id) } }, 96.dp)
            WheelRow("Framing", f, CameraWheels.index(f, s.shotSize), { w -> set { it.copy(shotSize = w.id) } }, 96.dp)
        }
        "movement" -> MovementBody(d, cat, wide, onMove)
        "directed" -> if (owner) Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(16.dp)) {
            studio.muse.app.ui.screens.camera.DirectedModePanel(d.title.ifBlank { d.tool.title }) { json -> update { it.copy(directed = json) } }
            if (d.directed != null) Row(Modifier.padding(top = 12.dp).heightIn(min = 48.dp).press { update { it.copy(directed = null) } }, verticalAlignment = Alignment.CenterVertically) {
                T("Directed camera applied · use the chips instead", muse.type.tiny, muse.t.accent)
            }
        }
        else -> Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(bottom = 16.dp)) {
            val b = CameraWheels.bodies(cat); val l = CameraWheels.lenses(cat); val fo = CameraWheels.focals(cat); val a = CameraWheels.apertures(cat)
            WheelRow("Camera", b, CameraWheels.index(b, s.body, cat.bodies), { w -> set { it.copy(body = w.id) } })
            WheelRow("Lens", l, CameraWheels.index(l, s.lens, cat.lenses), { w -> set { it.copy(lens = w.id) } })
            WheelRow("Focal", fo, CameraWheels.index(fo, s.focalMm?.toString()), { w -> set { it.copy(focalMm = w.id?.toIntOrNull()) } })
            WheelRow("Aperture", a, CameraWheels.index(a, s.aperture?.let { ComposerCatalog.nearestAperture(cat, it) }), { w -> set { it.copy(aperture = w.id) } })
        }
    }
}

/** The Camera picker's sub-steps (Directed only for the owner). */
fun cameraTabs(s: ComposerSettings, owner: Boolean, directed: Boolean) = listOfNotNull(
    SheetTab("setup", "Setup", s.body != null || s.lens != null || s.focalMm != null || s.aperture != null),
    SheetTab("angle", "Angle", s.height != null || s.shotSize != null),
    SheetTab("movement", "Movement"),
    if (owner) SheetTab("directed", "Directed", directed) else null,
)

/** The moves under a Movement chip: Featured = the library (its labels), the others by `group`. Talking: talk-safe only. */
fun movesFor(cat: CameraCatalog, group: String, query: String, talkOnly: Boolean): List<SuiteMoveOption> {
    val list = when {
        query.isNotBlank() -> PromptTokens.searchMoves(cat, query)
        group == "featured" -> cat.library.mapNotNull { l -> cat.move(l.id)?.copy(label = l.label.ifBlank { cat.move(l.id)?.label.orEmpty() }) }
        else -> cat.moves.filter { it.group == group }
    }
    return if (talkOnly) list.filter { it.talkSafe } else list
}

@Composable
private fun ColumnScope.MovementBody(d: ComposerDraft, cat: CameraCatalog, wide: Boolean, onMove: (SuiteMoveOption) -> Unit) {
    val m = muse
    var group by rememberSaveable { mutableStateOf("featured") }
    var query by rememberSaveable { mutableStateOf("") }
    var searching by rememberSaveable { mutableStateOf(false) }
    val talkOnly = d.tool == ComposerTool.TALKING
    val moves = movesFor(cat, group, query, talkOnly)
    val inPrompt = d.tokens.moves.map { it.id }.toSet()
    T("Tap to add to your prompt · or type # · up to 2 moves", m.type.body.copy(fontSize = 13.sp), m.t.muted, Modifier.padding(horizontal = 16.dp), maxLines = 2)
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(48.dp).press { searching = !searching; if (!searching) query = "" }.semantics { contentDescription = "Search moves"; role = Role.Button }, contentAlignment = Alignment.Center) {
            Box(Modifier.size(34.dp).clip(CircleShape).background(if (searching) m.t.ink else m.t.surface2), contentAlignment = Alignment.Center) { SIc("search", 16.dp, if (searching) Color(0xFF0D0E0F) else m.t.muted) }
        }
        cat.moveGroups.forEach { g ->
            val on = g.id == group && query.isBlank()
            Box(Modifier.heightIn(min = 48.dp).press { group = g.id; query = "" }.semantics { selected = on; role = Role.Tab }, contentAlignment = Alignment.Center) {
                Box(Modifier.height(32.dp).clip(RoundedCornerShape(16.dp)).background(if (on) m.t.ink else m.t.surface2).padding(horizontal = 13.dp), contentAlignment = Alignment.Center) {
                    T(g.label, m.type.body.copy(fontSize = 13.sp, fontWeight = FontWeight.SemiBold), if (on) Color(0xFF0D0E0F) else m.t.muted, maxLines = 1)
                }
            }
        }
    }
    if (searching) {
        Box(Modifier.padding(horizontal = 16.dp, vertical = 4.dp).fillMaxWidth().height(44.dp).clip(RoundedCornerShape(22.dp)).background(m.t.surface2).padding(horizontal = 16.dp), contentAlignment = Alignment.CenterStart) {
            BasicTextField(query, { query = it.take(40) }, Modifier.fillMaxWidth(), singleLine = true, textStyle = m.type.body.copy(fontSize = 14.sp, color = m.t.ink), cursorBrush = SolidColor(m.t.accent),
                decorationBox = { inner -> if (query.isEmpty()) T("Search ${cat.moves.size} moves", m.type.body.copy(fontSize = 14.sp), m.t.muted); inner() })
        }
    }
    LazyVerticalGrid(GridCells.Fixed(if (wide) 4 else 2), Modifier.weight(1f).fillMaxWidth(), contentPadding = PaddingValues(16.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        if (moves.isEmpty()) item(span = { GridItemSpan(maxLineSpan) }) { T("No move by that name", m.type.tiny, m.t.muted) }
        items(moves, key = { it.id }) { mv ->
            val on = mv.id in inPrompt
            Column(Modifier.press { onMove(mv) }.semantics(mergeDescendants = true) { role = Role.Button; selected = on; contentDescription = "Add ${mv.label}" }) {
                Box(Modifier.fillMaxWidth().picked(on, m.t.accent)) {
                    PreviewTile(Preview(loop = mv.loop, draw = PreviewDraw.Move(mv.id, mv.category)), Modifier.fillMaxWidth().aspectRatio(1.12f).clip(RoundedCornerShape(10.dp))) {
                        if (d.speaking == true && mv.talkSafe) Row(Modifier.align(Alignment.TopStart).padding(8.dp).height(20.dp).clip(RoundedCornerShape(10.dp)).background(Color(0xBD0D0E0F))
                            .border(1.dp, Color.White.copy(alpha = .08f), RoundedCornerShape(10.dp)).padding(horizontal = 7.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            SIc("talk", 11.dp, Color(0xFFECEAE5)); T("TALK-SAFE", m.type.mono.copy(fontSize = 9.5.sp, letterSpacing = .06.em), Color(0xFFECEAE5), maxLines = 1)
                        }
                        if (on) CheckBadge()
                    }
                }
                T(mv.label, m.type.body.copy(fontSize = 14.sp, fontWeight = FontWeight.SemiBold), m.t.ink, Modifier.padding(top = 6.dp, start = 3.dp), maxLines = 1)
                if (mv.editorBetter) T("Better done in Edit", m.type.body.copy(fontSize = 12.sp), m.t.muted, Modifier.padding(start = 3.dp), maxLines = 1)
            }
        }
    }
}

/**
 * A grid tile of Style, Look and Lighting: the preview (with a swatch strip for palettes and stocks), the name and a short
 * caption. The first tile of every grid is Auto.
 */
@Composable
fun PickTile(name: String, caption: String, preview: Preview, on: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier, aspect: Float = 1.3f) {
    val m = muse
    Column(modifier.press(onClick = onClick).semantics(mergeDescendants = true) { role = Role.Button; selected = on; contentDescription = name }) {
        Box(Modifier.fillMaxWidth().picked(on, m.t.accent)) {
            Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp))) {
                PreviewTile(preview, Modifier.fillMaxWidth().aspectRatio(aspect)) { if (on) CheckBadge() }
                if (preview.swatches.isNotEmpty()) SwatchStrip(preview.swatches)
            }
        }
        T(name, m.type.body.copy(fontSize = 14.sp, fontWeight = FontWeight.SemiBold), m.t.ink, Modifier.padding(top = 6.dp, start = 3.dp), maxLines = 1)
        if (caption.isNotBlank()) T(caption, m.type.body.copy(fontSize = 12.sp, lineHeight = 15.sp), m.t.muted, Modifier.padding(start = 3.dp), maxLines = 1)
    }
}

/** A grid of tiles that scrolls in the sheet: Auto first, then [items]. */
@Composable
fun ColumnScope.TileGrid(wide: Boolean, header: (@Composable () -> Unit)? = null, content: androidx.compose.foundation.lazy.grid.LazyGridScope.() -> Unit) {
    LazyVerticalGrid(GridCells.Fixed(if (wide) 4 else 2), Modifier.weight(1f).fillMaxWidth(), contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        if (header != null) item(span = { GridItemSpan(maxLineSpan) }) { header() }
        content()
    }
}


package studio.muse.app.ui.screens.suite

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.flow.update
import kotlinx.serialization.json.Json
import studio.muse.app.data.CameraCatalog
import studio.muse.app.data.SuiteOption
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.components.Chip
import studio.muse.app.ui.components.Cta
import studio.muse.app.ui.components.FlowRow
import studio.muse.app.ui.components.MuseSlider
import studio.muse.app.ui.components.Seg
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.TbBtn
import studio.muse.app.ui.components.Tiny
import studio.muse.app.ui.components.TopBar
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.ScreenBox
import studio.muse.app.ui.screens.camera.DirectedModePanel
import studio.muse.app.ui.theme.MuseTheme
import studio.muse.app.ui.theme.ThemeId
import studio.muse.app.ui.theme.muse

val BAG_TABS = listOf("Body", "Lens", "Optics", "Light", "Look", "Move", "Angle")
private val FILTERS = listOf("all" to "All", "ugc" to "UGC", "cinematic" to "Cinematic", "energy" to "Energy", "subtle" to "Subtle")

/**
 * M3 / M3d / M4 · the camera bag: always the dark theme (decision 3), whatever the app's theme. Preset: rig (body, lens,
 * optics), light and look from the real hardware renders, the 16-move library (filters, Mix 2/2, intensity and speed) and
 * the angle. Directed · Blender hosts workstream 2's panel. Apply to shot puts the bag into the Shot.
 */
@Composable
fun CameraBagScreen(startTab: String) {
    MuseTheme(ThemeId.B) { CameraBagContent(startTab) }
}

@Composable
private fun CameraBagContent(startTab: String) {
    val c = LocalContainer.current
    val nav = LocalNav.current
    val m = muse
    val store = c.suite
    val cat by store.catalog.collectAsState()
    val bag0 by store.bag.collectAsState()
    LaunchedEffect(Unit) {
        if (store.catalog.value == null) store.load()
        if (store.bag.value == null) store.bag.value = store.shot.value.camera
    }
    val bag = bag0 ?: store.shot.value.camera
    val cam = cat?.camera ?: CameraCatalog()
    var tab by remember { mutableStateOf(BAG_TABS.firstOrNull { it.equals(startTab, true) } ?: "Body") }
    var mode by remember { mutableStateOf(if (bag.directed != null) "directed" else "preset") }
    fun edit(f: (CameraDraft) -> CameraDraft) = store.bag.update { f(it ?: store.shot.value.camera) }
    fun apply() { store.shot.update { it.copy(camera = store.bag.value ?: it.camera) }; nav.back() }
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar("Camera") {
                Box(Modifier.size(44.dp).press { nav.back() }.semantics { contentDescription = "Close" }, contentAlignment = Alignment.Center) { SIc("close", 22.dp, m.t.ink) }
            }
            Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Seg(listOf("preset" to "Preset", "directed" to "Directed · Blender"), mode, { mode = it }, Modifier.fillMaxWidth())
                if (mode == "preset") TextTabs(BAG_TABS, tab, { tab = it })
            }
            Box(Modifier.weight(1f).fillMaxWidth()) {
                Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = if (tab == "Move") 230.dp else 24.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    if (mode == "directed") {
                        DirectedModePanel(store.shot.value.title.ifBlank { "Shot" }) { json ->
                            edit { it.copy(directed = runCatching { Json.parseToJsonElement(json) }.getOrNull()) }
                            apply()
                        }
                    } else when (tab) {
                        "Body" -> { RigPlate(bag, cam); Shelf("Camera bodies", cam.bodies, bag.body) { id -> edit { it.copy(body = id) } }; Shelf("Lenses", cam.lenses, bag.lens) { id -> edit { it.copy(lens = id) } } }
                        "Lens" -> {
                            RigPlate(bag, cam)
                            Shelf("Lenses", cam.lenses, bag.lens) { id -> edit { it.copy(lens = id) } }
                            SLbl("Focal length")
                            FlowRow { cam.focalLengths.forEach { f -> Chip("$f mm", bag.focalMm == f, { edit { it.copy(focalMm = f) } }) } }
                        }
                        "Optics" -> {
                            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                cam.optics.forEach { o -> HwCard(o.render, o.name, o.caption, false, Modifier.weight(1f), 150.dp) {} }
                            }
                            SLbl("Aperture")
                            FlowRow { cam.apertures.forEach { a -> Chip(CameraDraft.tStop(a.id), bag.aperture == a.id, { edit { it.copy(aperture = a.id) } }) } }
                            cam.apertures.firstOrNull { it.id == bag.aperture }?.let { Tiny(it.description) }
                            SLbl("Shutter")
                            FlowRow { cam.shutters.forEach { s -> Chip(s.label, (bag.shutter ?: "normal") == s.id, { edit { it.copy(shutter = s.id.takeIf { x -> x != "normal" }) } }) } }
                        }
                        "Light" -> Shelf("Lighting", cam.lighting, bag.lighting, big = true) { id -> edit { it.copy(lighting = id) } }
                        "Look" -> {
                            Shelf("Colour palettes", cam.palettes, bag.palette, big = true) { id -> edit { it.copy(palette = id) } }
                            Shelf("Film / sensor", cam.looks, bag.look) { id -> edit { it.copy(look = id) } }
                        }
                        "Move" -> MoveLibrary(bag, cam) { f -> edit(f) }
                        else -> {
                            SLbl("Height")
                            FlowRow { cam.heights.forEach { h -> Chip(h.label, bag.height == h.id, { edit { it.copy(height = h.id) } }) } }
                            SLbl("Shot size")
                            FlowRow { cam.shotSizes.forEach { s -> Chip(s.label, bag.shotSize == s.id, { edit { it.copy(shotSize = s.id) } }) } }
                        }
                    }
                }
                if (mode == "preset" && tab == "Move") MoveSheet(bag, cam, Modifier.align(Alignment.BottomCenter)) { f -> edit(f) }
            }
            if (mode == "preset") Box(Modifier.fillMaxWidth().navigationBarsPadding().padding(start = 16.dp, end = 16.dp, top = 6.dp, bottom = 12.dp)) {
                Cta("Apply to shot", { apply() }, Modifier.fillMaxWidth())
            }
        }
    }
}

/** The big rig plate: the body and the lens side by side, "Super 35 + Anamorphic 2×" and its look caption. */
@Composable
private fun RigPlate(bag: CameraDraft, cam: CameraCatalog) {
    val m = muse
    val body = cam.bodies.firstOrNull { it.id == bag.body }
    val lens = cam.lenses.firstOrNull { it.id == bag.lens }
    Box(Modifier.fillMaxWidth().height(176.dp).clip(RoundedCornerShape(m.t.r)).background(Color(0xFF16181A))) {
        Row(Modifier.fillMaxSize()) {
            HardwareImage(body?.render, Modifier.weight(1f).fillMaxHeight(), sample = 2)
            HardwareImage(lens?.render, Modifier.weight(1f).fillMaxHeight(), sample = 2)
        }
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Transparent, Color.Transparent, Color.Black.copy(alpha = .75f)))))
        Column(Modifier.align(Alignment.BottomStart).padding(12.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(listOfNotNull(body?.let { CameraDraft.short(it.title) }, lens?.title).joinToString(" + ").ifBlank { "Your rig" }, m.type.body.copy(fontSize = 14.sp, fontWeight = FontWeight.SemiBold), Color(0xFFECEAE5), maxLines = 1)
            T(listOfNotNull(body?.caption?.split(" · ")?.take(3)?.joinToString(" · "), bag.focalMm?.let { "$it mm" }, bag.aperture?.let { CameraDraft.tStop(it) }).joinToString(" · "),
                m.type.mono.copy(fontSize = 10.5.sp), Color(0xFFA9A6A0), maxLines = 1)
        }
    }
}

/** A swipeable shelf of hardware ("CAMERA BODIES · 10 · swipe"). Options without a render show as text cards. */
@Composable
private fun Shelf(title: String, items: List<SuiteOption>, selected: String?, big: Boolean = false, onPick: (String) -> Unit) {
    if (items.isEmpty()) return
    val m = muse
    // Hardware first (the renders), then the rest of the catalog's options.
    val list = items.sortedBy { if (it.render != null) 0 else 1 }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.fillMaxWidth()) { SLbl(title, Modifier.weight(1f)); Tiny("${list.size} · swipe") }
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.Top) {
            list.forEach { o -> HwCard(o.render, o.title, o.caption ?: o.description, o.id == selected, Modifier.width(if (big) 140.dp else 96.dp), if (big) 120.dp else 96.dp) { onPick(o.id) } }
        }
    }
}

@Composable
private fun HwCard(render: String?, title: String, caption: String, on: Boolean, modifier: Modifier, imgH: androidx.compose.ui.unit.Dp, onClick: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(m.t.r)
    Column(modifier.press(onClick = onClick).semantics(mergeDescendants = true) { contentDescription = title + if (on) ", in the bag" else "" }, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.fillMaxWidth().height(imgH).clip(shape).border(if (on) 2.dp else 0.dp, if (on) m.t.accent else Color.Transparent, shape)) {
            if (render != null) HardwareImage(render, Modifier.fillMaxSize(), sample = 4)
            else Box(Modifier.fillMaxSize().background(m.t.surface2), contentAlignment = Alignment.Center) { T(title, m.type.tiny, m.t.muted, maxLines = 2) }
            if (on) Row(Modifier.padding(6.dp).clip(RoundedCornerShape(999.dp)).background(m.t.accent).padding(horizontal = 7.dp, vertical = 2.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                SIc("check", 11.dp, m.t.accentInk); T("IN", m.type.mono.copy(fontSize = 10.sp, fontWeight = FontWeight.Bold), m.t.accentInk)
            }
        }
        T(title, m.type.body.copy(fontSize = 13.sp, fontWeight = FontWeight.SemiBold, lineHeight = 16.sp), m.t.ink, maxLines = 2)
        T(caption, m.type.mono.copy(fontSize = 10.sp, lineHeight = 13.sp), m.t.muted, maxLines = 3)
    }
}

/** M4 · the 16-move library: filter chips, Mix n/2, numbered picks. */
@Composable
private fun MoveLibrary(bag: CameraDraft, cam: CameraCatalog, edit: ((CameraDraft) -> CameraDraft) -> Unit) {
    val m = muse
    val c = LocalContainer.current
    var filter by remember { mutableStateOf("all") }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Row(Modifier.weight(1f).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            FILTERS.filter { (k, _) -> k == "all" || cam.library.any { it.tag == k } }.forEach { (k, l) -> Chip(l, filter == k, { filter = k }) }
        }
        Spacer(Modifier.width(8.dp))
        SBadge(bag.mixLabel, if (bag.moves.size >= 2) "busy" else "")
    }
    val list = cam.library.filter { filter == "all" || it.tag == filter }
    list.chunked(2).forEach { row ->
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            row.forEach { mv ->
                val n = bag.moves.indexOfFirst { it.id == mv.id }
                val on = n >= 0
                Column(Modifier.weight(1f).border(if (on) 2.dp else 1.dp, if (on) m.t.ink else m.t.line, RoundedCornerShape(m.t.r)).clip(RoundedCornerShape(m.t.r))
                    .background(m.t.surface).press {
                        val (next, msg) = bag.toggleMove(mv.id, cam)
                        edit { next }
                        msg?.let { c.repo.toast(it) }
                    }.semantics(mergeDescendants = true) { contentDescription = mv.label + if (on) ", move ${n + 1}" else "" }) {
                    Box(Modifier.fillMaxWidth().height(66.dp).background(if (on) m.t.surface2 else m.t.surface)) {
                        MovePictogram(mv.id, mv.category, Modifier.fillMaxSize().padding(6.dp))
                        if (on) Box(Modifier.padding(6.dp).size(20.dp).background(m.t.accent), contentAlignment = Alignment.Center) {
                            T("${n + 1}", m.type.mono.copy(fontSize = 10.sp, fontWeight = FontWeight.Bold), m.t.accentInk)
                        }
                    }
                    Row(Modifier.fillMaxWidth().padding(horizontal = 9.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically) {
                        T(mv.label, m.type.body.copy(fontSize = 13.sp, fontWeight = FontWeight.Bold), m.t.ink, Modifier.weight(1f), maxLines = 1)
                        SBadge(mv.tag)
                    }
                }
            }
            if (row.size == 1) Spacer(Modifier.weight(1f))
        }
    }
}

/** The bottom sheet for the active move: "1 · Dolly in", Intensity 0–100 %, Speed Slow / Normal / Fast. */
@Composable
private fun MoveSheet(bag: CameraDraft, cam: CameraCatalog, modifier: Modifier, edit: ((CameraDraft) -> CameraDraft) -> Unit) {
    val m = muse
    val a = bag.activeMove
    Column(modifier.fillMaxWidth().clip(RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp)).background(m.t.surface).padding(horizontal = 16.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(Modifier.align(Alignment.CenterHorizontally).size(36.dp, 4.dp).clip(RoundedCornerShape(2.dp)).background(m.t.line))
        if (a == null) { Tiny("Pick up to two moves. Locked-off keeps the camera still."); return@Column }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            T("${bag.active + 1} · ${cam.moveLabel(a.id)}", m.type.h3, m.t.ink, Modifier.weight(1f), maxLines = 1)
            if (bag.moves.size > 1) bag.moves.indices.forEach { i ->
                Box(Modifier.padding(start = 6.dp).size(26.dp).background(if (i == bag.active) m.t.accent else m.t.surface2).press { edit { it.setActive(i) } }, contentAlignment = Alignment.Center) {
                    T("${i + 1}", m.type.mono.copy(fontSize = 11.sp), if (i == bag.active) m.t.accentInk else m.t.ink)
                }
            } else Tiny("loops in preview")
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            T("INTENSITY", m.type.mono.copy(fontSize = 10.5.sp), m.t.muted, Modifier.width(72.dp))
            MuseSlider(a.intensity, 0, 100, { v -> edit { it.tune(intensity = v) } }, Modifier.weight(1f))
            T("${a.intensity}%", m.type.mono.copy(fontSize = 12.sp), m.t.ink, Modifier.width(40.dp))
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            T("SPEED", m.type.mono.copy(fontSize = 10.5.sp), m.t.muted, Modifier.width(72.dp))
            Seg(listOf("slow" to "Slow", "normal" to "Normal", "fast" to "Fast"), a.speed, { s -> edit { it.tune(speed = s) } }, Modifier.weight(1f), small = true)
        }
    }
}

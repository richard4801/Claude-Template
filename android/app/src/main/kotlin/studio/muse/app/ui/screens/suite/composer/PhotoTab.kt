package studio.muse.app.ui.screens.suite.composer

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import studio.muse.app.data.ImageRef
import studio.muse.app.data.PhotoAspectOption
import studio.muse.app.data.PhotoRules
import studio.muse.app.data.ShootRef
import studio.muse.app.data.Take
import studio.muse.app.data.UpscaleOffer
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.components.RefImage
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.suite.SIc
import studio.muse.app.ui.screens.suite.useAsStartFrame
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.radii
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale

// The Photo tab on Android (owner-approved 2026-11-14, plans/design/photo/; the Mac's PhotoTab.swift):
// - The stage: empty until this session's run (never an older result); the run's photos large with a strip under them,
//   Keep the one highlighted action, then Redo, Upscale, Use in Shot and Share.
// - The panel: Inputs (Character, Outfit, Product, References) with clear empty slots, then the Rig for a still
//   (Framing, Lens, Light, Look, Style); a preset locks Framing, Lens and Light to "From preset".
// - The bar: a compact Preset chip, the 1–4 count, the Size pill (from the estimate), and the model "Auto · <name>".

// ---------------------------------------------------------------- the stage

/** The stage: this session's run, or the empty state (four dashed photo shapes, "Your photos appear here"). */
@Composable
fun PhotoStage(ui: ComposerUi, modifier: Modifier, wide: Boolean) {
    val c = LocalContainer.current
    val m = muse
    val run by c.suite.photo.lastRun.collectAsState()
    val busy = ui.photo?.busy == true
    val count = ui.photo?.draft?.count ?: PhotoRules.DEFAULT_COUNT
    Column(modifier.semantics { contentDescription = if (run.isEmpty()) "Photo stage, empty" else "Photo stage, ${run.size} photos" }) {
        if (run.isEmpty() || busy) {
            Column(Modifier.fillMaxWidth().weight(1f, fill = true), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    repeat(4) { i ->
                        val on = busy && i < count
                        Box(Modifier.size(if (wide) 56.dp else 40.dp, if (wide) 70.dp else 50.dp).clip(RoundedCornerShape(4.dp))
                            .background(if (on) m.roles.raised else Color.Transparent).dashed(m.roles.ink2.copy(alpha = .5f)))
                    }
                }
                Spacer(Modifier.height(14.dp))
                T(if (busy) "Making ${PhotoRules.noun(count)}…" else "Your photos appear here", m.scale.label.copy(fontWeight = FontWeight.SemiBold), m.roles.ink, maxLines = 1)
                Spacer(Modifier.height(4.dp))
                T(if (busy) "They land here when they're ready" else "1 to ${PhotoRules.MAX_COUNT} photos per run", m.scale.caption, m.roles.ink2, maxLines = 1)
            }
            return@Column
        }
        PhotoResults(ui, run, wide, Modifier.fillMaxWidth().weight(1f, fill = true))
    }
}

@Composable
private fun PhotoResults(ui: ComposerUi, run: List<Take>, wide: Boolean, modifier: Modifier) {
    val c = LocalContainer.current
    val nav = LocalNav.current
    val m = muse
    val scope = rememberCoroutineScope()
    var at by remember(run.firstOrNull()?.id) { mutableIntStateOf(0) }
    val take = run[at.coerceIn(0, run.lastIndex)]
    Column(modifier, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                T(take.shownTitle.removePrefix("Photo · "), m.scale.label.copy(fontWeight = FontWeight.SemiBold), m.roles.ink, maxLines = 1)
                T(if (run.size > 1) "Photo ${at + 1} of ${run.size}" else "Photo", m.scale.caption, m.roles.ink2, maxLines = 1)
            }
        }
        // Owner decision 2 (suite redesign): the actions above the picture, Keep the one highlighted action. Their words
        // show when the stage is wide enough for all of them (icons with their labels for TalkBack otherwise).
        androidx.compose.foundation.layout.BoxWithConstraints(Modifier.fillMaxWidth()) {
        val words = wide && maxWidth >= 520.dp
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
            StageAction("arrow-clockwise", "Redo", words) { ui.photo?.generate?.invoke() }
            StageAction("arrows-out-simple", "Upscale", words, enabled = UpscaleOffer.canUpscale(take, c.repo.demo)) { c.suite.openUpscale(take.id) }
            StageAction("video-camera", "Use in Shot", words) { c.suite.useAsStartFrame(take); nav.go(Routes.suiteCompose("shot")) }
            StageAction("export", "Share", words) { nav.go(Routes.post(take.id)) }
            Spacer(Modifier.weight(1f))
            StageAction("check", if (take.final) "Kept" else "Keep", true, highlight = true) {
                scope.launch {
                    c.repo.setTakeStatus(take.id, if (take.final) "test" else "final")
                    c.suite.photo.replaceTake(take.copy(status = if (take.final) "test" else "final"))
                }
            }
        }
        }
        Box(Modifier.fillMaxWidth().weight(1f, fill = true), contentAlignment = Alignment.Center) {
            RefImage(take.thumb, Modifier.aspectRatio(photoRatio(ui.photo?.draft?.shownAspect)).clip(RoundedCornerShape(4.dp))
                .press { nav.go(Routes.result(take.id)) }.semantics { contentDescription = "${take.shownTitle}, open"; role = Role.Button }, 4)
        }
        if (run.size > 1) Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally), verticalAlignment = Alignment.CenterVertically) {
            run.forEachIndexed { i, t ->
                val on = i == at
                Box(Modifier.size(40.dp, 50.dp).alpha(if (on) 1f else .7f).clip(RoundedCornerShape(4.dp))
                    .let { if (on) it.border(2.dp, m.roles.ink, RoundedCornerShape(4.dp)) else it }
                    .press { at = i }.semantics { selected = on; role = Role.Tab; contentDescription = "Photo ${i + 1} of ${run.size}" }) {
                    RefImage(t.thumb, Modifier.fillMaxSize(), 4)
                }
            }
            T("${at + 1} of ${run.size}", m.scale.caption, m.roles.ink2, Modifier.padding(start = 4.dp), maxLines = 1)
        }
    }
}

@Composable
private fun StageAction(icon: String, label: String, words: Boolean, enabled: Boolean = true, highlight: Boolean = false, onClick: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(m.radii.control)
    Row(Modifier.heightIn(min = 48.dp).alpha(if (enabled) 1f else .45f).press(enabled = enabled, onClick = onClick)
        .semantics(mergeDescendants = true) { role = Role.Button; contentDescription = label },
        verticalAlignment = Alignment.CenterVertically) {
        Row(Modifier.height(36.dp).clip(shape).let { if (highlight) it.background(m.roles.raised).border(1.dp, if (m.isA) m.roles.ink.copy(alpha = .35f) else m.roles.action, shape) else it }
            .padding(horizontal = if (words || highlight) 10.dp else 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            val tint = if (highlight && !m.isA) m.roles.action else m.roles.ink
            SIc(icon, 16.dp, tint)
            if (words || highlight) T(label, m.scale.label.copy(fontWeight = if (highlight) FontWeight.SemiBold else FontWeight.Normal), tint, maxLines = 1)
        }
    }
}

/** "4:5" → 0.8 (the photo's shape on the stage); anything unreadable is 4:5. */
private fun photoRatio(a: String?): Float = a?.split(":")?.mapNotNull { it.trim().toFloatOrNull() }?.takeIf { it.size == 2 && it[0] > 0f && it[1] > 0f }?.let { it[0] / it[1] } ?: .8f

/** A dashed outline (the empty slots and the stage's empty photo shapes). */
private fun Modifier.dashed(color: Color): Modifier = drawBehind {
    drawRoundRect(color, style = Stroke(width = 1.2.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 3.dp.toPx()))),
        cornerRadius = androidx.compose.ui.geometry.CornerRadius(4.dp.toPx()))
}

// ---------------------------------------------------------------- the panel

/** Inputs, then the Rig for a still. */
@Composable
fun PhotoPanel(ui: ComposerUi) {
    val m = muse
    Column(Modifier.fillMaxWidth()) {
        T("Inputs", m.scale.title, m.roles.ink, maxLines = 1)
        PhotoInputRows(ui)
        T("Rig", m.scale.title, m.roles.ink, Modifier.padding(top = 16.dp), maxLines = 1)
        PhotoRigRows(ui)
    }
}

/** Character, Outfit, Product (optional) and References (optional): each an empty slot with a clear plus, or its value. */
@Composable
fun PhotoInputRows(ui: ComposerUi) {
    val c = LocalContainer.current
    val store = c.suite.photo
    val p by store.draft.collectAsState()
    val scope = rememberCoroutineScope()
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            val media = c.media ?: return@launch c.repo.toast("Couldn't read that photo")
            val bytes = media.bytes(uri) ?: return@launch c.repo.toast("Couldn't read that photo")
            store.upload("product", media.displayName(uri), bytes, media.mime(uri).takeIf { it.startsWith("image/") } ?: "image/jpeg")
        }
    }
    val outfit = ui.outfits.firstOrNull { it.id == ui.d.characterOutfit }
    val guide = p.refs.firstOrNull()?.guides?.firstOrNull()?.let { g -> when (g) { "pose" -> "Pose"; "look" -> "Look"; "scene" -> "Scene"; else -> g } }
    Column(Modifier.fillMaxWidth()) {
        InputRow("user", "Character", ui.lead?.name?.substringBefore(' '), ui.lead?.cover, add = "Pick a character", needed = ui.lead == null, round = true) {
            ui.open(ComposerSheet(SheetKind.CHARACTER))
        }
        InputRow("t-shirt", "Outfit", outfit?.name, outfit?.front, add = "Add outfit", enabled = ui.lead != null) { ui.open(ComposerSheet(SheetKind.CHARACTER)) }
        InputRow("package", "Product", if (p.uploading == "product") "Uploading…" else p.product?.let { "Product" }, p.product, add = "Add product",
            onClear = if (p.product != null) store::clearProduct else null) {
            if (p.product == null) pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
        }
        InputRow("images", "References", if (p.uploading == "ref") "Uploading…" else guide, p.refs.firstOrNull()?.image, add = "Add up to ${ShootRef.MAX}",
            detail = p.refs.takeIf { it.isNotEmpty() }?.let { "${it.size} of ${ShootRef.MAX}" }) { ui.open(ComposerSheet(SheetKind.REFERENCES)) }
    }
}

@Composable
private fun InputRow(icon: String, name: String, value: String?, thumb: ImageRef?, add: String, needed: Boolean = false, round: Boolean = false,
                     enabled: Boolean = true, detail: String? = null, onClear: (() -> Unit)? = null, onClick: () -> Unit) {
    val m = muse
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).alpha(if (enabled) 1f else .5f)
        .drawBehind { drawLine(m.roles.hairline, Offset(0f, size.height), Offset(size.width, size.height), 1.dp.toPx()) }
        .press(enabled = enabled, onClick = onClick).semantics(mergeDescendants = true) { role = Role.Button; contentDescription = "$name: ${value ?: add}" },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        SIc(icon, 20.dp, m.roles.ink2)
        T(name, m.scale.label, m.roles.ink2, Modifier.widthIn(min = 86.dp), maxLines = 1)
        Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (value != null) {
                if (thumb != null) RefImage(thumb, Modifier.size(24.dp).clip(if (round) RoundedCornerShape(999.dp) else RoundedCornerShape(4.dp)), 4)
                T(value, m.scale.label.copy(fontWeight = FontWeight.Medium), m.roles.ink, Modifier.weight(1f, fill = false), maxLines = 1)
            } else {
                Box(Modifier.size(24.dp).dashed(m.roles.ink2), contentAlignment = Alignment.Center) { SIc("plus", 14.dp, m.roles.ink) }
                T(add, m.scale.label.copy(fontWeight = FontWeight.Medium, textDecoration = if (needed) TextDecoration.Underline else null), m.roles.ink,
                    Modifier.weight(1f, fill = false), maxLines = 1)
            }
            detail?.let { T(it, m.scale.label, m.roles.ink2, maxLines = 1) }
        }
        if (onClear != null) Box(Modifier.size(40.dp).press(onClick = onClear).semantics { contentDescription = "Remove the $name"; role = Role.Button },
            contentAlignment = Alignment.Center) { SIc("x", 14.dp, m.roles.ink2) }
        else SIc("caret-down", 14.dp, m.roles.ink2)
    }
}

/** The Rig for a still: Framing (shot size), Lens (focal, aperture), Light, Look and Style; no movement, tempo or length. */
@Composable
fun PhotoRigRows(ui: ComposerUi) {
    val m = muse
    val s = ui.d.settings
    val cat = ui.cat
    val preset = ui.photo?.draft?.presetId != null
    fun lab(list: List<studio.muse.app.data.SuiteOption>, id: String?) = id?.let { v -> list.firstOrNull { it.id == v }?.label }
    val rows = listOf(
        PhotoRig("frame-corners", "Framing", SheetKind.CAMERA, "angle", listOfNotNull(lab(cat.shotSizes, s.shotSize), lab(cat.heights, s.height)), locked = preset),
        PhotoRig("aperture", "Lens", SheetKind.CAMERA, "setup", listOfNotNull(s.focalMm?.let { "$it mm" }, lab(cat.apertures, s.aperture), lab(cat.lenses, s.lens), lab(cat.bodies, s.body)), locked = preset),
        PhotoRig("sun", "Light", SheetKind.LIGHTING, "", listOfNotNull(lab(cat.lighting, s.lighting)), locked = preset),
        PhotoRig("palette", "Look", SheetKind.LOOK, "", listOfNotNull(lab(cat.palettes, s.palette), lab(cat.looks, s.stock)), auto = "House grade"),
        PhotoRig("sliders-horizontal", "Style", SheetKind.STYLE, "", listOfNotNull(lab(cat.genres, s.genre), lab(cat.eras, s.era))),
    )
    Column(Modifier.fillMaxWidth()) {
        rows.forEach { r ->
            val directed = ui.d.directed != null && r.tab.isNotEmpty()
            val value = when { r.locked -> "From preset"; directed -> "Directed"; r.values.isEmpty() -> r.auto; else -> r.values.joinToString(" · ") }
            val quiet = r.locked || (r.values.isEmpty() && !directed)
            Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).alpha(if (r.locked) .55f else 1f)
                .drawBehind { drawLine(m.roles.hairline, Offset(0f, size.height), Offset(size.width, size.height), 1.dp.toPx()) }
                .press(enabled = !r.locked) { ui.open(ComposerSheet(r.sheet, r.tab)) }
                .semantics(mergeDescendants = true) { role = Role.Button; contentDescription = "${r.name}: $value" },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                SIc(r.icon, 20.dp, m.roles.ink2)
                T(r.name, m.scale.label, m.roles.ink2, Modifier.widthIn(min = 86.dp), maxLines = 1)
                T(value, m.scale.label.copy(fontWeight = if (quiet) FontWeight.Normal else FontWeight.Medium), if (quiet) m.roles.ink2 else m.roles.ink,
                    Modifier.weight(1f), maxLines = 1)
                SIc(if (r.locked) "lock" else "caret-down", 14.dp, m.roles.ink2)
            }
        }
    }
}

private data class PhotoRig(val icon: String, val name: String, val sheet: SheetKind, val tab: String, val values: List<String>,
                            val locked: Boolean = false, val auto: String = "Auto")

// ---------------------------------------------------------------- the bar

/** "Preset": a small menu of the photo presets (search, covers); picked, the chip shows its name, outlined. */
@Composable
fun PhotoPresetChip(ui: ComposerUi) {
    val c = LocalContainer.current
    val nav = LocalNav.current
    val m = muse
    val st by c.repo.state.collectAsState()
    val p by c.suite.photo.draft.collectAsState()
    var open by remember { mutableStateOf(false) }
    var query by remember { mutableStateOf("") }
    val picked = st.templates.firstOrNull { it.id == p.presetId }
    val shape = RoundedCornerShape(m.radii.control)
    Box {
        Row(Modifier.heightIn(min = 48.dp).press { open = true; if (c.repo.state.value.templates.isEmpty()) scope(c) }
            .semantics(mergeDescendants = true) { role = Role.Button; contentDescription = picked?.let { "Preset: ${it.name}" } ?: "Preset: none" },
            verticalAlignment = Alignment.CenterVertically) {
            Row(Modifier.height(36.dp).clip(shape).background(if (picked != null) m.roles.raised else m.roles.field)
                .let { if (picked != null) it.border(1.dp, m.roles.action, shape) else it }.padding(horizontal = 10.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                SIc("images", 16.dp, m.roles.ink2)
                T(picked?.name ?: "Preset", m.scale.label.copy(fontWeight = FontWeight.Medium), m.roles.ink, Modifier.widthIn(max = 140.dp), maxLines = 1)
                SIc("caret-down", 12.dp, m.roles.ink2)
            }
        }
        DropdownMenu(open, { open = false }, Modifier.width(320.dp).background(m.roles.raised)) {
            Column(Modifier.padding(horizontal = 12.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                androidx.compose.foundation.text.BasicTextField(query, { query = it }, singleLine = true, textStyle = m.scale.label.copy(color = m.roles.ink),
                    modifier = Modifier.fillMaxWidth().clip(shape).background(m.roles.field).padding(horizontal = 10.dp, vertical = 10.dp),
                    decorationBox = { inner -> Box { if (query.isEmpty()) T("Search presets", m.scale.label, m.roles.ink2, maxLines = 1); inner() } })
                val list = st.templates.filter { query.isBlank() || it.name.contains(query.trim(), ignoreCase = true) }
                if (st.templates.isEmpty()) T(if (st.loaded) "No photo presets yet · save one from any photo" else "Loading presets…", m.scale.caption, m.roles.ink2)
                list.chunked(3).forEach { row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        row.forEach { t ->
                            val on = t.id == p.presetId
                            Column(Modifier.width(92.dp).press { c.suite.photo.pickPreset(t.id); open = false }
                                .semantics(mergeDescendants = true) { selected = on; role = Role.Button; contentDescription = "Preset ${t.name}" },
                                verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Box(Modifier.fillMaxWidth().aspectRatio(.8f).clip(RoundedCornerShape(4.dp)).background(m.roles.field)
                                    .let { if (on) it.border(2.dp, m.roles.action, RoundedCornerShape(4.dp)) else it }) { RefImage(t.cover, Modifier.fillMaxSize(), 4) }
                                T(t.name, m.scale.caption, m.roles.ink, maxLines = 1)
                            }
                        }
                    }
                }
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.weight(1f).heightIn(min = 44.dp).press(enabled = p.presetId != null) { c.suite.photo.clearPreset(); open = false }, contentAlignment = Alignment.CenterStart) {
                        T("No preset: use the rig", m.scale.caption, if (p.presetId != null) m.roles.ink else m.roles.ink2, maxLines = 1)
                    }
                    Box(Modifier.heightIn(min = 44.dp).press { open = false; nav.go(Routes.TEMPLATES) }, contentAlignment = Alignment.CenterEnd) {
                        T("All templates", m.scale.caption, m.roles.link, maxLines = 1)
                    }
                }
            }
        }
    }
}

private fun scope(c: studio.muse.app.AppContainer) { c.scope.launch { c.repo.loadTemplates(quiet = true) } }

/** Photos 1–4 as a small segmented control. */
@Composable
fun PhotoCountControl(ui: ComposerUi, words: Boolean) {
    val m = muse
    val p = ui.photo ?: return
    val shape = RoundedCornerShape(m.radii.control)
    Row(Modifier.heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
        Row(Modifier.height(36.dp).clip(shape).background(m.roles.field).padding(2.dp), verticalAlignment = Alignment.CenterVertically) {
            Row(Modifier.padding(start = 6.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                SIc("stack", 16.dp, m.roles.ink2)
                if (words) T("Photos", m.scale.label, m.roles.ink2, maxLines = 1)
            }
            (1..PhotoRules.MAX_COUNT).forEach { n ->
                val on = n == p.draft.count
                Box(Modifier.size(width = 30.dp, height = 32.dp).clip(RoundedCornerShape(m.radii.control - 1.dp)).background(if (on) m.roles.raised else Color.Transparent)
                    .press { p.setCount(n) }.semantics { selected = on; role = Role.Tab; contentDescription = PhotoRules.noun(n) }, contentAlignment = Alignment.Center) {
                    T("$n", m.scale.label.copy(fontWeight = if (on) FontWeight.SemiBold else FontWeight.Medium), if (on) m.roles.ink else m.roles.ink2, maxLines = 1, align = TextAlign.Center)
                }
            }
        }
    }
}

/** Size: the photo's shape and what this model makes for it; hidden until the server lists the shapes. */
@Composable
fun PhotoSizePill(ui: ComposerUi) {
    val c = LocalContainer.current
    val p = ui.photo ?: return
    val seen by c.suite.photo.seenAspects.collectAsState()
    val options: List<PhotoAspectOption> = p.raw?.aspects?.ifEmpty { null } ?: seen
    if (options.isEmpty()) return
    val shown = p.draft.shownAspect
    MenuPill("frame-corners", shown, "Size", options.map { it.label to (it.id == shown) }) { i -> options.getOrNull(i)?.let { c.suite.photo.setAspect(it.id) } }
}

/** "Auto · Nano Banana": the model Auto picked (owner 2026-11-14); a model the owner pinned keeps its own name. */
@Composable
fun photoModelName(ui: ComposerUi): String? {
    val c = LocalContainer.current
    val seen by c.suite.photo.seenModel.collectAsState()
    val p = ui.photo ?: return null
    if (p.draft.imageModel != null) return null
    return (p.raw?.model?.name ?: seen)?.let { "Auto · $it" }
}

/** Why Generate can't go yet, shown beside it (never "Generate · —" alone). */
fun photoBlocker(ui: ComposerUi): String? = ui.photo?.let { p -> p.error ?: p.raw?.takeIf { !it.ok }?.let { it.warnings.firstOrNull() ?: "These photos can't be made as set" } }

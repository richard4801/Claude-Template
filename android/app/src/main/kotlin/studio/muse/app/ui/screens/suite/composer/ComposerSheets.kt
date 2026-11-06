package studio.muse.app.ui.screens.suite.composer

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import studio.muse.app.data.CameraCatalog
import studio.muse.app.data.SuiteCatalog
import studio.muse.app.data.SuiteEstimate
import studio.muse.app.data.SuiteMoveOption
import studio.muse.app.data.SuiteOption
import studio.muse.app.data.SuiteRules
import studio.muse.app.ui.components.MuseSlider
import studio.muse.app.ui.components.RefImage
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.Toggle
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.suite.InputSlotTile
import studio.muse.app.ui.screens.suite.InputSlots
import studio.muse.app.ui.screens.suite.RecastDraft
import studio.muse.app.ui.screens.suite.SIc
import studio.muse.app.ui.screens.suite.SlotId
import studio.muse.app.ui.screens.suite.SlotKind
import studio.muse.app.ui.theme.muse

// AI suite (workstream 1): every picker of the composer in the one shell — Camera, Style, Look, Lighting, References,
// Settings, the tool and preset browser (Change), the character, a prompt token's intensity and Recast's people.

/** What the sheets read and change. Everything applies at once; [close] dismisses the sheet. */
class SheetContext(
    val d: ComposerDraft,
    val catalog: SuiteCatalog?,
    val slots: InputSlots,
    val recast: RecastDraft,
    val models: List<studio.muse.app.data.Model>,
    val outfitsOf: (String?) -> List<studio.muse.app.data.Outfit>,
    val owner: Boolean,
    val wide: Boolean,
    val estimate: SuiteEstimate?,
    val blocker: String?,
    val tierEstimates: Map<String, SuiteEstimate?>,
    val update: ((ComposerDraft) -> ComposerDraft) -> Unit,
    val updateRecast: ((RecastDraft) -> RecastDraft) -> Unit,
    val setTab: (String) -> Unit,
    val open: (ComposerSheet) -> Unit,
    val close: () -> Unit,
    val onMove: (SuiteMoveOption) -> Unit,
    val onPickSlot: (SlotId) -> Unit,
    val onClearSlot: (SlotId) -> Unit,
    val onPickCharacter: (String?, String?) -> Unit,
    val onGenerate: () -> Unit,
    val onStoryboard: () -> Unit,
    /** Recast: where the clip's first frame comes from (null = no clip yet). */
    val frame: FrameSource? = null,
    /** Recast: a tap on the first frame → the person's index (null = full). */
    val onTapFace: (android.graphics.Bitmap, Float, Float) -> Int? = { _, _, _ -> null },
) {
    val cam: CameraCatalog get() = catalog?.camera ?: CameraCatalog()
}

@Composable
fun BoxScope.ComposerSheetHost(sheet: ComposerSheet, x: SheetContext) {
    val d = x.d
    val s = d.settings
    val cam = x.cam
    fun set(f: (ComposerSettings) -> ComposerSettings) = x.update { it.copy(settings = f(it.settings)) }
    when (sheet.kind) {
        SheetKind.CAMERA -> {
            val tabs = cameraTabs(s, x.owner, d.directed != null)
            val tab = sheet.tab.takeIf { t -> tabs.any { it.key == t } } ?: "setup"
            PickerShell("Camera", x.wide, x.close, tabs, tab, x.setTab, onReset = { set { it.reset(ComposerChip.CAMERA) }; x.update { it.copy(directed = null) } }) {
                CameraPickerBody(tab, d, cam, x.wide, x.owner, x.update, x.onMove)
            }
        }
        SheetKind.STYLE -> {
            val tabs = listOf(SheetTab("genre", "Genre", s.genre != null), SheetTab("era", "Era", s.era != null), SheetTab("tempo", "Tempo", s.tempo != null))
            val tab = sheet.tab.takeIf { t -> tabs.any { it.key == t } } ?: "genre"
            PickerShell("Style", x.wide, x.close, tabs, tab, x.setTab, onReset = { set { it.reset(ComposerChip.STYLE) } }) {
                val (list, cur, put) = when (tab) {
                    "era" -> Triple(cam.eras, s.era) { id: String? -> set { it.copy(era = id) } }
                    "tempo" -> Triple(cam.tempos, s.tempo) { id: String? -> set { it.copy(tempo = id) } }
                    else -> Triple(cam.genres, s.genre) { id: String? -> set { it.copy(genre = id) } }
                }
                OptionGrid(ComposerCatalog.visible(list), cur, x.wide, put, preview = { o, i -> Preview(STYLE_STILLS[i % STYLE_STILLS.size], o.loop, PreviewDraw.Word(o.label)) })
            }
        }
        SheetKind.LOOK -> {
            val tabs = listOf(SheetTab("palette", "Palette", s.palette != null), SheetTab("stock", "Film stock", s.stock != null))
            val tab = sheet.tab.takeIf { t -> tabs.any { it.key == t } } ?: "palette"
            PickerShell("Look", x.wide, x.close, tabs, tab, x.setTab, onReset = { set { it.reset(ComposerChip.LOOK) } }, footer = {
                Row(Modifier.fillMaxWidth().heightIn(min = 52.dp).press { set { it.copy(gradeLook = !it.gradeLook) } }.semantics(mergeDescendants = true) { role = Role.Switch; selected = s.gradeLook },
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Toggle(s.gradeLook, { set { it.copy(gradeLook = !it.gradeLook) } })
                    Column(Modifier.weight(1f)) {
                        T("Grade the take with this look", muse.type.body.copy(fontSize = 14.sp, fontWeight = FontWeight.SemiBold), muse.t.ink, maxLines = 1)
                        T("Exact colour, reversible in Edit", muse.type.body.copy(fontSize = 12.sp), muse.t.muted, maxLines = 1)
                    }
                }
            }) {
                val stock = tab == "stock"
                val list = ComposerCatalog.visible(if (stock) cam.looks else cam.palettes)
                OptionGrid(list, if (stock) s.stock else s.palette, x.wide, { id -> set { if (stock) it.copy(stock = id) else it.copy(palette = id) } },
                    header = "${list.size} ${if (stock) "film stocks" else "palettes"} · each with an exact grade", autoCaption = "Matches the scene",
                    autoSwatches = listOf("#2A2C2E", "#3A3D40", "#4B4F52", "#5D6165", "#707478"),
                    preview = { o, _ -> Preview(o.render, o.loop, if (o.render == null) PreviewDraw.Swatch(o.swatches) else null, o.swatches.ifEmpty { listOf("#222222", "#555555", "#888888", "#BBBBBB", "#EEEEEE") }) })
            }
        }
        SheetKind.LIGHTING -> PickerShell("Lighting", x.wide, x.close, onReset = { set { it.reset(ComposerChip.LIGHTING) } }) {
            OptionGrid(ComposerCatalog.visible(cam.lighting), s.lighting, x.wide, { id -> set { it.copy(lighting = id) } }, autoCaption = "Matches the scene",
                preview = { o, _ -> Preview(o.render, o.loop, PreviewDraw.Light(o.id)) })
        }
        SheetKind.REFERENCES -> PickerShell("References", x.wide, x.close) { ReferencesBody(x) }
        SheetKind.SETTINGS -> PickerShell("Settings", x.wide, x.close, heightFraction = .9f, footer = { SettingsFooter(x) }) { SettingsBody(x) }
        SheetKind.TOOLS -> PickerShell("Tools", x.wide, x.close) { ToolsBody(x) }
        SheetKind.CHARACTER -> PickerShell("Character", x.wide, x.close, heightFraction = .7f) { CharacterBody(x) }
        SheetKind.TOKEN -> {
            val tok = d.tokens.parts.firstOrNull { it.key == sheet.token && it !is PromptPart.Text }
            if (tok == null) { x.close(); return }
            PickerShell(PromptCodec.chipText(tok), x.wide, x.close, heightFraction = .42f) { TokenBody(tok, x) }
        }
        SheetKind.PEOPLE -> PickerShell("People", x.wide, x.close) { PeopleBody(x) }
    }
}

/** Placeholder stills for Style cards until their own stills are made (any render reads as a mood; the big type says what). */
private val STYLE_STILLS = listOf("palette-04-bleached-warm", "palette-02-teal-orange", "palette-05-sodium-decay", "light-02-contre-jour", "palette-03-hyper-neon",
    "palette-06-classic-bw", "light-05-practicals", "stock-02-16mm", "palette-01-naturalistic", "light-04-window", "body-10-super8", "light-01-soft-cross")

/** A grid of options with Auto first (null). */
@Composable
private fun ColumnScope.OptionGrid(
    list: List<SuiteOption>, current: String?, wide: Boolean, onPick: (String?) -> Unit, header: String? = null, autoCaption: String = "The engine decides",
    preview: (SuiteOption, Int) -> Preview, autoSwatches: List<String> = emptyList(),
) {
    val sel = current?.let { c -> list.firstOrNull { it.id == c }?.mergedInto ?: c }
    TileGrid(wide, header = header?.let { h -> { T(h, muse.type.body.copy(fontSize = 12.5.sp), muse.t.muted) } }) {
        item { PickTile("Auto", autoCaption, Preview(draw = PreviewDraw.Auto, swatches = autoSwatches), sel == null, { onPick(null) }) }
        items(list.size) { i -> val o = list[i]; PickTile(o.label, o.description, preview(o, i), sel == o.id, { onPick(o.id) }) }
    }
}

@Composable
private fun ColumnScope.ReferencesBody(x: SheetContext) {
    val m = muse
    val inputs = x.catalog?.tier(x.d.quality)?.slots ?: studio.muse.app.data.SuiteInputs.NONE
    val kinds = listOf(SlotKind.IMAGE, SlotKind.VIDEO, SlotKind.AUDIO, SlotKind.MIDDLE).filter { it.capacity(inputs) > 0 }
    Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        if (kinds.isEmpty()) T("${SuiteRules.tierLabel(x.d.quality)} doesn't take references · try another quality", m.type.body.copy(fontSize = 14.sp), m.t.muted)
        kinds.forEach { k ->
            val ids = x.slots.visible(inputs).filter { it.kind == k }
            SheetLabel(when (k) { SlotKind.IMAGE -> "Images"; SlotKind.VIDEO -> "Clips"; SlotKind.AUDIO -> "Audio"; else -> "Middle frames" }, k.caption(inputs))
            ids.chunked(3).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    row.forEach { id -> InputSlotTile(id, x.slots[id], { x.onPickSlot(id) }, { x.onClearSlot(id) }, Modifier.weight(1f).aspectRatio(1f)) }
                    repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
                }
            }
        }
        x.slots.note(inputs)?.let { T(it, m.type.tiny, m.t.muted) }
    }
}

@Composable
private fun ColumnScope.SettingsBody(x: SheetContext) {
    val m = muse
    val d = x.d
    val tiers = x.catalog?.tiers?.ifEmpty { null } ?: SuiteRules.TIERS.map { studio.muse.app.data.SuiteTier(it, SuiteRules.tierLabel(it), available = true) }
    Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        SheetLabel("Quality", "per ${d.duration} s take", Modifier.padding(top = 4.dp, bottom = 4.dp))
        tiers.forEach { t ->
            val on = t.id == d.quality
            val e = x.tierEstimates[t.id]
            Row(Modifier.fillMaxWidth().heightIn(min = 52.dp).clip(RoundedCornerShape(12.dp)).background(m.t.surface).let { if (on) it.border(2.dp, m.t.accent, RoundedCornerShape(12.dp)) else it }
                .press(enabled = t.available) { x.update { it.copy(quality = t.id).fit(x.catalog) } }.semantics(mergeDescendants = true) { selected = on; role = Role.RadioButton }
                .padding(horizontal = 14.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                T(t.label, m.type.body.copy(fontSize = 15.sp, fontWeight = FontWeight.SemiBold), if (t.available) m.t.ink else m.t.muted, Modifier.width(78.dp), maxLines = 1)
                T(if (t.available) t.detail else "Not available", m.type.body.copy(fontSize = 12.5.sp), m.t.muted, Modifier.weight(1f), maxLines = 1)
                T(if (t.available) ComposerPrice.short(e) else "", m.type.mono.copy(fontSize = 16.sp, fontWeight = FontWeight.SemiBold), m.t.ink, maxLines = 1)
                Box(Modifier.width(20.dp)) { if (on) SIc("check", 18.dp, m.t.accent) }
            }
        }
        SheetLabel("Shape", modifier = Modifier.padding(top = 14.dp, bottom = 4.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ComposerDraft.SHAPES.forEach { a -> ShapeTile(a, a == d.aspect, Modifier.weight(1f).height(72.dp), dark = true) { x.update { it.copy(aspect = a) } } }
        }
        val range = d.lengthRange(x.catalog)
        SheetLabel("Length", "${d.duration} s", Modifier.padding(top = 14.dp))
        MuseSlider(d.duration.coerceIn(range), range.first, range.last, { v -> x.update { it.copy(duration = v) } })
        Row(Modifier.fillMaxWidth()) { T("${range.first} s", m.type.mono.copy(fontSize = 12.sp), m.t.muted, Modifier.weight(1f)); T("${range.last} s", m.type.mono.copy(fontSize = 12.sp), m.t.muted) }
        Box(Modifier.padding(vertical = 8.dp).fillMaxWidth().height(1.dp).background(m.t.line))
        SettingRow("Sound", "Ambience and effects", onClick = { x.update { it.copy(sound = !it.sound) } }) { Toggle(d.sound, { x.update { it.copy(sound = !it.sound) } }) }
        SettingRow("Speaking", "Lips move to the words") {
            MiniSeg(listOf("auto" to "Auto", "on" to "On", "off" to "Off"), when (d.speaking) { true -> "on"; false -> "off"; null -> "auto" }) { k ->
                x.update { it.copy(speaking = when (k) { "on" -> true; "off" -> false; else -> null }) }
            }
        }
        SettingRow("Takes", "Up to ${x.catalog?.takesMax ?: 4} at once") {
            Stepper(d.takes, 1, x.catalog?.takesMax ?: 4) { v -> x.update { it.copy(takes = v) } }
        }
        Spacer(Modifier.height(8.dp))
    }
}

@Composable
private fun ColumnScope.SettingsFooter(x: SheetContext) {
    val m = muse
    if (!x.d.tool.live) { T("Coming soon · ${x.d.tool.title} has no Generate yet", m.type.body.copy(fontSize = 14.sp), m.t.muted, Modifier.fillMaxWidth().padding(vertical = 14.dp), align = TextAlign.Center); return }
    x.blocker?.let { T(it, m.type.tiny, m.t.warn, Modifier.fillMaxWidth().padding(bottom = 6.dp), align = TextAlign.Center, maxLines = 2) }
    val off = x.blocker != null || x.estimate == null
    Box(Modifier.fillMaxWidth().height(54.dp).clip(RoundedCornerShape(27.dp)).background(m.t.accent.copy(alpha = if (off) .45f else 1f)).press { x.onGenerate() }
        .semantics { role = Role.Button }, contentAlignment = Alignment.Center) {
        T(ComposerPrice.button(x.estimate), m.type.body.copy(fontSize = 16.sp, fontWeight = FontWeight.Bold), Color(0xFF1A1205), maxLines = 1)
    }
}

@Composable
private fun SettingRow(title: String, sub: String, onClick: (() -> Unit)? = null, control: @Composable () -> Unit) {
    val m = muse
    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).let { if (onClick != null) it.press(onClick = onClick).semantics(mergeDescendants = true) { role = Role.Switch } else it },
        verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            T(title, m.type.body.copy(fontSize = 15.sp, fontWeight = FontWeight.SemiBold), m.t.ink, maxLines = 1)
            T(sub, m.type.body.copy(fontSize = 12.sp), m.t.muted, maxLines = 1)
        }
        control()
    }
}

@Composable
private fun MiniSeg(items: List<Pair<String, String>>, sel: String, onPick: (String) -> Unit) {
    val m = muse
    Row(Modifier.clip(RoundedCornerShape(10.dp)).background(m.t.surface2).padding(3.dp), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
        items.forEach { (k, l) ->
            val on = k == sel
            Box(Modifier.size(52.dp, 48.dp).clip(RoundedCornerShape(7.dp)).background(if (on) m.t.ink else Color.Transparent).press { onPick(k) }
                .semantics { selected = on; role = Role.RadioButton; contentDescription = l }, contentAlignment = Alignment.Center) {
                T(l, m.type.body.copy(fontSize = 13.sp, fontWeight = FontWeight.SemiBold), if (on) Color(0xFF0D0E0F) else m.t.muted, maxLines = 1)
            }
        }
    }
}

@Composable
private fun Stepper(v: Int, min: Int, max: Int, onChange: (Int) -> Unit) {
    val m = muse
    Row(Modifier.clip(RoundedCornerShape(10.dp)).background(m.t.surface2), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(48.dp).press(enabled = v > min) { onChange(v - 1) }.semantics { contentDescription = "Fewer takes" }, contentAlignment = Alignment.Center) { SIc("minus", 16.dp, if (v > min) m.t.ink else m.t.muted) }
        T("$v", m.type.mono.copy(fontSize = 16.sp, fontWeight = FontWeight.SemiBold), m.t.ink, Modifier.width(26.dp), align = TextAlign.Center)
        Box(Modifier.size(48.dp).press(enabled = v < max) { onChange(v + 1) }.semantics { contentDescription = "More takes" }, contentAlignment = Alignment.Center) { SIc("plus", 16.dp, if (v < max) m.t.ink else m.t.muted) }
    }
}

/** A Shape tile (9:16 · 1:1 · 16:9): the frame drawn to its ratio and the ratio in mono. */
@Composable
fun ShapeTile(aspect: String, on: Boolean, modifier: Modifier, dark: Boolean = false, onClick: () -> Unit) {
    val m = muse
    val (rw, rh) = when (aspect) { "9:16" -> 14 to 26; "1:1" -> 22 to 22; else -> 30 to 18 }
    val shape = RoundedCornerShape(if (dark) 12.dp else if (m.isA) 0.dp else 8.dp)
    val on2 = if (dark) m.t.accent else m.t.ink
    Column(modifier.clip(shape).background(if (dark) m.t.surface else if (on) m.t.surface else m.t.bg).border(if (on) 2.dp else 1.dp, if (on) on2 else if (dark) Color.Transparent else m.t.line, shape)
        .press(onClick = onClick).semantics(mergeDescendants = true) { selected = on; role = Role.RadioButton; contentDescription = "Shape $aspect" },
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically)) {
        Box(Modifier.size(rw.dp, rh.dp).background(if (on) (if (dark) m.t.accent.copy(alpha = .2f) else m.t.ink) else Color.Transparent).border(1.5.dp, if (on) on2 else m.t.muted))
        T(aspect, m.type.mono.copy(fontSize = 12.sp, letterSpacing = .06.em), if (on) m.t.ink else m.t.muted, maxLines = 1)
    }
}

@Composable
private fun ColumnScope.ToolsBody(x: SheetContext) {
    val m = muse
    val cam = x.cam
    Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SheetLabel("Tools")
        ComposerTool.entries.chunked(2).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                row.forEach { t ->
                    val on = t == x.d.tool && x.d.settings.preset == null
                    Column(Modifier.weight(1f).picked(on, m.t.accent).clip(RoundedCornerShape(10.dp)).background(m.t.surface).press { x.update { it.withTool(t) }; x.close() }
                        .semantics(mergeDescendants = true) { selected = on; role = Role.Button }) {
                        PreviewTile(Preview(t.render), Modifier.fillMaxWidth().height(70.dp)) {
                            if (!t.live) Box(Modifier.align(Alignment.TopEnd).padding(6.dp).background(Color.Black.copy(alpha = .6f)).padding(horizontal = 6.dp, vertical = 2.dp)) {
                                T("SOON", m.type.mono.copy(fontSize = 9.5.sp, letterSpacing = .1.em), Color.White)
                            }
                        }
                        Column(Modifier.padding(10.dp)) {
                            T(t.title, m.type.body.copy(fontSize = 14.sp, fontWeight = FontWeight.SemiBold), m.t.ink, maxLines = 1)
                            T(if (t.live) t.tagline else "Coming soon", m.type.body.copy(fontSize = 12.sp), m.t.muted, maxLines = 1)
                        }
                    }
                }
                if (row.size == 1) Spacer(Modifier.weight(1f))
            }
        }
        Row(Modifier.fillMaxWidth().heightIn(min = 52.dp).clip(RoundedCornerShape(10.dp)).background(m.t.surface).press { x.close(); x.onStoryboard() }.padding(horizontal = 14.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                T("Storyboard", m.type.body.copy(fontSize = 14.sp, fontWeight = FontWeight.SemiBold), m.t.ink)
                T("Shots in a row, one cast and look", m.type.body.copy(fontSize = 12.sp), m.t.muted)
            }
            SIc("chev", 16.dp, m.t.muted)
        }
        SheetLabel("Start from a preset", "${cam.presets.size} presets", Modifier.padding(top = 8.dp))
        cam.presets.chunked(2).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                row.forEach { p ->
                    val on = x.d.settings.preset == p.id
                    Box(Modifier.weight(1f).picked(on, m.t.accent)) {
                        PreviewTile(presetPreview(cam, p.id, p.label), Modifier.fillMaxWidth().height(84.dp).clip(RoundedCornerShape(10.dp)).press { x.update { it.pickPreset(cam, p.id, x.models.firstOrNull()?.id) }; x.close() }
                            .semantics { contentDescription = "Preset ${p.label}"; role = Role.Button })
                    }
                }
                if (row.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

/** A preset's tile: the still of its palette, light or camera, with its big name. */
fun presetPreview(cam: CameraCatalog, id: String, label: String): Preview {
    val spec = cam.presets.firstOrNull { it.id == id }?.spec
    fun s(o: String, k: String) = ((spec?.get(o) as? kotlinx.serialization.json.JsonObject)?.get(k) as? kotlinx.serialization.json.JsonPrimitive)?.content
    val still = cam.palettes.firstOrNull { it.id == s("palette", "preset") }?.render ?: cam.lighting.firstOrNull { it.id == s("lighting", "preset") }?.render
        ?: cam.bodies.firstOrNull { it.id == s("rig", "body") }?.render ?: "palette-01-naturalistic"
    return Preview(still, draw = PreviewDraw.Word(label))
}

@Composable
private fun ColumnScope.CharacterBody(x: SheetContext) {
    val m = muse
    val cur = x.d.characterId
    Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (x.models.isEmpty()) T("Make a model first: her character sheet keeps her the same in every shot.", m.type.body.copy(fontSize = 14.sp), m.t.muted)
        x.models.chunked(3).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                row.forEach { mod ->
                    val on = mod.id == cur
                    Column(Modifier.weight(1f).press { x.onPickCharacter(mod.id, x.outfitsOf(mod.id).firstOrNull()?.id) }.semantics(mergeDescendants = true) { selected = on; role = Role.Button }) {
                        Box(Modifier.fillMaxWidth().picked(on, m.t.accent)) {
                            Box(Modifier.fillMaxWidth().aspectRatio(.8f).clip(RoundedCornerShape(10.dp)).background(m.t.surface2)) {
                                RefImage(mod.cover, Modifier.fillMaxWidth().aspectRatio(.8f), 20); if (on) CheckBadge()
                            }
                        }
                        T(mod.name, m.type.body.copy(fontSize = 14.sp, fontWeight = FontWeight.SemiBold), m.t.ink, Modifier.padding(top = 6.dp, start = 3.dp), maxLines = 1)
                        T(mod.niche, m.type.body.copy(fontSize = 12.sp), m.t.muted, Modifier.padding(start = 3.dp), maxLines = 1)
                    }
                }
                repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
            }
        }
        val outfits = x.outfitsOf(cur)
        if (cur != null && outfits.isNotEmpty()) {
            SheetLabel("Outfit", modifier = Modifier.padding(top = 6.dp))
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                outfits.forEach { o -> studio.muse.app.ui.screens.OutfitTile(o, o.id == x.d.characterOutfit, { x.onPickCharacter(cur, o.id) }) }
            }
        }
        if (cur != null) Row(Modifier.heightIn(min = 48.dp).press { x.onPickCharacter(null, null); x.close() }, verticalAlignment = Alignment.CenterVertically) {
            T("No character", m.type.body.copy(fontSize = 14.sp, fontWeight = FontWeight.SemiBold), m.t.muted)
        }
    }
}

@Composable
private fun ColumnScope.TokenBody(tok: PromptPart, x: SheetContext) {
    val m = muse
    Column(Modifier.weight(1f).padding(horizontal = 20.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (tok is PromptPart.Move) {
            SheetLabel("Intensity", "${tok.intensity}%")
            MuseSlider(tok.intensity, 0, 100, { v -> x.update { it.copy(tokens = it.tokens.setIntensity(tok.key, v)) } })
            Row(Modifier.fillMaxWidth()) { T("Subtle", m.type.body.copy(fontSize = 12.sp), m.t.muted, Modifier.weight(1f)); T("Strong", m.type.body.copy(fontSize = 12.sp), m.t.muted) }
        } else if (tok is PromptPart.Mention && tok.kind == "character") {
            Row(Modifier.heightIn(min = 48.dp).press { x.open(ComposerSheet(SheetKind.CHARACTER)) }, verticalAlignment = Alignment.CenterVertically) {
                T("Change character", m.type.body.copy(fontSize = 15.sp, fontWeight = FontWeight.SemiBold), m.t.ink)
            }
        }
        Spacer(Modifier.weight(1f))
        Box(Modifier.fillMaxWidth().height(50.dp).clip(RoundedCornerShape(25.dp)).border(1.dp, m.t.line, RoundedCornerShape(25.dp)).press {
            x.update { it.copy(tokens = it.tokens.remove(tok.key), modelId = if (tok is PromptPart.Mention && tok.kind == "character" && it.modelId == tok.id) null else it.modelId) }; x.close()
        }.semantics { role = Role.Button }, contentAlignment = Alignment.Center) {
            T("Remove", m.type.body.copy(fontSize = 15.sp, fontWeight = FontWeight.SemiBold), m.t.ink)
        }
    }
}

@Composable
private fun ColumnScope.PeopleBody(x: SheetContext) {
    val m = muse
    val r = x.recast
    val max = (x.catalog?.recastMaxPeople ?: SuiteRules.MAX_CAST).coerceIn(1, SuiteRules.MAX_CAST)
    var active by androidx.compose.runtime.saveable.rememberSaveable { androidx.compose.runtime.mutableIntStateOf(0) }
    val frame = rememberFirstFrame(x.frame)
    Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (x.frame != null) {
            SheetLabel("Tap a face", "${r.people.count { it.tap != null }} / $max")
            FacePicker(frame, r.people, active, max, { fx, fy -> frame?.let { b -> x.onTapFace(b, fx, fy)?.let { active = it } } },
                Modifier.align(Alignment.CenterHorizontally), maxHeight = if (x.wide) 260.dp else 300.dp)
            T("Tap each face to replace, then pick who replaces them · or use the position chips", m.type.body.copy(fontSize = 13.sp), m.t.muted)
        } else T("Who in the clip becomes whom · up to $max", m.type.body.copy(fontSize = 13.sp), m.t.muted)
        r.people.forEachIndexed { i, p ->
            val on = i == active && r.people.size > 1
            Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(m.t.surface).let { if (on) it.border(2.dp, m.t.accent, RoundedCornerShape(12.dp)) else it }
                .press { active = i }.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (p.tap != null) FaceBadge(i + 1)
                    if (p.faceCrop != null) RefImage(p.faceCrop, Modifier.size(32.dp).clip(RoundedCornerShape(6.dp)), 50)
                    Column(Modifier.weight(1f)) {
                        T("Person ${i + 1}", m.type.body.copy(fontSize = 15.sp, fontWeight = FontWeight.SemiBold), m.t.ink, maxLines = 1)
                        val where = when {
                            p.cropping -> "Saving the face…"
                            p.tap != null && !p.hintPicked -> "Face picked · ${RecastDraft.hintLabel(p.hint).lowercase()} of the frame"
                            p.tap != null -> "Face picked"
                            else -> "No face tapped · ${RecastDraft.hintLabel(p.hint).lowercase()}"
                        }
                        T(where, m.type.body.copy(fontSize = 12.sp), m.t.muted, maxLines = 1)
                    }
                    if (p.tap != null) Box(Modifier.heightIn(min = 48.dp).press { x.updateRecast { it.clearTap(i) } }.semantics { role = Role.Button; contentDescription = "Clear face ${i + 1}" }, contentAlignment = Alignment.Center) {
                        T("Clear face", m.type.tiny, m.t.muted)
                    }
                    if (r.people.size > 1) Box(Modifier.heightIn(min = 48.dp).press { x.updateRecast { it.remove(i) }; active = 0 }, contentAlignment = Alignment.Center) { T("Remove", m.type.tiny, m.t.muted) }
                }
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    RecastDraft.HINTS.forEach { h -> DarkChip(RecastDraft.hintLabel(h), p.hint == h) { x.updateRecast { it.pickHint(i, h) } } }
                }
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    x.models.forEach { mod ->
                        val picked = mod.id == p.characterId
                        Row(Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(10.dp)).background(m.t.surface2).let { if (picked) it.border(2.dp, m.t.accent, RoundedCornerShape(10.dp)) else it }
                            .press { x.updateRecast { it.update(i) { q -> q.copy(characterId = mod.id, outfitId = null) } }; active = i }
                            .semantics(mergeDescendants = true) { selected = picked; role = Role.Button; contentDescription = "Person ${i + 1} becomes ${mod.name}" }.padding(6.dp),
                            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            RefImage(mod.cover, Modifier.size(30.dp, 38.dp).clip(RoundedCornerShape(4.dp)))
                            T(mod.name, m.type.body.copy(fontSize = 13.sp, fontWeight = FontWeight.SemiBold), m.t.ink, maxLines = 1)
                        }
                    }
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    T("Speaking", m.type.body.copy(fontSize = 14.sp), m.t.ink, Modifier.weight(1f))
                    MiniSeg(listOf("auto" to "Auto", "yes" to "Yes", "no" to "No"), when (p.speaking) { true -> "yes"; false -> "no"; null -> "auto" }) { k ->
                        x.updateRecast { it.update(i) { q -> q.copy(speaking = when (k) { "yes" -> true; "no" -> false; else -> null }) } }
                    }
                }
            }
        }
        if (r.canAdd(max)) Box(Modifier.fillMaxWidth().height(50.dp).clip(RoundedCornerShape(25.dp)).border(1.dp, m.t.line, RoundedCornerShape(25.dp)).press { x.updateRecast { it.add() }; active = r.people.size }, contentAlignment = Alignment.Center) {
            T("Add a person", m.type.body.copy(fontSize = 15.sp, fontWeight = FontWeight.SemiBold), m.t.ink)
        }
        Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).press { x.updateRecast { it.copy(keepAudio = !it.keepAudio) } }, verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                T("Keep the clip's audio", m.type.body.copy(fontSize = 15.sp, fontWeight = FontWeight.SemiBold), m.t.ink)
                T("The original sound, put back after the render", m.type.body.copy(fontSize = 12.sp), m.t.muted)
            }
            Toggle(r.keepAudio, { x.updateRecast { it.copy(keepAudio = !it.keepAudio) } })
        }
    }
}

@Composable
private fun DarkChip(label: String, on: Boolean, onClick: () -> Unit) {
    val m = muse
    Box(Modifier.heightIn(min = 48.dp).press(onClick = onClick).semantics { selected = on; role = Role.RadioButton }, contentAlignment = Alignment.Center) {
        Box(Modifier.height(32.dp).clip(RoundedCornerShape(16.dp)).background(if (on) m.t.ink else m.t.surface2).padding(horizontal = 12.dp), contentAlignment = Alignment.Center) {
            T(label, m.type.body.copy(fontSize = 13.sp, fontWeight = FontWeight.SemiBold), if (on) Color(0xFF0D0E0F) else m.t.muted, maxLines = 1)
        }
    }
}


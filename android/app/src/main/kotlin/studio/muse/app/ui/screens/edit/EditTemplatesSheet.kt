package studio.muse.app.ui.screens.edit

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import studio.muse.app.data.EditTemplate
import studio.muse.app.data.EditTemplateParam
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.scale
import studio.muse.core.edit.CaptionPreset
import studio.muse.core.edit.Presets

/**
 * Edit templates on Android (plans/edit-templates.md §5, mockup 3): the Templates sheet. Filters, then a 3-column grid
 * ("Yours", "Made by Claude"), the caption styles as a section; a tapped tile previews on the real edit and opens its
 * settings with one full-width Apply. Not-ready templates show the reference only (Claude makes them on the Mac). Owner
 * only: members see the caption styles.
 */
@Composable
fun ColumnScope.TemplatesBody(ui: EditSuiteUi, host: SuiteHost, act: (EditAction) -> Unit) {
    val m = muse
    val tu = ui.templates
    if (!ui.claudeOwner) {
        T("Templates are the studio owner's. Caption styles:", m.type.body.copy(fontSize = 13.sp), m.t.muted)
        CaptionStyleRows(ui, act)
        return
    }
    val picked = tu.pickedTemplate
    if (picked != null) { TemplateSettings(ui, picked, host, act); return }
    SuiteSeg(EditTemplatesLogic.FILTERS.map { it to it }, tu.filter, { act(EditAction.TemplateFilter(it)) }, Modifier.fillMaxWidth(), fill = true)
    when {
        tu.loading || (tu.library == null && tu.error == null) -> TemplateGrid(List(6) { null }, host, null) {}
        tu.error != null -> {
            T("Templates didn't load", m.type.body.copy(fontSize = 14.sp), m.t.ink)
            T(tu.error, m.type.tiny.copy(fontSize = 12.sp), m.t.muted)
            SuiteButton("Try again", { act(EditAction.LoadTemplates) }, Modifier.fillMaxWidth(), icon = "arrow-clockwise")
        }
        else -> {
            val sections = EditTemplatesLogic.sections(tu.library, tu.filter)
            if (sections.isEmpty() && tu.filter != "Captions") {
                T("No templates yet", m.type.body.copy(fontSize = 14.sp), m.t.ink)
                T("A template is an effect or transition you can put on any clip in one tap. Style a clip, then save it as a template below.", m.type.tiny.copy(fontSize = 12.sp), m.t.muted)
            }
            sections.forEach { (title, items) ->
                SuiteLabel(title)
                TemplateGrid(items, host, tu.picked) { act(EditAction.PickTemplate(it.id)) }
            }
        }
    }
    if (tu.filter == "All" || tu.filter == "Captions") {
        SuiteLabel("Caption styles")
        CaptionStyleRows(ui, act)
    }
    SaveTemplateRow(ui, act)
}

/** A 3-column grid of 16:10 tiles; null entries are skeletons while the library loads. */
@Composable
private fun TemplateGrid(items: List<EditTemplate?>, host: SuiteHost, picked: String?, onPick: (EditTemplate) -> Unit) {
    val m = muse
    items.chunked(3).forEach { row ->
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            row.forEach { t ->
                Column(Modifier.weight(1f).let { if (t != null) it.press { onPick(t) }.semantics { contentDescription = EditTemplatesLogic.badge(t)?.let { b -> "${t.name}, $b" } ?: t.name; selected = picked == t.id } else it },
                    verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    val shape = RoundedCornerShape(8.dp)
                    Box(Modifier.fillMaxWidth().aspectRatio(16f / 10f).clip(shape).background(m.t.surface2)
                        .border(if (t != null && picked == t.id) 2.dp else 0.dp, if (t != null && picked == t.id) m.t.accent else m.t.surface2, shape),
                        contentAlignment = Alignment.Center) {
                        if (t != null) {
                            TemplateStill(t.preview?.uploadId ?: t.reference?.uploadId, host)
                            EditTemplatesLogic.badge(t)?.let { b ->
                                Box(Modifier.align(Alignment.BottomStart).padding(4.dp).clip(RoundedCornerShape(4.dp)).background(m.t.bg).padding(horizontal = 5.dp, vertical = 1.dp)) {
                                    T(b, m.scale.micro, m.t.ink, maxLines = 1)
                                }
                            }
                        }
                    }
                    if (t != null) {
                        T(t.name, m.scale.label, m.t.ink, maxLines = 1)
                        t.timing?.let { T(it, m.scale.micro, m.t.muted, maxLines = 1) }
                    } else Box(Modifier.width(56.dp).height(10.dp).clip(RoundedCornerShape(3.dp)).background(m.t.surface2))
                }
            }
            repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
        }
    }
}

/** A still of the template's preview clip, or the film-strip mark without one (the edit itself is the live preview). */
@Composable
private fun TemplateStill(uploadId: String?, host: SuiteHost) {
    val still by produceState<ImageBitmap?>(null, uploadId) { value = uploadId?.let { runCatching { host.templateStill(it) }.getOrNull() } }
    val s = still
    if (s != null) Image(s, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
    else EIc("film-strip", 18.dp, muse.t.muted)
}

/** The picked template: what it does, where it goes, its settings and Apply (mockup 3); not ready: why, and the reference. */
@Composable
private fun ColumnScope.TemplateSettings(ui: EditSuiteUi, t: EditTemplate, host: SuiteHost, act: (EditAction) -> Unit) {
    val m = muse
    val tu = ui.templates
    Row(Modifier.fillMaxWidth().height(40.dp).press { act(EditAction.PickTemplate(null)) }.semantics { contentDescription = "All templates" }, verticalAlignment = Alignment.CenterVertically) {
        EIc("caret-left", 16.dp, m.t.muted)
        Spacer(Modifier.width(6.dp))
        T("All templates", m.scale.label, m.t.muted)
    }
    T(t.name, m.type.h3, m.t.ink)
    if (t.description.isNotBlank()) T(t.description, m.type.body.copy(fontSize = 13.sp), m.t.muted)
    if (t.state != "ready") {
        Box(Modifier.fillMaxWidth().aspectRatio(16f / 10f).clip(RoundedCornerShape(8.dp)).background(m.t.surface2), contentAlignment = Alignment.Center) {
            TemplateStill(t.reference?.uploadId ?: t.preview?.uploadId, host)
        }
        T(EditTemplatesLogic.badge(t) ?: "Not ready", m.type.body.copy(fontSize = 14.sp), m.t.ink)
        T(t.reason ?: "This one isn't built into Edit yet.", m.type.tiny.copy(fontSize = 12.sp), m.t.muted)
        if (t.state == "needs_update") T("Needs the next MUSE update", m.type.tiny.copy(fontSize = 12.sp), m.t.muted)
        else T("Claude can make it for your shots in the MUSE app on the Mac.", m.type.tiny.copy(fontSize = 12.sp), m.t.muted)
        return
    }
    val target = EditTemplatesLogic.target(t, ui.project, ui.selectedId, ui.playheadSec)
    SuiteLabel("Applies to")
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).background(m.t.surface).padding(12.dp)) {
        T(target?.title ?: "Nothing to put it on yet", m.type.body.copy(fontSize = 14.sp), m.t.ink, maxLines = 1)
        T(target?.detail ?: "Add clips to the timeline first", m.type.tiny.copy(fontSize = 12.sp), m.t.muted, maxLines = 1)
    }
    t.params.filter(EditTemplatesLogic::shown).forEach { p -> TemplateParamRow(p, tu.params[p.key] ?: p.defaultValue, act) }
    T(EditTemplatesLogic.levelLine(t), m.type.tiny.copy(fontSize = 12.sp), m.t.muted)
    tu.notes.forEach { T(it, m.type.tiny.copy(fontSize = 12.sp), m.t.muted) }
    val busy = tu.applying || tu.previewing
    SuiteButton(EditTemplatesLogic.applyTitle(t, target, tu.price), { act(EditAction.ApplyTemplate()) }, Modifier.fillMaxWidth(), primary = true,
        enabled = !busy && (target != null || t.target == "edit") && ui.session != null)
    EditTemplatesLogic.every(t)?.let { (_, title) -> SuiteButton(title, { act(EditAction.ApplyTemplate(every = true)) }, Modifier.fillMaxWidth(), enabled = !busy && ui.session != null) }
    T(when {
        ui.session == null -> "Templates apply once this edit is online"
        tu.previewing -> "Previewing…"
        tu.previewOf == t.id -> "Previewing on the edit, not applied yet"
        else -> ""
    }, m.type.tiny.copy(fontSize = 12.sp), m.t.muted)
}

@Composable
private fun TemplateParamRow(p: EditTemplateParam, v: kotlinx.serialization.json.JsonElement?, act: (EditAction) -> Unit) {
    val m = muse
    val prim = v as? JsonPrimitive
    when (p.type) {
        "enum" -> {
            SuiteLabel(p.label.ifBlank { p.key })
            SuiteSeg(p.options.map { it to EditTemplatesLogic.optionLabel(it) }, prim?.content, { act(EditAction.TemplateParam(p.key, JsonPrimitive(it))) }, Modifier.fillMaxWidth(), fill = true)
        }
        "number" -> {
            val lo = p.min ?: 0.0
            val hi = p.max ?: (lo + 1.0)
            val x = prim?.doubleOrNull ?: lo
            val whole = lo == Math.rint(lo) && hi == Math.rint(hi) && hi - lo >= 2
            var draft by remember(x) { mutableStateOf(x) }
            SuiteSlider(((draft - lo) / (hi - lo)).toFloat(), { f, done ->
                val raw = lo + f * (hi - lo)
                draft = if (whole) Math.rint(raw) else Math.rint(raw * 100) / 100
                if (done) act(EditAction.TemplateParam(p.key, JsonPrimitive(draft)))
            }, label = p.label.ifBlank { p.key }, valueText = EditTemplatesLogic.valueLabel(p, draft))
        }
        "bool" -> OptRow(p.label.ifBlank { p.key }, null, prim?.booleanOrNull == true, { act(EditAction.TemplateParam(p.key, JsonPrimitive(prim?.booleanOrNull != true))) })
        "text" -> {
            var text by remember(prim?.content) { mutableStateOf(prim?.content ?: "") }
            SuiteLabel(p.label.ifBlank { p.key })
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Box(Modifier.weight(1f).height(44.dp).background(m.t.surface).border(1.dp, m.t.line).padding(horizontal = 12.dp), contentAlignment = Alignment.CenterStart) {
                    BasicTextField(text, { text = it.take(200) }, Modifier.fillMaxWidth().semantics { contentDescription = p.label }, singleLine = true,
                        textStyle = m.type.body.copy(color = m.t.ink, fontSize = 14.sp), cursorBrush = SolidColor(m.t.accent))
                }
                SuiteButton("Set", { act(EditAction.TemplateParam(p.key, JsonPrimitive(text))) }, height = 44.dp)
            }
        }
    }
}

/** Caption styles as a section of the library (owner decision 1): the presets, applied to the captions. */
@Composable
private fun CaptionStyleRows(ui: EditSuiteUi, act: (EditAction) -> Unit) {
    val m = muse
    val ct = ui.captionTrack?.caption
    if (ct == null) { T("Make captions first (Captions in the tool row), then pick a style here.", m.type.tiny.copy(fontSize = 12.sp), m.t.muted); return }
    val names = ui.templates.library?.captionStyles?.associate { it.id to it.name } ?: emptyMap()
    Presets.CAPTION_STYLE_LABELS.take(6).chunked(3).forEach { row ->
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            row.forEach { (preset: CaptionPreset, label: String) ->
                CaptionTile(Presets.CAPTION_STYLES.getValue(preset), names[preset.wire] ?: label, ct.style.preset == preset, { act(EditAction.CaptionStyleOf(preset)) }, Modifier.weight(1f))
            }
        }
    }
}

/** Save as template: the selected clip (or the cut before it) with its effect, look and overlays. */
@Composable
private fun SaveTemplateRow(ui: EditSuiteUi, act: (EditAction) -> Unit) {
    val m = muse
    val sel = ui.selectedId ?: return
    val k = ui.project?.mainClips?.indexOfFirst { it.id == sel } ?: -1
    var name by remember(sel) { mutableStateOf("") }
    var kind by remember(sel) { mutableStateOf("effect") }
    SuiteLabel(if (k >= 0) "Save clip ${k + 1} as a template" else "Save the selection as a template")
    SuiteSeg(listOf("effect" to "Effect", "transition" to if (k > 0) "Transition (the cut before it)" else "Transition"), kind, { kind = it }, Modifier.fillMaxWidth(), fill = true)
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.weight(1f).height(44.dp).background(m.t.surface).border(1.dp, m.t.line).padding(horizontal = 12.dp), contentAlignment = Alignment.CenterStart) {
            BasicTextField(name, { name = it.take(60) }, Modifier.fillMaxWidth().semantics { contentDescription = "Template name" }, singleLine = true,
                textStyle = m.type.body.copy(color = m.t.ink, fontSize = 14.sp), cursorBrush = SolidColor(m.t.accent),
                decorationBox = { inner -> Box { if (name.isEmpty()) T("Name it", m.type.body.copy(fontSize = 14.sp), m.t.muted, maxLines = 1); inner() } })
        }
        SuiteButton("Save template", { act(EditAction.SaveTemplate(name, kind, cut = kind == "transition" && k > 0)); name = "" }, height = 44.dp,
            enabled = name.isNotBlank() && ui.session != null)
    }
}

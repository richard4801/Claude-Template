package studio.muse.app.ui.screens.edit

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import studio.muse.app.data.EditTemplate
import studio.muse.app.data.EditTemplateLibrary
import studio.muse.app.data.EditTemplateParam
import studio.muse.core.edit.EditProject
import studio.muse.core.edit.durationSec
import studio.muse.core.edit.locate
import studio.muse.core.edit.timeline
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Edit templates on Android (plans/edit-templates.md §5, mockup 3): what the Templates sheet shows and where Apply goes.
 * Pure, so the screenshots and unit tests use it without a server. The picked template previews on the real edit (the
 * server's dry run, applied to a copy the player shows: [EditSuiteUi.templatePreview]).
 */
data class TemplatesUi(
    val loading: Boolean = false,
    /** "Templates didn't load" and why, with Try again. */
    val error: String? = null,
    val library: EditTemplateLibrary? = null,
    /** All | Transitions | Effects | Captions */
    val filter: String = "All",
    val picked: String? = null,
    val params: Map<String, JsonElement> = emptyMap(),
    val previewing: Boolean = false,
    /** The template the player shows now (its dry run), else null. */
    val previewOf: String? = null,
    val price: Double? = null,
    val notes: List<String> = emptyList(),
    val applying: Boolean = false,
) {
    val pickedTemplate: EditTemplate? get() = picked?.let { id -> library?.templates?.firstOrNull { it.id == id } }
}

/** Where a template goes: the JSON the server takes ({itemId} / {cutAfter} / {each}; null for the whole edit), and the row's words. */
data class TemplateTarget(val json: JsonElement?, val title: String, val detail: String)

object EditTemplatesLogic {
    val FILTERS = listOf("All", "Transitions", "Effects", "Captions")

    val EditTemplate.ready: Boolean get() = state == "ready"
    /** The tile's badge: "Not ready", "Needs update", or none. */
    fun badge(t: EditTemplate): String? = when (t.state) { "ready" -> null; "needs_update" -> "Needs update"; else -> "Not ready" }

    /** The grid's sections for a filter: "Yours" (saved by you or Claude), then "Made by Claude" (the pack's), ready first. */
    fun sections(lib: EditTemplateLibrary?, filter: String): List<Pair<String, List<EditTemplate>>> {
        if (lib == null || filter == "Captions") return emptyList()
        val shown = lib.templates.filter { filter == "All" || (filter == "Transitions") == (it.kind == "transition") }
        val order = compareBy<EditTemplate>({ !it.ready }, { it.name.lowercase() })
        return listOf("Yours" to shown.filter { it.by != "seed" }.sortedWith(order), "Made by Claude" to shown.filter { it.by == "seed" }.sortedWith(order))
            .filter { it.second.isNotEmpty() }
    }

    /** "0:04.2" */
    fun clockTenths(s: Double): String {
        val t = (s.coerceAtLeast(0.0) * 10).roundToInt()
        val sec = (t / 10) % 60
        return "${t / 600}:${sec.toString().padStart(2, '0')}.${t % 10}"
    }

    /**
     * What Apply goes on now: the selected clip (else the one under the playhead); for a cut, the cut before the selected
     * clip, else the cut nearest the playhead; a whole-edit template, the edit. Null when there's nothing to put it on.
     */
    fun target(t: EditTemplate, p: EditProject?, selectedId: String?, playhead: Double): TemplateTarget? {
        p ?: return null
        val spans = timeline(p)
        if (spans.isEmpty()) return null
        val clips = p.mainClips
        fun cut(i: Int) = spans[i].startSec + spans[i].transitionSec / 2
        return when (t.target) {
            "edit" -> TemplateTarget(null, "The whole edit", "${clockTenths(durationSec(p))} long")
            "cut" -> {
                if (spans.size < 2) return null
                val sel = selectedId?.let { id -> clips.indexOfFirst { it.id == id } }?.takeIf { it > 0 }
                val i = sel ?: (1 until spans.size).minByOrNull { abs(cut(it) - playhead) } ?: return null
                TemplateTarget(JsonObject(mapOf("cutAfter" to JsonPrimitive(clips[i - 1].id))), "Cut at ${clockTenths(cut(i))}", "Between clip $i and clip ${i + 1}")
            }
            else -> {
                if (selectedId != null && p.locate(selectedId) != null) {
                    val n = clips.indexOfFirst { it.id == selectedId }
                    TemplateTarget(JsonObject(mapOf("itemId" to JsonPrimitive(selectedId))), if (n >= 0) "Clip ${n + 1}" else "The selected item", "The selected clip")
                } else {
                    val i = spans.indexOfFirst { playhead >= it.startSec && playhead < it.endSec }.takeIf { it >= 0 } ?: (spans.size - 1)
                    TemplateTarget(JsonObject(mapOf("itemId" to JsonPrimitive(spans[i].id))), "Clip ${i + 1}", "Under the playhead")
                }
            }
        }
    }

    /** "Apply to the cut into clip 3" (mockup 3), "Apply to clip 2", "… · $0.82" for a template that cuts out the subject. */
    fun applyTitle(t: EditTemplate, target: TemplateTarget?, price: Double?): String {
        val place = when {
            target == null -> null
            t.target == "cut" -> target.detail.substringAfterLast(" and ").let { "the cut into $it" }
            else -> target.title.replaceFirstChar { it.lowercase() }
        }
        val base = place?.let { "Apply to $it" } ?: "Apply"
        return if (t.paid && price != null && price > 0) "$base · $${String.format(java.util.Locale.ROOT, "%.2f", price)}" else base
    }

    /** The second button: every cut (or every cut on a note), every clip; none for whole-edit templates. */
    fun every(t: EditTemplate): Pair<JsonElement, String>? = when (t.target) {
        "cut" -> if (t.each == "note-cut") JsonObject(mapOf("each" to JsonPrimitive("note-cut"))) to "Apply to every cut on a note"
            else JsonObject(mapOf("each" to JsonPrimitive("cut"))) to "Apply to every cut"
        "clip" -> JsonObject(mapOf("each" to JsonPrimitive("clip"))) to "Apply to every clip"
        else -> null
    }

    /** The settings the sheet draws (uploads and time ranges are Claude's to set). */
    fun shown(p: EditTemplateParam): Boolean = when (p.type) { "enum" -> p.options.size > 1; "number", "bool", "text" -> true; else -> false }

    /** "box" → "Box", "easeOut" → "Ease out". */
    fun optionLabel(o: String): String = buildString { o.forEach { c -> if (c.isUpperCase() && isNotEmpty()) append(' ').append(c.lowercaseChar()) else append(c) } }
        .replaceFirstChar { it.uppercase() }

    /** "0.3 s", "1.35 ×", "25°", "3". */
    fun valueLabel(p: EditTemplateParam, v: Double): String {
        val n = when {
            abs(v - v.roundToInt()) < 1e-9 -> v.roundToInt().toString()
            abs(v * 10 - (v * 10).roundToInt()) < 1e-9 -> String.format(java.util.Locale.ROOT, "%.1f", v)
            else -> String.format(java.util.Locale.ROOT, "%.2f", v)
        }
        val u = p.unit?.takeIf { it.isNotEmpty() } ?: return n
        return if (u == "°") "$n°" else "$n $u"
    }

    /** The defaults of a template's settings (the sheet starts from them). */
    fun defaults(t: EditTemplate): Map<String, JsonElement> = t.params.mapNotNull { p -> p.defaultValue?.let { p.key to it } }.toMap()

    /** "Live transition: uses the clips themselves…" and the like, under the settings. */
    fun levelLine(t: EditTemplate): String = when (t.level) {
        "matte" -> "Cuts out the subject (Remove background), priced on Apply. Everything else is live and works on any video."
        "live" -> if (t.target == "cut") "Live transition: uses the clips themselves, so it works on any video." else "Live effect: works on any video."
        else -> t.reason ?: "Not ready yet"
    }

    /** A dry run's patch as the core's ops (empty when the server sent none). */
    fun patchOf(a: JsonArray?): List<studio.muse.core.edit.PatchOp> = a?.map(studio.muse.core.edit.PatchOp::of) ?: emptyList()
}

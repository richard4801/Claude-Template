package studio.muse.app.ui.screens.suite.composer

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import studio.muse.app.data.SuiteCatalog
import studio.muse.app.data.SuiteInputs
import studio.muse.app.data.SuiteCustomEngine
import studio.muse.app.data.SuiteResolution
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import studio.muse.app.data.SuiteRules
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.suite.SIc
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.scale

// The owner's model picker (owner request 2026-11-08, matching the Mac's "Model" pill, WS6). Owner only: members never see
// a model or provider name and keep the quality tiers. Order: this quality's ladder, then every other engine, then the
// studio's own models ("Your providers", WS5). Each row says its lengths, shapes and price per second at its resolution;
// picking one pins it for this shot and clamps Length and Shape to what it takes.

/** One engine the owner can pin: a registry model (with its resolutions) or a custom `c_…` model. Video or image. */
data class PickerEngine(
    val id: String,
    val name: String,
    /** The qualities whose ladder runs it (empty for custom and image models: the shot keeps its quality). */
    val tiers: List<String>,
    /** The resolution it runs at unless the owner picks another. */
    val resolution: String?,
    val resolutions: List<SuiteResolution>,
    val minSeconds: Int?,
    val maxSeconds: Int?,
    /** Exact lengths only (5 and 10…), when the engine has them. */
    val allowedSeconds: List<Int>?,
    val aspectRatios: List<String>,
    val perSec: Double?,
    val inputs: SuiteInputs?,
    val custom: Boolean,
    val perRun: Double? = null,
    val kind: String = "video",
    /** The resolution each quality's ladder runs it at (tier id → resolution id). */
    val ladderRes: Map<String, String> = emptyMap(),
) {
    val tier: String? get() = tiers.firstOrNull()

    /** The resolution it runs at on [quality]: that ladder's, else its default. */
    fun resolutionOn(quality: String): String? = ladderRes[quality] ?: resolution

    /** $/s at [res] (the resolution's own price when the server lists it). */
    fun perSecAt(res: String?): Double? = resolutions.firstOrNull { it.id == res }?.perSec ?: perSec

    /** "2–10 s · 9:16, 16:9", or "5 or 10 s" for exact lengths. */
    val limits: String get() = listOfNotNull(
        when {
            !allowedSeconds.isNullOrEmpty() -> allowedSeconds.joinToString(", ").let { l -> l.substringBeforeLast(", ").let { if (allowedSeconds.size > 1) "$it or ${allowedSeconds.last()} s" else "$l s" } }
            minSeconds != null && maxSeconds != null && minSeconds != maxSeconds -> "$minSeconds–$maxSeconds s"
            maxSeconds != null -> "$maxSeconds s"
            else -> null
        },
        aspectRatios.takeIf { it.isNotEmpty() }?.joinToString(", "),
    ).joinToString(" · ")

    /** "$0.065/s · 720p", "$0.04 a photo", or the resolution alone when there's no price. */
    fun price(res: String? = resolution): String = listOfNotNull(
        perSecAt(res)?.takeIf { kind == "video" && it > 0 }?.let { "${ModelPicker.rate(it)}/s" }
            ?: perRun?.takeIf { it > 0 }?.let { "${ModelPicker.rate(it)} ${if (kind == "image") "a photo" else "a run"}" },
        res?.let { r -> resolutions.firstOrNull { it.id == r }?.label?.substringBefore(' ')?.ifBlank { null } ?: r },
    ).joinToString(" · ")

    val price: String get() = price(resolution)
}

/** The three groups the picker shows. */
data class PickerGroups(val ladder: List<PickerEngine>, val others: List<PickerEngine>, val custom: List<PickerEngine>) {
    val all get() = ladder + others + custom
    val isEmpty get() = all.isEmpty()
}

object ModelPicker {
    /** Dollars with up to 3 decimals, trailing zeros trimmed past the cents: $0.065, $0.13, $1.20. */
    fun rate(v: Double): String {
        val s = String.format(java.util.Locale.US, "%.3f", v)
        return "$" + if (s.endsWith("0")) s.dropLast(1) else s
    }

    /**
     * Every [kind] engine in the owner's catalog: `engines[]` (WS5) when the server sends it; else, for video, each tier's
     * models (one entry per model, with every quality that runs it) plus the custom video models.
     */
    fun engines(cat: SuiteCatalog?, kind: String = "video"): List<PickerEngine> {
        cat ?: return emptyList()
        // Which resolution each quality's ladder runs a model at (owner catalogs list it per tier).
        fun ladderRes(id: String) = cat.tiers.mapNotNull { t -> t.models?.firstOrNull { it.model == id }?.resolution?.ifBlank { null }?.let { t.id to it } }.toMap()
        cat.engines?.let { list ->
            return list.filter { it.kind == kind }.map { e ->
                PickerEngine(e.model, e.name.ifBlank { e.model }, e.tiers.ifEmpty { listOfNotNull(e.tier) }, e.resolution?.ifBlank { null }, e.resolutions,
                    e.minSeconds, e.maxSeconds, e.allowedSeconds, e.aspectRatios, e.perSec, e.inputs, e.custom, e.perRun, e.kind, ladderRes(e.model))
            }
        }
        if (kind != "video") return cat.custom.orEmpty().filter { it.kind == kind }.map { c -> customEngine(c) }
        val rows = cat.tiers.filter { it.available }.flatMap { t -> t.models.orEmpty().map { t to it } }
        val core = rows.groupBy { it.second.model }.map { (id, at) ->
            val (t0, m0) = at.first()
            PickerEngine(id, m0.name.ifBlank { id }, at.map { it.first.id }.distinct(), m0.resolution.ifBlank { null },
                at.map { (_, m) -> SuiteResolution(m.resolution, m.resolution, perSec = m.perSec ?: 0.0) }.filter { it.id.isNotBlank() }.distinctBy { it.id },
                m0.minSeconds ?: t0.minSeconds, m0.maxSeconds ?: t0.maxSeconds, null, emptyList(), m0.perSec, m0.inputs, custom = false, ladderRes = ladderRes(id))
        }
        return core + cat.custom.orEmpty().filter { it.kind == "video" }.map(::customEngine)
    }

    private fun customEngine(c: SuiteCustomEngine) = PickerEngine(c.id, c.name.ifBlank { c.id }, emptyList(), null, emptyList(), c.minSeconds, c.maxSeconds, null,
        c.aspectRatios, c.price?.takeIf { it.basis == "per_second" }?.usd, c.inputs, custom = true, perRun = c.price?.takeIf { it.basis != "per_second" }?.usd, kind = c.kind)

    /** The picker's groups for a shot on [quality]: the engines on that quality's ladder first, then the rest, then "Your providers". */
    fun groups(cat: SuiteCatalog?, quality: String, kind: String = "video"): PickerGroups {
        val (custom, core) = engines(cat, kind).partition { it.custom }
        val (ladder, others) = core.partition { quality in it.tiers }
        // This quality's ladder in its own order; the others in quality order (Draft → Cinema).
        val ladderOrder = cat?.tier(quality)?.models.orEmpty().map { it.model }
        val order = cat?.tiers?.map { it.id } ?: SuiteRules.TIERS
        return PickerGroups(
            ladder.sortedBy { e -> ladderOrder.indexOf(e.id).let { if (it < 0) Int.MAX_VALUE else it } },
            others.sortedBy { e -> order.indexOf(e.tier).let { if (it < 0) Int.MAX_VALUE else it } },
            custom,
        )
    }

    /** The engine a draft has pinned, or null (Auto, or a pin the catalog no longer has). */
    fun find(cat: SuiteCatalog?, id: String?, kind: String = "video"): PickerEngine? = id?.let { engines(cat, kind).firstOrNull { e -> e.id == id } }

    /** [seconds] snapped to the nearest exact length the engine allows. */
    fun snap(seconds: Int, allowed: List<Int>?): Int = allowed?.takeIf { it.isNotEmpty() }?.minByOrNull { kotlin.math.abs(it - seconds) } ?: seconds
}

/**
 * Pins [e] for this shot (null = Auto) at [res] (its default resolution when null). A ladder engine keeps the quality when
 * that quality's ladder runs it, else moves to its first quality, so the price and the quality label agree; a custom
 * model keeps the quality. Length and Shape are clamped to what the engine takes.
 */
fun ComposerDraft.pinEngine(e: PickerEngine?, res: String? = null): ComposerDraft {
    if (e == null) return copy(engineModel = null, resolution = null)
    val q = if (e.tiers.isEmpty() || quality in e.tiers) quality else e.tiers.first()
    var d = copy(engineModel = e.id, resolution = res ?: e.resolutionOn(q), quality = q)
    val lo = e.minSeconds; val hi = e.maxSeconds
    if (lo != null && hi != null && hi >= lo) d = d.copy(duration = d.duration.coerceIn(lo, hi))
    else if (hi != null) d = d.copy(duration = d.duration.coerceAtMost(hi))
    d = d.copy(duration = ModelPicker.snap(d.duration, e.allowedSeconds))
    if (e.aspectRatios.isNotEmpty() && d.aspect !in e.aspectRatios) d = d.copy(aspect = e.aspectRatios.firstOrNull { it in ComposerDraft.SHAPES } ?: e.aspectRatios.first())
    return d
}

/** The pill and row value: "Auto", or the pinned engine's name with its resolution. */
fun ComposerDraft.modelLabel(cat: SuiteCatalog?): String =
    ModelPicker.find(cat, engineModel)?.let { e -> e.name + ((resolution ?: e.resolution)?.let { r -> " · " + (e.resolutions.firstOrNull { it.id == r }?.label?.substringBefore(' ')?.ifBlank { null } ?: r) } ?: "") }
        ?: if (engineModel == null) "Auto" else engineModel

/** The tablet menu's items: Auto, then every engine as "Name · 720p · $0.065/s". Index 0 is Auto. */
fun modelMenuItems(d: ComposerDraft, groups: PickerGroups): List<Pair<String, Boolean>> =
    listOf("Auto" to (d.engineModel == null)) + groups.all.map { e ->
        (listOf(e.name, e.price(e.resolutionOn(d.quality))).filter { it.isNotBlank() }.joinToString(" · ") + if (e.custom) " (yours)" else "") to (e.id == d.engineModel)
    }

/**
 * The phone's model list (inside the composer's Settings sheet, always dark): Auto, then the groups with a small heading
 * each. One row per engine: name, its lengths and shapes, and its price per second at its resolution.
 */
@Composable
fun ModelPickerList(d: ComposerDraft, groups: PickerGroups, onPick: (PickerEngine?, String?) -> Unit) {
    val m = muse
    Column(Modifier.fillMaxWidth().testTag("model_picker"), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        ModelRow("Auto", "MUSE picks the engine for this quality", "", d.engineModel == null) { onPick(null, null) }
        fun section(title: String, list: List<PickerEngine>) = title to list
        listOf(
            section("${SuiteRules.tierLabel(d.quality)} ladder", groups.ladder),
            section("Other models", groups.others),
            section("Your providers", groups.custom),
        ).filter { it.second.isNotEmpty() }.forEach { (title, list) ->
            T(title, m.scale.caption, m.t.muted, Modifier.padding(top = 10.dp, bottom = 2.dp), maxLines = 1)
            list.forEach { e ->
                val on = e.id == d.engineModel
                val detail = listOfNotNull(e.tier?.takeIf { d.quality !in e.tiers }?.let { SuiteRules.tierLabel(it) }, e.limits.ifBlank { null }).joinToString(" · ")
                ModelRow(e.name, detail, e.price(if (on) d.resolution ?: e.resolutionOn(d.quality) else e.resolutionOn(d.quality)), on) { onPick(e, null) }
                // The pinned engine's resolutions, each with its own price per second.
                if (on && e.resolutions.size > 1) Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(start = 14.dp, bottom = 4.dp),
                    horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    e.resolutions.forEach { r ->
                        val label = r.label.substringBefore(' ').ifBlank { r.id } + (e.perSecAt(r.id)?.let { " · ${ModelPicker.rate(it)}/s" } ?: "")
                        DarkChip(label, r.id == (d.resolution ?: e.resolutionOn(d.quality))) { onPick(e, r.id) }
                    }
                }
            }
        }
    }
}

@Composable
private fun ModelRow(name: String, detail: String, price: String, on: Boolean, onClick: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(12.dp)
    Row(
        Modifier.fillMaxWidth().heightIn(min = 56.dp).clip(shape).background(if (on) m.t.surface2 else m.t.surface).press(onClick = onClick)
            .semantics(mergeDescendants = true) { selected = on; role = Role.RadioButton; contentDescription = listOf(name, detail, price).filter { it.isNotBlank() }.joinToString(", ") }
            .padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Column(Modifier.weight(1f)) {
            T(name, m.type.body.copy(fontSize = 15.sp, fontWeight = FontWeight.SemiBold), m.t.ink, maxLines = 1)
            if (detail.isNotBlank()) T(detail, m.scale.caption, m.t.muted, maxLines = 1)
        }
        if (price.isNotBlank()) T(price, m.scale.label.copy(fontFeatureSettings = "tnum"), m.t.ink, maxLines = 1)
        Box(Modifier.width(20.dp), contentAlignment = Alignment.Center) { if (on) SIc("check", 18.dp, m.t.accent) }
    }
}

/**
 * Photo's owner-only Model pill (WS7): the studio's photo model (Auto) or any image model, custom ones marked "(yours)",
 * each with its price a photo. Members never see it.
 */
@Composable
fun PhotoModelPill(ui: ComposerUi) {
    val p = ui.photo ?: return
    if (!ui.owner) return
    val list = ModelPicker.engines(ui.catalog, "image")
    if (list.isEmpty()) return
    val cur = list.firstOrNull { it.id == p.draft.imageModel }
    val items = listOf("Auto" to (p.draft.imageModel == null)) + list.map { e ->
        (listOf(e.name, e.price).filter { it.isNotBlank() }.joinToString(" · ") + if (e.custom) " (yours)" else "") to (e.id == p.draft.imageModel)
    }
    MenuPill("cube", cur?.name ?: "Auto", "Model (owner)", items) { i -> p.setImageModel(list.getOrNull(i - 1)?.id) }
}

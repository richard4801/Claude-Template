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
// a model or provider name and keep the quality tiers. Order: this quality's ladder, then every other model, then the
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
    /** WS13: the purposes it serves (empty = any). */
    val purposes: List<String> = emptyList(),
) {
    val tier: String? get() = tiers.firstOrNull()

    /** The resolution it runs at on [quality]: that ladder's, else its default. */
    fun resolutionOn(quality: String): String? = ladderRes[quality] ?: resolution

    /** $/s at [res] (the resolution's own price when the server lists it). */
    fun perSecAt(res: String?): Double? = resolutions.firstOrNull { it.id == res }?.perSec ?: perSec

    /** Shared copy with the Mac (WS6): "4, 6 or 8 s, 9:16 and 16:9", "3–30 s, 4 shapes". */
    val limits: String get() = listOfNotNull(
        when {
            !allowedSeconds.isNullOrEmpty() -> if (allowedSeconds.size > 1) allowedSeconds.dropLast(1).joinToString(", ") + " or ${allowedSeconds.last()} s" else "${allowedSeconds.single()} s"
            minSeconds != null && maxSeconds != null && minSeconds != maxSeconds -> "$minSeconds–$maxSeconds s"
            maxSeconds != null -> "$maxSeconds s"
            else -> null
        },
        when (aspectRatios.size) { 0 -> null; 1 -> aspectRatios[0]; 2 -> "${aspectRatios[0]} and ${aspectRatios[1]}"; else -> "${aspectRatios.size} shapes" },
    ).joinToString(", ")

    /** A resolution's short label ("720p"). */
    fun resLabel(r: String): String = resolutions.firstOrNull { it.id == r }?.label?.substringBefore(' ')?.ifBlank { null } ?: r

    /** The row's price chips, shared with the Mac: one per resolution ("720p  $0.050/s"), or one "$0.05 a photo" / "$0.40 a run". */
    val chips: List<Pair<String?, String>> get() {
        val res = resolutions.filter { (it.perSec) > 0 }
        if (kind == "video" && res.isNotEmpty()) return res.map { it.id to "${resLabel(it.id)}  ${ModelPicker.perSec(it.perSec)}" }
        if (kind == "video" && (perSec ?: 0.0) > 0) return listOf(resolution to listOfNotNull(resolution?.let(::resLabel), ModelPicker.perSec(perSec!!)).joinToString("  "))
        return perRun?.takeIf { it > 0 }?.let { listOf(null to "${ModelPicker.money(it)} ${if (kind == "image") "a photo" else "a run"}") } ?: emptyList()
    }

    /** One price, for menus: "720p  $0.157/s", "$0.04 a photo". */
    fun price(res: String? = resolution): String =
        perSecAt(res)?.takeIf { kind == "video" && it > 0 }?.let { listOfNotNull(res?.let(::resLabel), ModelPicker.perSec(it)).joinToString("  ") }
            ?: perRun?.takeIf { it > 0 }?.let { "${ModelPicker.money(it)} ${if (kind == "image") "a photo" else "a run"}" }
            ?: res?.let(::resLabel).orEmpty()

    val price: String get() = price(resolution)
}

/** The three groups the picker shows. */
data class PickerGroups(val ladder: List<PickerEngine>, val others: List<PickerEngine>, val custom: List<PickerEngine>) {
    val all get() = ladder + others + custom
    val isEmpty get() = all.isEmpty()
}

object ModelPicker {
    /** Per second, as the Mac: 3 decimals below $0.10 ("$0.050/s", "$0.065/s"), cents from $0.10 ("$0.16/s"). */
    fun perSec(v: Double): String = "$" + String.format(java.util.Locale.US, if (v < 0.1) "%.3f" else "%.2f", v) + "/s"

    /** A photo or a run, in cents: "$0.05", "$0.40". */
    fun money(v: Double): String = "$" + String.format(java.util.Locale.US, "%.2f", v)

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
                    e.minSeconds, e.maxSeconds, e.allowedSeconds, e.aspectRatios, e.perSec, e.inputs, e.custom, e.perRun, e.kind, ladderRes(e.model), e.purposes)
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
    fun groups(cat: SuiteCatalog?, quality: String, kind: String = "video", purpose: String? = null): PickerGroups {
        // WS13: engines list their purposes; Talking and UGC take narrower lists than Shot. An entry without purposes fits any.
        val fit = engines(cat, kind).filter { e -> purpose == null || e.purposes.isEmpty() || purpose in e.purposes }
        val (custom, core) = fit.partition { it.custom }
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

/** The pinned model as the Mac writes it: "Kling 4.0, 1080p" (a comma, no middle dot); "Auto" on Auto. */
fun ComposerDraft.modelLabel(cat: SuiteCatalog?): String =
    ModelPicker.find(cat, engineModel)?.let { e -> e.name + ((resolution ?: e.resolutionOn(quality))?.let { r -> ", " + e.resLabel(r) } ?: "") }
        ?: if (engineModel == null) "Auto" else engineModel

/** The pill: "Model" on Auto, else the pinned model ("Kling 4.0, 1080p"). */
fun ComposerDraft.modelPill(cat: SuiteCatalog?): String = if (engineModel == null) "Model" else modelLabel(cat)

/** The tablet menu's items: Auto, then every model as "Kling 4.0, 720p  $0.157/s". Index 0 is Auto. */
fun modelMenuItems(d: ComposerDraft, groups: PickerGroups): List<Pair<String, Boolean>> =
    listOf("Auto" to (d.engineModel == null)) + groups.all.map { e ->
        (listOf(e.name, e.price(e.resolutionOn(d.quality))).filter { it.isNotBlank() }.joinToString(", ") + if (e.custom) " (yours)" else "") to (e.id == d.engineModel)
    }

/**
 * The phone's model list (inside the composer's Settings sheet, always dark): Auto, then the groups with a small heading
 * each. One row per engine: name, its lengths and shapes, and its price per second at its resolution.
 */
@Composable
fun ModelPickerList(d: ComposerDraft, groups: PickerGroups, onPick: (PickerEngine?, String?) -> Unit) =
    ModelList(d.engineModel, d.resolution, d.quality, groups, "MUSE picks the model for this quality", onPick)

/**
 * The owner's model list, shared by every surface (WS7): Auto (with [autoLine]), then "On <Quality>" (when there's a
 * [quality]), "Other models" (or "Models" without a quality) and "Your providers". [selected] / [selectedRes] are the
 * pinned model and resolution (null = Auto).
 */
@Composable
fun ModelList(selected: String?, selectedRes: String?, quality: String?, groups: PickerGroups, autoLine: String, onPick: (PickerEngine?, String?) -> Unit) {
    val m = muse
    Column(Modifier.fillMaxWidth().testTag("model_picker"), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        ModelRow("Auto", autoLine, emptyList(), null, selected == null, {}) { onPick(null, null) }
        listOf(
            (quality?.let { "On ${SuiteRules.tierLabel(it)}" } ?: "") to groups.ladder,
            (if (quality == null) "Models" else "Other models") to groups.others,
            "Your providers" to groups.custom,
        ).filter { it.second.isNotEmpty() }.forEach { (title, list) ->
            T(title, m.scale.caption, m.t.muted, Modifier.padding(top = 10.dp, bottom = 2.dp), maxLines = 1)
            list.forEach { e ->
                val on = e.id == selected
                val detail = listOfNotNull(e.tier?.takeIf { quality != null && quality !in e.tiers }?.let { SuiteRules.tierLabel(it) }, e.limits.ifBlank { null }).joinToString(", ")
                // The chip lit is the resolution it would run at: the pinned one, else this quality's.
                val res = if (on) selectedRes ?: quality?.let(e::resolutionOn) ?: e.resolution else quality?.let(e::resolutionOn) ?: e.resolution
                ModelRow(e.name, detail, e.chips, res, on, { r -> onPick(e, r) }) { onPick(e, null) }
            }
        }
    }
}

/**
 * One model: its name, the limits line, and its price chips (one per resolution; tapping a chip pins that resolution).
 * Tapping the row pins it at this quality's resolution.
 */
@Composable
private fun ModelRow(name: String, detail: String, chips: List<Pair<String?, String>>, lit: String?, on: Boolean, onChip: (String?) -> Unit, onClick: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(12.dp)
    Column(
        Modifier.fillMaxWidth().heightIn(min = 56.dp).clip(shape).background(if (on) m.t.surface2 else m.t.surface).press(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(Modifier.fillMaxWidth().semantics(mergeDescendants = true) { selected = on; role = Role.RadioButton; contentDescription = listOf(name, detail).filter { it.isNotBlank() }.joinToString(", ") },
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Column(Modifier.weight(1f)) {
                T(name, m.type.body.copy(fontSize = 15.sp, fontWeight = FontWeight.SemiBold), m.t.ink, maxLines = 1)
                if (detail.isNotBlank()) T(detail, m.scale.caption, m.t.muted, maxLines = 1)
            }
            Box(Modifier.width(20.dp), contentAlignment = Alignment.Center) { if (on) SIc("check", 18.dp, m.t.accent) }
        }
        if (chips.isNotEmpty()) Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            chips.forEach { (res, label) -> DarkChip(label, on && (chips.size == 1 || res == lit)) { onChip(res) } }
        }
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
    // Shared copy with the Mac: Auto is "the studio's photo model"; then "Photo models" and "Your providers" (custom marked).
    val ordered = list.filterNot { it.custom } + list.filter { it.custom }
    val items = listOf("Auto, the studio's photo model" to (p.draft.imageModel == null)) + ordered.map { e ->
        (listOf(e.name, e.price).filter { it.isNotBlank() }.joinToString(", ") + if (e.custom) " (yours)" else "") to (e.id == p.draft.imageModel)
    }
    MenuPill("cube", cur?.name ?: "Model", "Model, only you see models", items) { i -> p.setImageModel(ordered.getOrNull(i - 1)?.id) }
}

/** WS13's purpose for a composer tool (its model list): Shot, Talking and UGC ad each have their own. */
val ComposerTool.modelPurpose: String? get() = when (this) {
    ComposerTool.SHOT -> "shot"; ComposerTool.TALKING -> "talking"; ComposerTool.UGC -> "ugc"
    ComposerTool.SWAP -> "swap"; ComposerTool.RECAST -> "recast"; ComposerTool.EXTEND -> "extend"
    ComposerTool.PHOTO -> "photo"
    else -> null
}

/** The draft's model list: a Shot with a Directed camera (the Camera stage's guide) picks from WS13's "guide" models. */
val ComposerDraft.pickPurpose: String? get() = if (tool == ComposerTool.SHOT && directed != null) "guide" else tool.modelPurpose

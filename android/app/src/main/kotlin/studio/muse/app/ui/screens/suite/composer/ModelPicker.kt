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

/** One engine the owner can pin: a ladder model at one resolution, or a custom `c_…` model. */
data class PickerEngine(
    val id: String,
    val name: String,
    /** The quality it belongs to (null for custom models: the shot keeps its quality). */
    val tier: String?,
    val resolution: String?,
    val minSeconds: Int?,
    val maxSeconds: Int?,
    val aspectRatios: List<String>,
    val perSec: Double?,
    val inputs: SuiteInputs?,
    val custom: Boolean,
    /** A per-run price instead of per second (custom image-style pricing). */
    val perRun: Double? = null,
) {
    val key get() = "$id@${resolution.orEmpty()}"

    /** "2–10 s · 9:16, 16:9" (lengths, then shapes when the engine limits them). */
    val limits: String get() = listOfNotNull(
        when { minSeconds != null && maxSeconds != null && minSeconds != maxSeconds -> "$minSeconds–$maxSeconds s"; maxSeconds != null -> "$maxSeconds s"; else -> null },
        aspectRatios.takeIf { it.isNotEmpty() }?.joinToString(", "),
    ).joinToString(" · ")

    /** "$0.065/s · 720p", "$0.04 a run", or the resolution alone when the server sends no price. */
    val price: String get() = listOfNotNull(
        perSec?.let { "${ModelPicker.rate(it)}/s" } ?: perRun?.let { "${ModelPicker.rate(it)} a run" },
        resolution?.ifBlank { null },
    ).joinToString(" · ")
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

    /** Every engine in the owner's catalog: `engines[]` when the server sends it, else each tier's models; plus custom video models. */
    fun engines(cat: SuiteCatalog?): List<PickerEngine> {
        cat ?: return emptyList()
        val core = cat.engines?.map { e ->
            PickerEngine(e.model, e.name.ifBlank { e.model }, e.tier, e.resolution.ifBlank { null }, e.minSeconds, e.maxSeconds, e.aspectRatios, e.perSec, e.inputs, e.custom)
        } ?: cat.tiers.filter { it.available }.flatMap { t ->
            t.models.orEmpty().map { m ->
                PickerEngine(m.model, m.name.ifBlank { m.model }, t.id, m.resolution.ifBlank { null }, m.minSeconds ?: t.minSeconds, m.maxSeconds ?: t.maxSeconds,
                    emptyList(), m.perSec, m.inputs, custom = false)
            }
        }
        val custom = cat.custom.orEmpty().filter { it.kind == "video" && core.none { c -> c.id == it.id } }.map { c ->
            val i = c.inputs
            PickerEngine(c.id, c.name.ifBlank { c.id }, null, null, c.minSeconds, c.maxSeconds, c.aspectRatios,
                c.price?.takeIf { it.basis == "per_second" }?.usd,
                i?.let { SuiteInputs(start = it.startImage, end = it.endImage, images = it.referenceImages) }, custom = true,
                perRun = c.price?.takeIf { it.basis != "per_second" }?.usd)
        }
        return (core + custom).distinctBy { it.key }
    }

    /** The picker's groups for a shot on [quality]: that quality's ladder first, then the rest, then "Your providers". */
    fun groups(cat: SuiteCatalog?, quality: String): PickerGroups {
        val all = engines(cat)
        val (custom, core) = all.partition { it.custom }
        val (ladder, others) = core.partition { it.tier == quality }
        // Others in quality order (Draft → Cinema), keeping each ladder's own order.
        val order = cat?.tiers?.map { it.id } ?: SuiteRules.TIERS
        return PickerGroups(ladder, others.sortedBy { e -> order.indexOf(e.tier).let { if (it < 0) Int.MAX_VALUE else it } }, custom)
    }

    /** The engine a draft has pinned, or null (Auto, or a pin the catalog no longer has). */
    fun find(cat: SuiteCatalog?, id: String?, resolution: String?): PickerEngine? {
        id ?: return null
        val all = engines(cat).filter { it.id == id }
        return all.firstOrNull { it.resolution == resolution } ?: all.firstOrNull()
    }
}

/**
 * Pins [e] for this shot (null = Auto). A ladder engine also moves the quality to its own, so the price and the quality
 * label agree; a custom model keeps the quality. Length and Shape are clamped to what the engine takes.
 */
fun ComposerDraft.pinEngine(e: PickerEngine?): ComposerDraft {
    if (e == null) return copy(engineModel = null, resolution = null)
    var d = copy(engineModel = e.id, resolution = e.resolution, quality = e.tier ?: quality)
    val lo = e.minSeconds; val hi = e.maxSeconds
    if (lo != null && hi != null && hi >= lo) d = d.copy(duration = d.duration.coerceIn(lo, hi))
    else if (hi != null) d = d.copy(duration = d.duration.coerceAtMost(hi))
    if (e.aspectRatios.isNotEmpty() && d.aspect !in e.aspectRatios) d = d.copy(aspect = e.aspectRatios.firstOrNull { it in ComposerDraft.SHAPES } ?: e.aspectRatios.first())
    return d
}

/** The pill and row value: "Auto", or the pinned engine's name with its resolution. */
fun ComposerDraft.modelLabel(cat: SuiteCatalog?): String =
    ModelPicker.find(cat, engineModel, resolution)?.let { e -> e.name + (e.resolution?.let { " · $it" } ?: "") } ?: if (engineModel == null) "Auto" else engineModel

/** The tablet menu's items: Auto, then every engine as "Name · 720p · $0.065/s". Index 0 is Auto. */
fun modelMenuItems(d: ComposerDraft, groups: PickerGroups): List<Pair<String, Boolean>> =
    listOf("Auto" to (d.engineModel == null)) + groups.all.map { e ->
        (listOf(e.name, e.price).filter { it.isNotBlank() }.joinToString(" · ") + if (e.custom) " (yours)" else "") to (e.id == d.engineModel && (e.resolution == null || e.resolution == d.resolution))
    }

/**
 * The phone's model list (inside the composer's Settings sheet, always dark): Auto, then the groups with a small heading
 * each. One row per engine: name, its lengths and shapes, and its price per second at its resolution.
 */
@Composable
fun ModelPickerList(d: ComposerDraft, groups: PickerGroups, onPick: (PickerEngine?) -> Unit) {
    val m = muse
    Column(Modifier.fillMaxWidth().testTag("model_picker"), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        ModelRow("Auto", "MUSE picks the engine for this quality", "", d.engineModel == null) { onPick(null) }
        fun section(title: String, list: List<PickerEngine>) = title to list
        listOf(
            section("${SuiteRules.tierLabel(d.quality)} ladder", groups.ladder),
            section("Other models", groups.others),
            section("Your providers", groups.custom),
        ).filter { it.second.isNotEmpty() }.forEach { (title, list) ->
            T(title, m.scale.caption, m.t.muted, Modifier.padding(top = 10.dp, bottom = 2.dp), maxLines = 1)
            list.forEach { e ->
                val on = e.id == d.engineModel && (e.resolution == null || e.resolution == d.resolution)
                val detail = listOfNotNull(e.tier?.takeIf { e.tier != d.quality }?.let { SuiteRules.tierLabel(it) }, e.limits.ifBlank { null }).joinToString(" · ")
                ModelRow(e.name, detail, e.price, on) { onPick(e) }
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

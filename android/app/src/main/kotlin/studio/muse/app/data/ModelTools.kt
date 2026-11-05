package studio.muse.app.data

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

// Model tools (plans/api.md "Model tools", 2026-11-04): the owner's image model per step (any Replicate model, with the
// catalog), Enhance and Dress up for the 7-image character sheet with review and apply, sheet versions, archive.
// Members never see a model or provider name: they get "Option A" / "Option B" and the owner's defaults.

/** The 7 sheet images in the order the apps show them: three face close-ups, then four full-body angles. */
object Sheet {
    data class SlotInfo(val key: String, val label: String, val face: Boolean)
    val SLOTS = listOf(
        SlotInfo("face", "Face · front", true), SlotInfo("faceTq", "Face · ¾", true), SlotInfo("profile", "Face · profile", true),
        SlotInfo("front", "Full body · front", false), SlotInfo("tq", "Full body · ¾", false), SlotInfo("side", "Full body · side", false),
        SlotInfo("back", "Full body · back", false),
    )
    /** The wire order: the 6 original keys, then faceTq (appended so index-based clients keep working). */
    val KEYS = listOf("face", "profile", "front", "tq", "side", "back", "faceTq")
    /** Without these the sheet isn't "locked" (a missing face ¾ is only a warning, like the other face close-ups). */
    val REQUIRED = listOf("face", "profile", "front", "tq", "side", "back")
    fun label(key: String) = SLOTS.firstOrNull { it.key == key }?.label ?: key
    const val STEP_SHOT = "shot"
    val STEPS = listOf("shot", "edit", "realism", "upscale", "dressA", "dressB")
}

/** A model's price (owner only). kind: per-unit | per-second | unknown. */
@Serializable
data class PriceUnit(val metric: String, val usd: Double, val label: String = "")

@Serializable
data class PriceInfo(
    val kind: String = "unknown",
    val units: List<PriceUnit> = emptyList(),
    val usdPerSecond: Double? = null,
    val hardware: String? = null,
    val typicalUsd: Double? = null,
    val source: String? = null,
)

/** One Replicate model in the owner's catalog picker. compatible null = not read yet. */
@Serializable
data class CatalogModel(
    val id: String,
    val owner: String = "",
    val name: String = "",
    val description: String = "",
    val runCount: Long = 0,
    val official: Boolean = false,
    val coverUrl: String? = null,
    val price: PriceInfo? = null,
    val priceLine: String = "",
    val compatible: Boolean? = null,
    val reasons: List<String> = emptyList(),
    val warnings: List<String> = emptyList(),
) {
    /** "12.4M runs" */
    val runsLabel: String get() = when {
        runCount >= 1_000_000 -> "${"%.1f".format(runCount / 1_000_000.0).removeSuffix(".0")}M runs"
        runCount >= 1_000 -> "${runCount / 1_000}k runs"
        else -> "$runCount runs"
    }
}

@Serializable
data class CollectionRef(val slug: String, val name: String = "", val description: String = "")

@Serializable
data class CatalogPage(val step: String, val label: String = "", val collections: List<CollectionRef> = emptyList(), val models: List<CatalogModel> = emptyList(), val cachedAt: Long = 0)

@Serializable
data class InputField(
    val name: String, val type: String = "string", val required: Boolean = false, val default: JsonElement? = null,
    val minimum: Double? = null, val maximum: Double? = null, val description: String? = null, val mappedAs: String? = null,
)

/** GET /v1/image-models/model: one model in full (paste any owner/model, advanced view). */
@Serializable
data class ModelDetail(
    val id: String, val name: String = "", val owner: String = "", val description: String = "", val runCount: Long = 0, val official: Boolean = false,
    val priceLine: String = "", val compatible: Boolean? = null, val reasons: List<String> = emptyList(), val warnings: List<String> = emptyList(),
    val inputs: List<InputField> = emptyList(), val version: String? = null,
) {
    fun asCatalog() = CatalogModel(id, owner, name, description, runCount, official, null, null, priceLine, compatible, reasons, warnings)
}

/** One step's model in owner Settings → Engines → Image models. */
@Serializable
data class StepModel(
    val step: String,
    val label: String = "",
    val model: String = "",
    val defaultModel: String = "",
    val isDefault: Boolean = true,
    val name: String = "",
    val official: Boolean = true,
    val description: String = "",
    val price: PriceInfo? = null,
    val priceLine: String = "",
    val compatible: Boolean = true,
    val reasons: List<String> = emptyList(),
    val warnings: List<String> = emptyList(),
    val extra: JsonObject = JsonObject(emptyMap()),
)

@Serializable
data class StepModels(val steps: List<StepModel> = emptyList()) {
    fun of(step: String) = steps.firstOrNull { it.step == step }
}

@Serializable
data class SetStepModelRequest(val model: String, val extra: JsonObject? = null)

// ---------------------------------------------------------------- Enhance and Dress up

@Serializable
data class OptionInfo(val id: String, val label: String, val detail: String = "")

@Serializable
data class OwnerModelName(val model: String = "", val name: String = "")

@Serializable
data class EnhanceFeatures(
    val available: Boolean = true,
    val realism: List<OptionInfo> = listOf(OptionInfo("off", "Off"), OptionInfo("subtle", "Subtle"), OptionInfo("balanced", "Balanced"), OptionInfo("strong", "Strong")),
    val upscale: List<OptionInfo> = listOf(OptionInfo("off", "Off"), OptionInfo("2x", "2×"), OptionInfo("4x", "4×")),
    /** Owner only: realism / upscale → the current model. */
    val models: Map<String, OwnerModelName>? = null,
)

@Serializable
data class DressUpFeatures(
    val available: Boolean = true,
    val options: List<OptionInfo> = listOf(OptionInfo("a", "Option A", "Keeps each photo closest"), OptionInfo("b", "Option B", "Richer detail"),
        OptionInfo("both", "Both", "Makes both · pick per photo")),
    /** Owner only: dressA / dressB → the current model. */
    val models: Map<String, OwnerModelName>? = null,
)

@Serializable
data class ToolsFeatures(val enhance: EnhanceFeatures = EnhanceFeatures(), val dressUp: DressUpFeatures = DressUpFeatures())

@Serializable
data class EnhanceRequest(val realism: String = "balanced", val upscale: String = "2x", val slots: List<String>? = null, val models: Map<String, String>? = null)

@Serializable
data class DressUpRequest(val outfitImage: ImageRef? = null, val name: String? = null, val engine: String = "a", val models: Map<String, String>? = null)

@Serializable
data class ToolEstimate(val images: Int = 0, val estimate: Double = 0.0, val label: String = "", val perImage: Double? = null)

@Serializable
data class ToolResults(val a: ImageRef? = null, val b: ImageRef? = null) {
    fun of(e: String) = if (e == "b") b else a
}

/** One image of a run. state: waiting | running | done | failed. decision: pending | keep | reject. */
@Serializable
data class ToolItem(
    val slot: String,
    val label: String = "",
    val before: ImageRef? = null,
    val results: ToolResults = ToolResults(),
    val state: String = "waiting",
    val decision: String = "pending",
    val pick: String? = null,
    val cost: Double = 0.0,
    val error: String? = null,
)

@Serializable
data class ToolOptions(val realism: String? = null, val upscale: String? = null, val engine: String? = null, val name: String? = null, val outfitImage: ImageRef? = null)

/** kind: enhance | dressup. state: running | review | applied | failed | discarded. */
@Serializable
data class ToolRun(
    val id: String,
    val kind: String,
    val modelId: String,
    val state: String = "running",
    val options: ToolOptions = ToolOptions(),
    val engines: List<String> = listOf("a"),
    val items: List<ToolItem> = emptyList(),
    val estimate: Double = 0.0,
    val cost: Double = 0.0,
    val progress: Double = 0.0,
    val phase: String = "",
    val error: String? = null,
    val createdAt: Long = 0,
    val finishedAt: Long? = null,
    val appliedAt: Long? = null,
    val outfitId: String? = null,
    /** Owner only: step → model used. */
    val models: Map<String, String>? = null,
) {
    val kept: Int get() = items.count { it.decision == "keep" }
    val both: Boolean get() = engines.size > 1
}

@Serializable
data class DecideRequest(val decision: String, val pick: String? = null)

@Serializable
data class PickRequest(val pick: String)

@Serializable
data class RetryRequest(val engine: String? = null)

@Serializable
data class ApplyRequest(val name: String? = null)

@Serializable
data class ApplyResponse(val run: ToolRun, val model: Model, val outfit: Outfit? = null)

@Serializable
data class SheetVersion(val id: String, val createdAt: Long = 0, val reason: String = "enhance", val slots: List<SheetSlot> = emptyList())

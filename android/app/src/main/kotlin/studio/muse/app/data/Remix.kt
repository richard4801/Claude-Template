package studio.muse.app.data

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject

// New Swap (beta, plans/new-swap.md; owner-approved for Android 2026-11-14): remix a clip with toggles. The same server
// contract as the Mac's NewSwap.swift: POST /v1/suite/shots[/estimate] with mode "remix", `remix` (only the toggles that
// are on), `range` (the trimmer's part), `keepAudio` and `engineModel` (null = Auto); POST /v1/suite/remix/models for the
// model list; POST /v1/clips/from-take for a Library take as the clip. Anything off is kept from the clip.

@Serializable data class RemixBackground(val mode: String, val words: String? = null, val image: ImageRef? = null, val name: String? = null)
@Serializable data class RemixOutfit(val kind: String, val outfitId: String? = null, val image: ImageRef? = null, val name: String? = null, val words: String? = null)
@Serializable data class RemixCharacter(val kind: String, val modelId: String? = null, val image: ImageRef? = null, val name: String? = null)
@Serializable data class RemixLook(val words: String)

/** The changes. A toggle left out is kept from the clip. */
@Serializable
data class RemixToggles(
    val background: RemixBackground? = null,
    val outfit: RemixOutfit? = null,
    val character: RemixCharacter? = null,
    val look: RemixLook? = null,
)

enum class RemixBackgroundMode(val label: String) { DESCRIBE("Describe"), PHOTO("New photo") }
enum class RemixOutfitKind(val label: String) { OUTFIT("Her outfit"), PRODUCT("Product photo"), WORDS("Words") }
/** Character: her (default, strict figure lock), or the optional face swap from a photo. */
enum class RemixCharacterKind(val label: String) { MODEL("Her"), FACE("Face swap") }

/** The part of the clip used (the trimmer), in seconds. */
data class RemixRange(val from: Double, val to: Double) { val seconds: Double get() = maxOf(0.0, to - from) }

/** The panel's draft (the Mac's RemixDraft). */
data class RemixDraft(
    val backgroundOn: Boolean = false, val backgroundMode: RemixBackgroundMode = RemixBackgroundMode.DESCRIBE, val backgroundWords: String = "",
    val backgroundImage: ImageRef? = null, val backgroundName: String? = null,
    val outfitOn: Boolean = false, val outfitKind: RemixOutfitKind = RemixOutfitKind.OUTFIT, val outfitId: String? = null,
    val productImage: ImageRef? = null, val productName: String? = null, val outfitWords: String = "",
    val characterOn: Boolean = false, val characterKind: RemixCharacterKind = RemixCharacterKind.MODEL, val modelId: String? = null,
    val faceImage: ImageRef? = null, val faceName: String? = null,
    val lookOn: Boolean = false, val lookWords: String = "",
    /** The trimmer's part of the clip (null = the whole clip). */
    val range: RemixRange? = null,
    /** The picked model (null = Auto). */
    val engineModel: String? = null,
    val keepAudio: Boolean = true,
) {
    val anyOn: Boolean get() = backgroundOn || outfitOn || characterOn || lookOn

    /** What a turned-on toggle still needs, in plain words (the server says the same), or null when it can be priced. */
    val missing: String? get() {
        if (!anyOn) return "Turn on a change: Background, Outfit, Character or Look & light"
        if (backgroundOn) {
            if (backgroundMode == RemixBackgroundMode.DESCRIBE && backgroundWords.isBlank()) return "Background · Describe: write the new place"
            if (backgroundMode == RemixBackgroundMode.PHOTO && backgroundImage == null) return "Background · New photo: pick a location or upload a picture"
        }
        if (outfitOn) when (outfitKind) {
            RemixOutfitKind.OUTFIT -> if (outfitId == null) return "Outfit: pick one of her outfits"
            RemixOutfitKind.PRODUCT -> if (productImage == null) return "Outfit · Product photo: upload the picture"
            RemixOutfitKind.WORDS -> if (outfitWords.isBlank()) return "Outfit · Words: write what they wear"
        }
        if (characterOn) {
            if (characterKind == RemixCharacterKind.MODEL && modelId == null) return "Character: pick her"
            if (characterKind == RemixCharacterKind.FACE && faceImage == null) return "Face swap: add a photo of the face"
        }
        if (lookOn && lookWords.isBlank()) return "Look & light: write the time of day, light or colour grade"
        return null
    }

    /** The request's `remix` object: only the toggles that are on, each with only its own field. */
    val toggles: RemixToggles get() = RemixToggles(
        background = if (!backgroundOn) null else when (backgroundMode) {
            RemixBackgroundMode.PHOTO -> backgroundImage?.let { RemixBackground("photo", image = it, name = backgroundName?.take(120)) }
            RemixBackgroundMode.DESCRIBE -> RemixBackground("describe", words = backgroundWords.trim().take(400))
        },
        outfit = if (!outfitOn) null else when (outfitKind) {
            RemixOutfitKind.OUTFIT -> outfitId?.let { RemixOutfit("outfit", outfitId = it) }
            RemixOutfitKind.PRODUCT -> productImage?.let { RemixOutfit("product", image = it, name = productName?.take(120)) }
            RemixOutfitKind.WORDS -> RemixOutfit("words", words = outfitWords.trim().take(400))
        },
        character = if (!characterOn) null else when (characterKind) {
            RemixCharacterKind.MODEL -> modelId?.let { RemixCharacter("model", modelId = it) }
            RemixCharacterKind.FACE -> faceImage?.let { RemixCharacter("face", image = it, name = faceName?.take(120)) }
        },
        look = if (lookOn) RemixLook(lookWords.trim().take(400)) else null,
    )

    /** The toggles that are off, for the "Kept from the clip" line. */
    val keptLine: String get() = "Kept from the clip: " + buildList {
        add("motion"); add("camera"); if (keepAudio) add("sound")
        if (!characterOn) add("the person"); if (!outfitOn) add("the outfit"); if (!backgroundOn) add("the place"); if (!lookOn) add("the light")
    }.joinToString(", ")

    /** What Generate sends (null until a clip is in and every turned-on toggle is complete). */
    fun request(clipId: String?, clipName: String?): SuiteShotRequest? {
        if (clipId == null || missing != null) return null
        return SuiteShotRequest(mode = MODE, title = "New Swap · ${clipName ?: "clip"}", prompt = "", quality = "standard", takes = 1, clipId = clipId,
            keepAudio = keepAudio, engineModel = engineModel, remix = toggles, range = range?.let { listOf(it.from, it.to) })
    }

    companion object {
        const val MODE = "remix"

        /** The trimmer: the part of the clip used, inside the clip; the whole clip is null. Tenths of a second. */
        fun clampRange(from: Double, to: Double, clipSeconds: Double): RemixRange? {
            val a = from.coerceIn(0.0, clipSeconds); val b = to.coerceIn(a, clipSeconds)
            if (a <= 0.05 && b >= clipSeconds - 0.05) return null
            return RemixRange(Math.round(a * 10) / 10.0, Math.round(b * 10) / 10.0)
        }
    }
}

/** The estimate's `remix` block: the part used, the trimmer's limits, Auto's reason and the billed seconds. */
@Serializable
data class RemixEstimate(
    val toggles: List<String> = emptyList(),
    val why: String? = null,
    val tested: Boolean = false,
    val keepAudio: Boolean = true,
    val uses: Uses = Uses(),
    val trim: Trim = Trim(),
    val billedSeconds: Billed? = null,
) {
    @Serializable data class Uses(val from: Double = 0.0, val to: Double = 0.0, val of: Double = 0.0)
    @Serializable data class Trim(val needed: Boolean = false, val tooShort: Boolean = false, val minSeconds: Double = 1.0, val maxSeconds: Double = 0.0)
    @Serializable data class Billed(val output: Double = 0.0, val input: Double = 0.0, val inRate: Boolean = false)
}

/** POST /v1/suite/remix/models: every model that edits a video, for these toggles and this clip. */
data class RemixModels(val toggles: List<String> = emptyList(), val auto: Auto? = null, val models: List<Row> = emptyList(), val groups: List<Group>? = null) {
    @Serializable data class Auto(val model: String? = null, val why: String? = null)
    @Serializable data class Limits(val minSeconds: Double = 1.0, val maxSeconds: Double = 0.0, val resolutions: List<String> = emptyList(), val maxImages: Int = 0,
                                    val keepsAudio: Boolean = false, val soundNote: String = "")
    @Serializable data class Price(val resolution: String = "", val perSec: Double? = null, val seconds: Double? = null, val trimNeeded: Boolean? = null,
                                   val usd: Double? = null, val inputBilled: String = "")
    @Serializable data class Group(val id: String, val label: String)
    @Serializable
    data class Row(
        val model: String, val label: String, val support: String = "yes", val reason: String? = null, val notes: List<String>? = null, val route: String? = null,
        val unavailable: String? = null, val tested: Boolean = false, val auto: Boolean = false, val why: String? = null,
        val limits: Limits = Limits(), val price: Price = Price(), val group: String? = null, val warning: String? = null,
    ) {
        val groupId: String get() = group ?: if (auto) "auto" else route ?: "edit"
        val pickable: Boolean get() = unavailable == null
        val adaptedLine: String? get() = if (support == "adapted") notes?.firstOrNull() ?: reason else null
        /** Limits, sound, "not tested yet", or why it can't run. */
        val detail: String get() {
            unavailable?.let { return "Not available: $it" }
            val p = mutableListOf("up to ${trimNum(limits.maxSeconds)} s", limits.resolutions.joinToString("/"), limits.soundNote).filter { it.isNotBlank() }.toMutableList()
            if (support == "prompt") p += "by instruction only"
            if (price.perSec == null) p += "priced when you pick it"
            if (!tested) p += "not tested yet"
            return p.joinToString(", ")
        }
        /** The row's line under the name: why it can't run, else a recent refusal, else what MUSE does, else its limits. */
        val line: String get() = if (unavailable != null) detail else warning ?: adaptedLine ?: detail
    }

    /** The rows by group, in the list's order; empty groups left out. */
    val grouped: List<Pair<Group, List<Row>>> get() = (groups ?: DEFAULT_GROUPS).mapNotNull { g ->
        models.filter { it.groupId == g.id }.takeIf { it.isNotEmpty() }?.let { g to it }
    }

    companion object {
        val DEFAULT_GROUPS = listOf(Group("auto", "Auto picks"), Group("edit", "Edits the clip"), Group("reference", "Uses the clip as reference"),
            Group("frames", "From frames"), Group("text", "From words only"))
        private val json = Json { ignoreUnknownKeys = true; explicitNulls = false; coerceInputValues = true }

        /** A row that doesn't decode is left out alone (owner bug 2026-11-12: one bad row must never hide the whole list). */
        fun parse(e: JsonElement): RemixModels {
            val o = e as? JsonObject ?: return RemixModels()
            fun <T> opt(f: () -> T): T? = runCatching(f).getOrNull()
            return RemixModels(
                toggles = opt { json.decodeFromJsonElement<List<String>>(o["toggles"]!!) } ?: emptyList(),
                auto = opt { json.decodeFromJsonElement<Auto>(o["auto"]!!) },
                models = (o["models"] as? JsonArray)?.mapNotNull { r -> opt { json.decodeFromJsonElement<Row>(r) } } ?: emptyList(),
                groups = opt { json.decodeFromJsonElement<List<Group>>(o["groups"]!!) },
            )
        }
    }
}

/** The model list's request body. */
@Serializable data class RemixModelsRequest(val remix: RemixToggles, val clipId: String? = null, val range: List<Double>? = null)
@Serializable data class ClipFromTakeRequest(val takeId: String)

/** 9.4 → "9.4", 10.0 → "10" (the Mac's Pricing.trimNum). */
fun trimNum(v: Double): String = String.format(java.util.Locale.US, "%.1f", v).removeSuffix(".0")

package studio.muse.app.data

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

// AI suite · the Photo tool (workstream 3, plans/api.md "Photo tool", plans/video-composer.md "Photo tool"). Photoshoot
// folded into the composer: the shoot pipeline with the composer's rig compiled for a still. The server is strict
// (unknown fields are refused), so every optional field is null by default and left out of the JSON.

/**
 * POST /v1/suite/photos[/estimate]. [camera] is the composer's camera JSON without move, mix or tempo (the server would
 * drop them anyway, with a note). [presetId] is a photo template: it carries its own camera and light.
 */
@Serializable
data class PhotoRequest(
    /** The character; null = none (owner 2026-11-11): a reference image is then the photo to work from (server suite/photo.ts). */
    val modelId: String? = null,
    val outfitId: String? = null,
    /** The scene and what she does (the composer's prompt text; #move tokens are never in it). */
    val prompt: String = "",
    val camera: JsonElement? = null,
    /** "Grade with this look": null = the server's default (on). */
    val gradeLook: Boolean? = null,
    /** 1–4 photos; the composer always sends it (default 4). */
    val count: Int? = null,
    val presetId: String? = null,
    val productImage: ImageRef? = null,
    /** Up to 3, each with what it guides: pose, look, scene. */
    val references: List<ShootRef>? = null,
    val seed: Long? = null,
    val lockSeed: Boolean? = null,
    val shuffleSeed: Long? = null,
    val title: String? = null,
    /** AI suite (build step 2): the composer's full draft, stored on every still for "Reuse settings". */
    val draft: SuiteDraft? = null,
    /** WS5/WS7: owner only (403 for members), the image model for this run: "owner/name" or a custom `c_…`. Null = the studio's photo model. */
    val imageModel: String? = null,
    /** The photo's shape (owner 2026-11-14): "4:5", "1:1"…; null = the server's 9:16 (left out, so an older server never sees it). */
    val aspect: String? = null,
)

/** One shape on the Size pill and what the model makes for it: the nearest ratio it takes, or null (no size choice). */
@Serializable
data class PhotoAspectOption(val id: String, val makes: String? = null) {
    /** "4:5", "4:5 · makes 3:4", "4:5 · model's size". */
    val label: String get() = when (makes) { null -> "$id · model's size"; id -> id; else -> "$id · makes $makes" }
}

/** The model this runs on (owner 2026-11-14: "Auto · <model>"). [name] null: hidden from this member. */
@Serializable
data class PhotoModelRef(val id: String? = null, val name: String? = null, val auto: Boolean = true)

/** The preset a Photo estimate ran with (a photo template). */
@Serializable
data class PhotoPresetRef(val id: String, val name: String = "")

/** POST /v1/suite/photos/estimate: the price (count × perPhoto), the still rig check and what was left out. Holds nothing. */
@Serializable
data class PhotoEstimate(
    val tool: String = "photo",
    val count: Int = 4,
    val perPhoto: Double = 0.0,
    val estimate: Double = 0.0,
    /** "about $0.47 · 4 photos" */
    val priceLine: String = "",
    /** "Generate · 4 photos · $0.47" */
    val buttonLabel: String = "",
    val ok: Boolean = true,
    /** "Movement doesn’t apply to photos", "The preset sets its own camera and light". */
    val warnings: List<String> = emptyList(),
    /** The still rules only: deep_focus, wide_close, worm_close, look_clash, prompt_angle, prompt_size. */
    val rig: List<SuiteRigWarning> = emptyList(),
    val look: SuiteLook? = null,
    /** The still's prompt (absent with a preset). */
    val prompt: String? = null,
    val preset: PhotoPresetRef? = null,
    /** Size (owner 2026-11-14; absent from an older server: the Size pill stays hidden): the shape asked, what the model
     *  makes for it, and every shape with its mapping. */
    val aspect: String? = null,
    val makes: String? = null,
    val aspects: List<PhotoAspectOption> = emptyList(),
    /** The model (owner 2026-11-14): the bar's "Auto · <name>". */
    val model: PhotoModelRef? = null,
)

/** POST /v1/suite/photos: the stills, saved as takes (`kind: "shot"`, titled "Photo · …"). */
@Serializable
data class PhotoResult(val tool: String = "photo", val takes: List<Take> = emptyList())

/** The Photo tool's fixed rules (both the composer and demo mode use them). */
object PhotoRules {
    const val TOOL = "photo"
    const val MAX_COUNT = 4
    const val DEFAULT_COUNT = 4
    /** The rig-check rules that make sense for a still (server suite/photo.ts STILL_RULES). */
    val STILL_RULES = setOf("deep_focus", "wide_close", "worm_close", "look_clash", "prompt_angle", "prompt_size")
    const val NO_MOVEMENT = "Movement doesn’t apply to photos"
    const val NO_TEMPO = "Tempo doesn’t apply to photos"
    const val PRESET_RIG = "The preset sets its own camera and light"
    /** The Size pill's shapes when the server doesn't list them (server suite/photo.ts PHOTO_ASPECTS); 9:16 is its default. */
    val ASPECTS = listOf("9:16", "4:5", "3:4", "2:3", "1:1", "3:2", "4:3", "16:9")
    const val DEFAULT_ASPECT = "9:16"

    fun noun(count: Int) = "$count photo${if (count == 1) "" else "s"}"

    /** "Generate · 4 photos · $0.47" (server photoButton). */
    fun button(count: Int, money: String) = "Generate · ${noun(count)} · $money"
}

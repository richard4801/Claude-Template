package studio.muse.app.data

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

// AI suite (workstream 1): the wire types of /v1/suite (plans/api.md "AI suite", server/api/src/suite). Members never see
// providers or models: those fields only come back for the owner (marked "owner") and only the owner's Engines sheet shows them.

/** One option of the Camera picker. Hardware options also carry their bundled render (`hardware/<render>.webp`), name and look caption. */
@Serializable
data class SuiteOption(
    val id: String,
    val label: String = "",
    val description: String = "",
    val render: String? = null,
    val name: String? = null,
    val caption: String? = null,
    /** Composer: false = not offered to members (owners and Directed mode keep it). */
    val visible: Boolean = true,
    /** A merged duplicate: pickers show the survivor with this id instead. */
    val mergedInto: String? = null,
    /** Palettes and film stocks: 5 swatch colours (darkest first) and the LUT the take is graded with. */
    val swatches: List<String> = emptyList(),
    val lut: String? = null,
    /** A short looping preview (mp4/webm URL). Until the loops exist, pickers show the still ([render]). */
    val loop: String? = null,
    /** Lighting and angles: the bundled preview still (`previews/<poster>`). */
    val preview: SuitePreviewRef? = null,
) {
    /** The card's title: the hardware name when it has a render ("Super 35 Digital"), else the label. */
    val title: String get() = name ?: label
}

/** The composer's focal wheel step (`visible` = one of the six shown to members). */
@Serializable
data class SuiteFocal(val mm: Int, val label: String = "", val description: String = "", val visible: Boolean = true)

/** A Movement chip (Featured, UGC, Push…). */
@Serializable
data class SuiteMoveGroup(val id: String, val label: String = "")

@Serializable
data class SuiteMoveOption(
    val id: String,
    val label: String = "",
    val description: String = "",
    val category: String = "",
    val editorBetter: Boolean = false,
    val talkSafe: Boolean = false,
    /** The composer's Movement chip it sits under (see CameraCatalog.moveGroups). */
    val group: String = "",
    /** A short looping preview (mp4/webm URL); until it exists the tile shows a still with a motion arrow. */
    val loop: String? = null,
    /** The bundled loop and its poster (`previews/moves/<id>.mp4|jpg`); null = the drawn still with an arrow. */
    val preview: SuitePreviewRef? = null,
)

/** A bundled composer preview: paths relative to the app's `previews/` assets. */
@Serializable
data class SuitePreviewRef(val video: String? = null, val poster: String? = null, val seconds: Double? = null)

/** The Auto tiles' previews (`camera.autoPreviews`). */
@Serializable
data class SuiteAutoPreviews(val lighting: SuitePreviewRef? = null)

/** One of the 16 featured moves of the camera bag (UGC first), with its filter tag: ugc / cinematic / energy / subtle. */
@Serializable
data class SuiteLibraryMove(val id: String, val label: String = "", val tag: String = "", val description: String = "", val category: String = "")

@Serializable
data class SuiteOptic(val id: String, val render: String? = null, val name: String = "", val caption: String = "")

@Serializable
data class SuiteGrip(val move: String, val render: String? = null, val name: String = "", val caption: String = "")

@Serializable
data class SuitePreset(val id: String, val label: String = "", val description: String = "", val spec: JsonObject? = null)

/** GET /v1/suite/camera (also `catalog.camera`). The apps draw what this returns; demo mode bundles a copy. */
@Serializable
data class CameraCatalog(
    val presets: List<SuitePreset> = emptyList(),
    val bodies: List<SuiteOption> = emptyList(),
    val lenses: List<SuiteOption> = emptyList(),
    val focalLengths: List<Int> = emptyList(),
    val focals: List<SuiteFocal> = emptyList(),
    val apertures: List<SuiteOption> = emptyList(),
    val looks: List<SuiteOption> = emptyList(),
    val frameRates: List<SuiteOption> = emptyList(),
    val shutters: List<SuiteOption> = emptyList(),
    val lighting: List<SuiteOption> = emptyList(),
    val palettes: List<SuiteOption> = emptyList(),
    val optics: List<SuiteOptic> = emptyList(),
    val grips: List<SuiteGrip> = emptyList(),
    val moves: List<SuiteMoveOption> = emptyList(),
    val library: List<SuiteLibraryMove> = emptyList(),
    val moveGroups: List<SuiteMoveGroup> = emptyList(),
    val heights: List<SuiteOption> = emptyList(),
    val shotSizes: List<SuiteOption> = emptyList(),
    val genres: List<SuiteOption> = emptyList(),
    val eras: List<SuiteOption> = emptyList(),
    val tempos: List<SuiteOption> = emptyList(),
    val emotions: List<String> = emptyList(),
    /** UGC ad: the ad formats (unboxing, review, try_on…), sent as `camera.style.format`. Older catalogs: none. */
    val ugcFormats: List<SuiteOption> = emptyList(),
    val autoPreviews: SuiteAutoPreviews = SuiteAutoPreviews(),
) {
    fun move(id: String?) = moves.firstOrNull { it.id == id }
    fun libraryMove(id: String?) = library.firstOrNull { it.id == id }
    fun moveLabel(id: String?) = libraryMove(id)?.label ?: move(id)?.label ?: id.orEmpty()
}

/**
 * The input slots a tier (or, for the owner, one engine) takes: start / end / middle frames, reference images and videos,
 * one audio track. Counts are already capped to what a shot request can carry. `framesWithRefs` false = with a start or
 * end frame, references are not sent on this quality.
 */
@Serializable
data class SuiteInputs(
    val start: Boolean = false,
    val end: Boolean = false,
    val middle: Int = 0,
    val images: Int = 0,
    val videos: Int = 0,
    val audio: Boolean = false,
    val framesWithRefs: Boolean = false,
) {
    companion object {
        val NONE = SuiteInputs()
        /** A server from before `inputs`: keyframes = start + end, references = images and videos. */
        fun legacy(canKeyframes: Boolean, canReferences: Boolean) = SuiteInputs(
            start = canKeyframes, end = canKeyframes, images = if (canReferences) 6 else 0, videos = if (canReferences) 3 else 0, framesWithRefs = canKeyframes && canReferences,
        )
    }
}

/** owner: the models a tier runs, in ladder order, each with the inputs it takes. */
@Serializable
data class SuiteTierModel(val model: String, val name: String = "", val resolution: String = "", val inputs: SuiteInputs? = null)

/** A quality tier (Draft / Standard / HD / Cinema). */
@Serializable
data class SuiteTier(
    val id: String,
    val label: String = "",
    val detail: String = "",
    val available: Boolean = false,
    val resolution: String? = null,
    val fromPerSec: Double? = null,
    val maxSeconds: Int? = null,
    /** The shortest take this tier makes (with [maxSeconds], the composer's Length slider range). */
    val minSeconds: Int? = null,
    val canKeyframes: Boolean = false,
    val canReferences: Boolean = false,
    val canGuide: Boolean = false,
    /** What the tier takes (see [slots]). */
    val inputs: SuiteInputs? = null,
    /** owner */
    val models: List<SuiteTierModel>? = null,
) {
    /** The input slots this tier takes ([inputs], or worked out from the older flags). */
    val slots: SuiteInputs get() = inputs ?: SuiteInputs.legacy(canKeyframes, canReferences)
    /** Owner: what one engine of this tier takes (falls back to the tier's). */
    fun slotsFor(engineModel: String?): SuiteInputs = engineModel?.let { id -> models?.firstOrNull { it.model == id }?.inputs } ?: slots
}

/** A composer tool the server offers now (`catalog.tools`): shot, swap, recast, storyboard, talking, ugc_ad, extend. */
@Serializable
data class SuiteToolInfo(val id: String, val available: Boolean = false, val comingSoon: Boolean = false)

/** A place in the studio's locations library (`@location` in the prompt). GET/POST/DELETE /v1/suite/locations. */
@Serializable
data class SuiteLocation(val id: String, val name: String = "", val image: ImageRef = ImageRef(), val createdAt: Long = 0)

@Serializable
data class SuiteLocationCreate(val name: String, val image: ImageRef)

/** GET /v1/suite/catalog. `enabled` false = the server's SUITE_MODE is off; `test` = mock renders (free). */
@Serializable
data class SuiteCatalog(
    val enabled: Boolean = false,
    val test: Boolean = false,
    val defaultQuality: String = "draft",
    val tiers: List<SuiteTier> = emptyList(),
    val modes: List<String> = emptyList(),
    val recastMaxPeople: Int = 4,
    val aspectRatios: List<String> = emptyList(),
    val takesMax: Int = 4,
    val camera: CameraCatalog = CameraCatalog(),
    /** Which composer tools are live; null = an older server (the apps' built-in list applies). */
    val tools: List<SuiteToolInfo>? = null,
) {
    fun tier(id: String?) = tiers.firstOrNull { it.id == id }
    /** Whether a tool can Generate: the catalog's word, else [fallback]. */
    fun toolAvailable(id: String, fallback: Boolean): Boolean = tools?.firstOrNull { it.id == id }?.available ?: fallback
}

// ---------------------------------------------------------------- the request

@Serializable
data class SuiteMove(val id: String, val intensity: Double? = null, val speed: String? = null)

@Serializable
data class SuiteRig(
    val body: String? = null, val lens: String? = null, val focalMm: Int? = null, val aperture: String? = null,
    val look: String? = null, val fps: String? = null, val shutter: String? = null,
)

@Serializable
data class SuiteLighting(val preset: String? = null)

@Serializable
data class SuitePalette(val preset: String? = null)

@Serializable
data class SuiteAngle(val height: String? = null, val shotSize: String? = null)

/** The Camera block of a shot (CameraSpec, `.strict()` on the server: only these keys). */
@Serializable
data class SuiteCameraSpec(
    val mode: String = "preset",
    val preset: String? = null,
    val rig: SuiteRig? = null,
    val lighting: SuiteLighting? = null,
    val palette: SuitePalette? = null,
    val move: SuiteMove? = null,
    val mix: SuiteMove? = null,
    val angle: SuiteAngle? = null,
)

/** A reference video or audio track: an upload's storage key (or an https link). */
@Serializable
data class SuiteMediaRef(val key: String? = null, val url: String? = null, val seconds: Double? = null)

@Serializable
data class SuiteFrames(val start: ImageRef? = null, val middle: List<ImageRef>? = null, val end: ImageRef? = null)

/** role: product | location | style | prop | person. */
@Serializable
data class SuiteRefImage(val image: ImageRef, val role: String = "product", val label: String? = null)

/** use: camera | motion | style. */
@Serializable
data class SuiteRefVideo(val video: SuiteMediaRef, val use: String = "motion")

@Serializable
data class SuiteRefAudio(val audio: SuiteMediaRef)

@Serializable
data class SuiteReferences(val images: List<SuiteRefImage>? = null, val videos: List<SuiteRefVideo>? = null, val audio: SuiteRefAudio? = null)

/** Recast: one person of the source clip → a studio character. */
@Serializable
data class SuiteCastMember(
    val characterId: String,
    val outfitId: String? = null,
    val personIndex: Int? = null,
    val personHint: String? = null,
    val personNote: String? = null,
    val speaking: Boolean? = null,
    /** Who to replace: a square crop of their face from the clip's first frame ("tap a face"). */
    val faceCrop: ImageRef? = null,
)

/** POST /v1/suite/shots[/estimate]. Nulls are left out, so the server's defaults apply. */
@Serializable
data class SuiteShotRequest(
    val mode: String? = null,
    val cast: List<SuiteCastMember>? = null,
    val title: String? = null,
    val modelId: String? = null,
    val outfitId: String? = null,
    val prompt: String = "",
    val duration: Int? = null,
    val aspectRatio: String? = null,
    val quality: String? = null,
    val takes: Int? = null,
    val speaking: Boolean? = null,
    /** Native sound (ambience and effects); null = the server's default (on). */
    val audio: Boolean? = null,
    /** A preset spec, or a Directed mode spec from the camera stage (kept as JSON). */
    val camera: JsonElement? = null,
    val clipId: String? = null,
    val keepAudio: Boolean? = null,
    /** "Grade the take with this look" (default on at the server). */
    val gradeLook: Boolean? = null,
    /** Input slots (InputSlots.kt): start / middle / end frames and references, only those the tier takes. */
    val frames: SuiteFrames? = null,
    val references: SuiteReferences? = null,
    val dryRun: Boolean? = null,
    /** owner only */
    val engineModel: String? = null,
    val resolution: String? = null,
)

// ---------------------------------------------------------------- the answers

@Serializable
data class SuiteCaps(
    val perJob: Double = 0.0, val perDay: Double = 0.0, val spentToday: Double = 0.0, val leftToday: Double = 0.0,
    val ok: Boolean = true, val code: String? = null, val message: String? = null,
)

@Serializable
data class SuiteEstimateCamera(val moves: List<String> = emptyList(), val guideUsed: Boolean = false)

@Serializable
data class SuiteSpeaking(val speaking: Boolean = false, val source: String = "default")

/** Recast: who in the clip becomes whom, and whether their mouth follows speech ("yes" | "no" | "unknown"). */
@Serializable
data class SuiteEstimateCast(val characterId: String, val outfitId: String? = null, val who: String = "", val speaking: String = "unknown")

@Serializable
data class SuiteLicence(
    val kind: String = "", val name: String = "", val notice: String? = null, val blockNewFeatures: Boolean? = null,
    val territoryExcluded: List<String>? = null, val requiresAck: Boolean? = null,
)

/** owner: the engine a shot runs on. */
@Serializable
data class SuiteEngine(
    val model: String = "", val name: String? = null, val provider: String? = null, val ref: JsonElement? = null, val resolution: String? = null,
    val perSec: Double? = null, val billedPerTake: Double? = null, val licence: SuiteLicence? = null, val notice: String? = null, val test: Boolean? = null,
)

/** owner: a ladder step that was skipped, and why. */
@Serializable
data class SuiteTried(val model: String = "", val resolution: String = "", val why: String = "")

/** The take's Look: a palette or film stock and its LUT (`pack:<id>` or `palette:<id>`), applied in the Edit suite. */
@Serializable
data class SuiteLook(val id: String, val kind: String = "palette", val label: String = "", val lut: String = "")

/** POST /v1/suite/shots/estimate. Every Generate shows [buttonLabel] / [priceLine]; a cap problem shows [message]. */
@Serializable
data class SuiteEstimate(
    val quality: String = "draft",
    val label: String = "",
    val resolution: String? = null,
    val seconds: Double = 0.0,
    val takes: Int = 1,
    val mode: String = "text",
    val estimate: Double = 0.0,
    val priceLine: String = "",
    val buttonLabel: String = "",
    val ok: Boolean = true,
    val code: String? = null,
    val message: String? = null,
    val caps: SuiteCaps? = null,
    val warnings: List<String> = emptyList(),
    val camera: SuiteEstimateCamera? = null,
    val prompt: String = "",
    val test: Boolean = false,
    val speaking: SuiteSpeaking? = null,
    /** The Look the take will be graded with (null = none / grading off). */
    val look: SuiteLook? = null,
    val cast: List<SuiteEstimateCast>? = null,
    val keepAudio: Boolean? = null,
    /** owner */
    val engine: SuiteEngine? = null,
    /** owner */
    val tried: List<SuiteTried>? = null,
)

/** GET /v1/suite/shots/{id}. */
@Serializable
data class SuiteShot(val job: Job, val warnings: List<String> = emptyList(), val engine: SuiteEngine? = null)

@Serializable
data class SuiteLadderStep(val model: String, val resolution: String)

@Serializable
data class SuiteResolution(val id: String, val label: String = "", val shortSide: Int = 0, val perSec: Double = 0.0)

/** owner: one model of the registry, with the studio's switches. */
@Serializable
data class SuiteModelView(
    val id: String,
    val name: String = "",
    val provider: String = "",
    /** A model id, or one per mode ({t2v, i2v, …}). */
    val ref: JsonElement? = null,
    val status: String = "active",
    val resolutions: List<SuiteResolution> = emptyList(),
    val licence: SuiteLicence = SuiteLicence(),
    val enabled: Boolean = true,
    val blocked: Boolean = false,
    val blockedReason: String? = null,
    val needsAck: Boolean = false,
    val configured: Boolean = true,
    val priceScale: Double = 1.0,
) {
    fun perSec(resolution: String?) = (resolutions.firstOrNull { it.id == resolution } ?: resolutions.firstOrNull())?.perSec?.times(priceScale)
}

@Serializable
data class SuiteCapsSet(val perJob: Double = 0.0, val perDay: Double = 0.0)

/** GET /v1/suite/settings (owner). */
@Serializable
data class SuiteSettings(
    val mode: String = "off",
    val caps: SuiteCapsSet = SuiteCapsSet(),
    val spentToday: Double = 0.0,
    val ladder: Map<String, List<SuiteLadderStep>> = emptyMap(),
    val defaultLadder: Map<String, List<SuiteLadderStep>> = emptyMap(),
    val models: List<SuiteModelView> = emptyList(),
    val providers: Map<String, Boolean> = emptyMap(),
) {
    fun model(id: String?) = models.firstOrNull { it.id == id }
}

/** POST /v1/suite/camera/compile: what the camera becomes on a quality's first model (owner also gets the engine). */
@Serializable
data class SuiteCompileRequest(val camera: JsonElement, val quality: String? = null, val duration: Int? = null)

@Serializable
data class SuiteCompiled(val text: String = "", val moves: List<String> = emptyList(), val guideUsed: Boolean = false, val warnings: List<String> = emptyList(), val engine: SuiteEngine? = null)

/** PATCH /v1/suite/settings (owner). */
@Serializable
data class SuiteModelPatch(val enabled: Boolean? = null)

@Serializable
data class SuiteSettingsPatch(val models: Map<String, SuiteModelPatch>? = null)

/** Fixed suite wording and the rules both apps share. */
object SuiteRules {
    const val ENGINE = "suite"
    val TIERS = listOf("draft", "standard", "hd", "cinema")
    const val MAX_MOVES = 2
    const val MAX_CAST = 4
    /** Moves that can't be combined with another (static, time) and aerial ones. */
    private val SOLO = setOf("static", "time", "aerial")

    /** Two moves of different kinds; never static, time or aerial (server canMix). */
    fun canMix(a: SuiteMoveOption?, b: SuiteMoveOption?): Boolean {
        if (a == null || b == null || a.id == b.id || a.category == b.category) return false
        return a.category !in SOLO && b.category !in SOLO
    }

    fun tierLabel(id: String?) = when (id) { "standard" -> "Standard"; "hd" -> "HD"; "cinema" -> "Cinema"; else -> "Draft" }

    /** Words members must never see (server test PROVIDER_WORDS, plus the GPU words of the studio). */
    val PROVIDER_WORDS = Regex("(?i)\\b(replicate|fal|runpod|minimax|h3|kling|seedance|veo|wan|ltx|lightricks|bytedance|google|sora)\\b")

    /** The member's view of an estimate: no engine, no tried steps, no model words in what's shown. */
    fun memberSafe(e: SuiteEstimate): SuiteEstimate = e.copy(engine = null, tried = null, prompt = "",
        warnings = e.warnings.filterNot { PROVIDER_WORDS.containsMatchIn(it) })

    /** The member's view of the catalog: tiers without their models. */
    fun memberSafe(c: SuiteCatalog): SuiteCatalog = c.copy(tiers = c.tiers.map { it.copy(models = null) })

    /** The server variable the owner sets to turn the suite on, and its two values. */
    const val MODE_VAR = "SUITE_MODE"
}

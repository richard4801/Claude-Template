package studio.muse.app.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import studio.muse.core.ClipUse
import studio.muse.core.Engine
import studio.muse.core.Pricing
import studio.muse.core.Quality
import studio.muse.core.RenderSpec

/**
 * Wire types shared by both MuseApi implementations and the mock server (see plans/api.md).
 * Images are either a bundled sample (`asset`, e.g. "g_front") or a URL the client can load (`url`).
 */
@Serializable
data class ImageRef(val asset: String? = null, val url: String? = null) {
    companion object {
        fun asset(k: String) = ImageRef(asset = k)
    }
}

/** role: "owner" (loads the studio balance, invites people, sends credit) or "member". Also GET /v1/auth/me. */
@Serializable
data class User(val id: String, val studioName: String = "", val email: String, val role: String = "member") {
    val owner get() = role == "owner"
}

@Serializable
data class AuthResponse(val token: String, val user: User)

@Serializable
data class SignInRequest(val email: String, val password: String)

/** Both attestations are required, unticked by default. Consent otherwise lives only in the Terms. */
@Serializable
data class SignUpRequest(
    val studioName: String,
    val email: String,
    val password: String,
    val attestAdultRightsOriginal: Boolean,
    val attestLabelAi: Boolean,
    /** Required by the real API ("MUSE-XXXX-XXXX-XXXX"; the owner's first code is free text). Omitted when null. */
    val inviteCode: String? = null,
)

/** One of the 7 character-sheet slots (face, profile, front, tq, side, back, faceTq; see [Sheet]). source: "upload" (yours) or "generated" (filled in). */
@Serializable
data class SheetSlot(val key: String, val image: ImageRef? = null, val source: String = "upload", val busy: Boolean = false)

@Serializable
data class Model(
    val id: String,
    val name: String,
    val age: Int,
    val niche: String,
    val look: String = "",
    val neverAdd: List<String> = emptyList(),
    val slots: List<SheetSlot> = emptyList(),
    val outfitIds: List<String> = emptyList(),
    val personality: String? = null,
    val notes: String? = null,
    /** Archived by the owner: hidden from every list (plans/api.md "Model tools" §7). */
    val archived: Boolean = false,
    val archivedAt: Long? = null,
    /** AI suite (build step 2): her default rig, filled into the composer's rows still on Auto when she's @-mentioned ([applyDefaultRig]). */
    val defaultRig: SuiteRig? = null,
) {
    val filled: Int get() = slots.count { it.image != null && !it.busy }
    /** The 6 original sheet images are in (a missing face ¾ is only a warning). */
    val locked: Boolean get() = Sheet.REQUIRED.all { k -> slots.any { it.key == k && it.image != null && !it.busy } }
    val hasBothFaces: Boolean get() = slots.count { (it.key == "face" || it.key == "profile") && it.image != null } == 2
    fun slot(key: String) = slots.firstOrNull { it.key == key }
    val cover: ImageRef? get() = slot("face")?.image ?: slots.firstOrNull { it.image != null }?.image
    val initial: String get() = name.take(1).uppercase()
}

@Serializable
data class CreateModelRequest(val name: String, val age: Int, val niche: String)

@Serializable
data class SetSlotRequest(val image: ImageRef?, val source: String = "upload")

/** POST /v1/models/{id}/fill-angles (WS13, owner): the image model for the missing angles; empty body = the default. */
@Serializable
data class FillAnglesRequest(val imageModel: String? = null)

/** Outfit set: front, ¾, side, back. mode: describe | photo | own. state: ready | generating. */
@Serializable
data class Outfit(
    val id: String,
    val modelId: String,
    val name: String,
    val mode: String = "describe",
    val description: String = "",
    val angles: List<ImageRef?> = listOf(null, null, null, null),
    val state: String = "ready",
    val prompt: String = "",
    /** What the set really cost once made (exact, pass-through); null before, or from an older server. */
    val cost: Double? = null,
    /** Its face close-ups with its hair, make-up and accessories (face front, face ¾, face side); null on older outfits. */
    val faces: List<ImageRef?>? = null,
    /** When it was made (ms; the folder's date) and who made it (they or the owner may rename/delete it). */
    val createdAt: Long? = null,
    val createdBy: String? = null,
    /** A set that came out partly (some pictures failed while making it; owner 2026-11-12): "5 of 7 made · Redo the
     *  missing ones" and which are missing (OutfitPictures.KEYS names). Null when complete or still being made. */
    val partial: OutfitPartial? = null,
) {
    val front: ImageRef? get() = angles.firstOrNull()
    /** One of its 7 pictures (0–3 angles, 4–6 faces) is missing from a partial set: it gets its own Redo with its price. */
    fun isMissing(i: Int): Boolean = partial?.missing?.contains(OutfitPictures.KEYS.getOrNull(i)) == true
    /** How many of the four angles have a picture (a set can come back with some empty). */
    val madeAngles: Int get() = (0 until 4).count { angles.getOrNull(it) != null }
}

/** A set that came out partly (server outfitView `partial`). */
@Serializable
data class OutfitPartial(val made: Int = 0, val of: Int = 7, val missing: List<String> = emptyList(), val label: String = "")

/** PATCH /v1/outfits/{id}, POST /v1/outfits/{id}/save: the outfit's name (save: null keeps it). */
@Serializable
data class OutfitNameBody(val name: String? = null)

/** POST /v1/outfits/{id}/fill, /faces, /redo: the outfit now and the estimate held for the pictures being made. */
@Serializable
data class OutfitFill(val outfit: Outfit, val cost: Double = 0.0)

/** POST /v1/outfits/{id}/redo: which of the 7 pictures (front | tq | side | back | face | faceTq | profile). */
@Serializable
data class OutfitRedoRequest(val angle: String)

/** One move in POST /v1/outfits/{id}/reorder: swaps the pictures of slots [from] and [to] ([OutfitPictures.KEYS]); nothing is lost. */
@Serializable
data class OutfitMove(val from: String, val to: String)

/** POST /v1/outfits/{id}/reorder (owner or the outfit's maker, free): the moves in order; [dryRun] checks them without saving. */
@Serializable
data class OutfitReorderRequest(val moves: List<OutfitMove>, val dryRun: Boolean? = null)

/** POST /v1/outfits/{id}/reorder: the outfit now and which slots changed. */
@Serializable
data class OutfitReorder(val outfit: Outfit, val changed: List<String> = emptyList())

@Serializable
data class CreateOutfitRequest(
    val modelId: String,
    val name: String,
    val mode: String,
    val description: String = "",
    /** "My own set": one per angle (front, ¾, side, back; null = skipped); the product photo otherwise. */
    val images: List<ImageRef?> = emptyList(),
    /** WS13 (owner): the image model for the set; null = the studio's default. */
    val imageModel: String? = null,
    /** §6: start from her base photos, keeping the ticked pieces (null = a new outfit as before). */
    val base: OutfitBase? = null,
)

/** Which pieces of her base photos an outfit keeps (plans/outfit-head-looks.md §6). */
@Serializable
data class OutfitKeep(val top: Boolean = false, val bottom: Boolean = false, val shoes: Boolean = false, val accessories: Boolean = false) {
    val flags get() = listOf(top, bottom, shoes, accessories)
}

/** A base set's chosen angles (null = the set's own; a missing one uses the front). */
@Serializable
data class OutfitBaseAngles(val front: ImageRef? = null, val tq: ImageRef? = null, val side: ImageRef? = null, val back: ImageRef? = null) {
    operator fun get(i: Int): ImageRef? = listOf(front, tq, side, back)[i]
    fun with(i: Int, r: ImageRef?) = when (i) { 0 -> copy(front = r); 1 -> copy(tq = r); 2 -> copy(side = r); else -> copy(back = r) }
    val isEmpty get() = front == null && tq == null && side == null && back == null
    companion object { val KEYS = listOf("front", "tq", "side", "back") }
}

/**
 * POST /v1/outfits `base`: start from her base photos (her profile photos, or one of her outfits: [outfitId]) with single
 * angles swapped, keeping the ticked pieces and the note.
 */
@Serializable
data class OutfitBase(val source: String = "base", val keep: OutfitKeep = OutfitKeep(), val note: String? = null, val outfitId: String? = null, val angles: OutfitBaseAngles? = null) {
    /** Anything kept: a tick or a note (else the outfit is made as before). */
    val keeping get() = keep.flags.any { it } || !note.isNullOrBlank()

    /** "Keeps the top (the black lace bra). Changes the bottom, the shoes and the accessories." */
    val summary: String get() {
        val names = listOf("top", "bottom", "shoes", "accessories")
        fun and(xs: List<String>) = if (xs.size <= 1) xs.joinToString("") else xs.dropLast(1).joinToString(", ") + " and " + xs.last()
        val kept = names.filterIndexed { i, _ -> keep.flags[i] }.map { "the $it" }
        val rest = names.filterIndexed { i, _ -> !keep.flags[i] }.map { "the $it" }
        val n = note?.trim().orEmpty()
        val k = if (n.isEmpty()) and(kept) else if (kept.isEmpty()) n else "${and(kept)} ($n)"
        if (k.isEmpty()) return "Tick what to keep from her base photos."
        return "Keeps $k. Changes ${if (rest.isEmpty()) "the rest" else and(rest)}."
    }
}

/** status: good | bad | info */
@Serializable
data class ClipCheck(val label: String, val value: String, val status: String, val fix: String? = null)

/** A source clip from the camera roll, with its checks. */
@Serializable
data class Clip(
    val id: String,
    val name: String,
    val durationSec: Double,
    val width: Int,
    val height: Int,
    val fps: Int,
    val checks: List<ClipCheck>,
    val thumb: ImageRef? = null,
    /** Prompt scripts (workstream 4): the free talking detection; absent while it runs or when it failed. */
    val audio: ClipAudio? = null,
) {
    val ok: Boolean get() = checks.none { it.status == "bad" }
}

@Serializable
data class ClipMeta(val name: String, val durationSec: Double, val width: Int, val height: Int, val fps: Int, val people: Int = 1, val watermark: String? = null, val talking: Boolean = false)

@Serializable
data class JobRequest(
    val title: String = "Untitled",
    // AI suite (workstream 1): suite jobs (engine "suite") may have no character, outfit or clip, so these default to "".
    val modelId: String = "",
    val outfitId: String = "",
    val clipId: String = "",
    val engine: String = Engine.H3.id,
    val steps: Int = 10,
    val use: String = ClipUse.FIRST.id,
    val takes: Int = 1,
    val keepAudio: Boolean = true,
    val lipSync: Boolean = false,
    val background: String = "keep",
    val backgroundMotion: String = "subtle",
    val clipSeconds: Double? = null,
    /** true parks the job as "queued" (not charged) until [MuseApi.runQueue]. */
    val queue: Boolean = false,
    /** engine "replicate" only: draft | standard | hd (the server defaults to draft). */
    val quality: String? = null,
    /** Set by the server on replicate jobs: the $ per output second the job was priced at. */
    val pricePerSec: Double? = null,
    /** Prompt scripts (workstream 4): the studio's "Performer is speaking" switch; null = the clip's detection. */
    val speaking: Boolean? = null,
    /** AI suite (workstream 1), set by the server on suite jobs: text | image | reference | swap | recast, and the seconds each take renders. */
    val mode: String? = null,
    val seconds: Double? = null,
    /** Set by the server on upscale jobs (`engine: "upscale"`): the take being sharpened and the size (1080p | 2k | 4k). */
    val takeId: String? = null,
    val size: String? = null,
    /** WS13 (owner): Character swap's model on the classic path (h3-open = Edit, viggle = Fast·beta…); null = the default. */
    val engineModel: String? = null,
) {
    fun spec() = RenderSpec(Engine.fromId(engine), ClipUse.fromId(use), steps, lipSync, takes, clipSeconds, Quality.fromId(quality), pricePerSec)
}

/** POST /v1/jobs/clear-failed: the failed jobs it hid for good. */
@Serializable
data class ClearedJobs(val cleared: Int = 0, val ids: List<String> = emptyList())

/**
 * A render job. state: queued | running | done | failed.
 * progress 0..100; step/totalSteps are per take; phase is the human line ("step 12/20 · ~6 min left").
 */
@Serializable
data class Job(
    val id: String,
    val title: String,
    val modelId: String,
    val modelName: String,
    val outfitId: String,
    val request: JobRequest,
    val state: String,
    val progress: Double = 0.0,
    val take: Int = 1,
    val step: Int = 0,
    val totalSteps: Int = 10,
    val phase: String = "",
    val secondsLeft: Double = 0.0,
    val totalSeconds: Double = 0.0,
    val cost: Double = 0.0,
    val refunded: Double = 0.0,
    val error: String? = null,
    val createdAt: Long = 0,
    val finishedAt: Long? = null,
    val prompt: String = "",
    val seed: Long = 42,
    val thumb: ImageRef? = null,
    /** While waiting for a GPU (real API): place in line and seconds until the render should finish. */
    val queuePosition: Int? = null,
    val etaSeconds: Double? = null,
    /** Never set since 2026-11-04 (nothing pauses on a provider balance). */
    val blocked: String? = null,
    /** GPU warm-up charged with this job (when the member pays it). */
    val warmupCost: Double? = null,
    val userId: String? = null,
    /** Ran while the owner kept the add-on engine ready (owner ledger only). */
    val warm: Boolean? = null,
    /** The server's label ("Draft · 768P", "Edit", "Fast · beta"); older servers send none. */
    @SerialName("engineLabel") val serverEngineLabel: String? = null,
    /** Failed replicate/suite jobs: provider_refused | provider_failed | provider_rate_limited | provider_timeout |
     *  provider_paid_unsaved | provider_unconfirmed (made and charged at the provider: Recover, not Retry). */
    val errorCode: String? = null,
    /** Done replicate jobs: output seconds Replicate billed. */
    val billedSeconds: Double? = null,
    /** AI suite (build step 2): the composer draft it was made from, as sent ("Reuse settings"). */
    val draft: SuiteDraft? = null,
) {
    val paused get() = false
    val engineLabel: String get() = serverEngineLabel ?: Pricing.engineLabel(request.spec())
    val running get() = state == "running" || state == "queued"
    val done get() = state == "done"
    val failed get() = state == "failed"
    /** The provider made (and charged for) the video but the server couldn't save it, or may still finish it: the owner
     *  brings it back with Recover (free, POST /v1/jobs/:id/recover). Retry would pay for it again. */
    val canRecover get() = failed && errorCode in RECOVER_CODES
    companion object {
        val RECOVER_CODES = setOf("provider_paid_unsaved", "provider_unconfirmed")
        const val RECOVER = "Recover"
        /** What a member sees instead (Recover is owner-only on the server). */
        const val RECOVER_BY_OWNER = "The studio owner can recover it for free"
    }
}

/** One take of a job, or one photoshoot still. status: test | final. kind: take | shot. */
@Serializable
data class Take(
    val id: String,
    val kind: String = "take",
    val jobId: String? = null,
    val index: Int = 1,
    val of: Int = 1,
    val title: String,
    val label: String,
    val engineLabel: String = "",
    val cost: Double = 0.0,
    val seed: Long = 0,
    val status: String = "test",
    val thumb: ImageRef? = null,
    val prompt: String = "",
    val createdAt: Long = 0,
    /** The rendered video (real backend). Simulated renders may have none; the still is shown then. */
    val videoUrl: String? = null,
    val durationSec: Double? = null,
    val width: Int? = null,
    val height: Int? = null,
    /** Edited versions (kind "edit", plans/api.md "Video editor"): the take it was cut from, the edit list, the file's frame rate. */
    val parentTakeId: String? = null,
    // Edit suite (workstream 3): a v2 project comes back in the same field (EditsFieldSerializer keeps it in `project`).
    @Serializable(with = EditsFieldSerializer::class) val edits: EditListDto? = null,
    /** An edited version exported with "Label as AI-generated" (posting uses it for the platform's AI label). */
    val aiLabel: Boolean = false,
    val fps: Double? = null,
    /** Template shots: the template's id and name, the variation draw seed, and (template owner only) what was drawn. */
    val templateId: String? = null,
    val templateName: String? = null,
    val shuffleSeed: Long? = null,
    val variation: Map<String, String>? = null,
    /** Photoshoot stills: the reference images it was shot with (2026-11-05). */
    val refs: List<ShootRef>? = null,
    /** AI suite (workstream 1): a suite take's Look; the Edit suite opens with it applied. */
    val look: SuiteLook? = null,
    /** Edit sessions (workstream 3): an edited version's name (1–80 characters), e.g. from Claude's save_version. */
    val name: String? = null,
    /** AI suite (build step 2): the composer draft of its job, or of the photo itself ("Reuse settings"). */
    val draft: SuiteDraft? = null,
) {
    val final get() = status == "final"
    val shot get() = kind == "shot"
    /** The title and badge as members see them ([takeDisplayTitle]): old Photoshoot takes read "Photo". */
    val shownTitle get() = takeDisplayTitle(title)
    val shownLabel get() = takeDisplayTitle(label)
}

/**
 * Photoshoot is now the Photo tool (workstream 3), but takes made before keep their stored titles ("Shoot · Café window",
 * a bare "Shoot" badge). Every take title, label or badge shown to a member goes through this, so they all read "Photo".
 */
fun takeDisplayTitle(raw: String): String = when (raw) {
    "Shoot", "Photoshoot" -> "Photo"
    else -> raw.replace(Regex("^(?:Photoshoot|Shoot)( ·)"), "Photo$1")
}

@Serializable
data class SetTakeStatusRequest(val status: String)

@Serializable
data class ShootRequest(
    /** 2026-11-05: the server builds the prompt from these choices and the studio's prompt library; [prompt] only for "Edit as text". */
    val modelId: String, val outfitId: String, val scene: String? = null, val prompt: String? = null, val seed: Long? = null, val count: Int = 4,
    /** With a template the server builds every prompt; scene/prompt/seed are ignored (plans/api.md "Photo templates"). */
    val templateId: String? = null,
    val direction: String? = null,
    val shuffleSeed: Long? = null,
    val lockSeed: Boolean? = null,
    val productImage: ImageRef? = null,
    /** Owner only: a model for this run, step → "owner/name" (plans/api.md "Model tools" §2). */
    val models: Map<String, String>? = null,
    /** false = only identity, outfit, direction, reference and seed lines. Null = on. */
    val presets: Boolean? = null,
    val camera: CameraChoice? = null,
    val light: String? = null,
    val grade: String? = null,
    /** Up to 3 reference images (plans/api.md "Shoot references" §1). */
    val refs: List<ShootRef>? = null,
)

@Serializable
data class CameraChoice(val shot: String, val lens: Int, val aperture: String)

/** A shoot's reference image and what it guides: "pose" (Pose & framing), "look" (Look & colour), "scene" (Scene). Never face, body or outfit. */
@Serializable
data class ShootRef(val image: ImageRef, val guides: List<String>) {
    /** Turns a guide on or off, kept in the order pose, look, scene. Null when it would leave none on (a reference needs one). */
    fun toggled(guide: String): ShootRef? {
        val next = if (guide in guides) guides - guide else GUIDE_IDS.filter { it in guides || it == guide }
        return if (next.isEmpty()) null else copy(guides = next)
    }

    /** What POST /v1/shoots accepts: 1–3 known guides, no repeats, and an image. */
    val valid: Boolean get() = guides.isNotEmpty() && guides.all { it in GUIDE_IDS } && guides.toSet().size == guides.size && (image.url != null || image.asset != null)

    companion object {
        const val MAX = 3
        val GUIDES = listOf("pose" to "Pose & framing", "look" to "Look & colour", "scene" to "Scene")
        val GUIDE_IDS = GUIDES.map { it.first }

        /** The guide a new reference starts with: the first one the others don't use yet (pose, then look, then scene). */
        fun defaultGuide(existing: List<ShootRef>): String {
            val used = existing.flatMap { it.guides }.toSet()
            return GUIDE_IDS.firstOrNull { it !in used } ?: "pose"
        }

        /** The server's bad_request for a shoot's refs (null when fine). */
        fun problem(refs: List<ShootRef>?): String? = when {
            refs == null -> null
            refs.size > MAX -> "Up to $MAX reference images"
            refs.any { !it.valid } -> "Each reference image needs an image and at least one guide: pose, look or scene"
            else -> null
        }
    }
}

/** A reference image in a shoot preview: its image number in what is sent, or null + [dropped] when the shot can't take it. */
@Serializable
data class ShootPreviewRef(val index: Int? = null, val guides: List<String> = emptyList(), val dropped: Boolean = false) {
    /** "Image 7" (as the prompt lines say) or "Not sent". */
    val badge: String get() = if (dropped || index == null) "Not sent" else "Image $index"
}

/** POST /v1/shoots/preview: exactly what the shoot will send, the images it sends and the estimate. */
@Serializable
data class ShootPreview(
    val slots: List<PromptSlotView> = emptyList(), val text: String = "", val seed: Long? = null, val removed: List<String> = emptyList(),
    val images: Int = 0, val refs: List<ShootPreviewRef> = emptyList(), val estimate: Double = 0.0, val estimateLabel: String = "", val edited: Boolean = false,
) {
    /** Reference images the shot can't take (shown as "Not sent"). */
    val droppedRefs: Int get() = refs.count { it.dropped }
}

// ---------------------------------------------------------------- prompt library (owner, plans/api.md §"Shoot references and the prompt library" 3)
@Serializable
data class PromptPlaceholder(val name: String, val description: String = "", val required: Boolean = false)

@Serializable
data class PromptEntry(
    val key: String, val group: String, val title: String = "", val description: String = "", val kind: String = "text",
    val default: String = "", val current: String = "", val overridden: Boolean = false, val allowEmpty: Boolean = true,
    val placeholders: List<PromptPlaceholder> = emptyList(), val updatedAt: Long? = null, val updatedBy: String? = null,
)

@Serializable
data class PromptGroupInfo(val id: String, val label: String)

@Serializable
data class PromptLibrary(val groups: List<PromptGroupInfo> = emptyList(), val prompts: List<PromptEntry> = emptyList())

@Serializable
data class PromptText(val text: String)

@Serializable
data class PromptPreviewRequest(val key: String, val text: String? = null)

@Serializable
data class PromptPreview(val key: String = "", val text: String = "", val example: String = "", val sample: Map<String, String> = emptyMap())

// ---------------------------------------------------------------- photo templates (plans/templates.md)

/** Post-generation edits the server runs on each still. grade: none|phone-natural|underexposed|moody-blue|golden|harsh-sun|faded|mono. */
@Serializable
data class TemplateAfterEffects(val faceMotionBlur: Double? = null, val blurAngle: Double? = null, val grade: String? = null, val grain: Double? = null)

/** The hidden prompt layers. Only the template's owner ever receives them. */
@Serializable
data class TemplateLayers(
    val style: String? = null, val scene: String? = null, val camera: String? = null, val light: String? = null,
    val negative: String? = null, val product: String? = null, val afterEffects: TemplateAfterEffects? = null,
)

object PoolSlots {
    val ALL = listOf("pose", "bodyAngle", "framing", "expression", "background", "hands", "timeOfDay")
    fun label(k: String) = when (k) {
        "pose" -> "Pose"; "bodyAngle" -> "Body angle"; "framing" -> "Framing"; "expression" -> "Expression"
        "background" -> "Background detail"; "hands" -> "Hands"; "timeOfDay" -> "Time of day"; else -> k
    }
}

@Serializable
data class RecentShot(val id: String, val thumb: ImageRef? = null, val createdAt: Long = 0)

@Serializable
data class Template(
    val id: String,
    val name: String,
    val tags: List<String> = emptyList(),
    val visibility: String = "private",
    val ownerId: String = "",
    val ownerName: String = "",
    val isOwner: Boolean = false,
    val uses: Int = 0,
    val favourite: Boolean = false,
    val cover: ImageRef? = null,
    val acceptsProduct: Boolean = false,
    val starter: String? = null,
    val createdFromShotId: String? = null,
    val createdAt: Long = 0,
    val updatedAt: Long = 0,
    val layers: TemplateLayers? = null,
    /** slot (see [PoolSlots]) → options. Owner only. */
    val variationPool: Map<String, List<String>>? = null,
    val recent: List<RecentShot>? = null,
) {
    val public get() = visibility == "public"
}

@Serializable
data class TemplateDraft(
    val name: String, val tags: List<String> = emptyList(), val layers: TemplateLayers = TemplateLayers(),
    val variationPool: Map<String, List<String>> = emptyMap(), val cover: ImageRef? = null, val fromShotId: String = "",
)

@Serializable
data class CreateTemplateRequest(
    val name: String, val tags: List<String>? = null, val visibility: String? = null, val layers: TemplateLayers? = null,
    val variationPool: Map<String, List<String>>? = null, val coverTakeId: String? = null, val fromShotId: String? = null,
)

@Serializable
data class PatchTemplateRequest(
    val name: String? = null, val tags: List<String>? = null, val visibility: String? = null, val layers: TemplateLayers? = null,
    val variationPool: Map<String, List<String>>? = null,
)

@Serializable
data class TemplateDraftRequest(val fromShotId: String)

@Serializable
data class TemplatePromptRequest(val modelId: String, val outfitId: String? = null, val direction: String? = null, val shuffleSeed: Long? = null, val lockSeed: Boolean? = null)

/** One line of the prompt view. `locked` = the "Template: <name>" line non-owners see in place of the hidden layers. */
@Serializable
data class PromptSlotView(val layer: String, val text: String, val locked: Boolean = false)

@Serializable
data class TemplatePrompt(
    val slots: List<PromptSlotView> = emptyList(), val text: String = "", val seed: Long? = null, val shuffleSeed: Long = 0,
    val variation: Map<String, String>? = null, val removed: List<String>? = null,
)

/**
 * GET /v1/balance. Member: [balance] is their wallet in USD, today/month their own spend. Owner: [balance] is what they can
 * spend or send (the studio balance − members' unspent credit − holds; may be negative), today/month the studio's spend.
 */
@Serializable
data class Balance(
    val balance: Double,
    val month: Double,
    val today: Double = 0.0,
    val perJobLimit: Double = 5.0,
    val perDayLimit: Double = 15.0,
    val videos: Int = 0,
    val tokens: Long? = null,
    val tokenUsd: Double? = null,
    val role: String? = null,
    val heldUsd: Double? = null,
    val perUserDayLimit: Double? = null,
    /** studio (owner) | wallet (member) */
    val balanceSource: String? = null,
    val availableToSend: Double? = null,
    /** Owner: top-ups − all spending (plans/api.md "App clean-up" §4). */
    val studioBalance: Double? = null,
    /** Owner: no top-up recorded yet ("Add your first top-up"). */
    val needsFirstTopUp: Boolean? = null,
)

/** GET /v1/wallet: my tokens (1 token = [tokenUsd]). The owner's wallet is what the studio balance has free. */
@Serializable
data class Wallet(
    val userId: String = "",
    val role: String = "member",
    val tokens: Long = 0,
    val usd: Double = 0.0,
    val heldTokens: Long = 0,
    val heldUsd: Double = 0.0,
    val todayUsd: Double = 0.0,
    val monthUsd: Double = 0.0,
    val tokenUsd: Double = 0.01,
    val balanceSource: String = "wallet",
    val availableToSend: Double? = null,
    val studioBalance: Double? = null,
    val membersUnspentUsd: Double? = null,
) {
    val owner get() = role == "owner"
    /** Tokens the owner can send right now. */
    val tokensToSend: Long get() = availableToSend?.let { kotlin.math.floor(it / tokenUsd + 1e-6).toLong().coerceAtLeast(0) } ?: 0
}

/** One recorded top-up of the studio balance ("Added $20"). */
@Serializable
data class TopUp(val id: String, val amountUsd: Double, val note: String? = null, val paidAt: Long = 0, val createdAt: Long = 0, val createdBy: String? = null)

/** GET /v1/studio/balance (owner): top-ups − spending, and what's free to spend or send. */
@Serializable
data class StudioBalance(
    val balanceUsd: Double = 0.0,
    val toppedUpUsd: Double = 0.0,
    val spentUsd: Double = 0.0,
    val membersCreditUsd: Double = 0.0,
    val heldUsd: Double = 0.0,
    val availableUsd: Double = 0.0,
    val since: Long = 0,
    val needsFirstTopUp: Boolean = false,
    val topUps: List<TopUp> = emptyList(),
)

/** POST /v1/studio/topups (owner). */
@Serializable
data class AddTopUpRequest(val amountUsd: Double, val note: String? = null, val paidAt: Long? = null)

/** POST /v1/takes/{id}/upscale. */
@Serializable
data class UpscaleRequest(val size: String, /** WS13 (owner): the upscale model; null = the default. */ val engineModel: String? = null)

/** GET /v1/members (owner). Caps are in USD; null caps follow the studio default. */
@Serializable
data class Member(
    val id: String,
    val email: String,
    val role: String = "member",
    val tokens: Long = 0,
    val usd: Double = 0.0,
    val heldTokens: Long = 0,
    val todayUsd: Double = 0.0,
    val monthUsd: Double = 0.0,
    val lastActiveAt: Long? = null,
    val disabled: Boolean = false,
    val capPerJob: Double? = null,
    val capPerDay: Double? = null,
    val createdAt: Long = 0,
) {
    val owner get() = role == "owner"
}

@Serializable
data class TransferRequest(val toUserId: String, val tokens: Long, val note: String? = null)

@Serializable
data class ReclaimRequest(val fromUserId: String, val tokens: Long, val note: String? = null)

@Serializable
data class WalletMemberResponse(val wallet: Wallet, val member: Member)

/** PATCH /v1/members/{id}. [clearCapPerDay] sends `capPerDay: null` (back to the studio default). */
data class MemberPatch(val capPerDay: Double? = null, val clearCapPerDay: Boolean = false, val disabled: Boolean? = null)

@Serializable
data class CreateInviteRequest(val email: String? = null, val role: String? = null, val days: Int? = null)

/** POST /v1/invites: the code is shown once. [shareText] is the ready-to-send message with the download link (newer servers). */
@Serializable
data class InviteCreated(
    val code: String,
    val id: String,
    val email: String? = null,
    val role: String = "member",
    val expiresAt: Long = 0,
    val shareText: String? = null,
) {
    /** What Share sends: the server's [shareText], or the same message built here for an older server. */
    fun shareMessage(serverUrl: String): String = shareText?.takeIf { it.isNotBlank() } ?: buildString {
        append("You're invited to MUSE, the AI model studio. 1) Download: ")
        append(serverUrl.trimEnd('/')).append("/get")
        append(" 2) Sign up with this invite code: ").append(code)
        email?.let { append(" (email: ").append(it).append(')') }
        append(". The code works once and expires in 14 days.")
    }
}

/** GET /v1/invites (without codes). */
@Serializable
data class InviteInfo(val id: String, val email: String? = null, val role: String = "member", val createdAt: Long = 0, val expiresAt: Long = 0, val usedAt: Long? = null)

@Serializable
data class StudioFeatures(
    val standard: Boolean = true,
    val fastBeta: Boolean = true,
    val lipSync: Boolean = true,
    val loraTraining: Boolean = true,
    val replaceAudio: Boolean = false,
    val maxClipSec: Double? = null,
    /** Draft / Standard / HD can run (the field name is the server's). */
    val replicate: Boolean = false,
    val video: VideoFeatures? = null,
    /** Pass-through photo prices and estimates (plans/api.md "App clean-up" §3). */
    val photo: PhotoFeatures? = null,
    /** Enhance and Dress up (plans/api.md "Model tools" §4–5). */
    val tools: ToolsFeatures? = null,
)

/** features.photo: the prices the estimates use, and the server's own estimates. */
@Serializable
data class PhotoFeatures(
    val perRun: Double = 0.015,
    val perInputMp: Double = 0.015,
    val perOutputMp: Double = 0.015,
    val perEdit: Double = 0.03,
    val refMp: Double = 0.79,
    val maxRefs: Int = 6,
    val loraShots: Int = 30,
    /** Most images one new shot sends (identity references + reference images). */
    val maxInputs: Int = 8,
) {
    val prices get() = studio.muse.core.PhotoPrices(perRun, perInputMp, perOutputMp, perEdit, refMp, maxRefs, loraShots)
}

/** One add-on (features.video.addons): Edit, Fast · beta, Upscale. */
@Serializable
data class AddonInfo(
    val id: String,
    val label: String = "",
    val detail: String = "",
    val available: Boolean = true,
    val comingSoon: Boolean = false,
    val sizes: List<UpscaleSizeInfo> = emptyList(),
)

/** Upscale sizes: 1080p / 2K / 4K; unavailable with no price until the engine ships. */
@Serializable
data class UpscaleSizeInfo(val id: String, val label: String = "", val width: Int = 0, val height: Int = 0, val available: Boolean = false, val price: Double? = null)

/** One entry of the Render picker (features.video.options). */
@Serializable
data class VideoOptionInfo(
    val id: String,
    val label: String = "",
    val detail: String = "",
    val engine: String = "replicate",
    val quality: String? = null,
    val resolution: String? = null,
    val pricePerSec: Double? = null,
    val available: Boolean = true,
)

/** GET /v1/settings/studio → features.video: Render (Draft / Standard / HD) and the add-ons (Edit, Fast · beta, Upscale). */
@Serializable
data class VideoFeatures(
    val defaultEngine: String = "replicate",
    val defaultQuality: String = "draft",
    val minSeconds: Int = 4,
    val maxSeconds: Int = 15,
    val options: List<VideoOptionInfo> = emptyList(),
    val addons: List<AddonInfo> = emptyList(),
) {
    companion object {
        /** The contract's tables (plans/api.md "App clean-up" §2), Render and Edit available, Upscale coming soon. */
        val DEFAULT = VideoFeatures(
            options = studio.muse.core.VideoOption.RENDER.map { o -> VideoOptionInfo(o.id, o.label, o.detail, o.engine.id, o.quality?.id, o.quality?.resolution, o.quality?.pricePerSec) },
            addons = studio.muse.core.VideoOption.ADDONS.map { AddonInfo(it.id, it.label, it.detail) } + AddonInfo("upscale", "Upscale", "Sharper 1080p, 2K or 4K from a finished take",
                available = false, comingSoon = true, sizes = studio.muse.core.UpscaleSize.entries.map { UpscaleSizeInfo(it.id, it.label, it.width, it.height) }),
        )

        /** Demo mode's $ per output second for Upscale: 1080p and 2K priced, 4K not yet (like an unmeasured size on the server). */
        val DEMO_UPSCALE_PRICES = mapOf("1080p" to 0.02, "2k" to 0.04)

        /** Demo mode: [DEFAULT] with Upscale live at [DEMO_UPSCALE_PRICES]. */
        val DEMO = DEFAULT.copy(addons = DEFAULT.addons.map { a ->
            if (a.id != "upscale") a else a.copy(available = true, comingSoon = false, sizes = a.sizes.map { z ->
                DEMO_UPSCALE_PRICES[z.id]?.let { p -> z.copy(available = true, price = p) } ?: z.copy(available = false, price = null)
            })
        })
    }

    fun option(id: String) = options.firstOrNull { it.id == id }
    fun addon(id: String) = addons.firstOrNull { it.id == id } ?: if (id == "edit") options.firstOrNull { it.id == "exact" }?.let { AddonInfo("edit", "Edit", available = it.available) } else null
    /** An option or add-on is usable unless the server says it isn't. An older server without `addons` has no Fast · beta here. */
    fun available(id: String) = option(id)?.available ?: addon(id)?.available ?: (id != "upscale")
    fun pricePerSec(quality: Quality) = option(quality.id)?.pricePerSec
    /** Upscale (coming soon until the server says otherwise). */
    val upscale: AddonInfo get() = addon("upscale") ?: DEFAULT.addons.last()
}

/** One engine in owner Settings → Engines (the only place provider names appear). status: ready | no_key | simulated | out_of_credit | no_gpu */
@Serializable
data class EngineStatus(
    val id: String,
    val name: String = "",
    val usedFor: String = "",
    val keySet: Boolean = false,
    val status: String = "ready",
    val message: String? = null,
    val outOfCreditAt: Long? = null,
    val balanceUsd: Double? = null,
)

@Serializable
data class KeepReadyInfo(val idleMinutes: Int = 20, val maxMinutes: Int = 120, val ratePerHour: Double = 3.99)

/** Owner-only `engines` block of GET /v1/settings/studio. */
@Serializable
data class Engines(val list: List<EngineStatus> = emptyList(), val keepReady: KeepReadyInfo = KeepReadyInfo())

/**
 * GET/PATCH /v1/settings/studio. Members get caps, tokenUsd and features; the owner also gets the add-on engine limits
 * (maxGpus, overheadPayer = who pays start-up: "user" or "owner", Keep add-on engine ready minutes) and [engines].
 */
@Serializable
data class StudioSettings(
    val maxGpus: Int = 3,
    val overheadPayer: String = "user",
    val capPerJob: Double = 5.0,
    val capPerDay: Double = 15.0,
    val capPerUserDay: Double = 10.0,
    val tokenUsd: Double = 0.01,
    val warmIdleMinutes: Int = 20,
    val warmMaxMinutes: Int = 120,
    val features: StudioFeatures = StudioFeatures(),
    /** Owner only. */
    val engines: Engines? = null,
)

/**
 * Recreate's link rules (GET /v1/recreate/settings), which the phone applies to its own fetch too. [strictLinks] on
 * (the default): TikTok, Instagram and YouTube only, and TikTok's "downloads off" refused. Never cookies or sign-in.
 */
@Serializable
data class RecreateLinkSettings(
    val strictLinks: Boolean = true,
    val platforms: List<String> = listOf("tiktok", "instagram", "youtube"),
    val tiktokDownloadsOff: String = "refuse",
    val maxSec: Int = 60,
    val maxMb: Int = 80,
    val serverFetch: Boolean = true,
    val canEdit: Boolean = false,
)

/** POST /v1/recreate/links/check: may the phone fetch this link (its normalized form), or is it already a reference? */
data class RecreateLinkCheck(val allowed: Boolean, val url: String, val platform: String? = null,
    val cached: studio.muse.core.edit.RecipeReference? = null, val code: String? = null, val reason: String? = null)

@Serializable
data class StudioSettingsPatch(
    val maxGpus: Int? = null,
    val overheadPayer: String? = null,
    val capPerJob: Double? = null,
    val capPerDay: Double? = null,
    val capPerUserDay: Double? = null,
)

/** GET/PATCH /v1/settings/image-engine. provider: simulated | fal | custom-http. */
@Serializable
data class ImageEngine(
    val provider: String = "simulated",
    val model: String = "",
    /** Display name: "FLUX.2 [pro] · Replicate", "Simulated"… (older servers send none). */
    val label: String? = null,
    val editModel: String? = null,
    val url: String? = null,
    val available: Map<String, Boolean> = mapOf("simulated" to true),
)

@Serializable
data class ImageEnginePatch(val provider: String, val model: String? = null, val url: String? = null)

/** POST /v1/uploads/presign → PUT the bytes to [url] with [headers] → POST /v1/uploads/{uploadId}/confirm. */
@Serializable
data class PresignRequest(val kind: String, val contentType: String, val bytes: Long? = null)

@Serializable
data class PresignResponse(val uploadId: String, val method: String = "PUT", val url: String, val headers: Map<String, String> = emptyMap(), val expiresAt: Long = 0,
    /** AI suite (workstream 1): the editor presign's stored-file URL (…/uploads/<key>). */
    val fileUrl: String? = null)

@Serializable
data class ConfirmClipRequest(val meta: ClipMeta)

/** GET /health: `storage` is "s3" (R2: presigned uploads) or "local" (direct multipart). The mock has no field. */
@Serializable
data class Health(val ok: Boolean = true, val storage: String? = null, val gpu: String? = null, val imageEngine: String? = null, val version: String? = null)

/** An owner notice on a wallet event: "provider_out_of_credit" (an engine's own account is out of credit). */
@Serializable
data class Notice(val code: String, val message: String = "", val engine: String? = null)

@Serializable
data class TopUpRequest(val amount: Double, val method: String = "card")

@Serializable
data class FillAnglesResponse(val model: Model, val cost: Double)

/**
 * Keep add-on engine ready (GET/POST /v1/gpu/warm, owner only). state: off | starting | warm | stopping. Times are epoch ms.
 * costUsd is the "Add-on engine ready" line so far (settled per minute).
 */
@Serializable
data class WarmGpu(
    val state: String = "off",
    val startedAt: Long? = null,
    val readyAt: Long? = null,
    val minutes: Int = 0,
    val costUsd: Double = 0.0,
    val ratePerHour: Double = 3.99,
    val busy: Boolean = false,
    val autoOffAt: Long? = null,
    /** idle | cap */
    val autoOffReason: String? = null,
    val warningAt: Long? = null,
    val idleMinutes: Int = 20,
    val maxMinutes: Int = 120,
    val canExtend: Boolean = false,
    val allowed: Boolean = true,
    val lastOff: WarmLastOff? = null,
) {
    val on get() = state == "starting" || state == "warm" || state == "stopping"
    val starting get() = state == "starting"
}

/** How the last warm GPU ended. reason: user | idle | cap | credit | owner_balance | gpu_lost */
@Serializable
data class WarmLastOff(val reason: String, val at: Long = 0, val minutes: Int = 0, val costUsd: Double = 0.0)

/** The 5-minute warning before an idle or cap auto-off. */
@Serializable
data class WarmWarning(val reason: String, val autoOffAt: Long = 0, val message: String = "")

/** POST /v1/gpu/warm: {on: true|false} or {extend: true} ("Keep warm"). */
@Serializable
data class WarmRequest(val on: Boolean? = null, val extend: Boolean? = null)

/** Server-sent event on /v1/events. type: job | balance | model | outfit | lora | post | wallet | gpu */
@Serializable
data class ApiEvent(
    val type: String,
    val job: Job? = null,
    val balance: Balance? = null,
    val model: Model? = null,
    val outfit: Outfit? = null,
    val lora: Lora? = null,
    val post: Post? = null,
    val takes: List<Take> = emptyList(),
    val wallet: Wallet? = null,
    val notice: Notice? = null,
    /** type "gpu": the warm GPU, and event = state | tick | warning (with [warning]). */
    val gpu: WarmGpu? = null,
    val event: String? = null,
    val warning: WarmWarning? = null,
    /** type "tool": an Enhance or Dress up run changed. */
    val tool: ToolRun? = null,
    /** "delete": remove the item with [id] (take, job, model, template, post) or the account of [modelId] on [platform]. */
    val op: String? = null,
    val id: String? = null,
    /** type "take": one new or changed take (a photoshoot still on another device, a status change). */
    val take: Take? = null,
    /** type "template": my view of a template (layers only when it's mine). */
    val template: Template? = null,
    /** type "account". */
    val account: Account? = null,
    val modelId: String? = null,
    val platform: String? = null,
    /** type "settings": the studio settings in my role's view. */
    val settings: StudioSettings? = null,
    /** Owners only: type "member" (one row of Members) and type "studio" (the studio balance card). */
    val member: Member? = null,
    val studioBalance: StudioBalance? = null,
    /** Owners only: type "prompts", one prompt-library entry after a save or reset. */
    val prompt: PromptEntry? = null,
    /** Prompt scripts (workstream 4). Owners only: type "promptScript", one script after a save or reset. */
    val script: ScriptView? = null,
    /** Prompt scripts (workstream 4): type "clip", a clip whose talking detection finished after the upload answered. */
    val clip: Clip? = null,
    // Workstream 2: camera sessions. type "camera": op upsert (session) / delete (id) / message (sessionId, message) / asset (sessionId, asset);
    // type "blender": op relay (online, blender, addonVersion). Owners' devices only.
    val session: CameraSession? = null,
    val sessionId: String? = null,
    val message: CameraMessage? = null,
    val asset: CameraAsset? = null,
    val online: Boolean? = null,
    val blender: Boolean? = null,
    val addonVersion: String? = null,
    // Workstream 2: Claude on the owner's plan. type "claude" (op thread | message | event | turn | stop | status): its fields
    // clash with the ones above (message, event, status), so the stream reads it apart into [claude] (see claudeLiveOf).
    val claude: ClaudeLive? = null,
    // Edit sessions (workstream 3): type "edit" (owners only), with sessionId and op = patch | log | pending |
    // frame_request | app_request | closed. patch: revision, baseRevision, patch, entry · log: entry · pending: pending ·
    // frame_request: requestId, t, width, revision, device · app_request: request.
    val revision: Int? = null,
    val baseRevision: Int? = null,
    val patch: kotlinx.serialization.json.JsonArray? = null,
    val entry: EditHistoryEntry? = null,
    val pending: EditPending? = null,
    val requestId: String? = null,
    val t: Double? = null,
    val width: Int? = null,
    val device: String? = null,
    val request: EditAppRequest? = null,
    /** Claude in the AI Suite: type "suiteAssist", the shared composer draft after any change. */
    val assist: SuiteAssist? = null,
) {
    companion object {
        /** Not from the server: the stream (re)connected, so the app refetches what it may have missed. */
        const val CONNECTED = "connected"
    }
}

/** PATCH /v1/models/{id}: only the fields sent change. */
@Serializable
data class UpdateModelRequest(
    val name: String? = null,
    val niche: String? = null,
    val personality: String? = null,
    val notes: String? = null,
    val neverAdd: List<String>? = null,
)

// ---------------------------------------------------------------- Identity LoRA (plans/lora-training.md)

/** One training-set candidate. Flagged ones (tattoo, ring, choker, face drift) start dropped, but the user can keep them. */
@Serializable
data class LoraCandidate(val id: String, val image: ImageRef, val label: String = "", val flag: String? = null, val keep: Boolean = true)

/** One of the two trainings. state: none | waiting | training | ready */
@Serializable
data class LoraPart(val state: String = "none", val progress: Double = 0.0)

/**
 * A model's Identity LoRA. state: none | building | review | training | ready | failed.
 * [version] is the last ready version (0 = never trained). It is applied when version ≥ 1 and [use] is on, also during a retrain.
 */
@Serializable
data class Lora(
    val modelId: String,
    val version: Int = 0,
    val state: String = "none",
    val use: Boolean = true,
    val candidates: List<LoraCandidate> = emptyList(),
    val progress: Double = 0.0,
    val photo: LoraPart = LoraPart(),
    val video: LoraPart = LoraPart(),
    val cost: Double = 0.0,
    val trainedOn: Int? = null,
) {
    val kept: Int get() = candidates.count { it.keep }
    val flagged: Int get() = candidates.count { it.flag != null }
    val active: Boolean get() = version > 0 && use
    fun token(modelName: String): String? = if (active) studio.muse.core.LoraToken.of(modelName, version) else null
}

@Serializable
data class KeepRequest(val keep: Boolean)

@Serializable
data class PatchLoraRequest(val use: Boolean? = null, val state: String? = null)

// ---------------------------------------------------------------- Social accounts and posts (plans/socials.md)

/** The five platforms, in display order. Badges are coloured rounded squares with letters, not brand logos. */
enum class Platform(val id: String, val label: String, val badge: String, val color: Long, val androidPackages: List<String>) {
    TIKTOK("tiktok", "TikTok", "TT", 0xFF111111, listOf("com.zhiliaoapp.musically", "com.ss.android.ugc.trill")),
    INSTAGRAM("instagram", "Instagram", "IG", 0xFFD62976, listOf("com.instagram.android")),
    FACEBOOK("facebook", "Facebook", "f", 0xFF1877F2, listOf("com.facebook.katana")),
    YOUTUBE("youtube", "YouTube", "YT", 0xFFFF0000, listOf("com.google.android.youtube")),
    X("x", "X", "X", 0xFF111111, listOf("com.twitter.android"));

    companion object {
        fun of(id: String): Platform? = entries.firstOrNull { it.id == id }
    }
}

/** A model's linked account. canPostDirect stays false until that platform approves MUSE (stage 2). */
@Serializable
data class Account(val modelId: String, val platform: String, val handle: String, val connectedAt: Long = 0, val canPostDirect: Boolean = false)

/** The real backend returns an OAuth [authUrl]; the mock signs in and returns the [account]. */
@Serializable
data class ConnectResponse(val authUrl: String? = null, val account: Account? = null)

@Serializable
data class PostStats(val views: Long = 0, val likes: Long = 0, val comments: Long = 0)

/** state: scheduled | handoff | posted | failed. when: "now" or an ISO-8601 time. */
@Serializable
data class Post(
    val id: String,
    val modelId: String,
    val takeId: String,
    val title: String = "",
    val thumb: ImageRef? = null,
    val platforms: List<String> = emptyList(),
    val caption: String = "",
    val aiLabel: Boolean = false,
    val paidPartnership: Boolean = false,
    val `when`: String = "now",
    val state: String = "scheduled",
    val createdAt: Long = 0,
    val postedAt: Long? = null,
    val stats: PostStats? = null,
) {
    val scheduled get() = state == "scheduled"
    /** The Posted tab: handed off (stage 1) or posted. */
    val out get() = state == "handoff" || state == "posted"
    val whenMillis: Long? get() = if (`when` == "now") null else runCatching { java.time.Instant.parse(`when`).toEpochMilli() }.getOrNull()
}

/** Labels default to false and are only ever set by the user. */
@Serializable
data class CreatePostRequest(
    val modelId: String,
    val takeId: String,
    val platforms: List<String>,
    val caption: String,
    val aiLabel: Boolean = false,
    val paidPartnership: Boolean = false,
    val `when`: String = "now",
)

@Serializable
data class DevFailRequest(val failNext: Boolean)

@Serializable
data class ErrorBody(val error: String, val code: String? = null)

class ApiException(val code: String, message: String) : Exception(message) {
    /** The server restarting or the network dropping: worth retrying in a moment (polls keep going). */
    val transient: Boolean get() = code in TRANSIENT

    companion object { val TRANSIENT = setOf("server_restarting", "offline", "still_working", "http_502", "http_503", "http_504") }
}

// ---------------------------------------------------------------- Prompt scripts (workstream 4)
// plans/api.md "Prompt scripts (2026-11-05)": inputs → rules → blocks. Owner only (Settings → Prompts → Scripts).

/** A clip's audio as the server classified it on upload. kind: speech | music | silence | none. */
/** An edit style kit (/v1/editor/kits): [kit] is the contract's StyleKit JSON (core Kit.kt parseKit / encodeKit). */
@Serializable
data class EditKit(val id: String, val name: String, val kit: kotlinx.serialization.json.JsonObject, val createdBy: String? = null, val createdAt: Long = 0, val updatedAt: Long = 0)
@Serializable
data class EditKits(val kits: List<EditKit> = emptyList())
@Serializable
data class EditKitRequest(val name: String? = null, val kit: kotlinx.serialization.json.JsonObject? = null)

@Serializable
data class ClipAudio(val kind: String = "none", val speaking: Boolean = false, val detected: Boolean = false)

@Serializable
data class ScriptOption(val id: String, val label: String = "")

/** One typed input. type: bool | enum | number | text | list; [fields] = a list's item fields; [sample] = the preview's value. */
@Serializable
data class InputDef(
    val name: String, val label: String = "", val description: String = "", val type: String = "text",
    val options: List<ScriptOption> = emptyList(), val fields: List<InputDef> = emptyList(), val sample: JsonElement? = null,
)

/** One condition: [input] is an input name, or "item.<field>" in a section that repeats per list item. */
@Serializable
data class Cond(val input: String, val op: String, val value: JsonElement? = null)

/** A rule puts [block] in [target] (a section id, or "@value") when every condition holds. */
@Serializable
data class Rule(
    val id: String, val label: String = "", val target: String, @SerialName("when") val conds: List<Cond> = emptyList(), val block: String,
    val optional: Boolean? = null, val locked: Boolean? = null, val enabled: Boolean? = null,
) {
    val isLocked: Boolean get() = locked == true
    val isOn: Boolean get() = enabled != false
}

@Serializable
data class ScriptSection(val id: String, val label: String = "", val kind: String = "system", val each: String? = null, val heading: String? = null)

@Serializable
data class ScriptValue(
    val name: String, val label: String = "", val prefix: String? = null,
    /** A per-item value: repeats over this list input's items (first matching rule per item), each piece after [itemPrefix], joined with [join]. */
    val each: String? = null, val itemPrefix: String? = null, val join: String? = null,
)

@Serializable
data class ScriptTarget(val id: String, val label: String = "")

@Serializable
data class ScriptVar(val name: String, val description: String = "", val sample: String = "")

@Serializable
data class ScriptView(
    val id: String, val group: String = "", val title: String = "", val description: String = "", val format: String = "lines",
    val inputs: List<InputDef> = emptyList(), val sections: List<ScriptSection> = emptyList(), val values: List<ScriptValue> = emptyList(),
    val targets: List<ScriptTarget> = emptyList(), val vars: List<ScriptVar> = emptyList(), val blocks: List<String> = emptyList(),
    val rules: List<Rule> = emptyList(), val defaultRules: List<Rule> = emptyList(), val overridden: Boolean = false, val stale: Boolean = false,
    val updatedAt: Long? = null, val updatedBy: String? = null,
)

/** A test and the input types it applies to (GET /v1/prompt-scripts `ops`). */
@Serializable
data class CondOpInfo(val id: String, val label: String = "", val types: List<String> = emptyList())

@Serializable
data class PromptScriptsList(val groups: List<PromptGroupInfo> = emptyList(), val ops: List<CondOpInfo> = emptyList(), val scripts: List<ScriptView> = emptyList())

@Serializable
data class SaveScriptRules(val rules: List<Rule>)

@Serializable
data class ScriptPreviewRequest(
    val id: String, val inputs: JsonObject? = null, val rules: List<Rule>? = null, val texts: Map<String, String>? = null, val direction: String? = null,
)

@Serializable
data class ScriptPart(val section: String = "", val layer: String = "", val kind: String = "system", val text: String = "", val rules: List<String> = emptyList())

/** POST /v1/prompt-scripts/preview: the script run on the sample values (with the editor's unsaved changes). */
@Serializable
data class ScriptPreview(
    val id: String = "", val text: String = "", val parts: List<ScriptPart> = emptyList(), val fired: List<String> = emptyList(),
    val inputs: JsonObject = JsonObject(emptyMap()),
)

// ======================================================================= Edit suite (workstream 3)
// plans/api.md "Editor v2": AI helper jobs (estimate first, then a job polled to its result) and edited versions that
// carry a v2 project. Additive; nothing above depends on it except Take.edits' serializer.

/** A job's source: a take of the studio, or an upload (+ its length). */
@Serializable
data class EditorSourceDto(val takeId: String? = null, val uploadId: String? = null, val durationSec: Double? = null)

@Serializable
data class EditorJobRequest(val kind: String, val source: EditorSourceDto, val options: JsonObject? = null,
    /** WS13 (owner): the model to run this helper on (captions/cuts → captions, matte → matte or track with points, denoise). Null = the studio's default. */
    val engineModel: String? = null)

/** POST /v1/editor/estimate. [free] = nothing is charged ("Free" in the UI). */
@Serializable
data class EditorEstimate(val kind: String = "", val usd: Double = 0.0, val tokens: Double = 0.0, val free: Boolean = false, val reusesTranscript: Boolean = false, val durationSec: Double = 0.0)

/** An AI helper job (captions, cuts, matte, denoise, beats). [result] is the kind's result object (plans/api.md). */
@Serializable
data class EditorJob(
    val id: String,
    val kind: String,
    val state: String = "running",
    val progress: Int = 0,
    val phase: String = "",
    val estimateUsd: Double = 0.0,
    val costUsd: Double = 0.0,
    val result: JsonObject? = null,
    val error: String? = null,
    val createdAt: Long = 0,
    /** Failed after the provider made the result: provider_paid_unsaved / provider_unconfirmed (owner's free Recover when
     *  [recoverable]) or provider_paid_lost (not recoverable; the member wasn't charged). */
    val errorCode: String? = null,
    val recoverable: Boolean = false,
) {
    /** The owner can bring this result back for free (POST /v1/jobs/:id/recover; never a new run). */
    val canRecover: Boolean get() = state == "failed" && recoverable && errorCode in Job.RECOVER_CODES
    val finished: Boolean get() = state == "done" || state == "failed" || state == "cancelled"
}

/** POST /v1/takes/{id}/versions with a v2 project as `edits`. */
@Serializable
data class TakeVersionV2Request(
    val uploadId: String,
    val thumbUploadId: String? = null,
    val edits: JsonObject,
    val durationSec: Double,
    val width: Int,
    val height: Int,
    val fps: Double? = null,
    /** Edit sessions (workstream 3): the version's name, 1–80 characters trimmed (Claude's save_version name). */
    val name: String? = null,
    /** Export's "Label as AI-generated" (off by default): only ever sent as true; null leaves it off. */
    val aiLabel: Boolean? = null,
)

/** Edit sessions (workstream 3): a version name as the server takes it (trimmed, at most 80 characters; blank = none). */
fun versionName(raw: String?): String? = raw?.trim()?.take(80)?.trim()?.ifEmpty { null }

/** GET /v1/editor/uploads/{id}: where an upload of the studio can be fetched. */
@Serializable
data class EditorUploadDto(val uploadId: String, val url: String, val contentType: String? = null, val bytes: Long? = null)

/** POST /v1/editor/uploads/presign (voice-over / music / .cube / font). */
@Serializable
data class EditorPresignRequest(val contentType: String, val bytes: Long? = null, val purpose: String? = null)

/**
 * Take.edits: a v1 edit list decodes as before; a v2 project (version 2) becomes an EditListDto with no segments and
 * the project kept in [EditListDto.project], so old app code ignores it and the Edit suite reopens it.
 */
object EditsFieldSerializer : kotlinx.serialization.KSerializer<EditListDto> {
    override val descriptor = JsonElement.serializer().descriptor

    override fun deserialize(decoder: kotlinx.serialization.encoding.Decoder): EditListDto {
        val el = (decoder as kotlinx.serialization.json.JsonDecoder).decodeJsonElement()
        val o = el as? JsonObject ?: throw kotlinx.serialization.SerializationException("edits must be an object")
        val version = (o["version"] as? kotlinx.serialization.json.JsonPrimitive)?.content?.toIntOrNull() ?: 1
        if (version == 2) {
            val src = (o["sourceTakeId"] as? kotlinx.serialization.json.JsonPrimitive)?.content ?: ""
            return EditListDto(2, src, 0.0, emptyList(), false).also { it.project = o }
        }
        return decoder.json.decodeFromJsonElement(EditListDto.serializer(), o)
    }

    override fun serialize(encoder: kotlinx.serialization.encoding.Encoder, value: EditListDto) {
        val json = (encoder as kotlinx.serialization.json.JsonEncoder)
        json.encodeJsonElement(value.project ?: json.json.encodeToJsonElement(EditListDto.serializer(), value))
    }
}

// ---------------------------------------------------------------- Edit sessions (workstream 3)
// plans/api.md "Edit sessions" (plans/claude-editing.md A): the live, revisioned copy of a take's EditProject v2 the
// owner's apps and Claude share. Owner only. Changes travel as JSON Patch (studio.muse.core.edit.JsonPatch).

/** One change in a session's history (newest first). author: "app:<device>" or "claude". kind: edit | undo | tool | reset. */
@Serializable
data class EditHistoryEntry(
    val id: Long, val revision: Int = 0, val author: String = "", val byClaude: Boolean = false, val kind: String = "edit",
    val label: String = "", val undoes: Long? = null, val undone: Boolean = false, val createdAt: Long = 0,
)

/** A paid helper Claude asked for, waiting for the owner's yes. status: waiting | approved | declined | running | done | failed. */
@Serializable
data class EditPending(val id: String, val kind: String = "", val label: String = "", val estimateUsd: Double = 0.0, val status: String = "waiting", val jobId: String? = null, val createdAt: Long = 0)

/** Claude asked an online app to save a version or export. kind: save | export; status: sent | done | failed. */
@Serializable
data class EditAppRequest(
    val id: String, val kind: String = "save", val name: String? = null, val preset: JsonObject? = null, val device: String = "",
    val status: String = "sent", val versionId: String? = null, val error: String? = null, val at: Long = 0,
)

@Serializable
data class EditPresence(val device: String, val label: String = "", val platform: String = "other", val canRender: Boolean = true,
    /** Edit's preview on this device (plans/edit-platform-preview.md), so Claude knows what the person sees. */
    val preview: EditPresencePreview? = null)

/** The view ("clean", "tiktok" …) and the Safe area switch. */
@Serializable
data class EditPresencePreview(val view: String, val safeArea: Boolean = true)

@Serializable
data class EditSessionDto(
    val id: String, val takeId: String = "", val baseVersionId: String? = null, val revision: Int = 0, val project: JsonObject,
    val durationSec: Double = 0.0, val status: String = "open", val updatedBy: String = "", val updatedAt: Long = 0,
    val pending: List<EditPending> = emptyList(), val online: List<EditPresence> = emptyList(), val requests: List<EditAppRequest> = emptyList(),
    val history: List<EditHistoryEntry> = emptyList(),
    /** Continue a draft: where an editor was last left on this session (server 0035; Mac and Android share it). Absent on older servers. */
    val view: JsonObject? = null,
    /** GET /v1/edit-sessions?recent=1: the later of the last change and `view.at` (ms). */
    val lastTouchedAt: Long? = null,
)

/** POST /v1/edit-sessions/{id}/view */
@Serializable
data class EditViewRequest(val view: JsonObject)

@Serializable
data class OpenEditSessionRequest(val takeId: String, val project: JsonObject? = null, val baseVersionId: String? = null, val device: String? = null, val fresh: Boolean? = null)

@Serializable
data class EditPatchRequest(val baseRevision: Int, val patch: kotlinx.serialization.json.JsonArray, val label: String, val device: String)

@Serializable
data class EditUndoRequest(val entryId: Long, val device: String)

/** POST …/patch, …/undo → the new revision and its history entry (null when nothing changed). */
@Serializable
data class EditChangeResult(val revision: Int, val entry: EditHistoryEntry? = null)

@Serializable
data class EditFrameAnswer(val uploadId: String)

@Serializable
data class EditRequestAnswer(val status: String, val versionId: String? = null, val error: String? = null)

@Serializable
data class EditPendingAnswer(val approve: Boolean)

/** WS1 guardrails, `GET /v1/editor/settings` (owner): paid AI editing helpers on or off, the daily limit and today's spend. */
@Serializable
data class EditorSettings(
    val paidHelpers: String = "on",
    /** Dollars per day; the server's default ($5) when null. */
    val capPerDayUsd: Double? = null,
    val todayUsd: Double = 0.0,
    val markup: Double = 2.0,
    /** Owner only: which provider runs the helpers (mock until they are switched on for real). */
    val provider: String = "",
) {
    val on: Boolean get() = paidHelpers != "off"
    val cap: Double get() = capPerDayUsd ?: DEFAULT_CAP
    companion object { const val DEFAULT_CAP = 5.0 }
}

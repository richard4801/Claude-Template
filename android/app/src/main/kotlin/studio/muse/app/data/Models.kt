package studio.muse.app.data

import kotlinx.serialization.Serializable
import studio.muse.core.ClipUse
import studio.muse.core.Engine
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

@Serializable
data class User(val id: String, val studioName: String, val email: String)

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
)

/** One of the 6 character-sheet slots. source: "upload" (yours) or "generated" (filled in). */
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
) {
    val filled: Int get() = slots.count { it.image != null && !it.busy }
    val locked: Boolean get() = filled == 6
    val hasBothFaces: Boolean get() = slots.count { (it.key == "face" || it.key == "profile") && it.image != null } == 2
    fun slot(key: String) = slots.firstOrNull { it.key == key }
    val cover: ImageRef? get() = slot("face")?.image ?: slots.firstOrNull { it.image != null }?.image
    val initial: String get() = name.take(1).uppercase()
}

@Serializable
data class CreateModelRequest(val name: String, val age: Int, val niche: String)

@Serializable
data class SetSlotRequest(val image: ImageRef?, val source: String = "upload")

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
) {
    val front: ImageRef? get() = angles.firstOrNull()
}

@Serializable
data class CreateOutfitRequest(
    val modelId: String,
    val name: String,
    val mode: String,
    val description: String = "",
    val images: List<ImageRef> = emptyList(),
)

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
) {
    val ok: Boolean get() = checks.none { it.status == "bad" }
}

@Serializable
data class ClipMeta(val name: String, val durationSec: Double, val width: Int, val height: Int, val fps: Int, val people: Int = 1, val watermark: String? = null, val talking: Boolean = false)

@Serializable
data class JobRequest(
    val title: String,
    val modelId: String,
    val outfitId: String,
    val clipId: String,
    val engine: String = Engine.H3.id,
    val steps: Int = 10,
    val use: String = ClipUse.FIRST.id,
    val takes: Int = 1,
    val keepAudio: Boolean = true,
    val lipSync: Boolean = false,
    val background: String = "keep",
    val backgroundMotion: String = "subtle",
    val clipSeconds: Double? = null,
) {
    fun spec() = RenderSpec(Engine.fromId(engine), ClipUse.fromId(use), steps, lipSync, takes, clipSeconds)
}

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
) {
    val engineLabel: String
        get() = if (request.engine == Engine.VIGGLE.id) "Fast · beta" else "Standard · ${request.steps} steps"
    val running get() = state == "running" || state == "queued"
    val done get() = state == "done"
    val failed get() = state == "failed"
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
    val thumb: ImageRef,
    val prompt: String = "",
    val createdAt: Long = 0,
) {
    val final get() = status == "final"
}

@Serializable
data class SetTakeStatusRequest(val status: String)

@Serializable
data class ShootRequest(val modelId: String, val outfitId: String, val scene: String, val prompt: String, val seed: Long? = null, val count: Int = 4)

@Serializable
data class Balance(val balance: Double, val month: Double, val perJobLimit: Double = 5.0, val perDayLimit: Double = 15.0, val videos: Int = 0)

@Serializable
data class TopUpRequest(val amount: Double, val method: String = "card")

@Serializable
data class FillAnglesResponse(val model: Model, val cost: Double)

/** Server-sent event on /v1/events. type: job | balance | model | outfit */
@Serializable
data class ApiEvent(
    val type: String,
    val job: Job? = null,
    val balance: Balance? = null,
    val model: Model? = null,
    val outfit: Outfit? = null,
    val takes: List<Take> = emptyList(),
)

@Serializable
data class DevFailRequest(val failNext: Boolean)

@Serializable
data class ErrorBody(val error: String, val code: String? = null)

class ApiException(val code: String, message: String) : Exception(message)

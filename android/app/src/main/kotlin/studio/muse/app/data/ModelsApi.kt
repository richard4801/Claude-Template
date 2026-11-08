package studio.muse.app.data

// WS7: "pick the model everywhere" (owner, 2026-11-08, high priority), against WS13's contract:
//   GET /v1/engines?purpose=… → {purposes, engines} · GET/PATCH /v1/engines/defaults {<purpose>: model|null}.
// Owner only: members never see models. The demo studio's version is FakeModelsApi. MuseApi exposes it as `api.modelChoice`.

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/** Every place the app runs a model, with WS13's purpose ids (GET /v1/engines purposes[]); labels are the fallback when the server has none. */
enum class ModelPurpose(val id: String, val label: String, val kind: String) {
    SHOT("shot", "Shots", "video"),
    TALKING("talking", "Talking", "video"),
    UGC("ugc", "UGC ads", "video"),
    STORYBOARD("storyboard", "Storyboards", "video"),
    GUIDE("guide", "Camera guide", "video"),
    SWAP("swap", "Character swap", "video"),
    RECAST("recast", "Recast", "video"),
    EXTEND("extend", "Extend", "video"),
    FILL("fill", "Recreate shots", "video"),
    UPSCALE("upscale", "Upscale", "video"),
    PHOTO("photo", "Photos", "image"),
    OUTFIT("outfit", "Outfit sets", "image"),
    CHARACTER("character", "Character photos", "image"),
    PLATE("plate", "Backgrounds", "image"),
    MATTE("matte", "Remove background", "tool"),
    TRACK("track", "Tap to keep", "tool"),
    CAPTIONS("captions", "Captions", "tool"),
    DENOISE("denoise", "Noise reduction", "tool");

    companion object { fun of(id: String?) = entries.firstOrNull { it.id == id } }
}

/** The app's view of one purpose: its label, the studio's default (null = Auto) and its models in the picker's shape. */
@Serializable
data class ModelsForPurpose(val purpose: String = "", val default: String? = null, val models: List<SuiteCatalogEngine> = emptyList(), val label: String? = null)

// ---------------------------------------------------------------- WS13's wire shapes (GET /v1/engines)

@Serializable
data class EnginePurposeInfo(val id: String, val label: String = "", val kind: String = "video", val default: String? = null, val studioDefault: String? = null)

@Serializable
data class EngineResolution(val id: String, val label: String = "")

@Serializable
data class EngineLimits(
    val minSeconds: Int? = null,
    val maxSeconds: Int? = null,
    val allowedSeconds: List<Int>? = null,
    val aspectRatios: List<String> = emptyList(),
    val resolutions: List<EngineResolution> = emptyList(),
    val maxInputSeconds: Int? = null,
)

/** per_second | per_run | per_output_second, in dollars. */
@Serializable
data class EnginePrice(val basis: String = "per_run", val usd: Double = 0.0)

@Serializable
data class EngineEntry(
    val model: String,
    val name: String = "",
    val kind: String = "video",
    val purposes: List<String> = emptyList(),
    val custom: Boolean = false,
    /** With ?purpose: the model Auto uses for it. */
    val default: Boolean = false,
    val provider: String? = null,
    val notice: String? = null,
    val limits: EngineLimits = EngineLimits(),
    val resolution: String? = null,
    val price: EnginePrice? = null,
    val inputs: SuiteInputs? = null,
) {
    /** The picker's shape: one price, per second or per run. */
    fun asCatalogEngine(): SuiteCatalogEngine {
        val perSec = price?.takeIf { it.basis != "per_run" }?.usd
        return SuiteCatalogEngine(model, name.ifBlank { model }, if (kind == "image") "image" else "video", custom, null, emptyList(), resolution,
            limits.resolutions.map { SuiteResolution(it.id, it.label.ifBlank { it.id }, perSec = perSec ?: 0.0) }, perSec,
            price?.takeIf { it.basis == "per_run" }?.usd, limits.minSeconds, limits.maxSeconds, limits.allowedSeconds, limits.aspectRatios, inputs, purposes)
    }
}

@Serializable
data class EnginesResponse(val purposes: List<EnginePurposeInfo> = emptyList(), val engines: List<EngineEntry> = emptyList())

@Serializable
data class EngineDefaults(val defaults: Map<String, String?> = emptyMap(), val builtin: Map<String, String?> = emptyMap())

interface ModelsApi {
    suspend fun models(purpose: ModelPurpose): ModelsForPurpose
    /** Sets the studio's default for [purpose] (null = MUSE's built-in pick). */
    suspend fun setDefault(purpose: ModelPurpose, model: String?): ModelsForPurpose

    /** A server without WS13: the caller falls back to the Suite catalog's engines (shots and photos). */
    object Unsupported : ModelsApi {
        override suspend fun models(purpose: ModelPurpose) = throw ApiException("unsupported", "This studio server can't list models yet")
        override suspend fun setDefault(purpose: ModelPurpose, model: String?) = throw ApiException("unsupported", "This studio server can't set default models yet")
    }
}

/** WS13: GET /v1/engines?purpose=P (owner); GET/PATCH /v1/engines/defaults {<purpose>: model|null}. */
class HttpModelsApi(baseUrl: String, private val client: OkHttpClient, private val json: Json) : ModelsApi {
    private val base = if (baseUrl.endsWith("/")) baseUrl else "$baseUrl/"

    private suspend fun text(method: String, path: String, body: String?): String = withContext(Dispatchers.IO) {
        val rb = body?.toRequestBody("application/json".toMediaType())
        val res = try { client.newCall(Request.Builder().url(base + path).method(method, rb).build()).execute() }
            catch (e: java.io.IOException) { throw ApiException("offline", "Can't reach the server at $base") }
        res.use { r ->
            val t = r.body.string()
            if (!r.isSuccessful) {
                val err = runCatching { json.decodeFromString(ErrorBody.serializer(), t) }.getOrNull()
                throw ApiException(err?.code ?: if (r.code == 404) "unsupported" else "http_${r.code}", err?.error ?: "Server error ${r.code}")
            }
            t
        }
    }

    private fun <T> decode(s: kotlinx.serialization.KSerializer<T>, t: String): T =
        try { json.decodeFromString(s, t) } catch (e: kotlinx.serialization.SerializationException) { throw ApiException("bad_response", "The server sent something this app version can't read") }

    override suspend fun models(purpose: ModelPurpose): ModelsForPurpose {
        val r = decode(EnginesResponse.serializer(), text("GET", "v1/engines?purpose=${purpose.id}", null))
        val info = r.purposes.firstOrNull { it.id == purpose.id }
        return ModelsForPurpose(purpose.id, info?.studioDefault, r.engines.filter { purpose.id in it.purposes || it.purposes.isEmpty() }.map { it.asCatalogEngine() }, info?.label?.ifBlank { null })
    }

    override suspend fun setDefault(purpose: ModelPurpose, model: String?): ModelsForPurpose {
        val body = kotlinx.serialization.json.buildJsonObject { put(purpose.id, model?.let { kotlinx.serialization.json.JsonPrimitive(it) } ?: kotlinx.serialization.json.JsonNull) }
        text("PATCH", "v1/engines/defaults", body.toString())
        return models(purpose)
    }
}

/**
 * The demo studio's models per purpose (FakeSuite.enginesFor: recast models for Swap and Recast, the shot engines for
 * other video purposes, the image engines for stills; tools have none) and the defaults the owner sets (in memory).
 */
class FakeModelsApi(private val engines: (ModelPurpose) -> List<SuiteCatalogEngine>) : ModelsApi {
    private val defaults = mutableMapOf<ModelPurpose, String?>()
    override suspend fun models(purpose: ModelPurpose) = ModelsForPurpose(purpose.id, defaults[purpose], if (purpose.kind == "tool") emptyList() else engines(purpose))
    override suspend fun setDefault(purpose: ModelPurpose, model: String?): ModelsForPurpose { defaults[purpose] = model; return models(purpose) }
}

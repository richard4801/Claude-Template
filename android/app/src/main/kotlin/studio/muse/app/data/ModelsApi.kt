package studio.muse.app.data

// WS7: "pick the model everywhere" (owner, 2026-11-08, high priority), against WS13's contract (provisional until it lands):
//   GET /v1/models?purpose=… → {purpose, default, models: [catalog.engines entry]} · PATCH /v1/models/defaults {purpose, model|null}.
// Owner only: members never see models. The demo studio's version is FakeModelsApi. MuseApi exposes it as `api.modelChoice`.

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/** Every place the app runs an image or video model, as WS13 names them (provisional ids), with the owner's label. */
enum class ModelPurpose(val id: String, val label: String, val kind: String) {
    SHOT("shot", "Shots", "video"),
    PHOTO("photo", "Photos", "image"),
    SWAP("swap", "Character swap", "video"),
    RECAST("recast", "Recast", "video"),
    EXTEND("extend", "Extend", "video"),
    UPSCALE("upscale", "Upscale", "video"),
    RECREATE("recreate", "Recreate shots", "video"),
    MODEL_PHOTOS("model_photos", "Character sheet photos", "image"),
    OUTFIT("outfit", "Outfit sets", "image"),
    BACKGROUND("background", "Backgrounds", "image"),
    EDIT_HELPERS("edit", "Edit helpers", "video"),
    CAMERA("camera", "Camera shots", "video");

    companion object { fun of(id: String?) = entries.firstOrNull { it.id == id } }
}

/** GET /v1/models?purpose=…: the models the owner can pick for one purpose, and the studio's default (null = Auto). */
@Serializable
data class ModelsForPurpose(val purpose: String = "", val default: String? = null, val models: List<SuiteCatalogEngine> = emptyList())

@Serializable
data class ModelDefaultPatch(val purpose: String, val model: String?)

interface ModelsApi {
    suspend fun models(purpose: ModelPurpose): ModelsForPurpose
    /** Sets the studio's default for [purpose] (null = Auto). */
    suspend fun setDefault(purpose: ModelPurpose, model: String?): ModelsForPurpose

    /** A server without WS13: null, and the caller falls back to the Suite catalog's engines (shots and photos). */
    object Unsupported : ModelsApi {
        override suspend fun models(purpose: ModelPurpose) = throw ApiException("unsupported", "This studio server can't list models yet")
        override suspend fun setDefault(purpose: ModelPurpose, model: String?) = throw ApiException("unsupported", "This studio server can't set default models yet")
    }
}

class HttpModelsApi(baseUrl: String, private val client: OkHttpClient, private val json: Json) : ModelsApi {
    private val base = if (baseUrl.endsWith("/")) baseUrl else "$baseUrl/"

    private suspend fun send(method: String, path: String, body: String?): ModelsForPurpose = withContext(Dispatchers.IO) {
        val rb = body?.toRequestBody("application/json".toMediaType())
        val res = try { client.newCall(Request.Builder().url(base + path).method(method, rb).build()).execute() }
            catch (e: java.io.IOException) { throw ApiException("offline", "Can't reach the server at $base") }
        res.use { r ->
            val t = r.body.string()
            if (!r.isSuccessful) {
                val err = runCatching { json.decodeFromString(ErrorBody.serializer(), t) }.getOrNull()
                throw ApiException(err?.code ?: if (r.code == 404) "unsupported" else "http_${r.code}", err?.error ?: "Server error ${r.code}")
            }
            try { json.decodeFromString(ModelsForPurpose.serializer(), t) } catch (e: kotlinx.serialization.SerializationException) {
                throw ApiException("bad_response", "The server sent something this app version can't read")
            }
        }
    }

    override suspend fun models(purpose: ModelPurpose) = send("GET", "v1/models?purpose=${purpose.id}", null)
    override suspend fun setDefault(purpose: ModelPurpose, model: String?) =
        send("PATCH", "v1/models/defaults", json.encodeToString(ModelDefaultPatch.serializer(), ModelDefaultPatch(purpose.id, model)))
}

/**
 * The demo studio's models per purpose: the Suite catalog's engines of the purpose's kind (video or image), and the
 * defaults the owner sets (kept in memory).
 */
class FakeModelsApi(private val engines: () -> List<SuiteCatalogEngine>) : ModelsApi {
    private val defaults = mutableMapOf<ModelPurpose, String?>()
    override suspend fun models(purpose: ModelPurpose) = ModelsForPurpose(purpose.id, defaults[purpose], engines().filter { it.kind == purpose.kind })
    override suspend fun setDefault(purpose: ModelPurpose, model: String?): ModelsForPurpose { defaults[purpose] = model; return models(purpose) }
}

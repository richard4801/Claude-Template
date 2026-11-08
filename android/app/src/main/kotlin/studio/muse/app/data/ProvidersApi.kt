package studio.muse.app.data

// WS7 (Android) against WS5's "Bring your own provider" contract v1 (branch claude/muse-providers). Owner only: every
// endpoint answers 403 owner_only to a member. An API key goes up once (add or rotate) and never comes back: the server
// returns `keyLast4` only. The demo studio's version is FakeProvidersApi. MuseApi exposes it as `api.providers`.

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

// ---------------------------------------------------------------- types

/** GET /v1/providers/kinds: a provider the studio can connect (replicate, fal). */
@Serializable
data class ProviderKind(val kind: String, val label: String = "", val keyHint: String = "", val keyUrl: String? = null)

@Serializable
data class ProviderKinds(val kinds: List<ProviderKind> = emptyList())

@Serializable
data class ProviderModelCounts(val added: Int = 0, val enabled: Int = 0)

/** A connected provider. The key itself is never sent back: [keyLast4] only. */
@Serializable
data class Provider(
    val id: String,
    val kind: String,
    val label: String = "",
    val keyLast4: String = "",
    /** ok | invalid (the key stopped working at the last check). */
    val status: String = "ok",
    val checkedAt: Long? = null,
    val createdAt: Long = 0,
    val models: ProviderModelCounts = ProviderModelCounts(),
) {
    val invalid get() = status == "invalid"
}

@Serializable
data class Providers(val providers: List<Provider> = emptyList())

@Serializable
data class NewProvider(val kind: String, val apiKey: String, val label: String? = null)

@Serializable
data class ProviderPatch(val label: String? = null, val apiKey: String? = null)

@Serializable
data class DurationRange(val min: Int = 0, val max: Int = 0, val allowed: List<Int>? = null)

/** What a provider model takes, read from its schema. */
@Serializable
data class ProviderInputs(
    val prompt: Boolean = false,
    val negativePrompt: Boolean = false,
    val startImage: Boolean = false,
    val endImage: Boolean = false,
    val referenceImages: Int = 0,
    val duration: DurationRange? = null,
    val aspectRatios: List<String> = emptyList(),
    val resolutions: List<String> = emptyList(),
    val seed: Boolean = false,
)

/** per_run or per_second; [source] provider = read from the provider, owner = the owner typed it. */
@Serializable
data class ProviderPrice(val basis: String = "per_run", val costUsd: Double = 0.0, val source: String = "provider") {
    val perSecond get() = basis == "per_second"
}

@Serializable
data class AddedRef(val id: String, val enabled: Boolean = false)

/** One model in a provider's catalog (the owner's search). [added] is set when the studio already added it. */
@Serializable
data class ProviderCatalogModel(
    val ref: String,
    val name: String = "",
    val description: String? = null,
    /** image | video */
    val kind: String = "image",
    val inputs: ProviderInputs = ProviderInputs(),
    val missing: List<String> = emptyList(),
    val ready: Boolean = false,
    val price: ProviderPrice? = null,
    val added: AddedRef? = null,
)

@Serializable
data class ProviderCatalogPage(val models: List<ProviderCatalogModel> = emptyList(), val nextCursor: String? = null)

@Serializable
data class AddProviderModel(val ref: String, val displayName: String? = null)

@Serializable
data class MemberPrice(val basis: String = "per_run", val usd: Double = 0.0)

/** A model the studio added from one of its providers (`c_…`): usable as an engine once ready and switched on. */
@Serializable
data class CustomModel(
    val id: String,
    val providerId: String = "",
    val providerKind: String = "",
    val ref: String = "",
    val providerName: String = "",
    val displayName: String = "",
    val kind: String = "image",
    val enabled: Boolean = false,
    /** Members can pick it too (by its display name only). */
    val members: Boolean = false,
    /** ready | needs_setup (see [missing]). */
    val status: String = "ready",
    val missing: List<String> = emptyList(),
    val inputs: ProviderInputs = ProviderInputs(),
    val fixedInputs: JsonElement? = null,
    val price: ProviderPrice? = null,
    val priceScale: Double = 1.0,
    val memberPrice: MemberPrice? = null,
    val createdAt: Long = 0,
    val updatedAt: Long = 0,
) {
    val name get() = displayName.ifBlank { providerName.ifBlank { ref } }
    val ready get() = status == "ready"
}

@Serializable
data class CustomModels(val models: List<CustomModel> = emptyList())

/** PATCH /v1/providers/models/:id. Only the fields set are sent (409 needs_setup when switching on an unready one). */
@Serializable
data class CustomModelPatch(
    val enabled: Boolean? = null,
    val displayName: String? = null,
    val members: Boolean? = null,
    val price: ProviderPrice? = null,
    val priceScale: Double? = null,
)

// ---------------------------------------------------------------- the API

interface ProvidersApi {
    suspend fun kinds(): List<ProviderKind>
    suspend fun providers(): List<Provider>
    /** 400 invalid_key (nothing stored), 503 provider_keys_unavailable, 502 provider_unreachable. */
    suspend fun add(req: NewProvider): Provider
    /** Rename and/or rotate the key. */
    suspend fun patch(id: String, patch: ProviderPatch): Provider
    suspend fun remove(id: String)
    suspend fun catalog(providerId: String, q: String = "", kind: String? = null, cursor: String? = null, limit: Int = 30): ProviderCatalogPage
    /** Added switched off. */
    suspend fun addModel(providerId: String, req: AddProviderModel): CustomModel
    suspend fun models(): List<CustomModel>
    suspend fun patchModel(modelId: String, patch: CustomModelPatch): CustomModel
    suspend fun removeModel(modelId: String)

    /** Servers and builds without providers. */
    object Unsupported : ProvidersApi {
        private fun no(): Nothing = throw ApiException("unsupported", "This server doesn't support your own providers yet")
        override suspend fun kinds() = no()
        override suspend fun providers() = no()
        override suspend fun add(req: NewProvider) = no()
        override suspend fun patch(id: String, patch: ProviderPatch) = no()
        override suspend fun remove(id: String) = no()
        override suspend fun catalog(providerId: String, q: String, kind: String?, cursor: String?, limit: Int) = no()
        override suspend fun addModel(providerId: String, req: AddProviderModel) = no()
        override suspend fun models() = no()
        override suspend fun patchModel(modelId: String, patch: CustomModelPatch) = no()
        override suspend fun removeModel(modelId: String) = no()
    }
}

/** The HTTP version (the client already carries the session token). */
class HttpProvidersApi(baseUrl: String, private val client: OkHttpClient, private val json: Json) : ProvidersApi {
    private val base = if (baseUrl.endsWith("/")) baseUrl else "$baseUrl/"
    private val jsonType = "application/json".toMediaType()

    private suspend fun <T> send(method: String, url: String, body: String?, out: KSerializer<T>?): T? = withContext(Dispatchers.IO) {
        val rb = body?.toRequestBody(jsonType) ?: if (method == "POST" || method == "PATCH") "{}".toRequestBody(jsonType) else null
        val req = Request.Builder().url(url).method(method, rb).build()
        val res = try { client.newCall(req).execute() } catch (e: java.io.IOException) { throw ApiException("offline", "Can't reach the server at $base") }
        res.use { r ->
            val text = r.body.string()
            if (!r.isSuccessful) {
                val err = runCatching { json.decodeFromString(ErrorBody.serializer(), text) }.getOrNull()
                throw ApiException(err?.code ?: when (r.code) { 401 -> "unauthorized"; 404 -> "unsupported"; else -> "http_${r.code}" }, err?.error ?: "Server error ${r.code}")
            }
            if (out == null || r.code == 204) null
            else try { json.decodeFromString(out, text) } catch (e: kotlinx.serialization.SerializationException) {
                throw ApiException("bad_response", "The server sent something this app version can't read")
            }
        }
    }

    private fun u(path: String) = base + path
    private fun <B> enc(b: B, s: KSerializer<B>) = json.encodeToString(s, b)

    override suspend fun kinds() = send("GET", u("v1/providers/kinds"), null, ProviderKinds.serializer())!!.kinds
    override suspend fun providers() = send("GET", u("v1/providers"), null, Providers.serializer())!!.providers
    override suspend fun add(req: NewProvider) = send("POST", u("v1/providers"), enc(req, NewProvider.serializer()), Provider.serializer())!!
    override suspend fun patch(id: String, patch: ProviderPatch) = send("PATCH", u("v1/providers/$id"), enc(patch, ProviderPatch.serializer()), Provider.serializer())!!
    override suspend fun remove(id: String) { send("DELETE", u("v1/providers/$id"), null, Unit.serializer()) }
    override suspend fun catalog(providerId: String, q: String, kind: String?, cursor: String?, limit: Int): ProviderCatalogPage {
        val url = u("v1/providers/$providerId/models").toHttpUrl().newBuilder().apply {
            if (q.isNotBlank()) addQueryParameter("q", q)
            kind?.let { addQueryParameter("kind", it) }
            cursor?.let { addQueryParameter("cursor", it) }
            addQueryParameter("limit", limit.coerceIn(1, 50).toString())
        }.build().toString()
        return send("GET", url, null, ProviderCatalogPage.serializer())!!
    }
    override suspend fun addModel(providerId: String, req: AddProviderModel) =
        send("POST", u("v1/providers/$providerId/models"), enc(req, AddProviderModel.serializer()), CustomModel.serializer())!!
    override suspend fun models() = send("GET", u("v1/providers/models"), null, CustomModels.serializer())!!.models
    override suspend fun patchModel(modelId: String, patch: CustomModelPatch) =
        send("PATCH", u("v1/providers/models/$modelId"), enc(patch, CustomModelPatch.serializer()), CustomModel.serializer())!!
    override suspend fun removeModel(modelId: String) { send("DELETE", u("v1/providers/models/$modelId"), null, Unit.serializer()) }
}

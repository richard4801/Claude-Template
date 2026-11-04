package studio.muse.app.data

import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.retryWhen
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.sse.EventSource
import okhttp3.sse.EventSourceListener
import okhttp3.sse.EventSources
import retrofit2.HttpException
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory
import retrofit2.http.Body
import retrofit2.http.DELETE
import retrofit2.http.GET
import retrofit2.http.Multipart
import retrofit2.http.PATCH
import retrofit2.http.POST
import retrofit2.http.PUT
import retrofit2.http.Part
import retrofit2.http.Path
import retrofit2.http.Query
import java.util.concurrent.TimeUnit

/** Retrofit description of plans/api.md. */
interface MuseService {
    @POST("v1/auth/signin") suspend fun signIn(@Body r: SignInRequest): AuthResponse
    @POST("v1/auth/signup") suspend fun signUp(@Body r: SignUpRequest): AuthResponse
    @GET("v1/models") suspend fun models(): List<Model>
    @POST("v1/models") suspend fun createModel(@Body r: CreateModelRequest): Model
    @PUT("v1/models/{id}/slots/{slot}") suspend fun setSlot(@Path("id") id: String, @Path("slot") slot: String, @Body r: SetSlotRequest): Model
    @POST("v1/models/{id}/fill-angles") suspend fun fillAngles(@Path("id") id: String): FillAnglesResponse
    @GET("v1/outfits") suspend fun outfits(): List<Outfit>
    @POST("v1/outfits") suspend fun createOutfit(@Body r: CreateOutfitRequest): Outfit
    @POST("v1/outfits/{id}/save") suspend fun saveOutfit(@Path("id") id: String): Outfit
    @Multipart @POST("v1/uploads/images") suspend fun uploadImage(@Part file: MultipartBody.Part): ImageRef
    @Multipart @POST("v1/uploads/clips") suspend fun uploadClip(@Part("meta") meta: RequestBody, @Part file: MultipartBody.Part?): Clip
    @GET("v1/jobs") suspend fun jobs(): List<Job>
    @POST("v1/jobs") suspend fun createJob(@Body r: JobRequest): Job
    @DELETE("v1/jobs/{id}") suspend fun removeJob(@Path("id") id: String)
    @GET("v1/takes") suspend fun takes(): List<Take>
    @PATCH("v1/takes/{id}") suspend fun setTake(@Path("id") id: String, @Body r: SetTakeStatusRequest): Take
    @DELETE("v1/takes/{id}") suspend fun deleteTake(@Path("id") id: String)
    @POST("v1/shoots") suspend fun shoot(@Body r: ShootRequest): List<Take>
    @GET("v1/balance") suspend fun balance(): Balance
    @POST("v1/balance/topup") suspend fun topUp(@Body r: TopUpRequest): Balance
    @POST("v1/dev/fail-next") suspend fun failNext(@Body r: DevFailRequest)
    @PATCH("v1/models/{id}") suspend fun updateModel(@Path("id") id: String, @Body r: UpdateModelRequest): Model
    @DELETE("v1/models/{id}") suspend fun deleteModel(@Path("id") id: String)
    @POST("v1/queue/run") suspend fun runQueue(): List<Job>
    @GET("v1/models/{id}/lora") suspend fun lora(@Path("id") id: String): Lora
    @POST("v1/models/{id}/lora/candidates") suspend fun buildLoraSet(@Path("id") id: String): Lora
    @PATCH("v1/models/{id}/lora/candidates/{cid}") suspend fun keepCandidate(@Path("id") id: String, @Path("cid") cid: String, @Body r: KeepRequest): Lora
    @POST("v1/models/{id}/lora/train") suspend fun trainLora(@Path("id") id: String): Lora
    @PATCH("v1/models/{id}/lora") suspend fun patchLora(@Path("id") id: String, @Body r: PatchLoraRequest): Lora
    @GET("v1/models/{id}/accounts") suspend fun accounts(@Path("id") id: String): List<Account>
    @POST("v1/models/{id}/accounts/{platform}/connect") suspend fun connect(@Path("id") id: String, @Path("platform") platform: String): ConnectResponse
    @DELETE("v1/models/{id}/accounts/{platform}") suspend fun disconnect(@Path("id") id: String, @Path("platform") platform: String)
    @GET("v1/posts") suspend fun posts(@Query("state") state: String?): List<Post>
    @POST("v1/posts") suspend fun createPost(@Body r: CreatePostRequest): Post
    @DELETE("v1/posts/{id}") suspend fun deletePost(@Path("id") id: String)
}

/** MuseApi over HTTP. Progress comes from the SSE stream at GET /v1/events. */
class HttpMuseApi(baseUrl: String) : MuseApi {
    private val base = if (baseUrl.endsWith("/")) baseUrl else "$baseUrl/"
    @Volatile private var token: String? = null
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true }

    private val client = OkHttpClient.Builder()
        .connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .addInterceptor { chain ->
            val t = token
            chain.proceed(if (t == null) chain.request() else chain.request().newBuilder().header("Authorization", "Bearer $t").build())
        }
        .build()

    private val svc: MuseService = Retrofit.Builder()
        .baseUrl(base)
        .client(client)
        .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
        .build()
        .create(MuseService::class.java)

    override fun setToken(token: String?) { this.token = token }

    /** Turns `{"error": "...", "code": "..."}` bodies into [ApiException] so the UI can show the server's message. */
    private suspend fun <T> call(block: suspend MuseService.() -> T): T = try {
        svc.block()
    } catch (e: HttpException) {
        val body = e.response()?.errorBody()?.string()
        val err = runCatching { json.decodeFromString(ErrorBody.serializer(), body ?: "") }.getOrNull()
        throw ApiException(err?.code ?: "http_${e.code()}", err?.error ?: "Server error ${e.code()}")
    } catch (e: java.io.IOException) {
        throw ApiException("offline", "Can't reach the server at $base")
    }

    override suspend fun signIn(req: SignInRequest) = call { signIn(req) }
    override suspend fun signUp(req: SignUpRequest) = call { signUp(req) }
    override suspend fun listModels() = call { models() }
    override suspend fun createModel(req: CreateModelRequest) = call { createModel(req) }
    override suspend fun setSlot(modelId: String, slot: String, req: SetSlotRequest) = call { setSlot(modelId, slot, req) }
    override suspend fun fillAngles(modelId: String) = call { fillAngles(modelId) }
    override suspend fun listOutfits() = call { outfits() }
    override suspend fun createOutfit(req: CreateOutfitRequest) = call { createOutfit(req) }
    override suspend fun saveOutfit(outfitId: String) = call { saveOutfit(outfitId) }

    override suspend fun uploadImage(name: String, bytes: ByteArray, mime: String): ImageRef = call {
        val ref = uploadImage(MultipartBody.Part.createFormData("file", name, bytes.toRequestBody(mime.toMediaType())))
        // Server returns a path; make it absolute so Coil can load it.
        if (ref.url != null && ref.url.startsWith("/")) ref.copy(url = base.trimEnd('/') + ref.url) else ref
    }

    override suspend fun uploadClip(meta: ClipMeta, bytes: ByteArray?): Clip = call {
        val m = json.encodeToString(ClipMeta.serializer(), meta).toRequestBody("application/json".toMediaType())
        val part = bytes?.let { MultipartBody.Part.createFormData("file", meta.name, it.toRequestBody("video/mp4".toMediaType())) }
        uploadClip(m, part)
    }

    override suspend fun listJobs() = call { jobs() }
    override suspend fun createJob(req: JobRequest) = call { createJob(req) }
    override suspend fun removeJob(jobId: String) = call { removeJob(jobId) }
    override suspend fun listTakes() = call { takes() }
    override suspend fun setTakeStatus(takeId: String, status: String) = call { setTake(takeId, SetTakeStatusRequest(status)) }
    override suspend fun deleteTake(takeId: String) = call { deleteTake(takeId) }
    override suspend fun shoot(req: ShootRequest) = call { shoot(req) }
    override suspend fun balance() = call { balance() }
    override suspend fun topUp(req: TopUpRequest) = call { topUp(req) }
    override suspend fun setFailNext(fail: Boolean) = call { failNext(DevFailRequest(fail)) }
    override suspend fun updateModel(modelId: String, req: UpdateModelRequest) = call { updateModel(modelId, req) }
    override suspend fun deleteModel(modelId: String) = call { deleteModel(modelId) }
    override suspend fun runQueue() = call { runQueue() }
    override suspend fun lora(modelId: String) = call { lora(modelId) }.abs()
    override suspend fun buildLoraSet(modelId: String) = call { buildLoraSet(modelId) }.abs()
    override suspend fun keepCandidate(modelId: String, candidateId: String, keep: Boolean) = call { keepCandidate(modelId, candidateId, KeepRequest(keep)) }.abs()
    override suspend fun trainLora(modelId: String) = call { trainLora(modelId) }.abs()
    override suspend fun patchLora(modelId: String, req: PatchLoraRequest) = call { patchLora(modelId, req) }.abs()
    override suspend fun listAccounts(modelId: String) = call { accounts(modelId) }
    override suspend fun connectAccount(modelId: String, platform: String) = call { connect(modelId, platform) }
    override suspend fun disconnectAccount(modelId: String, platform: String) = call { disconnect(modelId, platform) }
    override suspend fun listPosts(state: String?) = call { posts(state) }.map { it.abs() }
    override suspend fun createPost(req: CreatePostRequest) = call { createPost(req) }.abs()
    override suspend fun deletePost(postId: String) = call { deletePost(postId) }

    /** Relative "/uploads/x" refs → absolute, so Coil can load them. */
    private fun ImageRef.abs(): ImageRef = if (url != null && url.startsWith("/")) copy(url = base.trimEnd('/') + url) else this
    private fun Lora.abs() = copy(candidates = candidates.map { it.copy(image = it.image.abs()) })
    private fun Post.abs() = copy(thumb = thumb?.abs())

    override fun events(): Flow<ApiEvent> = callbackFlow {
        val req = Request.Builder().url(base + "v1/events").apply { token?.let { header("Authorization", "Bearer $it") } }.build()
        val sseClient = client.newBuilder().readTimeout(0, TimeUnit.SECONDS).build()
        val source = EventSources.createFactory(sseClient).newEventSource(req, object : EventSourceListener() {
            override fun onEvent(eventSource: EventSource, id: String?, type: String?, data: String) {
                runCatching { json.decodeFromString(ApiEvent.serializer(), data) }.onSuccess { e -> trySend(e.copy(lora = e.lora?.abs(), post = e.post?.abs())) }
            }
            override fun onFailure(eventSource: EventSource, t: Throwable?, response: Response?) {
                close(t ?: java.io.IOException("SSE closed"))
            }
            override fun onClosed(eventSource: EventSource) { close(java.io.IOException("SSE closed")) }
        })
        awaitClose { source.cancel() }
    }.retryWhen { _, attempt -> delay(minOf(10_000L, 1000L * (attempt + 1))); true }
}

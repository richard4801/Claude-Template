package studio.muse.app.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import okhttp3.MediaType
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.sse.EventSource
import okhttp3.sse.EventSourceListener
import okhttp3.sse.EventSources
import okio.BufferedSink
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
    @GET("health") suspend fun health(): Health
    @POST("v1/auth/signin") suspend fun signIn(@Body r: SignInRequest): AuthResponse
    @POST("v1/auth/signup") suspend fun signUp(@Body r: SignUpRequest): AuthResponse
    @POST("v1/auth/signout") suspend fun signOut(): retrofit2.Response<Unit>
    @GET("v1/auth/me") suspend fun me(): User
    @POST("v1/invites") suspend fun createInvite(@Body r: CreateInviteRequest): InviteCreated
    @GET("v1/invites") suspend fun invites(): List<InviteInfo>
    @GET("v1/models") suspend fun models(): List<Model>
    @POST("v1/models") suspend fun createModel(@Body r: CreateModelRequest): Model
    @PUT("v1/models/{id}/slots/{slot}") suspend fun setSlot(@Path("id") id: String, @Path("slot") slot: String, @Body r: SetSlotRequest): Model
    @POST("v1/models/{id}/fill-angles") suspend fun fillAngles(@Path("id") id: String): FillAnglesResponse
    @GET("v1/outfits") suspend fun outfits(): List<Outfit>
    @POST("v1/outfits") suspend fun createOutfit(@Body r: CreateOutfitRequest): Outfit
    @POST("v1/outfits/{id}/save") suspend fun saveOutfit(@Path("id") id: String): Outfit
    @Multipart @POST("v1/uploads/images") suspend fun uploadImage(@Part file: MultipartBody.Part): ImageRef
    @Multipart @POST("v1/uploads/clips") suspend fun uploadClip(@Part("meta") meta: RequestBody, @Part file: MultipartBody.Part?): Clip
    @POST("v1/uploads/presign") suspend fun presign(@Body r: PresignRequest): PresignResponse
    @POST("v1/uploads/{id}/confirm") suspend fun confirmImage(@Path("id") id: String, @Body r: JsonObject): ImageRef
    @POST("v1/uploads/{id}/confirm") suspend fun confirmClip(@Path("id") id: String, @Body r: ConfirmClipRequest): Clip
    @GET("v1/jobs") suspend fun jobs(): List<Job>
    @POST("v1/jobs") suspend fun createJob(@Body r: JobRequest): Job
    @DELETE("v1/jobs/{id}") suspend fun removeJob(@Path("id") id: String)
    @GET("v1/takes") suspend fun takes(): List<Take>
    @PATCH("v1/takes/{id}") suspend fun setTake(@Path("id") id: String, @Body r: SetTakeStatusRequest): Take
    @DELETE("v1/takes/{id}") suspend fun deleteTake(@Path("id") id: String)
    @POST("v1/takes/{id}/versions") suspend fun createVersion(@Path("id") id: String, @Body r: TakeVersionRequest): Take
    @GET("v1/takes/{id}/versions") suspend fun versions(@Path("id") id: String): List<Take>
    @POST("v1/shoots") suspend fun shoot(@Body r: ShootRequest): List<Take>
    @POST("v1/shoots/preview") suspend fun previewShoot(@Body r: ShootRequest): ShootPreview
    @GET("v1/prompts") suspend fun prompts(): PromptLibrary
    @PUT("v1/prompts/{key}") suspend fun savePrompt(@Path("key") key: String, @Body r: PromptText): PromptEntry
    @DELETE("v1/prompts/{key}") suspend fun resetPrompt(@Path("key") key: String): PromptEntry
    @POST("v1/prompts/preview") suspend fun previewPrompt(@Body r: PromptPreviewRequest): PromptPreview
    // Prompt scripts (workstream 4)
    @GET("v1/prompt-scripts") suspend fun promptScripts(): PromptScriptsList
    @GET("v1/prompt-scripts/{id}") suspend fun promptScript(@Path("id") id: String): ScriptView
    @PUT("v1/prompt-scripts/{id}") suspend fun savePromptScript(@Path("id") id: String, @Body r: SaveScriptRules): ScriptView
    @DELETE("v1/prompt-scripts/{id}") suspend fun resetPromptScript(@Path("id") id: String): ScriptView
    @POST("v1/prompt-scripts/preview") suspend fun previewPromptScript(@Body r: ScriptPreviewRequest): ScriptPreview
    @GET("v1/templates") suspend fun templates(@Query("scope") scope: String, @Query("q") q: String?, @Query("tag") tag: String?): List<Template>
    @GET("v1/templates/{id}") suspend fun template(@Path("id") id: String): Template
    @POST("v1/templates") suspend fun createTemplate(@Body r: CreateTemplateRequest): Template
    @POST("v1/templates/draft") suspend fun templateDraft(@Body r: TemplateDraftRequest): TemplateDraft
    @PATCH("v1/templates/{id}") suspend fun patchTemplate(@Path("id") id: String, @Body r: PatchTemplateRequest): Template
    @DELETE("v1/templates/{id}") suspend fun deleteTemplate(@Path("id") id: String): retrofit2.Response<Unit>
    @POST("v1/templates/{id}/duplicate") suspend fun duplicateTemplate(@Path("id") id: String): Template
    @POST("v1/templates/{id}/favourite") suspend fun favourite(@Path("id") id: String): Template
    @DELETE("v1/templates/{id}/favourite") suspend fun unfavourite(@Path("id") id: String): Template
    @POST("v1/templates/{id}/prompt") suspend fun templatePrompt(@Path("id") id: String, @Body r: TemplatePromptRequest): TemplatePrompt
    @GET("v1/balance") suspend fun balance(): Balance
    @POST("v1/balance/topup") suspend fun topUp(@Body r: TopUpRequest): Balance
    @GET("v1/studio/balance") suspend fun studioBalance(): StudioBalance
    @POST("v1/studio/topups") suspend fun addTopUp(@Body r: AddTopUpRequest): StudioBalance
    @POST("v1/takes/{id}/upscale") suspend fun upscale(@Path("id") id: String, @Body r: UpscaleRequest): Job
    @GET("v1/wallet") suspend fun wallet(): Wallet
    @GET("v1/members") suspend fun members(): List<Member>
    @PATCH("v1/members/{id}") suspend fun patchMember(@Path("id") id: String, @Body r: JsonObject): Member
    @POST("v1/wallets/transfer") suspend fun transfer(@Body r: TransferRequest): WalletMemberResponse
    @POST("v1/wallets/reclaim") suspend fun reclaim(@Body r: ReclaimRequest): WalletMemberResponse
    @GET("v1/settings/studio") suspend fun studioSettings(): StudioSettings
    @PATCH("v1/settings/studio") suspend fun patchStudioSettings(@Body r: StudioSettingsPatch): StudioSettings
    @GET("v1/settings/image-engine") suspend fun imageEngine(): ImageEngine
    @PATCH("v1/settings/image-engine") suspend fun setImageEngine(@Body r: ImageEnginePatch): ImageEngine
    @POST("v1/dev/fail-next") suspend fun failNext(@Body r: DevFailRequest)
    @GET("v1/gpu/warm") suspend fun warmGpu(): WarmGpu
    @POST("v1/gpu/warm") suspend fun setWarmGpu(@Body r: WarmRequest): WarmGpu
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
    // Model tools (plans/api.md "Model tools")
    @GET("v1/image-models") suspend fun imageModels(): StepModels
    @GET("v1/image-models/catalog") suspend fun imageCatalog(@Query("step") step: String, @Query("q") q: String?, @Query("collection") collection: String?): CatalogPage
    @GET("v1/image-models/model") suspend fun imageModel(@Query("id") id: String, @Query("step") step: String): ModelDetail
    @PUT("v1/image-models/{step}") suspend fun setImageModel(@Path("step") step: String, @Body r: SetStepModelRequest): StepModel
    @DELETE("v1/image-models/{step}") suspend fun resetImageModel(@Path("step") step: String): StepModel
    @POST("v1/models/{id}/enhance/estimate") suspend fun enhanceEstimate(@Path("id") id: String, @Body r: EnhanceRequest): ToolEstimate
    @POST("v1/models/{id}/enhance") suspend fun startEnhance(@Path("id") id: String, @Body r: EnhanceRequest): ToolRun
    @POST("v1/models/{id}/dress-up/estimate") suspend fun dressUpEstimate(@Path("id") id: String, @Body r: DressUpRequest): ToolEstimate
    @POST("v1/models/{id}/dress-up") suspend fun startDressUp(@Path("id") id: String, @Body r: DressUpRequest): ToolRun
    @GET("v1/tool-runs") suspend fun toolRuns(@Query("modelId") modelId: String?): List<ToolRun>
    @GET("v1/tool-runs/{id}") suspend fun toolRun(@Path("id") id: String): ToolRun
    @PATCH("v1/tool-runs/{id}/items/{slot}") suspend fun decideTool(@Path("id") id: String, @Path("slot") slot: String, @Body r: DecideRequest): ToolRun
    @POST("v1/tool-runs/{id}/pick") suspend fun pickTool(@Path("id") id: String, @Body r: PickRequest): ToolRun
    @POST("v1/tool-runs/{id}/items/{slot}/retry") suspend fun retryTool(@Path("id") id: String, @Path("slot") slot: String, @Body r: RetryRequest): ToolRun
    @POST("v1/tool-runs/{id}/apply") suspend fun applyTool(@Path("id") id: String, @Body r: ApplyRequest): ApplyResponse
    @DELETE("v1/tool-runs/{id}") suspend fun discardTool(@Path("id") id: String): retrofit2.Response<Unit>
    @GET("v1/models/{id}/sheet-versions") suspend fun sheetVersions(@Path("id") id: String): List<SheetVersion>
    @POST("v1/models/{id}/sheet-versions/{vid}/restore") suspend fun restoreSheet(@Path("id") id: String, @Path("vid") vid: String): Model
    @POST("v1/models/{id}/archive") suspend fun archiveModel(@Path("id") id: String): Model
    @POST("v1/models/{id}/unarchive") suspend fun unarchiveModel(@Path("id") id: String): Model
    @GET("v1/models") suspend fun archivedModels(@Query("archived") archived: Boolean = true): List<Model>
}

/**
 * How files go up. AUTO asks GET /health once: `storage: "s3"` (R2) → presigned PUT + confirm; anything else (the
 * real API with `storage: "local"`, whose presigned links point at its own PUBLIC_URL, or server/mock) → multipart.
 */
enum class UploadMode { AUTO, PRESIGNED, MULTIPART }

/** MuseApi over HTTP. Progress comes from the SSE stream at GET /v1/events. */
class HttpMuseApi(baseUrl: String, private val uploadMode: UploadMode = UploadMode.AUTO) : MuseApi {
    private val base = if (baseUrl.endsWith("/")) baseUrl else "$baseUrl/"
    val baseUrl: String get() = base
    @Volatile private var token: String? = null
    @Volatile private var storage: String? = null
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true; coerceInputValues = true }

    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(5, TimeUnit.MINUTES)
        .addInterceptor { chain ->
            val t = token
            chain.proceed(if (t == null) chain.request() else chain.request().newBuilder().header("Authorization", "Bearer $t").build())
        }
        .build()

    /** For presigned PUTs to storage: never sends our bearer token to R2. */
    private val storageClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .writeTimeout(10, TimeUnit.MINUTES)
        .readTimeout(2, TimeUnit.MINUTES)
        .build()

    private val svc: MuseService = Retrofit.Builder()
        .baseUrl(base)
        .client(client)
        .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
        .build()
        .create(MuseService::class.java)

    /** Same API with a long read timeout, for calls that make images before answering (shoots, outfit sets). */
    private val longSvc: MuseService = Retrofit.Builder()
        .baseUrl(base)
        .client(client.newBuilder().readTimeout(6, TimeUnit.MINUTES).build())
        .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
        .build()
        .create(MuseService::class.java)

    override fun setToken(token: String?) { this.token = token }

    /** Turns `{"error": "...", "code": "..."}` bodies into [ApiException]. The UI words the codes (see [ErrorText]). */
    private suspend fun <T> call(block: suspend MuseService.() -> T): T = callOn(svc, block)
    private suspend fun <T> callLong(block: suspend MuseService.() -> T): T = callOn(longSvc, block)

    private suspend fun <T> callOn(service: MuseService, block: suspend MuseService.() -> T): T = try {
        service.block()
    } catch (e: HttpException) {
        val body = runCatching { e.response()?.errorBody()?.string() }.getOrNull()
        val err = runCatching { json.decodeFromString(ErrorBody.serializer(), body ?: "") }.getOrNull()
        val code = err?.code ?: when (e.code()) { 401 -> "unauthorized"; 429 -> "rate_limited"; 413 -> "too_large"; else -> "http_${e.code()}" }
        throw ApiException(code, err?.error ?: "Server error ${e.code()}")
    } catch (e: java.net.SocketTimeoutException) {
        throw ApiException("still_working", "This is taking longer than usual. It keeps going on the server; the results will appear in Gallery.")
    } catch (e: java.io.IOException) {
        throw ApiException("offline", "Can't reach the server at $base")
    } catch (e: kotlinx.serialization.SerializationException) {
        throw ApiException("bad_response", "The server sent something this app version can't read")
    }

    suspend fun health(): Health = call { health() }

    override suspend fun signIn(req: SignInRequest) = call { signIn(req) }
    override suspend fun signUp(req: SignUpRequest) = call { signUp(req.copy(inviteCode = req.inviteCode?.trim()?.ifBlank { null })) }
    override suspend fun signOut() { call { signOut() } }
    override suspend fun me() = call { me() }
    override suspend fun createInvite(req: CreateInviteRequest) = call { createInvite(req) }
    override suspend fun listInvites() = call { invites() }
    override suspend fun listModels() = call { models() }.map { it.abs() }
    override suspend fun createModel(req: CreateModelRequest) = call { createModel(req) }.abs()
    override suspend fun setSlot(modelId: String, slot: String, req: SetSlotRequest) = call { setSlot(modelId, slot, req) }.abs()
    override suspend fun fillAngles(modelId: String) = call { fillAngles(modelId) }.let { it.copy(model = it.model.abs()) }
    override suspend fun listOutfits() = call { outfits() }.map { it.abs() }
    override suspend fun createOutfit(req: CreateOutfitRequest) = callLong { createOutfit(req) }.abs()
    override suspend fun saveOutfit(outfitId: String) = call { saveOutfit(outfitId) }.abs()

    private suspend fun usePresigned(): Boolean = when (uploadMode) {
        UploadMode.PRESIGNED -> true
        UploadMode.MULTIPART -> false
        UploadMode.AUTO -> (storage ?: runCatching { health().storage ?: "none" }.getOrDefault("none").also { storage = it }) == "s3"
    }

    override suspend fun uploadImage(name: String, bytes: ByteArray, mime: String, onProgress: (Float) -> Unit): ImageRef {
        val ref = if (usePresigned()) {
            val id = putPresigned("image", mime, bytes, onProgress)
            call { confirmImage(id, JsonObject(emptyMap())) }
        } else call {
            uploadImage(MultipartBody.Part.createFormData("file", name, ProgressBody(bytes, mime.toMediaTypeOrNull(), onProgress)))
        }
        onProgress(1f)
        // The server may return a path; make it absolute so Coil can load it.
        return ref.abs()
    }

    override suspend fun uploadClip(meta: ClipMeta, bytes: ByteArray?, mime: String, onProgress: (Float) -> Unit): Clip {
        if (bytes != null && usePresigned()) {
            val id = putPresigned("clip", mime, bytes, onProgress)
            return call { confirmClip(id, ConfirmClipRequest(meta)) }.also { onProgress(1f) }
        }
        return call {
            val m = json.encodeToString(ClipMeta.serializer(), meta).toRequestBody("application/json".toMediaType())
            val part = bytes?.let { MultipartBody.Part.createFormData("file", meta.name, ProgressBody(it, mime.toMediaTypeOrNull(), onProgress)) }
            uploadClip(m, part)
        }.also { onProgress(1f) }
    }

    /** presign → PUT straight to storage (R2) with progress → returns the upload id to confirm. */
    private suspend fun putPresigned(kind: String, mime: String, bytes: ByteArray, onProgress: (Float) -> Unit): String {
        val p = call { presign(PresignRequest(kind, mime, bytes.size.toLong())) }
        val ct = p.headers.entries.firstOrNull { it.key.equals("content-type", true) }?.value ?: mime
        putToStorage(p, ProgressBody(bytes, ct.toMediaTypeOrNull(), onProgress))
        return p.uploadId
    }

    /** The PUT of a presigned upload (never with our bearer token). */
    private suspend fun putToStorage(p: PresignResponse, body: RequestBody) {
        val req = Request.Builder().url(p.url).apply {
            p.headers.forEach { (k, v) -> if (!k.equals("content-type", true)) header(k, v) }
        }.method(p.method.ifBlank { "PUT" }, body).build()
        withContext(Dispatchers.IO) {
            try {
                storageClient.newCall(req).execute().use { r ->
                    if (!r.isSuccessful) throw ApiException("upload_failed", "The upload was refused (${r.code})")
                }
            } catch (e: java.io.IOException) {
                throw ApiException("upload_failed", "The upload was interrupted")
            }
        }
    }

    override suspend fun listJobs() = call { jobs() }.map { it.abs() }
    override suspend fun createJob(req: JobRequest) = call { createJob(req) }.abs()
    override suspend fun removeJob(jobId: String) = call { removeJob(jobId) }

    /** Edited version: the MP4 (streamed from disk) and its JPEG go up with presigned PUTs, then the take is created. */
    override suspend fun saveTakeVersion(takeId: String, video: EditedVideo, edits: EditListDto, onProgress: (Float) -> Unit): Take {
        val p = call { presign(PresignRequest("clip", "video/mp4", video.file.length())) }
        putToStorage(p, FileProgressBody(video.file, "video/mp4".toMediaType()) { onProgress(it * .97f) })
        val thumbId = video.thumbJpeg?.let { putPresigned("image", "image/jpeg", it) {} }
        val req = TakeVersionRequest(p.uploadId, thumbId, edits, video.durationSec, video.width, video.height, video.fps)
        return call { createVersion(takeId, req) }.abs().also { onProgress(1f) }
    }
    override suspend fun takeVersions(takeId: String) = call { versions(takeId) }.map { it.abs() }
    override suspend fun listTakes() = call { takes() }.map { it.abs() }
    override suspend fun setTakeStatus(takeId: String, status: String) = call { setTake(takeId, SetTakeStatusRequest(status)) }.abs()
    override suspend fun deleteTake(takeId: String) = call { deleteTake(takeId) }
    override suspend fun shoot(req: ShootRequest) = callLong { shoot(req) }.map { it.abs() }
    override suspend fun listTemplates(scope: String, q: String?, tag: String?) = call { templates(scope, q?.ifBlank { null }, tag?.ifBlank { null }) }.map { it.abs() }
    override suspend fun template(id: String) = call { template(id) }.abs()
    override suspend fun createTemplate(req: CreateTemplateRequest) = call { createTemplate(req) }.abs()
    override suspend fun templateDraft(fromShotId: String) = call { templateDraft(TemplateDraftRequest(fromShotId)) }.let { it.copy(cover = it.cover?.abs()) }
    override suspend fun patchTemplate(id: String, req: PatchTemplateRequest) = call { patchTemplate(id, req) }.abs()
    override suspend fun deleteTemplate(id: String) { call { deleteTemplate(id).also { r -> if (!r.isSuccessful) throw HttpException(r) } } }
    override suspend fun duplicateTemplate(id: String) = call { duplicateTemplate(id) }.abs()
    override suspend fun favouriteTemplate(id: String, on: Boolean) = call { if (on) favourite(id) else unfavourite(id) }.abs()
    override suspend fun templatePrompt(id: String, req: TemplatePromptRequest) = call { templatePrompt(id, req) }
    override suspend fun previewShoot(req: ShootRequest) = call { previewShoot(req) }
    override suspend fun prompts() = call { prompts() }
    override suspend fun savePrompt(key: String, text: String) = call { savePrompt(key, PromptText(text)) }
    override suspend fun resetPrompt(key: String) = call { resetPrompt(key) }
    override suspend fun previewPrompt(req: PromptPreviewRequest) = call { previewPrompt(req) }
    // Prompt scripts (workstream 4)
    override suspend fun listPromptScripts() = call { promptScripts() }
    override suspend fun getPromptScript(id: String) = call { promptScript(id) }
    override suspend fun savePromptScript(id: String, rules: List<Rule>) = call { savePromptScript(id, SaveScriptRules(rules)) }
    override suspend fun resetPromptScript(id: String) = call { resetPromptScript(id) }
    override suspend fun previewPromptScript(id: String, inputs: JsonObject?, rules: List<Rule>?, texts: Map<String, String>?, direction: String?) =
        call { previewPromptScript(ScriptPreviewRequest(id, inputs, rules, texts, direction)) }
    override suspend fun balance() = call { balance() }
    override suspend fun topUp(req: TopUpRequest) = call { topUp(req) }
    override suspend fun wallet() = call { wallet() }
    override suspend fun studioBalance() = call { studioBalance() }
    override suspend fun addTopUp(req: AddTopUpRequest) = call { addTopUp(req) }
    override suspend fun upscale(takeId: String, size: String) = call { upscale(takeId, UpscaleRequest(size)) }
    override suspend fun listMembers() = call { members() }
    override suspend fun transfer(req: TransferRequest) = call { transfer(req) }
    override suspend fun reclaim(req: ReclaimRequest) = call { reclaim(req) }
    override suspend fun patchMember(memberId: String, patch: MemberPatch) = call {
        patchMember(memberId, buildJsonObject {
            if (patch.clearCapPerDay) put("capPerDay", JsonNull) else patch.capPerDay?.let { put("capPerDay", JsonPrimitive(it)) }
            patch.disabled?.let { put("disabled", JsonPrimitive(it)) }
        })
    }
    override suspend fun studioSettings() = call { studioSettings() }
    override suspend fun patchStudioSettings(req: StudioSettingsPatch) = call { patchStudioSettings(req) }
    override suspend fun imageEngine() = call { imageEngine() }
    override suspend fun setImageEngine(req: ImageEnginePatch) = call { setImageEngine(req) }
    override suspend fun setFailNext(fail: Boolean) = call { failNext(DevFailRequest(fail)) }
    override suspend fun warmGpu() = call { warmGpu() }
    override suspend fun setWarmGpu(req: WarmRequest) = call { setWarmGpu(req) }
    override suspend fun updateModel(modelId: String, req: UpdateModelRequest) = call { updateModel(modelId, req) }.abs()
    override suspend fun deleteModel(modelId: String) = call { deleteModel(modelId) }
    override suspend fun imageModels() = call { imageModels() }
    override suspend fun imageCatalog(step: String, q: String?, collection: String?) = call { imageCatalog(step, q?.ifBlank { null }, collection?.ifBlank { null }) }
    override suspend fun imageModel(id: String, step: String) = call { imageModel(id, step) }
    override suspend fun setImageModel(step: String, req: SetStepModelRequest) = call { setImageModel(step, req) }
    override suspend fun resetImageModel(step: String) = call { resetImageModel(step) }
    override suspend fun enhanceEstimate(modelId: String, req: EnhanceRequest) = call { enhanceEstimate(modelId, req) }
    override suspend fun startEnhance(modelId: String, req: EnhanceRequest) = call { startEnhance(modelId, req) }.abs()
    override suspend fun dressUpEstimate(modelId: String, req: DressUpRequest) = call { dressUpEstimate(modelId, req) }
    override suspend fun startDressUp(modelId: String, req: DressUpRequest) = call { startDressUp(modelId, req) }.abs()
    override suspend fun toolRuns(modelId: String?) = call { toolRuns(modelId) }.map { it.abs() }
    override suspend fun toolRun(id: String) = call { toolRun(id) }.abs()
    override suspend fun decideTool(id: String, slot: String, req: DecideRequest) = call { decideTool(id, slot, req) }.abs()
    override suspend fun pickTool(id: String, pick: String) = call { pickTool(id, PickRequest(pick)) }.abs()
    override suspend fun retryTool(id: String, slot: String, engine: String?) = call { retryTool(id, slot, RetryRequest(engine)) }.abs()
    override suspend fun applyTool(id: String, name: String?) = call { applyTool(id, ApplyRequest(name)) }.let { r -> r.copy(run = r.run.abs(), model = r.model.abs(), outfit = r.outfit?.abs()) }
    override suspend fun discardTool(id: String) { call { discardTool(id) } }
    override suspend fun sheetVersions(modelId: String) = call { sheetVersions(modelId) }.map { it.abs() }
    override suspend fun restoreSheet(modelId: String, versionId: String) = call { restoreSheet(modelId, versionId) }.abs()
    override suspend fun archiveModel(modelId: String, archived: Boolean) = call { if (archived) archiveModel(modelId) else unarchiveModel(modelId) }.abs()
    override suspend fun archivedModels() = call { archivedModels() }.map { it.abs() }
    override suspend fun runQueue() = call { runQueue() }.map { it.abs() }
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

    /** Relative "/uploads/x" refs → absolute, so Coil and ExoPlayer can load them. */
    private fun String.absUrl(): String = if (startsWith("/")) base.trimEnd('/') + this else this
    private fun ImageRef.abs(): ImageRef = if (url != null && url.startsWith("/")) copy(url = url.absUrl()) else this
    private fun Lora.abs() = copy(candidates = candidates.map { it.copy(image = it.image.abs()) })
    private fun Post.abs() = copy(thumb = thumb?.abs())
    private fun Model.abs() = copy(slots = slots.map { it.copy(image = it.image?.abs()) })
    private fun Outfit.abs() = copy(angles = angles.map { it?.abs() }, faces = faces?.map { it?.abs() })
    private fun ToolRun.abs() = copy(items = items.map { i -> i.copy(before = i.before?.abs(), results = ToolResults(i.results.a?.abs(), i.results.b?.abs())) },
        options = options.copy(outfitImage = options.outfitImage?.abs()))
    private fun SheetVersion.abs() = copy(slots = slots.map { it.copy(image = it.image?.abs()) })
    private fun Job.abs() = copy(thumb = thumb?.abs())
    private fun Take.abs() = copy(thumb = thumb?.abs(), videoUrl = videoUrl?.absUrl())
    private fun Template.abs() = copy(cover = cover?.abs(), recent = recent?.map { it.copy(thumb = it.thumb?.abs()) })

    /** Reconnects forever: 1 s after a drop, backing off to 10 s while the server can't be reached. */
    override fun events(): Flow<ApiEvent> = flow {
        var fails = 0
        while (true) {
            var opened = false
            try {
                eventStream().collect { if (it.type == ApiEvent.CONNECTED) opened = true; emit(it) }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Throwable) {
            }
            if (opened) fails = 0
            delay(minOf(10_000L, 1000L * ++fails))
        }
    }

    private fun eventStream(): Flow<ApiEvent> = callbackFlow {
        val req = Request.Builder().url(base + "v1/events").apply { token?.let { header("Authorization", "Bearer $it") } }.build()
        // The server sends a comment every 10 s (15 s on older builds), so 40 s without a byte means the connection died
        // quietly (sleep, a network change, a proxy dropping it): fail, and retryWhen reconnects.
        val sseClient = client.newBuilder().readTimeout(40, TimeUnit.SECONDS).build()
        val source = EventSources.createFactory(sseClient).newEventSource(req, object : EventSourceListener() {
            override fun onOpen(eventSource: EventSource, response: Response) {
                trySend(ApiEvent(ApiEvent.CONNECTED))
            }
            override fun onEvent(eventSource: EventSource, id: String?, type: String?, data: String) {
                runCatching { json.decodeFromString(ApiEvent.serializer(), data) }.onSuccess { e ->
                    trySend(e.copy(lora = e.lora?.abs(), post = e.post?.abs(), job = e.job?.abs(), model = e.model?.abs(), outfit = e.outfit?.abs(), takes = e.takes.map { it.abs() },
                        tool = e.tool?.abs(), take = e.take?.abs(), template = e.template?.abs(), clip = e.clip?.let { c -> c.copy(thumb = c.thumb?.abs()) }))
                }
            }
            override fun onFailure(eventSource: EventSource, t: Throwable?, response: Response?) {
                close(t ?: java.io.IOException("SSE closed"))
            }
            override fun onClosed(eventSource: EventSource) { close(java.io.IOException("SSE closed")) }
        })
        awaitClose { source.cancel() }
    }
}

/** A byte-array body that reports how much has been written (0..1). */
private class ProgressBody(private val bytes: ByteArray, private val type: MediaType?, private val onProgress: (Float) -> Unit) : RequestBody() {
    override fun contentType() = type
    override fun contentLength() = bytes.size.toLong()
    override fun writeTo(sink: BufferedSink) {
        val chunk = 64 * 1024
        var off = 0
        onProgress(0f)
        while (off < bytes.size) {
            val n = minOf(chunk, bytes.size - off)
            sink.write(bytes, off, n)
            off += n
            sink.flush()
            onProgress(off.toFloat() / bytes.size.coerceAtLeast(1))
        }
    }
}

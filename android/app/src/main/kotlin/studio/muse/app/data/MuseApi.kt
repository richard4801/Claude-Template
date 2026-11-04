package studio.muse.app.data

import kotlinx.coroutines.flow.Flow

/**
 * The backend contract (plans/api.md). Two implementations:
 *  - [FakeMuseApi]: in-process, no server, the default for debug installs.
 *  - [HttpMuseApi]: REST + Server-Sent Events against server/mock (or the real backend later).
 * Settings → Developer switches between them.
 */
interface MuseApi {
    // Auth (stub: any email/password works; sign-up requires both attestations)
    suspend fun signIn(req: SignInRequest): AuthResponse
    suspend fun signUp(req: SignUpRequest): AuthResponse
    fun setToken(token: String?)

    // Models and character sheets
    suspend fun listModels(): List<Model>
    suspend fun createModel(req: CreateModelRequest): Model
    suspend fun setSlot(modelId: String, slot: String, req: SetSlotRequest): Model
    /** Generates the missing angles from the user's images ($0.02 each). Slots come back busy; a model event follows. */
    suspend fun fillAngles(modelId: String): FillAnglesResponse
    suspend fun updateModel(modelId: String, req: UpdateModelRequest): Model
    /** Deletes the model with her outfits, LoRAs, training set, accounts and unsent posts. */
    suspend fun deleteModel(modelId: String)

    // Outfit sets
    suspend fun listOutfits(): List<Outfit>
    /** Starts generating an outfit set preview (state=generating; an outfit event follows). */
    suspend fun createOutfit(req: CreateOutfitRequest): Outfit
    /** Attaches a generated preview to the model. */
    suspend fun saveOutfit(outfitId: String): Outfit

    // Uploads
    suspend fun uploadImage(name: String, bytes: ByteArray, mime: String): ImageRef
    /** Registers a source clip and runs the clip checks. [bytes] may be null for the bundled sample clips. */
    suspend fun uploadClip(meta: ClipMeta, bytes: ByteArray?): Clip

    // Jobs and takes
    suspend fun listJobs(): List<Job>
    suspend fun createJob(req: JobRequest): Job
    suspend fun removeJob(jobId: String)
    /** Starts queued jobs, oldest first, charging each. Returns the jobs it started. */
    suspend fun runQueue(): List<Job>
    suspend fun listTakes(): List<Take>
    suspend fun setTakeStatus(takeId: String, status: String): Take
    suspend fun deleteTake(takeId: String)
    suspend fun shoot(req: ShootRequest): List<Take>

    // Identity LoRA
    suspend fun lora(modelId: String): Lora
    /** Generates 30 candidates ($0.60). state=building; a lora event follows with state=review. */
    suspend fun buildLoraSet(modelId: String): Lora
    suspend fun keepCandidate(modelId: String, candidateId: String, keep: Boolean): Lora
    /** Trains the photo then the video LoRA (needs 20+ kept; charges the training price). Progress arrives as lora events. */
    suspend fun trainLora(modelId: String): Lora
    /** use: on/off for new renders. state="review": retrain with the same shots. */
    suspend fun patchLora(modelId: String, req: PatchLoraRequest): Lora

    // Social accounts and posts
    suspend fun listAccounts(modelId: String): List<Account>
    suspend fun connectAccount(modelId: String, platform: String): ConnectResponse
    suspend fun disconnectAccount(modelId: String, platform: String)
    suspend fun listPosts(state: String? = null): List<Post>
    suspend fun createPost(req: CreatePostRequest): Post
    suspend fun deletePost(postId: String)

    // Balance
    suspend fun balance(): Balance
    suspend fun topUp(req: TopUpRequest): Balance

    // Developer
    suspend fun setFailNext(fail: Boolean)

    /** Live job progress, balance and generation updates. */
    fun events(): Flow<ApiEvent>
}

package studio.muse.app.data

import kotlinx.coroutines.flow.Flow

/**
 * The backend contract (plans/api.md). Two implementations:
 *  - [HttpMuseApi]: REST + Server-Sent Events against the real API (server/api, the default) or server/mock.
 *  - [FakeMuseApi]: in-process "Demo mode" with the bundled sample studio, no server.
 * Settings → Developer switches between them.
 */
interface MuseApi {
    // Auth: invite-only on the real API; sign-up requires both attestations.
    suspend fun signIn(req: SignInRequest): AuthResponse
    suspend fun signUp(req: SignUpRequest): AuthResponse
    /** Revokes this session on the server. */
    suspend fun signOut()
    /** The signed-in user, used on launch to restore the session. `unauthorized` when it has ended. */
    suspend fun me(): User
    fun setToken(token: String?)

    // Invites (owner)
    suspend fun createInvite(req: CreateInviteRequest): InviteCreated
    suspend fun listInvites(): List<InviteInfo>

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

    // Uploads. [onProgress] gets 0..1 while the bytes go up (presigned PUT to R2, or multipart).
    suspend fun uploadImage(name: String, bytes: ByteArray, mime: String, onProgress: (Float) -> Unit = {}): ImageRef
    /** Registers a source clip and runs the clip checks. [bytes] may be null for the bundled sample clips. */
    suspend fun uploadClip(meta: ClipMeta, bytes: ByteArray?, mime: String = "video/mp4", onProgress: (Float) -> Unit = {}): Clip

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

    // Photo templates (plans/templates.md). Hidden layers come back only for the owner's own templates.
    /** scope: all | mine | public | favourites. */
    suspend fun listTemplates(scope: String = "all", q: String? = null, tag: String? = null): List<Template>
    /** With `recent` (the newest shots made with it). */
    suspend fun template(id: String): Template
    suspend fun createTemplate(req: CreateTemplateRequest): Template
    /** What "Save as template" would save from this shot, to show and edit first. Nothing is stored. */
    suspend fun templateDraft(fromShotId: String): TemplateDraft
    suspend fun patchTemplate(id: String, req: PatchTemplateRequest): Template
    suspend fun deleteTemplate(id: String)
    suspend fun duplicateTemplate(id: String): Template
    suspend fun favouriteTemplate(id: String, on: Boolean): Template
    /** The prompt view for a template shoot: non-owners get one locked "Template: <name>" line plus their own layers. */
    suspend fun templatePrompt(id: String, req: TemplatePromptRequest): TemplatePrompt

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

    // Balance, wallets and members
    suspend fun balance(): Balance
    suspend fun topUp(req: TopUpRequest): Balance
    suspend fun wallet(): Wallet
    suspend fun listMembers(): List<Member>
    suspend fun transfer(req: TransferRequest): WalletMemberResponse
    suspend fun reclaim(req: ReclaimRequest): WalletMemberResponse
    suspend fun patchMember(memberId: String, patch: MemberPatch): Member

    // Studio settings (owner) and the image engine
    suspend fun studioSettings(): StudioSettings
    suspend fun patchStudioSettings(req: StudioSettingsPatch): StudioSettings
    suspend fun imageEngine(): ImageEngine
    suspend fun setImageEngine(req: ImageEnginePatch): ImageEngine

    // Keep GPU warm (plans/api.md): a dedicated GPU so renders start at once, billed per minute.
    suspend fun warmGpu(): WarmGpu
    /** {on: true|false} or {extend: true} ("Keep warm"). */
    suspend fun setWarmGpu(req: WarmRequest): WarmGpu

    // Developer
    suspend fun setFailNext(fail: Boolean)

    /** Live job progress, balance and generation updates. */
    fun events(): Flow<ApiEvent>
}

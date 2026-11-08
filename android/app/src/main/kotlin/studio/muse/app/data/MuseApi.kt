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
    /** Saves a video edited on this device as a new take (kind "edit") linked to [takeId] (plans/api.md "Video editor"). Free. */
    suspend fun saveTakeVersion(takeId: String, video: EditedVideo, edits: EditListDto, onProgress: (Float) -> Unit = {}): Take =
        throw ApiException("unsupported", "Saving an edited video needs the studio server")
    /** The edited versions of a take, newest first. */
    suspend fun takeVersions(takeId: String): List<Take> = listTakes().filter { it.parentTakeId == takeId }.sortedByDescending { it.createdAt }
    suspend fun shoot(req: ShootRequest): List<Take>
    /** The final prompt the shoot will send (built on the server from the prompt library), the images and the estimate. Free. */
    suspend fun previewShoot(req: ShootRequest): ShootPreview

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
    /** The owner-loaded studio balance and its top-ups (plans/api.md "App clean-up" §4, owner only). */
    suspend fun studioBalance(): StudioBalance
    suspend fun addTopUp(req: AddTopUpRequest): StudioBalance
    /** Upscale a finished render (coming soon: the server answers upscale_unavailable). */
    suspend fun upscale(takeId: String, size: String): Job

    // Studio settings (owner) and the image engine
    suspend fun studioSettings(): StudioSettings
    suspend fun patchStudioSettings(req: StudioSettingsPatch): StudioSettings
    suspend fun imageEngine(): ImageEngine
    suspend fun setImageEngine(req: ImageEnginePatch): ImageEngine

    // Keep add-on engine ready (plans/api.md "App clean-up" §6): owner only, billed per minute.
    suspend fun warmGpu(): WarmGpu
    /** {on: true|false} or {extend: true} ("Keep warm"). */
    suspend fun setWarmGpu(req: WarmRequest): WarmGpu

    // Model tools (plans/api.md "Model tools"). Image models are owner only; Enhance and Dress up are for everyone.
    suspend fun imageModels(): StepModels
    suspend fun imageCatalog(step: String, q: String? = null, collection: String? = null): CatalogPage
    suspend fun imageModel(id: String, step: String): ModelDetail
    suspend fun setImageModel(step: String, req: SetStepModelRequest): StepModel
    suspend fun resetImageModel(step: String): StepModel
    suspend fun enhanceEstimate(modelId: String, req: EnhanceRequest): ToolEstimate
    suspend fun startEnhance(modelId: String, req: EnhanceRequest): ToolRun
    suspend fun dressUpEstimate(modelId: String, req: DressUpRequest): ToolEstimate
    suspend fun startDressUp(modelId: String, req: DressUpRequest): ToolRun
    suspend fun toolRuns(modelId: String? = null): List<ToolRun>
    suspend fun toolRun(id: String): ToolRun
    suspend fun decideTool(id: String, slot: String, req: DecideRequest): ToolRun
    suspend fun pickTool(id: String, pick: String): ToolRun
    suspend fun retryTool(id: String, slot: String, engine: String? = null): ToolRun
    suspend fun applyTool(id: String, name: String? = null): ApplyResponse
    suspend fun discardTool(id: String)
    suspend fun sheetVersions(modelId: String): List<SheetVersion>
    suspend fun restoreSheet(modelId: String, versionId: String): Model
    /** Owner: archive (true) or restore (false). Archived models drop out of every list. */
    suspend fun archiveModel(modelId: String, archived: Boolean): Model
    /** Owner: the archived models only. */
    suspend fun archivedModels(): List<Model>

    // Prompt library (owner only): every prompt the server sends to a model.
    suspend fun prompts(): PromptLibrary
    suspend fun savePrompt(key: String, text: String): PromptEntry
    suspend fun resetPrompt(key: String): PromptEntry
    suspend fun previewPrompt(req: PromptPreviewRequest): PromptPreview

    // Prompt scripts (workstream 4), owner only: inputs → rules → blocks (plans/api.md "Prompt scripts").
    suspend fun listPromptScripts(): PromptScriptsList
    suspend fun getPromptScript(id: String): ScriptView
    /** The whole rule list, in order. script_invalid (400) carries the message to show as-is. */
    suspend fun savePromptScript(id: String, rules: List<Rule>): ScriptView
    suspend fun resetPromptScript(id: String): ScriptView
    suspend fun previewPromptScript(
        id: String, inputs: kotlinx.serialization.json.JsonObject? = null, rules: List<Rule>? = null, texts: Map<String, String>? = null, direction: String? = null,
    ): ScriptPreview

    // Workstream 2: camera sessions (plans/api.md "MCP & camera sessions"), owner only. See CameraApi.kt.
    val camera: CameraApi get() = CameraApi.Unsupported
    /** Claude on the owner's plan: chat threads relayed to the Mac's Claude Code (plans/api.md "Claude on the owner's plan"). See ClaudeApi.kt. */
    val claude: ClaudeApi get() = ClaudeApi.Unsupported

    // Edit suite (workstream 3): AI helpers and v2 versions (plans/api.md "Editor v2"). Defaults: not available.
    /** What a helper would cost (free ones say so). */
    suspend fun editorEstimate(req: EditorJobRequest): EditorEstimate = throw ApiException("unsupported", "AI helpers need the studio server")
    /** Starts a helper job (running); poll [editorJob] until it finishes. */
    suspend fun startEditorJob(req: EditorJobRequest): EditorJob = throw ApiException("unsupported", "AI helpers need the studio server")
    suspend fun editorJob(id: String): EditorJob = throw ApiException("not_found", "Job not found")
    suspend fun cancelEditorJob(id: String) {}
    /** Saves a video made by the Edit suite as a new version of [takeId] with its v2 project. */
    suspend fun saveProjectVersion(takeId: String, video: EditedVideo, project: kotlinx.serialization.json.JsonObject, name: String? = null /* 1–80 chars (edit sessions, workstream 3) */, onProgress: (Float) -> Unit = {}): Take =
        throw ApiException("unsupported", "Saving an edited video needs the studio server")
    /** Uploads a voice-over / music file (or with purpose "lut" a .cube) for the editor; returns the upload id. */
    suspend fun uploadEditorFile(file: java.io.File, contentType: String, purpose: String? = null, onProgress: (Float) -> Unit = {}): String =
        throw ApiException("unsupported", "Uploading files needs the studio server")

    // Edit sessions (workstream 3, plans/api.md "Edit sessions"), owner only. Defaults: not available (local editing only).
    /** The take's open session, or a new one (from [OpenEditSessionRequest.project] when sent, else the take's saved edit). */
    suspend fun openEditSession(req: OpenEditSessionRequest): EditSessionDto = throw ApiException("unsupported", "Editing with Claude needs the studio server")
    suspend fun editSession(id: String): EditSessionDto = throw ApiException("not_found", "Edit session not found")
    /** A local change as a JSON Patch against [EditPatchRequest.baseRevision]; `stale_revision` when the session moved on. */
    suspend fun pushEditPatch(id: String, req: EditPatchRequest): EditChangeResult = throw ApiException("unsupported", "Editing with Claude needs the studio server")
    /** Undoes one history entry (anyone's) as a new change. */
    suspend fun undoEditEntry(id: String, req: EditUndoRequest): EditChangeResult = throw ApiException("unsupported", "Editing with Claude needs the studio server")
    suspend fun editPresence(id: String, presence: EditPresence) {}
    suspend fun leaveEditSession(id: String, device: String) {}
    /** A PNG of a frame Claude asked for, uploaded with the image presign (`POST /v1/uploads/presign {kind:"image"}` + PUT): the upload id. */
    suspend fun uploadEditFrame(png: ByteArray): String = throw ApiException("unsupported", "Uploading frames needs the studio server")
    suspend fun answerEditFrame(id: String, requestId: String, uploadId: String) {}
    suspend fun answerEditRequest(id: String, requestId: String, answer: EditRequestAnswer) {}
    suspend fun answerEditPending(id: String, pendingId: String, approve: Boolean): EditPending = throw ApiException("not_found", "Waiting request not found")

    // AI suite (workstream 1, plans/api.md "AI suite"). Members never get engine names back; the owner does.
    suspend fun suiteCatalog(): SuiteCatalog = throw ApiException("not_found", "This server doesn't have the AI suite yet")
    suspend fun suiteEstimate(req: SuiteShotRequest): SuiteEstimate = throw ApiException("not_found", "This server doesn't have the AI suite yet")
    /** The rig check alone, for when the estimate fails (free, pure). An API without it: no warnings. */
    suspend fun suiteRigCheck(req: SuiteShotRequest): SuiteRigCheck = SuiteRigCheck()
    /** A render job (`request.engine == "suite"`) on the usual job pipeline: job, take and balance events follow. */
    suspend fun createSuiteShot(req: SuiteShotRequest): Job = throw ApiException("not_found", "This server doesn't have the AI suite yet")
    suspend fun suiteShot(id: String): SuiteShot = throw ApiException("not_found", "This server doesn't have the AI suite yet")
    suspend fun suiteCompile(req: SuiteCompileRequest): SuiteCompiled = throw ApiException("not_found", "This server doesn't have the AI suite yet")
    /** Owner only. */
    suspend fun suiteSettings(): SuiteSettings = throw ApiException("not_found", "This server doesn't have the AI suite yet")
    suspend fun patchSuiteSettings(req: SuiteSettingsPatch): SuiteSettings = throw ApiException("not_found", "This server doesn't have the AI suite yet")
    /** A reference video or audio track for a shot's input slots: uploaded to this studio, handed back as its storage key. */
    suspend fun uploadSuiteMedia(name: String, bytes: ByteArray, mime: String, onProgress: (Float) -> Unit = {}): SuiteMediaRef =
        throw ApiException("unsupported", "Uploading files needs the studio server")

    // Recreate this edit (workstream 1, plans/api.md "Recreate this edit"). Defaults: a server without it.
    /** A studio video upload (≤ 60 s, from [uploadEditorFile]) becomes a reference; its analysis runs on the server. */
    suspend fun createReference(uploadId: String, name: String?): studio.muse.core.edit.RecipeReference =
        throw ApiException("not_found", "This studio server can't read edits yet")
    /** The reference's state and step while it is analysed, and its recipe once ready. */
    suspend fun reference(id: String): studio.muse.core.edit.RecipeReference = throw ApiException("not_found", "Reference not found")

    /** The studio's locations (`@location` in the composer's prompt). */
    suspend fun suiteLocations(): List<SuiteLocation> = throw ApiException("not_found", "This server doesn't have locations yet")
    suspend fun createSuiteLocation(req: SuiteLocationCreate): SuiteLocation = throw ApiException("not_found", "This server doesn't have locations yet")
    suspend fun deleteSuiteLocation(id: String): Unit = throw ApiException("not_found", "This server doesn't have locations yet")

    // AI suite build step 2 (plans/api.md "The new Suite's server pieces"): saved rigs, a model's default rig, the takes feed.
    /** A member's own rigs; the owner gets every rig in the studio, theirs first ([SuiteRigView.mine]). Ordered by last change. */
    suspend fun suiteRigs(): List<SuiteRigView> = throw ApiException("not_found", "This server doesn't have saved rigs yet")
    /** Name 1–60 characters (trimmed); at most 100 rigs per person (`too_many_rigs`). Unknown ids → `bad_request`. */
    suspend fun createSuiteRig(name: String, rig: SuiteRig): SuiteRigView = throw ApiException("not_found", "This server doesn't have saved rigs yet")
    /** Your own rig, or any for the owner (anyone else's reads as `not_found`). Null leaves it; [rig] replaces the whole rig. */
    suspend fun updateSuiteRig(id: String, name: String? = null, rig: SuiteRig? = null): SuiteRigView = throw ApiException("not_found", "This server doesn't have saved rigs yet")
    suspend fun deleteSuiteRig(id: String): Unit = throw ApiException("not_found", "This server doesn't have saved rigs yet")
    /** The model's default rig (`PATCH /v1/models/{id} {defaultRig}`); null (or an all-Auto rig) clears it. Anyone in the studio may set it. */
    suspend fun setModelDefaultRig(modelId: String, rig: SuiteRig?): Model = throw ApiException("not_found", "This server doesn't have default rigs yet")
    /** The takes rail: newest first, queued/running/failed jobs as one card each, every done take and photo as its own. */
    suspend fun suiteFeed(q: SuiteFeedQuery = SuiteFeedQuery()): SuiteFeedPage = throw ApiException("not_found", "This server doesn't have the takes feed yet")

    // AI suite · Photo tool (workstream 3, plans/api.md "Photo tool"): Photoshoot on the composer. Free estimate; create holds and makes the stills.
    suspend fun photoEstimate(req: PhotoRequest): PhotoEstimate = throw ApiException("not_found", "This server doesn't have the Photo tool yet")
    suspend fun createPhotos(req: PhotoRequest): PhotoResult = throw ApiException("not_found", "This server doesn't have the Photo tool yet")

    // Developer
    suspend fun setFailNext(fail: Boolean)

    /** Live job progress, balance and generation updates. */
    fun events(): Flow<ApiEvent>
}

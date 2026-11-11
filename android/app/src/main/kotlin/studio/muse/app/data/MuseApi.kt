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
    suspend fun fillAngles(modelId: String, imageModel: String? = null): FillAnglesResponse
    suspend fun updateModel(modelId: String, req: UpdateModelRequest): Model
    /** Deletes the model with her outfits, LoRAs, training set, accounts and unsent posts. */
    suspend fun deleteModel(modelId: String)

    // Outfit sets
    suspend fun listOutfits(): List<Outfit>
    /** Starts generating an outfit set preview (state=generating; an outfit event follows). */
    suspend fun createOutfit(req: CreateOutfitRequest): Outfit
    /** Attaches a generated preview to the model. */
    suspend fun saveOutfit(outfitId: String, name: String? = null): Outfit
    /** Renames an outfit (1–80 characters; the owner or whoever made it). */
    suspend fun renameOutfit(outfitId: String, name: String): Outfit
    /** Deletes an outfit (refused while it is being made); takes made with it are kept. */
    suspend fun deleteOutfit(outfitId: String)
    /** Makes an outfit's missing ¾/side/back from its front; an outfit event with the filled angles follows. */
    suspend fun fillOutfit(outfitId: String, imageModel: String? = null): OutfitFill

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
    suspend fun upscale(takeId: String, size: String, engineModel: String? = null): Job

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
    // WS7: bring your own provider (WS5's contract v1), owner only. See ProvidersApi.kt.
    val providers: ProvidersApi get() = ProvidersApi.Unsupported
    // WS7: import a video from a link (WS12's contract). See ImportsApi.kt.
    val imports: ImportsApi get() = ImportsApi.Unsupported
    // WS7: the owner's model picker on every surface (WS13's contract). See ModelsApi.kt.
    val modelChoice: ModelsApi get() = ModelsApi.Unsupported
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
    suspend fun saveProjectVersion(takeId: String, video: EditedVideo, project: kotlinx.serialization.json.JsonObject, name: String? = null /* 1–80 chars (edit sessions, workstream 3) */, onProgress: (Float) -> Unit = {}, aiLabel: Boolean = false): Take =
        throw ApiException("unsupported", "Saving an edited video needs the studio server")
    /** Uploads a voice-over / music file (or with purpose "lut" a .cube) for the editor; returns the upload id. */
    suspend fun uploadEditorFile(file: java.io.File, contentType: String, purpose: String? = null, onProgress: (Float) -> Unit = {}): String =
        throw ApiException("unsupported", "Uploading files needs the studio server")
    /** The edit content library catalog (GET /v1/editor/content) as JSON text; null when the server has none. */
    suspend fun editorContentCatalog(): String? = null
    /** Where a content library file (a catalog `file` path) is downloaded from; null without a server. */
    fun editorContentUrl(path: String): String? = null
    /** Where an editor upload of the studio can be fetched (an own font, on reopening an edit); null when unknown. */
    suspend fun editorUploadUrl(uploadId: String): String? = null
    /** WS7 (import from link): a phone-fetched video as a clip upload (POST /v1/uploads/presign {kind: "clip"} → PUT, no confirm); returns the upload id. */
    suspend fun uploadClipFile(file: java.io.File, onProgress: (Float) -> Unit = {}): String =
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

    // The learning editor (workstream 3, plans/api.md "Learning editor", owner only). Defaults: a server without it.
    suspend fun playbook(): List<LearnRule> = throw ApiException("not_found", "This studio server doesn't have the playbook yet")
    // Edit style kits (/v1/editor/kits): members their own, the owner the studio's.
    suspend fun editKits(): List<EditKit> = throw ApiException("not_found", "This studio server can't keep style kits yet")
    suspend fun saveEditKit(name: String, kit: kotlinx.serialization.json.JsonObject): EditKit = throw ApiException("not_found", "This studio server can't keep style kits yet")
    suspend fun deleteEditKit(id: String) { throw ApiException("not_found", "This studio server can't keep style kits yet") }
    suspend fun addRule(req: LearnRuleRequest): LearnRule = throw ApiException("not_found", "This studio server doesn't have the playbook yet")
    suspend fun patchRule(id: String, req: LearnRuleRequest): LearnRule = throw ApiException("not_found", "This studio server doesn't have the playbook yet")
    suspend fun deleteRule(id: String) { throw ApiException("not_found", "This studio server doesn't have the playbook yet") }
    suspend fun lessons(): List<LearnLesson> = throw ApiException("not_found", "This studio server doesn't have the playbook yet")
    suspend fun corrections(limit: Int = 50): List<LearnCorrection> = throw ApiException("not_found", "This studio server doesn't have the playbook yet")
    suspend fun recipes(q: String? = null, tags: List<String> = emptyList(), origin: String? = null): List<LearnRecipeEntry> = throw ApiException("not_found", "This studio server doesn't have the playbook yet")
    suspend fun recipe(id: String): LearnRecipeEntry = throw ApiException("not_found", "This studio server doesn't have the playbook yet")
    suspend fun patchRecipe(id: String, req: LearnRecipePatch): LearnRecipeEntry = throw ApiException("not_found", "This studio server doesn't have the playbook yet")
    suspend fun deleteRecipe(id: String) { throw ApiException("not_found", "This studio server doesn't have the playbook yet") }
    suspend fun nearestRecipes(id: String, k: Int = 3): LearnNearest = throw ApiException("not_found", "This studio server doesn't have the playbook yet")
    suspend fun learnGaps(limit: Int = 10): List<LearnGap> = throw ApiException("not_found", "This studio server doesn't have the playbook yet")
    /** A reference's poster PNG (an authenticated route, so not an image URL); null when it has expired. */
    suspend fun referencePoster(referenceId: String): ByteArray? = null
    /** A shot's keyframe from the reference (PNG; the Recipe's tiles). Null when there is none. */
    suspend fun referenceSlotThumb(referenceId: String, slotId: String): ByteArray? = null
    /**
     * What the editor's AI helpers can do now (`GET /v1/editor/features`). `matte.available` is false while the cut-out
     * runs on the mock: Remove background and Tap to keep then read "Coming soon". A server without it: all available.
     */
    suspend fun editorFeatures(): kotlinx.serialization.json.JsonObject? = null
    /** Owner: the paid AI editing helpers' switch and daily limit (WS1 guardrails; members get 403). */
    suspend fun editorSettings(): EditorSettings = throw ApiException("not_found", "This studio server doesn't have AI editing settings yet")
    /** [paidHelpers]: "on" | "off" (null = unchanged). [cap]: the daily limit in dollars; [resetCap] puts back the default ($5). */
    suspend fun patchEditorSettings(paidHelpers: String? = null, cap: Double? = null, resetCap: Boolean = false): EditorSettings =
        throw ApiException("not_found", "This studio server doesn't have AI editing settings yet")
    /**
     * The reference video (an authenticated route: a redirect to storage, or the bytes), saved into [into] for the
     * player, which then needs no token. False when there is none (demo mode, expired).
     */
    suspend fun referenceVideo(referenceId: String, into: java.io.File): Boolean = false

    // Recreate this edit (workstream 1, plans/api.md "Recreate this edit"). Defaults: a server without it.
    /** A studio video upload (≤ 60 s, from [uploadEditorFile]) becomes a reference; its analysis runs on the server. */
    /** [sourceUrl]: the link the phone downloaded it from (a link reference, fetched on the device). */
    suspend fun createReference(uploadId: String, name: String?, sourceUrl: String? = null): studio.muse.core.edit.RecipeReference =
        throw ApiException("not_found", "This studio server can't read edits yet")
    /**
     * A shared link (TikTok, Instagram Reel, YouTube) becomes a reference: the server fetches it within the platforms'
     * rules. A link it can't use answers in words (link_unsupported, link_private, link_downloads_off, link_too_big,
     * link_blocked, too_long): show the message and offer the saved file instead.
     */
    suspend fun createReferenceFromLink(url: String, name: String?): studio.muse.core.edit.RecipeReference =
        throw ApiException("not_found", "This studio server can't read links yet · save the video and share the file")
    /** The reference's state and step while it is analysed, and its recipe once ready. */
    suspend fun reference(id: String): studio.muse.core.edit.RecipeReference = throw ApiException("not_found", "Reference not found")
    /** A failed reference analysed again (WS1 c47f9ef; a lighter analysis after `analysis_crashed`). 409 not_failed · 409 video_gone. */
    suspend fun retryReference(id: String): studio.muse.core.edit.RecipeReference = throw ApiException("not_found", "This studio server can't retry an analysis yet")
    /** The studio's references, newest first (Recreate's start page). */
    suspend fun listReferences(): List<studio.muse.core.edit.RecipeReference> = emptyList()
    // Recreate phases 2–3 (plans/api.md "Recreate this edit · slots and assembly"): match (free), price (nothing held),
    // fill (a paid Suite shot, only after the person confirmed its price), apply into an edit session.
    /** Scores the studio's takes against each shot (free); the fill then says which shots are yours and which to make. */
    suspend fun matchReference(id: String, modelId: String?): Unit = throw ApiException("not_found", "This studio server can't build recipes yet")
    suspend fun referenceFill(id: String): studio.muse.core.edit.RecreateFill = throw ApiException("not_found", "This studio server can't build recipes yet")
    /** A shot's price as a new shot. Nothing is held. */
    /** [method]: "swap" | "generate" (null: the server's default, swap when it can run); [keepBackground]: swap only. */
    /** [locationId]: "Use your own setting" with one of the studio's locations (free); without it the brief's place picks one, or a plate is made (priced in). */
    suspend fun estimateReferenceSlot(id: String, slotId: String, modelId: String, quality: String? = null, method: String? = null, keepBackground: Boolean? = null, locationId: String? = null, engineModel: String? = null, imageModel: String? = null): studio.muse.core.edit.RecreateSlotEstimate =
        throw ApiException("not_found", "This studio server can't build recipes yet")
    /** Makes a shot: an ordinary Suite job, held and charged. Only after the person confirmed the total. */
    suspend fun fillReferenceSlot(id: String, slotId: String, modelId: String, quality: String? = null, method: String? = null, keepBackground: Boolean? = null, locationId: String? = null, engineModel: String? = null, imageModel: String? = null): studio.muse.core.edit.RecreateFillStart =
        throw ApiException("not_found", "This studio server can't build recipes yet")
    /** Builds the edit in an edit session: [slots] is slotId → takeId or jobId. */
    suspend fun applyRecipe(id: String, sessionId: String, baseRevision: Int?, slots: Map<String, String>): studio.muse.core.edit.RecreateApplyResult =
        throw ApiException("not_found", "This studio server can't build recipes yet")
    /** G8: the price of having Claude (on the server) write every shot's brief. Nothing is held. */
    suspend fun estimateReferenceBriefs(id: String): studio.muse.core.edit.RecreateBriefsEstimate =
        throw ApiException("not_found", "This studio server can't write shot briefs yet")
    /** G8: writes them (charged; the caller confirmed the price) and returns the updated reference. */
    suspend fun writeReferenceBriefs(id: String): studio.muse.core.edit.RecipeReference =
        throw ApiException("not_found", "This studio server can't write shot briefs yet")
    /**
     * Fix shot (WS1 a7302fb): swaps one shot's clip in the built edit for [take] (a take id, or a finished fill's job id),
     * keeping its timing, transition, ramp, camera moves and look, and the owner's other edits. 409 slot_not_in_edit:
     * rebuild the edit instead.
     */
    suspend fun replaceRecipeSlot(id: String, slotId: String, sessionId: String, take: String, baseRevision: Int?): studio.muse.core.edit.RecreateReplaceResult =
        throw ApiException("not_found", "This studio server can't fix one shot yet")

    // The server's renders (plans/api.md "The built edit, rendered" and Recreate "Export"): the apps use these first so
    // pixels match across apps, and fall back to the device's own engine when the server can't render.
    /** Compare's preview of an edit session: [start] renders the current revision (POST); otherwise reads its state. */
    suspend fun editPreview(sessionId: String, start: Boolean, revision: Int? = null): studio.muse.core.edit.RecreateRender =
        throw ApiException("not_found", "This studio server can't render previews yet")
    /** The preview's file into [into]; false when there is none. */
    suspend fun editPreviewFile(sessionId: String, revision: Int?, into: java.io.File): Boolean = false
    /** Recreate's export of the built edit, [sound] "guide" | "silent". 409 no_reference_sound: export silent instead. */
    suspend fun recreateExport(id: String, sessionId: String, sound: String, start: Boolean, revision: Int? = null): studio.muse.core.edit.RecreateRender =
        throw ApiException("not_found", "This studio server can't export recreates yet")
    suspend fun recreateExportFile(id: String, sessionId: String, sound: String, revision: Int?, into: java.io.File): Boolean = false

    // Recreate links fetched on the phone (plans/api.md "Fetching on the device, and Strict link rules").
    /** The link rules the phone applies too; null on a server without them (the defaults then apply). */
    suspend fun recreateSettings(): RecreateLinkSettings? = null
    /** Owner: "Strict link rules". */
    suspend fun patchRecreateSettings(strictLinks: Boolean): RecreateLinkSettings = throw ApiException("not_found", "This studio server doesn't have link rules yet")
    /** Before the phone downloads: allowed (the normalized link), refused (code, reason) or already a reference (cached). */
    suspend fun checkRecreateLink(url: String): RecreateLinkCheck = RecreateLinkCheck(true, url)

    // Claude in the AI Suite (WS1 1eda187): the shared composer draft. Defaults: a server without it.
    /** A shared draft: the composer's current [draft], or a job's ([fromJobId]). */
    suspend fun createSuiteAssist(draft: SuiteDraft?, fromJobId: String? = null): SuiteAssist = throw ApiException("not_found", "This studio server doesn't have Claude in the Suite yet")
    suspend fun suiteAssist(id: String): SuiteAssist = throw ApiException("not_found", "Assist not found")
    /** The owner's own composer edits, so Claude sees them. `stale` (409): Claude changed it since; re-read it. */
    suspend fun patchSuiteAssist(id: String, draft: SuiteDraft, baseRevision: Int?): SuiteAssist = throw ApiException("not_found", "Assist not found")
    /** The owner's answer to Claude's Generate. `price_changed` (409): the price rose above the approved one; nothing ran. */
    suspend fun answerSuitePending(id: String, pendingId: String, approve: Boolean): SuitePending = throw ApiException("not_found", "Assist not found")
    /** An image for a Claude message (presign → PUT → confirm); returns its upload id. ≤ 10 MB, JPEG, PNG, WebP or HEIC. */
    suspend fun uploadClaudeImage(name: String, bytes: ByteArray, mime: String, onProgress: (Float) -> Unit = {}): String =
        throw ApiException("not_found", "This studio server can't take images for Claude yet")

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

    // Build step 3 (plans/api.md "Library collections and the Suite queue"). Defaults: a server without them.
    /** Queue a shot to run later: checked and priced, nothing held. [req] is the body of POST /v1/suite/shots. */
    suspend fun queueSuiteShot(req: SuiteShotRequest): QueuedShot = throw ApiException("not_found", "This server can't queue shots yet")
    suspend fun suiteQueue(): List<QueuedShot> = emptyList()
    /** Today's price for a queued shot (shown, then confirmed). */
    suspend fun estimateQueuedShot(id: String): QueuedEstimate = throw ApiException("not_found", "This server can't queue shots yet")
    /** Runs it, as POST /v1/suite/shots would (held and charged); the caller confirmed the price. */
    suspend fun runQueuedShot(id: String): QueuedRun = throw ApiException("not_found", "This server can't queue shots yet")
    suspend fun deleteQueuedShot(id: String): Unit = throw ApiException("not_found", "This server can't queue shots yet")
    suspend fun libraryCollections(): List<LibraryCollection> = emptyList()
    suspend fun createLibraryCollection(name: String, takeIds: List<String> = emptyList()): LibraryCollection = throw ApiException("not_found", "This server doesn't have collections yet")
    suspend fun renameLibraryCollection(id: String, name: String): LibraryCollection = throw ApiException("not_found", "This server doesn't have collections yet")
    suspend fun deleteLibraryCollection(id: String): Unit = throw ApiException("not_found", "This server doesn't have collections yet")
    suspend fun addToLibraryCollection(id: String, takeIds: List<String>): LibraryCollection = throw ApiException("not_found", "This server doesn't have collections yet")
    suspend fun removeFromLibraryCollection(id: String, takeIds: List<String>): LibraryCollection = throw ApiException("not_found", "This server doesn't have collections yet")
    /** The collections a take or photo is in (its detail). */
    suspend fun takeCollections(takeId: String): List<LibraryCollection> = emptyList()

    // AI suite · Photo tool (workstream 3, plans/api.md "Photo tool"): Photoshoot on the composer. Free estimate; create holds and makes the stills.
    suspend fun photoEstimate(req: PhotoRequest): PhotoEstimate = throw ApiException("not_found", "This server doesn't have the Photo tool yet")
    suspend fun createPhotos(req: PhotoRequest): PhotoResult = throw ApiException("not_found", "This server doesn't have the Photo tool yet")

    // Developer
    suspend fun setFailNext(fail: Boolean)

    /** Live job progress, balance and generation updates. */
    fun events(): Flow<ApiEvent>
}

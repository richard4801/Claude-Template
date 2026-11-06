import Foundation

/// The backend contract (plans/api.md). Two implementations:
///  - `FakeMuseAPI`: in-process, no server. The app's default data source.
///  - `HTTPMuseAPI`: REST + Server-Sent Events against the real API (`server/api`, the default) or server/mock.
/// Settings → Developer switches between them.
public protocol MuseAPI: AnyObject, Sendable {
    // Auth. The real API is invite-only (sign-up needs `inviteCode`); sign-up always requires both attestations.
    func signIn(_ req: SignInRequest) async throws -> AuthResponse
    func signUp(_ req: SignUpRequest) async throws -> AuthResponse
    func setToken(_ token: String?) async
    /// POST /v1/auth/signout: revokes this session on the server.
    func signOut() async throws
    /// GET /v1/auth/me: who the stored token belongs to (restores the session on launch).
    func me() async throws -> User

    // Tokens, members and studio settings (real API; owner-only calls answer owner_only for members)
    func wallet() async throws -> Wallet
    func createInvite(_ req: InviteRequest) async throws -> Invite
    func listMembers() async throws -> [Member]
    func updateMember(id: String, _ patch: MemberPatch) async throws -> Member
    /// POST /v1/wallets/transfer: the owner sends tokens to a member.
    func sendTokens(_ move: TokenMove) async throws -> TokenMoveResult
    /// POST /v1/wallets/reclaim: the owner takes unused tokens back.
    func takeBackTokens(_ move: TokenMove) async throws -> TokenMoveResult
    func imageEngine() async throws -> ImageEngine
    func setImageEngine(_ req: ImageEngineRequest) async throws -> ImageEngine
    func studioSettings() async throws -> StudioSettings
    func updateStudioSettings(_ patch: StudioSettingsPatch) async throws -> StudioSettings

    // Models and character sheets
    func listModels() async throws -> [MuseModel]
    func createModel(_ req: CreateModelRequest) async throws -> MuseModel
    func setSlot(modelId: String, slot: String, _ req: SetSlotRequest) async throws -> MuseModel
    /// Generates the missing angles from the user's images ($0.02 each). Slots come back busy; a model event follows.
    func fillAngles(modelId: String) async throws -> FillAnglesResponse
    /// PATCH /v1/models/{id}: name, niche, personality, notes, never-add list.
    func updateModel(id: String, _ req: UpdateModelRequest) async throws -> MuseModel
    /// DELETE /v1/models/{id}: also deletes its outfits, LoRAs, training set and accounts.
    func deleteModel(id: String) async throws

    // Identity LoRA (plans/lora-training.md)
    func lora(modelId: String) async throws -> Lora
    /// Generates the 30-shot training set ($0.60). Comes back `building`; a lora event follows with `review`.
    func buildLoraCandidates(modelId: String) async throws -> Lora
    func setLoraCandidate(modelId: String, candidateId: String, keep: Bool) async throws -> Lora
    /// Trains the photo and video LoRAs on the kept shots. Needs 20+ kept; charges the training price. Progress arrives as lora events.
    func trainLora(modelId: String) async throws -> Lora
    func setLoraUse(modelId: String, use: Bool) async throws -> Lora
    /// Retrain (PATCH …/lora {state: "review"}): a ready LoRA goes back to the review grid with the same shots.
    /// The current version stays in use until the next one is ready; training again makes v{n+1}.
    func retrainLora(modelId: String) async throws -> Lora

    // Social accounts and posts (plans/socials.md)
    func listAccounts(modelId: String) async throws -> [Account]
    func connectAccount(modelId: String, platform: Platform) async throws -> ConnectResult
    func disconnectAccount(modelId: String, platform: Platform) async throws
    /// state: nil for all, or scheduled | handoff | posted | failed.
    func listPosts(state: String?) async throws -> [Post]
    func createPost(_ req: CreatePostRequest) async throws -> Post
    /// Cancels a scheduled post.
    func deletePost(id: String) async throws

    // Outfit sets
    func listOutfits() async throws -> [Outfit]
    /// Starts generating an outfit set preview (state=generating; an outfit event follows with state=preview).
    func createOutfit(_ req: CreateOutfitRequest) async throws -> Outfit
    /// Attaches a generated preview to the model.
    func saveOutfit(outfitId: String) async throws -> Outfit

    // Uploads (HTTP: presign → PUT → confirm, falling back to a multipart upload). `progress` reports 0…1.
    func uploadImage(name: String, data: Data, mime: String, progress: UploadProgress?) async throws -> ImageRef
    /// Registers a source clip and runs the clip checks. `file` is nil for the sample clips.
    func uploadClip(_ meta: ClipMeta, file: URL?, progress: UploadProgress?) async throws -> Clip

    // Jobs and takes
    func listJobs() async throws -> [Job]
    func createJob(_ req: JobRequest) async throws -> Job
    func removeJob(id: String) async throws
    /// POST /v1/queue/run: starts the GPU on queued jobs ("Run queue"). Servers that start jobs on their own treat it as a no-op.
    func runQueue() async throws
    func listTakes() async throws -> [Take]
    func setTakeStatus(id: String, status: String) async throws -> Take
    func deleteTake(id: String) async throws
    func shoot(_ req: ShootRequest) async throws -> [Take]
    /// POST /v1/shoots/preview (same body, free): the final prompt the server will send, the images and the price.
    func shootPreview(_ req: ShootRequest) async throws -> ShootPreview

    // Prompt library (owner only; members get owner_only). plans/api.md "Shoot references and the prompt library" §3.
    /// GET /v1/prompts
    func prompts() async throws -> PromptLibrary
    /// PUT /v1/prompts/{key} {text}: `prompt_invalid` (message shown as-is). Saving the default text clears the override.
    func setPrompt(key: String, text: String) async throws -> PromptEntry
    /// DELETE /v1/prompts/{key}: back to the default.
    func resetPrompt(key: String) async throws -> PromptEntry
    /// POST /v1/prompts/preview {key, text?}
    func previewPrompt(_ req: PromptPreviewRequest) async throws -> PromptPreview

    // Prompt scripts (workstream 4; owner only, members get owner_only). plans/api.md "Prompt scripts".
    /// GET /v1/prompt-scripts
    func promptScripts() async throws -> PromptScriptsList
    /// GET /v1/prompt-scripts/{id}
    func promptScript(id: String) async throws -> ScriptView
    /// PUT /v1/prompt-scripts/{id} {rules}: the whole list, in order. `script_invalid` (message shown as-is). Saving the defaults clears the override.
    func savePromptScript(id: String, rules: [ScriptRule]) async throws -> ScriptView
    /// DELETE /v1/prompt-scripts/{id}: back to the default rules.
    func resetPromptScript(id: String) async throws -> ScriptView
    /// POST /v1/prompt-scripts/preview {id, inputs?, rules?, texts?, direction?}
    func previewPromptScript(_ req: ScriptPreviewRequest) async throws -> ScriptPreview

    // Photo templates (plans/templates.md). Layers and variation pools only ever reach the template's owner.
    /// GET /v1/templates?scope=&q=&tag=
    func listTemplates(_ query: TemplateQuery) async throws -> [MuseTemplate]
    /// GET /v1/templates/{id}: with `recent`. Someone else's private template is not_found.
    func template(id: String) async throws -> MuseTemplate
    /// POST /v1/templates (from scratch, or `fromShotId` to copy a shot's exact layers and still).
    func createTemplate(_ req: CreateTemplateRequest) async throws -> MuseTemplate
    /// POST /v1/templates/draft: what "Save as template" would save, to show and edit first. `template_hidden` for a shot made
    /// with someone else's template.
    func templateDraft(fromShotId: String) async throws -> TemplateDraft
    /// PATCH /v1/templates/{id} (owner only).
    func updateTemplate(id: String, _ patch: TemplatePatch) async throws -> MuseTemplate
    /// DELETE /v1/templates/{id} (owner only).
    func deleteTemplate(id: String) async throws
    /// POST /v1/templates/{id}/duplicate: a private copy (owner only).
    func duplicateTemplate(id: String) async throws -> MuseTemplate
    /// POST / DELETE /v1/templates/{id}/favourite.
    func setTemplateFavourite(id: String, _ on: Bool) async throws -> MuseTemplate
    /// POST /v1/templates/{id}/prompt: the prompt view. Non-owners get the locked "Template: <name>" line.
    func templatePrompt(id: String, _ req: TemplatePromptRequest) async throws -> TemplatePrompt

    // Video editor (plans/video-editor.md). The edit is made on the device; the server stores the file and the edit list.
    /// presign `clip` + PUT (no confirm) for the edited .mp4, presign `image` + PUT for its thumbnail. `progress` 0…1.
    func uploadEditedVideo(_ video: EditedVideo, progress: UploadProgress?) async throws -> EditedUpload
    /// POST /v1/takes/{id}/versions → the new `kind: "edit"` take (`parentTakeId` = id). Free.
    func createTakeVersion(takeId: String, _ req: TakeVersionRequest) async throws -> Take
    /// GET /v1/takes/{id}/versions: edited versions of a take, newest first.
    func takeVersions(takeId: String) async throws -> [Take]

    /// POST /v1/takes/{id}/upscale {size}: an Upscale job on a finished take. `upscale_unavailable` while it's coming soon.
    func upscale(takeId: String, _ req: UpscaleRequest) async throws -> Job

    // Keep add-on engine ready (owner only; members get owner_only). Billed by wall time from the studio balance.
    /// GET /v1/gpu/warm
    func warmGpu() async throws -> WarmGpu
    /// POST /v1/gpu/warm {on, extend?}
    func setWarmGpu(_ req: WarmGpuRequest) async throws -> WarmGpu

    // Balance
    func balance() async throws -> Balance
    /// POST /v1/balance/topup: the owner records a top-up (server/mock: demo credit).
    func topUp(_ req: TopUpRequest) async throws -> Balance
    /// GET /v1/studio/balance (owner): the owner-loaded studio balance with recent top-ups.
    func studioBalance() async throws -> StudioBalance
    /// POST /v1/studio/topups (owner): records "Added $20".
    func recordTopUp(_ req: TopUpRecord) async throws -> StudioBalance

    // Model tools (plans/api.md "Model tools"). Image models and the catalog are owner only (members get owner_only).
    /// GET /v1/image-models
    func imageModels() async throws -> [StepModel]
    /// PUT /v1/image-models/{step} {model, extra?}: `model_incompatible` when the model can't do the step.
    func setImageModel(step: ImageStep, _ req: SetImageModelRequest) async throws -> StepModel
    /// DELETE /v1/image-models/{step}: back to the default.
    func resetImageModel(step: ImageStep) async throws -> StepModel
    /// GET /v1/image-models/catalog?step=&q=&collection=
    func imageModelCatalog(_ query: CatalogQuery) async throws -> CatalogResponse
    /// GET /v1/image-models/collections
    func imageModelCollections() async throws -> [CatalogCollectionRef]
    /// GET /v1/image-models/model?id=owner/name&step=
    func imageModelDetail(id: String, step: ImageStep) async throws -> ModelDetail

    /// POST /v1/models/{id}/enhance/estimate
    func enhanceEstimate(modelId: String, _ req: EnhanceRequest) async throws -> ToolEstimate
    /// POST /v1/models/{id}/enhance → a running ToolRun; `tool` events follow.
    func enhance(modelId: String, _ req: EnhanceRequest) async throws -> ToolRun
    /// POST /v1/models/{id}/dress-up/estimate
    func dressUpEstimate(modelId: String, _ req: DressUpEstimateRequest) async throws -> ToolEstimate
    /// POST /v1/models/{id}/dress-up → a running ToolRun. The original sheet is never changed.
    func dressUp(modelId: String, _ req: DressUpRequest) async throws -> ToolRun
    /// GET /v1/tool-runs?modelId=&kind= (newest first)
    func listToolRuns(_ query: ToolRunQuery) async throws -> [ToolRun]
    func toolRun(id: String) async throws -> ToolRun
    /// PATCH /v1/tool-runs/{id}/items/{slot} {decision, pick?}
    func decideToolItem(runId: String, slot: String, _ req: ToolDecisionRequest) async throws -> ToolRun
    /// POST /v1/tool-runs/{id}/pick {pick}: that option for the whole set.
    func pickToolRun(runId: String, pick: String) async throws -> ToolRun
    /// POST /v1/tool-runs/{id}/items/{slot}/retry {engine?}
    func retryToolItem(runId: String, slot: String, engine: String?) async throws -> ToolRun
    /// POST /v1/tool-runs/{id}/apply {name?}
    func applyToolRun(runId: String, _ req: ToolApplyRequest) async throws -> ToolApplyResponse
    /// DELETE /v1/tool-runs/{id}
    func discardToolRun(runId: String) async throws
    /// GET /v1/models/{id}/sheet-versions (newest first)
    func sheetVersions(modelId: String) async throws -> [SheetVersion]
    /// POST /v1/models/{id}/sheet-versions/{vid}/restore
    func restoreSheetVersion(modelId: String, versionId: String) async throws -> MuseModel

    /// POST /v1/models/{id}/archive (owner)
    func archiveModel(id: String) async throws -> MuseModel
    /// POST /v1/models/{id}/unarchive (owner)
    func unarchiveModel(id: String) async throws -> MuseModel
    /// GET /v1/models?archived=true (owner)
    func listArchivedModels() async throws -> [MuseModel]

    // Edit suite (workstream 3): Editor v2 AI helpers, uploads and v2 versions (plans/api.md "Editor v2"). Types in
    // Edit/EditorAPI.swift; the fake in Edit/FakeMuseAPI+EditSuite.swift.
    /// POST /v1/editor/estimate
    func editorEstimate(_ req: EditorJobRequest) async throws -> EditorEstimate
    /// POST /v1/editor/jobs
    func startEditorJob(_ req: EditorJobRequest) async throws -> EditorJob
    /// GET /v1/editor/jobs/{id}
    func editorJob(id: String) async throws -> EditorJob
    /// DELETE /v1/editor/jobs/{id}
    func cancelEditorJob(id: String) async throws
    /// POST /v1/editor/uploads/presign {contentType, bytes, purpose?} + PUT → the uploadId (music, voice-over, .cube).
    func uploadEditorFile(_ file: URL, contentType: String, purpose: String?, progress: UploadProgress?) async throws -> String
    /// POST /v1/editor/luts/validate {uploadId}
    func validateLut(uploadId: String) async throws -> LutValidation
    /// POST /v1/takes/{id}/versions with `edits: EditProject` (v2).
    func createTakeVersionV2(takeId: String, _ req: TakeVersionV2Request) async throws -> Take

    // AI suite (workstream 1): plans/api.md "AI suite". Implemented in Suite/SuiteHTTP.swift and Suite/FakeMuseAPI+Suite.swift.
    /// GET /v1/suite/catalog
    func suiteCatalog() async throws -> SuiteCatalog
    /// GET /v1/suite/camera
    func suiteCamera() async throws -> CameraCatalog
    /// POST /v1/suite/camera/compile (free)
    func suiteCompileCamera(_ req: CameraCompileRequest) async throws -> CameraCompiled
    /// POST /v1/suite/shots/estimate: holds nothing. `nothing_fits` / `engine_unavailable` as ApiError.
    func suiteEstimate(_ req: ShotRequest) async throws -> ShotEstimate
    /// POST /v1/suite/shots → a render job (`request.engine: "suite"`); progress arrives as `job` events.
    func suiteCreateShot(_ req: ShotRequest) async throws -> Job
    /// GET /v1/suite/shots/{id}
    func suiteShot(id: String) async throws -> SuiteShot
    /// GET /v1/suite/settings (owner)
    func suiteSettings() async throws -> SuiteSettings
    /// PATCH /v1/suite/settings (owner)
    func updateSuiteSettings(_ patch: SuiteSettingsPatch) async throws -> SuiteSettings
    /// Input slots: a reference video or audio track uploaded to this studio → its storage key.
    func uploadSuiteMedia(_ file: URL, contentType: String, progress: UploadProgress?) async throws -> SuiteVideoRef
    /// GET /v1/suite/locations: the studio's saved places (@location in a prompt).
    func suiteLocations() async throws -> [SuiteLocation]
    /// POST /v1/suite/locations {name, image}
    func createSuiteLocation(_ new: NewSuiteLocation) async throws -> SuiteLocation
    /// DELETE /v1/suite/locations/{id}
    func deleteSuiteLocation(id: String) async throws
    // End AI suite (workstream 1)

    // Developer

    func setFailNext(_ fail: Bool) async throws

    /// Live job progress, balance, generation, LoRA, post and add-on engine updates. Each call returns a new subscription.
    func events() -> AsyncStream<ApiEvent>
}

extension MuseAPI {
    public func uploadImage(name: String, data: Data, mime: String) async throws -> ImageRef {
        try await uploadImage(name: name, data: data, mime: mime, progress: nil)
    }

    public func uploadClip(_ meta: ClipMeta, file: URL?) async throws -> Clip {
        try await uploadClip(meta, file: file, progress: nil)
    }
}

/// Fan-out of events to any number of subscribers.
public final class EventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var subs: [UUID: AsyncStream<ApiEvent>.Continuation] = [:]

    public init() {}

    public func stream() -> AsyncStream<ApiEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(256)) { cont in
            let id = UUID()
            lock.lock()
            subs[id] = cont
            lock.unlock()
            cont.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.subs[id] = nil
                self.lock.unlock()
            }
        }
    }

    public func emit(_ e: ApiEvent) {
        lock.lock()
        let all = Array(subs.values)
        lock.unlock()
        for c in all { c.yield(e) }
    }
}

func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
func shortId() -> String { String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)) }

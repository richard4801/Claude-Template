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

    // Keep GPU warm (plans/backend.md). One per user; billed by wall time from their credit.
    /// GET /v1/gpu/warm
    func warmGpu() async throws -> WarmGpu
    /// POST /v1/gpu/warm {on, extend?}
    func setWarmGpu(_ req: WarmGpuRequest) async throws -> WarmGpu

    // Balance
    func balance() async throws -> Balance
    func topUp(_ req: TopUpRequest) async throws -> Balance

    // Developer
    func setFailNext(_ fail: Bool) async throws

    /// Live job progress, balance, generation, LoRA, post and warm-GPU updates. Each call returns a new subscription.
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

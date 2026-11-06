import Foundation

/// In-process backend so the app works with no server. Same rules as server/mock and the Android fake:
/// renders run `speed`× faster than real time, the balance is charged when a job is queued and refunded if it fails,
/// and progress arrives as events. Like the desktop prototype, jobs run one after another.
public actor FakeMuseAPI: MuseAPI {
    private let speed: Double
    let genDelay: Double
    let storeDir: URL?
    /// Video editor: presigned uploads that were PUT but not used yet (id → file or JPEG), and the ids already saved as takes.
    var editUploads: [String: FakeEditUpload] = [:]
    var usedUploads: Set<String> = []
    /// Edit suite (workstream 3): editor AI jobs in demo mode, and editor uploads (music, voice-overs, .cube) by id.
    var editorJobs: [String: EditorJob] = [:]
    var editorFiles: [String: URL] = [:]
    /// Edit sessions (workstream 3): the live edits shared with Claude, in memory (Edit/FakeMuseAPI+EditSessions.swift).
    var editSessions: [String: FakeEditSessionRecord] = [:]

    let hub = EventHub()

    var models = SampleData.models()
    var outfits = SampleData.outfits()
    var jobs: [Job]
    var takes: [Take]
    private var clips: [String: Clip] = [:]
    var bal = SampleData.balance()
    var failNext = false
    /// The seeded queue waits for "Run queue", like the prototype. Any new job starts it.
    private var held = true
    private var runner: Task<Void, Never>?
    private var runningId: String?
    private let loraSeconds: Double
    var loras: [String: Lora] = [:]
    private var loraTasks: [String: Task<Void, Never>] = [:]
    private var accounts: [String: [Account]] = [:]
    private var posts: [Post] = []
    /// Demo mode signs you in as the studio owner, with two demo members to send tokens to.
    private var signedIn: User?
    private var members: [Member] = FakeMuseAPI.demoMembers()
    private var engine = ImageEngine(provider: "simulated", model: "bundled-stills", available: ["simulated": true, "fal": false, "custom-http": true])
    var studio = StudioSettings(features: StudioFeatures(replicate: true, video: .demo, photo: .standard, tools: ToolsFeatures()))
    /// The demo studio balance: one opening top-up, then what the owner records.
    private var topUps: [TopUp] = [TopUp(id: "tu_demo", amountUsd: 25, note: "Opening balance", paidAt: nowMs() - 864_000_000)]
    /// Templates with their layers (the "server side"). Only the owner's ever leave the actor with layers.
    private var templates: [MuseTemplate]
    private var favourites: Set<String> = []
    /// Demo prompt library overrides (Settings → Prompts) and when each was saved.
    var promptOverrides: [String: String] = [:]
    var promptUpdated: [String: Int64] = [:]
    /// Prompt scripts (workstream 4): the demo studio's saved rule lists by script id, and when each was saved.
    var scriptOverrides: [String: [ScriptRule]] = [:]
    var scriptUpdated: [String: Int64] = [:]
    /// The exact layers behind each shot (server-side record), for "Save as template".
    private var shotLayers: [String: TemplateLayers] = [:]
    /// Keep add-on engine ready (owner only): the rules run on a clock `warmSpeed`× real time (boot is sped up like renders).
    private var warm: WarmGpuSim
    private let warmSpeed: Double
    private let warmEpoch = nowMs()
    private var warmTask: Task<Void, Never>?
    private let warmBoot: Double
    /// Model tools (plans/api.md "Model tools"): the owner's model per image step, tool runs and sheet versions.
    var stepModels: [ImageStep: (model: String, extra: [String: JSONValue])] = [:]
    var toolRuns: [ToolRun] = []
    var toolTasks: [String: Task<Void, Never>] = [:]
    var sheetVersionsByModel: [String: [SheetVersion]] = [:]
    /// AI suite (workstream 1): the demo studio's suite settings (Engines), once changed.
    var suiteSettingsBox: SuiteSettings?
    /// AI suite (workstream 1): the Look each demo shot's takes carry (by job id), like the server's take.look.
    var suiteLooks: [String: SuiteLook] = [:]
    /// AI suite (workstream 1): a job's take length when it isn't the request's (Extend: source + extension; Upscale: the take's).
    var suiteTakeSeconds: [String: Double] = [:]
    /// AI suite (workstream 1): the demo studio's locations (@location), two to start with.
    var suiteLocationList: [SuiteLocation] = FakeMuseAPI.demoLocations

    /// - Parameters:
    ///   - speed: simulation speed; 0 freezes the queue (tests).
    ///   - genDelay: seconds a generation (shoot, outfit, fill angles) takes.
    ///   - storeDir: where uploaded images are copied. nil keeps them in memory as data URLs.
    ///   - loraSeconds: how long LoRA training takes in the demo (~100 min of GPU time; the prototype runs it 120× faster).
    ///   - warmSpeed: how fast the warm GPU's clock runs (minutes, billing, auto-off). 1 = real time.
    public init(speed: Double = demoSpeed, genDelay: Double = 1.6, storeDir: URL? = nil, loraSeconds: Double = 50, warmSpeed: Double = 1) {
        self.speed = speed
        self.warmSpeed = warmSpeed
        warm = WarmGpuSim(config: WarmGpuSim.Config(bootSeconds: 240 / max(1, speed) * warmSpeed))
        warmBoot = 240 / max(1, speed) * warmSpeed
        self.genDelay = genDelay
        self.storeDir = storeDir
        self.loraSeconds = loraSeconds
        let now = nowMs()
        jobs = SampleData.jobs(now: now)
        takes = FakeMuseAPI.withDemoMedia(SampleData.takes(now: now), jobs: jobs)
        templates = StarterTemplates.all(ownerId: "u1", ownerName: "Studio owner", now: now) + StarterTemplates.memberTemplates(now: now)
        favourites = ["tpl_mirror_selfie"]
        for (meta, id) in [(SampleData.sampleMeta, SampleData.sampleClip), (SampleData.badMeta, SampleData.badClip)] {
            clips[id] = Clip(id: id, name: meta.name, durationSec: meta.durationSec, width: meta.width, height: meta.height, fps: meta.fps, checks: ClipRules.checks(meta),
                             audio: ClipAudio.demo(talking: meta.talking))
        }
        bal = FakeMuseAPI.ownerView(bal, members: members)
    }

    public nonisolated func events() -> AsyncStream<ApiEvent> { hub.stream() }
    public func setToken(_ token: String?) {}

    // MARK: Auth

    public func signIn(_ req: SignInRequest) async throws -> AuthResponse {
        let email = req.email.trimmingCharacters(in: .whitespaces)
        if email.isEmpty { throw ApiError("bad_request", "Enter your email") }
        let u = User(id: "u1", studioName: Self.studio(from: email), email: email, role: "owner")
        signedIn = u
        return AuthResponse(token: "fake-token", user: u)
    }

    public func signUp(_ req: SignUpRequest) async throws -> AuthResponse {
        if !req.attestAdultRightsOriginal || !req.attestLabelAi { throw ApiError("attestation_required", "Tick both boxes to create your account") }
        let email = req.email.trimmingCharacters(in: .whitespaces)
        if email.isEmpty { throw ApiError("bad_request", "Enter your email") }
        let name = req.studioName.trimmingCharacters(in: .whitespaces)
        let u = User(id: "u1", studioName: name.isEmpty ? Self.studio(from: email) : name, email: email, role: "owner")
        signedIn = u
        return AuthResponse(token: "fake-token", user: u)
    }

    public func signOut() { signedIn = nil }

    /// Tests: look at the demo as a member would (members get the member view and owner_only errors).
    func setRole(_ role: String) { signedIn?.role = role }

    public func me() throws -> User {
        guard let u = signedIn else { throw ApiError("unauthorized", "Sign in to continue") }
        return u
    }

    // MARK: Tokens and members (demo: you are the owner; the studio balance is what you can send plus what members hold)

    static func demoMembers() -> [Member] {
        let now = nowMs()
        return [
            Member(id: "u_maya", email: "maya@studio.com", tokens: 250, usd: 2.5, todayUsd: 0.13, monthUsd: 1.94, lastActiveAt: now - 1_800_000, createdAt: now - 864_000_000),
            Member(id: "u_theo", email: "theo@studio.com", tokens: 40, usd: 0.4, monthUsd: 0.67, lastActiveAt: now - 90_000_000, createdAt: now - 432_000_000),
        ]
    }

    static func ownerView(_ b: Balance, members: [Member]) -> Balance {
        var out = b
        let unspent = members.reduce(0.0) { $0 + Double($1.tokens + $1.heldTokens) * b.tokenUsd }
        out.role = "owner"
        out.tokens = Int((b.balance / b.tokenUsd + 1e-6).rounded(.down))
        out.balanceSource = "studio"
        out.availableToSend = b.balance
        out.studioBalance = ((b.balance + unspent + b.heldUsd) * 100).rounded() / 100
        out.needsFirstTopUp = false
        out.perUserDayLimit = 10
        return out
    }

    private func syncOwner() {
        bal = Self.ownerView(bal, members: members)
        hub.emit(ApiEvent(type: "balance", balance: bal))
        hub.emit(ApiEvent(type: "wallet", wallet: walletNow()))
    }

    private func walletNow() -> Wallet {
        let unspent = members.reduce(0.0) { $0 + Double($1.tokens + $1.heldTokens) * bal.tokenUsd }
        return Wallet(userId: signedIn?.id ?? "u1", role: "owner", tokens: bal.tokenCount, usd: bal.balance, todayUsd: bal.today ?? 0, monthUsd: bal.month,
                      tokenUsd: bal.tokenUsd, balanceSource: "studio", availableToSend: bal.balance, studioBalance: bal.studioBalance, membersUnspentUsd: unspent)
    }

    public func wallet() -> Wallet { walletNow() }

    public func createInvite(_ req: InviteRequest) -> Invite {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let s = String((0..<12).map { _ in alphabet.randomElement()! })
        let code = "MUSE-\(s.prefix(4))-\(s.dropFirst(4).prefix(4))-\(s.suffix(4))"
        return Invite(code: code, id: "inv_" + shortId(), email: req.email, role: req.role ?? "member", expiresAt: nowMs() + Int64(req.days ?? 14) * 86_400_000)
    }

    public func listMembers() -> [Member] {
        let owner = Member(id: signedIn?.id ?? "u1", email: signedIn?.email ?? "you@studio.com", role: "owner", todayUsd: bal.today ?? 0, monthUsd: bal.month,
                           lastActiveAt: nowMs(), capPerDay: studio.capPerUserDay)
        return [owner] + members
    }

    private func memberIndex(_ id: String) throws -> Int {
        guard let i = members.firstIndex(where: { $0.id == id }) else { throw ApiError("not_found", "Member not found") }
        return i
    }

    public func updateMember(id: String, _ patch: MemberPatch) throws -> Member {
        let i = try memberIndex(id)
        switch patch.capPerJob { case .set(let v)?: members[i].capPerJob = v; case .reset?: members[i].capPerJob = studio.capPerJob; case nil: break }
        switch patch.capPerDay { case .set(let v)?: members[i].capPerDay = v; case .reset?: members[i].capPerDay = studio.capPerUserDay; case nil: break }
        if let d = patch.disabled { members[i].disabled = d }
        return members[i]
    }

    public func sendTokens(_ move: TokenMove) throws -> TokenMoveResult {
        if move.tokens <= 0 { throw ApiError("bad_request", "Send at least 1 token") }
        let i = try memberIndex(move.userId)
        if Double(move.tokens) * bal.tokenUsd > bal.balance + 1e-9 { throw ApiError("over_allocation", "Only \(bal.tokenCount) tokens are available to send") }
        members[i].tokens += move.tokens
        members[i].usd = Double(members[i].tokens) * bal.tokenUsd
        bal.balance = max(0, ((bal.balance - Double(move.tokens) * bal.tokenUsd) * 1e8).rounded() / 1e8)
        syncOwner()
        return TokenMoveResult(wallet: walletNow(), member: members[i])
    }

    public func takeBackTokens(_ move: TokenMove) throws -> TokenMoveResult {
        if move.tokens <= 0 { throw ApiError("bad_request", "Take back at least 1 token") }
        let i = try memberIndex(move.userId)
        if move.tokens > members[i].tokens { throw ApiError("bad_request", "\(members[i].email) has only \(members[i].tokens) unused tokens") }
        members[i].tokens -= move.tokens
        members[i].usd = Double(members[i].tokens) * bal.tokenUsd
        bal.balance += Double(move.tokens) * bal.tokenUsd
        syncOwner()
        return TokenMoveResult(wallet: walletNow(), member: members[i])
    }

    public func imageEngine() -> ImageEngine { engine }

    public func setImageEngine(_ req: ImageEngineRequest) throws -> ImageEngine {
        guard isOwner else { throw ApiError("owner_only", "Only the studio owner can change the image engine") }
        guard engine.isAvailable(req.provider) else { throw ApiError("bad_request", "\(req.provider) is not set up on the server") }
        if req.provider == "custom-http" && !(req.url ?? "").hasPrefix("https://") { throw ApiError("bad_request", "Use an https:// URL") }
        engine.provider = req.provider
        engine.model = req.model ?? (req.provider == "simulated" ? "bundled-stills" : engine.model)
        engine.url = req.provider == "custom-http" ? req.url : nil
        return engine
    }

    /// Members get the caps and features only; the owner also gets Settings → Engines.
    public func studioSettings() -> StudioSettings {
        guard isOwner else {
            // Members get neutral labels only: no model names.
            var f = studio.features
            f.tools?.enhance.models = nil
            f.tools?.dressUp.models = nil
            return StudioSettings(capPerJob: studio.capPerJob, capPerDay: studio.capPerDay, capPerUserDay: studio.capPerUserDay, tokenUsd: studio.tokenUsd, features: f)
        }
        var s = studio
        s.features.tools?.enhance.models = toolModelRefs(ImageStep.enhanceSteps)
        s.features.tools?.dressUp.models = toolModelRefs(ImageStep.dressUpSteps)
        s.engines = Engines(list: [EngineStatus(id: "replicate", name: "Replicate", usedFor: "Draft, Standard and HD video · photos", keySet: false, status: "simulated"),
                                   EngineStatus(id: "runpod", name: "RunPod", usedFor: "Edit, Fast · beta, Upscale", keySet: false, status: "simulated")],
                            imageEngine: engine, addOn: AddOnEngine(maxGpus: studio.maxGpus, overheadPayer: studio.overheadPayer),
                            keepReady: KeepReady(idleMinutes: studio.warmIdleMinutes, maxMinutes: studio.warmMaxMinutes))
        return s
    }

    /// Demo mode signs in as the owner; a demo account with role "member" sees the member view.
    var isOwner: Bool { (signedIn?.role ?? "owner") == "owner" }

    public func updateStudioSettings(_ patch: StudioSettingsPatch) throws -> StudioSettings {
        guard isOwner else { throw ApiError("owner_only", "Only the studio owner can change studio settings") }
        if let g = patch.maxGpus { guard (0...16).contains(g) else { throw ApiError("bad_request", "Max GPUs must be 0–16") }; studio.maxGpus = g }
        if let p = patch.overheadPayer { studio.overheadPayer = p == "owner" ? "owner" : "user" }
        if let v = patch.capPerJob { studio.capPerJob = v; bal.perJobLimit = v }
        if let v = patch.capPerDay { studio.capPerDay = v; bal.perDayLimit = v }
        if let v = patch.capPerUserDay { studio.capPerUserDay = v }
        if let v = patch.warmIdleMinutes { guard (5...120).contains(v) else { throw ApiError("bad_request", "Idle minutes must be 5–120") }; studio.warmIdleMinutes = v }
        if let v = patch.warmMaxMinutes { guard (30...480).contains(v) else { throw ApiError("bad_request", "The time limit must be 30–480 min") }; studio.warmMaxMinutes = v }
        // New warm sessions use the new rules.
        if !warm.isOn { warm = WarmGpuSim(config: warmConfig()) }
        return studioSettings()
    }

    static func studio(from email: String) -> String {
        let n = email.split(separator: "@").first.map(String.init) ?? "My"
        return n.prefix(1).uppercased() + n.dropFirst() + "'s studio"
    }

    // MARK: Models

    public func listModels() -> [MuseModel] { models.filter { !$0.archived } }

    public func createModel(_ req: CreateModelRequest) throws -> MuseModel {
        let name = req.name.trimmingCharacters(in: .whitespaces)
        let m = MuseModel(id: "m_" + shortId(), name: name.isEmpty ? "New model" : name, age: min(70, max(18, req.age)), niche: req.niche,
                          slots: SheetAngle.allCases.map { SheetSlot(key: $0.rawValue) }, personality: req.personality, notes: req.notes)
        models.append(m)
        return m
    }

    public func setSlot(modelId: String, slot: String, _ req: SetSlotRequest) throws -> MuseModel {
        var m = try model(modelId)
        if let i = m.slots.firstIndex(where: { $0.key == slot }) {
            m.slots[i] = SheetSlot(key: slot, image: req.image, source: req.source)
        } else {
            m.slots.append(SheetSlot(key: slot, image: req.image, source: req.source))
        }
        replace(m)
        return m
    }

    public func fillAngles(modelId: String) async throws -> FillAnglesResponse {
        var m = try activeModel(modelId)
        let missing = m.slots.filter { $0.image == nil && !$0.busy }
        let cost = photoPricing.sheetAngles(missing.count)
        if cost > bal.balance + 1e-9 { throw ApiError("insufficient_balance", "Not enough balance · top up in Credits") }
        charge(cost)
        for i in m.slots.indices where m.slots[i].image == nil { m.slots[i].busy = true }
        replace(m)
        hub.emit(ApiEvent(type: "balance", balance: bal))
        let busy = m
        Task { [genDelay] in
            try? await Task.sleep(nanoseconds: UInt64(genDelay * 1_000_000_000))
            self.finishFill(modelId)
        }
        return FillAnglesResponse(model: busy, cost: cost)
    }

    private func finishFill(_ modelId: String) {
        guard var m = try? model(modelId) else { return }
        for i in m.slots.indices where m.slots[i].busy {
            m.slots[i] = SheetSlot(key: m.slots[i].key, image: .asset(SampleData.sample(for: m.slots[i].key)), source: "generated")
        }
        replace(m)
        hub.emit(ApiEvent(type: "model", model: m))
    }

    public func updateModel(id: String, _ req: UpdateModelRequest) throws -> MuseModel {
        var m = try model(id)
        if let v = req.name?.trimmingCharacters(in: .whitespaces) {
            if v.isEmpty { throw ApiError("bad_request", "Give her a name") }
            m.name = v
        }
        if let v = req.niche { m.niche = v }
        if let v = req.personality { m.personality = v }
        if let v = req.notes { m.notes = v }
        if let v = req.neverAdd { m.neverAdd = v.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        replace(m)
        hub.emit(ApiEvent(type: "model", model: m))
        return m
    }

    /// Deletes the model with its outfits, LoRAs, training set and accounts.
    public func deleteModel(id: String) throws {
        _ = try model(id)
        models.removeAll { $0.id == id }
        outfits.removeAll { $0.modelId == id }
        loraTasks[id]?.cancel()
        loraTasks[id] = nil
        loras[id] = nil
        accounts[id] = nil
        posts.removeAll { $0.modelId == id && $0.isScheduled }
    }

    // MARK: Identity LoRA

    /// The demo pool of training shots (the prototype's CAND_POOL) and which ones get flagged.
    static let candidatePool: [(String, String)] = [
        ("g_front", "Green set · front"), ("g_tq", "Green set · ¾"), ("face", "Close-up · window light"), ("c_front", "Crystal dress · full"),
        ("g_side", "Green set · side"), ("profile", "Profile · soft light"), ("c_tq", "Crystal · ¾"), ("g_back", "Back · physique"),
        ("hero", "Portrait · golden hour"), ("c_face", "Close-up · choker"),
    ]
    static let candidateFlags: [Int: String] = [4: "tattoo", 9: "choker", 16: "ring", 23: "face drift"]

    public func lora(modelId: String) throws -> Lora {
        _ = try model(modelId)
        return loras[modelId] ?? Lora(modelId: modelId)
    }

    public func buildLoraCandidates(modelId: String) throws -> Lora {
        let m = try activeModel(modelId)
        var l = loras[modelId] ?? Lora(modelId: modelId)
        if l.isBusy { throw ApiError("busy", "The LoRA is busy · wait for it to finish") }
        if m.filled == 0 { throw ApiError("bad_request", "Add character-sheet shots first") }
        let cost = photoPricing.loraSet()
        if cost > bal.balance + 1e-9 { throw ApiError("insufficient_balance", "Not enough balance · top up in Credits") }
        charge(cost)
        hub.emit(ApiEvent(type: "balance", balance: bal))
        l.state = "building"
        l.candidates = []
        l.progress = 0
        l.cost = cost
        loras[modelId] = l
        hub.emit(ApiEvent(type: "lora", lora: l))
        let delay = genDelay + 0.2
        loraTasks[modelId]?.cancel()
        loraTasks[modelId] = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            self.finishCandidates(modelId)
        }
        return l
    }

    private func finishCandidates(_ modelId: String) {
        guard var l = loras[modelId], l.state == "building" else { return }
        let round = shortId().prefix(4)
        l.candidates = (0..<LoraPricing.candidates).map { i in
            let (k, label) = Self.candidatePool[i % Self.candidatePool.count]
            return LoraCandidate(id: "lc_\(round)_\(i + 1)", image: .asset(k), label: label, flag: Self.candidateFlags[i])
        }
        l.state = "review"
        loras[modelId] = l
        loraTasks[modelId] = nil
        hub.emit(ApiEvent(type: "lora", lora: l))
    }

    public func setLoraCandidate(modelId: String, candidateId: String, keep: Bool) throws -> Lora {
        guard var l = loras[modelId], let i = l.candidates.firstIndex(where: { $0.id == candidateId }) else { throw ApiError("not_found", "Shot not found") }
        if l.state != "review" { throw ApiError("bad_request", "The training set can only change while you review it") }
        l.candidates[i].keep = keep
        loras[modelId] = l
        return l
    }

    public func trainLora(modelId: String) throws -> Lora {
        guard var l = loras[modelId], l.state == "review" else { throw ApiError("bad_request", "Build and review the training set first") }
        if l.kept < LoraPricing.minKept { throw ApiError("bad_request", "Keep at least \(LoraPricing.minKept) shots to train") }
        let cost = LoraPricing.trainCost
        if cost > bal.balance + 1e-9 { throw ApiError("insufficient_balance", "Not enough balance to train · top up in Credits") }
        charge(cost)
        hub.emit(ApiEvent(type: "balance", balance: bal))
        l.state = "training"
        l.progress = 0
        l.photo = LoraPart(state: "training", progress: 0)
        l.video = LoraPart(state: "waiting", progress: 0)
        l.cost += cost
        loras[modelId] = l
        hub.emit(ApiEvent(type: "lora", lora: l))
        loraTasks[modelId]?.cancel()
        loraTasks[modelId] = Task { await self.driveTraining(modelId) }
        return l
    }

    private func driveTraining(_ modelId: String) async {
        let t0 = Date()
        let total = max(0.05, loraSeconds)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(min(0.3, total / 20) * 1_000_000_000))
            if Task.isCancelled { return }
            guard var l = loras[modelId], l.state == "training" else { return }
            let p = min(100, Date().timeIntervalSince(t0) / total * 100)
            l.progress = p
            l.photo = LoraPart(state: p >= 25 ? "ready" : "training", progress: LoraPricing.photoProgress(p))
            l.video = LoraPart(state: p >= 100 ? "ready" : p >= 25 ? "training" : "waiting", progress: LoraPricing.videoProgress(p))
            if p >= 100 {
                l.state = "ready"
                l.version += 1
                l.use = true
                l.trainedOn = l.kept
            }
            loras[modelId] = l
            hub.emit(ApiEvent(type: "lora", lora: l))
            if p >= 100 { break }
        }
        loraTasks[modelId] = nil
    }

    public func retrainLora(modelId: String) throws -> Lora {
        guard var l = loras[modelId], l.state == "ready" else { throw ApiError("bad_request", "Nothing to retrain yet") }
        l.state = "review"
        loras[modelId] = l
        hub.emit(ApiEvent(type: "lora", lora: l))
        return l
    }

    public func setLoraUse(modelId: String, use: Bool) throws -> Lora {
        _ = try model(modelId)
        var l = loras[modelId] ?? Lora(modelId: modelId)
        l.use = use
        loras[modelId] = l
        return l
    }

    // MARK: Social accounts and posts

    public func listAccounts(modelId: String) throws -> [Account] {
        _ = try model(modelId)
        return accounts[modelId] ?? []
    }

    /// The mock connects at once (no OAuth) and returns the account.
    public func connectAccount(modelId: String, platform: Platform) throws -> ConnectResult {
        let m = try model(modelId)
        let handle: String
        switch platform {
        case .youtube: handle = m.name
        case .facebook: handle = "\(m.name) (Page)"
        default: handle = "@" + m.name.lowercased().split(separator: " ").joined(separator: ".")
        }
        let a = Account(modelId: modelId, platform: platform, handle: handle, connectedAt: nowMs(), canPostDirect: false)
        var list = accounts[modelId] ?? []
        list.removeAll { $0.platform == platform }
        list.append(a)
        accounts[modelId] = list.sorted { Platform.allCases.firstIndex(of: $0.platform)! < Platform.allCases.firstIndex(of: $1.platform)! }
        return .connected(a)
    }

    public func disconnectAccount(modelId: String, platform: Platform) {
        accounts[modelId]?.removeAll { $0.platform == platform }
    }

    public func listPosts(state: String?) -> [Post] {
        promoteDuePosts()
        return state.map { s in posts.filter { $0.state == s } } ?? posts
    }

    public func createPost(_ req: CreatePostRequest) throws -> Post {
        _ = try model(req.modelId)
        if req.platforms.isEmpty { throw ApiError("bad_request", "Pick at least one account") }
        let connected = Set((accounts[req.modelId] ?? []).map(\.platform))
        if let missing = req.platforms.first(where: { !connected.contains($0) }) { throw ApiError("bad_request", "Connect \(missing.label) first") }
        guard let take = takes.first(where: { $0.id == req.takeId }) else { throw ApiError("not_found", "Take not found") }
        let scheduled = req.when != "now"
        if scheduled && PostTime.parse(req.when) == nil { throw ApiError("bad_request", "Pick a time to post") }
        let id = "p_" + shortId()
        // Stage 1: nothing is published by MUSE. "now" hands off to each app; the labels are stored exactly as the user set them.
        let p = Post(id: id, modelId: req.modelId, takeId: req.takeId, platforms: req.platforms, caption: req.caption, aiLabel: req.aiLabel,
                     paidPartnership: req.paidPartnership, when: req.when, state: scheduled ? "scheduled" : "handoff", title: take.caption, thumb: take.thumb,
                     createdAt: nowMs())
        posts.insert(p, at: 0)
        hub.emit(ApiEvent(type: "post", post: p))
        if !scheduled { markPostedLater(id) }
        return p
    }

    public func deletePost(id: String) { posts.removeAll { $0.id == id } }

    /// Scheduled posts whose time has come move to `handoff` (stage 1: the app opens each platform for the user).
    private func promoteDuePosts() {
        let now = Date()
        for i in posts.indices where posts[i].isScheduled {
            if let d = posts[i].scheduledDate, d <= now {
                posts[i].state = "handoff"
                hub.emit(ApiEvent(type: "post", post: posts[i]))
                markPostedLater(posts[i].id)
            }
        }
    }

    /// Like server/mock: a handed-off post turns `posted` with stats after a moment, standing in for the stats read-back.
    private func markPostedLater(_ id: String) {
        let delay = genDelay
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self.markPosted(id)
        }
    }

    private func markPosted(_ id: String) {
        guard let i = posts.firstIndex(where: { $0.id == id }), posts[i].state == "handoff" else { return }
        posts[i].state = "posted"
        posts[i].postedAt = nowMs()
        posts[i].stats = Self.demoStats(id)
        hub.emit(ApiEvent(type: "post", post: posts[i]))
    }

    /// Plausible demo numbers, stable per post.
    static func demoStats(_ id: String) -> PostStats {
        var h: UInt32 = 2166136261
        for b in id.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        let views = 1240 + Int(h % 900)
        return PostStats(views: views, likes: views * 11 / 100, comments: views * 8 / 1000)
    }

    // MARK: Outfits

    /// Archived models' outfits are left out.
    public func listOutfits() -> [Outfit] {
        let archived = Set(models.filter(\.archived).map(\.id))
        return outfits.filter { !archived.contains($0.modelId) }
    }

    public func createOutfit(_ req: CreateOutfitRequest) async throws -> Outfit {
        try checkOverrides(req.models)
        let m = try activeModel(req.modelId)
        let cost = req.mode == "own" ? 0 : photoPricing.outfitSet()
        if cost > bal.balance + 1e-9 { throw ApiError("insufficient_balance", "Not enough balance · top up in Credits") }
        charge(cost)
        let name = req.name.trimmingCharacters(in: .whitespaces)
        let label = name.isEmpty ? (req.description.isEmpty ? "New outfit" : String(req.description.prefix(28))) : name
        let prompt = PromptEngine.outfitAngle(identity: m.promptIdentity(lora: loras[m.id]), outfit: req.description.isEmpty ? label : req.description,
                                              mode: OutfitMode(rawValue: req.mode) ?? .describe, angle: "Front")
        let o = Outfit(id: "o_" + shortId(), modelId: req.modelId, name: label, mode: req.mode, description: req.description, state: "generating", prompt: prompt)
        outfits.append(o)
        if cost > 0 { hub.emit(ApiEvent(type: "balance", balance: bal)) }
        let images = req.images
        let delay = req.mode == "own" ? 0.3 : genDelay + 0.1
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self.finishOutfit(o.id, own: req.mode == "own", images: images)
        }
        return o
    }

    private func finishOutfit(_ id: String, own: Bool, images: [ImageRef]) {
        guard let i = outfits.firstIndex(where: { $0.id == id }) else { return }
        if own && !images.isEmpty {
            outfits[i].angles = (0..<4).map { $0 < images.count ? images[$0] : nil }
        } else {
            outfits[i].angles = ["c_front", "c_tq", "c_face", "c_front"].map { ImageRef.asset($0) }
        }
        outfits[i].state = "preview"
        hub.emit(ApiEvent(type: "outfit", outfit: outfits[i]))
    }

    public func saveOutfit(outfitId: String) throws -> Outfit {
        guard let i = outfits.firstIndex(where: { $0.id == outfitId }) else { throw ApiError("not_found", "Outfit not found") }
        outfits[i].state = "ready"
        var m = try model(outfits[i].modelId)
        if !m.outfitIds.contains(outfitId) { m.outfitIds.append(outfitId) }
        replace(m)
        hub.emit(ApiEvent(type: "model", model: m))
        return outfits[i]
    }

    // MARK: Uploads

    public func uploadImage(name: String, data: Data, mime: String, progress: UploadProgress?) throws -> ImageRef {
        progress?(1)
        guard let dir = storeDir else { return ImageRef(url: "data:\(mime);base64,\(data.base64EncodedString())") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = mime.contains("png") ? "png" : mime.contains("heic") ? "heic" : "jpg"
        let f = dir.appendingPathComponent("img_\(shortId()).\(ext)")
        try data.write(to: f)
        return ImageRef(url: f.absoluteString)
    }

    public func uploadClip(_ meta: ClipMeta, file: URL?, progress: UploadProgress?) -> Clip {
        progress?(1)
        let id: String
        if meta == SampleData.sampleMeta { id = SampleData.sampleClip } else if meta == SampleData.badMeta { id = SampleData.badClip } else { id = "clip_" + shortId() }
        // Prompt scripts: the demo's talking detection follows the upload's `talking`.
        let c = Clip(id: id, name: meta.name, durationSec: meta.durationSec, width: meta.width, height: meta.height, fps: meta.fps, checks: ClipRules.checks(meta),
                     audio: ClipAudio.demo(talking: meta.talking))
        clips[id] = c
        return c
    }

    // MARK: Jobs

    public func listJobs() -> [Job] { jobs.sorted { $0.createdAt > $1.createdAt } }

    public func createJob(_ req: JobRequest) throws -> Job {
        if let m = models.first(where: { $0.id == req.modelId }), m.archived { throw ApiError.modelArchived }
        // Clip checks are advice only: a failing clip can still be rendered (the app shows a disclaimer).
        var req = req
        if req.engine == Engine.replicate.rawValue {
            // Replicate always renders the whole clip and stores "full".
            req.use = ClipUse.full.rawValue
            if req.quality == nil { req.quality = VideoQuality.default.rawValue }
        }
        // Prompt scripts: "Performer is speaking" is resolved once, at creation (the switch, else the clip's detection, else off).
        if let sp = req.speaking {
            req.speaking = sp
            req.speakingSource = "switch"
        } else if let a = clips[req.clipId]?.audio {
            req.speaking = a.speaking
            req.speakingSource = a.detected ? "detected" : "upload"
        } else {
            req.speaking = false
            req.speakingSource = "default"
        }
        let spec = req.spec(pricePerSec: (studio.features.video ?? .fallback).pricePerSec(req.videoQuality))
        if spec.engine == .h3 && (spec.steps < Pricing.stepsMin || spec.steps > Pricing.stepsMax) { throw ApiError("bad_request", "That render setting isn't supported") }
        if spec.isReplicate {
            if req.lipSync { throw ApiError("bad_request", "Lip sync is Edit only") }
            if req.background == "photo" { throw ApiError("bad_request", "A new background photo is Edit only") }
            if let q = req.quality, !["draft", "standard", "hd"].contains(q) { throw ApiError("bad_request", "quality must be draft, standard or hd") }
        }
        if spec.takes < 1 || spec.takes > Pricing.takesMax { throw ApiError("bad_request", "Takes must be 1–4") }
        let cost = Pricing.totalCost(spec)
        if cost > bal.balance + 1e-9 { throw ApiError("insufficient_balance", "Not enough in the studio balance · add a top-up in Credits") }
        if cost > bal.perJobLimit { throw ApiError("over_job_limit", "Over your \(Pricing.money(bal.perJobLimit)) per-job limit") }
        if (bal.today ?? 0) + cost > bal.perDayLimit { throw ApiError("over_day_limit", "Over your \(Pricing.money(bal.perDayLimit)) daily limit") }
        let m = try model(req.modelId)
        let o = outfits.first { $0.id == req.outfitId }
        let seed = Int64.random(in: 1000...99999)
        let prompt = PromptEngine.video(VideoPromptInput(identity: m.promptIdentity(lora: loras[m.id]), outfitName: o?.name ?? "outfit",
                                                         performer: req.clipId == SampleData.sampleClip ? .sample : .generic,
                                                         keepBackground: req.background == "keep", backgroundMotion: req.backgroundMotion,
                                                         keepAudio: req.keepAudio, spec: spec))
        charge(cost)
        let p = JobClock.progress(req, elapsed: 0)
        var j = Job(id: "j_" + shortId(), title: req.title, modelId: m.id, modelName: m.name, outfitId: req.outfitId, request: req, state: "queued",
                    totalSteps: p.totalSteps, phase: "Queued", secondsLeft: p.secondsLeft, totalSeconds: Pricing.totalSeconds(spec), cost: cost,
                    createdAt: nowMs(), prompt: prompt, seed: seed, thumb: o?.front ?? m.cover)
        j.engineText = Job.engineLabel(for: req)
        jobs.append(j)
        hub.emit(ApiEvent(type: "balance", balance: bal))
        hub.emit(ApiEvent(type: "job", job: j))
        held = false
        pump()
        return jobs.first { $0.id == j.id } ?? j
    }

    public func runQueue() {
        held = false
        pump()
    }

    public func removeJob(id: String) {
        if runningId == id {
            runner?.cancel()
            runner = nil
            runningId = nil
        }
        jobs.removeAll { $0.id == id }
        pump()
    }

    /// Starts the next queued job when nothing is rendering.
    private func pump() {
        guard runner == nil, !held, speed > 0 else { return }
        guard let next = jobs.filter({ $0.isQueued }).min(by: { $0.createdAt < $1.createdAt }), let i = jobs.firstIndex(where: { $0.id == next.id }) else { return }
        let p = JobClock.progress(next.request, elapsed: 0)
        jobs[i].state = "running"
        jobs[i].phase = p.phase
        hub.emit(ApiEvent(type: "job", job: jobs[i]))
        let id = next.id
        let failThis = failNext
        failNext = false
        runningId = id
        // While the add-on engine is kept ready, Edit and Fast renders' time is on that line. Draft / Standard / HD never use it.
        if warm.isOn && next.engine != .replicate && next.request.engine != "suite" { jobs[i].warm = true } // AI suite (workstream 1): suite shots never use it
        runner = Task { await self.drive(id, fail: failThis) }
    }

    private func drive(_ id: String, fail: Bool) async {
        let t0 = Date()
        let failAt = fail ? (jobs.first { $0.id == id }.map { JobClock.failAt($0.request) } ?? 0) : .greatestFiniteMagnitude
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            guard let i = jobs.firstIndex(where: { $0.id == id }) else { break }
            let elapsed = Date().timeIntervalSince(t0) * speed
            let cur = jobs[i]
            if elapsed >= failAt {
                let p = JobClock.progress(cur.request, elapsed: failAt)
                jobs[i].state = "failed"
                jobs[i].progress = p.progress
                jobs[i].step = p.step
                jobs[i].refunded = cur.cost
                jobs[i].phase = "Failed"
                if cur.engine == .replicate {
                    jobs[i].errorCode = "provider_refused"
                    jobs[i].error = "This clip was refused by the content filter · you weren't charged"
                } else {
                    jobs[i].errorCode = "provider_failed"
                    jobs[i].error = MemberText.wentWrong
                }
                jobs[i].finishedAt = nowMs()
                refund(cur.cost)
                hub.emit(ApiEvent(type: "job", job: jobs[i]))
                hub.emit(ApiEvent(type: "balance", balance: bal))
                break
            } else if elapsed >= cur.totalSeconds {
                jobs[i].state = "done"
                jobs[i].progress = 100
                jobs[i].step = cur.totalSteps
                jobs[i].take = cur.request.takes
                jobs[i].phase = "Done"
                jobs[i].secondsLeft = 0
                jobs[i].finishedAt = nowMs()
                if cur.engine == .replicate { jobs[i].billedSeconds = Double(cur.request.spec.replicateSeconds * max(1, cur.request.takes)) }
                if jobs[i].warm == true {
                    // Settles to $0: the add-on engine's ready time already paid for it.
                    refund(cur.cost)
                    jobs[i].cost = 0
                    syncOwner()
                }
                let newTakes = makeTakes(for: jobs[i])
                takes.insert(contentsOf: newTakes, at: 0)
                hub.emit(ApiEvent(type: "job", job: jobs[i], takes: newTakes))
                break
            } else {
                let p = JobClock.progress(cur.request, elapsed: elapsed)
                jobs[i].progress = p.progress
                jobs[i].take = p.take
                jobs[i].step = p.step
                jobs[i].phase = p.phase
                jobs[i].secondsLeft = p.secondsLeft
                hub.emit(ApiEvent(type: "job", job: jobs[i]))
            }
        }
        if runningId == id {
            runner = nil
            runningId = nil
            // A short pause between jobs, like the prototype.
            try? await Task.sleep(nanoseconds: UInt64(0.6e9 * min(1, demoSpeed / speed)))
            pump()
        }
    }

    private func makeTakes(for j: Job) -> [Take] {
        let o = outfits.first { $0.id == j.outfitId }
        let pool = (o?.angles.compactMap { $0 } ?? [])
        let n = max(1, j.request.takes)
        let label = j.request.engine == "suite" ? SuiteText.tierLabel(j.request.quality) : j.videoQuality.label // AI suite (workstream 1): tier label
        return (1...n).map { k in
            let thumb = pool.isEmpty ? (j.thumb ?? .asset("g_front")) : pool[(k - 1) % pool.count]
            var t = Take(id: "t_\(j.id)_\(k)", jobId: j.id, index: k, of: n, title: j.title, label: label, engineLabel: j.engineLabel,
                         cost: j.cost / Double(n), seed: j.seed + Int64(k - 1), thumb: thumb, prompt: j.prompt, createdAt: nowMs())
            t.look = j.request.engine == "suite" ? suiteLooks[j.id] : nil // AI suite (workstream 1): the shot's Look
            // Its length and stored file (Extend and Upscale work on it).
            t.durationSec = suiteTakeSeconds[j.id] ?? j.request.clipSeconds ?? j.lengthSec
            t.mediaKey = "r/\(j.id)/take_\(k).mp4"
            if j.request.isUpscale { t.label = j.engineText ?? "Upscale" }
            return t
        }
    }

    /// Demo takes: render takes get a length and a stored file key (no file: there is no video in demo mode).
    static func withDemoMedia(_ list: [Take], jobs: [Job]) -> [Take] {
        list.map { t0 in
            var t = t0
            guard t.kind == "take" else { return t }
            if t.durationSec == nil { t.durationSec = t.jobId.flatMap { id in jobs.first { $0.id == id }?.lengthSec } ?? SampleData.sampleMeta.durationSec }
            if t.mediaKey == nil && t.videoUrl == nil { t.mediaKey = "r/\(t.jobId ?? t.id)/take_\(t.index).mp4" }
            return t
        }
    }

    // MARK: Takes

    public func listTakes() -> [Take] { takes }

    public func setTakeStatus(id: String, status: String) throws -> Take {
        guard let i = takes.firstIndex(where: { $0.id == id }) else { throw ApiError("not_found", "Take not found") }
        takes[i].status = status
        return takes[i]
    }

    public func deleteTake(id: String) { takes.removeAll { $0.id == id } }

    public func shoot(_ req: ShootRequest) async throws -> [Take] {
        try checkOverrides(req.models)
        _ = try activeModel(req.modelId)
        if let p = req.refsProblem { throw ApiError("bad_request", p) }
        if let tid = req.templateId { return try await templateShoot(tid, req) }
        let count = max(1, min(4, req.count))
        let preview = try shootPreviewNow(req)
        let cost = preview.estimate
        if cost > bal.balance + 1e-9 { throw ApiError("insufficient_balance", "Not enough in the studio balance · add a top-up in Credits") }
        charge(cost)
        hub.emit(ApiEvent(type: "balance", balance: bal))
        try? await Task.sleep(nanoseconds: UInt64(genDelay * 1_000_000_000))
        let o = outfits.first { $0.id == req.outfitId }
        let pool = [o?.front?.asset ?? "c_front", "c_tq", "g_front", "hero"]
        let scene = req.scene ?? "Rooftop · golden hour"
        let label = scene.components(separatedBy: "·").first?.trimmingCharacters(in: .whitespaces) ?? scene
        let t = nowMs()
        let shots = (0..<count).map { n in
            var take = Take(id: "s_\(shortId())", kind: "shot", index: n + 1, of: count, title: "Shoot · \(label.prefix(28))", label: "Shoot", cost: cost / Double(count),
                            seed: req.seed ?? preview.seed ?? Int64.random(in: 1000...99999), thumb: .asset(pool[n % pool.count]), prompt: preview.text, createdAt: t)
            take.refs = req.refs
            return take
        }
        takes.insert(contentsOf: shots, at: 0)
        return shots
    }

    // MARK: Photo templates (plans/templates.md, plans/api.md)

    private var meId: String { signedIn?.id ?? "u1" }

    /// What the signed-in user may see of a template: layers and pool only for its owner.
    private func view(_ t: MuseTemplate, detail: Bool = false) -> MuseTemplate {
        var v = t
        v.isOwner = t.ownerId == meId
        v.favourite = favourites.contains(t.id)
        if !v.isOwner { v = v.redacted }
        if detail {
            v.recent = takes.filter { $0.templateId == t.id }.sorted { $0.createdAt > $1.createdAt }.prefix(6)
                .map { TemplateRecent(id: $0.id, thumb: $0.thumb, createdAt: $0.createdAt) }
        } else {
            v.recent = nil
        }
        return v
    }

    private func visibleIndex(_ id: String) throws -> Int {
        guard let i = templates.firstIndex(where: { $0.id == id }), templates[i].isPublic || templates[i].ownerId == meId else {
            throw ApiError("not_found", "Template not found")
        }
        return i
    }

    private func ownedIndex(_ id: String) throws -> Int {
        let i = try visibleIndex(id)
        guard templates[i].ownerId == meId else { throw ApiError("owner_only", "Only the template's owner can change it") }
        return i
    }

    public func listTemplates(_ query: TemplateQuery) -> [MuseTemplate] { query.apply(templates.map { view($0) }) }

    public func template(id: String) throws -> MuseTemplate { view(templates[try visibleIndex(id)], detail: true) }

    public func templateDraft(fromShotId: String) throws -> TemplateDraft {
        guard let shot = takes.first(where: { $0.id == fromShotId }) else { throw ApiError("not_found", "Shot not found") }
        if let tid = shot.templateId, let t = templates.first(where: { $0.id == tid }), t.ownerId != meId {
            throw ApiError("template_hidden", "This photo was made with someone else's template, so its look can't be saved")
        }
        let model = models.first { shot.prompt.hasPrefix($0.name) }
        let layers = shotLayers[shot.id] ?? TemplateLayers.from(prompt: shot.prompt, neverAdd: model?.neverAdd ?? [])
        var name = shot.title.replacingOccurrences(of: "Shoot · ", with: "")
        if let tn = shot.templateName { name = tn }
        name = name.prefix(1).uppercased() + name.dropFirst()
        var pool = TemplateEngine.suggestPool(layers: layers, name: name)
        let direction = shot.prompt.components(separatedBy: "\n").first { $0.hasPrefix("Direction: ") }.map { String($0.dropFirst("Direction: ".count)) }
        if let d = direction?.trimmingCharacters(in: CharacterSet(charactersIn: ". ")), !d.isEmpty { pool[.pose] = [d] + pool[.pose].filter { $0 != d } }
        return TemplateDraft(name: name.trimmingCharacters(in: .whitespaces), tags: [], layers: layers, variationPool: pool, cover: shot.thumb, fromShotId: shot.id)
    }

    public func createTemplate(_ req: CreateTemplateRequest) throws -> MuseTemplate {
        let name = req.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { throw ApiError("bad_request", "Give the template a name") }
        let vis = req.visibility.isEmpty ? "private" : req.visibility
        guard TemplateVisibility(rawValue: vis) != nil else { throw ApiError("bad_request", "Visibility is private or public") }
        var layers = req.layers ?? TemplateLayers()
        var pool = req.variationPool ?? VariationPool()
        var cover: ImageRef?
        if let sid = req.fromShotId {
            let d = try templateDraft(fromShotId: sid)
            layers = d.layers
            if pool.isEmpty { pool = d.variationPool }
            cover = d.cover
        } else {
            if pool.isEmpty { pool = TemplateEngine.suggestPool(layers: layers, name: name) }
            if let cid = req.coverTakeId { cover = takes.first { $0.id == cid }?.thumb }
        }
        let now = nowMs()
        let t = MuseTemplate(id: "tpl_" + shortId(), name: name, tags: req.tags, visibility: vis, ownerId: meId, ownerName: signedIn?.email ?? "you",
                             isOwner: true, cover: cover, acceptsProduct: !layers.product.trimmingCharacters(in: .whitespaces).isEmpty,
                             createdFromShotId: req.fromShotId, createdAt: now, updatedAt: now, layers: layers, variationPool: pool)
        templates.insert(t, at: 0)
        return view(t)
    }

    public func updateTemplate(id: String, _ patch: TemplatePatch) throws -> MuseTemplate {
        let i = try ownedIndex(id)
        if let n = patch.name {
            let name = n.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { throw ApiError("bad_request", "Give the template a name") }
            templates[i].name = name
        }
        if let t = patch.tags { templates[i].tags = t }
        if let v = patch.visibility {
            guard TemplateVisibility(rawValue: v) != nil else { throw ApiError("bad_request", "Visibility is private or public") }
            templates[i].visibility = v
        }
        if let l = patch.layers {
            templates[i].layers = l
            templates[i].acceptsProduct = !l.product.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if let p = patch.variationPool { templates[i].variationPool = p }
        templates[i].updatedAt = nowMs()
        return view(templates[i])
    }

    public func deleteTemplate(id: String) throws {
        let i = try ownedIndex(id)
        favourites.remove(templates[i].id)
        templates.remove(at: i)
    }

    public func duplicateTemplate(id: String) throws -> MuseTemplate {
        let src = templates[try ownedIndex(id)]
        let now = nowMs()
        var t = src
        t.id = "tpl_" + shortId()
        t.name = "\(src.name) copy"
        t.visibility = "private"
        t.uses = 0
        t.starter = nil
        t.createdAt = now
        t.updatedAt = now
        templates.insert(t, at: 0)
        return view(t)
    }

    public func setTemplateFavourite(id: String, _ on: Bool) throws -> MuseTemplate {
        let i = try visibleIndex(id)
        if on { favourites.insert(id) } else { favourites.remove(id) }
        return view(templates[i])
    }

    private func templateBuild(_ t: MuseTemplate, modelId: String, outfitId: String?, direction: String?, shuffleSeed: Int64, index: Int,
                               lockSeed: Bool, seed: Int64?, hasProduct: Bool) throws -> TemplateEngine.Build {
        let m = try model(modelId)
        let outfit = outfitId.flatMap { id in outfits.first { $0.id == id } }
        return TemplateEngine.build(templateId: t.id, templateName: t.name, layers: t.layers ?? TemplateLayers(), pool: t.variationPool ?? VariationPool(),
                                    identity: m.promptIdentity(lora: loras[m.id]), outfitName: outfit?.name, direction: direction, shuffleSeed: shuffleSeed,
                                    index: index, lockSeed: lockSeed, seed: seed, hasProduct: hasProduct)
    }

    public func templatePrompt(id: String, _ req: TemplatePromptRequest) throws -> TemplatePrompt {
        let t = templates[try visibleIndex(id)]
        let shuffle = req.shuffleSeed ?? TemplateEngine.newShuffleSeed()
        let b = try templateBuild(t, modelId: req.modelId, outfitId: req.outfitId, direction: req.direction, shuffleSeed: shuffle, index: 0,
                                  lockSeed: req.lockSeed ?? false, seed: nil, hasProduct: false)
        let owner = t.ownerId == meId
        return TemplatePrompt(slots: owner ? b.full : b.visible, seed: b.seed, shuffleSeed: shuffle, variation: owner ? b.variation : nil)
    }

    private func templateShoot(_ tid: String, _ req: ShootRequest) async throws -> [Take] {
        let i = try visibleIndex(tid)
        _ = try model(req.modelId)
        let count = max(1, min(8, req.count))
        let cost = photoPricing.shoot(count: count)
        if cost > bal.balance + 1e-9 { throw ApiError("insufficient_balance", "Not enough in the studio balance · add a top-up in Credits") }
        charge(cost)
        hub.emit(ApiEvent(type: "balance", balance: bal))
        try? await Task.sleep(nanoseconds: UInt64(genDelay * 1_000_000_000))
        let t = templates[i]
        let owner = t.ownerId == meId
        let shuffle = req.shuffleSeed ?? TemplateEngine.newShuffleSeed()
        let o = outfits.first { $0.id == req.outfitId }
        let pool = [t.cover?.asset ?? "hero", o?.front?.asset ?? "c_front", "c_tq", "g_front", "face", "g_tq"]
        let now = nowMs()
        let hasProduct = req.productImage != nil && t.acceptsProduct
        var shots: [Take] = []
        for n in 0..<count {
            let seed = Int64.random(in: 1000...999_999)
            let b = try templateBuild(t, modelId: req.modelId, outfitId: req.outfitId, direction: req.direction, shuffleSeed: shuffle, index: n,
                                      lockSeed: req.lockSeed ?? false, seed: seed, hasProduct: hasProduct)
            var take = Take(id: "s_\(shortId())", kind: "shot", index: n + 1, of: count, title: "Template · \(t.name)", label: "Shoot", cost: cost / Double(count),
                            seed: b.seed ?? seed, thumb: .asset(pool[(n + Int(shuffle % 3)) % pool.count]), prompt: owner ? b.fullText : b.visibleText, createdAt: now)
            take.templateId = t.id
            take.templateName = t.name
            take.shuffleSeed = shuffle
            take.variation = owner ? b.variation : nil
            take.refs = req.refs
            shotLayers[take.id] = t.layers
            shots.append(take)
        }
        templates[i].uses += 1
        takes.insert(contentsOf: shots, at: 0)
        return shots
    }

    // MARK: Balance

    public func balance() -> Balance { bal }

    public func topUp(_ req: TopUpRequest) throws -> Balance {
        _ = try recordTopUp(TopUpRecord(amountUsd: req.amount, note: req.note))
        return bal
    }

    public func studioBalance() throws -> StudioBalance {
        guard isOwner else { throw ApiError("owner_only", "Only the studio owner can see the studio balance") }
        let unspent = members.reduce(0.0) { $0 + Double($1.tokens + $1.heldTokens) * bal.tokenUsd }
        let topped = topUps.reduce(0.0) { $0 + $1.amountUsd }
        let balance = ((bal.balance + unspent + bal.heldUsd) * 100).rounded() / 100
        return StudioBalance(balanceUsd: balance, toppedUpUsd: topped, spentUsd: max(0, ((topped - balance) * 100).rounded() / 100), membersCreditUsd: unspent,
                             heldUsd: bal.heldUsd, availableUsd: bal.balance, since: topUps.last?.paidAt ?? 0, needsFirstTopUp: topUps.isEmpty,
                             topUps: Array(topUps.prefix(20)))
    }

    public func recordTopUp(_ req: TopUpRecord) throws -> StudioBalance {
        guard isOwner else { throw ApiError("owner_only", "Only the studio owner can add a top-up") }
        guard req.isValid else { throw ApiError("bad_request", "Enter an amount between $0.01 and $10,000") }
        let now = nowMs()
        if let p = req.paidAt, p > now + 60_000 { throw ApiError("bad_request", "The paid date can't be in the future") }
        topUps.insert(TopUp(id: "tu_" + shortId(), amountUsd: req.amountUsd, note: req.note, paidAt: req.paidAt ?? now, createdAt: now, createdBy: meId), at: 0)
        bal.balance += req.amountUsd
        syncOwner()
        return try studioBalance()
    }

    /// POST /v1/takes/{id}/upscale, as the server: a size that isn't priced is `409 upscale_unavailable`; else a held job at
    /// price × the take's seconds whose take is labelled "Upscale · 2K".
    public func upscale(takeId: String, _ req: UpscaleRequest) throws -> Job {
        guard let t = takes.first(where: { $0.id == takeId }) else { throw ApiError("not_found", "Take not found") }
        guard t.kind == "take" else { throw ApiError("bad_request", "Upscale works on a finished video take") }
        let up = studio.features.video?.upscale
        guard let size = up?.sizes.first(where: { $0.id == req.size }) else { throw ApiError("bad_request", "Invalid size") }
        guard up?.available == true, up?.comingSoon != true, size.available, size.price != nil else { throw ApiError("upscale_unavailable", "Upscale is coming soon") }
        guard let seconds = t.durationSec, seconds > 0, let cost = UpscaleOffer.cost(size, seconds: seconds) else {
            throw ApiError("bad_request", "This take has no length on record · it can’t be upscaled")
        }
        let label = "Upscale · \(size.label)"
        let src = t.jobId.flatMap { id in jobs.first { $0.id == id } }
        let jr = JobRequest(title: "\(t.title) · \(label)", modelId: src?.modelId ?? "", outfitId: src?.outfitId ?? "", clipId: "", engine: "upscale", steps: 1,
                            use: ClipUse.full.rawValue, takes: 1, keepAudio: true, clipSeconds: seconds)
        let total = max(20, seconds * 6)
        var j = Job(id: "jl_" + shortId(), title: jr.title, modelId: jr.modelId, modelName: src?.modelName ?? "", outfitId: jr.outfitId, request: jr, state: "queued",
                    phase: MemberText.waitingToStart, secondsLeft: total, totalSeconds: total, cost: cost, createdAt: nowMs(), prompt: t.prompt, seed: t.seed, thumb: t.thumb)
        j.engineText = label
        suiteTakeSeconds[j.id] = seconds
        return try enqueueSuiteJob(j)
    }

    public func setFailNext(_ fail: Bool) { failNext = fail }

    // MARK: Keep add-on engine ready (owner only)

    /// The warm GPU's clock (ms): real time, sped up by `warmSpeed`.
    private func warmNow() -> Int64 { warmEpoch + Int64(Double(nowMs() - warmEpoch) * warmSpeed) }

    private func warmConfig() -> WarmGpuSim.Config {
        WarmGpuSim.Config(idleMinutes: studio.warmIdleMinutes, maxMinutes: studio.warmMaxMinutes, bootSeconds: warmBoot)
    }

    private func warmView() -> WarmGpu {
        var g = warm.status(now: warmNow())
        g.allowed = isOwner
        return g
    }

    public func warmGpu() throws -> WarmGpu {
        guard isOwner else { throw ApiError("owner_only", "Only the studio owner can keep the add-on engine ready") }
        return warmView()
    }

    public func setWarmGpu(_ req: WarmGpuRequest) throws -> WarmGpu {
        guard isOwner else { throw ApiError("owner_only", "Only the studio owner can keep the add-on engine ready") }
        let now = warmNow()
        if req.extend == true {
            try warm.keepWarm(now: now)
            emitWarm("state")
        } else if req.on == true {
            if !warm.isOn {
                try warm.turnOn(now: now, creditUsd: bal.balance)
                emitWarm("state")
                startWarmClock()
            }
        } else if req.on == false {
            if warm.isOn {
                let usd = warm.turnOff(now: now, reason: "user")
                warmTask?.cancel()
                warmTask = nil
                settleWarm(usd)
                emitWarm("state")
            }
        } else {
            throw ApiError("bad_request", "Send {on: true}, {on: false} or {extend: true}")
        }
        return warmView()
    }

    private func emitWarm(_ event: String, warning: WarmGpuWarning? = nil) {
        hub.emit(ApiEvent(type: "gpu", gpu: warmView(), event: event, warning: warning))
    }

    private func settleWarm(_ usd: Double) {
        guard usd > 0 else { return }
        charge(usd)
        syncOwner()
    }

    private func startWarmClock() {
        warmTask?.cancel()
        warmTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, await self.warmTick() else { return }
            }
        }
    }

    /// One pass of the warm GPU: boot, minute billing (a `tick` event), the warning and auto-off. Returns false once it's off.
    private func warmTick() -> Bool {
        let outs = warm.tick(now: warmNow(), creditUsd: bal.balance, busy: runningId != nil)
        for o in outs {
            switch o {
            case .charge(let usd):
                settleWarm(usd)
                if warm.isOn { emitWarm("tick") }
            case .ready: emitWarm("state")
            case .warning(let w): emitWarm("warning", warning: w)
            case .off: emitWarm("state")
            }
        }
        if !warm.isOn { warmTask = nil }
        return warm.isOn
    }

    // MARK: Helpers

    var photoPricing: PhotoPricing { studio.features.photo ?? .standard }

    func charge(_ cost: Double) {
        bal.balance = max(0, bal.balance - cost)
        bal.month += cost
        bal.today = (bal.today ?? 0) + cost
        bal.videos = Pricing.videosLeft(bal.balance)
        bal = Self.ownerView(bal, members: members)
    }

    func refund(_ cost: Double) {
        bal.balance += cost
        bal.month = max(0, bal.month - cost)
        bal.today = max(0, (bal.today ?? 0) - cost)
        bal.videos = Pricing.videosLeft(bal.balance)
        bal = Self.ownerView(bal, members: members)
    }

    func model(_ id: String) throws -> MuseModel {
        guard let m = models.first(where: { $0.id == id }) else { throw ApiError("not_found", "Model not found") }
        return m
    }

    func replace(_ m: MuseModel) {
        if let i = models.firstIndex(where: { $0.id == m.id }) { models[i] = m }
    }

    // AI suite (workstream 1): hooks for Suite/FakeMuseAPI+Suite.swift. Demo suite shots run on this job pipeline.
    var suiteIsOwner: Bool { signedIn?.role != "member" }
    func suiteClip(_ id: String) -> Clip? { clips[id] }
    func enqueueSuiteJob(_ j: Job) throws -> Job {
        if j.cost > bal.balance + 1e-9 { throw ApiError("insufficient_balance", "Not enough in the studio balance · add a top-up in Credits") }
        charge(j.cost)
        jobs.append(j)
        hub.emit(ApiEvent(type: "balance", balance: bal))
        hub.emit(ApiEvent(type: "job", job: j))
        held = false
        pump()
        return jobs.first { $0.id == j.id } ?? j
    }
    // End AI suite (workstream 1)
}

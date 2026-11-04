import Foundation

/// In-process backend so the app works with no server. Same rules as server/mock and the Android fake:
/// renders run `speed`× faster than real time, the balance is charged when a job is queued and refunded if it fails,
/// and progress arrives as events. Like the desktop prototype there is one GPU: jobs run one after another.
public actor FakeMuseAPI: MuseAPI {
    private let speed: Double
    private let genDelay: Double
    private let storeDir: URL?
    private let hub = EventHub()

    private var models = SampleData.models()
    private var outfits = SampleData.outfits()
    private var jobs: [Job]
    private var takes: [Take]
    private var clips: [String: Clip] = [:]
    private var bal = SampleData.balance()
    private var failNext = false
    /// The seeded queue waits for "Run queue", like the prototype. Any new job starts it.
    private var held = true
    private var runner: Task<Void, Never>?
    private var runningId: String?
    private let loraSeconds: Double
    private var loras: [String: Lora] = [:]
    private var loraTasks: [String: Task<Void, Never>] = [:]
    private var accounts: [String: [Account]] = [:]
    private var posts: [Post] = []

    /// - Parameters:
    ///   - speed: simulation speed; 0 freezes the queue (tests).
    ///   - genDelay: seconds a generation (shoot, outfit, fill angles) takes.
    ///   - storeDir: where uploaded images are copied. nil keeps them in memory as data URLs.
    ///   - loraSeconds: how long LoRA training takes in the demo (~100 min of GPU time; the prototype runs it 120× faster).
    public init(speed: Double = demoSpeed, genDelay: Double = 1.6, storeDir: URL? = nil, loraSeconds: Double = 50) {
        self.speed = speed
        self.genDelay = genDelay
        self.storeDir = storeDir
        self.loraSeconds = loraSeconds
        let now = nowMs()
        jobs = SampleData.jobs(now: now)
        takes = SampleData.takes(now: now)
        for (meta, id) in [(SampleData.sampleMeta, SampleData.sampleClip), (SampleData.badMeta, SampleData.badClip)] {
            clips[id] = Clip(id: id, name: meta.name, durationSec: meta.durationSec, width: meta.width, height: meta.height, fps: meta.fps, checks: ClipRules.checks(meta))
        }
    }

    public nonisolated func events() -> AsyncStream<ApiEvent> { hub.stream() }
    public func setToken(_ token: String?) {}

    // MARK: Auth

    public func signIn(_ req: SignInRequest) async throws -> AuthResponse {
        let email = req.email.trimmingCharacters(in: .whitespaces)
        if email.isEmpty { throw ApiError("bad_request", "Enter your email") }
        return AuthResponse(token: "fake-token", user: User(id: "u1", studioName: Self.studio(from: email), email: email))
    }

    public func signUp(_ req: SignUpRequest) async throws -> AuthResponse {
        if !req.attestAdultRightsOriginal || !req.attestLabelAi { throw ApiError("attestation_required", "Tick both boxes to create your account") }
        let email = req.email.trimmingCharacters(in: .whitespaces)
        if email.isEmpty { throw ApiError("bad_request", "Enter your email") }
        let name = req.studioName.trimmingCharacters(in: .whitespaces)
        return AuthResponse(token: "fake-token", user: User(id: "u1", studioName: name.isEmpty ? Self.studio(from: email) : name, email: email))
    }

    static func studio(from email: String) -> String {
        let n = email.split(separator: "@").first.map(String.init) ?? "My"
        return n.prefix(1).uppercased() + n.dropFirst() + "'s studio"
    }

    // MARK: Models

    public func listModels() -> [MuseModel] { models }

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
        var m = try model(modelId)
        let missing = m.slots.filter { $0.image == nil && !$0.busy }
        let cost = Pricing.fillAnglesCost(missing.count)
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
        let m = try model(modelId)
        var l = loras[modelId] ?? Lora(modelId: modelId)
        if l.isBusy { throw ApiError("busy", "The LoRA is busy · wait for it to finish") }
        if m.filled == 0 { throw ApiError("bad_request", "Add character-sheet shots first") }
        let cost = LoraPricing.setCost
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

    public func listOutfits() -> [Outfit] { outfits }

    public func createOutfit(_ req: CreateOutfitRequest) async throws -> Outfit {
        let cost = req.mode == "own" ? 0 : Pricing.outfitSetCost
        if cost > bal.balance + 1e-9 { throw ApiError("insufficient_balance", "Not enough balance · top up in Credits") }
        let m = try model(req.modelId)
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

    public func uploadImage(name: String, data: Data, mime: String) throws -> ImageRef {
        guard let dir = storeDir else { return ImageRef(url: "data:\(mime);base64,\(data.base64EncodedString())") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = mime.contains("png") ? "png" : mime.contains("heic") ? "heic" : "jpg"
        let f = dir.appendingPathComponent("img_\(shortId()).\(ext)")
        try data.write(to: f)
        return ImageRef(url: f.absoluteString)
    }

    public func uploadClip(_ meta: ClipMeta, file: URL?) -> Clip {
        let id: String
        if meta == SampleData.sampleMeta { id = SampleData.sampleClip } else if meta == SampleData.badMeta { id = SampleData.badClip } else { id = "clip_" + shortId() }
        let c = Clip(id: id, name: meta.name, durationSec: meta.durationSec, width: meta.width, height: meta.height, fps: meta.fps, checks: ClipRules.checks(meta))
        clips[id] = c
        return c
    }

    // MARK: Jobs

    public func listJobs() -> [Job] { jobs.sorted { $0.createdAt > $1.createdAt } }

    public func createJob(_ req: JobRequest) throws -> Job {
        if let clip = clips[req.clipId], !clip.ok { throw ApiError("clip_failed_checks", "Fix the clip first: one person, no watermark, 15s or less") }
        let spec = req.spec
        if spec.engine == .h3 && (spec.steps < Pricing.stepsMin || spec.steps > Pricing.stepsMax) { throw ApiError("bad_request", "Steps must be 4–30") }
        if spec.takes < 1 || spec.takes > Pricing.takesMax { throw ApiError("bad_request", "Takes must be 1–4") }
        let cost = Pricing.totalCost(spec)
        if cost > bal.balance + 1e-9 { throw ApiError("insufficient_balance", "Not enough balance for this render") }
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
        let j = Job(id: "j_" + shortId(), title: req.title, modelId: m.id, modelName: m.name, outfitId: req.outfitId, request: req, state: "queued",
                    totalSteps: p.totalSteps, phase: "Queued", secondsLeft: p.secondsLeft, totalSeconds: Pricing.totalSeconds(spec), cost: cost,
                    createdAt: nowMs(), prompt: prompt, seed: seed, thumb: o?.front ?? m.cover)
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

    /// Starts the next queued job if the GPU is free.
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
                jobs[i].phase = "Failed at step \(p.step)"
                jobs[i].refunded = cur.cost
                jobs[i].error = "The GPU disconnected at step \(p.step)."
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
        let label = j.engine == .viggle ? "Fast" : "\(j.request.steps) steps"
        return (1...n).map { k in
            let thumb = pool.isEmpty ? (j.thumb ?? .asset("g_front")) : pool[(k - 1) % pool.count]
            return Take(id: "t_\(j.id)_\(k)", jobId: j.id, index: k, of: n, title: j.title, label: label, engineLabel: j.engineLabel,
                        cost: j.cost / Double(n), seed: j.seed + Int64(k - 1), thumb: thumb, prompt: j.prompt, createdAt: nowMs())
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
        if Pricing.shootCost > bal.balance + 1e-9 { throw ApiError("insufficient_balance", "Not enough balance · top up in Credits") }
        charge(Pricing.shootCost)
        hub.emit(ApiEvent(type: "balance", balance: bal))
        try? await Task.sleep(nanoseconds: UInt64(genDelay * 1_000_000_000))
        let o = outfits.first { $0.id == req.outfitId }
        let pool = [o?.front?.asset ?? "c_front", "c_tq", "g_front", "hero"]
        let label = req.scene.components(separatedBy: "·").first?.trimmingCharacters(in: .whitespaces) ?? req.scene
        let t = nowMs()
        let count = max(1, min(8, req.count))
        let shots = (0..<count).map { n in
            Take(id: "s_\(shortId())", kind: "shot", index: n + 1, of: count, title: "Shoot · \(label.prefix(28))", label: "Shoot", cost: Pricing.shootCost / Double(count),
                 seed: req.seed ?? Int64.random(in: 1000...99999), thumb: .asset(pool[n % pool.count]), prompt: req.prompt, createdAt: t)
        }
        takes.insert(contentsOf: shots, at: 0)
        return shots
    }

    // MARK: Balance

    public func balance() -> Balance { bal }

    public func topUp(_ req: TopUpRequest) throws -> Balance {
        if req.amount <= 0 { throw ApiError("bad_request", "Pick an amount") }
        bal.balance += req.amount
        hub.emit(ApiEvent(type: "balance", balance: bal))
        return bal
    }

    public func setFailNext(_ fail: Bool) { failNext = fail }

    // MARK: Helpers

    private func charge(_ cost: Double) {
        bal.balance = max(0, bal.balance - cost)
        bal.month += cost
        bal.today = (bal.today ?? 0) + cost
        bal.videos = Pricing.videosLeft(bal.balance)
    }

    private func refund(_ cost: Double) {
        bal.balance += cost
        bal.month = max(0, bal.month - cost)
        bal.today = max(0, (bal.today ?? 0) - cost)
        bal.videos = Pricing.videosLeft(bal.balance)
    }

    private func model(_ id: String) throws -> MuseModel {
        guard let m = models.first(where: { $0.id == id }) else { throw ApiError("not_found", "Model not found") }
        return m
    }

    private func replace(_ m: MuseModel) {
        if let i = models.firstIndex(where: { $0.id == m.id }) { models[i] = m }
    }
}

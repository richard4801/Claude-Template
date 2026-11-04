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

    /// - Parameters:
    ///   - speed: simulation speed; 0 freezes the queue (tests).
    ///   - genDelay: seconds a generation (shoot, outfit, fill angles) takes.
    ///   - storeDir: where uploaded images are copied. nil keeps them in memory as data URLs.
    public init(speed: Double = demoSpeed, genDelay: Double = 1.6, storeDir: URL? = nil) {
        self.speed = speed
        self.genDelay = genDelay
        self.storeDir = storeDir
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

    // MARK: Outfits

    public func listOutfits() -> [Outfit] { outfits }

    public func createOutfit(_ req: CreateOutfitRequest) async throws -> Outfit {
        let cost = req.mode == "own" ? 0 : Pricing.outfitSetCost
        if cost > bal.balance + 1e-9 { throw ApiError("insufficient_balance", "Not enough balance · top up in Credits") }
        let m = try model(req.modelId)
        charge(cost)
        let name = req.name.trimmingCharacters(in: .whitespaces)
        let label = name.isEmpty ? (req.description.isEmpty ? "New outfit" : String(req.description.prefix(28))) : name
        let prompt = PromptEngine.outfitAngle(identity: m.promptIdentity, outfit: req.description.isEmpty ? label : req.description,
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
        let prompt = PromptEngine.video(VideoPromptInput(identity: m.promptIdentity, outfitName: o?.name ?? "outfit",
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

import Foundation

// Wire types shared by both MuseAPI implementations and the mock server (plans/api.md).
// Field names match the Android client (android/app/.../data/Models.kt) so both apps speak the same JSON.
// Decoding is lenient: a missing key falls back to the same default the Kotlin types use.

extension KeyedDecodingContainer {
    func v<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }

    func o<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

/// An image: a bundled sample (`asset`, e.g. "g_front") or a URL the client can load (`url`, file:// or http).
public struct ImageRef: Codable, Hashable, Sendable {
    public var asset: String?
    public var url: String?

    public init(asset: String? = nil, url: String? = nil) {
        self.asset = asset
        self.url = url
    }

    public static func asset(_ k: String) -> ImageRef { ImageRef(asset: k) }
}

public struct User: Codable, Hashable, Sendable {
    public var id: String
    public var studioName: String
    public var email: String

    public init(id: String, studioName: String, email: String) {
        self.id = id
        self.studioName = studioName
        self.email = email
    }
}

public struct AuthResponse: Codable, Sendable {
    public var token: String
    public var user: User

    public init(token: String, user: User) {
        self.token = token
        self.user = user
    }
}

public struct SignInRequest: Codable, Sendable {
    public var email: String
    public var password: String

    public init(email: String, password: String) {
        self.email = email
        self.password = password
    }
}

/// Both attestations are required and unticked by default. Consent otherwise lives only in the Terms.
public struct SignUpRequest: Codable, Sendable {
    public var studioName: String
    public var email: String
    public var password: String
    public var attestAdultRightsOriginal: Bool
    public var attestLabelAi: Bool

    public init(studioName: String, email: String, password: String, attestAdultRightsOriginal: Bool, attestLabelAi: Bool) {
        self.studioName = studioName
        self.email = email
        self.password = password
        self.attestAdultRightsOriginal = attestAdultRightsOriginal
        self.attestLabelAi = attestLabelAi
    }
}

/// One of the 6 character-sheet slots. source: "upload" (yours) or "generated" (AI).
public struct SheetSlot: Codable, Hashable, Sendable {
    public var key: String
    public var image: ImageRef?
    public var source: String
    public var busy: Bool

    public init(key: String, image: ImageRef? = nil, source: String = "upload", busy: Bool = false) {
        self.key = key
        self.image = image
        self.source = source
        self.busy = busy
    }

    enum CodingKeys: String, CodingKey { case key, image, source, busy }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        image = c.o(.image)
        source = c.v(.source, "upload")
        busy = c.v(.busy, false)
    }

    public var isAI: Bool { source == "generated" }
}

/// A character ("model") with its character sheet, outfits and never-add list.
public struct MuseModel: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var age: Int
    public var niche: String
    public var look: String
    public var neverAdd: [String]
    public var slots: [SheetSlot]
    public var outfitIds: [String]
    /// Desktop-only profile fields (not in plans/api.md yet; servers that don't know them ignore them).
    public var personality: String
    public var notes: String

    public init(id: String, name: String, age: Int = 24, niche: String, look: String = "", neverAdd: [String] = [], slots: [SheetSlot] = [],
                outfitIds: [String] = [], personality: String = "", notes: String = "") {
        self.id = id
        self.name = name
        self.age = age
        self.niche = niche
        self.look = look
        self.neverAdd = neverAdd
        self.slots = slots
        self.outfitIds = outfitIds
        self.personality = personality
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey { case id, name, age, niche, look, neverAdd, slots, outfitIds, personality, notes }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.v(.name, "")
        age = c.v(.age, 24)
        niche = c.v(.niche, "")
        look = c.v(.look, "")
        neverAdd = c.v(.neverAdd, [])
        slots = c.v(.slots, [])
        outfitIds = c.v(.outfitIds, [])
        personality = c.v(.personality, "")
        notes = c.v(.notes, "")
    }

    public var filled: Int { slots.filter { $0.image != nil && !$0.busy }.count }
    public var isLocked: Bool { filled == 6 }
    public var hasBothFaces: Bool { slots.filter { ($0.key == "face" || $0.key == "profile") && $0.image != nil }.count == 2 }
    public var isDraft: Bool { filled == 0 }
    public func slot(_ key: String) -> SheetSlot? { slots.first { $0.key == key } }
    public var cover: ImageRef? { slot("face")?.image ?? slots.first { $0.image != nil }?.image }
    public var initial: String { String(name.prefix(1)).uppercased() }
    public var shortName: String { name.split(separator: " ").first.map(String.init) ?? name }

    public var promptIdentity: PromptIdentity {
        PromptIdentity(name: name, look: look.isEmpty ? "\(age)-year-old woman" : look, referenceCount: max(1, filled), neverAdd: neverAdd)
    }
}

public struct CreateModelRequest: Codable, Sendable {
    public var name: String
    public var age: Int
    public var niche: String
    public var personality: String
    public var notes: String

    public init(name: String, age: Int, niche: String, personality: String = "", notes: String = "") {
        self.name = name
        self.age = age
        self.niche = niche
        self.personality = personality
        self.notes = notes
    }
}

public struct SetSlotRequest: Codable, Sendable {
    public var image: ImageRef?
    public var source: String

    public init(image: ImageRef?, source: String = "upload") {
        self.image = image
        self.source = source
    }
}

/// Outfit set: front, ¾, side, back. mode: describe | photo | own. state: ready | generating | preview.
public struct Outfit: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var modelId: String
    public var name: String
    public var mode: String
    public var description: String
    public var angles: [ImageRef?]
    public var state: String
    public var prompt: String

    public init(id: String, modelId: String, name: String, mode: String = "describe", description: String = "", angles: [ImageRef?] = [nil, nil, nil, nil],
                state: String = "ready", prompt: String = "") {
        self.id = id
        self.modelId = modelId
        self.name = name
        self.mode = mode
        self.description = description
        self.angles = angles
        self.state = state
        self.prompt = prompt
    }

    enum CodingKeys: String, CodingKey { case id, modelId, name, mode, description, angles, state, prompt }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        modelId = c.v(.modelId, "")
        name = c.v(.name, "")
        mode = c.v(.mode, "describe")
        description = c.v(.description, "")
        angles = c.v(.angles, [nil, nil, nil, nil])
        state = c.v(.state, "ready")
        prompt = c.v(.prompt, "")
    }

    public var front: ImageRef? { angles.first ?? nil }
}

public struct CreateOutfitRequest: Codable, Sendable {
    public var modelId: String
    public var name: String
    public var mode: String
    public var description: String
    public var images: [ImageRef]

    public init(modelId: String, name: String, mode: String, description: String = "", images: [ImageRef] = []) {
        self.modelId = modelId
        self.name = name
        self.mode = mode
        self.description = description
        self.images = images
    }
}

/// status: good | bad | info
public struct ClipCheck: Codable, Hashable, Sendable {
    public var label: String
    public var value: String
    public var status: String
    public var fix: String?

    public init(label: String, value: String, status: String, fix: String? = nil) {
        self.label = label
        self.value = value
        self.status = status
        self.fix = fix
    }
}

/// A source clip with its checks.
public struct Clip: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var durationSec: Double
    public var width: Int
    public var height: Int
    public var fps: Int
    public var checks: [ClipCheck]
    public var thumb: ImageRef?

    public init(id: String, name: String, durationSec: Double, width: Int, height: Int, fps: Int, checks: [ClipCheck], thumb: ImageRef? = nil) {
        self.id = id
        self.name = name
        self.durationSec = durationSec
        self.width = width
        self.height = height
        self.fps = fps
        self.checks = checks
        self.thumb = thumb
    }

    enum CodingKeys: String, CodingKey { case id, name, durationSec, width, height, fps, checks, thumb }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.v(.name, "")
        durationSec = c.v(.durationSec, 0)
        width = c.v(.width, 0)
        height = c.v(.height, 0)
        fps = c.v(.fps, 30)
        checks = c.v(.checks, [])
        thumb = c.o(.thumb)
    }

    public var ok: Bool { !checks.contains { $0.status == "bad" } }
}

/// What the client knows about a clip before upload (read with AVFoundation on the Mac; people and watermark are detected server-side).
public struct ClipMeta: Codable, Hashable, Sendable {
    public var name: String
    public var durationSec: Double
    public var width: Int
    public var height: Int
    public var fps: Int
    public var people: Int
    public var watermark: String?
    public var talking: Bool

    public init(name: String, durationSec: Double, width: Int, height: Int, fps: Int, people: Int = 1, watermark: String? = nil, talking: Bool = false) {
        self.name = name
        self.durationSec = durationSec
        self.width = width
        self.height = height
        self.fps = fps
        self.people = people
        self.watermark = watermark
        self.talking = talking
    }
}

public struct JobRequest: Codable, Hashable, Sendable {
    public var title: String
    public var modelId: String
    public var outfitId: String
    public var clipId: String
    public var engine: String
    public var steps: Int
    public var use: String
    public var takes: Int
    public var keepAudio: Bool
    public var lipSync: Bool
    public var background: String
    public var backgroundMotion: String
    public var clipSeconds: Double?

    public init(title: String, modelId: String, outfitId: String, clipId: String, engine: String = Engine.h3.rawValue, steps: Int = 10,
                use: String = ClipUse.first.rawValue, takes: Int = 1, keepAudio: Bool = true, lipSync: Bool = false,
                background: String = "keep", backgroundMotion: String = "subtle", clipSeconds: Double? = nil) {
        self.title = title
        self.modelId = modelId
        self.outfitId = outfitId
        self.clipId = clipId
        self.engine = engine
        self.steps = steps
        self.use = use
        self.takes = takes
        self.keepAudio = keepAudio
        self.lipSync = lipSync
        self.background = background
        self.backgroundMotion = backgroundMotion
        self.clipSeconds = clipSeconds
    }

    enum CodingKeys: String, CodingKey { case title, modelId, outfitId, clipId, engine, steps, use, takes, keepAudio, lipSync, background, backgroundMotion, clipSeconds }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        title = c.v(.title, "")
        modelId = c.v(.modelId, "")
        outfitId = c.v(.outfitId, "")
        clipId = c.v(.clipId, "")
        engine = c.v(.engine, "h3")
        steps = c.v(.steps, 10)
        use = c.v(.use, "first")
        takes = c.v(.takes, 1)
        keepAudio = c.v(.keepAudio, true)
        lipSync = c.v(.lipSync, false)
        background = c.v(.background, "keep")
        backgroundMotion = c.v(.backgroundMotion, "subtle")
        clipSeconds = c.o(.clipSeconds)
    }

    public var spec: RenderSpec {
        RenderSpec(engine: Engine(id: engine), use: ClipUse(id: use), steps: steps, lipSync: lipSync, takes: takes, clipSeconds: clipSeconds)
    }
}

/// A render job. state: queued | running | done | failed. progress 0…100; step/totalSteps are per take;
/// phase is the human line ("step 12/20 · ~6 min left").
public struct Job: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var modelId: String
    public var modelName: String
    public var outfitId: String
    public var request: JobRequest
    public var state: String
    public var progress: Double
    public var take: Int
    public var step: Int
    public var totalSteps: Int
    public var phase: String
    public var secondsLeft: Double
    public var totalSeconds: Double
    public var cost: Double
    public var refunded: Double
    public var error: String?
    public var createdAt: Int64
    public var finishedAt: Int64?
    public var prompt: String
    public var seed: Int64
    public var thumb: ImageRef?

    public init(id: String, title: String, modelId: String, modelName: String, outfitId: String, request: JobRequest, state: String, progress: Double = 0,
                take: Int = 1, step: Int = 0, totalSteps: Int = 10, phase: String = "", secondsLeft: Double = 0, totalSeconds: Double = 0, cost: Double = 0,
                refunded: Double = 0, error: String? = nil, createdAt: Int64 = 0, finishedAt: Int64? = nil, prompt: String = "", seed: Int64 = 42, thumb: ImageRef? = nil) {
        self.id = id
        self.title = title
        self.modelId = modelId
        self.modelName = modelName
        self.outfitId = outfitId
        self.request = request
        self.state = state
        self.progress = progress
        self.take = take
        self.step = step
        self.totalSteps = totalSteps
        self.phase = phase
        self.secondsLeft = secondsLeft
        self.totalSeconds = totalSeconds
        self.cost = cost
        self.refunded = refunded
        self.error = error
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.prompt = prompt
        self.seed = seed
        self.thumb = thumb
    }

    enum CodingKeys: String, CodingKey {
        case id, title, modelId, modelName, outfitId, request, state, progress, take, step, totalSteps, phase, secondsLeft, totalSeconds, cost, refunded, error,
             createdAt, finishedAt, prompt, seed, thumb
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = c.v(.title, "")
        modelId = c.v(.modelId, "")
        modelName = c.v(.modelName, "")
        outfitId = c.v(.outfitId, "")
        request = c.v(.request, JobRequest(title: "", modelId: "", outfitId: "", clipId: ""))
        state = c.v(.state, "queued")
        progress = c.v(.progress, 0)
        take = c.v(.take, 1)
        step = c.v(.step, 0)
        totalSteps = c.v(.totalSteps, 10)
        phase = c.v(.phase, "")
        secondsLeft = c.v(.secondsLeft, 0)
        totalSeconds = c.v(.totalSeconds, 0)
        cost = c.v(.cost, 0)
        refunded = c.v(.refunded, 0)
        error = c.o(.error)
        createdAt = c.v(.createdAt, 0)
        finishedAt = c.o(.finishedAt)
        prompt = c.v(.prompt, "")
        seed = c.v(.seed, 42)
        thumb = c.o(.thumb)
    }

    public var engine: Engine { Engine(id: request.engine) }
    /// "Standard" / "Fast · beta".
    public var engineName: String { engine.label }
    /// "Standard · 10 steps" / "Fast · beta".
    public var engineLabel: String { engine == .viggle ? "Fast · beta" : "Standard · \(request.steps) steps" }
    public var isActive: Bool { state == "running" || state == "queued" }
    public var isRunning: Bool { state == "running" }
    public var isQueued: Bool { state == "queued" }
    public var isDone: Bool { state == "done" }
    public var isFailed: Bool { state == "failed" }
    public var lengthSec: Double { request.spec.lengthSec }
}

/// One take of a job, or one photoshoot still. status: test | final. kind: take | shot.
public struct Take: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: String
    public var jobId: String?
    public var index: Int
    public var of: Int
    public var title: String
    public var label: String
    public var engineLabel: String
    public var cost: Double
    public var seed: Int64
    public var status: String
    public var thumb: ImageRef
    public var prompt: String
    public var createdAt: Int64

    public init(id: String, kind: String = "take", jobId: String? = nil, index: Int = 1, of: Int = 1, title: String, label: String, engineLabel: String = "",
                cost: Double = 0, seed: Int64 = 0, status: String = "test", thumb: ImageRef, prompt: String = "", createdAt: Int64 = 0) {
        self.id = id
        self.kind = kind
        self.jobId = jobId
        self.index = index
        self.of = of
        self.title = title
        self.label = label
        self.engineLabel = engineLabel
        self.cost = cost
        self.seed = seed
        self.status = status
        self.thumb = thumb
        self.prompt = prompt
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case id, kind, jobId, index, of, title, label, engineLabel, cost, seed, status, thumb, prompt, createdAt }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = c.v(.kind, "take")
        jobId = c.o(.jobId)
        index = c.v(.index, 1)
        of = c.v(.of, 1)
        title = c.v(.title, "")
        label = c.v(.label, "")
        engineLabel = c.v(.engineLabel, "")
        cost = c.v(.cost, 0)
        seed = c.v(.seed, 0)
        status = c.v(.status, "test")
        thumb = c.v(.thumb, ImageRef())
        prompt = c.v(.prompt, "")
        createdAt = c.v(.createdAt, 0)
    }

    public var isFinal: Bool { status == "final" }
    public var isVideo: Bool { kind == "take" }
    /// Gallery caption: "Living-room dance · 10 steps".
    public var caption: String {
        if kind == "shot" { return title.isEmpty ? label : "\(title) \(index)" }
        let t = of > 1 ? "\(title) · take \(index)" : title
        return label.isEmpty ? t : "\(t) · \(label)"
    }
}

public struct SetTakeStatusRequest: Codable, Sendable {
    public var status: String
    public init(status: String) { self.status = status }
}

public struct ShootRequest: Codable, Sendable {
    public var modelId: String
    public var outfitId: String
    public var scene: String
    public var prompt: String
    public var seed: Int64?
    public var count: Int

    public init(modelId: String, outfitId: String, scene: String, prompt: String, seed: Int64? = nil, count: Int = 4) {
        self.modelId = modelId
        self.outfitId = outfitId
        self.scene = scene
        self.prompt = prompt
        self.seed = seed
        self.count = count
    }
}

public struct Balance: Codable, Hashable, Sendable {
    public var balance: Double
    public var month: Double
    public var perJobLimit: Double
    public var perDayLimit: Double
    public var videos: Int
    /// Spent today. Not in the Android type; nil when the server doesn't send it (the app then sums today's jobs).
    public var today: Double?

    public init(balance: Double, month: Double, perJobLimit: Double = Pricing.perJobCap, perDayLimit: Double = Pricing.perDayCap, videos: Int = 0, today: Double? = nil) {
        self.balance = balance
        self.month = month
        self.perJobLimit = perJobLimit
        self.perDayLimit = perDayLimit
        self.videos = videos
        self.today = today
    }

    enum CodingKeys: String, CodingKey { case balance, month, perJobLimit, perDayLimit, videos, today }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        balance = c.v(.balance, 0)
        month = c.v(.month, 0)
        perJobLimit = c.v(.perJobLimit, Pricing.perJobCap)
        perDayLimit = c.v(.perDayLimit, Pricing.perDayCap)
        videos = c.v(.videos, 0)
        today = c.o(.today)
    }
}

public struct TopUpRequest: Codable, Sendable {
    public var amount: Double
    public var method: String
    public init(amount: Double, method: String = "card") {
        self.amount = amount
        self.method = method
    }
}

public struct FillAnglesResponse: Codable, Sendable {
    public var model: MuseModel
    public var cost: Double
    public init(model: MuseModel, cost: Double) {
        self.model = model
        self.cost = cost
    }
}

/// Server-sent event on /v1/events. type: job | balance | model | outfit
public struct ApiEvent: Codable, Sendable {
    public var type: String
    public var job: Job?
    public var balance: Balance?
    public var model: MuseModel?
    public var outfit: Outfit?
    public var takes: [Take]

    public init(type: String, job: Job? = nil, balance: Balance? = nil, model: MuseModel? = nil, outfit: Outfit? = nil, takes: [Take] = []) {
        self.type = type
        self.job = job
        self.balance = balance
        self.model = model
        self.outfit = outfit
        self.takes = takes
    }

    enum CodingKeys: String, CodingKey { case type, job, balance, model, outfit, takes }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        type = c.v(.type, "")
        job = c.o(.job)
        balance = c.o(.balance)
        model = c.o(.model)
        outfit = c.o(.outfit)
        takes = c.v(.takes, [])
    }
}

public struct DevFailRequest: Codable, Sendable {
    public var failNext: Bool
    public init(failNext: Bool) { self.failNext = failNext }
}

public struct ErrorBody: Codable, Sendable {
    public var error: String
    public var code: String?
}

/// An error the UI can show as-is. `code` matches the server's error codes (insufficient_balance, clip_failed_checks, …).
public struct ApiError: Error, LocalizedError, Equatable, Sendable {
    public var code: String
    public var message: String
    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
    public var errorDescription: String? { message }
}

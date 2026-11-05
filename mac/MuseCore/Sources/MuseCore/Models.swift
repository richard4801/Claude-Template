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
    /// "owner" | "member" from the real API (`server/api`). nil from server/mock, which has no roles.
    public var role: String?

    public init(id: String, studioName: String, email: String, role: String? = nil) {
        self.id = id
        self.studioName = studioName
        self.email = email
        self.role = role
    }

    enum CodingKeys: String, CodingKey { case id, studioName, email, role }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = c.v(.id, "")
        studioName = c.v(.studioName, "")
        email = c.v(.email, "")
        role = c.o(.role)
    }

    public var isOwner: Bool { role == "owner" }
    public var isMember: Bool { role == "member" }
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
    /// The invite code from the studio owner ("MUSE-7KQ2-XW9P-4HTD"). The real API needs it (`invite_required`); nil is left out of the JSON.
    public var inviteCode: String?
    public var attestAdultRightsOriginal: Bool
    public var attestLabelAi: Bool

    public init(studioName: String, email: String, password: String, inviteCode: String? = nil, attestAdultRightsOriginal: Bool, attestLabelAi: Bool) {
        self.studioName = studioName
        self.email = email
        self.password = password
        let code = inviteCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.inviteCode = (code?.isEmpty ?? true) ? nil : code
        self.attestAdultRightsOriginal = attestAdultRightsOriginal
        self.attestLabelAi = attestLabelAi
    }
}

/// One of the 7 character-sheet slots. source: "upload" (yours) or "generated" (AI).
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
    /// Optional profile fields (plans/api.md: "Model also carries optional { personality, notes }").
    public var personality: String
    public var notes: String
    /// Archived models vanish from every list and picker; the owner restores them in Settings → Archived models.
    public var archived: Bool
    public var archivedAt: Int64?

    public init(id: String, name: String, age: Int = 24, niche: String, look: String = "", neverAdd: [String] = [], slots: [SheetSlot] = [],
                outfitIds: [String] = [], personality: String = "", notes: String = "", archived: Bool = false, archivedAt: Int64? = nil) {
        self.archived = archived
        self.archivedAt = archivedAt
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

    enum CodingKeys: String, CodingKey { case id, name, age, niche, look, neverAdd, slots, outfitIds, personality, notes, archived, archivedAt }
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
        archived = c.v(.archived, false)
        archivedAt = c.o(.archivedAt) ?? (c.o(.archivedAt) as Double?).map { Int64($0) }
    }

    /// The sheet's filled slots (what Enhance and Dress up work on).
    public var filledSlots: [SheetSlot] { slots.filter { $0.image != nil && !$0.busy } }

    public var filled: Int { slots.filter { $0.image != nil && !$0.busy }.count }
    /// All six core slots filled (the face ¾ close-up is optional).
    public var isLocked: Bool { SheetAngle.core.allSatisfy { k in slots.contains { $0.key == k.rawValue && $0.image != nil && !$0.busy } } }
    public var hasBothFaces: Bool { slots.filter { ($0.key == "face" || $0.key == "profile") && $0.image != nil }.count == 2 }
    public var isDraft: Bool { filled == 0 }
    public func slot(_ key: String) -> SheetSlot? { slots.first { $0.key == key } }
    public var cover: ImageRef? { slot("face")?.image ?? slots.first { $0.image != nil }?.image }
    public var initial: String { String(name.prefix(1)).uppercased() }
    public var shortName: String { name.split(separator: " ").first.map(String.init) ?? name }

    public var promptIdentity: PromptIdentity {
        PromptIdentity(name: name, look: look.isEmpty ? "\(age)-year-old woman" : look, referenceCount: max(1, filled), neverAdd: neverAdd)
    }

    /// The prompt identity with the model's Identity LoRA when it is trained and switched on.
    public func promptIdentity(lora: Lora?) -> PromptIdentity {
        var id = promptIdentity
        id.lora = lora?.promptToken(modelName: name)
        return id
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
    /// Dress up outfits: face, face ¾ and profile close-ups with the accessories (nil where rejected or missing).
    public var faces: [ImageRef?]?

    public init(id: String, modelId: String, name: String, mode: String = "describe", description: String = "", angles: [ImageRef?] = [nil, nil, nil, nil],
                state: String = "ready", prompt: String = "", faces: [ImageRef?]? = nil) {
        self.faces = faces
        self.id = id
        self.modelId = modelId
        self.name = name
        self.mode = mode
        self.description = description
        self.angles = angles
        self.state = state
        self.prompt = prompt
    }

    enum CodingKeys: String, CodingKey { case id, modelId, name, mode, description, angles, state, prompt, faces }
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
        faces = c.o(.faces)
    }

    public var front: ImageRef? { angles.first ?? nil }
    /// Made with Dress up (plans/api.md "Model tools" §6).
    public var isDressUp: Bool { mode == "dressup" }
}

public struct CreateOutfitRequest: Codable, Sendable {
    public var modelId: String
    public var name: String
    public var mode: String
    public var description: String
    public var images: [ImageRef]
    /// Owner only: per-run model override (step → "owner/name").
    public var models: ModelOverrides?

    public init(modelId: String, name: String, mode: String, description: String = "", images: [ImageRef] = [], models: ModelOverrides? = nil) {
        self.models = (models?.isEmpty ?? true) ? nil : models
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
    // Prompt scripts (workstream 4): talking detection, the "Performer is speaking" switch's starting value.
    public var audio: ClipAudio?

    public init(id: String, name: String, durationSec: Double, width: Int, height: Int, fps: Int, checks: [ClipCheck], thumb: ImageRef? = nil,
                audio: ClipAudio? = nil) {
        self.audio = audio
        self.id = id
        self.name = name
        self.durationSec = durationSec
        self.width = width
        self.height = height
        self.fps = fps
        self.checks = checks
        self.thumb = thumb
    }

    enum CodingKeys: String, CodingKey { case id, name, durationSec, width, height, fps, checks, thumb, audio }
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
        audio = c.o(.audio)
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
    /// true parks the job as `queued` (not charged) until POST /v1/queue/run. nil/false starts it at once.
    public var queue: Bool?
    /// engine "replicate" only: draft | standard | hd (left out of the JSON otherwise).
    public var quality: String?
    // Prompt scripts (workstream 4): the studio's "Performer is speaking" switch (nil = the clip's detection). On a job the server
    // sends the resolved value and where it came from (switch | upload | detected | default).
    public var speaking: Bool?
    public var speakingSource: String?

    public init(title: String, modelId: String, outfitId: String, clipId: String, engine: String = Engine.h3.rawValue, steps: Int = 10,
                use: String = ClipUse.first.rawValue, takes: Int = 1, keepAudio: Bool = true, lipSync: Bool = false,
                background: String = "keep", backgroundMotion: String = "subtle", clipSeconds: Double? = nil, queue: Bool? = nil, quality: String? = nil,
                speaking: Bool? = nil) {
        self.speaking = speaking
        self.queue = queue
        self.quality = quality
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

    enum CodingKeys: String, CodingKey {
        case title, modelId, outfitId, clipId, engine, steps, use, takes, keepAudio, lipSync, background, backgroundMotion, clipSeconds, queue, quality
        case speaking, speakingSource // prompt scripts (workstream 4)
    }
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
        queue = c.o(.queue)
        quality = c.o(.quality)
        speaking = c.o(.speaking)
        speakingSource = c.o(.speakingSource)
    }

    /// A Draft / Standard / HD request: `{engine: "replicate", quality}`, always the whole clip, no lip sync or background photo.
    public static func replicate(title: String, modelId: String, outfitId: String, clipId: String, quality: VideoQuality, takes: Int = 1, keepAudio: Bool = true,
                                 clipSeconds: Double? = nil) -> JobRequest {
        JobRequest(title: title, modelId: modelId, outfitId: outfitId, clipId: clipId, engine: Engine.replicate.rawValue, steps: Pricing.stepsDefault,
                   use: ClipUse.full.rawValue, takes: takes, keepAudio: keepAudio, lipSync: false, background: "keep", clipSeconds: clipSeconds,
                   quality: quality.replicateOrDefault.rawValue)
    }

    /// An Edit or Fast · beta request as members make it: the whole clip and the default steps (plans/api.md "App clean-up" §2).
    /// Lip sync and a new background photo are Edit only.
    public static func addOn(_ q: VideoQuality, title: String, modelId: String, outfitId: String, clipId: String, takes: Int = 1, keepAudio: Bool = true,
                             lipSync: Bool = false, background: String = "keep", backgroundMotion: String = "subtle", clipSeconds: Double? = nil) -> JobRequest {
        let edit = q != .fast
        return JobRequest(title: title, modelId: modelId, outfitId: outfitId, clipId: clipId, engine: edit ? Engine.h3.rawValue : Engine.viggle.rawValue,
                          steps: Pricing.stepsDefault, use: ClipUse.full.rawValue, takes: takes, keepAudio: keepAudio, lipSync: edit && lipSync,
                          background: edit ? background : "keep", backgroundMotion: backgroundMotion, clipSeconds: clipSeconds)
    }

    public var videoQuality: VideoQuality { VideoQuality.of(engine: Engine(id: engine), quality: quality) }
    /// `engine: "upscale"` (an Upscale job on a finished take, once it ships).
    public var isUpscale: Bool { engine == "upscale" }

    /// `pricePerSec`: the server's price for a replicate quality (nil = the contract default).
    public func spec(pricePerSec: Double? = nil) -> RenderSpec {
        RenderSpec(engine: Engine(id: engine), use: ClipUse(id: use), steps: steps, lipSync: lipSync, takes: takes, clipSeconds: clipSeconds,
                   quality: videoQuality, pricePerSec: pricePerSec)
    }

    public var spec: RenderSpec { spec() }
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
    /// Waiting in line (real API): place in line and seconds until it starts.
    public var queuePosition: Int?
    public var etaSeconds: Double?
    /// Retired 2026-11-04: nothing pauses on a provider balance any more. Decoded and ignored.
    public var blocked: String?
    /// The add-on engine's start-up charged with this job: owner ledger only, never shown to members.
    public var warmupCost: Double?
    /// Who started it (real API).
    public var userId: String?
    /// It ran while the owner kept the add-on engine ready (its time is on that ledger line). Never shown to members.
    public var warm: Bool?
    /// The server's `engineLabel` ("Draft · 768P", "Edit"…). nil on older servers: `engineLabel` builds it.
    public var engineText: String?
    /// provider_refused | provider_failed | provider_rate_limited | provider_timeout | provider_out_of_credit. Never shown.
    public var errorCode: String?
    /// Replicate, done: output seconds Replicate billed, summed over takes.
    public var billedSeconds: Double?

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
             createdAt, finishedAt, prompt, seed, thumb, queuePosition, etaSeconds, blocked, warmupCost, userId, warm, errorCode, billedSeconds
        case engineText = "engineLabel"
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
        queuePosition = c.o(.queuePosition)
        etaSeconds = c.o(.etaSeconds)
        blocked = c.o(.blocked)
        warmupCost = c.o(.warmupCost)
        userId = c.o(.userId)
        warm = c.o(.warm)
        engineText = c.o(.engineText)
        errorCode = c.o(.errorCode)
        billedSeconds = c.o(.billedSeconds)
    }

    /// Waiting in line before it starts (real API): `queuePosition` is set and nothing has rendered yet.
    public var isWaiting: Bool { isActive && step == 0 && queuePosition != nil }
    /// "Waiting to start" / "#2 in line" (+ " · about 9 min") while it waits.
    public var waitLine: String? {
        guard isActive, let pos = queuePosition else { return nil }
        return (pos <= 1 ? MemberText.waitingToStart : "#\(pos) in line") + timeTail
    }
    public static func duration(_ s: Double) -> String { s >= 60 ? "~\(Int((s / 60).rounded(.up))) min" : "~\(Int(s.rounded(.up)))s" }

    /// " · about 2 min" from the ETA (or seconds left), or "" when there's none.
    var timeTail: String {
        let left = etaSeconds ?? secondsLeft
        return left > 0 ? " · about \(Job.aboutTime(left))" : ""
    }

    /// "2 min", "a minute" (whole minutes, JavaScript rounding, at least 1).
    public static func aboutTime(_ seconds: Double) -> String {
        seconds < 60 ? "a minute" : "\(max(1, Pricing.jsRound(seconds / 60))) min"
    }

    /// What it's doing, without its time: the server's phase cut before " · ~6 min left" ("Rendering", "take 2/3 · Finishing").
    /// Older servers' "step 3/10", "Starting GPU" or "Waiting for Replicate" read as Rendering / Getting ready / Waiting to start.
    public var statusLine: String {
        if isWaiting { return queuePosition.map { $0 <= 1 ? MemberText.waitingToStart : "#\($0) in line" } ?? MemberText.waitingToStart }
        switch state {
        case "done": return "Done"
        case "failed": return "Failed"
        case "queued": return "Queued"
        default: return Job.memberPhase(phase)
        }
    }

    /// The queue's line (plans/api.md "App clean-up" §2): "Rendering · about 2 min · $0.14", "Waiting to start · $0.14",
    /// "#2 in line · about 9 min · $0.14".
    public var progressLine: String {
        let time = isActive ? timeTail : ""
        return "\(statusLine)\(time) · \(Pricing.money(cost))"
    }

    /// The server's phase without its time, in member words (the same rules as the Android app).
    public static func memberPhase(_ phase: String) -> String {
        var head = phase
        for cut in [" · ~", " · starts in", " · about"] {
            if let r = head.range(of: cut) { head = String(head[..<r.lowerBound]) }
        }
        var prefix = ""
        if let r = head.range(of: #"^take \d+/\d+ · "#, options: .regularExpression) {
            prefix = String(head[r])
            head = String(head[r.upperBound...])
        }
        func has(_ p: String) -> Bool { head.range(of: p, options: [.regularExpression, .caseInsensitive]) != nil }
        let clean: String
        if head.trimmingCharacters(in: .whitespaces).isEmpty || has("paused|waiting|in line|queued|busy") {
            if let r = head.range(of: #"^#\d+ in line"#, options: .regularExpression) { clean = String(head[r]) } else { clean = MemberText.waitingToStart }
        } else if has("gpu|starting|load|getting ready") {
            clean = "Getting ready"
        } else if has("step|render|denois") {
            clean = "Rendering"
        } else if has("finish|upload|trim") {
            clean = "Finishing"
        } else {
            clean = MemberText.safe(head, or: "Rendering")
        }
        return prefix + clean
    }

    public var engine: Engine { Engine(id: request.engine) }
    /// The option it was made with.
    public var videoQuality: VideoQuality { request.videoQuality }
    /// "Draft" / "Standard" / "HD" / "Edit" / "Fast · beta" / "Upscale".
    public var engineName: String { request.isUpscale ? "Upscale" : videoQuality.label }
    /// The server's label when it's member-safe, or the same built here: "Draft · 768P", "HD · 2K", "Edit", "Fast · beta".
    public var engineLabel: String {
        if let t = engineText, !t.isEmpty, MemberText.isSafe(t) { return t }
        return Job.engineLabel(for: request)
    }
    public static func engineLabel(for r: JobRequest) -> String {
        if r.isUpscale { return "Upscale" }
        let q = r.videoQuality
        if let res = q.resolution { return "\(q.label) · \(res)" }
        return q.label
    }

    /// What to show for a failed job: the server's message when it's member-safe, else the contract's wording for its code.
    public var failureLine: String {
        if let e = error?.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty, MemberText.isSafe(e) { return e }
        return Job.defaultFailure(errorCode)
    }
    public static func defaultFailure(_ code: String?) -> String {
        switch code {
        case "provider_refused": return "This clip was refused by the content filter · you weren't charged"
        case "provider_rate_limited": return "Busy right now · you weren't charged. Try again in a minute."
        case "provider_timeout": return "This took too long and was stopped · you weren't charged"
        case "provider_out_of_credit": return MemberText.ownerTold
        default: return MemberText.wentWrong
        }
    }
    /// Refused by the provider's safety filter.
    public var isRefused: Bool { errorCode == "provider_refused" }
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
    /// The rendered video (real API). Renders are 768×1344; durationSec is the real length.
    public var videoUrl: String?
    public var durationSec: Double?
    public var width: Int?
    public var height: Int?
    /// Template shots: which template made it. `prompt` is the public version ("Template: <name>" plus the user's own layers)
    /// for anyone but the template's owner; `variation` (what was drawn) is owner only.
    public var templateId: String?
    public var templateName: String?
    public var shuffleSeed: Int64?
    public var variation: VariationDraw?
    /// Photoshoot stills: the reference images it was shot with (2026-11-05).
    public var refs: [ShootRef]?
    /// Edited versions (`kind: "edit"`, 2026-11-05): the take it was cut from, the edit list (to re-open it) and the file's fps.
    public var parentTakeId: String?
    public var edits: EditList?
    public var fps: Double?

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

    enum CodingKeys: String, CodingKey {
        case id, kind, jobId, index, of, title, label, engineLabel, cost, seed, status, thumb, prompt, createdAt, videoUrl, durationSec, width, height,
             templateId, templateName, shuffleSeed, variation, refs, parentTakeId, edits, fps
    }
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
        videoUrl = c.o(.videoUrl)
        durationSec = c.o(.durationSec)
        width = c.o(.width)
        height = c.o(.height)
        templateId = c.o(.templateId)
        templateName = c.o(.templateName)
        shuffleSeed = c.o(.shuffleSeed)
        variation = c.o(.variation)
        refs = c.o(.refs)
        parentTakeId = c.o(.parentTakeId)
        edits = c.o(.edits)
        fps = c.o(.fps)
    }

    /// Made with a template.
    public var isTemplateShot: Bool { templateId != nil }

    /// "0:05 · 768×1344" from the real output when the server sent it, else nil.
    public var mediaLine: String? {
        var parts: [String] = []
        if let d = durationSec { parts.append(Take.clock(d)) }
        if let w = width, let h = height { parts.append("\(w)×\(h)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    public static func clock(_ s: Double) -> String {
        let n = Int(s.rounded())
        return "\(n / 60):" + String(format: "%02d", n % 60)
    }

    public var isFinal: Bool { status == "final" }
    /// Video takes: renders and their edited versions.
    public var isVideo: Bool { kind == "take" || kind == "edit" }
    /// Gallery caption: "Living-room dance · Draft". Older servers' labels ("10 steps") read "Edit".
    public var caption: String {
        if kind == "shot" { return title.isEmpty ? label : "\(title) \(index)" }
        let t = of > 1 ? "\(title) · take \(index)" : title
        return displayLabel.isEmpty ? t : "\(t) · \(displayLabel)"
    }

    /// `label` for members: "Draft", "Standard", "HD", "Edit", "Fast · beta".
    public var displayLabel: String {
        if label == "Fast" { return "Fast · beta" }
        return MemberText.isSafe(label) ? label : "Edit"
    }

    /// `engineLabel` for members ("" on photos: the engine is never shown on a photo).
    public var displayEngineLabel: String {
        guard isVideo else { return "" }
        return MemberText.isSafe(engineLabel) ? engineLabel : displayLabel
    }

    /// A finished render take that Upscale could work on.
    public var canUpscale: Bool { kind == "take" && videoUrl != nil }
}

public struct SetTakeStatusRequest: Codable, Sendable {
    public var status: String
    public init(status: String) { self.status = status }
}

/// POST /v1/shoots. With `templateId` the server builds every still's prompt from the template's hidden layers + the model's
/// identity, outfit and never-add + the variation draws (or `direction`) + a seed; `scene`, `prompt` and `seed` are then ignored.
public struct ShootRequest: Codable, Sendable {
    public var modelId: String
    public var outfitId: String
    /// The chip label or the user's own words (the server lower-cases it into the scene line). nil on template shoots.
    public var scene: String?
    /// "Edit as text" only: sent to the model exactly and nothing is built. nil = the server builds the prompt from the choices.
    public var prompt: String?
    public var seed: Int64?
    public var count: Int
    // The server-built photoshoot prompt (plans/api.md 2026-11-05 §2). nil fields are left out of the JSON.
    /// false = only identity, outfit, direction, reference and seed lines.
    public var presets: Bool?
    public var camera: ShootCamera?
    public var light: String?
    public var grade: String?
    /// Up to 3 reference images (pose & framing, look & colour, scene). Also on template shoots.
    public var refs: [ShootRef]?
    // Template shoots (plans/templates.md). nil fields are left out of the JSON.
    public var templateId: String?
    /// Replaces the pose and body-angle draws.
    public var direction: String?
    /// The same shuffleSeed gives the same draws (Shuffle = a new one).
    public var shuffleSeed: Int64?
    /// "Lock look" (off by default for templates): one fixed seed for this template + model.
    public var lockSeed: Bool?
    /// For templates that take a product photo (Product moment).
    public var productImage: ImageRef?
    /// Owner only: per-run model override (step → "owner/name"); members never send it.
    public var models: ModelOverrides?

    public init(modelId: String, outfitId: String, scene: String?, prompt: String?, seed: Int64? = nil, count: Int = 4) {
        self.modelId = modelId
        self.outfitId = outfitId
        self.scene = scene
        self.prompt = prompt
        self.seed = seed
        self.count = count
    }

    /// A template shoot: only the template id and the user's choices are sent.
    public static func template(_ templateId: String, modelId: String, outfitId: String, direction: String = "", shuffleSeed: Int64?, lockSeed: Bool = false,
                                productImage: ImageRef? = nil, refs: [ShootRef] = [], count: Int = 4) -> ShootRequest {
        var r = ShootRequest(modelId: modelId, outfitId: outfitId, scene: nil, prompt: nil, count: count)
        r.templateId = templateId
        let d = direction.trimmingCharacters(in: .whitespacesAndNewlines)
        r.direction = d.isEmpty ? nil : d
        r.shuffleSeed = shuffleSeed
        r.lockSeed = lockSeed
        r.productImage = productImage
        r.refs = refs.isEmpty ? nil : Array(refs.prefix(ShootRef.max))
        return r
    }
}

public struct Balance: Codable, Hashable, Sendable {
    public var balance: Double
    public var month: Double
    public var perJobLimit: Double
    public var perDayLimit: Double
    public var videos: Int
    /// Spent today (`Balance.today` in plans/api.md). nil when an older server doesn't send it; the app then sums today's jobs.
    public var today: Double?
    /// Token wallet (real API). Member: their tokens. Owner: what they can spend or send, in tokens.
    public var tokens: Int?
    public var tokenUsd: Double
    public var role: String?
    public var heldUsd: Double
    public var perUserDayLimit: Double?
    /// studio (owner) | wallet (member)
    public var balanceSource: String?
    /// Owner only: what they can spend or send (`StudioBalance.availableUsd`), the studio balance, and whether a top-up was ever recorded.
    public var availableToSend: Double?
    public var studioBalance: Double?
    public var needsFirstTopUp: Bool?

    public init(balance: Double, month: Double, perJobLimit: Double = Pricing.perJobCap, perDayLimit: Double = Pricing.perDayCap, videos: Int = 0, today: Double? = nil,
                tokens: Int? = nil, tokenUsd: Double = 0.01, role: String? = nil, heldUsd: Double = 0, perUserDayLimit: Double? = nil, balanceSource: String? = nil,
                availableToSend: Double? = nil, studioBalance: Double? = nil, needsFirstTopUp: Bool? = nil) {
        self.balance = balance
        self.month = month
        self.perJobLimit = perJobLimit
        self.perDayLimit = perDayLimit
        self.videos = videos
        self.today = today
        self.tokens = tokens
        self.tokenUsd = tokenUsd
        self.role = role
        self.heldUsd = heldUsd
        self.perUserDayLimit = perUserDayLimit
        self.balanceSource = balanceSource
        self.availableToSend = availableToSend
        self.studioBalance = studioBalance
        self.needsFirstTopUp = needsFirstTopUp
    }

    enum CodingKeys: String, CodingKey {
        case balance, month, perJobLimit, perDayLimit, videos, today, tokens, tokenUsd, role, heldUsd, perUserDayLimit, balanceSource, availableToSend, studioBalance, needsFirstTopUp
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        balance = c.v(.balance, 0)
        month = c.v(.month, 0)
        perJobLimit = c.v(.perJobLimit, Pricing.perJobCap)
        perDayLimit = c.v(.perDayLimit, Pricing.perDayCap)
        videos = c.v(.videos, 0)
        today = c.o(.today)
        tokens = c.o(.tokens)
        tokenUsd = c.v(.tokenUsd, 0.01)
        role = c.o(.role)
        heldUsd = c.v(.heldUsd, 0)
        perUserDayLimit = c.o(.perUserDayLimit)
        balanceSource = c.o(.balanceSource)
        availableToSend = c.o(.availableToSend)
        studioBalance = c.o(.studioBalance)
        needsFirstTopUp = c.o(.needsFirstTopUp)
    }

    /// Whole tokens: the server's count, or the balance converted.
    public var tokenCount: Int { tokens ?? Int((balance / max(tokenUsd, 0.0001) + 1e-6).rounded(.down)) }
}

/// POST /v1/balance/topup `{amount, note?}`: the owner records a studio top-up (alias of POST /v1/studio/topups; server/mock adds demo credit).
public struct TopUpRequest: Codable, Sendable {
    public var amount: Double
    public var note: String?
    public init(amount: Double, note: String? = nil) {
        self.amount = amount
        let n = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = (n?.isEmpty ?? true) ? nil : n
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

/// Server-sent event on /v1/events. type: job | balance | model | outfit | lora | post | wallet | gpu (gpu: owner only)
public struct ApiEvent: Codable, Sendable {
    public var type: String
    public var job: Job?
    public var balance: Balance?
    public var model: MuseModel?
    public var outfit: Outfit?
    public var lora: Lora?
    public var post: Post?
    public var takes: [Take]
    /// `wallet` events (real API): the user's wallet after a transfer, reclaim or charge.
    public var wallet: Wallet?
    /// provider_out_of_credit (owners only).
    public var notice: EventNotice?
    /// `gpu` events (owner only): Keep add-on engine ready.
    public var gpu: WarmGpu?
    /// `gpu` events: state | tick | warning.
    public var event: String?
    /// `gpu` events with `event: "warning"`.
    public var warning: WarmGpuWarning?
    /// `tool` events: an Enhance or Dress up run changed.
    public var tool: ToolRun?
    /// "delete": remove the item with `id` (take, job, model, template, post), or the account of `modelId` on `platform`.
    public var op: String?
    public var id: String?
    /// `take` events: one new or changed take (a photoshoot still made on another device, a status change).
    public var take: Take?
    /// `template` events: my view of a template (layers only when it's mine).
    public var template: MuseTemplate?
    /// `account` events.
    public var account: Account?
    public var modelId: String?
    public var platform: String?
    /// `settings` events: the studio settings in my role's view.
    public var settings: StudioSettings?
    /// Owners only: `member` (one Members row) and `studio` (the studio balance card).
    public var member: Member?
    public var studioBalance: StudioBalance?
    /// `prompts` events (owners only): a prompt-library entry was saved or reset.
    public var prompt: PromptEntry?
    // Prompt scripts (workstream 4): `promptScript` events (owners only) carry the saved or reset script; `clip` events carry a
    // clip (a late one brings its talking detection).
    public var script: ScriptView?
    public var clip: Clip?

    /// Not from the server: the stream (re)connected, so the app refetches what it may have missed.
    public static let connected = "connected"

    public init(type: String, job: Job? = nil, tool: ToolRun? = nil, balance: Balance? = nil, model: MuseModel? = nil, outfit: Outfit? = nil, lora: Lora? = nil, post: Post? = nil,
                takes: [Take] = [], wallet: Wallet? = nil, notice: EventNotice? = nil, gpu: WarmGpu? = nil,
                event: String? = nil, warning: WarmGpuWarning? = nil, op: String? = nil, id: String? = nil, take: Take? = nil, template: MuseTemplate? = nil,
                account: Account? = nil, modelId: String? = nil, platform: String? = nil, settings: StudioSettings? = nil, member: Member? = nil,
                studioBalance: StudioBalance? = nil, prompt: PromptEntry? = nil, script: ScriptView? = nil, clip: Clip? = nil) {
        self.script = script
        self.clip = clip
        self.prompt = prompt
        self.op = op
        self.id = id
        self.take = take
        self.template = template
        self.account = account
        self.modelId = modelId
        self.platform = platform
        self.settings = settings
        self.member = member
        self.studioBalance = studioBalance
        self.tool = tool
        self.gpu = gpu
        self.event = event
        self.warning = warning
        self.wallet = wallet
        self.notice = notice
        self.type = type
        self.job = job
        self.balance = balance
        self.model = model
        self.outfit = outfit
        self.lora = lora
        self.post = post
        self.takes = takes
    }

    enum CodingKeys: String, CodingKey {
        case type, job, balance, model, outfit, lora, post, takes, wallet, notice, gpu, event, warning, tool
        case op, id, take, template, account, modelId, platform, settings, member, studioBalance, prompt
        case script, clip // prompt scripts (workstream 4)
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        type = c.v(.type, "")
        job = c.o(.job)
        balance = c.o(.balance)
        model = c.o(.model)
        outfit = c.o(.outfit)
        lora = c.o(.lora)
        post = c.o(.post)
        takes = c.v(.takes, [])
        wallet = c.o(.wallet)
        notice = c.o(.notice)
        gpu = c.o(.gpu)
        event = c.o(.event)
        warning = c.o(.warning)
        tool = c.o(.tool)
        op = c.o(.op)
        id = c.o(.id)
        take = c.o(.take)
        template = c.o(.template)
        account = c.o(.account)
        modelId = c.o(.modelId)
        platform = c.o(.platform)
        settings = c.o(.settings)
        member = c.o(.member)
        studioBalance = c.o(.studioBalance)
        prompt = c.o(.prompt)
        script = c.o(.script)
        clip = c.o(.clip)
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

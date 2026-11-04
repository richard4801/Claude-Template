import Foundation

// The real API's studio types (plans/api.md, server/api): token wallets, members, invites, studio settings,
// the image engine, presigned uploads, and the friendly text for every error code.

/// GET /v1/wallet. 1 token = `tokenUsd` dollars (0.01).
public struct Wallet: Codable, Hashable, Sendable {
    public var userId: String
    public var role: String
    public var tokens: Int
    public var usd: Double
    public var heldTokens: Int
    public var heldUsd: Double
    public var todayUsd: Double
    public var monthUsd: Double
    public var tokenUsd: Double
    public var balanceSource: String
    /// Owner only: what they can spend or send, the studio balance (top-ups − spending) and members' unspent credit.
    public var availableToSend: Double?
    public var studioBalance: Double?
    public var membersUnspentUsd: Double?

    public init(userId: String, role: String, tokens: Int, usd: Double, heldTokens: Int = 0, heldUsd: Double = 0, todayUsd: Double = 0, monthUsd: Double = 0,
                tokenUsd: Double = 0.01, balanceSource: String = "wallet", availableToSend: Double? = nil, studioBalance: Double? = nil, membersUnspentUsd: Double? = nil) {
        self.userId = userId
        self.role = role
        self.tokens = tokens
        self.usd = usd
        self.heldTokens = heldTokens
        self.heldUsd = heldUsd
        self.todayUsd = todayUsd
        self.monthUsd = monthUsd
        self.tokenUsd = tokenUsd
        self.balanceSource = balanceSource
        self.availableToSend = availableToSend
        self.studioBalance = studioBalance
        self.membersUnspentUsd = membersUnspentUsd
    }

    enum CodingKeys: String, CodingKey {
        case userId, role, tokens, usd, heldTokens, heldUsd, todayUsd, monthUsd, tokenUsd, balanceSource, availableToSend, studioBalance, membersUnspentUsd
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        userId = c.v(.userId, "")
        role = c.v(.role, "member")
        tokens = c.v(.tokens, 0)
        tokenUsd = c.v(.tokenUsd, 0.01)
        usd = c.v(.usd, Double(tokens) * tokenUsd)
        heldTokens = c.v(.heldTokens, 0)
        heldUsd = c.v(.heldUsd, 0)
        todayUsd = c.v(.todayUsd, 0)
        monthUsd = c.v(.monthUsd, 0)
        balanceSource = c.v(.balanceSource, "wallet")
        availableToSend = c.o(.availableToSend)
        studioBalance = c.o(.studioBalance)
        membersUnspentUsd = c.o(.membersUnspentUsd)
    }

    public var isOwner: Bool { role == "owner" }
    /// Tokens the owner can still send (the studio balance's available part; none while it's below zero).
    public var tokensToSend: Int? { availableToSend.map { max(0, Int(($0 / max(tokenUsd, 0.0001) + 1e-6).rounded(.down))) } }
}

/// A person in the studio (GET /v1/members, owner only).
public struct Member: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var email: String
    public var role: String
    public var tokens: Int
    public var usd: Double
    public var heldTokens: Int
    public var todayUsd: Double
    public var monthUsd: Double
    public var lastActiveAt: Int64?
    public var disabled: Bool
    /// Effective caps (their own, or the studio default).
    public var capPerJob: Double
    public var capPerDay: Double
    public var createdAt: Int64

    public init(id: String, email: String, role: String = "member", tokens: Int = 0, usd: Double = 0, heldTokens: Int = 0, todayUsd: Double = 0, monthUsd: Double = 0,
                lastActiveAt: Int64? = nil, disabled: Bool = false, capPerJob: Double = Pricing.perJobCap, capPerDay: Double = 10, createdAt: Int64 = 0) {
        self.id = id
        self.email = email
        self.role = role
        self.tokens = tokens
        self.usd = usd
        self.heldTokens = heldTokens
        self.todayUsd = todayUsd
        self.monthUsd = monthUsd
        self.lastActiveAt = lastActiveAt
        self.disabled = disabled
        self.capPerJob = capPerJob
        self.capPerDay = capPerDay
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case id, email, role, tokens, usd, heldTokens, todayUsd, monthUsd, lastActiveAt, disabled, capPerJob, capPerDay, createdAt }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        email = c.v(.email, "")
        role = c.v(.role, "member")
        tokens = c.v(.tokens, 0)
        usd = c.v(.usd, 0)
        heldTokens = c.v(.heldTokens, 0)
        todayUsd = c.v(.todayUsd, 0)
        monthUsd = c.v(.monthUsd, 0)
        lastActiveAt = c.o(.lastActiveAt)
        disabled = c.v(.disabled, false)
        capPerJob = c.v(.capPerJob, Pricing.perJobCap)
        capPerDay = c.v(.capPerDay, 10)
        createdAt = c.v(.createdAt, 0)
    }

    public var isOwner: Bool { role == "owner" }
}

/// PATCH /v1/members/{id}. Only the fields set are sent. `.reset` sends null: back to the studio default.
public struct MemberPatch: Encodable, Sendable {
    public enum Cap: Sendable, Equatable { case set(Double), reset }
    public var capPerJob: Cap?
    public var capPerDay: Cap?
    public var disabled: Bool?

    public init(capPerJob: Cap? = nil, capPerDay: Cap? = nil, disabled: Bool? = nil) {
        self.capPerJob = capPerJob
        self.capPerDay = capPerDay
        self.disabled = disabled
    }

    enum CodingKeys: String, CodingKey { case capPerJob, capPerDay, disabled }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        for (key, cap) in [(CodingKeys.capPerJob, capPerJob), (.capPerDay, capPerDay)] {
            switch cap {
            case .set(let v)?: try c.encode(v, forKey: key)
            case .reset?: try c.encodeNil(forKey: key)
            case nil: break
            }
        }
        try c.encodeIfPresent(disabled, forKey: .disabled)
    }
}

/// POST /v1/wallets/transfer and /reclaim.
public struct TokenMove: Codable, Sendable {
    public var userId: String
    public var tokens: Int
    public var note: String?

    /// From dollars (what the app shows): rounded to the nearest cent and converted at `tokenUsd` (0.01).
    public init(userId: String, usd: Double, tokenUsd: Double = 0.01, note: String? = nil) {
        self.init(userId: userId, tokens: Pricing.tokensForDollars(usd, tokenUsd), note: note)
    }

    public init(userId: String, tokens: Int, note: String? = nil) {
        self.userId = userId
        self.tokens = tokens
        let n = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = (n?.isEmpty ?? true) ? nil : n
    }
}

struct TransferBody: Encodable {
    var toUserId: String
    var tokens: Int
    var note: String?
}

struct ReclaimBody: Encodable {
    var fromUserId: String
    var tokens: Int
    var note: String?
}

/// The answer to a transfer or reclaim: the owner's wallet and the member after the move.
public struct TokenMoveResult: Codable, Sendable {
    public var wallet: Wallet
    public var member: Member
    public init(wallet: Wallet, member: Member) {
        self.wallet = wallet
        self.member = member
    }
}

/// POST /v1/invites → the code, shown once.
public struct Invite: Codable, Hashable, Sendable {
    public var code: String
    public var id: String
    public var email: String?
    public var role: String
    public var expiresAt: Int64
    /// Ready-to-send invite message from the server (newer servers). nil → build it with `shareMessage(publicURL:)`.
    public var shareText: String?

    public init(code: String, id: String, email: String? = nil, role: String = "member", expiresAt: Int64 = 0, shareText: String? = nil) {
        self.code = code
        self.id = id
        self.email = email
        self.role = role
        self.expiresAt = expiresAt
        self.shareText = shareText
    }

    enum CodingKeys: String, CodingKey { case code, id, email, role, expiresAt, shareText }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        code = c.v(.code, "")
        id = c.v(.id, "")
        email = c.o(.email)
        role = c.v(.role, "member")
        expiresAt = c.v(.expiresAt, 0)
        shareText = c.o(.shareText)
    }

    /// The text for Share…: the server's `shareText`, or the same message built here (download page at `{server}/get`).
    public func shareMessage(publicURL: String, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> String {
        if let s = shareText?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
        var base = publicURL
        while base.hasSuffix("/") { base.removeLast() }
        let left = expiresAt > now ? Int((Double(expiresAt - now) / 86_400_000).rounded()) : 14
        let days = max(1, left)
        let who = email.map { " (email: \($0))" } ?? ""
        return "You're invited to MUSE, the AI model studio. 1) Download: \(base)/get 2) Sign up with this invite code: \(code)\(who). "
            + "The code works once and expires in \(days) day\(days == 1 ? "" : "s")."
    }
}

public struct InviteRequest: Codable, Sendable {
    public var email: String?
    public var role: String?
    public var days: Int?
    public init(email: String? = nil, role: String? = nil, days: Int? = nil) {
        let e = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.email = (e?.isEmpty ?? true) ? nil : e
        self.role = role
        self.days = days
    }
}

/// GET/PATCH /v1/settings/image-engine. provider: simulated | fal | custom-http | replicate.
public struct ImageEngine: Codable, Hashable, Sendable {
    public var provider: String
    public var model: String
    /// replicate: the edit model (outfit angles).
    public var editModel: String?
    /// For display: "FLUX.2 [pro] · Replicate", "Simulated"… (newer servers).
    public var label: String?
    public var url: String?
    /// Which providers the server can use right now.
    public var available: [String: Bool]

    public init(provider: String = "simulated", model: String = "bundled-stills", url: String? = nil, available: [String: Bool] = ["simulated": true],
                label: String? = nil, editModel: String? = nil) {
        self.provider = provider
        self.model = model
        self.url = url
        self.available = available
        self.label = label
        self.editModel = editModel
    }

    enum CodingKeys: String, CodingKey { case provider, model, editModel, label, url, available }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        provider = c.v(.provider, "simulated")
        model = c.v(.model, "")
        editModel = c.o(.editModel)
        label = c.o(.label)
        url = c.o(.url)
        available = c.v(.available, [:])
    }

    /// The server's label, else "<provider> · <model>".
    public var displayLabel: String {
        if let l = label?.trimmingCharacters(in: .whitespaces), !l.isEmpty { return l }
        let name = ImageEngine.providers.first { $0.id == provider }?.label ?? provider
        return model.isEmpty ? name : "\(name) · \(model)"
    }

    public struct Provider: Hashable, Sendable, Identifiable {
        public let id: String
        public let label: String
    }
    public static let providers: [Provider] = [Provider(id: "replicate", label: "Replicate"), Provider(id: "simulated", label: "Built-in (free)"),
                                               Provider(id: "fal", label: "fal.ai"), Provider(id: "custom-http", label: "Custom HTTP")]
    public func isAvailable(_ p: String) -> Bool { available[p] ?? (p == provider) }
}

public struct ImageEngineRequest: Codable, Sendable {
    public var provider: String
    public var model: String?
    public var url: String?
    public init(provider: String, model: String? = nil, url: String? = nil) {
        self.provider = provider
        let m = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = (m?.isEmpty ?? true) ? nil : m
        let u = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.url = (u?.isEmpty ?? true) ? nil : u
    }
}

/// GET/PATCH /v1/settings/studio. Members get the caps, `tokenUsd` and `features` only; the owner also gets the add-on engine
/// settings and `engines` (plans/api.md "App clean-up" §5). overheadPayer: who pays the add-on engine's start-up ("user" or "owner").
public struct StudioSettings: Codable, Hashable, Sendable {
    public var maxGpus: Int
    public var overheadPayer: String
    public var capPerJob: Double
    public var capPerDay: Double
    public var capPerUserDay: Double
    public var tokenUsd: Double
    public var features: StudioFeatures
    /// Keep add-on engine ready (owner only): the idle auto-off and the session cap.
    public var warmIdleMinutes: Int
    public var warmMaxMinutes: Int
    /// Owner only: Settings → Engines.
    public var engines: Engines?

    public init(maxGpus: Int = 3, overheadPayer: String = "user", capPerJob: Double = 5, capPerDay: Double = 15, capPerUserDay: Double = 10, tokenUsd: Double = 0.01,
                features: StudioFeatures = StudioFeatures(), warmIdleMinutes: Int = 20, warmMaxMinutes: Int = 120, engines: Engines? = nil) {
        self.warmIdleMinutes = warmIdleMinutes
        self.warmMaxMinutes = warmMaxMinutes
        self.maxGpus = maxGpus
        self.overheadPayer = overheadPayer
        self.capPerJob = capPerJob
        self.capPerDay = capPerDay
        self.capPerUserDay = capPerUserDay
        self.tokenUsd = tokenUsd
        self.features = features
        self.engines = engines
    }

    enum CodingKeys: String, CodingKey {
        case maxGpus, overheadPayer, capPerJob, capPerDay, capPerUserDay, tokenUsd, features, warmIdleMinutes, warmMaxMinutes, engines
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        maxGpus = c.v(.maxGpus, 3)
        overheadPayer = c.v(.overheadPayer, "user")
        capPerJob = c.v(.capPerJob, 5)
        capPerDay = c.v(.capPerDay, 15)
        capPerUserDay = c.v(.capPerUserDay, 10)
        tokenUsd = c.v(.tokenUsd, 0.01)
        features = c.v(.features, StudioFeatures())
        warmIdleMinutes = c.v(.warmIdleMinutes, 20)
        warmMaxMinutes = c.v(.warmMaxMinutes, 120)
        engines = c.o(.engines)
    }
}

/// `engines` (owner only): the only place provider names appear (Settings → Engines).
public struct Engines: Codable, Hashable, Sendable {
    public var list: [EngineStatus]
    public var imageEngine: ImageEngine?
    public var addOn: AddOnEngine?
    public var keepReady: KeepReady?

    public init(list: [EngineStatus] = [], imageEngine: ImageEngine? = nil, addOn: AddOnEngine? = nil, keepReady: KeepReady? = nil) {
        self.list = list
        self.imageEngine = imageEngine
        self.addOn = addOn
        self.keepReady = keepReady
    }

    enum CodingKeys: String, CodingKey { case list, imageEngine, addOn, keepReady }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        list = c.v(.list, [])
        imageEngine = c.o(.imageEngine)
        addOn = c.o(.addOn)
        keepReady = c.o(.keepReady)
    }
}

/// One engine's status: ready | no_key | simulated | out_of_credit | no_gpu.
public struct EngineStatus: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var usedFor: String
    public var keySet: Bool
    public var status: String
    public var message: String?
    public var outOfCreditAt: Int64?

    public init(id: String, name: String, usedFor: String = "", keySet: Bool = false, status: String = "ready", message: String? = nil, outOfCreditAt: Int64? = nil) {
        self.id = id
        self.name = name
        self.usedFor = usedFor
        self.keySet = keySet
        self.status = status
        self.message = message
        self.outOfCreditAt = outOfCreditAt
    }

    enum CodingKeys: String, CodingKey { case id, name, usedFor, keySet, status, message, outOfCreditAt }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = c.v(.id, "")
        name = c.v(.name, "")
        usedFor = c.v(.usedFor, "")
        keySet = c.v(.keySet, false)
        status = c.v(.status, "ready")
        message = c.o(.message)
        outOfCreditAt = c.o(.outOfCreditAt)
    }

    /// "Ready", "No key", "Simulated", "Out of credit", "No GPU free".
    public var statusLabel: String {
        switch status {
        case "ready": return "Ready"
        case "no_key": return "No key"
        case "simulated": return "Simulated"
        case "out_of_credit": return "Out of credit"
        case "no_gpu": return "No GPU free"
        default: return status
        }
    }
    public var isProblem: Bool { status == "out_of_credit" || status == "no_gpu" || status == "no_key" }
}

/// The add-on engine's settings: max GPUs at once and who pays start-up.
public struct AddOnEngine: Codable, Hashable, Sendable {
    public var maxGpus: Int?
    public var overheadPayer: String?
    public init(maxGpus: Int? = nil, overheadPayer: String? = nil) {
        self.maxGpus = maxGpus
        self.overheadPayer = overheadPayer
    }
    enum CodingKeys: String, CodingKey { case maxGpus, overheadPayer }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        maxGpus = c.o(.maxGpus)
        overheadPayer = c.o(.overheadPayer)
    }
}

/// Keep add-on engine ready: the auto-off minutes and the rate.
public struct KeepReady: Codable, Hashable, Sendable {
    public var idleMinutes: Int
    public var maxMinutes: Int
    public var ratePerHour: Double
    public init(idleMinutes: Int = 20, maxMinutes: Int = 120, ratePerHour: Double = WarmGpu.defaultRate) {
        self.idleMinutes = idleMinutes
        self.maxMinutes = maxMinutes
        self.ratePerHour = ratePerHour
    }
    enum CodingKeys: String, CodingKey { case idleMinutes, maxMinutes, ratePerHour }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        idleMinutes = c.v(.idleMinutes, 20)
        maxMinutes = c.v(.maxMinutes, 120)
        ratePerHour = c.v(.ratePerHour, WarmGpu.defaultRate)
    }
}

/// GET /v1/studio/balance (owner): the owner-loaded studio balance (plans/api.md "App clean-up" §4).
public struct StudioBalance: Codable, Hashable, Sendable {
    public var balanceUsd: Double
    public var toppedUpUsd: Double
    public var spentUsd: Double
    public var membersCreditUsd: Double
    public var heldUsd: Double
    /// What the owner can spend or send; may be below zero until the first top-up.
    public var availableUsd: Double
    public var since: Int64
    public var needsFirstTopUp: Bool
    public var topUps: [TopUp]

    public init(balanceUsd: Double = 0, toppedUpUsd: Double = 0, spentUsd: Double = 0, membersCreditUsd: Double = 0, heldUsd: Double = 0, availableUsd: Double = 0,
                since: Int64 = 0, needsFirstTopUp: Bool = true, topUps: [TopUp] = []) {
        self.balanceUsd = balanceUsd
        self.toppedUpUsd = toppedUpUsd
        self.spentUsd = spentUsd
        self.membersCreditUsd = membersCreditUsd
        self.heldUsd = heldUsd
        self.availableUsd = availableUsd
        self.since = since
        self.needsFirstTopUp = needsFirstTopUp
        self.topUps = topUps
    }

    enum CodingKeys: String, CodingKey { case balanceUsd, toppedUpUsd, spentUsd, membersCreditUsd, heldUsd, availableUsd, since, needsFirstTopUp, topUps }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        balanceUsd = c.v(.balanceUsd, 0)
        toppedUpUsd = c.v(.toppedUpUsd, 0)
        spentUsd = c.v(.spentUsd, 0)
        membersCreditUsd = c.v(.membersCreditUsd, 0)
        heldUsd = c.v(.heldUsd, 0)
        availableUsd = c.v(.availableUsd, balanceUsd - membersCreditUsd - heldUsd)
        since = c.v(.since, 0)
        topUps = c.v(.topUps, [])
        needsFirstTopUp = c.v(.needsFirstTopUp, topUps.isEmpty)
    }
}

/// One recorded top-up ("Added $20").
public struct TopUp: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var amountUsd: Double
    public var note: String?
    public var paidAt: Int64
    public var createdAt: Int64
    public var createdBy: String?

    public init(id: String, amountUsd: Double, note: String? = nil, paidAt: Int64, createdAt: Int64? = nil, createdBy: String? = nil) {
        self.id = id
        self.amountUsd = amountUsd
        self.note = note
        self.paidAt = paidAt
        self.createdAt = createdAt ?? paidAt
        self.createdBy = createdBy
    }

    enum CodingKeys: String, CodingKey { case id, amountUsd, note, paidAt, createdAt, createdBy }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = c.v(.id, "")
        amountUsd = c.v(.amountUsd, 0)
        note = c.o(.note)
        createdAt = c.v(.createdAt, 0)
        paidAt = c.v(.paidAt, createdAt)
        createdBy = c.o(.createdBy)
    }

    /// "Added $20.00" (+ " · <note>"), like the ledger note.
    public var line: String { "Added \(Pricing.money(amountUsd))" + (note.map { $0.isEmpty ? "" : " · \($0)" } ?? "") }
}

/// POST /v1/studio/topups.
public struct TopUpRecord: Codable, Sendable {
    public static let maxAmount = 10_000.0
    public var amountUsd: Double
    public var note: String?
    public var paidAt: Int64?

    public init(amountUsd: Double, note: String? = nil, paidAt: Int64? = nil) {
        self.amountUsd = (amountUsd * 100).rounded() / 100
        let n = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = (n?.isEmpty ?? true) ? nil : String(n!.prefix(200))
        self.paidAt = paidAt
    }

    /// 0 < amount ≤ $10,000.
    public var isValid: Bool { amountUsd > 0 && amountUsd <= TopUpRecord.maxAmount }
}

public struct StudioFeatures: Codable, Hashable, Sendable {
    public var standard: Bool
    public var fastBeta: Bool
    public var lipSync: Bool
    public var loraTraining: Bool
    public var replaceAudio: Bool
    public var maxClipSec: Double
    /// The Replicate engine is set up on the server.
    public var replicate: Bool
    /// Render and add-ons (newer servers). nil = use `VideoFeatures.fallback`.
    public var video: VideoFeatures?
    /// Photo price estimates. nil = `PhotoPricing.standard`.
    public var photo: PhotoPricing?

    public init(standard: Bool = true, fastBeta: Bool = true, lipSync: Bool = true, loraTraining: Bool = true, replaceAudio: Bool = false, maxClipSec: Double = 15,
                replicate: Bool = false, video: VideoFeatures? = nil, photo: PhotoPricing? = nil) {
        self.replicate = replicate
        self.video = video
        self.photo = photo
        self.standard = standard
        self.fastBeta = fastBeta
        self.lipSync = lipSync
        self.loraTraining = loraTraining
        self.replaceAudio = replaceAudio
        self.maxClipSec = maxClipSec
    }

    enum CodingKeys: String, CodingKey { case standard, fastBeta, lipSync, loraTraining, replaceAudio, maxClipSec, replicate, video, photo }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        standard = c.v(.standard, true)
        fastBeta = c.v(.fastBeta, true)
        lipSync = c.v(.lipSync, true)
        loraTraining = c.v(.loraTraining, true)
        replaceAudio = c.v(.replaceAudio, false)
        maxClipSec = c.v(.maxClipSec, 15)
        replicate = c.v(.replicate, false)
        video = c.o(.video)
        photo = c.o(.photo)
    }
}

/// `features.video` (GET /v1/settings/studio): the Render picker (`options`) and the add-ons (plans/api.md "App clean-up" §2).
public struct VideoFeatures: Codable, Hashable, Sendable {
    public var defaultEngine: String
    public var defaultQuality: String
    public var minSeconds: Int
    public var maxSeconds: Int
    public var options: [VideoOption]
    public var addons: [AddonOption]

    public init(defaultEngine: String = "replicate", defaultQuality: String = VideoQuality.default.rawValue, minSeconds: Int = 4, maxSeconds: Int = 15,
                options: [VideoOption] = VideoOption.defaults, addons: [AddonOption] = AddonOption.defaults) {
        self.defaultEngine = defaultEngine
        self.defaultQuality = defaultQuality
        self.minSeconds = minSeconds
        self.maxSeconds = maxSeconds
        self.options = options
        self.addons = addons
    }

    enum CodingKeys: String, CodingKey { case defaultEngine, defaultQuality, minSeconds, maxSeconds, options, addons }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        defaultEngine = c.v(.defaultEngine, "replicate")
        defaultQuality = c.v(.defaultQuality, VideoQuality.default.rawValue)
        minSeconds = c.v(.minSeconds, Pricing.replicateMinSec)
        maxSeconds = c.v(.maxSeconds, Pricing.replicateMaxSec)
        let read: [VideoOption] = c.v(.options, [])
        options = read.isEmpty ? VideoOption.defaults : read
        let adds: [AddonOption] = c.v(.addons, [])
        if adds.isEmpty {
            // Older servers listed Exact edit among the options; its availability carries over to Edit.
            let exact = read.first { $0.id == "exact" }
            addons = AddonOption.defaults.map { a in
                var a = a
                if a.id == "edit", let e = exact { a.available = e.available }
                return a
            }
        } else {
            addons = adds
        }
    }

    /// For servers that don't send `features.video`: the contract's table, every render and add-on available, Upscale coming soon.
    public static let fallback = VideoFeatures()

    /// The picker's default: Edit when the server's default engine is h3, else `defaultQuality` (Draft).
    public var defaultOption: VideoQuality {
        if defaultEngine == Engine.h3.rawValue { return .edit }
        return VideoQuality(id: defaultQuality).replicateOrDefault
    }

    public func option(_ q: VideoQuality) -> VideoOption { options.first { $0.id == q.rawValue } ?? VideoOption.make(q) }
    public func addon(_ id: String) -> AddonOption? { addons.first { $0.id == id } }
    /// Edit and Fast · beta come from `addons`; Draft / Standard / HD from `options`.
    public func isAvailable(_ q: VideoQuality) -> Bool {
        switch q {
        case .edit: return addon("edit")?.available ?? false
        case .fast: return addon("fast")?.available ?? false
        default: return option(q).available
        }
    }
    /// The server's $ per second for a render quality (nil for add-ons).
    public func pricePerSec(_ q: VideoQuality) -> Double? { q.isReplicate ? (option(q).pricePerSec ?? q.defaultPricePerSec) : nil }
    /// The Render picker: Draft / Standard / HD in the server's order, with any missing one added.
    public var ordered: [VideoOption] {
        var out = options.filter { VideoQuality(rawValue: $0.id)?.isReplicate == true }
        for q in VideoQuality.renders where !out.contains(where: { $0.id == q.rawValue }) { out.append(VideoOption.make(q)) }
        return out
    }
    /// The add-ons to show: Edit, Fast · beta only when available, and Upscale.
    public var shownAddons: [AddonOption] { addons.filter { $0.id != "fast" || $0.available } }
    public var upscale: AddonOption? { addon("upscale") }
}

public struct VideoOption: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var detail: String
    public var engine: String
    public var quality: String?
    public var resolution: String?
    public var pricePerSec: Double?
    public var available: Bool

    public init(id: String, label: String, detail: String, engine: String, quality: String? = nil, resolution: String? = nil, pricePerSec: Double? = nil, available: Bool = true) {
        self.id = id
        self.label = label
        self.detail = detail
        self.engine = engine
        self.quality = quality
        self.resolution = resolution
        self.pricePerSec = pricePerSec
        self.available = available
    }

    enum CodingKeys: String, CodingKey { case id, label, detail, engine, quality, resolution, pricePerSec, available }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = c.v(.id, VideoQuality.default.rawValue)
        let q = VideoQuality(id: id)
        label = c.v(.label, q.label)
        detail = c.v(.detail, q.detail)
        engine = c.v(.engine, q.engine.rawValue)
        quality = c.o(.quality)
        resolution = c.o(.resolution)
        pricePerSec = c.o(.pricePerSec)
        available = c.v(.available, true)
    }

    public var videoQuality: VideoQuality { VideoQuality(id: id) }
    /// The server's detail when it's member-safe (older servers said "768P · lite"), else the app's.
    public var shownDetail: String { MemberText.safe(detail, or: videoQuality.detail) }

    public static func make(_ q: VideoQuality, available: Bool = true) -> VideoOption {
        VideoOption(id: q.rawValue, label: q.label, detail: q.detail, engine: q.engine.rawValue, quality: q.requestQuality, resolution: q.resolution,
                    pricePerSec: q.defaultPricePerSec, available: available)
    }
    public static let defaults: [VideoOption] = VideoQuality.renders.map { make($0) }
}

/// An add-on: Edit, Fast · beta or Upscale.
public struct AddonOption: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var detail: String
    public var available: Bool
    public var comingSoon: Bool
    public var sizes: [UpscaleSize]

    public init(id: String, label: String, detail: String, available: Bool = true, comingSoon: Bool = false, sizes: [UpscaleSize] = []) {
        self.id = id
        self.label = label
        self.detail = detail
        self.available = available
        self.comingSoon = comingSoon
        self.sizes = sizes
    }

    enum CodingKeys: String, CodingKey { case id, label, detail, available, comingSoon, sizes }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let key: String = c.v(.id, "")
        id = key
        let def = AddonOption.defaults.first { $0.id == key }
        label = c.v(.label, def?.label ?? id)
        detail = c.v(.detail, def?.detail ?? "")
        available = c.v(.available, false)
        comingSoon = c.v(.comingSoon, false)
        let s: [UpscaleSize] = c.v(.sizes, [])
        sizes = s.isEmpty && key == "upscale" ? UpscaleSize.defaults : s
    }

    /// The render this add-on makes (nil for Upscale).
    public var videoQuality: VideoQuality? { id == "edit" ? .edit : id == "fast" ? .fast : nil }
    public var shownDetail: String { MemberText.safe(detail, or: AddonOption.defaults.first { $0.id == id }?.detail ?? "") }

    public static let defaults: [AddonOption] = [
        AddonOption(id: "edit", label: "Edit", detail: VideoQuality.edit.detail),
        AddonOption(id: "fast", label: "Fast · beta", detail: VideoQuality.fast.detail),
        AddonOption(id: "upscale", label: "Upscale", detail: "Sharper 1080p, 2K or 4K from a finished take", available: false, comingSoon: true, sizes: UpscaleSize.defaults),
    ]
}

/// Upscale sizes: 1080p = 1080×1920, 2K = 1440×2560, 4K = 2160×3840. `price` is nil until measured.
public struct UpscaleSize: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var width: Int
    public var height: Int
    public var available: Bool
    public var price: Double?

    public init(id: String, label: String, width: Int, height: Int, available: Bool = false, price: Double? = nil) {
        self.id = id
        self.label = label
        self.width = width
        self.height = height
        self.available = available
        self.price = price
    }

    enum CodingKeys: String, CodingKey { case id, label, width, height, available, price }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let key: String = c.v(.id, "")
        id = key
        let def = UpscaleSize.defaults.first { $0.id == key }
        label = c.v(.label, def?.label ?? id)
        width = c.v(.width, def?.width ?? 0)
        height = c.v(.height, def?.height ?? 0)
        available = c.v(.available, false)
        price = c.o(.price)
    }

    /// "1440×2560".
    public var sizeLine: String { "\(width)×\(height)" }

    public static let defaults: [UpscaleSize] = [
        UpscaleSize(id: "1080p", label: "1080p", width: 1080, height: 1920),
        UpscaleSize(id: "2k", label: "2K", width: 1440, height: 2560),
        UpscaleSize(id: "4k", label: "4K", width: 2160, height: 3840),
    ]
}

/// POST /v1/takes/{id}/upscale.
public struct UpscaleRequest: Codable, Sendable {
    public var size: String
    public init(size: String) { self.size = size }
}

/// PATCH /v1/settings/studio: only the fields set are sent.
public struct StudioSettingsPatch: Codable, Sendable {
    public var maxGpus: Int?
    public var overheadPayer: String?
    public var capPerJob: Double?
    public var capPerDay: Double?
    public var capPerUserDay: Double?
    public var warmIdleMinutes: Int?
    public var warmMaxMinutes: Int?
    public init(maxGpus: Int? = nil, overheadPayer: String? = nil, capPerJob: Double? = nil, capPerDay: Double? = nil, capPerUserDay: Double? = nil,
                warmIdleMinutes: Int? = nil, warmMaxMinutes: Int? = nil) {
        self.warmIdleMinutes = warmIdleMinutes
        self.warmMaxMinutes = warmMaxMinutes
        self.maxGpus = maxGpus
        self.overheadPayer = overheadPayer
        self.capPerJob = capPerJob
        self.capPerDay = capPerDay
        self.capPerUserDay = capPerUserDay
    }
}

/// `notice` on a wallet event (owners): provider_out_of_credit, with the engine (replicate | runpod).
public struct EventNotice: Codable, Hashable, Sendable {
    public var code: String
    public var message: String
    public var engine: String?
    public init(code: String, message: String, engine: String? = nil) {
        self.code = code
        self.message = message
        self.engine = engine
    }
}

/// POST /v1/uploads/presign → where to PUT the bytes.
public struct PresignedUpload: Codable, Sendable {
    public var uploadId: String
    public var method: String
    public var url: String
    public var headers: [String: String]
    public var expiresAt: Int64?

    enum CodingKeys: String, CodingKey { case uploadId, method, url, headers, expiresAt }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        uploadId = try c.decode(String.self, forKey: .uploadId)
        method = c.v(.method, "PUT")
        url = try c.decode(String.self, forKey: .url)
        headers = c.v(.headers, [:])
        expiresAt = c.o(.expiresAt)
    }
}

struct PresignBody: Encodable {
    var kind: String
    var contentType: String
    var bytes: Int?
}

struct ConfirmBody: Encodable {
    var meta: ClipMeta?
}

/// Upload progress, 0…1.
public typealias UploadProgress = @Sendable (Double) -> Void

// MARK: - Friendly errors

extension ApiError {
    /// Server codes that end the session: the app goes back to sign-in.
    public var endsSession: Bool { code == "unauthorized" || code == "account_disabled" }

    /// The text the app shows for this error. Known codes get MUSE's own wording; anything else shows the server's message.
    /// Server text that names an engine or a GPU (older servers) reads "Something went wrong".
    public var friendlyMessage: String { ApiError.friendly(code) ?? MemberText.safe(ApiError.inDollars(message), or: MemberText.wentWrong) }

    /// The app shows dollars, never tokens: "They have 250 unused tokens" → "They have $2.50 unused credit".
    public static func inDollars(_ text: String, tokenUsd: Double = 0.01) -> String {
        guard text.range(of: "token", options: .caseInsensitive) != nil else { return text }
        var out = text
        if let re = try? NSRegularExpression(pattern: "(\\d+) ((?:unused |more )?)(?:tokens?|(?=are on hold))") {
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let n = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let mid = ns.substring(with: m.range(at: 2))
                let held = ns.substring(with: m.range).hasSuffix(" ")
                result += Pricing.money(n * tokenUsd) + " " + mid + (held ? "" : "credit")
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        return out.replacingOccurrences(of: "tokens", with: "credit").replacingOccurrences(of: "Tokens", with: "Credit")
            .replacingOccurrences(of: "token", with: "credit")
    }

    public static func friendly(_ code: String) -> String? {
        switch code {
        case "invite_required": return "MUSE is invite-only. Enter the invite code the studio owner sent you."
        case "invite_invalid": return "That invite code isn't valid or has expired. Check it, or ask the studio owner for a new one."
        case "email_taken": return "That email already has an account. Sign in instead."
        case "bad_credentials": return "Wrong email or password."
        case "account_disabled": return "This account is switched off. Ask the studio owner to turn it back on."
        case "rate_limited", "http_429": return "Too many tries. Wait a minute, then try again."
        case "unauthorized": return "Your session has ended. Sign in again."
        case "attestation_required": return "Tick both boxes to create your account."
        case "insufficient_tokens": return "Not enough credit. Ask the studio owner for more."
        case "insufficient_balance": return "Not enough in the studio balance · add a top-up in Credit"
        case "owner_only": return "Only the studio owner can do that."
        case "over_allocation": return "That's more than the studio balance has free. Add a top-up in Credit, or send less."
        case "upload_missing": return "The upload didn't arrive. Try again."
        case "image_engine_failed": return "Something went wrong making the photos · you weren't charged"
        case "provider_refused": return "This photo was refused by the content filter · you weren't charged"
        case "provider_rate_limited": return "Busy right now · you weren't charged. Try again in a minute."
        case "provider_out_of_credit": return MemberText.ownerTold
        case "upscale_unavailable": return "Upscale is coming soon"
        // Retired codes from older servers, in member-safe words.
        case "owner_balance_low", "balance_unavailable", "topup_unavailable": return MemberText.wentWrong
        default: return nil
        }
    }
}

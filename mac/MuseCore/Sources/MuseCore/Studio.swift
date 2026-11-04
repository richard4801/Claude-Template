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
    /// Owner only.
    public var availableToSend: Double?
    public var runpodBalance: Double?
    public var membersUnspentUsd: Double?

    public init(userId: String, role: String, tokens: Int, usd: Double, heldTokens: Int = 0, heldUsd: Double = 0, todayUsd: Double = 0, monthUsd: Double = 0,
                tokenUsd: Double = 0.01, balanceSource: String = "wallet", availableToSend: Double? = nil, runpodBalance: Double? = nil, membersUnspentUsd: Double? = nil) {
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
        self.runpodBalance = runpodBalance
        self.membersUnspentUsd = membersUnspentUsd
    }

    enum CodingKeys: String, CodingKey {
        case userId, role, tokens, usd, heldTokens, heldUsd, todayUsd, monthUsd, tokenUsd, balanceSource, availableToSend, runpodBalance, membersUnspentUsd
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
        runpodBalance = c.o(.runpodBalance)
        membersUnspentUsd = c.o(.membersUnspentUsd)
    }

    public var isOwner: Bool { role == "owner" }
    /// Tokens the owner can still send (what the RunPod balance backs).
    public var tokensToSend: Int? { availableToSend.map { Int(($0 / max(tokenUsd, 0.0001) + 1e-6).rounded(.down)) } }
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

/// GET/PATCH /v1/settings/studio. overheadPayer: who pays GPU warm-up ("user" or "owner").
public struct StudioSettings: Codable, Hashable, Sendable {
    public var maxGpus: Int
    public var overheadPayer: String
    public var capPerJob: Double
    public var capPerDay: Double
    public var capPerUserDay: Double
    public var tokenUsd: Double
    public var minRunpodBalance: Double
    public var lowBalance: Bool
    public var features: StudioFeatures
    /// Keep GPU warm: who may switch it on (owner | everyone, default everyone), the idle auto-off and the session cap.
    public var warmGpuAllowed: String
    public var warmIdleMinutes: Int
    public var warmMaxMinutes: Int

    public init(maxGpus: Int = 3, overheadPayer: String = "user", capPerJob: Double = 5, capPerDay: Double = 15, capPerUserDay: Double = 10, tokenUsd: Double = 0.01,
                minRunpodBalance: Double = 2, lowBalance: Bool = false, features: StudioFeatures = StudioFeatures(), warmGpuAllowed: String = "everyone",
                warmIdleMinutes: Int = 20, warmMaxMinutes: Int = 120) {
        self.warmGpuAllowed = warmGpuAllowed
        self.warmIdleMinutes = warmIdleMinutes
        self.warmMaxMinutes = warmMaxMinutes
        self.maxGpus = maxGpus
        self.overheadPayer = overheadPayer
        self.capPerJob = capPerJob
        self.capPerDay = capPerDay
        self.capPerUserDay = capPerUserDay
        self.tokenUsd = tokenUsd
        self.minRunpodBalance = minRunpodBalance
        self.lowBalance = lowBalance
        self.features = features
    }

    enum CodingKeys: String, CodingKey {
        case maxGpus, overheadPayer, capPerJob, capPerDay, capPerUserDay, tokenUsd, minRunpodBalance, lowBalance, features, warmGpuAllowed, warmIdleMinutes, warmMaxMinutes
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        maxGpus = c.v(.maxGpus, 3)
        overheadPayer = c.v(.overheadPayer, "user")
        capPerJob = c.v(.capPerJob, 5)
        capPerDay = c.v(.capPerDay, 15)
        capPerUserDay = c.v(.capPerUserDay, 10)
        tokenUsd = c.v(.tokenUsd, 0.01)
        minRunpodBalance = c.v(.minRunpodBalance, 2)
        lowBalance = c.v(.lowBalance, false)
        features = c.v(.features, StudioFeatures())
        warmGpuAllowed = c.v(.warmGpuAllowed, "everyone")
        warmIdleMinutes = c.v(.warmIdleMinutes, 20)
        warmMaxMinutes = c.v(.warmMaxMinutes, 120)
    }
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
    /// The Quality picker (newer servers). nil = use `VideoFeatures.fallback`.
    public var video: VideoFeatures?

    public init(standard: Bool = true, fastBeta: Bool = true, lipSync: Bool = true, loraTraining: Bool = true, replaceAudio: Bool = false, maxClipSec: Double = 15,
                replicate: Bool = false, video: VideoFeatures? = nil) {
        self.replicate = replicate
        self.video = video
        self.standard = standard
        self.fastBeta = fastBeta
        self.lipSync = lipSync
        self.loraTraining = loraTraining
        self.replaceAudio = replaceAudio
        self.maxClipSec = maxClipSec
    }

    enum CodingKeys: String, CodingKey { case standard, fastBeta, lipSync, loraTraining, replaceAudio, maxClipSec, replicate, video }
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
    }
}

/// `features.video` (GET /v1/settings/studio): the Quality picker's options and prices.
public struct VideoFeatures: Codable, Hashable, Sendable {
    public var defaultEngine: String
    public var defaultQuality: String
    public var minSeconds: Int
    public var maxSeconds: Int
    public var options: [VideoOption]

    public init(defaultEngine: String = "replicate", defaultQuality: String = VideoQuality.default.rawValue, minSeconds: Int = 4, maxSeconds: Int = 15, options: [VideoOption] = VideoOption.defaults) {
        self.defaultEngine = defaultEngine
        self.defaultQuality = defaultQuality
        self.minSeconds = minSeconds
        self.maxSeconds = maxSeconds
        self.options = options
    }

    enum CodingKeys: String, CodingKey { case defaultEngine, defaultQuality, minSeconds, maxSeconds, options }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        defaultEngine = c.v(.defaultEngine, "replicate")
        defaultQuality = c.v(.defaultQuality, VideoQuality.default.rawValue)
        minSeconds = c.v(.minSeconds, Pricing.replicateMinSec)
        maxSeconds = c.v(.maxSeconds, Pricing.replicateMaxSec)
        let read: [VideoOption] = c.v(.options, [])
        options = read.isEmpty ? VideoOption.defaults : read
    }

    /// For servers that don't send `features.video`: the contract's table, every option available.
    public static let fallback = VideoFeatures()

    /// The picker's default: Exact edit when the server's default engine is h3, else `defaultQuality` (Draft).
    public var defaultOption: VideoQuality {
        if defaultEngine == Engine.h3.rawValue { return .exact }
        return VideoQuality(id: defaultQuality).replicateOrDefault
    }

    public func option(_ q: VideoQuality) -> VideoOption { options.first { $0.id == q.rawValue } ?? VideoOption.make(q) }
    public func isAvailable(_ q: VideoQuality) -> Bool { option(q).available }
    /// The server's $ per second for a replicate quality (nil = the default).
    public func pricePerSec(_ q: VideoQuality) -> Double? { q.isReplicate ? (option(q).pricePerSec ?? q.defaultPricePerSec) : nil }
    /// Picker order: the server's, with any missing option added.
    public var ordered: [VideoOption] {
        var out = options.filter { VideoQuality(rawValue: $0.id) != nil }
        for q in VideoQuality.allCases where !out.contains(where: { $0.id == q.rawValue }) { out.append(VideoOption.make(q)) }
        return out
    }
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

    public static func make(_ q: VideoQuality, available: Bool = true) -> VideoOption {
        VideoOption(id: q.rawValue, label: q.label, detail: q.detail, engine: q.engine.rawValue, quality: q.requestQuality, resolution: q.resolution,
                    pricePerSec: q.defaultPricePerSec, available: available)
    }
    public static let defaults: [VideoOption] = VideoQuality.allCases.map { make($0) }
}

/// PATCH /v1/settings/studio: only the fields set are sent.
public struct StudioSettingsPatch: Codable, Sendable {
    public var maxGpus: Int?
    public var overheadPayer: String?
    public var capPerJob: Double?
    public var capPerDay: Double?
    public var capPerUserDay: Double?
    public var warmGpuAllowed: String?
    public var warmIdleMinutes: Int?
    public var warmMaxMinutes: Int?
    public init(maxGpus: Int? = nil, overheadPayer: String? = nil, capPerJob: Double? = nil, capPerDay: Double? = nil, capPerUserDay: Double? = nil,
                warmGpuAllowed: String? = nil, warmIdleMinutes: Int? = nil, warmMaxMinutes: Int? = nil) {
        self.warmGpuAllowed = warmGpuAllowed
        self.warmIdleMinutes = warmIdleMinutes
        self.warmMaxMinutes = warmMaxMinutes
        self.maxGpus = maxGpus
        self.overheadPayer = overheadPayer
        self.capPerJob = capPerJob
        self.capPerDay = capPerDay
        self.capPerUserDay = capPerUserDay
    }
}

/// `notice` on a wallet event (owners): owner_balance_low | owner_balance_ok.
public struct EventNotice: Codable, Hashable, Sendable {
    public var code: String
    public var message: String
    public init(code: String, message: String) {
        self.code = code
        self.message = message
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
    public var friendlyMessage: String { ApiError.friendly(code) ?? ApiError.inDollars(message) }

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
        case "owner_balance_low": return Job.pausedLine
        case "owner_only": return "Only the studio owner can do that."
        case "over_allocation": return "That's more than the studio's RunPod balance backs. Top up RunPod or send less."
        case "balance_unavailable": return "MUSE can't read the RunPod balance right now, so credit can't be sent. Try again in a minute."
        case "topup_unavailable": return "Top up your RunPod account. MUSE reads the balance from RunPod."
        case "upload_missing": return "The upload didn't arrive. Try again."
        case "provider_refused": return "Replicate's safety filter refused this photo. Try other references or wording. You weren't charged."
        case "provider_rate_limited": return "Replicate is busy right now. Try again in a minute. You weren't charged."
        default: return nil
        }
    }
}

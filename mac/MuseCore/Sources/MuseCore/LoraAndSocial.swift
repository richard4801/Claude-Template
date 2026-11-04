import Foundation

// Identity LoRA (plans/lora-training.md) and per-model social accounts and posts (plans/socials.md).
// Wire types follow plans/api.md. Decoding is lenient like the other types in Models.swift.

// MARK: Identity LoRA

/// Prices and limits for the Identity LoRA. These are estimates until one real training has run (lora-training.md, "Before we ship").
public enum LoraPricing {
    /// Shots generated for the training set.
    public static let candidates = 30
    /// The user must keep at least this many to train.
    public static let minKept = 20
    public static let photoMinutes = 25.0
    public static let videoMinutes = 75.0

    /// Building the training set: an estimate (30 new photos, "about $3.03"); it settles to the exact cost.
    public static var setCost: Double { PhotoPricing.standard.loraSet() }
    public static var photoCost: Double { photoMinutes / 60 * Pricing.gpuPerHour }
    public static var videoCost: Double { videoMinutes / 60 * Pricing.gpuPerHour }
    /// Training both LoRAs: (25 + 75) min at $3.99/h ≈ $6.65.
    public static var trainCost: Double { (photoMinutes + videoMinutes) / 60 * Pricing.gpuPerHour }
    /// "about $9.68" in total.
    public static var totalCost: Double { setCost + trainCost }
    /// "~1 h 40".
    public static var timeLabel: String {
        let m = Int(photoMinutes + videoMinutes)
        return m >= 60 ? "~\(m / 60) h \(String(format: "%02d", m % 60))" : "~\(m) min"
    }

    /// The photo bar runs over the first quarter of training, the video bar over the rest (the prototype's split).
    public static func photoProgress(_ overall: Double) -> Double { min(100, max(0, overall * 4)) }
    public static func videoProgress(_ overall: Double) -> Double { min(100, max(0, (overall - 25) / 75 * 100)) }
}

/// One generated training shot. `flag` marks a risky shot (tattoo, ring, choker, face drift); flagged shots start dropped.
public struct LoraCandidate: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var image: ImageRef
    public var label: String
    public var flag: String?
    public var keep: Bool

    public init(id: String, image: ImageRef, label: String, flag: String? = nil, keep: Bool? = nil) {
        self.id = id
        self.image = image
        self.label = label
        self.flag = flag
        self.keep = keep ?? (flag == nil)
    }

    enum CodingKeys: String, CodingKey { case id, image, label, flag, keep }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        image = c.v(.image, ImageRef())
        label = c.v(.label, "")
        let f: String? = c.o(.flag)
        flag = (f?.isEmpty ?? true) ? nil : f
        keep = c.v(.keep, flag == nil)
    }
}

/// Progress of one of the two LoRAs (photo or video).
public struct LoraPart: Codable, Hashable, Sendable {
    public var state: String
    public var progress: Double

    public init(state: String = "none", progress: Double = 0) {
        self.state = state
        self.progress = progress
    }

    enum CodingKeys: String, CodingKey { case state, progress }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        state = c.v(.state, "none")
        progress = c.v(.progress, 0)
    }
}

/// A model's Identity LoRA. state: none | building | review | training | ready | failed.
/// `version` is the latest trained version (0 = never trained). A retrain keeps using the previous version until the new one is ready.
public struct Lora: Codable, Hashable, Sendable {
    public var modelId: String
    public var version: Int
    public var state: String
    public var use: Bool
    public var candidates: [LoraCandidate]
    public var progress: Double
    public var photo: LoraPart
    public var video: LoraPart
    public var cost: Double
    /// Shots the current version was trained on.
    public var trainedOn: Int?

    public init(modelId: String, version: Int = 0, state: String = "none", use: Bool = true, candidates: [LoraCandidate] = [], progress: Double = 0,
                photo: LoraPart = LoraPart(), video: LoraPart = LoraPart(), cost: Double = 0, trainedOn: Int? = nil) {
        self.modelId = modelId
        self.version = version
        self.state = state
        self.use = use
        self.candidates = candidates
        self.progress = progress
        self.photo = photo
        self.video = video
        self.cost = cost
        self.trainedOn = trainedOn
    }

    enum CodingKeys: String, CodingKey { case modelId, version, state, use, candidates, progress, photo, video, cost, trainedOn }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        modelId = c.v(.modelId, "")
        version = c.v(.version, 0)
        state = c.v(.state, "none")
        use = c.v(.use, true)
        candidates = c.v(.candidates, [])
        progress = c.v(.progress, 0)
        photo = c.v(.photo, LoraPart())
        video = c.v(.video, LoraPart())
        cost = c.v(.cost, 0)
        trainedOn = c.o(.trainedOn)
    }

    public var kept: Int { candidates.filter(\.keep).count }
    public var flagged: Int { candidates.filter { $0.flag != nil }.count }
    public var canTrain: Bool { state == "review" && kept >= LoraPricing.minKept }
    public var isReady: Bool { state == "ready" }
    public var isBusy: Bool { state == "building" || state == "training" }
    /// The version new renders use, or nil when there's no trained version or the user turned it off.
    public var activeVersion: Int? { use && version > 0 ? version : nil }

    /// The trigger token, e.g. "sienna_v1": the model's first name, lower-case letters and digits only.
    public static func token(modelName: String, version: Int) -> String {
        let first = modelName.split(separator: " ").first.map(String.init) ?? modelName
        let clean = first.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
        let base = clean.isEmpty ? "model" : String(String.UnicodeScalarView(clean))
        return "\(base)_v\(version)"
    }

    /// The token the prompt engine adds, or nil when the LoRA is off or not trained.
    public func promptToken(modelName: String) -> String? { activeVersion.map { Self.token(modelName: modelName, version: $0) } }
}

public struct LoraCandidateRequest: Codable, Sendable {
    public var keep: Bool
    public init(keep: Bool) { self.keep = keep }
}

/// PATCH /v1/models/{id}/lora {use?, state?: "review"}.
public struct LoraPatchRequest: Codable, Sendable {
    public var use: Bool?
    public var state: String?
    public init(use: Bool? = nil, state: String? = nil) {
        self.use = use
        self.state = state
    }
}

// MARK: Social accounts

public enum Platform: String, Codable, CaseIterable, Sendable, Identifiable {
    case tiktok, instagram, facebook, youtube, x
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .tiktok: return "TikTok"
        case .instagram: return "Instagram"
        case .facebook: return "Facebook"
        case .youtube: return "YouTube"
        case .x: return "X"
        }
    }

    /// The letters on the coloured badge (no brand logos).
    public var badge: String {
        switch self {
        case .tiktok: return "TT"
        case .instagram: return "IG"
        case .facebook: return "f"
        case .youtube: return "YT"
        case .x: return "X"
        }
    }

    /// Badge colour, 0xRRGGBB.
    public var color: UInt32 {
        switch self {
        case .tiktok, .x: return 0x111111
        case .instagram: return 0xD62976
        case .facebook: return 0x1877F2
        case .youtube: return 0xFF0000
        }
    }

    /// Stage 1 handoff: where the Mac opens to post by hand.
    public var uploadURL: URL {
        switch self {
        case .tiktok: return URL(string: "https://www.tiktok.com/upload")!
        case .instagram: return URL(string: "https://www.instagram.com/")!
        case .facebook: return URL(string: "https://www.facebook.com/")!
        case .youtube: return URL(string: "https://studio.youtube.com/")!
        case .x: return URL(string: "https://x.com/compose/post")!
        }
    }

    /// Whether the platform has its own field for each label (socials.md, "Labels are the user's choice"). X has neither.
    public var hasAILabel: Bool { self != .x }
    public var hasPaidLabel: Bool { self != .x }
}

/// A model's own account on one platform. `canPostDirect` is false until that platform approves MUSE (stage 1).
public struct Account: Codable, Hashable, Sendable, Identifiable {
    public var modelId: String
    public var platform: Platform
    public var handle: String
    public var connectedAt: Int64
    public var canPostDirect: Bool
    public var id: String { "\(modelId)/\(platform.rawValue)" }

    public init(modelId: String, platform: Platform, handle: String, connectedAt: Int64 = 0, canPostDirect: Bool = false) {
        self.modelId = modelId
        self.platform = platform
        self.handle = handle
        self.connectedAt = connectedAt
        self.canPostDirect = canPostDirect
    }

    enum CodingKeys: String, CodingKey { case modelId, platform, handle, connectedAt, canPostDirect }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        modelId = c.v(.modelId, "")
        platform = try c.decode(Platform.self, forKey: .platform)
        handle = c.v(.handle, "")
        connectedAt = c.v(.connectedAt, 0)
        canPostDirect = c.v(.canPostDirect, false)
    }
}

/// POST …/accounts/{platform}/connect: either an OAuth URL to open, or (the mock) the connected account.
public enum ConnectResult: Sendable, Equatable {
    case connected(Account)
    case authorize(URL)

    /// Accepts `{authUrl}`, `{account}` or a bare `Account`.
    public static func decode(_ data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> ConnectResult {
        struct Wrapper: Decodable {
            var authUrl: String?
            var account: Account?
        }
        if let w = try? decoder.decode(Wrapper.self, from: data) {
            if let a = w.account { return .connected(a) }
            if let s = w.authUrl, let u = URL(string: s) { return .authorize(u) }
        }
        return .connected(try decoder.decode(Account.self, from: data))
    }
}

// MARK: Posts

public struct PostStats: Codable, Hashable, Sendable {
    public var views: Int
    public var likes: Int
    public var comments: Int

    public init(views: Int, likes: Int, comments: Int) {
        self.views = views
        self.likes = likes
        self.comments = comments
    }

    enum CodingKeys: String, CodingKey { case views, likes, comments }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        views = c.v(.views, 0)
        likes = c.v(.likes, 0)
        comments = c.v(.comments, 0)
    }

    /// "1,240 views · 136 likes · 9 comments"
    public var line: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        func n(_ v: Int) -> String { f.string(from: NSNumber(value: v)) ?? "\(v)" }
        return "\(n(views)) views · \(n(likes)) likes · \(n(comments)) comments"
    }
}

/// A post of one take to some of the model's accounts. state: scheduled | handoff | posted | failed.
/// `when` is "now" or an ISO 8601 time. `aiLabel` and `paidPartnership` are only ever set by the user.
public struct Post: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var modelId: String
    public var takeId: String
    public var platforms: [Platform]
    public var caption: String
    public var aiLabel: Bool
    public var paidPartnership: Bool
    public var when: String
    public var state: String
    public var stats: PostStats?
    /// The take's title and thumbnail, so the Posts page can show a post whose take is gone.
    public var title: String
    public var thumb: ImageRef?
    public var createdAt: Int64
    public var postedAt: Int64?

    public init(id: String, modelId: String, takeId: String, platforms: [Platform], caption: String = "", aiLabel: Bool = false, paidPartnership: Bool = false,
                when: String = "now", state: String = "handoff", stats: PostStats? = nil, title: String = "", thumb: ImageRef? = nil, createdAt: Int64 = 0,
                postedAt: Int64? = nil) {
        self.title = title
        self.thumb = thumb
        self.createdAt = createdAt
        self.postedAt = postedAt
        self.id = id
        self.modelId = modelId
        self.takeId = takeId
        self.platforms = platforms
        self.caption = caption
        self.aiLabel = aiLabel
        self.paidPartnership = paidPartnership
        self.when = when
        self.state = state
        self.stats = stats
    }

    enum CodingKeys: String, CodingKey { case id, modelId, takeId, platforms, caption, aiLabel, paidPartnership, when, state, stats, title, thumb, createdAt, postedAt }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        modelId = c.v(.modelId, "")
        takeId = c.v(.takeId, "")
        // Unknown platforms from a newer server are skipped rather than failing the whole post.
        let raw: [String] = c.v(.platforms, [])
        platforms = raw.compactMap(Platform.init(rawValue:))
        caption = c.v(.caption, "")
        aiLabel = c.v(.aiLabel, false)
        paidPartnership = c.v(.paidPartnership, false)
        when = c.v(.when, "now")
        state = c.v(.state, "handoff")
        stats = c.o(.stats)
        title = c.v(.title, "")
        thumb = c.o(.thumb)
        createdAt = c.v(.createdAt, 0)
        postedAt = c.o(.postedAt)
    }

    public var isScheduled: Bool { state == "scheduled" }
    /// Posted, or handed off to the platform's app (stage 1). Shown under "Posted".
    public var isOut: Bool { state == "posted" || state == "handoff" }
    public var scheduledDate: Date? { PostTime.parse(when) }
}

public struct CreatePostRequest: Codable, Sendable, Equatable {
    public var modelId: String
    public var takeId: String
    public var platforms: [Platform]
    public var caption: String
    /// Off unless the user turns it on. MUSE never sets it by itself.
    public var aiLabel: Bool
    /// Off unless the user turns it on. MUSE never sets it by itself.
    public var paidPartnership: Bool
    public var when: String

    public init(modelId: String, takeId: String, platforms: [Platform], caption: String = "", aiLabel: Bool = false, paidPartnership: Bool = false, when: String = "now") {
        self.modelId = modelId
        self.takeId = takeId
        self.platforms = platforms
        self.caption = caption
        self.aiLabel = aiLabel
        self.paidPartnership = paidPartnership
        self.when = when
    }
}

/// ISO 8601 times for `Post.when`.
public enum PostTime {
    public static func string(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    public static func parse(_ s: String) -> Date? {
        guard s != "now" else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// The Schedule chips: today 7:30 PM (or tomorrow if that has passed), tomorrow 12:00 PM, and the next Friday 6:00 PM.
    public static func suggestions(now: Date = Date(), calendar: Calendar = .current) -> [Date] {
        func at(_ day: Date, _ h: Int, _ m: Int) -> Date { calendar.date(bySettingHour: h, minute: m, second: 0, of: day) ?? day }
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        var evening = at(today, 19, 30)
        if evening <= now { evening = at(tomorrow, 19, 30) }
        let noon = at(tomorrow, 12, 0)
        var friday = calendar.nextDate(after: tomorrow, matching: DateComponents(hour: 18, minute: 0, weekday: 6), matchingPolicy: .nextTime) ?? at(tomorrow, 18, 0)
        if friday == evening || friday == noon { friday = calendar.date(byAdding: .day, value: 7, to: friday) ?? friday }
        return [evening, noon, friday]
    }

    /// "Today · 7:30 PM", "Tomorrow · 12:00 PM", "Fri · 6:00 PM".
    public static func label(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let t = DateFormatter()
        t.locale = Locale(identifier: "en_US")
        t.timeZone = calendar.timeZone
        t.dateFormat = "h:mm a"
        let time = t.string(from: d)
        if calendar.isDate(d, inSameDayAs: now) { return "Today · \(time)" }
        if let tm = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(d, inSameDayAs: tm) { return "Tomorrow · \(time)" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: d)).day ?? 0
        t.dateFormat = days < 7 && days > 0 ? "EEE" : "MMM d"
        return "\(t.string(from: d)) · \(time)"
    }
}

// MARK: Model edits

/// PATCH /v1/models/{id}. Only the fields that are set are sent.
public struct UpdateModelRequest: Codable, Sendable, Equatable {
    public var name: String?
    public var niche: String?
    public var personality: String?
    public var notes: String?
    public var neverAdd: [String]?

    public init(name: String? = nil, niche: String? = nil, personality: String? = nil, notes: String? = nil, neverAdd: [String]? = nil) {
        self.name = name
        self.niche = niche
        self.personality = personality
        self.notes = notes
        self.neverAdd = neverAdd
    }
}

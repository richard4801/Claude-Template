import Foundation

/// Video engine (wire values only; members never see these names). `replicate` renders Draft / Standard / HD, `h3` is the
/// **Edit** add-on, `viggle` is **Fast · beta** (plans/api.md "App clean-up" §2).
public enum Engine: String, Codable, CaseIterable, Sendable {
    case replicate
    case h3
    case viggle

    /// What members see.
    public var label: String {
        switch self {
        case .replicate: return "Standard"
        case .h3: return "Edit"
        case .viggle: return "Fast · beta"
        }
    }

    /// Runs on the add-on engine (start-up, Keep add-on engine ready).
    public var isAddOnEngine: Bool { self != .replicate }

    public init(id: String) { self = Engine(rawValue: id) ?? .h3 }
}

/// The video studio's choice: **Render** (Draft / Standard / HD) or an **add-on** (Edit, Fast · beta). Default Draft,
/// the owner's choice on 2026-11-04 (`features.video.defaultQuality`).
public enum VideoQuality: String, Codable, CaseIterable, Sendable, Identifiable {
    case draft
    case standard
    case hd
    case edit
    case fast

    public var id: String { rawValue }
    public static let `default` = VideoQuality.draft
    /// The Render picker, in order.
    public static let renders: [VideoQuality] = [.draft, .standard, .hd]
    /// The add-ons that render a clip (Upscale works on a finished take instead).
    public static let addOns: [VideoQuality] = [.edit, .fast]

    /// Unknown or missing ids are the default. "exact" (older servers and saved settings) is Edit.
    public init(id: String?) {
        if id == "exact" { self = .edit; return }
        self = VideoQuality(rawValue: id ?? "") ?? .default
    }

    public var label: String {
        switch self {
        case .draft: return "Draft"
        case .standard: return "Standard"
        case .hd: return "HD"
        case .edit: return "Edit"
        case .fast: return "Fast · beta"
        }
    }

    public var detail: String {
        switch self {
        case .draft: return "Quick preview · 768P"
        case .standard: return "768P"
        case .hd: return "2K"
        case .edit: return "Swaps her into every frame of the whole clip"
        case .fast: return "Quicker and rougher · beta"
        }
    }

    public var resolution: String? {
        switch self {
        case .draft, .standard: return "768P"
        case .hd: return "2K"
        case .edit, .fast: return nil
        }
    }

    /// The contract's default $ per output second (the server's `features.video.options[].pricePerSec` wins once read).
    public var defaultPricePerSec: Double? {
        switch self {
        case .draft: return 0.02
        case .standard: return 0.08
        case .hd: return 0.13
        case .edit, .fast: return nil
        }
    }

    public var isReplicate: Bool { VideoQuality.renders.contains(self) }
    public var isAddOn: Bool { !isReplicate }
    public var engine: Engine {
        switch self {
        case .draft, .standard, .hd: return .replicate
        case .edit: return .h3
        case .fast: return .viggle
        }
    }
    /// The `quality` field of a JobRequest (replicate only).
    public var requestQuality: String? { isReplicate ? rawValue : nil }

    /// The option a job was made with: replicate jobs by their quality, h3 = Edit, viggle = Fast · beta.
    public static func of(engine: Engine, quality: String?) -> VideoQuality {
        switch engine {
        case .replicate: return VideoQuality(id: quality).replicateOrDefault
        case .h3: return .edit
        case .viggle: return .fast
        }
    }

    /// Draft / Standard / HD as is; anything else is the default (Draft).
    public var replicateOrDefault: VideoQuality { isReplicate ? self : .default }
}

/// Which part of the source clip is rendered. Members always render the whole clip (the "first 5.2 s" choice is gone);
/// it stays for the prototype pricing fixtures and older jobs.
public enum ClipUse: String, Codable, CaseIterable, Sendable {
    case first
    case full

    /// The prototype's sample clip lengths.
    public var sampleSeconds: Double { self == .first ? 5.2 : 9.4 }

    public init(id: String) { self = ClipUse(rawValue: id) ?? .first }
}

/// Everything that changes the price of a render. Mirrors the prototype's `S.engine / S.use / S.steps / S.lip / S.takes`.
public struct RenderSpec: Equatable, Sendable {
    public var engine: Engine
    public var use: ClipUse
    public var steps: Int
    public var lipSync: Bool
    public var takes: Int
    /// Real length of the picked clip. nil = the prototype's 9.4 s sample clip.
    public var clipSeconds: Double?
    /// Replicate only: draft | standard | hd.
    public var quality: VideoQuality
    /// Replicate only: $ per output second from the server's `features.video`; nil = the contract default for `quality`.
    public var pricePerSec: Double?

    public init(engine: Engine = .h3, use: ClipUse = .first, steps: Int = Pricing.stepsDefault, lipSync: Bool = false, takes: Int = 1, clipSeconds: Double? = nil,
                quality: VideoQuality = .default, pricePerSec: Double? = nil) {
        self.engine = engine
        self.use = use
        self.steps = steps
        self.lipSync = lipSync
        self.takes = takes
        self.clipSeconds = clipSeconds
        self.quality = quality
        self.pricePerSec = pricePerSec
    }

    /// A Replicate render (always the whole clip).
    public static func replicate(_ quality: VideoQuality, clipSeconds: Double?, takes: Int = 1, pricePerSec: Double? = nil) -> RenderSpec {
        RenderSpec(engine: .replicate, use: .full, takes: takes, clipSeconds: clipSeconds, quality: quality, pricePerSec: pricePerSec)
    }

    /// An add-on render as members make it: the whole clip and the default steps.
    public static func addOn(_ q: VideoQuality, clipSeconds: Double?, takes: Int = 1, lipSync: Bool = false) -> RenderSpec {
        RenderSpec(engine: q == .fast ? .viggle : .h3, use: .full, steps: Pricing.stepsDefault, lipSync: q == .edit && lipSync, takes: takes, clipSeconds: clipSeconds)
    }

    /// The studio's choice: Render (Draft / Standard / HD) or an add-on (Edit, Fast · beta).
    public static func choice(_ q: VideoQuality, clipSeconds: Double?, takes: Int = 1, lipSync: Bool = false, pricePerSec: Double? = nil) -> RenderSpec {
        q.isReplicate ? replicate(q, clipSeconds: clipSeconds, takes: takes, pricePerSec: pricePerSec) : addOn(q, clipSeconds: clipSeconds, takes: takes, lipSync: lipSync)
    }

    public var isReplicate: Bool { engine == .replicate }
    /// The option this spec belongs to.
    public var videoQuality: VideoQuality { isReplicate ? quality.replicateOrDefault : VideoQuality.of(engine: engine, quality: nil) }
    /// $ per output second for a replicate spec.
    public var replicatePricePerSec: Double { pricePerSec ?? quality.replicateOrDefault.defaultPricePerSec ?? 0.02 }
    /// Replicate's billed output length D (whole seconds, 4–15).
    public var replicateSeconds: Int { Pricing.replicateSeconds(clipSeconds) }

    /// Seconds actually rendered (the prototype's `LENS()`): the first 5.2 s, or the whole clip up to the 15 s single-pass limit.
    /// Replicate always renders the whole clip (each take is trimmed back to its exact length).
    public var lengthSec: Double {
        if isReplicate { return min(clipSeconds ?? ClipUse.full.sampleSeconds, Pricing.maxClipSec) }
        switch use {
        case .first: return min(ClipUse.first.sampleSeconds, clipSeconds ?? ClipUse.first.sampleSeconds)
        case .full: return min(clipSeconds ?? ClipUse.full.sampleSeconds, Pricing.maxClipSec)
        }
    }
}

/// The pricing maths from prototype/desktop/desktop.js (`secPerLen`, `estMin`, `estCost`, `fmtMin`, `stepsDelta`, `genLabel`), ported 1:1.
/// Measured on an H100 with FlashAttention 3: 57.8 s per step for a 5.2 s clip, billed at $3.99/h.
public enum Pricing {
    public static let stepsMin = 4
    public static let stepsMax = 30
    public static let stepsDefault = 10
    public static let takesMax = 4
    public static let secPerStep5s = 57.8
    public static let gpuPerHour = 3.99
    public static let gpuStartupMin = 0.5
    public static let lipSyncMin = 4.0
    public static let viggleMin5s = 1.6
    public static let viggleCost5s = 0.13
    public static let baseLen = 5.2
    public static let maxClipSec = 15.0

    /// Photo prices are estimates now: `PhotoPricing` (plans/api.md "App clean-up" §3). Receipts show the exact settled amount.
    /// Default spend caps (Settings → Costs & limits).
    public static let perJobCap = 5.0
    public static let perDayCap = 15.0

    /// Seconds per denoising step for a clip of `len` seconds.
    public static func secPerLen(_ len: Double) -> Double { secPerStep5s * pow(len / baseLen, 1.3) }

    public static func clampSteps(_ n: Int) -> Int { min(stepsMax, max(stepsMin, n)) }
    /// A price in whole wallet tokens (rounded up, like the server's hold). 1 token = $0.01 by default. The UI shows dollars only.
    public static func tokens(_ usd: Double, _ tokenUsd: Double = 0.01) -> Int { Int((usd / max(tokenUsd, 0.0001) - 1e-6).rounded(.up)) }
    /// A dollar amount the user typed, as whole wallet tokens for the API: rounded to the nearest cent, then converted at `tokenUsd`.
    public static func tokensForDollars(_ usd: Double, _ tokenUsd: Double = 0.01) -> Int {
        let cents = (usd * 100).rounded()
        return Int((cents / 100 / max(tokenUsd, 0.0001)).rounded())
    }
    /// Parses "$5", "5.5", "1,250.00" → dollars rounded to 2 decimals; nil if it isn't a non-negative amount.
    public static func parseDollars(_ text: String) -> Double? {
        let s = text.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, let v = Double(s), v.isFinite, v >= 0 else { return nil }
        return (v * 100).rounded() / 100
    }
    public static func clampTakes(_ n: Int) -> Int { min(takesMax, max(1, n)) }

    // MARK: Replicate (Draft / Standard / HD), plans/api.md "Pricing"

    public static let replicateMinSec = 4
    public static let replicateMaxSec = 15

    /// D = min(15, max(4, ceil(clipSeconds − 0.001))). No clip (the sample) = 9.4 s → 10.
    public static func replicateSeconds(_ clipSeconds: Double?, min lo: Int = replicateMinSec, max hi: Int = replicateMaxSec) -> Int {
        let c = clipSeconds ?? ClipUse.full.sampleSeconds
        return Swift.min(hi, Swift.max(lo, Int((c - 0.001).rounded(.up))))
    }

    /// pricePerSec × D × takes, left to right in doubles (the shared fixture's `cost`).
    public static func replicateCost(pricePerSec: Double, seconds: Int, takes: Int) -> Double {
        pricePerSec * Double(seconds) * Double(max(1, takes))
    }

    /// " · 2 takes" when takes > 1.
    static func takesTail(_ takes: Int) -> String { takes > 1 ? " · \(takes) takes" : "" }

    /// The line under the picker: "about $0.56 · 7 s" for Draft / Standard / HD, "about $0.67" for Edit and Fast · beta
    /// (no minutes, no steps), + " · 2 takes".
    public static func priceLine(_ s: RenderSpec) -> String {
        if !s.isReplicate { return "about \(money(totalCost(s)))\(takesTail(s.takes))" }
        return "about \(money(totalCost(s))) · \(s.replicateSeconds) s\(takesTail(s.takes))"
    }

    /// Replicate's estimated wall time for ONE take, for the queue and the demo backend: the line, a start, ~15 s per output second.
    public static let replicateBaseMin = 1.0
    public static let replicateMinPerSec = 0.25

    /// Estimated minutes for ONE take.
    public static func estMin(_ s: RenderSpec) -> Double {
        let len = s.lengthSec
        if s.isReplicate { return replicateBaseMin + replicateMinPerSec * Double(s.replicateSeconds) }
        if s.engine == .viggle { return viggleMin5s * (len / baseLen) }
        return Double(s.steps) * secPerLen(len) / 60 + gpuStartupMin + (s.lipSync ? lipSyncMin : 0)
    }

    /// Estimated dollars for ONE take.
    public static func estCost(_ s: RenderSpec) -> Double {
        let len = s.lengthSec
        if s.isReplicate { return s.replicatePricePerSec * Double(s.replicateSeconds) }
        if s.engine == .viggle { return viggleCost5s * (len / baseLen) }
        return estMin(s) / 60 * gpuPerHour
    }

    public static func totalMin(_ s: RenderSpec) -> Double { estMin(s) * Double(max(1, s.takes)) }
    public static func totalCost(_ s: RenderSpec) -> Double {
        if s.isReplicate { return replicateCost(pricePerSec: s.replicatePricePerSec, seconds: s.replicateSeconds, takes: s.takes) }
        return estCost(s) * Double(max(1, s.takes))
    }
    public static func totalSeconds(_ s: RenderSpec) -> Double { totalMin(s) * 60 }

    /// `fmtMin`: "38s" under two minutes, otherwise "10 min".
    public static func fmtMin(_ m: Double) -> String { m < 2 ? "\(jsRound(m * 60))s" : "\(jsRound(m)) min" }

    /// The Generate button: "Generate · $0.56" (+ " · 2 takes"), for every option (plans/api.md "App clean-up" §2).
    public static func genLabel(_ s: RenderSpec) -> String { "Generate · \(money(totalCost(s)))\(takesTail(s.takes))" }

    /// The prototype's button ("Generate · 10 min · $0.67", "Generate 3 takes · 30 min · $2.02"), kept only to check the
    /// prototype's pricing fixtures; the app shows `genLabel`.
    static func prototypeGenLabel(_ s: RenderSpec) -> String {
        "Generate\(s.takes > 1 ? " \(s.takes) takes" : "") · \(fmtMin(totalMin(s))) · \(money(totalCost(s)))"
    }

    /// The prototype's hint under its steps control, kept only to check the prototype's pricing fixtures (members never see steps).
    static func stepsDelta(_ s: RenderSpec) -> String {
        if s.steps == stepsDefault { return "Same quality as 15 or 20 steps in testing, for less time." }
        let d = Double(s.steps - stepsDefault) * secPerLen(s.lengthSec) / 60
        let c = d / 60 * gpuPerHour
        let sign = d > 0 ? "+" : "−"
        let tail = s.steps > stepsDefault ? " · no visible gain in testing" : " · may lose detail"
        return "\(sign)\(toFixed(abs(d), 1)) min · \(sign)\(money(abs(c))) vs 10 steps\(tail)"
    }

    /// A typical render for the "≈ 30 Draft videos" hint: Draft on a 10 s clip.
    public static var typicalVideo: Double { totalCost(.replicate(.draft, clipSeconds: 10)) }

    /// "≈ 30 Draft videos": how many typical Draft renders a balance covers.
    public static func videosLeft(_ balance: Double) -> Int { max(0, Int(floor(balance / typicalVideo + 1e-9))) }

    /// JavaScript `'$' + v.toFixed(2)`.
    public static func money(_ v: Double) -> String { "$" + toFixed(v, 2) }

    /// JavaScript `Number.prototype.toFixed`: rounds the exact binary value, ties away from zero.
    public static func toFixed(_ v: Double, _ digits: Int) -> String {
        if !v.isFinite { return String(v) }
        let neg = v < 0
        // 40 fractional digits are more than enough to see past any double near a tie.
        let s = String(format: "%.40f", abs(v))
        let parts = s.split(separator: ".", maxSplits: 1).map(String.init)
        var intDigits = Array(parts[0])
        let frac = Array(parts.count > 1 ? parts[1] : "")
        var keep = Array(frac.prefix(digits))
        while keep.count < digits { keep.append("0") }
        let roundUp = frac.count > digits && frac[digits] >= "5"
        if roundUp {
            var all = intDigits + keep
            var i = all.count - 1
            var carry = true
            while carry && i >= 0 {
                if all[i] == "9" { all[i] = "0"; i -= 1 } else { all[i] = Character(String(all[i].wholeNumberValue! + 1)); carry = false }
            }
            if carry { all.insert("1", at: 0) }
            intDigits = Array(all.prefix(all.count - digits))
            keep = Array(all.suffix(digits))
        }
        var out = String(intDigits)
        if digits > 0 { out += "." + String(keep) }
        if neg && out.contains(where: { $0 >= "1" && $0 <= "9" }) { out = "-" + out }
        return out
    }

    /// JavaScript `Math.round`: halves round towards +infinity.
    public static func jsRound(_ v: Double) -> Int { Int(floor(v + 0.5)) }

    /// 9.4 → "9.4", 15.0 → "15".
    public static func trimNum(_ v: Double) -> String {
        let s = toFixed(v, 1)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }
}

/// "05:35" countdowns.
public func formatClock(_ seconds: Double) -> String {
    let s = Pricing.jsRound(max(0, seconds))
    return String(format: "%02d:%02d", s / 60, s % 60)
}

/// Photo prices (plans/api.md "App clean-up" §3): every photo action holds an **estimate** and settles to the exact engine cost.
/// `GET /v1/settings/studio` → `features.photo`. The formulas run in doubles, left to right, like the server and Android
/// (shared fixture `photo_pricing_fixture.json`).
public struct PhotoPricing: Codable, Hashable, Sendable {
    public var perRun: Double
    public var perInputMp: Double
    public var perOutputMp: Double
    public var perEdit: Double
    public var refMp: Double
    public var maxRefs: Int
    public var loraShots: Int
    public var estimates: Estimates?

    public struct Estimates: Codable, Hashable, Sendable {
        public var shoot: Double?
        public var outfitSet: Double?
        public var sheetAngle: Double?
        public var loraSet: Double?
        public init(shoot: Double? = nil, outfitSet: Double? = nil, sheetAngle: Double? = nil, loraSet: Double? = nil) {
            self.shoot = shoot
            self.outfitSet = outfitSet
            self.sheetAngle = sheetAngle
            self.loraSet = loraSet
        }
    }

    public init(perRun: Double = 0.015, perInputMp: Double = 0.015, perOutputMp: Double = 0.015, perEdit: Double = 0.03, refMp: Double = 0.79, maxRefs: Int = 6,
                loraShots: Int = 30, estimates: Estimates? = nil) {
        self.perRun = perRun
        self.perInputMp = perInputMp
        self.perOutputMp = perOutputMp
        self.perEdit = perEdit
        self.refMp = refMp
        self.maxRefs = maxRefs
        self.loraShots = loraShots
        self.estimates = estimates
    }

    enum CodingKeys: String, CodingKey { case perRun, perInputMp, perOutputMp, perEdit, refMp, maxRefs, loraShots, estimates }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let z = PhotoPricing()
        perRun = c.v(.perRun, z.perRun)
        perInputMp = c.v(.perInputMp, z.perInputMp)
        perOutputMp = c.v(.perOutputMp, z.perOutputMp)
        perEdit = c.v(.perEdit, z.perEdit)
        refMp = c.v(.refMp, z.refMp)
        maxRefs = c.v(.maxRefs, z.maxRefs)
        loraShots = c.v(.loraShots, z.loraShots)
        estimates = c.o(.estimates)
    }

    /// The contract's defaults (FLUX.2 [pro] and the edit model's published prices), for servers that don't send `features.photo`.
    public static let standard = PhotoPricing()

    /// Megapixels of a shoot photo (1080×1920 asks for "2 MP") and of everything else.
    public static let shootOutMp = 2.0
    public static let otherOutMp = 1.0
    public static let shootCount = 4

    /// One new photo: perRun + perOutputMp × outMp + perInputMp × refMp × min(refs, maxRefs).
    public func newShot(outMp: Double, refs: Int) -> Double {
        perRun + perOutputMp * outMp + perInputMp * refMp * Double(min(max(0, refs), maxRefs))
    }

    /// A photoshoot of `count` photos (1–4).
    public func shoot(count: Int = PhotoPricing.shootCount, refs: Int? = nil) -> Double {
        Double(count) * newShot(outMp: PhotoPricing.shootOutMp, refs: refs ?? maxRefs)
    }

    /// An outfit set: the front is a new photo, ¾ / side / back are edits of it. "My own set" is free.
    public func outfitSet(refs: Int? = nil) -> Double {
        newShot(outMp: PhotoPricing.otherOutMp, refs: refs ?? maxRefs) + 3 * perEdit
    }

    /// Filling `missing` character-sheet angles.
    public func sheetAngles(_ missing: Int, refs: Int? = nil) -> Double {
        Double(missing) * newShot(outMp: PhotoPricing.otherOutMp, refs: refs ?? maxRefs)
    }

    /// The LoRA training set (`loraShots` photos).
    public func loraSet(refs: Int? = nil) -> Double {
        Double(loraShots) * newShot(outMp: PhotoPricing.otherOutMp, refs: refs ?? maxRefs)
    }

    /// "about $0.46".
    public static func label(_ estimate: Double) -> String { "about " + Pricing.money(estimate) }
}

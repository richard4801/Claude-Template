import Foundation

/// Video engine. User-facing names: "Standard" (MiniMax H3) and "Fast · beta" (Viggle).
public enum Engine: String, Codable, CaseIterable, Sendable {
    case h3
    case viggle

    public var label: String { self == .h3 ? "Standard" : "Fast · beta" }

    public init(id: String) { self = Engine(rawValue: id) ?? .h3 }
}

/// Which part of the source clip is rendered.
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

    public init(engine: Engine = .h3, use: ClipUse = .first, steps: Int = Pricing.stepsDefault, lipSync: Bool = false, takes: Int = 1, clipSeconds: Double? = nil) {
        self.engine = engine
        self.use = use
        self.steps = steps
        self.lipSync = lipSync
        self.takes = takes
        self.clipSeconds = clipSeconds
    }

    /// Seconds actually rendered (the prototype's `LENS()`): the first 5.2 s, or the whole clip up to H3's 15 s single-pass limit.
    public var lengthSec: Double {
        switch use {
        case .first: return min(ClipUse.first.sampleSeconds, clipSeconds ?? ClipUse.first.sampleSeconds)
        case .full: return min(clipSeconds ?? ClipUse.full.sampleSeconds, Pricing.maxClipSec)
        }
    }

    /// "First 5.2s" / "Full 9.4s" for the timeline's Use control.
    public var useLabel: String { Self.useLabel(use, clipSeconds: clipSeconds) }

    public static func useLabel(_ use: ClipUse, clipSeconds: Double?) -> String {
        let len = RenderSpec(use: use, clipSeconds: clipSeconds).lengthSec
        return (use == .first ? "First " : "Full ") + Pricing.trimNum(len) + "s"
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

    /// Photoshoot: 4 stills. plans/api.md fixes this at $0.12 for every client and the server
    /// (the desktop prototype showed an older "$0.08").
    public static let shootCost = 0.12
    public static let shootLabel = "Shoot 4 · ~32s · $0.12"
    /// Outfit set: 4 angles on one seed.
    public static let outfitSetCost = 0.08
    /// Character sheet: fill one missing angle from the user's images.
    public static let fillAngleCost = 0.02
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

    /// Estimated minutes for ONE take.
    public static func estMin(_ s: RenderSpec) -> Double {
        let len = s.lengthSec
        if s.engine == .viggle { return viggleMin5s * (len / baseLen) }
        return Double(s.steps) * secPerLen(len) / 60 + gpuStartupMin + (s.lipSync ? lipSyncMin : 0)
    }

    /// Estimated dollars for ONE take.
    public static func estCost(_ s: RenderSpec) -> Double {
        let len = s.lengthSec
        if s.engine == .viggle { return viggleCost5s * (len / baseLen) }
        return estMin(s) / 60 * gpuPerHour
    }

    public static func totalMin(_ s: RenderSpec) -> Double { estMin(s) * Double(max(1, s.takes)) }
    public static func totalCost(_ s: RenderSpec) -> Double { estCost(s) * Double(max(1, s.takes)) }
    public static func totalSeconds(_ s: RenderSpec) -> Double { totalMin(s) * 60 }

    /// `fmtMin`: "38s" under two minutes, otherwise "10 min".
    public static func fmtMin(_ m: Double) -> String { m < 2 ? "\(jsRound(m * 60))s" : "\(jsRound(m)) min" }

    /// "Generate · 10 min · $0.67", or "Generate 3 takes · 30 min · $2.02".
    public static func genLabel(_ s: RenderSpec) -> String {
        "Generate\(s.takes > 1 ? " \(s.takes) takes" : "") · \(fmtMin(totalMin(s))) · \(money(totalCost(s)))"
    }

    /// The hint under the steps control.
    public static func stepsDelta(_ s: RenderSpec) -> String {
        if s.steps == stepsDefault { return "Same quality as 15 or 20 steps in testing, for less time." }
        let d = Double(s.steps - stepsDefault) * secPerLen(s.lengthSec) / 60
        let c = d / 60 * gpuPerHour
        let sign = d > 0 ? "+" : "−"
        let tail = s.steps > stepsDefault ? " · no visible gain in testing" : " · may lose detail"
        return "\(sign)\(toFixed(abs(d), 1)) min · \(sign)\(money(abs(c))) vs 10 steps\(tail)"
    }

    public enum BadgeStyle: Sendable { case normal, readout, sticker }

    /// Badge next to the steps value. `.readout` is Camera Body's caps readout, `.sticker` Creator Pop's sticker.
    public static func stepsBadge(_ steps: Int, style: BadgeStyle = .normal) -> String {
        switch style {
        case .normal: return steps == stepsDefault ? "Recommended" : steps > stepsDefault ? "Rarely worth it" : "Below tested"
        case .readout: return steps == stepsDefault ? "RECOMMENDED" : steps > stepsDefault ? "RARELY WORTH IT" : "BELOW TESTED"
        case .sticker: return steps == stepsDefault ? "RECOMMENDED" : "TAKES LONGER"
        }
    }

    /// Fill-missing-angles price, e.g. 3 missing → $0.06.
    public static func fillAnglesCost(_ missing: Int) -> Double { fillAngleCost * Double(missing) }

    /// The prototype's typical 10-step video price, shown as "Per video ~$0.66".
    public static let typicalVideo = 0.66

    /// "≈ 9 videos at 10 steps" (the prototype divides by its $0.66 typical price).
    public static func videosLeft(_ balance: Double) -> Int { max(0, Int(floor(balance / typicalVideo))) }

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

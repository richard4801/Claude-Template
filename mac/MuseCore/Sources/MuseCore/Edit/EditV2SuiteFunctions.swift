import Foundation

// Edit suite additions (plans/video-editor.md "Edit suite additions"): ports of the reference functions in
// server/api/src/editor/model.ts (toneAdjust, maskAlpha, toSrt, duckTimes), audio.ts (biquad, voiceChain, runChain) and the
// label tables of presets.ts. Fixture-checked (functions.json → masks, tone, speedCurves, voice, duckTimes; presets.json).

extension EditV2 {
    public static let maskShapes: [MaskShape] = MaskShape.all
    public static let voiceEffects: [VoiceEffect] = VoiceEffect.all

    // MARK: Tone

    /// Highlights/shadows (Adjust, −1…1) on one channel value, after the colour matrix: shadows move values around 1/3,
    /// highlights around 2/3 (weights 4v(1−v)² and 4v²(1−v), at most ±0.25·0.6).
    public static func toneAdjust(_ v: Double, shadows: Double = 0, highlights: Double = 0) -> Double {
        if shadows == 0 && highlights == 0 { return v }
        return clamp(v + 0.25 * (shadows * 4 * v * (1 - v) * (1 - v) + highlights * 4 * v * v * (1 - v)), 0, 1)
    }

    /// The tone part of an item's adjust (nil when it changes nothing).
    public struct Tone: Hashable, Sendable {
        public var shadows: Double
        public var highlights: Double
        public init(shadows: Double = 0, highlights: Double = 0) { self.shadows = shadows; self.highlights = highlights }
        public init?(_ a: Adjust?) {
            let s = a?.shadows ?? 0, h = a?.highlights ?? 0
            if s == 0 && h == 0 { return nil }
            self.init(shadows: s, highlights: h)
        }
    }

    // MARK: Masks

    /// Mask opacity (0–1) at u, v of the item's own frame (0–1, top-left origin). Distances are in item fractions;
    /// feather is the soft edge width.
    public static func maskAlpha(_ m: Mask, _ u: Double, _ v: Double) -> Double {
        let cx = m.x ?? 0.5, cy = m.y ?? 0.5, w = max(0.01, m.width ?? 0.5), h = max(0.01, m.height ?? 0.5), f = max(1e-4, m.feather ?? 0.1)
        let a = (m.rotation ?? 0) * Double.pi / 180, du = u - cx, dv = v - cy
        let x = du * cos(a) + dv * sin(a), y = -du * sin(a) + dv * cos(a)
        func soft(_ d: Double) -> Double { 1 - smoothstep(-f / 2, f / 2, d) }
        let alpha: Double
        switch m.shape {
        case .linear: alpha = soft(y)
        case .mirror: alpha = soft(abs(y) - h / 2)
        case .circle:
            let r = ((x / (w / 2)) * (x / (w / 2)) + (y / (h / 2)) * (y / (h / 2))).squareRoot()
            alpha = soft((r - 1) * min(w, h) / 2)
        case .rect: alpha = soft(max(abs(x) - w / 2, abs(y) - h / 2))
        case .heart:
            let X = (x / (w / 2)) * 1.15, Y = (-y / (h / 2)) * 1.15 + 0.25
            let F = pow(X * X + Y * Y - 1, 3) - X * X * Y * Y * Y
            alpha = soft(F * 0.6 * min(w, h))
        case .star:
            let X = x / (w / 2), Y = y / (h / 2), r = (X * X + Y * Y).squareRoot()
            let ang = (atan2(X, -Y) * 180 / Double.pi + 360).truncatingRemainder(dividingBy: 72), t = abs(ang - 36) / 36
            let edge = 0.45 + 0.55 * t
            alpha = soft((r - edge) * min(w, h) / 2)
        default: alpha = 1
        }
        return r6(m.invert == true ? 1 - alpha : alpha)
    }

    /// The mask as an 8-bit alpha map of `width`×`height` (row 0 = the top), for the renderers.
    public static func maskMap(_ m: Mask, width: Int, height: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: max(0, width * height))
        for y in 0..<height {
            for x in 0..<width {
                let a = maskAlpha(m, (Double(x) + 0.5) / Double(width), (Double(y) + 0.5) / Double(height))
                out[y * width + x] = UInt8(max(0, min(255, (a * 255).rounded())))
            }
        }
        return out
    }

    // MARK: SRT

    static func srtTime(_ t: Double) -> String {
        let ms = Int(jsRound(max(0, t) * 1000))
        let h = ms / 3_600_000, m = (ms / 60000) % 60, s = (ms / 1000) % 60
        func pad(_ v: Int, _ n: Int) -> String { let s = String(v); return String(repeating: "0", count: max(0, n - s.count)) + s }
        return "\(pad(h, 2)):\(pad(m, 2)):\(pad(s, 2)),\(pad(ms % 1000, 3))"
    }

    // MARK: Captions in other scripts (WS8 d0c1a6e)

    /// Languages written without spaces between words: their caption pages join words with nothing between.
    public static let unspacedLanguages = ["ja", "zh", "th", "lo", "km", "my"]
    /// Languages written right to left (a caption page reads from the right; the words keep their order).
    public static let rtlLanguages = ["ar", "he", "fa", "ur"]
    static func baseLanguage(_ l: String?) -> String { l.map { String($0.split(separator: "-", omittingEmptySubsequences: false).first ?? "") } ?? "" }
    /// What goes between a caption page's words.
    public static func captionJoiner(_ language: String?) -> String { unspacedLanguages.contains(baseLanguage(language)) ? "" : " " }
    public static func isRtlLanguage(_ language: String?) -> Bool { rtlLanguages.contains(baseLanguage(language)) }
    /// A caption page's text in `language` (words joined by captionJoiner).
    public static func captionText(_ words: [String], _ language: String?) -> String { words.joined(separator: captionJoiner(language)) }

    /// The captions as an .srt file (one cue per caption page; upper case when the style says so). Empty without captions.
    public static func toSrt(_ p: Project) -> String {
        guard let ct = p.captionTrack else { return "" }
        return captionPages(p).enumerated().map { i, pg in
            let text = captionText(pg.words.map(\.text), ct.language)
            return "\(i + 1)\n\(srtTime(pg.startSec)) --> \(srtTime(pg.endSec))\n\(ct.style.uppercase == true ? text.uppercased() : text)\n"
        }.joined(separator: "\n")
    }

    // MARK: Ducking

    /// Ramp down (attack, before speech) and back up (release, after it): attackSec/releaseSec, else fadeSec for both.
    public static func duckTimes(_ d: Duck) -> (attack: Double, release: Double) {
        let f = d.fadeSec ?? 0.25
        return (max(0.05, d.attackSec ?? f), max(0.05, d.releaseSec ?? f))
    }

    // MARK: Labels (presets.ts)

    /// The caption style names the Edit suite shows, in its order; `highlight` and `single` stay for older projects.
    public static let captionStyleLabels: [(CaptionPreset, String)] = [
        (.pop, "Word pop"), (.karaoke, "Karaoke"), (.box, "Bold box"), (.plain, "Minimal"), (.highlighter, "Highlighter"), (.neon, "Neon"),
        (.highlight, "Highlight"), (.single, "One word"),
    ]
    /// The six styles of the design's grid (E1/E3).
    public static let suiteCaptionStyles: [CaptionPreset] = [.pop, .karaoke, .box, .plain, .highlighter, .neon]
    public static func captionStyleLabel(_ p: CaptionPreset) -> String { captionStyleLabels.first { $0.0 == p }?.1 ?? p.rawValue }

    /// Transition names in the Edit suite (design E2): "cut" = no transition.
    public static let transitionLabels: [(String, String)] = [
        ("cut", "Cut"), ("fade", "X-fade"), ("zoom", "Zoom"), ("whip", "Whip"), ("slideLeft", "Slide"), ("white", "Flash"), ("glitch", "Glitch"),
        ("spin", "Spin"), ("black", "Dip to black"),
    ]
    /// Labels for the content pack's kinds (WS8 929bcf2), kept apart from the reference's picker table above.
    public static let moreTransitionLabels: [(String, String)] = [
        ("zoomOut", "Zoom out"), ("whipRight", "Whip right"), ("coverLeft", "Cover left"), ("coverRight", "Cover right"),
        ("coverUp", "Cover up"), ("coverDown", "Cover down"), ("splitFade", "Split fade"),
    ]
    public static func transitionLabel(_ k: TransitionKind?) -> String {
        let key = k?.rawValue ?? "cut"
        return (transitionLabels + moreTransitionLabels).first { $0.0 == key }?.1 ?? key
    }

    // MARK: Voice (audio.ts)

    public struct Biquad: Codable, Hashable, Sendable {
        public var b0: Double
        public var b1: Double
        public var b2: Double
        public var a1: Double
        public var a2: Double
        public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) { self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2 }
    }

    public enum BiquadKind: Sendable { case lowpass, highpass, peaking, lowshelf, highshelf }

    static func r9(_ v: Double) -> Double { jsRound(v * 1e9) / 1e9 }

    /// RBJ audio-EQ-cookbook biquad, normalised by a0. Shelves use S = 1.
    public static func biquad(_ kind: BiquadKind, _ f: Double, _ sr: Double, q: Double = 0.5.squareRoot(), gainDb: Double = 0) -> Biquad {
        let A = pow(10, gainDb / 40), w = 2 * Double.pi * f / sr, cw = cos(w), sw = sin(w)
        let alpha = kind == .lowshelf || kind == .highshelf ? (sw / 2) * 2.0.squareRoot() : sw / (2 * q)
        let sq = 2 * A.squareRoot() * alpha
        let b0, b1, b2, a0, a1, a2: Double
        switch kind {
        case .lowpass: b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = (1 - cw) / 2; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        case .highpass: b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = (1 + cw) / 2; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
        case .peaking: b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A; a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A
        case .lowshelf:
            b0 = A * (A + 1 - (A - 1) * cw + sq); b1 = 2 * A * (A - 1 - (A + 1) * cw); b2 = A * (A + 1 - (A - 1) * cw - sq)
            a0 = A + 1 + (A - 1) * cw + sq; a1 = -2 * (A - 1 + (A + 1) * cw); a2 = A + 1 + (A - 1) * cw - sq
        case .highshelf:
            b0 = A * (A + 1 + (A - 1) * cw + sq); b1 = -2 * A * (A - 1 + (A + 1) * cw); b2 = A * (A + 1 + (A - 1) * cw - sq)
            a0 = A + 1 - (A - 1) * cw + sq; a1 = 2 * (A - 1 - (A + 1) * cw); a2 = A + 1 - (A - 1) * cw - sq
        }
        return Biquad(b0: r9(b0 / a0), b1: r9(b1 / a0), b2: r9(b2 / a0), a1: r9(a1 / a0), a2: r9(a2 / a0))
    }

    /// The filters for a clip's voice: `enhance` first, then the effect. Empty = untouched.
    public static func voiceChain(effect: VoiceEffect?, enhance: Bool?, sampleRate sr: Double) -> [Biquad] {
        var out: [Biquad] = []
        if enhance == true { out += [biquad(.highpass, 80, sr), biquad(.lowshelf, 200, sr, q: 0, gainDb: -2), biquad(.peaking, 3000, sr, q: 1, gainDb: 3)] }
        switch effect ?? VoiceEffect.none {
        case .warm: out += [biquad(.lowshelf, 200, sr, q: 0, gainDb: 3), biquad(.highshelf, 6000, sr, q: 0, gainDb: -3)]
        case .radio: out += [biquad(.highpass, 500, sr), biquad(.lowpass, 3000, sr), biquad(.peaking, 1500, sr, q: 1, gainDb: 4)]
        case .phone: out += [biquad(.highpass, 300, sr), biquad(.highpass, 300, sr), biquad(.lowpass, 3400, sr), biquad(.lowpass, 3400, sr)]
        case .deep: out += [biquad(.lowshelf, 150, sr, q: 0, gainDb: 6), biquad(.highshelf, 3000, sr, q: 0, gainDb: -4)]
        default: break
        }
        return out
    }
    public static func voiceChain(_ c: VideoClip, sampleRate: Double) -> [Biquad] { voiceChain(effect: c.voiceEffect, enhance: c.enhance, sampleRate: sampleRate) }
    public static func voiceChain(_ c: AudioClip, sampleRate: Double) -> [Biquad] { voiceChain(effect: c.voiceEffect, enhance: c.enhance, sampleRate: sampleRate) }

    /// Runs a chain over mono samples (direct form I, state per filter).
    public static func runChain(_ chain: [Biquad], _ x: [Double]) -> [Double] {
        var cur = x
        for f in chain {
            var st = BiquadState()
            for i in 0..<cur.count { cur[i] = st.step(f, cur[i]) }
        }
        return cur
    }

    /// One filter's memory (direct form I), for streaming use in the audio tap.
    public struct BiquadState: Sendable {
        public var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        public init() {}
        @inline(__always) public mutating func step(_ f: Biquad, _ x: Double) -> Double {
            let v = f.b0 * x + f.b1 * x1 + f.b2 * x2 - f.a1 * y1 - f.a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = v
            return v
        }
    }
}

import Foundation

/// The kinds of interface sound. The first six are the prototype's (`SND` in prototype/app/app.js); `error` is Mac-only.
public enum SoundKind: String, CaseIterable, Sendable {
    case tap, tick, nav, go, done, theme, error
}

/// The prototype's per-theme UI sounds, rendered to mono PCM the way WebAudio plays them: oscillators with exponential
/// pitch ramps and exponential gain envelopes, and white noise through a band-pass biquad. Pure Swift, no audio APIs,
/// so it renders and tests on Linux. Same port as the Android app (android/.../platform/SoundFx.kt), including the
/// normalisation: the browser mixes these quietly, so each sound is scaled to a peak of 0.7 (0.45 for a tick).
public enum SoundSynth {
    public static let defaultRate = 44_100.0

    /// Peak level after normalisation.
    public static func targetPeak(_ k: SoundKind) -> Float { k == .tick ? 0.45 : 0.7 }

    /// Renders one sound for a theme ("a" Editorial, "b" Camera Body, "c" Soft Tactile, "d" Creator Pop).
    public static func render(theme: String, kind: SoundKind, sampleRate: Double = defaultRate) -> [Float] {
        var m = Mix(rate: sampleRate)
        switch theme {
        case "b":
            switch kind {
            case .tap: m.noise(0.018, 2400, q: 6, vol: 0.16); m.tone(90, 50, 0.05, .sine, 0.12)
            case .tick: m.noise(0.012, 4200, q: 10, vol: 0.14)
            case .nav: m.noise(0.05, 1500, q: 3, vol: 0.12); m.noise(0.05, 900, q: 3, vol: 0.1, delay: 0.06)
            case .go: m.tone(880, nil, 0.08, .square, 0.05); m.tone(880, nil, 0.08, .square, 0.05, delay: 0.14); m.tone(1320, nil, 0.18, .square, 0.05, delay: 0.28)
            case .done: m.tone(1046, nil, 0.12, .triangle, 0.08); m.tone(1568, nil, 0.3, .triangle, 0.07, delay: 0.12)
            case .theme: m.noise(0.03, 2000, q: 8, vol: 0.2); m.noise(0.08, 600, q: 2, vol: 0.15, delay: 0.07)
            case .error: m.tone(440, nil, 0.08, .square, 0.05); m.tone(330, nil, 0.16, .square, 0.05, delay: 0.1)
            }
        case "c":
            switch kind {
            case .tap: m.tone(520, 380, 0.09, .sine, 0.1)
            case .tick: m.tone(900, 700, 0.03, .sine, 0.05)
            case .nav: m.tone(330, 440, 0.18, .sine, 0.06)
            case .go: m.tone(440, 660, 0.35, .sine, 0.08)
            case .done: for (i, f) in [392.0, 523, 659, 784].enumerated() { m.tone(f, nil, 1.1, .sine, 0.06, delay: Double(i) * 0.1) }
            case .theme: m.tone(262, 392, 0.5, .sine, 0.07)
            case .error: m.tone(392, 262, 0.3, .sine, 0.08)
            }
        case "d":
            switch kind {
            case .tap: m.tone(500, 1100, 0.08, .triangle, 0.12)
            case .tick: m.tone(1400, 1800, 0.03, .square, 0.03)
            case .nav: m.tone(300, 900, 0.12, .triangle, 0.08)
            case .go: m.tone(400, 1600, 0.25, .sawtooth, 0.05); m.noise(0.25, 800, q: 0.7, vol: 0.06, sweepTo: 4000)
            case .done:
                for (i, f) in [523.0, 659, 784, 1046].enumerated() { m.tone(f, nil, 0.25, .square, 0.05, delay: Double(i) * 0.08) }
                m.tone(1568, 2093, 0.3, .triangle, 0.06, delay: 0.34)
            case .theme: m.tone(200, 1200, 0.3, .triangle, 0.08); m.tone(1200, 1800, 0.15, .square, 0.03, delay: 0.2)
            case .error: m.tone(600, 200, 0.25, .triangle, 0.1)
            }
        default:
            switch kind {
            case .tap: m.noise(0.035, 3200, q: 2, vol: 0.09)
            case .tick: m.noise(0.02, 5000, q: 4, vol: 0.06)
            case .nav: m.noise(0.22, 1800, q: 0.6, vol: 0.05, sweepTo: 600)
            case .go: m.tone(392, nil, 0.5, .sine, 0.08); m.tone(587, nil, 0.6, .sine, 0.06, delay: 0.08)
            case .done: for (i, f) in [523.0, 659, 784].enumerated() { m.tone(f, nil, 0.9, .sine, 0.07, delay: Double(i) * 0.12) }
            case .theme: m.noise(0.4, 900, q: 0.5, vol: 0.06, sweepTo: 3000)
            case .error: m.tone(330, 220, 0.35, .sine, 0.09)
            }
        }
        return normalise(m.buf, peak: targetPeak(kind))
    }

    static func normalise(_ buf: [Float], peak target: Float) -> [Float] {
        let peak = max(1e-4, buf.reduce(0) { max($0, abs($1)) })
        let gain = target / peak
        return buf.map { min(1, max(-1, $0 * gain)) }
    }

    public static func peak(_ buf: [Float]) -> Float { buf.reduce(0) { max($0, abs($1)) } }

    enum Wave { case sine, square, triangle, sawtooth }

    struct Mix {
        let rate: Double
        var buf: [Float] = []

        init(rate: Double) { self.rate = rate }

        mutating func ensure(_ n: Int) { if n > buf.count { buf.append(contentsOf: repeatElement(0, count: n - buf.count)) } }

        /// WebAudio: exponential ramp 0.0001 → vol over 8 ms, then → 0.0001 at `dur`; the oscillator stops 20 ms later.
        static func env(_ t: Double, _ dur: Double, _ vol: Double) -> Double {
            let lo = 0.0001
            if t < 0.008 { return lo * pow(vol / lo, t / 0.008) }
            if t < dur { return vol * pow(lo / vol, (t - 0.008) / max(1e-4, dur - 0.008)) }
            return 0
        }

        /// An oscillator from f1, ramping exponentially to f2 over `dur` when f2 is set.
        mutating func tone(_ f1: Double, _ f2: Double?, _ dur: Double, _ wave: Wave = .sine, _ vol: Double = 0.12, delay: Double = 0) {
            let start = Int(delay * rate)
            let n = Int((dur + 0.02) * rate)
            ensure(start + n)
            var phase = 0.0
            for i in 0..<n {
                let t = Double(i) / rate
                let f: Double
                if let f2, t < dur { f = f1 * pow(f2 / f1, t / dur) } else { f = f2 ?? f1 }
                phase += f / rate
                let p = phase - floor(phase)
                let s: Double
                switch wave {
                case .square: s = p < 0.5 ? 1 : -1
                case .triangle: s = 1 - 4 * abs(p - 0.5)
                case .sawtooth: s = 2 * p - 1
                case .sine: s = sin(2 * .pi * p)
                }
                buf[start + i] += Float(s * Self.env(t, dur, vol))
            }
        }

        /// White noise through a band-pass biquad (WebAudio's constant-peak band-pass), centre optionally swept exponentially to `sweepTo`;
        /// gain ramps exponentially from `vol` to 0.0001 over `dur`.
        mutating func noise(_ dur: Double, _ freq: Double, q: Double = 1, vol: Double = 0.15, delay: Double = 0, sweepTo: Double? = nil) {
            let start = Int(delay * rate)
            let n = Int(dur * rate)
            ensure(start + n)
            var rng = SplitMix(seed: UInt64(freq) &* 31 &+ UInt64(n))
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in 0..<n {
                let t = Double(i) / rate
                let f = min(rate / 2 - 100, sweepTo.map { freq * pow($0 / freq, t / dur) } ?? freq)
                let w0 = 2 * Double.pi * f / rate
                let alpha = sin(w0) / (2 * q)
                let cw = cos(w0)
                let b0 = alpha, b1 = 0.0, b2 = -alpha
                let a0 = 1 + alpha, a1 = -2 * cw, a2 = 1 - alpha
                let x0 = rng.nextUnit() * 2 - 1
                let y0 = (b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
                x2 = x1; x1 = x0; y2 = y1; y1 = y0
                let g = vol * pow(0.0001 / vol, t / dur)
                buf[start + i] += Float(y0 * g)
            }
        }
    }

    /// Deterministic noise, so each sound renders the same every time.
    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }
}

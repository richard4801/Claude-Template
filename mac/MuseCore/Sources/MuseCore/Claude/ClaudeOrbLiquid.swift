import Foundation

// The orb's liquid (owner, 2026-11-12, second pass): inside the dark glass, four soft blobs of coloured light (magenta,
// violet, blue, a touch of cyan-green; the same in every theme) drift, swell and melt into each other, added together so
// overlaps brighten. Motion is value noise over a phase that only moves forward, so it never loops or circles. Pure maths:
// the Mac draws these blobs with Canvas, the review preview (design/direction/orb_preview.py) runs the same numbers in
// JavaScript, and Android can port it as is. The state machine (ClaudeOrb) decides how fast and how bright.

public struct ClaudeOrbBlob: Hashable, Sendable {
    /// Centre, relative to the sphere's centre, in sphere radii (−1…1).
    public var x: Double
    public var y: Double
    /// Radius in sphere radii.
    public var radius: Double
    /// 0…1, multiplied into the colour.
    public var alpha: Double
    /// sRGB 0…1.
    public var r: Double, g: Double, b: Double
}

public enum ClaudeOrbLiquid {
    /// Magenta, violet, blue, cyan-green (sRGB hex), and the error palette (red and orange).
    public static let palette: [UInt32] = [0xFF3DA8, 0x8E5BFF, 0x3B82FF, 0x2FE0C0]
    public static let errorPalette: [UInt32] = [0xFF4D3D, 0xFF8A2B, 0xD9302B, 0xFFB347]

    /// The phase moves at the state's flow speed (`look.swirl`): call each frame with the time since the last.
    public static func advance(_ phase: Double, by dt: Double, look: ClaudeOrbLook) -> Double {
        phase + max(0, min(dt, 0.25)) * max(0.02, look.swirl)
    }

    /// The four blobs at `phase`. `pulse` (0…1, the last chunk/action) swells them; `time` drives the operating sweep.
    public static func blobs(phase: Double, time: Double, look: ClaudeOrbLook, pulse: Double) -> [ClaudeOrbBlob] {
        let colors = look.danger ? errorPalette : palette
        let sweepAt = (time * 0.45).truncatingRemainder(dividingBy: 1) * 2.6 - 1.3
        return (0..<4).map { i in
            let s = Double(i) * 17.0
            var x = 0.6 * noise(s + 1, phase * 0.9)
            var y = 0.6 * noise(s + 5, phase * 0.75)
            if look.sweep {
                // Operating: the blobs stream across the glass, left to right, in a loose line.
                let lane = (Double(i) - 1.5) / 1.5
                x = mix(x, sweepAt + 0.35 * lane, 0.65)
                y = mix(y, 0.25 * lane, 0.4)
            }
            let swell = 0.18 * pulse
            let radius = 0.62 + 0.18 * noise(s + 9, phase * 0.6) + swell
            let alpha = min(0.9, look.band * (0.6 + 0.25 * noise(s + 13, phase * 0.5)) + 0.18 * pulse)
            let c = colors[i]
            return ClaudeOrbBlob(x: x, y: y, radius: radius, alpha: max(0, alpha),
                                 r: Double((c >> 16) & 0xFF) / 255, g: Double((c >> 8) & 0xFF) / 255, b: Double(c & 0xFF) / 255)
        }
    }

    /// Smooth 1-D value noise in −1…1 (hashed lattice values, smoothstep between them): drifts without repeating.
    public static func noise(_ seed: Double, _ x: Double) -> Double {
        let i = floor(x), f = x - i
        let u = f * f * (3 - 2 * f)
        return mix(lattice(seed, i), lattice(seed, i + 1), u)
    }

    static func lattice(_ seed: Double, _ i: Double) -> Double {
        let v = sin(i * 127.1 + seed * 311.7) * 43758.5453
        return (v - floor(v)) * 2 - 1
    }

    static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}

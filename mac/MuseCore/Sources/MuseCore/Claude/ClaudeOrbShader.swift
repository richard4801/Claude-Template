import Foundation

// The orb's shader inputs (owner, 2026-11-12: Option C2 "alive", luminous 3D smoke in a living glass ball; the shader is
// mac/Muse/Views/Claude/ClaudeOrb.metal, previewed by design/direction/orb_alive.py with the same numbers). ClaudeOrb
// decides the state; this turns a state into the shader's uniforms. Pure, so Android can port it with the shader.

public struct ClaudeOrbUniforms: Hashable, Sendable {
    /// The smoke's emission.
    public var bright: Double
    /// 0: drifting plumes; >0: a current streaming across (operating), and the ball leans into it.
    public var current: Double
    /// 0…1: the iridescent smoke → orange and red (error).
    public var danger: Double
    /// 0…1: the last chunk or action (a bright plume rising, a small pop of the glass).
    public var pulse: Double
    /// 0…1: the breath (waiting).
    public var breath: Double
    /// The silhouette's soft-body wobble (a fraction of the radius).
    public var wobble: Double
    /// The glass's breathing scale above 1 (a pop per chunk or action).
    public var pop: Double
}

public enum ClaudeOrbShader {
    /// The colours the smoke is made of (magenta, violet, blue, cyan) and the error ones: the panel's edge uses them too.
    public static let palette: [UInt32] = [0xFF3DA8, 0x8E5BFF, 0x3B82FF, 0x2FE0C0]
    public static let errorPalette: [UInt32] = [0xFF4D3D, 0xFF8A2B, 0xD9302B, 0xFFB347]

    /// The ball fills 1/scale of its frame; the rest is room for the wobble and the pop.
    public static let scale = 1.1

    /// The phase moves at the state's flow speed (`look.swirl`) and never jumps (a stalled frame counts at most 0.25 s).
    public static func advance(_ phase: Double, by dt: Double, look: ClaudeOrbLook) -> Double {
        phase + max(0, min(dt, 0.25)) * look.swirl
    }

    /// The uniforms for a state at `time`, with the pulse (`ClaudeOrb.pulse(at:)`). Reduce Motion: the shape stays still.
    public static func uniforms(_ s: ClaudeOrbState, look: ClaudeOrbLook, time: Double, pulse: Double, reduceMotion: Bool = false) -> ClaudeOrbUniforms {
        let breath = look.breath > 0 ? 0.5 - 0.5 * cos(2 * .pi * time / look.breath) : 0
        var u: ClaudeOrbUniforms
        switch s {
        case .idle: u = ClaudeOrbUniforms(bright: 0.85, current: 0, danger: 0, pulse: 0, breath: breath, wobble: 0.02, pop: 0)
        case .thinking: u = ClaudeOrbUniforms(bright: 1.1, current: 0, danger: 0, pulse: pulse, breath: 0, wobble: 0.05, pop: 0)
        case .operating: u = ClaudeOrbUniforms(bright: 1.0, current: 1.6, danger: 0, pulse: pulse, breath: 0, wobble: 0.045, pop: 0)
        case .waiting: u = ClaudeOrbUniforms(bright: 1.15, current: 0, danger: 0, pulse: 0, breath: breath, wobble: 0.025, pop: 0)
        case .error: u = ClaudeOrbUniforms(bright: 0.9, current: 0, danger: 1, pulse: 0, breath: 0, wobble: 0.015, pop: 0)
        }
        u.pop = 0.006 * sin(time * 0.7) + 0.035 * u.pulse + 0.02 * u.breath
        if reduceMotion { u.wobble = 0; u.pop = 0; u.pulse = 0; u.breath = 0 }
        return u
    }
}

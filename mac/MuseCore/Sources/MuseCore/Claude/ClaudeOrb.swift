import Foundation

// Claude's orb (owner, 2026-11-12; plans/design/claude-panel/orb-states-*.png): MUSE's own design, a small dark glass
// sphere with soft multicolour light flowing inside it (ClaudeOrbLiquid). It sits in the panel header, beside the reply being written,
// in the activity strip, and floats over the app while Claude operates MUSE with the panel closed. The panel's edge
// glows in step with it. ONE state machine, fed only by real events (the chat stream, ui-control calls, cards, jobs),
// never by a timer of its own; the views read `look` and `pulse(at:)` and draw. Pure, so Android can port it as is.

public enum ClaudeOrbState: String, Sendable, CaseIterable {
    /// Nothing happening: slow breathing.
    case idle
    /// A turn runs (thinking, writing, a tool): the swirl speeds up and pulses with each streamed chunk.
    case thinking
    /// Claude operates the MUSE window: a directional sweep, a flash per action and per change applied.
    case operating
    /// An Approve card or a question waits for the person: a steady glow with a slow pulse.
    case waiting
    /// The last turn or action failed: the glass takes the danger tint (the band goes grey and still).
    case error
}

/// How the orb (and the panel's edge) looks in a state. Numbers, not colours: the view takes the theme's accent, and
/// the danger colour when `danger` is set.
public struct ClaudeOrbLook: Hashable, Sendable {
    /// Band turns per second (0: still).
    public var swirl: Double
    /// Band brightness and the halo around the sphere, 0…1.
    public var band: Double
    public var glow: Double
    /// Seconds per breath (0: no breathing).
    public var breath: Double
    /// How much a breath moves the glow, 0…1.
    public var breathDepth: Double
    /// The operating sweep across the glass.
    public var sweep: Bool
    /// Pulses (chunks, ui actions, changes) show as a flash.
    public var flashes: Bool
    public var danger: Bool
    /// The panel's living edge: its glow, 0…1 (the view multiplies the accent's alpha by it).
    public var edge: Double
}

public struct ClaudeOrb: Hashable, Sendable {
    public private(set) var turnRunning = false
    public private(set) var openUiCalls: Set<String> = []
    public private(set) var waitingCount = 0
    public private(set) var jobRunning = false
    public private(set) var errorUntil: Double?
    /// Pulses so far (a chunk, a ui action, a change applied) and when the last one came.
    public private(set) var pulses = 0
    public private(set) var lastPulseAt: Double = -.infinity
    /// The person is typing in the composer: the edge stays quiet.
    public var typing = false

    /// An error tints the orb this long, or until the person writes again.
    public static let errorHold: Double = 8
    /// A flash fades out over this long.
    public static let flashDecay: Double = 0.6

    public init() {}

    // MARK: Events in

    /// The person sent a message (or a phone turn started): a new turn; a past error is cleared.
    public mutating func turnStarted() { turnRunning = true; errorUntil = nil }
    /// A streamed chunk of Claude's text (or a tool step): a pulse while thinking.
    public mutating func chunk(at now: Double) { turnRunning = true; pulse(now) }
    /// The turn ended; a failed one tints the orb for `errorHold` seconds.
    public mutating func turnEnded(ok: Bool, at now: Double) {
        turnRunning = false
        if !ok { errorUntil = now + Self.errorHold }
    }
    /// Claude operates the window (a uiCall): operating, with a flash.
    public mutating func uiCallBegan(_ id: String, at now: Double) { openUiCalls.insert(id); pulse(now) }
    public mutating func uiCallEnded(_ id: String, ok: Bool = true, at now: Double) {
        openUiCalls.remove(id)
        if !ok { errorUntil = now + Self.errorHold }
    }
    /// The person pressed Esc / "Esc to stop": the window calls end at once.
    public mutating func stopped() { openUiCalls.removeAll() }
    /// A change landed (What I changed, an edit op): a flash.
    public mutating func changeApplied(at now: Double) { pulse(now) }
    /// How many Approve cards or questions wait for the person.
    public mutating func waiting(_ count: Int) { waitingCount = max(0, count) }
    /// A job Claude started runs (or ended).
    public mutating func job(running: Bool, failed: Bool = false, at now: Double) {
        jobRunning = running
        if failed { errorUntil = now + Self.errorHold }
    }

    private mutating func pulse(_ now: Double) { pulses += 1; lastPulseAt = now }

    // MARK: What it shows

    /// The state at `now`. Error first (it must be seen), then operating, thinking, waiting, idle.
    public func state(at now: Double) -> ClaudeOrbState {
        if let e = errorUntil, now < e { return .error }
        if !openUiCalls.isEmpty { return .operating }
        if turnRunning || jobRunning { return .thinking }
        if waitingCount > 0 { return .waiting }
        return .idle
    }

    /// The flash of the last pulse at `now`, 1 → 0 over `flashDecay` (0 under Reduce Motion: no flashes).
    public func pulse(at now: Double, reduceMotion: Bool = false) -> Double {
        guard !reduceMotion, now >= lastPulseAt else { return 0 }
        let t = (now - lastPulseAt) / Self.flashDecay
        return t >= 0.999 ? 0 : (1 - t) * (1 - t)
    }

    /// The look of a state. Reduce Motion keeps only static tint and glow changes: no swirl, breath, sweep or flash.
    public static func look(_ s: ClaudeOrbState, reduceMotion: Bool = false, typing: Bool = false) -> ClaudeOrbLook {
        var l: ClaudeOrbLook
        switch s {
        // swirl: the liquid's flow speed (phase per second); band: how bright the blobs are; glow: the halo.
        case .idle: l = ClaudeOrbLook(swirl: 0.12, band: 0.45, glow: 0.10, breath: 6, breathDepth: 0.35, sweep: false, flashes: false, danger: false, edge: 0.12)
        case .thinking: l = ClaudeOrbLook(swirl: 0.65, band: 0.85, glow: 0.28, breath: 0, breathDepth: 0, sweep: false, flashes: true, danger: false, edge: 0.30)
        case .operating: l = ClaudeOrbLook(swirl: 0.45, band: 0.80, glow: 0.35, breath: 0, breathDepth: 0, sweep: true, flashes: true, danger: false, edge: 0.40)
        case .waiting: l = ClaudeOrbLook(swirl: 0.10, band: 0.95, glow: 0.45, breath: 3.2, breathDepth: 0.20, sweep: false, flashes: false, danger: false, edge: 0.45)
        case .error: l = ClaudeOrbLook(swirl: 0.06, band: 0.70, glow: 0.30, breath: 0, breathDepth: 0, sweep: false, flashes: false, danger: true, edge: 0.35)
        }
        if reduceMotion { l.swirl = 0; l.breath = 0; l.breathDepth = 0; l.sweep = false; l.flashes = false }
        // While the person types, the edge stays calm: at most the idle glow, never pulsing.
        if typing { l.edge = min(l.edge, 0.15) }
        return l
    }

    public func look(at now: Double, reduceMotion: Bool = false) -> ClaudeOrbLook {
        Self.look(state(at: now), reduceMotion: reduceMotion, typing: typing)
    }

    /// The glow 0…1 at `now`: the state's glow, the breath, and the flash of the last pulse. One number drives both the
    /// orb's halo and the panel's edge, so they move together.
    public func glow(at now: Double, reduceMotion: Bool = false) -> Double {
        let l = look(at: now, reduceMotion: reduceMotion)
        var g = l.glow
        if l.breath > 0 { g *= 1 - l.breathDepth * 0.5 * (1 - cos(2 * .pi * now / l.breath)) }
        if l.flashes && !typing { g += (1 - g) * 0.6 * pulse(at: now, reduceMotion: reduceMotion) }
        return min(1, max(0, g))
    }

    /// The edge's glow at `now` (the same rhythm as the orb, scaled to the state's edge strength).
    public func edge(at now: Double, reduceMotion: Bool = false) -> Double {
        let l = look(at: now, reduceMotion: reduceMotion)
        let base = l.glow > 0 ? glow(at: now, reduceMotion: reduceMotion) / l.glow : 1
        return min(1, max(0, l.edge * base))
    }

    /// Whether anything moves at `now` (the view stops its timeline when nothing does, to save CPU and GPU).
    public func animates(at now: Double, reduceMotion: Bool = false) -> Bool {
        let l = look(at: now, reduceMotion: reduceMotion)
        return l.swirl > 0 || l.breath > 0 || l.sweep || pulse(at: now, reduceMotion: reduceMotion) > 0
    }

    /// Frames per second the view should draw at: low in idle, capped at 30.
    public func frameRate(at now: Double, reduceMotion: Bool = false) -> Double {
        guard animates(at: now, reduceMotion: reduceMotion) else { return 0 }
        let s = state(at: now)
        return s == .idle || s == .error ? 12 : 30
    }
}

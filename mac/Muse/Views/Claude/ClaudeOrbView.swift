import AppKit
import MuseCore
import SwiftUI

// Claude's orb (owner, 2026-11-12, Option C2 "alive"; plans/design/claude-panel/orb-alive-*.png, orb-alive-preview.mp4):
// a glass ball with luminous 3D smoke inside, the glass wobbling, breathing and turning a little with it. Drawn on the GPU
// by ClaudeOrb.metal (SwiftUI colorEffect), with uniforms from MuseCore's ClaudeOrb (real events only) and
// ClaudeOrbShader. A TimelineView redraws at the orb's own rate (12 fps idle or error, 30 at most) and pauses when
// nothing moves (Reduce Motion) or the window is hidden.

struct ClaudeOrbView: View {
    @Environment(\.theme) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var box: ClaudeOrbBox = .shared
    @ObservedObject private var visibility: OrbVisibility = .shared
    var size: CGFloat
    /// The tone of what is behind the orb (the glass shows it, darkened); the panel's own surface by default.
    var behind: Color?
    /// false: drawn as one still frame (the small orbs beside a reply or on a card), so only the header's orb (and the
    /// overlay's) keeps a clock (build 704).
    var live = true

    private var page: Color { behind ?? t.roles.raised }

    var body: some View {
        let orb = box.orb
        let now = Date().timeIntervalSinceReferenceDate
        let fps = visibility.visible && live ? orb.frameRate(at: now, reduceMotion: reduceMotion) : 0
        TimelineView(.animation(minimumInterval: 1 / max(fps, 1), paused: fps == 0)) { ctx in
            let time = ctx.date.timeIntervalSinceReferenceDate
            let look = orb.look(at: time, reduceMotion: reduceMotion)
            let state = orb.state(at: time)
            let u = ClaudeOrbShader.uniforms(state, look: look, time: time, pulse: orb.pulse(at: time, reduceMotion: reduceMotion), reduceMotion: reduceMotion)
            let phase = OrbPhase.shared.phase(at: time, look: look)
            Rectangle()
                .fill(.white)
                .colorEffect(ShaderLibrary.claudeOrb(.float2(Float(size), Float(size)), .float(Float(ClaudeOrbShader.scale)), .float(Float(phase)),
                                                     .float(Float(time.truncatingRemainder(dividingBy: 3600))), .float(Float(u.bright)), .float(Float(u.current)),
                                                     .float(Float(u.danger)), .float(Float(u.pulse)), .float(Float(u.breath)), .float(t.isDark ? 0 : 1),
                                                     .float(Float(u.wobble)), .float(Float(u.pop)), .color(page)))
        }
        .frame(width: size, height: size)
        // The shader's frames stay in the orb's own small layer instead of making the panel around it composite again.
        .drawingGroup()
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(Self.words(orb.state(at: now)))
    }

    static func words(_ s: ClaudeOrbState) -> String {
        switch s {
        case .idle: "Claude"
        case .thinking: "Claude is thinking"
        case .operating: "Claude is using MUSE"
        case .waiting: "Claude is waiting for you"
        case .error: "Claude ran into a problem"
        }
    }
}

/// Claude's orb state on its own (build 704): the orbs and the panel's edge watch this, not the whole ClaudeCodeService,
/// so a service change (a relay state, a setting, a turn count) no longer re-renders them, nor an orb change the rest.
@MainActor
final class ClaudeOrbBox: ObservableObject {
    static let shared = ClaudeOrbBox()
    @Published private(set) var orb = ClaudeOrb()
    private var settle: Task<Void, Never>?

    func set(_ o: ClaudeOrb) {
        guard o != orb else { return }
        orb = o
        // An idle orb draws only while a flash fades: redraw once after it so the clock stops again.
        let now = Date().timeIntervalSinceReferenceDate
        if o.state(at: now) == .idle, o.pulse(at: now) > 0 {
            settle?.cancel()
            settle = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((ClaudeOrb.flashDecay + 0.05) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.redraw()
            }
        }
    }

    /// Something time-based ended (an error's hold, a flash): the views work out their frame rate again.
    func redraw() { objectWillChange.send() }
}

/// The ribbons' phase, shared by every orb and the panel's edge so they turn together. It only moves forward, at the
/// state's speed (ClaudeOrbShader.advance), so a state change never makes the ribbons jump.
@MainActor
final class OrbPhase {
    static let shared = OrbPhase()
    private var value = 0.0
    private var last: Double?

    func phase(at time: Double, look: ClaudeOrbLook) -> Double {
        if let l = last, time > l { value = ClaudeOrbShader.advance(value, by: time - l, look: look) }
        if last == nil || time > last! { last = time }
        return value
    }
}

/// Whether the MUSE window can be seen (not hidden, minimised or fully covered): the orb and the panel's edge stop
/// drawing when it can't.
@MainActor
final class OrbVisibility: ObservableObject {
    static let shared = OrbVisibility()
    @Published private(set) var visible = true
    private var observers: [NSObjectProtocol] = []

    private init() {
        let nc = NotificationCenter.default
        for name in [NSApplication.didChangeOcclusionStateNotification, NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.update() } })
        }
        update()
    }

    private func update() {
        let shown = !NSApp.isHidden && NSApp.occlusionState.contains(.visible)
            && (NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && !$0.isMiniaturized }).map { $0.occlusionState.contains(.visible) && !$0.isMiniaturized } ?? true
        if shown != visible { visible = shown }
    }
}

/// The floating panel's living edge: the orb's colours flowing round a hairline, glowing in step with the orb (same state, same
/// rhythm); calm in idle and while the person types.
struct ClaudeLivingEdge: View {
    @Environment(\.theme) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var box: ClaudeOrbBox = .shared
    @ObservedObject private var visibility: OrbVisibility = .shared
    var cornerRadius: CGFloat

    var body: some View {
        let orb = box.orb
        let now = Date().timeIntervalSinceReferenceDate
        // Performance (build 704): in idle the edge holds still (its glow is 0.12, the breath on it can't be seen), so an
        // open panel with nothing happening no longer redraws the whole edge and its 12 pt blur 12 times a second. Any
        // real activity changes `orb`, which re-runs this body and starts the timeline again.
        let fps = visibility.visible && orb.state(at: now) != .idle ? orb.frameRate(at: now, reduceMotion: reduceMotion) : 0
        TimelineView(.animation(minimumInterval: 1 / max(fps, 1), paused: fps == 0)) { ctx in
            let time = ctx.date.timeIntervalSinceReferenceDate
            let look = orb.look(at: time, reduceMotion: reduceMotion)
            let e = orb.edge(at: time, reduceMotion: reduceMotion)
            // The orb's own colours flowing round the border (the same phase as the orb, so they move together).
            let hexes = look.danger ? ClaudeOrbShader.errorPalette : ClaudeOrbShader.palette
            let colors = (hexes + [hexes[0]]).map { h in Color(red: Double((h >> 16) & 0xFF) / 255, green: Double((h >> 8) & 0xFF) / 255, blue: Double(h & 0xFF) / 255) }
            let turn = Angle.degrees(OrbPhase.shared.phase(at: time, look: look) * 90)
            let flow = AngularGradient(colors: colors, center: .center, angle: turn)
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            ZStack {
                shape.strokeBorder(t.roles.hairline, lineWidth: 1)
                shape.strokeBorder(flow, lineWidth: 1.5).opacity(0.2 + 0.8 * e)
                shape.stroke(flow, lineWidth: 8).blur(radius: 12).opacity(0.7 * e)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

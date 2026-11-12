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
    @ObservedObject private var service: ClaudeCodeService = .shared
    @ObservedObject private var visibility: OrbVisibility = .shared
    var size: CGFloat
    /// The tone of what is behind the orb (the glass shows it, darkened); the panel's own surface by default.
    var behind: Color?

    private var page: Color { behind ?? t.roles.raised }

    var body: some View {
        let orb = service.orb
        let now = Date().timeIntervalSinceReferenceDate
        let fps = visibility.visible ? orb.frameRate(at: now, reduceMotion: reduceMotion) : 0
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
    @ObservedObject private var service: ClaudeCodeService = .shared
    @ObservedObject private var visibility: OrbVisibility = .shared
    var cornerRadius: CGFloat

    var body: some View {
        let orb = service.orb
        let now = Date().timeIntervalSinceReferenceDate
        let fps = visibility.visible ? orb.frameRate(at: now, reduceMotion: reduceMotion) : 0
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

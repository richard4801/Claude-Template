import AppKit
import MuseCore
import SwiftUI

// Claude's orb (owner, 2026-11-12, second pass; plans/design/claude-panel/orb-states-*.png, orb-preview.mp4): our own
// design, a dark glass sphere with multicolour liquid light inside (MuseCore ClaudeOrbLiquid: four soft blobs added
// together, drifting on noise), an inner shadow, a thin rim and a soft halo. State and rhythm come from ClaudeOrb (real
// events only). Drawn with Canvas (gradients and plus-lighter blending, no blur filters) inside a TimelineView at the
// orb's own rate (12 fps idle or error, 30 at most), paused when nothing moves (Reduce Motion) or the window is hidden.

struct ClaudeOrbView: View {
    @Environment(\.theme) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var service: ClaudeCodeService = .shared
    @ObservedObject private var visibility: OrbVisibility = .shared
    var size: CGFloat

    var body: some View {
        let orb = service.orb
        let now = Date().timeIntervalSinceReferenceDate
        let fps = visibility.visible ? orb.frameRate(at: now, reduceMotion: reduceMotion) : 0
        TimelineView(.animation(minimumInterval: 1 / max(fps, 1), paused: fps == 0)) { ctx in
            let time = ctx.date.timeIntervalSinceReferenceDate
            Canvas { g, sz in
                draw(&g, sz, orb: orb, time: time)
            }
        }
        .frame(width: size, height: size)
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

    private func draw(_ g: inout GraphicsContext, _ sz: CGSize, orb: ClaudeOrb, time: Double) {
        let look = orb.look(at: time, reduceMotion: reduceMotion)
        let glow = orb.glow(at: time, reduceMotion: reduceMotion)
        let pulse = look.flashes ? orb.pulse(at: time, reduceMotion: reduceMotion) : 0
        let phase = OrbPhase.shared.phase(at: time, look: look)
        let d = min(sz.width, sz.height)
        let inset = d * 0.16 // room for the halo
        let r = CGRect(x: inset, y: inset, width: d - 2 * inset, height: d - 2 * inset)
        let R = r.width / 2
        let c = CGPoint(x: r.midX, y: r.midY)
        let sphere = Path(ellipseIn: r)

        // Halo (violet, or warm on error), breathing and flashing with the state.
        let halo = look.danger ? Color(red: 1, green: 0.35, blue: 0.24) : Color(red: 0.59, green: 0.43, blue: 1)
        g.fill(Path(ellipseIn: r.insetBy(dx: -R * 0.6, dy: -R * 0.6)),
               with: .radialGradient(Gradient(stops: [.init(color: halo.opacity(0.15 + 0.6 * glow), location: 0.5), .init(color: halo.opacity(0), location: 1)]),
                                     center: c, startRadius: 0, endRadius: R * 1.6))

        // The dark glass, then the liquid: four soft blobs added together (overlaps brighten), clipped to the sphere.
        var inner = g
        inner.clip(to: sphere)
        inner.fill(sphere, with: .radialGradient(Gradient(colors: [Color(red: 0.09, green: 0.094, blue: 0.114), Color(red: 0.016, green: 0.016, blue: 0.024)]),
                                                 center: CGPoint(x: c.x, y: c.y + R * 0.25), startRadius: 0, endRadius: R * 1.05))
        inner.blendMode = .plusLighter
        for b in ClaudeOrbLiquid.blobs(phase: phase, time: time, look: look, pulse: pulse) {
            let col = Color(red: b.r, green: b.g, blue: b.b)
            let at = CGPoint(x: c.x + b.x * R, y: c.y + b.y * R)
            inner.fill(sphere, with: .radialGradient(Gradient(stops: [.init(color: col.opacity(b.alpha), location: 0),
                                                                     .init(color: col.opacity(b.alpha * 0.45), location: 0.45),
                                                                     .init(color: col.opacity(0), location: 1)]),
                                                     center: at, startRadius: 0, endRadius: b.radius * R))
        }
        inner.blendMode = .normal
        // It reads as a ball: an inner shadow at the edge and a soft highlight at the top.
        inner.fill(sphere, with: .radialGradient(Gradient(stops: [.init(color: .clear, location: 0.62), .init(color: .black.opacity(0.55), location: 1)]),
                                                 center: c, startRadius: 0, endRadius: R))
        let hi = CGPoint(x: c.x - R * 0.3, y: c.y - R * 0.55)
        inner.fill(sphere, with: .radialGradient(Gradient(colors: [.white.opacity(0.32), .clear]), center: hi, startRadius: 0, endRadius: R * 0.45))

        // The thin bright glass rim.
        let w = max(0.75, R * 0.03)
        g.stroke(Path(ellipseIn: r.insetBy(dx: w / 2, dy: w / 2)),
                 with: .linearGradient(Gradient(stops: [.init(color: .white.opacity(0.55), location: 0), .init(color: .white.opacity(0.08), location: 0.5),
                                                        .init(color: .white.opacity(0.22), location: 1)]),
                                       startPoint: CGPoint(x: c.x, y: r.minY), endPoint: CGPoint(x: c.x, y: r.maxY)),
                 lineWidth: w)
    }
}

/// The liquid's phase, shared by every orb and the panel's edge so they flow together. It only moves forward, at the
/// state's flow speed (ClaudeOrbLiquid.advance), so a state change never makes the liquid jump.
@MainActor
final class OrbPhase {
    static let shared = OrbPhase()
    private var value = 0.0
    private var last: Double?

    func phase(at time: Double, look: ClaudeOrbLook) -> Double {
        if let l = last, time > l { value = ClaudeOrbLiquid.advance(value, by: time - l, look: look) }
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
            let hexes = look.danger ? ClaudeOrbLiquid.errorPalette : ClaudeOrbLiquid.palette
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

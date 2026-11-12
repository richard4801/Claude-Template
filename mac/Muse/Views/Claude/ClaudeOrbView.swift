import AppKit
import MuseCore
import SwiftUI

// Claude's orb (owner, 2026-11-12; plans/design/claude-panel/orb-states-*.png): our own design, a small dark glass sphere
// with one elliptical light band in the theme's accent and a soft halo. State and rhythm come from MuseCore's ClaudeOrb
// (real events only). Drawn with Canvas inside a TimelineView that runs at the orb's own rate (12 fps idle, 30 at most),
// stops when nothing moves (Reduce Motion, a still state) and when the window is hidden or covered.

struct ClaudeOrbView: View {
    @Environment(\.theme) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var service: ClaudeCodeService = .shared
    @ObservedObject private var visibility: OrbVisibility = .shared
    var size: CGFloat
    /// Colours for windows without the theme environment (the "Claude is using MUSE" pill).
    var accent: Color?
    var danger: Color?

    var body: some View {
        let orb = service.orb
        let now = Date().timeIntervalSinceReferenceDate
        let fps = visibility.visible ? orb.frameRate(at: now, reduceMotion: reduceMotion) : 0
        TimelineView(.animation(minimumInterval: 1 / max(fps, 1), paused: fps == 0)) { ctx in
            let time = ctx.date.timeIntervalSinceReferenceDate
            Canvas(rendersAsynchronously: true) { g, sz in
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
        let flash = look.flashes ? orb.pulse(at: time, reduceMotion: reduceMotion) : 0
        let accent = self.accent ?? t.roles.accent
        let danger = self.danger ?? t.roles.danger
        let halo = look.danger ? danger : accent
        let d = min(sz.width, sz.height)
        let inset = d * 0.14 // room for the halo
        let r = CGRect(x: inset, y: inset, width: d - 2 * inset, height: d - 2 * inset)
        let sphere = Path(ellipseIn: r)

        // Halo: the glow, breathing and flashing with the state.
        var h = g
        h.addFilter(.blur(radius: d * 0.10))
        h.fill(Path(ellipseIn: r.insetBy(dx: -d * 0.04, dy: -d * 0.04)), with: .color(halo.opacity(0.15 + 0.6 * glow)))

        // The dark glass (danger-tinted on error, so it reads even where the accent is red).
        let center = CGPoint(x: r.midX, y: r.minY + r.height * 0.62)
        g.fill(sphere, with: .radialGradient(Gradient(colors: look.danger ? [danger.opacity(0.85), Color(white: 0.08)] : [Color(white: 0.15), Color(white: 0.04)]),
                                              center: center, startRadius: 0, endRadius: r.width * 0.62))

        // The band: an ellipse stroked in the accent (grey and still on error), turning with the swirl.
        var b = g
        b.clip(to: sphere)
        b.addFilter(.blur(radius: max(0.4, d * 0.035)))
        let angle = Angle.radians(2 * .pi * look.swirl * time) + .degrees(-20)
        let bandColor = look.danger ? Color(white: 0.72) : accent
        let band = Path(ellipseIn: CGRect(x: r.minX + r.width * 0.06, y: r.midY - r.height * 0.18, width: r.width * 0.88, height: r.height * 0.36))
        let turn = CGAffineTransform(translationX: r.midX, y: r.midY).rotated(by: angle.radians).translatedBy(x: -r.midX, y: -r.midY)
        b.stroke(band.applying(turn), with: .color(bandColor.opacity(min(1, look.band + 0.3 * flash))), lineWidth: max(1, d * 0.07))
        if !look.danger {
            let second = CGAffineTransform(translationX: r.midX, y: r.midY).rotated(by: angle.radians + .pi / 3).translatedBy(x: -r.midX, y: -r.midY)
            b.stroke(band.applying(second), with: .color(accent.opacity(look.band * 0.4)), lineWidth: max(0.6, d * 0.04))
        }
        // Operating: a sweep crossing the glass, left to right.
        if look.sweep {
            let x = r.minX + r.width * CGFloat((time * 0.8).truncatingRemainder(dividingBy: 1)) * 1.6 - r.width * 0.3
            b.fill(Path(CGRect(x: x, y: r.minY, width: r.width * 0.28, height: r.height)),
                   with: .linearGradient(Gradient(colors: [.clear, accent.opacity(0.45 + 0.4 * flash), .clear]),
                                         startPoint: CGPoint(x: x, y: r.midY), endPoint: CGPoint(x: x + r.width * 0.28, y: r.midY)))
        }

        // Glass: the highlight and the rim.
        g.fill(Path(ellipseIn: CGRect(x: r.minX + r.width * 0.22, y: r.minY + r.height * 0.08, width: r.width * 0.40, height: r.height * 0.24)),
               with: .radialGradient(Gradient(colors: [Color.white.opacity(0.45), .clear]), center: CGPoint(x: r.minX + r.width * 0.42, y: r.minY + r.height * 0.2),
                                     startRadius: 0, endRadius: r.width * 0.22))
        g.stroke(sphere, with: .color(Color.white.opacity(0.14)), lineWidth: 0.5)
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

/// The floating panel's living edge: a hairline that takes the accent and glows in step with the orb (same state, same
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
            let e = orb.edge(at: time, reduceMotion: reduceMotion)
            let c = orb.look(at: time, reduceMotion: reduceMotion).danger ? t.roles.danger : t.roles.accent
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            ZStack {
                shape.strokeBorder(t.roles.hairline, lineWidth: 1)
                shape.strokeBorder(c.opacity(0.25 + 0.75 * e), lineWidth: 1)
                shape.stroke(c.opacity(0.6 * e), lineWidth: 6).blur(radius: 10)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

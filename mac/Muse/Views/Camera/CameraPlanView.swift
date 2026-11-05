import MuseCore
import SwiftUI

/// Line style per cast member, shared by the plan, its legend and the side view: the first is the accent, then ink, then muted.
enum CastStyle {
    static func color(_ index: Int, _ t: Theme) -> Color {
        switch index % 4 {
        case 0: return t.accent
        case 1: return t.ink
        case 2: return t.isD ? t.blue : t.good
        default: return t.muted
        }
    }

    static func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").filter { !$0.isEmpty }
        let s = parts.prefix(2).compactMap(\.first).map(String.init).joined()
        return (s.isEmpty ? "?" : s).uppercased()
    }
}

/// The top-down plan (and the side view): grid, paths with time ticks, tokens at the playhead, the camera and its view cone.
/// Dragging a token or the camera moves (or inserts) the key at the playhead; the drawing's fit is frozen while dragging.
struct CameraPlanCanvas: View {
    @Environment(\.theme) private var t
    var session: CameraSession
    var playhead: Double
    var projection: PlanProjection = .top
    /// Read-only (phone-like) when false.
    var editable = true
    var onDrag: (PlanHandle, CGPoint) -> Void = { _, _ in }

    @State private var frozen: PlanGeometry?
    @State private var grabbed: PlanHandle?

    private var hasBlocking: Bool {
        !(session.cameraPath?.keyframes.isEmpty ?? true) || (session.blocking?.characters.contains { !$0.keyframes.isEmpty } ?? false)
    }

    var body: some View {
        GeometryReader { g in
            let geo = frozen ?? PlanGeometry(session: session, size: g.size, projection: projection)
            ZStack {
                Canvas { ctx, _ in
                    drawGrid(&ctx, geo)
                    if projection == .top { drawTop(&ctx, geo) } else { drawSide(&ctx, geo) }
                }
                if !hasBlocking {
                    Text(CameraText.emptyPlan).font(t.body(13)).foregroundStyle(t.muted).multilineTextAlignment(.center)
                        .padding(24).frame(maxWidth: 420)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(geo), including: editable && projection == .top && hasBlocking ? .all : .subviews)
        }
        .background(t.surface)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hasBlocking ? "Blocking plan at \(CameraTimeline.playheadLabel(playhead))" : CameraText.emptyPlan)
    }

    private func dragGesture(_ geo: PlanGeometry) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in
                if frozen == nil {
                    frozen = geo
                    grabbed = CameraDrag.hit(v.startLocation, session: session, at: playhead, geometry: geo)
                }
                guard let h = grabbed, let f = frozen else { return }
                onDrag(h, f.world(v.location))
            }
            .onEnded { _ in
                frozen = nil
                grabbed = nil
            }
    }

    // MARK: Drawing

    private func label(_ s: String, size: CGFloat = 9.5, color: Color? = nil) -> Text {
        Text(s).font(t.mono(size)).foregroundColor(color ?? t.muted)
    }

    private func drawGrid(_ ctx: inout GraphicsContext, _ g: PlanGeometry) {
        let (xs, ys) = g.grid(step: 0.5)
        var p = Path()
        for x in xs { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: g.size.height)) }
        for y in ys { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y)) }
        ctx.stroke(p, with: .color(t.line.opacity(0.55)), lineWidth: 0.5)
        if projection == .side {
            // The floor.
            let y = g.point(CGPoint(x: 0, y: 0)).y
            var f = Path()
            f.move(to: CGPoint(x: 0, y: y)); f.addLine(to: CGPoint(x: g.size.width, y: y))
            ctx.stroke(f, with: .color(t.ink.opacity(0.6)), lineWidth: 1)
        }
        // 1 m scale bar, bottom right.
        let w = g.scale
        let end = CGPoint(x: g.size.width - 16, y: g.size.height - 16)
        var bar = Path()
        bar.move(to: CGPoint(x: end.x - w, y: end.y)); bar.addLine(to: end)
        bar.move(to: CGPoint(x: end.x - w, y: end.y - 4)); bar.addLine(to: CGPoint(x: end.x - w, y: end.y + 4))
        bar.move(to: CGPoint(x: end.x, y: end.y - 4)); bar.addLine(to: CGPoint(x: end.x, y: end.y + 4))
        ctx.stroke(bar, with: .color(t.ink), lineWidth: 1)
        ctx.draw(label("1 m", color: t.ink), at: CGPoint(x: end.x - w / 2, y: end.y - 9), anchor: .center)
    }

    private func castIndex(_ id: String) -> Int {
        session.characters.firstIndex { $0.modelId == id } ?? (session.blocking?.characters.firstIndex { $0.modelId == id } ?? 0)
    }

    private func name(_ id: String) -> String { session.characters.first { $0.modelId == id }?.name ?? "Character" }

    private func drawTop(_ ctx: inout GraphicsContext, _ g: PlanGeometry) {
        // Camera path, cone and glyph first: the cast draws on top.
        let camKeys = session.cameraPath?.keyframes ?? []
        if camKeys.count > 1 {
            var p = Path()
            p.addLines(camKeys.map { g.point($0.position) })
            ctx.stroke(p, with: .color(t.ink.opacity(0.75)), style: StrokeStyle(lineWidth: 1.2, dash: [1.5, 3.5]))
        }
        if let pose = CameraMotion.camera(session.cameraPath, at: playhead) {
            let sensor = session.cameraPath?.sensorMm ?? CameraMotion.defaultSensor
            if let cone = g.viewCone(pose, sensorMm: sensor) {
                var c = Path()
                c.addLines(cone)
                c.closeSubpath()
                ctx.fill(c, with: .color(t.accent.opacity(0.12)))
                ctx.stroke(c, with: .color(t.accent.opacity(0.35)), lineWidth: 0.8)
            }
            let at = g.point(pose.position)
            let dir = atan2(-(pose.target.y - pose.position.y), pose.target.x - pose.position.x) // screen angle
            var glyph = ctx
            glyph.translateBy(x: at.x, y: at.y)
            glyph.rotate(by: .radians(dir))
            glyph.fill(Path(roundedRect: CGRect(x: -11, y: -7, width: 16, height: 14), cornerRadius: 2), with: .color(t.ink))
            var lens = Path()
            lens.move(to: CGPoint(x: 5, y: -3)); lens.addLine(to: CGPoint(x: 11, y: -7)); lens.addLine(to: CGPoint(x: 11, y: 7)); lens.addLine(to: CGPoint(x: 5, y: 3))
            lens.closeSubpath()
            glyph.fill(lens, with: .color(t.ink))
            if grabbed == .camera { glyph.stroke(Path(ellipseIn: CGRect(x: -16, y: -16, width: 32, height: 32)), with: .color(t.accent), lineWidth: 1.5) }
            let text = label(PlanGeometry.cameraLabel(pose).uppercased(), size: 9, color: t.ink)
            let lp = CGPoint(x: at.x + 16, y: at.y + 18)
            let size = ctx.resolve(text).measure(in: CGSize(width: 400, height: 40))
            ctx.fill(Path(CGRect(x: lp.x - 4, y: lp.y - size.height / 2 - 2, width: size.width + 8, height: size.height + 4)), with: .color(t.surface))
            ctx.stroke(Path(CGRect(x: lp.x - 4, y: lp.y - size.height / 2 - 2, width: size.width + 8, height: size.height + 4)), with: .color(t.line), lineWidth: 0.8)
            ctx.draw(text, at: lp, anchor: .leading)
        }

        for track in session.blocking?.characters ?? [] where !track.keyframes.isEmpty {
            let color = CastStyle.color(castIndex(track.modelId), t)
            if track.keyframes.count > 1 {
                var p = Path()
                p.addLines(track.keyframes.map { g.point($0.position) })
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.6, dash: [5, 4]))
            }
            for tick in CameraPathTicks.ticks(track.keyframes, g) {
                ctx.fill(Path(ellipseIn: CGRect(x: tick.point.x - 2.5, y: tick.point.y - 2.5, width: 5, height: 5)), with: .color(color))
                ctx.draw(label(tick.label, size: 9, color: color), at: CGPoint(x: tick.point.x, y: tick.point.y - 9), anchor: .center)
            }
            guard let pose = CameraMotion.character(track, at: playhead) else { continue }
            let at = g.point(pose.position)
            let r: CGFloat = 12
            // Facing arrow (screen y is flipped).
            let f = pose.facing
            let tip = CGPoint(x: at.x + CGFloat(f.x) * (r + 7), y: at.y - CGFloat(f.y) * (r + 7))
            let side = CGPoint(x: -CGFloat(f.y) * 4, y: -CGFloat(f.x) * 4)
            var arrow = Path()
            let base = CGPoint(x: at.x + CGFloat(f.x) * (r + 1), y: at.y - CGFloat(f.y) * (r + 1))
            arrow.move(to: tip); arrow.addLine(to: CGPoint(x: base.x + side.x, y: base.y + side.y)); arrow.addLine(to: CGPoint(x: base.x - side.x, y: base.y - side.y))
            arrow.closeSubpath()
            ctx.fill(arrow, with: .color(color))
            let token = Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r, width: 2 * r, height: 2 * r))
            ctx.fill(token, with: .color(color == t.ink ? t.ink : color))
            if grabbed == .character(track.modelId) { ctx.stroke(Path(ellipseIn: CGRect(x: at.x - r - 4, y: at.y - r - 4, width: 2 * r + 8, height: 2 * r + 8)), with: .color(t.accent), lineWidth: 1.5) }
            ctx.draw(Text(CastStyle.initials(name(track.modelId))).font(t.mono(9, .semibold)).foregroundColor(color == t.ink ? t.bg : t.accentInk), at: at, anchor: .center)
            let action = pose.action.map { "\(name(track.modelId)) · \($0)" } ?? name(track.modelId)
            ctx.draw(label(action, size: 9.5, color: color == t.ink ? t.ink : color), at: CGPoint(x: at.x + r + 6, y: at.y + r + 4), anchor: .leading)
        }
    }

    private func drawSide(_ ctx: inout GraphicsContext, _ g: PlanGeometry) {
        if let keys = session.cameraPath?.keyframes, keys.count > 1 {
            var p = Path()
            p.addLines(keys.map { g.point($0.position) })
            ctx.stroke(p, with: .color(t.ink.opacity(0.75)), style: StrokeStyle(lineWidth: 1.2, dash: [1.5, 3.5]))
        }
        if let pose = CameraMotion.camera(session.cameraPath, at: playhead) {
            let at = g.point(pose.position), aim = g.point(pose.target)
            var sight = Path()
            sight.move(to: at); sight.addLine(to: aim)
            ctx.stroke(sight, with: .color(t.accent.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ctx.fill(Path(roundedRect: CGRect(x: at.x - 8, y: at.y - 6, width: 16, height: 12), cornerRadius: 2), with: .color(t.ink))
            ctx.draw(label(PlanGeometry.cameraLabel(pose).uppercased(), size: 9, color: t.ink), at: CGPoint(x: at.x + 12, y: at.y - 12), anchor: .leading)
        }
        for track in session.blocking?.characters ?? [] {
            guard let pose = CameraMotion.character(track, at: playhead) else { continue }
            let color = CastStyle.color(castIndex(track.modelId), t)
            let h = session.characters.first { $0.modelId == track.modelId }?.heightM ?? 1.68
            let foot = g.point(pose.position), head = g.point(pose.position + Vec3(0, 0, h))
            let w = max(6, 0.4 * g.scale)
            ctx.fill(Path(roundedRect: CGRect(x: foot.x - w / 2, y: head.y, width: w, height: foot.y - head.y), cornerRadius: w / 2), with: .color(color.opacity(0.85)))
            ctx.draw(label("\(name(track.modelId)) · \(CameraText.metres(h))", size: 9.5, color: color), at: CGPoint(x: foot.x, y: head.y - 8), anchor: .center)
        }
    }
}

/// "Camera view": the newest still nearest the playhead.
struct CameraStillView: View {
    @Environment(\.theme) private var t
    var session: CameraSession
    var playhead: Double

    var body: some View {
        if let a = CameraGuides.still(session, at: playhead), let url = a.url {
            ZStack(alignment: .bottomLeading) {
                MuseImage(ref: ImageRef(url: url), symbol: "camera")
                Pill(CameraGuides.label(a.kind), .yours).padding(10)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "camera.viewfinder").font(.system(size: 22)).foregroundStyle(t.muted)
                Text("No camera stills yet · Re-render to make the keyframes").font(t.body(13)).foregroundStyle(t.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(t.surface)
        }
    }
}

/// Legend under the plan: one line style per character, the camera, and the drag hint.
struct CameraPlanLegend: View {
    @Environment(\.theme) private var t
    var session: CameraSession
    var editable = true

    var body: some View {
        HStack(spacing: 16) {
            ForEach(Array(session.characters.enumerated()), id: \.element.modelId) { i, c in
                HStack(spacing: 6) {
                    Rectangle().fill(CastStyle.color(i, t)).frame(width: 14, height: 3)
                    Text(i == 0 ? "\(c.name)’s path" : c.name).font(t.body(12)).foregroundStyle(t.ink)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "video.fill").font(.system(size: 11)).foregroundStyle(t.ink)
                Text("Camera path & view").font(t.body(12)).foregroundStyle(t.ink)
            }
            Spacer(minLength: 8)
            if editable { Text(CameraText.dragNote).font(t.body(12)).foregroundStyle(t.muted).lineLimit(1) }
        }
    }
}

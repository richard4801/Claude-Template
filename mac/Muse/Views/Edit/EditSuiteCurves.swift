import MuseCore
import SwiftUI

/// Curves (parity, as Android's CurvesEditor): All / Red / Green / Blue on the selected picture's `look.curves`. Drag a point
/// to move it, click on the line away from a point to add one, click a point (without dragging) to remove it. The ends stay
/// at x 0 and 1. A drag is one undo step.
struct CurvesEditor: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    @State private var channel: EditSuite.CurveChannel = .rgb
    /// The point being dragged (its index in the points as the drag started) and whether it moved.
    @State private var dragging: Int?
    @State private var moved = false
    @State private var startPoints: EditV2.CurvePoints = []

    private static let straight: EditV2.CurvePoints = [[0, 0], [1, 1]]
    private var points: EditV2.CurvePoints { session.state.curve(channel) ?? Self.straight }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(EditSuite.CurveChannel.allCases) { ch in
                    Chip(ch.label, on: channel == ch) { channel = ch }
                }
                Spacer(minLength: 0)
                SuiteToolButton(title: "Reset curve", icon: "arrow-counter-clockwise", disabled: session.state.curve(channel) == nil, plain: true, iconOnly: true) {
                    session.edit { $0.setCurve(channel, nil) }
                }
            }
            GeometryReader { g in
                let side = g.size.width
                Canvas { ctx, size in draw(ctx, size) }
                    .frame(width: side, height: side)
                    .background(t.roles.field)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in changed(v, side) }.onEnded { v in ended(v, side) })
            }
            .aspectRatio(1, contentMode: .fit)
            .accessibilityElement()
            .accessibilityLabel("Curve \(channel.label)")
            .accessibilityValue("\(points.count) points")
        }
    }

    private var lineColor: Color {
        switch channel {
        case .rgb: return t.roles.ink
        case .r: return Color(red: 0.86, green: 0.3, blue: 0.3)
        case .g: return Color(red: 0.3, green: 0.72, blue: 0.4)
        case .b: return Color(red: 0.35, green: 0.5, blue: 0.95)
        }
    }

    /// The curve's output at `x` (the engine's own interpolation, so the line is what the picture gets).
    private func value(_ x: Double) -> Double {
        let c: EditV2.Curves
        switch channel {
        case .rgb: c = EditV2.Curves(rgb: points)
        case .r: c = EditV2.Curves(r: points)
        case .g: c = EditV2.Curves(g: points)
        case .b: c = EditV2.Curves(b: points)
        }
        guard let f = EditV2.curvesFn(c) else { return x }
        let o = f(SIMD3(x, x, x))
        switch channel {
        case .rgb, .r: return o.x
        case .g: return o.y
        case .b: return o.z
        }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        var grid = Path()
        for i in 1..<4 {
            let f = CGFloat(i) / 4
            grid.move(to: CGPoint(x: w * f, y: 0)); grid.addLine(to: CGPoint(x: w * f, y: h))
            grid.move(to: CGPoint(x: 0, y: h * f)); grid.addLine(to: CGPoint(x: w, y: h * f))
        }
        ctx.stroke(grid, with: .color(t.roles.hairline), lineWidth: 1)
        var diag = Path(); diag.move(to: CGPoint(x: 0, y: h)); diag.addLine(to: CGPoint(x: w, y: 0))
        ctx.stroke(diag, with: .color(t.roles.hairline), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        var line = Path()
        let n = 64
        for i in 0...n {
            let x = Double(i) / Double(n)
            let p = CGPoint(x: w * x, y: h * (1 - min(1, max(0, value(x)))))
            if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
        }
        ctx.stroke(line, with: .color(lineColor), lineWidth: 1.5)
        for p in points {
            let c = CGPoint(x: w * p[0], y: h * (1 - p[1]))
            let r = CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
            ctx.fill(Path(ellipseIn: r), with: .color(t.roles.canvas))
            ctx.stroke(Path(ellipseIn: r), with: .color(lineColor), lineWidth: 1.5)
        }
    }

    private func unit(_ p: CGPoint, _ side: CGFloat) -> (Double, Double) {
        (min(1, max(0, Double(p.x / max(1, side)))), min(1, max(0, 1 - Double(p.y / max(1, side)))))
    }

    private func changed(_ v: DragGesture.Value, _ side: CGFloat) {
        let (x, y) = unit(v.location, side)
        if dragging == nil {
            // Start: the nearest point within 10 pt, or a new point on the curve here.
            let (sx, _) = unit(v.startLocation, side)
            var pts = points
            let near = pts.indices.min { abs(pts[$0][0] - sx) < abs(pts[$1][0] - sx) }
            if let i = near, abs(pts[i][0] - sx) * Double(side) <= 10 {
                dragging = i
            } else {
                guard pts.count < 16 else { session.lastError = "A curve has at most 16 points"; return }
                pts.append([sx, value(sx)]); pts.sort { $0[0] < $1[0] }
                dragging = pts.firstIndex { $0[0] == sx }
                moved = true
            }
            startPoints = pts
            session.beginGesture()
            if moved { push(pts) }
            return
        }
        guard let i = dragging, hypot(v.translation.width, v.translation.height) > 2 || moved else { return }
        moved = true
        var pts = startPoints
        let lo = i == 0 ? 0.0 : pts[i - 1][0] + 0.01, hi = i == pts.count - 1 ? 1.0 : pts[i + 1][0] - 0.01
        let nx = (i == 0 || i == pts.count - 1) ? pts[i][0] : min(hi, max(lo, x))
        pts[i] = [nx, y]
        push(pts)
    }

    private func ended(_ v: DragGesture.Value, _ side: CGFloat) {
        defer { dragging = nil; moved = false; startPoints = [] }
        guard let i = dragging else { return }
        if !moved, i > 0, i < startPoints.count - 1 {
            // A click on an inner point removes it.
            var pts = startPoints
            pts.remove(at: i)
            push(pts)
        }
        session.endGesture()
    }

    private func push(_ pts: EditV2.CurvePoints) {
        let ch = channel
        session.updateGesture { st in
            var c = st
            return c.setCurve(ch, pts) ? c.project : nil
        }
    }
}

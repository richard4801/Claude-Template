import AVFoundation
import MuseCore
import SwiftUI

// AI suite (workstream 1): a picker preview. Today every preview is a still (a bundled hardware render); when a tile's
// `PickerPreview.video` is set (a looping mp4/webm, bundled name or URL) it plays muted while the pointer is over it, and
// the still stays the fallback. Swapping stills for loops is only a data change.

struct PreviewView: View {
    var preview: PickerPreview
    var fallback = ""
    @State private var hovering = false
    @State private var looper: StageLooper?

    var body: some View {
        ZStack {
            HardwareImage(name: preview.still ?? fallback)
            if let looper { PlayerLayerView(player: looper.player).allowsHitTesting(false) }
        }
        .onHover { h in
            hovering = h
            if h { start() } else { stop() }
        }
        .onDisappear { stop() }
    }

    private var videoURL: URL? {
        guard let v = preview.video, !v.isEmpty else { return nil }
        if v.hasPrefix("http") || v.hasPrefix("file:") { return URL(string: v) }
        let ext = (v as NSString).pathExtension.isEmpty ? "mp4" : (v as NSString).pathExtension
        let name = (v as NSString).deletingPathExtension
        return Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "previews") ?? Bundle.main.url(forResource: name, withExtension: ext)
    }

    private func start() {
        guard looper == nil, let url = videoURL else { return }
        looper = StageLooper(url: url, muted: true)
    }

    private func stop() {
        looper?.stop()
        looper = nil
    }
}

/// The motion arrow drawn over a move's neutral still, by the move's kind.
struct MoveArrow: View {
    var move: SuiteMoveOption
    private let amber = Color(hex: 0xF2A93B)

    var body: some View {
        Canvas { ctx, size in draw(&ctx, size) }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        let cx = w / 2
        var p = Path()
        var head: (CGPoint, Double)?
        let id = move.id
        switch true {
        case id.contains("dolly_out") || id.contains("zoom_out"):
            p.move(to: CGPoint(x: cx, y: h * 0.62)); p.addLine(to: CGPoint(x: cx, y: h * 0.9)); head = (CGPoint(x: cx, y: h * 0.94), 90)
        case id.contains("dolly") || id.contains("push") || id.contains("zoom") || move.category == "push":
            p.move(to: CGPoint(x: cx, y: h * 0.92)); p.addLine(to: CGPoint(x: cx, y: h * 0.66)); head = (CGPoint(x: cx, y: h * 0.62), -90)
        case id.contains("left"):
            p.move(to: CGPoint(x: w * 0.78, y: h * 0.45)); p.addLine(to: CGPoint(x: w * 0.24, y: h * 0.45)); head = (CGPoint(x: w * 0.19, y: h * 0.45), 180)
        case id.contains("right") || id.contains("track") || id.contains("whip"):
            p.move(to: CGPoint(x: w * 0.22, y: h * 0.45)); p.addLine(to: CGPoint(x: w * 0.76, y: h * 0.45)); head = (CGPoint(x: w * 0.81, y: h * 0.45), 0)
        case id.contains("up"):
            p.move(to: CGPoint(x: w * 0.17, y: h * 0.86)); p.addLine(to: CGPoint(x: w * 0.17, y: h * 0.3)); head = (CGPoint(x: w * 0.17, y: h * 0.25), -90)
        case id.contains("down") || id.contains("overhead"):
            p.move(to: CGPoint(x: w * 0.17, y: h * 0.25)); p.addLine(to: CGPoint(x: w * 0.17, y: h * 0.8)); head = (CGPoint(x: w * 0.17, y: h * 0.85), 90)
        case move.category == "orbit":
            p.addArc(center: CGPoint(x: cx, y: h * 0.66), radius: w * 0.3, startAngle: .degrees(0), endAngle: .degrees(170), clockwise: false)
            head = (CGPoint(x: cx - w * 0.3, y: h * 0.66 + 4), 260)
        case move.category == "aerial":
            p.move(to: CGPoint(x: w * 0.1, y: h * 0.92))
            p.addCurve(to: CGPoint(x: w * 0.84, y: h * 0.22), control1: CGPoint(x: w * 0.3, y: h * 0.5), control2: CGPoint(x: w * 0.6, y: h * 0.95))
            head = (CGPoint(x: w * 0.86, y: h * 0.18), -70)
        case id.contains("handheld") || id.contains("snorri"):
            p.move(to: CGPoint(x: w * 0.12, y: h * 0.84))
            for i in 1...6 {
                let x: CGFloat = w * 0.12 + CGFloat(i) * w * 0.05
                let y: CGFloat = h * (i % 2 == 0 ? 0.84 : 0.79)
                p.addLine(to: CGPoint(x: x, y: y))
            }
        case move.category == "follow":
            p.move(to: CGPoint(x: w * 0.2, y: h * 0.45)); p.addLine(to: CGPoint(x: w * 0.76, y: h * 0.45)); head = (CGPoint(x: w * 0.81, y: h * 0.45), 0)
        case move.category == "static":
            p.addRect(CGRect(x: w * 0.12, y: h * 0.12, width: w * 0.76, height: h * 0.76))
        default:
            // Special moves: a focus ring.
            p.addEllipse(in: CGRect(x: cx - w * 0.14, y: h * 0.18, width: w * 0.28, height: w * 0.28))
        }
        let style = StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
        ctx.addFilter(.shadow(color: .black.opacity(0.65), radius: 2, y: 1))
        ctx.stroke(p, with: .color(move.category == "static" ? .white.opacity(0.4) : amber), style: style)
        if let hd = head {
            let pt = hd.0, angle = hd.1
            var tri = Path()
            tri.move(to: .zero)
            tri.addLine(to: CGPoint(x: -10, y: -5.5))
            tri.addLine(to: CGPoint(x: -10, y: 5.5))
            tri.closeSubpath()
            let tf = CGAffineTransform(translationX: pt.x, y: pt.y).rotated(by: CGFloat(angle * Double.pi / 180))
            ctx.fill(tri.applying(tf), with: .color(amber))
        }
    }
}

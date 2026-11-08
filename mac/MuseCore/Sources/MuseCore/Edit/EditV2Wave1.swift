import Foundation

// Editor contract, wave 1 (plans/edit-parity.md): mirror (Transform.flipX / flipY), freeze frame (VideoClip.holdSec, timing in
// EditV2Functions), blend modes (blend on overlay items) and the blur fill (Canvas.fill). A port of the wave-1 part of
// server/api/src/editor/model.ts; the shared fixtures (functions.json → wave1, projects.json, validation.json) check it.

extension EditV2 {
    /// One channel of the W3C compositing blend functions: top = the item (Cs), below = the backdrop (Cb), both 0–1.
    public static func blendChannel(_ mode: BlendMode, top s: Double, below b: Double) -> Double {
        switch mode {
        case .normal: return s
        case .multiply: return b * s
        case .screen: return b + s - b * s
        case .overlay: return b <= 0.5 ? 2 * b * s : 1 - 2 * (1 - b) * (1 - s)   // hard-light with the layers swapped
        case .softLight:
            if s <= 0.5 { return b - (1 - 2 * s) * b * (1 - b) }
            let d = b <= 0.25 ? ((16 * b - 12) * b + 4) * b : b.squareRoot()
            return b + (2 * s - 1) * (d - b)
        case .darken: return min(b, s)
        case .lighten: return max(b, s)
        case .add: return min(1, b + s)
        }
    }

    /// A pixel of a blended item over what is below it, on straight sRGB 0–1, mixed in by the item's coverage
    /// a = alpha × opacity: below + (blend − below) × a.
    public static func blendPixel(_ mode: BlendMode, top: [Double], below: [Double], a: Double) -> [Double] {
        (0..<3).map { i in r6(below[i] + (clamp(blendChannel(mode, top: top[i], below: below[i]), 0, 1) - below[i]) * clamp(a, 0, 1)) }
    }

    /// Where an item's picture corners land on the canvas (pixels): fitted, mirrored about its centre, scaled, rotated clockwise
    /// and moved. The picture's own top-left, top-right, bottom-right, bottom-left (a flip shows as swapped corners).
    public static func itemCorners(canvasWidth cw: Double, canvasHeight ch: Double, w: Double, h: Double, fit: Fit, transform t: Transform?) -> [[Double]] {
        let k = fit == .cover ? max(cw / w, ch / h) : min(cw / w, ch / h)
        let sc = t?.scale ?? 1, hw = w * k * sc / 2, hh = h * k * sc / 2
        let fx: Double = t?.flipX == true ? -1 : 1, fy: Double = t?.flipY == true ? -1 : 1
        let a = (t?.rotation ?? 0) * Double.pi / 180, cosA = cos(a), sinA = sin(a)
        let cx = (t?.x ?? 0.5) * cw, cy = (t?.y ?? 0.5) * ch
        return [[-1.0, -1.0], [1, -1], [1, 1], [-1, 1]].map { uv in
            let px = uv[0] * hw * fx, py = uv[1] * hh * fy
            return [r6(cx + px * cosA - py * sinA), r6(cy + px * sinA + py * cosA)]
        }
    }

    /// Blur fill: the box-blur radius in pixels (applied once, separable, clamp to edge), then RGB × blurFillDarken.
    public static func blurFillRadius(width: Int, height: Int) -> Int { max(1, Int(jsRound(0.04 * Double(min(width, height))))) }
    public static let blurFillDarken = 0.85

    /// The blur fill of a cover-fitted frame (w × h × 3 floats 0–1, row-major): box-blurred and darkened. CPU reference (tests).
    public static func blurFill(_ rgb: [Double], w: Int, h: Int, radius: Int) -> [Double] {
        func box(_ src: [Double], horizontal: Bool) -> [Double] {
            var out = [Double](repeating: 0, count: src.count)
            for y in 0..<h {
                for x in 0..<w {
                    for c in 0..<3 {
                        var sum = 0.0
                        for k in -radius...radius {
                            let xx = horizontal ? min(max(x + k, 0), w - 1) : x, yy = horizontal ? y : min(max(y + k, 0), h - 1)
                            sum += src[(yy * w + xx) * 3 + c]
                        }
                        out[(y * w + x) * 3 + c] = sum / Double(2 * radius + 1)
                    }
                }
            }
            return out
        }
        return box(box(rgb, horizontal: true), horizontal: false).map { r6($0 * blurFillDarken) }
    }

    /// Which main clip (and its local time) the blur fill shows at timeline t: the incoming clip from half-way through a transition.
    public static func blurFillClip(_ p: Project, _ t: Double) -> (clipId: String, local: Double)? {
        let spans = timeline(p)
        for (i, s) in spans.enumerated() {
            if t < s.startSec - 1e-9 || t > s.endSec + 1e-9 { continue }
            if i + 1 < spans.count {
                let next = spans[i + 1]
                if t >= next.startSec && next.transitionSec > 0 {
                    let pick = (t - next.startSec) / next.transitionSec >= 0.5 ? next : s
                    return (pick.id, r6(t - pick.startSec))
                }
            }
            return (s.id, r6(t - s.startSec))
        }
        return nil
    }
}

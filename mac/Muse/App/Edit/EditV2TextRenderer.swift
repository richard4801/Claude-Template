import AppKit
import CoreText
import MuseCore

/// Draws text items, hooks and caption pages to images with Core Text (thread-safe; used on the compositor's queue): the
/// bundled font families, weight, size, colour, alignment, wrap width, line height, letter spacing, upper case, stroke,
/// shadow and a rounded background, plus per-word colours, scale and a highlight box for the caption presets.
enum EditV2TextRenderer {
    struct Run {
        var text: String
        var color: String
        /// A rounded box of this colour behind the word (caption preset `box`).
        var box: String?
        var scale: Double = 1
        init(text: String, color: String, box: String? = nil, scale: Double = 1) {
            self.text = text
            self.color = color
            self.box = box
            self.scale = scale
        }
    }

    /// The bundled family for each contract font (registered at launch by Fonts.registerBundled); nil = the system font.
    static func family(_ f: EditV2.Font) -> String? {
        switch f {
        case .sans: return "Figtree"
        case .serif: return "Instrument Serif"
        case .rounded: return nil
        case .condensed: return "Barlow Condensed"
        case .mono: return "DM Mono"
        case .marker: return "Permanent Marker"
        }
    }

    static func font(_ f: EditV2.Font, weight: Int, size: CGFloat) -> NSFont {
        let w: NSFont.Weight = weight >= 900 ? .black : weight >= 700 ? .bold : .regular
        if let family = family(f) {
            let d = NSFontDescriptor(fontAttributes: [.family: family, .traits: [NSFontDescriptor.TraitKey.weight: w.rawValue]])
            if let font = NSFont(descriptor: d, size: size), font.familyName == family { return font }
        }
        let sys = NSFont.systemFont(ofSize: size, weight: w)
        if f == .rounded, let d = sys.fontDescriptor.withDesign(.rounded), let r = NSFont(descriptor: d, size: size) { return r }
        if f == .mono { return NSFont.monospacedSystemFont(ofSize: size, weight: w) }
        return sys
    }

    static func cgColor(_ hex: String, alpha: Double = 1) -> CGColor {
        let (r, g, b) = EditV2.hexRgb(hex)
        return CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }

    private static let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
    private static let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
    private static let kernKey = NSAttributedString.Key(kCTKernAttributeName as String)
    private static let strokeWidthKey = NSAttributedString.Key(kCTStrokeWidthAttributeName as String)
    private static let strokeColorKey = NSAttributedString.Key(kCTStrokeColorAttributeName as String)
    private static let paragraphKey = NSAttributedString.Key(kCTParagraphStyleAttributeName as String)

    /// The runs joined by spaces, drawn with `style` at `fontSize` px, wrapped at `wrapWidth` px. Transparent around the text.
    static func render(_ runs: [Run], style: EditV2.TextStyle, fontSize: CGFloat, wrapWidth: CGFloat) -> CGImage? {
        guard fontSize > 0, wrapWidth > 0, !runs.isEmpty else { return nil }
        let para = NSMutableParagraphStyle()
        para.alignment = style.align == .left ? .left : style.align == .right ? .right : .center
        let lineHeight = fontSize * CGFloat(style.lineHeight ?? 1.15)
        para.minimumLineHeight = lineHeight
        para.maximumLineHeight = lineHeight
        para.lineBreakMode = .byWordWrapping
        func attrs(_ scale: Double, _ color: String) -> [NSAttributedString.Key: Any] {
            let size = fontSize * CGFloat(scale)
            return [fontKey: font(style.font, weight: style.weight, size: size), colorKey: cgColor(color),
                    kernKey: NSNumber(value: Double(size) * (style.letterSpacing ?? 0)), paragraphKey: para]
        }
        let fill = NSMutableAttributedString()
        var boxes: [(NSRange, String)] = []
        for (i, r) in runs.enumerated() {
            if i > 0 { fill.append(NSAttributedString(string: " ", attributes: attrs(1, style.color))) }
            let text = style.uppercase == true ? r.text.uppercased() : r.text
            let start = fill.length
            fill.append(NSAttributedString(string: text, attributes: attrs(r.scale, r.color)))
            if let b = r.box { boxes.append((NSRange(location: start, length: fill.length - start), b)) }
        }
        let fs = CTFramesetterCreateWithAttributedString(fill as CFAttributedString)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: 0), nil,
                                                                       CGSize(width: wrapWidth, height: .greatestFiniteMagnitude), nil)
        let textW = ceil(min(wrapWidth, suggested.width) + 2), textH = ceil(suggested.height + fontSize * 0.1)
        let pad = style.background.map { CGFloat($0.paddingPct) * fontSize } ?? 0
        let strokeW = style.stroke.map { CGFloat($0.widthPct) * fontSize } ?? 0
        let blur = style.shadow.map { CGFloat($0.blurPct) * fontSize } ?? 0
        let dy = style.shadow.map { CGFloat($0.dyPct) * fontSize } ?? 0
        let boxPad = boxes.isEmpty ? 0 : fontSize * 0.15
        let margin = ceil(max(pad, boxPad) + strokeW + blur + abs(dy) + 2)
        let width = Int(textW + 2 * margin), height = Int(textH + 2 * margin)
        guard width > 0, height > 0, width < 16384, height < 16384,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.textMatrix = .identity
        let textRect = CGRect(x: margin, y: margin, width: textW, height: textH)

        if let bg = style.background {
            let r = textRect.insetBy(dx: -pad, dy: -pad)
            let radius = min(CGFloat(bg.radiusPct) * fontSize, r.height / 2, r.width / 2)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setFillColor(cgColor(bg.color, alpha: bg.opacity))
            ctx.fillPath()
        }

        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: textRect, transform: nil), nil)
        if !boxes.isEmpty, let lines = CTFrameGetLines(frame) as? [CTLine] {
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
            for (range, color) in boxes {
                for (line, o) in zip(lines, origins) {
                    let lr = CTLineGetStringRange(line)
                    let a = max(range.location, lr.location), b = min(range.location + range.length, lr.location + lr.length)
                    guard b > a else { continue }
                    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                    _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
                    let x0 = CTLineGetOffsetForStringIndex(line, a, nil), x1 = CTLineGetOffsetForStringIndex(line, b, nil)
                    let r = CGRect(x: textRect.minX + o.x + x0, y: textRect.minY + o.y - descent, width: x1 - x0, height: ascent + descent)
                        .insetBy(dx: -boxPad, dy: -boxPad * 0.5)
                    let radius = min(fontSize * 0.2, r.width / 2, r.height / 2)
                    ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
                    ctx.setFillColor(cgColor(color))
                    ctx.fillPath()
                }
            }
        }

        if let sh = style.shadow {
            ctx.setShadow(offset: CGSize(width: 0, height: -dy), blur: blur, color: cgColor(sh.color, alpha: sh.opacity))
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        if let st = style.stroke, st.widthPct > 0 {
            // Core Text strokes centred on the outline: twice the width, the fill drawn on top covers the inner half.
            let stroked = NSMutableAttributedString(attributedString: fill)
            stroked.addAttributes([strokeWidthKey: NSNumber(value: st.widthPct * 200), strokeColorKey: cgColor(st.color)],
                                  range: NSRange(location: 0, length: stroked.length))
            ctx.setLineJoin(.round)
            let sfs = CTFramesetterCreateWithAttributedString(stroked as CFAttributedString)
            CTFrameDraw(CTFramesetterCreateFrame(sfs, CFRange(location: 0, length: 0), CGPath(rect: textRect, transform: nil), nil), ctx)
        }
        CTFrameDraw(frame, ctx)
        ctx.endTransparencyLayer()
        return ctx.makeImage()
    }
}

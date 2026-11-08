import Foundation

/// The Look swatches as the Recipe view shows them (owner note: "never garish"). The analysis reports the reference's
/// real colours, which can include pure greens and yellows that look broken on screen. The display keeps each colour's
/// hue but calms it: saturation is clamped, brightness kept in a mid range, and the strip is 3–5 swatches ordered by tone
/// (dark to light).
public enum RecreateSwatches {
    /// No shown swatch is more saturated than this (HSB saturation, 0–1).
    public static let maxSaturation = 0.38
    /// Shown swatches stay in this HSB brightness range.
    public static let brightness: ClosedRange<Double> = 0.35...0.76
    public static let minCount = 3
    public static let maxCount = 5

    /// The softened strip: `#RRGGBB` strings, 3–5 of them (none when no colour could be read), dark to light.
    public static func soften(_ hexes: [String]) -> [String] {
        // A little under the clamp, so rounding to 8-bit channels never lands above it.
        let sCap = maxSaturation - 0.015
        var hsb: [(h: Double, s: Double, v: Double)] = hexes.compactMap { rgb($0) }.map { c -> (h: Double, s: Double, v: Double) in
            let x = toHSB(c)
            return (h: x.h, s: min(x.s, sCap), v: min(max(x.v, brightness.lowerBound), brightness.upperBound))
        }
        guard !hsb.isEmpty else { return [] }
        // Fewer than three: add a darker and a lighter tone of the middle colour.
        while hsb.count < minCount {
            let mid = hsb[hsb.count / 2]
            let darker = (h: mid.h, s: mid.s, v: max(brightness.lowerBound, mid.v - 0.2))
            let lighter = (h: mid.h, s: mid.s * 0.8, v: min(brightness.upperBound, mid.v + 0.2))
            hsb.append(hsb.count % 2 == 1 ? darker : lighter)
        }
        var out = hsb.map { hex(fromHSB($0.h, $0.s, $0.v)) }
        out.sort { luminance($0) < luminance($1) }
        if out.count > maxCount {
            // Keep the darkest, the lightest and evenly spaced tones between.
            let n = out.count
            out = (0..<maxCount).map { out[Int((Double($0) * Double(n - 1) / Double(maxCount - 1)).rounded())] }
        }
        return out
    }

    // MARK: Colour helpers

    /// `#RRGGBB` (or `RRGGBB`) → 0–1 channels.
    public static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    public static func hex(_ c: (r: Double, g: Double, b: Double)) -> String {
        func b(_ x: Double) -> Int { max(0, min(255, Int((x * 255).rounded()))) }
        return String(format: "#%02X%02X%02X", b(c.r), b(c.g), b(c.b))
    }

    public static func toHSB(_ c: (r: Double, g: Double, b: Double)) -> (h: Double, s: Double, v: Double) {
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == c.r { h = ((c.g - c.b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == c.g { h = (c.b - c.r) / d + 2 }
            else { h = (c.r - c.g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    public static func fromHSB(_ h: Double, _ s: Double, _ v: Double) -> (r: Double, g: Double, b: Double) {
        let hh = (h - floor(h)) * 6, i = Int(hh) % 6, f = hh - floor(hh)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    /// HSB saturation of a hex colour (0 for one that can't be read).
    public static func saturation(_ hex: String) -> Double { rgb(hex).map { toHSB($0).s } ?? 0 }

    /// Relative luminance (WCAG), for ordering by tone.
    public static func luminance(_ hex: String) -> Double {
        guard let c = rgb(hex) else { return 0 }
        func lin(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }
}

extension RecreateText {
    /// The analysis steps, in the order the server reports them as `phase` (server/api/src/recreate/analyze.ts).
    public static let analysisSteps = ["Finding the cuts", "Listening for the beat", "Reading the text", "Reading the look", "Reading the poses", "Writing the recipe"]

    /// The step the analysis is on (its index in `analysisSteps`): -1 before the first, `analysisSteps.count` once done.
    public static func analysisStep(phase: String?, state: String) -> Int {
        if state == "ready" { return analysisSteps.count }
        guard let phase, let i = analysisSteps.firstIndex(where: { $0.caseInsensitiveCompare(phase) == .orderedSame }) else {
            return phase?.lowercased() == "done" ? analysisSteps.count : -1
        }
        return i
    }

    /// "$1.28".
    public static func money(_ amount: Double) -> String { String(format: "$%.2f", amount) }

    /// "1 from your takes, 2 to generate · $1.28 in all", from the fill (never hard-coded).
    public static func makingSummary(_ fill: RecreateFill) -> String {
        let yours = fill.slots.filter { $0.state == "matched" || $0.state == "ready" }.count
        let generate = fill.slots.filter { $0.state == "to_generate" }.count
        let generating = fill.slots.filter { $0.state == "generating" }.count
        let empty = fill.slots.count - yours - generate - generating
        var parts: [String] = []
        if yours > 0 { parts.append("\(yours) from your takes") }
        if generate > 0 { parts.append("\(generate) to generate") }
        if generating > 0 { parts.append("\(generating) generating") }
        if empty > 0 { parts.append("\(empty) to fill") }
        let head = parts.isEmpty ? "No shots yet" : parts.joined(separator: ", ")
        return generate > 0 ? "\(head) · \(money(fill.toGenerateTotal)) in all" : "\(head) · nothing to pay"
    }

    public static let approveNote = "You approve before anything is made."

    /// The whole line: "1 from your takes, 2 to generate · $1.28 in all. You approve before anything is made."
    public static func makingLine(_ fill: RecreateFill) -> String { "\(makingSummary(fill)). \(approveNote)" }

    static let shotSizes = ["els": "Extreme wide", "ls": "Wide", "full": "Full body", "cowboy": "Cowboy", "ms": "Medium", "mcu": "Medium close-up",
                            "cu": "Close-up", "ecu": "Extreme close-up", "insert": "Insert", "ots": "Over the shoulder", "pov": "POV", "two_shot": "Two-shot"]
    static let heights = ["eye": "eye level", "shoulder": "shoulder level", "low": "low angle", "high": "high angle", "overhead": "overhead",
                          "worm": "worm’s-eye", "ground": "ground level", "hip": "hip level"]

    /// "Close-up · eye level · flips her hair", or nil when the slot has no brief yet.
    public static func brief(_ b: Recipe.Slot.Brief?) -> String? {
        guard let b else { return nil }
        let parts = [b.shotSize.flatMap { shotSizes[$0] }, b.angle.flatMap { heights[$0] }, b.action].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

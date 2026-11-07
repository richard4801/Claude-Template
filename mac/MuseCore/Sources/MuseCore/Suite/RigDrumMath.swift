import Foundation

/// The drum wheel's maths (design/drum-wheels-prototype.html), pure so it can be tested. The same names and values as
/// the Android port. A drum's `pos` is a continuous item index: 2.0 has item 2 in the band, 2.5 sits between 2 and 3.
/// While a drum loops, `pos` stays unwrapped (it can be -3 or 14); `nearest` wraps it into the list.
public enum RigDrumMath {
    /// Degrees between detents on the drum.
    public static let stepDegrees = 21.0

    /// Drums with 5 or more items loop, so the band never has an empty neighbour (owner fix 2).
    public static func loops(_ n: Int) -> Bool { n >= 5 }

    /// Rounds .5 up (towards +infinity), as Kotlin's `floor(x + 0.5)`: 2.5 → 3, -2.5 → -2.
    public static func roundHalfUp(_ x: Double) -> Double { (x + 0.5).rounded(.down) }

    /// An index wrapped into 0..<n (negatives too).
    public static func wrap(_ i: Int, _ n: Int) -> Int {
        guard n > 0 else { return 0 }
        return ((i % n) + n) % n
    }

    /// The signed distance, in items, from `pos` to item `i`; the shortest way round while looping.
    public static func delta(item i: Int, pos: Double, count n: Int, loop: Bool) -> Double {
        var d = Double(i) - pos
        if loop && n > 0 { d -= Double(n) * roundHalfUp(d / Double(n)) }
        return d
    }

    /// The item in the band at `pos`.
    public static func nearest(_ pos: Double, count n: Int, loop: Bool) -> Int {
        guard n > 0 else { return 0 }
        let r = Int(roundHalfUp(pos))
        return loop ? wrap(r, n) : min(max(r, 0), n - 1)
    }

    /// Past the ends of a drum that doesn't loop, the position rubber-bands (at most 0.6 of an item).
    public static func clampSoft(_ pos: Double, count n: Int, loop: Bool) -> Double {
        if loop { return pos }
        let top = Double(max(n - 1, 0))
        if pos < 0 { return -min(0.6, -pos * 0.35) }
        if pos > top { return top + min(0.6, (pos - top) * 0.35) }
        return pos
    }

    /// Where a fling with `v` items per second lands: a detent, clamped to the ends unless the drum loops.
    public static func flingTarget(pos: Double, velocity v: Double, count n: Int, loop: Bool, tau: Double = 0.325) -> Double {
        let t = roundHalfUp(pos + v * tau)
        if loop { return t }
        return min(max(t, 0), Double(max(n - 1, 0)))
    }

    /// The fling's exponential decay from `start` towards `target` after `t` seconds.
    public static func decay(start: Double, target: Double, elapsed t: Double, tau: Double = 0.325) -> Double {
        target - (target - start) * exp(-t / tau)
    }

    /// One step of the critically damped spring that settles a drum on its detent (`x` is the offset from it).
    public static func springStep(x: Double, v: Double, dt: Double, k: Double = 170) -> (x: Double, v: Double) {
        let h = min(dt, 0.032)
        let c = 2 * k.squareRoot()
        let a = -k * x - c * v
        let nv = v + a * h
        return (x: x + nv * h, v: nv)
    }

    /// The spring has come to rest.
    public static func settled(x: Double, v: Double) -> Bool { abs(x) < 0.002 && abs(v) < 0.01 }

    /// How an item `d` detents from the band is drawn on the drum.
    public struct ItemLook: Equatable, Sendable {
        public var visible: Bool
        /// Offset from the band's centre, in points (down is positive).
        public var y: Double
        public var scale: Double
        public var opacity: Double
        /// Tilt about the horizontal axis.
        public var rotationDegrees: Double
        public var brightness: Double

        public init(visible: Bool, y: Double, scale: Double, opacity: Double, rotationDegrees: Double, brightness: Double) {
            self.visible = visible
            self.y = y
            self.scale = scale
            self.opacity = opacity
            self.rotationDegrees = rotationDegrees
            self.brightness = brightness
        }
    }

    /// Items shrink, dim and tilt away from the band; neighbours sit one item height apart.
    public static func look(delta d: Double, itemHeight h: Double, selected: Bool) -> ItemLook {
        let deg = d * stepDegrees
        let rad = deg * .pi / 180
        let falloff = cos(rad)
        let r = h / (2 * sin(stepDegrees * .pi / 360))
        return ItemLook(visible: abs(deg) <= 95,
                        y: r * sin(rad),
                        scale: 0.78 + 0.22 * falloff,
                        opacity: pow(max(0, falloff), 2.2),
                        rotationDegrees: -deg,
                        brightness: selected ? 1 : 0.55 + 0.35 * falloff)
    }
}

// MARK: Fitting the drums to a height (the cinematic Suite's rig panel)

public extension RigDrumMath {
    /// The drums' fixed chrome around their five rows, top to bottom: the step's padding (16), the rig line (20) and its
    /// spacing (18), the bag's top padding (14), the label (18), the gaps above and below the rows (10 + 10), the name and
    /// caption block (50), the bag's bottom padding (16) and the step's bottom padding (16).
    static let fitChrome = 188.0
    static let fitRows = 5.0
    /// Smallest row that still reads (a render, its name and the focal / aperture glyphs).
    static let minRow = 50.0

    /// The row height that fits all five rows in `height` without clipping: the width's row (84, or 112 from 720 pt
    /// wide) when there is room, else what fits (54 pt in a 684 pt window), never under `minRow`.
    static func fitRow(width: Double, height: Double) -> Double {
        let byWidth = width >= 720 ? 112.0 : 84.0
        let byHeight = ((height - fitChrome) / fitRows).rounded(.down)
        return max(minRow, min(byWidth, byHeight))
    }

    /// The height the drums take at a row height (the inverse, for checks).
    static func fitHeight(row: Double) -> Double { fitChrome + fitRows * row }
}

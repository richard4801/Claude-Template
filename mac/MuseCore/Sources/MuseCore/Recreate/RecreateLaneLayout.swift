import Foundation

/// The geometry of the Recipe's lanes under the reference player (owner test 2026-11-08: a 30 s reference with 7 shots
/// drew a huge selected tile and overlapping tiles). Pure maths, so every item sits strictly on its own time span and no
/// two items share any space: shot tiles, text items, transition labels and ruler labels.
public enum RecreateLaneLayout {
    /// A horizontal slot in a lane, in points from the lane's left edge.
    public struct Span: Hashable, Sendable {
        public var x: Double
        public var width: Double
        public var maxX: Double { x + width }
        public init(x: Double, width: Double) {
            self.x = x
            self.width = width
        }
    }

    /// Seconds to points along a lane `width` wide, for a reference `duration` long (clamped to the lane).
    public static func x(_ sec: Double, duration: Double, width: Double) -> Double {
        guard duration > 0, width > 0, sec.isFinite else { return 0 }
        return min(max(0, sec / duration), 1) * width
    }

    /// Shot tiles: each tile covers exactly its slot's time span (start / duration × width, length / duration × width),
    /// less `gap` between neighbours. A span that runs past the next slot's start is cut there, so tiles never overlap; a
    /// span narrower than the gap gets a zero-width tile rather than borrowing its neighbour's room.
    public static func tiles(_ spans: [(start: Double, end: Double)], duration: Double, width: Double, gap: Double = 2) -> [Span] {
        spans.indices.map { i in
            let x0 = x(spans[i].start, duration: duration, width: width)
            var x1 = x(spans[i].end, duration: duration, width: width)
            if i + 1 < spans.count {
                let next = x(spans[i + 1].start, duration: duration, width: width)
                if next > x0 { x1 = min(x1, next) }
            }
            let w = max(0, x1 - x0 - gap)
            return Span(x: x0 + (w > 0 ? gap / 2 : 0), width: w)
        }
    }

    /// Text items: placed at their start, as wide as their span, and at least `marker` wide when there is room before the
    /// next item, never past the next item's start or the lane's end. Items keep their input order in the result.
    public static func texts(_ spans: [(start: Double, end: Double)], duration: Double, width: Double, gap: Double = 2, marker: Double = 20) -> [Span] {
        let order = spans.indices.sorted { spans[$0].start < spans[$1].start || (spans[$0].start == spans[$1].start && $0 < $1) }
        var out = [Span](repeating: Span(x: 0, width: 0), count: spans.count)
        for (k, i) in order.enumerated() {
            let x0 = x(spans[i].start, duration: duration, width: width)
            let span = x(spans[i].end, duration: duration, width: width) - x0
            let next = k + 1 < order.count ? x(spans[order[k + 1]].start, duration: duration, width: width) : width
            let room = max(0, min(next, width) - x0 - gap)
            out[i] = Span(x: x0, width: max(0, min(max(span - gap, marker), room)))
        }
        return out
    }

    /// Point items (transitions): each gets the room centred on its moment, up to half the distance to each neighbour
    /// (the lane's edge counts in full), less `gap`, and at most `maxWidth`. The label goes in that room when it fits,
    /// else an icon, else nothing (the tooltip still names it).
    public static func points(_ secs: [Double], duration: Double, width: Double, gap: Double = 4, maxWidth: Double = 120) -> [Span] {
        let xs = secs.map { x($0, duration: duration, width: width) }
        let order = xs.indices.sorted { xs[$0] < xs[$1] || (xs[$0] == xs[$1] && $0 < $1) }
        var out = [Span](repeating: Span(x: 0, width: 0), count: xs.count)
        for (k, i) in order.enumerated() {
            let xi = xs[i]
            let left = k > 0 ? (xi - xs[order[k - 1]]) / 2 : xi
            let right = k + 1 < order.count ? (xs[order[k + 1]] - xi) / 2 : width - xi
            let w = max(0, min(2 * min(left, right) - gap, maxWidth))
            out[i] = Span(x: xi - w / 2, width: w)
        }
        return out
    }

    /// The ruler's label step: the first of 0.5, 1, 2, 5, 10, 15, 30 s, 1, 2, 5, 10 min whose labels sit at least `minGap`
    /// points apart.
    public static func rulerStep(duration: Double, width: Double, minGap: Double = 48) -> Double {
        let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        guard duration > 0, width > 0 else { return 1 }
        let pps = width / duration
        return steps.first { $0 * pps >= minGap } ?? (minGap / pps).rounded(.up)
    }

    /// The ruler's labelled seconds: every step from 0, keeping only labels that end inside the lane.
    public static func rulerMarks(duration: Double, width: Double, minGap: Double = 48, labelWidth: Double = 40) -> [Double] {
        let step = rulerStep(duration: duration, width: width, minGap: minGap)
        var out: [Double] = []
        var k = 0
        while true {
            let s = Double(k) * step
            if s > duration + 1e-9 || x(s, duration: duration, width: width) + labelWidth > width { break }
            out.append(s)
            k += 1
        }
        return out
    }

    /// A ruler label: "0:05" on whole-second steps, "0:00.5" on half seconds.
    public static func rulerLabel(_ sec: Double, step: Double) -> String {
        let s = max(0, sec)
        if step < 1 { return RecreateText.time(s) }
        let whole = Int(s.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// The largest overlap in points between any two spans (0 when none touch), for the fit check.
    public static func worstOverlap(_ spans: [Span]) -> Double {
        let sorted = spans.filter { $0.width > 0 }.sorted { $0.x < $1.x }
        var worst = 0.0
        for i in sorted.indices {
            for j in sorted.indices where j > i {
                if sorted[j].x >= sorted[i].maxX { break }
                worst = max(worst, min(sorted[i].maxX, sorted[j].maxX) - sorted[j].x)
            }
        }
        return worst
    }
}

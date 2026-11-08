import Foundation

/// The recipe built into an edit project, the way workstream 1's server does it (server/api/src/recreate/assemble.ts,
/// plans/api.md "Applying a recipe"): main-track clips cut to the reference's times, transitions, speed ramps, camera moves
/// as x / y / scale keyframes, the text on a text track, and the nearest Look. The app uses it where there is no server
/// edit session to read the built edit from: demo mode, so Compare still plays a real built edit on the demo take.
/// With a server, Compare plays the edit session's own project (what `apply` wrote), not this.
public enum RecreateAssembly {
    /// A take that fills a slot: its id and facts.
    public struct TakeInfo: Hashable, Sendable {
        public var id: String
        public var durationSec: Double
        public var width: Int
        public var height: Int
        public var hasAudio: Bool
        public init(id: String, durationSec: Double, width: Int, height: Int, hasAudio: Bool = true) {
            self.id = id; self.durationSec = durationSec; self.width = width; self.height = height; self.hasAudio = hasAudio
        }
    }

    public struct Result: Hashable, Sendable {
        public var project: EditV2.Project
        /// Slots without a take, left out.
        public var missing: [String]
        public var durationSec: Double
    }

    static let canvases: [String: (Int, Int)] = ["9:16": (1080, 1920), "16:9": (1920, 1080), "1:1": (1080, 1080), "4:5": (1080, 1350),
                                                 "3:4": (1080, 1440), "4:3": (1440, 1080), "21:9": (2520, 1080)]

    static func r4(_ x: Double) -> Double { (x * 10000).rounded() / 10000 }
    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }

    /// The editor transition for a recipe transition: crossfade → fade, fade → black, flash → white, whip, zoom, glitch;
    /// cuts and unknown ones get none.
    public static func transition(_ t: Recipe.Transition?) -> EditV2.Transition? {
        guard let t else { return nil }
        let kind: EditV2.TransitionKind?
        switch t.kind {
        case "crossfade": kind = .fade
        case "fade": kind = .black
        case "flash": kind = .white
        case "whip": kind = .whip
        case "zoom": kind = .zoom
        case "glitch": kind = .glitch
        default: kind = nil
        }
        guard let kind else { return nil }
        let d = (t.durationSec ?? 0) > 0 ? t.durationSec! : 0.2
        return EditV2.Transition(kind: kind, durationSec: r4(clamp(d, EditV2.minTransitionSec, EditV2.maxTransitionSec)))
    }

    /// The source range that plays for exactly `len` seconds (with the speed curve when there is one).
    static func range(_ inSec: Double, _ len: Double, _ available: Double, _ curve: EditV2.SpeedCurve?) -> (outSec: Double, speed: Double, curve: EditV2.SpeedCurve?) {
        func plain() -> (Double, Double, EditV2.SpeedCurve?) {
            if available - inSec >= len { return (r4(inSec + len), 1, nil) }
            // A take shorter than its slot plays slower to fill it.
            let speed = clamp((available - inSec) / len, EditV2.minSpeed, 1)
            return (r4(inSec + len * speed), r4(speed), nil)
        }
        guard let curve else { return plain() }
        func length(_ src: Double) -> Double {
            EditV2.clipLength(EditV2.VideoClip(id: "x", asset: "a", inSec: inSec, outSec: inSec + src, speedCurve: curve))
        }
        var lo = 0.05, hi = available - inSec
        guard hi > lo, length(hi) >= len else { return plain() }   // too short for the ramp
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if length(mid) < len { lo = mid } else { hi = mid }
        }
        return (r4(inSec + hi), 1, curve)
    }

    /// The project for `recipe` with `takes[slotId]` in each slot. `startAtSlot` starts each clip at its slot's own time in
    /// the take (demo mode, where one take fills every slot) instead of at 0. `paletteIds`: the Looks this Mac has; the
    /// reference's Look is used when it is one of them and close enough (distance under 0.4), at 0.8.
    public static func project(_ recipe: Recipe, sourceTakeId: String, takes: [String: TakeInfo], paletteIds: Set<String> = [],
                               startAtSlot: Bool = false) -> Result {
        let (cw, ch) = canvases[recipe.source?.aspect ?? "9:16"] ?? (1080, 1920)
        let fps = clamp((recipe.source?.fps ?? 30).rounded(), 24, 60)
        var assets: [EditV2.Asset] = []
        func asset(_ t: TakeInfo) -> String {
            if let a = assets.first(where: { $0.take == t.id }) { return a.id }
            let a = EditV2.Asset(id: "a\(assets.count + 1)", kind: .video, take: t.id, durationSec: t.durationSec, width: t.width, height: t.height, hasAudio: t.hasAudio)
            assets.append(a)
            return a.id
        }
        let used = recipe.slots.filter { takes[$0.id] != nil }
        let missing = recipe.slots.filter { takes[$0.id] == nil }.map(\.id)
        func into(_ slot: String, from prev: String?) -> Recipe.Transition? {
            recipe.transitions.first { $0.to == slot && $0.from == prev && $0.from != $0.to }
        }
        let lut: String? = {
            guard let look = recipe.grade?.look, (look.distance ?? 1) < 0.4, paletteIds.contains(look.id) else { return nil }
            return "palette:\(look.id)"
        }()

        var clips: [EditV2.Item] = []
        for (i, s) in used.enumerated() {
            let t = takes[s.id]!
            let tin = i > 0 ? transition(into(s.id, from: used[i - 1].id)) : nil
            let tnext = i + 1 < used.count ? transition(into(used[i + 1].id, from: s.id)) : nil
            let len = s.length + (tin.map { $0.durationSec / 2 } ?? 0) + (tnext.map { $0.durationSec / 2 } ?? 0)
            var curve: EditV2.SpeedCurve?
            if let sp = s.speed, let pts = sp.curve, pts.count >= 2, sp.ramp != nil, sp.ramp != "none", sp.ramp != "freeze" {
                var p = pts.map { [r4(clamp($0.t / max(s.length, 0.001), 0, 1)), r4(clamp($0.speed, 0.25, 4))] }
                p[0][0] = 0
                p[p.count - 1][0] = 1
                // Rising x (the editor's rule): a repeated x is nudged forward.
                for k in 1..<p.count where p[k][0] <= p[k - 1][0] { p[k][0] = min(1, p[k - 1][0] + 0.0001) }
                curve = EditV2.SpeedCurve(preset: .custom, points: p)
            }
            var start = 0.0
            if startAtSlot, t.durationSec > 0 { start = r4(min(max(0, s.startSec), max(0, t.durationSec - max(len, 0.5)))) }
            let r = range(start, len, t.durationSec, curve)
            var clip = EditV2.VideoClip(id: "c\(i + 1)", asset: asset(t), inSec: start, outSec: r.outSec, speed: r.speed,
                                        look: lut.map { EditV2.Look(lut: $0, strength: 0.8) }, transitionIn: tin, speedCurve: r.curve)
            // The reference's camera move, replayed by moving and scaling the clip (the frame stays covered).
            if let cam = s.camera, let keys = cam.keys, keys.count >= 2, cam.motion != "static", cam.motion != "mixed", let last = keys.last {
                let off = tin.map { $0.durationSec / 2 } ?? 0
                let X = last.x ?? 0, Y = last.y ?? 0
                let base = cam.motion == "shake" ? 1.08 : clamp(1 + max(abs(X), abs(Y)), 1, 2)
                let step = max(1, Int((Double(keys.count) / 40).rounded(.up)))
                let pick = keys.enumerated().filter { $0.offset % step == 0 || $0.offset == keys.count - 1 }.map(\.element)
                func kf(_ f: (Recipe.Slot.CameraKey) -> Double) -> [EditV2.Keyframe] {
                    pick.map { EditV2.Keyframe(t: r4(off + $0.t), v: r4(f($0)), ease: .linear) }
                }
                clip.keyframes = EditV2.Keyframes(x: kf { 0.5 + ($0.x ?? 0) - X / 2 }, y: kf { 0.5 + ($0.y ?? 0) - Y / 2 },
                                                  scale: kf { clamp(base * ($0.scale ?? 1), 0.05, 10) })
            }
            clips.append(.video(clip))
        }

        var tracks = [EditV2.Track(id: "main", kind: .main, items: clips)]
        if !recipe.text.isEmpty {
            let first = used.first?.startSec ?? 0
            let items: [EditV2.Item] = recipe.text.enumerated().map { i, x in
                let box = x.box ?? Recipe.TextItem.Box(x: 0.1, y: 0.7, w: 0.8, h: 0.07)
                let color = x.color ?? "#FFFFFF"
                let words = x.words?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let style = EditV2.TextStyle(font: EditV2.Font(rawValue: x.fontId ?? "sans") ?? .sans, weight: 900,
                                             sizePct: r4(clamp(x.sizeFrac ?? 0.045, 0.015, 0.25)), color: color, align: .center,
                                             maxWidthPct: r4(clamp(box.w + 0.05, 0.1, 1)),
                                             stroke: color.uppercased() == "#FFFFFF" ? EditV2.Stroke(color: "#000000", widthPct: 0.08) : nil)
                return .text(EditV2.TextItem(id: "x\(i + 1)", startSec: r4(max(0, x.startSec - first)), durationSec: r4(max(EditV2.minItemSec, x.endSec - x.startSec)),
                                             text: words.isEmpty ? "Text" : words, style: style,
                                             transform: EditV2.Transform(x: r4(box.x + box.w / 2), y: r4(box.y + box.h / 2))))
            }
            tracks.append(EditV2.Track(id: "text", kind: .text, items: items))
        }
        let project = EditV2.Project(sourceTakeId: sourceTakeId, canvas: EditV2.Canvas(width: cw, height: ch, fps: fps, background: "#000000"),
                                     assets: assets, tracks: tracks)
        return Result(project: project, missing: missing, durationSec: EditV2.durationSec(project))
    }
}

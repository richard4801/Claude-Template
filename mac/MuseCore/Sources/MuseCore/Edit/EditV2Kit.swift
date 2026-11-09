import Foundation

// Style kits (plans/edit-parity.md, M "Save your own edit as a template / style kit"; Swift port of server/api/src/editor/
// kit.ts, WS8 81fa2f3): an edit's look, colour, transition, caption and text styles and canvas background, saved by name
// and applied to another edit. Matched against functions.json → kits (kitOf, applyKit, validateKit).

extension EditV2 {
    public struct StyleKit: Codable, Hashable, Sendable {
        public var version: Int
        public var look: Look?
        public var filter: FilterRef?
        public var adjust: Adjust?
        public var transition: Transition?
        public var captionStyle: CaptionStyle?
        public var textStyle: TextStyle?
        public var background: String?
        public var fill: CanvasFill?

        public init(version: Int = 1, look: Look? = nil, filter: FilterRef? = nil, adjust: Adjust? = nil, transition: Transition? = nil,
                    captionStyle: CaptionStyle? = nil, textStyle: TextStyle? = nil, background: String? = nil, fill: CanvasFill? = nil) {
            self.version = version; self.look = look; self.filter = filter; self.adjust = adjust; self.transition = transition
            self.captionStyle = captionStyle; self.textStyle = textStyle; self.background = background; self.fill = fill
        }

        /// The parts it carries, in words ("Look, colour, transition, captions"), as Android shows them.
        public var partsLabel: String {
            var out: [String] = []
            if look != nil { out.append("look") }
            if filter != nil || adjust != nil { out.append("colour") }
            if transition != nil { out.append("transition") }
            if captionStyle != nil { out.append("captions") }
            if textStyle != nil { out.append("text") }
            if background != nil || fill != nil { out.append("background") }
            guard let first = out.first else { return "Nothing yet" }
            return ([first.prefix(1).uppercased() + first.dropFirst()] + out.dropFirst()).joined(separator: ", ")
        }
    }

    public static let kitKeys: [String] = ["version", "look", "filter", "adjust", "transition", "captionStyle", "textStyle", "background", "fill"]

    static func portableLut(_ lut: String?) -> Bool { lut.map { $0.hasPrefix("pack:") || $0.hasPrefix("palette:") } ?? true }

    /// The style of `p` as a kit: the first main clip's look (a LUT only when it's a pack or palette look), filter and adjust
    /// (no keyframes); the first transition; the caption style; the first text item's style; the canvas background and fill.
    public static func kitOf(_ p: Project) -> StyleKit {
        let main = p.mainClips
        var kit = StyleKit()
        if let c = main.first {
            if var look = c.look {
                if !portableLut(look.lut) { look.lut = nil; look.strength = nil }
                if look != Look() { kit.look = look }
            }
            kit.filter = c.filter
            if let a = c.adjust, a != Adjust() { kit.adjust = a }
        }
        kit.transition = main.first { $0.transitionIn != nil }?.transitionIn
        kit.captionStyle = p.tracks.first { $0.kind == .caption && $0.caption != nil }?.caption?.style
        // An own font's asset id belongs to its edit: the kit carries only the fallback family (WS8 6ccd9aa).
        if let t = p.tracks.first(where: { $0.kind == .text && !$0.items.isEmpty }), case .text(let tx) = t.items[0] { kit.textStyle = tx.style.with(fontAsset: nil) }
        kit.background = p.canvas.background
        kit.fill = p.canvas.fill
        return kit
    }

    /// `kit` applied to `p`: every main clip takes its look, filter and adjust (keyframes stay); every cut its transition, at
    /// most half of each clip beside it (cuts too short for 0.1 s stay as they were); the caption tracks and every text
    /// item its styles; the canvas its background and fill. Parts the kit leaves out stay as they are.
    public static func applyKit(_ p: Project, _ kit: StyleKit) -> Project {
        var q = p
        for ti in q.tracks.indices where q.tracks[ti].kind == .main {
            var lens: [Double] = []
            for ii in q.tracks[ti].items.indices {
                guard case .video(var c) = q.tracks[ti].items[ii] else { lens.append(0); continue }
                if let l = kit.look { c.look = l }
                if let f = kit.filter { c.filter = f }
                if let a = kit.adjust { c.adjust = a }
                lens.append(clipLength(c))
                if let tr = kit.transition, ii >= 1 {
                    let d = (min(tr.durationSec, lens[ii] / 2, lens[ii - 1] / 2) * 1000).rounded(.down) / 1000
                    if d >= minTransitionSec { c.transitionIn = Transition(kind: tr.kind, durationSec: d) }
                }
                q.tracks[ti].items[ii] = .video(c)
            }
        }
        for ti in q.tracks.indices {
            if q.tracks[ti].kind == .caption, q.tracks[ti].caption != nil, let cs = kit.captionStyle { q.tracks[ti].caption?.style = cs }
            if q.tracks[ti].kind == .text, let ts = kit.textStyle {
                for ii in q.tracks[ti].items.indices { if case .text(var tx) = q.tracks[ti].items[ii] { tx.style = ts; q.tracks[ti].items[ii] = .text(tx) } }
            }
        }
        if let b = kit.background { q.canvas.background = b }
        if let f = kit.fill { q.canvas.fill = f }
        return q
    }

    /// A small valid edit every part of a kit lands on (kit.ts PROBE).
    static let kitProbe: Project = {
        let text = TextItem(id: "t1", startSec: 0, durationSec: 2, text: "Kit", style: hooks[0].style)
        return Project(sourceTakeId: "kit", canvas: Canvas(width: 1080, height: 1920, fps: 30),
                       assets: [Asset(id: "v", kind: .video, take: "kit", durationSec: 10, width: 1080, height: 1920, hasAudio: true)],
                       tracks: [
                           Track(id: "main", kind: .main, items: [.video(VideoClip(id: "c1", asset: "v", inSec: 0, outSec: 4)),
                                                                  .video(VideoClip(id: "c2", asset: "v", inSec: 4, outSec: 8))]),
                           Track(id: "txt", kind: .text, items: [.text(text)]),
                           Track(id: "cap", kind: .caption, items: [],
                                 caption: CaptionTrack(asset: "v", words: [CaptionWord(text: "kit", startSec: 0, endSec: 0.5)], style: captionStyles[.pop]!)),
                       ])
    }()

    /// Where each probe path came from in the kit.
    private static let kitFieldMap: [(NSRegularExpression, String)] = [
        (#"^edits\.tracks\.0\.items\.\d+\.transitionIn"#, "kit.transition"),
        (#"^edits\.tracks\.0\.items\.\d+\.(look|filter|adjust)"#, "kit.$1"),
        (#"^edits\.tracks\.1\.items\.0\.style"#, "kit.textStyle"),
        (#"^edits\.tracks\.2\.caption\.style"#, "kit.captionStyle"),
        (#"^edits\.canvas\.(background|fill)"#, "kit.$1"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func kitField(_ probeField: String) -> String {
        let r = NSRange(probeField.startIndex..., in: probeField)
        for (re, tpl) in kitFieldMap {
            guard let m = re.firstMatch(in: probeField, range: r) else { continue }
            let replaced = re.replacementString(for: m, in: probeField, offset: 0, template: tpl)
            return replaced + String(probeField[Range(m.range, in: probeField)!.upperBound...])
        }
        return "kit"
    }

    /// Checks a kit as JSON (throws an EditProblem with a `kit.…` field, first failure wins, as kit.ts validateKit): an
    /// object of the known keys at version 1, a transition of a known kind at 0.1–2 s, a pack or palette look, and every
    /// other part valid where it lands on a small probe edit.
    public static func validateKit(_ json: JSONValue, presets: [FilterPreset] = filters, lookIds: Set<String> = Set(lookPackIds),
                                   paletteIds: Set<String> = []) throws -> StyleKit {
        guard case .object(let k) = json else { throw EditProblem("kit", "must be an object") }
        for key in k.keys.sorted() where !kitKeys.contains(key) { throw EditProblem("kit.\(key)", "is not part of a style kit") }
        guard case .number(let v)? = k["version"], v == 1 else { throw EditProblem("kit.version", "must be 1") }
        if let tr = k["transition"] {
            guard case .object(let t) = tr, case .string(let kind)? = t["kind"], TransitionKind(rawValue: kind) != nil else {
                throw EditProblem("kit.transition.kind", "unknown transition")
            }
            guard case .number(let d)? = t["durationSec"], d >= minTransitionSec, d <= maxTransitionSec else {
                throw EditProblem("kit.transition.durationSec", "must be a number from \(minTransitionSec) to \(maxTransitionSec)")
            }
        }
        if case .object(let l)? = k["look"] {
            let lut: String?
            if case .string(let s)? = l["lut"] { lut = s } else { lut = nil }
            if !portableLut(lut) { throw EditProblem("kit.look.lut", "a kit can only carry a pack or palette look") }
        }
        let kit: StyleKit
        do {
            kit = try JSONPatch.decode(StyleKit.self, json)
        } catch let e as DecodingError {
            // A part that doesn't even decode (a fill of "mirror"): its own path in the kit.
            let path: [CodingKey]
            switch e {
            case .dataCorrupted(let c), .keyNotFound(_, let c), .typeMismatch(_, let c), .valueNotFound(_, let c): path = c.codingPath
            @unknown default: path = []
            }
            let f = path.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
            throw EditProblem(f.isEmpty ? "kit" : "kit.\(f)", "is not valid")
        }
        if let p = problem(applyKit(kitProbe, kit), presets: presets, lookIds: lookIds, paletteIds: paletteIds) {
            throw EditProblem(kitField(p.field), p.message)
        }
        return kit
    }
}

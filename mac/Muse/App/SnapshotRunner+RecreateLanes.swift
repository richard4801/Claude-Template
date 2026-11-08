import AppKit
import CoreGraphics
import MuseCore

// Review mode (SnapshotRunner.recreateShots): the Recipe's lanes on a long reference (owner test 2026-11-08: a 29.7 s
// reference with 7 shots drew the selected shot's tile huge, over the player's transport and the other lanes, with tiles
// overlapping and the text lane cut to "Wor…").
extension SnapshotRunner {
    /// The lanes reference: 29.7 s, 7 uneven shots (1.2, 2.5, 6.0, 0.8, 9.4, 3.1 and 6.7 s) with portrait stills, text items
    /// (some shorter than 0.6 s, one not read), transitions (two of them 0.1 s apart) and beats. Review mode only: it is
    /// never sent to the server.
    static func lanesReference() -> (RecreateReference, RecreateFill)? {
        let lengths: [Double] = [1.2, 2.5, 6.0, 0.8, 9.4, 3.1, 6.7]
        let duration = lengths.reduce(0, +)
        let stills = FileManager.default.temporaryDirectory.appendingPathComponent("MUSE-recreate-lanes", isDirectory: true)
        try? FileManager.default.createDirectory(at: stills, withIntermediateDirectories: true)
        var slots: [[String: Any]] = []
        var start = 0.0
        for (i, l) in lengths.enumerated() {
            let still = stills.appendingPathComponent("shot\(i + 1).png")
            writeStill(still, hue: Double(i) / Double(lengths.count))
            slots.append(["id": "l\(i + 1)", "index": i, "startSec": start, "endSec": start + l, "durationSec": l,
                          "keyframeSec": start + l / 2, "confidence": 0.9, "camera": ["motion": i % 2 == 0 ? "static" : "pan"],
                          "thumbUrl": still.absoluteString])
            start += l
        }
        func text(_ id: String, _ from: Double, _ to: Double, _ words: String?) -> [String: Any] {
            var t: [String: Any] = ["id": id, "startSec": from, "endSec": to, "box": ["x": 0.1, "y": 0.7, "w": 0.8, "h": 0.07]]
            if let words { t["words"] = words }
            return t
        }
        let texts = [text("x1", 0.2, 0.5, "WAIT"), text("x2", 1.3, 3.5, nil), text("x3", 3.9, 4.3, "for it"),
                     text("x4", 4.4, 4.9, "now"), text("x5", 10.6, 14.0, "Summer in the city"), text("x6", 20.0, 20.5, "go"),
                     text("x7", 24.0, 28.0, "See you there")]
        let cuts: [(Double, String)] = [(1.2, "cut"), (3.7, "whip"), (9.7, "cut"), (10.5, "flash"), (10.6, "glitch"),
                                        (19.9, "crossfade"), (23.0, "zoom")]
        let transitions = cuts.map { ["atSec": $0.0, "kind": $0.1, "durationSec": 0.1, "confidence": 0.8] as [String: Any] }
        let beats = stride(from: 0.5, to: duration, by: 0.5).map { $0 }
        let strong = stride(from: 2.0, to: duration, by: 2.0).map { $0 }
        let recipe: [String: Any] = [
            "schema": "muse.recipe/1", "summary": "Seven shots, slow then fast, with words on the beat.", "tags": ["review"],
            "source": ["durationSec": duration, "width": 1080, "height": 1920, "fps": 30, "aspect": "9:16", "hasAudio": true] as [String: Any],
            "sound": ["bpm": 120.0, "beats": beats, "strong": strong, "confidence": 0.8] as [String: Any],
            "pacing": ["shots": lengths.count, "avgShotSec": duration / Double(lengths.count), "cutsPerMin": 60 * Double(lengths.count - 1) / duration] as [String: Any],
            "slots": slots, "transitions": transitions, "text": texts,
            "grade": ["swatches": ["#286521", "#8987ED", "#0BF802", "#E3CA8A", "#F8FA02"], "look": ["id": "teal_orange", "label": "Teal & orange"]] as [String: Any],
            "gaps": [] as [Any],
        ]
        let ref: [String: Any] = ["id": "rx_lanes", "name": "Lanes check", "state": "ready", "progress": 100, "phase": "done",
                                  "durationSec": duration, "recipe": recipe]
        let states: [(String, String?)] = [("matched", nil), ("to_generate", nil), ("to_generate", "swap"), ("matched", nil),
                                           ("to_generate", nil), ("matched", nil), ("to_generate", "swap")]
        var fillSlots: [[String: Any]] = []
        for (i, s) in states.enumerated() {
            var f: [String: Any] = ["slotId": "l\(i + 1)", "state": s.0]
            if let m = s.1 { f["method"] = m }
            fillSlots.append(f)
        }
        let fill: [String: Any] = ["referenceId": "rx_lanes", "slots": fillSlots]
        guard let refData = try? JSONSerialization.data(withJSONObject: ref),
              let fillData = try? JSONSerialization.data(withJSONObject: fill),
              let r = try? JSONDecoder().decode(RecreateReference.self, from: refData),
              let f = try? JSONDecoder().decode(RecreateFill.self, from: fillData),
              r.recipe?.slots.count == lengths.count, r.recipe?.text.count == texts.count else { return nil }
        return (r, f)
    }

    /// A 9:16 still: a coloured field with a light band, so a tile that draws it too big is plain to see.
    private static func writeStill(_ url: URL, hue: Double) {
        let w = 180, h = 320
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let base = NSColor(calibratedHue: CGFloat(hue), saturation: 0.35, brightness: 0.45, alpha: 1).cgColor
        let band = NSColor(calibratedHue: CGFloat(hue), saturation: 0.2, brightness: 0.8, alpha: 1).cgColor
        ctx.setFillColor(base)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(band)
        ctx.fill(CGRect(x: 0, y: h / 2 - 20, width: w, height: 40))
        guard let img = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The Recipe with the lanes reference at 1280 × 800 and 1470 × 800, a middle shot selected
    /// (`mac_c_recreate_lanes_<w>.png`). Fit lines: every shot tile drawn, no two overlapping by more than 0.5 pt, all
    /// inside the Shots lane, and the selected tile the same size as when it isn't selected; the same for the text items
    /// and the ruler labels. CUT fails CI.
    static func recreateLanesShots(_ store: AppStore, dir: URL, window w: NSWindow) async -> [String] {
        guard let made = lanesReference() else { return ["CUT recreate_lanes the test reference didn't decode"] }
        let (ref, fill) = made
        var lines: [String] = []
        let shots = ref.recipe?.slots.count ?? 0
        let middle = 3
        let top = w.frame.maxY
        let left = w.frame.minX
        store.themeID = .c
        store.openEdit(takeId: nil)
        store.openRecreate()
        try? await Task.sleep(for: .seconds(1))
        store.recreate.clearReference()
        store.recreate.reference = ref
        store.recreate.fill = fill
        for width in [1280, 1470] {
            NSLog("[snapshot] recreate lanes %d", width)
            w.setFrame(NSRect(x: left, y: top - 800, width: CGFloat(width), height: 800), display: true)
            store.selectRecreateSlot(middle)
            try? await Task.sleep(for: .seconds(1.5))
            store.toast = nil
            w.contentView?.layoutSubtreeIfNeeded()
            let label = "recreate_lanes_\(width) \(width)x800 c"
            let selectedFrame = state.recreateFrames["laneShot\(middle)"]
            lines.append(contentsOf: laneLines(label, prefix: "laneShot", lane: "laneShots", what: "shot tiles", expected: shots))
            lines.append(contentsOf: laneLines(label, prefix: "laneText", lane: "laneText", what: "text items", expected: nil))
            lines.append(contentsOf: laneLines(label, prefix: "rulerLabel", lane: "laneRuler", what: "ruler labels", expected: nil, inside: false))
            capture(dir.appendingPathComponent("mac_c_recreate_lanes_\(width).png"))
            // The same tile unselected: selection changes only the border, never the size.
            store.selectRecreateSlot(0)
            try? await Task.sleep(for: .seconds(0.8))
            w.contentView?.layoutSubtreeIfNeeded()
            let plainFrame = state.recreateFrames["laneShot\(middle)"]
            if let s = selectedFrame, let p = plainFrame {
                let same = abs(s.width - p.width) <= 0.5 && abs(s.height - p.height) <= 0.5 && abs(s.minX - p.minX) <= 0.5 && abs(s.minY - p.minY) <= 0.5
                lines.append("\(same ? "FITS" : "CUT") \(label) selected shot \(middle + 1) \(Int(s.width))x\(Int(s.height)) at \(Int(s.minX)),\(Int(s.minY)), unselected \(Int(p.width))x\(Int(p.height)) at \(Int(p.minX)),\(Int(p.minY))")
            } else {
                lines.append("CUT \(label) selected shot \(middle + 1) not drawn")
            }
            // The selected tile stays clear of the player's transport above the lanes.
            if let s = selectedFrame, let lane = state.recreateFrames["laneShots"], let ruler = state.recreateFrames["laneRuler"] {
                let clear = s.minY >= lane.minY - 0.5 && s.minY >= ruler.maxY - 0.5
                lines.append("\(clear ? "FITS" : "CUT") \(label) selected shot clear of the ruler and the transport (top \(Int(s.minY)), lanes start \(Int(ruler.minY)))")
            }
        }
        store.closeRecreate()
        try? await Task.sleep(for: .seconds(0.5))
        return lines
    }

    /// One lane's frames (window space): how many are drawn, the worst overlap between any two, and whether all sit inside
    /// the lane's own frame.
    private static func laneLines(_ label: String, prefix: String, lane: String, what: String, expected: Int?, inside: Bool = true) -> [String] {
        let frames = state.recreateFrames.filter { $0.key.hasPrefix(prefix) && Int($0.key.dropFirst(prefix.count)) != nil }
            .sorted { $0.value.minX < $1.value.minX }.map(\.value)
        guard let laneFrame = state.recreateFrames[lane] else { return ["CUT \(label) \(what) lane not drawn"] }
        var out: [String] = []
        if let expected, frames.count != expected {
            out.append("CUT \(label) \(what) \(frames.count) of \(expected) drawn")
        }
        if frames.isEmpty { return out + ["CUT \(label) \(what) none drawn"] }
        let worst = RecreateLaneLayout.worstOverlap(frames.map { RecreateLaneLayout.Span(x: Double($0.minX), width: Double($0.width)) })
        out.append("\(worst <= 0.5 ? "FITS" : "CUT") \(label) \(what) \(frames.count) drawn, worst overlap \(String(format: "%.1f", worst)) pt")
        if inside {
            let outside = frames.filter {
                $0.minX < laneFrame.minX - 0.5 || $0.maxX > laneFrame.maxX + 0.5 || $0.minY < laneFrame.minY - 0.5 || $0.maxY > laneFrame.maxY + 0.5
            }
            out.append("\(outside.isEmpty ? "FITS" : "CUT") \(label) \(what) inside the lane \(Int(laneFrame.width))x\(Int(laneFrame.height))\(outside.isEmpty ? "" : ", \(outside.count) outside")")
        }
        if prefix == "laneShot" {
            let tall = frames.filter { $0.height > laneFrame.height + 0.5 }
            out.append("\(tall.isEmpty ? "FITS" : "CUT") \(label) \(what) no taller than the lane (\(Int(frames.map(\.height).max() ?? 0)) of \(Int(laneFrame.height)) pt)")
        }
        return out
    }
}

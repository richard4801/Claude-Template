import AppKit
import AVFoundation
import ImageIO
import MuseCore

/// Edit operations check (Mac CI, Mac Edit audit 2026-11-08, plans/mac-edit-audit.md). The click-through proves no control
/// crashes; this proves they WORK: each operation runs through the real editor session (the same call its control makes),
/// then the project is checked, and the live preview's frame at a known time is probed (the preview renders through the same
/// engine as the export). Then a short project is exported for real and the file is checked: length, size, frames, and sound
/// (level, volume above 0 dB, mute). Writes `edit-ops-check.txt`: one `OK` or `FAIL` line per check, `ALL DONE` at the end;
/// CI fails on any FAIL or a missing ALL DONE.
extension SnapshotRunner {
    static func editOpsCheck(_ store: AppStore, dir: URL) async {
        let log = OpsLog(dir.appendingPathComponent("edit-ops-check.txt"))
        let note = log.note
        let media = FileManager.default.temporaryDirectory.appendingPathComponent("MUSE-edit-ops", isDirectory: true)
        try? FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let red = media.appendingPathComponent("red.mp4"), blue = media.appendingPathComponent("blue.mp4")
        do {
            // A red 4 s take with a steady tone (amplitude 0.2: room for +6 dB) and a blue 3 s take without sound.
            try await makeSolidVideo(red, seconds: 4, rgb: (220, 30, 30), tone: 0.2)
            try await makeSolidVideo(blue, seconds: 3, rgb: (30, 40, 220), tone: nil)
            note("MADE test videos")
        } catch {
            note("FAIL making the test videos: \(error.localizedDescription)")
            note("ALL DONE")
            return
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let raw: [[String: Any]] = [
            ["id": "ops_red", "kind": "take", "title": "Red", "videoUrl": red.absoluteString, "durationSec": 4, "width": 360, "height": 640, "fps": 30, "createdAt": now],
            ["id": "ops_blue", "kind": "take", "title": "Blue", "videoUrl": blue.absoluteString, "durationSec": 3, "width": 360, "height": 640, "fps": 30, "createdAt": now - 1],
        ]
        let made: [Take] = raw.compactMap { r in (try? JSONSerialization.data(withJSONObject: r)).flatMap { try? JSONDecoder().decode(Take.self, from: $0) } }
        guard made.count == 2 else { note("FAIL decoding the test takes"); note("ALL DONE"); return }
        store.takes.removeAll { $0.id.hasPrefix("ops_") }
        store.takes.insert(contentsOf: made, at: 0)
        await (store.api as? FakeMuseAPI)?.adoptTakes(made)
        defer { store.takes.removeAll { $0.id.hasPrefix("ops_") } }

        guard let s = store.makeEditSuiteSession(takeId: "ops_red") else { note("FAIL no editor session"); note("ALL DONE"); return }
        await s.load()
        guard s.isReady else { note("FAIL the edit didn't open (\(s.phase))"); s.close(); note("ALL DONE"); return }
        await operations(s, blue: made[1], log: log)
        await exportCheck(s, media: media, log: log)
        await formatsCheck(s, media: media, log: log)
        s.close()
        note("ALL DONE")
    }

    // MARK: Operations on the live session, with preview probes

    /// Waits until the preview shows the current project, then reads its frame at `t` (timeline seconds) at (x, y).
    @MainActor
    static func previewPixel(_ s: EditSuiteSession, at t: Double, _ x: Double = 0.5, _ y: Double = 0.5) async -> (r: Int, g: Int, b: Int)? {
        for _ in 0..<80 where !s.previewIsCurrent { try? await Task.sleep(for: .milliseconds(100)) }
        guard s.previewIsCurrent, let item = s.player.currentItem else {
            lastProbeError = "preview not rebuilt (\(s.lastError ?? "no error"))"
            return nil
        }
        let gen = AVAssetImageGenerator(asset: item.asset)
        gen.videoComposition = item.videoComposition
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        do {
            let cg = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
            lastProbeError = nil
            return pixel(cg, x, y)
        } catch {
            let tracks = (try? await item.asset.loadTracks(withMediaType: .video).count) ?? -1
            lastProbeError = "frame grab failed: \(error.localizedDescription) (\(tracks) video tracks)"
            return nil
        }
    }

    /// The preview's frame size (the canvas), or nil.
    @MainActor
    static func previewSize(_ s: EditSuiteSession) async -> CGSize? {
        for _ in 0..<80 where !s.previewIsCurrent { try? await Task.sleep(for: .milliseconds(100)) }
        return s.player.currentItem?.videoComposition?.renderSize
    }

    static func isRed(_ p: (r: Int, g: Int, b: Int)?) -> Bool { p.map { $0.r > 150 && $0.g < 90 && $0.b < 90 } ?? false }
    static func isBlue(_ p: (r: Int, g: Int, b: Int)?) -> Bool { p.map { $0.b > 150 && $0.r < 90 } ?? false }
    static func isBlack(_ p: (r: Int, g: Int, b: Int)?) -> Bool { p.map { $0.r < 25 && $0.g < 25 && $0.b < 25 } ?? false }
    static func describe(_ p: (r: Int, g: Int, b: Int)?) -> String { p.map { "rgb(\($0.r), \($0.g), \($0.b))" } ?? "no frame: \(lastProbeError ?? "?")" }
    /// Why the last preview probe got no frame.
    nonisolated(unsafe) static var lastProbeError: String?

    @MainActor
    static func operations(_ s: EditSuiteSession, blue: Take, log: OpsLog) async {
        typealias E = EditV2
        func step(_ name: String) { log.note("STEP \(name)") }
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { log.check(name, ok, detail) }
        let base = s.project

        step("preview of the untouched take")
        let p0 = await previewPixel(s, at: 1)
        check("preview shows the take", isRed(p0), describe(p0))
        check("duration is the take's", abs(s.duration - 4) < 0.05, "\(s.duration)")

        step("Adjust · Exposure −100")
        s.edit { $0.changeVisual { v in var a = v.adjust ?? E.Adjust(); a.exposure = -1; v.adjust = a } }
        check("project: exposure on the clip", s.project.mainClips.first?.adjust?.exposure == -1)
        let p1 = await previewPixel(s, at: 1)
        check("preview darker", (p1?.r ?? 255) < (p0?.r ?? 0) - 40, "\(describe(p0)) → \(describe(p1))")
        s.undo()

        step("Transform · Opacity 0")
        s.edit { $0.setVisualValue(.opacity, 0) }
        check("project: opacity 0", s.project.mainClips.first?.opacity == 0)
        let q1 = await previewPixel(s, at: 1)
        check("preview shows the black canvas", isBlack(q1), describe(q1))
        s.undo()

        step("Transform · Scale 50 %")
        s.edit { $0.setVisualValue(.scale, 0.5) }
        check("project: scale 0.5", s.project.mainClips.first?.transform?.scale == 0.5)
        let corner = await previewPixel(s, at: 1, 0.05, 0.05), centre = await previewPixel(s, at: 1)
        check("preview: canvas at the corner, picture in the middle", isBlack(corner) && isRed(centre), "\(describe(corner)) / \(describe(centre))")
        s.undo()

        step("Crop · Left 45 %")
        s.edit { $0.setCrop(.left, 0.45) }
        check("project: crop left 0.45", s.project.mainClips.first?.crop?.left == 0.45)
        let q2 = await previewPixel(s, at: 1, 0.5, 0.5)
        check("preview still fills with the picture (cover)", isRed(q2), describe(q2))
        s.undo()

        step("Keyframes · opacity 0 → 1")
        s.seek(0.1)
        s.edit { $0.addKeyframe(.opacity, value: 0) }
        s.seek(3)
        s.edit { $0.setVisualValue(.opacity, 1) }
        check("project: two opacity keys", s.project.mainClips.first?.keyframes?.opacity?.count == 2)
        let kEarly = await previewPixel(s, at: 0.2), kLate = await previewPixel(s, at: 3.2)
        check("preview fades in", (kEarly?.r ?? 255) + 60 < (kLate?.r ?? 0), "\(describe(kEarly)) → \(describe(kLate))")
        s.undo(); s.undo()

        step("Mask · circle, inverted")
        s.edit { $0.changeVisual { $0.mask = E.Mask(shape: .circle, width: 0.4, height: 0.4, feather: 0) } }
        let mIn = await previewPixel(s, at: 1), mOut = await previewPixel(s, at: 1, 0.03, 0.03)
        check("preview: masked to the circle", isRed(mIn) && isBlack(mOut), "\(describe(mIn)) / \(describe(mOut))")
        s.edit { $0.changeMask { $0.invert = true } }
        let q3 = await previewPixel(s, at: 1)
        check("preview: inverted", isBlack(q3), describe(q3))
        s.undo(); s.undo()

        step("Look · first bundled look")
        if let id = EditV2LookLibrary.shared.pack?.looks.first?.id {
            s.applyLook(id)
            check("project: look on the clip", s.project.mainClips.first?.look?.lut == "pack:\(id)")
            let pl = await previewPixel(s, at: 1)
            check("preview changes colour", pl.map { abs($0.r - (p0?.r ?? 0)) + abs($0.g - (p0?.g ?? 0)) + abs($0.b - (p0?.b ?? 0)) > 6 } ?? false,
                  "\(describe(p0)) → \(describe(pl))")
            s.undo()
        } else { check("look pack in the build", false) }

        step("Hide the video row")
        let mainId = s.project.mainTrack?.id ?? "main"
        s.edit { $0.toggleHidden(mainId) }
        check("project: main hidden", s.project.mainTrack?.hidden == true)
        let q4 = await previewPixel(s, at: 1)
        check("preview black", isBlack(q4), describe(q4))
        s.undo()

        step("Text · add at the playhead, white box")
        s.seek(0.5)
        s.edit { $0.addText("MUSE", style: E.TextStyle(font: .sans, weight: 900, sizePct: 0.12, color: "#FFFFFF", align: .center, maxWidthPct: 0.85, lineHeight: 1.15,
                                                       background: E.TextBackground(color: "#FFFFFF", opacity: 1, paddingPct: 0.6, radiusPct: 0))) }
        let tx = s.state.selectedItem?.textItem
        check("project: text item", tx?.text == "MUSE" && tx?.startSec == 0.5)
        let pt = await previewPixel(s, at: 1.5)
        check("preview shows the text box", pt.map { $0.r > 200 && $0.g > 200 && $0.b > 200 } ?? false, describe(pt))
        s.undo()

        step("Split at 2 s, delete the first part")
        s.seek(2)
        s.view { $0.selection = s.project.mainClips.first?.id }
        s.edit { $0.split() }
        check("project: two clips", s.project.mainClips.count == 2 && abs((s.project.mainClips.first?.outSec ?? 0) - 2) < 0.05)
        s.view { $0.selection = s.project.mainClips.first?.id }
        s.edit { $0.deleteSelected() }
        check("project: 2 s left, from 2 s of the source", abs(s.duration - 2) < 0.05 && abs((s.project.mainClips.first?.inSec ?? 0) - 2) < 0.05)
        _ = await previewPixel(s, at: 0.5)
        let splitLen = s.player.currentItem?.asset.duration.seconds ?? 0
        check("preview length follows", abs(splitLen - 2) < 0.15, "\(splitLen)")
        s.undo(); s.undo()

        step("Speed 2×")
        s.view { $0.selection = s.project.mainClips.first?.id }
        s.edit { $0.setSpeed(2) }
        check("project: half as long", abs(s.duration - 2) < 0.05)
        _ = await previewPixel(s, at: 0.5)
        let pd = s.player.currentItem?.asset.duration.seconds ?? 0
        check("preview half as long", abs(pd - 2) < 0.15, "\(pd)")
        s.undo()

        step("Trim the start (drag 1 s)")
        if let id = s.project.mainClips.first?.id {
            s.beginGesture()
            for x in stride(from: 0.1, through: 1.0, by: 0.1) { s.updateGesture { $0.trimming(id, .start, to: x) } }
            s.endGesture()
            check("project: in at 1 s (not run away)", abs((s.project.mainClips.first?.inSec ?? 0) - 1) < 0.02, "\(s.project.mainClips.first?.inSec ?? -1)")
            s.undo()
        }

        step("Add a take, reorder, transition")
        s.addTake(blue)
        check("project: two clips, 7 s", s.project.mainClips.count == 2 && abs(s.duration - 7) < 0.05)
        let atBlue = await previewPixel(s, at: 5.5)
        check("preview shows the added take", isBlue(atBlue), describe(atBlue))
        if let second = s.project.mainClips.last?.id {
            s.edit { $0.moveMainClip(second, to: 0) }
            check("project: reordered", s.project.mainClips.first?.id == second)
            let q5 = await previewPixel(s, at: 1)
            check("preview: blue first", isBlue(q5), describe(q5))
            s.undo()
            s.view { $0.selection = second }
            s.edit { $0.setTransition(.fade, duration: 1) }
            check("project: fade into the second clip", s.project.mainClips.last?.transitionIn?.kind == .fade)
            // The fade overlaps the clips by 1 s: at its middle (3.5 s) both colours mix.
            let mid = await previewPixel(s, at: 3.5)
            check("preview: cross-dissolve", mid.map { $0.r > 70 && $0.b > 70 } ?? false, describe(mid))
            s.undo()
        }
        s.undo()

        step("Mute the video row")
        s.edit { $0.toggleMuted(mainId) }
        check("project: muted", s.project.mainTrack?.muted == true)
        let plan = E.renderPlan(s.project, media: s.sources.infos)
        check("render plan has no sound", plan.audio.isEmpty)
        s.undo()

        step("Ratio 1:1")
        await s.setRatio(.square)
        check("project: square canvas", s.project.canvas.width == s.project.canvas.height)
        let sz = await previewSize(s)
        check("preview square", sz.map { abs($0.width - $0.height) < 2 } ?? false, "\(String(describing: sz))")
        s.undo()

        step("Save this frame (extract frame)")
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("MUSE-edit-ops-frame.png")
        try? FileManager.default.removeItem(at: png)
        let saveErr = await s.saveFrame(at: 1, to: png)
        let saved = NSImage(contentsOf: png)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let sp = saved.flatMap { pixel($0, 0.5, 0.5) }
        check("frame saved as a PNG of the edit", saveErr == nil && isRed(sp), saveErr ?? describe(sp))

        step("Volume keyframes")
        s.view { $0.selection = s.project.mainClips.first?.id }
        s.seek(1); s.edit { $0.addVolumeKey() }
        s.seek(3); s.edit { $0.setVolumeValue(0.2) }
        check("project: two volume keys", s.project.mainClips.first?.keyframes?.volume?.count == 2)
        s.undo(); s.undo()

        step("Overlay ⇄ main track")
        s.seek(0)
        s.addTake(blue)
        if let bid = s.project.mainClips.last?.id {
            s.view { $0.selection = bid }
            s.edit { $0.moveToOverlay() }
            check("project: blue on an overlay track, main back to 4 s", s.project.tracks.contains { $0.kind == .video && $0.items.contains { $0.id == bid } } && abs(s.duration - 4) < 0.05,
                  "\(s.duration)")
            s.edit { $0.moveToMain() }
            check("project: back on the main track", s.project.mainClips.contains { $0.id == bid } && !s.project.tracks.contains { $0.kind == .video })
            let qm2 = await previewPixel(s, at: 5)
            check("preview: blue after the take", isBlue(qm2), describe(qm2))
            s.undo(); s.undo()
        }
        s.undo()

        step("Ratio 4:3")
        await s.setRatio(.fourThree)
        let sz43 = await previewSize(s)
        check("preview 4:3", sz43.map { abs($0.width / $0.height - 4.0 / 3.0) < 0.01 } ?? false, "\(String(describing: sz43))")
        s.undo()

        // Parity wave 1 (contract): mirror, freeze frame, blend, blur fill.
        step("Mirror")
        s.view { $0.selection = s.project.mainClips.first?.id }
        s.edit { $0.setFlip(x: true) }
        check("project: mirrored", s.project.mainClips.first?.transform?.flipX == true)
        let qm = await previewPixel(s, at: 1)
        check("preview still shows the take", isRed(qm), describe(qm))
        s.undo()

        step("Freeze frame 1 s at 1 s")
        s.seek(1)
        s.edit { $0.freezeFrame(durationSec: 1) }
        check("project: a 1 s hold between two pieces", s.project.mainClips.count == 3 && s.project.mainClips[1].holdSec == 1 && abs(s.duration - 5) < 0.05,
              "\(s.project.mainClips.map { $0.holdSec.map { "hold \($0)" } ?? "\($0.inSec)–\($0.outSec)" }) · \(s.duration)")
        let qf = await previewPixel(s, at: 1.5)
        check("preview shows the held frame", isRed(qf), describe(qf))
        let fd = s.player.currentItem?.asset.duration.seconds ?? 0
        check("preview 1 s longer", abs(fd - 5) < 0.15, "\(fd)")
        s.undo()

        step("Blend multiply (blue overlay)")
        s.seek(0.5)
        s.addTake(blue, overlay: true)
        s.edit { $0.setFit(.cover) }
        s.edit { $0.setVisualValue(.scale, 1) }
        s.edit { $0.setVisualValue(.x, 0.5) }
        s.edit { $0.setVisualValue(.y, 0.5) }
        let qn = await previewPixel(s, at: 1)
        check("preview: the overlay covers the take", isBlue(qn), describe(qn))
        s.edit { $0.setBlend(.multiply) }
        check("project: multiply", s.state.selectedBlend == .multiply)
        let qb = await previewPixel(s, at: 1)
        // red (220, 30, 30) × blue (30, 40, 220) ≈ (26, 5, 26): dark, neither red nor blue.
        check("preview: multiplied", qb.map { $0.r < 60 && $0.g < 30 && $0.b < 60 } ?? false, describe(qb))
        s.edit { $0.setBlend(.screen) }
        let qs = await previewPixel(s, at: 1)
        check("preview: screen is lighter than both", qs.map { $0.r > 200 && $0.b > 200 } ?? false, describe(qs))
        for _ in 0..<7 { s.undo() }

        step("Blur fill behind a scaled-down clip")
        s.view { $0.selection = s.project.mainClips.first?.id }
        s.edit { $0.setVisualValue(.scale, 0.5) }
        let qc = await previewPixel(s, at: 1, 0.05, 0.05)
        check("preview: background colour at the corner", isBlack(qc), describe(qc))
        s.edit { $0.setBackground(fill: .blur) }
        check("project: canvas fill blur", s.project.canvas.fill == .blur)
        let qbf = await previewPixel(s, at: 1, 0.05, 0.05)
        check("preview: the blurred, darkened take at the corner", qbf.map { $0.r > 120 && $0.r < 215 && $0.g < 60 } ?? false, describe(qbf))
        s.edit { $0.setBackground(fill: .color, color: "#2040FF") }
        let qcol = await previewPixel(s, at: 1, 0.05, 0.05)
        check("preview: background colour", isBlue(qcol), describe(qcol))
        for _ in 0..<3 { s.undo() }

        // Parity M rows (as Android c8875ec): keyframes on the timeline, curves, auto adjust.
        step("Drag a keyframe on the timeline")
        s.view { $0.selection = s.project.mainClips.first?.id }
        let kid = s.project.mainClips.first?.id ?? ""
        s.seek(0.5); s.edit { $0.addKeyframe(.opacity, value: 1) }
        s.seek(1.5); s.edit { $0.addKeyframe(.opacity, value: 0.4) }
        s.beginGesture()
        for d in [0.2, 0.4, 0.5] { s.updateGesture { $0.movingKeys(kid, from: 0.5, by: d) } }
        s.endGesture()
        check("project: the 0.5 s key moved to 1 s", s.state.keyTimes(kid) == [1, 1.5], "\(s.state.keyTimes(kid))")
        s.updateGesture { $0.movingKeys(kid, from: 1, by: 2) }
        check("a key can't pass its neighbour", s.state.keyTimes(kid) == [1, 1.5], "\(s.state.keyTimes(kid))")
        for _ in 0..<3 { s.undo() }

        step("Curves")
        s.view { $0.selection = s.project.mainClips.first?.id }
        s.edit { $0.setCurve(.rgb, [[0, 0], [1, 0.3]]) }
        check("project: an All curve", s.project.mainClips.first?.look?.curves?.rgb?.count == 2)
        let qk = await previewPixel(s, at: 1)
        check("preview: darker red under the curve", qk.map { $0.r > 30 && $0.r < 120 && $0.g < 40 } ?? false, describe(qk))
        s.undo()

        step("Auto adjust")
        s.view { $0.selection = s.project.mainClips.first?.id }
        s.seek(1)
        await s.autoAdjust()
        let aa = s.project.mainClips.first?.adjust
        check("project: a red frame gets cooler", (aa?.temperature ?? 0) < 0, "\(String(describing: aa)) · \(s.notice ?? s.lastError ?? "")")
        if aa != nil { s.undo() }

        step("Colour keyframes (exposure dark → normal)")
        s.view { $0.selection = s.project.mainClips.first?.id }
        s.seek(0.5); s.edit { $0.addKeyframe(.exposure, value: -1) }
        s.seek(2.5); s.edit { $0.addKeyframe(.exposure, value: 0) }
        check("project: exposure keys", s.project.mainClips.first?.keyframes?.exposure?.count == 2 && E.problem(s.project) == nil)
        let qd = await previewPixel(s, at: 0.5), ql = await previewPixel(s, at: 2.5)
        check("preview: darker at the first key", (qd?.r ?? 255) + 40 < (ql?.r ?? 0) && isRed(ql), "\(describe(qd)) then \(describe(ql))")
        for _ in 0..<2 { s.undo() }

        step("Style kit: save, apply, delete")
        s.view { $0.selection = s.project.mainClips.first?.id }
        s.edit { $0.changeVisual { $0.adjust = E.Adjust(contrast: 0.3) } }
        let savedKit = await s.saveKit(name: "CI style")
        check("kit saved", savedKit && s.kits?.first?.name == "CI style", s.lastError ?? "")
        check("kit carries the colour", s.kits?.first?.kit.adjust?.contrast == 0.3, "\(String(describing: s.kits?.first?.kit))")
        s.undo()
        if let k = s.kits?.first {
            s.applyKit(k)
            check("project: every main clip takes the kit's colour", s.project.mainClips.allSatisfy { $0.adjust?.contrast == 0.3 })
            s.undo()
            await s.deleteKit(k)
            check("kit deleted", s.kits?.contains { $0.id == k.id } == false)
        }

        step("HSL per hue (red hues toward orange)")
        s.view { $0.selection = s.project.mainClips.first?.id }
        s.edit { $0.setHsl("red", "hue", 1) }
        check("project: an HSL setting", s.state.hslValue("red", "hue") == 1 && E.problem(s.project) == nil)
        let hq = await previewPixel(s, at: 1)
        check("preview: the red take turns orange", hq.map { $0.r > 150 && $0.g > 70 && $0.b < 70 } ?? false, describe(hq))
        s.undo()

        step("Own font on a text")
        let sysFont = ["/System/Library/Fonts/Supplemental/Arial.ttf", "/System/Library/Fonts/Supplemental/Georgia.ttf"]
            .map(URL.init(fileURLWithPath:)).first { FileManager.default.fileExists(atPath: $0.path) }
        if let sysFont {
            s.edit { $0.addText("Own font") }
            await s.importFont(sysFont)
            let fa = s.state.selectedItem?.textItem?.style.fontAsset
            check("project: the text uses the font asset", fa != nil && s.project.asset(fa ?? "")?.kind == .font && E.problem(s.project) == nil,
                  "\(fa ?? "none") · \(s.lastError ?? s.notice ?? "")")
            for _ in 0..<(fa == nil ? 1 : 2) { s.undo() }
        } else {
            log.note("SKIP no system .ttf on this runner")
        }

        step("Adjustment layer (exposure down over the whole picture)")
        s.seek(0.5)
        let before = await previewPixel(s, at: 1)
        s.edit { $0.addAdjustLayer() }
        s.edit { $0.setVisualValue(.exposure, -1) }
        check("project: an adjustment layer", s.project.tracks.contains { $0.kind == .adjust } && E.problem(s.project) == nil)
        let after = await previewPixel(s, at: 1)
        check("preview: darker under the layer", (after?.r ?? 255) + 40 < (before?.r ?? 0), "\(describe(before)) then \(describe(after))")
        let outside = await previewPixel(s, at: 3.8)
        check("preview: as before after the layer ends", isRed(outside), describe(outside))
        for _ in 0..<2 { s.undo() }

        step("Loop animation (blink on an overlay)")
        s.seek(0.5)
        s.addTake(blue, overlay: true)
        s.edit { $0.setFit(.cover) }
        s.edit { $0.setVisualValue(.scale, 1) }
        s.edit { $0.setVisualValue(.x, 0.5) }
        s.edit { $0.setVisualValue(.y, 0.5) }
        s.edit { $0.setLoop(E.AnimLoop(kind: .blink, periodSec: 1, amount: 1)) }
        check("project: a blink loop on the overlay", s.state.selectedLoop?.kind == .blink && E.problem(s.project) == nil)
        let lb = await previewPixel(s, at: 0.5), lr = await previewPixel(s, at: 1.0)
        check("preview: the overlay at rest, then gone half a cycle in", isBlue(lb) && isRed(lr), "\(describe(lb)) then \(describe(lr))")
        for _ in 0..<6 { s.undo() }

        step("Look keyframes (vignette 0 → 1)")
        s.view { $0.selection = s.project.mainClips.first?.id }
        s.seek(0.5); s.edit { $0.addKeyframe(.vignette, value: 0) }
        s.seek(2.5); s.edit { $0.addKeyframe(.vignette, value: 1) }
        check("project: vignette keys", s.project.mainClips.first?.keyframes?.vignette?.count == 2 && E.problem(s.project) == nil)
        let v0 = await previewPixel(s, at: 0.5, 0.03, 0.03), v1 = await previewPixel(s, at: 2.5, 0.03, 0.03)
        check("preview: the corner darker at the second key", (v1?.r ?? 255) + 40 < (v0?.r ?? 0), "\(describe(v0)) then \(describe(v1))")
        for _ in 0..<2 { s.undo() }

        step("Key colour from the picture (eyedropper)")
        s.view { $0.selection = s.project.mainClips.first?.id }
        s.seek(1)
        s.edit { $0.changeVisual { $0.chroma = E.Chroma(color: "#2BD15F", similarity: 0.4, smoothness: 0.08, spill: 0.5) } }
        await s.toggleKeyPick()
        check("picking", s.pickingKeyColour, s.lastError ?? "")
        let cw = Double(s.project.canvas.width), chh = Double(s.project.canvas.height)
        s.pickKeyColour(canvasX: cw / 2, canvasY: chh / 2)
        let picked = s.project.mainClips.first?.chroma?.color ?? ""
        let pr = Int(picked.dropFirst().prefix(2), radix: 16) ?? 0, pg = Int(picked.dropFirst(3).prefix(2), radix: 16) ?? 255
        check("project: the key colour is the take's red", !s.pickingKeyColour && pr > 150 && pg < 90, picked)
        for _ in 0..<2 { s.undo() }

        step("A large picture goes up at 2048 px")
        let big = FileManager.default.temporaryDirectory.appendingPathComponent("big-\(UUID().uuidString).png")
        if let ctx = CGContext(data: nil, width: 3000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 0.5)); ctx.fill(CGRect(x: 0, y: 0, width: 3000, height: 1000))
            if let img = ctx.makeImage(), let d = CGImageDestinationCreateWithURL(big as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(d, img, nil); _ = CGImageDestinationFinalize(d)
            }
        }
        let resized = try? EditSuiteSession.pictureForUpload(big, ext: "png")
        check("2048 × 683, still a PNG", resized.map { $0.2 == 2048 && abs($0.3 - 683) <= 1 && $0.1 == "image/png" } ?? false,
              resized.map { "\($0.2) × \($0.3) \($0.1)" } ?? "failed")

        step("Content library: a sticker, a sound effect, a transition preset")
        await s.loadContent()
        if let c = s.content, let sp = c.packs(.stickers).first, let st = sp.items.first, let fp = c.packs(.sfx).first, let fx = fp.items.first {
            s.view { $0.selection = nil }
            s.seek(1)
            await s.addContentSticker(sp, st)
            let ref = ContentCatalog.ref(pack: sp.id, item: st.id)
            check("project: the sticker is a library picture", s.project.assets.contains { $0.library == ref && $0.kind == .image } && E.problem(s.project) == nil)
            let px = await previewPixel(s, at: 2, 0.5, 0.4)
            check("preview: the sticker over the clip", px.map { $0.r > 150 && $0.g > 120 && $0.b < 90 } ?? false, describe(px))
            await s.addContentSound(fp, fx)
            check("project: the sound effect on its row", s.project.tracks.contains { $0.kind == .sfx && !$0.items.isEmpty } && E.problem(s.project) == nil)
            s.view { $0.selection = s.project.mainClips.dropFirst().first?.id }
            if let tr = c.packs(.transitions).flatMap(\.items).compactMap(\.transitionValue).first(where: { $0.kind == .zoomOut }), s.project.mainClips.count > 1 {
                s.edit { $0.setTransition(tr.kind, duration: tr.durationSec) }
                check("project: the zoom out preset", s.project.mainClips[1].transitionIn?.kind == .zoomOut && E.problem(s.project) == nil)
                s.undo()
            }
            for _ in 0..<2 { s.undo() }
        } else {
            check("the content catalog loads", false, "no stickers or sounds in it")
        }

        step("Stabilise: a steadied copy, then off again (only the last step switches off)")
        s.view { $0.selection = s.project.mainClips.first?.id }
        s.lastError = nil
        let unsteady = s.project
        await s.toggleStabilize()
        for _ in 0..<200 where s.isRunning(.stabilize) || s.state.selectedSteps.isEmpty && s.lastError == nil { try? await Task.sleep(for: .milliseconds(100)) }
        let steadied = s.project.mainClips.first.map { E.derivedLabel(s.project, $0.asset) } ?? ""
        check("stabilise: the clip plays a steadied copy", steadied == "Steadied" && E.problem(s.project) == nil, s.lastError ?? steadied)
        await s.toggleStabilize()
        check("stabilise: off again, the copy kept", s.state.selectedSteps.isEmpty && s.project.assets.contains { $0.derivedFrom?.kind == .stabilize },
              s.lastError ?? "\(s.state.selectedSteps)")
        for _ in 0..<2 { s.undo() }
        check("stabilise: undone", s.project.mainClips == unsteady.mainClips)
        s.lastError = nil

        step("Split voice and music (the demo job): the clip muted, both parts on their rows")
        do {
            s.view { $0.selection = s.project.mainClips.first?.id }
            s.lastError = nil
            let unsplit = s.project
            await s.separateSelected(keep: .both)
            s.confirmPaid()
            for _ in 0..<200 where s.isRunning(.separate) || (s.project == unsplit && s.lastError == nil) { try? await Task.sleep(for: .milliseconds(100)) }
            let voice = s.project.tracks.contains { $0.kind == .voice && !$0.items.isEmpty }, music = s.project.tracks.contains { $0.kind == .music && !$0.items.isEmpty }
            check("separate: muted, voice and music rows, valid", s.project.mainClips.first?.muted == true && voice && music && E.problem(s.project) == nil,
                  s.lastError ?? "voice \(voice) music \(music)")
            s.undo()
            check("separate: undone", s.project == unsplit)
            s.lastError = nil
        }

        step("Effects: duotone on the clip changes the preview; off again")
        do {
            s.view { $0.selection = s.project.mainClips.first?.id }
            let plain = await previewPixel(s, at: 1)
            s.edit { $0.setEffect(E.Effect(id: "duotone", amount: 1, colors: ["#000000", "#00FF00"])) }
            let toned = await previewPixel(s, at: 1)
            // Red (luma ≈ 0.21) between black and green: green rises, red falls.
            check("effects: duotone maps the red picture into black → green", toned.map { $0.g > $0.r && $0.g > 20 } ?? false, "\(describe(plain)) → \(describe(toned))")
            s.undo()
        }

        step("Effects library: the Core Image kernel against the reference maths (WS8 f7226f2)")
        effectsKernelCheck(check)

        step("Smooth slow motion: 1 s from 1 s, 4× (the demo job), split around it")
        s.view { $0.selection = s.project.mainClips.first?.id }
        s.seek(1)
        s.lastError = nil
        let unslowed = s.project
        s.slowmoFactor = 4; s.slowmoLength = 1
        await s.smoothSlowmo()
        s.confirmPaid()
        for _ in 0..<200 where s.isRunning(.slowmo) || (s.state.selectedVideo?.asset == unslowed.mainClips.first?.asset && s.lastError == nil) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let slowed = s.state.selectedVideo
        check("slowmo: the slowed piece plays the copy, muted", slowed.map { E.derivedLabel(s.project, $0.asset) == "Smooth 4×" && $0.muted == true } ?? false,
              s.lastError ?? "\(String(describing: slowed?.asset))")
        check("slowmo: the clip is split around it and valid", s.project.mainClips.count == unslowed.mainClips.count + 2 && E.problem(s.project) == nil,
              "\(s.project.mainClips.count) clips")
        s.undo()
        check("slowmo: undone", s.project.mainClips == unslowed.mainClips)
        s.lastError = nil

        step("Translated captions: the demo job, then Show original")
        let uncaptioned = s.project
        if let asset = s.project.mainClips.first?.asset {
            s.edit { $0.setCaptions(words: [E.Word(text: "Hello", startSec: 0.2, endSec: 0.6), E.Word(text: "world", startSec: 0.6, endSec: 1.1)], assetId: asset) }
            s.lastError = nil
            s.translateTarget = "fr"
            await s.translateCaptions()
            s.confirmPaid()
            for _ in 0..<200 where s.isRunning(.translate) || (s.state.captionLanguage == nil && s.lastError == nil) { try? await Task.sleep(for: .milliseconds(100)) }
            check("translate: captions in French, the English kept", s.state.captionLanguage == "fr" && s.state.captionsTranslated && E.problem(s.project) == nil,
                  s.lastError ?? "\(String(describing: s.state.captionLanguage))")
            s.edit { $0.swapCaptionOriginal() }
            check("translate: Show original", s.project.captionTrack?.words.first?.text == "Hello")
            for _ in 0..<3 { s.undo() }
            check("translate: undone", s.project == uncaptioned)
            s.lastError = nil
        }

        step("Auto reframe: Vision runs over the clip (no face in the test take)")
        s.view { $0.selection = s.project.mainClips.first?.id }
        s.lastError = nil
        let beforeReframe = s.project
        s.followFaces()
        for _ in 0..<300 where s.reframeProgress != nil { try? await Task.sleep(for: .milliseconds(100)) }
        check("reframe: finished", s.reframeProgress == nil)
        check("reframe: no face, no change, and says why", s.project == beforeReframe && (s.lastError ?? "").contains("No face"), s.lastError ?? "no message")
        s.lastError = nil

        step("Back to the take")
        check("every change undone", s.project == base, "the project differs from the take after undoing everything")
    }

    /// The check's log file: each line written and flushed at once (a crash leaves what ran).
    final class OpsLog {
        let url: URL
        init(_ url: URL) { self.url = url; try? Data().write(to: url) }
        func note(_ s: String) {
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            h.seekToEndOfFile()
            h.write(Data((s + "\n").utf8))
            try? h.synchronize()
            try? h.close()
            print("edit-ops: \(s)")
        }
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            note(ok ? "OK \(name)" : "FAIL \(name)" + (detail.isEmpty ? "" : ": \(detail)"))
        }
    }

    // MARK: Export

    /// Exports for real (the session's own export: render, describe, upload to the demo API, save a version) and checks the file.
    @MainActor
    static func exportCheck(_ s: EditSuiteSession, media: URL, log: OpsLog) async {
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { log.check(name, ok, detail) }
        let note = log.note
        note("STEP export: 3 s cut, +6 dB, text, 720p 30 fps, AI label")
        // 0.5–3.5 s of the red take, its sound at +6 dB.
        s.view { $0.selection = s.project.mainClips.first?.id }
        if let id = s.project.mainClips.first?.id {
            s.beginGesture(); s.updateGesture { $0.trimming(id, .start, to: 0.5) }; s.endGesture()
            s.beginGesture(); s.updateGesture { $0.trimming(id, .end, to: 3.0) }; s.endGesture()
        }
        s.edit { $0.changeSound { $0.volume = 2 } }
        check("project: 3 s at +6 dB", abs(s.duration - 3) < 0.05 && s.state.selectedVideo?.volume == 2, "\(s.duration)")
        let loud = await exportFile(s, media: media, name: "loud", labelAI: true, note: note)
        if let loud {
            let asset = AVURLAsset(url: loud.url)
            let d = (try? await asset.load(.duration).seconds) ?? 0
            check("export: length 3 s", abs(d - 3) < 0.12, "\(d)")
            let vt = try? await asset.loadTracks(withMediaType: .video).first
            let size = (try? await vt?.load(.naturalSize)) ?? .zero
            check("export: 720 × 1280", Int(size.width) == 720 && Int(size.height) == 1280, "\(size)")
            let fps = (try? await vt?.load(.nominalFrameRate)) ?? 0
            check("export: 30 fps", abs(Double(fps) - 30) < 1.5, "\(fps)")
            let gen = AVAssetImageGenerator(asset: asset)
            gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
            let frame = try? await gen.image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image
            let px = frame.flatMap { pixel($0, 0.5, 0.5) }
            check("export: the picture", isRed(px), describe(px))
            let rms = await audioRMS(loud.url, from: 1, to: 2)
            // The tone is 0.2 (RMS ≈ 0.141); +6 dB doubles it (≈ 0.28). Before the fix it stayed at 0.141.
            check("export: sound at +6 dB", rms > 0.22 && rms < 0.36, String(format: "RMS %.3f", rms))
            check("export: saved a version with the AI label", loud.take?.aiLabel == true && loud.take?.editsV2 != nil,
                  "aiLabel \(String(describing: loud.take?.aiLabel))")
        }
        note("STEP export: −12 dB")
        s.edit { $0.changeSound { $0.volume = EditSuite.gain(db: -12) } }
        if let quiet = await exportFile(s, media: media, name: "quiet", labelAI: false, note: note) {
            let rms = await audioRMS(quiet.url, from: 1, to: 2)
            check("export: sound at −12 dB", rms > 0.02 && rms < 0.05, String(format: "RMS %.3f", rms))
            check("export: no AI label unless asked", quiet.take?.aiLabel == nil)
        }
        note("STEP export: muted")
        s.edit { $0.changeSound { $0.muted = true } }
        if let silent = await exportFile(s, media: media, name: "muted", labelAI: false, note: note) {
            let rms = await audioRMS(silent.url, from: 0.2, to: 2.8)
            check("export: muted is silent", rms < 0.005, String(format: "RMS %.4f", rms))
        }
        note("STEP export: HDR (HEVC 10-bit HLG)")
        if let hdr = await exportFile(s, media: media, name: "hdr", labelAI: false, hdr: true, note: note) {
            let asset = AVURLAsset(url: hdr.url)
            let vt = try? await asset.loadTracks(withMediaType: .video).first
            let desc = (try? await vt?.load(.formatDescriptions))?.first
            let codec = desc.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
            let ext = desc.flatMap { CMFormatDescriptionGetExtensions($0) as? [String: Any] } ?? [:]
            let transfer = ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String ?? ""
            let primaries = ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String ?? ""
            let depth = ext[kCMFormatDescriptionExtension_Depth as String] as? Int ?? 0
            check("export HDR: HEVC", codec == kCMVideoCodecType_HEVC, String(format: "%08x", codec))
            check("export HDR: BT.2020 / HLG", transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
                  && primaries == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String), "\(primaries) / \(transfer) depth \(depth)")
            let gen = AVAssetImageGenerator(asset: asset)
            gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
            let frame = try? await gen.image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image
            let px = frame.flatMap { pixel($0, 0.5, 0.5) }
            // SDR content sits at HLG reference white (BT.2408, 75 %), below HDR peak, so it reads darker when decoded to
            // SDR (rgb(150, 1, 10) on CI): check the hue, not the brightness.
            check("export HDR: the picture", px.map { $0.r > 100 && $0.g < 50 && $0.b < 50 } ?? false, describe(px))
        }
    }

    /// HDR colour, on its own and early in review mode (round 2: in build 582 an earlier check stopped the run before it).
    /// Writes hdr-colour-check.txt. Two skin-tone takes: untagged and tagged BT.709 (as the owner's AI take).
    @MainActor
    static func hdrColourCheck(_ store: AppStore, dir: URL) async {
        let log = OpsLog(dir.appendingPathComponent("hdr-colour-check.txt"))
        let media = FileManager.default.temporaryDirectory.appendingPathComponent("MUSE-hdr-colour", isDirectory: true)
        try? FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        await hdrConsistencyCheck(store, media: media, log: log, tagged: false)
        await hdrConsistencyCheck(store, media: media, log: log, tagged: true)
        store.takes.removeAll { $0.id.hasPrefix("hdr_") }
        log.note("ALL DONE")
    }

    /// Owner bug 2026-11-12: HDR (HLG) exports turned skin warmer / orange at the start and now and then. A skin-tone take
    /// (`tagged`: BT.709 tags in the file, else none), captions on its first second only, exported SDR and HDR. Every HDR
    /// frame's skin patch (decoded from the file's own 10-bit codes with BT.2020 / HLG, tone-mapped to SDR) must match
    /// every other frame's (the first 15 frames, caption vs plain, first vs middle) and the SDR export's. The colour tags
    /// the compositor's frames really arrived with are written as TRACE lines.
    @MainActor
    static func hdrConsistencyCheck(_ store: AppStore, media: URL, log: OpsLog, tagged: Bool) async {
        typealias H = EditV2.HDRColor
        let kind = tagged ? "tagged 709" : "untagged"
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { log.check("export HDR colour (\(kind)): \(name)", ok, detail) }
        log.note("STEP export HDR: same colour on every frame, \(kind) take")
        let skinRGB = (224, 172, 140)
        let url = media.appendingPathComponent(tagged ? "skin-709.mp4" : "skin.mp4")
        do { try await makeSolidVideo(url, seconds: 3, rgb: skinRGB, tone: nil, tag709: tagged) } catch {
            check("test video", false, error.localizedDescription); return
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let raw: [String: Any] = ["id": tagged ? "hdr_skin709" : "hdr_skin", "kind": "take", "title": "Skin", "videoUrl": url.absoluteString, "durationSec": 3,
                                  "width": 360, "height": 640, "fps": 30, "createdAt": now]
        guard let take = (try? JSONSerialization.data(withJSONObject: raw)).flatMap({ try? JSONDecoder().decode(Take.self, from: $0) }) else {
            check("test take", false); return
        }
        store.takes.insert(take, at: 0)
        await (store.api as? FakeMuseAPI)?.adoptTakes([take])
        guard let s = store.makeEditSuiteSession(takeId: take.id) else { check("editor session", false); return }
        defer { s.close() }
        await s.load()
        guard s.isReady, let asset = s.project.mainClips.first?.asset else { check("the edit opened", false, "\(s.phase)"); return }
        // Burned-in captions on 0.1–1.0 s; plain frames after.
        s.edit { $0.setCaptions(words: [EditV2.Word(text: "Hello", startSec: 0.1, endSec: 0.5), EditV2.Word(text: "there", startSec: 0.5, endSec: 1.0)], assetId: asset) }
        s.edit { $0.changeCaptionStyle { $0.y = 0.85 } }
        guard let sdr = await exportFile(s, media: media, name: tagged ? "skin709-sdr" : "skin-sdr", labelAI: false, note: log.note) else { return }
        EditV2HDRTrace.reset()
        let hdrFile = await exportFile(s, media: media, name: tagged ? "skin709-hdr" : "skin-hdr", labelAI: false, hdr: true, note: log.note)
        for line in EditV2HDRTrace.dump() { log.note("TRACE \(line)") }
        if let vt = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
           let desc = (try? await vt.load(.formatDescriptions))?.first {
            log.note("TRACE source file tags \(EditV2Engine.colorTags(desc))")
        }
        guard let hdr = hdrFile else { return }
        let sdrPx = await framePatches(sdr.url, hdr: false)
        let hdrPx = await framePatches(hdr.url, hdr: true)
        func nearest(_ px: [Double: (r: Int, g: Int, b: Int)], _ t: Double) -> (r: Int, g: Int, b: Int)? { px.min { abs($0.key - t) < abs($1.key - t) }?.value }
        guard hdrPx.count > 60, let ref = nearest(sdrPx, 1.5) else {
            check("read the frames", false, "\(hdrPx.count) HDR, \(sdrPx.count) SDR"); return
        }
        func at(_ t: Double) -> (r: Int, g: Int, b: Int)? { nearest(hdrPx, t) }
        let all = hdrPx.sorted { $0.key < $1.key }
        let first = all[0].value, caption = at(0.5), plain = at(2.0), middle = at(1.5)
        let worst = all.max { H.distance($0.value, first) < H.distance($1.value, first) }!
        check("caption frame = plain frame", caption.map { c in plain.map { H.distance(c, $0) <= 3 } ?? false } ?? false,
              "caption \(describe(caption)) plain \(describe(plain))")
        check("first frame = middle", middle.map { H.distance(first, $0) <= 3 } ?? false, "first \(describe(first)) middle \(describe(middle))")
        let head = all.prefix(15).map(\.value)
        let headWorst = head.map { m in middle.map { H.distance(m, $0) } ?? 99 }.max() ?? 99
        check("first 15 frames = middle", headWorst <= 3, "frames 0–14 " + head.map { describe($0) }.joined(separator: " ") + " middle " + describe(middle))
        log.note("FRAMES " + all.map { String(format: "%.2f ", $0.key) + describe($0.value) }.joined(separator: " | "))
        check("every frame the same", H.distance(worst.value, first) <= 3,
              String(format: "worst at %.2f s: ", worst.key) + describe(worst.value) + " vs first " + describe(first))
        // The SDR export shows the source colour; HDR, tone-mapped back, within a viewer's rounding of it.
        check("matches the SDR export", H.distance(first, ref) <= 10 && H.distance(ref, (r: skinRGB.0, g: skinRGB.1, b: skinRGB.2)) <= 6,
              "HDR \(describe(first)) SDR \(describe(ref)) source rgb\(skinRGB)")
    }

    /// The mean colour of a 16 × 16 patch at (0.5, 0.3) of every frame of a file, by time. HDR files are read as their
    /// raw 10-bit Y′CbCr codes (no conversion by the reader) and decoded with EditV2.HDRColor; SDR files as BGRA.
    static func framePatches(_ url: URL, hdr: Bool) async -> [Double: (r: Int, g: Int, b: Int)] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first, let reader = try? AVAssetReader(asset: asset) else { return [:] }
        let format = hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: format])
        guard reader.canAdd(out) else { return [:] }
        reader.add(out)
        guard reader.startReading() else { return [:] }
        var result: [Double: (r: Int, g: Int, b: Int)] = [:]
        while let sb = out.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            let x0 = w / 2 - 8, y0 = Int(Double(h) * 0.3) - 8
            var sum = (0.0, 0.0, 0.0), n = 0.0
            if hdr {
                guard let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let cb = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { continue }
                let yRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
                for y in y0..<(y0 + 16) {
                    for x in x0..<(x0 + 16) {
                        // 10-bit samples sit in the top bits of 16-bit words.
                        let luma = Int(yb.load(fromByteOffset: y * yRow + x * 2, as: UInt16.self) >> 6)
                        let co = (y / 2) * cRow + (x / 2) * 4
                        let u = Int(cb.load(fromByteOffset: co, as: UInt16.self) >> 6), v = Int(cb.load(fromByteOffset: co + 2, as: UInt16.self) >> 6)
                        let p = EditV2.HDRColor.sdr255(fromHLGCodes: (luma, u, v))
                        sum.0 += Double(p.r); sum.1 += Double(p.g); sum.2 += Double(p.b); n += 1
                    }
                }
            } else {
                guard let base = CVPixelBufferGetBaseAddress(pb) else { continue }
                let row = CVPixelBufferGetBytesPerRow(pb)
                for y in y0..<(y0 + 16) {
                    for x in x0..<(x0 + 16) {
                        let o = y * row + x * 4
                        sum.0 += Double(base.load(fromByteOffset: o + 2, as: UInt8.self))
                        sum.1 += Double(base.load(fromByteOffset: o + 1, as: UInt8.self))
                        sum.2 += Double(base.load(fromByteOffset: o, as: UInt8.self)); n += 1
                    }
                }
            }
            if n > 0 { result[t] = (Int((sum.0 / n).rounded()), Int((sum.1 / n).rounded()), Int((sum.2 / n).rounded())) }
        }
        return result
    }

    /// Parity formats: a video at a chosen bitrate (the reader → writer path), Sound only (.m4a) and GIF.
    @MainActor
    static func formatsCheck(_ s: EditSuiteSession, media: URL, log: OpsLog) async {
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { log.check(name, ok, detail) }
        log.note("STEP export formats: bitrate, Sound only, GIF")
        s.view { $0.selection = s.project.mainClips.first?.id }
        s.edit { $0.changeSound { $0.muted = nil; $0.volume = nil } }
        // A video at "Higher quality" goes through the writer (AVAssetExportSession has no bitrate).
        var hi = s.state.export
        hi.ratio = .portrait; hi.resolution = .p720; hi.fps = 30; hi.codec = .h264; hi.bitrate = .higher
        let hiURL = media.appendingPathComponent("export-hi.mp4")
        try? FileManager.default.removeItem(at: hiURL)
        var savedHi = false
        s.export(hi, saveFileTo: hiURL) { _ in savedHi = true }
        for _ in 0..<600 where !savedHi && !(s.exportPhase == .idle && s.lastError != nil) { try? await Task.sleep(for: .milliseconds(100)) }
        if savedHi {
            let a = AVURLAsset(url: hiURL)
            let d = (try? await a.load(.duration).seconds) ?? 0
            let vt = try? await a.loadTracks(withMediaType: .video).first
            let size = (try? await vt?.load(.naturalSize)) ?? .zero
            check("bitrate export: 3 s, 720 × 1280", abs(d - 3) < 0.15 && Int(size.width) == 720 && Int(size.height) == 1280, "\(d) s, \(size)")
            let gen = AVAssetImageGenerator(asset: a)
            gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
            let px = (try? await gen.image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image).flatMap { pixel($0, 0.5, 0.5) }
            check("bitrate export: the picture", isRed(px), describe(px))
            let rms = await audioRMS(hiURL, from: 1, to: 2)
            check("bitrate export: the sound", rms > 0.09 && rms < 0.2, String(format: "RMS %.3f", rms))
        } else { check("bitrate export finished", false, s.lastError ?? "timed out") }

        // Sound only and GIF save a file on this Mac (no version).
        func other(_ format: EditSuite.ExportFormat, _ name: String) async -> URL? {
            var e = s.state.export
            e.format = format
            let url = media.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
            s.export(e, saveFileTo: url) { _ in }
            try? await Task.sleep(for: .milliseconds(300))
            for _ in 0..<600 where s.exportPhase != .idle { try? await Task.sleep(for: .milliseconds(100)) }
            guard FileManager.default.fileExists(atPath: url.path) else { check("\(format.label) export finished", false, s.lastError ?? "no file"); return nil }
            return url
        }
        if let m4a = await other(.sound, "export-sound.m4a") {
            let a = AVURLAsset(url: m4a)
            let d = (try? await a.load(.duration).seconds) ?? 0
            let vids = (try? await a.loadTracks(withMediaType: .video).count) ?? -1
            let rms = await audioRMS(m4a, from: 1, to: 2)
            check("Sound only: 3 s of the mix, no picture", abs(d - 3) < 0.15 && vids == 0 && rms > 0.09 && rms < 0.2, String(format: "%.2f s, %d video tracks, RMS %.3f", d, vids, rms))
        }
        if let gif = await other(.gif, "export.gif") {
            let src = CGImageSourceCreateWithURL(gif as CFURL, nil)
            let n = src.map { CGImageSourceGetCount($0) } ?? 0
            let first = src.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            let short = first.map { min($0.width, $0.height) } ?? 0
            let px = first.flatMap { pixel($0, 0.5, 0.5) }
            let want = min(480, min(s.project.canvas.width, s.project.canvas.height))   // never upscaled
            check("GIF: 15 frames a second, 480 px at most, the picture", abs(n - 45) <= 2 && short == want && isRed(px), "\(n) frames, short side \(short) (want \(want)), \(describe(px))")
        }
    }

    /// Runs the session's export to a file next to the check's media; returns the file and the saved version.
    @MainActor
    static func exportFile(_ s: EditSuiteSession, media: URL, name: String, labelAI: Bool, hdr: Bool = false, note: (String) -> Void) async -> (url: URL, take: Take?)? {
        var settings = s.state.export
        settings.ratio = .portrait
        settings.resolution = .p720
        settings.fps = 30
        settings.codec = .h264
        settings.labelAI = labelAI
        settings.hdr = hdr
        let url = media.appendingPathComponent("export-\(name).mp4")
        try? FileManager.default.removeItem(at: url)
        var saved: Take?
        var finished = false
        s.export(settings, saveFileTo: url) { t in saved = t; finished = true }
        for _ in 0..<600 where !finished {
            if s.exportPhase == .idle, !finished, s.lastError != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard finished, FileManager.default.fileExists(atPath: url.path) else {
            note("FAIL export \(name): \(s.lastError ?? "didn't finish in 60 s")")
            return nil
        }
        return (url, saved)
    }

    /// Root mean square of the first audio track between `from` and `to` seconds (0 when there is no sound).
    static func audioRMS(_ url: URL, from: Double, to: Double) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return 0 }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600), end: CMTime(seconds: to, preferredTimescale: 600))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                                                                           AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                                                                           AVLinearPCMIsBigEndianKey: false])
        guard reader.canAdd(out) else { return 0 }
        reader.add(out)
        guard reader.startReading() else { return 0 }
        var sum = 0.0, n = 0
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let len = CMBlockBufferGetDataLength(bb)
            var data = [Float](repeating: 0, count: len / 4)
            _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            for v in data { sum += Double(v) * Double(v) }
            n += data.count
        }
        return n > 0 ? (sum / Double(n)).squareRoot() : 0
    }

    // MARK: Test media

    /// An H.264 MP4 of one colour at 30 fps, 360 × 640, with a steady 440 Hz tone of amplitude `tone` (mono AAC 48 kHz) or no sound.
    static func makeSolidVideo(_ url: URL, seconds: Double, rgb: (Int, Int, Int), tone: Double?, tag709: Bool = false) async throws {
        try? FileManager.default.removeItem(at: url)
        let dir = url.deletingLastPathComponent()
        let silent = tone == nil ? url : dir.appendingPathComponent("v-\(UUID().uuidString).mp4")
        let w = 360, h = 640, fps: Int32 = 30
        let writer = try AVAssetWriter(outputURL: silent, fileType: .mp4)
        var settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h]
        if tag709 {
            settings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                                   AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                                   AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ApiError("edit_ops", "Couldn't start the test video") }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { break }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let row = CVPixelBufferGetBytesPerRow(pb)
                let p = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<h {
                    for x in 0..<w {
                        let o = y * row + x * 4
                        p[o] = UInt8(rgb.2); p[o + 1] = UInt8(rgb.1); p[o + 2] = UInt8(rgb.0); p[o + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? ApiError("edit_ops", "Couldn't write the test video") }
        guard let tone else { return }
        defer { try? FileManager.default.removeItem(at: silent) }
        let sound = dir.appendingPathComponent("a-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: sound) }
        let rate = 48_000.0
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(seconds * rate)), let data = buf.floatChannelData else {
            throw ApiError("edit_ops", "Couldn't make the test sound")
        }
        buf.frameLength = buf.frameCapacity
        for i in 0..<Int(buf.frameLength) { data[0][i] = Float(sin(2 * Double.pi * 440 * Double(i) / rate) * tone) }
        do {
            let file = try AVAudioFile(forWriting: sound, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                                                                    AVEncoderBitRateKey: 128_000])
            try file.write(from: buf)
        }
        let comp = AVMutableComposition()
        let va = AVURLAsset(url: silent), aa = AVURLAsset(url: sound)
        guard let vSrc = try await va.loadTracks(withMediaType: .video).first, let aSrc = try await aa.loadTracks(withMediaType: .audio).first,
              let vT = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let aT = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ApiError("edit_ops", "Couldn't mux the test video")
        }
        let vDur = try await va.load(.duration), aDur = try await aa.load(.duration)
        try vT.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: vSrc, at: .zero)
        try aT.insertTimeRange(CMTimeRange(start: .zero, duration: min(vDur, aDur)), of: aSrc, at: .zero)
        guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { throw ApiError("edit_ops", "Couldn't mux the test video") }
        ex.outputURL = url
        ex.outputFileType = .mp4
        await ex.export()
        if ex.status != .completed { throw ex.error ?? ApiError("edit_ops", "Couldn't mux the test video") }
    }

    /// Each effect drawn by the kernel on a 32×32 pattern against EditV2.effectPixel: at least 95 % of the pixels within
    /// 3/255 (a noise threshold can flip on a float edge), and the kernel must exist.
    @MainActor
    static func effectsKernelCheck(_ check: (String, Bool, String) -> Void) {
        check("effects: the kernel compiles", EditV2EffectRenderer.kernel != nil, "CIKernel(source:) returned nil")
        guard EditV2EffectRenderer.kernel != nil else { return }
        let W = 32, H = 32
        var px: [EditV2.RGB] = []
        var floats: [Float] = []
        for y in 0..<H {
            for x in 0..<W {
                let c = EditV2.RGB(Double(x) / 31, Double(y) / 31, (x + y) % 2 == 0 ? 0.25 : 0.75)
                px.append(c)
                floats += [Float(c.x), Float(c.y), Float(c.z), 1]
            }
        }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        // Bitmap data's first row is the image's top (as the pattern's row 0, v pointing down); render(toBitmap:) writes
        // the top row first too, so neither is flipped.
        let img = CIImage(bitmapData: floats.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: W * 16, size: CGSize(width: W, height: H), format: .RGBAf, colorSpace: srgb)
        let ctx = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb])
        let sampler = EditV2.imageSampler(width: W, height: H, px)
        for id in EditV2.effectIds {
            let e = EditV2.Effect(id: id, amount: 0.8, speed: 1.3)
            let out = EditV2EffectRenderer.apply(e, to: img, t: 0.37)
            var buf = [Float](repeating: 0, count: W * H * 4)
            buf.withUnsafeMutableBytes { ctx.render(out, toBitmap: $0.baseAddress!, rowBytes: W * 16, bounds: CGRect(x: 0, y: 0, width: W, height: H), format: .RGBAf, colorSpace: srgb) }
            var good = 0, worst = 0.0
            var firstBad: [String] = []
            for y in 0..<H {
                for x in 0..<W {
                    let ref = EditV2.effectPixel(e, t: 0.37, width: Double(W), height: Double(H), u: (Double(x) + 0.5) / Double(W), v: (Double(y) + 0.5) / Double(H), sample: sampler)
                    let o = y * W * 4 + x * 4
                    let d = max(abs(Double(buf[o]) - ref.x), abs(Double(buf[o + 1]) - ref.y), abs(Double(buf[o + 2]) - ref.z))
                    worst = max(worst, d)
                    if d <= 3.0 / 255 { good += 1 } else if firstBad.count < 3 {
                        firstBad.append(String(format: "(%d,%d) got %.3f %.3f %.3f want %.3f %.3f %.3f", x, y, buf[o], buf[o + 1], buf[o + 2], ref.x, ref.y, ref.z))
                    }
                }
            }
            check("effects: \(id) matches the reference", Double(good) / Double(W * H) >= 0.95,
                  String(format: "%d/%d within 3/255, worst %.3f; ", good, W * H, worst) + firstBad.joined(separator: "; "))
        }
        // Diagnostic: the permutation as the kernel reads it (nearest, 256×1, no colour management).
        let readK = CIKernel(source: """
            kernel vec4 musePermRead(sampler perm) {
                vec2 d = destCoord();
                float v = sample(perm, samplerTransform(perm, vec2(floor(d.x) + 0.5, 0.5))).r;
                return vec4(v, v, v, 1.0);
            }
            """)
        if let readK, let out = readK.apply(extent: CGRect(x: 0, y: 0, width: 256, height: 1), roiCallback: { _, _ in CGRect(x: 0, y: 0, width: 256, height: 1) },
                                           arguments: [EditV2EffectRenderer.perm]) {
            var pb = [Float](repeating: 0, count: 256 * 4)
            pb.withUnsafeMutableBytes { ctx.render(out, toBitmap: $0.baseAddress!, rowBytes: 256 * 16, bounds: CGRect(x: 0, y: 0, width: 256, height: 1), format: .RGBAf, colorSpace: nil) }
            let got = (0..<256).map { Int((pb[$0 * 4] * 255).rounded()) }
            let bad = (0..<256).filter { got[$0] != EditV2.effectPerm[$0] }
            check("effects: the kernel reads Perlin's permutation exactly", bad.isEmpty,
                  "\(bad.count) wrong; first: " + bad.prefix(6).map { "[\($0)] got \(got[$0]) want \(EditV2.effectPerm[$0])" }.joined(separator: ", "))
        } else {
            check("effects: the permutation readback kernel compiles", false, "nil")
        }
    }
}

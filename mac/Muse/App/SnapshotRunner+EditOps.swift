import AppKit
import AVFoundation
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
    }

    /// Runs the session's export to a file next to the check's media; returns the file and the saved version.
    @MainActor
    static func exportFile(_ s: EditSuiteSession, media: URL, name: String, labelAI: Bool, note: (String) -> Void) async -> (url: URL, take: Take?)? {
        var settings = s.state.export
        settings.ratio = .portrait
        settings.resolution = .p720
        settings.fps = 30
        settings.codec = .h264
        settings.labelAI = labelAI
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
    static func makeSolidVideo(_ url: URL, seconds: Double, rgb: (Int, Int, Int), tone: Double?) async throws {
        try? FileManager.default.removeItem(at: url)
        let dir = url.deletingLastPathComponent()
        let silent = tone == nil ? url : dir.appendingPathComponent("v-\(UUID().uuidString).mp4")
        let w = 360, h = 640, fps: Int32 = 30
        let writer = try AVAssetWriter(outputURL: silent, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
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
}

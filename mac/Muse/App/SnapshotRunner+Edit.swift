import AppKit
import ApplicationServices
import AVFoundation
import MuseCore

/// Edit check (Mac CI, owner blocker 2026-11-07: the app crashed on opening Edit with real takes; the crash was the waveform
/// reader on real AAC sound). In review mode only: makes real MP4s shaped like live takes (48 kHz stereo and 44.1 kHz mono
/// AAC, one without sound, odd frame rates, a rotated file, a 15 s take trimmed to 8 s), checks their waveforms, puts
/// them in the demo store as takes with the missing or zero facts the server can send (durationSec / width / height null
/// or 0, a suite look), and opens each path into editing: the Edit home, the Edit suite on each take, and the older
/// editor from the Library. Every step is written to `edit-check.txt` before it runs and flushed, so a crash leaves the
/// last `START` line pointing at it; CI fails unless the file ends with `ALL DONE`.
extension SnapshotRunner {
    static func editCheck(_ store: AppStore, dir: URL) async {
        let log = dir.appendingPathComponent("edit-check.txt")
        try? Data().write(to: log)
        func note(_ s: String) {
            guard let h = try? FileHandle(forWritingTo: log) else { return }
            h.seekToEndOfFile()
            h.write(Data((s + "\n").utf8))
            try? h.synchronize()
            try? h.close()
            print("edit-check: \(s)")
        }
        let media = FileManager.default.temporaryDirectory.appendingPathComponent("MUSE-edit-check", isDirectory: true)
        try? FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let short = media.appendingPathComponent("short.mp4"), long = media.appendingPathComponent("long.mp4"), turned = media.appendingPathComponent("turned.mp4")
        do {
            // Live takes have real AAC sound (owner crash 2026-11-07: the waveform reader raised on 44.1 / 48 kHz AAC).
            try await makeVideo(short, seconds: 3, fps: 24, width: 360, height: 640, audio: (44_100, 1))
            try await makeVideo(long, seconds: 15, fps: 30, width: 432, height: 768, audio: (48_000, 2))
            try await makeVideo(turned, seconds: 4, fps: 25, width: 640, height: 360, rotated: true)
            note("MADE videos")
        } catch {
            note("FAIL making the test videos: \(error.localizedDescription)")
            return
        }
        // The crash's own path, on its own: waveforms of the files with sound must come back, and the silent one empty.
        for (name, url, sound) in [("mono_44k", short, true), ("stereo_48k", long, true), ("silent", turned, false)] {
            note("START waveform_\(name)")
            let w = await EditSuiteMedia.waveform(url)
            if sound && (w.isEmpty || (w.max() ?? 0) <= 0) { note("FAIL waveform_\(name): no peaks (\(w.count))") }
            else if !sound && !w.isEmpty { note("FAIL waveform_\(name): peaks without sound") }
            else { note("DONE waveform_\(name) (\(w.count) peaks)") }
        }
        await matteRenderCheck(short, media: media, note: note)
        let lut = store.suite.camera.palettes.first { ($0.lut ?? "").isEmpty == false }
        let look: [String: Any] = ["id": lut?.id ?? "teal_orange", "kind": "palette", "label": lut?.label ?? "Teal & orange", "lut": lut?.lut ?? "pack:teal-orange"]
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let raw: [[String: Any]] = [
            ["id": "rx_null", "kind": "take", "title": "Facts missing", "videoUrl": short.absoluteString, "createdAt": now, "look": look],
            ["id": "rx_zero", "kind": "take", "title": "Facts zero", "videoUrl": long.absoluteString, "durationSec": 0, "width": 0, "height": 0, "fps": 0, "createdAt": now - 1],
            ["id": "rx_turned", "kind": "take", "title": "Rotated", "videoUrl": turned.absoluteString, "durationSec": 4, "width": 640, "height": 360, "createdAt": now - 2, "look": look],
            ["id": "rx_trim", "kind": "edit", "title": "Trimmed to 8 s", "videoUrl": long.absoluteString, "parentTakeId": "rx_zero", "durationSec": 8, "createdAt": now - 3,
             "edits": ["version": 1, "sourceTakeId": "rx_zero", "sourceDurationSec": 15, "segments": [["inSec": 0, "outSec": 8, "speed": 1]], "mute": false]],
            ["id": "rx_full", "kind": "take", "title": "Real sound", "videoUrl": long.absoluteString, "durationSec": 15, "width": 432, "height": 768, "fps": 30,
             "createdAt": now - 5, "look": look],
            ["id": "rx_gone", "kind": "take", "title": "File missing", "videoUrl": media.appendingPathComponent("nope.mp4").absoluteString, "createdAt": now - 4],
        ]
        var made: [Take] = []
        for r in raw {
            guard let data = try? JSONSerialization.data(withJSONObject: r), let t = try? JSONDecoder().decode(Take.self, from: data) else {
                note("FAIL decoding take \(r["id"] ?? "?")")
                continue
            }
            made.append(t)
        }
        store.takes.removeAll { $0.id.hasPrefix("rx_") }
        store.takes.insert(contentsOf: made, at: 0)
        // The demo API must know them too, or every AI helper on them fails with "Take not found" (found 2026-11-08).
        await (store.api as? FakeMuseAPI)?.adoptTakes(made)

        func step(_ name: String, wait: Double, _ show: @MainActor () -> Void) async {
            note("START \(name)")
            show()
            try? await Task.sleep(for: .seconds(wait))
            capture(dir.appendingPathComponent("mac_edit_\(name).png"))
            note("DONE \(name)")
        }
        await step("home", wait: 3) { store.openEdit(takeId: nil) }
        for t in made {
            await step("suite_\(t.id)", wait: 9) { store.openEdit(takeId: t.id) }
            await step("suite_\(t.id)_home", wait: 2) { store.openEdit(takeId: nil) }
        }
        for t in made where t.id != "rx_gone" {
            await step("editor_\(t.id)", wait: 7) { store.openEditor(t) }
        }
        store.editor?.close()
        store.editor = nil
        // Every control of the Edit suite, on a take with real stereo AAC sound (owner crash 2026-11-08: Hook templates).
        await controlsCheck(store, takeId: "rx_full", note: note)
        // Real AI editing (2026-11-08): paid helpers ask first with their price; the guardrails' answers show at the button.
        await paidHelpersCheck(store, takeId: "rx_full", note: note)
        store.takes.removeAll { $0.id.hasPrefix("rx_") }
        store.go(.home)
        // Round 2's new screens (outfit full view, Settings, the model picker): every control pressed once.
        await screensWalk(store, note: note)
        note("ALL DONE")
    }

    /// A short H.264 MP4: grey frames that change brightness (so strips differ). `rotated` stores it landscape with a 90°
    /// preferredTransform, as some phone files are. `audio` (sample rate, channels) adds an AAC track of a rising tone.
    static func makeVideo(_ url: URL, seconds: Double, fps: Int32, width w: Int, height h: Int, rotated: Bool = false,
                          audio: (rate: Double, channels: Int)? = nil) async throws {
        try? FileManager.default.removeItem(at: url)
        guard let audio else { return try await writeFrames(url, seconds: seconds, fps: fps, width: w, height: h, rotated: rotated) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("MUSE-edit-check", isDirectory: true)
        let silent = tmp.appendingPathComponent("v-\(UUID().uuidString).mp4"), sound = tmp.appendingPathComponent("a-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: silent); try? FileManager.default.removeItem(at: sound) }
        try await writeFrames(silent, seconds: seconds, fps: fps, width: w, height: h, rotated: rotated)
        try writeTone(sound, seconds: seconds, rate: audio.rate, channels: audio.channels)
        // Video and sound into one MP4, as the providers deliver them (no re-encode).
        let comp = AVMutableComposition()
        let va = AVURLAsset(url: silent), aa = AVURLAsset(url: sound)
        guard let vSrc = try await va.loadTracks(withMediaType: .video).first, let aSrc = try await aa.loadTracks(withMediaType: .audio).first,
              let vT = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let aT = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ApiError("edit_check", "Couldn't mux the test video")
        }
        let vDur = try await va.load(.duration), aDur = try await aa.load(.duration)
        try vT.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: vSrc, at: .zero)
        vT.preferredTransform = try await vSrc.load(.preferredTransform)
        try aT.insertTimeRange(CMTimeRange(start: .zero, duration: min(vDur, aDur)), of: aSrc, at: .zero)
        guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { throw ApiError("edit_check", "Couldn't mux the test video") }
        ex.outputURL = url
        ex.outputFileType = .mp4
        await ex.export()
        if ex.status != .completed { throw ex.error ?? ApiError("edit_check", "Couldn't mux the test video") }
    }

    /// An AAC .m4a of a tone that rises in volume (so the waveform has a shape).
    static func writeTone(_ url: URL, seconds: Double, rate: Double, channels: Int) throws {
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels)),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(seconds * rate)), let data = buf.floatChannelData else {
            throw ApiError("edit_check", "Couldn't make the test sound")
        }
        buf.frameLength = buf.frameCapacity
        let n = Int(buf.frameLength)
        for c in 0..<channels {
            for i in 0..<n { data[c][i] = Float(sin(2 * Double.pi * 440 * Double(i) / rate) * 0.8 * Double(i) / Double(n)) }
        }
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                                              AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 96_000])
        try file.write(from: buf)
    }

    static func writeFrames(_ url: URL, seconds: Double, fps: Int32, width w: Int, height h: Int, rotated: Bool, split: Bool = false) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        input.expectsMediaDataInRealTime = false
        if rotated { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ApiError("edit_check", "Couldn't start the test video") }
        writer.startSession(atSourceTime: .zero)
        let frames = Int(seconds * Double(fps))
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { break }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let row = CVPixelBufferGetBytesPerRow(pb)
                if split {
                    // A matte: the left half white (keep), the right half black.
                    for y in 0..<h { memset(base + y * row, 255, w / 2 * 4); memset(base + y * row + w / 2 * 4, 0, row - w / 2 * 4) }
                } else {
                    memset(base, Int32(40 + (i * 7) % 180), row * h)
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? ApiError("edit_check", "Couldn't write the test video") }
    }

    // MARK: Paid AI helpers (2026-11-08): confirm with the price, and the guardrails' answers

    /// With the fake priced (no money moves), a paid helper waits for the owner: Cancel starts nothing, Run starts it and its
    /// result lands. With paid helpers switched off, the helpers are unavailable with the reason; with today's cap reached,
    /// the refusal shows at the helper.
    static func paidHelpersCheck(_ store: AppStore, takeId: String, note: (String) -> Void) async {
        note("START paid_helpers")
        guard let fake = store.api as? FakeMuseAPI else { note("DONE paid_helpers (skipped: not the demo API)"); return }
        guard let s = store.makeEditSuiteSession(takeId: takeId) else { note("FAIL paid_helpers: no session for \(takeId)"); return }
        defer { s.close() }
        await s.load()
        guard s.isReady else { note("FAIL paid_helpers: the edit didn't open"); return }
        await fake.setEditorGuardrails(priceUsd: 0.05)
        await s.autoCaptions()
        guard let ask = s.paidAsk else { note("FAIL paid_helpers: a priced helper started without asking (last error: \(s.lastError ?? "none"), job: \(s.jobs[.captions]?.state ?? "none"))"); await fake.setEditorGuardrails(); return }
        if ask.title != "Auto-captions" || !ask.price.contains("0.05") { note("FAIL paid_helpers: asked \(ask.title) · \(ask.price)") }
        s.cancelPaid()
        if s.paidAsk != nil || s.jobs[.captions] != nil { note("FAIL paid_helpers: Cancel started the helper") }
        await s.autoCaptions()
        s.confirmPaid()
        for _ in 0..<100 where s.project.captionTrack == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard s.project.captionTrack != nil else { note("FAIL paid_helpers: Run didn't add the captions"); await fake.setEditorGuardrails(); return }
        // Today's cap reached: the refusal shows at the helper, nothing asks.
        await fake.setEditorGuardrails(priceUsd: 0.05, capHit: true)
        await s.autoCaptions()
        if s.paidAsk != nil { note("FAIL paid_helpers: asked although today's cap is reached") }
        if !(s.helperNote(.captions) ?? "").contains("limit") { note("FAIL paid_helpers: no cap note at the button (\(s.helperNote(.captions) ?? "none"))") }
        // Paid helpers switched off: unavailable, with the reason.
        await fake.setEditorGuardrails(priceUsd: 0.05, paidOff: true)
        await s.refreshFeatures()
        if s.helperAvailable(.captions) || s.helperAvailable(.matte) || s.helperAvailable(.denoise) { note("FAIL paid_helpers: helpers still offered while switched off") }
        if !(s.helperNote(.denoise) ?? "").contains("switched off") { note("FAIL paid_helpers: no switched-off reason (\(s.helperNote(.denoise) ?? "none"))") }
        if !s.helperAvailable(.beats) { note("FAIL paid_helpers: the free beat detection went too") }
        await fake.setEditorGuardrails()
        note("DONE paid_helpers")
    }

    // MARK: Remove background (2026-11-08): the alpha matte in the real renderer

    /// A clip with an alpha matte whose left half is white and right half black, on a red canvas: the left of the frame must
    /// show the clip and the right the canvas.
    static func matteRenderCheck(_ clip: URL, media: URL, note: (String) -> Void) async {
        note("START matte_render")
        let matte = media.appendingPathComponent("matte.mp4")
        do {
            try await writeFrames(matte, seconds: 3, fps: 24, width: 360, height: 640, rotated: false, split: true)
            var p = EditV2.fromV1(EditList(sourceTakeId: "rx_matte", sourceDurationSec: 3), EditV2.SourceFacts(width: 360, height: 640, fps: 24))
            p.canvas.background = "#FF0000"
            p = p.addingAsset(EditV2.Asset(id: "bg2", kind: .video, upload: "up_matte", durationSec: 3, width: 360, height: 640, hasAudio: false))
            guard let matted = p.updating("c1", { it in
                guard case .video(var v) = it else { return }
                v.alphaMatte = EditV2.AlphaMatte(asset: "bg2")
                it = .video(v)
            }) else { note("FAIL matte_render: couldn't set the matte"); return }
            let sources = try await EditV2Engine.load(matted, files: ["src": clip, "bg2": matte])
            let built = try EditV2Engine.build(matted, sources: sources)
            let gen = AVAssetImageGenerator(asset: built.composition)
            gen.videoComposition = built.videoComposition
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            let cg = try await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
            guard let left = pixel(cg, 0.25, 0.5), let right = pixel(cg, 0.75, 0.5) else { note("FAIL matte_render: couldn't read the frame"); return }
            let kept = abs(left.r - left.g) < 40 && abs(left.g - left.b) < 40   // the grey clip
            let cut = right.r > 180 && right.g < 70 && right.b < 70             // the red canvas
            if kept && cut { note("DONE matte_render (left \(left), right \(right))") }
            else { note("FAIL matte_render: left \(left) should be the clip (grey), right \(right) the canvas (red)") }
        } catch {
            note("FAIL matte_render: \(error.localizedDescription)")
        }
    }

    /// The colour at (x, y), 0–1 from the top left, as 0–255 sRGB.
    static func pixel(_ img: CGImage, _ x: Double, _ y: Double) -> (r: Int, g: Int, b: Int)? {
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let w = CGFloat(img.width), h = CGFloat(img.height)
        // Draw the image so the wanted pixel lands on the 1×1 context (CG's origin is bottom left).
        ctx.draw(img, in: CGRect(x: -CGFloat(x) * w, y: -(1 - CGFloat(y)) * h, width: w, height: h))
        return (Int(px[0]), Int(px[1]), Int(px[2]))
    }

    // MARK: Every control (owner request 2026-11-08: "vet the entire Edit function")

    /// Presses every button, checkbox, tab and radio button of the Edit suite, and nudges every slider one step, through the
    /// Accessibility API on this app's own process (AXUIElementCreateApplication(getpid()), queried
    /// on the main actor, as the AX API runs own-process requests inline): each control's real action runs, closures and all. SwiftUI only builds its
    /// accessibility tree for an accessibility client, so in-process NSAccessibility calls see an empty window.
    /// It explores as panels appear (a tab press reveals its panel), works inside sheets and closes them, and comes back if a
    /// control leaves the editor. Each control is logged before it is used. Skipped on purpose (logged as SKIP): controls
    /// that open a blocking system panel (file import, the save panel behind the sheet's Export, the microphone) and menus.
    /// The editor's own close button: present exactly while the editor is open.
    static let editorMarker = "Close the editor"

    static func controlsCheck(_ store: AppStore, takeId: String, note: (String) -> Void) async {
        note("START controls \(takeId)")
        let ax = AXWalker()
        note("AX trusted \(AXIsProcessTrusted())")
        // The app's own chrome (sidebar, title bar, theme switcher) is not the Edit suite: what's there before the editor opens
        // is skipped, so the walk stays inside Edit.
        store.openEdit(takeId: nil)
        try? await Task.sleep(for: .seconds(1.5))
        let home = await ax.controls().controls
        let chrome = Set(home.map(\.key))
        note("CHROME \(chrome.count) controls outside the editor are skipped")
        // The Recreate entry on the Edit home (plans/recreate): pressed like a person would, its start page shown, then back.
        // Its own page isn't walked: choosing a video opens a modal file panel.
        if let r = home.first(where: { $0.label == "Recreate an edit" }) {
            note("PRESS \(r.role) \(r.label)")
            await ax.press(r)
            try? await Task.sleep(for: .seconds(2.5))
            capture(SnapshotRunner.dir!.appendingPathComponent("mac_edit_recreate_entry.png"))
            note("DONE recreate entry (screen \(store.screen))")
            store.openEdit(takeId: nil)
            try? await Task.sleep(for: .seconds(1.5))
        } else {
            note("FAIL controls: no \"Recreate an edit\" on the Edit home")
        }
        store.openEdit(takeId: takeId)
        var ready = false
        for _ in 0..<50 {
            try? await Task.sleep(for: .seconds(0.5))
            let found = await ax.find(editorMarker)
            if store.screen == .edit, found { ready = true; break }
        }
        capture(SnapshotRunner.dir!.appendingPathComponent("mac_edit_controls_start.png"))
        let st = await ax.stats()
        note("AX nodes \(st.nodes), actionable \(st.actionable), error \(st.error), screen \(store.screen), sample: \(st.sample)")
        guard ready else { note("FAIL controls: the editor (\(editorMarker)) never appeared to accessibility on \(takeId)"); return }
        let deny: Set<String> = ["Import", ".cube import", "Import video or picture", "Import picture", "Import music", "Import sound", "Record a voice-over", "Stop recording the voice-over", "Record VO",
                                 "Back", "Close the editor", "Translate…",
                                 // The Claude chat's "+" opens a file panel (a modal that would stop the walk).
                                 "Attach images",
                                 // A full-screen window over the app (checked on its own in the Edit operations check).
                                 "Full screen preview (Esc to leave)", "Save this frame as a picture",
                                 // Paid helpers (2026-11-08: the walk skips anything that spends): background removal, tap to keep's run.
                                 "Remove background", "Run the cut-out",
                                 // The shared link import sheet (WS6) has its own walk (SnapshotRunner+Walk.swift).
                                 "Import a video from a link",
                                 // Asks first (its own Keep / Delete kit dialog).
                                 "Delete style kit"]
        let denyInSheet: Set<String> = ["Export", "Save to Library", "Save GIF…", "Save sound…"]
        let closers = ["Close", "Cancel", "Use the latest", "Keep this device's changes", "Done"]
        var used = Set<String>(), skipped = Set<String>(), left = Set<String>()
        var presses = 0, nudges = 0
        func inEditor() async -> Bool {
            guard store.screen == .edit else { return false }
            return await ax.find(editorMarker)
        }
        // Depth first: the controls a press reveals (a tab's panel, captions mode's hook templates) are used before anything
        // else, newest group first, so a later mode switch can't hide them before they are reached.
        var groups: [[String]] = []
        var lastSeen = Set<String>()
        for _ in 0..<900 {
            let scan = await ax.controls()
            let inSheet = scan.inSheet
            func usable(_ c: AXWalker.Control) -> Bool {
                let key = (inSheet ? "sheet:" : "") + c.key
                if used.contains(key) || skipped.contains(c.key) || left.contains(c.key) || (!inSheet && chrome.contains(c.key)) { return false }
                if deny.contains(c.label) || (inSheet && denyInSheet.contains(c.label)) || c.isMenu {
                    skipped.insert(c.key)
                    note("SKIP \(c.role) \(c.label)")
                    return false
                }
                return true
            }
            let keys = scan.controls.map(\.key)
            let fresh = keys.filter { !lastSeen.contains($0) }
            if !lastSeen.isEmpty, !fresh.isEmpty { groups.append(fresh) }
            lastSeen = Set(keys)
            var pick: AXWalker.Control?
            while pick == nil, let g = groups.last {
                let want = Set(g)
                // Bottom-up within a group: a panel's contents (hook templates, caption styles) come after the mode switch
                // that revealed them in tree order, and must be used before it can switch the mode back.
                pick = scan.controls.last { want.contains($0.key) && usable($0) }
                if pick == nil { groups.removeLast() }
            }
            if pick == nil { pick = scan.controls.first(where: usable) }
            guard let c = pick else {
                if inSheet {
                    note("CLOSE sheet")
                    if let close = scan.controls.first(where: { closers.contains($0.label) }) { await ax.press(close) }
                    try? await Task.sleep(for: .seconds(0.8))
                    let stillSheet = await ax.controls().inSheet
                    if stillSheet, let w = mainWindow, let sh = w.attachedSheet { w.endSheet(sh) }
                    try? await Task.sleep(for: .seconds(0.4))
                    continue
                }
                break
            }
            used.insert((inSheet ? "sheet:" : "") + c.key)
            note("\(c.isSlider ? "NUDGE" : "PRESS") \(c.role) \(c.label)")
            if c.isSlider { await ax.increment(c); nudges += 1 } else { await ax.press(c); presses += 1 }
            try? await Task.sleep(for: .seconds(0.45))
            let stillIn = await inEditor()
            if mainWindow?.attachedSheet == nil, !stillIn {
                left.insert(c.key)
                note("LEFT the editor via \(c.label); reopening")
                store.openEdit(takeId: nil)
                try? await Task.sleep(for: .seconds(0.5))
                store.openEdit(takeId: takeId)
                var back = false
                for _ in 0..<40 {
                    try? await Task.sleep(for: .seconds(0.5))
                    let ok = await inEditor()
                    if ok { back = true; break }
                }
                if !back { note("FAIL controls: couldn't get back into the editor"); return }
            }
        }
        note("CONTROLS pressed \(presses), sliders nudged \(nudges), skipped \(skipped.count), left the editor via \(left.count)")
        if presses + nudges < 40 { note("FAIL controls: only \(presses + nudges) controls found") }
        // The owner's crashes must stay covered: the hook templates (exclusivity, 2026-11-08).
        if !used.contains(where: { $0.contains("Add hook") }) { note("FAIL controls: no hook template was pressed (Hook ideas → Add hook …)") }
        // Remove background → Pick what to keep: the picker opened and a point was tapped on its frame.
        if !used.contains(where: { $0.contains("Pick what to keep") }) { note("FAIL controls: \"Pick what to keep\" was never pressed (Video → Mask & green screen)") }
        if !used.contains(where: { $0.contains("Frame · tap what to keep") }) { note("FAIL controls: no point was tapped on the keep picker's frame") }
        if let w = mainWindow, let sh = w.attachedSheet { w.endSheet(sh) }
        store.openEdit(takeId: nil)
        try? await Task.sleep(for: .seconds(1))
        note("DONE controls \(takeId)")
    }
}

/// An Accessibility API client on this app's own process. For its own process the AX API runs each request inline on the
/// calling thread (no round trip), and SwiftUI's actions assert the main actor, so every call runs on the main actor.
@MainActor
final class AXWalker {
    struct Control: @unchecked Sendable {
        let element: AXUIElement
        let role: String
        let label: String
        /// History entries undo into "Undo: Undo: …" entries; the same control however deep the chain goes.
        var key: String { "\(role)|\(label.replacingOccurrences(of: "Undo: ", with: ""))" }
        var isSlider: Bool { role == "AXSlider" }
        var isMenu: Bool { role == "AXPopUpButton" || role == "AXMenuButton" }
    }
    private let app: AXUIElement
    static let actionable: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXPopUpButton", "AXMenuButton", "AXDisclosureTriangle"]

    init() {
        app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 3)
    }

    private func value(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }
    private func string(_ e: AXUIElement, _ a: String) -> String? { (value(e, a) as? String).flatMap { $0.isEmpty ? nil : $0 } }
    private func children(_ e: AXUIElement) -> [AXUIElement] { (value(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
    /// The main window, or its sheet when one is up.
    private func root() -> (AXUIElement?, Bool) {
        guard let w = value(app, kAXMainWindowAttribute) ?? value(app, kAXFocusedWindowAttribute) else { return (nil, false) }
        let win = w as! AXUIElement
        if let sheets = value(win, "AXSheets") as? [AXUIElement], let s = sheets.first { return (s, true) }
        return (win, false)
    }
    private func walk(_ e: AXUIElement, _ depth: Int, _ visit: (AXUIElement) -> Bool) {
        guard depth < 90, visit(e) else { return }
        for k in children(e) { walk(k, depth + 1, visit) }
    }

    func controls() async -> (controls: [Control], inSheet: Bool) {
        do {
            let (r, sheet) = root()
            guard let r else { return ([], false) }
            var out: [Control] = []
            walk(r, 0) { e in
                if let role = string(e, kAXRoleAttribute), Self.actionable.contains(role), (value(e, kAXEnabledAttribute) as? Bool) ?? true,
                   let label = string(e, kAXDescriptionAttribute) ?? string(e, kAXTitleAttribute) ?? string(e, kAXHelpAttribute) {
                    out.append(Control(element: e, role: role, label: label))
                }
                return true
            }
            return (out, sheet)
        }
    }

    func find(_ label: String) async -> Bool {
        do {
            guard let r = root().0 else { return false }
            var found = false
            walk(r, 0) { e in
                if found { return false }
                if string(e, kAXDescriptionAttribute) == label || string(e, kAXTitleAttribute) == label { found = true; return false }
                return true
            }
            return found
        }
    }

    func press(_ c: Control) async { _ = AXUIElementPerformAction(c.element, kAXPressAction as CFString) }
    func increment(_ c: Control) async { _ = AXUIElementPerformAction(c.element, kAXIncrementAction as CFString) }

    func stats() async -> (nodes: Int, actionable: Int, error: String, sample: String) {
        do {
            var v: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v)
            guard let r = root().0 else { return (0, 0, "\(err.rawValue)", "") }
            var nodes = 0, act = 0
            var sample: [String] = []
            walk(r, 0) { e in
                nodes += 1
                let role = string(e, kAXRoleAttribute) ?? "-"
                if Self.actionable.contains(role) { act += 1 }
                if sample.count < 25, let l = string(e, kAXDescriptionAttribute) ?? string(e, kAXTitleAttribute) { sample.append("\(role):\(l.prefix(24))") }
                return true
            }
            return (nodes, act, "\(err.rawValue)", sample.joined(separator: " | "))
        }
    }
}

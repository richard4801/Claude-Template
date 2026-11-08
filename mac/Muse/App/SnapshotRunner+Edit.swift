import AppKit
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
        store.takes.removeAll { $0.id.hasPrefix("rx_") }
        store.go(.home)
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

    static func writeFrames(_ url: URL, seconds: Double, fps: Int32, width w: Int, height h: Int, rotated: Bool) async throws {
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
            if let base = CVPixelBufferGetBaseAddress(pb) { memset(base, Int32(40 + (i * 7) % 180), CVPixelBufferGetBytesPerRow(pb) * h) }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? ApiError("edit_check", "Couldn't write the test video") }
    }

    // MARK: Every control (owner request 2026-11-08: "vet the entire Edit function")

    /// Presses every button, checkbox, tab and radio button of the Edit suite, and nudges every slider one step, through the
    /// app's own accessibility tree (so each control's real action runs, closures and all). It explores as panels appear
    /// (a tab press reveals its panel's controls), handles sheets (works inside them, then closes them) and comes back if
    /// a control leaves the editor. Each control is logged before it is used. Skipped on purpose, and logged as SKIP:
    /// controls that open a blocking system panel (file import, the save panel behind the sheet's Export, the microphone)
    /// and menus (their tracking loop would block this run).
    static func controlsCheck(_ store: AppStore, takeId: String, note: (String) -> Void) async {
        note("START controls \(takeId)")
        store.openEdit(takeId: takeId)
        try? await Task.sleep(for: .seconds(9))
        let deny = ["Import", ".cube import", "Import music", "Import sound", "Record a voice-over", "Stop recording the voice-over", "Record VO",
                    "Back", "Close editor", "Translate…"]
        let denyInSheet = ["Export", "Save to Library"]
        var used = Set<String>(), skipped = Set<String>(), left = Set<String>()
        var presses = 0, nudges = 0
        func inEditor() -> Bool { store.screen == .edit && axFind(mainWindow?.contentView, label: "Timeline ruler") }
        guard inEditor() else { note("FAIL controls: the editor didn't open on \(takeId)"); return }
        for _ in 0..<600 {
            guard let w = mainWindow else { break }
            let sheet = w.attachedSheet
            let root: NSView? = sheet?.contentView ?? w.contentView
            let all = axControls(root)
            let next = all.first { c in
                let key = (sheet == nil ? "" : "sheet:") + c.key
                if used.contains(key) || skipped.contains(c.key) || left.contains(c.key) { return false }
                if deny.contains(where: { c.label == $0 }) || (sheet != nil && denyInSheet.contains(c.label)) || c.isMenu {
                    if !skipped.contains(c.key) { skipped.insert(c.key); note("SKIP \(c.role) \(c.label)") }
                    return false
                }
                return true
            }
            guard let c = next else {
                if let sheet {
                    // Done with this sheet: close it like a person would.
                    note("CLOSE sheet")
                    if let close = all.first(where: { ["Close", "Cancel", "Use the latest", "Keep this device's changes", "Done"].contains($0.label) }) {
                        _ = close.press()
                    } else { w.endSheet(sheet) }
                    try? await Task.sleep(for: .seconds(0.8))
                    if w.attachedSheet === sheet { w.endSheet(sheet) }
                    continue
                }
                break
            }
            let key = (sheet == nil ? "" : "sheet:") + c.key
            used.insert(key)
            note("\(c.isSlider ? "NUDGE" : "PRESS") \(c.role) \(c.label)")
            if c.isSlider { _ = c.increment(); nudges += 1 } else { _ = c.press(); presses += 1 }
            try? await Task.sleep(for: .seconds(0.45))
            // A control that leaves the editor (navigation): note it, never press it again, and come back.
            if mainWindow?.attachedSheet == nil, !inEditor() {
                left.insert(c.key)
                note("LEFT the editor via \(c.label); reopening")
                store.openEdit(takeId: nil)
                try? await Task.sleep(for: .seconds(0.5))
                store.openEdit(takeId: takeId)
                try? await Task.sleep(for: .seconds(8))
                if !inEditor() { note("FAIL controls: couldn't get back into the editor"); return }
            }
        }
        note("CONTROLS pressed \(presses), sliders nudged \(nudges), skipped \(skipped.count), left the editor via \(left.count)")
        // The tree must really have been walked: the Edit suite has well over 40 controls across its tabs.
        if presses + nudges < 40 { note("FAIL controls: only \(presses + nudges) controls found (accessibility tree not reachable?)") }
        if let s = mainWindow?.attachedSheet { mainWindow?.endSheet(s) }
        store.openEdit(takeId: nil)
        try? await Task.sleep(for: .seconds(1))
        note("DONE controls \(takeId)")
    }

    /// One actionable accessibility element.
    struct AXControl {
        let element: AnyObject
        let role: String
        let label: String
        var key: String { "\(role)|\(label)" }
        var isSlider: Bool { role == NSAccessibility.Role.slider.rawValue }
        var isMenu: Bool { role == NSAccessibility.Role.popUpButton.rawValue || role == NSAccessibility.Role.menuButton.rawValue }
        // Dynamic Objective-C calls: the accessibility methods exist on every AppKit / SwiftUI accessibility element.
        func press() -> Bool { element.accessibilityPerformPress?() ?? false }
        func increment() -> Bool { element.accessibilityPerformIncrement?() ?? false }
    }

    static let actionable: Set<NSAccessibility.Role> = [.button, .checkBox, .radioButton, .slider, .popUpButton, .menuButton, .disclosureTriangle]

    /// Every enabled actionable element under `root`, in tree order (labels from the label, title or help text).
    static func axControls(_ root: Any?) -> [AXControl] {
        var out: [AXControl] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ x: Any, _ depth: Int) {
            guard depth < 80 else { return }
            let e = x as AnyObject
            let id = ObjectIdentifier(e)
            guard !seen.contains(id) else { return }
            seen.insert(id)
            if let role = e.accessibilityRole?() ?? nil, actionable.contains(role), (e.isAccessibilityEnabled?() ?? true) {
                let label = [e.accessibilityLabel?() ?? nil, e.accessibilityTitle?() ?? nil, e.accessibilityHelp?() ?? nil].compactMap { $0 }.first { !$0.isEmpty } ?? ""
                if !label.isEmpty { out.append(AXControl(element: e, role: role.rawValue, label: label)) }
            }
            for k in (e.accessibilityChildren?() ?? nil) ?? [] { walk(k, depth + 1) }
        }
        if let root { walk(root, 0) }
        return out
    }

    /// Whether an element labelled `label` is under `root`.
    static func axFind(_ root: Any?, label: String) -> Bool {
        var found = false
        var seen = Set<ObjectIdentifier>()
        func walk(_ x: Any, _ depth: Int) {
            guard !found, depth < 80 else { return }
            let e = x as AnyObject
            let id = ObjectIdentifier(e)
            guard !seen.contains(id) else { return }
            seen.insert(id)
            if (e.accessibilityLabel?() ?? nil) == label { found = true; return }
            for k in (e.accessibilityChildren?() ?? nil) ?? [] { walk(k, depth + 1) }
        }
        if let root { walk(root, 0) }
        return found
    }
}

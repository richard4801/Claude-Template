import AppKit
import AVFoundation
import MuseCore

/// Edit check (Mac CI, owner blocker 2026-11-07: the app crashed on opening Edit with real takes). In review mode only: makes
/// real MP4s shaped like live takes (no audio track, odd frame rates, a rotated file, a 15 s take trimmed to 8 s), puts
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
            try await makeVideo(short, seconds: 3, fps: 24, width: 360, height: 640)
            try await makeVideo(long, seconds: 15, fps: 30, width: 432, height: 768)
            try await makeVideo(turned, seconds: 4, fps: 25, width: 640, height: 360, rotated: true)
            note("MADE videos")
        } catch {
            note("FAIL making the test videos: \(error.localizedDescription)")
            return
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
        store.takes.removeAll { $0.id.hasPrefix("rx_") }
        store.go(.home)
        note("ALL DONE")
    }

    /// A short H.264 MP4 with no audio track: grey frames that change brightness (so strips differ). `rotated` stores it
    /// landscape with a 90° preferredTransform, as some phone files are.
    static func makeVideo(_ url: URL, seconds: Double, fps: Int32, width w: Int, height h: Int, rotated: Bool = false) async throws {
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
}

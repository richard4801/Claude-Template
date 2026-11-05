import AVFoundation
import AppKit
import MuseCore
import Vision

/// Edit suite media helpers on the Mac: frames for the Looks thumbnails and the timeline, audio waveforms, face framing for
/// re-shaping (Vision), and the .srt sidecar.
enum EditSuiteMedia {
    /// A local copy of a source (downloaded once per key into the temporary folder; file URLs are used as they are).
    static func localCopy(_ src: URL, key: String) async throws -> URL {
        if src.isFileURL { return src }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("MUSE-edit", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = key.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        let ext = src.pathExtension.isEmpty ? "mp4" : src.pathExtension
        let dst = dir.appendingPathComponent("src-\(safe.isEmpty ? "media" : safe)").appendingPathExtension(ext)
        if fm.fileExists(atPath: dst.path) { return dst }
        let tmp: URL
        do {
            tmp = try await URLSession.shared.download(from: src).0
        } catch {
            throw ApiError("download_failed", "Couldn't download the video")
        }
        try? fm.removeItem(at: dst)
        try fm.moveItem(at: tmp, to: dst)
        return dst
    }

    /// One frame of a video file at `t` source seconds (upright), at most `maxSide` px.
    static func frame(_ url: URL, at t: Double, maxSide: CGFloat = 640) async -> CGImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxSide, height: maxSide)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        return try? await gen.image(at: CMTime(seconds: max(0, t), preferredTimescale: 600)).image
    }

    /// `count` frames spread evenly over a file's length, for the timeline's clip strips.
    static func strip(_ url: URL, count: Int, height: CGFloat = 48) async -> [CGImage] {
        let a = AVURLAsset(url: url)
        guard let d = try? await a.load(.duration).seconds, d.isFinite, d > 0 else { return [] }
        return await VideoEditEngine.thumbnails(a, duration: d, count: count, height: height).map(\.1)
    }

    /// Peak levels (0…1) of a file's sound in `count` equal slices of its whole length; empty without sound.
    static func waveform(_ url: URL, count: Int = 400) async -> [Float] {
        await Task.detached(priority: .utility) { () -> [Float] in
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return [] }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 2000,
            ]
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            guard reader.canAdd(out) else { return [] }
            reader.add(out)
            guard reader.startReading() else { return [] }
            var samples: [Int16] = []
            while let sb = out.copyNextSampleBuffer() {
                guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
                let len = CMBlockBufferGetDataLength(bb) / 2 * 2
                var chunk = [Int16](repeating: 0, count: len / 2)
                _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
                samples += chunk
            }
            guard !samples.isEmpty, count > 0 else { return [] }
            let per = max(1, samples.count / count)
            var peaks: [Float] = []
            var i = 0
            while i < samples.count && peaks.count < count {
                let end = min(samples.count, i + per)
                var m: Int32 = 0
                for k in i..<end { m = max(m, abs(Int32(samples[k]))) }
                peaks.append(Float(m) / 32768)
                i = end
            }
            let top = max(0.05, peaks.max() ?? 1)
            return peaks.map { min(1, $0 / top) }
        }.value
    }

    /// Where the largest face is across a frame of the file at `t` (0 = left edge, 1 = right edge), or nil.
    static func faceCentreX(_ url: URL, at t: Double) async -> Double? {
        guard let cg = await frame(url, at: t, maxSide: 720) else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> Double? in
            let req = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            guard (try? handler.perform([req])) != nil, let faces = req.results, !faces.isEmpty else { return nil }
            let big = faces.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
            return big.map { Double($0.boundingBox.midX) }
        }.value
    }

    /// Face framing for every main clip (by clip id), for EditSuiteState.setRatio.
    static func framing(_ p: EditV2.Project, files: [String: URL]) async -> [String: Double] {
        var out: [String: Double] = [:]
        for c in p.mainClips {
            guard let url = files[c.asset] else { continue }
            if let x = await faceCentreX(url, at: (c.inSec + c.outSec) / 2) { out[c.id] = x }
        }
        return out
    }

    /// Writes the captions as an .srt next to `video` (same name). Returns its URL, or nil without captions.
    @discardableResult
    static func writeSrt(_ p: EditV2.Project, nextTo video: URL) throws -> URL? {
        let text = EditV2.toSrt(p)
        guard !text.isEmpty else { return nil }
        let url = video.deletingPathExtension().appendingPathExtension("srt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

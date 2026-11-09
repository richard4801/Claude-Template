import AVFoundation
import CoreAudio
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

    /// A file's frame at source time `t`, small (at most `size` px), as straight sRGB r, g, b, … 0–1: what auto adjust reads.
    static func frameRGB(_ url: URL, at t: Double, size: Int = 96) async -> [Double]? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: size, height: size)
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        guard let cg = try? await gen.image(at: CMTime(seconds: max(0, t), preferredTimescale: 600)).image else { return nil }
        let w = max(1, cg.width), h = max(1, cg.height)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out = [Double](); out.reserveCapacity(w * h * 3)
        for i in 0..<(w * h) { for c in 0..<3 { out.append(Double(px[i * 4 + c]) / 255) } }
        return out
    }

    // MARK: The Mac's sound output (recording a voice-over over playback)

    private static func outputProperty<T>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
                                          _ initial: T) -> T? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static var defaultOutput: AudioObjectID? {
        outputProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal,
                       AudioObjectID(0)).flatMap { $0 == 0 ? nil : $0 }
    }

    /// Whether the sound goes somewhere the microphone won't hear it: headphones, Bluetooth or USB (the design pass: playing
    /// the video while recording is on by default only then).
    static var outputIsPrivate: Bool {
        guard let dev = defaultOutput else { return false }
        let transport = outputProperty(dev, kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0
        if [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeUSB].contains(transport) { return true }
        // The built-in jack: its data source says headphones ('hdpn').
        let source = outputProperty(dev, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput, UInt32(0)) ?? 0
        return source == 0x6864_706E
    }

    /// How late the Mac's sound output plays what it's given, in seconds (device + safety offset + stream latency + one
    /// buffer): a voice-over recorded over playback is shifted by this, so lips stay in sync on Bluetooth.
    static var outputLatencySec: Double {
        guard let dev = defaultOutput else { return 0 }
        let rate = outputProperty(dev, kAudioDevicePropertyNominalSampleRate, scope: kAudioObjectPropertyScopeGlobal, Float64(0)) ?? 0
        guard rate > 0 else { return 0 }
        let out = kAudioDevicePropertyScopeOutput
        var frames = Double(outputProperty(dev, kAudioDevicePropertyLatency, scope: out, UInt32(0)) ?? 0)
        frames += Double(outputProperty(dev, kAudioDevicePropertySafetyOffset, scope: out, UInt32(0)) ?? 0)
        frames += Double(outputProperty(dev, kAudioDevicePropertyBufferFrameSize, scope: out, UInt32(0)) ?? 0)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: out, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioStreamID>.size) {
            var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &streams) == noErr, let first = streams.first, first != 0 {
                frames += Double(outputProperty(first, kAudioStreamPropertyLatency, scope: kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0)
            }
        }
        return min(0.5, frames / rate)
    }

    /// What the waveform asks the reader for: 16-bit little-endian interleaved PCM at the track's own sample rate and channel
    /// count. Never a sample rate or channel count: the reader's converter raises an uncatchable exception on ones it can't do.
    static let pcmReaderSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
    ]

    /// Peak levels (0…1) of a file's sound in `count` equal slices of its whole length; empty without sound.
    ///
    /// Owner crash 2026-11-07: asking the reader to resample to 2 kHz mono made `AVAssetReaderTrackOutput` raise an
    /// Objective-C exception on real AAC takes (44.1 / 48 kHz stereo), which Swift can't catch. The reader now decodes to
    /// 16-bit PCM at the track's own rate and channels (`pcmReaderSettings`: no rate, no channel count), and
    /// the down-mix (loudest channel) and the slicing happen here (`EditSuite.Peaks`, tested in MuseCore).
    static func waveform(_ url: URL, count: Int = 400) async -> [Float] {
        await Task.detached(priority: .utility) { () -> [Float] in
            guard count > 0 else { return [] }
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let formats = try? await track.load(.formatDescriptions), !formats.isEmpty,
                  let reader = try? AVAssetReader(asset: asset) else { return [] }
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: pcmReaderSettings)
            out.alwaysCopiesSampleData = false
            guard reader.canAdd(out) else { return [] }
            reader.add(out)
            guard reader.startReading() else { return [] }
            var peaks = EditSuite.Peaks()
            while let sb = out.copyNextSampleBuffer() {
                guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
                var channels = 1
                if let fd = CMSampleBufferGetFormatDescription(sb), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
                    channels = max(1, Int(asbd.mChannelsPerFrame))
                }
                let len = CMBlockBufferGetDataLength(bb) / 2 * 2
                guard len > 0 else { continue }
                var chunk = [Int16](repeating: 0, count: len / 2)
                let ok = chunk.withUnsafeMutableBytes { raw -> Bool in
                    guard let base = raw.baseAddress else { return false }
                    return CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: base) == kCMBlockBufferNoErr
                }
                if ok { peaks.add(interleaved: chunk, channels: channels) }
            }
            if reader.status == .failed { return [] }
            return peaks.slices(count)
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

    /// Auto reframe (XL): the face to follow in a clip, five times a second (at most 300 frames, decoded at 480 px), as
    /// Android's Reframe.kt: the largest face first, then the one nearest the last (|Δx| + 0.5 · (1 − width)); a frame
    /// without a face is a sample with no x (the position holds).
    static func faceTrack(_ url: URL, clip c: EditV2.VideoClip, progress: @escaping @MainActor (Double) -> Void) async -> [EditV2.FaceSample] {
        let len = EditV2.clipLength(c)
        guard len > 0 else { return [] }
        let n = max(2, min(300, Int((len * 5).rounded(.up)) + 1))
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.04, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.04, preferredTimescale: 600)
        var out: [EditV2.FaceSample] = []
        var last: Double?
        for i in 0..<n {
            if Task.isCancelled { return [] }
            let t = len * Double(i) / Double(n - 1)
            let src = EditV2.clipSourceAt(c, t)
            var faces: [CGRect] = []
            if let cg = try? await gen.image(at: CMTime(seconds: src, preferredTimescale: 600)).image {
                faces = await Task.detached(priority: .userInitiated) { () -> [CGRect] in
                    let req = VNDetectFaceRectanglesRequest()
                    guard (try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])) != nil else { return [] }
                    return (req.results ?? []).map(\.boundingBox)
                }.value
            }
            let pick: CGRect?
            if let l = last {
                pick = faces.min { abs(Double($0.midX) - l) + 0.5 * (1 - Double($0.width)) < abs(Double($1.midX) - l) + 0.5 * (1 - Double($1.width)) }
            } else {
                pick = faces.max { $0.width * $0.height < $1.width * $1.height }
            }
            if let f = pick { last = Double(f.midX) }
            out.append(EditV2.FaceSample(t: t, x: pick.map { Double($0.midX) }))
            await progress(Double(i + 1) / Double(n))
        }
        return out
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

    /// The loudness of source seconds [a, b) of a file's sound: the RMS of the samples above the −50 dB gate, and the loudest
    /// sample (0–1). Nil when it's silent or has no sound. For evening clips out against each other.
    static func level(_ url: URL, from a: Double, to b: Double) async -> (rms: Double, peak: Double)? {
        await Task.detached(priority: .utility) { () -> (rms: Double, peak: Double)? in
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return nil }
            reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, a), preferredTimescale: 600), end: CMTime(seconds: max(a + 0.01, b), preferredTimescale: 600))
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                                                                               AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                                                                               AVLinearPCMIsBigEndianKey: false])
            guard reader.canAdd(out) else { return nil }
            reader.add(out)
            guard reader.startReading() else { return nil }
            var sum = 0.0, n = 0, peak = 0.0
            while let sb = out.copyNextSampleBuffer() {
                guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
                let len = CMBlockBufferGetDataLength(bb)
                var data = [Float](repeating: 0, count: len / 4)
                _ = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
                for v in data {
                    let x = Double(abs(v))
                    if x > peak { peak = x }
                    if x > 0.00316 { sum += x * x; n += 1 }
                }
            }
            return n > 0 ? ((sum / Double(n)).squareRoot(), peak) : nil
        }.value
    }
}

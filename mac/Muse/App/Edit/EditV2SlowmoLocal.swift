import AVFoundation
import CoreVideo
import MuseCore
import VideoToolbox

/// Smooth slow motion on this Mac (XL, owner-approved): Apple's frame interpolation (VideoToolbox frame-rate conversion,
/// macOS 15.4+), free and on the device. The copy has the same shape as the server's slowmo job: the source range
/// [startSec, endSec] with `factor − 1` new frames between each pair, written at the source frame rate, so it lasts
/// range × factor; no sound. When it isn't supported or fails, the session uses the server job.
enum EditV2SlowmoLocal {
    struct Made {
        let file: URL
        let width: Int
        let height: Int
        let durationSec: Double
    }

    /// Frame interpolation can run on this Mac.
    static var available: Bool {
        // `processorSupported` is the macOS 15 SDK's name (renamed `isSupported` later, the old one kept).
        if #available(macOS 15.4, *) { return VTFrameRateConversionConfiguration.processorSupported }
        return false
    }

    @available(macOS 15.4, *)
    static func make(_ src: URL, startSec: Double, endSec: Double, factor: Int, progress: @escaping @MainActor (Double) -> Void) async throws -> Made {
        let asset = AVURLAsset(url: src)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ApiError("slowmo_failed", "This clip has no picture") }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let nominal = Double(try await track.load(.nominalFrameRate))
        let fps = nominal.isFinite && nominal > 1 ? nominal : 30
        let w = Int(natural.width), h = Int(natural.height)
        guard w > 0, h > 0 else { throw ApiError("slowmo_failed", "This clip has no picture") }

        let format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: startSec, preferredTimescale: 600), end: CMTime(seconds: endSec, preferredTimescale: 600))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: format,
                                                                          kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { throw ApiError("slowmo_failed", "Couldn't read this clip") }
        reader.add(out)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("slowmo-\(UUID().uuidString.prefix(8)).mp4")
        let writer = try AVAssetWriter(outputURL: file, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(4_000_000, w * h * 8), AVVideoExpectedSourceFrameRateKey: Int(fps.rounded())],
        ])
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard factor == 2 || factor == 4 else { throw ApiError("slowmo_failed", "2× or 4× only") }
        guard writer.canAdd(input) else { throw ApiError("slowmo_failed", "This Mac can't write the slowed clip") }
        writer.add(input)

        guard let config = VTFrameRateConversionConfiguration(frameWidth: w, frameHeight: h, usePrecomputedFlow: false,
                                                              qualityPrioritization: .normal, revision: .revision1) else {
            throw ApiError("slowmo_unsupported", "Frame interpolation can't take this clip")
        }
        let processor = VTFrameProcessor()
        try processor.startSession(configuration: config)
        defer { processor.endSession() }

        guard reader.startReading(), writer.startWriting() else { throw reader.error ?? writer.error ?? ApiError("slowmo_failed", "Couldn't start") }
        writer.startSession(atSourceTime: .zero)
        let step = CMTime(value: 1000, timescale: CMTimeScale((fps * 1000).rounded()))
        var index: Int64 = 0
        let expected = max(1.0, (endSec - startSec) * fps)
        var seen = 0.0

        func append(_ buf: CVPixelBuffer) async throws {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard adaptor.append(buf, withPresentationTime: CMTimeMultiply(step, multiplier: Int32(index))) else {
                throw writer.error ?? ApiError("slowmo_failed", "Couldn't write the slowed clip")
            }
            index += 1
        }
        func blank(like b: CVPixelBuffer) throws -> CVPixelBuffer {
            var outBuf: CVPixelBuffer?
            let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
            guard CVPixelBufferCreate(kCFAllocatorDefault, CVPixelBufferGetWidth(b), CVPixelBufferGetHeight(b), CVPixelBufferGetPixelFormatType(b),
                                      attrs as CFDictionary, &outBuf) == kCVReturnSuccess, let outBuf else {
                throw ApiError("slowmo_failed", "Out of memory for the slowed clip")
            }
            return outBuf
        }

        var prev: (CVPixelBuffer, CMTime)?
        let phases = (1..<factor).map { Double($0) / Double(factor) }
        do {
            while let sample = out.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let buf = CMSampleBufferGetImageBuffer(sample) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                if let (a, at) = prev {
                    try await append(a)
                    let dests = try phases.map { _ in try blank(like: a) }
                    guard let src = VTFrameProcessorFrame(buffer: a, presentationTimeStamp: at),
                          let next = VTFrameProcessorFrame(buffer: buf, presentationTimeStamp: pts) else { throw ApiError("slowmo_failed", "Couldn't read a frame") }
                    let destFrames = try dests.enumerated().map { i, d -> VTFrameProcessorFrame in
                        let t = CMTimeAdd(at, CMTimeMultiplyByFloat64(CMTimeSubtract(pts, at), multiplier: Double(phases[i])))
                        guard let f = VTFrameProcessorFrame(buffer: d, presentationTimeStamp: t) else { throw ApiError("slowmo_failed", "Couldn't make a frame") }
                        return f
                    }
                    // Literals, so they fit the SDK's element type ([NSNumber] in the macOS 15 SDK, [Float] later).
                    let made = factor == 2
                        ? VTFrameRateConversionParameters(sourceFrame: src, nextFrame: next, opticalFlow: nil, interpolationPhase: [0.5],
                                                          submissionMode: .sequential, destinationFrames: destFrames)
                        : VTFrameRateConversionParameters(sourceFrame: src, nextFrame: next, opticalFlow: nil, interpolationPhase: [0.25, 0.5, 0.75],
                                                          submissionMode: .sequential, destinationFrames: destFrames)
                    guard let params = made else {
                        throw ApiError("slowmo_failed", "Couldn't set up frame interpolation")
                    }
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        processor.process(parameters: params) { _, error in
                            if let error { cont.resume(throwing: error) } else { cont.resume() }
                        }
                    }
                    for d in dests { try await append(d) }
                }
                prev = (buf, pts)
                seen += 1
                let v = min(0.99, seen / expected)
                await progress(v)
            }
            // The last frame holds for its slot, so the copy is exactly range × factor long.
            if let (a, _) = prev { for _ in 0..<factor { try await append(a) } }
            guard reader.status != .failed else { throw reader.error ?? ApiError("slowmo_failed", "Couldn't read this clip") }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? ApiError("slowmo_failed", "Couldn't write the slowed clip") }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        await progress(1)
        let size = natural.applying(transform)
        return Made(file: file, width: Int(abs(size.width)), height: Int(abs(size.height)), durationSec: EditV2.r6(Double(index) / fps))
    }
}

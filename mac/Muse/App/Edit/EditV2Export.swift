import AVFoundation
import VideoToolbox
import CoreImage
import ImageIO
import MuseCore
import UniformTypeIdentifiers

/// Export formats beyond the default video (parity with Android, plans/edit-parity.md): a video at a chosen bitrate (reader →
/// writer, since AVAssetExportSession has no bitrate), the edit's mix alone as .m4a (AAC 192 kbit/s), and a looping GIF
/// (15 frames a second, 480 px on the short side, up to 30 s, captions burned in).
extension EditV2Engine {
    /// A reader → writer pump: every sample of `output` appended to `input`, then the input finished.
    private final class Pump: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        let queue: DispatchQueue
        init(_ output: AVAssetReaderOutput, _ input: AVAssetWriterInput, _ label: String) {
            self.output = output; self.input = input; queue = DispatchQueue(label: label)
        }
        func run(onSample: @escaping @Sendable (CMTime) -> Void) async {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                var done = false
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    while input.isReadyForMoreMediaData && !done {
                        if let sb = output.copyNextSampleBuffer() {
                            onSample(CMSampleBufferGetPresentationTimeStamp(sb))
                            if !input.append(sb) { done = true; input.markAsFinished(); cont.resume(); return }
                        } else {
                            done = true
                            input.markAsFinished()
                            cont.resume()
                            return
                        }
                    }
                }
            }
        }
    }

    /// Writes `built` through AVAssetReader → AVAssetWriter: video at `bitrate` bits/s (H.264 or HEVC) with AAC sound, or
    /// with `audioOnly` just the mix as AAC 192 kbit/s in an .m4a. Progress 0…1; cancelling stops it and deletes the file.
    /// `hdr`: HEVC Main 10, BT.2020 / HLG (built with `hdr`).
    /// 5A.3: what a file saved on this Mac carries: nothing (no device, place, software or source details), and with the
    /// "Label as AI-generated" switch on only MUSE's label, as the server writes it on stored files.
    static let aiLabelText = "AI-generated · made with MUSE"
    static func fileMetadata(aiLabel: Bool) -> [AVMetadataItem] {
        guard aiLabel else { return [] }
        let item = AVMutableMetadataItem()
        item.identifier = .iTunesMetadataUserComment
        item.value = aiLabelText as NSString
        item.extendedLanguageTag = "und"
        return [item]
    }

    static func write(_ built: Built, to url: URL, audioOnly: Bool = false, hevc: Bool = false, bitrate: Double = 16e6, hdr: Bool = false,
                      aiLabel: Bool = false, progress: @escaping @MainActor (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        let asset = built.composition
        let total = max(0.1, built.plan.durationSec)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: url, fileType: audioOnly ? .m4a : .mp4)
        var pumps: [Pump] = []

        if !audioOnly {
            let vTracks = try await asset.loadTracks(withMediaType: .video)
            guard !vTracks.isEmpty else { throw ApiError("edit_export_failed", "This edit has no picture to export") }
            let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: vTracks, videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32BGRA])
            vOut.videoComposition = built.videoComposition
            vOut.alwaysCopiesSampleData = false
            guard reader.canAdd(vOut) else { throw ApiError("edit_export_failed", "Couldn't read this edit's picture") }
            reader.add(vOut)
            let size = built.videoComposition.renderSize
            let fps = built.plan.fps.isFinite && built.plan.fps > 0 ? built.plan.fps : 30
            var compression: [String: Any] = [AVVideoAverageBitRateKey: Int(max(200_000, bitrate)), AVVideoExpectedSourceFrameRateKey: Int(fps.rounded())]
            var video: [String: Any] = [AVVideoCodecKey: hevc || hdr ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
                                        AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)]
            if hdr {
                compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
                video[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                                                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                                                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
            }
            video[AVVideoCompressionPropertiesKey] = compression
            let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: video)
            vIn.expectsMediaDataInRealTime = false
            guard writer.canAdd(vIn) else { throw ApiError("edit_export_failed", "This Mac can't encode this video") }
            writer.add(vIn)
            pumps.append(Pump(vOut, vIn, "studio.muse.edit.export.video"))
        }

        let aTracks = try await asset.loadTracks(withMediaType: .audio)
        if aTracks.isEmpty, audioOnly { throw ApiError("edit_no_sound", "This edit has no sound to export") }
        if !aTracks.isEmpty {
            let aOut = AVAssetReaderAudioMixOutput(audioTracks: aTracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                                                                                         AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
                                                                                         AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false,
                                                                                         AVLinearPCMIsBigEndianKey: false])
            aOut.audioMix = built.audioMix
            aOut.audioTimePitchAlgorithm = .spectral
            if reader.canAdd(aOut) {
                reader.add(aOut)
                let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                                                                                 AVEncoderBitRateKey: audioOnly ? EditSuite.ExportFormat.soundBitrate : 128_000])
                aIn.expectsMediaDataInRealTime = false
                if writer.canAdd(aIn) {
                    writer.add(aIn)
                    pumps.append(Pump(aOut, aIn, "studio.muse.edit.export.audio"))
                }
            }
        }
        guard !pumps.isEmpty else { throw ApiError("edit_export_failed", "Nothing to export") }
        guard reader.startReading() else { throw reader.error ?? ApiError("edit_export_failed", "Couldn't read this edit") }
        writer.metadata = fileMetadata(aiLabel: aiLabel)
        guard writer.startWriting() else { throw writer.error ?? ApiError("edit_export_failed", "Couldn't write the file") }
        writer.startSession(atSourceTime: .zero)
        do {
            try await withTaskCancellationHandler {
                await withTaskGroup(of: Void.self) { group in
                    for (i, p) in pumps.enumerated() {
                        let report = i == 0
                        group.addTask {
                            await p.run { t in
                                guard report, t.isNumeric else { return }
                                let v = min(1, max(0, t.seconds / total))
                                Task { @MainActor in progress(v) }
                            }
                        }
                    }
                }
                try Task.checkCancellation()
                await writer.finishWriting()
                if writer.status != .completed || reader.status == .failed {
                    throw writer.error ?? reader.error ?? ApiError("edit_export_failed", "Couldn't export the edit")
                }
                await progress(1)
            } onCancel: {
                reader.cancelReading()
                writer.cancelWriting()
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// A looping GIF of the edit: 15 frames a second, 480 px on the short side, at most 30 s (captions burned in).
    static func writeGif(_ built: Built, to url: URL, progress: @escaping @MainActor (Double) -> Void) async throws {
        let d = built.plan.durationSec
        guard d <= EditSuite.ExportFormat.gifMaxSec + 0.05 else { throw ApiError("edit_gif_long", "GIFs are up to 30 s · trim the edit or export a video") }
        try? FileManager.default.removeItem(at: url)
        let fps = EditSuite.ExportFormat.gifFps
        let n = max(1, Int((d * fps).rounded(.down)))
        let rs = built.videoComposition.renderSize
        let short = Double(EditSuite.ExportFormat.gifShortSide)
        let k = min(1, short / Double(min(rs.width, rs.height)))
        let gen = AVAssetImageGenerator(asset: built.composition)
        gen.videoComposition = built.videoComposition
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = CGSize(width: (Double(rs.width) * k).rounded(), height: (Double(rs.height) * k).rounded())
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, n, nil) else {
            throw ApiError("edit_export_failed", "Couldn't make the GIF")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: 1 / fps,
                                                                   kCGImagePropertyGIFUnclampedDelayTime as String: 1 / fps]] as CFDictionary
        do {
            for i in 0..<n {
                try Task.checkCancellation()
                let t = CMTime(seconds: (Double(i) + 0.5) / fps, preferredTimescale: 600)
                let img = try await gen.image(at: t).image
                CGImageDestinationAddImage(dest, img, frameProps)
                await progress(Double(i + 1) / Double(n))
            }
            guard CGImageDestinationFinalize(dest) else { throw ApiError("edit_export_failed", "Couldn't make the GIF") }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

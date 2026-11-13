import AppKit
import AVFoundation
import MuseCore

/// Builds the edited video on the Mac with AVFoundation (plans/video-editor.md): an AVMutableComposition from the edit list
/// (each kept segment inserted in order, `scaleTimeRange` for its speed, audio left out where muted), played live in the
/// editor and exported as H.264/AAC at the source size and frame rate. Nothing is encoded on the server.
enum VideoEditEngine {
    struct Built {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition?
        let hasAudio: Bool
    }

    /// The source's video facts: display size (after its rotation), frame rate and length.
    struct SourceInfo: Equatable {
        var duration: Double
        var width: Int
        var height: Int
        var fps: Double
    }

    static func info(_ asset: AVAsset) async throws -> SourceInfo {
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ApiError("edit_no_video", "This take has no video to edit")
        }
        let (size, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let shown = size.applying(transform)
        return SourceInfo(duration: duration.isFinite ? duration : 0, width: Int(abs(shown.width).rounded()), height: Int(abs(shown.height).rounded()),
                          fps: fps > 0 ? Double(fps) : 30)
    }

    /// The composition for an edit list. Muted segments (or a muted list) get no audio.
    static func build(_ list: EditList, asset: AVAsset) async throws -> Built {
        let comp = AVMutableComposition()
        guard let srcVideo = try await asset.loadTracks(withMediaType: .video).first,
              let video = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ApiError("edit_no_video", "This take has no video to edit")
        }
        let (transform, fps, natural) = try await srcVideo.load(.preferredTransform, .nominalFrameRate, .naturalSize)
        video.preferredTransform = transform
        let srcAudio = try await asset.loadTracks(withMediaType: .audio).first
        let wantsAudio = srcAudio != nil && !list.mute && list.segments.contains { !$0.muted }
        let audio = wantsAudio ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil

        let scale: CMTimeScale = 600
        var cursor = CMTime.zero
        for seg in list.segments where seg.sourceLength > EditList.minSegment / 2 {
            let range = CMTimeRange(start: CMTime(seconds: seg.inSec, preferredTimescale: scale), end: CMTime(seconds: seg.outSec, preferredTimescale: scale))
            let retimed = abs(seg.speed - 1) > 0.001
            let outDur = retimed ? CMTime(seconds: seg.outputLength, preferredTimescale: scale) : range.duration
            let inserted = CMTimeRange(start: cursor, duration: range.duration)
            try video.insertTimeRange(range, of: srcVideo, at: cursor)
            if retimed { video.scaleTimeRange(inserted, toDuration: outDur) }
            if let audio {
                // Keep the audio track's timeline in step with the video: silence where it's muted (or the source has none).
                let end = audio.timeRange.end
                if end.isValid, end < cursor { audio.insertEmptyTimeRange(CMTimeRange(start: end, end: cursor)) }
                if let srcAudio, !seg.muted, (try? audio.insertTimeRange(range, of: srcAudio, at: cursor)) != nil {
                    if retimed { audio.scaleTimeRange(inserted, toDuration: outDur) }
                } else {
                    audio.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: outDur))
                }
            }
            cursor = cursor + outDur
        }

        // A fixed frame rate at the source's own rate (speed changes would otherwise change it) and the upright size.
        let vc = AVMutableVideoComposition()
        let shown = natural.applying(transform)
        vc.renderSize = CGSize(width: abs(shown.width).rounded(), height: abs(shown.height).rounded())
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, (fps > 0 ? fps : 30).rounded())))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
        layer.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layer]
        vc.instructions = [instruction]
        return Built(composition: comp, videoComposition: comp.duration > .zero ? vc : nil, hasAudio: audio != nil)
    }

    /// A player item for the live preview, with pitch kept at any speed.
    static func playerItem(_ built: Built) -> AVPlayerItem {
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioTimePitchAlgorithm = .spectral
        return item
    }

    /// Thumbnails along the source, `count` evenly spaced, for the timeline.
    static func thumbnails(_ asset: AVAsset, duration: Double, count: Int, height: CGFloat) async -> [(Double, CGImage)] {
        guard duration > 0, count > 0 else { return [] }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: height * 2, height: height * 2)
        // Any frame within half a slot will do for a strip: the decoder stops at a nearby keyframe instead of decoding up
        // to an exact time (owner ci_83f9d0dcd92f: long-GOP 1080p files made each strip dozens of decodes).
        let slack = CMTime(seconds: max(0.2, duration / Double(count) / 2), preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = slack
        gen.requestedTimeToleranceAfter = slack
        var out: [(Double, CGImage)] = []
        for i in 0..<count {
            let t = duration * (Double(i) + 0.5) / Double(count)
            if Task.isCancelled { break }
            if let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                out.append((t, img))
            }
        }
        return out
    }

    /// Exports H.264/AAC .mp4 at the source size and frame rate. `progress` reports 0…1; cancelling the task cancels the export.
    static func export(_ built: Built, to url: URL, progress: @escaping @MainActor (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ApiError("edit_export_failed", "This Mac can't export this video")
        }
        session.outputURL = url
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.videoComposition = built.videoComposition
        session.audioTimePitchAlgorithm = .spectral
        let box = ExportBox(session)
        try await withTaskCancellationHandler {
            let poll = Task { @MainActor in
                while !Task.isCancelled {
                    progress(Double(box.session.progress))
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            }
            defer { poll.cancel() }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                box.session.exportAsynchronously { cont.resume() }
            }
            switch box.session.status {
            case .completed:
                await progress(1)
            case .cancelled:
                throw CancellationError()
            default:
                throw ApiError("edit_export_failed", "Couldn't export the edit" + (box.session.error.map { " (\($0.localizedDescription))" } ?? ""))
            }
        } onCancel: {
            box.session.cancelExport()
        }
    }

    /// What the server needs about the exported file: its real length, size and frame rate, and a JPEG frame (≤ 720 px).
    static func describe(_ file: URL) async throws -> EditedVideo {
        let a = AVURLAsset(url: file)
        let i = try await info(a)
        let gen = AVAssetImageGenerator(asset: a)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 720, height: 720)
        var jpeg: Data?
        if let img = try? await gen.image(at: CMTime(seconds: min(0.5, i.duration / 2), preferredTimescale: 600)).image {
            jpeg = NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        }
        return EditedVideo(file: file, thumbJPEG: jpeg, durationSec: i.duration, width: i.width, height: i.height, fps: i.fps)
    }

    final class ExportBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ s: AVAssetExportSession) { session = s }
    }
}

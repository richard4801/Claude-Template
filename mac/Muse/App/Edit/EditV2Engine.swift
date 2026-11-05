import AppKit
import AVFoundation
import CoreImage
import MuseCore

/// Builds and exports an Editor v2 project on the Mac (plans/video-editor.md "Editor v2"): the pure render plan from MuseCore
/// (EditV2.renderPlan) laid into an AVMutableComposition (main clips on two alternating video tracks, one track per overlay
/// video track, one audio track per lane with `setVolumeRamp` between the audioEnvelope points), drawn per frame by
/// EditV2Compositor (Core Image), played live through an AVPlayerItem and exported as H.264/AAC MP4 at the canvas size and
/// frame rate. Nothing is encoded on the server.
enum EditV2Engine {
    /// A source file of the project, read once.
    struct Media {
        let asset: AVURLAsset
        let info: EditV2.MediaInfo
        let videoTrack: AVAssetTrack?
        let audioTrack: AVAssetTrack?
        /// Turns the decoded frame (natural orientation, Core Image coordinates) upright with its origin at 0,0.
        let orient: CGAffineTransform
    }

    /// Every source of a project by asset id: video/audio files, and pictures for image items.
    struct Sources {
        var media: [String: Media] = [:]
        var images: [String: CIImage] = [:]
        var infos: [String: EditV2.MediaInfo] { media.mapValues(\.info) }
    }

    struct Built {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        let audioMix: AVMutableAudioMix?
        let plan: EditV2.RenderPlan
    }

    static let timescale: CMTimeScale = 6000
    static func time(_ s: Double) -> CMTime { CMTime(seconds: max(0, s), preferredTimescale: timescale) }

    // MARK: Sources

    /// Reads every asset of the project from its local file (`files` by asset id). Assets without a file are left out
    /// (the plan then skips them); a file that can't be read throws.
    static func load(_ project: EditV2.Project, files: [String: URL]) async throws -> Sources {
        var out = Sources()
        for a in project.assets {
            guard let url = files[a.id] else { continue }
            switch a.kind {
            case .image:
                guard let img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
                    throw ApiError("edit_bad_media", "Couldn't open a picture of this edit")
                }
                out.images[a.id] = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
            case .video, .audio:
                out.media[a.id] = try await media(AVURLAsset(url: url))
            }
        }
        return out
    }

    static func media(_ asset: AVURLAsset) async throws -> Media {
        let duration = try await asset.load(.duration).seconds
        let video = try await asset.loadTracks(withMediaType: .video).first
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        var orient = CGAffineTransform.identity
        var w = 0, h = 0
        if let video {
            let (size, transform) = try await video.load(.naturalSize, .preferredTransform)
            orient = uprightTransform(natural: size, preferred: transform)
            let shown = CGRect(origin: .zero, size: size).applying(orient)
            w = Int(shown.width.rounded())
            h = Int(shown.height.rounded())
        }
        let info = EditV2.MediaInfo(durationSec: duration.isFinite ? duration : 0, hasVideo: video != nil, hasAudio: audio != nil, width: w, height: h)
        return Media(asset: asset, info: info, videoTrack: video, audioTrack: audio, orient: orient)
    }

    /// The track's preferredTransform (a y-down transform) in Core Image's y-up coordinates, moved so the upright frame
    /// starts at 0,0.
    static func uprightTransform(natural: CGSize, preferred: CGAffineTransform) -> CGAffineTransform {
        let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: natural.height)
        let shownSize = CGRect(origin: .zero, size: natural).applying(preferred).size
        let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: abs(shownSize.height))
        let t = flipIn.concatenating(preferred).concatenating(flipOut)
        let r = CGRect(origin: .zero, size: natural).applying(t)
        return t.concatenating(CGAffineTransform(translationX: -r.minX, y: -r.minY))
    }

    // MARK: Composition

    /// The composition, video composition (custom compositor) and audio mix for a project.
    static func build(_ project: EditV2.Project, sources: Sources) throws -> Built {
        let plan = EditV2.renderPlan(project, media: sources.infos)
        guard plan.durationSec > 0 else { throw ApiError("edit_empty", "This edit has nothing to play") }
        let comp = AVMutableComposition()
        var videoLanes: [Int: AVMutableCompositionTrack] = [:]
        var audioLanes: [Int: AVMutableCompositionTrack] = [:]

        func lane(_ n: Int, _ type: AVMediaType, _ lanes: inout [Int: AVMutableCompositionTrack]) throws -> AVMutableCompositionTrack {
            if let t = lanes[n] { return t }
            guard let t = comp.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw ApiError("edit_build_failed", "Couldn't build this edit")
            }
            lanes[n] = t
            return t
        }

        /// Puts source [s, e) of `src` at timeline [start, end) of `track`, retimed to fit (speed).
        func place(_ src: AVAssetTrack, on track: AVMutableCompositionTrack, source s: Double, _ e: Double, at start: Double, _ end: Double) throws {
            var at = time(start)
            let tEnd = track.timeRange.end
            let trackEnd = tEnd.isValid && tEnd.isNumeric ? tEnd : .zero
            if at > trackEnd { track.insertEmptyTimeRange(CMTimeRange(start: trackEnd, end: at)) }
            else { at = trackEnd }   // never insert inside the previous piece (rounding)
            let range = CMTimeRange(start: time(s), end: time(e))
            guard range.duration > .zero else { return }
            try track.insertTimeRange(range, of: src, at: at)
            let want = time(end) - at
            if want > .zero, abs((want - range.duration).seconds) > 0.5 / Double(timescale) {
                track.scaleTimeRange(CMTimeRange(start: at, duration: range.duration), toDuration: want)
            }
        }

        var trackIds: [Int: CMPersistentTrackID] = [:]
        for seg in plan.video {
            guard let src = sources.media[seg.assetId]?.videoTrack else { continue }
            let t = try lane(seg.lane, .video, &videoLanes)
            try place(src, on: t, source: seg.sourceStart, seg.sourceEnd, at: seg.timelineStart, seg.timelineEnd)
            trackIds[seg.lane] = t.trackID
        }

        var params: [Int: AVMutableAudioMixInputParameters] = [:]
        for seg in plan.audio {
            guard let src = sources.media[seg.assetId]?.audioTrack else { continue }
            let t = try lane(seg.lane, .audio, &audioLanes)
            try place(src, on: t, source: seg.sourceStart, seg.sourceEnd, at: seg.timelineStart, seg.timelineEnd)
            let p = params[seg.lane] ?? AVMutableAudioMixInputParameters(track: t)
            p.audioTimePitchAlgorithm = .spectral
            // AVAudioMix volumes are 0…1: louder than 1× (volume up to 2) plays at 1×.
            let pts = seg.envelope
            if let first = pts.first { p.setVolume(Float(min(1, first.gain)), at: time(first.t)) }
            for (a, b) in zip(pts, pts.dropFirst()) {
                let r = CMTimeRange(start: time(a.t), end: time(b.t))
                guard r.duration > .zero else { continue }
                p.setVolumeRamp(fromStartVolume: Float(min(1, a.gain)), toEndVolume: Float(min(1, b.gain)), timeRange: r)
            }
            params[seg.lane] = p
        }
        let mix: AVMutableAudioMix?
        if params.isEmpty { mix = nil } else {
            let m = AVMutableAudioMix()
            m.inputParameters = params.keys.sorted().compactMap { params[$0] }
            mix = m
        }

        let scene = EditV2Scene(project: project, plan: plan, laneTracks: trackIds, sources: sources)
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = EditV2Compositor.self
        vc.renderSize = CGSize(width: plan.width, height: plan.height)
        let fps = plan.fps > 0 ? plan.fps : 30
        vc.frameDuration = CMTime(value: 1000, timescale: CMTimeScale(max(1, (fps * 1000).rounded())))
        let end = max(comp.duration, time(plan.durationSec))
        var instructions: [EditV2Instruction] = []
        let cuts = plan.boundaries
        for (i, (a, b)) in zip(cuts, cuts.dropFirst()).enumerated() {
            let start = time(a)
            let stop = i == cuts.count - 2 ? end : time(b)
            guard stop > start else { continue }
            let ids = Set(plan.videoSegments(from: a, to: b).compactMap { trackIds[$0.lane] })
            instructions.append(EditV2Instruction(timeRange: CMTimeRange(start: start, end: stop), trackIDs: ids.sorted(), scene: scene))
        }
        // Instructions must cover the timeline without gaps.
        for i in 1..<max(1, instructions.count) where instructions[i].timeRange.start != instructions[i - 1].timeRange.end {
            instructions[i] = EditV2Instruction(timeRange: CMTimeRange(start: instructions[i - 1].timeRange.end, end: instructions[i].timeRange.end),
                                                trackIDs: instructions[i].trackIDs, scene: scene)
        }
        vc.instructions = instructions
        return Built(composition: comp, videoComposition: vc, audioMix: mix, plan: plan)
    }

    /// A player item for the live preview, with pitch kept at any speed.
    static func playerItem(_ built: Built) -> AVPlayerItem {
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        item.audioTimePitchAlgorithm = .spectral
        return item
    }

    // MARK: Export

    /// Exports H.264/AAC .mp4 at the canvas size and frame rate. `progress` reports 0…1; cancelling the task cancels the
    /// export, and a cancelled or failed export deletes the half-made file.
    static func export(_ built: Built, to url: URL, progress: @escaping @MainActor (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ApiError("edit_export_failed", "This Mac can't export this video")
        }
        session.outputURL = url
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        session.audioTimePitchAlgorithm = .spectral
        let box = VideoEditEngine.ExportBox(session)
        do {
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
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Builds and exports in one go, then describes the file for the upload (length, size, frame rate, a JPEG frame).
    static func render(_ project: EditV2.Project, files: [String: URL], to url: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> EditedVideo {
        let sources = try await load(project, files: files)
        let built = try build(project, sources: sources)
        try await export(built, to: url, progress: progress)
        return try await VideoEditEngine.describe(url)
    }
}

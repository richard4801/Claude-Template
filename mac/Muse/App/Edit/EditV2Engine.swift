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
        /// Imported .cube LUTs (assets of kind "lut") by asset id.
        var luts: [String: EditV2.Lut] = [:]
        var infos: [String: EditV2.MediaInfo] { media.mapValues(\.info) }
    }

    struct Built {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        let audioMix: AVMutableAudioMix?
        let plan: EditV2.RenderPlan
    }

    static let timescale: CMTimeScale = 6000
    /// A composition time; NaN, negative and infinite seconds become 0 (owner blocker 2026-11-07: AVFoundation raises an
    /// Objective-C exception, which Swift can't catch, on an invalid time range).
    static func time(_ s: Double) -> CMTime { CMTime(seconds: EditSuite.finiteSeconds(s), preferredTimescale: timescale) }

    // MARK: Sources

    /// Reads every asset of the project from its local file (`files` by asset id; a "lut" asset = its downloaded .cube).
    /// Assets without a file are left out (the plan then skips them); a file that can't be read throws.
    static func load(_ project: EditV2.Project, files: [String: URL]) async throws -> Sources {
        var out = Sources()
        _ = await filler()
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
            case .lut:
                do { out.luts[a.id] = try EditV2LookLibrary.readCube(url) } catch {
                    throw ApiError("edit_bad_media", "Couldn't read a LUT of this edit (\(error.localizedDescription))")
                }
            case .font:
                // Own fonts: text that names it draws with this file; if it can't be read, the fallback family is used.
                EditV2TextRenderer.registerOwnFont(a.id, file: url)
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

    /// The alpha matte of a segment's clip, if it has one.
    static func matteOf(_ project: EditV2.Project, _ seg: EditV2.VideoSegment) -> EditV2.AlphaMatte? {
        project.tracks.first { $0.id == seg.trackId }?.item(seg.itemId)?.videoClip?.alphaMatte
    }

    /// The composition, video composition (custom compositor) and audio mix for a project. `burnCaptions` false leaves the
    /// captions out of the picture (they go out as an .srt).
    static func build(_ project: EditV2.Project, sources: Sources, burnCaptions: Bool = true) throws -> Built {
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

        /// Puts a segment's constant-speed pieces back to back from `start` (a speed curve = up to 48 retimed pieces).
        func placePieces(_ src: AVAssetTrack, on track: AVMutableCompositionTrack, pieces: [EditV2.Piece], source s: Double, _ e: Double,
                   at start: Double, _ end: Double) throws {
            if pieces.count <= 1 { try place(src, on: track, source: s, e, at: start, end); return }
            var tl = start
            for (i, pc) in pieces.enumerated() {
                let pieceEnd = i == pieces.count - 1 ? end : min(end, tl + pc.length)
                if pieceEnd - tl > 1e-4 { try place(src, on: track, source: pc.inSec, pc.outSec, at: tl, pieceEnd) }
                tl += pc.length
            }
        }

        var trackIds: [Int: CMPersistentTrackID] = [:]
        for seg in plan.video {
            guard let src = sources.media[seg.assetId]?.videoTrack else { continue }
            let t = try lane(seg.lane, .video, &videoLanes)
            try placePieces(src, on: t, pieces: seg.pieces, source: seg.sourceStart, seg.sourceEnd, at: seg.timelineStart, seg.timelineEnd)
            trackIds[seg.lane] = t.trackID
        }
        // Every video row hidden (or no picture at all): AVFoundation raises on a video composition without a video track
        // (Mac Edit audit 2026-11-08), so a black filler track runs under the whole edit; the compositor still draws the
        // background, pictures, text and captions over it (it never reads the filler's frames).
        var fillerId: CMPersistentTrackID?
        if videoLanes.isEmpty {
            // First choice: the hidden main clips' own pictures, placed as if shown (never drawn: the compositor only draws
            // what the plan shows). Else the black filler file.
            var shown = project
            if let mi = shown.tracks.firstIndex(where: { $0.kind == .main }) { shown.tracks[mi].hidden = nil }
            let shadow = EditV2.renderPlan(shown, media: sources.infos).video.filter { $0.mainIndex != nil }
            if !shadow.isEmpty, let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                for seg in shadow {
                    guard let src = sources.media[seg.assetId]?.videoTrack else { continue }
                    try placePieces(src, on: t, pieces: seg.pieces, source: seg.sourceStart, seg.sourceEnd, at: seg.timelineStart, seg.timelineEnd)
                }
                fillerId = t.trackID
            } else if let f = fillerTrack, let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let fr = f.timeRange
                let src = CMTimeRange(start: fr.start, duration: min(fr.duration, CMTime(value: 1, timescale: 2)))
                if src.duration > .zero {
                    try t.insertTimeRange(src, of: f, at: .zero)
                    t.scaleTimeRange(CMTimeRange(start: .zero, duration: src.duration), toDuration: time(plan.durationSec))
                    fillerId = t.trackID
                }
            }
        }
        // Remove background (2026-11-08): a clip's alpha matte plays on a track of its own per lane, with the clip's own
        // source times, so the compositor gets the matte frame that belongs to each picture frame.
        var matteLanes: [Int: AVMutableCompositionTrack] = [:]
        var matteIds: [Int: CMPersistentTrackID] = [:]
        var matted = Set<String>()   // "<lane>/<itemId>" of the segments that have their matte
        for seg in plan.video {
            guard let m = matteOf(project, seg), let mm = sources.media[m.asset], let src = mm.videoTrack, sources.media[seg.assetId]?.videoTrack != nil else { continue }
            // A matte a little shorter than its source (encoder rounding) plays to its end; never past it.
            let end = mm.info.durationSec > 0 ? mm.info.durationSec - 0.001 : .infinity
            let pieces = seg.pieces.compactMap { pc -> EditV2.Piece? in pc.inSec >= end ? nil : EditV2.Piece(inSec: pc.inSec, outSec: min(pc.outSec, end), speed: pc.speed) }
            guard seg.sourceStart < end else { continue }
            let t = try lane(seg.lane, .video, &matteLanes)
            try placePieces(src, on: t, pieces: pieces,
                            source: seg.sourceStart, min(seg.sourceEnd, end), at: seg.timelineStart, seg.timelineEnd)
            matteIds[seg.lane] = t.trackID
            matted.insert("\(seg.lane)/\(seg.itemId)")
        }

        var params: [Int: AVMutableAudioMixInputParameters] = [:]
        var voiceSpans: [Int: [EditV2VoiceTap.Span]] = [:]
        for seg in plan.audio {
            guard let src = sources.media[seg.assetId]?.audioTrack else { continue }
            let t = try lane(seg.lane, .audio, &audioLanes)
            try placePieces(src, on: t, pieces: seg.pieces, source: seg.sourceStart, seg.sourceEnd, at: seg.timelineStart, seg.timelineEnd)
            // Voice processing and gain above 1× both go through the lane's audio tap.
            let boost = seg.envelope.contains { $0.gain > 1.0001 } ? seg.envelope : []
            if seg.voice != nil || !boost.isEmpty {
                voiceSpans[seg.lane, default: []].append(EditV2VoiceTap.Span(start: seg.timelineStart, end: seg.timelineEnd, voice: seg.voice, boost: boost))
            }
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
        // Edit suite: voice enhance / effects through an audio tap per lane (works in export too).
        for (laneNo, spans) in voiceSpans {
            guard let p = params[laneNo] else { continue }
            p.audioTapProcessor = EditV2VoiceTap.make(spans)
        }
        let mix: AVMutableAudioMix?
        if params.isEmpty { mix = nil } else {
            let m = AVMutableAudioMix()
            m.inputParameters = params.keys.sorted().compactMap { params[$0] }
            mix = m
        }

        let scene = EditV2Scene(project: project, plan: plan, laneTracks: trackIds, matteTracks: matteIds, matted: matted, sources: sources,
                                burnCaptions: burnCaptions)
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = EditV2Compositor.self
        // A zero or odd render size makes AVFoundation refuse (or raise on) the video composition.
        vc.renderSize = CGSize(width: max(2, plan.width / 2 * 2), height: max(2, plan.height / 2 * 2))
        let fps = plan.fps.isFinite && plan.fps > 0 ? min(plan.fps, 240) : 30
        vc.frameDuration = CMTime(value: 1000, timescale: CMTimeScale(max(1, (fps * 1000).rounded())))
        let end = max(comp.duration, time(plan.durationSec))
        var instructions: [EditV2Instruction] = []
        let cuts = plan.boundaries
        for (i, (a, b)) in zip(cuts, cuts.dropFirst()).enumerated() {
            let start = time(a)
            let stop = i == cuts.count - 2 ? end : time(b)
            guard stop > start else { continue }
            let segs = plan.videoSegments(from: a, to: b)
            var ids = Set(segs.compactMap { trackIds[$0.lane] } + segs.filter { matted.contains("\($0.lane)/\($0.itemId)") }.compactMap { matteIds[$0.lane] })
            if let fillerId { ids.insert(fillerId) }
            instructions.append(EditV2Instruction(timeRange: CMTimeRange(start: start, end: stop), trackIDs: ids.sorted(), scene: scene))
        }
        // Instructions must cover the timeline from 0 without gaps or overlaps, each with a positive duration (AVFoundation
        // raises on anything else). Each starts where the previous ended; one that would end before it starts is dropped.
        var tiled: [EditV2Instruction] = []
        var cursor = CMTime.zero
        for ins in instructions {
            let stop = ins.timeRange.end
            guard stop.isNumeric, stop > cursor else { continue }
            tiled.append(EditV2Instruction(timeRange: CMTimeRange(start: cursor, end: stop), trackIDs: ins.trackIDs, scene: scene))
            cursor = stop
        }
        if end.isNumeric, end > cursor {
            tiled.append(EditV2Instruction(timeRange: CMTimeRange(start: cursor, end: end), trackIDs: tiled.last?.trackIDs ?? [], scene: scene))
        }
        vc.instructions = tiled
        return Built(composition: comp, videoComposition: vc, audioMix: mix, plan: plan)
    }

    /// The filler's video track (a black 64 × 64 H.264 file made once in the temporary folder), when it could be made.
    nonisolated(unsafe) private static var fillerTrack: AVAssetTrack?

    /// Makes (once) and loads the filler track.
    @discardableResult
    static func filler() async -> AVAssetTrack? {
        if let f = fillerTrack { return f }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MUSE-edit-filler-64.mp4")
        if !FileManager.default.fileExists(atPath: url.path) {
            let tmp = url.deletingLastPathComponent().appendingPathComponent("MUSE-edit-filler-\(UUID().uuidString).mp4")
            do {
                let writer = try AVAssetWriter(outputURL: tmp, fileType: .mp4)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
                writer.add(input)
                guard writer.startWriting() else { return nil }
                writer.startSession(atSourceTime: .zero)
                for i in 0..<2 {
                    while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
                    guard let pool = adaptor.pixelBufferPool else { break }
                    var pb: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                    guard let pb else { break }
                    CVPixelBufferLockBaseAddress(pb, [])
                    if let base = CVPixelBufferGetBaseAddress(pb) { memset(base, 0, CVPixelBufferGetBytesPerRow(pb) * 64) }
                    CVPixelBufferUnlockBaseAddress(pb, [])
                    adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 1))
                }
                input.markAsFinished()
                writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
                await writer.finishWriting()
                guard writer.status == .completed else { return nil }
                try? FileManager.default.moveItem(at: tmp, to: url)
            } catch { return nil }
        }
        fillerTrack = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first
        return fillerTrack
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
    static func export(_ built: Built, to url: URL, hevc: Bool = false, progress: @escaping @MainActor (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        // Edit suite: MP4 · H.264 (default) or HEVC.
        let preset = hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: built.composition, presetName: preset) else {

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

import AVFoundation
import AppKit
import MuseCore
import Observation

/// Compare's "Your edit" (Release 1 gap 1): the built edit played with the editor's own engine (EditV2Engine: the same
/// composition, compositor, Looks, text and speed curves as the Edit suite's preview), so ramps, camera keys, text and the
/// Look show as they will in the editor. It follows Recreate's shared playhead: seeks while paused, plays and pauses with it.
@MainActor
@Observable
final class RecreateBuiltPreview {
    enum Phase: Equatable { case loading, ready, failed(String) }

    private(set) var phase: Phase = .loading
    private(set) var duration: Double = 0
    /// The project rendered on this Mac (nil when the server's render plays).
    let project: EditV2.Project?
    /// The server's render (workstream 1, "The built edit, rendered"), played from its downloaded file.
    let serverRender: EditPreviewRender?
    let player = AVPlayer()
    private let files: [String: URL]
    private let file: URL?

    /// The built edit rendered on this Mac by the editor's engine (demo mode, and servers without previews).
    init(project: EditV2.Project, files: [String: URL]) {
        self.project = project
        self.files = files
        self.serverRender = nil
        self.file = nil
        player.actionAtItemEnd = .pause
        // The reference plays its sound beside it; the built edit is posted with that sound, so it plays muted here.
        player.isMuted = true
    }

    /// The server's preview of the edit session's revision, downloaded to `file`.
    init(render: EditPreviewRender, file: URL) {
        self.project = nil
        self.files = [:]
        self.serverRender = render
        self.file = file
        player.actionAtItemEnd = .pause
        player.isMuted = true
    }

    /// True when `url` is a real video (a video track that lasts). A still image or an unreadable file is never drawn as
    /// "your edit": animating a poster with the clip's camera keys made the edit look like a slideshow (owner bug).
    static func isPlayableVideo(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else { return false }
        let secs = (try? await asset.load(.duration).seconds) ?? 0
        return secs.isFinite && secs > 0.1
    }

    /// The server's picture leaves something out (rotation, masks, captions…): the player says "Preview of the cut".
    var cutOnly: Bool { serverRender?.isCutOnly ?? false }
    var clipCount: Int { project?.mainClips.count ?? 0 }

    var aspect: CGFloat {
        if let p = project { return CGFloat(p.canvas.width) / CGFloat(max(1, p.canvas.height)) }
        if let r = serverRender, let w = r.width, let h = r.height, w > 0, h > 0 { return CGFloat(w) / CGFloat(h) }
        return 9 / 16
    }

    func load() async {
        phase = .loading
        if let file {
            let item = AVPlayerItem(url: file)
            player.replaceCurrentItem(with: item)
            let secs = (try? await item.asset.load(.duration).seconds) ?? 0
            duration = secs.isFinite && secs > 0 ? secs : (serverRender?.durationSec ?? 0)
            phase = duration > 0 ? .ready : .failed("Couldn’t play the rendered edit")
            return
        }
        guard let project else { phase = .failed("Nothing to play"); return }
        do {
            let sources = try await EditV2Engine.load(project, files: files)
            let built = try EditV2Engine.build(project, sources: sources)
            player.replaceCurrentItem(with: EditV2Engine.playerItem(built))
            duration = built.plan.durationSec
            phase = .ready
        } catch {
            phase = .failed((error as? ApiError)?.message ?? "Couldn’t build this edit to play")
        }
    }

    /// The edit's time for a time in the reference (the cuts land on the reference's times), held at its end.
    func seek(_ referenceTime: Double) {
        guard phase == .ready else { return }
        let t = min(max(0, referenceTime), max(0, duration - 0.001))
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func play(from referenceTime: Double) {
        guard phase == .ready else { return }
        seek(referenceTime)
        player.play()
    }

    func pause() { player.pause() }

    /// The exact frame at `t` (edit seconds), drawn by the same composition the player shows (review mode's proof shot).
    func frame(at t: Double) async -> CGImage? {
        guard phase == .ready, let item = player.currentItem else { return nil }
        let gen = AVAssetImageGenerator(asset: item.asset)
        gen.videoComposition = item.videoComposition
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = CGSize(width: 540, height: 960)
        let time = CMTime(seconds: min(max(0, t), max(0, duration - 0.05)), preferredTimescale: 600)
        return try? await gen.image(at: time).image
    }

    func close() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

/// Recreate's export: the built edit rendered on this Mac by the editor's export path (EditV2Engine.build + export), its own
/// sound replaced by the reference's (a guide track from 0, as long as the edit or the reference, whichever is shorter), or
/// with no sound at all. Nothing is uploaded or charged.
enum RecreateExporter {
    static func export(project: EditV2.Project, files: [String: URL], guide: URL?, to url: URL,
                       progress: @escaping @MainActor (Double) -> Void) async throws {
        let sources = try await EditV2Engine.load(project, files: files)
        let built = try EditV2Engine.build(project, sources: sources)
        let comp = built.composition
        // The takes' own sound goes: the edit is posted with the reference's sound.
        for t in comp.tracks(withMediaType: .audio) { comp.removeTrack(t) }
        if let guide {
            let asset = AVURLAsset(url: guide)
            guard let src = try await asset.loadTracks(withMediaType: .audio).first else {
                throw ApiError("no_sound", "The reference has no sound. Export silent instead.")
            }
            let range = try await src.load(.timeRange)
            guard let r = RecreateExport.guideRange(editSec: built.plan.durationSec, referenceSec: range.duration.seconds),
                  let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw ApiError("no_sound", "The reference’s sound couldn’t be laid under the edit. Export silent instead.")
            }
            try track.insertTimeRange(CMTimeRange(start: range.start, duration: EditV2Engine.time(r.duration)), of: src, at: .zero)
        }
        let out = EditV2Engine.Built(composition: comp, videoComposition: built.videoComposition, audioMix: nil, plan: built.plan)
        try await EditV2Engine.export(out, to: url, progress: progress)
    }
}

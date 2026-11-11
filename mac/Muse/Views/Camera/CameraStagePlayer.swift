import AVFoundation
import AVKit
import MuseCore
import SwiftUI

// Camera stage viewer (owner, 2026-11-11: "I should be able to play it directly here and view the path without it hanging").
// The greybox guide streams in the page (AVPlayer on its signed URL, never a download), in step with the timeline; the
// paths are drawn over the Camera view; the Plan, Side and 3D views play along. Logic: MuseCore CameraStage.swift.
//
// Why the page hung before: the Blocking body was part of DirectedBody, so every playhead change (each mouse move while
// scrubbing) re-ran the whole page body, including the Claude transcript beside it (all messages re-filtered and
// re-laid out, the closures passed to it defeat SwiftUI's equality check). Here the playhead is only read by the leaves
// that draw it (viewport, transport label, timeline), so playing at 30 fps redraws those and nothing else.

/// The guide video and the shot clock. The playhead (CameraModel.playhead) stays the source of truth: the player reports
/// its time into it while playing, and a scrub seeks the player (only when it is more than half a frame away).
@MainActor
@Observable
final class StagePlayer {
    let player: AVPlayer = {
        let p = AVPlayer()
        p.isMuted = true
        p.actionAtItemEnd = .pause
        p.preventsDisplaySleepDuringVideoPlayback = false
        return p
    }()

    private(set) var playing = false
    var loop = true
    /// The greybox asset playing (by id: its signed URL changes on every session reload, the video doesn't).
    private(set) var assetId: String?
    /// The first frames are in: the video can cover the still.
    private(set) var ready = false
    private(set) var failed = false

    var hasVideo: Bool { assetId != nil && !failed }

    @ObservationIgnored var duration: Double = 6
    @ObservationIgnored var fps: Double = 24
    /// Where the playhead goes: set by the stage.
    @ObservationIgnored var onTime: (Double) -> Void = { _ in }
    /// The playhead now (read when Play starts).
    @ObservationIgnored var currentPlayhead: () -> Double = { 0 }

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var clock: Task<Void, Never>?
    // Chase seeking (Apple QA1820): one seek in flight, the newest target waits, so a fast scrub never queues up seeks.
    @ObservationIgnored private var seeking = false
    @ObservationIgnored private var pendingSeek: Double?

    init() {}

    /// The session's newest ready greybox, or none (then Play runs the blocking on a clock).
    func load(_ asset: CameraAsset?) {
        let id = asset?.id
        if id == assetId, !failed { return }
        pause()
        teardownItem()
        assetId = id
        ready = false
        failed = false
        guard let s = asset?.url, let url = URL(string: s) else { return }
        // Neither call blocks: AVFoundation opens and buffers the stream on its own threads.
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        item.preferredForwardBufferDuration = 4
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item else { return }
                switch status {
                case .readyToPlay:
                    self.ready = true
                    self.seek(to: self.currentPlayhead())
                case .failed:
                    self.failed = true
                    self.playing = false
                default: break
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reachedEnd() }
        }
        player.replaceCurrentItem(with: item)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.playing, !self.seeking else { return }
                self.onTime(StagePlayback.playhead(fromPlayer: time.seconds, duration: self.duration))
            }
        }
    }

    /// Try the same greybox again (a fresh signed URL comes with the next session reload).
    func retry(_ asset: CameraAsset?) {
        assetId = nil
        failed = false
        load(asset)
    }

    func toggle() { playing ? pause() : play() }

    func play() {
        let start = StagePlayback.startTime(playhead: currentPlayhead(), duration: duration, fps: fps)
        if start != currentPlayhead() { onTime(start) }
        playing = true
        if hasVideo {
            seek(to: start)
            player.play()
        } else {
            runClock()
        }
    }

    func pause() {
        playing = false
        player.pause()
        clock?.cancel()
        clock = nil
    }

    /// A scrub or a jump: the playhead moved without the player.
    func playheadMoved(to t: Double) {
        guard hasVideo else { return }
        let now = player.currentTime().seconds
        if !now.isFinite || StagePlayback.needsSeek(playerTime: now, playhead: t, fps: fps) { seek(to: t) }
    }

    func stop() {
        pause()
        teardownItem()
        assetId = nil
    }

    // MARK: Private

    private func seek(to t: Double) {
        guard player.currentItem != nil else { return }
        if seeking {
            pendingSeek = t
            return
        }
        seeking = true
        let tol = CMTime(seconds: StagePlayback.tolerance(fps: fps), preferredTimescale: 600)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: tol, toleranceAfter: tol) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.seeking = false
                if let next = self.pendingSeek {
                    self.pendingSeek = nil
                    self.seek(to: next)
                }
            }
        }
    }

    private func reachedEnd() {
        if loop, playing {
            onTime(0)
            seek(to: 0)
            player.play()
        } else {
            playing = false
            onTime(duration)
        }
    }

    /// No video: the blocking plays on a 30 fps clock.
    private func runClock() {
        clock?.cancel()
        clock = Task { @MainActor [weak self] in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, self.playing, !Task.isCancelled else { return }
                let now = ContinuousClock.now
                let dt = Double((now - last).components.attoseconds) / 1e18 + Double((now - last).components.seconds)
                last = now
                let step = StagePlayback.advance(self.currentPlayhead(), by: dt, duration: self.duration, loop: self.loop)
                self.onTime(step.time)
                if !step.playing { self.playing = false }
            }
        }
    }

    private func teardownItem() {
        if let o = timeObserver { player.removeTimeObserver(o) }
        timeObserver = nil
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        endObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        seeking = false
        pendingSeek = nil
        player.replaceCurrentItem(with: nil)
    }
}

/// The Blocking tab: session strip, the view (Plan · Camera view · Side · 3D), transport, legend and timeline.
/// This body never reads the playhead itself (see the note at the top of the file).
struct CameraStageBlocking: View {
    @Environment(\.theme) private var t
    var model: CameraModel
    var session: CameraSession
    @State private var player = StagePlayer()

    private var greybox: CameraAsset? { CameraStageVideo.greybox(session) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                SessionStrip(model: model, session: session)
                CameraStageViewport(model: model, session: session, player: player)
                    .frame(minHeight: 260, maxHeight: .infinity)
                    .overlay(Rectangle().strokeBorder(t.line, lineWidth: 1))
                CameraStageTransport(model: model, session: session, player: player, greybox: greybox)
                CameraPlanLegend(session: session, editable: model.viewMode == .plan)
                if let e = model.applyError { Text(e).font(t.body(12)).foregroundStyle(t.rec) }
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)
            .padding(.bottom, 10)
            CameraTimelineView(session: session, playhead: Binding(get: { model.playhead }, set: { v in
                model.playhead = v
                player.playheadMoved(to: v)
            }))
        }
        .onAppear {
            wire()
            player.load(greybox)
        }
        .onChange(of: greybox?.id) { _, _ in
            wire()
            player.load(greybox)
        }
        .onChange(of: session.id) { _, _ in
            player.pause()
            wire()
        }
        .onDisappear { player.stop() }
    }

    private func wire() {
        player.duration = max(0.1, session.durationSec)
        player.fps = max(1, session.fps)
        player.onTime = { [weak model] t in model?.playhead = t }
        player.currentPlayhead = { [weak model] in model?.playhead ?? 0 }
    }
}

enum CameraStageVideo {
    static func greybox(_ s: CameraSession) -> CameraAsset? {
        s.assets.filter { $0.kind == "greybox" && $0.state == "ready" && $0.url != nil }.max { ($0.createdAt ?? 0) < ($1.createdAt ?? 0) }
    }
}

/// The picture: Plan, Camera view (the video with the paths over it), Side, or the 3D preview. Reads the playhead.
struct CameraStageViewport: View {
    var model: CameraModel
    var session: CameraSession
    var player: StagePlayer

    var body: some View {
        let t = model.playhead
        ZStack(alignment: .topTrailing) {
            switch model.viewMode {
            case .plan: CameraPlanCanvas(session: session, playhead: t, projection: .top) { h, p in model.drag(h, to: p) }
            case .side: CameraPlanCanvas(session: session, playhead: t, projection: .side, editable: false)
            case .camera: CameraVideoView(session: session, player: player, playhead: t)
            case .orbit: CameraOrbitView(session: session, playhead: t)
            }
            // The video keeps playing beside the Plan, Side and 3D views.
            if model.viewMode != .camera, player.playing, player.hasVideo, player.ready {
                CameraStageInset(player: player, aspect: CameraStageMath.aspect(session.aspect)).padding(10)
            }
        }
    }
}

/// Play/pause, the time, Loop, Paths and what is playing.
struct CameraStageTransport: View {
    @Environment(\.theme) private var t
    var model: CameraModel
    var session: CameraSession
    var player: StagePlayer
    var greybox: CameraAsset?
    @AppStorage("cameraStage.paths") private var paths = true

    var body: some View {
        HStack(spacing: 12) {
            StageIconButton(icon: player.playing ? "pause.fill" : "play.fill", help: player.playing ? "Pause" : "Play") { player.toggle() }
            Text(StagePlayback.timeLabel(model.playhead, duration: session.durationSec))
                .font(t.body(12, .medium).monospacedDigit()).foregroundStyle(t.ink)
                .frame(minWidth: 86, alignment: .leading)
            Chip("Loop", on: player.loop) { player.loop.toggle() }
                .help("Start again from the beginning at the end")
            if model.viewMode == .camera {
                Chip("Paths", on: paths) { paths.toggle() }
                    .help("Draw the paths through the shot camera")
            }
            Spacer(minLength: 8)
            Text(status).font(t.body(12)).foregroundStyle(player.failed ? t.rec : t.muted).lineLimit(1)
            if player.failed { MButton("Try again", size: .small) { player.retry(greybox) } }
        }
        .frame(minHeight: 34)
    }

    private var status: String {
        if greybox == nil { return "No guide video yet · Play runs the blocking" }
        if player.failed { return "The guide video didn't load" }
        if !player.ready { return "Loading the guide video…" }
        return "Greybox · rev \(session.revision)"
    }
}

/// Camera view: the newest still at once, the greybox over it when it is ready, the paths through the shot camera on top.
struct CameraVideoView: View {
    @Environment(\.theme) private var t
    var session: CameraSession
    var player: StagePlayer
    var playhead: Double
    @AppStorage("cameraStage.paths") private var paths = true

    var body: some View {
        let aspect = CameraStageMath.aspect(session.aspect)
        ZStack {
            t.surface
            ZStack {
                Color.black.opacity(0.06)
                if !(player.hasVideo && player.ready), let still = CameraGuides.still(session, at: playhead) {
                    StableStill(asset: still)
                }
                if player.hasVideo {
                    PlayerLayerView(player: player.player).opacity(player.ready ? 1 : 0)
                }
                if paths { CameraPathOverlay(session: session, playhead: playhead) }
                if !player.hasVideo, CameraGuides.still(session, at: playhead) == nil {
                    Text("No guide video yet · Re-render to make one").font(t.body(12)).foregroundStyle(t.muted)
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .clipped()
            .padding(12)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Camera view at \(CameraTimeline.playheadLabel(playhead))")
    }
}

/// A guide still that keeps showing while the session reloads (its signed URL changes; the asset id doesn't).
struct StableStill: View {
    var asset: CameraAsset
    @State private var image: NSImage?
    @State private var shownId: String?

    var body: some View {
        ZStack {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: asset.id) {
            guard shownId != asset.id, let u = asset.url else { return }
            if let img = await ImageCache.shared.load(u, px: 1600), !Task.isCancelled {
                image = img
                shownId = asset.id
            }
        }
    }
}

/// The paths seen through the shot camera at the playhead: each character's floor path and a dot where they are now, and
/// the camera's own path ahead. Colours sit on the grey render whatever the theme, so each line has a dark keyline.
struct CameraPathOverlay: View {
    @Environment(\.theme) private var t
    var session: CameraSession
    var playhead: Double

    var body: some View {
        Canvas { ctx, size in
            guard let o = CameraStageMath.overlay(session, at: playhead) else { return }
            func path(_ runs: [[CGPoint]]) -> Path {
                var p = Path()
                for run in runs {
                    p.addLines(run.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
                }
                return p
            }
            let cam = path(o.cameraPath)
            ctx.stroke(cam, with: .color(.black.opacity(0.45)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            ctx.stroke(cam, with: .color(.white), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [1.5, 4]))
            for c in o.characters {
                let color = CastStyle.color(c.castIndex, t)
                let p = path(c.path)
                ctx.stroke(p, with: .color(.black.opacity(0.45)), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [6, 4]))
                if let n = c.now {
                    let at = CGPoint(x: n.x * size.width, y: n.y * size.height)
                    let r: CGFloat = 6
                    ctx.fill(Path(ellipseIn: CGRect(x: at.x - r - 2, y: at.y - r - 2, width: 2 * r + 4, height: 2 * r + 4)), with: .color(.black.opacity(0.5)))
                    ctx.fill(Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r, width: 2 * r, height: 2 * r)), with: .color(color))
                    ctx.stroke(Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r, width: 2 * r, height: 2 * r)), with: .color(.white), lineWidth: 1.5)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// The video in a corner while the Plan, Side or 3D view plays.
struct CameraStageInset: View {
    @Environment(\.theme) private var t
    var player: StagePlayer
    var aspect: Double

    var body: some View {
        let w: CGFloat = aspect >= 1 ? 200 : 120
        PlayerLayerView(player: player.player)
            .frame(width: w, height: w / CGFloat(max(0.1, aspect)))
            .clipShape(RoundedRectangle(cornerRadius: t.isA ? 0 : 4))
            .overlay(RoundedRectangle(cornerRadius: t.isA ? 0 : 4).strokeBorder(t.line, lineWidth: 1))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Guides tab: a guide video plays here, in the app (it used to open the file in the browser, which downloaded it).
struct GuideVideoSheet: View {
    @Environment(\.theme) private var t
    @Environment(\.dismiss) private var dismiss
    var item: GuideItem
    @State private var player = AVPlayer()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(item.label).font(t.body(14, .semibold)).foregroundStyle(t.ink)
                Spacer()
                MButton("Done", size: .small) { dismiss() }
            }
            .padding(12)
            VideoPlayer(player: player)
                .frame(minWidth: 480, minHeight: 480)
        }
        .frame(width: 720, height: 640)
        .background(t.bg)
        .onAppear {
            guard let u = item.asset.url, let url = URL(string: u) else { return }
            player.isMuted = true
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            player.play()
        }
        .onDisappear { player.pause() }
    }
}

/// A 34 pt icon-only button with a Phosphor icon, hover tone, tooltip and accessibility label.
struct StageIconButton: View {
    @Environment(\.theme) private var t
    var icon: String
    var help: String
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Ph(icon, 16).foregroundStyle(t.ink)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: t.controlRadius).fill(hover ? t.surface2 : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hover = $0 }
    }
}

import AVFoundation
import MuseCore
import SwiftUI

// The Shot stage (approved frame "Shot composer", owner decision 2): a finished take on the field-tone stage with its
// title and real specs on the left, the actions above the video (Keep the one highlighted action, then Redo, Extend,
// Upscale, Split and Share), the take at its own shape, and a filmstrip timeline with play and the take's real length.

/// The stage's actions drawn quietly: Keep outlined on the raised tone (Generate stays the one filled button), the others
/// as plain icon-and-word buttons.
private struct ViewerStageStyleKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var viewerStageStyle: Bool {
        get { self[ViewerStageStyleKey.self] }
        set { self[ViewerStageStyleKey.self] = newValue }
    }
}

struct ShotStageTake: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var job: Job
    /// A take picked elsewhere (the feed); nil: the job's first.
    var takeId: String? = nil
    @State private var page = 0
    @State private var playback = ViewerPlayback()

    var body: some View {
        let list = store.takes(of: job)
        let start = list.firstIndex { $0.id == takeId } ?? 0
        let at = list.isEmpty ? 0 : (start + page) % list.count
        if list.isEmpty {
            MuseImage(ref: job.thumb).aspectRatio(9.0 / 16.0, contentMode: .fit)
        } else {
            let take = list[at]
            VStack(spacing: Space.s3) {
                header(take, at: at, count: list.count)
                TakeViewer(media: ViewerMedia(take: take), context: .suite, take: nil, job: nil, compact: true, startMuted: true,
                           onStep: list.count > 1 ? { step($0, count: list.count) } : nil, sharedPlayback: playback)
                    .id(take.id)
                    .frame(maxHeight: .infinity)
                if !take.isVideo && list.count > 1 {
                    // The Photo tab (owner 2026-11-14): every photo of the run as a strip, the shown one marked.
                    StagePhotoStrip(takes: list, at: at) { i in page = ((i - start) % list.count + list.count) % list.count }
                }
                if take.isVideo {
                    StageTimeline(playback: playback, video: take.videoUrl.flatMap(URL.init(string:)), poster: take.thumb,
                                  length: take.durationSec)
                        .frame(maxWidth: 420)
                }
            }
            .background { if SnapshotRunner.probing { ComposerBarFrame(key: "stage ready") } }
            .background {
                // Review mode: the carousel's probe, keyed by its job too (run 640: the stage's previous Photo × 4 job had the same
                // "1/4" key, and its probe going away removed the new one's). The check reads the prefix and the "/4" end.
                if SnapshotRunner.probing && list.count > 1 {
                    let key = "stage carousel \(job.id) \(at + 1)/\(list.count)"
                    ComposerBarFrame(key: key).id(key)
                }
            }
            .onChange(of: job.id) { page = 0 }
        }
    }

    private func step(_ d: Int, count: Int) { page = ((page + d) % count + count) % count }

    private func header(_ take: Take, at: Int, count: Int) -> some View {
        let actions = TakeViewerActions.list(.suite, isVideo: take.isVideo, canRedo: true, canExtend: ExtendSource.take(take) != nil,
                                             canUpscale: take.canUpscale, canUseInShot: job.isPhoto)
        return HStack(alignment: .center, spacing: Space.s4) {
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).font(t.body(15, .semibold)).foregroundStyle(t.roles.ink).lineLimit(1)
                HStack(spacing: 10) {
                    ForEach(Self.meta(take, at: at, count: count, noun: job.isPhoto ? "Photo" : "Take"), id: \.self) { Text($0) }
                }
                .font(t.scale.caption.font).monospacedDigit().foregroundStyle(t.roles.ink2).lineLimit(1).fixedSize()
            }
            .layoutPriority(1)
            if count > 1 {
                HStack(spacing: 0) {
                    SuiteIconButton(systemName: "caret-left", label: "Previous take") { step(-1, count: count) }
                    SuiteIconButton(systemName: "caret-right", label: "Next take") { step(1, count: count) }
                }
            }
            ViewerActionRow(take: take, job: job, actions: actions, time: { playback.time }, alignment: .trailing)
                .frame(height: ViewerActionRow.height)
                .environment(\.viewerStageStyle, true)
        }
    }

    /// "Take 2 of 4", "8 s", "9:16", "1080p": the take's own values (its real length, never the request's).
    static func meta(_ take: Take, at: Int, count: Int, noun: String = "Take") -> [String] {
        var out: [String] = []
        if count > 1 { out.append("\(noun) \(at + 1) of \(count)") }
        if let s = take.durationSec, s > 0 { out.append(s < 10 && s.rounded() != s ? String(format: "%.1f s", s) : "\(Int(s.rounded())) s") }
        if let w = take.width, let h = take.height, w > 0, h > 0 {
            if let shape = shape(w, h) { out.append(shape) }
            out.append("\(min(w, h))p")
        }
        return out
    }

    /// "9:16", "16:9", "1:1", "4:5", "3:4" when the size is one of them.
    static func shape(_ w: Int, _ h: Int) -> String? {
        let r = Double(w) / Double(h)
        let shapes: [(String, Double)] = [("9:16", 0.5625), ("16:9", 1.7778), ("1:1", 1.0), ("4:5", 0.8), ("3:4", 0.75), ("2:3", 0.6667), ("21:9", 2.3333)]
        for (label, v) in shapes where abs(r - v) < 0.02 { return label }
        return nil
    }
}

/// The Photo tab's run under the photo: each still small, the shown one outlined, "2 of 4". Clicking one shows it.
struct StagePhotoStrip: View {
    @Environment(\.theme) private var t
    var takes: [Take]
    var at: Int
    var pick: (Int) -> Void

    var body: some View {
        HStack(spacing: Space.s2) {
            ForEach(Array(takes.enumerated()), id: \.element.id) { i, take in
                let on = i == at
                Button { pick(i) } label: {
                    MuseImage(ref: take.thumb).frame(width: 40, height: 50).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: t.radii.chip))
                        .overlay(RoundedRectangle(cornerRadius: t.radii.chip + 2).strokeBorder(on ? t.roles.ink : .clear, lineWidth: 2).padding(-3))
                        .opacity(on ? 1 : 0.7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Photo \(i + 1) of \(takes.count)\(on ? ", shown" : "")")
            }
            Text("\(at + 1) of \(takes.count)").font(t.scale.caption.font).monospacedDigit().foregroundStyle(t.roles.ink2)
                .padding(.leading, Space.s2).fixedSize()
        }
        .padding(.top, 3)
        .background { if SnapshotRunner.probing { ComposerBarFrame(key: "stage photo strip") } }
    }
}

/// Play, the take's frames with the playhead, and "0:03 / 0:08". Clicking the strip moves the playhead there.
struct StageTimeline: View {
    @Environment(\.theme) private var t
    var playback: ViewerPlayback
    var video: URL?
    var poster: ImageRef?
    /// The take's length as recorded (shown until the player knows it).
    var length: Double?
    @State private var frames: [CGImage] = []

    private static let cells = 12

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let total = playback.duration > 0 ? playback.duration : (length ?? 0)
            let now = min(playback.time, total)
            HStack(spacing: Space.s3) {
                Button { playback.togglePlay() } label: {
                    Ph(playback.playing ? "pause" : "play", 14).foregroundStyle(t.roles.ink2)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(playback.playing ? "Pause (Space)" : "Play (Space)")
                .accessibilityLabel(playback.playing ? "Pause" : "Play")
                GeometryReader { g in strip(width: g.size.width, at: total > 0 ? now / total : 0, total: total) }
                    .frame(height: 30)
                Text("\(Take.clock(now)) / \(Take.clock(total))").font(t.scale.caption.font).monospacedDigit()
                    .foregroundStyle(t.roles.ink2).lineLimit(1).fixedSize()
                    .accessibilityLabel("\(Int(now)) of \(Int(total)) seconds")
            }
        }
        .task(id: video) { frames = await Filmstrip.frames(video, count: Self.cells) }
    }

    private func strip(width: CGFloat, at: Double, total: Double) -> some View {
        let cell = width / CGFloat(Self.cells)
        return ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                ForEach(0..<Self.cells, id: \.self) { i in
                    Group {
                        if frames.indices.contains(i) {
                            Image(decorative: frames[i], scale: 1).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            MuseImage(ref: poster)
                        }
                    }
                    .frame(width: cell, height: 30).clipped()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: t.radii.chip))
            .overlay(RoundedRectangle(cornerRadius: t.radii.chip).strokeBorder(t.roles.ink.opacity(0.85), lineWidth: 1.5))
            Rectangle().fill(t.roles.accent).frame(width: 2, height: 36)
                .offset(x: max(0, min(width - 2, CGFloat(at) * width - 1)))
                .allowsHitTesting(false)
        }
        .frame(width: width, height: 30)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            guard total > 0 else { return }
            let s = max(0, min(total, Double(v.location.x / max(width, 1)) * total))
            playback.player.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        })
        .help("Click or drag to move through the take")
        .accessibilityElement()
        .accessibilityLabel("Timeline")
    }
}

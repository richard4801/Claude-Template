import AppKit
import AVFoundation
import MuseCore
import SwiftUI

// The video studio's stage (owner request 2026-11-05): the source on the left, and on the right the target while idle,
// the render's live state while it runs (blurred, softly moving, phase, progress and price), the finished take playing
// inline (muted loop, unmute), or what went wrong with Try again. Member-safe wording only (`StudioStage`).

/// A 9:16 frame like `Media`, with the theme's corners and Creator Pop's ink outline.
private struct StageFrame<Content: View>: View {
    @Environment(\.theme) private var t
    var caption: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: t.isA ? 0 : t.r, style: .continuous)
        Color.clear
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .overlay(content())
            .overlay(alignment: .bottomLeading) {
                if let caption {
                    Text(caption).font(t.body(12, .semibold)).lineLimit(2).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.bottom, 8).padding(.top, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                        .allowsHitTesting(false)
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(t.isD ? Color(hex: 0x111111) : .clear, lineWidth: 2.5))
    }
}

/// The stage's left pane: the uploaded clip, or an empty placeholder before one is uploaded (never a sample performer).
struct StageSourcePane: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        if let poster = store.clipPoster {
            Media(ref: poster, caption: "Source · performer")
        } else {
            Button { store.pickClip() } label: {
                StageFrame(caption: nil) {
                    VStack(spacing: 6) {
                        Image(systemName: "film").font(.system(size: 18))
                        Text("No clip yet").font(t.body(12, .semibold))
                        Text("Source · performer").font(t.body(11)).foregroundStyle(t.muted)
                    }
                    .multilineTextAlignment(.center)
                    .foregroundStyle(t.ink)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(t.surface2.opacity(0.6))
                    .overlay(RoundedRectangle(cornerRadius: t.isA ? 0 : t.r).strokeBorder(t.strongLine, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choose a clip")
        }
    }
}

/// The stage's right pane.
struct StageOutputPane: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var stage: StudioStage
    /// The target: the outfit's front, else the model.
    var target: ImageRef?
    /// "<MODEL> · <outfit>".
    var caption: String
    @State private var muted = true

    var body: some View {
        switch stage.phase {
        case .idle:
            Media(ref: target, caption: caption)
        case .queued, .rendering:
            StageFrame(caption: caption) {
                ZStack {
                    BlurredStageArt(ref: art, moving: true)
                    busyCard.padding(10)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(stage.headline) · \(stage.phase == .rendering ? stage.percent + " · " : "")\(stage.price)")
        case .ready:
            ready
        case .failed:
            StageFrame(caption: caption) {
                ZStack {
                    BlurredStageArt(ref: art, moving: false).saturation(0.4)
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 18)).foregroundStyle(.white)
                        Text(stage.failure ?? MemberText.wentWrong).font(t.body(12, .semibold)).foregroundStyle(.white)
                            .multilineTextAlignment(.center).lineLimit(6).minimumScaleFactor(0.8).fixedSize(horizontal: false, vertical: true)
                        MButton("Try again", kind: .primary, size: .small, off: store.generating) { store.generate() }
                    }
                    .padding(12)
                }
            }
        }
    }

    /// The blurred picture: the clip's first frame, or the model when there's no frame.
    private var art: ImageRef? { store.clipThumb ?? store.clip?.thumb ?? target }

    private var busyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(stage.headline).font(t.body(12.5, .semibold)).foregroundStyle(.white)
                .lineLimit(3).minimumScaleFactor(0.85).fixedSize(horizontal: false, vertical: true)
            if stage.phase == .queued {
                WaitingBar()
            } else {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.25))
                        Capsule().fill(.white).frame(width: max(4, g.size.width * stage.progress))
                    }
                }
                .frame(height: 4)
                .animation(.linear(duration: 0.4), value: stage.progress)
            }
            HStack(spacing: 6) {
                if stage.phase == .rendering { Text(stage.percent).contentTransition(.numericText()) }
                Spacer(minLength: 0)
                Text(stage.price)
            }
            .font(t.mono(11, .medium))
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: t.isA ? 0 : 10).fill(.black.opacity(0.38)))
    }

    /// "Take 2 of 3 · 0:07 · 768×1344" (nil when there's nothing to say: the pane then keeps "<MODEL> · <outfit>").
    private func readyCaption(_ tk: Take) -> String? {
        let parts: [String] = [stage.takeLabel(tk), tk.mediaLine].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private var ready: some View {
        let take = stage.take(store.stageTakeId)
        let url = take?.videoUrl.flatMap(URL.init(string:))
        StageFrame(caption: take.flatMap { readyCaption($0) } ?? caption) {
            ZStack {
                if let url {
                    StageVideo(url: url, poster: take?.thumb, muted: muted)
                } else {
                    MuseImage(ref: take?.thumb ?? target)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            Text(t.isA ? "READY" : "Ready").font(t.mono(10, .medium)).foregroundStyle(.white)
                .padding(.horizontal, 7).frame(height: 18)
                .background(Capsule().fill(.black.opacity(0.5)))
                .padding(8)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            if url != nil {
                Button { muted.toggle() } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(.black.opacity(0.5)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(6)
                .help(muted ? "Unmute" : "Mute")
                .accessibilityLabel(muted ? "Unmute" : "Mute")
            }
        }
    }
}

/// Under the stage: the take switcher and Open / Edit video / Generate again when ready; a short note while it renders.
struct StageBar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var stage: StudioStage

    var body: some View {
        switch stage.phase {
        case .ready:
            if let take = stage.take(store.stageTakeId) {
                VStack(alignment: .leading, spacing: 10) {
                    if stage.takes.count > 1 {
                        HStack(spacing: 6) {
                            ForEach(stage.takes) { tk in
                                Chip("Take \(tk.index)", on: tk.id == take.id) { store.stageTakeId = tk.id }
                            }
                        }
                    }
                    FlowLayout(spacing: 8) {
                        MButton("Open", icon: "arrow.up.right.square", size: .small) { store.openTake(take.id) }
                        MButton("Edit video", icon: "scissors", size: .small, off: !store.canEdit(take)) {
                            if store.canEdit(take) { store.openEditor(take) } else { store.showToast("Edit video works once the take has its video") }
                        }
                        .help("Trim, split, change speed or mute. Saved as a new version; the original is kept.")
                        MButton("Generate again", icon: "arrow.clockwise", kind: .primary, size: .small, off: store.generateBlocked) { store.generate() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .queued, .rendering:
            HStack(spacing: 8) {
                Muted("It keeps rendering if you close the app.")
                Spacer(minLength: 4)
                LinkText("Open queue") { store.go(.queue) }
            }
        case .idle, .failed:
            EmptyView()
        }
    }
}

/// Waiting to start: a soft segment gliding along the track (no progress to show yet).
private struct WaitingBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var x: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white.opacity(0.85)).frame(width: g.size.width * 0.3)
                    .offset(x: x * g.size.width * 0.7)
            }
        }
        .frame(height: 4)
        .clipShape(Capsule())
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { x = 1 }
        }
    }
}

/// The busy stage's picture: blurred, breathing slowly, with a soft light passing over it.
struct BlurredStageArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var ref: ImageRef?
    var moving: Bool
    @State private var on = false

    var body: some View {
        let animate = moving && !reduceMotion
        GeometryReader { g in
            MuseImage(ref: ref)
                .blur(radius: 16, opaque: true)
                .scaleEffect(on ? 1.14 : 1.04)
                .overlay(Color.black.opacity(0.3))
                .overlay(alignment: .top) {
                    if animate {
                        LinearGradient(colors: [.clear, .white.opacity(0.16), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: g.size.height * 0.45)
                            .offset(y: on ? g.size.height * 0.8 : -g.size.height * 0.25)
                    }
                }
                .frame(width: g.size.width, height: g.size.height)
                .clipped()
        }
        .onAppear {
            guard animate else { return }
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) { on = true }
        }
    }
}

/// A finished take playing inline: muted by default, looping, no controls, the take's still underneath while it loads.
struct StageVideo: View {
    var url: URL
    var poster: ImageRef?
    var muted: Bool
    @State private var looper: StageLooper?

    var body: some View {
        ZStack {
            MuseImage(ref: poster)
            if let looper { PlayerLayerView(player: looper.player).allowsHitTesting(false) }
        }
        .onAppear { start() }
        .onChange(of: url) { start() }
        .onChange(of: muted) { looper?.player.isMuted = muted }
        .onDisappear {
            looper?.stop()
            looper = nil
        }
    }

    private func start() {
        looper?.stop()
        looper = StageLooper(url: url, muted: muted)
    }
}

/// AVQueuePlayer + AVPlayerLooper: plays one take over and over.
@MainActor
final class StageLooper {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    init(url: URL, muted: Bool) {
        player.isMuted = muted
        player.preventsDisplaySleepDuringVideoPlayback = false
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.play()
    }

    func stop() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
    }
}

/// An AVPlayerLayer filling its frame (aspect fill, no controls).
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerNSView {
        let v = PlayerNSView(frame: .zero)
        v.player = player
        return v
    }

    func updateNSView(_ v: PlayerNSView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

final class PlayerNSView: NSView {
    private let playerLayer = AVPlayerLayer()

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { return nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

/// The empty source area before a clip is uploaded: drop a clip here, or click to choose one.
struct ClipDropZone: View {
    @Environment(\.theme) private var t
    var targeted: Bool
    var action: () -> Void

    var body: some View {
        let radius = t.isA ? 0 : t.imageRadius
        Button(action: action) {
            Color.clear.aspectRatio(9.0 / 16.0, contentMode: .fit)
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 22))
                        Text(StudioText.dropTitle).font(t.body(13, .semibold))
                        Text(StudioText.dropHint).font(t.body(11.5)).foregroundStyle(t.muted)
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(targeted ? t.accent : t.ink)
                    .padding(14)
                )
                .background(RoundedRectangle(cornerRadius: radius).fill(targeted ? t.accent.opacity(0.08) : t.surface2.opacity(0.5)))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(targeted ? t.accent : t.strongLine, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(StudioText.dropTitle). \(StudioText.dropHint)")
    }
}

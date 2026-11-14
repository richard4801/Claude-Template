import AppKit
import AVFoundation
import MuseCore
import SwiftUI

// The take viewer (plans/swap-viewer-design.md §B, owner-approved 2026-11-12): one viewer wherever a take, a clip or an
// image is shown (the Suite's stage, Takes, Compare, the Library and New Swap's source).
// - The frame is the media's own shape: a portrait take sits in a portrait frame, never a letterbox.
// - A clean player: no platform layouts, device frames or safe zones (owner 2026-11-12: those are Edit's, see
//   Views/Edit/EditPlatformChrome.swift and plans/edit-platform-preview.md).
// - No scrubber, no loader bar: Space plays or pauses, ← → jump 3 s (⇧ 10 s), J/K/L shuttle, , . step a frame, M mutes,
//   F is full screen, ↑ ↓ change take, Esc closes. A small readout ("+3 s  0:07 / 0:10") shows briefly while seeking.
// - The take's actions (Keep, Redo, Extend, Upscale, Split, Share, More): a rail beside portrait media, a row under
//   landscape media; labels give way in a set order (Split, Upscale, Extend, Redo), so nothing is ever cut.

/// What the viewer shows.
struct ViewerMedia: Equatable {
    var id: String
    var videoURL: URL?
    var poster: ImageRef?
    var width: Int?
    var height: Int?
    var label: String

    var aspect: Double { ViewerFrame.aspect(width: width, height: height, isVideo: videoURL != nil) }

    init(id: String, videoURL: URL?, poster: ImageRef?, width: Int?, height: Int?, label: String) {
        self.id = id
        self.videoURL = videoURL
        self.poster = poster
        self.width = width
        self.height = height
        self.label = label
    }

    init(take: Take) {
        self.init(id: take.id, videoURL: take.videoUrl.flatMap(URL.init(string:)), poster: take.thumb, width: take.width, height: take.height,
                  label: take.displayLabel)
    }
}

// MARK: Playback

/// One AVPlayer and the viewer's transport. Loops, so a short take keeps playing; nothing on screen shows its position
/// except the brief readout while seeking.
@MainActor @Observable
final class ViewerPlayback {
    let player = AVPlayer()
    private(set) var playing = false
    private(set) var muted = false
    /// The brief readout while seeking ("+3 s  0:07 / 0:10"); nil when hidden.
    private(set) var readout: String?
    /// Over the poster for more than 600 ms while loading: a small ring in the corner.
    private(set) var slowLoad = false
    var transport = ViewerTransport()
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var readoutTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    var duration: Double {
        let d = player.currentItem?.duration.seconds ?? 0
        return d.isFinite ? d : 0
    }

    var time: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? t : 0
    }

    func load(_ url: URL?, autoplay: Bool, muted: Bool) {
        guard url != self.url else { return }
        self.url = url
        player.pause()
        playing = false
        transport = ViewerTransport()
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        endObserver = nil
        loadTask?.cancel()
        slowLoad = false
        guard let url else {
            player.replaceCurrentItem(with: nil)
            return
        }
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.actionAtItemEnd = .none
        player.preventsDisplaySleepDuringVideoPlayback = true
        setMuted(muted)
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.looped() }
        }
        loadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.player.currentItem?.status != .readyToPlay { self.slowLoad = true }
            while !Task.isCancelled, self.player.currentItem?.status == .unknown { try? await Task.sleep(nanoseconds: 100_000_000) }
            self.slowLoad = false
        }
        if autoplay { play() }
    }

    func release() { load(nil, autoplay: false, muted: muted) }

    func setMuted(_ m: Bool) {
        muted = m
        player.isMuted = m
    }

    func play() {
        guard player.currentItem != nil else { return }
        player.rate = 1
        playing = true
    }

    func pause() {
        player.pause()
        playing = false
    }

    func togglePlay() { playing ? pause() : play() }

    /// From the start (Compare's "Play both").
    func restart() {
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        play()
    }

    private func looped() {
        player.seek(to: .zero)
        if playing { player.rate = transport.shuttle > 0 ? Float(transport.shuttle) : 1 }
    }

    /// Run a key's command. Navigation and closing are the host's (returns false for them).
    func run(_ c: ViewerCommand) -> Bool {
        switch c {
        case .togglePlay: togglePlay()
        case .jump(let d): seek(by: d)
        case .shuttle(let r): shuttle(r)
        case .frame(let n):
            pause()
            player.currentItem?.step(byCount: n)
            show(nil)
        case .toStart: seek(to: 0, delta: nil)
        case .toEnd: seek(to: max(0, duration - 0.05), delta: nil)
        case .mute: setMuted(!muted)
        case .fullScreen: NSApp.keyWindow?.toggleFullScreen(nil)
        case .previousTake, .nextTake, .close: return false
        }
        return true
    }

    func seek(by d: Double) {
        let to = ViewerTransport.seek(time, by: d, duration: duration)
        seek(to: to, delta: d)
    }

    private func seek(to t: Double, delta: Double?) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        readout = ViewerTransport.readout(delta: delta, time: t, duration: duration)
        hideReadoutSoon()
    }

    private func shuttle(_ r: Double) {
        if r == 0 {
            pause()
            show(nil)
            return
        }
        if r < 0, player.currentItem?.canPlayReverse != true {
            seek(by: -ViewerTransport.jump) // can't play backwards: jump back instead
            return
        }
        player.rate = Float(r)
        playing = true
        readout = ViewerTransport.shuttleLabel(r)
        hideReadoutSoon()
    }

    private func show(_ delta: Double?) {
        readout = ViewerTransport.readout(delta: delta, time: time, duration: duration)
        hideReadoutSoon()
    }

    private func hideReadoutSoon() {
        readoutTask?.cancel()
        readoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.readout = nil
        }
    }
}

/// An AVPlayerLayer filling its frame (the frame is already the media's shape, or the phone's screen for a platform
/// layout, which crops the sides as those apps do).
struct ViewerPlayerLayer: NSViewRepresentable {
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

// MARK: The viewer

struct TakeViewer: View {
    @Environment(\.theme) private var t
    var media: ViewerMedia
    var context: TakeViewerContext
    /// The take, for its actions (nil: a clip or an image with no actions).
    var take: Take? = nil
    /// The take's job (Redo needs it).
    var job: Job? = nil
    /// A small pane (the stage, Compare): the actions go under the media.
    var compact = false
    var autoplay = true
    var startMuted = false
    /// ↑ ↓: the previous or next take (nil: no list).
    var onStep: ((Int) -> Void)? = nil
    /// Esc (nil: nothing to close).
    var onClose: (() -> Void)? = nil
    /// A player owned by the host (Compare plays two together); nil: the viewer's own.
    var sharedPlayback: ViewerPlayback? = nil

    @State private var ownPlayback = ViewerPlayback()
    private var playback: ViewerPlayback { sharedPlayback ?? ownPlayback }
    @FocusState private var focused: Bool

    private var aspect: Double { media.aspect }
    private var landscape: Bool { PreviewSkin.isLandscape(aspect) }
    private var actions: [TakeViewerAction] {
        guard let take else { return [] }
        return TakeViewerActions.list(context, isVideo: take.isVideo, canRedo: job != nil, canExtend: ExtendSource.take(take) != nil,
                                      canUpscale: take.canUpscale)
    }

    var body: some View {
        VStack(spacing: compact ? Space.s2 : Space.s3) {
            GeometryReader { g in
                // Beside portrait media when there's room for it and a 240 pt picture; otherwise the row under it.
                let rail = !compact && !landscape && !actions.isEmpty && g.size.width >= 2 * (Self.railWidth + Space.s7) + 240
                if rail {
                    HStack(alignment: .center, spacing: Space.s7) {
                        Color.clear.frame(width: Self.railWidth) // balances the rail, so the media stays centred
                        mediaArea(width: g.size.width - 2 * (Self.railWidth + Space.s7), height: g.size.height)
                        ViewerActionRail(take: take!, job: job, actions: actions, time: { playback.time })
                            .frame(width: Self.railWidth)
                    }
                    .frame(width: g.size.width, height: g.size.height)
                } else {
                    // The row has a fixed height, so the media always gets the rest (build 582: a menu label grew and
                    // pushed the take off the stage).
                    let rowH: CGFloat = actions.isEmpty ? 0 : ViewerActionRow.height + Space.s3
                    VStack(spacing: Space.s3) {
                        mediaArea(width: g.size.width, height: g.size.height - rowH)
                        if let take, !actions.isEmpty {
                            ViewerActionRow(take: take, job: job, actions: actions, more: context != .compare, time: { playback.time })
                                .frame(width: g.size.width, height: ViewerActionRow.height)
                        }
                    }
                    .frame(width: g.size.width, height: g.size.height, alignment: .top)
                }
            }
            .frame(minHeight: 160)
            .layoutPriority(1)
        }
        .clipped()
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat, .up]) { press in key(press) }
        .onAppear {
            playback.load(media.videoURL, autoplay: autoplay, muted: startMuted)
            if context != .source { focused = true }
        }
        .onChange(of: media.videoURL) { _, u in playback.load(u, autoplay: autoplay, muted: playback.muted) }
        .onDisappear { playback.release() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(media.label)
    }

    private static let railWidth: CGFloat = 176

    // MARK: Media in its frame

    /// The media at its own shape, fitted: never a letterbox, nothing drawn over it but the seek readout.
    private func mediaArea(width: CGFloat, height: CGFloat) -> some View {
        let f = ViewerFrame.fit(aspect: aspect, width: max(0, Double(width)), height: max(0, Double(height)))
        return surface
            .frame(width: f.w, height: f.h)
            .clipShape(RoundedRectangle(cornerRadius: t.radii.container))
            .overlay(alignment: .center) { readout }
            .frame(width: max(0, width), height: max(0, height))
            .contentShape(Rectangle())
            .onTapGesture {
                focused = true
                if media.videoURL != nil { playback.togglePlay() }
            }
    }

    /// The media itself: the poster, the video over it, the slow-load ring in the corner.
    private var surface: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.black
            MuseImage(ref: media.poster)
            if media.videoURL != nil { ViewerPlayerLayer(player: playback.player).allowsHitTesting(false) }
            if playback.slowLoad {
                ProgressView().controlSize(.small).tint(.white).padding(Space.s3).accessibilityLabel("Loading")
            }
        }
        .accessibilityLabel(media.label)
    }

    @ViewBuilder private var readout: some View {
        if let r = playback.readout {
            Text(r).font(t.scale.caption.font).monospacedDigit().foregroundStyle(.white)
                .padding(.horizontal, Space.s3).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: t.radii.chip).fill(.black.opacity(0.6)))
                .transition(.opacity)
                .accessibilityLabel(r)
                .allowsHitTesting(false)
        }
    }

    // MARK: Keys

    private func key(_ press: KeyPress) -> KeyPress.Result {
        let shift = press.modifiers.contains(.shift)
        guard press.modifiers.subtracting([.shift, .capsLock, .numericPad, .function]).isEmpty else { return .ignored } // ⌘ shortcuts go to the app
        let k: ViewerKey
        switch press.key {
        case .space: k = .space
        case .leftArrow: k = .left
        case .rightArrow: k = .right
        case .upArrow: k = .up
        case .downArrow: k = .down
        case .home: k = .home
        case .end: k = .end
        case .escape: k = .escape
        default:
            guard let c = press.characters.first else { return .ignored }
            if c.lowercased() == "k" { playback.transport.kHeld = press.phase != .up }
            k = .character(c)
        }
        if press.phase == .up { return k == .character("k") || k == .character("K") ? .handled : .ignored }
        // A held key repeats only seeking and stepping (arrows, J/L, , .); toggles (Space, M, F, K) fire once.
        if press.phase == .repeat {
            switch k {
            case .left, .right, .up, .down: break
            case .character(let c) where ",.jlJL".contains(c): break
            default: return .handled
            }
        }
        let hasVideo = media.videoURL != nil
        guard let cmd = playback.transport.command(for: k, shift: shift) else { return .ignored }
        switch cmd {
        case .previousTake:
            guard let onStep else { return .ignored }
            onStep(-1)
        case .nextTake:
            guard let onStep else { return .ignored }
            onStep(1)
        case .close:
            guard let onClose else { return .ignored }
            onClose()
        case .fullScreen, .mute:
            _ = playback.run(cmd)
        default:
            guard hasVideo else { return .ignored }
            _ = playback.run(cmd)
        }
        return .handled
    }
}

// MARK: Actions

/// One take action: icon and label, or the icon alone with the label as its tooltip.
struct ViewerActionButton: View {
    @Environment(\.theme) private var t
    /// The Suite stage (redesign): Keep outlined on the raised tone, the rest plain (Generate is the one filled button).
    @Environment(\.viewerStageStyle) private var stageStyle
    var action: TakeViewerAction
    var title: String? = nil
    var iconOnly = false
    var primary = false
    var off = false
    var fullWidth = false
    var run: () -> Void

    static func icon(_ a: TakeViewerAction) -> String {
        switch a {
        case .keep: return "check"
        case .redo: return "arrow-clockwise"
        case .extend: return "arrow-line-right"
        case .upscale: return "arrows-out-simple"
        case .split: return "scissors"
        case .useInShot: return "video-camera"
        case .share: return "export"
        }
    }

    var body: some View {
        let label = title ?? action.title
        Button(action: run) {
            HStack(spacing: Space.s2) {
                Ph(Self.icon(action), 15)
                if !iconOnly { Text(label).font(t.scale.label.font).lineLimit(1).fixedSize() }
                if fullWidth { Spacer(minLength: 0) }
            }
            .padding(.horizontal, iconOnly ? 0 : Space.s3)
            .frame(width: iconOnly ? 36 : nil, height: primary ? 40 : 36)
            .frame(maxWidth: fullWidth ? .infinity : nil, alignment: primary ? .center : .leading)
            .foregroundStyle(primary && !stageStyle ? t.roles.onAction : t.roles.ink)
            .background(RoundedRectangle(cornerRadius: t.radii.control).fill(primary ? (stageStyle ? t.roles.raised : t.roles.action) : .clear))
            .overlay {
                if !primary && !stageStyle || primary && stageStyle {
                    RoundedRectangle(cornerRadius: t.radii.control).strokeBorder(stageStyle ? t.roles.ink.opacity(0.35) : t.roles.hairline, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .opacity(off ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(off)
        .help(action.help)
        .accessibilityLabel(label)
    }
}

/// What each action does (shared by the rail and the row).
@MainActor
private struct ViewerActionRunner {
    let store: AppStore
    let take: Take
    let job: Job?
    let time: () -> Double

    func run(_ a: TakeViewerAction) {
        switch a {
        case .keep: store.approve(take)
        case .redo: if let job { store.retakeShot(job) }
        case .extend: store.openExtend(take)
        case .upscale: break // the Upscale button opens its own picker
        case .split: store.openEdit(takeId: take.id, at: time()) // owner 2026-11-12: Edit at this moment
        case .useInShot: store.useAsStartFrame(take) // Photo tab (owner 2026-11-14): the still opens Shot as its start frame
        case .share: store.openPostSheet(take)
        }
    }
}

/// More: everything else this take can do (in a small pane, also the actions that didn't fit), and why a hidden action
/// isn't offered. A button with a popover, never a `Menu`: a macOS menu label drops the icon's frame and draws it huge
/// (build 582's giant chevron and dots).
struct ViewerMoreMenu: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var take: Take
    var job: Job?
    var fullWidth = false
    var iconOnly = false
    /// Actions shown here because the row had no room for them (Redo, Extend, Split).
    var extra: [TakeViewerAction] = []
    var time: () -> Double = { 0 }
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: Space.s2) {
                Ph("dots-three", 15).frame(width: 18, height: 18)
                if !iconOnly { Text("More").font(t.scale.label.font).lineLimit(1).fixedSize() }
                if fullWidth { Spacer(minLength: 0) }
            }
            .foregroundStyle(t.roles.ink2)
            .padding(.horizontal, iconOnly ? 0 : Space.s3)
            .frame(width: iconOnly ? 36 : nil, height: 36)
            .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: !fullWidth, vertical: true)
        .help("More for this take")
        .accessibilityLabel("More for this take")
        .popover(isPresented: $open, arrowEdge: .bottom) { list.environment(store).environment(\.theme, t) }
    }

    private var list: some View {
        let runner = ViewerActionRunner(store: store, take: take, job: job, time: time)
        let why = TakeViewerActions.hiddenReasons(isVideo: take.isVideo, canRedo: job != nil, canExtend: ExtendSource.take(take) != nil,
                                                  canUpscale: take.canUpscale, isMaxResolution: (take.height ?? 0) >= 2160 || (take.width ?? 0) >= 2160)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(extra.filter { $0 != .upscale && $0 != .keep }, id: \.self) { a in item(a.title) { runner.run(a) } }
            if !extra.isEmpty { Divider().padding(.vertical, Space.s1) }
            item("Vary") { store.vary(take) }
            item("Reuse settings") { if !store.reuseSettings(take) { store.showToast("This take was made before Reuse settings") } }
            if take.isVideo { item("Use as start frame") { store.useAsStartFrame(take) } }
            item(store.suite.compareIds.contains(take.id) ? "Remove from compare" : "Compare") { store.compareInSuite(take) }
            if take.isVideo { item("Open in Edit") { store.openEdit(takeId: take.id) } }
            item("Download") { store.export(take) }
            if !why.isEmpty {
                Divider().padding(.vertical, Space.s1)
                ForEach(why, id: \.self) { Text($0).font(t.scale.caption.font).foregroundStyle(t.roles.ink2).padding(.horizontal, Space.s3).padding(.vertical, 2)
                    .fixedSize(horizontal: false, vertical: true) }
            }
        }
        .padding(.vertical, Space.s2)
        .frame(width: 240, alignment: .leading)
    }

    private func item(_ title: String, _ run: @escaping () -> Void) -> some View {
        Button {
            open = false
            run()
        } label: {
            Text(title).font(t.scale.label.font).foregroundStyle(t.roles.ink)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .padding(.horizontal, Space.s3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Upscale in the viewer's own button style (the shared UpscaleButton draws an SF Symbol in another style); its picker
/// opens in a popover as before.
struct ViewerUpscaleButton: View {
    @Environment(AppStore.self) private var store
    var take: Take
    var iconOnly = false
    var fullWidth = false
    @State private var open = false

    var body: some View {
        ViewerActionButton(action: .upscale, title: store.upscaleLive ? "Upscale" : "Upscale · soon", iconOnly: iconOnly, off: store.upscaling,
                           fullWidth: fullWidth) { open = true }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                UpscalePicker(take: take) { open = false }
                    .environment(store)
                    .environment(\.theme, PickerTheme.dark)
                    .environment(\.colorScheme, .dark)
            }
    }
}

/// Beside portrait media: Keep (the one filled button), then one quiet button per action, More, and the take's details.
struct ViewerActionRail: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var take: Take
    var job: Job?
    var actions: [TakeViewerAction]
    var time: () -> Double

    var body: some View {
        let runner = ViewerActionRunner(store: store, take: take, job: job, time: time)
        VStack(alignment: .leading, spacing: Space.s2) {
            ForEach(actions, id: \.self) { a in
                if a == .upscale {
                    ViewerUpscaleButton(take: take, fullWidth: true)
                } else if a == .keep {
                    ViewerActionButton(action: a, title: take.isFinal ? "Kept" : "Keep", primary: true, off: take.isFinal, fullWidth: true) { runner.run(a) }
                } else {
                    ViewerActionButton(action: a, fullWidth: true) { runner.run(a) }
                }
            }
            ViewerMoreMenu(take: take, job: job, fullWidth: true, time: time)
            Text(details).font(t.scale.caption.font).monospacedDigit().foregroundStyle(t.roles.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.s4)
        }
    }

    /// "9:16 · 10 s", the size, the price: one per line.
    private var details: String {
        var lines: [String] = []
        let shape = SuiteFeedText.aspect(width: take.width.map(Double.init), height: take.height.map(Double.init))
        let secs = take.durationSec.map { "\(Pricing.trimNum($0)) s" }
        lines.append([shape, secs].compactMap { $0 }.joined(separator: " · "))
        if let w = take.width, let h = take.height { lines.append("\(w) × \(h)") }
        if take.cost > 0 { lines.append(Pricing.money(take.cost)) }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Under landscape media (and in small panes): the same buttons in a row. Labels give way in a set order (Split,
/// Upscale, Extend, Redo); Keep and Share always keep theirs.
struct ViewerActionRow: View {
    @Environment(AppStore.self) private var store
    static let height: CGFloat = 40
    var take: Take
    var job: Job?
    var actions: [TakeViewerAction]
    var more = true
    var time: () -> Double
    /// Where the row sits in its frame (the Suite stage puts it on the right of the title).
    var alignment: Alignment = .center

    var body: some View {
        let steps = TakeViewerActions.steps(actions)
        // Each step one candidate: all labels, then Split, Upscale, Extend and Redo give theirs up; narrowest of all,
        // Keep and Share stay and everything else is in More. Every candidate is fixed-size, so nothing is ever cut.
        ViewThatFits(in: .horizontal) {
            row(iconOnly: steps[0]).fixedSize()
            if steps.count > 1 { row(iconOnly: steps[1]).fixedSize() }
            if steps.count > 2 { row(iconOnly: steps[2]).fixedSize() }
            if steps.count > 3 { row(iconOnly: steps[3]).fixedSize() }
            if steps.count > 4 { row(iconOnly: steps[4]).fixedSize() }
            narrowest.fixedSize()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    private func row(iconOnly: Set<TakeViewerAction>) -> some View {
        let runner = ViewerActionRunner(store: store, take: take, job: job, time: time)
        return HStack(spacing: Space.s2) {
            ForEach(actions, id: \.self) { a in
                if a == .upscale {
                    ViewerUpscaleButton(take: take, iconOnly: iconOnly.contains(a))
                } else if a == .keep {
                    ViewerActionButton(action: a, title: take.isFinal ? "Kept" : "Keep", primary: true, off: take.isFinal) { runner.run(a) }
                } else {
                    ViewerActionButton(action: a, iconOnly: iconOnly.contains(a)) { runner.run(a) }
                }
            }
            if more { ViewerMoreMenu(take: take, job: job, iconOnly: !iconOnly.isEmpty, time: time) }
        }
    }

    /// Keep and Share as icons with Keep's label, and More holding the rest.
    private var narrowest: some View {
        let runner = ViewerActionRunner(store: store, take: take, job: job, time: time)
        let rest = actions.filter { $0 != .keep && $0 != .share }
        return HStack(spacing: Space.s2) {
            if actions.contains(.keep) {
                ViewerActionButton(action: .keep, title: take.isFinal ? "Kept" : "Keep", primary: true, off: take.isFinal) { runner.run(.keep) }
            }
            if actions.contains(.upscale) { ViewerUpscaleButton(take: take, iconOnly: true) }
            if actions.contains(.share) { ViewerActionButton(action: .share, iconOnly: true) { runner.run(.share) } }
            if more || !rest.isEmpty { ViewerMoreMenu(take: take, job: job, iconOnly: true, extra: rest, time: time) }
        }
    }
}

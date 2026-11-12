import AppKit
import AVFoundation
import MuseCore
import SwiftUI

// The take viewer (plans/swap-viewer-design.md §B, owner-approved 2026-11-12): one viewer wherever a take, a clip or an
// image is shown (the Suite's stage, Takes, Compare, the Library and New Swap's source).
// - The frame is the media's own shape: a portrait take sits in a portrait frame, never a letterbox.
// - Preview: Clean, or a generic drawing of TikTok, Reels, Shorts or Facebook (portrait) / YouTube or Facebook
//   (landscape), in an optional phone or laptop frame, with the safe zones on request. Remembered per device.
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

// MARK: Remembered choices

/// The viewer's per-device choices (owner 2026-11-12): the skin per shape, the device frame and the safe zones.
private struct ViewerPrefsKey {
    static let key = "viewer.prefs"

    static func read(_ raw: String) -> ViewerPrefs {
        (try? JSONDecoder().decode(ViewerPrefs.self, from: Data(raw.utf8))) ?? ViewerPrefs()
    }

    static func write(_ p: ViewerPrefs) -> String {
        (try? String(decoding: JSONEncoder().encode(p), as: UTF8.self)) ?? ""
    }
}

/// The server's safe-zone table, fetched once per launch (defaults until then, and offline).
@MainActor
enum ViewerLayouts {
    private(set) static var current = PreviewLayouts.defaults
    private static var loaded = false

    static func load(_ api: any MuseAPI) async {
        guard !loaded else { return }
        loaded = true
        current = await api.previewLayouts()
    }
}

// MARK: The viewer

struct TakeViewer: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var media: ViewerMedia
    var context: TakeViewerContext
    /// The take, for its actions (nil: a clip or an image with no actions).
    var take: Take? = nil
    /// The take's job (Redo needs it).
    var job: Job? = nil
    /// A small pane (the stage, Compare): the preview choice is one menu and the actions go under the media.
    var compact = false
    var autoplay = true
    var startMuted = false
    /// ↑ ↓: the previous or next take (nil: no list).
    var onStep: ((Int) -> Void)? = nil
    /// Esc (nil: nothing to close).
    var onClose: (() -> Void)? = nil
    /// The preview choices (Clean, the platform layouts, the frame, safe zones); off for New Swap's source clip.
    var previewControls = true
    /// A player owned by the host (Compare plays two together); nil: the viewer's own.
    var sharedPlayback: ViewerPlayback? = nil

    @State private var ownPlayback = ViewerPlayback()
    private var playback: ViewerPlayback { sharedPlayback ?? ownPlayback }
    @AppStorage(ViewerPrefsKey.key) private var prefsRaw = ""
    @FocusState private var focused: Bool
    @State private var layouts = ViewerLayouts.current

    private var prefs: ViewerPrefs { ViewerPrefsKey.read(prefsRaw) }
    private func update(_ f: (inout ViewerPrefs) -> Void) {
        var p = prefs
        f(&p)
        prefsRaw = ViewerPrefsKey.write(p)
    }

    private var aspect: Double { media.aspect }
    private var landscape: Bool { PreviewSkin.isLandscape(aspect) }
    private var skin: PreviewSkin { previewControls ? prefs.skin(aspect: aspect) : .clean }
    private var actions: [TakeViewerAction] {
        guard let take else { return [] }
        return TakeViewerActions.list(context, isVideo: take.isVideo, canRedo: job != nil, canExtend: ExtendSource.take(take) != nil,
                                      canUpscale: take.canUpscale)
    }

    var body: some View {
        VStack(spacing: compact ? Space.s2 : Space.s3) {
            if !compact && previewControls { previewBar.frame(maxWidth: .infinity).frame(height: 32) }
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
        .task { await ViewerLayouts.load(store.api); layouts = ViewerLayouts.current }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(media.label)
    }

    private static let railWidth: CGFloat = 176

    // MARK: Media in its frame

    @ViewBuilder private func mediaArea(width: CGFloat, height: CGFloat) -> some View {
        let w = max(0, Double(width)), h = max(0, Double(height))
        Group {
            if previewControls && prefs.deviceFrame && !landscape {
                let sw = ViewerFrame.phoneScreenWidth(width: w, height: h)
                PhoneFrame(screenWidth: sw) { screen(width: sw, height: sw / ViewerFrame.phoneScreenAspect) }
            } else if previewControls && prefs.deviceFrame && landscape {
                let lw = min(w / 1.16, (h - 24) * ViewerFrame.laptopScreenAspect / 1.04)
                LaptopFrame(screenWidth: max(0, lw)) { laptopScreen(width: max(0, lw), height: max(0, lw) / ViewerFrame.laptopScreenAspect) }
            } else {
                let f = ViewerFrame.fit(aspect: aspect, width: w, height: h)
                surface
                    .frame(width: f.w, height: f.h)
                    .overlay { if skin != .clean && !landscape { skinLayer(width: f.w, height: f.h) } }
                    .clipShape(RoundedRectangle(cornerRadius: t.radii.container))
                    .overlay(alignment: .center) { readout }
            }
        }
        .frame(width: max(0, width), height: max(0, height))
        .contentShape(Rectangle())
        .onTapGesture {
            focused = true
            if media.videoURL != nil { playback.togglePlay() }
        }
        .overlay(alignment: .topTrailing) {
            if compact && previewControls {
                ViewerPreviewButton(skin: skin, aspect: aspect, prefsRaw: $prefsRaw, hasZones: layouts.zone(skin) != nil, onMedia: true)
                    .padding(Space.s2)
            }
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

    /// The phone's screen: a platform layout fills it (cropping a 9:16 take's sides, as those apps do on tall phones);
    /// Clean fits it with black above and below, as a phone's own player does.
    private func screen(width: Double, height: Double) -> some View {
        let fill = ViewerFrame.fillsScreen(skin)
        let f = fill ? (w: width, h: height) : ViewerFrame.fit(aspect: aspect, width: width, height: height)
        return ZStack {
            Color.black
            surface.frame(width: f.w, height: f.h).clipped()
            if skin != .clean { skinLayer(width: width, height: height) }
            readout
        }
        .frame(width: width, height: height)
    }

    private func laptopScreen(width: Double, height: Double) -> some View {
        ZStack {
            if skin == .clean {
                Color.black
                let f = ViewerFrame.fit(aspect: aspect, width: width, height: height)
                surface.frame(width: f.w, height: f.h).clipped()
            } else {
                DesktopSkin(skin: skin, width: width, height: height) { w, h in surface.frame(width: w, height: h).clipped() }
            }
            readout
        }
        .frame(width: width, height: height)
    }

    @ViewBuilder private func skinLayer(width: Double, height: Double) -> some View {
        PhoneSkin(skin: skin, width: width, height: height)
        if prefs.safeZones, let z = layouts.zone(skin) { SafeZoneLayer(zone: z).allowsHitTesting(false) }
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

    // MARK: Preview controls

    /// Clean · TikTok · Reels · Shorts · Facebook (or Clean · YouTube · Facebook), the frame switch and the safe zones.
    /// Narrow: the switches fold into the Preview button, then the whole bar does.
    private var previewBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.s4) { skinPicker; frameToggle; zonesToggle }.fixedSize()
            HStack(spacing: Space.s3) { skinPicker; ViewerPreviewButton(skin: skin, aspect: aspect, prefsRaw: $prefsRaw, hasZones: layouts.zone(skin) != nil, switchesOnly: true) }.fixedSize()
            ViewerPreviewButton(skin: skin, aspect: aspect, prefsRaw: $prefsRaw, hasZones: layouts.zone(skin) != nil).fixedSize()
        }
    }

    private var skinPicker: some View {
        Picker("Preview as", selection: Binding(get: { skin }, set: { s in update { $0.setSkin(s, aspect: aspect) } })) {
            ForEach(PreviewSkin.options(aspect: aspect), id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Preview as it would look on each app (a generic drawing of its layout)")
    }

    private var frameToggle: some View {
        Toggle(landscape ? "Laptop frame" : "Phone frame", isOn: Binding(get: { prefs.deviceFrame }, set: { v in update { $0.deviceFrame = v } }))
            .toggleStyle(.switch).controlSize(.small)
            .font(t.scale.label.font)
            .fixedSize()
    }

    private var zonesToggle: some View {
        Toggle("Safe zones", isOn: Binding(get: { prefs.safeZones }, set: { v in update { $0.safeZones = v } }))
            .toggleStyle(.switch).controlSize(.small)
            .font(t.scale.label.font)
            .fixedSize()
            .disabled(layouts.zone(skin) == nil)
            .help(layouts.note ?? "Where each app's own buttons and captions sit")
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

// MARK: Device frames

/// A generic phone: a rounded body, an even bezel and a round front camera (no maker's shapes).
struct PhoneFrame<Screen: View>: View {
    var screenWidth: Double
    @ViewBuilder var screen: () -> Screen

    var body: some View {
        let bezel = ViewerFrame.phoneBezel(screenWidth: screenWidth)
        let r = ViewerFrame.phoneRadius(screenWidth: screenWidth)
        let k = screenWidth / 300
        screen()
            .overlay(alignment: .top) {
                Circle().fill(.black).frame(width: 10 * k, height: 10 * k)
                    .overlay(Circle().strokeBorder(Color(white: 0.13), lineWidth: 1))
                    .padding(.top, 10 * k)
            }
            .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
            .padding(bezel)
            .background(RoundedRectangle(cornerRadius: r + bezel, style: .continuous).fill(Color(white: 0.04)))
            .overlay(RoundedRectangle(cornerRadius: r + bezel, style: .continuous).strokeBorder(Color(red: 0.23, green: 0.24, blue: 0.25), lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Phone preview")
    }
}

/// A generic laptop: a screen with a thin bezel on a wider base.
struct LaptopFrame<Screen: View>: View {
    var screenWidth: Double
    @ViewBuilder var screen: () -> Screen

    var body: some View {
        let edge = Color(red: 0.23, green: 0.24, blue: 0.25)
        VStack(spacing: 0) {
            screen()
                .padding(screenWidth * 0.018)
                .background(UnevenRoundedRectangle(topLeadingRadius: screenWidth * 0.025, bottomLeadingRadius: 4, bottomTrailingRadius: 4,
                                                   topTrailingRadius: screenWidth * 0.025).fill(Color(white: 0.04)))
                .overlay(UnevenRoundedRectangle(topLeadingRadius: screenWidth * 0.025, bottomLeadingRadius: 4, bottomTrailingRadius: 4,
                                                topTrailingRadius: screenWidth * 0.025).strokeBorder(edge, lineWidth: 1))
            UnevenRoundedRectangle(bottomLeadingRadius: screenWidth * 0.03, bottomTrailingRadius: screenWidth * 0.03)
                .fill(Color(red: 0.16, green: 0.17, blue: 0.18))
                .overlay(UnevenRoundedRectangle(bottomLeadingRadius: screenWidth * 0.03, bottomTrailingRadius: screenWidth * 0.03).strokeBorder(edge, lineWidth: 1))
                .frame(width: screenWidth * 1.16, height: max(8, screenWidth * 0.022))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Laptop preview")
    }
}

// MARK: Platform layouts (generic drawings: grey bars for text, Phosphor glyphs for buttons; no logos or brand colours)

private struct Bar: View {
    var w: Double
    var h: Double
    var dim = false
    var body: some View { RoundedRectangle(cornerRadius: h / 2).fill(.white.opacity(dim ? 0.55 : 0.85)).frame(width: w, height: h) }
}

private struct Glyph: View {
    var name: String
    var size: Double
    var count = true
    var body: some View {
        VStack(spacing: size * 0.12) {
            Ph(name, size * 0.8).foregroundStyle(.white)
            if count { Bar(w: size * 0.7, h: max(3, size * 0.2)) }
        }
    }
}

/// A phone app's layout over the take: top bar, the right-hand rail, the caption block and the bottom navigation.
struct PhoneSkin: View {
    var skin: PreviewSkin
    var width: Double
    var height: Double

    var body: some View {
        let k = width / 300
        let nav = 56 * k
        let icon = 26 * k
        ZStack(alignment: .topLeading) {
            // status bar
            HStack { Bar(w: 28 * k, h: 7 * k); Spacer(); Bar(w: 40 * k, h: 7 * k) }
                .padding(.horizontal, 18 * k).padding(.top, 8 * k)
            top(k)
            rail(k, icon: icon)
                .padding(.trailing, 10 * k).padding(.bottom, nav + 16 * k)
                .frame(width: width, height: height, alignment: .bottomTrailing)
            caption(k)
                .padding(.leading, 12 * k).padding(.bottom, nav + 14 * k)
                .frame(width: width, height: height, alignment: .bottomLeading)
            HStack {
                ForEach(navIcons, id: \.self) { n in
                    Spacer(minLength: 0)
                    Ph(n, 18 * k).foregroundStyle(.white)
                    Spacer(minLength: 0)
                }
            }
            .padding(.bottom, 10 * k)
            .frame(width: width, height: nav)
            .background(Color.black.opacity(0.92))
            .frame(width: width, height: height, alignment: .bottom)
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var navIcons: [String] {
        switch skin {
        case .tiktok: return ["house", "users-three", "plus-square", "chat-circle", "user"]
        case .reels: return ["house", "magnifying-glass", "plus-square", "film-strip", "user-circle"]
        case .shorts: return ["house", "lightning", "plus-circle", "play-circle", "user-circle"]
        default: return ["house", "video", "users-three", "bag", "bell"]
        }
    }

    @ViewBuilder private func top(_ k: Double) -> some View {
        switch skin {
        case .tiktok:
            ZStack {
                HStack(spacing: 14 * k) { Bar(w: 50 * k, h: 8 * k, dim: true); Bar(w: 44 * k, h: 8 * k) }
                HStack { Spacer(); Ph("magnifying-glass", 18 * k).foregroundStyle(.white) }
            }
            .padding(.horizontal, 14 * k).padding(.top, 32 * k)
        case .reels:
            HStack { Bar(w: 54 * k, h: 10 * k); Spacer(); Ph("camera", 18 * k).foregroundStyle(.white) }
                .padding(.horizontal, 14 * k).padding(.top, 32 * k)
        case .shorts:
            HStack(spacing: 16 * k) { Spacer(); Ph("magnifying-glass", 18 * k); Ph("dots-three-vertical", 18 * k) }
                .foregroundStyle(.white).padding(.horizontal, 14 * k).padding(.top, 30 * k)
        default:
            HStack(spacing: 14 * k) { Ph("caret-left", 18 * k); Bar(w: 48 * k, h: 10 * k); Spacer(); Ph("magnifying-glass", 18 * k); Ph("user-circle", 18 * k) }
                .foregroundStyle(.white).padding(.horizontal, 14 * k).padding(.top, 30 * k)
        }
    }

    @ViewBuilder private func rail(_ k: Double, icon: Double) -> some View {
        switch skin {
        case .tiktok:
            VStack(spacing: 16 * k) {
                avatar(40 * k)
                Glyph(name: "heart", size: icon); Glyph(name: "chat-circle-dots", size: icon)
                Glyph(name: "bookmark-simple", size: icon); Glyph(name: "share-fat", size: icon)
                Circle().fill(Color(white: 0.2)).frame(width: 32 * k, height: 32 * k).overlay(Circle().strokeBorder(Color(white: 0.07), lineWidth: 5 * k))
            }
        case .reels:
            VStack(spacing: 18 * k) {
                Glyph(name: "heart", size: icon); Glyph(name: "chat-circle", size: icon); Glyph(name: "paper-plane-tilt", size: icon)
                Glyph(name: "dots-three-vertical", size: icon, count: false)
                RoundedRectangle(cornerRadius: 5 * k).fill(.white.opacity(0.6)).frame(width: 26 * k, height: 26 * k)
            }
        case .shorts:
            VStack(spacing: 16 * k) {
                Glyph(name: "thumbs-up", size: icon); Glyph(name: "thumbs-down", size: icon, count: false)
                Glyph(name: "chat-circle-dots", size: icon); Glyph(name: "share-fat", size: icon); Glyph(name: "arrows-clockwise", size: icon)
                RoundedRectangle(cornerRadius: 6 * k).fill(.white.opacity(0.6)).frame(width: 28 * k, height: 28 * k)
            }
        default:
            VStack(spacing: 18 * k) {
                Glyph(name: "thumbs-up", size: icon); Glyph(name: "chat-circle", size: icon); Glyph(name: "share-fat", size: icon)
                Glyph(name: "dots-three", size: icon, count: false)
            }
        }
    }

    private func caption(_ k: Double) -> some View {
        let w = width * 0.62
        return VStack(alignment: .leading, spacing: 6 * k) {
            switch skin {
            case .tiktok: Bar(w: w * 0.4, h: 9 * k)
            case .reels:
                HStack(spacing: 8 * k) { avatar(26 * k); Bar(w: w * 0.34, h: 9 * k)
                    RoundedRectangle(cornerRadius: 6 * k).strokeBorder(.white.opacity(0.8), lineWidth: 1.2 * k).frame(width: 46 * k, height: 20 * k) }
            case .shorts:
                HStack(spacing: 8 * k) { avatar(26 * k); Bar(w: w * 0.3, h: 9 * k); Capsule().fill(.white.opacity(0.9)).frame(width: 60 * k, height: 22 * k) }
            default:
                HStack(spacing: 8 * k) { avatar(26 * k); Bar(w: w * 0.3, h: 9 * k)
                    RoundedRectangle(cornerRadius: 6 * k).fill(.white.opacity(0.25)).frame(width: 44 * k, height: 20 * k) }
            }
            Bar(w: w * 0.92, h: 7 * k, dim: true)
            Bar(w: w * 0.64, h: 7 * k, dim: true)
            HStack(spacing: 6 * k) { Ph("music-note", 11 * k).foregroundStyle(.white); Bar(w: w * 0.52, h: 6 * k, dim: true) }
        }
        .frame(width: w, alignment: .leading)
    }

    private func avatar(_ d: Double) -> some View {
        Circle().fill(.white.opacity(0.75)).frame(width: d, height: d).overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
    }
}

/// A desktop app's layout on the laptop screen: YouTube's player with its list on the right, or Facebook's player with
/// its comments column. The take plays where the player is.
struct DesktopSkin<Player: View>: View {
    var skin: PreviewSkin
    var width: Double
    var height: Double
    var player: (Double, Double) -> Player

    var body: some View {
        let pad = width * 0.02
        let top = height * 0.07
        ZStack(alignment: .topLeading) {
            Color(white: 0.06)
            HStack(spacing: width * 0.015) {
                Ph("list-bullets", 14).foregroundStyle(.white)
                Bar(w: width * 0.06, h: 7)
                Spacer()
                Capsule().strokeBorder(Color(white: 0.27), lineWidth: 1).frame(width: width * 0.3, height: height * 0.04)
                Spacer()
                Ph("bell", 14).foregroundStyle(.white)
                Circle().fill(Color(white: 0.4)).frame(width: 14, height: 14)
            }
            .padding(.horizontal, pad).frame(height: top)
            let vw = width * (skin == .youtube ? 0.66 : 0.70)
            VStack(alignment: .leading, spacing: 10) {
                player(vw, vw * 9 / 16).clipShape(RoundedRectangle(cornerRadius: 6))
                Bar(w: vw * 0.7, h: 9)
                HStack(spacing: 8) {
                    Circle().fill(Color(white: 0.4)).frame(width: 22, height: 22)
                    Bar(w: vw * 0.18, h: 7, dim: true)
                    if skin == .youtube { Capsule().fill(.white.opacity(0.9)).frame(width: 56, height: 20) }
                    Spacer()
                    Capsule().fill(Color(white: 0.2)).frame(width: 80, height: 20)
                    Capsule().fill(Color(white: 0.2)).frame(width: 54, height: 20)
                }
                .frame(width: vw)
            }
            .padding(.leading, pad).padding(.top, height * 0.09)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<6, id: \.self) { _ in
                    HStack(alignment: .top, spacing: 8) {
                        if skin == .youtube {
                            RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.17)).frame(width: width * 0.12, height: width * 0.12 * 9 / 16)
                        } else {
                            Circle().fill(Color(white: 0.3)).frame(width: 18, height: 18)
                        }
                        VStack(alignment: .leading, spacing: 5) { Bar(w: width * 0.12, h: 5, dim: true); Bar(w: width * 0.08, h: 5, dim: true).opacity(0.6) }
                    }
                }
            }
            .frame(width: width * (skin == .youtube ? 0.27 : 0.24), alignment: .leading)
            .padding(.top, height * 0.09)
            .frame(width: width - pad, alignment: .trailing)
        }
        .frame(width: width, height: height)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(skin.label) layout")
    }
}

/// The safe zones: a diagonal hatch where the app's own buttons and captions sit, and a dashed box around the safe part.
struct SafeZoneLayer: View {
    var zone: SafeZone

    var body: some View {
        Canvas { ctx, size in
            let r = zone.safeRect
            let safe = CGRect(x: r.x * size.width, y: r.y * size.height, width: r.w * size.width, height: r.h * size.height)
            var covered = Path(CGRect(origin: .zero, size: size))
            covered.addRect(safe)
            ctx.clip(to: covered, style: FillStyle(eoFill: true))
            var hatch = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                hatch.move(to: CGPoint(x: x, y: size.height))
                hatch.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 12
            }
            ctx.stroke(hatch, with: .color(.white.opacity(0.22)), lineWidth: 5)
        }
        .overlay(GeometryReader { g in
            let r = zone.safeRect
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(.white.opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .frame(width: r.w * g.size.width, height: r.h * g.size.height)
                .offset(x: r.x * g.size.width, y: r.y * g.size.height)
        })
        .accessibilityLabel("Safe zones: keep faces and text inside the dashed box")
    }
}

// MARK: Actions

/// One take action: icon and label, or the icon alone with the label as its tooltip.
struct ViewerActionButton: View {
    @Environment(\.theme) private var t
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
            .foregroundStyle(primary ? t.roles.onAction : t.roles.ink)
            .background(RoundedRectangle(cornerRadius: t.radii.control).fill(primary ? t.roles.action : .clear))
            .overlay { if !primary { RoundedRectangle(cornerRadius: t.radii.control).strokeBorder(t.roles.hairline, lineWidth: 1) } }
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

/// The preview choices in a popover: Clean or a platform layout, the device frame, the safe zones. Used in small panes
/// (over the media's corner) and when the preview bar has no room.
struct ViewerPreviewButton: View {
    @Environment(\.theme) private var t
    var skin: PreviewSkin
    var aspect: Double
    @Binding var prefsRaw: String
    var hasZones: Bool
    /// Over the media: a 28 pt icon on a scrim.
    var onMedia = false
    /// Beside the segmented skins: only the two switches.
    var switchesOnly = false
    @State private var open = false

    private var prefs: ViewerPrefs { ViewerPrefsKey.read(prefsRaw) }
    private func update(_ f: (inout ViewerPrefs) -> Void) {
        var p = prefs
        f(&p)
        prefsRaw = ViewerPrefsKey.write(p)
    }

    var body: some View {
        Button { open.toggle() } label: {
            Group {
                if onMedia {
                    Ph("device-mobile", 14).frame(width: 16, height: 16).foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(.black.opacity(0.5)))
                } else {
                    HStack(spacing: Space.s1) {
                        Ph("device-mobile", 14).frame(width: 16, height: 16)
                        Text(switchesOnly ? "Frame" : "Preview: \(skin.label)").font(t.scale.label.font).lineLimit(1).fixedSize()
                        Ph("caret-down", 11).frame(width: 12, height: 12)
                    }
                    .foregroundStyle(t.roles.ink)
                    .padding(.horizontal, Space.s2).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: t.radii.control).strokeBorder(t.roles.hairline, lineWidth: 1))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Preview as it would look on each app")
        .accessibilityLabel("Preview: \(skin.label)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Space.s3) {
                if !switchesOnly {
                    Text("Preview as").font(t.scale.label.font).foregroundStyle(t.roles.ink2)
                    Picker("Preview as", selection: Binding(get: { skin }, set: { s in update { $0.setSkin(s, aspect: aspect) } })) {
                        ForEach(PreviewSkin.options(aspect: aspect), id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Divider()
                }
                Toggle(PreviewSkin.isLandscape(aspect) ? "Laptop frame" : "Phone frame",
                       isOn: Binding(get: { prefs.deviceFrame }, set: { v in update { $0.deviceFrame = v } }))
                    .toggleStyle(.switch).controlSize(.small)
                Toggle("Safe zones", isOn: Binding(get: { prefs.safeZones }, set: { v in update { $0.safeZones = v } }))
                    .toggleStyle(.switch).controlSize(.small)
                    .disabled(!hasZones)
            }
            .font(t.scale.label.font)
            .padding(Space.s4)
            .frame(width: 220, alignment: .leading)
        }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

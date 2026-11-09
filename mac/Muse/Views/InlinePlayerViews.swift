import AppKit
import AVFoundation
import MuseCore
import SwiftUI

// Inline video playback shared by the AI Suite (Swap's stage, the composer feed and previews). It used to live with the
// classic video studio, removed on 2026-11-08 (the AI Suite covers it).

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

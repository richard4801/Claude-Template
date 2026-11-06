import AVKit
import MuseCore
import SwiftUI

/// The preview (E1): the live edit on the dark stage at the canvas shape, platform safe-area guides (TikTok / Reels /
/// Shorts), Fit · 100 %, and the transport (time, back, play/pause, forward, mute, full screen).
struct EditSuitePreview: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    @Binding var showBin: Bool
    var binHidden: Bool
    @State private var actualSize = false
    @State private var muted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if binHidden {
                    SuiteIconButton(systemName: "sidebar.left", label: showBin ? "Hide the media bin" : "Show the media bin", tint: .white) { showBin.toggle() }
                }
                ForEach(EditSuite.SafeArea.allCases) { a in
                    let on = session.state.safeArea == a
                    Button { session.view { $0.safeArea = on ? nil : a } } label: {
                        HStack(spacing: 5) {
                            if a == .tiktok { Ph("music.note", 9) }
                            Text(a.label).font(t.scale.micro.font)
                        }
                        .foregroundStyle(on ? Color(hex: 0xFF5A5F) : Color(hex: 0xA9A6A0))
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .overlay(Rectangle().strokeBorder(on ? Color(hex: 0xFF5A5F) : Color(hex: 0x4A4642), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(a.label) guide")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                Spacer()
                Button { actualSize.toggle() } label: {
                    Text(actualSize ? "Actual · 100%" : "Fit · 100%").font(t.mono(11)).foregroundStyle(Color(hex: 0xA9A6A0))
                }
                .buttonStyle(.plain)
                .help("Fit the preview or show it at its actual size")
            }
            .padding(.horizontal, 14)
            .frame(height: 40)

            GeometryReader { g in
                let c = session.project.canvas
                let aspect = CGFloat(c.width) / CGFloat(max(1, c.height))
                let fit = min(g.size.width / aspect, g.size.height)
                let h = actualSize ? min(CGFloat(c.height) / (NSScreen.main?.backingScaleFactor ?? 2), fit * 1.0) : fit
                let w = h * aspect
                ZStack {
                    SuitePlayerSurface(player: session.player)
                    if let a = session.state.safeArea { SafeAreaGuide(area: a) }
                }
                .frame(width: w, height: h)
                .position(x: g.size.width / 2, y: g.size.height / 2)
            }
            .padding(.horizontal, 16)

            transport
        }
        .background(suiteStage)
    }

    private var transport: some View {
        HStack(spacing: 14) {
            Text("\(EditSuite.clockTenths(session.playhead)) / \(EditSuite.clockTenths(session.duration))")
                .font(t.mono(12.5)).foregroundStyle(Color(hex: 0xE7E1D6))
                .monospacedDigit()
            SuiteIconButton(systemName: "backward.fill", label: "Back to the start", tint: Color(hex: 0xE7E1D6)) { session.seek(0) }
            SuiteIconButton(systemName: session.playing ? "pause.fill" : "play.fill", label: session.playing ? "Pause" : "Play",
                            size: 34, tint: .white) { session.togglePlay() }
            SuiteIconButton(systemName: "forward.fill", label: "Forward one second", tint: Color(hex: 0xE7E1D6)) { session.seek(session.playhead + 1) }
            SuiteIconButton(systemName: muted ? "speaker.slash" : "speaker.wave.2", label: muted ? "Unmute the preview" : "Mute the preview",
                            tint: Color(hex: 0xE7E1D6)) {
                muted.toggle()
                session.player.isMuted = muted
            }
            SuiteIconButton(systemName: "arrow.up.left.and.arrow.down.right", label: "Full screen", tint: Color(hex: 0xE7E1D6)) {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
        }
        .frame(height: 48)
    }
}

/// The preview surface: AVPlayerView without controls (the suite has its own transport).
struct SuitePlayerSurface: NSViewRepresentable {
    var player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        v.player = player
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

/// Dashed safe-area box: the part of the frame the platform's buttons and captions leave clear.
struct SafeAreaGuide: View {
    var area: EditSuite.SafeArea

    var body: some View {
        GeometryReader { g in
            let i = area.insets
            let rect = CGRect(x: g.size.width * i.left, y: g.size.height * i.top,
                              width: g.size.width * (1 - i.left - i.right), height: g.size.height * (1 - i.top - i.bottom))
            Path { p in p.addRect(rect) }
                .stroke(Color(hex: 0xFF5A5F).opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

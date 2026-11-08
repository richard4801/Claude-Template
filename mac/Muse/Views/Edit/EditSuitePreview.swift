import AVKit
import MuseCore
import SwiftUI

/// The viewer (E1, plans/edit-layout.md): "Safe area" as one segmented control (Off · TikTok · Reels · Shorts) and Fit ·
/// 100 %; the live edit on the viewer tone at the canvas shape with the platform's safe-area guide; the transport below
/// (timecode in tabular figures, back, a 40 pt play, forward, sound, full screen).
struct EditSuitePreview: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    var mediaHidden: Bool
    var showMedia: () -> Void
    @State private var actualSize = false
    @State private var muted = false

    var body: some View {
        VStack(spacing: Space.s3) {
            HStack(spacing: Space.s2) {
                if mediaHidden {
                    SuiteIconButton(systemName: "caret-double-right", label: "Show media", tint: t.roles.ink2, action: showMedia)
                }
                Text("Safe area").font(t.scale.caption.font).foregroundStyle(t.roles.ink2).lineLimit(1).fitProbe("safe area")
                EditSeg(options: safeAreas,
                        selection: session.state.safeArea, height: 28, small: true) { a in
                    session.view { $0.safeArea = a }
                }
                .fixedSize()
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Safe area")
                Spacer(minLength: Space.s2)
                Button { actualSize.toggle() } label: {
                    Text(actualSize ? "Actual · 100%" : "Fit · 100%").font(t.scale.caption.font).monospacedDigit()
                        .foregroundStyle(t.roles.ink2).lineLimit(1)
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Fit the preview or show it at its actual size")
                .accessibilityLabel(actualSize ? "Actual size" : "Fit")
            }

            GeometryReader { g in
                let c = session.project.canvas
                let inner = CGSize(width: max(1, g.size.width - 24), height: max(1, g.size.height - 24))
                let aspect = CGFloat(c.width) / CGFloat(max(1, c.height))
                let fit = min(inner.width / aspect, inner.height)
                let h = actualSize ? min(CGFloat(c.height) / (NSScreen.main?.backingScaleFactor ?? 2), fit * 1.0) : fit
                let w = h * aspect
                ZStack {
                    SuitePlayerSurface(player: session.player)
                    if let a = session.state.safeArea { SafeAreaGuide(area: a) }
                }
                .frame(width: w, height: h)
                .position(x: g.size.width / 2, y: g.size.height / 2)
            }
            .background(RoundedRectangle(cornerRadius: t.radii.container, style: .continuous).fill(t.editViewer))
            .clipShape(RoundedRectangle(cornerRadius: t.radii.container, style: .continuous))

            transport
        }
        .padding(Space.s4)
        .background(t.roles.canvas)
    }

    /// Off, then each platform's guide (the same state as the guides before: nil is off).
    private var safeAreas: [(EditSuite.SafeArea?, String)] {
        [(nil, "Off")] + EditSuite.SafeArea.allCases.map { a -> (EditSuite.SafeArea?, String) in (a, a.label) }
    }

    private var transport: some View {
        HStack(spacing: Space.s2) {
            Text("\(EditSuite.clockTenths(session.playhead)) / \(EditSuite.clockTenths(session.duration))")
                .font(t.scale.label.font).monospacedDigit().foregroundStyle(t.roles.ink)
                .lineLimit(1)
                .fitProbe("timecode")
                .frame(minWidth: 120, alignment: .leading)
            Spacer(minLength: 0)
            SuiteIconButton(systemName: "skip-back", label: "Back to the start") { session.seek(0) }
            Button { session.togglePlay() } label: {
                Ph(session.playing ? "pause" : "play", 16)
                    .foregroundStyle(t.roles.canvas)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(t.roles.ink))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(session.playing ? "Pause (space)" : "Play (space)")
            .accessibilityLabel(session.playing ? "Pause" : "Play")
            SuiteIconButton(systemName: "skip-forward", label: "Forward one second") { session.seek(session.playhead + 1) }
            Spacer(minLength: 0)
            HStack(spacing: Space.s1) {
                SuiteIconButton(systemName: muted ? "speaker-slash" : "speaker-high", label: muted ? "Unmute the preview" : "Mute the preview") {
                    muted.toggle()
                    session.player.isMuted = muted
                }
                SuiteIconButton(systemName: "arrows-out-simple", label: "Full screen") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
            }
            .frame(minWidth: 120, alignment: .trailing)
        }
        .frame(height: 40)
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

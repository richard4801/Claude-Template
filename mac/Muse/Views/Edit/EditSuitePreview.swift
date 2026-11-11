import AVKit
import MuseCore
import SwiftUI
import UniformTypeIdentifiers

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
    /// The fitted picture's size against actual size (the "Fit · 43%" label).
    @State private var fitScale: CGFloat = 1
    private var fitPercent: Int { max(1, Int((fitScale * 100).rounded())) }

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
                    Text(actualSize ? "Actual size · 100%" : "Fit · \(fitPercent)%").font(t.scale.caption.font).monospacedDigit()
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
                // Actual size = one canvas pixel per screen pixel (it may be larger than the viewer: then it's cropped to it).
                let actual = CGFloat(c.height) / (NSScreen.main?.backingScaleFactor ?? 2)
                let h = actualSize ? actual : fit
                let w = h * aspect
                ZStack {
                    SuitePlayerSurface(player: session.player)
                    if session.project.mainClips.isEmpty {
                        // A blank project before its first clip (owner request 2026-11-11).
                        Text("Add a video from the media panel to start")
                            .font(t.scale.caption.font).foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(.center).padding(Space.s3)
                    }
                    if let a = session.state.safeArea { SafeAreaGuide(area: a) }
                    if session.pickingKeyColour { KeyColourPicker(session: session, scale: Double(c.width) / Double(max(1, w))) }
                }
                .frame(width: w, height: h)
                .position(x: g.size.width / 2, y: g.size.height / 2)
                .onAppear { fitScale = actual > 0 ? fit / actual : 1 }
                .onChange(of: fit) { _, f in fitScale = actual > 0 ? f / actual : 1 }
                .onChange(of: c.height) { _, _ in fitScale = actual > 0 ? fit / actual : 1 }
            }
            .background(RoundedRectangle(cornerRadius: t.radii.container, style: .continuous).fill(t.editViewer))
            .clipShape(RoundedRectangle(cornerRadius: t.radii.container, style: .continuous))

            transport
        }
        .padding(Space.s4)
        .background(t.roles.canvas)
    }

    /// Parity wave 1 "extract frame": the edit's frame at the playhead (with every look, text and caption) as a PNG.
    private func saveFrame() {
        session.pause()
        let t = session.playhead
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(session.title) \(EditSuite.clockTenths(t).replacingOccurrences(of: ":", with: ".")).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if let msg = await session.saveFrame(at: t, to: url) { session.lastError = msg } else { session.notice = "Saved the frame" }
        }
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
            SuiteIconButton(systemName: "caret-left", label: "Back one frame (←)") { session.step(-1) }
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
            SuiteIconButton(systemName: "caret-right", label: "Forward one frame (→)") { session.step(1) }
            SuiteIconButton(systemName: "skip-forward", label: "Forward one second") { session.seek(session.playhead + 1) }
            Spacer(minLength: 0)
            HStack(spacing: Space.s1) {
                SuiteIconButton(systemName: "camera", label: "Save this frame as a picture") { saveFrame() }
                SuiteIconButton(systemName: muted ? "speaker-slash" : "speaker-high", label: muted ? "Unmute the preview" : "Mute the preview") {
                    muted.toggle()
                    session.player.isMuted = muted
                }
                SuiteIconButton(systemName: "arrows-out-simple", label: "Full screen preview (Esc to leave)") {
                    ViewerFullScreen.toggle(player: session.player) { session.togglePlay() }
                }
            }
            .frame(minWidth: 120, alignment: .trailing)
        }
        .frame(height: 40)
    }
}

/// The preview on its own, filling the screen (Mac Edit audit 2026-11-08: "Full screen" made the whole window full screen).
/// Esc (or the button again) leaves; space plays and pauses.
@MainActor
enum ViewerFullScreen {
    private static var window: NSWindow?
    private static var monitor: Any?

    static var isOpen: Bool { window != nil }

    static func toggle(player: AVPlayer, togglePlay: @escaping @MainActor () -> Void) {
        if window != nil { close(); return }
        guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main else { return }
        let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .mainMenu + 1
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        let v = AVPlayerView()
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        v.player = player
        w.contentView = v
        w.setFrame(screen.frame, display: true)
        w.orderFrontRegardless()
        window = w
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { e in
            MainActor.assumeIsolated {
                if e.type == .keyDown && e.keyCode == 53 { close(); return nil }        // Esc
                if e.type == .keyDown && e.keyCode == 49 { togglePlay(); return nil }   // space
                if e.type == .leftMouseDown && e.window === window { togglePlay(); return nil }
                return e
            }
        }
    }

    static func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        (window?.contentView as? AVPlayerView)?.player = nil
        window?.orderOut(nil)
        window = nil
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

/// The chroma key eyedropper over the preview (design pass, owner-approved): a crosshair, and beside it the colour under
/// the pointer at about 4× with its hex; a click sets the key colour, Esc cancels.
struct KeyColourPicker: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    /// Canvas pixels per point.
    var scale: Double
    @State private var at: CGPoint?
    @State private var hex: String?

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            at = p
                            hex = session.keyColour(canvasX: Double(p.x) * scale, canvasY: Double(p.y) * scale)
                        case .ended:
                            at = nil; hex = nil
                        }
                    }
                    .onTapGesture { p in session.pickKeyColour(canvasX: Double(p.x) * scale, canvasY: Double(p.y) * scale) }
                    .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
                if let p = at {
                    let right = p.x + 96 < g.size.width
                    HStack(spacing: Space.s2) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(hex.map { Color(hex: UInt32($0.dropFirst(), radix: 16) ?? 0) } ?? .clear)
                            .frame(width: 36, height: 36)
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                        Text(hex ?? "Off the clip").font(t.scale.caption.font).monospacedDigit().foregroundStyle(.white)
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.7)))
                    .offset(x: right ? p.x + 14 : p.x - 110, y: max(0, p.y - 50))
                    .allowsHitTesting(false)
                }
            }
        }
        .onExitCommand { Task { await session.toggleKeyPick() } }
        .accessibilityElement()
        .accessibilityLabel("Pick the key colour: click on the picture")
    }
}

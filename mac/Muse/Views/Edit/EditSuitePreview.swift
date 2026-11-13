import AVKit
import MuseCore
import SwiftUI
import UniformTypeIdentifiers

/// The viewer (E1, plans/edit-layout.md; platform views plans/edit-platform-preview.md): "View" (Clean · TikTok · Reels ·
/// Shorts · Facebook, or Clean · YouTube · Facebook on 16:9) with the "Safe area" switch, and Fit · 100 %; the live edit
/// on the viewer tone at the canvas shape with the app's generic chrome and its red safe box over it; a warning line when
/// captions or text sit outside the box; the transport below (timecode in tabular figures, back, a 40 pt play, forward,
/// sound, full screen).
struct EditSuitePreview: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    var mediaHidden: Bool
    var showMedia: () -> Void
    @State private var actualSize = false
    @State private var muted = false
    @State private var viewMenuOpen = false
    /// The fitted picture's size against actual size (the "Fit · 43%" label).
    @State private var fitScale: CGFloat = 1
    private var fitPercent: Int { max(1, Int((fitScale * 100).rounded())) }

    var body: some View {
        VStack(spacing: Space.s3) {
            HStack(spacing: Space.s2) {
                if mediaHidden {
                    SuiteIconButton(systemName: "caret-double-right", label: "Show media", tint: t.roles.ink2, action: showMedia)
                }
                // The bar adapts so nothing is ever cut (owner review, run 587: with the Claude panel open "Safe area"
                // showed as "S"): every view as chips, then "View: TikTok ▾" with the switch's label, then the switch as
                // an icon with its tooltip and the fit as a bare percentage.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Space.s2) {
                        Text("View").font(t.scale.caption.font).foregroundStyle(t.roles.ink2).lineLimit(1).fixedSize().fitProbe("preview view")
                        viewChips
                        safeSwitch.padding(.leading, Space.s2)
                        Spacer(minLength: Space.s2)
                        fitButton(short: false)
                    }
                    HStack(spacing: Space.s2) {
                        viewMenu
                        safeSwitch.padding(.leading, Space.s1)
                        Spacer(minLength: Space.s2)
                        fitButton(short: false)
                    }
                    HStack(spacing: Space.s1) {
                        viewMenu
                        SuiteIconButton(systemName: "selection", label: safeHelp + (session.state.preview.safeArea ? " (on)" : " (off)"),
                                        on: session.state.preview.safeArea, size: 28) { setSafeArea(!session.state.preview.safeArea) }
                        Spacer(minLength: Space.s1)
                        fitButton(short: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
                    EditPlatformChrome(view: session.shownPreview.view, landscape: session.previewIsLandscape, width: w, height: h)
                    if let z = session.safeZone {
                        EditSafeBoxGuide(zone: z, name: EditSafeBox.name(session.state.preview, width: c.width, height: c.height))
                    }
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

            if let warning = session.safeWarning { safeWarning(warning) }

            transport
        }
        .padding(Space.s4)
        .background(t.roles.canvas)
        // Review mode: the platform-preview shots set the view (never remembered).
        .onChange(of: SnapshotRunner.state.editPreview) { _, p in if let p { session.setPreview(p, remember: false) } }
    }

    /// "Captions sit under TikTok's caption and buttons (0:01–0:09)." and the one fix.
    private func safeWarning(_ text: String) -> some View {
        HStack(spacing: Space.s2) {
            Ph("warning", 14).foregroundStyle(Color(hex: 0xFF5A5F))
            Text(text).font(t.scale.caption.font).foregroundStyle(t.roles.ink).lineLimit(1).truncationMode(.middle)
            Button("Move into the safe area") { session.moveIntoSafeArea() }
                .buttonStyle(.plain)
                .font(t.scale.caption.font.weight(.medium))
                .foregroundStyle(t.roles.accent)
                .fixedSize()
                .help("Moves the captions and text just inside the red box (one change; Undo puts them back)")
            Spacer(minLength: 0)
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .combine)
    }

    // MARK: View bar parts

    private var safeHelp: String {
        session.previewLayouts.note.map { "Safe area: the red box shows where the app leaves your picture clear. \($0)" }
            ?? "Safe area: the red box shows where the app leaves your picture clear"
    }

    private func setView(_ v: PreviewSkin) {
        var p = session.state.preview
        p.view = v
        session.setPreview(p)
    }

    private func setSafeArea(_ on: Bool) {
        var p = session.state.preview
        p.safeArea = on
        session.setPreview(p)
    }

    /// Every view as chips (the widest form).
    private var viewChips: some View {
        EditSeg(options: views, selection: session.shownPreview.view, height: 28, small: true) { setView($0) }
            .fixedSize()
            .help("Preview the edit under each app's buttons and captions (our own drawing of its layout)")
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Preview view")
    }

    /// "View: TikTok ▾": the views in a popover (a button, not a Menu, so no icon is drawn at menu size).
    private var viewMenu: some View {
        Button { viewMenuOpen.toggle() } label: {
            HStack(spacing: 4) {
                Text("View: \(session.shownPreview.view.label)").font(t.scale.caption.font).foregroundStyle(t.roles.ink)
                    .lineLimit(1).fixedSize().fitProbe("preview view menu")
                Ph("caret-down", 11).foregroundStyle(t.roles.ink2)
            }
            .padding(.horizontal, Space.s2)
            .frame(minHeight: 28)
            .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.roles.field))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Preview the edit under each app's buttons and captions (our own drawing of its layout)")
        .accessibilityLabel("Preview view: \(session.shownPreview.view.label)")
        .popover(isPresented: $viewMenuOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(views, id: \.0) { item in viewRow(item.0, item.1) }
            }
            .padding(.vertical, Space.s2)
            .frame(width: 180)
        }
    }

    private func viewRow(_ v: PreviewSkin, _ label: String) -> some View {
        Button {
            setView(v)
            viewMenuOpen = false
        } label: {
            HStack(spacing: Space.s2) {
                Text(label).font(t.scale.label.font).foregroundStyle(t.roles.ink).lineLimit(1)
                Spacer(minLength: Space.s3)
                if v == session.shownPreview.view { Ph("check", 14).foregroundStyle(t.roles.accent) }
            }
            .padding(.horizontal, Space.s3)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(v == session.shownPreview.view ? .isSelected : [])
    }

    /// The Safe area switch with its label.
    private var safeSwitch: some View {
        Toggle(isOn: Binding(get: { session.state.preview.safeArea }, set: { setSafeArea($0) })) {
            Text("Safe area").font(t.scale.caption.font).foregroundStyle(t.roles.ink).lineLimit(1).fixedSize().fitProbe("safe area")
        }
        .toggleStyle(.switch).controlSize(.small)
        .fixedSize()
        .help(safeHelp)
    }

    /// "Fit · 43%" (or "43%" when short), or "Actual size · 100%".
    private func fitButton(short: Bool) -> some View {
        Button { actualSize.toggle() } label: {
            Text(actualSize ? (short ? "100%" : "Actual size · 100%") : (short ? "\(fitPercent)%" : "Fit · \(fitPercent)%"))
                .font(t.scale.caption.font).monospacedDigit()
                .foregroundStyle(t.roles.ink2).lineLimit(1).fixedSize().fitProbe("preview fit")
                .frame(minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Fit the preview or show it at its actual size")
        .accessibilityLabel(actualSize ? "Actual size" : "Fit")
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

    /// The views this canvas offers: the phone apps on portrait, square and 4:5; the landscape players on 16:9.
    private var views: [(PreviewSkin, String)] {
        EditPreview.options(width: session.project.canvas.width, height: session.project.canvas.height).map { ($0, $0.label) }
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

import AVKit
import MuseCore
import SwiftUI

/// The video editor (plans/video-editor.md): live preview, transport, the frame-thumbnail timeline with trim handles and
/// split marks, and Speed / Sound for the selected part or the whole video. Space plays, ←/→ step a frame, S splits,
/// ⌫ deletes the selected part, ⌘Z / ⇧⌘Z undo and redo.
struct VideoEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @FocusState private var focused: Bool

    var body: some View {
        if let s = store.editor {
            content(s)
        } else {
            Page { Note("Open a video take and choose Edit.") }
        }
    }

    @ViewBuilder private func content(_ s: VideoEditorSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(s)
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 14) {
                    preview(s)
                    transport(s)
                    EditorTimeline(session: s)
                    trimLine(s)
                }
                .frame(maxWidth: .infinity)
                inspector(s).frame(width: 300)
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 28)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onDisappear { s.player.pause() }
        .onKeyPress(.space) { s.togglePlay(); return .handled }
        .onKeyPress(.leftArrow) { s.step(-1); return .handled }
        .onKeyPress(.rightArrow) { s.step(1); return .handled }
        .onKeyPress(.delete) { s.deleteSelected(); return .handled }
        .onKeyPress(.deleteForward) { s.deleteSelected(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "sS")) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
            s.split()
            return .handled
        }
        .overlay { if s.busy { ExportOverlay(session: s) } }
    }

    // MARK: Header

    private func header(_ s: VideoEditorSession) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Breadcrumb(parent: "Gallery", title: s.take.caption) { store.closeEditor() }
                Text(t.headingsUppercase ? "EDIT VIDEO" : "Edit video").font(t.isA ? Fonts.font("Instrument Serif", 30, .regular) : t.display(26))
            }
            Spacer()
            Button { s.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(MuseButtonStyle(size: .small, off: !s.history.canUndo))
                .keyboardShortcut("z", modifiers: .command)
                .help("Undo (⌘Z)")
            Button { s.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(MuseButtonStyle(size: .small, off: !s.history.canRedo))
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help("Redo (⇧⌘Z)")
            MButton("Reset", size: .small, off: s.list.isUnedited || !s.isReady) { s.reset() }
                .help("Back to the whole video at 1× with sound")
            MButton("Close", size: .small) { store.closeEditor() }
            MButton("Export", icon: "square.and.arrow.up", kind: .primary, size: .small, off: !s.isReady || s.exportProblem != nil) { store.exportEdit() }
                .help(s.exportProblem ?? "Make the edited video on this Mac and save it as a new version")
        }
        .padding(.bottom, 18)
    }

    // MARK: Preview

    @ViewBuilder private func preview(_ s: VideoEditorSession) -> some View {
        let w = Double(s.info?.width ?? s.take.width ?? 768)
        let h = Double(s.info?.height ?? s.take.height ?? 1344)
        ZStack {
            Rectangle().fill(Color.black)
            switch s.phase {
            case .loading:
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Opening the video…").font(t.body(12)).foregroundStyle(.white.opacity(0.8))
                }
            case .failed(let msg):
                Text(msg).font(t.body(13)).foregroundStyle(.white).multilineTextAlignment(.center).padding(20)
            default:
                PlayerSurface(player: s.player)
                    .onTapGesture { s.togglePlay() }
            }
        }
        .aspectRatio(max(0.1, w / max(1, h)), contentMode: .fit)
        .frame(maxHeight: 520)
        .clipShape(RoundedRectangle(cornerRadius: t.isA ? 0 : t.cardRadius * 0.6))
    }

    private func transport(_ s: VideoEditorSession) -> some View {
        HStack(spacing: 10) {
            Button { s.step(-1) } label: { Image(systemName: "backward.frame.fill") }
                .buttonStyle(MuseButtonStyle(size: .small, off: !s.isReady)).help("Previous frame (←)")
            Button { s.togglePlay() } label: { Image(systemName: s.playing ? "pause.fill" : "play.fill").frame(width: 18) }
                .buttonStyle(MuseButtonStyle(kind: .primary, size: .small, off: !s.isReady)).help("Play / pause (space)")
            Button { s.step(1) } label: { Image(systemName: "forward.frame.fill") }
                .buttonStyle(MuseButtonStyle(size: .small, off: !s.isReady)).help("Next frame (→)")
            Text("\(EditList.clock(s.playhead)) / \(EditList.clock(s.duration))")
                .font(t.mono(13, .medium)).monospacedDigit()
            Spacer()
            MButton("Split", icon: "scissors", size: .small, off: !s.canSplit) { s.split() }
                .help(s.canSplit ? "Split at the playhead (S)" : "Move the playhead at least 0.1 s from a cut to split")
            MButton("Delete", icon: "trash", size: .small, off: !s.canDelete) { s.deleteSelected() }
                .help(s.list.segments.count > 1 ? "Delete the selected part (⌫)" : "The last part can't be deleted")
        }
    }

    private func trimLine(_ s: VideoEditorSession) -> some View {
        HStack(spacing: 18) {
            if let sel = s.selected, s.list.segments.count > 1 {
                stat("Part", "\((s.selectedIndex ?? 0) + 1) of \(s.list.segments.count)")
                stat("In", EditList.clock(sel.inSec))
                stat("Out", EditList.clock(sel.outSec))
            } else {
                stat("In", EditList.clock(s.list.trimIn))
                stat("Out", EditList.clock(s.list.trimOut))
            }
            stat("Kept", EditList.clock(s.duration))
            Spacer()
            if s.history.canUndo || !s.list.isUnedited {
                Muted("Source \(EditList.clock(s.list.sourceDurationSec))")
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(t.body(12)).foregroundStyle(t.muted)
            Text(value).font(t.mono(12, .medium)).monospacedDigit()
        }
    }

    // MARK: Inspector

    private func inspector(_ s: VideoEditorSession) -> some View {
        @Bindable var s = s
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Lbl("Speed")
                    Spacer()
                    if let sp = s.shownSpeed { Text(EditList.speedLabel(sp)).font(t.mono(12, .medium)) }
                }
                Seg([(false, s.list.segments.count > 1 ? "Selected part" : "This video"), (true, "Whole video")], selection: $s.wholeVideo)
                FlowLayout(spacing: 6) {
                    ForEach(EditList.speeds, id: \.self) { sp in
                        Chip(EditList.speedLabel(sp), on: s.shownSpeed == sp) { s.setSpeed(sp) }
                    }
                }
                Muted("Sound keeps its pitch at every speed.")
            }
            .card(14)

            VStack(alignment: .leading, spacing: 12) {
                Lbl("Sound")
                OptionRow(title: "Mute whole video", hint: "The export has no sound") {
                    MToggle(isOn: Binding(get: { s.list.mute }, set: { s.setMuted($0) }))
                }
                if s.list.segments.count > 1, let sel = s.selected {
                    OptionRow(title: "Mute this part", hint: "Silence for part \((s.selectedIndex ?? 0) + 1)") {
                        MToggle(isOn: Binding(get: { sel.muted }, set: { s.setSegmentMuted($0) }))
                    }
                    .opacity(s.list.mute ? 0.45 : 1)
                    .disabled(s.list.mute)
                }
            }
            .card(14)

            ListBox {
                let rows: [(String, String)] = [
                    ("Length", EditList.clock(s.duration)),
                    ("Parts", "\(s.list.segments.count)"),
                    ("Size", s.info.map { "\($0.width)×\($0.height)" } ?? "—"),
                    ("Frame rate", s.info.map { "\(Pricing.trimNum($0.fps)) fps" } ?? "—"),
                ]
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    ListRow(title: r.0, last: i == rows.count - 1) { MonoValue(r.1) }
                }
            }
            if let e = s.lastError { Note(icon: "exclamationmark.triangle", warn: true, e) }
            Muted("Export makes the video on this Mac at the same size and frame rate, then saves it as a new version marked Edited. The original stays as it is. Editing is free.")
            VStack(alignment: .leading, spacing: 4) {
                Lbl("Keys")
                Muted("Space play · ← → frame · S split · ⌫ delete · ⌘Z undo · ⇧⌘Z redo")
            }
        }
    }
}

/// The preview surface: AVPlayerView with no controls (the editor has its own transport).
struct PlayerSurface: NSViewRepresentable {
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

/// Export → upload progress with Cancel, over the editor.
struct ExportOverlay: View {
    @Environment(\.theme) private var t
    var session: VideoEditorSession

    var body: some View {
        let (title, value): (String, Double) = {
            switch session.phase {
            case .exporting(let p): return ("Making the video on this Mac", p)
            case .uploading(let p): return ("Uploading", p)
            default: return ("", 0)
            }
        }()
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(t.body(15, .bold))
                ProgressLine(value: value)
                HStack {
                    Text("\(Int((value * 100).rounded())) %").font(t.mono(12)).foregroundStyle(t.muted)
                    Spacer()
                    MButton("Cancel", size: .small) { session.cancelExport() }.keyboardShortcut(.cancelAction)
                }
            }
            .frame(width: 340)
            .card(18)
        }
    }
}

/// The timeline: each kept part as a strip of frames, widths by how long it plays; split marks between parts, trim
/// handles on the outer ends and on the selected part, and the playhead. Click or drag on it to seek.
struct EditorTimeline: View {
    @Environment(\.theme) private var t
    var session: VideoEditorSession
    @State private var dragStart: (id: String, isIn: Bool, src: Double, pxPerSrc: Double)?

    private let height: CGFloat = 64
    private let handle: CGFloat = 12

    var body: some View {
        let s = session
        let l = s.list
        GeometryReader { g in
            let width = max(1, g.size.width - handle * 2)
            let total = max(0.001, l.duration)
            let pxPerSec = width / total
            let starts = l.outputStarts
            ZStack(alignment: .topLeading) {
                // Clicking or dragging on the frames seeks (and selects the part there).
                Color.clear
                    .frame(width: g.size.width, height: height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { v in
                        s.scrub(to: (v.location.x - handle) / pxPerSec)
                    })
                ForEach(Array(l.segments.enumerated()), id: \.element.id) { i, seg in
                    let x = handle + starts[i] * pxPerSec
                    let w = max(2, seg.outputLength * pxPerSec)
                    SegmentStrip(seg: seg, thumbs: s.thumbs, width: w, height: height, silent: l.isSilent(i))
                        .frame(width: w, height: height)
                        .overlay(alignment: .topLeading) {
                            if seg.speed != 1 {
                                Text(EditList.speedLabel(seg.speed)).font(t.mono(10, .bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Capsule().fill(.black.opacity(0.6))).padding(4)
                            }
                        }
                        .overlay {
                            Rectangle().strokeBorder(seg.id == s.selectedId && !s.wholeVideo ? t.accent : .clear, lineWidth: 2.5)
                        }
                        .offset(x: x)
                        .allowsHitTesting(false)
                    if i > 0 {
                        Rectangle().fill(t.bg).frame(width: 2, height: height + 8).offset(x: x - 1, y: -4).allowsHitTesting(false)
                    }
                }

                // Trim handles: the outer ends, and the selected part's own edges.
                ForEach(handles(l), id: \.key) { h in
                    let i = l.segments.firstIndex { $0.id == h.id } ?? 0
                    let seg = l.segments[i]
                    let edge = h.isIn ? starts[i] : starts[i] + seg.outputLength
                    TrimHandle(isIn: h.isIn, height: height, color: h.isSelected ? t.accent : t.ink)
                        .frame(width: handle, height: height + 8)
                        .offset(x: h.isIn ? handle + edge * pxPerSec - handle : handle + edge * pxPerSec, y: -4)
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
                            .onChanged { v in
                                if dragStart == nil {
                                    s.beginTrim()
                                    dragStart = (h.id, h.isIn, h.isIn ? seg.inSec : seg.outSec, pxPerSec / seg.speed)
                                }
                                guard let d = dragStart else { return }
                                s.trim(d.id, isIn: d.isIn, to: d.src + v.translation.width / d.pxPerSrc)
                            }
                            .onEnded { _ in
                                dragStart = nil
                                s.endTrim()
                            })
                        .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                        .help(h.isIn ? "Drag to trim the start" : "Drag to trim the end")
                }

                // Playhead
                let px = handle + min(s.playhead, total) * pxPerSec
                VStack(spacing: 0) {
                    Triangle().fill(t.accent).frame(width: 12, height: 8)
                    Rectangle().fill(t.accent).frame(width: 2, height: height + 8)
                }
                .frame(width: 12)
                .offset(x: px - 6, y: -8)
                .allowsHitTesting(false)
            }
            .padding(.top, 8)
            .coordinateSpace(name: "timeline")
        }
        .frame(height: height + 16)
        .padding(.vertical, 6)
    }

    private struct HandleSpec { let id: String; let isIn: Bool; let isSelected: Bool; var key: String { id + (isIn ? "<" : ">") } }

    private func handles(_ l: EditList) -> [HandleSpec] {
        guard let first = l.segments.first, let last = l.segments.last else { return [] }
        var out = [HandleSpec(id: first.id, isIn: true, isSelected: first.id == session.selectedId && l.segments.count == 1),
                   HandleSpec(id: last.id, isIn: false, isSelected: last.id == session.selectedId && l.segments.count == 1)]
        if let sel = session.selected, l.segments.count > 1, !session.wholeVideo {
            if sel.id != first.id { out.append(HandleSpec(id: sel.id, isIn: true, isSelected: true)) } else { out[0] = HandleSpec(id: sel.id, isIn: true, isSelected: true) }
            if sel.id != last.id { out.append(HandleSpec(id: sel.id, isIn: false, isSelected: true)) } else { out[1] = HandleSpec(id: sel.id, isIn: false, isSelected: true) }
        }
        return out
    }
}

/// One part's frames: thumbnails from its own source range, tiled across its width.
struct SegmentStrip: View {
    var seg: EditSegment
    var thumbs: [(Double, CGImage)]
    var width: CGFloat
    var height: CGFloat
    var silent: Bool

    var body: some View {
        let tileW = max(20, height * 0.5625)
        let n = max(1, Int((width / tileW).rounded(.up)))
        HStack(spacing: 0) {
            ForEach(0..<n, id: \.self) { k in
                let src = seg.inSec + seg.sourceLength * (Double(k) + 0.5) / Double(n)
                if let img = nearest(src) {
                    Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: tileW, height: height).clipped()
                } else {
                    Rectangle().fill(Color.gray.opacity(0.35)).frame(width: tileW, height: height)
                }
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .clipped()
        .overlay(alignment: .bottomTrailing) {
            if silent {
                Image(systemName: "speaker.slash.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    .padding(4).background(Circle().fill(.black.opacity(0.6))).padding(4)
            }
        }
    }

    private func nearest(_ t: Double) -> CGImage? {
        guard !thumbs.isEmpty else { return nil }
        var best = thumbs[0]
        for th in thumbs where abs(th.0 - t) < abs(best.0 - t) { best = th }
        return best.1
    }
}

struct TrimHandle: View {
    var isIn: Bool
    var height: CGFloat
    var color: Color

    var body: some View {
        ZStack {
            UnevenRoundedRectangle(topLeadingRadius: isIn ? 4 : 0, bottomLeadingRadius: isIn ? 4 : 0,
                                   bottomTrailingRadius: isIn ? 0 : 4, topTrailingRadius: isIn ? 0 : 4)
                .fill(color)
            Capsule().fill(.white.opacity(0.9)).frame(width: 2, height: 18)
        }
        .contentShape(Rectangle())
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

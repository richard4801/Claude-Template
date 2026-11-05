import AppKit
import MuseCore
import SwiftUI

/// The multitrack timeline (E1): tools (split, delete, speed, keyframe, undo/redo), Ripple, Cut silences, Snap to beat,
/// Auto-captions; the ruler with the playhead; one row per track (eye = hide, lock) with its blocks: frame strips and
/// transition diamonds on the video row, caption pages, hooks/text, overlays, waveforms with beat marks on music.
/// Click to seek and select, drag a block to move it, drag its edges to trim. Zoom with the slider (points per second).
struct EditSuiteTimeline: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    static let headerWidth: CGFloat = 150

    private var s: EditSuiteState { session.state }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            SuiteRule()
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 22)
                        ForEach(s.rows) { row in
                            rowHeader(row).frame(height: height(row))
                            SuiteRule()
                        }
                    }
                    .frame(width: Self.headerWidth)
                    .background(t.chrome)
                    SuiteRule(vertical: true)
                    ScrollView(.horizontal) {
                        TimelineCanvas(session: session)
                    }
                }
            }
        }
        .background(t.bg)
    }

    func height(_ row: EditSuite.Row) -> CGFloat { TimelineCanvas.rowHeight(row.kind) }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            SuiteIconButton(systemName: "scissors", label: "Split at the playhead (S)") { session.edit { $0.split() } }
            SuiteIconButton(systemName: "trash", label: "Delete (⌫)", disabled: s.selection == nil) { session.edit { $0.deleteSelected() } }
            SuiteIconButton(systemName: "speedometer", label: "Speed", disabled: s.selectedVideo == nil) { session.view { $0.tab = .speed } }
            SuiteIconButton(systemName: "diamond", label: "Add a keyframe at the playhead", disabled: s.selectedVisual == nil) {
                let v = s.selectedVisual
                session.edit { $0.addKeyframe(.scale, value: v?.transform?.scale ?? 1) }
            }
            SuiteIconButton(systemName: "crop", label: "Transform", disabled: s.selectedVisual == nil) { session.view { $0.tab = .video } }
            SuiteIconButton(systemName: "arrow.uturn.backward", label: "Undo (⌘Z)", disabled: !s.canUndo) { session.undo() }
            SuiteIconButton(systemName: "arrow.uturn.forward", label: "Redo (⇧⌘Z)", disabled: !s.canRedo) { session.redo() }
            SuiteRule(vertical: true).frame(height: 20).padding(.horizontal, 4)
            SuiteToolButton(title: "Ripple", icon: "rectangle.split.3x1", filled: s.ripple) { session.view { $0.ripple.toggle() } }
                .accessibilityValue(s.ripple ? "On" : "Off")
            SuiteToolButton(title: session.isRunning(.cuts) ? "Cutting…" : "Cut silences", icon: "scissors", disabled: session.isRunning(.cuts)) {
                Task { await session.cutSilences() }
            }
            .help("Free · removes long pauses (silences first; filler words in Captions & hooks)")
            SuiteToolButton(title: "Snap to beat", icon: "metronome", filled: s.snapToBeats) { session.view { $0.snapToBeats.toggle() } }
                .accessibilityValue(s.snapToBeats ? "On" : "Off")
            SuiteToolButton(title: session.isRunning(.captions) ? "Captioning…" : "Auto-captions", icon: "captions.bubble",
                            disabled: session.isRunning(.captions)) {
                Task { await session.autoCaptions() }
            }
            .help(session.estimateLabel(.captions).map { "Word-timed captions · \($0)" } ?? "Word-timed captions")
            if let e = session.estimateLabel(.captions), !session.isRunning(.captions) {
                Text(e).font(t.mono(10.5)).foregroundStyle(t.muted)
            }
            Spacer(minLength: 6)
            Text(EditSuite.clockTenths(session.duration)).font(t.mono(12)).foregroundStyle(t.muted).monospacedDigit()
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(t.muted).accessibilityHidden(true)
            Slider(value: Binding(get: { log(s.zoom) }, set: { v in session.view { $0.zoom = exp(v) } }),
                   in: log(EditSuiteState.zoomRange.lowerBound)...log(EditSuiteState.zoomRange.upperBound))
                .controlSize(.mini)
                .frame(width: 110)
                .accessibilityLabel("Timeline zoom")
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .task { await session.loadEstimate(.captions) }
    }

    // MARK: Row headers

    private func rowHeader(_ row: EditSuite.Row) -> some View {
        let track = session.project.track(row.trackId)
        let hidden = track?.hidden == true
        let locked = s.locked.contains(row.trackId)
        return HStack(spacing: 6) {
            Image(systemName: row.icon).font(.system(size: 11)).foregroundStyle(t.muted).frame(width: 16).accessibilityHidden(true)
            Text(row.label).font(t.mono(10.5, .medium)).tracking(1).foregroundStyle(t.ink).lineLimit(1)
            Spacer(minLength: 2)
            if row.kind.isAudio || row.kind == .main {
                SuiteIconButton(systemName: track?.muted == true ? "speaker.slash" : "speaker.wave.1",
                                label: track?.muted == true ? "Unmute \(row.label.lowercased())" : "Mute \(row.label.lowercased())",
                                on: track?.muted == true, size: 22) { session.edit { $0.toggleMuted(row.trackId) } }
            }
            if !row.kind.isAudio {
                SuiteIconButton(systemName: hidden ? "eye.slash" : "eye", label: hidden ? "Show \(row.label.lowercased())" : "Hide \(row.label.lowercased())",
                                on: hidden, size: 22) { session.edit { $0.toggleHidden(row.trackId) } }
            }
            SuiteIconButton(systemName: locked ? "lock.fill" : "lock.open", label: locked ? "Unlock \(row.label.lowercased())" : "Lock \(row.label.lowercased())",
                            on: locked, size: 22) { session.view { $0.toggleLocked(row.trackId) } }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
    }
}

/// The time-scaled part of the timeline (inside the horizontal scroll view).
struct TimelineCanvas: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    @State private var drag: DragState?

    private struct DragState: Equatable {
        enum Kind: Equatable { case move, trimStart, trimEnd }
        let itemId: String
        let kind: Kind
        let start: Double
        let end: Double
    }

    static func rowHeight(_ k: EditV2.TrackKind) -> CGFloat {
        switch k {
        case .main: return 48
        case .music, .voice: return 36
        default: return 28
        }
    }

    private var s: EditSuiteState { session.state }
    private var z: CGFloat { CGFloat(s.zoom) }

    var body: some View {
        let width = max(600, CGFloat(session.duration) * z + 160)
        VStack(alignment: .leading, spacing: 0) {
            ruler(width: width)
            ForEach(s.rows) { row in
                rowView(row, width: width).frame(width: width, height: Self.rowHeight(row.kind), alignment: .leading)
                SuiteRule()
            }
        }
        .frame(width: width, alignment: .leading)
        .overlay(alignment: .topLeading) { playhead }
    }

    // MARK: Ruler and playhead

    private func ruler(width: CGFloat) -> some View {
        let step: Double = z >= 120 ? 0.5 : z >= 50 ? 2 : z >= 24 ? 5 : 10
        return Canvas { ctx, size in
            var tt = 0.0
            while CGFloat(tt) * z <= size.width {
                let x = CGFloat(tt) * z
                ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 12)); p.addLine(to: CGPoint(x: x, y: size.height)) }, with: .color(t.line), lineWidth: 1)
                ctx.draw(Text(EditSuite.clockTenths(tt).replacingOccurrences(of: ".0", with: "")).font(t.mono(9.5)).foregroundColor(t.muted),
                         at: CGPoint(x: x + 3, y: 6), anchor: .leading)
                tt += step
            }
        }
        .frame(width: width, height: 22)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in session.seek(Double(max(0, v.location.x) / z)) })
        .accessibilityLabel("Timeline ruler")
        .accessibilityValue(EditSuite.clockTenths(session.playhead))
    }

    private var playhead: some View {
        let x = CGFloat(session.playhead) * z
        return ZStack(alignment: .top) {
            Rectangle().fill(t.accent).frame(width: 1.5)
            Text(EditSuite.clockTenths(session.playhead)).font(t.mono(10, .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 4).frame(height: 16).background(t.accent)
        }
        .frame(maxHeight: .infinity)
        .offset(x: x - 0.75)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Rows

    @ViewBuilder private func rowView(_ row: EditSuite.Row, width: CGFloat) -> some View {
        let blocks = s.blocks(row.trackId)
        let locked = s.locked.contains(row.trackId)
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { loc in session.scrub(to: Double(loc.x / z), trackId: row.trackId) }
            if row.kind == .music { beatMarks(height: Self.rowHeight(row.kind)) }
            ForEach(blocks) { b in
                block(b, row: row, locked: locked)
            }
        }
        .opacity(session.project.track(row.trackId)?.hidden == true ? 0.4 : 1)
    }

    private func beatMarks(height: CGFloat) -> some View {
        let beats = s.beats
        return Canvas { ctx, size in
            for b in beats {
                let x = CGFloat(b.t) * z
                ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: b.strong ? 7 : 4)) },
                           with: .color(t.accent), lineWidth: b.strong ? 2 : 1)
            }
        }
        .frame(height: height)
        .allowsHitTesting(false)
    }

    private func color(_ k: EditV2.TrackKind) -> Color {
        switch k {
        case .main: return Color(hex: 0x23262A)
        case .text: return t.accent.opacity(0.15)
        case .caption: return t.surface
        case .video, .image: return t.surface2
        case .voice: return Color(hex: 0x6E6AE0).opacity(0.18)
        case .music: return Color(hex: 0x2F9E57).opacity(0.18)
        case .sfx: return Color(hex: 0xF2A93B).opacity(0.25)
        }
    }

    @ViewBuilder private func block(_ b: EditSuite.Block, row: EditSuite.Row, locked: Bool) -> some View {
        let x = CGFloat(b.startSec) * z
        let w = max(4, CGFloat(b.endSec - b.startSec) * z)
        let h = Self.rowHeight(row.kind) - 6
        let selected = b.itemId != nil && b.itemId == s.selection
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3).fill(color(row.kind))
            blockContent(b, row: row, width: w, height: h)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            RoundedRectangle(cornerRadius: 3).strokeBorder(selected ? t.accent : t.line.opacity(0.7), lineWidth: selected ? 2 : 1)
            if selected && !locked && b.itemId != nil {
                HStack(spacing: 0) {
                    trimHandle(b, edge: .start, height: h)
                    Spacer(minLength: 0)
                    trimHandle(b, edge: .end, height: h)
                }
            }
        }
        .frame(width: w, height: h)
        .offset(x: x, y: 3)
        .contentShape(Rectangle())
        .onTapGesture {
            guard let id = b.itemId else {
                session.scrub(to: b.startSec, trackId: row.trackId)
                return
            }
            if !locked { session.view { $0.selection = id } }
        }
        .gesture(moveGesture(b, row: row, locked: locked))
        .overlay(alignment: .topLeading) {
            if row.kind == .main, let tr = b.transition {
                Image(systemName: "diamond.fill").font(.system(size: 13)).foregroundStyle(t.accent)
                    .offset(x: x - 7, y: 3 + h / 2 - 7)
                    .help(EditV2.transitionLabel(tr))
                    .accessibilityLabel("Transition: \(EditV2.transitionLabel(tr))")
                    .onTapGesture {
                        if let id = b.itemId {
                            session.view { $0.selection = id; $0.tab = .video }
                        }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.label.capitalized): \(b.label)")
        .accessibilityValue("\(EditSuite.clockTenths(b.startSec)) to \(EditSuite.clockTenths(b.endSec))")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private func blockContent(_ b: EditSuite.Block, row: EditSuite.Row, width: CGFloat, height: CGFloat) -> some View {
        switch row.kind {
        case .main, .video:
            if let id = b.itemId, let c = session.project.track(row.trackId)?.item(id)?.videoClip {
                strip(c, width: width, height: height)
                    .overlay(alignment: .topLeading) {
                        Text(b.label).font(t.mono(9.5)).foregroundStyle(.white).lineLimit(1).padding(.horizontal, 4).padding(.top, 2)
                            .shadow(color: .black, radius: 1)
                    }
            }
        case .music, .voice, .sfx:
            if let id = b.itemId, let c = session.project.track(row.trackId)?.item(id)?.audioClip {
                wave(asset: c.asset, inSec: c.inSec, outSec: c.outSec, width: width, height: height, kind: row.kind)
                    .overlay(alignment: .leading) {
                        if row.kind == .sfx { Text(b.label).font(t.mono(9.5)).foregroundStyle(t.ink).lineLimit(1).padding(.horizontal, 4) }
                    }
            }
        default:
            Text(b.label).font(t.mono(10)).foregroundStyle(row.kind == .text ? t.accent : t.ink).lineLimit(1).padding(.horizontal, 5)
        }
    }

    /// Frames of the clip's source across the block.
    private func strip(_ c: EditV2.VideoClip, width: CGFloat, height: CGFloat) -> some View {
        let frames = session.strips[c.asset] ?? []
        let dur = session.project.asset(c.asset)?.durationSec ?? max(c.outSec, 0.1)
        let tileW = max(16, height * 0.75)
        let n = max(1, Int((width / tileW).rounded(.up)))
        return HStack(spacing: 0) {
            ForEach(0..<n, id: \.self) { k in
                let src = c.inSec + (Double(k) + 0.5) / Double(n) * (c.outSec - c.inSec)
                let i = frames.isEmpty ? -1 : min(frames.count - 1, max(0, Int(src / dur * Double(frames.count))))
                Group {
                    if i >= 0 {
                        Image(decorative: frames[i], scale: 1).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color(hex: 0x33302C)
                    }
                }
                .frame(width: tileW, height: height)
                .clipped()
            }
        }
        .frame(width: width, height: height, alignment: .leading)
    }

    /// The asset's peaks between in and out.
    private func wave(asset: String, inSec: Double, outSec: Double, width: CGFloat, height: CGFloat, kind: EditV2.TrackKind) -> some View {
        let peaks = session.waves[asset] ?? []
        let dur = session.project.asset(asset)?.durationSec ?? outSec
        let tint: Color = kind == .music ? Color(hex: 0x2F9E57) : kind == .voice ? Color(hex: 0x6E6AE0) : Color(hex: 0xB45A00)
        return Canvas { ctx, size in
            guard !peaks.isEmpty, dur > 0 else { return }
            let bars = max(1, Int(size.width / 3))
            for k in 0..<bars {
                let src = inSec + (Double(k) + 0.5) / Double(bars) * (outSec - inSec)
                let i = min(peaks.count - 1, max(0, Int(src / dur * Double(peaks.count))))
                let v = CGFloat(peaks[i]) * (size.height - 4)
                let x = CGFloat(k) * 3 + 1
                ctx.fill(Path(CGRect(x: x, y: (size.height - v) / 2, width: 2, height: max(1, v))), with: .color(tint))
            }
        }
        .frame(width: width, height: height)
    }

    // MARK: Gestures

    private func trimHandle(_ b: EditSuite.Block, edge: EditSuiteState.Edge, height: CGFloat) -> some View {
        Rectangle().fill(t.accent).frame(width: 6, height: height)
            .contentShape(Rectangle().inset(by: -4))
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in
                    guard let id = b.itemId else { return }
                    if drag == nil {
                        drag = DragState(itemId: id, kind: edge == .start ? .trimStart : .trimEnd, start: b.startSec, end: b.endSec)
                        session.beginGesture()
                    }
                    guard let d = drag else { return }
                    let target = (edge == .start ? d.start : d.end) + Double(v.translation.width / z)
                    session.updateGesture { $0.trimming(id, edge, to: target) }
                }
                .onEnded { _ in
                    drag = nil
                    session.endGesture()
                })
            .accessibilityLabel(edge == .start ? "Trim start" : "Trim end")
    }

    private func moveGesture(_ b: EditSuite.Block, row: EditSuite.Row, locked: Bool) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                guard !locked, row.kind != .main, row.kind != .caption, let id = b.itemId else { return }
                if drag == nil {
                    drag = DragState(itemId: id, kind: .move, start: b.startSec, end: b.endSec)
                    session.view { $0.selection = id }
                    session.beginGesture()
                }
                guard let d = drag, d.kind == .move else { return }
                let target = d.start + Double(v.translation.width / z)
                session.updateGesture { $0.moving(id, to: target) }
            }
            .onEnded { _ in
                if drag != nil { session.endGesture() }
                drag = nil
            }
    }
}

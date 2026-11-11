import AppKit
import MuseCore
import SwiftUI

/// The multitrack timeline (E1, plans/edit-layout.md): a 48 pt toolbar (Split, Delete, Speed, Keyframe, Crop; Undo /
/// Redo; Ripple, Cut silences and Snap to beat as toggles; zoom), the ruler with the playhead, and one lane per track with
/// a 176 pt header (name in full, mute / visibility / lock): frame strips and transition diamonds on Video, caption
/// pages, hooks/text, overlays, waveforms with beat marks on music, and the video's own sound as the Sound lane.
/// Click to seek and select, drag a block to move it, drag its edges to trim. Zoom with the slider (points per second).
struct EditSuiteTimeline: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    /// ≥ 1440 pt windows: the edit tools show their labels.
    var wide = false
    /// Very narrow: the toggles go icon-only too (never hidden).
    var narrow = false
    static let headerWidth: CGFloat = 176

    private var s: EditSuiteState { session.state }

    var body: some View {
        let lanes = TimelineCanvas.lanes(session)
        VStack(spacing: 0) {
            toolbar
            SuiteRule()
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: TimelineCanvas.rulerHeight)
                        SuiteRule()
                        ForEach(lanes) { lane in
                            header(lane).frame(height: TimelineCanvas.laneHeight(lane))
                            SuiteRule()
                        }
                    }
                    .frame(width: Self.headerWidth)
                    SuiteRule(vertical: true)
                    ScrollView(.horizontal) {
                        TimelineCanvas(session: session, lanes: lanes)
                    }
                }
            }
        }
        .background(t.roles.canvas)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: Space.s1) {
            tool("Split", icon: "scissors", help: "Split at the playhead (S)") { session.edit { $0.split() } }
            tool("Delete", icon: "trash", help: "Delete (⌫)", disabled: s.selection == nil) { session.edit { $0.deleteSelected() } }
            tool("Speed", icon: "gauge", help: "Speed", disabled: s.selectedVideo == nil) { session.view { $0.tab = .speed } }
            tool("Freeze frame", icon: "pause", help: "Freeze frame at the playhead (1 s)", disabled: session.project.mainClips.isEmpty) {
                session.edit { $0.freezeFrame(durationSec: 1) }
            }
            tool("Keyframe", icon: "diamond", help: "Keyframe position, scale, rotation and opacity at the playhead", disabled: s.selectedVisual == nil) {
                session.edit { $0.addKeyframesAll() }
            }
            tool("Crop", icon: "crop", help: "Crop and transform", disabled: s.selectedVisual == nil || s.selectedItem?.textItem != nil) { session.view { $0.tab = .video } }
            divider
            SuiteIconButton(systemName: "arrow-counter-clockwise", label: "Undo (⌘Z)", disabled: !s.canUndo) { EditShortcutRunner.undoRedo(false, session) }
                .keyboardShortcut("z", modifiers: .command)
            SuiteIconButton(systemName: "arrow-clockwise", label: "Redo (⇧⌘Z)", disabled: !s.canRedo) { EditShortcutRunner.undoRedo(true, session) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            divider
            SuiteToolButton(title: "Ripple", icon: "magnet", filled: s.ripple, plain: !s.ripple, iconOnly: narrow) { session.view { $0.ripple.toggle() } }
                .accessibilityValue(s.ripple ? "On" : "Off")
                .help("Ripple: closing a gap moves what follows")
            SuiteToolButton(title: session.isRunning(.cuts) ? "Cutting…" : "Cut silences", icon: "scissors", disabled: session.isRunning(.cuts),
                            plain: true, iconOnly: narrow) {
                Task { await session.cutSilences() }
            }
            .help("Free. Removes long pauses (silences first; filler words in Captions and hooks)")
            SuiteToolButton(title: "Snap to beat", icon: "music-note", filled: s.snapToBeats, plain: !s.snapToBeats, iconOnly: !wide) {
                session.view { $0.snapToBeats.toggle() }
            }
            .accessibilityValue(s.snapToBeats ? "On" : "Off")
            Spacer(minLength: Space.s2)
            zoom
        }
        .padding(.horizontal, Space.s3)
        .frame(height: 48)
        .task { await session.loadEstimate(.captions) }
    }

    private var divider: some View {
        Rectangle().fill(t.roles.hairline).frame(width: 1, height: 20).padding(.horizontal, Space.s1 + 2)
    }

    /// An edit tool: icon and label when there's room (≥ 1440 pt windows), icon with a tooltip below.
    @ViewBuilder private func tool(_ title: String, icon: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        if wide {
            SuiteToolButton(title: title, icon: icon, disabled: disabled, plain: true, action: action)
                .help(help)
                .accessibilityLabel(help)
        } else {
            SuiteIconButton(systemName: icon, label: help, disabled: disabled, action: action)
        }
    }

    private var zoom: some View {
        let range = log(EditSuiteState.zoomRange.lowerBound)...log(EditSuiteState.zoomRange.upperBound)
        let step = (range.upperBound - range.lowerBound) / 8
        return HStack(spacing: Space.s1) {
            SuiteIconButton(systemName: "magnifying-glass-minus", label: "Zoom out", tint: t.roles.ink2) {
                session.view { $0.zoom = exp(max(range.lowerBound, log($0.zoom) - step)) }
            }
            Slider(value: Binding(get: { log(s.zoom) }, set: { v in session.view { $0.zoom = exp(v) } }), in: range)
                .controlSize(.mini)
                .tint(t.roles.accent)
                .frame(width: 96)
                .accessibilityLabel("Timeline zoom")
            SuiteIconButton(systemName: "magnifying-glass-plus", label: "Zoom in", tint: t.roles.ink2) {
                session.view { $0.zoom = exp(min(range.upperBound, log($0.zoom) + step)) }
            }
        }
    }

    // MARK: Lane headers

    @ViewBuilder private func header(_ lane: TimelineCanvas.Lane) -> some View {
        switch lane {
        case .track(let row): rowHeader(row)
        case .noCaptions:
            headerLabel("Captions", icon: "closed-captioning")
        case .sound(let trackId):
            let muted = session.project.track(trackId)?.muted == true
            HStack(spacing: 0) {
                headerLabel("Sound", icon: "waveform")
                SuiteIconButton(systemName: muted ? "speaker-slash" : "speaker-high", label: muted ? "Unmute the sound" : "Mute the sound",
                                on: muted, size: 28, tint: t.roles.ink2) { session.edit { $0.toggleMuted(trackId) } }
            }
            .padding(.trailing, Space.s2)
        }
    }

    private func headerLabel(_ name: String, icon: String) -> some View {
        HStack(spacing: Space.s2) {
            Ph(icon, 15).foregroundStyle(t.roles.ink2).frame(width: 20).accessibilityHidden(true)
            Text(name).font(t.scale.label.font).foregroundStyle(t.roles.ink).lineLimit(1).fitProbe("track \(name)")
            Spacer(minLength: 0)
        }
        .padding(.leading, Space.s3)
        .frame(maxHeight: .infinity)
    }

    private func rowHeader(_ row: EditSuite.Row) -> some View {
        let track = session.project.track(row.trackId)
        let hidden = track?.hidden == true
        let locked = s.locked.contains(row.trackId)
        let name = row.label.lowercased()
        // The main track's sound has its own lane (Sound) when the video has sound: its mute lives there.
        let soundLane = row.kind == .main && TimelineCanvas.soundTrack(session) == row.trackId
        return HStack(spacing: 0) {
            headerLabel(row.label, icon: TimelineCanvas.icon(row.kind))
            if row.kind.isAudio || (row.kind == .main && !soundLane) {
                SuiteIconButton(systemName: track?.muted == true ? "speaker-slash" : "speaker-high",
                                label: track?.muted == true ? "Unmute \(name)" : "Mute \(name)",
                                on: track?.muted == true, size: 28, tint: t.roles.ink2) { session.edit { $0.toggleMuted(row.trackId) } }
            }
            if !row.kind.isAudio {
                SuiteIconButton(systemName: hidden ? "eye-slash" : "eye", label: hidden ? "Show \(name)" : "Hide \(name)",
                                on: hidden, size: 28, tint: t.roles.ink2) { session.edit { $0.toggleHidden(row.trackId) } }
            }
            SuiteIconButton(systemName: locked ? "lock" : "lock-open", label: locked ? "Unlock \(name)" : "Lock \(name)",
                            on: locked, size: 28, tint: t.roles.ink2) { session.view { $0.toggleLocked(row.trackId) } }
        }
        .padding(.trailing, Space.s2)
    }
}

/// The time-scaled part of the timeline (inside the horizontal scroll view).
struct TimelineCanvas: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    var lanes: [Lane]
    @State private var drag: DragState?
    /// A main clip being dragged to a new place: how far it has moved (points).
    @State private var reorderOffset: CGFloat = 0
    /// A keyframe ◆ being dragged (parity): its item time when the drag started.
    @State private var keyFrom: Double?

    /// Where a main clip dropped with its centre at timeline `centre` goes: the number of other clips whose centre is before it.
    static func reorderIndex(blocks: [EditSuite.Block], moving id: String, centre: Double) -> Int {
        blocks.filter { $0.itemId != id && ($0.startSec + $0.endSec) / 2 < centre }.count
    }

    /// A lane of the timeline: a track, the Captions lane before there are captions, or the video's own sound.
    enum Lane: Identifiable, Hashable {
        case track(EditSuite.Row)
        case noCaptions
        case sound(trackId: String)
        var id: String {
            switch self {
            case .track(let r): return r.id
            case .noCaptions: return "#captions"
            case .sound(let id): return "#sound-\(id)"
            }
        }
    }

    static let rulerHeight: CGFloat = 28

    /// The main track, when its clips have sound (the Sound lane draws their waveform; its mute is the main track's).
    static func soundTrack(_ session: EditSuiteSession) -> String? {
        guard let main = session.project.mainTrack else { return nil }
        let sounding = main.items.contains { it in
            guard let c = it.videoClip else { return false }
            return session.project.asset(c.asset)?.hasAudio != false
        }
        return sounding ? main.id : nil
    }

    /// The rows in the design's order with the Captions lane (made or not) and the Sound lane under the video.
    static func lanes(_ session: EditSuiteSession) -> [Lane] {
        let rows = session.state.rows
        var out: [Lane] = []
        if !rows.contains(where: { $0.kind == .caption }) {
            let firstVisual = rows.firstIndex { $0.kind != .text } ?? rows.count
            out = rows[..<firstVisual].map { Lane.track($0) } + [Lane.noCaptions] + rows[firstVisual...].map { Lane.track($0) }
        } else {
            out = rows.map { Lane.track($0) }
        }
        if let sound = soundTrack(session), let i = out.firstIndex(where: { if case .track(let r) = $0 { return r.trackId == sound }; return false }) {
            out.insert(.sound(trackId: sound), at: i + 1)
        }
        return out
    }

    static func laneHeight(_ lane: Lane) -> CGFloat {
        switch lane {
        case .track(let r): return rowHeight(r.kind)
        case .noCaptions: return 44
        case .sound: return 56
        }
    }

    static func icon(_ k: EditV2.TrackKind) -> String {
        switch k {
        case .main: return "film-strip"
        case .video: return "stack"
        case .image: return "sticker"
        case .text: return "text-t"
        case .caption: return "closed-captioning"
        case .music: return "music-notes"
        case .voice: return "microphone"
        case .sfx: return "speaker-high"
        case .adjust: return "sliders-horizontal"
        }
    }

    private struct DragState: Equatable {
        enum Kind: Equatable { case move, trimStart, trimEnd }
        let itemId: String
        let kind: Kind
        let start: Double
        let end: Double
    }

    static func rowHeight(_ k: EditV2.TrackKind) -> CGFloat {
        switch k {
        case .main: return 72
        case .music, .voice, .video, .image: return 56
        default: return 44
        }
    }

    private var s: EditSuiteState { session.state }
    private var z: CGFloat { CGFloat(s.zoom) }

    var body: some View {
        let width = min(2_000_000, max(600, CGFloat(EditSuite.finiteSeconds(session.duration)) * z + 160)) // finite (owner blocker 2026-11-07)
        VStack(alignment: .leading, spacing: 0) {
            ruler(width: width)
            SuiteRule()
            ForEach(lanes) { lane in
                laneView(lane, width: width).frame(width: width, height: Self.laneHeight(lane), alignment: .leading)
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
            var tt = 0.0, ticks = 0
            while CGFloat(tt) * z <= size.width, ticks < 20_000, z > 0 {
                ticks += 1
                let x = CGFloat(tt) * z
                ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: size.height - 6)); p.addLine(to: CGPoint(x: x, y: size.height)) },
                           with: .color(t.roles.hairline), lineWidth: 1)
                ctx.draw(Text(EditSuite.clockTenths(tt).replacingOccurrences(of: ".0", with: "")).font(t.scale.micro.font).monospacedDigit()
                            .foregroundColor(t.roles.ink2),
                         at: CGPoint(x: x + 4, y: size.height / 2 - 2), anchor: .leading)
                tt += step
            }
        }
        .frame(width: width, height: Self.rulerHeight)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in session.seek(Double(max(0, v.location.x) / z)) })
        .accessibilityLabel("Timeline ruler")
        .accessibilityValue(EditSuite.clockTenths(session.playhead))
    }

    private var playhead: some View {
        let x = CGFloat(EditSuite.finiteSeconds(session.playhead)) * z
        return Rectangle().fill(t.roles.accent).frame(width: 2)
        .frame(maxHeight: .infinity)
        .offset(x: x - 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Rows

    @ViewBuilder private func laneView(_ lane: Lane, width: CGFloat) -> some View {
        switch lane {
        case .track(let row): rowView(row, width: width)
        case .noCaptions:
            HStack(spacing: Space.s2) {
                SuiteToolButton(title: session.isRunning(.captions) ? "Captioning…" : "Make captions", icon: "closed-captioning",
                                disabled: session.isRunning(.captions) || !session.helperAvailable(.captions), plain: true) { Task { await session.autoCaptions() } }
                    .help(session.helperNote(.captions) ?? session.estimateLabel(.captions).map { "Word-timed captions from what's said, \($0)" } ?? "Word-timed captions from what's said")
                if session.isRunning(.captions) { ProgressView().controlSize(.small) }
            }
            .padding(.leading, Space.s2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        case .sound(let trackId): soundLane(trackId, width: width)
        }
    }

    /// The main clips' own sound, under each clip.
    private func soundLane(_ trackId: String, width: CGFloat) -> some View {
        let h = Self.laneHeight(.sound(trackId: trackId)) - 12
        let muted = session.project.track(trackId)?.muted == true
        return ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { loc in session.scrub(to: Double(loc.x / z), trackId: trackId) }
            ForEach(s.blocks(trackId)) { b in
                if let id = b.itemId, let c = session.project.track(trackId)?.item(id)?.videoClip {
                    let x = CGFloat(EditSuite.finiteSeconds(b.startSec)) * z
                    let w = max(4, CGFloat(EditSuite.finiteSeconds(b.endSec - b.startSec)) * z)
                    wave(asset: c.asset, inSec: c.inSec, outSec: c.outSec, width: max(1, w - 12), height: h, kind: .main)
                        .padding(.horizontal, 6)
                        .frame(width: w, height: h)
                        .background(RoundedRectangle(cornerRadius: min(t.radii.control, 8), style: .continuous).fill(t.roles.field))
                        .offset(x: x, y: 6)
                        .allowsHitTesting(false)
                }
            }
        }
        .opacity(muted ? 0.4 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(muted ? "Sound, muted" : "Sound")
    }

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
            // Design pass: while a voice-over records, a red bar grows on the first voice row from where it started.
            if session.isRecordingVO, row.kind == .voice, session.project.tracks.first(where: { $0.kind == .voice })?.id == row.trackId {
                let from = session.voStartSec
                Rectangle().fill(t.roles.danger.opacity(0.55))
                    .frame(width: max(2, CGFloat(max(0, session.playhead - from)) * z), height: Self.rowHeight(row.kind) - 12)
                    .offset(x: CGFloat(from) * z, y: 6)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Recording")
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
                           with: .color(t.roles.accent), lineWidth: b.strong ? 2 : 1)
            }
        }
        .frame(height: height)
        .allowsHitTesting(false)
    }

    private func color(_ k: EditV2.TrackKind) -> Color {
        switch k {
        case .main: return t.editViewer
        case .text: return t.roles.accent.opacity(0.15)
        case .caption: return t.roles.field
        case .video, .image: return t.roles.field
        case .voice: return Color(hex: 0x6E6AE0).opacity(0.18)
        case .music: return Color(hex: 0x2F9E57).opacity(0.18)
        case .sfx: return Color(hex: 0xF2A93B).opacity(0.25)
        case .adjust: return t.roles.accent.opacity(0.1)
        }
    }

    @ViewBuilder private func block(_ b: EditSuite.Block, row: EditSuite.Row, locked: Bool) -> some View {
        let x = CGFloat(EditSuite.finiteSeconds(b.startSec)) * z
        let w = max(4, CGFloat(EditSuite.finiteSeconds(b.endSec - b.startSec)) * z)
        let h = Self.rowHeight(row.kind) - 12
        let selected = b.itemId != nil && b.itemId == s.selection
        let shape = RoundedRectangle(cornerRadius: min(t.radii.control, 8), style: .continuous)
        ZStack(alignment: .leading) {
            shape.fill(color(row.kind))
            blockContent(b, row: row, width: w, height: h)
                .clipShape(shape)
            shape.strokeBorder(selected ? t.roles.selection : .clear, lineWidth: 2)
            if selected && !locked && b.itemId != nil {
                HStack(spacing: 0) {
                    trimHandle(b, edge: .start, height: h)
                    Spacer(minLength: 0)
                    trimHandle(b, edge: .end, height: h)
                }
            }
            if selected && !locked, let id = b.itemId {
                // By position, so the ◆ being dragged keeps its identity while its time changes (keys can't pass each other).
                ForEach(Array(s.keyTimes(id).enumerated()), id: \.offset) { _, kt in keyMark(id, at: kt, height: h) }
            }
        }
        .frame(width: w, height: h)
        .offset(x: x + (row.kind == .main && drag?.itemId == b.itemId && drag?.kind == .move ? reorderOffset : 0), y: 6)
        .zIndex(drag?.itemId == b.itemId ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture {
            guard let id = b.itemId else {
                session.scrub(to: b.startSec, trackId: row.trackId)
                return
            }
            if !locked { session.view { $0.selection = id } }
        }
        .gesture(moveGesture(b, row: row, locked: locked))
        .overlay(alignment: .topTrailing) {
            if let id = b.itemId, let badge = MaskBadge(session.project.track(row.trackId)?.item(id)), w >= 36 {
                maskBadge(badge, itemId: id, locked: locked).offset(x: x, y: 6)
            }
        }
        .overlay(alignment: .topLeading) {
            if row.kind == .main, let tr = b.transition {
                Ph("diamond.fill", 13).foregroundStyle(t.roles.accent)
                    .offset(x: x - 8, y: 6 + h / 2 - 8)
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
        .accessibilityLabel("\(row.label): \(b.label)\(b.itemId.flatMap { MaskBadge(session.project.track(row.trackId)?.item($0)) }.map { ", \($0.text)" } ?? "")")
        .accessibilityValue("\(EditSuite.clockTenths(b.startSec)) to \(EditSuite.clockTenths(b.endSec))")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// A clip's mask, Invert, green-screen key or cut-out, which can hide most of the picture without showing on the
    /// timeline (the owner's "oval", 2026-11-11). Click: select the clip and open "Mask & green screen".
    private func maskBadge(_ badge: MaskBadge, itemId: String, locked: Bool) -> some View {
        Button {
            guard !locked else { return }
            session.view { $0.selection = itemId; $0.tab = .video }
            session.reveal = MaskBadge.panelId
        } label: {
            Ph(badge.icon, 12).foregroundStyle(.white).shadow(color: .black, radius: 1)
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, Space.s1)
        .help("\(badge.text). Click to open Mask & green screen")
        .accessibilityLabel(badge.text)
        .accessibilityHint("Opens Mask & green screen")
    }

    @ViewBuilder private func blockContent(_ b: EditSuite.Block, row: EditSuite.Row, width: CGFloat, height: CGFloat) -> some View {
        switch row.kind {
        case .main, .video:
            if let id = b.itemId, let c = session.project.track(row.trackId)?.item(id)?.videoClip {
                strip(c, width: width, height: height)
                    .overlay(alignment: .topLeading) {
                        Text(b.label).font(t.scale.micro.font).foregroundStyle(.white).lineLimit(1).padding(.horizontal, Space.s1 + 2).padding(.top, 2)
                            .shadow(color: .black, radius: 1)
                    }
            }
        case .music, .voice, .sfx:
            if let id = b.itemId, let c = session.project.track(row.trackId)?.item(id)?.audioClip {
                wave(asset: c.asset, inSec: c.inSec, outSec: c.outSec, width: width, height: height, kind: row.kind)
                    .overlay(alignment: .leading) {
                        if row.kind == .sfx { Text(b.label).font(t.scale.micro.font).foregroundStyle(t.roles.ink).lineLimit(1).padding(.horizontal, Space.s1) }
                    }
            }
        default:
            Text(b.label).font(t.scale.micro.font).foregroundStyle(row.kind == .text ? t.roles.accent : t.roles.ink).lineLimit(1).padding(.horizontal, Space.s2)
        }
    }

    /// Frames of the clip's source across the block.
    private func strip(_ c: EditV2.VideoClip, width: CGFloat, height: CGFloat) -> some View {
        // Owner blocker 2026-11-07: a 0 / NaN duration made `Int(src / dur …)` trap. The index math is in MuseCore (tested).
        let frames = session.strips[c.asset] ?? []
        let dur = session.project.asset(c.asset)?.durationSec
        let tileW = max(16, height.isFinite ? height * 0.75 : 16)
        let n = EditSuite.tileCount(width: Double(width), tileWidth: Double(tileW))
        return HStack(spacing: 0) {
            ForEach(0..<n, id: \.self) { k in
                let src = c.inSec + (Double(k) + 0.5) / Double(n) * (c.outSec - c.inSec)
                let i = EditSuite.frameIndex(source: src, durationSec: dur, fallbackSec: c.outSec, count: frames.count) ?? -1
                Group {
                    if i >= 0 && i < frames.count {
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
        let dur = session.project.asset(asset)?.durationSec
        let tint: Color = kind == .music ? Color(hex: 0x2F9E57) : kind == .voice ? Color(hex: 0x6E6AE0) : kind == .main ? t.roles.ink2.opacity(0.7) : Color(hex: 0xB45A00)
        return Canvas { ctx, size in
            guard !peaks.isEmpty else { return }
            let bars = EditSuite.tileCount(width: Double(size.width), tileWidth: 3)
            for k in 0..<bars {
                let src = inSec + (Double(k) + 0.5) / Double(bars) * (outSec - inSec)
                guard let i = EditSuite.frameIndex(source: src, durationSec: dur, fallbackSec: outSec, count: peaks.count) else { return }
                let pk = Double(peaks[i])
                let v = CGFloat(pk.isFinite ? min(1, max(0, pk)) : 0) * max(0, size.height - 4)
                let x = CGFloat(k) * 3 + 1
                ctx.fill(Path(CGRect(x: x, y: (size.height - v) / 2, width: 2, height: max(1, v))), with: .color(tint))
            }
        }
        .frame(width: width, height: height)
    }

    // MARK: Gestures

    /// A keyframe of the selected item (every property at that time): drag it along the lane to move them all, one undo
    /// step; it stops before a neighbour (parity, as Android's timeline ◆).
    private func keyMark(_ id: String, at kt: Double, height: CGFloat) -> some View {
        Rectangle().fill(t.roles.selection)
            .frame(width: 8, height: 8)
            .rotationEffect(.degrees(45))
            .overlay(Rectangle().stroke(t.roles.canvas, lineWidth: 1).frame(width: 8, height: 8).rotationEffect(.degrees(45)))
            .frame(width: 16, height: height)
            .contentShape(Rectangle())
            .offset(x: CGFloat(kt) * z - 8)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .highPriorityGesture(DragGesture(minimumDistance: 1)
                .onChanged { v in
                    if keyFrom == nil { keyFrom = kt; session.beginGesture() }
                    guard let from = keyFrom else { return }
                    session.updateGesture { $0.movingKeys(id, from: from, by: Double(v.translation.width / z)) }
                }
                .onEnded { _ in
                    keyFrom = nil
                    session.endGesture()
                })
            .help("Keyframe at \(EditSuite.clockTenths(kt)) · drag to move")
            .accessibilityLabel("Keyframe at \(EditSuite.clockTenths(kt))")
    }

    private func trimHandle(_ b: EditSuite.Block, edge: EditSuiteState.Edge, height: CGFloat) -> some View {
        Rectangle().fill(t.roles.selection).frame(width: 6, height: height)
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
                guard !locked, row.kind != .caption, let id = b.itemId else { return }
                if row.kind == .main {
                    // Main clips reorder (Mac Edit audit 2026-11-08: there was no way to change their order): the block follows
                    // the pointer and drops into the gap it ends over.
                    if drag == nil { drag = DragState(itemId: id, kind: .move, start: b.startSec, end: b.endSec); session.view { $0.selection = id } }
                    reorderOffset = v.translation.width
                    return
                }
                if drag == nil {
                    drag = DragState(itemId: id, kind: .move, start: b.startSec, end: b.endSec)
                    session.view { $0.selection = id }
                    session.beginGesture()
                }
                guard let d = drag, d.kind == .move else { return }
                let target = d.start + Double(v.translation.width / z)
                session.updateGesture { $0.moving(id, to: target) }
            }
            .onEnded { v in
                if row.kind == .main {
                    defer { drag = nil; reorderOffset = 0 }
                    guard let d = drag, let id = b.itemId else { return }
                    let to = Self.reorderIndex(blocks: s.blocks(row.trackId), moving: id, centre: (d.start + d.end) / 2 + Double(v.translation.width / z))
                    if let from = session.project.mainClips.firstIndex(where: { $0.id == id }), to != from { session.edit { $0.moveMainClip(id, to: to) } }
                    return
                }
                if drag != nil { session.endGesture() }
                drag = nil
            }
    }
}

/// What a clip's badge says is on: a mask (Invert noted), a green-screen key, a cut-out. Nil when none.
struct MaskBadge {
    static let panelId = "edit.mask"
    let text: String
    let icon: String

    init?(_ item: EditV2.Item?) {
        let mask = item?.videoClip?.mask ?? item?.imageItem?.mask
        let c = item?.videoClip
        var on: [String] = []
        if let mask { on.append(mask.invert == true ? "Inverted mask" : "Mask") }
        if c?.chroma != nil { on.append("Green screen") }
        if let m = c?.alphaMatte { on.append(m.invert == true ? "Inverted cut-out" : "Cut-out") }
        guard let first = on.first else { return nil }
        text = ListFormatter.localizedString(byJoining: on)
        icon = mask?.invert == true ? "selection-background" : mask != nil ? "selection" : first == "Green screen" ? "drop" : "scissors"
    }
}

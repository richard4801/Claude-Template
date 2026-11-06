import AppKit
import MuseCore
import SwiftUI
import UniformTypeIdentifiers

// The inspector panels of design E2: Transform & keyframes, Filters & LUTs (the Looks picker), Adjust, Mask & green
// screen, Transitions (Video tab); Audio · clip and Audio · mix & beats (Audio tab); Speed with the curve editor.

private func signed100(_ v: Double) -> String {
    let n = Int((v * 100).rounded())
    return n > 0 ? "+\(n)" : "\(n)"
}

private func dbString(_ gain: Double) -> String {
    let d = EditSuite.db(gain: gain)
    return d == 0 ? "0 dB" : String(format: "%+.0f dB", d)
}

// MARK: - Video tab

struct VideoPanels: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession

    var body: some View {
        if let v = session.state.selectedVisual {
            TransformPanel(session: session, visual: v)
            if session.state.selectedItem?.textItem == nil {
                LooksPanel(session: session, visual: v)
                AdjustPanel(session: session, visual: v)
                MaskPanel(session: session, visual: v)
            }
            if session.state.selectedIsMain { TransitionsPanel(session: session) }
        } else {
            InspectorEmpty(text: "Select a clip, an overlay or a sticker on the timeline.")
        }
    }
}

struct TransformPanel: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    var visual: EditSuite.Visual

    private func setTransform(_ f: @escaping (inout EditV2.Transform) -> Void) {
        session.edit { s in s.changeVisual { v in var tf = v.transform ?? EditV2.Transform(); f(&tf); v.transform = tf } }
    }

    var body: some View {
        let tf = visual.transform ?? EditV2.Transform()
        let k = visual.keyframes
        EditPanel(title: "Transform & keyframes") {
            row("Position X", value: (tf.x ?? 0.5) - 0.5, range: -1...1, prop: .x, keys: k?.x, fmt: signed100) { v in setTransform { $0.x = 0.5 + v } }
            row("Position Y", value: (tf.y ?? 0.5) - 0.5, range: -1...1, prop: .y, keys: k?.y, fmt: signed100) { v in setTransform { $0.y = 0.5 + v } }
            row("Scale", value: tf.scale ?? 1, range: 0.1...4, prop: .scale, keys: k?.scale, fmt: { "\(Int(($0 * 100).rounded()))%" }) { v in setTransform { $0.scale = v } }
            row("Rotation", value: tf.rotation ?? 0, range: -180...180, prop: .rotation, keys: k?.rotation, fmt: { "\(Int($0.rounded()))°" }) { v in setTransform { $0.rotation = v } }
            row("Opacity", value: visual.opacity ?? 1, range: 0...1, prop: .opacity, keys: k?.opacity, fmt: { "\(Int(($0 * 100).rounded()))%" }) { v in
                session.edit { s in s.changeVisual { $0.opacity = v } }
            }
            HStack {
                SuiteLabel("Ease")
                EditSeg(options: [(EditV2.Ease.linear, "Linear"), (.easeInOut, "In-out"), (.easeOut, "Ease out"), (.hold, "Hold")],
                         selection: k?.present.first?.1.first?.ease ?? .easeInOut) { e in session.edit { $0.setKeyframeEase(e) } }
                    .frame(width: 230)
            }
            HStack(spacing: 6) {
                Ph("diamond.fill", 9).foregroundStyle(t.muted)
                Text("adds a keyframe at the playhead").font(t.body(12)).foregroundStyle(t.muted)
            }
        }
    }

    private func row(_ label: String, value: Double, range: ClosedRange<Double>, prop: EditV2.KfProp, keys: [EditV2.Keyframe]?,
                     fmt: @escaping (Double) -> String, set: @escaping (Double) -> Void) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            SuiteSlider(label, value: min(range.upperBound, max(range.lowerBound, value)), range: range, format: fmt, onCommit: set)
            SuiteIconButton(systemName: (keys?.isEmpty ?? true) ? "diamond" : "diamond.fill", label: "Add a \(label.lowercased()) keyframe at the playhead",
                            on: !(keys?.isEmpty ?? true), size: 24) {
                let v = prop == .x || prop == .y ? value + 0.5 : value
                session.edit { $0.addKeyframe(prop, value: v) }
            }
        }
    }
}

/// Filters & LUTs: the 32 bundled looks drawn on the current frame, by category; intensity; .cube import. A suite look
/// ("palette:<id>", generated from a palette or film stock) isn't listed: it shows as the current look card.
struct LooksPanel: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    var visual: EditSuite.Visual
    @State private var category = "all"

    var body: some View {
        let pack = EditV2LookLibrary.shared.pack
        let looks = (pack?.looks ?? []).filter { category == "all" || $0.category == category }
        let current = session.selectedLookId
        EditPanel(title: "Filters & LUTs", trailing: "\(pack?.looks.count ?? 0) looks") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Chip("All", on: category == "all") { category = "all" }
                    ForEach(EditV2.LookPack.categories, id: \.self) { c in
                        Chip(c == "bw" ? "B&W" : c.capitalized, on: category == c) { category = c }
                    }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 78, maximum: 110), spacing: 8)], spacing: 10) {
                tile(id: nil, name: "Clean", image: session.lookFrame, on: visual.look?.lut == nil)
                ForEach(looks) { e in
                    tile(id: e.id, name: e.name, image: session.lookThumbs[e.id], on: current == e.id)
                }
            }
            if let pid = visual.look?.paletteId { suiteLookCard(name: EditV2LookLibrary.shared.palettes.name(of: pid)) }
            if pack == nil { Note(warn: true, "The look pack is missing from this build.") }
            if let look = visual.look, look.lut != nil {
                SuiteSlider("Intensity", value: look.strength ?? 1, range: 0...1, format: { "\(Int(($0 * 100).rounded()))%" }) { v in
                    session.edit { s in s.changeVisual { vv in vv.look?.strength = (v * 100).rounded() / 100 } }
                }
            }
            HStack {
                SuiteToolButton(title: ".cube import", icon: "square.and.arrow.down") { importCube() }
                Spacer()
                Text("Same looks as the Camera bag palettes").font(t.body(11.5)).foregroundStyle(t.muted)
            }
        }
        .task(id: session.state.selection) { session.refreshLookThumbs() }
    }

    /// The clip's suite look: picking a look above swaps it, Remove clears it, the intensity slider works on it as on any look.
    private func suiteLookCard(name: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Current look").font(t.body(11)).foregroundStyle(t.muted)
                Text("Suite look · \(name)").font(t.body(12.5, .semibold)).foregroundStyle(t.ink).lineLimit(1)
            }
            Spacer()
            SuiteToolButton(title: "Remove", icon: "xmark") { session.applyLook(nil) }
        }
        .padding(10)
        .background(t.surface2)
        .overlay(Rectangle().strokeBorder(t.ink, lineWidth: 2))
    }

    private func tile(id: String?, name: String, image: CGImage?, on: Bool) -> some View {
        Button { session.applyLook(id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill) } else { Rectangle().fill(t.surface2) }
                }
                .frame(height: 58)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(Rectangle().strokeBorder(on ? t.ink : .clear, lineWidth: 2))
                Text(name).font(t.body(11.5, on ? .semibold : .regular)).foregroundStyle(on ? t.ink : t.muted).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Look \(name)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func importCube() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a 3D LUT (.cube, up to 64³, 12 MB)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await session.importCube(url) }
    }
}

struct AdjustPanel: View {
    @Bindable var session: EditSuiteSession
    var visual: EditSuite.Visual

    private func setAdjust(_ f: @escaping (inout EditV2.Adjust) -> Void) {
        session.edit { s in s.changeVisual { v in var a = v.adjust ?? EditV2.Adjust(); f(&a); v.adjust = a } }
    }

    var body: some View {
        let a = visual.adjust ?? EditV2.Adjust()
        EditPanel(title: "Adjust") {
            SuiteSlider("Exposure", value: a.exposure ?? 0, range: -1...1, format: signed100) { v in setAdjust { $0.exposure = v } }
            SuiteSlider("Contrast", value: a.contrast ?? 0, range: -1...1, format: signed100) { v in setAdjust { $0.contrast = v } }
            SuiteSlider("Saturation", value: a.saturation ?? 0, range: -1...1, format: signed100) { v in setAdjust { $0.saturation = v } }
            SuiteSlider("Temperature", value: a.temperature ?? 0, range: -1...1, format: signed100) { v in setAdjust { $0.temperature = v } }
            SuiteSlider("Highlights", value: a.highlights ?? 0, range: -1...1, format: signed100) { v in setAdjust { $0.highlights = v } }
            SuiteSlider("Shadows", value: a.shadows ?? 0, range: -1...1, format: signed100) { v in setAdjust { $0.shadows = v } }
            SuiteSlider("Grain", value: visual.look?.grain?.amount ?? 0, range: 0...1, format: { "\(Int(($0 * 100).rounded()))" }) { v in
                session.edit { s in
                    s.changeVisual { vv in
                        var l = vv.look ?? EditV2.Look()
                        l.grain = v > 0.005 ? EditV2.Grain(amount: (v * 100).rounded() / 100, size: l.grain?.size) : nil
                        vv.look = l
                    }
                }
            }
        }
    }
}

struct MaskPanel: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    var visual: EditSuite.Visual

    private func setMask(_ f: @escaping (inout EditV2.Mask?) -> Void) { session.edit { s in s.changeVisual { f(&$0.mask) } } }

    var body: some View {
        let m = visual.mask
        let isVideo = session.state.selectedVideo != nil
        EditPanel(title: "Mask & green screen") {
            SuiteLabel("Mask")
            FlowLayout(spacing: 6) {
                Chip("None", on: m == nil) { setMask { $0 = nil } }
                ForEach(EditV2.MaskShape.all, id: \.self) { sh in
                    Chip(sh.rawValue.capitalized, on: m?.shape == sh) {
                        setMask { cur in var x = cur ?? EditV2.Mask(shape: sh); x.shape = sh; cur = x }
                    }
                }
            }
            if let m {
                SuiteSlider("Feather", value: m.feather ?? 0.1, range: 0...1, format: { "\(Int(($0 * 100).rounded()))" }) { v in setMask { $0?.feather = v } }
                SuiteSlider("Size", value: m.width ?? 0.5, range: 0.05...1.5, format: { "\(Int(($0 * 100).rounded()))%" }) { v in
                    setMask { $0?.width = v; $0?.height = v * ((m.height ?? 0.5) / max(0.01, m.width ?? 0.5)) }
                }
                SuiteSlider("Rotation", value: m.rotation ?? 0, range: -180...180, format: { "\(Int($0.rounded()))°" }) { v in setMask { $0?.rotation = v } }
                SuiteToggleRow(title: "Invert", isOn: m.invert == true) { on in setMask { $0?.invert = on ? true : nil } }
            }
            if isVideo {
                SuiteRule()
                let ck = visual.chroma
                HStack {
                    SuiteLabel("Chroma key")
                    if let ck {
                        SuiteSwatch(hex: ck.color, label: "Key colour") { c in session.edit { s in s.changeVisual { $0.chroma?.color = c } } }
                        Text(ck.color).font(t.mono(11)).foregroundStyle(t.muted)
                    }
                    MToggle(isOn: Binding(get: { ck != nil }, set: { on in
                        session.edit { s in s.changeVisual { $0.chroma = on ? EditV2.Chroma(color: "#2BD15F", similarity: 0.4, smoothness: 0.08, spill: 0.5) : nil } }
                    }))
                    .accessibilityLabel("Chroma key")
                }
                if let ck {
                    SuiteSlider("Strength", value: ck.similarity ?? 0.4, range: 0...1, format: { "\(Int(($0 * 100).rounded()))" }) { v in
                        session.edit { s in s.changeVisual { $0.chroma?.similarity = v } }
                    }
                }
                SuiteToggleRow(title: "Remove background", hint: "No green screen needed", isOn: visual.chroma != nil && session.state.selectedVideo?.audioAsset != nil,
                               busy: session.isRunning(.matte), trailingNote: session.estimateLabel(.matte)) { on in
                    Task { await session.setRemoveBackground(on) }
                }
                .task(id: session.state.selection) { await session.loadEstimate(.matte) }
            }
        }
    }
}

struct TransitionsPanel: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    @State private var duration = 0.3

    private let tiles: [(String, String)] = [("cut", "scissors"), ("fade", "square.split.2x1"), ("zoom", "arrow.up.left.and.arrow.down.right"),
                                              ("whip", "forward.fill"), ("slideLeft", "chevron.right"), ("white", "sun.max"),
                                              ("glitch", "waveform.path"), ("spin", "arrow.clockwise")]

    var body: some View {
        let clip = session.state.selectedVideo
        let isFirst = session.project.mainClips.first?.id == clip?.id
        let current = clip?.transitionIn?.kind.rawValue ?? "cut"
        EditPanel(title: "Transitions") {
            if isFirst {
                Text("The first clip has no transition in. Select the next clip.").font(t.body(12)).foregroundStyle(t.muted)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 10) {
                ForEach(tiles, id: \.0) { tile in
                    let key = tile.0, icon = tile.1
                    let on = current == key
                    Button { set(key) } label: {
                        VStack(spacing: 5) {
                            Ph(icon, 15)
                                .frame(maxWidth: .infinity)
                                .frame(height: 40)
                                .background(Rectangle().fill(on ? t.surface : t.surface2))
                                .overlay(Rectangle().strokeBorder(on ? t.ink : t.line, lineWidth: on ? 2 : 1))
                            Text(label(key)).font(t.body(11.5)).foregroundStyle(on ? t.ink : t.muted)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isFirst)
                    .accessibilityLabel("Transition \(label(key))")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            Chip("Dip to black", on: current == "black") { set("black") }.disabled(isFirst)
            SuiteSlider("Duration", value: clip?.transitionIn?.durationSec ?? duration, range: 0.1...2, format: { String(format: "%.1f s", $0) }) { v in
                duration = (v * 10).rounded() / 10
                if let k = clip?.transitionIn?.kind { session.edit { $0.setTransition(k, duration: duration) } }
            }
            HStack(alignment: .top) {
                SuiteToolButton(title: "Apply to all cuts") {
                    let k = clip?.transitionIn?.kind
                    session.edit { $0.applyTransitionToAll(k, duration: clip?.transitionIn?.durationSec ?? duration) }
                }
                Text("Whip pans live here, not in the AI shot").font(t.body(11.5)).foregroundStyle(t.muted)
            }
        }
    }

    private func label(_ key: String) -> String { EditV2.transitionLabels.first { $0.0 == key }?.1 ?? key }

    private func set(_ key: String) {
        let kind = EditV2.TransitionKind(rawValue: key)
        let d = session.state.selectedVideo?.transitionIn?.durationSec ?? duration
        session.edit { $0.setTransition(kind, duration: d) }
    }
}

// MARK: - Audio tab

struct AudioPanels: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession

    var body: some View {
        if let snd = session.state.selectedSound { clipPanel(snd) } else {
            InspectorEmpty(text: "Select a clip, voice-over or song for its sound.")
        }
        mixPanel
    }

    private func setSound(_ f: @escaping (inout EditSuite.Sound) -> Void) { session.edit { s in s.changeSound(f) } }

    private func clipPanel(_ snd: EditSuite.Sound) -> some View {
        let audioAsset = snd.audioAsset.flatMap { session.project.asset($0) }
        let denoised = audioAsset?.kind == .audio
        return EditPanel(title: "Audio · clip") {
            SuiteSlider("Volume", value: EditSuite.db(gain: snd.volume ?? 1), range: -30...6, format: { $0 == 0 ? "0 dB" : String(format: "%+.0f dB", $0) }) { v in
                let g = v <= -29.5 ? 0 : EditSuite.gain(db: v.rounded())
                setSound { $0.volume = min(2, g) == 1 ? nil : min(2, g) }
            }
            HStack(spacing: 14) {
                SuiteSlider("Fade in", value: snd.fadeInSec ?? 0, range: 0...5, format: { String(format: "%.1f s", $0) }) { v in
                    setSound { $0.fadeInSec = v < 0.05 ? nil : (v * 10).rounded() / 10 }
                }
                SuiteSlider("Fade out", value: snd.fadeOutSec ?? 0, range: 0...5, format: { String(format: "%.1f s", $0) }) { v in
                    setSound { $0.fadeOutSec = v < 0.05 ? nil : (v * 10).rounded() / 10 }
                }
            }
            SuiteToggleRow(title: "Mute", isOn: snd.muted == true) { on in setSound { $0.muted = on ? true : nil } }
            SuiteToggleRow(title: "Noise reduction", hint: "Removes background noise and music", isOn: denoised,
                           busy: session.isRunning(.denoise), trailingNote: session.estimateLabel(.denoise)) { on in
                Task { await session.setNoiseReduction(on) }
            }
            .task(id: session.state.selection) { await session.loadEstimate(.denoise) }
            SuiteToggleRow(title: "Voice enhance", hint: "Clearer speech", isOn: snd.enhance == true) { on in setSound { $0.enhance = on ? true : nil } }
            SuiteLabel("Voice effect")
            FlowLayout(spacing: 6) {
                ForEach(EditV2.VoiceEffect.all, id: \.self) { e in
                    Chip(e.rawValue.capitalized, on: (snd.voiceEffect ?? EditV2.VoiceEffect.none) == e) { setSound { $0.voiceEffect = e == EditV2.VoiceEffect.none ? nil : e } }
                }
            }
        }
    }

    @ViewBuilder private var mixPanel: some View {
        let music = session.state.musicTrack
        EditPanel(title: "Audio · mix & beats") {
            if music == nil {
                Text("Add music (Music in the media bin) to duck it under the voice and cut on its beats.").font(t.body(12)).foregroundStyle(t.muted)
            } else {
                let duck = music?.duck
                SuiteToggleRow(title: "Auto-duck music",
                               hint: duck.map { "Under voice · \(dbString($0.level ?? 0.3).replacingOccurrences(of: "-", with: "−"))" } ?? "Quieter under voice and speech",
                               isOn: duck != nil) { on in session.edit { $0.setAutoDuck(on) } }
                if let d = duck {
                    let times = EditV2.duckTimes(d)
                    HStack(spacing: 14) {
                        SuiteSlider("Attack", value: times.attack, range: 0.05...2, format: { String(format: "%.1f s", $0) }) { v in
                            session.edit { $0.changeDuck { $0?.attackSec = (v * 20).rounded() / 20 } }
                        }
                        SuiteSlider("Release", value: times.release, range: 0.05...3, format: { String(format: "%.1f s", $0) }) { v in
                            session.edit { $0.changeDuck { $0?.releaseSec = (v * 20).rounded() / 20 } }
                        }
                    }
                    SuiteSlider("Duck to", value: EditSuite.db(gain: d.level ?? 0.3), range: -26...0, format: { String(format: "%.0f dB", $0) }) { v in
                        session.edit { $0.changeDuck { $0?.level = max(0.05, EditSuite.gain(db: v.rounded())) } }
                    }
                }
                SuiteRule()
                HStack {
                    SuiteLabel("Beat markers")
                    if let bpm = session.state.bpm { Text("\(Int(bpm.rounded())) BPM").font(t.body(12)).foregroundStyle(t.muted) }
                }
                if session.state.bpm == nil {
                    HStack {
                        SuiteToolButton(title: session.isRunning(.beats) ? "Finding the beat…" : "Detect beats", icon: "metronome",
                                        disabled: session.isRunning(.beats)) { Task { await session.detectBeats() } }
                        Spacer()
                        Text("Free").font(t.mono(11)).foregroundStyle(t.muted)
                    }
                } else {
                    EditSeg(options: [(EditSuite.BeatMarks.every, "Every beat"), (.strong, "Strong beats")], selection: session.state.beatMarks) { m in
                        session.view { $0.beatMarks = m }
                    }
                }
                SuiteToggleRow(title: "Snap cuts to beats", hint: "Auto-cut on the beat", isOn: session.state.snapToBeats) { on in
                    session.view { $0.snapToBeats = on }
                }
            }
        }
    }
}

// MARK: - Speed

struct SpeedPanel: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession

    var body: some View {
        if let c = session.state.selectedVideo {
            EditPanel(title: "Speed") {
                EditSeg(options: [(false, "Constant"), (true, "Curve")], selection: c.speedCurve != nil) { curve in
                    session.edit { $0.setSpeedPreset(curve ? .custom : nil) }
                }
                if let curve = c.speedCurve {
                    SpeedCurveEditor(curve: curve) { next in session.edit { $0.setSpeedCurve(next) } }
                        .frame(height: 150)
                    FlowLayout(spacing: 6) {
                        ForEach(EditV2.SpeedPreset.all, id: \.self) { p in
                            Chip(presetLabel(p), on: curve.preset == p) { session.edit { $0.setSpeedPreset(p) } }
                        }
                    }
                } else {
                    SuiteSlider("Speed", value: log10(c.speed), range: -1...1, format: { String(format: "%.2g×", pow(10, $0)) }) { v in
                        session.edit { $0.setSpeed(pow(10, v)) }
                    }
                    FlowLayout(spacing: 6) {
                        ForEach([0.25, 0.5, 1, 1.5, 2, 4], id: \.self) { sp in
                            Chip(String(format: "%g×", sp), on: abs(c.speed - sp) < 0.001) { session.edit { $0.setSpeed(sp) } }
                        }
                    }
                }
                HStack {
                    Text(session.state.speedSummary ?? "").font(t.body(13)).foregroundStyle(t.ink)
                    Spacer()
                    Text("Keep pitch · Drag points · double-click to add").font(t.body(11.5)).foregroundStyle(t.muted)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Smooth slow-mo").font(t.body(13.5, .semibold)).foregroundStyle(t.muted)
                        Text("Fills in frames (AI) · Coming soon").font(t.body(12)).foregroundStyle(t.muted)
                    }
                    Spacer()
                    MToggle(isOn: .constant(false)).disabled(true).opacity(0.5)
                        .accessibilityLabel("Smooth slow-mo, coming soon")
                }
            }
        } else {
            InspectorEmpty(text: "Select a video clip to change its speed.")
        }
    }

    private func presetLabel(_ p: EditV2.SpeedPreset) -> String {
        switch p {
        case .montage: return "Montage"
        case .hero: return "Hero"
        case .bullet: return "Bullet"
        case .flashIn: return "Flash in"
        case .flashOut: return "Flash out"
        default: return "Custom"
        }
    }
}

/// The speed curve: speed (log scale, 0.1×–10×) over the clip; drag the points, double-click to add one.
struct SpeedCurveEditor: View {
    @Environment(\.theme) private var t
    var curve: EditV2.SpeedCurve
    var onCommit: (EditV2.SpeedCurve) -> Void
    @State private var draft: EditV2.SpeedCurve?

    private func y(_ speed: Double, _ h: CGFloat) -> CGFloat { h * CGFloat(1 - (log10(max(0.1, min(10, speed))) + 1) / 2) }
    private func speed(_ y: CGFloat, _ h: CGFloat) -> Double { pow(10, Double(1 - y / max(1, h)) * 2 - 1) }

    var body: some View {
        let c = draft ?? curve
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                Rectangle().fill(t.surface)
                ForEach([10.0, 1.0, 0.1], id: \.self) { s in
                    Path { p in p.move(to: CGPoint(x: 0, y: y(s, h))); p.addLine(to: CGPoint(x: w, y: y(s, h))) }
                        .stroke(t.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    Text(s == 1 ? "1×" : s == 10 ? "10×" : "0.1×").font(t.mono(9)).foregroundStyle(t.muted)
                        .position(x: 16, y: min(h - 6, max(6, y(s, h) - 7)))
                }
                Path { p in
                    let n = 96
                    for i in 0...n {
                        let x = Double(i) / Double(n)
                        let pt = CGPoint(x: CGFloat(x) * w, y: y(EditV2.curveSpeed(c, x), h))
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }
                .stroke(t.accent, lineWidth: 2)
                ForEach(c.points.indices, id: \.self) { i in
                    let pt = c.points[i]
                    Circle().fill(t.surface).overlay(Circle().strokeBorder(t.accent, lineWidth: 2))
                        .frame(width: 13, height: 13)
                        .position(x: CGFloat(pt[0]) * w, y: y(pt[1], h))
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { v in
                                draft = EditSuiteState.movingCurvePoint(draft ?? curve, i, x: Double(v.location.x / max(1, w)), speed: speed(v.location.y, h))
                            }
                            .onEnded { _ in
                                if let d = draft { onCommit(d) }
                                draft = nil
                            })
                        .accessibilityLabel(String(format: "Curve point %d, %.2g×", i + 1, pt[1]))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { loc in onCommit(EditSuiteState.addingCurvePoint(curve, x: Double(loc.x / max(1, w)))) }
        }
        .overlay(Rectangle().strokeBorder(t.line))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Speed curve")
    }
}

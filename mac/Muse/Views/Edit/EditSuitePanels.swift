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
            if session.state.selectedBlend != nil { BlendPanel(session: session) }
            if session.state.selectedIsMain, let c = session.state.selectedVideo, c.holdSec == nil,
               let d = session.project.asset(c.asset)?.durationSec, d - (c.outSec - c.inSec) > 0.05 {
                SlipPanel(session: session, clip: c, sourceSec: d)
            }
            if session.state.clipsHere.count >= 2 { SplitScreenPanel(session: session) }
            if session.state.selectedIsMain { BackgroundPanel(session: session) }
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

    var body: some View {
        let s = session.state
        // Values at the playhead: a keyframed property shows (and edits) its key there, not the ignored static value
        // (Mac Edit audit 2026-11-08).
        let px = s.visualValue(.x) ?? 0.5, py = s.visualValue(.y) ?? 0.5, sc = s.visualValue(.scale) ?? 1
        let rot = s.visualValue(.rotation) ?? 0, op = s.visualValue(.opacity) ?? 1
        let isText = s.selectedItem?.textItem != nil
        EditPanel(title: "Transform & keyframes") {
            row("Position X", value: px - 0.5, range: -1...1, prop: .x, fmt: signed100) { x in session.edit { $0.setVisualValue(.x, 0.5 + x) } }
            row("Position Y", value: py - 0.5, range: -1...1, prop: .y, fmt: signed100) { y in session.edit { $0.setVisualValue(.y, 0.5 + y) } }
            row("Scale", value: sc, range: 0.1...4, prop: .scale, fmt: { "\(Int(($0 * 100).rounded()))%" }) { n in session.edit { $0.setVisualValue(.scale, n) } }
            row("Rotation", value: rot, range: -180...180, prop: .rotation, fmt: { "\(Int($0.rounded()))°" }) { n in session.edit { $0.setVisualValue(.rotation, n) } }
            row("Opacity", value: op, range: 0...1, prop: .opacity, fmt: { "\(Int(($0 * 100).rounded()))%" }) { n in session.edit { $0.setVisualValue(.opacity, n) } }
            if visual.keyframes.map({ !$0.isEmpty }) == true {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text("Ease").font(t.scale.label.font).foregroundStyle(t.roles.ink)
                    EditSeg(options: [(EditV2.Ease.linear, "Linear"), (.easeInOut, "In-out"), (.easeOut, "Ease out"), (.hold, "Hold")],
                             selection: visual.keyframes?.present.first?.1.first?.ease ?? .easeInOut, small: true) { e in session.edit { $0.setKeyframeEase(e) } }
                }
                HStack(spacing: Space.s2) {
                    SuiteToolButton(title: "Previous key", icon: "caret-left", disabled: s.adjacentKeyframe(-1) == nil, plain: true) {
                        if let k = session.state.adjacentKeyframe(-1) { session.seek(k) }
                    }
                    SuiteToolButton(title: "Next key", icon: "caret-right", disabled: s.adjacentKeyframe(1) == nil, plain: true) {
                        if let k = session.state.adjacentKeyframe(1) { session.seek(k) }
                    }
                    Spacer(minLength: 0)
                }
            }
            // Parity wave 1: mirror, and fit / fill for pictures.
            HStack(spacing: Space.s2) {
                SuiteToolButton(title: "Mirror", icon: "arrows-left-right", filled: s.selectedFlip.x, plain: !s.selectedFlip.x) {
                    let on = session.state.selectedFlip.x
                    session.edit { $0.setFlip(x: !on) }
                }
                .accessibilityLabel("Mirror horizontally")
                .accessibilityValue(s.selectedFlip.x ? "On" : "Off")
                SuiteToolButton(title: "Flip", icon: "swap", filled: s.selectedFlip.y, plain: !s.selectedFlip.y) {
                    let on = session.state.selectedFlip.y
                    session.edit { $0.setFlip(y: !on) }
                }
                .accessibilityLabel("Mirror vertically")
                .accessibilityValue(s.selectedFlip.y ? "On" : "Off")
                Spacer(minLength: 0)
            }
            if let swap = s.selectedTrackSwap {
                // Parity (as Android): a clip between the main track and an overlay track.
                SuiteToolButton(title: swap.toMain ? "Move to main track" : "Move to an overlay track", icon: "stack", disabled: !swap.possible, plain: true) {
                    if swap.toMain { session.edit { $0.moveToMain() } } else { session.edit { $0.moveToOverlay() } }
                }
                .help(swap.possible ? "" : "The main track needs at least one clip")
            }
            if !isText {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text("Frame").font(t.scale.label.font).foregroundStyle(t.roles.ink)
                    EditSeg(options: [(EditV2.Fit.cover, "Fill"), (.contain, "Fit")], selection: fitNow, small: true) { f in session.edit { $0.setFit(f) } }
                        .accessibilityLabel("Fill or fit the frame")
                }
            }
            Text("The diamond adds a keyframe at the playhead, or removes the one there. With keyframes, a slider sets the value at the playhead.")
                .font(t.scale.caption.font).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
        }
        if !isText { CropPanel(session: session, crop: visual.crop) }
    }

    /// The selected video's or picture's fit (main clips fill by default, overlays fit).
    private var fitNow: EditV2.Fit {
        switch session.state.selectedItem {
        case .video(let c): return c.fit ?? (session.state.selectedIsMain ? .cover : .contain)
        case .image(let c): return c.fit ?? .contain
        default: return .cover
        }
    }

    private func row(_ label: String, value: Double, range: ClosedRange<Double>, prop: EditV2.KfProp,
                     fmt: @escaping (Double) -> String, set: @escaping (Double) -> Void) -> some View {
        let s = session.state
        let keyed = !(session.state.selectedVisual?.keyframes?[prop]?.isEmpty ?? true)
        let here = s.hasKeyframe(prop)
        return HStack(alignment: .bottom, spacing: 8) {
            SuiteSlider(label, value: min(range.upperBound, max(range.lowerBound, value)), range: range, format: fmt, onCommit: set)
            SuiteIconButton(systemName: here ? "diamond.fill" : "diamond",
                            label: here ? "Remove the \(label.lowercased()) keyframe at the playhead" : "Add a \(label.lowercased()) keyframe at the playhead",
                            on: keyed, size: 28) {
                let v = prop == .x || prop == .y ? value + 0.5 : value
                if here { session.edit { $0.removeKeyframe(prop) } } else { session.edit { $0.addKeyframe(prop, value: v) } }
            }
        }
    }
}

/// Slip (parity): the clip plays another part of its source, keeping its length.
struct SlipPanel: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    var clip: EditV2.VideoClip
    var sourceSec: Double

    var body: some View {
        let len = clip.outSec - clip.inSec
        EditPanel(title: "Slip") {
            SuiteSlider("Starts at", value: clip.inSec, range: 0...max(0.01, sourceSec - len), format: { String(format: "%.1f s of the take", $0) }) { v in
                session.edit { $0.slip(to: v) }
            }
            Text("Plays another part of the take; its length stays.").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
        }
    }
}

/// Split screen (parity): the clips on screen at the playhead, side by side, top and bottom, in three rows or a grid.
struct SplitScreenPanel: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession

    var body: some View {
        EditPanel(title: "Split screen") {
            FlowLayout(spacing: 6) {
                ForEach(EditSuite.SplitLayout.allCases) { l in
                    Chip(l.label, on: false) { session.edit { $0.splitScreen(l) } }
                        .accessibilityLabel("Split screen \(l.label)")
                }
            }
            Text("Uses the \(session.state.clipsHere.count) clips on screen at the playhead. Each stays editable.")
                .font(t.scale.caption.font).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Blend modes for overlays (parity wave 1): how the picture mixes with the layers below.
struct BlendPanel: View {
    @Bindable var session: EditSuiteSession

    static func label(_ m: EditV2.BlendMode) -> String {
        switch m {
        case .normal: return "Normal"
        case .multiply: return "Multiply"
        case .screen: return "Screen"
        case .overlay: return "Overlay"
        case .softLight: return "Soft light"
        case .darken: return "Darken"
        case .lighten: return "Lighten"
        case .add: return "Add"
        }
    }

    var body: some View {
        let cur = session.state.selectedBlend ?? .normal
        EditPanel(title: "Blend") {
            FlowLayout(spacing: 6) {
                ForEach(EditV2.BlendMode.allCases, id: \.self) { m in
                    Chip(Self.label(m), on: cur == m) { session.edit { $0.setBlend(m) } }
                        .accessibilityLabel("Blend \(Self.label(m))")
                }
            }
        }
    }
}

/// The background behind the main clips (parity wave 1): a colour, or a blurred copy of the clip. It shows where a clip is
/// fitted (Frame: Fit) or moved and scaled.
struct BackgroundPanel: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession

    var body: some View {
        let cv = session.project.canvas
        let blur = cv.fill == .blur
        EditPanel(title: "Background") {
            HStack(spacing: Space.s2) {
                EditSeg(options: [(EditV2.CanvasFill.color, "Colour"), (.blur, "Blur")], selection: blur ? .blur : .color, small: true) { f in
                    session.edit { $0.setBackground(fill: f) }
                }
                .fixedSize()
                .accessibilityLabel("Background")
                if !blur {
                    SuiteSwatch(hex: cv.background ?? "#000000", label: "Background colour") { c in session.edit { $0.setBackground(fill: .color, color: c) } }
                }
                Spacer(minLength: 0)
            }
            Text("Shows where a clip doesn't fill the frame (Frame: Fit, or scaled down).")
                .font(t.scale.caption.font).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Crop (Mac Edit audit 2026-11-08: the timeline's Crop button opened the Video tab, which had no crop): each side 0–45 %.
struct CropPanel: View {
    @Bindable var session: EditSuiteSession
    var crop: EditV2.Crop?

    var body: some View {
        EditPanel(title: "Crop") {
            ForEach(EditSuiteState.CropSide.allCases, id: \.self) { side in
                SuiteSlider(side.rawValue.capitalized, value: value(side), range: 0...0.45, format: { "\(Int(($0 * 100).rounded()))%" }) { v in
                    session.edit { $0.setCrop(side, (v * 100).rounded() / 100) }
                }
            }
            HStack {
                SuiteToolButton(title: "Reset crop and transform", icon: "arrow-counter-clockwise", plain: true) { session.edit { $0.resetTransform() } }
                Spacer(minLength: 0)
            }
        }
    }

    private func value(_ side: EditSuiteState.CropSide) -> Double {
        switch side {
        case .left: return crop?.left ?? 0
        case .top: return crop?.top ?? 0
        case .right: return crop?.right ?? 0
        case .bottom: return crop?.bottom ?? 0
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
            VStack(alignment: .leading, spacing: Space.s1) {
                SuiteToolButton(title: ".cube import", icon: "square.and.arrow.down") { importCube() }
                Text("Same looks as the Camera bag palettes").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
            }
        }
        .task(id: session.state.selection) { session.refreshLookThumbs() }
    }

    /// The clip's suite look: picking a look above swaps it, Remove clears it, the intensity slider works on it as on any look.
    private func suiteLookCard(name: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Current look").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                Text("Suite look · \(name)").font(t.scale.caption.font).foregroundStyle(t.roles.ink).lineLimit(1)
            }
            Spacer()
            SuiteToolButton(title: "Remove", icon: "xmark") { session.applyLook(nil) }
        }
        .padding(10)
        .background(t.surface2)
        .overlay(Rectangle().strokeBorder(t.roles.ink, lineWidth: 2))
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
                .overlay(Rectangle().strokeBorder(on ? t.roles.ink : .clear, lineWidth: 2))
                Text(name).font(t.scale.caption.font).foregroundStyle(on ? t.roles.ink : t.roles.ink2).lineLimit(1)
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
            if session.state.selectedVideo != nil {
                // Parity: the clip's own picture under the playhead → exposure, contrast, saturation, white balance.
                SuiteToolButton(title: "Auto adjust", icon: "sliders-horizontal", plain: true) { Task { await session.autoAdjust() } }
                    .help("Balance this clip from its picture at the playhead")
            }
            // Colour keyframes (contract, WS8 c10e398): the ◆ keys the value at the playhead; once keyed, the slider sets it there.
            colorRow("Exposure", .exposure)
            colorRow("Contrast", .contrast)
            colorRow("Saturation", .saturation)
            colorRow("Temperature", .temperature)
            colorRow("Tint", .tint)
            SuiteSlider("Highlights", value: a.highlights ?? 0, range: -1...1, format: signed100) { v in setAdjust { $0.highlights = v } }
            SuiteSlider("Shadows", value: a.shadows ?? 0, range: -1...1, format: signed100) { v in setAdjust { $0.shadows = v } }
            // The look's effects (parity): 0 removes each.
            ForEach(EditSuite.LookEffect.allCases) { e in
                SuiteSlider(e.label, value: session.state.lookEffect(e), range: e.range, format: { e == .vignette ? signed100($0) : "\(Int(($0 * 100).rounded()))" }) { v in
                    session.edit { $0.setLookEffect(e, v) }
                }
            }
            SuiteSlider("Grain", value: visual.look?.grain?.amount ?? 0, range: 0...1, format: { "\(Int(($0 * 100).rounded()))" }) { v in
                session.edit { s in
                    s.changeVisual { vv in
                        var l = vv.look ?? EditV2.Look()
                        l.grain = v > 0.005 ? EditV2.Grain(amount: (v * 100).rounded() / 100, size: l.grain?.size) : nil
                        vv.look = l
                    }
                }
            }
            if session.state.selectedItem?.textItem == nil {
                SuiteRule()
                SuiteLabel("Curves")
                CurvesEditor(session: session)
            }
        }
    }
}

extension AdjustPanel {
    fileprivate func colorRow(_ label: String, _ prop: EditV2.KfProp) -> some View {
        let s = session.state
        let value = s.visualValue(prop) ?? 0
        let keyed = !(visual.keyframes?[prop]?.isEmpty ?? true)
        let here = s.hasKeyframe(prop)
        return HStack(alignment: .bottom, spacing: 8) {
            SuiteSlider(label, value: min(1, max(-1, value)), range: -1...1, format: signed100) { v in
                session.edit { $0.setVisualValue(prop, (v * 100).rounded() / 100) }
            }
            SuiteIconButton(systemName: here ? "diamond.fill" : "diamond",
                            label: here ? "Remove the \(label.lowercased()) keyframe at the playhead" : "Add a \(label.lowercased()) keyframe at the playhead",
                            on: keyed, size: 28) {
                if here { session.edit { $0.removeKeyframe(prop) } } else { session.edit { $0.addKeyframe(prop, value: value) } }
            }
        }
    }
}

/// The owner's model for an Edit helper (WS6's OwnerModelPill, "model picks everywhere"); members see nothing. A new pick
/// asks for the helper's price again (`kind`), since models can cost differently.
struct HelperModelPill: View {
    @Bindable var session: EditSuiteSession
    var purpose: EnginePurpose
    var kind: EditorJobKind?

    var body: some View {
        OwnerModelPill(purpose: purpose, selection: Binding(get: { session.helperModels[purpose] }, set: { m in
            session.helperModels[purpose] = m
            if let kind { Task { await session.loadEstimate(kind) } }
        }), compact: true)
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
                // Where the mask sits on the picture (Mac Edit audit: it could only be centred).
                SuiteSlider("Position X", value: (m.x ?? 0.5) - 0.5, range: -0.5...0.5, format: signed100) { v in session.edit { $0.changeMask { $0.x = 0.5 + (v * 100).rounded() / 100 } } }
                SuiteSlider("Position Y", value: (m.y ?? 0.5) - 0.5, range: -0.5...0.5, format: signed100) { v in session.edit { $0.changeMask { $0.y = 0.5 + (v * 100).rounded() / 100 } } }
                SuiteToggleRow(title: "Invert", isOn: m.invert == true) { on in setMask { $0?.invert = on ? true : nil } }
            }
            if isVideo {
                SuiteRule()
                let ck = visual.chroma
                HStack {
                    SuiteLabel("Chroma key")
                    if let ck {
                        SuiteSwatch(hex: ck.color, label: "Key colour") { c in session.edit { s in s.changeVisual { $0.chroma?.color = c } } }
                        Text(ck.color).font(t.scale.caption.font).monospacedDigit().foregroundStyle(t.roles.ink2)
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
                    SuiteSlider("Softness", value: ck.smoothness ?? 0.08, range: 0...1, format: { "\(Int(($0 * 100).rounded()))" }) { v in
                        session.edit { $0.changeChroma { $0.smoothness = (v * 100).rounded() / 100 } }
                    }
                    SuiteSlider("Spill", value: ck.spill ?? 0.5, range: 0...1, format: { "\(Int(($0 * 100).rounded()))" }) { v in
                        session.edit { $0.changeChroma { $0.spill = (v * 100).rounded() / 100 } }
                    }
                }
                if !session.matteAvailable && !session.backgroundRemoved {
                    // Not ready yet ("Coming soon"), or the owner switched paid helpers off: say so instead of offering a no-op.
                    HelperUnavailableRow(title: "Remove background", note: session.helperNote(.matte))
                } else {
                    HStack(spacing: Space.s2) {
                        SuiteToggleRow(title: "Remove background", hint: "No green screen needed", isOn: session.backgroundRemoved,
                                       busy: session.isRunning(.matte), trailingNote: session.estimateLabel(.matte)) { on in
                            Task { await session.setRemoveBackground(on) }
                        }
                        HelperModelPill(session: session, purpose: .matte, kind: .matte)
                    }
                    .task(id: session.state.selection) { await session.loadEstimate(.matte) }
                    HelperNote(text: session.helperNotes[.matte])
                    if let k = session.keepPick, k.clipId == session.state.selection {
                        KeepPicker(session: session, pick: k)
                    } else {
                        SuiteToolButton(title: "Pick what to keep", icon: "plus-circle", disabled: session.isRunning(.matte) || !session.matteAvailable, plain: true) {
                            Task { await session.startKeepPick() }
                        }
                    }
                }
            }
        }
    }
}

/// A paid helper that can't run now: its name and why, in plain words ("Coming soon", switched off by the owner).
struct HelperUnavailableRow: View {
    @Environment(\.theme) private var t
    var title: String
    var note: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(t.scale.label.font).foregroundStyle(t.roles.ink)
                Text(note ?? "Coming soon").font(t.scale.caption.font).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A helper's message at its own button (the owner switched paid helpers off, today's limit reached).
struct HelperNote: View {
    @Environment(\.theme) private var t
    var text: String?

    var body: some View {
        if let text {
            Text(text).font(t.scale.caption.font).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Remove background → "Pick what to keep": the frame under the playhead; a tap adds a point to keep (or, in "Leave out",
/// one to leave out) and a tap on a point removes it. The price shows before anything runs, and "Cut out" asks once more.
struct KeepPicker: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    var pick: EditSuite.KeepPick

    var body: some View {
        let r = t.roles
        let price = session.keepEstimate?.label
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(alignment: .top, spacing: Space.s2) {
                Text("Tap what to keep on the frame. Tap a point again to remove it.")
                    .font(t.scale.caption.font).foregroundStyle(r.ink2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !pick.points.isEmpty { SuiteToolButton(title: "Clear points", plain: true) { session.clearKeep() } }
                SuiteToolButton(title: "Cancel", plain: true) { session.cancelKeep() }
            }
            frame
            HStack(spacing: Space.s2) {
                Chip("Keep", on: !pick.leaveOut) { session.setKeepLeaveOut(false) }
                Chip("Leave out", on: pick.leaveOut) { session.setKeepLeaveOut(true) }
                Spacer(minLength: 0)
                Text(pick.summary).font(t.scale.caption.font).monospacedDigit().foregroundStyle(r.ink2)
            }
            if pick.confirming {
                // The second step: the price, then Run (the only thing here that spends).
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text("Cut out what you picked on this clip · \(price ?? "checking the price…")")
                        .font(t.scale.label.font).foregroundStyle(r.ink).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Space.s2) {
                        SuiteToolButton(title: "Run the cut-out", icon: "scissors", accent: true, disabled: price == nil || session.isRunning(.matte)) {
                            Task { await session.runKeep() }
                        }
                        SuiteToolButton(title: "Not now", plain: true) { session.keepPick?.confirming = false }
                        HelperModelPill(session: session, purpose: .track, kind: nil)
                    }
                }
            } else {
                HStack(spacing: Space.s2) {
                    SuiteToolButton(title: price.map { "Cut out · \($0)" } ?? "Cut out", icon: "scissors", accent: pick.canRun,
                                    disabled: !pick.canRun || session.isRunning(.matte)) { session.askKeep() }
                    Spacer(minLength: 0)
                }
            }
            if session.isRunning(.matte) {
                HStack(spacing: Space.s2) {
                    ProgressView().controlSize(.small)
                    Text(session.jobs[.matte]?.phase ?? "Cutting out").font(t.scale.caption.font).foregroundStyle(r.ink2)
                }
            }
        }
    }

    /// The frame, fitted, with the points on it (keep: an accent dot; leave out: an outlined x).
    @ViewBuilder private var frame: some View {
        let r = t.roles
        if let img = session.keepFrame {
            let aspect = CGFloat(img.width) / CGFloat(max(1, img.height))
            GeometryReader { geo in
                let size = geo.size
                ZStack(alignment: .topLeading) {
                    Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit).frame(width: size.width, height: size.height)
                    ForEach(Array(pick.points.enumerated()), id: \.offset) { _, p in
                        dot(p)
                            .position(x: CGFloat(p.x) * size.width, y: CGFloat(p.y) * size.height)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { at in
                    guard size.width > 0, size.height > 0 else { return }
                    session.tapKeep(x: Double(at.x / size.width), y: Double(at.y / size.height))
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 320)
            .clipShape(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous))
            // One element for accessibility: pressing it adds a point in the middle (the click-through reaches it too).
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Frame · tap what to keep")
            .accessibilityValue(pick.summary)
            .accessibilityAction { session.tapKeep(x: 0.5, y: 0.5) }
        } else {
            RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(r.field)
                .frame(height: 200)
                .overlay(ProgressView().controlSize(.small))
        }
    }

    @ViewBuilder private func dot(_ p: KeepPoint) -> some View {
        let r = t.roles
        if p.keeps {
            Circle().fill(r.accent).frame(width: 14, height: 14).overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
        } else {
            ZStack {
                Circle().fill(Color.black.opacity(0.55)).frame(width: 18, height: 18)
                Ph("x", 10).foregroundStyle(Color.white)
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
                Text("The first clip has no transition in. Select the next clip.").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
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
                                .overlay(Rectangle().strokeBorder(on ? t.roles.ink : t.roles.hairline, lineWidth: on ? 2 : 1))
                            Text(label(key)).font(t.scale.caption.font).foregroundStyle(on ? t.roles.ink : t.roles.ink2)
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
                Text("Whip pans live here, not in the AI shot").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
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
            // Keyframe aware (parity wave 1): with volume keys the slider sets the key at the playhead.
            let st = session.state
            HStack(alignment: .bottom, spacing: 8) {
                SuiteSlider("Volume", value: EditSuite.db(gain: st.volumeAtPlayhead ?? snd.volume ?? 1), range: -30...6,
                            format: { $0 == 0 ? "0 dB" : String(format: "%+.0f dB", $0) }) { v in
                    let g = v <= -29.5 ? 0 : EditSuite.gain(db: v.rounded())
                    session.edit { $0.setVolumeValue(g) }
                }
                SuiteIconButton(systemName: st.hasVolumeKeyHere ? "diamond.fill" : "diamond",
                                label: st.hasVolumeKeyHere ? "Remove the volume keyframe at the playhead" : "Add a volume keyframe at the playhead",
                                on: st.hasVolumeKeys, size: 28) {
                    if session.state.hasVolumeKeyHere { session.edit { $0.removeVolumeKey() } } else { session.edit { $0.addVolumeKey() } }
                }
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
            if !session.helperAvailable(.denoise) && !denoised {
                HelperUnavailableRow(title: "Noise reduction", note: session.helperNote(.denoise))
            } else {
                HStack(spacing: Space.s2) {
                    SuiteToggleRow(title: "Noise reduction", hint: "Removes background noise and music", isOn: denoised,
                                   busy: session.isRunning(.denoise), trailingNote: session.estimateLabel(.denoise)) { on in
                        Task { await session.setNoiseReduction(on) }
                    }
                    HelperModelPill(session: session, purpose: .denoise, kind: .denoise)
                }
                .task(id: session.state.selection) { await session.loadEstimate(.denoise) }
                HelperNote(text: session.helperNotes[.denoise])
            }
            if session.state.selectedItem?.audioClip != nil {
                SuiteToolButton(title: "Loop to the end", icon: "arrows-clockwise", plain: true) { session.edit { $0.loopToEnd() } }
                    .help("Repeat this sound until the video ends")
            }
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
            SuiteToolButton(title: "Even out volume", icon: "faders", plain: true) { Task { await session.evenVolume() } }
                .help("Spoken clips and voice-overs to the same level (music is left to ducking)")
            if music == nil {
                Text("Add music (Music in the media bin) to duck it under the voice and cut on its beats.").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
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
                    if let bpm = session.state.bpm { Text("\(Int(bpm.rounded())) BPM").font(t.scale.caption.font).foregroundStyle(t.roles.ink2) }
                }
                if session.state.bpm == nil {
                    HStack {
                        SuiteToolButton(title: session.isRunning(.beats) ? "Finding the beat…" : "Detect beats", icon: "metronome",
                                        disabled: session.isRunning(.beats)) { Task { await session.detectBeats() } }
                        Spacer()
                        Text("Free").font(t.scale.caption.font).monospacedDigit().foregroundStyle(t.roles.ink2)
                    }
                } else {
                    EditSeg(options: [(EditSuite.BeatMarks.every, "Every beat"), (.strong, "Strong beats")], selection: session.state.beatMarks) { m in
                        session.view { $0.beatMarks = m }
                    }
                }
                SuiteToggleRow(title: "Snap cuts to beats", hint: "Auto-cut on the beat", isOn: session.state.snapToBeats) { on in
                    session.view { $0.snapToBeats = on }
                }
                HStack(spacing: Space.s2) {
                    SuiteToolButton(title: "Mark a beat", icon: "metronome", plain: true) { session.edit { $0.markBeat() } }
                        .help("A beat mark at the playhead on the music")
                    SuiteToolButton(title: "Clear beats", icon: "x", disabled: session.state.bpm == nil && session.state.beats.isEmpty, plain: true) {
                        session.edit { $0.clearBeats() }
                    }
                }
                SuiteToolButton(title: "Cut clips to the beat", icon: "scissors", disabled: session.state.beats.isEmpty) {
                    var n = 0
                    session.edit { s in n = s.cutToBeats(); return n > 0 }
                    if n > 0 { session.notice = "\(n) clip\(n == 1 ? "" : "s") now end on the beat" }
                }
                .help("Each clip ends on the beat nearest its end")
            }
        }
    }
}

// MARK: - Speed

struct SpeedPanel: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession

    var body: some View {
        if let c = session.state.selectedVideo, let hold = c.holdSec {
            // Parity wave 1: a freeze frame has a length, not a speed.
            EditPanel(title: "Freeze frame") {
                SuiteSlider("Length", value: hold, range: EditV2.holdMinSec...10, format: { String(format: "%.1f s", $0) }) { v in
                    session.edit { $0.setHoldDuration((v * 10).rounded() / 10) }
                }
                Text("Holds this frame, silent. Drag its edges on the timeline to change the length.")
                    .font(t.scale.caption.font).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            }
        } else if let c = session.state.selectedVideo {
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
                    let srcLen = c.outSec - c.inSec
                    SuiteSlider("Length", value: EditV2.clipLength(c), range: max(0.1, srcLen / 10)...max(0.2, srcLen * 10), format: { String(format: "%.1f s", $0) }) { v in
                        session.edit { $0.setClipLength((v * 10).rounded() / 10) }
                    }
                    FlowLayout(spacing: 6) {
                        ForEach([0.25, 0.5, 1, 1.5, 2, 4], id: \.self) { sp in
                            Chip(String(format: "%g×", sp), on: abs(c.speed - sp) < 0.001) { session.edit { $0.setSpeed(sp) } }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.state.speedSummary ?? "").font(t.scale.caption.font).foregroundStyle(t.roles.ink)
                    Text("Keeps the pitch. Drag points; double-click to add one.").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                        .fixedSize(horizontal: false, vertical: true)
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
                        .stroke(t.roles.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    Text(s == 1 ? "1×" : s == 10 ? "10×" : "0.1×").font(t.scale.micro.font).monospacedDigit().foregroundStyle(t.roles.ink2)
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
        .overlay(Rectangle().strokeBorder(t.roles.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Speed curve")
    }
}

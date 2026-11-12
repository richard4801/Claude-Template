import AppKit
import SwiftUI
import MuseCore

// Edit → Layers (plans/layers-edit.md, Phase 1): find up to five things in a main clip with one paid run, then give each
// its own colour, look, blur and opacity, hide it, put text behind it, or swap the background. Free and live after the run.

/// The Layers panel of a selected main clip.
struct LayersPanel: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    var clip: EditV2.VideoClip

    var body: some View {
        let layers = clip.layers ?? []
        EditPanel(title: "Layers", trailing: layers.isEmpty ? nil : "\(layers.count)") {
            if let k = session.layersPick, k.clipId == clip.id {
                LayersPicker(session: session, pick: k)
            } else if layers.isEmpty {
                if session.features?.isAvailable(.layers) == false {
                    HelperUnavailableRow(title: "Find layers", note: session.helperNote(.layers))
                } else {
                    Text("Mark people and things in this clip. Each becomes a layer you can recolour, blur or hide, or put text behind.")
                        .font(t.scale.caption.font).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                    SuiteToolButton(title: "Find layers", icon: "stack", disabled: session.isRunning(.layers)) { Task { await session.startLayersPick() } }
                    HelperNote(text: session.helperNotes[.layers])
                }
            } else {
                list(layers)
                if let id = session.layerSelection, let l = layers.first(where: { $0.id == id }) {
                    LayerControls(session: session, layer: l)
                } else {
                    BackgroundControls(session: session, clip: clip)
                }
                HStack(spacing: Space.s2) {
                    SuiteToolButton(title: "Find layers again", disabled: session.isRunning(.layers), plain: true) { Task { await session.startLayersPick() } }
                    Spacer(minLength: 0)
                    SuiteToolButton(title: "Remove layers", plain: true) { session.removeLayers() }
                }
            }
        }
    }

    /// Background, then each layer: an eye to hide it, its name (selects it).
    private func list(_ layers: [EditV2.ClipLayer]) -> some View {
        VStack(spacing: 2) {
            row(name: "Background", selected: session.layerSelection == nil, hidden: clip.layerBase?.hidden == true,
                toggle: { session.changeLayerBase { $0.hidden = $0.hidden == true ? nil : true } }, select: { session.layerSelection = nil })
            ForEach(layers) { l in
                row(name: l.name, selected: session.layerSelection == l.id, hidden: l.hidden == true, behind: l.aboveText == true,
                    toggle: { session.changeLayer(l.id) { $0.hidden = $0.hidden == true ? nil : true } }, select: { session.layerSelection = l.id })
            }
        }
    }

    private func row(name: String, selected: Bool, hidden: Bool, behind: Bool = false, toggle: @escaping () -> Void, select: @escaping () -> Void) -> some View {
        let r = t.roles
        return HStack(spacing: Space.s2) {
            Button(action: toggle) { Ph(hidden ? "eye-slash" : "eye", 16).foregroundStyle(hidden ? r.ink2 : r.ink).frame(width: 28, height: 28) }
                .buttonStyle(.plain)
                .help(hidden ? "Show \(name)" : "Hide \(name)")
                .accessibilityLabel(hidden ? "Show \(name)" : "Hide \(name)")
            Button(action: select) {
                HStack {
                    Text(name).font(t.scale.label.font).foregroundStyle(hidden ? r.ink2 : r.ink).lineLimit(1)
                    Spacer(minLength: 4)
                    if behind { Text("Text behind").font(t.scale.caption.font).foregroundStyle(r.ink2) }
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
        .padding(.horizontal, Space.s2)
        .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(selected ? r.field : .clear))
        .overlay(alignment: .leading) { if selected { Rectangle().fill(r.accent).frame(width: 2).padding(.vertical, 6) } }
    }
}

/// One layer's own look: colour wash, look, light, blur, opacity, edge, and text behind it.
struct LayerControls: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    var layer: EditV2.ClipLayer
    static let swatches = ["#1B2A6B", "#B5121B", "#2F6B3A", "#F2A93B", "#6B3FA0", "#111111", "#F5F1E8", "#C97B5A"]

    private func set(_ f: @escaping (inout EditV2.ClipLayer) -> Void) { session.changeLayer(layer.id, f) }
    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))" }

    var body: some View {
        let r = t.roles
        VStack(alignment: .leading, spacing: Space.s3) {
            SuiteLabel("Colour")
            FlowLayout(spacing: 6) {
                Chip("None", on: layer.recolor == nil) { set { $0.recolor = nil } }
                ForEach(Self.swatches, id: \.self) { hex in
                    let on = layer.recolor?.color == hex
                    Button { set { $0.recolor = EditV2.Recolor(color: hex, amount: $0.recolor?.amount ?? 0.8) } } label: {
                        Circle().fill(swatchColor(hex)).frame(width: 24, height: 24)
                            .overlay(Circle().strokeBorder(on ? r.accent : r.hairline, lineWidth: on ? 2 : 1))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help(hex)
                    .accessibilityLabel("Colour \(hex)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                SuiteSwatch(hex: layer.recolor?.color ?? "#808080", label: "Any colour") { hex in
                    set { $0.recolor = EditV2.Recolor(color: hex, amount: $0.recolor?.amount ?? 0.8) }
                }
            }
            if let rc = layer.recolor {
                SuiteSlider("Colour amount", value: rc.amount, range: 0...1, format: pct) { v in set { $0.recolor?.amount = (v * 100).rounded() / 100 } }
            }
            Menu {
                Button("Same as the clip") { set { $0.look = nil } }
                ForEach(EditV2LookLibrary.shared.pack?.looks ?? []) { e in Button(e.name) { set { $0.look = e.look } } }
            } label: {
                Text(lookName).font(t.scale.label.font).foregroundStyle(r.ink)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("A look for this layer only")
            SuiteSlider("Brightness", value: layer.adjust?.exposure ?? 0, range: -1...1, format: pct) { v in set { $0.adjust = adjusted($0.adjust) { $0.exposure = round2(v) } } }
            SuiteSlider("Saturation", value: layer.adjust?.saturation ?? 0, range: -1...1, format: pct) { v in set { $0.adjust = adjusted($0.adjust) { $0.saturation = round2(v) } } }
            SuiteSlider("Blur", value: layer.blur ?? 0, range: 0...1, format: pct) { v in set { $0.blur = v < 0.005 ? nil : round2(v) } }
            SuiteSlider("Opacity", value: layer.opacity ?? 1, range: 0...1, format: pct) { v in set { $0.opacity = v > 0.995 ? nil : round2(v) } }
            SuiteSlider("Soft edge", value: layer.feather ?? 0, range: 0...1, format: pct) { v in set { $0.feather = v < 0.005 ? nil : round2(v) } }
            SuiteToggleRow(title: "Text behind \(layer.name)", hint: "Titles and captions go behind this layer", isOn: layer.aboveText == true) { on in
                set { $0.aboveText = on ? true : nil }
            }
        }
    }

    private var lookName: String {
        guard let lut = layer.look?.lut, lut.hasPrefix("pack:") else { return layer.look == nil ? "Look: same as the clip" : "Look: own" }
        let id = String(lut.dropFirst(5))
        return "Look: " + (EditV2LookLibrary.shared.pack?.looks.first { $0.id == id }?.name ?? id)
    }
}

/// The Background row: hide it, blur it, darken it, or show another picture behind the layers.
struct BackgroundControls: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    var clip: EditV2.VideoClip

    var body: some View {
        let b = clip.layerBase
        let pictures = session.project.assets.filter { a in (a.kind == .image || a.kind == .video) && a.id != clip.asset && !(clip.layers ?? []).contains(where: { l in l.matte == a.id }) }
        VStack(alignment: .leading, spacing: Space.s3) {
            SuiteSlider("Blur", value: b?.blur ?? 0, range: 0...1, format: { "\(Int(($0 * 100).rounded()))" }) { v in
                session.changeLayerBase { $0.blur = v < 0.005 ? nil : round2(v) }
            }
            SuiteSlider("Brightness", value: b?.adjust?.exposure ?? 0, range: -1...1, format: { "\(Int(($0 * 100).rounded()))" }) { v in
                session.changeLayerBase { $0.adjust = adjusted($0.adjust) { $0.exposure = round2(v) } }
            }
            SuiteSlider("Saturation", value: b?.adjust?.saturation ?? 0, range: -1...1, format: { "\(Int(($0 * 100).rounded()))" }) { v in
                session.changeLayerBase { $0.adjust = adjusted($0.adjust) { $0.saturation = round2(v) } }
            }
            HStack(spacing: Space.s2) {
                Menu {
                    Button("The clip itself") { session.changeLayerBase { $0.asset = nil } }
                    ForEach(pictures) { a in Button(session.state.assetNames[a.id] ?? (a.kind == .image ? "Picture" : "Video")) { session.changeLayerBase { $0.asset = a.id } } }
                } label: {
                    Text(b?.asset == nil ? "Behind: the clip itself" : "Behind: \(session.state.assetNames[b!.asset!] ?? "another picture")")
                        .font(t.scale.label.font).foregroundStyle(t.roles.ink)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(pictures.isEmpty)
                .help(pictures.isEmpty ? "Add a photo or video to this edit first" : "Show another photo or video behind the layers")
                Spacer(minLength: 0)
            }
        }
    }
}

private func swatchColor(_ hex: String) -> Color { Color(hex: UInt32(hex.dropFirst(), radix: 16) ?? 0) }
private func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
private func adjusted(_ a: EditV2.Adjust?, _ f: (inout EditV2.Adjust) -> Void) -> EditV2.Adjust? {
    var x = a ?? EditV2.Adjust()
    f(&x)
    return x == EditV2.Adjust() ? nil : x
}

/// Find layers: the frame under the playhead; each thing gets a name and taps (⌥ or "Leave out" for what isn't it) or a
/// box (drag). The price is on the button; above $1 a clip it asks once more.
struct LayersPicker: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    var pick: EditSuite.LayersPick
    @State private var drag: (CGPoint, CGPoint)?

    var body: some View {
        let r = t.roles
        let price = session.layersEstimate?.label
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(alignment: .top, spacing: Space.s2) {
                Text("Click a thing to mark it, or drag a box round it. Click a point again to remove it.")
                    .font(t.scale.caption.font).foregroundStyle(r.ink2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                SuiteToolButton(title: "Cancel", plain: true) { session.cancelLayersPick() }
            }
            ForEach(Array(pick.objects.enumerated()), id: \.offset) { i, o in
                HStack(spacing: Space.s2) {
                    Button { session.changeLayersPick { $0.current = i; return true } } label: {
                        Circle().fill(i == pick.current ? r.accent : r.ink2.opacity(0.5)).frame(width: 10, height: 10).frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("Mark \(o.name)")
                    .accessibilityLabel("Mark \(o.name)")
                    .accessibilityAddTraits(i == pick.current ? .isSelected : [])
                    TextField("Name", text: Binding(get: { o.name }, set: { v in session.changeLayersPick { $0.rename(i, v); return true } }))
                        .textFieldStyle(.roundedBorder)
                        .font(t.scale.label.font)
                    Text(o.box != nil ? "Box" : o.points.isEmpty ? "Not marked" : "\(o.points.count) \(o.points.count == 1 ? "point" : "points")")
                        .font(t.scale.caption.font).monospacedDigit().foregroundStyle(r.ink2).frame(minWidth: 64, alignment: .trailing)
                    if pick.objects.count > 1 {
                        SuiteToolButton(title: "Remove \(o.name)", icon: "x", plain: true, iconOnly: true) { session.changeLayersPick { $0.remove(i); return true } }
                    }
                }
            }
            HStack(spacing: Space.s2) {
                if pick.canAdd { SuiteToolButton(title: "Add a thing", icon: "plus", plain: true) { session.changeLayersPick { $0.add() } } }
                Spacer(minLength: 0)
                Chip("Keep", on: !pick.leaveOut) { session.layersPick?.leaveOut = false }
                Chip("Leave out", on: pick.leaveOut) { session.layersPick?.leaveOut = true }
            }
            frame
            if pick.confirming, let p = session.layersEstimate {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text("Finding these layers costs \(p.label), more than $1 for one clip. Go ahead?")
                        .font(t.scale.label.font).foregroundStyle(r.ink).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Space.s2) {
                        SuiteToolButton(title: "Find layers · \(p.label)", icon: "stack", accent: true, disabled: session.isRunning(.layers)) { Task { await session.findLayers() } }
                        SuiteToolButton(title: "Not now", plain: true) { session.layersPick?.confirming = false }
                    }
                }
            } else {
                SuiteToolButton(title: price.map { "Find layers · \($0)" } ?? "Find layers", icon: "stack", accent: pick.canRun,
                                disabled: !pick.canRun || session.isRunning(.layers)) { Task { await session.findLayers() } }
            }
            HelperNote(text: session.helperNotes[.layers])
            if session.isRunning(.layers) {
                HStack(spacing: Space.s2) {
                    ProgressView().controlSize(.small)
                    Text(session.jobs[.layers]?.phase ?? "Finding layers").font(t.scale.caption.font).foregroundStyle(r.ink2)
                    Spacer(minLength: 0)
                    SuiteToolButton(title: "Stop", plain: true) { session.cancelJob(.layers) }
                }
            }
        }
    }

    @ViewBuilder private var frame: some View {
        let r = t.roles
        if let img = session.layersFrame {
            let aspect = CGFloat(img.width) / CGFloat(max(1, img.height))
            GeometryReader { geo in
                let size = geo.size
                ZStack(alignment: .topLeading) {
                    Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit).frame(width: size.width, height: size.height)
                    ForEach(Array(pick.objects.enumerated()), id: \.offset) { i, o in
                        let col = i == pick.current ? r.accent : Color.white.opacity(0.8)
                        if let b = o.box {
                            Rectangle().strokeBorder(col, lineWidth: 2)
                                .frame(width: CGFloat(b.w) * size.width, height: CGFloat(b.h) * size.height)
                                .position(x: CGFloat(b.x + b.w / 2) * size.width, y: CGFloat(b.y + b.h / 2) * size.height)
                        }
                        ForEach(Array(o.points.enumerated()), id: \.offset) { _, p in
                            Group {
                                if p.keeps { Circle().fill(col).frame(width: 12, height: 12).overlay(Circle().strokeBorder(Color.black.opacity(0.5), lineWidth: 1)) }
                                else { ZStack { Circle().fill(Color.black.opacity(0.55)).frame(width: 16, height: 16); Ph("x", 9).foregroundStyle(col) } }
                            }
                            .position(x: CGFloat(p.x) * size.width, y: CGFloat(p.y) * size.height)
                        }
                    }
                    .allowsHitTesting(false)
                    if let d = drag {
                        Rectangle().strokeBorder(r.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .frame(width: abs(d.1.x - d.0.x), height: abs(d.1.y - d.0.y))
                            .position(x: (d.0.x + d.1.x) / 2, y: (d.0.y + d.1.y) / 2)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { g in drag = (g.startLocation, g.location) }
                    .onEnded { g in
                        drag = nil
                        guard size.width > 0, size.height > 0 else { return }
                        let a = g.startLocation, b = g.location
                        let alt = NSEvent.modifierFlags.contains(.option)
                        if hypot(b.x - a.x, b.y - a.y) < 6 {
                            session.changeLayersPick { k in
                                let was = k.leaveOut
                                if alt { k.leaveOut = true }
                                let ok = k.tap(x: Double(a.x / size.width), y: Double(a.y / size.height), aspect: Double(aspect))
                                k.leaveOut = was
                                return ok
                            }
                        } else {
                            session.changeLayersPick { $0.box(Double(a.x / size.width), Double(a.y / size.height), Double(b.x / size.width), Double(b.y / size.height)) }
                        }
                    })
            }
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 360)
            .clipShape(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous))
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Frame · mark \(pick.objects.indices.contains(pick.current) ? pick.objects[pick.current].name : "a thing")")
            .accessibilityValue(pick.summary)
            .accessibilityAction { session.changeLayersPick { $0.tap(x: 0.5, y: 0.5) } }
        } else {
            RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(r.field)
                .frame(height: 220)
                .overlay(ProgressView().controlSize(.small))
        }
    }
}

/// Pin a text to a layer (text inspector): its centre follows the layer around.
struct PinTextRow: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    var text: EditV2.TextItem

    var body: some View {
        let targets = session.pinTargets
        if !targets.isEmpty {
            EditPanel(title: "Pin to a layer") {
                HStack(spacing: Space.s2) {
                    Menu {
                        Button("Not pinned") { session.pinSelectedText(nil) }
                        ForEach(Array(targets.enumerated()), id: \.offset) { _, x in
                            Button(targets.filter { $0.layer.name == x.layer.name }.count > 1 ? "\(x.layer.name) (\(x.clip.id))" : x.layer.name) {
                                session.pinSelectedText(EditV2.TextPin(clip: x.clip.id, layer: x.layer.id, anchor: text.pin?.anchor ?? .top, offset: EditV2.PinOffset(x: 0, y: -0.04)))
                            }
                        }
                    } label: {
                        Text(text.pin.flatMap { p in targets.first { $0.clip.id == p.clip && $0.layer.id == p.layer }?.layer.name }.map { "Follows \($0)" } ?? "Not pinned")
                            .font(t.scale.label.font).foregroundStyle(t.roles.ink)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Spacer(minLength: 0)
                }
                if let p = text.pin {
                    HStack(spacing: 6) {
                        ForEach(EditV2.PinAnchor.allCases, id: \.self) { a in
                            Chip(a == .center ? "Middle" : a == .top ? "Top" : "Bottom", on: p.anchor == a) {
                                var q = p; q.anchor = a; session.pinSelectedText(q)
                            }
                        }
                    }
                }
            }
        }
    }
}

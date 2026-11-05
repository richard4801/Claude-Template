import MuseCore
import SwiftUI

// PAUSED 2026-11-05: the owner asked for a prompt-first composer with compact camera chips (redesign coming). This layout
// is kept as it stands and still builds; the reusable camera layer is MuseCore/Suite/CameraPickers.swift.

// AI suite (workstream 1): the camera bag (D3/D3d rig, D4 light & look, D5 move & angle). Always in the dark theme
// (decision 3) whatever the app theme. Every option and render comes from the catalog; camera choices are free.

extension SuiteState {
    func rig(_ f: (inout CameraRig) -> Void) { var r = bagDraft.rig ?? CameraRig(); f(&r); bagDraft.rig = r; bagDraft.preset = nil }
    func light(_ f: (inout CameraLighting) -> Void) { var r = bagDraft.lighting ?? CameraLighting(); f(&r); bagDraft.lighting = r; bagDraft.preset = nil }
    func angle(_ f: (inout CameraAngle) -> Void) { var r = bagDraft.angle ?? CameraAngle(); f(&r); bagDraft.angle = r }
    func style(_ f: (inout CameraStyle) -> Void) { var r = bagDraft.style ?? CameraStyle(); f(&r); bagDraft.style = r }
}

struct CameraBagView: View {
    @Environment(AppStore.self) private var store
    private let dark = Theme.get(.b)

    var body: some View {
        CameraBagContent()
            .environment(\.theme, dark)
            .foregroundStyle(dark.ink)
            .font(dark.body(14))
            .tint(dark.accent)
            .background(dark.bg)
            .environment(\.colorScheme, .dark)
    }
}

private struct CameraBagContent: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var rigName = ""
    @State private var naming = false

    var body: some View {
        let s = store.suite
        VStack(spacing: 0) {
            header
            if !s.bagDirected { tabs }
            Rectangle().fill(t.line).frame(height: 1)
            Group {
                if s.bagDirected {
                    DirectedModePanel(shotTitle: shotTitle) { store.applyDirected($0) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        switch s.bagTab {
                        case .rig: RigTab()
                        case .light: LightTab()
                        case .move: MoveTab()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(t.line).frame(height: 1)
            footer
        }
    }

    static let tabList: [(BagTab, String)] = [(.rig, "Rig"), (.light, "Light & look"), (.move, "Move & angle")]

    private var shotTitle: String { store.suite.bagTarget == .shot ? store.suite.shot.title : store.suite.board.title }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SHOT · \(shotTitle.uppercased()) · CAMERA").font(t.mono(11)).tracking(1.6).foregroundStyle(t.muted)
                Text("CAMERA").font(t.display(40)).tracking(1)
            }
            Spacer()
            SuiteSeg(options: [(false, "Preset"), (true, "Directed · Blender")], selection: store.suite.bagDirected) { store.suite.bagDirected = $0 }
                .frame(width: 260)
                .disabled(store.suite.bagTarget == .storyboard)
            Spacer()
            MButton("Cancel", size: .regular) { store.closeBag(apply: false) }
                .keyboardShortcut(.cancelAction)
            MButton(store.suite.bagTarget == .shot ? "Apply to shot" : "Apply to storyboard", kind: .primary, size: .regular) { store.closeBag(apply: true) }
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private var tabs: some View {
        HStack(spacing: 22) {
            ForEach(Self.tabList.indices, id: \.self) { i in
                let (tab, label) = Self.tabList[i]
                let on = store.suite.bagTab == tab
                Button { store.suite.bagTab = tab } label: {
                    Text(label).font(t.body(14, on ? .semibold : .regular)).foregroundStyle(on ? t.ink : t.muted)
                        .padding(.bottom, 8)
                        .overlay(alignment: .bottom) { Rectangle().fill(on ? t.accent : .clear).frame(height: 2) }
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("START FROM").font(t.mono(10.5)).tracking(1.2).foregroundStyle(t.muted)
            Chip("Auto", on: store.suite.bagDraft == CameraSpec()) { store.startBag(from: nil) }
            ForEach(store.suite.camera.presets.prefix(5)) { p in
                Chip(p.label, on: store.suite.bagDraft.preset == p.id) { store.startBag(from: p) }.help(p.description)
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 4)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text("YOUR CAMERA").font(t.mono(10.5)).tracking(1.2).foregroundStyle(t.muted)
            Text(CameraSummary.line(store.suite.bagDraft, store.suite.camera)).font(t.mono(12)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if let note = store.suite.bagNote { Text(note).font(t.body(12)).foregroundStyle(t.warn).lineLimit(1) }
            Text("Camera choices are free").font(t.body(12)).foregroundStyle(t.muted).fixedSize()
            MButton("Save as rig…", size: .small) { naming = true }
                .popover(isPresented: $naming) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Name this rig").font(t.body(13, .semibold))
                        TextField("Night street", text: $rigName).textFieldStyle(.roundedBorder).frame(width: 220)
                            .onSubmit { store.saveRig(rigName); naming = false }
                        MButton("Save", kind: .primary, size: .small) { store.saveRig(rigName); naming = false }
                    }
                    .padding(14)
                }
        }
        .padding(.horizontal, 28)
        .frame(height: 56)
    }
}

/// A horizontal row of hardware cards; the one in the bag is ringed and tagged.
private struct BagCarousel: View {
    @Environment(\.theme) private var t
    var title: String
    var options: [SuiteOption]
    var selected: String?
    var size: CGFloat = 132
    var onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(title.uppercased()) · \(options.count)").font(t.mono(11, .medium)).tracking(1.4)
                Spacer()
                Text("Scroll or ← → to browse · click to put in the bag").font(t.body(11.5)).foregroundStyle(t.muted)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(options) { o in card(o) }
                }
                .padding(2)
            }
        }
    }

    private func card(_ o: SuiteOption) -> some View {
        let on = o.id == selected
        return Button { onPick(o.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HardwareImage(name: o.render)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? t.accent : .clear, lineWidth: 2))
                    .overlay(alignment: .topLeading) {
                        if on {
                            Label("IN BAG", systemImage: "checkmark").font(t.mono(9.5, .semibold)).foregroundStyle(t.accentInk)
                                .padding(.horizontal, 6).frame(height: 18).background(Capsule().fill(t.accent)).padding(6)
                        }
                    }
                Text(o.title).font(t.body(13, .semibold)).lineLimit(1)
                Text(o.caption ?? o.description).font(t.mono(10)).foregroundStyle(t.muted).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: size, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(o.title)\(on ? ", in the bag" : "")")
    }
}

/// Small rounded chips for the dark bag.
private struct BagChips: View {
    @Environment(\.theme) private var t
    var options: [(String, String)]
    var selected: String?
    var onPick: (String) -> Void
    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(options.indices, id: \.self) { i in
                let (id, label) = options[i]
                let on = id == selected
                Button { onPick(id) } label: {
                    Text(label).font(t.mono(11)).foregroundStyle(on ? t.accentInk : t.ink)
                        .padding(.horizontal, 9).frame(height: 26)
                        .background(Capsule().fill(on ? t.accent : t.surface2))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct BagCard<Content: View>: View {
    @Environment(\.theme) private var t
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(t.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(t.line, lineWidth: 1))
    }
}

// MARK: Rig (D3)

private struct RigTab: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let s = store.suite
        let c = s.camera
        let rig = s.bagDraft.rig ?? CameraRig()
        let cam = c.bodies.first { $0.id == rig.body }
        let lens = c.lenses.first { $0.id == rig.lens }
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    HardwareImage(name: cam?.render ?? c.bodies.first?.render).frame(width: 300, height: 230).clipShape(RoundedRectangle(cornerRadius: 12))
                    if let l = lens?.render {
                        HardwareImage(name: l).frame(width: 150, height: 130).clipShape(RoundedRectangle(cornerRadius: 10)).padding(-1)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    Text("RIG · \((s.bagDraft.preset.flatMap { id in c.presets.first { $0.id == id }?.label } ?? "Custom").uppercased())").font(t.mono(10.5)).tracking(1.2).padding(10)
                }
                VStack(spacing: 0) {
                    specRow("Body", cam?.title ?? "Auto")
                    specRow("Sensor", cam?.caption?.components(separatedBy: " · ").dropFirst().joined(separator: " · ").suiteDash ?? "—")
                    specRow("Lens", [lens?.title, rig.focalMm.map { "\(Int($0)) mm" }].compactMap { $0 }.joined(separator: " · ").suiteDash)
                    specRow("Aperture", rig.aperture.flatMap { a in c.apertures.first { $0.id == a }?.label } ?? "Auto")
                    specRow("Shutter / fps", [rig.shutter.flatMap { x in c.shutters.first { $0.id == x }?.label }, rig.fps.flatMap { x in c.frameRates.first { $0.id == x }?.label }].compactMap { $0 }.joined(separator: " · ").suiteDash)
                    specRow("Stock", rig.look.flatMap { x in c.looks.first { $0.id == x }?.title } ?? "Auto")
                }
                if cam != nil || lens != nil {
                    Text("Feels like: \([cam?.description, lens?.description].compactMap { $0 }.joined(separator: ". ")).").font(t.body(12)).foregroundStyle(t.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 300)
            VStack(alignment: .leading, spacing: 22) {
                BagCarousel(title: "Camera bodies", options: c.bodies, selected: rig.body) { id in s.rig { $0.body = id } }
                BagCarousel(title: "Lenses", options: c.lenses, selected: rig.lens) { id in s.rig { $0.lens = id } }
                HStack(alignment: .top, spacing: 12) {
                    focalCard(rig, c)
                    BagCard {
                        HStack(alignment: .top, spacing: 10) {
                            HardwareImage(name: c.optic("aperture")?.render).frame(width: 64, height: 64).clipShape(Circle())
                            VStack(alignment: .leading, spacing: 6) {
                                Text("APERTURE · DEPTH").font(t.mono(10.5)).tracking(1.2)
                                Text(c.optic("aperture")?.caption ?? "").font(t.body(11)).foregroundStyle(t.muted)
                            }
                        }
                        BagChips(options: c.apertures.map { ($0.id, $0.label.components(separatedBy: " · ").first ?? $0.label) }, selected: rig.aperture) { id in s.rig { $0.aperture = id } }
                    }
                    BagCard {
                        HStack(alignment: .top, spacing: 10) {
                            HardwareImage(name: c.optic("shutter")?.render).frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 6) {
                                Text("SHUTTER · FPS").font(t.mono(10.5)).tracking(1.2)
                                Text(c.optic("shutter")?.caption ?? "").font(t.body(11)).foregroundStyle(t.muted)
                            }
                        }
                        BagChips(options: c.shutters.map { ($0.id, $0.label) }, selected: rig.shutter) { id in s.rig { $0.shutter = id } }
                        BagChips(options: c.frameRates.map { ($0.id, $0.label.components(separatedBy: " · ").first ?? $0.label) }, selected: rig.fps) { id in s.rig { $0.fps = id } }
                    }
                }
            }
        }
        .padding(28)
    }

    private func specRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k.uppercased()).font(t.mono(10.5)).tracking(1.2).foregroundStyle(t.muted)
            Spacer()
            Text(v).font(t.mono(12)).lineLimit(1)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(t.line).frame(height: 1) }
    }

    private func focalCard(_ rig: CameraRig, _ c: CameraCatalog) -> some View {
        let s = store.suite
        let stops = c.focalLengths.isEmpty ? [14, 24, 35, 50, 85, 135] : c.focalLengths
        let idx = Binding<Double>(get: {
            let f = rig.focalMm ?? 35
            return Double(stops.enumerated().min { abs($0.element - f) < abs($1.element - f) }?.offset ?? 0)
        }, set: { v in
            let i = max(0, min(stops.count - 1, Int(v.rounded())))
            s.rig { $0.focalMm = stops[i] }
        })
        return BagCard {
            HStack(alignment: .firstTextBaseline) {
                Text("FOCAL LENGTH").font(t.mono(10.5)).tracking(1.2)
                Spacer()
                Text(rig.focalMm.map { "\(Int($0)) mm" } ?? "Auto").font(t.display(26))
            }
            Slider(value: idx, in: 0...Double(max(1, stops.count - 1)), step: 1)
                .accessibilityLabel("Focal length")
            Text(stops.map { "\(Int($0))" }.joined(separator: " · ")).font(t.mono(10)).foregroundStyle(t.muted).lineLimit(2)
        }
    }
}

private extension String {
    var suiteDash: String { isEmpty ? "—" : self }
}

// MARK: Light & look (D4)

private struct LightTab: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let s = store.suite
        let c = s.camera
        let d = s.bagDraft
        let palette = c.palettes.first { $0.id == d.palette?.preset }
        let lightOpt = c.lighting.first { $0.id == d.lighting?.preset }
        let look = c.looks.first { $0.id == d.rig?.look }
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text("LOOK PREVIEW").font(t.mono(10.5)).tracking(1.2)
                HardwareImage(name: palette?.render ?? lightOpt?.render ?? c.palettes.first?.render).frame(width: 300, height: 380).clipShape(RoundedRectangle(cornerRadius: 12))
                FlowLayout(spacing: 6) {
                    ForEach([lightOpt?.title, palette?.title, look?.title].compactMap { $0 }, id: \.self) { x in
                        Text(x.uppercased()).font(t.mono(10)).padding(.horizontal, 8).frame(height: 22).background(Capsule().fill(t.surface2))
                    }
                }
            }
            .frame(width: 300)
            VStack(alignment: .leading, spacing: 22) {
                BagCarousel(title: "Lighting", options: c.lighting, selected: d.lighting?.preset, size: 150) { id in s.light { $0.preset = id } }
                BagCarousel(title: "Colour palette", options: c.palettes, selected: d.palette?.preset, size: 150) { id in
                    s.bagDraft.palette = CameraPalette(preset: id)
                    s.bagDraft.preset = nil
                }
                HStack(alignment: .top, spacing: 16) {
                    BagCarousel(title: "Film & sensor", options: c.looks, selected: d.rig?.look, size: 110) { id in s.rig { $0.look = id } }
                        .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("ERA").font(t.mono(10.5)).tracking(1.2)
                        BagChips(options: c.eras.map { ($0.id, $0.label) }, selected: d.style?.era) { id in s.style { $0.era = $0.era == id ? nil : id } }
                        Text("LIGHT TWEAKS").font(t.mono(10.5)).tracking(1.2).padding(.top, 6)
                        HStack {
                            Text("COLOUR TEMP").font(t.mono(10)).foregroundStyle(t.muted)
                            Spacer()
                            Text(d.lighting?.temperatureK.map { "\(Int($0)) K" } ?? "Auto").font(t.mono(11))
                        }
                        Slider(value: Binding(get: { d.lighting?.temperatureK ?? 5600 }, set: { v in s.light { $0.temperatureK = (v / 100).rounded() * 100 } }), in: 1800...12000)
                            .accessibilityLabel("Colour temperature")
                        HStack {
                            Text("INTENSITY").font(t.mono(10)).foregroundStyle(t.muted)
                            Spacer()
                        }
                        BagChips(options: [("low", "Low"), ("normal", "Normal"), ("high", "High")], selected: d.lighting?.intensity) { id in s.light { $0.intensity = id } }
                        Text("DIRECTION").font(t.mono(10)).foregroundStyle(t.muted)
                        BagChips(options: ["front", "left", "right", "back", "top", "below"].map { ($0, $0.capitalized) }, selected: d.lighting?.direction) { id in s.light { $0.direction = id } }
                    }
                    .frame(width: 300)
                }
            }
        }
        .padding(28)
    }
}

// MARK: Move & angle (D5)

private struct MoveTab: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let s = store.suite
        let c = s.camera
        let d = s.bagDraft
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    ForEach(SuiteMoves.tags.indices, id: \.self) { i in
                        let tag = SuiteMoves.tags[i]
                        Chip(tag.id == nil ? "All \(SuiteMoves.library(c, tag: nil).count)" : tag.label, on: s.moveTag == tag.id) { s.moveTag = tag.id }
                    }
                    Spacer()
                    Text("MIX · \(SuiteMoves.mixCount(move: d.move, mix: d.mix)) OF 2").font(t.mono(11, .semibold)).foregroundStyle(t.rec)
                        .padding(.horizontal, 8).frame(height: 24).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(t.rec, lineWidth: 1))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 12)], spacing: 12) {
                    ForEach(SuiteMoves.library(c, tag: s.moveTag)) { m in moveCard(m, c, d) }
                }
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 16) {
                if let m = d.move { moveControls(1, m, c) { s.bagDraft.move = $0 } }
                if let m = d.mix { moveControls(2, m, c) { s.bagDraft.mix = $0 } }
                if d.move != nil && d.mix != nil {
                    MButton("Swap order", icon: "arrow.up.arrow.down", size: .small) { let a = s.bagDraft.move; s.bagDraft.move = s.bagDraft.mix; s.bagDraft.mix = a }
                }
                if d.move == nil { Text("Pick up to two moves from the library.").font(t.body(12.5)).foregroundStyle(t.muted) }
                Text("CAMERA HEIGHT").font(t.mono(10.5)).tracking(1.2)
                BagChips(options: c.heights.map { ($0.id, $0.label) }, selected: d.angle?.height) { id in s.angle { $0.height = id } }
                Text("FRAMING").font(t.mono(10.5)).tracking(1.2)
                BagChips(options: c.shotSizes.map { ($0.id, $0.label) }, selected: d.angle?.shotSize) { id in s.angle { $0.shotSize = id } }
                HStack {
                    Text("DUTCH").font(t.mono(10.5)).tracking(1.2)
                    Slider(value: Binding(get: { d.angle?.dutchDeg ?? 0 }, set: { v in s.angle { $0.dutchDeg = v.rounded() } }), in: 0...max(1, c.limits.dutchDeg.last ?? 30))
                        .accessibilityLabel("Dutch angle")
                    Text("\(Int(d.angle?.dutchDeg ?? 0))°").font(t.mono(11)).frame(width: 34)
                }
            }
            .frame(width: 330)
        }
        .padding(28)
    }

    private func symbol(_ category: String) -> String {
        switch category {
        case "static": return "camera.on.rectangle"
        case "push": return "arrow.right.to.line"
        case "lateral", "follow": return "figure.walk.motion"
        case "rotate": return "arrow.triangle.2.circlepath"
        case "vertical": return "arrow.up.and.down"
        case "zoom": return "plus.magnifyingglass"
        case "aerial": return "airplane"
        default: return "video"
        }
    }

    private func moveCard(_ m: SuiteLibraryMove, _ c: CameraCatalog, _ d: CameraSpec) -> some View {
        let order = d.move?.id == m.id ? 1 : d.mix?.id == m.id ? 2 : 0
        let grip = c.grip(for: m.id)?.render
        return Button { store.toggleBagMove(m.id) } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    Group {
                        if let grip { HardwareImage(name: grip) } else {
                            Image(systemName: symbol(m.category)).font(.system(size: 30)).foregroundStyle(t.muted).frame(maxWidth: .infinity, maxHeight: .infinity).background(t.surface2)
                        }
                    }
                    .frame(height: 86).clipped()
                    if order > 0 {
                        Text("\(order)").font(t.mono(11, .semibold)).foregroundStyle(.white).frame(width: 20, height: 20).background(t.rec).padding(6)
                    }
                }
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.label).font(t.body(13, .semibold)).lineLimit(1)
                        Text(m.description).font(t.mono(9.5)).foregroundStyle(t.muted).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(m.tag.uppercased()).font(t.mono(9)).foregroundStyle(t.muted).padding(.horizontal, 4).overlay(Rectangle().strokeBorder(t.line, lineWidth: 1))
                }
                .padding(8)
            }
            .background(t.surface)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(order > 0 ? t.accent : t.line, lineWidth: order > 0 ? 2 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(m.label), \(m.tag)\(order > 0 ? ", move \(order)" : "")")
    }

    private func moveControls(_ n: Int, _ m: SuiteMove, _ c: CameraCatalog, set: @escaping (SuiteMove) -> Void) -> some View {
        BagCard {
            HStack {
                Text("\(n)").font(t.mono(11, .semibold)).foregroundStyle(.white).frame(width: 20, height: 20).background(t.rec)
                Text(c.libraryMove(m.id)?.label ?? c.move(m.id)?.label ?? m.id).font(t.body(14, .semibold))
                Spacer()
            }
            HStack {
                Text("INTENSITY").font(t.mono(10)).foregroundStyle(t.muted)
                Slider(value: Binding(get: { (m.intensity ?? 0.5) * 100 }, set: { v in var x = m; x.intensity = (v / 100 * 100).rounded() / 100; set(x) }), in: 0...100)
                    .accessibilityLabel("Intensity of move \(n)")
                Text("\(Int(((m.intensity ?? 0.5) * 100).rounded()))%").font(t.mono(11)).frame(width: 40)
            }
            HStack {
                Text("SPEED").font(t.mono(10)).foregroundStyle(t.muted)
                BagChips(options: [("slow", "Slow"), ("normal", "Normal"), ("fast", "Fast")], selected: m.speed ?? "normal") { id in var x = m; x.speed = id; set(x) }
            }
        }
    }
}

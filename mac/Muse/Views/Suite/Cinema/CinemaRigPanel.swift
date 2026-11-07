import MuseCore
import SwiftUI

// Build step 3 (plans/ai-suite-design.md; mocks plans/ai-suite-cinematic/3-rig-style and 4-rig-camera): the rig panel of
// the cinematic Suite, behind the same owner switch. One glass panel over the room with the rig's tabs (Camera, Angle,
// Move, Light, Look, Style; Directed for the owner), the saved rigs at the top, and each tab's picker: the approved drums
// for hardware, the loop grid for moves, the stills for light, the swatch tiles for looks, and Style's arc carousel with
// the era ruler and tempo.

/// A tab of the rig panel: which picker and step it shows.
enum CinemaRigTab: String, CaseIterable, Identifiable {
    case camera, angle, move, light, look, style, directed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .camera: return "Camera"
        case .angle: return "Angle"
        case .move: return "Move"
        case .light: return "Light"
        case .look: return "Look"
        case .style: return "Style"
        case .directed: return "Directed"
        }
    }
    var picker: ComposerPicker {
        switch self {
        case .camera, .angle, .move, .directed: return .camera
        case .light: return .lighting
        case .look: return .look
        case .style: return .style
        }
    }
    var step: String {
        switch self {
        case .camera: return "setup"
        case .angle: return "angle"
        case .move: return "movement"
        case .directed: return "directed"
        case .light: return "lighting"
        case .look: return "look"
        case .style: return "genre"
        }
    }

    static func of(_ p: ComposerPicker, step: String) -> CinemaRigTab {
        switch p {
        case .camera:
            switch step {
            case "angle": return .angle
            case "movement": return .move
            case "directed": return .directed
            default: return .camera
            }
        case .lighting: return .light
        case .look: return .look
        case .style: return .style
        }
    }
}

struct CinemaRigPanel: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var moveQuery = ""
    @State private var saveOpen = false
    @State private var rigName = ""

    private var photo: Bool { store.suite.composer.tool == .photo }
    private var tab: CinemaRigTab { CinemaRigTab.of(store.suite.picker ?? .camera, step: store.suite.pickerStep) }
    private var tabs: [CinemaRigTab] {
        var all: [CinemaRigTab] = [.camera, .angle]
        if !photo { all.append(.move) }
        all += [.light, .look, .style]
        if store.isOwner && !photo { all.append(.directed) }
        return all
    }

    var body: some View {
        GeometryReader { g in
            ZStack {
                t.roles.canvas.opacity(0.7)
                    .contentShape(Rectangle())
                    .onTapGesture { store.closePicker() }
                    .accessibilityHidden(true)
                panel
                    .frame(width: max(0, min(g.size.width - 80, 1040)), height: max(0, min(g.size.height - 48, 760)))
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }

    private var panel: some View {
        let shape = RoundedRectangle(cornerRadius: max(t.roomRadius, 10))
        return VStack(alignment: .leading, spacing: 0) {
            header
            savedRigs
            Rectangle().fill(t.roles.hairline).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                t.roles.canvas.opacity(0.82)
                t.roomGlassTint.opacity(0.06)
            }
            .clipShape(shape)
        }
        .overlay(shape.strokeBorder(t.roles.ink.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 50, y: 30)
        .onExitCommand { store.closePicker() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rig")
    }

    private var header: some View {
        HStack(spacing: 22) {
            ForEach(tabs) { tb in
                let on = tb == tab
                Button {
                    store.suite.picker = tb.picker
                    store.suite.pickerStep = tb.step
                } label: {
                    VStack(spacing: 6) {
                        Text(tb.title).font(t.scale.caption.font.weight(.medium)).foregroundStyle(on ? t.roles.ink : t.roles.ink2)
                        Rectangle().fill(on ? t.roles.accent : .clear).frame(height: 2)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(tb.title)\(on ? ", selected" : "")")
            }
            Spacer(minLength: 8)
            if tab == .move {
                HStack(spacing: 8) {
                    Ph("magnifyingglass", 12)
                    TextField("Search \(store.suite.camera.moves.count) moves", text: $moveQuery).textFieldStyle(.plain).font(t.scale.caption.font)
                }
                .foregroundStyle(t.roles.ink2)
                .padding(.horizontal, 12).frame(width: 220, height: 30)
                .background(Capsule().fill(t.roles.ink.opacity(0.08)))
            }
            Button { reset() } label: {
                Text("Reset").font(t.scale.caption.font.weight(.medium)).foregroundStyle(t.roles.ink2).padding(.horizontal, 6).frame(height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Reset this tab")
            Button { store.closePicker() } label: {
                Ph("xmark", 16).foregroundStyle(t.roles.ink).frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain).keyboardShortcut(.cancelAction).help("Close").accessibilityLabel("Close")
        }
        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 4)
    }

    private var savedRigs: some View {
        HStack(spacing: 6) {
            Text("Saved rigs").font(t.scale.micro.font).foregroundStyle(t.roles.ink2).padding(.trailing, 4)
            if store.suite.savedRigs.isEmpty {
                Text("None yet").font(t.scale.micro.font).foregroundStyle(t.roles.ink2.opacity(0.8))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.suite.savedRigs.prefix(12)) { r in
                        Button { store.applySavedRig(r) } label: {
                            Text(r.name).font(t.scale.caption.font).foregroundStyle(t.roles.ink).lineLimit(1)
                                .padding(.horizontal, 10).frame(height: 28)
                                .overlay(Capsule().strokeBorder(t.roles.ink.opacity(0.16), lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(r.mine ? "Apply \(r.name)" : "Apply \(r.name) (from the studio)")
                    }
                }
            }
            Spacer(minLength: 8)
            Button { saveOpen = true } label: {
                Text("Save rig…").font(t.scale.caption.font.weight(.medium)).foregroundStyle(t.roles.accent).frame(height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $saveOpen, arrowEdge: .bottom) {
                HStack(spacing: 8) {
                    TextField("Name this rig", text: $rigName).textFieldStyle(.roundedBorder).frame(width: 200).onSubmit { save() }
                    Button("Save") { save() }.disabled(rigName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(12)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
    }

    private func save() {
        store.saveRig(named: rigName)
        rigName = ""
        saveOpen = false
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .camera: ScrollView { CameraSetupStep() } // short windows scroll; the drums keep their own scroll inside them
        case .angle: ScrollView { CameraAngleStep().padding(24) }
        case .move: CameraMovementStep(query: $moveQuery)
        case .directed:
            DirectedModePanel(shotTitle: store.suite.composer.title) { store.applyDirected($0) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .light: ScrollView { LightingStep().padding(24) }
        case .look: ScrollView { LookStep().padding(24) }
        case .style: CinemaStylePicker()
        }
    }

    private func reset() {
        let chip = tab.picker.chip
        store.suite.pickerSettings = store.suite.pickerSettings.reset(chip)
        if tab == .move || tab == .camera {
            var tk = store.suite.composer.tokens
            if tab == .move { for k in tk.moves.compactMap(\.key) { tk = tk.remove(key: k) } }
            store.suite.composer.tokens = tk
        }
    }
}

// MARK: Style: the genre arc carousel, the era ruler and tempo

struct CinemaStylePicker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let c = store.suite.camera
        let s = store.suite.pickerSettings
        let photo = store.suite.composer.tool == .photo
        let genres: [SuiteOption?] = [nil] + c.genres.map { Optional($0) }
        let sel = genres.firstIndex { $0?.id == s.genre } ?? 0
        VStack(alignment: .leading, spacing: 0) {
            Text("Genre").font(t.scale.caption.font).foregroundStyle(t.roles.ink2).padding(.horizontal, 24).padding(.top, 14)
            GeometryReader { g in
                let base = max(40, min(300, (g.size.height - 70) / 1.25)) // never negative (a first layout pass can be 0 tall)
                ZStack {
                    ForEach(Array(genres.enumerated()), id: \.offset) { i, o in
                        let d = i - sel
                        if abs(d) <= 3 {
                            arcCard(o, d: d, base: base, center: g.size.width / 2, top: 16)
                                .zIndex(Double(10 - abs(d)))
                        }
                    }
                }
                .frame(width: g.size.width, height: g.size.height)
                .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86), value: sel)
            }
            .frame(maxHeight: .infinity)
            eraRuler(c.eras, selected: s.era)
                .padding(.horizontal, 24).padding(.top, 8)
            HStack(spacing: 6) {
                Text("Tempo").font(t.scale.caption.font).foregroundStyle(t.roles.ink2).frame(width: 64, alignment: .leading)
                if !photo {
                    tempoPill("Auto", on: s.tempo == nil) { store.suite.pickerSettings.tempo = nil }
                    ForEach(c.tempos) { o in tempoPill(o.label, on: s.tempo == o.id) { store.suite.pickerSettings.tempo = o.id } }
                } else {
                    Text("Stills have no tempo").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                }
                Spacer(minLength: 8)
                Text(summary(c, s)).font(t.scale.caption.font).foregroundStyle(t.roles.ink2).lineLimit(1)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .onMoveCommand { dir in
            switch dir {
            case .left: if sel > 0 { store.suite.pickerSettings.genre = genres[sel - 1]?.id }
            case .right: if sel < genres.count - 1 { store.suite.pickerSettings.genre = genres[sel + 1]?.id }
            default: break
            }
        }
        .focusable()
    }

    /// A card on the arc: the centre one large with the glow ring and its name; the others smaller, tilted and faded.
    private func arcCard(_ o: SuiteOption?, d: Int, base: CGFloat, center: CGFloat, top: CGFloat) -> some View {
        let a = abs(d)
        let sc: CGFloat = [1, 0.78, 0.62, 0.5][min(a, 3)]
        let w = base * sc
        let k = base / 300
        let x = center + CGFloat(d) * (a == 1 ? 210 : 190) * k + CGFloat(a > 1 ? 40 * d : 0) * k
        let y = top + pow(CGFloat(a), 1.6) * 26 * k
        let shape = RoundedRectangle(cornerRadius: max(t.radii.control, 12))
        return Button { store.suite.pickerSettings.genre = o?.id } label: {
            VStack(spacing: 10) {
                ZStack {
                    if let o { PreviewView(preview: PickerPreview.option(o), fallback: o.label) } else {
                        LinearGradient(colors: [t.roles.raised, t.roles.canvas], startPoint: .top, endPoint: .bottom)
                            .overlay(Ph("aperture", 34).foregroundStyle(t.roles.ink2))
                    }
                }
                .frame(width: w, height: w * 1.25)
                .clipShape(shape)
                .overlay(shape.strokeBorder(d == 0 ? t.roles.accent : .clear, lineWidth: 2))
                .shadow(color: d == 0 ? t.roles.accent.opacity(0.5) : .black.opacity(0.55), radius: d == 0 ? 20 : 16, y: d == 0 ? 0 : 14)
                if d == 0 {
                    VStack(spacing: 2) {
                        Text(o?.label ?? "Auto").font(t.scale.heading.font).foregroundStyle(t.roles.ink)
                        Text(o?.caption ?? o?.description ?? "Picks for the shot").font(t.scale.caption.font).foregroundStyle(t.roles.ink2).lineLimit(1)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rotationEffect(.degrees(Double(d) * 7), anchor: UnitPoint(x: 0.5, y: 1.6))
        .opacity([1, 0.8, 0.5, 0.3][min(a, 3)])
        .position(x: x, y: y + w * 1.25 / 2 + (d == 0 ? 24 : 0))
        .accessibilityLabel("\(o?.label ?? "Auto")\(d == 0 ? ", selected" : "")")
    }

    private func eraRuler(_ eras: [SuiteOption], selected: String?) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text("Era").font(t.scale.caption.font).foregroundStyle(t.roles.ink2).frame(width: 64, alignment: .leading)
            HStack(alignment: .top, spacing: 0) {
                tick("Auto", on: selected == nil) { store.suite.pickerSettings.era = nil }
                ForEach(eras) { e in tick(e.label, on: selected == e.id) { store.suite.pickerSettings.era = e.id } }
            }
            .overlay(alignment: .top) { Rectangle().fill(t.roles.ink.opacity(0.18)).frame(height: 1) }
        }
    }

    private func tick(_ label: String, on: Bool, _ pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            VStack(spacing: 6) {
                Rectangle().fill(on ? t.roles.accent : t.roles.ink.opacity(0.35)).frame(width: on ? 2 : 1, height: on ? 18 : 10)
                    .shadow(color: on ? t.roles.accent : .clear, radius: 6)
                Text(label).font(t.scale.micro.font).foregroundStyle(on ? t.roles.ink : t.roles.ink2).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Era \(label)\(on ? ", selected" : "")")
    }

    private func tempoPill(_ label: String, on: Bool, _ pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            Text(label).font(t.scale.caption.font.weight(.medium)).foregroundStyle(on ? t.roles.ink : t.roles.ink2)
                .padding(.horizontal, 12).frame(height: 30)
                .background(Capsule().fill(on ? t.roles.ink.opacity(0.10) : .clear))
                .overlay(Capsule().strokeBorder(on ? t.roles.accent : .clear, lineWidth: 1))
                .shadow(color: on ? t.roles.accent.opacity(0.4) : .clear, radius: 8)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Tempo \(label)\(on ? ", selected" : "")")
    }

    private func summary(_ c: CameraCatalog, _ s: ComposerSettings) -> String {
        let parts = [ComposerCatalog.label(c.genres, s.genre), ComposerCatalog.label(c.eras, s.era), ComposerCatalog.label(c.tempos, s.tempo).map { $0.lowercased() }]
            .compactMap { $0 }
        return parts.isEmpty ? "Auto" : parts.joined(separator: ", ")
    }
}

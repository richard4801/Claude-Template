import MuseCore
import SwiftUI

/// Photoshoot: a 4-shot canvas with the Scene / Camera / Light / Prompt inspector.
struct ShootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        HStack(spacing: 0) {
            ShootCanvas().frame(maxWidth: .infinity)
            if store.shootTemplate != nil {
                TemplateInspector().frame(width: 344)
            } else {
                ShootInspector().frame(width: 344)
            }
        }
    }
}

struct ShootCanvas: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var modelPicker = false

    var body: some View {
        let model = store.currentModel
        let outfitBinding = Binding<String>(get: { store.currentOutfit?.id ?? "" }, set: { id in
            if let o = store.currentOutfits.first(where: { $0.id == id }) { store.selectOutfit(o) }
        })
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(eyebrow: store.shootTemplate.map { "Photoshoot · Template: \($0.name)" } ?? "Photoshoot",
                           title: "\(model?.shortName ?? "Model") · \(store.currentOutfit?.name ?? "No outfit")") {
                    MButton("Templates", icon: "square.on.square.dashed") { store.openTemplates() }
                    MoreMenu {
                        if store.shootTemplate != nil {
                            Button("Shoot without a template") { store.stopUsingTemplate() }
                        } else {
                            Button("Show prompt") { store.shootTab = .prompt }
                            Button("Save as preset") { store.showToast("Saved as preset") }
                            Button("Reset camera") { store.resetCamera() }
                        }
                    }
                }
                HStack(spacing: 10) {
                    Lbl("Model")
                    // A button + popover, not a Menu: macOS menus draw an image label at its full pixel size,
                    // so a full-resolution uploaded cover filled the whole window.
                    Button { modelPicker = true } label: {
                        Media(ref: model?.cover, ratio: 0.75, radius: t.isA ? 0 : 6)
                            .frame(width: 44, height: 58)
                            .overlay(RoundedRectangle(cornerRadius: t.isA ? 0 : 6).strokeBorder(t.accent, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .help("Change model")
                    .popover(isPresented: $modelPicker, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(store.models) { m in
                                Button {
                                    store.selectModel(m)
                                    modelPicker = false
                                } label: {
                                    HStack(spacing: 10) {
                                        Media(ref: m.cover, ratio: 0.75, radius: 4).frame(width: 30, height: 40)
                                        Text(m.name).font(t.body(13, m.id == model?.id ? .semibold : .regular)).foregroundStyle(t.ink)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(8)
                        .frame(width: 240)
                    }
                    Lbl("Outfit").padding(.leading, 14)
                    if !store.currentOutfits.isEmpty {
                        Seg(store.currentOutfits.map { ($0.id, $0.name) }, selection: outfitBinding).frame(maxWidth: 360)
                    }
                    LinkText("+ New outfit") { store.openOutfitSheet(for: nil) }
                    Spacer()
                    if t.isB {
                        Text("\(store.shoot.lens)MM · \(store.shoot.aperture.uppercased()) · 4300K").font(t.mono(11.5)).tracking(0.7).foregroundStyle(t.accent)
                    }
                }
                .padding(.bottom, 18)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
                    ForEach(0..<4, id: \.self) { i in
                        switch store.shootState {
                        case .busy: Shimmer()
                        case .done:
                            let shot = store.lastShots.indices.contains(i) ? store.lastShots[i] : nil
                            Button { if let shot { store.openTake(shot.id) } } label: {
                                Media(ref: shot?.thumb, ratio: 0.75, radius: t.cardRadius) { Pill("AI", .acc) }
                            }
                            .buttonStyle(.plain)
                            .transition(.scale(scale: 0.9).combined(with: .opacity).animation(.spring(response: 0.4, dampingFraction: 0.7).delay(Double(i) * 0.08)))
                        case .idle:
                            EmptyTile(icon: "camera", text: "Shot \(i + 1)")
                        }
                    }
                }
                if store.shootState == .done {
                    // The receipt: what these photos actually cost (the estimate settles to the exact amount).
                    if !store.lastShots.isEmpty {
                        Muted("\(store.lastShots.count) photo\(store.lastShots.count == 1 ? "" : "s") · \(Pricing.money(store.lastShots.reduce(0) { $0 + $1.cost }))")
                    }
                    HStack(spacing: 10) {
                        MButton("View in Gallery", icon: "square.grid.2x2", kind: .primary) {
                            store.galleryTab = .tests
                            store.go(.gallery)
                        }
                        if let tpl = store.shootTemplate {
                            MButton("Shoot 4 more · \(PhotoPricing.label(store.shootEstimate))", icon: "arrow.triangle.2.circlepath") { store.startTemplateShoot() }
                            Muted(store.templateLockLook ? "Lock look is on: the same seed for \(tpl.name) on this model." : "Same template, a new moment every shot.")
                        } else {
                            MButton("Shoot 4 more · \(PhotoPricing.label(store.shootEstimate))", icon: "arrow.triangle.2.circlepath") { store.startShoot() }
                            if store.shoot.lockSeed { Muted("Lock look is on: retakes keep the same face and styling.") }
                        }
                    }
                    .padding(.top, 18)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 40)
        }
    }
}

struct ShootInspector: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(ShootTab.allCases, id: \.self) { tab in
                    let on = store.shootTab == tab
                    Button { store.shootTab = tab } label: {
                        Text(t.isA ? tab.rawValue.uppercased() : tab.rawValue.capitalized)
                            .font(t.isA ? t.mono(11.5, .medium) : t.body(13, .semibold))
                            .tracking(t.isA ? 0.9 : 0)
                            .foregroundStyle(on ? t.ink : t.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 14)
                            .padding(.bottom, 12)
                            .overlay(alignment: .bottom) { Rectangle().fill(on ? (t.isD ? Color(hex: 0x111111) : t.accent) : .clear).frame(height: 2) }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(t.isC ? t.line : t.strongLine).frame(height: t.lineWidth) }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch store.shootTab {
                    case .scene:
                        Field("Scene") {
                            FlowLayout {
                                ForEach(ShootSettings.scenes, id: \.self) { s in
                                    Chip(s, on: store.shoot.scene == s && store.shoot.sceneCustom.trimmingCharacters(in: .whitespaces).isEmpty) {
                                        store.shoot.scene = s
                                        store.shoot.sceneCustom = ""
                                    }
                                }
                            }
                        }
                        Field("Or describe your own") {
                            TextBox(placeholder: "e.g. sunlit rooftop bar, string lights, city skyline", text: $store.shoot.sceneCustom)
                        }
                    case .camera:
                        Field("Shot") { Seg(ShootSettings.shots.map { ($0, $0) }, selection: $store.shoot.shot) }
                        Field("Lens · \(store.shoot.lens)mm") {
                            FlowLayout {
                                ForEach(ShootSettings.lenses, id: \.self) { l in Chip("\(l)mm", on: store.shoot.lens == l) { store.shoot.lens = l } }
                            }
                            Muted(store.shoot.lensHint)
                        }
                        Field("Aperture") {
                            FlowLayout {
                                ForEach(ShootSettings.apertures, id: \.self) { a in Chip(a, on: store.shoot.aperture == a) { store.shoot.aperture = a } }
                            }
                        }
                        LinkText("Reset camera") { store.resetCamera() }
                    case .light:
                        Field("Light") {
                            FlowLayout {
                                ForEach(ShootSettings.lights, id: \.self) { l in Chip(l, on: store.shoot.light == l) { store.shoot.light = l } }
                            }
                        }
                        Field("Grade") {
                            FlowLayout {
                                ForEach(ShootSettings.grades, id: \.self) { g in Chip(g, on: store.shoot.grade == g) { store.shoot.grade = g } }
                            }
                        }
                    case .prompt:
                        Field("Your direction") {
                            TextBox(placeholder: "e.g. laughing mid-step, hair blowing, holding an iced coffee", text: $store.shoot.direction)
                            Muted("Adds detail. It can't change her identity or the never-add list.")
                        }
                        OptionRow(title: "Presets", hint: store.shootPresets ? "Adds scene, camera, light, style and never-add lines" : "Off: only her identity, outfit and your direction are sent") {
                            MToggle(isOn: Binding(get: { store.shootPresets }, set: { store.shootPresets = $0 }))
                        }
                        OptionRow(title: "Lock look", hint: "Same seed, so retakes stay consistent") { MToggle(isOn: $store.shoot.lockSeed) }
                        Field("Final prompt") {
                            if store.promptOverride != nil {
                                TextBox(placeholder: "", text: Binding(get: { store.promptOverride ?? "" }, set: { store.promptOverride = $0 }), lines: 9, mono: true)
                            } else {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(store.shootSlots) { slot in
                                        (Text(slot.key.uppercased() + "  ").font(t.mono(10)).foregroundColor(t.muted) + Text(slot.body).font(t.body(12.5)))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .textSelection(.enabled)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: t.controlRadius).fill(t.surface2))
                                .overlay(RoundedRectangle(cornerRadius: t.controlRadius).strokeBorder(t.isC ? .clear : t.strongLine, lineWidth: t.lineWidth))
                            }
                        }
                        HStack(spacing: 10) {
                            MButton("Copy", size: .small, fill: true) { store.copy(store.promptOverride ?? store.shootPromptText) }
                            if store.promptOverride != nil {
                                MButton("Use built prompt", size: .small, fill: true) { store.promptOverride = nil }
                            } else {
                                MButton("Edit as text", size: .small, fill: true) {
                                    store.promptOverride = store.shootPromptText
                                    store.showToast("Editing as text. Your edits apply to the next shoot only.")
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            VStack(alignment: .leading, spacing: 8) {
                if store.isOwner { ModelChooser(step: .shot, target: .shoot) }
                MButton(store.shootState == .busy ? "Shooting…" : "Shoot 4 · \(PhotoPricing.label(store.shootEstimate))", kind: .primary, size: .big, off: store.shootState == .busy) { store.startShoot() }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 18)
            .overlay(alignment: .top) { Rectangle().fill(t.isC ? .clear : t.strongLine).frame(height: t.lineWidth) }
        }
        .background(t.chrome)
        .overlay(alignment: .leading) { Rectangle().fill(t.isC ? .clear : t.strongLine).frame(width: t.lineWidth) }
    }
}

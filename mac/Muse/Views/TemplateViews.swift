import MuseCore
import SwiftUI

// Photoshoot → Templates (plans/templates.md): the library, the detail, the template inspector on the Photoshoot screen and
// the template editor. Prompt layers are only ever drawn from `layers`/`variationPool`, which the server sends to the owner only.

/// The library: All / Mine / Public / Favourites, search, tag chips and cards.
struct TemplatesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        @Bindable var store = store
        let list = store.templateList
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(eyebrow: "Photoshoot", title: "Templates") {
                    HStack(spacing: 10) {
                        MButton("Photoshoot", icon: "camera") { store.go(.shoot) }
                        if store.pro { MButton("New template", icon: "plus", kind: .primary) { store.newTemplate() } }
                    }
                }
                Muted("A template is a look: camera, scene, light, grade and after-effects. Use it on any model and outfit; every shot is a new moment.", size: 13)
                    .padding(.bottom, 18)
                HStack(spacing: 14) {
                    Seg(TemplateScope.allCases.map { ($0, $0.label) }, selection: $store.templateScope).frame(maxWidth: 440)
                    Spacer(minLength: 12)
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(t.muted)
                        TextField("Search by name or tag", text: $store.templateQuery).textFieldStyle(.plain)
                        if !store.templateQuery.isEmpty {
                            Button { store.templateQuery = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(t.muted) }.buttonStyle(.plain)
                        }
                    }
                    .fieldChrome()
                    .frame(width: 260)
                }
                .padding(.bottom, 14)
                let tags = store.templateTags
                if !tags.isEmpty {
                    FlowLayout {
                        Chip("All tags", on: store.templateTag == nil) { store.templateTag = nil }
                        ForEach(tags, id: \.self) { tag in
                            let on = store.templateTag.map { $0.caseInsensitiveCompare(tag) == .orderedSame } ?? false
                            Chip(tag, on: on) {
                                store.templateTag = on ? nil : tag
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }
                if list.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "square.on.square.dashed").font(.system(size: 26)).foregroundStyle(t.muted)
                        Text(emptyTitle).font(t.body(15, .semibold))
                        Muted(emptyHint, size: 13).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 18, alignment: .top)], alignment: .leading, spacing: 22) {
                        ForEach(list) { tpl in TemplateCard(template: tpl) }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 40)
        }
        .task { await store.loadTemplates() }
    }

    private var emptyTitle: String {
        if !store.templateQuery.isEmpty || store.templateTag != nil { return "No templates match" }
        switch store.templateScope {
        case .all, .public: return "No templates yet"
        case .mine: return "You haven't made a template yet"
        case .favourites: return "No favourites yet"
        }
    }

    private var emptyHint: String {
        if !store.templateQuery.isEmpty || store.templateTag != nil { return "Try another word or tag." }
        switch store.templateScope {
        case .mine: return "Open any photo you like and choose Save as template."
        case .favourites: return "Tap the star on a template to keep it here."
        default: return "Save a photo you like as a template, and it shows up here."
        }
    }
}

/// A library card: cover, name, owner, uses and the private/public badge.
struct TemplateCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var template: MuseTemplate
    @State private var hover = false

    var body: some View {
        let tpl = template
        VStack(alignment: .leading, spacing: 8) {
            Button { store.openTemplate(tpl) } label: {
                Media(ref: tpl.cover, ratio: 0.75, radius: t.imageRadius, symbol: "square.on.square.dashed") {
                    Pill(tpl.isPublic ? "Public" : "Private", tpl.isPublic ? .good : .neutral)
                }
            }
            .buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                FavouriteButton(on: tpl.favourite) { store.toggleFavourite(tpl) }.padding(6)
            }
            .overlay(alignment: .bottomTrailing) {
                if hover {
                    HoverChip("Use") { store.useTemplate(tpl) }.padding(10).transition(.opacity)
                }
            }
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
            Text(t.headingsUppercase ? tpl.name.uppercased() : tpl.name).font(t.body(14, .semibold)).foregroundStyle(t.ink).lineLimit(1)
            HStack(spacing: 6) {
                Text("by \(store.ownerLabel(tpl))").lineLimit(1)
                Text("·")
                Text(tpl.usesLabel)
            }
            .font(t.body(12))
            .foregroundStyle(t.muted)
        }
        .contextMenu {
            Button("Use") { store.useTemplate(tpl) }
            Button("Open") { store.openTemplate(tpl) }
            Button(tpl.favourite ? "Remove from Favourites" : "Add to Favourites") { store.toggleFavourite(tpl) }
            if tpl.isOwner {
                Divider()
                Button("Edit…") { store.editTemplate(tpl) }
                Button("Duplicate") { store.duplicateTemplate(tpl) }
                Button(tpl.isPublic ? "Make private" : "Make public") { store.setVisibility(tpl, tpl.isPublic ? .private : .public) }
                Divider()
                Button("Delete", role: .destructive) { store.deleteTemplate(tpl) }
            }
        }
    }
}

struct FavouriteButton: View {
    @Environment(\.theme) private var t
    var on: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: on ? "star.fill" : "star")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? (t.isD ? Color(hex: 0x111111) : t.accent) : Color(hex: 0x111111))
                .frame(width: 28, height: 28)
                .background(Circle().fill(on && t.isD ? t.yellow : .white.opacity(0.9)))
                .overlay(Circle().strokeBorder(t.isD ? Color(hex: 0x111111) : .clear, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(on ? "Remove from Favourites" : "Add to Favourites")
    }
}

/// Template detail: the cover, recent results, Use, and for the owner Duplicate / Edit / Delete / visibility.
struct TemplateDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        if let tpl = store.templateDetail {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Breadcrumb(parent: "Templates", title: tpl.name) { store.go(.templates) }
                    HStack(alignment: .top, spacing: 28) {
                        Media(ref: tpl.cover, ratio: 0.75, radius: t.cardRadius, symbol: "square.on.square.dashed").frame(width: 340)
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Eyebrow("Template · by \(store.ownerLabel(tpl))").styled()
                                    Text(t.headingsUppercase ? tpl.name.uppercased() : tpl.name)
                                        .font(t.isA ? Fonts.font("Instrument Serif", 40, .regular) : t.display(32, t.isD ? .heavy : .bold))
                                }
                                Spacer()
                                FavouriteButton(on: tpl.favourite) { store.toggleFavourite(tpl) }
                                if tpl.isOwner {
                                    MoreMenu {
                                        Button("Edit…") { store.editTemplate(tpl) }
                                        Button("Duplicate") { store.duplicateTemplate(tpl) }
                                        Divider()
                                        Button("Delete", role: .destructive) { store.deleteTemplate(tpl) }
                                    }
                                }
                            }
                            HStack(spacing: 8) {
                                Pill(tpl.isPublic ? "Public" : "Private", tpl.isPublic ? .good : .neutral)
                                Pill(tpl.usesLabel)
                                if tpl.acceptsProduct { Pill("Takes a product photo", .acc) }
                                ForEach(tpl.tags, id: \.self) { Pill($0) }
                            }
                            MButton("Use this template", icon: "camera", kind: .primary, size: .big) { store.useTemplate(tpl) }
                            if tpl.isOwner {
                                ListBox {
                                    ListRow(title: "Public", hint: tpl.isPublic ? "Everyone in the studio can see and use it" : "Only you can see and use it", last: true) {
                                        MToggle(isOn: Binding(get: { tpl.isPublic }, set: { store.setVisibility(tpl, $0 ? .public : .private) }))
                                    }
                                }
                                HStack(spacing: 10) {
                                    MButton("Edit", icon: "slider.horizontal.3", fill: true) { store.editTemplate(tpl) }
                                    MButton("Duplicate", icon: "plus.square.on.square", fill: true) { store.duplicateTemplate(tpl) }
                                    MButton("Delete", icon: "trash", fill: true) { store.deleteTemplate(tpl) }
                                }
                                if let l = tpl.layers { LayersSummary(layers: l, pool: tpl.variationPool ?? VariationPool()) }
                            } else {
                                Note(icon: "lock", "The look behind this template stays with its creator. You pick the model, the outfit and, if you like, a direction; every shot is a new moment.")
                            }
                        }
                        .frame(maxWidth: 460, alignment: .leading)
                        Spacer(minLength: 0)
                    }
                    SectionHeader("Recent results")
                    let recent = tpl.recent ?? []
                    if recent.isEmpty {
                        Muted("No shots with this template yet.", size: 13)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 6), spacing: 14) {
                            ForEach(recent) { r in
                                Button { if store.takes.contains(where: { $0.id == r.id }) { store.openTake(r.id) } } label: {
                                    Media(ref: r.thumb, ratio: 0.75, radius: t.imageRadius)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 40)
            }
        } else {
            VStack { Muted("Pick a template in the library.", size: 13) }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The owner's view of their layers (never shown for anyone else's template; they have no layers to show).
struct LayersSummary: View {
    @Environment(\.theme) private var t
    var layers: TemplateLayers
    var pool: VariationPool

    var body: some View {
        let rows: [(String, String)] = [
            ("Style", layers.style), ("Scene", layers.scene), ("Camera", layers.camera), ("Light", layers.light),
            ("After-effects", layers.afterEffects?.summary ?? ""), ("Never add", layers.negative), ("Product", layers.product),
        ].filter { !$0.1.isEmpty }
        VStack(alignment: .leading, spacing: 8) {
            Lbl("Your layers · only you see these")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    (Text(row.0.uppercased() + "  ").font(t.mono(10)).foregroundColor(t.muted) + Text(row.1).font(t.body(12.5)))
                        .fixedSize(horizontal: false, vertical: true)
                }
                let slots = VariationSlot.allCases.filter { !pool[$0].isEmpty }
                if !slots.isEmpty {
                    (Text("VARIATION  ").font(t.mono(10)).foregroundColor(t.muted)
                        + Text(slots.map { "\($0.label.lowercased()) (\(pool[$0].count))" }.joined(separator: ", ")).font(t.body(12.5)))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: t.controlRadius).fill(t.surface2))
        }
    }
}

/// The Photoshoot inspector while shooting with a template: the template, Direction, Shuffle, Lock look (off), the prompt
/// view in pro mode, and Shoot.
struct TemplateInspector: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        @Bindable var store = store
        if let tpl = store.shootTemplate {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(spacing: 12) {
                            Media(ref: tpl.cover, ratio: 0.75, radius: t.imageRadius, symbol: "square.on.square.dashed").frame(width: 64)
                            VStack(alignment: .leading, spacing: 4) {
                                Lbl("Template")
                                Text(tpl.name).font(t.body(15, .semibold)).foregroundStyle(t.ink).lineLimit(2)
                                Text("by \(store.ownerLabel(tpl))").font(t.body(12)).foregroundStyle(t.muted)
                            }
                            Spacer(minLength: 0)
                        }
                        HStack(spacing: 14) {
                            LinkText("Change template") { store.openTemplates() }
                            LinkText("Shoot without a template") { store.stopUsingTemplate() }
                        }
                        Field("Direction · optional") {
                            TextBox(placeholder: "e.g. sitting on the steps, looking back over her shoulder", text: $store.templateDirection)
                            Muted("Places her your way: it replaces the template's pose and angle. The rest of the look still applies.")
                        }
                        if tpl.acceptsProduct {
                            Field("Product photo · optional") {
                                HStack(spacing: 10) {
                                    if let p = store.templateProduct {
                                        Media(ref: p, ratio: 1, radius: t.imageRadius).frame(width: 56)
                                        LinkText("Replace") { store.pickTemplateProduct() }
                                        LinkText("Remove") { store.templateProduct = nil }
                                    } else {
                                        MButton("Add product photo", icon: "photo", size: .small, fill: false) { store.pickTemplateProduct() }
                                    }
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            MButton("Shuffle", icon: "shuffle", fill: true) { store.shuffleTemplate() }
                            Muted("New pose, angle, framing and moment. Same template.")
                        }
                        OptionRow(title: "Lock look", hint: store.templateLockLook ? "Same seed every shot for this model" : "Off: every shot gets a new seed") {
                            MToggle(isOn: $store.templateLockLook)
                        }
                        if store.pro {
                            Field("Final prompt") {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(store.templatePromptSlots) { slot in
                                        if slot.locked {
                                            HStack(spacing: 6) {
                                                Image(systemName: "lock.fill").font(.system(size: 10))
                                                Text(slot.text).font(t.body(12.5, .semibold))
                                            }
                                            .foregroundStyle(t.ink)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(RoundedRectangle(cornerRadius: t.controlRadius * 0.6).fill(t.surface))
                                            .help("The template's layers stay with its creator")
                                        } else {
                                            (Text(slot.layer.uppercased() + "  ").font(t.mono(10)).foregroundColor(t.muted) + Text(slot.body).font(t.body(12.5)))
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                                .textSelection(.enabled)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: t.controlRadius).fill(t.surface2))
                                .overlay(RoundedRectangle(cornerRadius: t.controlRadius).strokeBorder(t.isC ? .clear : t.strongLine, lineWidth: t.lineWidth))
                                Muted(tpl.isOwner ? "Your template: you see every layer. Others see one locked line." : "Built on the server. Your own layers are shown; the template's stay hidden.")
                            }
                            MButton("Copy", size: .small, fill: true) { store.copy(store.templatePromptSlots.map(\.text).joined(separator: "\n")) }
                        }
                    }
                    .padding(20)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if store.isOwner { ModelChooser(step: .shot, target: .shoot) }
                    MButton(store.shootState == .busy ? "Shooting…" : "Shoot 4 · \(store.shootEstimateLabel)", icon: "camera", kind: .primary, size: .big,
                            off: store.shootState == .busy) { store.startTemplateShoot() }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 18)
                .overlay(alignment: .top) { Rectangle().fill(t.isC ? .clear : t.strongLine).frame(height: t.lineWidth) }
            }
            .background(t.chrome)
            .overlay(alignment: .leading) { Rectangle().fill(t.isC ? .clear : t.strongLine).frame(width: t.lineWidth) }
            .task(id: promptKey) {
                // Debounced: typing a direction asks for the prompt view once the typing pauses.
                try? await Task.sleep(nanoseconds: 300_000_000)
                if !Task.isCancelled { store.refreshTemplatePrompt() }
            }
        }
    }

    private var promptKey: String {
        [store.shootTemplate?.id ?? "", store.modelId, store.currentOutfit?.id ?? "", store.templateDirection, "\(store.templateShuffle)",
         "\(store.templateLockLook)", "\(store.pro)"].joined(separator: "|")
    }
}

/// Save as template / Edit / New template: name, tags, private (default) or public, and for the creator the full prompt layers
/// and the auto-suggested variation pool.
struct TemplateSheetView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var newOption: [VariationSlot: String] = [:]

    var body: some View {
        if let f = store.templateForm {
            ZStack {
                Color.black.opacity(0.38).onTapGesture { store.closeTemplateForm() }
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Eyebrow(f.isEditing ? "Edit template" : f.fromShotId != nil ? "From this photo" : "From scratch").styled()
                            Text(t.headingsUppercase ? title(f).uppercased() : title(f))
                                .font(t.isA ? Fonts.font("Instrument Serif", 44, .regular) : t.display(30, t.isD ? .heavy : .bold))
                        }
                        Spacer()
                        IconButton(systemName: "xmark", help: "Close") { store.closeTemplateForm() }
                    }
                    HStack(alignment: .top, spacing: 22) {
                        VStack(alignment: .leading, spacing: 8) {
                            Media(ref: f.cover, ratio: 0.75, radius: t.imageRadius, symbol: "square.on.square.dashed").frame(width: 170)
                            Muted(f.cover == nil ? "The cover comes from your first shot with it." : "Cover")
                        }
                        .frame(width: 170)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Field("Name") {
                                    TextField("e.g. Rooftop golden hour", text: bind(\.name)).fieldChrome()
                                }
                                Field("Tags") {
                                    TextField("e.g. Faceless, Golden hour", text: bind(\.tagsText)).fieldChrome()
                                    if !f.tags.isEmpty { FlowLayout { ForEach(f.tags, id: \.self) { Pill($0) } } }
                                }
                                Field("Who can use it") {
                                    Seg([(TemplateVisibility.private, "Private · only me"), (.public, "Public · the studio")], selection: bind(\.visibility)).frame(width: 340)
                                }
                                SectionHeader("Prompt layers", top: 6)
                                Muted("Only you see these. Anyone else who uses the template sees one locked line, \"Template: \(f.trimmedName.isEmpty ? "Name" : f.trimmedName)\". Identity, outfit and never-add always come from the model being shot.")
                                layerField("Style", \.style, "e.g. real mirror selfie, nothing staged")
                                layerField("Scene", \.scene, "e.g. lived-in bedroom with a full-length mirror")
                                layerField("Camera", \.camera, "Shot, lens, angle, framing")
                                layerField("Light and grade", \.light, "e.g. window light, slightly underexposed")
                                layerField("Never add", \.negative, "Extra never-add items for this look")
                                layerField("Product photo", \.product, "Optional: how a product photo is used")
                                afterEffects(f)
                                SectionHeader(title: "Variation pool", top: 10) {
                                    LinkText("Suggest again") { store.templateForm?.suggestPool() }
                                }
                                Muted("Each shot draws one option from every slot, so the style stays and the moment changes. A written direction replaces pose and body angle.")
                                ForEach(VariationSlot.allCases) { slot in poolSlot(slot, f) }
                            }
                            .padding(.trailing, 8)
                        }
                        .frame(maxHeight: 520)
                    }
                    HStack {
                        Muted(f.isEditing ? "Changes apply to the next shots made with it." : "Private by default. You can make it public any time.")
                        Spacer(minLength: 16)
                        MButton("Cancel") { store.closeTemplateForm() }
                        MButton(store.templateFormBusy ? "Saving…" : f.isEditing ? "Save changes" : "Save template", kind: .primary,
                                off: !f.canSave || store.templateFormBusy) { store.saveTemplateForm() }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 26)
                .frame(width: 860)
                .background(RoundedRectangle(cornerRadius: t.rLg).fill(t.bg))
                .overlay(RoundedRectangle(cornerRadius: t.rLg).strokeBorder(t.strongLine, lineWidth: t.lineWidth))
                .modifier(ThemeShadow(kind: .card, radius: t.rLg))
                .shadow(color: .black.opacity(0.35), radius: 40, y: 30)
            }
        }
    }

    private func title(_ f: TemplateForm) -> String { f.isEditing ? f.name : "Save as template" }

    private func bind<V>(_ kp: WritableKeyPath<TemplateForm, V>) -> Binding<V> {
        Binding(get: { (store.templateForm ?? TemplateForm())[keyPath: kp] }, set: { store.templateForm?[keyPath: kp] = $0 })
    }

    private func layerField(_ label: String, _ kp: WritableKeyPath<TemplateLayers, String>, _ placeholder: String) -> some View {
        Field(label) {
            TextBox(placeholder: placeholder, text: Binding(get: { store.templateForm?.layers[keyPath: kp] ?? "" },
                                                            set: { store.templateForm?.layers[keyPath: kp] = String($0.prefix(TemplateLayers.maxLength)) }), lines: 2)
        }
    }

    @ViewBuilder private func afterEffects(_ f: TemplateForm) -> some View {
        let fx = f.layers.afterEffects ?? TemplateAfterEffects()
        Field("After-effects") {
            VStack(alignment: .leading, spacing: 10) {
                Muted("Applied to each photo after it's made, not through the prompt.")
                FlowLayout {
                    ForEach(TemplateGrade.allCases, id: \.self) { g in
                        Chip(g.label, on: (fx.grade ?? "none") == g.rawValue) { setFX { $0.grade = g == TemplateGrade.none ? nil : g.rawValue } }
                    }
                }
                fxSlider("Face motion blur", value: fx.faceMotionBlur ?? 0) { v in setFX { $0.faceMotionBlur = v > 0 ? v : nil } }
                fxSlider("Grain", value: fx.grain ?? 0) { v in setFX { $0.grain = v > 0 ? v : nil } }
            }
        }
    }

    private func fxSlider(_ label: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(label).font(t.body(13)).frame(width: 130, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { set(($0 * 20).rounded() / 20) }), in: 0...1)
            Text(value > 0 ? "\(Int((value * 100).rounded()))%" : "Off").font(t.mono(12)).foregroundStyle(t.muted).frame(width: 40, alignment: .trailing)
        }
    }

    private func setFX(_ change: (inout TemplateAfterEffects) -> Void) {
        var fx = store.templateForm?.layers.afterEffects ?? TemplateAfterEffects()
        change(&fx)
        store.templateForm?.layers.afterEffects = fx.isEmpty ? nil : fx
    }

    private func poolSlot(_ slot: VariationSlot, _ f: TemplateForm) -> some View {
        let options = f.pool[slot]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Lbl(slot.label)
                if slot.replacedByDirection { Muted("· replaced by a direction") }
            }
            FlowLayout {
                ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                    RemovableChip(text: o) { store.templateForm?.removeOption(at: i, from: slot) }
                }
                HStack(spacing: 6) {
                    TextField("Add an option", text: Binding(get: { newOption[slot] ?? "" }, set: { newOption[slot] = $0 }))
                        .textFieldStyle(.plain)
                        .font(t.body(13))
                        .frame(width: 150)
                        .onSubmit { add(slot) }
                    Button { add(slot) } label: { Image(systemName: "plus").font(.system(size: 11, weight: .bold)) }.buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .overlay(RoundedRectangle(cornerRadius: t.isA ? 0 : 16).strokeBorder(t.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
        }
    }

    private func add(_ slot: VariationSlot) {
        store.templateForm?.addOption(newOption[slot] ?? "", to: slot)
        newOption[slot] = ""
    }
}

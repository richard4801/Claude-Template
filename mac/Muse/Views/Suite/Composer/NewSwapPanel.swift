import MuseCore
import SwiftUI

// New Swap (beta, plans/new-swap.md): the Swap screen's second panel, in the composer's right rail. The video first
// (upload, link or Library), then four toggles, each with one short field; what is off is kept from the clip. A clip
// longer than the model takes gets a trimmer (owner: never cut silently). The model pill lists every model that edits a
// video, with its limits and price for this clip; Auto is first and says why.

/// Swap's header switch: Swap | New Swap (beta).
struct SwapVariantSwitch: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Picker("Swap version", selection: Binding(get: { store.suite.swapVariant }, set: { store.setSwapVariant($0) })) {
            ForEach(SwapVariant.allCases, id: \.self) { v in Text(v.label).tag(v) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Switch between the current Swap and New Swap (beta)")
        .accessibilityLabel("Swap version")
    }
}

struct NewSwapPanel: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var libraryOpen = false
    /// Outfit "Her outfit" while Character isn't her: whose outfits are listed.
    @State private var outfitOwner: String?
    /// Character: the list of her characters is open (Change).
    @State private var pickHer = false
    /// New Swap's own screen (plans/swap-viewer-design.md §A): the video and the trimmer are on the stage, so this column
    /// holds only the changes.
    var onScreen = false

    private var d: RemixDraft { store.suite.remix }

    private func bind<V>(_ kp: WritableKeyPath<RemixDraft, V>) -> Binding<V> {
        Binding(get: { store.suite.remix[keyPath: kp] }, set: { store.suite.remix[keyPath: kp] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            if onScreen {
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text("Changes").font(t.scale.heading.font).foregroundStyle(t.roles.ink)
                    Text("Switch on what should change. Write only the change.").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                source
                if let c = store.clip { trimmer(c) }
            }
            VStack(alignment: .leading, spacing: Space.s3) {
                toggleRow("Background", isOn: bind(\.backgroundOn), state: d.backgroundMode == .describe ? "Describe the new place" : "A new place from a picture",
                          help: "A new place: describe it, or a location or photo") { backgroundField }
                toggleRow("Outfit", isOn: bind(\.outfitOn), state: "New clothes", help: "New clothes: one of her outfits, a product photo, or words") { outfitField }
                toggleRow("Character", isOn: bind(\.characterOn), state: d.characterKind == .model ? "Her, with the figure lock" : "Face swap from a photo",
                          help: "Who the person becomes: her, or a face swap from a photo") { characterField }
                toggleRow("Look & light", isOn: bind(\.lookOn), state: "Time of day, light, grade", help: "Time of day, light and colour grade") { lookField }
            }
            Text(d.keptLine).font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if !onScreen, d.engineModel == nil, let why = store.suite.remixEstimate?.remix?.why ?? store.suite.remixModels?.auto?.why {
                Text("Auto: \(why)").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { preselectHer() }
        .onChange(of: d.characterOn) { _, on in if on && d.characterKind == .model && d.modelId == nil { store.suite.remix.modelId = defaultHer } }
    }

    /// Owner's rule: her, with the strict figure lock, is the default Character.
    /// The one chosen in Swap or the composer, else the first character.
    private var defaultHer: String? {
        store.suite.swap.modelId ?? store.suite.composer.tokens.characterId ?? store.suiteCharacters.first?.id
    }

    /// A fresh draft (Character never touched) starts with Character on and her picked.
    private func preselectHer() {
        guard !d.characterOn, d.characterKind == .model, d.modelId == nil, let her = defaultHer else { return }
        store.suite.remix.characterOn = true
        store.suite.remix.modelId = her
    }

    /// Choosing her outfit (or whose outfits) turns Character on as that character, unless Character is a face swap.
    private func characterFrom(_ id: String?) {
        guard let id, !d.characterOn || d.characterKind == .model else { return }
        store.suite.remix.characterOn = true
        store.suite.remix.characterKind = .model
        store.suite.remix.modelId = id
    }

    // MARK: The video

    private var source: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("Video").font(t.scale.label.font).foregroundStyle(t.roles.ink)
            if let c = store.clip {
                HStack(spacing: Space.s2) {
                    Text(c.name).font(t.body(12.5)).foregroundStyle(t.roles.ink).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: Space.s2)
                    Text(Take.clock(c.durationSec)).font(t.body(12.5)).foregroundStyle(t.roles.ink2).fixedSize()
                }
            } else {
                Text("Add the video you want to change. Then switch on what should change.")
                    .font(t.body(12.5)).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Space.s2) {
                Button(store.clip == nil ? "Upload…" : "Replace…") { store.pickClip() }
                Button("Paste link…") { store.openLinkImport(.swap) }
                Button("Library…") { libraryOpen = true }
                    .popover(isPresented: $libraryOpen, arrowEdge: .bottom) {
                        NewSwapLibraryPicker { libraryOpen = false }
                            .environment(store)
                            .environment(\.theme, PickerTheme.dark)
                            .environment(\.colorScheme, .dark)
                    }
            }
            .controlSize(.small)
        }
    }

    // MARK: The trimmer

    /// Shown when the clip is longer than the model takes, or a part is already picked. The price follows the part.
    @ViewBuilder private func trimmer(_ c: Clip) -> some View {
        let est = store.suite.remixEstimate?.remix
        let row = store.suite.remixModels?.models.first { d.engineModel == nil ? $0.auto : $0.model == d.engineModel }
        let maxS = est?.trim.maxSeconds ?? row?.limits.maxSeconds
        let minS = est?.trim.minSeconds ?? row?.limits.minSeconds ?? 1
        if let maxS, c.durationSec > maxS + 0.05 || d.range != nil {
            let r = d.range ?? RemixRange(from: 0, to: min(c.durationSec, maxS))
            let needed = c.durationSec > maxS + 0.05
            VStack(alignment: .leading, spacing: Space.s2) {
                Text(needed ? "Pick the part to use: this model takes up to \(Pricing.trimNum(maxS)) s" : "Part of the clip used")
                    .font(t.scale.label.font).foregroundStyle(needed && d.range == nil ? t.warn : t.roles.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(Take.clock(r.from))–\(Take.clock(r.to)) of \(Take.clock(c.durationSec)), \(Pricing.trimNum(r.seconds)) s")
                    .font(t.body(12)).foregroundStyle(t.roles.ink2)
                let startMax = max(0, c.durationSec - minS)
                if startMax > 0.1 {
                    LabeledContent("Start") {
                        Slider(value: Binding(get: { r.from }, set: { v in store.setRemixRange(from: v, to: v + min(r.seconds, maxS)) }), in: 0...startMax)
                    }
                    .font(t.body(12))
                }
                let lenMax = min(maxS, c.durationSec - r.from)
                let lenMin = min(minS, lenMax)
                if lenMax - lenMin > 0.1 {
                    LabeledContent("Length") {
                        Slider(value: Binding(get: { min(max(r.seconds, lenMin), lenMax) }, set: { v in store.setRemixRange(from: r.from, to: r.from + v) }), in: lenMin...lenMax)
                    }
                    .font(t.body(12))
                }
                if needed && d.range == nil {
                    Button("Use \(Take.clock(r.from))–\(Take.clock(r.to))") { store.setRemixRange(from: r.from, to: r.to) }.controlSize(.small)
                } else if !needed {
                    Button("Use the whole clip") { store.suite.remix.range = nil }.controlSize(.small)
                }
            }
        }
    }

    // MARK: Toggles

    /// One change (approved mockup): its name and a state line on the left, the switch on the right; when on, its one
    /// field under it.
    @ViewBuilder private func toggleRow<F: View>(_ title: String, isOn: Binding<Bool>, state: String, help: String, @ViewBuilder field: () -> F) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(alignment: .center, spacing: Space.s3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(t.scale.label.font).foregroundStyle(t.roles.ink)
                    Text(isOn.wrappedValue ? state : "Kept from the clip").font(t.scale.caption.font).foregroundStyle(t.roles.ink2).lineLimit(1)
                }
                Spacer(minLength: Space.s2)
                Toggle(title, isOn: isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .help(help)
            if isOn.wrappedValue { field().padding(.bottom, Space.s1) }
        }
    }

    /// A text field on the field tone (the mockup's fields), 1–3 lines.
    private func wordsField(_ placeholder: String, _ text: Binding<String>) -> some View {
        TextField(placeholder, text: text, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...3)
            .font(t.scale.body.font)
            .foregroundStyle(t.roles.ink)
            .padding(.horizontal, Space.s3).padding(.vertical, Space.s2)
            .frame(minHeight: 36)
            .background(RoundedRectangle(cornerRadius: t.radii.control).fill(t.roles.field))
    }

    @ViewBuilder private var backgroundField: some View {
        Picker("Background", selection: bind(\.backgroundMode)) {
            ForEach(RemixBackgroundMode.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        if d.backgroundMode == .describe {
            wordsField("A rooftop at golden hour, city lights behind", bind(\.backgroundWords))
        } else {
            HStack(spacing: Space.s2) {
                Menu(d.backgroundImage == nil ? "Pick a picture" : (d.backgroundName ?? "New background")) {
                    ForEach(store.suite.locations) { loc in Button(loc.name) { store.pickRemixLocation(loc) } }
                    if !store.suite.locations.isEmpty { Divider() }
                    Button("Upload a picture…") { store.pickRemixPhoto(.background) }
                }
                .fixedSize()
                if d.backgroundImage != nil {
                    Button { store.suite.remix.backgroundImage = nil; store.suite.remix.backgroundName = nil } label: { Ph("xmark", 11) }
                        .buttonStyle(.plain).help("Remove the picture").accessibilityLabel("Remove the background picture")
                }
            }
            .controlSize(.small)
        }
    }

    /// Whose outfits "Her outfit" lists: her when Character is her, else the one picked here (or the first model).
    private var outfitOwnerId: String? {
        if d.characterOn && d.characterKind == .model, let m = d.modelId { return m }
        return outfitOwner ?? d.outfitId.flatMap { id in store.outfits.first { $0.id == id }?.modelId } ?? store.suiteCharacters.first?.id
    }

    @ViewBuilder private var outfitField: some View {
        Picker("Outfit", selection: bind(\.outfitKind)) {
            ForEach(RemixOutfitKind.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        switch d.outfitKind {
        case .outfit:
            let owner = outfitOwnerId.flatMap { store.character($0) }
            let list = store.outfits(for: owner)
            HStack(spacing: Space.s2) {
                if !(d.characterOn && d.characterKind == .model) {
                    Menu(owner?.shortName ?? "Whose") {
                        ForEach(store.suiteCharacters) { m in Button(m.name) { outfitOwner = m.id; store.suite.remix.outfitId = nil; characterFrom(m.id) } }
                    }
                    .fixedSize()
                }
                Menu(list.first { $0.id == d.outfitId }?.name ?? (list.isEmpty ? "No outfits yet" : "Pick an outfit")) {
                    ForEach(list) { o in Button(o.name) { store.suite.remix.outfitId = o.id; characterFrom(o.modelId) } }
                }
                .fixedSize()
                .disabled(list.isEmpty)
            }
            .controlSize(.small)
            Text("Sends the outfit’s pictures: its body angles and close-ups.").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                .fixedSize(horizontal: false, vertical: true)
        case .product:
            Button(d.productImage == nil ? "Upload the product photo…" : (d.productName ?? "Product photo")) { store.pickRemixPhoto(.product) }
                .controlSize(.small)
        case .words:
            wordsField("A black linen two-piece", bind(\.outfitWords))
        }
    }

    /// Her (the default): her chip with her face, her name, where her look comes from and Change; a link to a face swap
    /// instead. A face swap: the photo and the consent line, and a link back to her.
    @ViewBuilder private var characterField: some View {
        if d.characterKind == .model {
            let her = d.modelId.flatMap { store.character($0) }
            HStack(spacing: Space.s3) {
                MuseImage(ref: her?.cover)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: t.radii.chip))
                VStack(alignment: .leading, spacing: 2) {
                    Text(her?.name ?? "Pick her").font(t.scale.label.font).foregroundStyle(t.roles.ink).lineLimit(1)
                    Text("Face and figure from her pictures").font(t.scale.caption.font).foregroundStyle(t.roles.ink2).lineLimit(1)
                }
                Spacer(minLength: Space.s2)
                Button(her == nil ? "Pick" : "Change") { pickHer = true }
                    .buttonStyle(.plain).font(t.scale.label.font).foregroundStyle(t.roles.link).fixedSize()
                    .popover(isPresented: $pickHer, arrowEdge: .bottom) { herList }
            }
            .padding(.vertical, 6).padding(.leading, 6).padding(.trailing, Space.s3)
            .background(RoundedRectangle(cornerRadius: t.radii.control).fill(t.roles.field))
            Button("Face swap from a photo instead") { store.suite.remix.characterKind = .face }
                .buttonStyle(.plain).font(t.scale.label.font).foregroundStyle(t.roles.ink2).fixedSize()
                .help("Only the face changes; their hair, body and figure stay as in the video")
        } else {
            HStack(spacing: Space.s3) {
                MuseImage(ref: d.faceImage)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: t.radii.chip))
                    .opacity(d.faceImage == nil ? 0.4 : 1)
                Text(d.faceImage == nil ? "Add a face photo" : (d.faceName ?? "Face photo")).font(t.scale.label.font).foregroundStyle(t.roles.ink).lineLimit(1)
                Spacer(minLength: Space.s2)
                Button(d.faceImage == nil ? "Upload…" : "Change") { store.pickRemixPhoto(.face) }
                    .buttonStyle(.plain).font(t.scale.label.font).foregroundStyle(t.roles.link).fixedSize()
            }
            .padding(.vertical, 6).padding(.leading, 6).padding(.trailing, Space.s3)
            .background(RoundedRectangle(cornerRadius: t.radii.control).fill(t.roles.field))
            Text("Face swap: only the face changes. Their hair, body and figure stay as in the video. Use a photo of someone who agreed to this.")
                .font(t.scale.caption.font).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            Button("Use her instead") { store.suite.remix.characterKind = .model }
                .buttonStyle(.plain).font(t.scale.label.font).foregroundStyle(t.roles.ink2).fixedSize()
        }
    }

    /// Her characters, to pick who she is.
    private var herList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(store.suiteCharacters) { m in
                    Button {
                        store.suite.remix.modelId = m.id
                        pickHer = false
                    } label: {
                        HStack(spacing: Space.s2) {
                            MuseImage(ref: m.cover).frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: t.radii.chip))
                            Text(m.name).font(t.scale.label.font).foregroundStyle(t.roles.ink).lineLimit(1)
                            Spacer(minLength: 0)
                            if m.id == d.modelId { Ph("check", 13).frame(width: 16, height: 16).foregroundStyle(t.roles.accent) }
                        }
                        .padding(.horizontal, Space.s3).frame(height: 36).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, Space.s2)
        }
        .frame(width: 260).frame(maxHeight: 320)
        .environment(\.theme, t)
    }

    private var lookField: some View {
        wordsField("Night, neon signs, teal grade", bind(\.lookWords))
    }
}

/// Library: a finished take as the video (copied to a clip on the server).
struct NewSwapLibraryPicker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var onDone: () -> Void

    var body: some View {
        let list = store.extendableTakes
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick a video from your Library").font(t.body(13, .semibold))
            if list.isEmpty {
                Text("No finished videos yet. Upload one, or paste a link.").font(t.body(12)).foregroundStyle(t.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(88), spacing: 8), count: 4), alignment: .leading, spacing: 10) {
                        ForEach(list) { item in
                            Button {
                                store.useTakeAsRemixSource(item.take)
                                onDone()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    MuseImage(ref: item.take.thumb).frame(width: 88, height: 110).clipped()
                                        .overlay(Rectangle().strokeBorder(t.line, lineWidth: 1))
                                    Text(item.take.caption).font(t.body(10.5)).lineLimit(1).frame(width: 88, alignment: .leading)
                                    Text(item.source.seconds.map { Take.clock($0) } ?? "—").font(t.body(10)).foregroundStyle(t.muted)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.take.caption)
                        }
                    }
                    .padding(2)
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(14)
        .frame(width: 410, alignment: .leading)
        .foregroundStyle(t.ink)
        .background(t.surface)
    }
}

/// New Swap's model pill (owner bug 2026-11-12: "MiniMax H3 Higgsfield is not part of the models that come with New
/// Swap"): a popover with every video model, grouped (Auto picks · Edits the clip · Uses the clip as reference · From
/// frames · From words only) and scrollable, each with its price for this clip and one line: what MUSE does with it, a
/// recent refusal, or why it can't run. Only a model that can't run at all is greyed. The list reloads when it opens.
struct RemixModelPill: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var compact = false
    @State private var open = false

    var body: some View {
        let list = store.suite.remixModels
        let picked = store.suite.remix.engineModel
        let auto = list?.models.first { $0.auto }
        let current = picked.flatMap { p in list?.models.first { $0.model == p } }
        let title = current?.label ?? "Auto\(auto.map { " · \($0.label)" } ?? "")"
        Button { open.toggle() } label: {
            HStack(spacing: 4) {
                Text(compact ? (current?.label ?? "Auto") : title).font(t.body(12.5, .medium)).lineLimit(1)
                    .truncationMode(.tail).frame(maxWidth: compact ? 120 : 220, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(t.roles.ink2)
            }
            .foregroundStyle(t.roles.ink)
            .padding(.horizontal, 8).frame(height: 30).fixedSize()
            .background(RoundedRectangle(cornerRadius: t.radii.chip).fill(open ? t.roles.field : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Model: \(title)")
        .accessibilityLabel("Model: \(title)")
        .popover(isPresented: $open, arrowEdge: .top) {
            RemixModelList(onPick: { open = false })
                .environment(store).environment(\.theme, t)
                .task { await store.loadRemixModels() }
        }
    }
}

/// The list in New Swap's model popover.
struct RemixModelList: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var onPick: () -> Void

    var body: some View {
        let list = store.suite.remixModels
        let picked = store.suite.remix.engineModel
        VStack(alignment: .leading, spacing: 0) {
            Text("Model for New Swap").scaled(t.scale.label, t.roles.ink)
                .padding(.horizontal, Space.s4).padding(.top, Space.s3).padding(.bottom, Space.s2)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    autoRow(list, on: picked == nil)
                    ForEach(list?.grouped ?? [], id: \.group.id) { g in
                        Text(g.group.label).scaled(t.scale.caption, t.roles.ink2)
                            .padding(.horizontal, Space.s4).padding(.top, Space.s3).padding(.bottom, Space.s1)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(g.rows) { m in row(m, on: picked == m.model) }
                    }
                    if list == nil {
                        Text(store.suite.remix.anyOn ? "Loading models…" : "Turn on a change to see the models for it.")
                            .scaled(t.scale.caption, t.roles.ink2).padding(Space.s4)
                    }
                }
                .padding(.bottom, Space.s2)
            }
            .frame(maxHeight: 460)
        }
        .frame(width: 420, alignment: .leading)
    }

    private func autoRow(_ list: RemixModels?, on: Bool) -> some View {
        let auto = list?.models.first { $0.auto }
        return Button {
            store.suite.remix.engineModel = nil
            onPick()
        } label: {
            HStack(alignment: .top, spacing: Space.s2) {
                check(on)
                VStack(alignment: .leading, spacing: 2) {
                    Text(auto.map { "Auto (\($0.label))" } ?? "Auto").scaled(t.scale.body, t.roles.ink)
                    Text(list?.auto?.why ?? "MUSE picks the model for these changes").scaled(t.scale.caption, t.roles.ink2).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.s4).padding(.vertical, Space.s2)
            .background(on ? t.roles.field : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Use Auto")
    }

    private func row(_ m: RemixModels.Row, on: Bool) -> some View {
        Button {
            store.suite.remix.engineModel = m.model
            onPick()
        } label: {
            HStack(alignment: .top, spacing: Space.s2) {
                check(on)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Space.s2) {
                        Text(m.label).scaled(t.scale.body, m.pickable ? t.roles.ink : t.roles.ink2).lineLimit(1)
                        Spacer(minLength: Space.s2)
                        if let usd = m.price.usd { Text(Pricing.money(usd)).monospacedDigit().scaled(t.scale.caption, t.roles.ink2).fixedSize() }
                    }
                    Text(m.line).scaled(t.scale.caption, m.warning != nil && m.pickable ? t.roles.caution : t.roles.ink2).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Space.s4).padding(.vertical, Space.s2)
            .background(on ? t.roles.field.opacity(0.5) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!m.pickable)
        .help(m.line)
        .accessibilityLabel("\(m.label), \(m.line)")
    }

    private func check(_ on: Bool) -> some View {
        Ph("checkmark", 11).foregroundStyle(t.roles.accent).opacity(on ? 1 : 0).frame(width: 16, height: 20)
    }
}

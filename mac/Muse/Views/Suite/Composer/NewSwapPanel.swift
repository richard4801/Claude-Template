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

    private var d: RemixDraft { store.suite.remix }

    private func bind<V>(_ kp: WritableKeyPath<RemixDraft, V>) -> Binding<V> {
        Binding(get: { store.suite.remix[keyPath: kp] }, set: { store.suite.remix[keyPath: kp] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            source
            if let c = store.clip { trimmer(c) }
            VStack(alignment: .leading, spacing: Space.s3) {
                toggleRow("Background", isOn: bind(\.backgroundOn), help: "A new place: describe it, or a location or photo") { backgroundField }
                toggleRow("Outfit", isOn: bind(\.outfitOn), help: "New clothes: one of her outfits, a product photo, or words") { outfitField }
                toggleRow("Character", isOn: bind(\.characterOn), help: "Who the person becomes: her, or a face swap from a photo") { characterField }
                toggleRow("Look & light", isOn: bind(\.lookOn), help: "Time of day, light and colour grade") { lookField }
            }
            Text(d.keptLine).font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if d.engineModel == nil, let why = store.suite.remixEstimate?.remix?.why ?? store.suite.remixModels?.auto?.why {
                Text("Auto: \(why)").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    @ViewBuilder private func toggleRow<F: View>(_ title: String, isOn: Binding<Bool>, help: String, @ViewBuilder field: () -> F) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Toggle(isOn: isOn) {
                Text(title).font(t.scale.label.font).foregroundStyle(t.roles.ink)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(help)
            if isOn.wrappedValue { field() }
        }
    }

    @ViewBuilder private var backgroundField: some View {
        Picker("Background", selection: bind(\.backgroundMode)) {
            ForEach(RemixBackgroundMode.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        if d.backgroundMode == .describe {
            TextField("A rooftop at golden hour, city lights behind", text: bind(\.backgroundWords), axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...3).font(t.body(12.5))
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
                        ForEach(store.suiteCharacters) { m in Button(m.name) { outfitOwner = m.id; store.suite.remix.outfitId = nil } }
                    }
                    .fixedSize()
                }
                Menu(list.first { $0.id == d.outfitId }?.name ?? (list.isEmpty ? "No outfits yet" : "Pick an outfit")) {
                    ForEach(list) { o in Button(o.name) { store.suite.remix.outfitId = o.id } }
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
            TextField("A black linen two-piece", text: bind(\.outfitWords), axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...3).font(t.body(12.5))
        }
    }

    @ViewBuilder private var characterField: some View {
        Picker("Character", selection: bind(\.characterKind)) {
            ForEach(RemixCharacterKind.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        if d.characterKind == .model {
            Menu(d.modelId.flatMap { store.character($0)?.name } ?? "Pick her") {
                ForEach(store.suiteCharacters) { m in Button(m.name) { store.suite.remix.modelId = m.id } }
            }
            .fixedSize().controlSize(.small)
            Text("Her face and figure come only from her images. The clip gives only the motion and facial gestures.")
                .font(t.scale.caption.font).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
        } else {
            Button(d.faceImage == nil ? "Add a face photo…" : (d.faceName ?? "Face photo")) { store.pickRemixPhoto(.face) }
                .controlSize(.small)
            Text("Face swap: only the face changes. Their hair, body and figure stay as in the video. Use a photo of someone who agreed to this.")
                .font(t.scale.caption.font).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lookField: some View {
        TextField("Night, neon signs, teal grade", text: bind(\.lookWords), axis: .vertical)
            .textFieldStyle(.roundedBorder).lineLimit(1...3).font(t.body(12.5))
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

/// New Swap's model pill: Auto (with its pick) first, then every video model (owner 2026-11-12: every model on every
/// mode), each with its limits and its price for this clip; an adapted one says what MUSE does with it. Only a model
/// that can't run at all (its provider isn't set up) is greyed, with the reason.
struct RemixModelPill: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var compact = false

    var body: some View {
        let list = store.suite.remixModels
        let picked = store.suite.remix.engineModel
        let auto = list?.models.first { $0.auto }
        let current = picked.flatMap { p in list?.models.first { $0.model == p } }
        let title = current?.label ?? "Auto\(auto.map { " · \($0.label)" } ?? "")"
        Menu {
            Button {
                store.suite.remix.engineModel = nil
            } label: {
                Text(auto.map { "Auto · \($0.label)" } ?? "Auto")
                if let w = list?.auto?.why { Text(w) }
            }
            Divider()
            ForEach(list?.models ?? []) { m in
                Button {
                    store.suite.remix.engineModel = m.model
                } label: {
                    Text("\(m.label)\(m.price.usd.map { " · \(Pricing.money($0))" } ?? "")")
                    Text(m.adaptedLine ?? m.detail) // an adapted model says exactly what MUSE does with it
                }
                .disabled(!m.pickable)
            }
        } label: {
            HStack(spacing: 6) {
                Ph("cpu", 13)
                if !compact { Text(title).font(t.body(12.5, .medium)).lineLimit(1).fixedSize() }
            }
            .foregroundStyle(t.roles.ink)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Model: \(title)")
        .accessibilityLabel("Model: \(title)")
    }
}

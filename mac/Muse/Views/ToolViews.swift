import MuseCore
import SwiftUI

// Model tools (plans/api.md "Model tools"): the owner's Image models and catalog, Enhance, Dress up, review and apply, sheet
// versions and archived models. Members never see a provider or model name here: they get "Option A" / "Option B".

/// A centred modal card over a dimmed window, like the outfit sheet.
struct ModalCard<Content: View>: View {
    @Environment(\.theme) private var t
    var width: CGFloat = 820
    var close: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.38).onTapGesture { withAnimation { close() } }
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) { content() }
                    .padding(Space.s6)
            }
            .frame(width: width)
            .frame(maxHeight: 760)
            .background(RoundedRectangle(cornerRadius: t.radii.container, style: .continuous).fill(t.roles.raised))
            .clipShape(RoundedRectangle(cornerRadius: t.radii.container, style: .continuous))
            .museFloat(t)
            .padding(30)
        }
    }
}

struct ModalHeader: View {
    @Environment(\.theme) private var t
    var eyebrow: String
    var title: String
    var close: () -> Void

    var body: some View {
        // Sheet title (`title` step, sentence case); the old eyebrow is a quiet line under it.
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaled(t.scale.title, t.roles.ink).accessibilityAddTraits(.isHeader)
                if !eyebrow.isEmpty { Text(eyebrow).scaled(t.scale.caption, t.roles.ink2) }
            }
            Spacer()
            RIconButton(systemName: "xmark", help: "Close") { withAnimation { close() } }
                .keyboardShortcut(.cancelAction)
        }
    }
}

// MARK: Owner: per-run model chooser and Settings → Engines → Image models

/// The owner's small "Model" chooser on Shoot, Enhance and Dress up. Callers show it to the owner only.
struct ModelChooser: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var step: ImageStep
    var target: CatalogTarget
    var label: String = "Model"

    var body: some View {
        let o = store.modelOverride(step, target: target)
        HStack(spacing: 8) {
            Image(systemName: "cpu").font(.system(size: 11)).foregroundStyle(t.muted)
            Text(label).font(t.body(12)).foregroundStyle(t.muted)
            Button { store.openCatalog(step, target: target) } label: {
                HStack(spacing: 4) {
                    Text(o == nil ? "Default · \(store.modelName(for: step, override: nil))" : store.modelName(for: step, override: o))
                        .font(t.mono(11.5)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(t.ink)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: t.controlRadius).fill(t.surface2))
            }
            .buttonStyle(.plain)
            .help("Owner only: pick the model for this run")
            if o != nil { LinkText("Default") { store.clearOverride(step, target: target) } }
        }
    }
}

struct ImageModelsSection: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        SectionTitle("Image models")
        Text("Every image step runs on a Replicate model. Pick any public model for a step; members only see the photos and their price.")
            .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.bottom, Space.s3)
        if store.stepModels.isEmpty {
            InlineNotice("This server doesn't offer model choice yet.")
        } else {
            ForEach(store.stepModels, id: \.id) { s in
                SettingRow(s.label, hint: hint(s)) {
                    HStack(spacing: Space.s2) {
                        if !s.compatible { StateTag("Check", .caution) }
                        if !s.isDefault, let step = s.imageStep { RButton("Use default", kind: .plain, small: true) { store.resetImageModel(step) } }
                        if let step = s.imageStep { RButton("Change", small: true) { store.openCatalog(step, target: .settings) } }
                    }
                }
            }
        }
    }

    /// The model, its price and anything to check, as short sentences.
    private func hint(_ s: StepModel) -> String {
        let lines = [s.model + (s.isDefault ? " (default)" : ""), s.priceLine, s.compatible ? (s.warnings.first ?? "") : "Not compatible: " + s.reasons.joined(separator: ", "),
                     s.extra.isEmpty ? "" : "\(s.extra.count) advanced input\(s.extra.count == 1 ? "" : "s")"]
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// The model catalog: search, collections, paste owner/model, then the advanced view with price, compatibility and extra inputs.
struct ModelCatalogSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        if let d = store.catalog {
            ModalCard(width: 880, close: { store.catalog = nil }) {
                ModalHeader(eyebrow: d.target == .settings ? "Image models" : "This run only", title: d.step.label) { store.catalog = nil }
                Muted(d.step.usedBy)
                if let detail = d.detail {
                    detailView(d, detail)
                } else {
                    listView(d)
                }
                if let e = d.error { Note(icon: "exclamationmark.triangle", warn: true, e) }
            }
        }
    }

    @ViewBuilder private func listView(_ d: CatalogDraft) -> some View {
        HStack(spacing: 10) {
            TextField("Search Replicate models", text: Binding(get: { store.catalog?.query ?? "" }, set: { store.catalog?.query = $0 }))
                .fieldChrome()
                .onSubmit { store.searchCatalog() }
            MButton("Search", icon: "magnifyingglass") { store.searchCatalog() }
        }
        if !d.collections.isEmpty {
            FlowLayout(spacing: 8) {
                Chip("For this step", on: d.collection == nil) {
                    store.catalog?.collection = nil
                    store.catalog?.query = ""
                    store.searchCatalog()
                }
                ForEach(d.collections) { c in
                    Chip(c.name, on: d.collection == c.slug) {
                        store.catalog?.collection = c.slug
                        store.catalog?.query = ""
                        store.searchCatalog()
                    }
                }
            }
        }
        HStack(spacing: 10) {
            TextField("Or paste owner/model, e.g. black-forest-labs/flux-2-pro", text: Binding(get: { store.catalog?.paste ?? "" }, set: { store.catalog?.paste = $0 }))
                .fieldChrome()
                .font(t.mono(13))
                .onSubmit { store.openCatalogModel(d.paste) }
            MButton("Open", off: d.paste.trimmingCharacters(in: .whitespaces).isEmpty) { store.openCatalogModel(d.paste) }
        }
        if d.loading || d.detailLoading {
            ForEach(0..<3, id: \.self) { _ in Shimmer(ratio: 8) }
        } else if d.models.isEmpty {
            Note(icon: "magnifyingglass", "No models found. Try another search, or paste owner/model.")
        } else {
            ListBox {
                ForEach(Array(d.models.enumerated()), id: \.element.id) { i, m in
                    Button { store.openCatalogModel(m.id) } label: {
                        ListRow(title: m.id, hint: [m.description, "\(m.runsLabel) · \(m.priceLine)"].filter { !$0.isEmpty }.joined(separator: "\n"), last: i == d.models.count - 1) {
                            HStack(spacing: 6) {
                                if m.official { Pill("Official") }
                                compat(m)
                                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(t.muted)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private func compat(_ m: CatalogModel) -> some View {
        switch m.compatible {
        case .some(true): Pill(m.warnings.isEmpty ? "Compatible" : "Compatible · note", m.warnings.isEmpty ? .good : .neutral)
        case .some(false): Pill("Not compatible", .warn)
        case .none: Pill("Not checked")
        }
    }

    @ViewBuilder private func detailView(_ d: CatalogDraft, _ detail: ModelDetail) -> some View {
        let m = detail.model
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(m.id).font(t.mono(15, .medium))
                if !m.description.isEmpty { Muted(m.description, size: 13) }
                Muted("\(m.runsLabel)\(m.official ? " · official" : "")\(detail.version.isEmpty ? "" : " · version \(detail.version.prefix(12))")")
            }
            Spacer()
            LinkText("Back to the list") { store.catalog?.detail = nil }
        }
        ListBox {
            ListRow(icon: "dollarsign.circle", title: "Price", hint: m.price?.isPerSecond == true ? "Community models are billed by time; the estimate uses the typical run." : nil) {
                Text(m.priceLine).font(t.mono(12)).multilineTextAlignment(.trailing)
            }
            ListRow(icon: m.compatible == false ? "xmark.octagon" : "checkmark.seal", title: m.compatibilityLabel,
                    hint: m.warnings.count > 1 ? m.warnings.joined(separator: " · ") : nil) { EmptyView() }
            ListRow(icon: "arrow.left.arrow.right", title: "How MUSE fills it", hint: detail.mapping.summary.isEmpty ? "Nothing mapped" : detail.mapping.summary, last: true) { EmptyView() }
        }
        if d.target == .settings {
            let editable = detail.editableInputs
            if !editable.isEmpty {
                H2("Advanced inputs")
                Muted("Sent on every run of this step and win over MUSE's values. Leave blank to use the model's default. The safety checker can't be changed.")
                ListBox {
                    ForEach(Array(editable.enumerated()), id: \.element.id) { i, f in
                        ListRow(title: f.name + (f.required ? " *" : ""), hint: inputHint(f), last: i == editable.count - 1) {
                            TextField(f.defaultValue?.description ?? f.type, text: Binding(get: { store.catalog?.extraText[f.name] ?? "" },
                                                                                          set: { store.catalog?.extraText[f.name] = $0 }))
                                .fieldChrome()
                                .font(t.mono(12))
                                .frame(width: 220)
                        }
                    }
                }
            }
        }
        HStack {
            Spacer()
            MButton(d.target == .settings ? "Use for \(d.step.label)" : "Use for this run", kind: .primary, off: m.compatible == false || d.saving) {
                store.useCatalogModel()
            }
        }
    }

    private func inputHint(_ f: InputField) -> String {
        var parts = [f.type]
        if let o = f.options, !o.isEmpty { parts.append(o.map(\.description).joined(separator: " / ")) }
        if let lo = f.minimum, let hi = f.maximum { parts.append("\(JSONValue.number(lo).description)–\(JSONValue.number(hi).description)") }
        if let d = f.description, !d.isEmpty { parts.append(d) }
        return parts.joined(separator: " · ")
    }
}

// MARK: Review (Enhance and Dress up)

/// Drag the handle to compare: "before" on the left, "after" on the right.
struct BeforeAfterSlider: View {
    @Environment(\.theme) private var t
    var before: ImageRef?
    var after: ImageRef?
    @State private var split: CGFloat = 0.5

    var body: some View {
        Color.clear
            .aspectRatio(0.75, contentMode: .fit)
            .overlay(GeometryReader { g in
                ZStack(alignment: .leading) {
                    MuseImage(ref: after)
                    MuseImage(ref: before)
                        .mask(alignment: .leading) { Rectangle().frame(width: g.size.width * split) }
                    Rectangle().fill(.white).frame(width: 2).offset(x: g.size.width * split - 1)
                    Circle().fill(.white).frame(width: 20, height: 20)
                        .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.black))
                        .offset(x: g.size.width * split - 10)
                }
                .overlay(alignment: .topLeading) { Pill("Before").padding(6) }
                .overlay(alignment: .topTrailing) { Pill("After", .acc).padding(6) }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in split = min(1, max(0, v.location.x / max(1, g.size.width))) })
            })
            .clipShape(RoundedRectangle(cornerRadius: t.imageRadius))
    }
}

struct ToolReviewView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var run: ToolRun

    var body: some View {
        if run.isRunning {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(run.phase.isEmpty ? "Starting" : run.phase).font(t.body(14, .semibold))
                    Spacer()
                    Muted("about \(Pricing.money(run.estimate)) held")
                }
                ProgressLine(value: run.progress / 100)
                Muted("You can close this. MUSE tells you when it's ready to review.")
            }
            .card()
        } else if run.state == "failed" {
            Note(icon: "exclamationmark.triangle", warn: true, run.error ?? MemberText.wentWrong)
        }
        if run.isReview && run.showsBoth {
            HStack(spacing: 10) {
                Muted("Whole set:")
                MButton("Keep all Option A", size: .small) { store.pickWholeSet(run, "a") }
                MButton("Keep all Option B", size: .small) { store.pickWholeSet(run, "b") }
                Spacer()
            }
        }
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: run.showsBoth ? 2 : 3), alignment: .leading, spacing: 16) {
            ForEach(run.orderedItems) { item in tile(item) }
        }
    }

    @ViewBuilder private func tile(_ item: ToolItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.label).font(t.body(13, .bold))
                Spacer()
                if item.isKept { Pill(run.showsBoth ? "Keep \(item.pick == "b" ? "B" : "A")" : "Keep", .good) }
                if item.isRejected { Pill("Rejected", .warn) }
            }
            switch item.state {
            case "running", "waiting":
                if run.showsBoth { HStack(spacing: 6) { Shimmer(); Shimmer(); Shimmer() } } else { Shimmer() }
            case "failed":
                Note(icon: "exclamationmark.triangle", warn: true, item.error ?? MemberText.wentWrong)
            default:
                if run.showsBoth {
                    HStack(spacing: 6) {
                        labelled("Before", Media(ref: item.before, ratio: 0.75))
                        labelled("Option A", Media(ref: item.results.a, ratio: 0.75, selectedColor: item.isKept && item.pick == "a" ? t.accent : nil))
                        labelled("Option B", Media(ref: item.results.b, ratio: 0.75, selectedColor: item.isKept && item.pick == "b" ? t.accent : nil))
                    }
                } else {
                    BeforeAfterSlider(before: item.before, after: item.after)
                }
            }
            if run.isReview && item.isDone {
                FlowLayout(spacing: 6) {
                    if run.showsBoth {
                        if item.results.a != nil { Chip("Keep A", on: item.isKept && item.pick == "a") { store.decide(run, item, keep: true, pick: "a") } }
                        if item.results.b != nil { Chip("Keep B", on: item.isKept && item.pick == "b") { store.decide(run, item, keep: true, pick: "b") } }
                    } else {
                        Chip("Keep", on: item.isKept, icon: "checkmark") { store.decide(run, item, keep: true) }
                    }
                    Chip("Reject", on: item.isRejected, icon: "xmark") { store.decide(run, item, keep: false) }
                    if run.showsBoth {
                        Menu("Retry") {
                            Button("Retry Option A") { store.retryItem(run, item, engine: "a") }
                            Button("Retry Option B") { store.retryItem(run, item, engine: "b") }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    } else {
                        Chip("Retry", icon: "arrow.clockwise") { store.retryItem(run, item) }
                    }
                }
            }
        }
        .padding(10)
        .surface()
    }

    private func labelled(_ text: String, _ media: some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            media
            Text(text).font(t.body(11)).foregroundStyle(t.muted)
        }
    }
}

// MARK: Enhance

struct EnhanceSheetView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        if let d = store.enhanceDraft {
            let model = store.models.first { $0.id == d.modelId }
            let f = store.toolsFeatures?.enhance ?? EnhanceFeatures()
            ModalCard(close: { store.enhanceDraft = nil }) {
                ModalHeader(eyebrow: model?.shortName ?? "Model", title: "Enhance") { store.enhanceDraft = nil }
                if let id = d.runId, let run = store.toolRuns[id] {
                    Muted("Check each image. Kept images replace their sheet slots; the sheet as it is now is kept as a previous version you can restore.")
                    ToolReviewView(run: run)
                    HStack {
                        MButton("Discard", icon: "trash") { store.discardRun(run) }
                        Spacer()
                        if run.isReview {
                            MButton("Use \(run.keptCount) kept image\(run.keptCount == 1 ? "" : "s")", kind: .primary, off: !run.canApply) { store.applyRun(run) }
                        }
                    }
                } else {
                    Muted("Makes the character sheet look like real photos: natural skin, true colour, then sharper and bigger. Every image gets the same settings.")
                    Field("Realism") {
                        Seg(f.realism.map { ($0.id, $0.label) }, selection: Binding(get: { d.realism }, set: { store.enhanceDraft?.realism = $0 })) { _ in store.refreshEnhanceEstimate() }
                            .frame(maxWidth: 440)
                    }
                    Field("Upscale") {
                        Seg(f.upscale.map { ($0.id, $0.label) }, selection: Binding(get: { d.upscale }, set: { store.enhanceDraft?.upscale = $0 })) { _ in store.refreshEnhanceEstimate() }
                            .frame(maxWidth: 330)
                    }
                    if store.isOwner {
                        VStack(alignment: .leading, spacing: 6) {
                            ModelChooser(step: .realism, target: .enhance, label: "Realism model")
                            ModelChooser(step: .upscale, target: .enhance, label: "Upscale model")
                        }
                    }
                    if let m = model {
                        HStack(spacing: 8) {
                            ForEach(SheetAngle.faceGroup + SheetAngle.bodyGroup) { a in
                                if let img = m.slot(a.rawValue)?.image { Media(ref: img, ratio: 0.75).frame(width: 70) }
                            }
                        }
                    }
                    HStack {
                        if d.realism == "off" && d.upscale == "off" {
                            Note(icon: "exclamationmark.triangle", warn: true, "Turn on realism or upscale")
                        } else {
                            Muted(d.estimating ? "Working out the price…" : d.estimate.map { "Total: \($0.label)" } ?? "")
                        }
                        Spacer()
                        MButton(d.starting ? "Starting…" : "Enhance" + (d.estimate.map { " · \(PhotoPricing.label($0.estimate))" } ?? ""), icon: "wand.and.stars", kind: .primary,
                                off: d.starting || (d.realism == "off" && d.upscale == "off")) { store.startEnhance() }
                    }
                }
            }
        }
    }
}

// MARK: Dress up

struct DressUpSheetView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var targeted = false
    @State private var outfitName = ""

    var body: some View {
        if let d = store.dressUpDraft {
            let model = store.models.first { $0.id == d.modelId }
            let f = store.toolsFeatures?.dressUp ?? DressUpFeatures()
            ModalCard(width: 900, close: { store.dressUpDraft = nil }) {
                ModalHeader(eyebrow: model?.shortName ?? "Model", title: "Dress up") { store.dressUpDraft = nil }
                if let id = d.runId, let run = store.toolRuns[id] {
                    Muted(run.showsBoth ? "Keep Option A or B for each photo, or the whole set. The original sheet isn't changed." : "Keep or reject each photo. The original sheet isn't changed.")
                    ToolReviewView(run: run)
                    HStack(spacing: 10) {
                        MButton("Discard", icon: "trash") { store.discardRun(run) }
                        Spacer()
                        if run.isReview {
                            TextField("Outfit name", text: $outfitName).fieldChrome().frame(width: 220)
                            MButton("Save as new outfit · \(run.keptCount)", kind: .primary, off: !run.canApply) {
                                store.applyRun(run, name: outfitName.isEmpty ? run.options.name : outfitName)
                            }
                        }
                    }
                    .onAppear { if outfitName.isEmpty { outfitName = run.options.name ?? d.name } }
                } else {
                    Muted("Drop one outfit-sheet photo (the clothes and accessories). One button dresses all 7 character-sheet images: full-body shots get the whole outfit, face close-ups get what shows (earrings, necklace, glasses, hat) and the neckline. It's saved as a new outfit; the original sheet stays as it is.")
                    dropZone(d)
                    Field("Outfit name") {
                        TextField("e.g. Denim day", text: Binding(get: { store.dressUpDraft?.name ?? "" }, set: { store.dressUpDraft?.name = $0 })).fieldChrome()
                    }
                    Field("Options") {
                        HStack(spacing: 10) {
                            ForEach(f.options) { o in
                                ChoiceTile(title: store.dressUpLabel(o), detail: o.detail ?? "", on: d.engine == o.id) {
                                    store.dressUpDraft?.engine = o.id
                                    store.refreshDressUpEstimate()
                                }
                            }
                        }
                    }
                    if store.isOwner {
                        VStack(alignment: .leading, spacing: 6) {
                            if d.engine != "b" { ModelChooser(step: .dressA, target: .dressUp, label: "Option A model") }
                            if d.engine != "a" { ModelChooser(step: .dressB, target: .dressUp, label: "Option B model") }
                        }
                    }
                    HStack {
                        Muted(d.estimating ? "Working out the price…" : d.estimate.map { "Price: \($0.label)" } ?? "")
                        Spacer()
                        MButton(d.starting ? "Starting…" : "Dress up" + (d.estimate.map { " · \(PhotoPricing.label($0.estimate))" } ?? ""), icon: "tshirt", kind: .primary,
                                off: d.starting || d.image == nil) { store.startDressUp() }
                    }
                }
            }
        }
    }

    private func dropZone(_ d: DressUpDraft) -> some View {
        Button {
            if let u = MediaImport.pick(MediaImport.imageTypes, multiple: false, prompt: "Use").first { store.setDressUpImage(u) }
        } label: {
            HStack(spacing: 14) {
                if let u = d.image {
                    Media(ref: ImageRef(url: u.absoluteString), ratio: 0.75).frame(width: 64)
                } else {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 20))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.image?.lastPathComponent ?? "Drop an outfit photo").font(t.body(14, .bold)).lineLimit(1)
                    Muted("One image: the outfit with its accessories, on a person or laid flat.")
                }
                Spacer()
            }
            .foregroundStyle(t.ink)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: t.cardRadius).fill(targeted ? t.accent.opacity(0.08) : t.surface))
            .overlay(RoundedRectangle(cornerRadius: t.cardRadius).strokeBorder(targeted ? t.accent : t.line, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first(where: MediaImport.isImage) else { return false }
            store.setDressUpImage(u)
            return true
        } isTargeted: { targeted = $0 }
    }
}

/// A selectable card with a title and a one-line detail.
struct ChoiceTile: View {
    @Environment(\.theme) private var t
    var title: String
    var detail: String
    var on: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(t.body(14, .bold)).lineLimit(1)
                Text(detail).font(t.body(12)).foregroundStyle(t.muted).lineLimit(2)
            }
            .foregroundStyle(t.ink)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: t.cardRadius).fill(on ? t.accent.opacity(0.1) : t.surface))
            .overlay(RoundedRectangle(cornerRadius: t.cardRadius).strokeBorder(on ? t.accent : t.line, lineWidth: on ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Sheet versions

struct SheetVersionsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        if let d = store.versionsDraft {
            ModalCard(close: { store.versionsDraft = nil }) {
                ModalHeader(eyebrow: store.models.first { $0.id == d.modelId }?.shortName ?? "Model", title: "Previous versions") { store.versionsDraft = nil }
                if d.loading {
                    Shimmer(ratio: 6)
                } else if d.versions.isEmpty {
                    Note(icon: "clock.arrow.circlepath", "No previous versions yet. Enhance saves the sheet here before it changes anything.")
                } else {
                    Muted("Restoring saves the sheet as it is now as another version, so nothing is lost. The last 10 are kept.")
                    ForEach(d.versions) { v in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(v.reasonLabel).font(t.body(14, .bold))
                                Muted(Date(timeIntervalSince1970: Double(v.createdAt) / 1000).formatted(date: .abbreviated, time: .shortened))
                                Spacer()
                                MButton("Restore", icon: "arrow.uturn.backward", size: .small) { store.restoreVersion(v) }
                            }
                            HStack(spacing: 6) {
                                ForEach(SheetAngle.faceGroup + SheetAngle.bodyGroup) { a in
                                    Media(ref: v.slots.first { $0.key == a.rawValue }?.image, ratio: 0.75)
                                }
                            }
                        }
                        .padding(12)
                        .surface()
                    }
                }
            }
        }
    }
}

// MARK: Archived models (owner, Settings)

struct ArchivedModelsSection: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        SectionTitle("Archived models", top: 0)
        Text("Archived models are hidden from every list and picker. Their outfits, photos, renders and posts are kept. Restore one to use her again.")
            .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, Space.s3)
        if store.archivedModels.isEmpty {
            EmptyState("Nothing archived", "Archive a model from the ⋯ menu on her profile. She stays here until you restore her.")
        } else {
            ForEach(store.archivedModels) { m in
                SettingRow(m.name, hint: ScreenCopy.meta([m.niche, m.archivedAt.map { "Archived " + Date(timeIntervalSince1970: Double($0) / 1000).formatted(date: .abbreviated, time: .omitted) }], limit: 2)) {
                    RButton("Restore", small: true) { store.unarchiveModel(m) }
                }
            }
        }
        Color.clear.frame(height: 0).onAppear { store.loadArchived() }
    }
}

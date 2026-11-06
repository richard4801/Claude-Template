import MuseCore
import SwiftUI

// AI suite (workstream 1): the video composer page (plans/video-composer.md, C1, C5, C6). Recent takes on top, the
// composer (tool card, Auto chips, prompt with tokens, slot cards, bottom bar) and "Start from a preset" below. Picking a
// preset collapses the composer to who + shape + Generate, with "Edit settings". Pickers open over the page, always dark.

/// Re-price when anything that changes the request changes.
private struct ComposerPriceKey: Equatable {
    var draft: ComposerDraft
    var slots: InputSlots
    var swap: SwapDraft
    var clipId: String?
    var catalogLoaded: Bool
}

struct ComposerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let s = store.suite
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    RecentTakesRow().padding(.top, 20)
                    Spacer(minLength: 28)
                    ComposerCard().zIndex(2)
                    PresetsRow().padding(.top, 26).padding(.bottom, 30)
                }
                .frame(maxWidth: 960)
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity)
            }
            ComposerPickerHost()
            if s.browserOpen { ToolBrowser().transition(.opacity) }
        }
        .task(id: ComposerPriceKey(draft: s.composer, slots: s.composerSlots.slots, swap: s.swap, clipId: store.clip?.id, catalogLoaded: s.catalog != nil)) {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            switch s.composer.tool {
            case .shot, .talking, .ugc: if !store.isComingSoon(s.composer.tool) { await store.estimateShot() }
            case .swap, .recast: await store.estimateSwap()
            default: break
            }
        }
        .sheet(isPresented: Binding(get: { store.isOwner && s.showEngines }, set: { s.showEngines = $0 })) {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Done") { s.showEngines = false }.keyboardShortcut(.cancelAction).padding(12)
                }
                ScrollView { SuiteEnginesPanel(estimate: s.composer.tool == .shot ? s.estimate : s.swapEstimate).padding(20) }
            }
            .frame(minWidth: 560, minHeight: 520)
            .environment(store)
            .environment(\.theme, t)
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Button { store.openSuite(.hub) } label: {
                    Text("VIDEO SUITE").font(t.mono(11)).tracking(1.6).foregroundStyle(t.muted)
                }
                .buttonStyle(.plain)
                .help("Back to the Video suite")
                .accessibilityLabel("Back to the Video suite")
                Text(store.suite.composer.tool.title).font(t.isA ? Fonts.font("Instrument Serif", 44, .regular) : t.display(34))
            }
            Spacer(minLength: 12)
            SuiteTestBadge()
        }
        .padding(.top, 22)
    }
}

// MARK: Recent takes (C1)

struct RecentTakesRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SuiteSectionHead(title: "Recent takes") { LinkText("See all in Queue →") { store.go(.queue) } }
            let jobs = store.suiteRecentJobs
            if jobs.isEmpty {
                Muted("Your takes show up here as they render.").frame(height: 60, alignment: .topLeading)
            } else {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(jobs) { j in tile(j) }
                }
            }
        }
    }

    private func tile(_ j: Job) -> some View {
        let state = SuiteResultState.of(j)
        let take = store.takes(of: j).first
        return Button {
            if let take { store.openTake(take.id) } else { store.go(.queue) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                MuseImage(ref: take?.thumb ?? j.thumb)
                    .blur(radius: state == .ready ? 0 : 10)
                    .frame(width: 100, height: 178)
                    .clipped()
                    .overlay(overlay(state))
                Text("\(j.title.uppercased()) · T\(max(1, j.take))").font(t.mono(10)).lineLimit(1).frame(width: 100, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(j.title), \(label(state))")
    }

    private func label(_ s: SuiteResultState) -> String {
        switch s {
        case .ready: return "ready"
        case .rendering(let p, _): return "rendering \(p) percent"
        case .queued: return s.queueLine
        case .failed: return "failed"
        case .empty: return ""
        }
    }

    @ViewBuilder private func overlay(_ s: SuiteResultState) -> some View {
        switch s {
        case .ready:
            Ph("play.fill", 13).foregroundStyle(Color(hex: 0x141210))
                .frame(width: 36, height: 36).background(Circle().fill(Color.white.opacity(0.9)))
        case .rendering(let p, _): Text("\(p)%").font(t.isA ? Fonts.font("Instrument Serif", 30, .regular) : t.display(22)).foregroundStyle(.white)
        case .queued: Text(s.queueLine.uppercased()).font(t.mono(9)).foregroundStyle(.white).padding(4).background(Color.black.opacity(0.8))
        case .failed: Text("RETRY FREE").font(t.mono(9, .semibold)).foregroundStyle(.white).padding(4).background(t.rec)
        case .empty: EmptyView()
        }
    }
}

// MARK: Presets (the beginner path)

struct PresetsRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let presets = store.suite.camera.presets
        if !presets.isEmpty && store.suite.composer.tool == .shot {
            VStack(alignment: .leading, spacing: 10) {
                SuiteSectionHead(title: "Start from a preset") { LinkText("All \(presets.count) presets →") { store.suite.browserOpen = true } }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(presets) { p in PresetTile(preset: p, selected: store.suite.composer.collapsed == p.id) { store.applyPreset(p) } }
                    }
                    .padding(6)
                }
                .padding(-6)
            }
        }
    }
}

struct PresetTile: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var preset: SuitePreset
    var selected: Bool
    var width: CGFloat = 150
    var height: CGFloat = 96
    var action: () -> Void

    var body: some View {
        // No play badge: a preset tile is a still (nothing plays), and the badge was one more mark on every tile.
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                PreviewView(preview: PickerPreview(still: ComposerPresets.render(preset, store.suite.camera)))
                LinearGradient(colors: [.clear, Color(hex: 0x0A0908, alpha: 0.72)], startPoint: .center, endPoint: .bottom)
                Text(preset.label).font(Fonts.font("Instrument Serif", 22, .regular)).foregroundStyle(Color(hex: 0xF8F5EF)).lineLimit(1)
                    .minimumScaleFactor(0.7).padding(.leading, 10).padding(.bottom, 8)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: t.imageRadius))
            .overlay(RoundedRectangle(cornerRadius: t.imageRadius + 4).strokeBorder(selected ? t.ink : .clear, lineWidth: 2).padding(-4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(preset.description)
        .accessibilityLabel("\(preset.label) preset\(selected ? ", selected" : "")")
    }
}

// MARK: The composer card

struct ComposerCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    private var draft: ComposerDraft { store.suite.composer }

    var body: some View {
        VStack(spacing: 0) {
            ToolCardRow()
            Rectangle().fill(t.line).frame(height: 1)
            if let pid = draft.collapsed, draft.tool == .shot {
                CollapsedComposer(presetId: pid)
            } else if store.isComingSoon(draft.tool) {
                comingSoonBody
            } else {
                // Above its siblings so the prompt's suggestion list draws over the rig check and the bottom bar.
                fullBody.zIndex(1)
                RigCheckRow()
                Rectangle().fill(t.line).frame(height: 1)
                ComposerBottomBar()
            }
        }
        // Not clipped: the prompt's @ / # suggestion list drops below the prompt box and must float over the rest of the
        // card and the presets (zIndex above). Fill and border are one rounded shape behind the content, so the border's
        // corners aren't cut and it never crosses the list.
        .background {
            // A softer lift than before (radius 35, y 26, 12 %), and none in the dark theme where it couldn't be seen.
            RoundedRectangle(cornerRadius: t.cardRadius).fill(t.surface)
                .shadow(color: Color(hex: 0x281E0A, alpha: t.isDark ? 0 : 0.08), radius: 22, y: 12)
                .overlay(RoundedRectangle(cornerRadius: t.cardRadius).strokeBorder(t.line, lineWidth: 1))
        }
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !draft.tool.chips.isEmpty {
                // Wraps to a second line instead of scrolling: a hidden horizontal scroll cut the last chips at the edge.
                FlowLayout(spacing: 6) {
                    ForEach(draft.tool.chips, id: \.self) { c in SettingChip(chip: c) }
                }
            }
            HStack(alignment: .top, spacing: 16) {
                promptArea
                ComposerSlotRow()
            }
            if let note = store.suite.composerSlots.slots.note(store.composerInputs), draft.tool == .shot {
                Label(note, ph: "info.circle").font(t.body(11.5)).foregroundStyle(t.muted)
            }
            if let p = currentProblem {
                Label(p, ph: "exclamationmark.triangle").font(t.body(12, .semibold)).foregroundStyle(t.warn).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 16)
    }

    private var currentProblem: String? {
        switch draft.tool {
        case .swap, .recast:
            if store.clip == nil { return "Choose a clip first" }
            return store.suite.swapEstimate?.problem ?? store.suite.swapError
        default: return store.suite.estimate?.problem ?? store.suite.estimateError
        }
    }

    @ViewBuilder private var promptArea: some View {
        switch draft.tool {
        case .swap:
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(get: { store.suite.swap.promptOn }, set: { store.suite.swap.promptOn = $0 })) {
                    Text("Add a prompt").font(t.body(13))
                }
                .toggleStyle(.switch).controlSize(.small)
                if store.suite.swap.promptOn {
                    ComposerPromptBox(placeholder: draft.tool.promptPlaceholder, minHeight: 80)
                } else {
                    Text("Your character takes over the clip: its motion, camera, framing and cuts stay as they are.").font(t.body(14)).foregroundStyle(t.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        case .recast:
            VStack(alignment: .leading, spacing: 6) {
                Text("Same take, new cast").font(t.body(16, .semibold))
                Text("Open PEOPLE, click each face on the first frame and pick who replaces them (up to \(store.suite.catalog?.recastMaxPeople ?? 4) people). The motion, camera, framing and sound stay.")
                    .font(t.body(14)).foregroundStyle(t.muted).fixedSize(horizontal: false, vertical: true)
                if let lines = store.suite.swapEstimate?.cast {
                    ForEach(lines, id: \.self) { l in
                        Text("\(l.who.capitalized(with: nil)) → \(store.character(l.characterId)?.shortName ?? "")").font(t.body(12)).foregroundStyle(t.muted)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        default:
            ComposerPromptBox(placeholder: draft.tool.promptPlaceholder).frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var comingSoonBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The chips already work (UGC ad's Style has its format wheel), so the settings are ready when the tool is.
            if !draft.tool.chips.isEmpty {
                HStack(spacing: 6) {
                    ForEach(draft.tool.chips, id: \.self) { c in SettingChip(chip: c) }
                }
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Pill(SuiteText.comingSoon)
                    Text(draft.tool.mode.tileLine).font(t.body(15)).foregroundStyle(t.muted).fixedSize(horizontal: false, vertical: true)
                    Text("It will use the same composer: these slots, the chips and the price on Generate.").font(t.body(12.5)).foregroundStyle(t.muted)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                ComposerSlotRow().disabled(true).opacity(0.55)
            }
        }
        .padding(16)
    }
}

/// The tool card row: thumbnail, NAME · tagline, Change (the tool and preset browser).
struct ToolCardRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let d = store.suite.composer
        let preset = d.collapsed.flatMap { id in store.suite.camera.presets.first { $0.id == id } }
        HStack(spacing: 12) {
            HardwareImage(name: preset.flatMap { ComposerPresets.render($0, store.suite.camera) } ?? d.tool.render)
                .frame(width: 34, height: 42).clipped()
            Text((preset?.label ?? d.tool.title).uppercased()).font(t.mono(11, .medium)).tracking(1.5)
            Circle().fill(t.line).frame(width: 3, height: 3)
            Text(preset?.description ?? d.tool.tagline).font(t.body(13.5)).foregroundStyle(t.muted).lineLimit(1)
            Button { store.suite.browserOpen = true } label: {
                Label("Change", ph: "arrow.left.arrow.right").font(t.body(13, .semibold)).foregroundStyle(t.ink)
                    .padding(.horizontal, 12).frame(height: 30)
                    .overlay(RoundedRectangle(cornerRadius: t.controlRadius).strokeBorder(t.line, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)
            .help("Change the tool or start from a preset")
            Spacer(minLength: 8)
            if store.isComingSoon(d.tool) { SuiteTag(text: SuiteText.comingSoon) }
            if d.tool == .shot && d.collapsed == nil && !d.tokens.isEmpty {
                Button { store.addShotToStoryboard() } label: {
                    Ph("rectangle.split.3x1").frame(width: 28, height: 28).contentShape(Rectangle())
                }
                    .buttonStyle(.plain).foregroundStyle(t.muted).help("Add to storyboard")
                    .accessibilityLabel("Add to storyboard")
            }
            if store.isOwner && !store.isComingSoon(d.tool) {
                Button { store.suite.showEngines = true } label: {
                    Ph("server.rack").frame(width: 28, height: 28).contentShape(Rectangle())
                }
                    .buttonStyle(.plain).foregroundStyle(t.muted).help("Engines")
                    .accessibilityLabel("Engines (owner)")
            }
        }
        .padding(.leading, 12).padding(.trailing, 16)
        .frame(height: 58)
    }
}

// MARK: Setting chips

/// A setting chip: a tiny visual, the mono label and the value ("Auto" until picked).
struct SettingChip: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var chip: ComposerChip
    @State private var refsOpen = false

    var body: some View {
        let s = store.suite.composer.settings
        let cat = store.suite.camera
        // @locations count against the References limit too.
        let refs = ComposerLocations.used(store.suite.composer.tokens, slots: store.suite.composerSlots.slots)
        let sum = ComposerCatalog.summary(chip, s, cat, refs: refs, refsMax: SlotKind.image.capacity(store.composerInputs))
        let directed = chip == .camera && store.suite.composer.directed != nil
        Button {
            if chip == .references { refsOpen = true } else if let p = ComposerPicker(chip: chip) { store.openPicker(p) }
        } label: {
            HStack(spacing: 7) {
                thumb(auto: sum.auto && !directed)
                Text(chip.key).font(t.mono(9.5, .medium)).tracking(0.8).foregroundStyle(t.muted)
                Text(directed ? "Directed" : sum.value).font(t.body(12.5, sum.auto && !directed ? .regular : .semibold))
                    .foregroundStyle(sum.auto && !directed ? t.ink.opacity(0.8) : t.ink)
                    .lineLimit(1).truncationMode(.tail).frame(maxWidth: 190, alignment: .leading)
            }
            .padding(.leading, 5).padding(.trailing, 11).frame(height: 34)
            .background(t.bg)
            .overlay(RoundedRectangle(cornerRadius: t.controlRadius).strokeBorder(t.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: t.controlRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(sum.text(max: 60))
        .accessibilityLabel(sum.text(max: 80))
        .popover(isPresented: $refsOpen, arrowEdge: .bottom) { ReferencesPopover().environment(store).environment(\.theme, t) }
    }

    @ViewBuilder private func thumb(auto: Bool) -> some View {
        if chip == .references {
            Ph("photo", 11).foregroundStyle(t.muted)
                .frame(width: 24, height: 24)
                .overlay(Rectangle().strokeBorder(t.muted.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        } else {
            HardwareImage(name: render)
                .frame(width: 24, height: 24).clipped()
                .grayscale(auto ? 1 : 0).brightness(auto ? -0.04 : 0)
        }
    }

    private var render: String {
        let s = store.suite.composer.settings
        let c = store.suite.camera
        let r = { (list: [SuiteOption], id: String?) -> String? in ComposerCatalog.survivor(list, id).flatMap { i in list.first { $0.id == i }?.render } }
        switch chip {
        case .style: return "stock-02-16mm"
        case .camera: return r(c.bodies, s.body) ?? r(c.lenses, s.lens) ?? "body-05-film35"
        case .look: return r(c.palettes, s.palette) ?? r(c.looks, s.stock) ?? "palette-02-teal-orange"
        case .lighting: return r(c.lighting, s.lighting) ?? "light-04-window"
        case .references: return ""
        }
    }
}

/// The References chip's popover: the reference images (and clips) this quality takes, each an input slot.
struct ReferencesPopover: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let inputs = store.composerInputs
        let model = store.suite.composerSlots
        let ids = model.slots.visible(inputs).filter { $0.kind == .image || $0.kind == .video }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("REFERENCES").font(t.mono(10.5, .medium)).tracking(1.2)
                Spacer()
                Text(ComposerSlots.referencesCaption(inputs)).font(t.body(11.5)).foregroundStyle(t.muted)
            }
            if ids.isEmpty {
                Muted("This quality doesn't take references. Try Standard or HD.")
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 8), count: 4), alignment: .leading, spacing: 8) {
                    ForEach(ids, id: \.self) { id in
                        InputSlotTile(id: id, value: model.slots[id], compact: true) { model.pick(id, api: store.api) } onClear: { model.clear(id) }
                            .frame(width: 84, height: 84)
                    }
                }
            }
            let places = ComposerLocations.ids(store.suite.composer.tokens).compactMap { id in store.suite.locations.first { $0.id == id }?.name }
            if !places.isEmpty {
                Label("@\(places.joined(separator: ", @")) · \(places.count == 1 ? "a location" : "locations") from the prompt", ph: "mappin.and.ellipse")
                    .font(t.body(11.5)).foregroundStyle(t.muted)
            }
            Muted("A product, place, style or prop · images up to 20 MB, clips up to 200 MB.")
        }
        .padding(14)
        .frame(width: 390, alignment: .leading)
        .foregroundStyle(t.ink)
    }
}

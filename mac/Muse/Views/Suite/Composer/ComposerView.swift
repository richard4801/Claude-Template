import MuseCore
import SwiftUI

// AI suite: the composer page, laid out as the owner-approved render (plans/design-direction/composer-mac-b.png and
// composer-mac-1000-b.png; plans/design-direction.md §9 fix 1; design/direction/render.py `composer_mac`).
// - Header: the tool's title (it opens the tool browser) and a quiet "Presets" link for the presets strip.
// - Main row, filling the height: the picture on the left (the take in progress or the latest take; before any, the
//   scene's light), and on the right a 300 pt rail (264 when narrow) with Setup rows, the Inputs thumbnails and the
//   tool's own controls.
// - The prompt bar right under it: the prompt, then the bottom bar's pills and Generate (the one filled action).
// Pickers open over the page, always dark.

/// Re-price when anything that changes the request changes.
private struct ComposerPriceKey: Equatable {
    var draft: ComposerDraft
    var slots: InputSlots
    var swap: SwapDraft
    var clipId: String?
    var catalogLoaded: Bool
    var photo: PhotoDraft // Photo tool (workstream 3): count, preset and references re-price too
}

/// The composer's width below which the rail narrows to 264 and the bar's pills go to icon plus value. A 1000 pt window
/// (compact sidebar) gives about 930; a 1280 one about 1050.
private let composerNarrowWidth: CGFloat = 1000

struct ComposerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    /// The presets strip under the header: shown by default while the draft is empty.
    @State private var presetsOpen = false

    var body: some View {
        let s = store.suite
        ZStack {
            GeometryReader { g in
                page(narrow: g.size.width < composerNarrowWidth)
                    .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            }
            ComposerPickerHost()
            if s.browserOpen { ToolBrowser().transition(.opacity) }
        }
        .onAppear { presetsOpen = draftIsEmpty }
        .onChange(of: s.composer.tool) { _, _ in presetsOpen = draftIsEmpty }
        .task(id: ComposerPriceKey(draft: s.composer, slots: s.composerSlots.slots, swap: s.swap, clipId: store.clip?.id, catalogLoaded: s.catalog != nil, photo: s.photo)) {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            switch s.composer.tool {
            case .shot, .talking, .ugc, .extend: if !store.isComingSoon(s.composer.tool) { await store.estimateShot() }
            case .swap, .recast: await store.estimateSwap()
            case .photo: await store.estimatePhoto() // Photo tool (workstream 3)
            default: break
            }
        }
        .sheet(isPresented: Binding(get: { store.isOwner && s.showEngines }, set: { s.showEngines = $0 })) {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Done") { s.showEngines = false }.keyboardShortcut(.cancelAction).padding(12)
                }
                ScrollView { SuiteEnginesPanel(estimate: s.composer.tool == .swap || s.composer.tool == .recast ? s.swapEstimate : s.estimate).padding(20) }
            }
            .frame(minWidth: 560, minHeight: 520)
            .environment(store)
            .environment(\.theme, t)
        }
    }

    private var draftIsEmpty: Bool {
        let d = store.suite.composer
        if d.tool == .photo { return store.suite.photo.presetId == nil && d.tokens.isEmpty }
        return d.tokens.isEmpty && d.collapsed == nil
    }

    /// Shot has the catalog's presets; Photo has the photo templates. The other tools have none.
    private var hasPresets: Bool {
        switch store.suite.composer.tool {
        case .shot: return !store.suite.camera.presets.isEmpty
        case .photo: return true
        default: return false
        }
    }

    private func page(narrow: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            header
            if presetsOpen && hasPresets {
                if store.suite.composer.tool == .photo {
                    PhotoPresetsRow() // Photo tool (workstream 3): the photo templates
                } else {
                    PresetsRow()
                }
            }
            HStack(alignment: .top, spacing: Space.s4) {
                ComposerMediaPane()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ScrollView(.vertical, showsIndicators: false) {
                    ComposerRail(narrow: narrow)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: narrow ? 264 : 300)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity)
            .zIndex(0)
            // Above the main row so the prompt's @ / # list, which opens upwards, draws over the picture.
            ComposerPromptBar()
                .zIndex(1)
        }
        .padding(.horizontal, Space.s5)
        .padding(.top, Space.s4)
        .padding(.bottom, 20)
    }

    private var header: some View {
        let d = store.suite.composer
        let preset = d.collapsed.flatMap { id in store.suite.camera.presets.first { $0.id == id } }
        let photoPreset = d.tool == .photo ? store.photoPreset : nil // Photo tool (workstream 3)
        return HStack(spacing: Space.s3) {
            Button { store.suite.browserOpen = true } label: {
                HStack(spacing: Space.s2) {
                    Text(d.tool.title).font(t.scale.title.font).foregroundStyle(t.roles.ink).lineLimit(1)
                    Ph("caret-down", 14).foregroundStyle(t.roles.ink2)
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Change the tool or start from a preset")
            .accessibilityLabel("\(d.tool.title), change tool")
            if let name = preset?.label ?? photoPreset?.name {
                Text(name).font(t.scale.label.font).foregroundStyle(t.roles.ink2).lineLimit(1)
            }
            if store.isComingSoon(d.tool) { SuiteTag(text: SuiteText.comingSoon) }
            SuiteTestBadge()
            Spacer(minLength: Space.s3)
            if d.tool == .shot && d.collapsed == nil && !d.tokens.isEmpty {
                Button { store.addShotToStoryboard() } label: {
                    Ph("rectangle.split.3x1", 16).frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(t.roles.ink2).help("Add to storyboard")
                .accessibilityLabel("Add to storyboard")
            }
            if store.isOwner && !store.isComingSoon(d.tool) && d.tool != .photo { // Photo (workstream 3) runs on the image steps, not the video engines
                Button { store.suite.showEngines = true } label: {
                    Ph("server.rack", 16).frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(t.roles.ink2).help("Engines")
                .accessibilityLabel("Engines (owner)")
            }
            if hasPresets {
                Button { presetsOpen.toggle() } label: {
                    Text(presetsOpen ? "Hide presets" : "Presets").font(t.scale.label.font).foregroundStyle(t.roles.ink2)
                        .frame(minHeight: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(presetsOpen ? "Hide the presets" : "Start from a preset")
            }
        }
        .frame(height: 32)
    }
}

// MARK: The picture

/// The left pane: the take in progress or the latest take of this composer; before any, the scene's current light (the
/// lighting option's preview, else the catalog's Auto preview), with the shape and length on a scrim tag.
struct ComposerMediaPane: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    private var tool: ComposerTool { store.suite.composer.tool }

    private var job: Job? {
        switch tool {
        case .swap, .recast: return store.swapJob
        case .photo: return nil // Photo's stills open in the take view (AppStore+Photo)
        default: return store.shotJob
        }
    }

    /// The picture under the result pane's blur: the start frame, the clip or the video being extended.
    private var art: ImageRef? {
        switch tool {
        case .swap, .recast: return store.clipPoster
        case .extend: return store.suite.composer.extend.source?.thumb
        default: return store.suite.composerSlots.slots[SlotId(.start)]?.image
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: t.radii.container)
        let current = job
        let idle: Bool = {
            if case .empty = SuiteResultState.of(current) { return true }
            return false
        }()
        ZStack(alignment: .bottomLeading) {
            shape.fill(t.roles.field)
            if idle {
                Color.clear
                    .overlay(still)
                    .clipped()
                    .accessibilityHidden(true)
                if let tag {
                    Text(tag).font(t.scale.micro.font).monospacedDigit().foregroundStyle(.white).lineLimit(1)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: t.radii.chip).fill(Color.black.opacity(0.55)))
                        .padding(Space.s2)
                        .accessibilityLabel(tagLabel ?? tag)
                }
            } else {
                SuiteResultPane(job: current, art: art, character: store.composerCharacter)
                    .padding(Space.s3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipShape(shape)
        .accessibilityElement(children: .contain)
    }

    /// Before any take: the clip or the video when the tool works on one, else the scene's light.
    @ViewBuilder private var still: some View {
        if (tool == .swap || tool == .recast), let poster = store.clipPoster {
            MuseImage(ref: poster)
        } else if tool == .extend, let thumb = store.suite.composer.extend.source?.thumb {
            MuseImage(ref: thumb)
        } else {
            PreviewView(preview: lightPreview, fallback: tool.render)
        }
    }

    /// The selected lighting option's preview poster, else the catalog's Auto lighting preview, else its hardware render.
    private var lightPreview: PickerPreview {
        let cam = store.suite.camera
        let id = ComposerCatalog.survivor(cam.lighting, store.suite.composer.settings.lighting)
        let option = id.flatMap { i in cam.lighting.first { $0.id == i } }
        if let p = option?.preview, !p.poster.isEmpty { return PickerPreview(still: option?.render, poster: p.poster) }
        if let auto = cam.autoPreviews.lighting, !auto.poster.isEmpty { return PickerPreview(still: option?.render, poster: auto.poster) }
        return PickerPreview(still: option?.render ?? tool.render)
    }

    /// "16:9 · 8 s" (shape · length); Extend shows the added length; Photo and the clip tools take theirs from elsewhere.
    private var tag: String? {
        let d = store.suite.composer
        switch tool {
        case .photo, .swap, .recast: return nil
        case .extend: return "+\(d.duration) s"
        default: return "\(d.aspect) · \(d.duration) s"
        }
    }

    private var tagLabel: String? {
        let d = store.suite.composer
        switch tool {
        case .photo, .swap, .recast: return nil
        case .extend: return "Adds \(d.duration) seconds"
        default: return "Shape \(d.aspect), \(d.duration) seconds"
        }
    }
}

// MARK: The rail (Setup, Inputs, the tool's own controls)

struct ComposerRail: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var narrow: Bool

    /// The render's order: Camera, Light, Look, Style, References.
    private static let order: [ComposerChip] = [.camera, .lighting, .look, .style, .references]

    var body: some View {
        let d = store.suite.composer
        let soon = store.isComingSoon(d.tool)
        VStack(alignment: .leading, spacing: 0) {
            if let pid = d.collapsed, d.tool == .shot {
                CollapsedComposer(presetId: pid, narrow: narrow)
            } else {
                if hasSetup {
                    Text("Setup").font(t.scale.heading.font).foregroundStyle(t.roles.ink).padding(.bottom, Space.s1)
                    ForEach(Self.order.filter { d.tool.chips.contains($0) }, id: \.self) { chip in
                        SetupChipRow(chip: chip)
                    }
                    if hasSettingsRow { SetupSettingsRow() }
                }
                Text("Inputs").font(t.scale.heading.font).foregroundStyle(t.roles.ink)
                    .padding(.top, hasSetup ? Space.s5 : 0).padding(.bottom, Space.s2)
                Group {
                    if d.tool == .photo {
                        PhotoSlotRow(size: narrow ? 56 : 64, spacing: narrow ? Space.s2 : 10) // Photo tool (workstream 3)
                    } else {
                        ComposerSlotRow(size: narrow ? 64 : 72, thumbs: true)
                    }
                }
                .disabled(soon)
                .opacity(soon ? 0.55 : 1)
                if let note = store.suite.composerSlots.slots.note(store.composerInputs), d.tool == .shot {
                    Text(note).font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Space.s2)
                }
                toolControls
                    .padding(.top, Space.s4)
            }
        }
    }

    private var hasSetup: Bool { !store.suite.composer.tool.chips.isEmpty || hasSettingsRow }

    /// Shape, length and takes: the tools that render a new video of their own length.
    private var hasSettingsRow: Bool {
        switch store.suite.composer.tool {
        case .shot, .talking, .ugc, .extend: return true
        default: return false
        }
    }

    /// What the old card carried for each tool: Swap's prompt switch, Extend's direction and length, the rig check.
    @ViewBuilder private var toolControls: some View {
        let tool = store.suite.composer.tool
        VStack(alignment: .leading, spacing: Space.s3) {
            if tool == .swap {
                Toggle(isOn: Binding(get: { store.suite.swap.promptOn }, set: { store.suite.swap.promptOn = $0 })) {
                    Text("Add a prompt").font(t.scale.label.font).foregroundStyle(t.roles.ink)
                }
                .toggleStyle(.switch).controlSize(.small)
            }
            if tool == .recast, let lines = store.suite.swapEstimate?.cast {
                VStack(alignment: .leading, spacing: Space.s1) {
                    ForEach(lines, id: \.self) { l in
                        Text("\(l.who.capitalized(with: nil)) → \(store.character(l.characterId)?.shortName ?? "")")
                            .font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                    }
                }
            }
            if tool == .extend { ExtendDirectionControl() }
            RigCheckRow()
        }
    }
}

/// A Setup row: icon, name in muted, the value on the right (muted while Auto), chevron. Opens its picker.
struct ComposerSetupRow: View {
    @Environment(\.theme) private var t
    var icon: String
    var name: String
    var value: String
    var auto: Bool
    var help: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s3) {
                Ph(icon, 18).foregroundStyle(t.roles.ink2).frame(width: 24)
                Text(name).font(t.scale.label.font).foregroundStyle(t.roles.ink2).lineLimit(1).fixedSize()
                Spacer(minLength: Space.s2)
                Text(value).font(t.scale.label.font).foregroundStyle(auto ? t.roles.ink2 : t.roles.ink)
                    .lineLimit(1).truncationMode(.tail)
                Ph("caret-right", 12).foregroundStyle(t.roles.ink2)
            }
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? "\(name): \(value)")
        .accessibilityLabel("\(name), \(value)")
    }
}

/// Camera, Light, Look, Style and References as Setup rows. Camera reads "body · lens", Style "genre · tempo".
struct SetupChipRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var chip: ComposerChip
    @State private var refsOpen = false

    var body: some View {
        let v = value
        // Photo tool (workstream 3): a Photo preset sets its own camera and light, so those rows show it, locked.
        let locked = (chip == .camera || chip == .lighting) && store.suite.composer.tool == .photo && store.suite.photo.presetId != nil
        ComposerSetupRow(icon: icon, name: name, value: locked ? "From preset" : v.text, auto: locked || v.auto,
                         help: locked ? "\(name) comes from the preset" : nil) {
            if chip == .references { refsOpen = true } else if let p = ComposerPicker(chip: chip) { store.openPicker(p) }
        }
        .disabled(locked)
        .popover(isPresented: $refsOpen, arrowEdge: .leading) { ReferencesPopover().environment(store).environment(\.theme, t) }
    }

    private var name: String {
        switch chip {
        case .camera: return "Camera"
        case .lighting: return "Light"
        case .look: return "Look"
        case .style: return "Style"
        case .references: return "References"
        }
    }

    private var icon: String {
        switch chip {
        case .camera: return "film-strip"
        case .lighting: return "lightbulb-filament"
        case .look: return "palette"
        case .style: return "sliders-horizontal"
        case .references: return "image"
        }
    }

    private var value: (text: String, auto: Bool) {
        let d = store.suite.composer
        let s = d.settings
        let cat = store.suite.camera
        if chip == .camera && d.directed != nil { return ("Directed", false) }
        switch chip {
        case .camera:
            let pair = [ComposerCatalog.label(cat.bodies, s.body), ComposerCatalog.label(cat.lenses, s.lens)].compactMap { $0 }
            if !pair.isEmpty { return (pair.joined(separator: " · "), false) }
        case .style:
            let pair = [ComposerCatalog.label(cat.genres, s.genre), ComposerCatalog.label(cat.tempos, s.tempo)].compactMap { $0 }
            if !pair.isEmpty { return (pair.joined(separator: " · "), false) }
        default:
            break
        }
        // @locations count against the References limit too.
        let refs = ComposerLocations.used(d.tokens, slots: store.suite.composerSlots.slots)
        let sum = ComposerCatalog.summary(chip, s, cat, refs: refs, refsMax: SlotKind.image.capacity(store.composerInputs))
        return (sum.value.replacingOccurrences(of: ", ", with: " · "), sum.auto)
    }
}

/// Settings: shape, length and takes ("8 s · 16:9, 1 take"), in a small panel.
struct SetupSettingsRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var open = false

    var body: some View {
        let d = store.suite.composer
        let takes = "\(d.takes) take\(d.takes == 1 ? "" : "s")"
        let value = d.tool == .extend ? "+\(d.duration) s \(d.extend.direction.label.lowercased()), \(takes)" : "\(d.duration) s · \(d.aspect), \(takes)"
        ComposerSetupRow(icon: "crop", name: "Settings", value: value, auto: false, help: "Shape, length and takes") { open = true }
            .popover(isPresented: $open, arrowEdge: .leading) {
                ComposerSettingsPanel().environment(store).environment(\.theme, t)
            }
    }
}

/// The Settings row's panel: Shape, Length and Takes (the bar keeps Quality, Sound and Speaking).
struct ComposerSettingsPanel: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let d = store.suite.composer
        let range = ComposerBar.lengthRange(store.suite.catalog?.tier(d.quality))
        let listed = store.suite.catalog?.aspectRatios ?? []
        let ratios = listed.isEmpty ? ComposerBar.shapes : listed
        let maxTakes = store.suite.catalog?.takesMax ?? 4
        VStack(alignment: .leading, spacing: Space.s4) {
            if d.tool != .extend {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text("Shape").font(t.scale.label.font).foregroundStyle(t.roles.ink2)
                    SuiteSeg(options: ratios.map { ($0, $0) }, selection: d.aspect) { store.suite.composer.aspect = $0 }
                        .accessibilityLabel("Shape")
                }
            }
            VStack(alignment: .leading, spacing: Space.s2) {
                HStack {
                    Text(d.tool == .extend ? "Added length" : "Length").font(t.scale.label.font).foregroundStyle(t.roles.ink2)
                    Spacer(minLength: Space.s2)
                    Text("\(d.duration) s").font(t.scale.label.font).monospacedDigit()
                }
                Slider(value: Binding(get: { Double(store.suite.composer.duration) }, set: { store.suite.composer.duration = Int($0.rounded()) }),
                       in: Double(range.lowerBound)...Double(max(range.upperBound, range.lowerBound + 1)), step: 1) { Text("Length") }
                    .labelsHidden()
                HStack {
                    Text("\(range.lowerBound) s").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                    Spacer()
                    Text("\(range.upperBound) s on \(SuiteText.tierLabel(d.quality))").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                }
            }
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("Takes").font(t.scale.label.font).foregroundStyle(t.roles.ink2)
                SuiteSeg(options: ComposerBar.takes(maxTakes).map { ($0, "\($0)") }, selection: d.takes) { store.suite.composer.takes = $0 }
                    .accessibilityLabel("Takes")
            }
        }
        .padding(Space.s4)
        .frame(width: 280, alignment: .leading)
        .foregroundStyle(t.roles.ink)
    }
}

// MARK: The prompt bar

/// The prompt on top, the bottom bar under it (pills, "How is this priced?", Generate), on the raised tone.
struct ComposerPromptBar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    private var draft: ComposerDraft { store.suite.composer }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            if store.isComingSoon(draft.tool) {
                comingSoon
            } else {
                promptArea
                if let p = currentProblem {
                    Label(p, ph: "exclamationmark.triangle").font(t.scale.caption.font).foregroundStyle(t.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ComposerBottomBar(settingsInRail: true)
            }
        }
        .padding(.leading, Space.s4).padding(.trailing, Space.s3).padding(.top, Space.s3).padding(.bottom, Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: t.radii.control).fill(t.roles.raised))
    }

    private var currentProblem: String? {
        switch draft.tool {
        case .swap, .recast:
            if store.clip == nil { return "Choose a clip first" }
            return store.suite.swapEstimate?.problem ?? store.suite.swapError
        case .photo: return store.suite.photoError // Photo tool (workstream 3)
        default: return store.suite.estimate?.problem ?? store.suite.estimateError
        }
    }

    @ViewBuilder private var promptArea: some View {
        switch draft.tool {
        case .swap:
            if store.suite.swap.promptOn {
                promptBox
            } else {
                Text("Your character takes over the clip: its motion, camera, framing and cuts stay as they are.")
                    .font(t.scale.body.font).foregroundStyle(t.roles.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            }
        case .recast:
            Text("Same take, new cast. Click each face on the first frame in People and pick who replaces them (up to \(store.suite.catalog?.recastMaxPeople ?? 4) people). The motion, camera, framing and sound stay.")
                .font(t.scale.body.font).foregroundStyle(t.roles.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        case .extend:
            ExtendPromptField()
        default:
            promptBox
        }
    }

    private var promptBox: some View {
        ComposerPromptBox(placeholder: draft.tool.promptPlaceholder, minHeight: 48, maxHeight: 72, suggestionsAbove: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var comingSoon: some View {
        // The Setup rows already work (UGC ad's Style has its format wheel), so the settings are ready when the tool is.
        HStack(spacing: Space.s3) {
            Pill(SuiteText.comingSoon)
            Text(draft.tool.mode.tileLine).font(t.scale.body.font).foregroundStyle(t.roles.ink2).lineLimit(2)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 48)
    }
}

// MARK: Presets (the beginner path)

/// The presets strip under the header: real stills with their names under them.
struct PresetsRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let presets = store.suite.camera.presets
        if !presets.isEmpty && store.suite.composer.tool == .shot {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Space.s3) {
                    ForEach(presets) { p in
                        PresetTile(preset: p, selected: store.suite.composer.collapsed == p.id, width: 132, height: 84) { store.applyPreset(p) }
                    }
                }
                .padding(Space.s1)
            }
            .padding(-Space.s1)
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
        // The still, and its name under it in sentence case (no words over the picture, no play badge: nothing plays).
        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.s2) {
                Color.clear
                    .overlay(PreviewView(preview: PickerPreview(still: ComposerPresets.render(preset, store.suite.camera))))
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: t.radii.container))
                    .overlay(RoundedRectangle(cornerRadius: t.radii.container + 3).strokeBorder(selected ? t.roles.selection : .clear, lineWidth: 2).padding(-3))
                Text(preset.label).font(t.scale.label.font).foregroundStyle(t.roles.ink).lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(preset.description)
        .accessibilityLabel("\(preset.label) preset\(selected ? ", selected" : "")")
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
                Text("References").font(t.scale.label.font)
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

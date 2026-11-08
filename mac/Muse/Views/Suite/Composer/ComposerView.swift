import MuseCore
import SwiftUI

// AI suite: the composer page, laid out as the owner-approved render (plans/design-direction/composer-mac-b.png and
// composer-mac-1000-b.png; plans/design-direction.md §9 fix 1; design/direction/render.py `composer_mac`).
// - Header: the tool's title (it opens the mode menu, SuiteNav.swift) and a quiet "Presets" link for the presets strip.
// - Main row, filling the height: the picture on the left (the take in progress or the latest take; before any, the
//   scene's light), and on the right a 300 pt rail (264 when narrow) with Setup rows, the Inputs thumbnails and the
//   tool's own controls.
// - The prompt bar right under it: the prompt, then the bottom bar's pills and Generate (the one filled action).
// Pickers open over the page, always dark.

/// Re-price when anything that changes the request changes.
struct ComposerPriceKey: Equatable {
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

/// Below this window height the composer page scrolls as a whole (header, a short picture, the prompt bar).
let composerMinHeight: CGFloat = 520

struct ComposerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    /// The presets strip under the header: shown by default while the draft is empty.
    @State private var presetsOpen = false

    var body: some View {
        let s = store.suite
        ZStack {
            // The page fills the window; the picture gives up height first so the prompt bar and Generate stay on
            // screen. Below `composerMinHeight` the whole page scrolls instead (owner fix A2).
            GeometryReader { g in
                let fits = g.size.height >= composerMinHeight
                ScrollView(.vertical, showsIndicators: !fits) {
                    page(narrow: g.size.width < composerNarrowWidth)
                        .frame(width: g.size.width, height: max(g.size.height, composerMinHeight), alignment: .topLeading)
                }
                .scrollDisabled(fits)
            }
            ComposerPickerHost()
            // Compare in the feed: two takes side by side over the composer.
            let comparing = store.suiteComparing
            if comparing.count == 2 { ComposerCompare(takes: comparing) }
            // The title's mode menu (owner decision 2026-11-08: a plain grouped list, no presets; they stay in the strip).
            if s.browserOpen { SuiteModeMenu() }
            // Review only: the big tool and preset browser it replaced, for the before shot.
            if SnapshotRunner.state.overlay == "tools_before" { ToolBrowser() }
        }
        .onAppear { presetsOpen = draftIsEmpty }
        .onChange(of: s.composer.tool) { _, _ in presetsOpen = draftIsEmpty }
        // Saved rigs for the Setup rail's Rigs row; a model's default rig when she is @-mentioned (fills Auto rows only).
        .task(id: store.serverKey) { await store.loadSavedRigs() }
        .onChange(of: s.composer.tokens.characterId) { _, new in
            // A take's settings just came back (Reuse settings): keep them exactly, no default rig on top.
            if let r = s.restoredCharacterId { s.restoredCharacterId = nil; if r == new { return } }
            if new != nil { store.applyDefaultRigIfAny() }
        }
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
                .layoutPriority(1)
            if presetsOpen && hasPresets {
                if store.suite.composer.tool == .photo {
                    PhotoPresetsRow() // Photo tool (workstream 3): the photo templates
                } else {
                    PresetsRow()
                }
            }
            HStack(alignment: .top, spacing: Space.s4) {
                // The results feed takes the picture's place beside the rail (header "Takes").
                if store.suite.feedOpen {
                    ComposerFeed()
                } else {
                    ComposerMediaPane()
                }
                ScrollView(.vertical, showsIndicators: false) {
                    ComposerRail(narrow: narrow)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: narrow ? 264 : 300)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            .zIndex(0)
            // Above the main row so the prompt's @ / # list, which opens upwards, draws over the picture. It keeps its
            // full height; the row above takes what is left.
            ComposerPromptBar()
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
                .zIndex(1)
                .accessibilityIdentifier("composer.promptBar")
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
            Button { store.suite.browserOpen.toggle() } label: {
                HStack(spacing: Space.s2) {
                    Text(d.tool.title).font(t.scale.title.font).foregroundStyle(t.roles.ink).lineLimit(1)
                    Ph("caret-down", 14).foregroundStyle(t.roles.ink2)
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Change the mode")
            .accessibilityLabel("\(d.tool.title), change mode")
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
            Button { store.suite.feedOpen.toggle() } label: {
                Text(store.suite.feedOpen ? "Hide takes" : (d.tool == .photo ? "Photos" : "Takes")).font(t.scale.label.font).foregroundStyle(t.roles.ink2)
                    .lineLimit(1).fixedSize()
                    .frame(minHeight: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(store.suite.feedOpen ? "Back to the picture" : "Everything you made with this tool, newest first")
            .accessibilityLabel(store.suite.feedOpen ? "Hide takes" : "Show takes")
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

/// The left pane: the take in progress or the latest take of this composer. Before any take it is a quiet empty canvas:
/// the shot's shape outlined on the surface tone with a one-line hint (no sample or scene stills, owner fix A1). Swap,
/// Recast and Extend show the member's own clip or video instead, since that is what they work on.
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

    /// The member's own media for the tools that work on a clip or a video.
    private var ownMedia: ImageRef? {
        switch tool {
        case .swap, .recast: return store.clipPoster
        case .extend: return store.suite.composer.extend.source?.thumb
        default: return nil
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: t.radii.container)
        let current = job
        let idle: Bool = {
            if case .empty = SuiteResultState.of(current) { return true }
            return false
        }()
        Group {
            if idle, let media = ownMedia {
                ZStack(alignment: .bottomLeading) {
                    shape.fill(t.roles.field)
                    Color.clear.overlay(MuseImage(ref: media)).clipped().accessibilityHidden(true)
                    if let tag { tagText(tag).padding(Space.s3) }
                }
                .clipShape(shape)
            } else if idle {
                emptyCanvas
            } else {
                ZStack {
                    shape.fill(t.roles.field)
                    SuiteResultPane(job: current, art: art, character: store.composerCharacter)
                        .padding(Space.s3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .clipShape(shape)
            }
        }
        // Takes whatever height the page gives it (owner fix A2: the prompt bar and Generate always stay on screen).
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
        .accessibilityElement(children: .contain)
    }

    /// No take yet: the shape's outline, centred, with the hint inside and the shape and length under it.
    private var emptyCanvas: some View {
        let shape = RoundedRectangle(cornerRadius: t.radii.container)
        return VStack(spacing: Space.s2) {
            Text(hint).font(t.scale.body.font).foregroundStyle(t.roles.ink2).multilineTextAlignment(.center)
            if let tag {
                Text(tag).font(t.scale.caption.font).monospacedDigit().foregroundStyle(t.roles.ink2.opacity(0.8))
                    .accessibilityLabel(tagLabel ?? tag)
            }
        }
        .padding(Space.s4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(t.roles.raised))
        .overlay(shape.strokeBorder(t.roles.hairline, lineWidth: 1))
        .aspectRatio(aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// "16:9" → 16/9; anything unreadable is 16:9.
    private var aspectRatio: CGFloat {
        let parts = store.suite.composer.aspect.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return 16.0 / 9.0 }
        return CGFloat(parts[0] / parts[1])
    }

    private var hint: String {
        switch tool {
        case .photo: return "Your photos appear here"
        case .swap, .recast: return "Choose a clip to start"
        case .extend: return "Choose a video to extend"
        default: return "Your shot appears here"
        }
    }

    private func tagText(_ tag: String) -> some View {
        Text(tag).font(t.scale.micro.font).monospacedDigit().foregroundStyle(.white).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: t.radii.chip).fill(Color.black.opacity(0.55)))
            .accessibilityLabel(tagLabel ?? tag)
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
                    if hasRig { SetupRigsRow() }
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

    /// The tools whose Setup is a rig (camera, light, look or style rows): saved rigs apply there.
    private var hasRig: Bool {
        let chips = store.suite.composer.tool.chips
        return chips.contains(.camera) || chips.contains(.lighting) || chips.contains(.look) || chips.contains(.style)
    }

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

/// Saved rigs (plans/ai-suite-design.md: "A whole rig can be saved", for everyone): apply one (Undo in the toast), save
/// this one under a name, and with one character in the prompt make it her default rig (it then fills her Auto rows
/// whenever she is @-mentioned).
struct SetupRigsRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var open = false
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        let rigs = store.suite.savedRigs
        let value = rigs.isEmpty ? "None saved" : "\(rigs.count) saved"
        ComposerSetupRow(icon: "faders", name: "Rigs", value: value, auto: rigs.isEmpty, help: "Saved rigs") { open = true }
            .popover(isPresented: $open, arrowEdge: .leading) { panel.environment(store).environment(\.theme, t) }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Saved rigs").font(t.scale.label.font).foregroundStyle(t.roles.ink2)
                .padding(.horizontal, Space.s4).padding(.top, Space.s3).padding(.bottom, Space.s2)
            if store.suite.savedRigs.isEmpty {
                Text("Save the camera, light, look and style you have now, then apply them to any shot in one click.")
                    .font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.s4).padding(.bottom, Space.s2)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(store.suite.savedRigs) { r in rigRow(r) }
                    }
                }
                .frame(maxHeight: 260)
            }
            Divider().padding(.vertical, Space.s1)
            if naming {
                HStack(spacing: Space.s2) {
                    TextField("Name this rig", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, Space.s4).padding(.vertical, Space.s2)
            } else {
                action("Save this rig…", icon: "plus") { naming = true }
            }
            if let m = store.soleMentionedCharacter {
                action("Make it \(m.shortName)’s default", icon: "user") {
                    store.setDefaultRig(for: m)
                    open = false
                }
                .help("Whenever \(m.shortName) is in a prompt, this rig fills the rows still on Auto")
            }
        }
        .padding(.bottom, Space.s2)
        .frame(width: 300, alignment: .leading)
        .foregroundStyle(t.roles.ink)
    }

    private func rigRow(_ r: SuiteRigView) -> some View {
        HStack(spacing: Space.s2) {
            Button {
                store.applySavedRig(r)
                open = false
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.name).font(t.scale.label.font).foregroundStyle(t.roles.ink).lineLimit(1)
                    if !r.mine { Text("From the studio").font(t.scale.caption.font).foregroundStyle(t.roles.ink2) }
                }
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Apply \(r.name)")
            if r.mine || store.isOwner {
                Button { store.deleteSavedRig(r) } label: {
                    Ph("trash", 14).foregroundStyle(t.roles.ink2).frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete \(r.name)")
                .accessibilityLabel("Delete \(r.name)")
            }
        }
        .padding(.horizontal, Space.s4)
    }

    private func action(_ title: String, icon: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: Space.s2) {
                Ph(icon, 14).foregroundStyle(t.roles.ink2)
                Text(title).font(t.scale.label.font).foregroundStyle(t.roles.ink).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.s4).frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func save() {
        store.saveRig(named: name)
        name = ""
        naming = false
        open = false
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

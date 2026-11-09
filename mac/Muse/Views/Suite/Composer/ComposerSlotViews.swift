import MuseCore
import SwiftUI

// AI suite (workstream 1): the slot cards beside the prompt (CHARACTER, START FRAME, END FRAME, CLIP, PEOPLE…), the
// preset-collapsed composer (C6) and the tool and preset browser that Change opens. Frame, product and audio slots are
// the shot's input slots (InputSlotTile once filled); which show comes from MuseCore's ComposerSlots.

/// The composer's slot cards. `thumbs` (the Inputs rail, plans/design-direction.md §9 fix 4): small thumbnails with
/// their name under each and "Optional" where it applies; an empty one is a dashed box with a plain +.
struct ComposerSlotRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var size: CGFloat = 104
    var thumbs = false

    var body: some View {
        let cards = ComposerSlots.cards(store.suite.composer.tool, inputs: store.composerInputs, slots: store.suite.composerSlots.slots)
        if thumbs {
            HStack(alignment: .top, spacing: Space.s3) {
                ForEach(cards) { c in thumb(c) }
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                ForEach(cards) { c in ComposerSlotCardView(card: c, size: size) }
            }
        }
    }

    private func thumb(_ c: ComposerSlotCard) -> some View {
        let filled = isFilled(c.slot)
        return VStack(alignment: .leading, spacing: 2) {
            ComposerSlotCardView(card: c, size: size)
                .environment(\.slotThumbs, true)
                .padding(.bottom, Space.s1)
            Text(c.slot.label).font(t.scale.micro.font).foregroundStyle(filled ? t.roles.ink : t.roles.ink2).lineLimit(1)
            if c.slot == .character && filled {
                CharacterOutfitLine()
            } else if c.optional && !filled {
                Text("Optional").font(t.scale.micro.font).foregroundStyle(t.roles.ink2).lineLimit(1)
            }
        }
        .frame(width: size + Space.s1, alignment: .leading)
    }

    private func isFilled(_ slot: ComposerSlot) -> Bool {
        let tool = store.suite.composer.tool
        switch slot {
        case .character: return (tool == .swap || tool == .recast ? store.character(store.suite.swap.modelId) : store.composerCharacter) != nil
        case .clip: return store.clipPoster != nil
        case .people: return !store.suite.swap.cast.isEmpty
        case .video: return store.suite.composer.extend.source != nil
        default: return slot.slotId.map { store.suite.composerSlots.slots[$0] != nil } ?? false
        }
    }
}

/// The Inputs rail draws slots as bare thumbnails: the name goes under them, so the card itself carries no text.
private struct SlotThumbsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var slotThumbs: Bool {
        get { self[SlotThumbsKey.self] }
        set { self[SlotThumbsKey.self] = newValue }
    }
}

/// Under the Character thumbnail: the outfit, a small menu (it lived on the card's scrim before).
struct CharacterOutfitLine: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    private var isSwap: Bool { store.suite.composer.tool == .swap || store.suite.composer.tool == .recast }

    var body: some View {
        let m = isSwap ? store.character(store.suite.swap.modelId) : store.composerCharacter
        let outfits = m.map { store.outfits(for: $0) } ?? []
        let current = isSwap ? store.suite.swap.outfitId : store.suite.composer.outfitId
        let outfit = outfits.first { $0.id == current } ?? outfits.first
        if !outfits.isEmpty {
            Menu {
                ForEach(outfits) { o in
                    Button(o.name) {
                        if isSwap { store.suite.swap.outfitId = o.id } else { store.suite.composer.outfitId = o.id }
                    }
                }
            } label: {
                Text(outfit?.name ?? "Outfit").font(t.scale.micro.font).foregroundStyle(t.roles.ink2).lineLimit(1)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Outfit")
            .accessibilityLabel("Outfit, \(outfit?.name ?? "")")
        }
    }
}

struct ComposerSlotCardView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var card: ComposerSlotCard
    var size: CGFloat = 104
    @State private var peopleOpen = false
    @Environment(\.slotThumbs) private var thumbs

    var body: some View {
        Group {
            switch card.slot {
            case .character: CharacterSlot(card: card, size: size)
            case .clip: clipSlot
            case .people: peopleSlot
            case .video: ExtendVideoSlot(card: card, size: size)
            default:
                if let id = card.slot.slotId {
                    inputSlot(id)
                } else {
                    EmptySlotCard(card: card, disabled: true) {}
                }
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private func inputSlot(_ id: SlotId) -> some View {
        let model = store.suite.composerSlots
        if let v = model.slots[id] {
            InputSlotTile(id: id, value: v, compact: true) { model.pick(id, api: store.api) } onClear: { model.clear(id) }
        } else {
            EmptySlotCard(card: card, disabled: card.waiting) { model.pick(id, api: store.api) }
        }
    }

    /// The clip, with "Import from a link" on its corner and a dropped link imported (owner 2026-11-08).
    private var clipSlot: some View {
        clipTile
            .overlay(alignment: .topTrailing) {
                Button { store.openLinkImport(.swap) } label: {
                    Ph("link", 12).foregroundStyle(t.roles.ink)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(t.roles.canvas.opacity(0.92)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(4)
                .help("Import a video from a link")
                .accessibilityLabel("Import a video from a link")
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let u = urls.first else { return false }
                if u.isFileURL { store.importClip(u); return true }
                return store.importDroppedLink(u, for: .swap)
            }
    }

    @ViewBuilder private var clipTile: some View {
        if let poster = store.clipPoster {
            Button { store.pickClip() } label: {
                ZStack(alignment: .bottomLeading) {
                    MuseImage(ref: poster)
                    if !thumbs {
                    LinearGradient(colors: [.clear, Color(hex: 0x0E0C0A, alpha: 0.78)], startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Clip").font(t.scale.micro.font).foregroundStyle(Color(hex: 0xF8F5EF))
                        Text(store.clip.map { "\(Pricing.trimNum($0.durationSec)) s · change" } ?? "Change").font(t.body(10.5)).foregroundStyle(Color(hex: 0xE7E1D6))
                    }
                    .padding(.horizontal, 8).padding(.bottom, 7)
                    }
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: t.imageRadius))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clip, \(store.clip?.name ?? ""), change")
        } else {
            EmptySlotCard(card: card) { store.pickClip() }
        }
    }

    private var peopleSlot: some View {
        let cast = store.suite.swap.cast
        return Button { peopleOpen = true } label: {
            VStack(spacing: 6) {
                HStack(spacing: -6) {
                    ForEach(Array(cast.prefix(4).enumerated()), id: \.offset) { _, m in
                        MuseImage(ref: store.character(m.characterId)?.cover).frame(width: 24, height: 30).clipped()
                            .overlay(Rectangle().strokeBorder(t.surface, lineWidth: 1.5))
                    }
                    if cast.isEmpty { Ph("plus", 14).frame(width: 30, height: 30).overlay(Circle().strokeBorder(t.line, lineWidth: 1)) }
                }
                if !thumbs {
                    Text("People").font(t.scale.label.font)
                    Text(cast.isEmpty ? card.caption : "\(cast.count) of \(store.suite.catalog?.recastMaxPeople ?? 4) · edit").font(t.body(10.5)).foregroundStyle(t.muted)
                }
            }
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: t.imageRadius).fill(t.bg))
            .overlay(RoundedRectangle(cornerRadius: t.imageRadius).strokeBorder(t.line, style: StrokeStyle(lineWidth: 1, dash: cast.isEmpty ? [4, 3] : [])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("People, \(cast.count)")
        .sheet(isPresented: $peopleOpen) {
            RecastFacePicker { peopleOpen = false }
                .environment(store)
                .environment(\.theme, PickerTheme.dark)
                .environment(\.colorScheme, .dark)
        }
    }
}

/// An empty slot card: dashed outline, "+", the caps label, its caption and an "Optional" caption.
struct EmptySlotCard: View {
    @Environment(\.theme) private var t
    @Environment(\.slotThumbs) private var thumbs
    var card: ComposerSlotCard
    var disabled = false
    var action: () -> Void

    var body: some View {
        let off = disabled || card.waiting
        if thumbs {
            thumbBody(off: off)
        } else {
            cardBody(off: off)
        }
    }

    /// The Inputs rail: a dashed box with a plain + (its name is under it).
    private func thumbBody(off: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: t.radii.control)
        return Button(action: action) {
            Ph("plus", 18)
                .foregroundStyle(t.roles.ink2)
                .opacity(off ? 0.42 : 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(shape.strokeBorder(t.roles.ink2.opacity(off ? 0.35 : 0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(off)
        .help(card.waiting ? card.caption : "\(card.slot.label): \(card.caption)")
        .accessibilityLabel("\(card.slot.label), \(card.caption)\(card.optional ? ", optional" : "")\(off ? ", not available yet" : "")")
    }

    private func cardBody(off: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: t.imageRadius)
        // Quieter than before: the + sits on a plain disc (no ring) and "Optional" is a caption, not a boxed pill, so the
        // dashed outline is the card's only line.
        return Button(action: action) {
            VStack(spacing: 5) {
                // Workstream 4 (design direction, owner fix 4): a plain plus and the name of what the slot adds, sentence case.
                Ph("plus", 16)
                    .padding(.bottom, 2)
                Text(card.slot.label).font(t.scale.label.font).lineLimit(1).minimumScaleFactor(0.8)
                Text(card.caption).font(t.body(10.5)).foregroundStyle(t.muted).multilineTextAlignment(.center).lineLimit(2).padding(.horizontal, 6)
            }
            .opacity(off ? 0.42 : 1)
            .padding(.top, card.optional ? 14 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(off ? Color.clear : t.bg))
            .overlay(shape.strokeBorder(off ? t.line : t.muted.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .overlay(alignment: .topTrailing) {
                if card.optional {
                    Text("Optional").font(t.scale.micro.font).foregroundStyle(t.muted)
                        .padding(.top, 7).padding(.trailing, 8)
                        .opacity(off ? 0.42 : 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(off)
        .help(card.waiting ? card.caption : card.slot.label)
        .accessibilityLabel("\(card.slot.label), \(card.caption)\(card.optional ? ", optional" : "")\(off ? ", not available yet" : "")")
    }
}

/// CHARACTER: the studio's real characters, with the outfit picked inside the card.
struct CharacterSlot: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var card: ComposerSlotCard
    var size: CGFloat
    @State private var open = false
    @Environment(\.slotThumbs) private var thumbs

    private var isSwap: Bool { store.suite.composer.tool == .swap || store.suite.composer.tool == .recast }
    private var current: MuseModel? { isSwap ? store.character(store.suite.swap.modelId) : store.composerCharacter }
    private var outfitId: String? { isSwap ? store.suite.swap.outfitId : store.suite.composer.outfitId }

    var body: some View {
        Group {
            if let m = current {
                filled(m)
            } else {
                EmptySlotCard(card: card) { open = true }
            }
        }
        .popover(isPresented: $open, arrowEdge: .bottom) { picker.environment(\.theme, t) }
    }

    private func filled(_ m: MuseModel) -> some View {
        let outfits = store.outfits(for: m)
        let outfit = outfits.first { $0.id == outfitId } ?? outfits.first
        return ZStack(alignment: .bottomLeading) {
            Button { open = true } label: {
                MuseImage(ref: m.cover).frame(width: size, height: size).clipped()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Character: \(m.shortName). Change")
            .help(m.shortName)
            if !thumbs {
            LinearGradient(colors: [.clear, Color(hex: 0x0E0C0A, alpha: 0.78)], startPoint: .center, endPoint: .bottom).allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 1) {
                Text(m.shortName).font(t.body(13, .semibold)).foregroundStyle(Color(hex: 0xF8F5EF)).lineLimit(1)
                if !outfits.isEmpty {
                    Menu {
                        ForEach(outfits) { o in Button(o.name) { setOutfit(o.id) } }
                    } label: {
                        Text("\(outfit?.name ?? "Outfit") ▾").font(t.body(10.5)).foregroundStyle(Color(hex: 0xE7E1D6)).lineLimit(1)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Outfit, \(outfit?.name ?? "")")
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 7)
            }
            Button { clear() } label: {
                Ph("xmark", 9).foregroundStyle(Color(hex: 0xF8F5EF))
                    .frame(width: 20, height: 20).background(Circle().fill(Color(hex: 0x0E0C0A, alpha: 0.55)))
            }
            .buttonStyle(.plain)
            .padding(5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .accessibilityLabel("Remove \(m.shortName)")
            .opacity(isSwap ? 0 : 1)
            .accessibilityHidden(isSwap)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: thumbs ? t.radii.control : t.imageRadius))
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your cast").font(t.scale.label.font).foregroundStyle(t.muted).padding(12)
            if store.suiteCharacters.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Muted("Make a model with a character sheet to cast her.")
                    MButton("New model", icon: "person.badge.plus", size: .small) { store.go(.create) }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
            ForEach(store.suiteCharacters) { m in
                Button {
                    pick(m)
                    open = false
                } label: {
                    HStack(spacing: 10) {
                        MuseImage(ref: m.cover).frame(width: 32, height: 40).clipped()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.name).font(t.body(13, .semibold))
                            Text("\(m.niche) · \(store.outfits(for: m).count) outfits").font(t.body(11.5)).foregroundStyle(t.muted)
                        }
                        Spacer(minLength: 0)
                        if m.id == current?.id { Ph("checkmark").foregroundStyle(t.accent) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 8)
        .frame(width: 280, alignment: .leading)
        .foregroundStyle(t.ink)
    }

    private func pick(_ m: MuseModel) {
        if isSwap {
            store.suite.swap.modelId = m.id
            store.suite.swap.outfitId = nil
        } else {
            store.setComposerCharacter(m)
        }
    }

    private func setOutfit(_ id: String) {
        if isSwap { store.suite.swap.outfitId = id } else { store.suite.composer.outfitId = id }
    }

    private func clear() {
        if !isSwap { store.setComposerCharacter(nil) }
    }
}

// MARK: The preset-collapsed composer (C6)

/// The rail when a preset is picked: the preset and its line, who (or what) is in it, the shape, and "Edit settings".
/// Generate stays in the prompt bar.
struct CollapsedComposer: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var presetId: String
    var narrow = false

    var body: some View {
        let d = store.suite.composer
        let preset = store.suite.camera.presets.first { $0.id == presetId }
        let slots = ComposerSlots.collapsed(preset: presetId)
        let side: CGFloat = narrow ? 64 : 72
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(preset?.label ?? "Preset").font(t.scale.heading.font).foregroundStyle(t.roles.ink)
            Text(ComposerPresets.summary(preset, quality: d.quality, seconds: d.duration)).font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text(slots.first == .product ? "What" : "Who").font(t.scale.heading.font).foregroundStyle(t.roles.ink).padding(.top, Space.s4)
            HStack(spacing: Space.s3) {
                ForEach(slots) { s in
                    ComposerSlotCardView(card: ComposerSlotCard(slot: s, optional: false), size: side)
                        .environment(\.slotThumbs, true)
                }
            }
            Text("Shape").font(t.scale.heading.font).foregroundStyle(t.roles.ink).padding(.top, Space.s4)
            HStack(spacing: Space.s2) {
                ForEach(ComposerBar.shapes, id: \.self) { r in shape(r, on: d.aspect == r, side: side) }
            }
            HStack(spacing: Space.s3) {
                PricingLink(estimate: store.suite.estimate)
                Button { store.suite.composer.collapsed = nil } label: {
                    Text("Edit settings").font(t.scale.label.font).foregroundStyle(t.roles.link)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, Space.s4)
        }
    }

    private func shape(_ r: String, on: Bool, side: CGFloat) -> some View {
        let parts = r.split(separator: ":").compactMap { Double($0) }
        let ratio = CGFloat(parts.count == 2 && parts[1] > 0 ? parts[0] / parts[1] : 1)
        let box = side * 0.5
        let w: CGFloat = ratio >= 1 ? box : box * ratio
        let h: CGFloat = ratio >= 1 ? box / ratio : box
        let tile = RoundedRectangle(cornerRadius: t.radii.control)
        return Button { store.suite.composer.aspect = r } label: {
            VStack(spacing: Space.s1) {
                Rectangle().fill(on ? t.roles.ink : Color.clear).frame(width: w, height: h).overlay(Rectangle().strokeBorder(t.roles.ink, lineWidth: 1.5))
                Text(r).font(t.scale.micro.font).monospacedDigit()
            }
            .frame(width: side, height: side)
            .background(tile.fill(on ? t.roles.field : Color.clear))
            .overlay(tile.strokeBorder(on ? t.roles.selection : t.roles.hairline, lineWidth: on ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shape \(r)\(on ? ", selected" : "")")
    }
}

// MARK: The tool and preset browser (Change)

struct ToolBrowser: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ZStack {
            Color(hex: 0x100E0C, alpha: 0.52).ignoresSafeArea().contentShape(Rectangle())
                .onTapGesture { store.suite.browserOpen = false }
                .accessibilityHidden(true)
            ToolBrowserPanel().frame(width: 840, height: 540)
        }
        .environment(\.theme, PickerTheme.dark)
        .environment(\.colorScheme, .dark)
    }
}

private struct ToolBrowserPanel: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("TOOLS").font(Fonts.font("Barlow Condensed", 24, .bold)).tracking(2)
                Text("One composer · pick a tool, or start from a preset").font(t.body(13)).foregroundStyle(t.muted)
                Spacer()
                Button { store.suite.browserOpen = false } label: {
                    Ph("xmark", 14).frame(width: 34, height: 34).background(Circle().fill(t.surface2))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
            }
            .padding(.leading, 24).padding(.trailing, 14).frame(height: 62)
            Rectangle().fill(t.line).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(ComposerTool.shell) { tool in toolRow(tool) }
                    }
                    .padding(12)
                }
                .frame(width: 300)
                Rectangle().fill(t.line).frame(width: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Presets").font(t.scale.label.font).foregroundStyle(t.muted)
                        if store.suite.composer.tool == .photo {
                            // Photo tool (workstream 3): its presets are the photo templates.
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), alignment: .leading, spacing: 16) {
                                ForEach(store.templates) { tpl in
                                    PhotoPresetTile(template: tpl, selected: store.suite.photo.presetId == tpl.id) {
                                        store.choosePhotoPreset(tpl)
                                        store.suite.browserOpen = false
                                    }
                                }
                            }
                            if store.templates.isEmpty { Muted("No photo presets yet. Save a photo as a template and it shows up here.") }
                        } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 14) {
                            ForEach(store.suite.camera.presets) { p in
                                VStack(alignment: .leading, spacing: 6) {
                                    PresetTile(preset: p, selected: store.suite.composer.collapsed == p.id, width: 150, height: 96) { store.applyPreset(p) }
                                    Text(p.description).font(t.body(11.5)).foregroundStyle(t.muted).lineLimit(2)
                                }
                            }
                        }
                        }
                    }
                    .padding(18)
                }
            }
        }
        .foregroundStyle(t.ink)
        .background(t.bg)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(t.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 60, y: 40)
        .onExitCommand { store.suite.browserOpen = false }
    }

    private func toolRow(_ tool: ComposerTool) -> some View {
        let on = store.suite.composer.tool == tool && store.screen == .suite && store.suite.mode != .storyboard
        return Button { store.openTool(tool) } label: {
            HStack(spacing: 12) {
                HardwareImage(name: tool.render).frame(width: 40, height: 48).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(tool.title).font(t.body(14, .semibold))
                        if store.isComingSoon(tool) { SuiteTag(text: "Soon") }
                    }
                    Text(tool.tagline).font(t.body(12)).foregroundStyle(t.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                if on { PickCheck() }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? t.surface2 : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tool.title)\(store.isComingSoon(tool) ? ", coming soon" : "")\(on ? ", selected" : "")")
    }
}

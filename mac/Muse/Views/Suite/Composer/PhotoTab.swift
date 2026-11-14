import MuseCore
import SwiftUI

// The Photo tab (owner-approved 2026-11-14, plans/design/photo/): the suite's stage + panel + bar for stills.
// - The panel: Inputs (Character, Outfit, Product, References), each an empty slot with a clear plus and its words, then
//   the Rig for a still (Framing, Lens, Light, Look, Style). A preset sets its own camera and light, so Framing, Lens and
//   Light read "From preset", locked.
// - The bar: a compact Preset chip (a small menu with search and covers, never a whole row), the 1–4 count, the Size pill
//   (the shapes the model makes, from the estimate) and, beside Generate, why it can't go yet.

// MARK: The panel

struct PhotoRail: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SuitePanelTitle(title: "Inputs") { EmptyView() }
                .padding(.bottom, Space.s2)
            PhotoCharacterRow()
            PhotoOutfitRow()
            PhotoProductRow()
            PhotoReferencesRow()
            SuitePanelTitle(title: "Rig", subtitle: store.photoPreset.map { "\($0.name) sets the camera and light" }) {
                SetupRigsRow(asSaveButton: true)
            }
            .padding(.top, Space.s5).padding(.bottom, Space.s2)
            ForEach(PhotoRigRow.Kind.allCases, id: \.self) { PhotoRigRow(kind: $0) }
            VStack(alignment: .leading, spacing: Space.s3) {
                ComposerSentImagesRow() // images sent (server images/sent.ts)
                RigCheckRow()
            }
            .padding(.top, Space.s3)
            Color.clear.frame(height: 1)
                .background { if SnapshotRunner.probing { ComposerBarFrame(key: "photo rail end") } }
        }
    }
}

/// An Inputs row: icon, name, then either the filled value (its picture and name) or an empty slot (a dashed square with a
/// plus and words in ink, so it never reads as faint or disabled), and a caret.
struct PhotoInputRow: View {
    @Environment(\.theme) private var t
    var icon: String
    var name: String
    /// The filled value; nil shows the empty slot with `add`.
    var value: String?
    var thumb: ImageRef? = nil
    var round = false
    /// The empty slot's words ("Add outfit").
    var add: String
    /// The one the photo can't go without: its empty words are underlined.
    var needed = false
    var detail: String? = nil
    var enabled = true
    var help: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s2) {
                Ph(icon, 15).frame(width: 18, height: 18).foregroundStyle(t.roles.ink2)
                Text(name).font(t.scale.label.font).foregroundStyle(t.roles.ink2).lineLimit(1).fixedSize()
                    .frame(minWidth: 72, alignment: .leading)
                HStack(spacing: Space.s2) {
                    if let value {
                        if let thumb {
                            MuseImage(ref: thumb).frame(width: 22, height: 22)
                                .clipShape(round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: t.radii.chip)))
                        }
                        Text(value).font(t.body(13, .medium)).foregroundStyle(t.roles.ink).lineLimit(1).truncationMode(.tail)
                    } else {
                        Ph("plus", 11).foregroundStyle(t.roles.ink)
                            .frame(width: 22, height: 22)
                            .overlay(RoundedRectangle(cornerRadius: t.radii.chip).strokeBorder(t.roles.ink2, style: StrokeStyle(lineWidth: 1.2, dash: [3, 2])))
                        Text(add).font(t.body(13, .medium)).foregroundStyle(t.roles.ink).lineLimit(1).minimumScaleFactor(0.85)
                            .underline(needed, color: t.roles.ink2)
                    }
                    if let detail {
                        Text(detail).font(t.body(13)).foregroundStyle(t.roles.ink2).lineLimit(1).fixedSize()
                    }
                }
                Spacer(minLength: Space.s2)
                Ph("caret-down", 12).foregroundStyle(t.roles.ink2)
            }
            .frame(minHeight: 36)
            .overlay(alignment: .bottom) { Rectangle().fill(t.roles.hairline).frame(height: 1) }
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help ?? "\(name): \(value ?? add)")
        .accessibilityLabel("\(name): \(value ?? add)")
    }
}

/// Character: the studio's cast. Not required (a photo can start from words or an image), but the usual start, so its
/// empty words are underlined.
struct PhotoCharacterRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var open = false

    var body: some View {
        let m = store.composerCharacter
        PhotoInputRow(icon: "user", name: "Character", value: m?.shortName, thumb: m?.cover, round: true, add: "Pick a character", needed: m == nil) { open = true }
            .popover(isPresented: $open, arrowEdge: .leading) {
                PhotoCastList(onPick: { open = false }).environment(store).environment(\.theme, t)
            }
    }
}

/// Outfit: her ready outfits; waits for a character ("Add outfit" makes an outfit set when she has none).
struct PhotoOutfitRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var open = false

    var body: some View {
        let m = store.composerCharacter
        let outfits = store.outfits(for: m)
        let current = outfits.first { $0.id == (store.suite.composer.tokens.outfitId ?? store.suite.composer.outfitId) } ?? outfits.first
        PhotoInputRow(icon: "t-shirt", name: "Outfit", value: current?.name, thumb: current?.angles.compactMap { $0 }.first,
                      add: "Add outfit", enabled: m != nil, help: m == nil ? "Outfit: pick a character first" : nil) {
            if outfits.isEmpty { store.openOutfitSheet(for: m?.id) } else { open = true }
        }
        .popover(isPresented: $open, arrowEdge: .leading) {
            PhotoOutfitList(outfits: outfits, current: current?.id, character: m?.id) { open = false }
                .environment(store).environment(\.theme, t)
        }
    }
}

/// Product (optional): the composer's image slot, as in UGC ad.
struct PhotoProductRow: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let model = store.suite.composerSlots
        let id = SlotId(.image)
        let v = model.slots[id]
        PhotoInputRow(icon: "package", name: "Product", value: v.map { $0.ready ? ($0.name.isEmpty ? "Product" : $0.name) : "Uploading…" }, thumb: v?.image,
                      add: "Add product", detail: nil) { model.pick(id, api: store.api) }
            .contextMenu { if v != nil { Button("Remove the product") { model.clear(id) } } }
    }
}

/// References (optional): up to 3, each guiding the pose, the look or the scene.
struct PhotoReferencesRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var open = false

    var body: some View {
        let refs = store.suite.photo.references
        let feature = store.photoRefsFeature
        let guide = refs.first.flatMap { $0.guides.first }.map { feature.label($0) }
        PhotoInputRow(icon: "images", name: "References", value: refs.isEmpty ? nil : (guide ?? "Reference"), thumb: refs.first?.image,
                      add: "Add up to \(ShootRef.max)", detail: refs.isEmpty ? nil : "\(refs.count) of \(ShootRef.max)") { open = true }
            .popover(isPresented: $open, arrowEdge: .leading) {
                PhotoReferencesPanel().environment(store).environment(\.theme, t)
            }
    }
}

/// Her outfits, and "New outfit set".
struct PhotoOutfitList: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var outfits: [Outfit]
    var current: String?
    var character: String?
    var onPick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Outfits").font(t.body(13, .medium)).foregroundStyle(t.muted).padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
            ForEach(outfits) { o in
                let on = o.id == current
                Button {
                    store.suite.composer.outfitId = o.id
                    onPick()
                } label: {
                    HStack(spacing: 10) {
                        MuseImage(ref: o.angles.compactMap { $0 }.first).frame(width: 32, height: 40).clipShape(RoundedRectangle(cornerRadius: t.imageRadius))
                        Text(o.name).font(t.body(14, on ? .semibold : .regular)).lineLimit(1)
                        Spacer(minLength: 0)
                        if on { Ph("check", 12).foregroundStyle(t.accent) }
                    }
                    .padding(.horizontal, 12).frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(o.name)\(on ? ", selected" : "")")
            }
            LinkText("New outfit set", size: 13) {
                onPick()
                store.openOutfitSheet(for: character)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 260, alignment: .leading)
        .foregroundStyle(t.ink)
    }
}

/// The Rig for a still: Framing (shot size), Lens (focal and aperture), Light, Look and Style. No movement, tempo or length.
struct PhotoRigRow: View {
    @Environment(AppStore.self) private var store
    var kind: Kind

    enum Kind: CaseIterable { case framing, lens, light, look, style }

    var body: some View {
        let d = store.suite.composer
        let locked = kind != .look && kind != .style && store.suite.photo.presetId != nil
        let v = locked ? ("From preset", true) : Self.value(kind, store)
        SuiteRow(icon: icon, name: name, value: v.0, quiet: v.1, enabled: !locked,
                 help: locked ? "\(name) comes from the preset" : nil) {
            switch kind {
            case .framing: store.openPicker(.camera, step: "angle")
            case .lens: store.openPicker(.camera, step: "setup")
            case .light: store.openPicker(.lighting)
            case .look: store.openPicker(.look)
            case .style: store.openPicker(.style)
            }
        }
        .disabled(d.directed != nil && (kind == .framing || kind == .lens))
    }

    private var name: String {
        switch kind {
        case .framing: return "Framing"
        case .lens: return "Lens"
        case .light: return "Light"
        case .look: return "Look"
        case .style: return "Style"
        }
    }

    private var icon: String {
        switch kind {
        case .framing: return "frame-corners"
        case .lens: return "aperture"
        case .light: return "sun"
        case .look: return "palette"
        case .style: return "sliders-horizontal"
        }
    }

    /// The row's value and whether it is on Auto ("Auto": the house defaults; Look: "House grade").
    @MainActor static func value(_ kind: Kind, _ store: AppStore) -> (String, Bool) {
        let d = store.suite.composer
        let s = d.settings
        let cat = store.suite.camera
        if d.directed != nil && (kind == .framing || kind == .lens) { return ("Directed", false) }
        let parts: [String]
        switch kind {
        case .framing: parts = [ComposerCatalog.label(cat.shotSizes, s.shotSize), ComposerCatalog.label(cat.heights, s.height)].compactMap { $0 }
        case .lens:
            parts = [s.focalMm.map { ComposerCatalog.focalLabel(cat, $0) }, ComposerCatalog.label(cat.apertures, s.aperture),
                     ComposerCatalog.label(cat.lenses, s.lens), ComposerCatalog.label(cat.bodies, s.body)].compactMap { $0 }
        case .light: parts = [ComposerCatalog.label(cat.lighting, s.lighting)].compactMap { $0 }
        case .look:
            parts = [ComposerCatalog.label(cat.palettes, s.palette), ComposerCatalog.label(cat.looks, s.stock)].compactMap { $0 }
            if parts.isEmpty { return ("House grade", true) }
        case .style: parts = [ComposerCatalog.label(cat.genres, s.genre), ComposerCatalog.label(cat.eras, s.era)].compactMap { $0 }
        }
        return parts.isEmpty ? ("Auto", true) : (parts.joined(separator: " · "), false)
    }
}

// MARK: The bar

/// "Preset": a small menu of the photo presets (search, covers, names). Picked, the chip shows its name, outlined.
struct PhotoPresetPill: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var compact = false
    @State private var open = false

    var body: some View {
        let picked = store.photoPreset
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Ph("images", 13).frame(width: 16, height: 16).foregroundStyle(t.roles.ink2)
                if !compact || picked != nil {
                    Text(picked?.name ?? "Preset").font(t.body(13, .medium)).foregroundStyle(t.roles.ink).lineLimit(1).fixedSize()
                }
                Ph("caret-down", 9).foregroundStyle(t.roles.ink2)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: t.radii.control).fill(picked != nil ? t.roles.raised : (open ? t.roles.hairline : t.roles.field)))
            .overlay {
                if picked != nil { RoundedRectangle(cornerRadius: t.radii.control).strokeBorder(t.roles.action, lineWidth: 1) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .background { if SnapshotRunner.probing { ComposerBarFrame(key: "pill preset") } }
        .help(picked.map { "Preset: \($0.name)" } ?? "Start from a preset")
        .accessibilityLabel(picked.map { "Preset: \($0.name)" } ?? "Preset: none")
        .popover(isPresented: $open, arrowEdge: .top) {
            PhotoPresetMenu { open = false }.environment(store).environment(\.theme, t)
        }
    }
}

/// The preset menu: search, the covers in a grid, and "No preset" (back to your own rig).
struct PhotoPresetMenu: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var onPick: () -> Void
    @State private var query = ""

    var body: some View {
        let all = store.templates
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? all : all.filter { $0.name.lowercased().contains(q) }
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s2) {
                Ph("magnifying-glass", 13).foregroundStyle(t.roles.ink2)
                TextField("Search presets", text: $query).textFieldStyle(.plain).font(t.body(13))
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: t.radii.control).fill(t.roles.field))
            if all.isEmpty {
                Text("No photo presets yet. Save a photo as a template and it shows up here.")
                    .font(t.body(13)).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s2, alignment: .top), count: 3), spacing: Space.s3) {
                        ForEach(list) { tpl in
                            PhotoPresetTile(template: tpl, selected: store.suite.photo.presetId == tpl.id, width: 100) {
                                store.choosePhotoPreset(tpl)
                                onPick()
                            }
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 360)
            }
            HStack {
                Button {
                    store.suite.photo.presetId = nil
                    onPick()
                } label: {
                    Text("No preset: use the rig").font(t.body(12.5)).foregroundStyle(store.suite.photo.presetId == nil ? t.roles.ink2 : t.roles.ink)
                }
                .buttonStyle(.plain)
                .disabled(store.suite.photo.presetId == nil)
                Spacer()
                LinkText("All templates", size: 12.5) {
                    onPick()
                    store.openTemplates()
                }
            }
            .padding(.top, Space.s1)
            .overlay(alignment: .top) { Rectangle().fill(t.roles.hairline).frame(height: 1).offset(y: -Space.s2) }
        }
        .padding(Space.s3)
        .frame(width: 348, alignment: .leading)
        .foregroundStyle(t.roles.ink)
        .task { if store.templates.isEmpty { await store.loadTemplates() } }
    }
}

/// Photos 1–4 as a small segmented control.
struct PhotoCountControl: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var compact = false

    var body: some View {
        let n = store.suite.photo.count
        HStack(spacing: 2) {
            HStack(spacing: 6) {
                Ph("stack", 13).frame(width: 16, height: 16).foregroundStyle(t.roles.ink2)
                if !compact { Text("Photos").font(t.body(13)).foregroundStyle(t.roles.ink2).lineLimit(1).fixedSize() }
            }
            .padding(.leading, 8).padding(.trailing, 4)
            ForEach(PhotoDraft.counts, id: \.self) { c in
                let on = c == n
                Button { store.suite.photo.count = c } label: {
                    Text("\(c)").font(t.body(13, on ? .semibold : .medium)).monospacedDigit()
                        .foregroundStyle(on ? t.roles.ink : t.roles.ink2)
                        .frame(width: 24, height: 26)
                        .background(RoundedRectangle(cornerRadius: t.radii.control - 1).fill(on ? t.roles.raised : .clear))
                        .overlay { if on { RoundedRectangle(cornerRadius: t.radii.control - 1).strokeBorder(t.roles.hairline, lineWidth: 1) } }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(PhotoEstimate.photos(c))\(on ? ", selected" : "")")
            }
        }
        .padding(2)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: t.radii.control).fill(t.roles.field))
        .fixedSize()
        .background { if SnapshotRunner.probing { ComposerBarFrame(key: "pill photos") } }
        .help("Photos in this run")
    }
}

/// Size: the photo's shape, with what this model makes for it. Hidden until the server lists the shapes (an older server
/// has no size choice).
struct PhotoSizePill: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var open = false

    var body: some View {
        let options = store.photoAspects
        if !options.isEmpty {
            let shown = store.suite.photo.shownAspect
            Button { open.toggle() } label: {
                SuitePillLabel(icon: "frame-corners", value: shown, open: open)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .background { if SnapshotRunner.probing { ComposerBarFrame(key: "pill size") } }
            .help("Size: \(shown)")
            .accessibilityLabel("Size: \(shown)")
            .popover(isPresented: $open, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Size").font(t.body(13, .medium)).foregroundStyle(t.roles.ink2).padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
                    ForEach(options) { o in
                        let on = o.id == shown
                        Button {
                            store.suite.photo.aspect = o.id == "9:16" ? nil : o.id
                            open = false
                        } label: {
                            HStack(spacing: 10) {
                                Text(o.label).font(t.body(13, on ? .semibold : .regular)).foregroundStyle(t.roles.ink).lineLimit(1)
                                Spacer(minLength: 0)
                                if on { Ph("check", 12).foregroundStyle(t.roles.ink) }
                            }
                            .padding(.horizontal, 12).frame(minHeight: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 6)
                .frame(width: 220, alignment: .leading)
                .environment(\.theme, t)
            }
        }
    }
}

extension AppStore {
    /// The Size pill's shapes: the estimate's (with what this model makes), kept from the last estimate while the next one
    /// is on its way; none from an older server.
    var photoAspects: [PhotoAspectOption] {
        if let list = suite.photoEstimate?.aspects, !list.isEmpty { return list }
        return suite.photoAspectsSeen
    }

    /// Why Photo's Generate can't go now (nil: it can, at the estimate's price), shown beside it.
    var photoBlocker: String? {
        let uploading = suite.photoRefsUploading > 0 || suite.composerSlots.slots.uploading
        if let need = suite.composer.photoMissing(suite.photo, uploading: uploading) { return need }
        if let e = suite.photoError { return e }
        if let e = suite.photoEstimate, !e.ok { return e.warnings.first ?? "These photos can't be made as set" }
        return nil
    }

    /// "Auto · Nano Banana": the model Auto picked, from the estimate; a model picked on the pill keeps its own name.
    var photoModelLabel: String {
        let base = ComposerModelPicker.imageLabel(suite.photo, catalog: suite.catalog)
        guard suite.photo.imageModel == nil, let name = suite.photoEstimate?.model?.name ?? suite.photoModelSeen else { return base }
        return "Auto · \(name)"
    }
}

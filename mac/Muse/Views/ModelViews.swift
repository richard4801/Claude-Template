import MuseCore
import SwiftUI

/// One character-sheet slot: image with a yours/AI tag, hover actions, and a drop target for an image file.
struct SheetSlotTile: View {
    @Environment(\.theme) private var t
    var label: String
    var ref: ImageRef?
    var ai = false
    var busy = false
    var primary = "Replace"
    var secondary: String?
    var onPrimary: () -> Void
    var onSecondary: () -> Void = {}
    var onDrop: (URL) -> Void
    var moveTargets: [SheetAngle] = []
    var onMove: (SheetAngle) -> Void = { _ in }
    @State private var hover = false
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if busy {
                    SkeletonBlock(ratio: 0.75, radius: t.radii.container)
                } else if let ref {
                    // Only the AI-made shots carry a tag; your own images need none.
                    MediaFrame(ref: ref, ratio: 0.75, selected: targeted) {
                        if ai { StateTag("AI", .onMedia) }
                    }
                    .overlay {
                        if hover || targeted {
                            ZStack {
                                Color.black.opacity(0.45)
                                VStack(spacing: 6) {
                                    if targeted {
                                        Text("Drop to replace").font(t.scale.label.font).foregroundStyle(.white)
                                    } else {
                                        HoverChip(primary, action: onPrimary)
                                        if let secondary { HoverChip(secondary, action: onSecondary) }
                                    }
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: t.radii.container, style: .continuous))
                            .transition(.opacity)
                        }
                    }
                    .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
                    // The hover buttons can't be reached without a mouse: VoiceOver gets them as actions.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(label)
                    .accessibilityAction(named: Text(primary), onPrimary)
                    .if(secondary != nil) { $0.accessibilityAction(named: Text(secondary ?? ""), onSecondary) }
                    .contextMenu {
                        Button(primary, action: onPrimary)
                        if let secondary { Button(secondary, action: onSecondary) }
                        if !moveTargets.isEmpty {
                            Menu("Move to") {
                                ForEach(moveTargets) { a in Button(a.label) { onMove(a) } }
                            }
                        }
                    }
                } else {
                    Button(action: onPrimary) {
                        let shape = RoundedRectangle(cornerRadius: t.radii.container, style: .continuous)
                        Color.clear.aspectRatio(0.75, contentMode: .fit)
                            .background(shape.fill(t.roles.field))
                            .overlay(shape.strokeBorder(targeted ? t.roles.selection : t.roles.hairline,
                                                        style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: targeted ? [] : [5, 4])))
                            .overlay(Text(targeted ? "Drop to add" : "Add").scaled(t.scale.caption, t.roles.ink2))
                            .contentShape(shape)
                    }
                    .buttonStyle(.plain)
                    .help("Add \(label)")
                    .accessibilityLabel("Add \(label)")
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let u = urls.first else { return false }
                onDrop(u)
                return true
            } isTargeted: { targeted = $0 }
            Text(label).scaled(t.scale.caption, t.roles.ink2)
        }
    }
}

struct HoverChip: View {
    var text: String
    var action: () -> Void
    init(_ text: String, action: @escaping () -> Void) {
        self.text = text
        self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0x111111))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(.white))
        }
        .buttonStyle(.plain)
    }
}

/// Her page's tabs (plans/model-world.md, mockup 1). People and Pets come in later phases; their tabs say what they'll hold.
enum ProfileTab: String, CaseIterable, Identifiable {
    case profile, wardrobe, places, people, pets
    var id: String { rawValue }
    var title: String {
        switch self {
        case .profile: return "Profile"
        case .wardrobe: return "Wardrobe"
        case .places: return "Places"
        case .people: return "People"
        case .pets: return "Pets"
        }
    }
}

struct ProfileView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var newNever = ""
    @State private var addingNever = false
    @State private var allAngles = false
    @FocusState private var neverFocused: Bool

    var body: some View {
        if let m = store.profileModel {
            ScrollViewReader { proxy in
            ScreenPage {
                Crumb(parent: "Models", title: m.name) { store.go(.models) }
                header(m)
                tabs(m)
                switch store.profileTab {
                case .profile: profileTab(m)
                case .wardrobe: wardrobeTab(m)
                case .places: PlacesTab(model: m, openId: Binding(get: { store.profilePlaceId }, set: { store.profilePlaceId = $0 }))
                case .people:
                    WorldEmpty(icon: "users", title: "No people yet",
                               message: "Her sister, a brother, a best friend. Each gets a few photos and their own outfits, and you can @tag them.")
                case .pets:
                    WorldEmpty(icon: "paw-print", title: "No pets yet", message: "Her dog or cat: a few photos and a name to @tag in a prompt.")
                }
            }
            .task(id: m.id) { await store.reloadPlaces() }
            // Review screenshots only (SnapshotRunner): scroll to an anchor (Her world).
            .onChange(of: SnapshotRunner.state.scrollTo) { _, id in if let id { proxy.scrollTo(id, anchor: .top) } }
            }
        } else if store.loading {
            ScreenPage {
                HStack(alignment: .center, spacing: Space.s4) {
                    SkeletonBlock(width: 72, height: 72, radius: 36)
                    SkeletonBlock(width: 220, height: 24)
                }
                .padding(.bottom, Space.s5)
                SkeletonGrid(columns: 5, count: 5, ratio: 0.75)
            }
        } else {
            ScreenPage {
                EmptyState("No model yet", "A model is a character you build from your own reference images.", actionTitle: "New model", actionKind: .action) { store.go(.create) }
            }
        }
    }

    // MARK: Header and tabs

    private func header(_ m: MuseModel) -> some View {
        HStack(alignment: .center, spacing: Space.s4) {
            Group {
                if let c = m.cover {
                    MuseImage(ref: c)
                } else {
                    t.roles.field.overlay(Text(m.initial).font(t.scale.heading.font).foregroundStyle(t.roles.ink2))
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(Circle())
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(m.name).scaled(t.scale.display, t.roles.ink).lineLimit(1).accessibilityAddTraits(.isHeader)
                Text(lookLine(m)).scaled(t.scale.caption, t.roles.ink2).lineLimit(2)
            }
            Spacer(minLength: Space.s4)
            // Photoshoot is the AI suite's Photo tool (workstream 3): it opens with her preselected.
            Button {
                store.selectModel(m)
                store.openPhoto(model: m.id)
            } label: { Label("Photo", ph: "camera") }
                .buttonStyle(RButtonStyle(kind: .quiet))
            // The AI Suite's Shot tool with her as the character (the one primary action on her page).
            Button {
                store.selectModel(m)
                store.openTool(.shot)
                store.setComposerCharacter(m)
            } label: { Label("New shot", ph: "video-camera") }
                .buttonStyle(RButtonStyle(kind: .action))
            MoreMenu {
                Button("Edit character sheet") { store.uploadSheet(m) }
                Button("Identity LoRA") { store.openLora(m.id) }
                Button("Add outfit") { store.openOutfitSheet(for: m.id) }
                Button("Enhance character sheet") { store.openEnhance(m) }
                Button("Previous sheet versions") { store.openVersions(m.id) }
                Button("Duplicate model") { store.duplicate(m) }
                Button("Share profile card") { store.shareProfileCard(m) }
                Divider()
                if store.isOwner { Button("Archive model…") { store.archiveModel(m) } }
                Button("Delete model…", role: .destructive) { store.deleteModel(m) }
            }
        }
        .padding(.bottom, Space.s5)
    }

    private func lookLine(_ m: MuseModel) -> String {
        let look = m.look.trimmingCharacters(in: .whitespacesAndNewlines)
        let sheet = m.isLocked ? "Identity locked, \(ScreenCopy.count(m.filled, "photo"))" : ScreenCopy.count(m.filled, "photo")
        return look.isEmpty ? sheet : "\(look.hasSuffix(".") ? look : look + ".") \(sheet)"
    }

    private func count(_ tab: ProfileTab, _ m: MuseModel) -> Int? {
        switch tab {
        case .wardrobe: let n = store.outfits(for: m).count; return n > 0 ? n : nil
        case .places: let n = store.places(for: m).count; return n > 0 ? n : nil
        default: return nil
        }
    }

    private func tabs(_ m: MuseModel) -> some View {
        HStack(spacing: Space.s5) {
            ForEach(ProfileTab.allCases) { k in
                let on = store.profileTab == k
                Button { store.profileTab = k } label: {
                    VStack(spacing: Space.s2) {
                        HStack(spacing: Space.s1) {
                            Text(k.title).scaled(t.scale.label, on ? t.roles.ink : t.roles.ink2)
                            if let n = count(k, m) { Text("\(n)").monospacedDigit().scaled(t.scale.caption, t.roles.ink2) }
                        }
                        Rectangle().fill(on ? t.roles.accent : .clear).frame(height: 2)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer()
            if store.profileTab == .places && !store.places(for: m).isEmpty {
                Button {
                    guard let name = store.askPlaceName() else { return }
                    Task { if let l = await store.newPlace(for: m, name: name) { store.profilePlaceId = l.id } }
                } label: { Label("Add a place", ph: "plus") }
                    .buttonStyle(RButtonStyle(kind: .plain, small: true))
                    .padding(.bottom, Space.s2)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(t.roles.hairline).frame(height: 1) }
    }

    // MARK: Profile tab: her photos, her world, and about her

    private func profileTab(_ m: MuseModel) -> some View {
        HStack(alignment: .top, spacing: Space.s6) {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle("Her photos", top: Space.s5) {
                    HStack(spacing: Space.s2) {
                        RButton("Upload images", kind: .plain, small: true) { store.uploadSheet(m) }
                        if store.toolsFeatures?.enhance.available ?? false {
                            RButton("Enhance", kind: .plain, small: true) { store.openEnhance(m) }
                        }
                        RButton("Versions", kind: .plain, small: true) { store.openVersions(m.id) }
                    }
                }
                // Mockup 1: one row (face front and ¾, full body front and ¾, her first outfit); every angle on demand.
                if allAngles {
                    VStack(alignment: .leading, spacing: Space.s5) {
                        sheetGroup(m, "Face close-ups", SheetAngle.faceGroup)
                        sheetGroup(m, "Full body", SheetAngle.bodyGroup)
                    }
                    .dropDestination(for: URL.self) { urls, _ in
                        store.uploadSheet(m, urls: urls)
                        return true
                    }
                } else {
                    photoRow(m)
                }
                RButton(allAngles ? "Show fewer" : "All \(SheetAngle.allCases.count) angles", kind: .plain, small: true) { allAngles.toggle() }
                    .padding(.top, Space.s2)
                if !m.hasBothFaces && m.filled > 0 {
                    InlineNotice("No \(m.slot("face")?.image == nil ? "face" : "profile") close-up yet. Faces come out softer without both close-ups.", tone: .caution,
                                 actionTitle: "Upload images") { store.uploadSheet(m) }
                        .padding(.top, Space.s4)
                }
                herWorld(m).id("profile.world")
                ProfileAccounts(model: m)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            about(m).frame(width: 300, alignment: .leading)
        }
    }

    /// "Her world": a row each for places, people and pets; a row opens its tab.
    private func herWorld(_ m: MuseModel) -> some View {
        let places = store.places(for: m)
        return VStack(alignment: .leading, spacing: 0) {
            SectionTitle("Her world")
            Text("Places, people and pets keep her videos consistent. Type @ in any prompt to use them.").scaled(t.scale.caption, t.roles.ink2)
                .padding(.bottom, Space.s3)
            worldRow(icon: "map-pin", title: "Places", summary: Places.summary(places), thumbs: places.prefix(4).compactMap(\.coverImage)) { store.profileTab = .places }
            worldRow(icon: "users", title: "People", summary: "None yet", thumbs: []) { store.profileTab = .people }
            worldRow(icon: "paw-print", title: "Pets", summary: "None yet", thumbs: []) { store.profileTab = .pets }
        }
    }

    private func worldRow(icon: String, title: String, summary: String, thumbs: [ImageRef], open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: Space.s4) {
                Ph(icon, 15).foregroundStyle(t.roles.ink2).frame(width: 20)
                Text(title).scaled(t.scale.label, t.roles.ink).frame(width: 72, alignment: .leading)
                Text(summary).scaled(t.scale.caption, t.roles.ink2).lineLimit(1)
                Spacer(minLength: Space.s3)
                HStack(spacing: Space.s1) {
                    ForEach(Array(thumbs.enumerated()), id: \.offset) { _, r in
                        MuseImage(ref: r).frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous))
                    }
                }
                Ph("caret-right", 12).foregroundStyle(t.roles.ink2)
            }
            .frame(minHeight: 56)
            .overlay(alignment: .top) { Rectangle().fill(t.roles.hairline).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title): \(summary)")
        .accessibilityHint("Opens the \(title) tab")
    }

    /// The right column: niche, personality, notes, never add, then her LoRA and accounts.
    private func about(_ m: MuseModel) -> some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            detail("Niche", m.niche)
            detail("Personality", m.personality)
            if !m.notes.isEmpty { detail("Notes", m.notes) }
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("Never add").scaled(t.scale.caption, t.roles.ink2)
                FlowLayout(spacing: Space.s2) {
                    ForEach(Array(store.neverList(m).enumerated()), id: \.offset) { i, item in
                        RemovableTag(text: item) { store.removeNever(m, at: i) }
                    }
                    if addingNever {
                        TextField("e.g. necklaces", text: $newNever)
                            .focused($neverFocused)
                            .frame(width: 140)
                            .roleField(focused: neverFocused)
                            .onAppear { neverFocused = true }
                            .onSubmit {
                                store.addNever(m, newNever)
                                newNever = ""
                                addingNever = false
                            }
                            .onExitCommand { addingNever = false }
                    } else {
                        RIconButton(systemName: "plus", help: "Add something she never has") { addingNever = true }
                    }
                }
                Text("Removed from every render").scaled(t.scale.micro, t.roles.ink2)
            }
            loraRow(m)
        }
        .padding(.top, Space.s5)
    }

    /// The five photos of mockup 1: hover to replace or retake a sheet photo, as on the full sheet.
    private func photoRow(_ m: MuseModel) -> some View {
        let outfit = store.outfits(for: m).first
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s3), count: 5), alignment: .leading, spacing: Space.s3) {
            ForEach([SheetAngle.face, .faceTq, .front, .tq]) { a in
                let sl = m.slot(a.rawValue)
                SheetSlotTile(label: a.label, ref: sl?.image, ai: sl?.isAI ?? false, busy: sl?.busy ?? false, primary: "Replace", secondary: "Retake with AI",
                              onPrimary: { store.replaceSlot(m, a) }, onSecondary: { store.retakeSlot(m, a) }, onDrop: { store.replaceSlot(m, a, with: $0) })
            }
            if let o = outfit {
                MediaTile(ref: o.angles.compactMap { $0 }.first, ratio: 0.75, caption: "Outfit, \(o.name)")
            }
        }
    }

    /// Mockup 1's right column: her LoRA as one quiet row that opens its page.
    private func loraRow(_ m: MuseModel) -> some View {
        let l = store.lora(for: m)
        return Button { store.openLora(m.id) } label: {
            HStack(spacing: Space.s3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Identity LoRA").scaled(t.scale.label, t.roles.ink)
                    Text(store.loraLine(l)).scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.s2)
                Ph("caret-right", 12).foregroundStyle(t.roles.ink2)
            }
            .padding(.vertical, Space.s3)
            .overlay(alignment: .top) { Rectangle().fill(t.roles.hairline).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Identity LoRA: \(store.loraLine(l))")
        .accessibilityHint("Opens the LoRA page")
    }

    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).scaled(t.scale.caption, t.roles.ink2)
            Text(value.isEmpty ? "—" : value).scaled(t.scale.body, t.roles.ink).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Wardrobe tab: her outfit folders

    private func wardrobeTab(_ m: MuseModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle("Outfits", top: Space.s5) {
                RButton("Add outfit", small: true) { store.openOutfitSheet(for: m.id) }
            }
            if store.outfits(for: m).isEmpty {
                EmptyState("No outfits yet", "Describe one, use a product photo, or upload your own four angles.", actionTitle: "Add outfit", actionKind: .action) {
                    store.openOutfitSheet(for: m.id)
                }
            } else {
                // Folders (plans/outfit-head-looks.md §4): the front only, 8 per page across the full width, "‹ 1 of 3 ›".
                OutfitFolders(model: m)
            }
        }
    }
}

extension ProfileView {
    /// One group of the character sheet (face close-ups, or the full body).
    func sheetGroup(_ m: MuseModel, _ title: String, _ angles: [SheetAngle]) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(title).scaled(t.scale.label, t.roles.ink)
            // Four columns for both groups, so every tile is the same size.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s3), count: 4), alignment: .leading, spacing: Space.s3) {
                ForEach(angles) { a in
                    let s = m.slot(a.rawValue)
                    SheetSlotTile(label: a.label, ref: s?.image, ai: s?.isAI ?? false, busy: s?.busy ?? false, primary: "Replace", secondary: "Retake with AI",
                                  onPrimary: { store.replaceSlot(m, a) }, onSecondary: { store.retakeSlot(m, a) }, onDrop: { store.replaceSlot(m, a, with: $0) })
                }
            }
        }
    }
}

struct CreateModelView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var store = store
        let c = store.create
        ScreenPage {
            Crumb(parent: "Models", title: "New model") { store.cancelCreate() }
            if c.step == 1 {
                ScreenTitle("New model", subtitle: "Step 1 of 2: the basics")
                VStack(alignment: .leading, spacing: Space.s5) {
                    RField("Name") { RTextField(placeholder: "e.g. Noor", text: $store.create.name) }
                    RField("Age", hint: "Characters must be clearly adult (18+)") {
                        HStack(spacing: Space.s2) {
                            RIconButton(systemName: "minus", help: "Younger") { store.create.age = max(18, c.age - 1) }
                            Text("\(c.age)").monospacedDigit().scaled(t.scale.body, t.roles.ink).frame(minWidth: 32)
                                .accessibilityLabel("Age \(c.age)")
                            RIconButton(systemName: "plus", help: "Older") { store.create.age = min(70, c.age + 1) }
                        }
                    }
                    RField("Niche") {
                        FlowLayout(spacing: Space.s2) {
                            ForEach(Niches.all, id: \.self) { n in ChoiceChip(n, on: c.niche == n) { store.create.niche = n } }
                        }
                    }
                    RField("Personality", hint: "Optional") {
                        RTextField(placeholder: "e.g. warm, a little dry, morning-routine energy", text: $store.create.personality)
                    }
                    RField("Notes", hint: "Optional") {
                        RTextBox(placeholder: "Anything about the look you want kept", text: $store.create.notes, lines: 3)
                    }
                    HStack(spacing: Space.s2) {
                        RButton("Next: character sheet", kind: .action) { store.createNext() }
                            .keyboardShortcut(.defaultAction)
                        RButton("Cancel", kind: .plain) { store.cancelCreate() }
                            .keyboardShortcut(.cancelAction)
                    }
                    .padding(.top, Space.s2)
                }
                .frame(maxWidth: 560, alignment: .leading)
            } else {
                ScreenTitle("Character sheet", subtitle: "Step 2 of 2: \(c.name.isEmpty ? "untitled model" : c.name)") {
                    RButton("Back") { store.createBack() }
                    RButton(c.busy ? "Saving…" : "Save model", kind: .action, off: c.busy) { store.createSave() }
                }
                Button {
                    store.addDraftImages(MediaImport.pick(MediaImport.imageTypes, multiple: true, prompt: "Add images"))
                } label: {
                    DropZone(title: "Drop your reference images here",
                             hint: "Or choose files. We sort them into the slots below, and you can move any image to another slot.",
                             buttonTitle: "Choose files", targeted: dropTargeted)
                }
                .buttonStyle(.plain)
                .dropDestination(for: URL.self) { urls, _ in
                    store.addDraftImages(urls)
                    return true
                } isTargeted: { dropTargeted = $0 }

                SectionTitle("\(c.filled) of \(SheetAngle.allCases.count) shots") {
                    Text("Two face close-ups give the sharpest face").scaled(t.scale.caption, t.roles.ink2)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s3), count: 7), alignment: .leading, spacing: Space.s3) {
                    ForEach(SheetAngle.faceGroup + SheetAngle.bodyGroup) { a in
                        let slot = c.slots[a]
                        SheetSlotTile(label: a.label, ref: ref(slot), ai: isAI(slot), busy: slot == .busy, primary: "Replace", secondary: "Remove",
                                      onPrimary: { store.setDraftSlot(a) }, onSecondary: { store.clearDraftSlot(a) }, onDrop: { store.setDraftSlot(a, $0) },
                                      moveTargets: SheetAngle.allCases.filter { $0 != a }, onMove: { store.moveDraftSlot(a, to: $0) })
                    }
                }
                if c.faces < 2 && c.filled > 0 {
                    InlineNotice("No \(c.faces > 0 ? "profile" : "face") close-up yet. You can still save, but faces come out softer without both close-ups.", tone: .caution)
                        .padding(.top, Space.s4)
                }
                if c.filled > 0 && c.filled < SheetAngle.allCases.count && !c.busy {
                    let missing = SheetAngle.allCases.count - c.filled
                    HStack(spacing: Space.s4) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Fill the missing angles").scaled(t.scale.label, t.roles.ink)
                            Text("Optional. Makes the \(ScreenCopy.count(missing, "empty angle")) from the images you added.").scaled(t.scale.caption, t.roles.ink2)
                        }
                        Spacer()
                        OwnerModelPill(purpose: .character, compact: true) // the owner's model-photo model (WS6)
                        RButton("Fill \(missing) · \(Pricing.money(store.sheetAnglesEstimate(missing)))") { store.fillMissing() }
                    }
                    .padding(.top, Space.s5)
                }
            }
        }
    }

    private func ref(_ s: DraftSlot?) -> ImageRef? {
        switch s {
        case .local(let u)?: return ImageRef(url: u.absoluteString)
        case .remote(let r, _)?: return r
        default: return nil
        }
    }

    private func isAI(_ s: DraftSlot?) -> Bool {
        if case .remote(_, let ai)? = s { return ai }
        return false
    }
}

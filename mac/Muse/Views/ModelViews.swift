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

struct ProfileView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var newNever = ""
    @State private var addingNever = false
    @FocusState private var neverFocused: Bool

    var body: some View {
        if let m = store.profileModel {
            ScreenPage {
                Crumb(parent: "Models", title: m.name) { store.go(.models) }
                HStack(alignment: .top, spacing: Space.s6) {
                    left(m).frame(width: 280)
                    right(m).frame(maxWidth: .infinity, alignment: .leading) // the outfit folders fill the width (§4)
                }
            }
        } else if store.loading {
            ScreenPage {
                HStack(alignment: .top, spacing: Space.s6) {
                    SkeletonBlock(ratio: 0.75, radius: t.radii.container).frame(width: 280)
                    VStack(alignment: .leading, spacing: Space.s4) {
                        SkeletonBlock(width: 220, height: 24)
                        SkeletonGrid(columns: 4, count: 8, ratio: 0.75)
                    }
                }
            }
        } else {
            ScreenPage {
                EmptyState("No model yet", "A model is a character you build from your own reference images.", actionTitle: "New model", actionKind: .action) { store.go(.create) }
            }
        }
    }

    private func left(_ m: MuseModel) -> some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            if let c = m.cover {
                MediaFrame(ref: c, ratio: 0.75)
            } else {
                let shape = RoundedRectangle(cornerRadius: t.radii.container, style: .continuous)
                Color.clear.aspectRatio(0.75, contentMode: .fit).background(shape.fill(t.roles.field))
                    .overlay(Text(m.initial).font(t.scale.display.font).foregroundStyle(t.roles.ink2))
            }
            HStack(spacing: Space.s2) {
                // The AI Suite's Shot tool with her as the character (the classic studio is gone, owner 2026-11-08).
                RButton("Shot", kind: .action, fill: true) {
                    store.selectModel(m)
                    store.openTool(.shot)
                    store.setComposerCharacter(m)
                }
                // Photoshoot is the AI suite's Photo tool now (workstream 3): it opens with her preselected.
                RButton("Photo", fill: true) {
                    store.selectModel(m)
                    store.openPhoto(model: m.id)
                }
                MoreMenu {
                    Button("Edit character sheet") { store.uploadSheet(m) }
                    Button("Identity LoRA") { store.openLora(m.id) }
                    Button("Add outfit") { store.openOutfitSheet(for: m.id) }
                    Button("Enhance character sheet") { store.openEnhance(m) }
                    Button("Dress up") { store.openDressUp(m) }
                    Button("Previous sheet versions") { store.openVersions(m.id) }
                    Button("Duplicate model") { store.duplicate(m) }
                    Button("Share profile card") { store.shareProfileCard(m) }
                    Divider()
                    if store.isOwner { Button("Archive model…") { store.archiveModel(m) } }
                    Button("Delete model…", role: .destructive) { store.deleteModel(m) }
                }
            }
            VStack(alignment: .leading, spacing: Space.s3) {
                detail("Niche", m.niche)
                detail("Personality", m.personality)
                detail("Notes", m.notes)
            }
            .padding(.top, Space.s2)
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).scaled(t.scale.caption, t.roles.ink2)
            Text(value.isEmpty ? "—" : value).scaled(t.scale.body, t.roles.ink).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func right(_ m: MuseModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(m.name).scaled(t.scale.display, t.roles.ink).accessibilityAddTraits(.isHeader)
            SectionTitle("Character sheet", top: Space.s5) { RButton("Versions", kind: .plain, small: true) { store.openVersions(m.id) } }
            HStack(spacing: Space.s2) {
                Text("Hover a shot to replace it, or drop an image on it.").scaled(t.scale.caption, t.roles.ink2)
                Spacer(minLength: Space.s2)
                RButton("Upload images", small: true) { store.uploadSheet(m) }
                if store.toolsFeatures?.enhance.available ?? false {
                    RButton("Enhance", small: true) { store.openEnhance(m) }
                }
                if store.toolsFeatures?.dressUp.available ?? false {
                    RButton("Dress up", small: true) { store.openDressUp(m) }
                }
            }
            .padding(.bottom, Space.s4)
            VStack(alignment: .leading, spacing: Space.s5) {
                sheetGroup(m, "Face close-ups", SheetAngle.faceGroup)
                sheetGroup(m, "Full body", SheetAngle.bodyGroup)
            }
            .dropDestination(for: URL.self) { urls, _ in
                store.uploadSheet(m, urls: urls)
                return true
            }
            if !m.hasBothFaces && m.filled > 0 {
                InlineNotice("No \(m.slot("face")?.image == nil ? "face" : "profile") close-up yet. Faces come out softer without both close-ups.", tone: .caution,
                             actionTitle: "Upload images") { store.uploadSheet(m) }
                    .padding(.top, Space.s4)
            }

            ProfileLoraCard(model: m)
            ProfileAccounts(model: m)

            SectionTitle("Outfits") {
                RButton("Add outfit", small: true) { store.openOutfitSheet(for: m.id) }
            }
            let fits = store.outfits(for: m)
            if fits.isEmpty {
                Text("No outfits yet. Describe one, use a product photo, or upload your own four angles.").scaled(t.scale.body, t.roles.ink2)
            }
            // Folders (plans/outfit-head-looks.md §4): the front only, 8 per page across the full width, "‹ 1 of 3 ›".
            if !fits.isEmpty { OutfitFolders(model: m) }

            SectionTitle("Never add") { Text("Removed from every render").scaled(t.scale.caption, t.roles.ink2) }
            FlowLayout(spacing: Space.s2) {
                ForEach(Array(store.neverList(m).enumerated()), id: \.offset) { i, item in
                    RemovableTag(text: item) { store.removeNever(m, at: i) }
                }
                if addingNever {
                    TextField("e.g. necklaces", text: $newNever)
                        .focused($neverFocused)
                        .frame(width: 160)
                        .roleField(focused: neverFocused)
                        .onAppear { neverFocused = true }
                        .onSubmit {
                            store.addNever(m, newNever)
                            newNever = ""
                            addingNever = false
                        }
                        .onExitCommand { addingNever = false }
                } else {
                    RButton("Add", small: true) { addingNever = true }
                }
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

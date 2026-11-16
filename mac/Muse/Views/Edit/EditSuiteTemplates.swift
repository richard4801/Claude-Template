import AVFoundation
import MuseCore
import SwiftUI

// Edit templates (plans/edit-templates.md §5; mockups 1, 2 and 4 in plans/design/edit-templates/): the media panel's
// Templates tab, the picked template's inspector, and Save as template. One action fill per screen (Apply), the accent only
// on the selection, Phosphor icons, sentence case; a price only on a template that cuts out the subject.

// MARK: - The library (media panel)

struct EditTemplatesPanel: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    private let grid = [GridItem(.flexible(), spacing: Space.s2), GridItem(.flexible(), spacing: Space.s2)]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            if session.templatesAvailable {
                search
                // Full words, never truncated (review run 700): chips that scroll sideways when the panel is narrow.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.s1) {
                        ForEach(EditTemplateLibrary.Filter.allCases) { f in
                            let on = session.templates.filter == f
                            SuiteToolButton(title: f.label, filled: on, plain: !on) { session.templates.filter = f }
                                .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }
                library
            }
            captionStyles
        }
        .task { await session.loadTemplates() }
    }

    private var search: some View {
        HStack(spacing: Space.s2) {
            Ph("magnifying-glass", 14).foregroundStyle(t.roles.ink2)
            TextField("Search templates", text: $session.templates.query)
                .textFieldStyle(.plain)
                .font(t.scale.label.font)
                .accessibilityLabel("Search templates")
        }
        .padding(.horizontal, Space.s2)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.roles.field))
    }

    @ViewBuilder private var library: some View {
        let p = session.templates
        switch p.load {
        case .idle, .loading:
            // Skeletons shaped like the tiles.
            LazyVGrid(columns: grid, spacing: Space.s3) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: Space.s1) {
                        RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.roles.field).aspectRatio(16 / 10, contentMode: .fit)
                        RoundedRectangle(cornerRadius: 3).fill(t.roles.field).frame(width: 90, height: 10)
                    }
                }
            }
            .accessibilityLabel("Loading templates")
        case .failed(let why):
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("Templates didn't load").font(t.scale.label.font).foregroundStyle(t.roles.ink)
                Text(why == "Templates didn't load" ? "Check the connection to MUSE, then try again." : why)
                    .font(t.scale.caption.font).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                SuiteToolButton(title: "Try again", icon: "arrow-clockwise") { Task { await session.loadTemplates(force: true) } }
            }
        case .loaded:
            let sections = p.library.sections(filter: p.filter, query: p.query)
            if sections.isEmpty, p.filter != .captions {
                empty
            }
            ForEach(sections, id: \.title) { s in
                VStack(alignment: .leading, spacing: Space.s2) {
                    SuiteLabel(s.title, trailing: "\(s.items.count)")
                    LazyVGrid(columns: grid, alignment: .leading, spacing: Space.s3) {
                        ForEach(s.items) { tpl in
                            EditTemplateTile(session: session, template: tpl, picked: p.picked == tpl.id) { session.pickTemplate(tpl) }
                        }
                    }
                }
            }
        }
    }

    /// Nothing matches (or nothing saved yet): what a template is, and one way to start.
    private var empty: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(session.templates.query.isEmpty ? "No templates yet" : "No templates match")
                .font(t.scale.label.font).foregroundStyle(t.roles.ink)
            Text("A template is an effect or transition you can put on any clip in one click. Select a clip you've styled and save it as a template.")
                .font(t.scale.caption.font).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            if session.canSaveTemplate, let sel = session.state.selection {
                let n = session.project.mainClips.firstIndex { $0.id == sel }.map { "clip \($0 + 1)" } ?? "the selection"
                SuiteToolButton(title: "Save \(n) as template", icon: "stack") { session.templates.saving = true }
            }
        }
    }

    /// Caption styles: a section of the library (owner decision 1) and the Captions filter.
    @ViewBuilder private var captionStyles: some View {
        let p = session.templates
        let styles = p.load == .loaded ? p.library.captionStyles(filter: p.filter, query: p.query) : []
        if !session.templatesAvailable || p.filter == .all || p.filter == .captions {
            VStack(alignment: .leading, spacing: Space.s2) {
                SuiteLabel("Caption styles")
                if session.project.captionTrack == nil {
                    HStack(spacing: Space.s2) {
                        SuiteToolButton(title: session.isRunning(.captions) ? "Captioning…" : "Make captions", icon: "closed-captioning",
                                        disabled: session.isRunning(.captions) || !session.helperAvailable(.captions)) { Task { await session.autoCaptions() } }
                            .help(session.helperNote(.captions) ?? session.estimateLabel(.captions).map { "Word-timed captions from what's said, \($0)" } ?? "Word-timed captions from what's said")
                        if session.isRunning(.captions) { ProgressView().controlSize(.small) }
                    }
                    .padding(.bottom, Space.s1)
                }
                // The server's names when the library loaded (search filters them); else the app's own list.
                let presets: [(preset: EditV2.CaptionPreset, name: String)] = styles.isEmpty && p.query.isEmpty
                    ? EditV2.suiteCaptionStyles.map { (preset: $0, name: EditV2.captionStyleLabel($0)) }
                    : styles.compactMap { s in EditV2.CaptionPreset(rawValue: s.id).map { (preset: $0, name: s.name) } }
                ForEach(presets, id: \.preset) { pair in
                    Button { session.edit { $0.setCaptionPreset(pair.preset) } } label: {
                        HStack {
                            Text(pair.name).font(t.scale.label.font).foregroundStyle(t.roles.ink)
                            Spacer()
                            if session.state.captionStyle?.preset == pair.preset { Ph("check", 16).foregroundStyle(t.roles.accent) }
                        }
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(session.project.captionTrack == nil)
                    .accessibilityLabel("Caption style \(pair.name)")
                }
            }
        }
    }
}

/// A 16:10 tile: the preview (playing while hovered or picked), the name and its timing; "Not ready" / "Needs update" on
/// the picture when it can't be applied.
struct EditTemplateTile: View {
    @Environment(\.theme) private var t
    var session: EditSuiteSession
    var template: EditTemplate
    var picked: Bool
    var pick: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: Space.s1) {
                let shape = RoundedRectangle(cornerRadius: t.radii.control, style: .continuous)
                EditTemplatePreview(session: session, uploadId: template.previewUpload ?? template.referenceUpload, playing: hover || picked)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .clipShape(shape)
                    .overlay(alignment: .bottomLeading) {
                        if let b = template.badge {
                            Text(b).font(t.scale.micro.font).foregroundStyle(t.roles.ink)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(t.roles.raised))
                                .padding(Space.s1)
                        }
                    }
                    .overlay(shape.strokeBorder(t.roles.accent, lineWidth: picked ? 2 : 0))
                Text(template.name).font(t.scale.label.font).foregroundStyle(t.roles.ink).lineLimit(1).truncationMode(.tail)
                if let timing = template.timing {
                    Text(timing).font(t.scale.caption.font).foregroundStyle(t.roles.ink2).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(template.name)
        .accessibilityLabel(template.badge.map { "\(template.name), \($0)" } ?? template.name)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// A template's preview or reference clip: a still of its first frame, playing (muted, looping) while `playing`. Without
/// one, the field with a film-strip mark (the apps draw a live render on the edit when it's picked).
struct EditTemplatePreview: View {
    @Environment(\.theme) private var t
    var session: EditSuiteSession
    var uploadId: String?
    var playing: Bool
    @State private var url: URL?
    @State private var still: CGImage?
    @State private var looper: StageLooper?

    var body: some View {
        ZStack {
            t.roles.field
            if let still { Image(decorative: still, scale: 1).resizable().aspectRatio(contentMode: .fill) }
            else { Ph("film-strip", 20).foregroundStyle(t.roles.ink2) }
            if let looper { PlayerLayerView(player: looper.player).allowsHitTesting(false) }
        }
        .clipped()
        .task(id: uploadId) { await load() }
        .onChange(of: playing) { _, on in play(on) }
        .onDisappear { looper?.stop(); looper = nil }
    }

    private func load() async {
        guard let id = uploadId, let u = try? await session.templateAPI.editTemplateMediaURL(uploadId: id) else { return }
        url = u
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: u))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        still = try? await gen.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
        play(playing)
    }

    private func play(_ on: Bool) {
        if on, looper == nil, let url { looper = StageLooper(url: url, muted: true) }
        if !on { looper?.stop(); looper = nil }
    }
}

// MARK: - The picked template (inspector)

struct EditTemplateInspector: View {
    @Environment(\.theme) private var t
    @Bindable var session: EditSuiteSession
    let template: EditTemplate
    @State private var deleting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.s2) {
                // The whole name, wrapping to two lines if it must (review run 700: it collapsed to "W…").
                Text(template.name).font(t.scale.heading.font).foregroundStyle(t.roles.ink).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                    .fitProbe("template title")
                Menu {
                    Button("Close template") { session.closeTemplate() }
                    Button("Delete template…", role: .destructive) { deleting = true }
                } label: { Image(nsImage: Ph.menuImage("dots-three", 16)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .frame(width: 28, height: 28)
                    .help("More").accessibilityLabel("More for \(template.name)")
            }
            .padding(.horizontal, Space.s4).padding(.top, Space.s3).padding(.bottom, Space.s2)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    VStack(alignment: .leading, spacing: Space.s1) {
                        Text(template.description).font(t.scale.label.font).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                        Text(template.origin).font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                    }
                    if template.isReady { ready } else { notReady }
                }
                .padding(.horizontal, Space.s4).padding(.bottom, Space.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(t.roles.canvas)
        .confirmationDialog("Delete \u{201C}\(template.name)\u{201D}?", isPresented: $deleting) {
            Button("Delete template", role: .destructive) { Task { await session.deleteTemplate(template) } }
            Button("Keep", role: .cancel) {}
        } message: { Text("Edits that used it keep their items.") }
    }

    // A template that applies: where it goes, its settings, the level line, Apply.
    @ViewBuilder private var ready: some View {
        let target = session.templateTarget
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("Applies to").font(t.scale.label.font).foregroundStyle(t.roles.ink2)
                .templateFrame("applies to")
            HStack(spacing: Space.s2) {
                Ph(template.target == "cut" ? "arrows-left-right" : template.target == "edit" ? "film-strip" : "film", 16).foregroundStyle(t.roles.ink2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(target?.title ?? (template.target == "cut" ? "No cut yet" : "No clip yet")).font(t.scale.label.font).foregroundStyle(t.roles.ink)
                    Text(target?.detail ?? "Add clips to the timeline first").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.s3)
            .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.roles.field))
            .help(template.target == "edit" ? "Goes across the whole edit" : "Select a clip, or move the playhead, to change where it goes")
        }
        ForEach(template.params.filter { $0.control != .hidden }) { p in param(p) }
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            Ph("check-circle", 14).foregroundStyle(t.roles.ink2)
            Text(template.levelLine).font(t.scale.caption.font).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
        }
        ForEach(session.templates.notes, id: \.self) { n in
            HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                Ph("warning-circle", 14).foregroundStyle(t.roles.ink2)
                Text(n).font(t.scale.caption.font).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
        VStack(alignment: .leading, spacing: Space.s2) {
            let busy = session.templates.applying || session.templates.previewing
            let price = template.paid ? session.templates.priceUsd : nil
            HStack(spacing: Space.s2) {
                SuiteToolButton(title: target.map { EditTemplateTarget.applyTitle($0.title, priceUsd: price) } ?? "Apply", accent: true,
                                disabled: busy || target == nil || session.live == nil) { Task { await session.applyTemplate() } }
                if busy { ProgressView().controlSize(.small) }
            }
            if let every = EditTemplateTarget.everyTitle(template) {
                SuiteToolButton(title: every.title, disabled: busy || session.live == nil, plain: true) { Task { await session.applyTemplate(every: every.target) } }
            }
            if session.live == nil {
                Text("Templates apply once this edit is shared with Claude (it opens with the edit).").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
            } else if session.templates.previewOf == template.id {
                Text("Previewing on the edit, not applied yet").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
            }
        }
    }

    @ViewBuilder private func param(_ p: EditTemplateParam) -> some View {
        let v = session.templates.params[p.key] ?? p.defaultValue
        switch p.control {
        case .segmented, .menu:
            let cur: String? = { if case .string(let s)? = v { return s }; return nil }()
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(p.label).font(t.scale.label.font).foregroundStyle(t.roles.ink)
                if p.control == .segmented {
                    EditSeg(options: p.options.map { ($0, EditTemplateParam.optionLabel($0)) }, selection: cur, small: true) { session.setTemplateParam(p.key, .string($0)) }
                } else {
                    Picker(p.label, selection: Binding(get: { cur ?? p.options.first ?? "" }, set: { session.setTemplateParam(p.key, .string($0)) })) {
                        ForEach(p.options, id: \.self) { Text(EditTemplateParam.optionLabel($0)).tag($0) }
                    }
                    .labelsHidden()
                }
            }
        case .slider:
            let n: Double = { if case .number(let x)? = v { return x }; return p.min ?? 0 }()
            SuiteSlider(p.label, value: n, range: (p.min ?? 0)...(p.max ?? 1), format: { p.valueLabel($0) }) { x in
                // Whole-number settings (frames, panels) stay whole.
                let whole = (p.min ?? 0).rounded() == p.min && (p.max ?? 1).rounded() == p.max && (p.max ?? 1) - (p.min ?? 0) >= 2
                session.setTemplateParam(p.key, .number(whole ? x.rounded() : (x * 100).rounded() / 100))
            }
        case .toggle:
            let on: Bool = { if case .bool(let b)? = v { return b }; return false }()
            SuiteToggleRow(title: p.label, isOn: on) { session.setTemplateParam(p.key, .bool($0)) }
        case .field:
            let s: String = { if case .string(let x)? = v { return x }; return "" }()
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(p.label).font(t.scale.label.font).foregroundStyle(t.roles.ink)
                TextField(p.label, text: Binding(get: { s }, set: { session.templates.params[p.key] = .string($0) }))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { session.setTemplateParam(p.key, session.templates.params[p.key] ?? .string("")) }
                    .accessibilityLabel(p.label)
            }
        case .hidden:
            EmptyView()
        }
    }

    // Not ready (mockup 2): the reference clip, why, and on the Mac, Claude makes it for this cut.
    @ViewBuilder private var notReady: some View {
        if template.referenceUpload != nil || template.previewUpload != nil {
            EditTemplatePreview(session: session, uploadId: template.referenceUpload ?? template.previewUpload, playing: true)
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous))
                .accessibilityLabel("Reference clip of \(template.name)")
        }
        VStack(alignment: .leading, spacing: Space.s1) {
            Text(template.badge ?? "Not ready").font(t.scale.label.font).foregroundStyle(t.roles.ink)
            Text(template.reason ?? "This one isn't built into Edit yet.").font(t.scale.caption.font).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
        }
        if template.state == "needs_update" {
            Text("Needs the next MUSE update").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
        } else if session.isOwner {
            SuiteToolButton(title: template.target == "cut" ? "Ask Claude to make it for this cut" : "Ask Claude to make it for this clip", accent: true) { session.askClaudeToMake(template) }
                .help("Claude adapts the template's script to your shots and adds the result as an overlay. It takes Claude a few minutes; nothing is charged.")
                .templateFrame("ask claude")
        }
        if template.referenceUpload != nil {
            Text("The reference clip is the Icon edit's own footage: it shows what the template does and isn't added to your video.")
                .font(t.scale.caption.font).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Save as template (sheet, mockup 4)

struct EditSaveTemplateSheet: View {
    @Environment(\.theme) private var t
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: EditSuiteSession
    @State private var name = ""
    @State private var kind = "effect"
    @State private var onCut = false
    @State private var saving = false

    var body: some View {
        let sel = session.state.selection
        let mainIndex = sel.flatMap { s in session.project.mainClips.firstIndex { $0.id == s } }
        VStack(alignment: .leading, spacing: Space.s4) {
            Text("Save as template").font(t.scale.heading.font).foregroundStyle(t.roles.ink)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text("Name").font(t.scale.label.font).foregroundStyle(t.roles.ink)
                TextField("Punch-in", text: $name).textFieldStyle(.roundedBorder).accessibilityLabel("Template name")
            }
            VStack(alignment: .leading, spacing: Space.s1) {
                Text("Kind").font(t.scale.label.font).foregroundStyle(t.roles.ink)
                EditSeg(options: [("effect", "Effect"), ("transition", "Transition")], selection: kind, small: true) { kind = $0 }
            }
            if let i = mainIndex, i > 0 {
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text("Applies to").font(t.scale.label.font).foregroundStyle(t.roles.ink)
                    EditSeg(options: [(false, "Each clip"), (true, "A cut")], selection: onCut, small: true) { onCut = $0 }
                }
            }
            Text("It keeps the clip's effect, look, colour, mask and keyframes, and the overlays, text and sounds over it. A copy of the next or previous shot stays a copy of whichever shot is next to it, so it works on any video.")
                .font(t.scale.caption.font).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.s2) {
                Spacer()
                SuiteToolButton(title: "Cancel", plain: true) { dismiss() }
                SuiteToolButton(title: saving ? "Saving…" : "Save template", accent: true, disabled: saving || name.trimmingCharacters(in: .whitespaces).isEmpty || sel == nil) {
                    saving = true
                    Task {
                        let ok = await session.saveTemplate(name: String(name.trimmingCharacters(in: .whitespaces).prefix(60)), kind: kind, cut: onCut)
                        saving = false
                        if ok { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.s5)
        .frame(width: 420)
        .background(t.roles.canvas)
        .onAppear { onCut = kind == "transition" }
        .onChange(of: kind) { _, k in onCut = k == "transition" && (mainIndex ?? 0) > 0 }
    }
}

extension View {
    /// Review mode: where this sits in the window (SnapshotRunner+EditTemplates.swift checks it is on screen without scrolling).
    @ViewBuilder func templateFrame(_ name: String) -> some View {
        if SnapshotRunner.probing {
            background(GeometryReader { g in
                Color.clear
                    .onAppear { SnapshotRunner.templateFrames[name] = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { _, r in SnapshotRunner.templateFrames[name] = r }
            })
        } else { self }
    }
}

import MuseCore
import SwiftUI

// The cinematic Suite (plans/ai-suite-design.md, MOCKS APPROVED; mocks: plans/ai-suite-cinematic/ at 66ed2c2), build step 1:
// Shot and Photo, behind the owner's "Try the new Suite" switch (Settings → Developer). The page is the theme's own
// "dark room" (DesignTokens.room) set into the unchanged shell: the stage with the take's ambient glow, a floating glass
// dock (inputs, prompt, rig check, one image chip per rig control, pills, Generate · price) and the takes rail.

extension Theme {
    /// The same theme in its dark room: the room's roles (and the older colour fields the reused composer parts read),
    /// with the theme's own fonts and radii.
    func room() -> Theme {
        let rm = DesignTokens.room(id.rawValue).roles
        let c = { (v: UInt32) in Color(hex: v) }
        return Theme(id: id, bg: c(rm.canvas), surface: c(rm.raised), surface2: c(rm.field), ink: c(rm.ink), muted: c(rm.ink2), line: c(rm.hairline),
                     accent: c(rm.accent), accentInk: c(rm.onAction), cta: c(rm.action), ctaInk: c(rm.onAction), good: c(rm.positive), warn: c(rm.caution),
                     warnBg: c(rm.raised), warnInk: c(rm.caution), rec: c(rm.danger), r: r, rLg: rLg, stroke: stroke,
                     displayFamily: displayFamily, bodyFamily: bodyFamily, monoFamily: monoFamily, isDark: true, rolesOverride: Roles(rm))
    }

    /// The room's corner: the theme's container radius, at most 20 (Editorial stays nearly square).
    var roomRadius: CGFloat { min(CGFloat(DesignTokens.radii(id.rawValue).container), 20) }
    var roomGlassTint: Color { Color(hex: DesignTokens.room(id.rawValue).glassTint) }
}

struct CinemaSuiteView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var shell
    /// The take on the stage when the member picked one in the rail; else the newest.
    @State private var picked: String?

    var body: some View {
        let t = shell.room()
        let s = store.suite
        GeometryReader { g in
            let railW: CGFloat = g.size.width >= 1150 ? 260 : 228
            HStack(spacing: 0) {
                CinemaStageArea(picked: $picked)
                    .frame(width: max(0, g.size.width - railW))
                CinemaTakesRail(picked: $picked)
                    .frame(width: railW)
            }
            .background(t.roles.canvas)
            .overlay(CinemaGrain())
            .clipShape(RoundedRectangle(cornerRadius: shell.roomRadius))
            .overlay(RoundedRectangle(cornerRadius: shell.roomRadius).strokeBorder(t.roles.hairline.opacity(0.7), lineWidth: 1))
            // A soft inner shadow along the top and left: the room is set into the shell, not pasted on it.
            .overlay(alignment: .topLeading) {
                LinearGradient(colors: [.black.opacity(0.28), .clear], startPoint: .top, endPoint: .bottom).frame(height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: shell.roomRadius)).allowsHitTesting(false)
            }
        }
        .padding([.top, .trailing, .bottom], 8)
        .environment(\.theme, t)
        .environment(\.colorScheme, .dark)
        // The rig panel and the tool browser in their own view (CinemaOverlays), which reads the picker itself. Hung off
        // this body they could miss an update: after Photo, Shot and the panel opened in one tick left this body stale
        // (CI: the picker set, this body's last run saw it closed, the panel never inserted), while child views updated.
        .overlay { CinemaOverlays(roomTheme: shell.room()) }
        .task(id: ComposerPriceKey(draft: s.composer, slots: s.composerSlots.slots, swap: s.swap, clipId: store.clip?.id, catalogLoaded: s.catalog != nil, photo: s.photo)) {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            switch s.composer.tool {
            case .photo: await store.estimatePhoto()
            default: if !store.isComingSoon(s.composer.tool) { await store.estimateShot() }
            }
        }
        .onChange(of: s.composer.tool) { _, _ in picked = nil }
        // A model's default rig when it is @-mentioned (fills Auto rows only, with Undo).
        .onChange(of: s.composer.tokens.characterId) { _, new in if new != nil { store.applyDefaultRigIfAny() } }
        .task(id: store.serverKey) { await store.loadSavedRigs() }
    }
}

// MARK: Data

extension AppStore {
    /// The rail's takes, newest first: Shot shows the suite's video takes, Photo its stills.
    func cinemaTakes(photo: Bool) -> [Take] {
        if photo { return takes.filter { $0.kind == "shot" }.sorted { $0.createdAt > $1.createdAt } }
        let suiteIds = Set(jobs.filter { $0.request.engine == "suite" || $0.request.isUpscale }.map(\.id))
        let video = takes.filter { $0.isVideo && $0.kind == "take" }
        let mine = suiteIds.isEmpty ? video : video.filter { $0.jobId.map(suiteIds.contains) ?? false }
        return mine.sorted { $0.createdAt > $1.createdAt }
    }

    /// Suite renders still in progress (Shot), newest first.
    var cinemaRunning: [Job] {
        jobs.filter { ($0.request.engine == "suite") && !$0.isDone && !$0.isFailed }.sorted { $0.createdAt > $1.createdAt }
    }
}

// MARK: The stage and the dock

struct CinemaStageArea: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @Binding var picked: String?

    private var photo: Bool { store.suite.composer.tool == .photo }

    var body: some View {
        let takes = store.cinemaTakes(photo: photo)
        let stage = picked.flatMap { id in takes.first { $0.id == id } } ?? (photo ? takes.first : store.takes(of: store.shotJob).last ?? takes.first)
        let running = picked == nil && !photo ? store.shotJob.flatMap { j in j.isDone || j.isFailed ? nil : j } : nil
        let empty = (stage == nil && running == nil) || SnapshotRunner.state.cinemaEmpty
        GeometryReader { g in
            let dockH: CGFloat = 330
            let top: CGFloat = 64
            let availH = max(120, g.size.height - dockH - top - 16)
            let stageW = max(0, min(availH * 16 / 9, g.size.width - 120))
            let stageH = stageW * 9 / 16
            ZStack(alignment: .top) {
                if !empty, let img = running?.thumb ?? stage?.thumb { CinemaAmbient(ref: img) }
                header
                Group {
                    if empty {
                        CinemaEmptyStage(photo: photo)
                    } else if photo, let first = stage {
                        CinemaPhotoStage(lead: first, rest: Array(takes.filter { $0.id != first.id }.prefix(3)))
                    } else if let job = running {
                        CinemaRunningStage(job: job)
                    } else if let take = stage {
                        CinemaTakeStage(take: take)
                    }
                }
                .frame(width: photo ? nil : stageW, height: stageH)
                .padding(.top, top)
                .animation(.easeInOut(duration: 0.25), value: stage?.id)
                VStack {
                    Spacer(minLength: 0)
                    CinemaDock().padding(.horizontal, 28).padding(.bottom, 20)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }

    private var header: some View {
        HStack(spacing: Space.s3) {
            Button { store.suite.browserOpen = true } label: {
                HStack(spacing: 8) {
                    Text(store.suite.composer.tool.title).font(t.scale.heading.font).foregroundStyle(t.roles.ink)
                    Ph("caret-down", 13).foregroundStyle(t.roles.ink2)
                }
                .frame(minHeight: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Change the tool")
            .accessibilityLabel("\(store.suite.composer.tool.title), change tool")
            if store.isComingSoon(store.suite.composer.tool) { SuiteTag(text: SuiteText.comingSoon) }
            Spacer(minLength: 0)
            CinemaPresetsButton()
        }
        .padding(.horizontal, 28).padding(.top, 16)
        .frame(maxWidth: .infinity, alignment: .top)
        .zIndex(2)
    }
}

/// The take's colours spill into the room: a small copy of its poster, blurred once and scaled up (cheap: no live blur
/// of video), under a vignette in the room's tone.
struct CinemaAmbient: View {
    @Environment(\.theme) private var t
    var ref: ImageRef

    var body: some View {
        GeometryReader { g in
            MuseImage(ref: ref)
                .frame(width: g.size.width / 16, height: g.size.height / 16)
                .blur(radius: 3)
                .drawingGroup()
                .scaleEffect(16, anchor: .topLeading)
                .opacity(0.55)
                .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                .clipped()
            RadialGradient(colors: [.clear, t.roles.canvas.opacity(0.55), t.roles.canvas.opacity(0.92)], center: UnitPoint(x: 0.5, y: 0.38),
                           startRadius: 0, endRadius: max(g.size.width, g.size.height) * 0.62)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transition(.opacity)
    }
}

struct CinemaTakeStage: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var take: Take

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: max(t.radii.control, 10))
        Button { store.openTake(take.id) } label: {
            ZStack(alignment: .bottomLeading) {
                Color.clear.overlay(MuseImage(ref: take.thumb)).clipped()
                Rectangle().fill(RadialGradient(colors: [.clear, .black.opacity(0.45)], center: .center, startRadius: 120, endRadius: 600))
                HStack(spacing: 8) {
                    Ph("play", 13)
                    Text(take.of > 1 ? "Take \(take.index) of \(take.of)" : take.displayLabel).font(t.scale.micro.font)
                    if let d = take.durationSec { Text(String(format: "0:%02d", Int(d.rounded()))).font(t.scale.micro.font).monospacedDigit() }
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(14)
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(0.5), radius: 30, y: 20)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help("Open the take")
        .accessibilityLabel("Open \(take.displayLabel)")
    }
}

struct CinemaRunningStage: View {
    @Environment(\.theme) private var t
    var job: Job

    var body: some View {
        let state = SuiteResultState.of(job)
        let pct: Int = { if case .rendering(let p, _) = state { return p } else { return 0 } }()
        ZStack(alignment: .bottomLeading) {
            Color.clear.overlay(MuseImage(ref: job.thumb).blur(radius: 18)).clipped()
            t.roles.canvas.opacity(0.35)
            VStack(alignment: .leading, spacing: 8) {
                Text(state == .ready ? "Ready" : pct > 0 ? "\(pct)%" : state.queueLine).font(t.scale.label.font).foregroundStyle(t.roles.ink)
                Capsule().fill(t.roles.ink.opacity(0.18)).frame(height: 3)
                    .overlay(alignment: .leading) {
                        GeometryReader { g in Capsule().fill(t.roles.accent).frame(width: g.size.width * CGFloat(pct) / 100).shadow(color: t.roles.accent, radius: 6) }
                    }
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: max(t.radii.control, 10)))
        .accessibilityElement(children: .combine)
    }
}

struct CinemaPhotoStage: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var lead: Take
    var rest: [Take]

    var body: some View {
        GeometryReader { g in
            let h = g.size.height
            let small = (h - 20) / 3
            HStack(alignment: .top, spacing: 10) {
                Spacer(minLength: 0)
                Button { store.openTake(lead.id) } label: {
                    Color.clear.overlay(MuseImage(ref: lead.thumb)).clipped()
                        .frame(width: h * 4 / 5, height: h)
                        .clipShape(RoundedRectangle(cornerRadius: max(t.radii.control, 10)))
                        .overlay(RoundedRectangle(cornerRadius: max(t.radii.control, 10)).strokeBorder(t.roles.accent, lineWidth: 2))
                        .shadow(color: .black.opacity(0.5), radius: 30, y: 20)
                }
                .buttonStyle(.plain).accessibilityLabel("Open \(lead.displayLabel)")
                VStack(spacing: 10) {
                    ForEach(rest) { p in
                        Button { store.openTake(p.id) } label: {
                            Color.clear.overlay(MuseImage(ref: p.thumb)).clipped()
                                .frame(width: small * 4 / 5, height: small)
                                .clipShape(RoundedRectangle(cornerRadius: max(t.radii.control - 4, 8)))
                        }
                        .buttonStyle(.plain).accessibilityLabel("Open \(p.displayLabel)")
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// Before the first take: a dark frame with corner marks and a faint warm light leak; one line.
struct CinemaEmptyStage: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var photo: Bool

    var body: some View {
        let d = store.suite.composer
        let shape = RoundedRectangle(cornerRadius: max(t.radii.control, 10))
        ZStack {
            t.roles.canvas.opacity(0.6)
            RadialGradient(colors: [Color(hex: 0xFFAA5A, alpha: 0.28), .clear], center: UnitPoint(x: 0.82, y: 0.05), startRadius: 0, endRadius: 320)
            RadialGradient(colors: [t.roles.accent.opacity(0.18), .clear], center: UnitPoint(x: 0.1, y: 1.0), startRadius: 0, endRadius: 280)
            CinemaCorners().stroke(t.roles.ink.opacity(0.35), lineWidth: 1.5).padding(14)
            VStack(spacing: 4) {
                Text(photo ? "Your first photos appear here" : "Your first take plays here").font(t.scale.body.font).foregroundStyle(t.roles.ink)
                Text(photo ? "Describe the photo below." : "\(d.aspect), \(d.duration) s. Describe the shot below.").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(t.roles.hairline.opacity(0.6), lineWidth: 1))
        .aspectRatio(photo ? 4 / 5 : 16 / 9, contentMode: .fit)
        .accessibilityElement(children: .combine)
    }
}

struct CinemaCorners: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let l: CGFloat = 18
        for (x, y, dx, dy) in [(r.minX, r.minY, l, l), (r.maxX, r.minY, -l, l), (r.minX, r.maxY, l, -l), (r.maxX, r.maxY, -l, -l)] {
            p.move(to: CGPoint(x: x + dx, y: y)); p.addLine(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x, y: y + dy))
        }
        return p
    }
}

// MARK: The dock

struct CinemaDock: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    private var photo: Bool { store.suite.composer.tool == .photo }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: max(t.roomRadius, 10))
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                Group {
                    if photo { PhotoSlotRow(size: 64, spacing: 8) } else { ComposerSlotRow(size: 64, thumbs: true) }
                }
                .fixedSize()
                VStack(alignment: .leading, spacing: 8) {
                    ComposerPromptBox(placeholder: store.suite.composer.tool.promptPlaceholder, minHeight: 52, maxHeight: 88, suggestionsAbove: true)
                    RigCheckRow()
                }
            }
            CinemaChipRow()
            HStack(spacing: 8) {
                CinemaPills()
                Spacer(minLength: 8)
                CinemaGenerate()
            }
        }
        .padding(16)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                t.roles.canvas.opacity(0.55)
                t.roomGlassTint.opacity(0.07)
            }
            .clipShape(shape)
        }
        .overlay(shape.strokeBorder(t.roles.ink.opacity(0.11), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 24)
        .frame(maxWidth: 980)
    }
}

/// One tall image chip per rig control; each opens its picker. The open one carries the glow ring.
struct CinemaChipRow: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let d = store.suite.composer
        let s = d.settings
        let cat = store.suite.camera
        let photo = d.tool == .photo
        let locked = photo && store.suite.photo.presetId != nil
        let open = store.suite.picker
        let cam = cat.bodies.first { $0.id == ComposerCatalog.survivor(cat.bodies, s.body) }
        let lens = cat.lenses.first { $0.id == ComposerCatalog.survivor(cat.lenses, s.lens) }
        let light = cat.lighting.first { $0.id == ComposerCatalog.survivor(cat.lighting, s.lighting) }
        let look = cat.palettes.first { $0.id == ComposerCatalog.survivor(cat.palettes, s.palette) }
        let genre = cat.genres.first { $0.id == ComposerCatalog.survivor(cat.genres, s.genre) }
        let tempo = ComposerCatalog.label(cat.tempos, s.tempo)
        let moves = d.tokens.moves.compactMap { $0.move?.id }.compactMap { cat.move($0) }
        HStack(spacing: 8) {
            CinemaRigChip(label: "Camera", value: locked ? "From preset" : cam?.label, preview: cam.map(PickerPreview.option), on: open == .camera && store.suite.pickerStep == "setup") {
                store.openPicker(.camera, step: "setup")
            }
            .disabled(locked)
            CinemaRigChip(label: "Lens", value: locked ? "From preset" : lens?.label, preview: lens.map(PickerPreview.option), on: false) {
                store.openPicker(.camera, step: "setup")
            }
            .disabled(locked)
            CinemaRigChip(label: "Light", value: locked ? "From preset" : light?.label, preview: light.map(PickerPreview.option), on: open == .lighting) {
                store.openPicker(.lighting)
            }
            .disabled(locked)
            CinemaRigChip(label: "Look", value: look?.label, preview: look.map(PickerPreview.option), swatches: look?.swatches ?? [], on: open == .look) {
                store.openPicker(.look)
            }
            CinemaRigChip(label: "Style", value: [genre?.label, tempo].compactMap { $0 }.joined(separator: ", ").nilIfEmpty, preview: genre.map(PickerPreview.option),
                          on: open == .style) {
                store.openPicker(.style)
            }
            if !photo {
                CinemaRigChip(label: "Move", value: moves.first.map { m in moves.count > 1 ? "\(m.label), +\(moves.count - 1)" : m.label },
                              preview: moves.first.map(PickerPreview.move), on: open == .camera && store.suite.pickerStep == "movement") {
                    store.openPicker(.camera, step: "movement")
                }
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct CinemaRigChip: View {
    @Environment(\.theme) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var label: String
    var value: String?
    var preview: PickerPreview?
    var swatches: [String] = []
    var on: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: max(t.radii.control - 2, 10))
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottom) {
                    if let preview, value != nil {
                        PreviewView(preview: preview).frame(maxWidth: .infinity).frame(height: 58).clipped()
                    } else {
                        Ph("aperture", 24).foregroundStyle(t.roles.ink2).frame(maxWidth: .infinity).frame(height: 58)
                    }
                    if !swatches.isEmpty {
                        HStack(spacing: 0) { ForEach(swatches.prefix(6), id: \.self) { s in (Color(hexString: s) ?? .clear).frame(height: 8) } }
                    }
                }
                .background(t.roles.canvas)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(t.scale.micro.font).foregroundStyle(t.roles.ink2)
                    Text(value ?? "Auto").font(t.scale.caption.font.weight(.medium)).foregroundStyle(value == nil ? t.roles.ink2 : t.roles.ink)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .frame(height: 32, alignment: .topLeading)
                }
                .padding(.horizontal, 10).padding(.top, 7).padding(.bottom, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(t.roles.ink.opacity(0.06))
            .clipShape(shape)
            .overlay(shape.strokeBorder(on ? t.roles.accent : t.roles.ink.opacity(0.11), lineWidth: on ? 1.5 : 1))
            .shadow(color: on ? t.roles.accent.opacity(0.45) : .clear, radius: 11)
            .offset(y: hover && !reduceMotion ? -2 : 0)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .help(label)
        .accessibilityLabel("\(label), \(value ?? "Auto")")
    }
}

// MARK: Pills and Generate

struct CinemaPills: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var open: String?

    var body: some View {
        let d = store.suite.composer
        HStack(spacing: 8) {
            if d.tool == .photo {
                let n = store.suite.photo.count
                pill("photos", icon: "images", value: "\(n) photo\(n == 1 ? "" : "s")", help: "Photos") {
                    PillList(title: "Photos", options: PhotoDraft.counts.map { ("\($0) photo\($0 == 1 ? "" : "s")", $0) }, selected: n) { store.suite.photo.count = $0; open = nil }
                }
            } else {
                // The owner's engine lives inside Quality (plans/ai-suite-design.md), not as its own pill.
                let tier = store.suite.catalog?.tier(d.quality)
                let pinned = store.isOwner && d.engineModel != nil
                let qValue = SuiteText.tierLabel(store.suite.toolQuality) + (pinned ? ", " + ComposerBottomBar.engineName(ComposerEngines.label(d, tier)) : "")
                pill("quality", icon: "gauge", value: qValue, help: "Quality") {
                    VStack(alignment: .leading, spacing: 0) {
                        QualityPopover(onPick: { open = nil })
                        if store.isOwner { CinemaEngineList(onPick: { open = nil }) }
                    }
                }
                let ratios = store.suite.catalog?.aspectRatios ?? ComposerBar.shapes
                pill("shape", icon: "crop", value: d.aspect, help: "Shape") {
                    PillList(title: "Shape", options: ratios.map { ($0, $0) }, selected: d.aspect) { store.suite.composer.aspect = $0; open = nil }
                }
                let range = ComposerBar.lengthRange(store.suite.catalog?.tier(d.quality))
                pill("length", icon: "timer", value: "\(d.duration) s", help: "Length") {
                    PillList(title: "Length", options: Array(range).map { ("\($0) s", $0) }, selected: d.duration) { store.suite.composer.duration = $0; open = nil }
                }
                pill("sound", icon: d.sound ? "speaker-high" : "speaker-slash", value: d.sound ? "Sound on" : "Sound off", help: "Sound") {
                    PillList(title: "Sound", options: [("On", true), ("Off", false)], selected: d.sound) { store.suite.composer.sound = $0; open = nil }
                }
                let takesMax = store.suite.catalog?.takesMax ?? 4
                pill("takes", icon: "copy", value: "\(d.takes) take\(d.takes == 1 ? "" : "s")", help: "Takes") {
                    PillList(title: "Takes", options: ComposerBar.takes(takesMax).map { ("\($0) take\($0 == 1 ? "" : "s")", $0) }, selected: d.takes) {
                        store.suite.composer.takes = $0; open = nil
                    }
                }
            }
        }
        .fixedSize()
    }

    private func pill<Pop: View>(_ id: String, icon: String, value: String, help: String, @ViewBuilder popover: @escaping () -> Pop) -> some View {
        let isOpen = open == id
        return Button { open = isOpen ? nil : id } label: {
            HStack(spacing: 7) {
                Ph(icon, 15).foregroundStyle(t.roles.ink2)
                Text(value).font(t.scale.caption.font.weight(.medium)).foregroundStyle(t.roles.ink)
            }
            .padding(.horizontal, 12).frame(height: 32)
            .background(t.roles.ink.opacity(isOpen ? 0.12 : 0.06))
            .overlay(RoundedRectangle(cornerRadius: max(t.radii.chip == 999 ? 16 : t.radii.chip, 8)).strokeBorder(t.roles.ink.opacity(0.11), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: max(t.radii.chip == 999 ? 16 : t.radii.chip, 8)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("\(help), \(value)")
        .popover(isPresented: Binding(get: { open == id }, set: { if !$0 { open = nil } }), arrowEdge: .top) {
            popover().environment(store).environment(\.theme, t).environment(\.colorScheme, .dark)
        }
    }
}

struct CinemaGenerate: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    private var photo: Bool { store.suite.composer.tool == .photo }

    var body: some View {
        let price = photo ? GeneratePrice.photo(store.suite.photoEstimate) : GeneratePrice.of(store.suite.estimate)
        let pricing = photo ? (store.suite.photoEstimate == nil && store.suite.photoError == nil && store.photoRequest != nil)
                            : (store.suite.estimate == nil && store.suite.estimateError == nil && store.suite.enabled)
        let enabled = price.canGenerate
        GenerateButton(label: pricing ? "Generate · Pricing…" : price.buttonText, enabled: enabled, busy: store.suite.generating, height: 48) {
            if photo { store.generatePhoto() } else { store.generateShot() }
        }
        .shadow(color: enabled ? t.roles.action.opacity(0.5) : .clear, radius: 14)
        .background { if SnapshotRunner.dir != nil { GenerateFrameProbe() } }
        .fixedSize()
    }
}

// MARK: Presets

struct CinemaPresetsButton: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Text("Presets").font(t.scale.caption.font.weight(.medium)).foregroundStyle(t.roles.ink2) // presets and saved rigs
                .padding(.horizontal, 10).frame(height: 30)
                .background(t.roles.ink.opacity(open ? 0.08 : 0)).clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Start from a preset")
        .popover(isPresented: $open, arrowEdge: .top) {
            list.frame(width: 280).environment(\.theme, t).environment(\.colorScheme, .dark)
        }
    }

    @State private var rigName = ""

    @ViewBuilder private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.suite.composer.tool != .photo || !store.suite.savedRigs.isEmpty {
                Text("Saved rigs").font(t.scale.micro.font).foregroundStyle(t.roles.ink2).padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 4)
                ForEach(store.suite.savedRigs.prefix(8)) { r in
                    row(r.name, r.mine ? "" : "From the studio", on: false) { store.applySavedRig(r); open = false }
                }
                HStack(spacing: 6) {
                    TextField("Name this rig", text: $rigName).textFieldStyle(.plain).font(t.scale.caption.font).foregroundStyle(t.roles.ink)
                        .onSubmit { save() }
                    Button("Save rig") { save() }.buttonStyle(.plain).font(t.scale.caption.font.weight(.medium)).foregroundStyle(t.roles.accent)
                        .disabled(rigName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                Rectangle().fill(t.roles.hairline).frame(height: 1).padding(.vertical, 4)
                Text("Presets").font(t.scale.micro.font).foregroundStyle(t.roles.ink2).padding(.horizontal, 14).padding(.bottom, 4)
            }
            if store.suite.composer.tool == .photo {
                ForEach(store.templates.prefix(8)) { tpl in
                    row(tpl.name, tpl.tags.prefix(3).joined(separator: ", "), on: store.suite.photo.presetId == tpl.id) { store.choosePhotoPreset(tpl); open = false }
                }
            } else {
                ForEach(store.suite.camera.presets.prefix(8)) { p in
                    row(p.label, p.description, on: store.suite.composer.collapsed == p.id) { store.applyPreset(p); open = false }
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func save() {
        store.saveRig(named: rigName)
        rigName = ""
    }

    private func row(_ title: String, _ line: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(t.scale.caption.font.weight(.medium)).foregroundStyle(t.roles.ink)
                if !line.isEmpty { Text(line).font(t.scale.micro.font).foregroundStyle(t.roles.ink2).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(on ? t.roles.ink.opacity(0.08) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}


// MARK: Grain and the owner's engine

/// The room's faint film grain: one 128 px noise tile, drawn once and tiled (static: nothing animates).
struct CinemaGrain: View {
    private static let tile: NSImage = {
        let n = 128
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: n * 4, bitsPerPixel: 32),
              let data = rep.bitmapData else { return NSImage() }
        var x: UInt32 = 0x9E37_79B9
        for i in 0..<(n * n) {
            x = x &* 1_664_525 &+ 1_013_904_223
            let v = UInt8(truncatingIfNeeded: x >> 24)
            data[i * 4] = v; data[i * 4 + 1] = v; data[i * 4 + 2] = v; data[i * 4 + 3] = 255
        }
        let img = NSImage(size: NSSize(width: n, height: n))
        img.addRepresentation(rep)
        return img
    }()

    var body: some View {
        Image(nsImage: Self.tile).resizable(resizingMode: .tile)
            .opacity(0.05).blendMode(.overlay)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Owner only, under the quality tiers: pin this shot's engine, or Auto (the tier's ladder).
struct CinemaEngineList: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var onPick: () -> Void

    var body: some View {
        let d = store.suite.composer
        let tier = store.suite.catalog?.tier(d.quality)
        let models = ComposerEngines.options(tier)
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(t.roles.hairline).frame(height: 1).padding(.vertical, 4)
            Text("Engine (owner)").font(t.scale.micro.font).foregroundStyle(t.roles.ink2).padding(.horizontal, 14).padding(.vertical, 6)
            row("Auto", "The \(SuiteText.tierLabel(d.quality)) ladder", on: d.engineModel == nil) { store.suite.composer = ComposerEngines.pin(store.suite.composer, nil) }
            ForEach(models, id: \.self) { m in
                let on = d.engineModel == m.model && (d.resolution ?? m.resolution) == m.resolution
                row("\(m.name), \(m.resolution)", ComposerBottomBar.plainAccepts(m.inputs ?? tier?.slots ?? .none), on: on) {
                    store.suite.composer = ComposerEngines.pin(store.suite.composer, m)
                }
            }
        }
        .padding(.bottom, 6)
    }

    private func row(_ title: String, _ line: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            onPick()
        } label: {
            HStack(spacing: 10) {
                Ph("checkmark", 11).foregroundStyle(t.roles.accent).opacity(on ? 1 : 0).frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(t.scale.caption.font.weight(on ? .semibold : .regular)).foregroundStyle(t.roles.ink)
                    Text(line).font(t.scale.micro.font).foregroundStyle(t.roles.ink2).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}


/// The rig panel and the tool browser over the room. Its own view so it re-renders whenever the picker or the browser
/// changes, whatever else changed in the same update (see CinemaSuiteView).
struct CinemaOverlays: View {
    @Environment(AppStore.self) private var store
    var roomTheme: Theme

    var body: some View {
        let open = store.suite.picker != nil
        let _ = SnapshotRunner.noteSuiteBody(pickerOpen: open) // review mode only: did this view see the picker?
        ZStack {
            if open {
                CinemaRigPanel()
                    .padding([.top, .trailing, .bottom], 8)
                    .environment(\.theme, roomTheme)
                    .environment(\.colorScheme, .dark)
            }
            if store.suite.browserOpen { ToolBrowser().transition(.opacity) }
        }
    }
}

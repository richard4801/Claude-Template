import MuseCore
import SwiftUI

// PAUSED 2026-11-05: the owner asked for a prompt-first composer with compact camera chips (redesign coming). This layout
// is kept as it stands and still builds; the reusable camera layer is MuseCore/Suite/CameraPickers.swift.

// AI suite (workstream 1): D2, the Shot builder. Cast (up to 3, the studio's real characters), scene (text / image / refs),
// references, the 9:16 result pane following the newest render live, and the camera, length, shape, sound, quality and
// takes, every price from the estimate. D9 (owner): the Engines drawer replaces the camera column.

struct ShotBuilderView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(t.line).frame(height: 1)
            HStack(spacing: 0) {
                ScrollView { ShotLeftColumn().padding(18) }
                    .frame(width: 290)
                Rectangle().fill(t.line).frame(width: 1)
                ShotCenterColumn().padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(t.surface2.opacity(0.5))
                Rectangle().fill(t.line).frame(width: 1)
                ScrollView {
                    if store.isOwner && store.suite.showEngines {
                        SuiteEnginesPanel(estimate: store.suite.estimate, showToggle: true).padding(18)
                    } else {
                        ShotRightColumn().padding(18)
                    }
                }
                .frame(width: 350)
            }
        }
        .task(id: store.suite.shot) {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            await store.estimateShot()
        }
    }

    private var header: some View {
        @Bindable var suite = store.suite
        return HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Button { store.openSuite(.hub) } label: {
                    Text("VIDEO SUITE · SHOT").font(t.mono(11)).tracking(1.6).foregroundStyle(t.muted)
                }
                .buttonStyle(.plain)
                TextField("Name this shot", text: $suite.shot.title)
                    .textFieldStyle(.plain)
                    .font(t.isA ? Fonts.font("Instrument Serif", 42, .regular) : t.display(32))
            }
            Spacer(minLength: 12)
            SuiteTestBadge()
            if store.isOwner {
                Chip("Engines", on: store.suite.showEngines, icon: "server.rack") { store.suite.showEngines.toggle() }
                    .help("Owner only: what each quality runs, the compiled prompt and the cost")
            }
            MButton("Add to storyboard", icon: "rectangle.split.3x1", size: .small) { store.addShotToStoryboard() }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

// MARK: Left: cast, scene, references

private struct ShotLeftColumn: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            castSection
            sceneSection
            refsSection
        }
    }

    private var castSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SuiteSectionHead(title: "Cast") { Text("Up to 3 · identity locked").font(t.body(11.5)).foregroundStyle(t.muted) }
            if store.suiteCharacters.isEmpty {
                Muted("Make a model with a character sheet to cast her.")
                MButton("New model", icon: "person.badge.plus", size: .small) { store.go(.create) }
            }
            ForEach(store.suite.shot.castIds, id: \.self) { id in
                if let m = store.character(id) { CastCard(model: m, lead: id == store.suite.shot.castIds.first) }
            }
            ForEach(store.suiteCharacters.filter { !store.suite.shot.castIds.contains($0.id) }) { m in
                Button { store.toggleCast(m) } label: {
                    HStack(spacing: 10) {
                        MuseImage(ref: m.cover).frame(width: 32, height: 40).clipped()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.name).font(t.body(13, .semibold))
                            Text("Tap to add to shot").font(t.body(11.5)).foregroundStyle(t.muted)
                        }
                        Spacer()
                        Image(systemName: "plus").foregroundStyle(t.muted)
                    }
                    .padding(8)
                    .overlay(Rectangle().strokeBorder(t.line, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add \(m.name) to the shot")
            }
        }
    }

    private var sceneSection: some View {
        @Bindable var suite = store.suite
        return VStack(alignment: .leading, spacing: 10) {
            SuiteSectionHead(title: "Scene") {
                SuiteSeg(options: [(SceneTab.text, "Text"), (.image, "Image"), (.refs, "Refs")], selection: suite.shot.sceneTab) { suite.shot.sceneTab = $0 }
                    .frame(width: 170)
            }
            if suite.shot.sceneTab == .image {
                HStack(spacing: 8) {
                    frameTile("Start frame", suite.shot.startFrame) { store.setShotFrame(end: false) } clear: { suite.shot.startFrame = nil }
                    frameTile("End frame", suite.shot.endFrame) { store.setShotFrame(end: true) } clear: { suite.shot.endFrame = nil }
                }
            }
            TextBox(placeholder: "What happens: who, where, what she does or says.", text: $suite.shot.prompt, lines: 6)
            FlowLayout(spacing: 6) {
                Chip("Add a beat", icon: "plus") { suite.shot.prompt += (suite.shot.prompt.isEmpty ? "" : " ") + "Then, " }
                Menu {
                    Button("No emotion") { suite.shot.emotion = nil }
                    ForEach(store.suite.camera.emotions, id: \.self) { e in Button(e.capitalized) { suite.shot.emotion = e } }
                } label: {
                    Text("Emotion: \(suite.shot.emotion ?? "auto")").font(t.body(13))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 10).frame(height: 32)
                .overlay(Rectangle().strokeBorder(t.line, lineWidth: 1))
            }
        }
    }

    private func frameTile(_ label: String, _ ref: ImageRef?, pick: @escaping () -> Void, clear: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: pick) {
                Group {
                    if let ref { MuseImage(ref: ref) } else { Image(systemName: "plus").foregroundStyle(t.muted).frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
                .frame(width: 64, height: 64).clipped()
                .overlay(Rectangle().strokeBorder(t.line, style: StrokeStyle(lineWidth: 1, dash: ref == nil ? [4, 3] : [])))
            }
            .buttonStyle(.plain)
            HStack(spacing: 4) {
                Text(label.uppercased()).font(t.mono(9.5)).foregroundStyle(t.muted)
                if ref != nil { Button(action: clear) { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain).accessibilityLabel("Remove \(label)") }
            }
        }
    }

    private var refsSection: some View {
        @Bindable var suite = store.suite
        return VStack(alignment: .leading, spacing: 10) {
            SuiteSectionHead(title: "References") { Text("\(suite.shot.refs.count) of 6").font(t.body(11.5)).foregroundStyle(t.muted) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(Array(suite.shot.refs.enumerated()), id: \.offset) { i, r in
                    VStack(alignment: .leading, spacing: 4) {
                        MuseImage(ref: r.image).frame(width: 64, height: 64).clipped()
                            .overlay(alignment: .topTrailing) {
                                Button { suite.shot.refs.remove(at: i) } label: {
                                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white).padding(4).background(Color.black.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove reference")
                            }
                        Text(r.role.uppercased()).font(t.mono(9.5)).foregroundStyle(t.muted)
                    }
                }
                if suite.shot.refs.count < 6 {
                    Menu {
                        ForEach(["product", "location", "style", "prop", "person"], id: \.self) { role in
                            Button(role.capitalized) { store.addShotRef(role: role) }
                        }
                    } label: {
                        Image(systemName: "plus").frame(width: 64, height: 64)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 64, height: 64)
                    .overlay(Rectangle().strokeBorder(t.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .accessibilityLabel("Add a reference image")
                }
            }
        }
    }
}

/// A cast member's card: sheet strip, identity lock and outfit.
private struct CastCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var model: MuseModel
    var lead: Bool

    var body: some View {
        let outfits = store.outfits(for: model)
        let picked = store.suite.shot.outfitByModel[model.id] ?? outfits.first?.id
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                MuseImage(ref: model.cover).frame(width: 44, height: 56).clipped()
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name).font(t.body(14, .semibold))
                    Text("\(model.niche) · \(model.age)\(lead ? " · Lead" : "")").font(t.body(11.5)).foregroundStyle(t.muted)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 6) {
                    SuiteTag(text: "Locked", color: t.good)
                    if !lead {
                        Button { store.toggleCast(model) } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                            .buttonStyle(.plain).accessibilityLabel("Remove \(model.name) from the shot")
                    }
                }
            }
            HStack(spacing: 3) {
                ForEach(model.slots.filter { $0.image != nil }.prefix(7), id: \.key) { s in
                    MuseImage(ref: s.image).frame(width: 30, height: 38).clipped()
                }
            }
            if !outfits.isEmpty {
                HStack(spacing: 6) {
                    Text("OUTFIT").font(t.mono(10)).foregroundStyle(t.muted)
                    FlowLayout(spacing: 6) {
                        ForEach(outfits) { o in
                            Chip(o.name, on: o.id == picked) { store.suite.shot.outfitByModel[model.id] = o.id }
                        }
                    }
                }
            }
        }
        .padding(10)
        .overlay(Rectangle().strokeBorder(lead ? t.ink : t.line, lineWidth: lead ? 1.5 : 1))
    }
}

// MARK: Centre: the result pane and its takes

private struct ShotCenterColumn: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let d = store.suite.shot
        let job = store.shotJob
        let takes = store.takes(of: job)
        let lead = store.character(d.castIds.first)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                SuiteTag(text: d.aspect, color: t.ink, filled: false)
                SuiteTag(text: "\(store.suite.estimate.map { Pricing.trimNum($0.seconds) } ?? String(d.duration)) s")
                SuiteTag(text: SuiteText.tierLabel(d.quality))
                Spacer()
                if let tk = takes.first(where: { $0.id == store.suite.shotTakeId }) ?? takes.first {
                    MButton("Open in Edit", icon: "scissors", size: .small) { store.openEdit(takeId: tk.id) }
                }
            }
            HStack(alignment: .top, spacing: 14) {
                SuiteResultPane(job: job, art: d.startFrame ?? lead?.cover, character: lead, takeId: store.suite.shotTakeId)
                    .frame(maxWidth: 420)
                VStack(alignment: .leading, spacing: 8) {
                    Text("TAKES").font(t.mono(10.5)).tracking(1.2)
                    ForEach(takes) { tk in
                        Button { store.suite.shotTakeId = tk.id } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                MuseImage(ref: tk.thumb).frame(width: 72, height: 128).clipped()
                                    .overlay(Rectangle().strokeBorder(tk.id == (store.suite.shotTakeId ?? takes.first?.id) ? t.ink : .clear, lineWidth: 2))
                                Text("TAKE \(tk.index)\(tk.durationSec.map { " · \(Pricing.trimNum($0)) s" } ?? "")").font(t.mono(9.5)).foregroundStyle(t.muted)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if let j = job, j.isActive {
                        SuiteTag(text: "\(Int(j.progress.rounded()))%", color: t.rec)
                    }
                    Button { store.generateShot() } label: {
                        Image(systemName: "plus").frame(width: 72, height: 44)
                            .overlay(Rectangle().strokeBorder(t.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                    .buttonStyle(.plain)
                    .help("Generate another take")
                    .accessibilityLabel("Generate another take")
                }
                .frame(width: 80)
            }
        }
    }
}

// MARK: Right: camera, length, shape, sound, quality, takes, Generate

private struct ShotRightColumn: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        @Bindable var suite = store.suite
        let d = suite.shot
        let tier = suite.catalog?.tier(d.quality)
        let maxS = Int(tier?.maxSeconds ?? 15)
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Camera").font(t.body(16, .semibold))
                Spacer()
                SuiteSeg(options: [("preset", "Preset"), ("directed", "Directed")], selection: d.cameraTab) { suite.shot.cameraTab = $0 }
                    .frame(width: 180)
            }
            if d.cameraTab == "directed" {
                DirectedModePanel(shotTitle: d.title) { store.applyDirected($0) }
                    .frame(minHeight: 240)
            } else {
                SuiteCameraSummary(spec: d.camera) { store.openBag(.shot, tab: $0) }
            }
            Rectangle().fill(t.line).frame(height: 1)
            row("Length") {
                SuiteSeg(options: [4, 6, 8, 10, 15].filter { $0 <= maxS }.map { ($0, "\($0)s") }, selection: d.duration) { suite.shot.duration = $0 }
            }
            row("Shape") {
                SuiteSeg(options: (suite.catalog?.aspectRatios ?? ["9:16"]).prefix(4).map { ($0, $0) }, selection: d.aspect) { suite.shot.aspect = $0 }
            }
            OptionRow(title: "Sound", hint: d.audio ? "Native sound with the shot" : "Silent") { MToggle(isOn: $suite.shot.audio) }
            VStack(alignment: .leading, spacing: 8) {
                SuiteSectionHead(title: "Quality") { Text("per \(d.duration) s take").font(t.body(11.5)).foregroundStyle(t.muted) }
                SuiteTierCards(selection: d.quality, estimates: suite.tierEstimates.mapValues { e in
                    var x = e
                    x.estimate = e.estimate / Double(max(1, e.takes))
                    return x
                }) { suite.shot.quality = $0 }
            }
            row("Takes") {
                SuiteSeg(options: (1...max(1, suite.catalog?.takesMax ?? 4)).map { ($0, "\($0)") }, selection: d.takes) { suite.shot.takes = $0 }
            }
            Rectangle().fill(t.line).frame(height: 1)
            let e = suite.estimate
            SuiteGenerateBar(estimate: e, error: suite.estimateError,
                             summary: "\(e.map { Pricing.trimNum($0.seconds) } ?? String(d.duration)) s · \(SuiteText.tierLabel(d.quality)) · \(d.takes) take\(d.takes == 1 ? "" : "s")",
                             busy: suite.generating) { store.generateShot() }
        }
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 12) {
            Text(label.uppercased()).font(t.mono(10.5)).tracking(1).frame(width: 64, alignment: .leading)
            content()
        }
    }
}

/// The camera as chosen: its renders, the summary line and the move card. Taps open the bag on that tab.
struct SuiteCameraSummary: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var spec: CameraSpec
    var open: (BagTab) -> Void

    var body: some View {
        let cam = store.suite.camera
        let renders = CameraSummary.renders(spec, cam)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(renders.prefix(4), id: \.self) { r in
                    Button { open(.rig) } label: { HardwareImage(name: r).frame(width: 56, height: 56).clipped() }.buttonStyle(.plain)
                }
                if renders.isEmpty {
                    Text("Auto").font(t.body(13)).foregroundStyle(t.muted).frame(height: 56)
                }
                Spacer(minLength: 0)
                Button { open(.rig) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44).overlay(Rectangle().strokeBorder(t.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Open the camera bag")
                .accessibilityLabel("Open the camera bag")
            }
            Text(CameraSummary.parts(spec, cam).filter { !$0.contains("%") }.joined(separator: " · ").suiteOr("Auto · the camera follows the scene"))
                .font(t.mono(11.5)).foregroundStyle(t.ink).fixedSize(horizontal: false, vertical: true)
            Button { open(.move) } label: {
                HStack(spacing: 10) {
                    HardwareImage(name: spec.move.flatMap { cam.grip(for: $0.id)?.render } ?? "grip-01-dolly").frame(width: 64, height: 40).clipped()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SuiteMoves.line(move: spec.move, mix: spec.mix, catalog: cam) ?? "No move · pick one").font(t.body(13, .semibold))
                        Text(angleLine(spec, cam)).font(t.body(11.5)).foregroundStyle(t.muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(t.muted)
                }
                .padding(6)
                .overlay(Rectangle().strokeBorder(t.line, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func angleLine(_ s: CameraSpec, _ c: CameraCatalog) -> String {
        let h = s.angle?.height.flatMap { id in c.heights.first { $0.id == id }?.label } ?? "Eye level"
        let size = s.angle?.shotSize.flatMap { id in c.shotSizes.first { $0.id == id }?.label } ?? "Auto framing"
        return "\(h) · \(size) · \(Int(s.angle?.dutchDeg ?? 0))°"
    }
}

private extension String {
    func suiteOr(_ fallback: String) -> String { isEmpty ? fallback : self }
}

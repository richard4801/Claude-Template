import MuseCore
import SwiftUI

// AI suite (workstream 1): D8, Storyboard. Shots with one cast and a look lock (the camera), one quality; "Generate"
// sends the ready shots as suite shots, each priced by the estimate. "Assemble in Edit" opens workstream 3's Edit.

struct StoryboardView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        @Bindable var suite = store.suite
        VStack(spacing: 0) {
            header
            Rectangle().fill(t.line).frame(height: 1)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 10) {
                        TextBox(placeholder: "The idea: who, where, what happens. One sentence per shot.", text: $suite.board.idea, lines: 2)
                        MButton("Split into shots", icon: "sparkle", size: .small) {
                            let list = Storyboard.shotList(from: suite.board.idea)
                            if list.isEmpty { store.showToast("Write the idea first") } else { suite.board.shots = list; suite.boardShotId = list.first?.id }
                        }
                        .help("One shot per sentence. Nothing is generated or charged.")
                        MButton("Shot", icon: "plus", size: .small) {
                            let s = StoryShot(title: "Shot \(suite.board.shots.count + 1)")
                            suite.board.shots.append(s)
                            suite.boardShotId = s.id
                        }
                    }
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(Array(suite.board.shots.enumerated()), id: \.element.id) { i, s in
                                StoryCard(index: i + 1, shot: s, selected: s.id == suite.boardShotId) { suite.boardShotId = s.id }
                            }
                            if suite.board.shots.isEmpty {
                                Muted("No shots yet. Write the idea and split it, or add a shot.").padding(.top, 40)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    Spacer(minLength: 0)
                }
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Rectangle().fill(t.line).frame(width: 1)
                ScrollView { StoryShotEditor().padding(18) }.frame(width: 320)
            }
            Rectangle().fill(t.line).frame(height: 1)
            sequenceBar
        }
        .task(id: suite.board) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            await store.estimateBoard()
        }
    }

    private var header: some View {
        @Bindable var suite = store.suite
        return HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Button { store.openSuite(.hub) } label: {
                    Text("Video suite").font(t.scale.caption.font).foregroundStyle(t.muted)
                }
                .buttonStyle(.plain)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField("Name the storyboard", text: $suite.board.title).textFieldStyle(.plain)
                        .font(t.isA ? Fonts.font("Instrument Serif", 42, .regular) : t.display(32)).fixedSize()
                    Text("· \(suite.board.totalSeconds) s").font(t.isA ? Fonts.font("Instrument Serif", 42, .regular) : t.display(32)).foregroundStyle(t.muted)
                }
            }
            Spacer(minLength: 12)
            SuiteTestBadge()
            HStack(spacing: 6) {
                Text("Cast").font(t.scale.label.font).foregroundStyle(t.muted)
                ForEach(suite.board.castIds, id: \.self) { id in
                    MuseImage(ref: store.character(id)?.cover).frame(width: 28, height: 36).clipped().help(store.character(id)?.name ?? "")
                }
                Menu {
                    ForEach(store.suiteCharacters) { m in
                        Button((suite.board.castIds.contains(m.id) ? "✓ " : "") + m.name) {
                            if let i = suite.board.castIds.firstIndex(of: m.id) { suite.board.castIds.remove(at: i) } else if suite.board.castIds.count < 3 { suite.board.castIds.append(m.id) }
                        }
                    }
                } label: { Image(nsImage: Ph.menuImage("plus", 16)) } // a Menu label ignores frames; the image comes at its size
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Choose the cast")
            }
            Rectangle().fill(t.line).frame(width: 1, height: 40)
            Button { store.openPicker(.look, target: .storyboard) } label: {
                HStack(spacing: 6) {
                    Text("Look lock").font(t.scale.label.font).foregroundStyle(t.muted)
                    ForEach(CameraSummary.renders(suite.board.camera, suite.camera).prefix(2), id: \.self) { r in
                        HardwareImage(name: r).frame(width: 30, height: 30).clipped()
                    }
                    Text(lookName).font(t.body(13, .semibold))
                }
            }
            .buttonStyle(.plain)
            .help("Same camera, lens and look across all shots")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var lookName: String {
        let b = store.suite.board.camera
        let c = store.suite.camera
        let preset = b.preset.flatMap { id in c.presets.first { $0.id == id }?.label }
        let palette = b.palette?.preset.flatMap { id in c.palettes.first { $0.id == id }?.title }
        let parts = [preset, palette].compactMap { $0 }
        if parts.isEmpty, let l = ComposerCatalog.label(c.looks, store.suite.boardSettings.stock) { return l }
        return parts.isEmpty ? "Set the look" : parts.joined(separator: " · ")
    }

    private var sequenceBar: some View {
        let b = store.suite.board
        let total = max(1, b.totalSeconds)
        let states = b.shots.map { SuiteResultState.of(store.boardJob($0)) }
        let ready = states.filter { $0 == .ready }.count
        let busy = states.filter { if case .rendering = $0 { return true }; if case .queued = $0 { return true }; return false }.count
        let toGo = b.toGenerate.count
        return HStack(spacing: 16) {
            Text("Sequence").font(t.scale.label.font)
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(Array(b.shots.enumerated()), id: \.element.id) { i, s in
                        Text("\(i + 1)").font(t.mono(10)).foregroundStyle(segInk(states[i])).padding(.leading, 6)
                            .frame(width: max(18, g.size.width * CGFloat(s.seconds) / CGFloat(total) - 2), height: 30, alignment: .leading)
                            .background(segFill(states[i]))
                    }
                }
            }
            .frame(height: 30)
            Text("\(b.totalSeconds) s").font(t.mono(12))
            Text("\(ready) ready · \(busy) generating · \(toGo) to go").font(t.body(12)).foregroundStyle(t.muted).fixedSize()
            MButton("Assemble in Edit", icon: "scissors", size: .small) { store.openEdit() }
            Button { store.generateBoard() } label: {
                Text("Generate \(toGo) shot\(toGo == 1 ? "" : "s"), \(SuiteText.tierLabel(b.quality))\(store.suite.boardEstimate.map { " · \(Pricing.money($0))" } ?? "")")
                    .font(t.body(14, .semibold)).foregroundStyle(t.ctaInk)
                    .padding(.horizontal, 22).frame(height: 48).background(t.cta.opacity(toGo == 0 || store.suite.generating ? 0.45 : 1))
            }
            .buttonStyle(.plain)
            .disabled(toGo == 0 || store.suite.generating || store.suite.boardEstimate == nil)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .overlay(alignment: .topLeading) {
            if let err = store.suite.boardEstimateError { Text(err).font(t.body(11.5)).foregroundStyle(t.warn).padding(.leading, 24).offset(y: -18) }
        }
    }

    private func segFill(_ s: SuiteResultState) -> Color {
        switch s {
        case .ready: return t.ink
        case .rendering, .queued: return t.rec
        case .failed: return t.warn
        case .empty: return t.surface2
        }
    }

    private func segInk(_ s: SuiteResultState) -> Color { s == .empty ? t.ink : t.bg }
}

/// One shot's card: number, state, picture, title, move, length and line.
private struct StoryCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var index: Int
    var shot: StoryShot
    var selected: Bool
    var select: () -> Void

    var body: some View {
        let job = store.boardJob(shot)
        let state = SuiteResultState.of(job)
        let take = store.takes(of: job).first
        let lead = store.character(store.suite.board.castIds.first)
        Button(action: select) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    MuseImage(ref: take?.thumb ?? job?.thumb ?? lead?.cover).blur(radius: state.blur * 0.5)
                        .frame(width: 172, height: 220).clipped()
                    HStack {
                        Text("\(index)").font(t.isA ? Fonts.font("Instrument Serif", 20, .regular) : t.display(16)).padding(.horizontal, 6).background(t.surface)
                        Spacer()
                        tag(state)
                    }
                    .padding(8)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(shot.title).font(t.body(13.5, .semibold)).lineLimit(1)
                    HStack {
                        Text(shot.moveId.flatMap { id in store.suite.camera.libraryMove(id)?.label ?? store.suite.camera.move(id)?.label } ?? "Look lock move").font(t.body(12)).foregroundStyle(t.muted).lineLimit(1)
                        Spacer()
                        Text("\(shot.seconds) s").font(t.mono(11))
                    }
                    Text(shot.line.isEmpty ? "—" : "“\(shot.line)”").font(t.body(12).italic()).foregroundStyle(t.muted).lineLimit(1)
                }
                .padding(10)
            }
            .frame(width: 172)
            .background(t.surface)
            .overlay(Rectangle().strokeBorder(selected ? t.ink : t.line, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shot \(index), \(shot.title)")
    }

    @ViewBuilder private func tag(_ s: SuiteResultState) -> some View {
        switch s {
        case .ready: SuiteTag(text: "Ready", color: t.goodInk, filled: true)
        case .rendering(let p, _): SuiteTag(text: "Generating \(p)%", color: t.rec, filled: true)
        case .queued: SuiteTag(text: s.queueLine, color: t.rec, filled: true)
        case .failed: SuiteTag(text: "Failed", color: t.rec, filled: true)
        case .empty: if !shot.isReady { SuiteTag(text: "Needs a line", color: t.warn, filled: true) }
        }
    }
}

/// The selected shot: what happens, the line, its move and length; the board's quality and camera.
private struct StoryShotEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        @Bindable var suite = store.suite
        if let i = suite.board.shots.firstIndex(where: { $0.id == suite.boardShotId }) {
            let job = store.boardJob(suite.board.shots[i])
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    TextField("Shot title", text: $suite.board.shots[i].title).textFieldStyle(.plain).font(t.body(16, .semibold))
                    if let j = job, j.isActive { SuiteTag(text: "Generating \(Int(j.progress.rounded()))%", color: t.rec) }
                }
                TextBox(placeholder: "What happens in this shot.", text: $suite.board.shots[i].prompt, lines: 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Line").font(t.scale.label.font)
                    TextField("What she says (optional)", text: $suite.board.shots[i].line).textFieldStyle(.plain).fieldChrome()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Move").font(t.scale.label.font)
                    Menu(suite.board.shots[i].moveId.flatMap { id in suite.camera.libraryMove(id)?.label } ?? "Look lock move") {
                        Button("Look lock move") { suite.board.shots[i].moveId = nil }
                        ForEach(suite.camera.library) { m in Button("\(m.label) · \(m.tag)") { suite.board.shots[i].moveId = m.id } }
                    }
                }
                HStack(spacing: 12) {
                    Text("Length").font(t.scale.label.font).frame(width: 64, alignment: .leading)
                    SuiteSeg(options: [3, 4, 5, 8].map { ($0, "\($0)s") }, selection: suite.board.shots[i].seconds) { suite.board.shots[i].seconds = $0 }
                }
                HStack(spacing: 12) {
                    Text("Quality").font(t.scale.label.font).frame(width: 64, alignment: .leading)
                    SuiteSeg(options: SuiteText.tierIds.map { ($0, $0 == "standard" ? "Std" : SuiteText.tierLabel($0)) }, selection: suite.board.quality) { suite.board.quality = $0 }
                }
                OwnerModelPill(purpose: .storyboard) // the owner's model for every shot here (WS6); members see nothing
                Rectangle().fill(t.line).frame(height: 1)
                Text("Camera").font(t.body(15, .semibold))
                BoardLookChips()
                Muted("Keyframes come from \(store.character(suite.board.castIds.first)?.shortName ?? "the lead")’s sheet. Same cast, look and lens across all shots.")
                if let j = job, j.isDone || j.isFailed {
                    SuiteResultPane(job: j, art: store.character(suite.board.castIds.first)?.cover, character: store.character(suite.board.castIds.first)).frame(maxWidth: 260)
                }
                HStack {
                    MButton("Remove shot", icon: "trash", size: .small) {
                        suite.board.shots.remove(at: i)
                        suite.boardShotId = suite.board.shots.first?.id
                    }
                    if job != nil {
                        MButton("Make again", icon: "arrow.clockwise", size: .small) { suite.board.shots[i].jobId = nil }
                    }
                }
            }
        } else {
            Muted("Pick a shot to edit it.")
        }
    }
}

/// The storyboard's look lock as the composer's chips (Style, Camera, Look, Lighting); each opens the same picker shell.
private struct BoardLookChips: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let s = store.suite.boardSettings
        VStack(alignment: .leading, spacing: 6) {
            ForEach([ComposerChip.style, .camera, .look, .lighting], id: \.self) { chip in
                let sum = ComposerCatalog.summary(chip, s, store.suite.camera)
                Button {
                    if let p = ComposerPicker(chip: chip) { store.openPicker(p, target: .storyboard) }
                } label: {
                    HStack(spacing: 8) {
                        Text(chip.key).font(t.mono(10, .medium)).tracking(1).foregroundStyle(t.muted).frame(width: 74, alignment: .leading)
                        Text(sum.value).font(t.body(12.5, sum.auto ? .regular : .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        Ph("chevron.right", 10).foregroundStyle(t.muted)
                    }
                    .padding(.horizontal, 10).frame(height: 32)
                    .overlay(Rectangle().strokeBorder(t.line, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(sum.text(max: 80))
            }
        }
    }
}

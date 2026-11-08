import AppKit
import MuseCore
import SwiftUI

// MARK: Recipe

/// The reference plays on the left; the panel describes the selected shot and the whole edit; the lanes show its shots,
/// text, transitions and beats (plans/recreate/recipe_*.png).
struct RecreateRecipe: View {
    @Environment(\.theme) private var t

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: Space.s3) {
                    RecreatePlayer(label: "Reference")
                    RecreateTransport()
                }
                .padding(Space.s4)
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                SuiteRule(vertical: true)
                RecreatePanel()
                    .frame(width: EditSuiteEditor.inspectorWidth)
            }
            .frame(maxHeight: .infinity)
            SuiteRule()
            RecreateLanes(scores: false)
                .frame(height: EditSuiteEditor.timelineHeight)
        }
    }
}

/// The selected shot (what happens, the camera and speed, how sure the analysis is, how it will be made), then the whole
/// edit (summary, pacing, beat, Look) and anything the editor can't do yet. The total sits beside Build in the top bar.
struct RecreatePanel: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var picking = false

    var body: some View {
        let rs = store.recreate
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Space.s4) {
                    // The Cast step (Release 1 item E): who plays the lead in the new shots, chosen before Build.
                    RecreateCastRow()
                    SuiteRule()
                    if let s = rs.selected {
                        shot(s, index: rs.selectedSlot, of: rs.slots.count)
                    }
                    SuiteRule()
                    whole
                }
                .padding(Space.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Review mode: the Look shot scrolls the panel to the swatches.
            .onChange(of: SnapshotRunner.state.scrollTo) { _, id in
                if id == "recreate.look" { proxy.scrollTo(id, anchor: .bottom) }
                if id == "recreate.fill" { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .background(t.roles.canvas)
    }

    private func shot(_ s: Recipe.Slot, index: Int, of count: Int) -> some View {
        let camera = RecreateText.camera(s.camera?.motion) ?? "Still"
        let speed = (RecreateText.speed(s.speed?.ramp) ?? "Steady").lowercased()
        let sure = s.confidence.map { " · \(RecreateText.percent($0)) sure" } ?? ""
        return VStack(alignment: .leading, spacing: Space.s4) {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text("Shot \(index + 1) of \(count)").scaled(t.scale.heading, t.roles.ink)
                Text("\(RecreateText.time(s.startSec))–\(RecreateText.time(s.endSec)) · \(String(format: "%.1f", s.length)) s\(sure)")
                    .scaled(t.scale.caption, t.roles.ink2).monospacedDigit().lineLimit(1).fitProbe("shot facts")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("What happens").scaled(t.scale.label, t.roles.ink)
                if let b = RecreateText.brief(s.brief) {
                    Text(b).scaled(t.scale.caption, t.roles.ink).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Not described yet").scaled(t.scale.caption, t.roles.ink2)
                    RecreateBriefsButton()
                }
                Text("Camera: \(camera.lowercased()) · Speed: \(speed)").scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            }
            fillBox(s)
            ForEach(Array((store.recreate.recipe?.gaps ?? []).filter { g in g.atSec.map { $0 >= s.startSec && $0 < s.endSec } ?? false }.enumerated()), id: \.offset) { _, g in
                gapRow(g)
            }
        }
    }

    @ViewBuilder private func fillBox(_ s: Recipe.Slot) -> some View {
        let rs = store.recreate
        let f = rs.slotFill(s.id)
        let state = f?.state ?? "empty"
        let aspect = rs.recipe?.source?.aspect ?? "9:16"
        let failed = rs.fillErrors[s.id]
        let cant = state == "to_generate" ? rs.estimateErrors[s.id] : nil
        let starting = rs.generatingSlots.contains(s.id) && state != "generating"
        let swapping = (f?.method ?? rs.estimateInfo[s.id]?.method) == "swap"
        let shown = status(state: state, swapping: swapping, failed: failed != nil, swapFailed: f?.fallback == "generate", starting: starting)
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack {
                Text(shown).scaled(t.scale.label, failed != nil ? t.roles.caution : t.roles.ink).lineLimit(1)
                Spacer(minLength: Space.s2)
                if state == "to_generate", cant == nil, failed == nil, let amount = price(s.id, f) {
                    Text(amount).scaled(t.scale.label, t.roles.ink).monospacedDigit()
                } else if state == "generating" || starting, let p = progress(f) {
                    Text("\(p)%").scaled(t.scale.label, t.roles.ink).monospacedDigit()
                } else if state == "matched", let sc = f?.score {
                    Text("\(RecreateText.percent(sc)) alike").scaled(t.scale.label, t.roles.ink).monospacedDigit()
                }
            }
            Text(line(s, state: state, f: f, aspect: aspect, failed: failed, cant: cant, starting: starting))
                .scaled(t.scale.caption, cant != nil ? t.roles.caution : t.roles.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if state == "generating" || starting, let p = progress(f) {
                RProgress(value: Double(p) / 100)
            }
            if state == "to_generate", !starting {
                RecreateMethodPicker(slotId: s.id)
            }
            if rs.fill != nil, state != "generating", !starting {
                HStack(spacing: Space.s2) {
                    if failed != nil {
                        SuiteToolButton(title: "Try again", disabled: rs.building || rs.estimating || rs.isGenerating) {
                            Task { await store.requestRecreateBuild() }
                        }
                    }
                    Button { picking = true } label: {
                        Text(state == "matched" ? "Pick another take" : "Use one of my takes")
                            .font(t.scale.label.font).foregroundStyle(t.roles.ink).lineLimit(1)
                            .padding(.horizontal, Space.s3)
                            .frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.roles.raised))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $picking, arrowEdge: .leading) { takePicker(s) }
                }
            } else if rs.loadingFill {
                SkeletonBlock(height: 28)
            }
        }
        .padding(Space.s3)
        .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.roles.field))
        .id("recreate.fill")
    }

    /// The slot's status word: how it is made (swap or a new shot) and where it is.
    private func status(state: String, swapping: Bool, failed: Bool, swapFailed: Bool, starting: Bool) -> String {
        if failed { return swapFailed ? "Swap didn’t work" : "Didn’t generate" }
        if starting || state == "generating" { return swapping ? "Swapping in" : "Generating" }
        if swapping && state == "to_generate" { return "To swap in" }
        if swapping && state == "ready" { return "Swapped in" }
        return RecreateText.fill(state)
    }

    /// The slot's price: its estimate when priced, else the fill's own figure.
    private func price(_ slotId: String, _ f: RecreateFill.SlotFill?) -> String? {
        if let e = store.recreate.estimates[slotId], e.ok { return RecreateText.money(e.estimate) }
        return f?.estimate.map { $0.label ?? RecreateText.money($0.amount) }
    }

    /// The job's progress from the live job events (0–100), when the app has the job.
    private func progress(_ f: RecreateFill.SlotFill?) -> Int? {
        guard let id = f?.jobId, let j = store.jobs.first(where: { $0.id == id }), j.progress > 0 else { return nil }
        return Int(j.progress.rounded())
    }

    private func line(_ s: Recipe.Slot, state: String, f: RecreateFill.SlotFill?, aspect: String, failed: String?, cant: String?, starting: Bool) -> String {
        if let failed { return failed }
        if let cant { return cant }
        let swap = (f?.method ?? store.recreate.estimateInfo[s.id]?.method) == "swap"
        if state == "generating" || starting {
            return swap ? "Your lead is being swapped into this shot. You can leave this page; it carries on."
                        : "Being made with your model. You can leave this page; it carries on."
        }
        if state == "ready" { return swap ? "Swapped into the reference shot." : "Generated for this shot." }
        if let r = f?.reason { return r }
        switch state {
        case "to_generate":
            if swap { return "Your lead in the reference’s own \(String(format: "%.1f", s.length)) s: its camera, speed and look come with it." }
            return "Made with your model: \(String(format: "%.1f", s.length)) s, \(aspect)."
        case "matched": return "From one of your takes."
        default: return "Pick a take for this shot."
        }
    }

    private func takePicker(_ s: Recipe.Slot) -> some View {
        let takes = store.recreateTakeChoices
        return VStack(alignment: .leading, spacing: Space.s2) {
            Text("Use one of my takes").scaled(t.scale.heading, t.roles.ink)
            if takes.isEmpty {
                Text("No video takes yet. Make one in the Video suite.").scaled(t.scale.caption, t.roles.ink2)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(takes) { tk in
                            Button {
                                store.useTakeForRecreateSlot(s.id, take: tk)
                                picking = false
                            } label: {
                                HStack(spacing: Space.s3) {
                                    Text(tk.caption).scaled(t.scale.label, t.roles.ink).lineLimit(1)
                                    Spacer(minLength: Space.s2)
                                    if let d = tk.durationSec {
                                        Text(String(format: "%.1f s", d)).scaled(t.scale.caption, t.roles.ink2).monospacedDigit()
                                    }
                                }
                                .padding(.horizontal, Space.s2)
                                .frame(height: 32)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Use \(tk.caption)")
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .padding(Space.s4)
        .frame(width: 300)
        .background(t.roles.raised)
    }

    @ViewBuilder private var whole: some View {
        let rs = store.recreate
        if let r = rs.recipe {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("The whole edit").scaled(t.scale.heading, t.roles.ink)
                if let sum = r.summary, !sum.isEmpty {
                    Text(sum).scaled(t.scale.caption, t.roles.ink).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Space.s4) {
                    Text(r.slots.count == 1 ? "1 shot" : "\(r.slots.count) shots")
                    if let c = r.pacing?.cutsPerMin { Text("\(Int(c.rounded())) cuts a minute") }
                    if let b = r.sound?.bpm { Text("\(Int(b.rounded())) BPM") }
                }
                .scaled(t.scale.caption, t.roles.ink2)
                .monospacedDigit()
                .lineLimit(1)
            }
            if let g = r.grade {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text(g.look?.label.map { "Look · \($0)" } ?? "Look").scaled(t.scale.label, t.roles.ink).lineLimit(1)
                    RecreateSwatchStrip(swatches: g.swatches ?? [])
                }
                .id("recreate.look")
            }
            let general = r.gaps.filter { $0.atSec == nil }
            if !general.isEmpty {
                VStack(alignment: .leading, spacing: Space.s2) {
                    ForEach(Array(general.enumerated()), id: \.offset) { _, g in gapRow(g) }
                }
            }
        }
    }

    /// Something the editor can't do yet, with the moment it happens.
    private func gapRow(_ g: Recipe.Gap) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(g.note ?? "Not supported yet").scaled(t.scale.label, t.roles.caution)
            Text(g.atSec.map { "\(g.what) at \(RecreateText.time($0))" } ?? g.what)
                .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The Look as calm swatches (owner note 1): the grade's real hues, softened and ordered dark to light by MuseCore.
struct RecreateSwatchStrip: View {
    @Environment(\.theme) private var t
    var swatches: [String]
    var height: CGFloat = 28

    var body: some View {
        let soft = RecreateSwatches.soften(swatches)
        HStack(spacing: 0) {
            ForEach(soft.indices, id: \.self) { i in Color(swatch: soft[i]) }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Look colours")
    }
}

// MARK: Compare

/// After Build: the reference and your edit side by side on one playhead, the match per element above them, each shot's
/// score on its tile, and Fix shot N for the weakest (plans/recreate/compare_*.png).
struct RecreateCompare: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let rs = store.recreate
        VStack(spacing: 0) {
            VStack(spacing: Space.s3) {
                HStack(alignment: .bottom, spacing: Space.s5) {
                    metric("Overall", rs.match?.overall, big: true)
                    metric("Cuts", rs.match?.cuts)
                    metric("Text", rs.match?.text)
                    metric("Speed", rs.match?.ramps)
                    metric("Look", rs.match?.grade)
                    metric("Shots", rs.match?.shots)
                    Spacer(minLength: Space.s2)
                    if let w = rs.weakestSlot {
                        SuiteToolButton(title: "Fix shot \(w + 1)", icon: "arrows-clockwise", plain: true) { store.openRecreateFix(w) }
                    }
                }
                if let line = bakedLine {
                    // Swapped shots (G2): their camera, speed and look are the reference's own, so they count as matched.
                    Text(line).scaled(t.scale.caption, t.roles.ink2).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(line)
                }
                HStack(spacing: Space.s4) {
                    RecreatePlayer(label: "Reference")
                    RecreatePlayer(label: "Your edit", yours: true)
                }
                .frame(maxHeight: .infinity)
                RecreateTransport()
            }
            .padding(Space.s4)
            .frame(maxHeight: .infinity)
            SuiteRule()
            RecreateLanes(scores: true)
                .frame(height: EditSuiteEditor.timelineHeight)
        }
    }

    /// "Already in the shot: shot 2's camera, speed and look (swapped into the reference shot)."
    private var bakedLine: String? {
        let rs = store.recreate
        let shots = rs.slots.enumerated().filter { !(rs.baked[$0.element.id] ?? []).isEmpty }
        guard let first = shots.first else { return nil }
        let names = shots.map { "\($0.offset + 1)" }
        let which = names.count == 1 ? "shot \(names[0])" : "shots \(names.dropLast().joined(separator: ", ")) and \(names.last!)"
        return "Already in the shot: \(which) \(names.count == 1 ? "keeps" : "keep") the reference’s own \(RecreateBaked.words(rs.baked[first.element.id] ?? []))."
    }

    private func metric(_ name: String, _ v: Double?, big: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).scaled(t.scale.caption, t.roles.ink2).lineLimit(1)
            Text(RecreateText.percent(v)).scaled(big ? t.scale.title : t.scale.heading, t.roles.ink).monospacedDigit().lineLimit(1).fixedSize()
        }
        .frame(minWidth: 64, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Lanes

/// Under the players: a time ruler, then one lane each for the shots (picture, number, and whether it comes from your
/// takes or will be generated, or its score after Build), the text, the transitions and the beats. Click a shot to
/// select it. Every item sits strictly on its own time span (RecreateLaneLayout) and each lane clips to its row, so
/// nothing draws over the player or another lane, and selecting a shot only changes its border (owner test 2026-11-08).
struct RecreateLanes: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var scores: Bool

    static let labelWidth: CGFloat = 176
    /// The shot tiles' height inside their 104 pt lane.
    static let tileHeight: CGFloat = 92

    var body: some View {
        let rs = store.recreate
        let bpm = rs.recipe?.sound?.bpm.map { "Beats · \(Int($0.rounded())) BPM" } ?? "Beats"
        VStack(spacing: 0) {
            lane(28, icon: nil, label: nil, probe: "laneRuler") { w in ruler(w) }
            SuiteRule()
            lane(104, icon: "film-strip", label: "Shots", probe: "laneShots") { w in shots(w) }
            SuiteRule()
            lane(40, icon: "text-t", label: "Text", probe: "laneText") { w in texts(w) }
            SuiteRule()
            lane(36, icon: "arrows-left-right", label: "Transitions") { w in transitions(w) }
            SuiteRule()
            lane(44, icon: "metronome", label: bpm) { w in beats(w) }
            SuiteRule()
            HStack(spacing: 0) {
                Color.clear.frame(width: Self.labelWidth)
                SuiteRule(vertical: true)
                Color.clear
            }
        }
        .background(t.roles.canvas)
    }

    private func x(_ sec: Double, _ w: CGFloat) -> CGFloat {
        CGFloat(RecreateLaneLayout.x(sec, duration: store.recreate.duration, width: Double(w)))
    }

    /// One lane: its name on the left, then its content and the playhead, clipped to the row.
    private func lane<C: View>(_ h: CGFloat, icon: String?, label: String?, probe: String? = nil,
                               @ViewBuilder _ content: @escaping (CGFloat) -> C) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: Space.s2) {
                if let icon { Ph(icon, 16).foregroundStyle(t.roles.ink2) }
                if let label { Text(label).scaled(t.scale.label, t.roles.ink).lineLimit(1).fitProbe("lane \(label)") }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.s3)
            .frame(width: Self.labelWidth, height: h)
            SuiteRule(vertical: true)
            GeometryReader { g in
                ZStack(alignment: .topLeading) {
                    content(g.size.width)
                    Rectangle().fill(t.roles.accent)
                        .frame(width: 2, height: g.size.height)
                        .offset(x: x(store.recreate.time, g.size.width) - 1)
                        .allowsHitTesting(false)
                }
                .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                .background(probe.map { SnapshotFrame(key: $0) })
                .clipped()
            }
            .padding(.horizontal, Space.s2)
            .frame(height: h)
        }
        .frame(height: h)
    }

    /// Labels every 0.5, 1, 2, 5, 10, 15 or 30 s, whichever keeps them at least 48 pt apart.
    private func ruler(_ w: CGFloat) -> some View {
        let d = store.recreate.duration
        let step = RecreateLaneLayout.rulerStep(duration: d, width: Double(w))
        let marks = RecreateLaneLayout.rulerMarks(duration: d, width: Double(w))
        return ZStack(alignment: .topLeading) {
            ForEach(marks.indices, id: \.self) { i in
                let at = x(marks[i], w)
                Text(RecreateLaneLayout.rulerLabel(marks[i], step: step))
                    .scaled(t.scale.micro, t.roles.ink2).monospacedDigit().lineLimit(1).fixedSize()
                    .background(SnapshotFrame(key: "rulerLabel\(i)"))
                    .alignmentGuide(.leading) { _ in -at }
                    .alignmentGuide(.top) { _ in -7 }
            }
        }
    }

    private func shots(_ w: CGFloat) -> some View {
        let rs = store.recreate
        let spans = RecreateLaneLayout.tiles(rs.slots.map { (start: $0.startSec, end: $0.endSec) }, duration: rs.duration, width: Double(w))
        return ZStack(alignment: .topLeading) {
            ForEach(rs.slots.indices, id: \.self) { i in
                let s = rs.slots[i]
                let span = spans.indices.contains(i) ? spans[i] : RecreateLaneLayout.Span(x: 0, width: 0)
                let tagText = tag(s)
                Button { store.selectRecreateSlot(i) } label: {
                    RecreateShotTile(slot: s, index: i, tag: tagText, selected: i == rs.selectedSlot)
                }
                .buttonStyle(.plain)
                .frame(width: CGFloat(span.width), height: Self.tileHeight)
                .background(SnapshotFrame(key: "laneShot\(i)"))
                .help(tagText.map { "Shot \(i + 1): \($0)" } ?? "Shot \(i + 1)")
                .accessibilityLabel("Shot \(i + 1)")
                .accessibilityValue(tagText ?? "")
                .accessibilityAddTraits(i == rs.selectedSlot ? .isSelected : [])
                .position(x: CGFloat(span.x + span.width / 2), y: 6 + Self.tileHeight / 2)
            }
        }
    }

    /// The tile's tag: "Yours", "To swap in", "To generate", … (its score after Build); nil before the fill is read.
    private func tag(_ s: Recipe.Slot) -> String? {
        let rs = store.recreate
        if scores, let sc = rs.score(s.id) { return RecreateText.percent(sc) }
        let swap = (rs.slotFill(s.id)?.method ?? rs.estimateInfo[s.id]?.method) == "swap"
        if rs.fillErrors[s.id] != nil { return swap ? "Swap didn’t work" : "Didn’t generate" }
        if rs.generatingSlots.contains(s.id) { return swap ? "Swapping in" : "Generating" }
        guard let state = rs.slotFill(s.id)?.state else { return nil }
        switch state {
        case "matched": return "Yours"
        case "ready": return swap ? "Swapped in" : "Ready"
        case "to_generate": return rs.estimateErrors[s.id] != nil ? "Can’t be made" : (swap ? "To swap in" : "To generate")
        case "generating": return swap ? "Swapping in" : "Generating"
        default: return "To fill"
        }
    }

    /// Each text item on its time span: its words when they fit, else a "T" marker, else a dot; the tooltip has the words.
    private func texts(_ w: CGFloat) -> some View {
        let rs = store.recreate
        let items = rs.recipe?.text ?? []
        let spans = RecreateLaneLayout.texts(items.map { (start: $0.startSec, end: $0.endSec) }, duration: rs.duration, width: Double(w))
        return ZStack(alignment: .topLeading) {
            ForEach(items.indices, id: \.self) { i in
                let span = spans.indices.contains(i) ? spans[i] : RecreateLaneLayout.Span(x: 0, width: 0)
                let shown = RecreateLanes.words(items[i].words)
                if span.width >= 4 {
                    RecreateTextChip(text: shown)
                        .frame(width: CGFloat(span.width), height: 24)
                        .background(SnapshotFrame(key: "laneText\(i)"))
                        .help(shown)
                        .accessibilityElement()
                        .accessibilityLabel("Text at \(RecreateText.time(items[i].startSec))")
                        .accessibilityValue(shown)
                        .position(x: CGFloat(span.x + span.width / 2), y: 8 + 12)
                }
            }
        }
    }

    /// A text item's words as the lane and its tooltip show them: “Summer”, or "Words not read yet".
    static func words(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "Words not read yet" }
        let cased = raw.prefix(1).uppercased() + raw.dropFirst().lowercased()
        return "“\(cased)”"
    }

    /// Each transition in the room around its moment: its name when it fits, else a marker; the tooltip names it.
    private func transitions(_ w: CGFloat) -> some View {
        let rs = store.recreate
        let items = rs.recipe?.transitions ?? []
        let spans = RecreateLaneLayout.points(items.map(\.atSec), duration: rs.duration, width: Double(w))
        return ZStack(alignment: .topLeading) {
            ForEach(items.indices, id: \.self) { i in
                let span = spans.indices.contains(i) ? spans[i] : RecreateLaneLayout.Span(x: 0, width: 0)
                let name = RecreateText.transition(items[i].kind)
                let said = "\(name) at \(RecreateText.time(items[i].atSec))"
                if span.width >= 8 {
                    ViewThatFits(in: .horizontal) {
                        Text(name).scaled(t.scale.micro, t.roles.ink).lineLimit(1).fixedSize()
                            .padding(.horizontal, Space.s2).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous).fill(t.roles.field))
                        Ph("diamond", 12).foregroundStyle(t.roles.ink2).frame(width: 12, height: 20)
                        Color.clear.frame(width: 0, height: 0)
                    }
                    .frame(width: CGFloat(span.width), height: 24)
                    .contentShape(Rectangle())
                    .help(said)
                    .accessibilityElement()
                    .accessibilityLabel(said)
                    .position(x: CGFloat(span.x + span.width / 2), y: 18)
                }
            }
        }
    }

    private func beats(_ w: CGFloat) -> some View {
        let sound = store.recreate.recipe?.sound
        let strong = Set((sound?.strong ?? []).map { Int(($0 * 1000).rounded()) })
        let beats = sound?.beats ?? []
        return ZStack(alignment: .topLeading) {
            ForEach(beats.indices, id: \.self) { i in
                let on = strong.contains(Int((beats[i] * 1000).rounded()))
                RoundedRectangle(cornerRadius: 1)
                    .fill(on ? t.roles.accent : t.roles.ink2.opacity(0.5))
                    .frame(width: 2, height: on ? 24 : 18)
                    .offset(x: x(beats[i], w) - 1, y: on ? 10 : 16)
            }
        }
    }
}

/// A shot tile, exactly its slot's span: the picture, the number and the tag when there is room (the number alone when
/// narrower, a bare strip when narrower still). Hover and selection change only the border.
struct RecreateShotTile: View {
    @Environment(\.theme) private var t
    var slot: Recipe.Slot
    var index: Int
    var tag: String?
    var selected: Bool
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: min(t.radii.container, 8), style: .continuous)
        let border: Color = selected ? t.roles.selection : (hovering ? t.roles.ink2 : .clear)
        GeometryReader { g in
            RecreateStill(link: slot.thumbUrl, tone: index, icon: g.size.width >= 44)
                .frame(width: g.size.width, height: g.size.height)
                .overlay(alignment: .bottomLeading) {
                    if g.size.width >= 24 { badges.padding(4) }
                }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(border, lineWidth: selected ? 2 : 1))
        .contentShape(shape)
        .onHover { hovering = $0 }
    }

    /// The number and tag when both fit whole, else the number alone, else nothing (the tooltip and the accessibility
    /// value carry the tag).
    @ViewBuilder private var badges: some View {
        if let tag {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.s1) {
                    number
                    Spacer(minLength: Space.s1)
                    Text(tag).font(t.scale.micro.font).monospacedDigit().foregroundStyle(t.roles.ink).lineLimit(1).fixedSize()
                        .padding(.horizontal, Space.s2).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous).fill(t.roles.raised))
                }
                numberOnly
            }
        } else {
            numberOnly
        }
    }

    private var numberOnly: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) { number; Spacer(minLength: 0) }
            Color.clear.frame(width: 0, height: 0)
        }
    }

    private var number: some View {
        Text("\(index + 1)").font(t.scale.micro.font).monospacedDigit().foregroundStyle(.white).lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous).fill(Color.black.opacity(0.6)))
    }
}

/// A text item on its span: the words when they fit whole, else a small "T" marker, else a dot. Never a cut-off word.
struct RecreateTextChip: View {
    @Environment(\.theme) private var t
    var text: String

    var body: some View {
        let chip = RoundedRectangle(cornerRadius: min(t.radii.control, 6), style: .continuous)
        ViewThatFits(in: .horizontal) {
            Text(text).scaled(t.scale.micro, t.roles.ink).lineLimit(1).fixedSize()
                .padding(.horizontal, Space.s2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(chip.fill(t.roles.field))
            Ph("text-t", 12).foregroundStyle(t.roles.ink2)
                .frame(width: 20, height: 24)
                .background(chip.fill(t.roles.field))
                .frame(maxWidth: .infinity, alignment: .leading)
            Circle().fill(t.roles.ink2).frame(width: 4, height: 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

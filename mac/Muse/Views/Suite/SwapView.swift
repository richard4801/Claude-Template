import MuseCore
import SwiftUI

// AI suite (workstream 1): D7, Character swap with Recast inside it. Swap puts one studio character into a real clip
// (`mode: "swap"`); Recast replaces up to 4 people (`mode: "recast"`) and keeps the clip's motion, camera, framing and sound.
// One quality ladder (Draft / Standard / HD / Cinema); Edit and Fast · beta stay add-ons on the classic pipeline.

private struct SwapEstimateKey: Equatable {
    var draft: SwapDraft
    var clipId: String?
}

struct SwapView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(t.line).frame(height: 1)
            HStack(spacing: 0) {
                ScrollView { SwapSourceColumn().padding(18) }.frame(width: 260)
                Rectangle().fill(t.line).frame(width: 1)
                center.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(t.surface2.opacity(0.5))
                Rectangle().fill(t.line).frame(width: 1)
                ScrollView { SwapRightColumn().padding(18) }.frame(width: 320)
            }
        }
        .task(id: SwapEstimateKey(draft: store.suite.swap, clipId: store.clip?.id)) {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            await store.estimateSwap()
        }
        .onAppear {
            if store.clip == nil && store.isDemo { Task { await store.useSampleClip(bad: false, quiet: true) } }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Button { store.openSuite(.hub) } label: {
                    Text("VIDEO SUITE · CHARACTER SWAP").font(t.mono(11)).tracking(1.6).foregroundStyle(t.muted)
                }
                .buttonStyle(.plain)
                Text(store.suite.swap.kind == .swap ? "Swap into a clip" : "Recast the clip")
                    .font(t.isA ? Fonts.font("Instrument Serif", 42, .regular) : t.display(32))
            }
            Spacer(minLength: 12)
            SuiteTestBadge()
            SuiteSeg(options: [(SwapKind.swap, "Swap · one person"), (.recast, "Recast · up to \(store.suite.catalog?.recastMaxPeople ?? 4)")],
                     selection: store.suite.swap.kind) { k in
                store.suite.swap.kind = k
                if k == .recast && store.suite.swap.cast.isEmpty { store.addRecastPerson() }
                if k == .recast { store.suite.swap.addOn = nil }
            }
            .frame(width: 330)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var center: some View {
        let lead = store.character(store.suite.swap.kind == .swap ? store.suite.swap.modelId : store.suite.swap.cast.first?.characterId)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SOURCE → \((lead?.shortName ?? "Character").uppercased()) · PREVIEW").font(t.mono(10.5)).tracking(1.2).foregroundStyle(t.muted)
                Spacer()
                if let c = store.clip { Text("Using 0:00–0:\(String(format: "%02d", Int(min(30, c.durationSec.rounded())))) · \(Pricing.trimNum(c.durationSec)) s").font(t.mono(10.5)).foregroundStyle(t.muted) }
            }
            SuiteResultPane(job: store.swapJob, art: store.clipPoster, character: lead, takeId: nil,
                            emptyTitle: store.suite.swap.kind == .swap ? "Your swap\nappears here" : "Your recast\nappears here",
                            emptyLine: store.suite.swap.kind == .swap ? "Pick a clip and a character, then press Generate." : "Say who in the clip becomes whom, then press Generate.")
                .frame(maxWidth: 470)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: Left: the source clip, its checks, who to replace

private struct SwapSourceColumn: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SuiteSectionHead(title: "Source clip") { LinkText("Change…") { store.pickClip() } }
            if let poster = store.clipPoster {
                Media(ref: poster)
                if let c = store.clip {
                    Text(c.name).font(t.body(13.5, .semibold))
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(c.checks, id: \.label) { ch in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: ch.status == "good" ? "checkmark" : ch.status == "bad" ? "exclamationmark.triangle" : "clock")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(ch.status == "good" ? t.good : t.warn).frame(width: 14)
                                Text("\(ch.label) · \(ch.value)\(ch.fix.map { " — \($0)" } ?? "")").font(t.body(12)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            } else {
                Button { store.pickClip() } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "film").font(.system(size: 20))
                        Text("Choose a clip").font(t.body(13, .semibold))
                        Text(".mp4 or .mov, up to 30 s").font(t.body(11.5)).foregroundStyle(t.muted)
                    }
                    .frame(maxWidth: .infinity).frame(height: 200)
                    .overlay(Rectangle().strokeBorder(t.line, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if store.suite.swap.kind == .recast { RecastCastList() } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("WHO TO REPLACE").font(t.mono(10.5)).tracking(1.2)
                    Muted("The performer in the clip. For two or more people, use Recast.")
                }
            }
        }
    }
}

/// Recast: each person in the clip and the studio character who replaces them.
private struct RecastCastList: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    static let hints: [(String, String)] = [("left", "On the left"), ("center", "In the centre"), ("right", "On the right"), ("foreground", "In front"),
                                            ("background", "Behind"), ("first", "First to appear"), ("second", "Second"), ("third", "Third"), ("fourth", "Fourth")]

    var body: some View {
        @Bindable var suite = store.suite
        VStack(alignment: .leading, spacing: 10) {
            SuiteSectionHead(title: "Who becomes whom") { Text("\(suite.swap.cast.count) of \(suite.catalog?.recastMaxPeople ?? 4)").font(t.body(11.5)).foregroundStyle(t.muted) }
            ForEach(Array(suite.swap.cast.enumerated()), id: \.offset) { i, m in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("PERSON \(i + 1)").font(t.mono(10.5)).tracking(1)
                        Spacer()
                        Button { suite.swap.cast.remove(at: i) } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                            .buttonStyle(.plain).accessibilityLabel("Remove person \(i + 1)")
                    }
                    Menu(Self.hints.first { $0.0 == m.personHint }?.1 ?? "Where in the clip") {
                        ForEach(Self.hints.indices, id: \.self) { k in Button(Self.hints[k].1) { suite.swap.cast[i].personHint = Self.hints[k].0 } }
                    }
                    Menu {
                        ForEach(store.suiteCharacters) { c in Button(c.name) { suite.swap.cast[i].characterId = c.id; suite.swap.cast[i].outfitId = nil } }
                    } label: {
                        HStack(spacing: 6) {
                            MuseImage(ref: store.character(m.characterId)?.cover).frame(width: 20, height: 24).clipped()
                            Text("Becomes \(store.character(m.characterId)?.name ?? "…")")
                        }
                    }
                    let outfits = store.outfits(for: store.character(m.characterId))
                    if !outfits.isEmpty {
                        Menu("Outfit: \(outfits.first { $0.id == m.outfitId }?.name ?? "from the clip")") {
                            Button("From the clip") { suite.swap.cast[i].outfitId = nil }
                            ForEach(outfits) { o in Button(o.name) { suite.swap.cast[i].outfitId = o.id } }
                        }
                    }
                    Menu("Speaks: \(m.speaking.map { $0 ? "yes" : "no" } ?? "as in the clip")") {
                        Button("As in the clip") { suite.swap.cast[i].speaking = nil }
                        Button("Yes") { suite.swap.cast[i].speaking = true }
                        Button("No") { suite.swap.cast[i].speaking = false }
                    }
                }
                .padding(10)
                .overlay(Rectangle().strokeBorder(t.line, lineWidth: 1))
            }
            if let lines = store.suite.swapEstimate?.cast {
                ForEach(lines, id: \.self) { l in
                    Text("\(l.who.capitalized(with: nil)) → \(store.character(l.characterId)?.shortName ?? "")").font(t.body(11.5)).foregroundStyle(t.muted)
                }
            }
            if suite.swap.cast.count < (suite.catalog?.recastMaxPeople ?? 4) {
                MButton("Add a person", icon: "plus", size: .small) { store.addRecastPerson() }
            }
        }
    }
}

// MARK: Right: character, camera, quality, add-ons, sound, Generate

private struct SwapRightColumn: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        @Bindable var suite = store.suite
        let d = suite.swap
        VStack(alignment: .leading, spacing: 18) {
            if d.kind == .swap { characterPicker }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Camera").font(t.body(15, .semibold))
                    Spacer()
                    SuiteTag(text: "Follows the clip")
                }
                Muted("Moves, framing and cuts come from the source clip.")
            }
            VStack(alignment: .leading, spacing: 8) {
                SuiteSectionHead("Render")
                SuiteTierCards(selection: d.addOn == nil ? d.quality : "", estimates: suite.swapEstimates) { q in
                    suite.swap.quality = q
                    suite.swap.addOn = nil
                }
            }
            if d.kind == .swap { addOns }
            OptionRow(title: "Keep the clip's audio", hint: d.kind == .recast ? "The original sound comes back as it was" : nil) { MToggle(isOn: $suite.swap.keepAudio) }
            Rectangle().fill(t.line).frame(height: 1)
            if let q = d.addOn {
                let cost = Pricing.totalCost(store.spec(for: q))
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(store.clip.map { Pricing.trimNum($0.durationSec) } ?? "–") s · \(q.label)").font(t.body(13))
                        Spacer()
                        Text(Pricing.money(cost)).font(t.mono(18))
                    }
                    MButton("Generate · \(q.label) · \(Pricing.money(cost))", kind: .primary, size: .big, off: store.generateBlocked, fill: true) { store.generateSwap() }
                }
            } else {
                let e = suite.swapEstimate
                SuiteGenerateBar(estimate: e, error: store.clip == nil ? "Choose a clip first" : suite.swapError,
                                 summary: "\(e.map { Pricing.trimNum($0.seconds) } ?? "–") s · \(SuiteText.tierLabel(d.quality))\(d.kind == .recast ? " · \(d.cast.count) \(d.cast.count == 1 ? "person" : "people")" : "")",
                                 busy: suite.generating) { store.generateSwap() }
            }
        }
    }

    private var characterPicker: some View {
        @Bindable var suite = store.suite
        let m = store.character(suite.swap.modelId)
        let outfits = store.outfits(for: m)
        return VStack(alignment: .leading, spacing: 8) {
            Text("CHARACTER").font(t.mono(10.5)).tracking(1.2)
            Menu {
                ForEach(store.suiteCharacters) { c in Button(c.name) { suite.swap.modelId = c.id; suite.swap.outfitId = nil } }
            } label: {
                HStack(spacing: 10) {
                    MuseImage(ref: m?.cover).frame(width: 40, height: 50).clipped()
                    Text(m?.name ?? "Pick a character").font(t.body(14, .semibold))
                }
            }
            .menuStyle(.borderlessButton)
            if !outfits.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(outfits) { o in
                        Chip(o.name, on: o.id == (suite.swap.outfitId ?? outfits.first?.id)) { suite.swap.outfitId = o.id }
                    }
                }
            }
        }
    }

    private var addOns: some View {
        @Bindable var suite = store.suite
        return VStack(alignment: .leading, spacing: 8) {
            SuiteSectionHead("Add-ons")
            ForEach([VideoQuality.edit, .fast].filter { store.videoFeatures.isAvailable($0) }, id: \.self) { q in
                let cost = Pricing.totalCost(store.spec(for: q))
                OptionRow(title: q.label, hint: q == .edit ? "Fix hands & details, lip sync" : "Half the wait") {
                    HStack(spacing: 10) {
                        Text(Pricing.money(cost)).font(t.mono(12))
                        MToggle(isOn: Binding(get: { suite.swap.addOn == q }, set: { suite.swap.addOn = $0 ? q : nil }))
                    }
                }
            }
        }
    }
}

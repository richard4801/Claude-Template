import MuseCore
import SwiftUI

// AI suite (workstream 1): the composer's bottom bar (C1, C5). Pills for Quality, Shape, Length, Sound, Speaking and
// Takes, each opening a small list with a check or a slider, each with a one-word tooltip; then "How is this priced?"
// and Generate with the live price ("—" until known, "Free" for test renders, else the estimate's own label).

struct ComposerBottomBar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var open: String?

    private var tool: ComposerTool { store.suite.composer.tool }
    private var isSwap: Bool { tool == .swap || tool == .recast }

    var body: some View {
        HStack(spacing: 8) {
            qualityPill
            if isSwap {
                listPill("sound", icon: "speaker.wave.2", title: "Clip sound", value: store.suite.swap.keepAudio ? "On" : "Off", help: "Sound",
                         options: [("On", true), ("Off", false)], selected: store.suite.swap.keepAudio) { store.suite.swap.keepAudio = $0 }
                if tool == .swap {
                    listPill("speaking", icon: "text.bubble", title: "Speaking", value: store.suite.swap.speaking.label, help: "Speaking",
                             options: ComposerSpeaking.allCases.map { ($0.label, $0) }, selected: store.suite.swap.speaking) { store.suite.swap.speaking = $0 }
                    addOnPill
                }
            } else {
                shapePill
                lengthPill
                listPill("sound", icon: "speaker.wave.2", title: "Sound", value: store.suite.composer.sound ? "On" : "Off", help: "Sound",
                         options: [("On", true), ("Off", false)], selected: store.suite.composer.sound) { store.suite.composer.sound = $0 }
                listPill("speaking", icon: "text.bubble", title: "Speaking", value: store.suite.composer.speaking.label, help: "Speaking",
                         options: ComposerSpeaking.allCases.map { ($0.label, $0) }, selected: store.suite.composer.speaking) { store.suite.composer.speaking = $0 }
                takesPill
            }
            Spacer(minLength: 8)
            PricingLink(estimate: estimate)
            GenerateButton(label: generateLabel, enabled: canGenerate, busy: store.suite.generating) { generate() }
        }
        .padding(.leading, 16).padding(.trailing, 12)
        .frame(height: 62)
    }

    // MARK: Price

    private var estimate: ShotEstimate? { isSwap ? store.suite.swapEstimate : store.suite.estimate }

    private var price: GeneratePrice { GeneratePrice.of(estimate) }

    private var generateLabel: String {
        if isSwap, let q = store.suite.swap.addOn { return "Generate · \(Pricing.money(Pricing.totalCost(store.spec(for: q))))" }
        return price.buttonText
    }

    private var canGenerate: Bool {
        if isSwap, store.suite.swap.addOn != nil { return !store.generateBlocked }
        return price.canGenerate
    }

    private func generate() {
        if isSwap { store.generateSwap() } else { store.generateShot() }
    }

    // MARK: Pills

    private var qualityPill: some View {
        let q = store.suite.toolQuality
        return pill("quality", help: "Quality") {
            Image(systemName: "gauge.with.dots.needle.33percent")
            Text(isSwap && store.suite.swap.addOn != nil ? store.suite.swap.addOn!.label : SuiteText.tierLabel(q)).font(t.body(12.5, .medium))
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
        } popover: {
            QualityPopover(onPick: { open = nil })
        }
    }

    private var shapePill: some View {
        let ratios = store.suite.catalog?.aspectRatios ?? ComposerBar.shapes
        return listPill("shape", icon: "rectangle.portrait", title: nil, value: store.suite.composer.aspect, help: "Shape",
                        options: ratios.map { ($0, $0) }, selected: store.suite.composer.aspect) { store.suite.composer.aspect = $0 }
    }

    private var lengthPill: some View {
        let tier = store.suite.catalog?.tier(store.suite.composer.quality)
        let range = ComposerBar.lengthRange(tier)
        return pill("length", help: "Length") {
            Image(systemName: "clock")
            Text("\(store.suite.composer.duration)s").font(t.body(12.5, .medium))
        } popover: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("LENGTH").font(t.mono(10.5, .medium)).tracking(1.2)
                    Spacer()
                    Text("\(store.suite.composer.duration) s").font(t.mono(13, .medium))
                }
                Slider(value: Binding(get: { Double(store.suite.composer.duration) }, set: { store.suite.composer.duration = Int($0.rounded()) }),
                       in: Double(range.lowerBound)...Double(max(range.upperBound, range.lowerBound + 1)), step: 1) { Text("Length") }
                    .labelsHidden()
                HStack {
                    Text("\(range.lowerBound) s").font(t.body(11.5)).foregroundStyle(t.muted)
                    Spacer()
                    Text("\(range.upperBound) s on \(SuiteText.tierLabel(store.suite.composer.quality))").font(t.body(11.5)).foregroundStyle(t.muted)
                }
            }
            .padding(16).frame(width: 280)
        }
    }

    private var takesPill: some View {
        let max = store.suite.catalog?.takesMax ?? 4
        return pill("takes", help: "Takes") {
            Image(systemName: "square.stack")
            Text("\(store.suite.composer.takes)").font(t.body(12.5, .medium)) + Text(" /\(min(max, 4))").font(t.body(12.5)).foregroundColor(t.muted)
        } popover: {
            PillList(title: "Takes", options: ComposerBar.takes(max).map { ("\($0) take\($0 == 1 ? "" : "s")", $0) }, selected: store.suite.composer.takes) {
                store.suite.composer.takes = $0
                open = nil
            }
        }
    }

    private var addOnPill: some View {
        let options: [(String, VideoQuality?)] = [("None · the ladder", nil)] + [VideoQuality.edit, .fast].filter { store.videoFeatures.isAvailable($0) }.map { ($0.label, Optional($0)) }
        return listPill("addon", icon: "plus.square.on.square", title: "Add-on", value: store.suite.swap.addOn?.label ?? "None", help: "Add-ons",
                        options: options, selected: store.suite.swap.addOn) { store.suite.swap.addOn = $0 }
    }

    private func listPill<T: Hashable>(_ id: String, icon: String, title: String?, value: String, help: String, options: [(String, T)], selected: T,
                                       onPick: @escaping (T) -> Void) -> some View {
        pill(id, help: help) {
            Image(systemName: icon)
            if let title { Text(title).font(t.body(12.5, .medium)) }
            Text(value).font(t.body(12.5, title == nil ? .medium : .regular)).foregroundStyle(title == nil ? t.ink : t.muted)
        } popover: {
            PillList(title: help, options: options, selected: selected) {
                onPick($0)
                open = nil
            }
        }
    }

    private func pill<Label: View, Pop: View>(_ id: String, help: String, @ViewBuilder label: () -> Label, @ViewBuilder popover: @escaping () -> Pop) -> some View {
        let isOpen = open == id
        return Button { open = isOpen ? nil : id } label: {
            HStack(spacing: 7) { label() }
                .font(.system(size: 13))
                .foregroundStyle(t.ink)
                .padding(.horizontal, 11).frame(height: 34)
                .background(isOpen ? t.surface : t.bg)
                .overlay(RoundedRectangle(cornerRadius: t.controlRadius).strokeBorder(isOpen ? t.ink : t.line, lineWidth: isOpen ? 2 : 1))
                .clipShape(RoundedRectangle(cornerRadius: t.controlRadius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .popover(isPresented: Binding(get: { open == id }, set: { if !$0 && open == id { open = nil } }), arrowEdge: .top) {
            popover().environment(store).environment(\.theme, t)
        }
    }
}

/// A pill's small list with a check on the current value.
struct PillList<T: Hashable>: View {
    @Environment(\.theme) private var t
    var title: String
    var options: [(String, T)]
    var selected: T
    var onPick: (T) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased()).font(t.mono(10.5, .medium)).tracking(1.2).foregroundStyle(t.muted).padding(.horizontal, 14).padding(.vertical, 10)
            ForEach(options.indices, id: \.self) { i in
                let (label, v) = options[i]
                let on = v == selected
                Button { onPick(v) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(t.accent).opacity(on ? 1 : 0).frame(width: 14)
                        Text(label).font(t.body(13, on ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).frame(height: 34)
                    .background(on ? t.bg : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(label)\(on ? ", selected" : "")")
            }
        }
        .padding(.bottom, 6)
        .frame(minWidth: 200, alignment: .leading)
        .foregroundStyle(t.ink)
    }
}

/// The Quality pill's popover (C5): the four tiers with their price per take, what each takes, and the pricing link.
struct QualityPopover: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var onPick: () -> Void

    var body: some View {
        let isSwap = store.suite.composer.tool == .swap || store.suite.composer.tool == .recast
        let estimates = isSwap ? store.suite.swapEstimates : store.suite.tierEstimates
        let tiers = store.suite.catalog?.tiers ?? []
        let seconds: Int? = isSwap ? (store.suite.swapEstimate?.seconds).map { Int($0) } : store.suite.composer.duration
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("QUALITY").font(t.mono(11, .medium)).tracking(1.4)
                Text(seconds.map { "per \($0) s take · slots follow what each accepts" } ?? "slots follow what each accepts").font(t.body(12)).foregroundStyle(t.muted)
                Spacer(minLength: 8)
                PricingLink(estimate: isSwap ? store.suite.swapEstimate : store.suite.estimate)
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach(tiers) { tier in
                    let on = tier.id == store.suite.toolQuality && !(isSwap && store.suite.swap.addOn != nil)
                    let e = estimates[tier.id]
                    Button {
                        guard tier.available else { return }
                        store.suite.toolQuality = tier.id
                        if isSwap { store.suite.swap.addOn = nil }
                        store.suite.composer.duration = ComposerBar.clampLength(store.suite.composer.duration, tier)
                        onPick()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(tier.label).font(t.body(13, .bold))
                                if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(t.accent) }
                                Spacer(minLength: 4)
                                Text(e.map { Pricing.money($0.estimate / Double(max(1, $0.takes))) } ?? "—")
                                    .font(t.isA ? Fonts.font("Instrument Serif", 23, .regular) : t.mono(15, .medium))
                            }
                            Text(tier.available ? tier.detail : "Not available right now").font(t.body(12)).foregroundStyle(t.muted).lineLimit(1)
                            Text(ComposerBar.acceptsLine(tier.slots)).font(t.mono(10)).foregroundStyle(t.muted).lineLimit(2).padding(.top, 3)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .frame(width: 136, alignment: .leading)
                        .background(on ? t.surface : t.bg)
                        .overlay(Rectangle().strokeBorder(on ? t.ink : t.line, lineWidth: on ? 2 : 1))
                        .opacity(tier.available ? 1 : 0.5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(tier.label)\(e.map { ", \(Pricing.money($0.estimate))" } ?? "")\(on ? ", selected" : "")")
                }
            }
        }
        .padding(12)
        .foregroundStyle(t.ink)
        .background(t.surface)
    }
}

/// "How is this priced?" with the estimate's own lines.
struct PricingLink: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var estimate: ShotEstimate?
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Text("How is this priced?").font(t.body(12)).foregroundStyle(t.ink).underline(color: t.line)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("HOW IS THIS PRICED?").font(t.mono(10.5, .medium)).tracking(1.2).foregroundStyle(t.muted)
                Text("You pay per second of video, per take, at the quality you pick. The price is worked out before anything renders, and a failed take is refunded in full.")
                    .font(t.body(12.5)).fixedSize(horizontal: false, vertical: true)
                if let e = estimate {
                    Divider()
                    Text(e.label).font(t.body(12.5, .semibold))
                    Text(e.test ? "\(e.priceLine) · test render, free" : e.priceLine).font(t.mono(12))
                    HStack {
                        Text("Balance after").font(t.body(12)).foregroundStyle(t.muted)
                        Spacer()
                        Text(Pricing.money(max(0, store.creditUsd - (e.test ? 0 : e.estimate)))).font(t.mono(12))
                    }
                    ForEach(e.warnings.filter(SuiteText.isMemberSafe), id: \.self) { w in
                        Label(w, systemImage: "info.circle").font(t.body(11.5)).foregroundStyle(t.muted)
                    }
                    if let p = e.problem { Label(p, systemImage: "exclamationmark.triangle").font(t.body(12, .semibold)).foregroundStyle(t.warn) }
                    if let look = e.look { Text("Graded with \(look.label) · reversible in Edit").font(t.body(11.5)).foregroundStyle(t.muted) }
                }
            }
            .padding(16)
            .frame(width: 300, alignment: .leading)
            .foregroundStyle(t.ink)
        }
    }
}

/// The Generate button with the live price.
struct GenerateButton: View {
    @Environment(\.theme) private var t
    var label: String
    var enabled: Bool
    var busy: Bool
    var height: CGFloat = 44
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if busy { ProgressView().controlSize(.small).tint(t.ctaInk) }
                Text(label.uppercased()).font(t.mono(12.5, .medium)).tracking(1.8).lineLimit(1)
            }
            .foregroundStyle(t.ctaInk)
            .padding(.horizontal, 22).frame(height: height)
            .background(t.cta.opacity(enabled && !busy ? 1 : 0.45))
            .clipShape(RoundedRectangle(cornerRadius: t.controlRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || busy)
        .keyboardShortcut(.return, modifiers: .command)
        .help("Generate")
        .accessibilityLabel(label)
    }
}

import MuseCore
import SwiftUI

// AI suite (workstream 1): the composer's bottom bar (C1, C5). Pills for Quality, Shape, Length, Sound, Speaking and
// Takes, each opening a small list with a check or a slider, each with a one-word tooltip; then "How is this priced?"
// and Generate with the live price ("—" until known, "Free" for test renders, else the estimate's own label).

struct ComposerBottomBar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var open: String?
    /// The swap take the Upscale pill's picker is open for.
    @State private var upscaleTake: Take?

    private var tool: ComposerTool { store.suite.composer.tool }
    private var isSwap: Bool { tool == .swap || tool == .recast }

    var body: some View {
        // About 1000 px wide (owner): each pill is icon + value and never wraps; Generate always shows its price. When
        // the row is still too wide the pills tighten, "How is this priced?" becomes a "?" and then the pills scroll.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                pills(spacing: 8, compact: false)
                Spacer(minLength: 8)
                PricingLink(estimate: estimate)
                generateButton
            }
            HStack(spacing: 6) {
                pills(spacing: 5, compact: true)
                Spacer(minLength: 6)
                PricingLink(estimate: estimate, compact: true)
                generateButton
            }
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) { pills(spacing: 5, compact: true).padding(.vertical, 2) }
                PricingLink(estimate: estimate, compact: true)
                generateButton
            }
        }
        .padding(.leading, 16).padding(.trailing, 12)
        .frame(height: 62)
    }

    private var generateButton: some View {
        GenerateButton(label: generateLabel, enabled: canGenerate, busy: store.suite.generating) { generate() }
            .fixedSize()
            .layoutPriority(2)
    }

    /// `compact`: the owner's Engine pill shows only its icon (the engine is its tooltip).
    @ViewBuilder private func pills(spacing: CGFloat, compact: Bool) -> some View {
        HStack(spacing: spacing) {
            if tool != .photo { qualityPill } // Photo tool (workstream 3): stills render at the shoot's size, no Quality
            if isSwap {
                listPill("sound", icon: store.suite.swap.keepAudio ? "speaker.wave.2" : "speaker.slash", value: store.suite.swap.keepAudio ? "On" : "Off",
                         help: "Clip sound", options: [("On", true), ("Off", false)], selected: store.suite.swap.keepAudio) { store.suite.swap.keepAudio = $0 }
                if tool == .swap {
                    listPill("speaking", icon: "text.bubble", value: store.suite.swap.speaking.label, help: "Speaking",
                             options: ComposerSpeaking.allCases.map { ($0.label, $0) }, selected: store.suite.swap.speaking) { store.suite.swap.speaking = $0 }
                    addOnPills
                }
            } else if tool == .extend {
                // Extend: the new part's length on this quality, and takes. The shape and sound follow the video.
                lengthPill
                takesPill
            } else if tool == .photo {
                // Photo tool (workstream 3): one Photos 1–4 count in place of Shape, Length, Sound, Speaking and Takes.
                let n = store.suite.photo.count
                listPill("photos", icon: "photo.on.rectangle", value: "\(n)", help: "Photos",
                         options: PhotoDraft.counts.map { ("\($0) photo\($0 == 1 ? "" : "s")", $0) }, selected: n) { store.suite.photo.count = $0 }
            } else {
                shapePill
                lengthPill
                listPill("sound", icon: store.suite.composer.sound ? "speaker.wave.2" : "speaker.slash", value: store.suite.composer.sound ? "On" : "Off",
                         help: "Sound", options: [("On", true), ("Off", false)], selected: store.suite.composer.sound) { store.suite.composer.sound = $0 }
                listPill("speaking", icon: "text.bubble", value: store.suite.composer.speaking.label, help: "Speaking",
                         options: ComposerSpeaking.allCases.map { ($0.label, $0) }, selected: store.suite.composer.speaking) { store.suite.composer.speaking = $0 }
                takesPill
                if store.isOwner { enginePill(compact: compact) }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: Price

    private var estimate: ShotEstimate? {
        if tool == .photo { return store.suite.photoEstimate?.asShotEstimate } // Photo tool (workstream 3)
        return isSwap ? store.suite.swapEstimate : store.suite.estimate
    }

    private var price: GeneratePrice {
        if tool == .photo { return GeneratePrice.photo(store.suite.photoEstimate) } // Photo tool (workstream 3): "Generate · 4 photos · $0.24"
        return GeneratePrice.of(estimate)
    }

    private var generateLabel: String {
        if isSwap, let q = store.suite.swap.addOn { return "Generate · \(Pricing.money(Pricing.totalCost(store.spec(for: q))))" }
        if pricing { return "Generate · Pricing…" }
        return price.buttonText
    }

    /// No price yet and no reason why: the estimate is on its way (Extend without a video has no price to wait for).
    private var pricing: Bool {
        // Photo tool (workstream 3): pricing while a request exists and its estimate hasn't come back or failed.
        if tool == .photo { return store.suite.photoEstimate == nil && store.suite.photoError == nil && store.photoRequest != nil }
        guard estimate == nil, store.suite.enabled else { return false }
        if isSwap { return store.suite.swapError == nil && store.swapRequest != nil }
        if tool == .extend && store.suite.composer.extendRequest() == nil { return false }
        return store.suite.estimateError == nil
    }

    private var canGenerate: Bool {
        if isSwap, store.suite.swap.addOn != nil { return !store.generateBlocked }
        return price.canGenerate
    }

    private func generate() {
        if tool == .photo { return store.generatePhoto() } // Photo tool (workstream 3): POST /v1/suite/photos
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
        return listPill("shape", icon: "rectangle.portrait", value: store.suite.composer.aspect, help: "Shape",
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
                    Text(tool == .extend ? "ADDED LENGTH" : "LENGTH").font(t.mono(10.5, .medium)).tracking(1.2)
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

    /// Swap's add-ons as pills (Edit, Fast · beta, Upscale), each with its own price; tapping one again goes back to
    /// the Quality ladder.
    private var addOnPills: some View {
        let pills = SwapAddOns.pills(store.videoFeatures, clipSeconds: store.clip?.durationSec, takes: store.takeCount, lipSync: store.lipSync,
                                     upscaleSeconds: swapTake?.durationSec)
        return HStack(spacing: 6) {
            ForEach(pills) { p in addOnPill(p) }
        }
    }

    private func addOnPill(_ p: SwapAddOnPill) -> some View {
        let on = p.quality != nil && p.quality == store.suite.swap.addOn
        return Button {
            if p.quality == nil {
                // Upscale works on the finished swap take: its sizes and prices in a small picker.
                if let take = swapTake {
                    upscaleTake = take
                } else {
                    store.showToast("Upscale works on a finished take · generate it first")
                }
                return
            }
            store.suite.swap.addOn = SwapAddOns.toggle(store.suite.swap.addOn, p)
        } label: {
            HStack(spacing: 6) {
                if !on { Image(systemName: "plus").font(.system(size: 10, weight: .bold)) }
                Text(p.label).font(t.body(12.5, .medium))
                Text(p.priceText).font(t.mono(11)).foregroundStyle(t.muted)
            }
            .foregroundStyle(t.ink)
            .padding(.horizontal, 10).frame(height: 34)
            .background(on ? t.surface : t.bg)
            .overlay(RoundedRectangle(cornerRadius: t.controlRadius).strokeBorder(on ? t.accent : t.line, lineWidth: on ? 2 : 1))
            .clipShape(RoundedRectangle(cornerRadius: t.controlRadius))
            .opacity(p.available ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!p.available)
        .help(p.comingSoon ? "\(p.label) · coming soon" : p.detail)
        .popover(item: p.quality == nil ? $upscaleTake : .constant(nil), arrowEdge: .top) { take in
            UpscalePicker(take: take) { upscaleTake = nil }
                .environment(store)
                .environment(\.theme, PickerTheme.dark)
                .environment(\.colorScheme, .dark)
        }
        .accessibilityLabel("\(p.label) add-on, \(p.priceText)\(on ? ", on" : "")")
    }

    /// The finished swap take (a render with a stored file) Upscale works on.
    private var swapTake: Take? { store.takes(of: store.swapJob).first { $0.canUpscale } }

    /// Owner only: pin this shot's engine (one of the quality's models), "Engine · Auto" = the ladder.
    private func enginePill(compact: Bool) -> some View {
        let tier = store.suite.catalog?.tier(store.suite.composer.quality)
        let models = ComposerEngines.options(tier)
        let label = ComposerEngines.label(store.suite.composer, tier)
        return pill("engine", help: label) {
            Image(systemName: "server.rack")
            if !compact { Text(label.replacingOccurrences(of: "Engine · ", with: "")).font(t.body(12.5, .medium)) }
        } popover: {
            VStack(alignment: .leading, spacing: 0) {
                Text("ENGINE · OWNER").font(t.mono(10.5, .medium)).tracking(1.2).foregroundStyle(t.muted).padding(.horizontal, 14).padding(.vertical, 10)
                engineRow("Auto", line: "The \(SuiteText.tierLabel(store.suite.composer.quality)) ladder", on: store.suite.composer.engineModel == nil) {
                    store.suite.composer = ComposerEngines.pin(store.suite.composer, nil)
                }
                ForEach(models, id: \.self) { m in
                    let on = store.suite.composer.engineModel == m.model && (store.suite.composer.resolution ?? m.resolution) == m.resolution
                    engineRow("\(m.name) · \(m.resolution)", line: ComposerBar.acceptsLine(m.inputs ?? tier?.slots ?? .none), on: on) {
                        store.suite.composer = ComposerEngines.pin(store.suite.composer, m)
                    }
                }
                if models.isEmpty { Muted("No engines listed for this quality.").padding(14) }
            }
            .padding(.bottom, 6)
            .frame(minWidth: 280, alignment: .leading)
            .foregroundStyle(t.ink)
        }
    }

    private func engineRow(_ title: String, line: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            open = nil
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(t.accent).opacity(on ? 1 : 0).frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(t.body(13, on ? .semibold : .regular))
                    Text(line).font(t.mono(10)).foregroundStyle(t.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(on ? t.bg : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Icon + value (the name is the tooltip and the list's title).
    private func listPill<T: Hashable>(_ id: String, icon: String, value: String, help: String, options: [(String, T)], selected: T,
                                       onPick: @escaping (T) -> Void) -> some View {
        pill(id, help: help) {
            Image(systemName: icon)
            Text(value).font(t.body(12.5, .medium))
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
            HStack(spacing: 6) { label() }
                .lineLimit(1)
                .fixedSize()
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
        .accessibilityLabel(help)
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
                        if isSwap {
                            store.suite.toolQuality = tier.id
                            store.suite.swap.addOn = nil
                        } else {
                            store.setComposerQuality(tier.id)
                        }
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
    /// A narrow bar: a "?" in place of the words.
    var compact = false
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            if compact {
                Image(systemName: "questionmark.circle").font(.system(size: 15)).foregroundStyle(t.muted).frame(width: 28, height: 34).contentShape(Rectangle())
            } else {
                Text("How is this priced?").font(t.body(12)).foregroundStyle(t.ink).underline(color: t.muted).lineLimit(1).fixedSize()
            }
        }
        .buttonStyle(.plain)
        .help("How is this priced?")
        .accessibilityLabel("How is this priced?")
        .popover(isPresented: $open, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("HOW IS THIS PRICED?").font(t.mono(10.5, .medium)).tracking(1.2).foregroundStyle(t.muted)
                // Photo tool (workstream 3): photos are priced per photo, from the images sent and the size made.
                Text(store.suite.composer.tool == .photo
                     ? "You pay per photo: the price counts her reference images, your references and the size made. It is worked out before anything is made, and photos that fail aren't charged."
                     : "You pay per second of video, per take, at the quality you pick. The price is worked out before anything renders, and a failed take is refunded in full.")
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

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
    /// The composer's Setup rail has a Settings row (shape, length and takes), so the bar keeps Quality, Sound and Speaking
    /// (plans/design-direction/composer-mac-b.png).
    var settingsInRail = false

    private var tool: ComposerTool { store.suite.composer.tool }
    private var isSwap: Bool { tool == .swap || tool == .recast }

    var body: some View {
        // About 1000 pt wide (owner, coordination item 8): each pill is icon + value and never wraps; Generate always
        // shows its price. When the row is still too wide the pills tighten, "How is this priced?" becomes a "?", then
        // Generate drops its middle words ("Generate · 4 photos · $0.24" → "Generate · $0.24"), and last the pills scroll.
        // The fit check (SnapshotRunner.fitCheck) shoots this at 1440 down to 960 pt and fails on a cut pill or price.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.s2) {
                pills(spacing: Space.s2, compact: false)
                Spacer(minLength: Space.s2)
                pricingLink(compact: false)
                queueButton(compact: false)
                generateButton(short: false)
            }
            HStack(spacing: 6) {
                pills(spacing: 5, compact: true)
                Spacer(minLength: 6)
                pricingLink(compact: true)
                queueButton(compact: false)
                generateButton(short: false)
            }
            HStack(spacing: 6) {
                pills(spacing: 5, compact: true)
                Spacer(minLength: 6)
                pricingLink(compact: true)
                queueButton(compact: true)
                generateButton(short: true)
            }
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) { pills(spacing: 5, compact: true).padding(.vertical, 2) }
                pricingLink(compact: true)
                queueButton(compact: true)
                generateButton(short: true)
            }
        }
        // The prompt bar around it gives the padding; the bar sits right under the prompt (owner fix 1).
        .frame(minHeight: 48)
    }

    /// `short`: the price stays, only the words between "Generate" and it go (the full label is the tooltip and the
    /// accessibility label).
    private func generateButton(short: Bool) -> some View {
        let full = generateLabel
        let shown = short ? GenerateButton.shortLabel(full) : full
        return GenerateButton(label: shown, accessibility: full, enabled: canGenerate, busy: store.suite.generating) { generate() }
            .background { if SnapshotRunner.dir != nil { GenerateFrameProbe(label: shown) } } // CI fit check (owner fix A2)
            .fixedSize()
            .layoutPriority(2)
    }

    /// "Add to queue" (build step 3): the shot saved to run later, priced, nothing held. Secondary and quiet beside
    /// Generate; an icon with its tooltip when the bar is tight.
    @ViewBuilder private func queueButton(compact: Bool) -> some View {
        if store.canQueue {
            Button { store.addShotToQueue() } label: {
                Group {
                    if compact {
                        Ph("clock", 15).frame(width: 28, height: 34)
                    } else {
                        Text("Add to queue").font(t.scale.label.font).lineLimit(1).fixedSize()
                            .fitProbe("composer add to queue")
                            .padding(.horizontal, Space.s2).frame(height: 34)
                    }
                }
                .foregroundStyle(t.roles.ink2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(!canGenerate || store.suite.generating)
            .help("Add to queue: priced now, nothing is charged until you run it")
            .accessibilityLabel("Add to queue")
        }
    }

    private func pricingLink(compact: Bool) -> some View {
        PricingLink(estimate: estimate, compact: compact)
            .fixedSize()
            .background { if SnapshotRunner.probing { ComposerBarFrame(key: "pricing") } }
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
                    addOnPills(compact: compact)
                }
                OwnerModelPill(purpose: tool == .recast ? .recast : .swap, compact: compact) // the model (WS6; 4c: everyone)
            } else if tool == .extend {
                // Extend: the new part's length on this quality, and takes. The shape and sound follow the video.
                if !settingsInRail {
                    lengthPill
                    takesPill
                }
                OwnerModelPill(purpose: .extend, compact: compact) // the model (WS6; 4c: everyone)
            } else if tool == .photo {
                // Photo tool (workstream 3): one Photos 1–4 count in place of Shape, Length, Sound, Speaking and Takes.
                let n = store.suite.photo.count
                listPill("photos", icon: "photo.on.rectangle", value: "\(n)", help: "Photos",
                         options: PhotoDraft.counts.map { ("\($0) photo\($0 == 1 ? "" : "s")", $0) }, selected: n) { store.suite.photo.count = $0 }
                enginePill(compact: compact) // the photo model (WS6; 4c: everyone)
            } else {
                if !settingsInRail {
                    shapePill
                    lengthPill
                }
                listPill("sound", icon: store.suite.composer.sound ? "speaker.wave.2" : "speaker.slash", value: store.suite.composer.sound ? "On" : "Off",
                         help: "Sound", options: [("On", true), ("Off", false)], selected: store.suite.composer.sound) { store.suite.composer.sound = $0 }
                listPill("speaking", icon: "text.bubble", value: store.suite.composer.speaking.label, help: "Speaking",
                         options: ComposerSpeaking.allCases.map { ($0.label, $0) }, selected: store.suite.composer.speaking) { store.suite.composer.speaking = $0 }
                if !settingsInRail { takesPill }
                enginePill(compact: compact) // 4c: everyone
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
            Ph("gauge.with.dots.needle.33percent", 13)
            Text(isSwap && store.suite.swap.addOn != nil ? store.suite.swap.addOn!.label : SuiteText.tierLabel(q)).font(t.body(12.5, .medium))
            Ph("chevron.down", 9)
        } popover: {
            QualityPopover(onPick: { open = nil })
        }
    }

    private var shapePill: some View {
        let ratios = store.composerShapes // the pinned model's shapes, else the catalog's (WS6)
        return listPill("shape", icon: "rectangle.portrait", value: store.suite.composer.aspect, help: "Shape",
                        options: ratios.map { ($0, $0) }, selected: store.suite.composer.aspect) { store.suite.composer.aspect = $0 }
    }

    private var lengthPill: some View {
        let range = store.composerLengthRange // the pinned model's lengths, else the quality's (WS6)
        return pill("length", help: "Length") {
            Ph("clock", 13)
            Text("\(store.suite.composer.duration)s").font(t.body(12.5, .medium))
        } popover: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(tool == .extend ? "Added length" : "Length").font(t.scale.label.font)
                    Spacer()
                    Text("\(store.suite.composer.duration) s").font(t.mono(13, .medium))
                }
                Slider(value: Binding(get: { Double(store.suite.composer.duration) }, set: { store.setComposerLength(Int($0.rounded())) }),
                       in: Double(range.lowerBound)...Double(max(range.upperBound, range.lowerBound + 1)), step: 1) { Text("Length") }
                    .labelsHidden()
                HStack {
                    Text("\(range.lowerBound) s").font(t.body(11.5)).foregroundStyle(t.muted)
                    Spacer()
                    Text("\(range.upperBound) s on \(store.composerLengthSource)").font(t.body(11.5)).foregroundStyle(t.muted)
                }
            }
            .padding(16).frame(width: 280)
        }
    }

    private var takesPill: some View {
        let max = store.suite.catalog?.takesMax ?? 4
        return pill("takes", help: "Takes") {
            Ph("square.stack", 13)
            Text("\(store.suite.composer.takes)").font(t.body(12.5, .medium)) + Text(" /\(min(max, 4))").font(t.body(12.5)).foregroundColor(t.muted)
        } popover: {
            PillList(title: "Takes", options: ComposerBar.takes(max).map { ("\($0) take\($0 == 1 ? "" : "s")", $0) }, selected: store.suite.composer.takes) {
                store.suite.composer.takes = $0
                open = nil
            }
        }
    }

    /// Swap's Upscale pill (on the finished swap take). The Edit and Fast · beta add-ons are models now: the owner picks
    /// them in the Model list (coordinator decision 2026-11-08, as on Android), so their pills are gone.
    private func addOnPills(compact: Bool) -> some View {
        let pills = SwapAddOns.pills(store.videoFeatures, clipSeconds: store.clip?.durationSec, takes: store.takeCount, lipSync: store.lipSync,
                                     upscaleSeconds: swapTake?.durationSec).filter { $0.quality == nil }
        return HStack(spacing: 6) {
            ForEach(pills) { p in addOnPill(p, compact: compact) }
        }
    }

    /// `compact` (a tight bar, about 1000 pt): the price without "about", and Upscale's "on the take" left to its
    /// tooltip, so no pill is cut.
    private func addOnPill(_ p: SwapAddOnPill, compact: Bool) -> some View {
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
                if !on { Ph("plus", 10) }
                Text(p.label).font(t.body(12.5, .medium)).lineLimit(1).fixedSize()
                let price = compact ? Self.compactPrice(p) : p.priceText
                if !price.isEmpty {
                    Text(price).font(t.scale.caption.font).monospacedDigit().foregroundStyle(t.muted).lineLimit(1).fixedSize()
                }
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
        .background { if SnapshotRunner.probing { ComposerBarFrame(key: "pill addon \(p.id)") } }
        .accessibilityLabel("\(p.label) add-on, \(p.priceText)\(on ? ", on" : "")")
    }

    /// "about $1.42" → "$1.42"; "on the take" → "" (the tooltip says it); "Soon", "from $0.19" and "—" stay.
    static func compactPrice(_ p: SwapAddOnPill) -> String {
        let s = p.priceText
        if s == "on the take" { return "" }
        return s.hasPrefix("about ") ? String(s.dropFirst("about ".count)) : s
    }

    /// What a quality takes in plain words for its card: "Start and end frame, references, clips" (from
    /// ComposerBar.acceptsLine's "Start + end frame · refs · clips").
    static func plainAccepts(_ i: SuiteInputs) -> String {
        ComposerBar.acceptsLine(i)
            .replacingOccurrences(of: " + ", with: " and ")
            .replacingOccurrences(of: " · ", with: ", ")
            .replacingOccurrences(of: "refs", with: "references")
    }

    /// The finished swap take (a render with a stored file) Upscale works on.
    private var swapTake: Take? { store.takes(of: store.swapJob).first { $0.canUpscale } }

    /// Owner only (owner request 2026-11-08): the shot's model, "Auto" = the quality's ladder. Lists every registry model
    /// this tool can run with its limits and price (ModelPickerList); members never see it.
    private func enginePill(compact: Bool) -> some View {
        let label = store.composerModelLabel
        let pinned = store.composerPinnedModel != nil
        // Pinned: the model's own name ("Kling 4.0, 1080p"), whole, at every width.
        return pill("model", help: "Model: \(label)") {
            Ph("cpu", 13)
            if pinned || !compact {
                Text(pinned ? label : "Model").font(t.body(12.5, .medium)).lineLimit(1).fixedSize()
            }
        } popover: {
            ModelPickerList(onPick: { open = nil })
        }
    }

    /// Icon + value (the name is the tooltip and the list's title).
    private func listPill<T: Hashable>(_ id: String, icon: String, value: String, help: String, options: [(String, T)], selected: T,
                                       onPick: @escaping (T) -> Void) -> some View {
        pill(id, help: help) {
            Ph(icon, 13)
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
                .fitProbe("composer pill \(id)") // CI fit check: a wrapped or cut label is a CUT line
                .font(.system(size: 13))
                .foregroundStyle(t.roles.ink)
                // Quiet text pills on the prompt bar (the render): no box, the field tone only while its list is open.
                .padding(.horizontal, 8).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: t.radii.chip).fill(isOpen ? t.roles.field : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background { if SnapshotRunner.probing { ComposerBarFrame(key: "pill \(id)") } }
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
            Text(title).font(t.scale.label.font).foregroundStyle(t.muted).padding(.horizontal, 14).padding(.vertical, 10)
            ForEach(options.indices, id: \.self) { i in
                let (label, v) = options[i]
                let on = v == selected
                Button { onPick(v) } label: {
                    HStack(spacing: 10) {
                        Ph("checkmark", 11).foregroundStyle(t.accent).opacity(on ? 1 : 0).frame(width: 14)
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
        // An owner's engine pin sets the quality: the tiers grey out and the pinned engine's one price shows.
        let pinned = !isSwap && store.suite.composer.engineModel != nil
        VStack(alignment: .leading, spacing: 10) {
            if pinned {
                let engine = store.composerModelLabel
                VStack(alignment: .leading, spacing: 6) {
                    Text("Model pinned: \(engine). The price follows the model.").font(t.scale.label.font)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        if let e = store.suite.estimate {
                            Text("\(Pricing.money(e.estimate / Double(max(1, e.takes)))) per take").font(t.scale.caption.font).monospacedDigit()
                        }
                        Button {
                            store.pinComposerModel(nil)
                            onPick()
                        } label: {
                            Text("Back to Auto").font(t.scale.label.font).foregroundStyle(t.link)
                        }
                        .buttonStyle(.plain)
                        .help("Back to Auto: the quality's ladder picks the engine")
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Quality").font(t.scale.label.font)
                Text(seconds.map { "per \($0) s take · slots follow what each accepts" } ?? "slots follow what each accepts").font(t.body(12)).foregroundStyle(t.muted)
                Spacer(minLength: 8)
                PricingLink(estimate: isSwap ? store.suite.swapEstimate : store.suite.estimate)
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach(tiers) { tier in
                    let on = tier.id == store.suite.toolQuality && !(isSwap && store.suite.swap.addOn != nil)
                    let e = estimates[tier.id]
                    Button {
                        guard tier.available, !pinned else { return }
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
                                if on { Ph("checkmark", 11).foregroundStyle(t.accent) }
                                Spacer(minLength: 4)
                                Text(pinned ? "" : e.map { Pricing.money($0.estimate / Double(max(1, $0.takes))) } ?? "—")
                                    .font(t.isA ? Fonts.font("Instrument Serif", 23, .regular) : t.mono(15, .medium))
                            }
                            Text(tier.available ? tier.detail : "Not available right now").font(t.body(12)).foregroundStyle(t.muted).lineLimit(1)
                            Text(ComposerBottomBar.plainAccepts(tier.slots)).font(t.scale.caption.font).foregroundStyle(t.muted)
                                .fixedSize(horizontal: false, vertical: true).padding(.top, 3)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .frame(width: 136, alignment: .leading)
                        .background(on ? t.surface : t.bg)
                        .overlay(Rectangle().strokeBorder(on ? t.ink : t.line, lineWidth: on ? 2 : 1))
                        .opacity(pinned ? 0.45 : tier.available ? 1 : 0.5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(pinned)
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
                Ph("questionmark.circle", 15).foregroundStyle(t.muted).frame(width: 28, height: 34).contentShape(Rectangle())
            } else {
                Text("How is this priced?").font(t.body(12)).foregroundStyle(t.ink).underline(color: t.muted).lineLimit(1).fixedSize()
            }
        }
        .buttonStyle(.plain)
        .help("How is this priced?")
        .accessibilityLabel("How is this priced?")
        .popover(isPresented: $open, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("How is this priced?").font(t.scale.label.font).foregroundStyle(t.muted)
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
    /// The full label ("Generate · 4 photos · $0.24") when `label` is the short one; the accessibility label and tooltip.
    var accessibility: String? = nil
    var enabled: Bool
    var busy: Bool
    var height: CGFloat = 44
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if busy { ProgressView().controlSize(.small).tint(t.ctaInk) }
                Text(label).font(t.body(14, .semibold)).lineLimit(1).fixedSize()
                    .fitProbe("composer generate") // CI fit check: Generate is never cut ("GENERATE…")
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
        .help(accessibility ?? "Generate")
        .accessibilityLabel(accessibility ?? label)
    }

    /// "Generate · 4 photos · $0.24" → "Generate · $0.24": the first and last parts, so the price always shows.
    static func shortLabel(_ label: String) -> String {
        let parts = label.components(separatedBy: " · ")
        guard parts.count > 2, let first = parts.first, let last = parts.last else { return label }
        return "\(first) · \(last)"
    }
}


/// Review mode only (SnapshotRunner): reports where Generate sits in the window, so CI can check it is fully on screen.
struct GenerateFrameProbe: View {
    /// The words drawn on the button, for the fit check's "Generate shows its price" line.
    var label: String = ""
    var body: some View {
        GeometryReader { g in
            let f = g.frame(in: .global)
            Color.clear
                .onAppear { SnapshotRunner.state.generateFrame = f; SnapshotRunner.state.generateLabel = label }
                .onChange(of: f) { _, v in SnapshotRunner.state.generateFrame = v }
                .onChange(of: label) { _, v in SnapshotRunner.state.generateLabel = v }
                // The runner asks again after each screen change (the frame may not have moved at all).
                .onChange(of: SnapshotRunner.state.probeTick) { _, _ in
                    SnapshotRunner.state.generateFrame = f
                    SnapshotRunner.state.generateLabel = label
                }
        }
    }
}

/// Review mode only: where a bottom-bar pill or the pricing link sits in the window, so the fit check can tell a pill
/// that runs under "How is this priced?" or Generate (or off the window) from one drawn whole.
struct ComposerBarFrame: View {
    var key: String
    var body: some View {
        GeometryReader { g in
            let f = g.frame(in: .global)
            Color.clear
                .onAppear { SnapshotRunner.state.composerFrames[key] = f }
                .onChange(of: f) { _, v in SnapshotRunner.state.composerFrames[key] = v }
                .onChange(of: SnapshotRunner.state.probeTick) { _, _ in SnapshotRunner.state.composerFrames[key] = f }
                .onDisappear { SnapshotRunner.state.composerFrames[key] = nil }
        }
    }
}

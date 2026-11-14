import MuseCore
import SwiftUI

// The Suite redesign (owner-approved 2026-11-11, plans/studio-redesign.md; mocks in design/studio-redesign/):
// - The stage: the picture sized to its shape and capped at about half the page height, centred, with the strip of this
//   tool's takes under it (click one to show it).
// - Folding section headers for the right column (Setup, Inputs) with a one-line summary.
// - On small windows (or with Setup hidden) the column becomes a row of buttons above the prompt: one per Setup row,
//   each opening the same picker, and "Inputs", which opens the slots in a popover.

/// The picture and the takes strip under it.
struct ComposerStage: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @Binding var pinned: String?
    var maxPictureHeight: CGFloat

    /// The shape the tool renders ("16:9" → 16/9). Photo, Swap and Recast show their own media at its own shape.
    private var ratio: CGFloat? {
        switch store.suite.composer.tool {
        case .photo, .swap, .recast: return nil
        default:
            let parts = store.suite.composer.aspect.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return 16.0 / 9.0 }
            return CGFloat(parts[0] / parts[1])
        }
    }

    /// A finished take on the stage: the take viewer sizes it to its own shape and puts its actions under it, so the stage
    /// gives it the whole width (build 582: inside the tool's 9:16 box the actions were cut and the take squeezed out).
    private var showsTake: Bool {
        guard !store.suite.generating else { return false }
        let job = pinned.flatMap { id in store.jobs.first { $0.id == id } } ?? store.stageJob(store.suite.composer.tool)
        if case .ready = SuiteResultState.of(job) { return true }
        return false
    }

    /// The job on the stage: a take picked in the strip, else this tool's latest.
    private var stageJob: Job? {
        pinned.flatMap { id in store.jobs.first { $0.id == id } } ?? store.stageJob(store.suite.composer.tool)
    }

    var body: some View {
        let width = showsTake ? nil : ratio.map { maxPictureHeight * $0 }
        Group {
            if showsTake, let job = stageJob {
                // The redesign's Shot stage: title and actions above the take, the timeline under it.
                ShotStageTake(job: job)
            } else {
                VStack(spacing: Space.s3) {
                    Spacer(minLength: 0)
                    Group {
                        if let r = ratio {
                            ComposerMediaPane(pinned: pinned).aspectRatio(r, contentMode: .fit)
                        } else {
                            ComposerMediaPane(pinned: pinned)
                        }
                    }
                    .frame(maxWidth: width ?? .infinity, maxHeight: maxPictureHeight)
                    // The strip of this tool's takes: never narrower than its thumbnails need (build 582 cut it at the 9:16 width).
                    ComposerTakesStrip(pinned: $pinned)
                        .frame(maxWidth: max(width ?? .infinity, 560), alignment: .center)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(Space.s4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .suiteStage(t)
    }
}

/// This tool's latest takes as small thumbnails; the one on the stage is outlined. Shown once there are two or more.
struct ComposerTakesStrip: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @Binding var pinned: String?

    private var takes: [Job] {
        let tool = store.suite.composer.tool.rawValue
        let me = store.user?.id
        let mine = store.jobs.filter { $0.suiteTool == tool && (me == nil || $0.userId == nil || $0.userId == me) }
        return Array(mine.sorted { $0.createdAt > $1.createdAt }.prefix(8))
    }

    var body: some View {
        let list = takes
        let stage = store.stageJob(store.suite.composer.tool)?.id
        let shown = pinned ?? stage
        if list.count > 1 {
            HStack(spacing: Space.s3) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.s2) {
                        ForEach(list) { j in tile(j, selected: j.id == shown, stage: stage) }
                    }
                    .padding(3)
                }
                Button {
                    store.suite.feedOpen = true
                    store.suite.claude.open = false
                } label: {
                    Text("All takes").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                        .lineLimit(1).fixedSize()
                        .frame(minHeight: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Everything you made with this tool, newest first")
            }
            .frame(height: 50)
        }
    }

    private func tile(_ j: Job, selected: Bool, stage: String?) -> some View {
        let shape = RoundedRectangle(cornerRadius: t.radii.chip)
        return Button {
            pinned = j.id == stage ? nil : j.id
        } label: {
            ZStack {
                shape.fill(t.roles.field)
                if let thumb = j.thumb { Color.clear.overlay(MuseImage(ref: thumb)).clipped() }
                if j.isActive {
                    Color.black.opacity(0.45)
                    Text("\(Int(j.progress.rounded()))%").font(t.scale.micro.font).monospacedDigit().foregroundStyle(.white)
                } else if j.isFailed {
                    Color.black.opacity(0.45)
                    Ph("warning", 14).foregroundStyle(.white)
                }
            }
            .frame(width: 72, height: 40)
            .clipShape(shape)
            .overlay(RoundedRectangle(cornerRadius: t.radii.chip + 3).strokeBorder(selected ? t.roles.selection : .clear, lineWidth: 2).padding(-3))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(j.prompt.isEmpty ? "Show this take" : j.prompt)
        .accessibilityLabel("Take\(j.isActive ? ", rendering" : j.isFailed ? ", failed" : "")\(selected ? ", shown" : "")")
    }
}

/// A folding section header: caret, title, a quiet summary on the right and an optional trailing button.
struct RailSection: View {
    @Environment(\.theme) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var title: String
    var summary: String?
    @Binding var open: Bool
    var trailing: AnyView?

    var body: some View {
        HStack(spacing: Space.s2) {
            Button {
                if reduceMotion { open.toggle() } else { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } }
            } label: {
                HStack(spacing: 6) {
                    Ph(open ? "caret-down" : "caret-right", 12).foregroundStyle(t.roles.ink2)
                    Text(title).font(t.scale.heading.font).foregroundStyle(t.roles.ink)
                    Spacer(minLength: Space.s2)
                    if let summary {
                        Text(summary).font(t.scale.caption.font).foregroundStyle(t.roles.ink2).lineLimit(1)
                    }
                }
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "Fold \(title)" : "Show \(title)")
            .accessibilityLabel("\(title), \(open ? "shown" : "folded")\(summary.map { ", \($0)" } ?? "")")
            if let trailing { trailing }
        }
        .padding(.bottom, Space.s1)
    }
}

/// Small windows: the Setup rows as buttons above the prompt, then "Inputs" (a popover with the slots and the tool's
/// controls). Each Setup button opens the same picker as its row.
struct ComposerSetupStrip: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var inputsOpen = false

    var body: some View {
        let tool = store.suite.composer.tool
        let chips = ComposerRail.order.filter { tool.chips.contains($0) }
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chips, id: \.self) { SetupStripButton(chip: $0) }
                }
            }
            Button { inputsOpen = true } label: {
                HStack(spacing: 6) {
                    Ph("images", 14).foregroundStyle(t.roles.ink2)
                    Text("Inputs").font(t.scale.caption.font).foregroundStyle(t.roles.ink)
                    if let n = filled { Text(n).font(t.scale.caption.font).foregroundStyle(t.roles.ink2) }
                }
                .padding(.horizontal, 10).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: t.radii.control).fill(t.roles.field))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Character, frames and references")
            .accessibilityLabel("Inputs\(filled.map { ", \($0)" } ?? "")")
            .popover(isPresented: $inputsOpen, arrowEdge: .top) {
                ScrollView(.vertical, showsIndicators: false) {
                    ComposerRail(narrow: true, showSetup: false).padding(Space.s4)
                }
                .frame(width: 320)
                .frame(maxHeight: 520)
                .environment(store)
                .environment(\.theme, t)
            }
        }
        .frame(height: 32)
    }

    /// "1 of 3" filled input slots (Photo has its own count).
    private var filled: String? {
        guard store.suite.composer.tool != .photo else { return nil }
        let slots = store.suite.composerSlots.slots
        let ids = slots.visible(store.composerInputs)
        guard !ids.isEmpty else { return nil }
        return "\(ids.filter { slots[$0] != nil }.count) of \(ids.count)"
    }
}

/// One Setup row as a compact button: "Camera  35 mm film ▾" (the value quiet while on Auto).
struct SetupStripButton: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var chip: ComposerChip
    @State private var refsOpen = false

    var body: some View {
        let name = SetupChipRow.name(chip)
        // Photo tool (workstream 3): a Photo preset sets its own camera and light.
        let locked = (chip == .camera || chip == .lighting) && store.suite.composer.tool == .photo && store.suite.photo.presetId != nil
        let v = SetupChipRow.value(chip, store)
        let text = locked ? "From preset" : v.text
        Button {
            if chip == .references { refsOpen = true } else if let p = ComposerPicker(chip: chip) { store.openPicker(p) }
        } label: {
            HStack(spacing: 5) {
                Text(name).foregroundStyle(t.roles.ink2)
                Text(text).foregroundStyle(v.auto || locked ? t.roles.ink2 : t.roles.ink).lineLimit(1)
                Ph("caret-down", 10).foregroundStyle(t.roles.ink2)
            }
            .font(t.scale.caption.font)
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: t.radii.control).fill(t.roles.field))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(locked)
        .help("\(name): \(text)")
        .accessibilityLabel("\(name), \(text)")
        .popover(isPresented: $refsOpen, arrowEdge: .top) { ReferencesPopover().environment(store).environment(\.theme, t) }
    }
}

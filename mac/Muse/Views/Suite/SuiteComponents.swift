import AppKit
import MuseCore
import SwiftUI

// AI suite (workstream 1): pieces shared by the video suite screens.

/// A photoreal hardware render from the bundled `hardware/` folder, filling its frame; neutral art if it's missing.
struct HardwareImage: View {
    var name: String?
    var body: some View {
        GeometryReader { g in
            Group {
                if let img = HardwareRenders.image(name) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Placeholder(key: name ?? "empty", symbol: "camera")
                }
            }
            .frame(width: g.size.width, height: g.size.height)
            .clipped()
        }
    }
}

/// Small mono caps tag ("IN BAG", "UGC", "READY").
struct SuiteTag: View {
    @Environment(\.theme) private var t
    var text: String
    var color: Color?
    var filled = false
    var body: some View {
        let c = color ?? t.muted
        Text(text)
            .font(t.scale.micro.font)
            .foregroundStyle(filled ? Self.ink(on: c) : c)
            .padding(.horizontal, 6).frame(height: 18)
            .background(Rectangle().fill(filled ? c : .clear))
            .overlay(Rectangle().strokeBorder(c, lineWidth: 1))
            .fixedSize()
    }

    /// White or near-black on a filled tag, whichever reads (Camera Body's green and amber fills are light).
    static func ink(on fill: Color) -> Color {
        guard let n = NSColor(fill).usingColorSpace(.sRGB) else { return .white }
        func byte(_ v: CGFloat) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        let hex = (byte(n.redComponent) << 16) | (byte(n.greenComponent) << 8) | byte(n.blueComponent)
        return Contrast.bestInk(on: hex) == 0xFFFFFF ? .white : Color(hex: Contrast.darkInk)
    }
}

/// "Test renders · free" (catalog.test).
struct SuiteTestBadge: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        if store.suite.catalog?.test == true {
            Pill(SuiteText.testBadge, .warn)
                .help(store.isOwner ? "The server makes free test-pattern renders (SUITE_MODE=mock)" : "Renders here are free test patterns for now")
        }
    }
}

/// A section label row: "CAST" on the left, a hint on the right.
struct SuiteSectionHead<Trailing: View>: View {
    @Environment(\.theme) private var t
    var title: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(t.scale.heading.font).foregroundStyle(t.ink) // sentence case (plans/design-direction.md §3)
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension SuiteSectionHead where Trailing == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
}

/// A panel column with the suite's hairline borders.
struct SuitePanel<Content: View>: View {
    @Environment(\.theme) private var t
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A bordered segmented picker in the suite's look ("4S 6S 8S").
struct SuiteSeg<T: Hashable>: View {
    @Environment(\.theme) private var t
    var options: [(T, String)]
    var selection: T
    var onPick: (T) -> Void
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let (v, l) = options[i]
                let on = v == selection
                Button { onPick(v) } label: {
                    Text(l).font(t.body(12, on ? .semibold : .regular))
                        .foregroundStyle(on ? t.bg : t.muted)
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .background(on ? t.ink : t.surface)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if i < options.count - 1 { Rectangle().fill(t.line).frame(width: 1, height: 30) }
            }
        }
        .overlay(Rectangle().strokeBorder(t.line, lineWidth: 1))
    }
}

/// D10: the 9:16 result pane (empty, in line, rendering with the blurred picture and three named steps, ready, failed).
struct SuiteResultPane: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var job: Job?
    /// The picture under the blur: the start frame, the clip or the character.
    var art: ImageRef?
    var character: MuseModel?
    var takeId: String?
    var emptyTitle = "Your shot\nappears here"
    var emptyLine = "Pick a character, describe the moment, press Generate."
    /// WS19: the result shown when the job made several (Photo × 4, takes): ← → / the dots move through them.
    @State private var page = 0

    var body: some View {
        let state = SuiteResultState.of(job)
        Group {
            if case .ready = state {
                // A finished take: the one take viewer, at the take's own shape (no 9:16 box around a landscape take).
                ready
            } else {
                Color.clear
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .overlay(content(state))
                    .clipped()
            }
        }
        .animation(.easeOut(duration: 0.6), value: state)
        .accessibilityElement(children: .contain)
        .onChange(of: job?.id) { page = 0 }
    }

    @ViewBuilder private func content(_ state: SuiteResultState) -> some View {
        switch state {
        case .empty: empty
        case .queued: busy(state, percent: nil)
        case .rendering(let p, _): busy(state, percent: p)
        case .ready: ready
        case .failed(let message): failed(message)
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            if let m = character {
                MuseImage(ref: m.cover).frame(width: 64, height: 80).clipped()
            }
            Text(emptyTitle).font(t.isA ? Fonts.font("Instrument Serif", 26, .regular) : t.display(22)).multilineTextAlignment(.center)
            Text(emptyLine).font(t.body(12)).foregroundStyle(t.muted).multilineTextAlignment(.center).padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t.surface)
        .overlay(Rectangle().strokeBorder(t.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    private func busy(_ state: SuiteResultState, percent: Int?) -> some View {
        let j = job
        let takeLine = j.map { $0.isPhoto ? Job.memberPhase($0.phase) : $0.request.takes > 1 ? "Rendering take \($0.take) of \($0.request.takes)" : "Rendering" } ?? "Rendering"
        let step: Int = { if case .rendering(_, let s) = state { return s } else { return -1 } }()
        return ZStack {
            MuseImage(ref: art ?? character?.cover)
                .blur(radius: state.blur, opaque: true)
                .overlay(Color.black.opacity(0.18))
            VStack(spacing: 14) {
                if let p = percent {
                    Text(takeLine).font(t.scale.label.font).foregroundStyle(.white)
                    Text("\(p)%").font(t.isA ? Fonts.font("Instrument Serif", 72, .regular) : t.display(60)).foregroundStyle(.white)
                        .contentTransition(.numericText())
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.3))
                            Rectangle().fill(t.rec).frame(width: g.size.width * CGFloat(p) / 100)
                        }
                    }
                    .frame(width: 180, height: 3)
                    if j?.isPhoto != true { VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(SuiteResultState.steps(character: character?.shortName).enumerated()), id: \.offset) { i, s in
                            HStack(spacing: 10) {
                                Ph(i < step ? "checkmark" : i == step ? "chevron.right" : "clock", 11)
                                    .foregroundStyle(i < step ? t.good : i == step ? t.rec : t.muted).frame(width: 14)
                                Text(s).font(t.body(12.5)).foregroundStyle(i <= step ? t.ink : t.muted)
                            }
                        }
                    }
                    .padding(12)
                    .background(t.surface.opacity(0.92)) }
                    if let j, j.secondsLeft > 0 {
                        Text("About \(Job.aboutTime(j.secondsLeft)) left · you can leave this screen").font(t.body(11.5)).foregroundStyle(.white.opacity(0.9))
                    }
                } else {
                    Text(state.queueLine).font(t.scale.label.font).foregroundStyle(.white)
                        .padding(.horizontal, 10).frame(height: 24).background(Color.black.opacity(0.8))
                    Text("Leaving is safe · we'll tell you when it's ready").font(t.body(11.5)).foregroundStyle(.white.opacity(0.9))
                }
            }
            .padding(16)
        }
        .accessibilityLabel(percent.map { "Rendering, \($0) percent" } ?? state.queueLine)
        .background { if SnapshotRunner.probing { ComposerBarFrame(key: "stage busy") } }
    }

    /// The finished take(s) in the take viewer (plans/swap-viewer-design.md §B): its shape, the keys, the preview menu and
    /// its actions. Several results (Photo × 4, takes): "2 of 4" with ‹ › above it, and ↑ ↓ in the viewer.
    @ViewBuilder private var ready: some View {
        let list = store.takes(of: job)
        let start = list.firstIndex { $0.id == takeId } ?? 0
        let at = list.isEmpty ? 0 : (start + page) % list.count
        let take = list.isEmpty ? nil : list[at]
        VStack(spacing: Space.s2) {
            if list.count > 1 {
                HStack(spacing: Space.s2) {
                    Text("\(at + 1) of \(list.count)").font(t.scale.caption.font).monospacedDigit().foregroundStyle(t.roles.ink2)
                    Spacer(minLength: 0)
                    SuiteIconButton(systemName: "caret-left", label: "Previous result") { step(-1, count: list.count) }
                    SuiteIconButton(systemName: "caret-right", label: "Next result") { step(1, count: list.count) }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Result \(at + 1) of \(list.count)")
            }
            if let take {
                TakeViewer(media: ViewerMedia(take: take), context: .suite, take: take, job: job, compact: true, startMuted: true,
                           onStep: list.count > 1 ? { step($0, count: list.count) } : nil)
                    .id(take.id)
            } else {
                MuseImage(ref: job?.thumb ?? art).aspectRatio(9.0 / 16.0, contentMode: .fit)
            }
        }
        .background { if SnapshotRunner.probing { ComposerBarFrame(key: "stage ready") } }
        .background { if SnapshotRunner.probing && list.count > 1 { ComposerBarFrame(key: "stage carousel \(at + 1)/\(list.count)") } }
    }

    private func step(_ d: Int, count: Int) { page = ((page + d) % count + count) % count }


    private func failed(_ message: String) -> some View {
        let tier = job?.request.quality ?? "draft"
        let lower = SuiteText.tierIds.firstIndex(of: tier).flatMap { $0 > 0 ? SuiteText.tierIds[$0 - 1] : nil }
        return ZStack {
            MuseImage(ref: art ?? character?.cover).blur(radius: 6, opaque: true).overlay(Color.black.opacity(0.55))
            VStack(spacing: 10) {
                Text("That take didn't work").font(t.isA ? Fonts.font("Instrument Serif", 26, .regular) : t.display(20)).foregroundStyle(.white)
                Text(message).font(t.body(12)).foregroundStyle(.white.opacity(0.9)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                if let j = job, j.canRecover {
                    // Already made and charged at the provider: Recover is free (owner only); Retry would pay again.
                    if store.isOwner {
                        Button { store.recover(j) } label: {
                            Text(ScreenCopy.recoverLabel).font(t.scale.label.font).foregroundStyle(.white).padding(.horizontal, 12).frame(height: 26).background(t.rec)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(ScreenCopy.recoverByOwner).font(t.body(11)).foregroundStyle(.white.opacity(0.8))
                    }
                } else if let j = job {
                    Button { store.retakeShot(j) } label: {
                        // Not free: the failed run was refunded and the retry is a new run (owner bug 2026-11-11).
                        Text(j.isPhoto ? "Make again" : j.cost > 0 ? ScreenCopy.retryLabel(cost: j.cost, estimate: 0) : "Retry").font(t.scale.label.font).foregroundStyle(.white).padding(.horizontal, 12).frame(height: 26).background(t.rec)
                    }
                    .buttonStyle(.plain)
                    if let lower, !j.isPhoto {
                        Button { store.tryCheaper(j) } label: {
                            Text("Try \(SuiteText.tierLabel(lower))").font(t.scale.label.font).foregroundStyle(.white)
                                .padding(.horizontal, 12).frame(height: 26).overlay(Rectangle().strokeBorder(.white, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(18)
        }
    }
}

/// The suite is off on the server: the owner's way to turn it on, or a member's note.
struct SuiteOffView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Ph("video.slash", 28).foregroundStyle(t.muted)
            if store.isOwner {
                Text(SuiteText.offOwnerTitle).font(t.isA ? Fonts.font("Instrument Serif", 40, .regular) : t.display(30))
                Text(SuiteText.offOwnerBody).font(t.body(14)).foregroundStyle(t.muted).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text("\(SuiteText.offVariable) = live | mock").font(t.mono(13)).padding(.horizontal, 10).frame(height: 32).background(t.surface2)
                    MButton("Copy \(SuiteText.offVariable)", icon: "doc.on.doc", size: .small) { store.copy(SuiteText.offVariable, toast: "Copied \(SuiteText.offVariable)") }
                }
                Muted("live: real renders, billed to the studio balance · mock: free test renders, to try the suite")
                MButton("Check again", icon: "arrow.clockwise", size: .small) { Task { await store.loadSuite(force: true) } }
            } else {
                Text(SuiteText.offMember).font(t.isA ? Fonts.font("Instrument Serif", 34, .regular) : t.display(26)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Settings → Connections (owner): opens workstream 2's ConnectionsView.
struct SuiteConnectionsRow: View {
    @State private var open = false

    var body: some View {
        // Same row as the other Settings sections (SettingsViews.swift): text only, no icon or subtitle.
        SettingsNavRow(title: "Connections", on: open) { open = true }
            .help("Claude and MCP, and the Blender relay")
            .sheet(isPresented: $open) {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button("Done") { open = false }.keyboardShortcut(.cancelAction).padding(12)
                    }
                    ConnectionsView()
                }
                .frame(minWidth: 720, minHeight: 520)
            }
    }
}

/// A small take action: icon + label, or icon only with the label as tooltip when space is short.
struct TakeActionButton: View {
    var title: String
    var icon: String
    var iconOnly: Bool
    var off = false
    var action: () -> Void

    var body: some View {
        if iconOnly {
            Button(action: action) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).frame(minWidth: 14)
            }
            .buttonStyle(MuseButtonStyle(kind: .secondary, size: .small, off: off, fill: false))
            .help(title)
            .accessibilityLabel(title)
        } else {
            MButton(title, icon: icon, size: .small, off: off, action: action)
                .lineLimit(1)
                .help(title)
        }
    }
}

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
        Text(text.uppercased())
            .font(t.mono(9.5, .medium)).tracking(0.8)
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
                    Text(l.uppercased()).font(t.mono(11, on ? .semibold : .regular)).tracking(0.6)
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
    @State private var muted = true

    var body: some View {
        let state = SuiteResultState.of(job)
        Color.clear
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .overlay(content(state))
            .clipped()
            .animation(.easeOut(duration: 0.6), value: state)
            .accessibilityElement(children: .contain)
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
        let takeLine = j.map { $0.request.takes > 1 ? "Rendering take \($0.take) of \($0.request.takes)" : "Rendering" } ?? "Rendering"
        let step: Int = { if case .rendering(_, let s) = state { return s } else { return -1 } }()
        return ZStack {
            MuseImage(ref: art ?? character?.cover)
                .blur(radius: state.blur, opaque: true)
                .overlay(Color.black.opacity(0.18))
            VStack(spacing: 14) {
                if let p = percent {
                    Text(takeLine.uppercased()).font(t.mono(11, .medium)).tracking(1.4).foregroundStyle(.white)
                    Text("\(p)%").font(t.isA ? Fonts.font("Instrument Serif", 72, .regular) : t.display(60)).foregroundStyle(.white)
                        .contentTransition(.numericText())
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.3))
                            Rectangle().fill(t.rec).frame(width: g.size.width * CGFloat(p) / 100)
                        }
                    }
                    .frame(width: 180, height: 3)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(SuiteResultState.steps(character: character?.shortName).enumerated()), id: \.offset) { i, s in
                            HStack(spacing: 10) {
                                Ph(i < step ? "checkmark" : i == step ? "chevron.right" : "clock", 11)
                                    .foregroundStyle(i < step ? t.good : i == step ? t.rec : t.muted).frame(width: 14)
                                Text(s).font(t.body(12.5)).foregroundStyle(i <= step ? t.ink : t.muted)
                            }
                        }
                    }
                    .padding(12)
                    .background(t.surface.opacity(0.92))
                    if let j, j.secondsLeft > 0 {
                        Text("About \(Job.aboutTime(j.secondsLeft)) left · you can leave this screen").font(t.body(11.5)).foregroundStyle(.white.opacity(0.9))
                    }
                } else {
                    Text(state.queueLine.uppercased()).font(t.mono(11, .medium)).tracking(1.4).foregroundStyle(.white)
                        .padding(.horizontal, 10).frame(height: 24).background(Color.black.opacity(0.8))
                    Text("Leaving is safe · we'll tell you when it's ready").font(t.body(11.5)).foregroundStyle(.white.opacity(0.9))
                }
            }
            .padding(16)
        }
        .accessibilityLabel(percent.map { "Rendering, \($0) percent" } ?? state.queueLine)
    }

    @ViewBuilder private var ready: some View {
        let list = store.takes(of: job)
        let take = list.first { $0.id == takeId } ?? list.first
        VStack(spacing: 0) {
            ZStack {
                if let v = take?.videoUrl, let url = URL(string: v) {
                    StageVideo(url: url, poster: take?.thumb, muted: muted)
                } else {
                    MuseImage(ref: take?.thumb ?? job?.thumb ?? art)
                }
            }
            .overlay(alignment: .topLeading) { SuiteTag(text: "Ready", color: t.goodInk, filled: true).padding(8) }
            .overlay(alignment: .topTrailing) {
                if take?.videoUrl != nil {
                    Button { muted.toggle() } label: {
                        Ph(muted ? "speaker.slash.fill" : "speaker.wave.2.fill", 11).foregroundStyle(.white)
                            .frame(width: 26, height: 26).background(Circle().fill(.black.opacity(0.5)))
                    }
                    .buttonStyle(.plain).padding(6)
                    .accessibilityLabel(muted ? "Unmute" : "Mute")
                }
            }
            if let take {
                HStack(spacing: 6) {
                    MButton(take.isFinal ? "Kept" : "Keep", icon: "checkmark", size: .small, off: take.isFinal) { store.approve(take) }
                    if let j = job { MButton("Retake", icon: "arrow.clockwise", size: .small) { store.retakeShot(j) } }
                    MButton("Edit", icon: "scissors", size: .small) { store.openEdit(takeId: take.id) }
                    MButton("Share", icon: "square.and.arrow.up", size: .small) { store.openPostSheet(take) }
                }
                .padding(.top, 8)
                // Finish the take: a longer version (Extend) or a sharper one (Upscale).
                let canExtend = ExtendSource.take(take) != nil
                if canExtend || take.canUpscale {
                    HStack(spacing: 6) {
                        if canExtend { MButton("Extend", icon: "arrow.right.to.line", size: .small) { store.openExtend(take) } }
                        if take.canUpscale { UpscaleButton(take: take, size: .small) }
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    private func failed(_ message: String) -> some View {
        let tier = job?.request.quality ?? "draft"
        let lower = SuiteText.tierIds.firstIndex(of: tier).flatMap { $0 > 0 ? SuiteText.tierIds[$0 - 1] : nil }
        return ZStack {
            MuseImage(ref: art ?? character?.cover).blur(radius: 6, opaque: true).overlay(Color.black.opacity(0.55))
            VStack(spacing: 10) {
                Text("That take didn't work").font(t.isA ? Fonts.font("Instrument Serif", 26, .regular) : t.display(20)).foregroundStyle(.white)
                Text(message).font(t.body(12)).foregroundStyle(.white.opacity(0.9)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                if let j = job {
                    Button { store.retakeShot(j) } label: {
                        Text("RETRY FREE").font(t.mono(11, .semibold)).tracking(1).foregroundStyle(.white).padding(.horizontal, 12).frame(height: 26).background(t.rec)
                    }
                    .buttonStyle(.plain)
                    if let lower {
                        Button { store.tryCheaper(j) } label: {
                            Text("TRY \(SuiteText.tierLabel(lower).uppercased())").font(t.mono(11, .semibold)).tracking(1).foregroundStyle(.white)
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

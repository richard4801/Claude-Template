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
            .foregroundStyle(filled ? Color.white : c)
            .padding(.horizontal, 6).frame(height: 18)
            .background(Rectangle().fill(filled ? c : .clear))
            .overlay(Rectangle().strokeBorder(c, lineWidth: 1))
            .fixedSize()
    }
}

/// "Test renders · free" (catalog.test).
struct SuiteTestBadge: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        if store.suite.catalog?.test == true { Pill(SuiteText.testBadge, .warn).help("The server makes free test-pattern renders (SUITE_MODE=mock)") }
    }
}

/// A section label row: "CAST" on the left, a hint on the right.
struct SuiteSectionHead<Trailing: View>: View {
    @Environment(\.theme) private var t
    var title: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased()).font(t.mono(11, .medium)).tracking(1.2).foregroundStyle(t.ink)
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

/// The quality ladder as cards with each tier's price (from the estimates).
struct SuiteTierCards: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var selection: String
    var estimates: [String: ShotEstimate]
    var columns = 2
    var onPick: (String) -> Void

    var body: some View {
        let tiers = store.suite.catalog?.tiers ?? SuiteText.tierIds.map { SuiteTier(id: $0, label: SuiteText.tierLabel($0), detail: "") }
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
            ForEach(tiers) { tier in card(tier) }
        }
    }

    private func card(_ tier: SuiteTier) -> some View {
        let on = tier.id == selection
        let e = estimates[tier.id]
        return Button { if tier.available { onPick(tier.id) } } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(tier.label).font(t.body(13.5, .semibold))
                    Spacer(minLength: 4)
                    Text(e.map { Pricing.money($0.estimate) } ?? "—").font(t.isA ? Fonts.font("Instrument Serif", 22, .regular) : t.mono(15, .medium))
                }
                Text(tier.available ? tier.detail : "Not available right now").font(t.body(11.5)).foregroundStyle(t.muted).lineLimit(2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(t.surface)
            .overlay(Rectangle().strokeBorder(on ? t.ink : t.line, lineWidth: on ? 2 : 1))
            .opacity(tier.available ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tier.label)\(e.map { ", \(Pricing.money($0.estimate))" } ?? "")\(on ? ", selected" : "")")
    }
}

/// The big Generate bar: what it makes, the price, and the button with the estimate's own label.
struct SuiteGenerateBar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var estimate: ShotEstimate?
    var error: String?
    var summary: String
    var busy: Bool
    var action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(summary).font(t.body(13))
                Spacer()
                Text(estimate.map { Pricing.money($0.estimate) } ?? "—").font(t.isA ? Fonts.font("Instrument Serif", 30, .regular) : t.mono(20, .medium))
            }
            if let e = estimate {
                HStack {
                    Text("Balance after").font(t.body(12)).foregroundStyle(t.muted)
                    Spacer()
                    Text(Pricing.money(max(0, store.creditUsd - e.estimate))).font(t.mono(12))
                }
                ForEach(e.warnings.filter(SuiteText.isMemberSafe), id: \.self) { w in
                    Label(w, systemImage: "info.circle").font(t.body(11.5)).foregroundStyle(t.muted)
                }
                if let p = e.problem { Label(p, systemImage: "exclamationmark.triangle").font(t.body(12, .semibold)).foregroundStyle(t.warn) }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(t.body(12)).foregroundStyle(t.warn).fixedSize(horizontal: false, vertical: true) }
            Button(action: action) {
                Text((estimate?.buttonLabel ?? "Generate").uppercased())
                    .font(t.mono(13, .semibold)).tracking(2)
                    .foregroundStyle(t.ctaInk)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(t.cta.opacity(canGo ? 1 : 0.45))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGo)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private var canGo: Bool { !busy && estimate != nil && (estimate?.ok ?? false) }
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
                                Image(systemName: i < step ? "checkmark" : i == step ? "chevron.right" : "clock").font(.system(size: 11, weight: .semibold))
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
            .overlay(alignment: .topLeading) { SuiteTag(text: "Ready", color: t.good, filled: true).padding(8) }
            .overlay(alignment: .topTrailing) {
                if take?.videoUrl != nil {
                    Button { muted.toggle() } label: {
                        Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
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
            Image(systemName: "video.slash").font(.system(size: 28)).foregroundStyle(t.muted)
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

/// Talking, UGC ad, Extend & upscale: no backend yet.
struct SuiteComingSoonView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var mode: SuiteMode

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("VIDEO SUITE · \(mode.title.uppercased())").font(t.mono(11)).tracking(1.4).foregroundStyle(t.muted)
            Text(mode.title).font(t.isA ? Fonts.font("Instrument Serif", 48, .regular) : t.display(34))
            HardwareImage(name: mode.tileRender).frame(width: 360, height: 200).clipped().opacity(0.85)
            Pill(SuiteText.comingSoon)
            Text(mode.tileLine).font(t.body(14)).foregroundStyle(t.muted)
            MButton("Back to the Video suite", icon: "chevron.left", size: .small) { store.openSuite(.hub) }
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Settings → Connections (owner): opens workstream 2's ConnectionsView.
struct SuiteConnectionsRow: View {
    @Environment(\.theme) private var t
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "link").font(.system(size: 15)).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.navUppercase ? "CONNECTIONS" : "Connections").font(t.navFont).lineLimit(1)
                    Text("Claude & MCP · Blender relay").font(t.body(11)).foregroundStyle(t.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(t.isD ? .white : t.muted)
            .padding(.horizontal, 10)
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Connections, Claude and MCP, Blender relay")
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

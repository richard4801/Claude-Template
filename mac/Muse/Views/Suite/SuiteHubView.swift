import MuseCore
import SwiftUI

// AI suite (workstream 1): the Video suite screen (Screen.suite). It loads the catalog, shows the suite-off state when the
// server has it switched off, and otherwise the hub (D1), the composer (Shot, Character swap, Talking, UGC ad, Extend),
// the storyboard or the camera stage. Pickers open over it, always dark.

struct SuiteRootView: View {
    var body: some View {
        // The redesign's tokens (Camera Body's lifted dark) on every Suite page, on the page's own canvas.
        SuiteRootContent().suiteTokens()
    }
}

private struct SuiteRootContent: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        ZStack {
            t.roles.canvas
            content
            // The storyboard's look lock opens the same picker shell (the composer has its own host).
            if store.suite.mode == .storyboard { ComposerPickerHost() }
        }
        .task(id: store.serverKey) { await store.loadSuite() }
    }

    @ViewBuilder private var content: some View {
        let s = store.suite
        if s.catalog == nil {
            if let err = s.catalogError {
                VStack(alignment: .leading, spacing: 12) {
                    Text("The Video suite couldn't load").font(t.display(24))
                    Muted(err, size: 13)
                    MButton("Try again", icon: "arrow.clockwise", size: .small) { Task { await store.loadSuite(force: true) } }
                }
                .padding(36)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Muted("Loading the Video suite…", size: 13)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if !s.enabled {
            SuiteOffView()
        } else {
            switch s.mode {
            case .hub: SuiteHubView()
            case .shot, .swap, .talking, .ugc, .extend, .photo:
                ComposerView()
            case .storyboard: StoryboardView()
            case .cameraStage: CameraStageView()
            }
        }
    }
}

/// Suite home (approved frame "Suite home"): the quick prompt bar, recent takes, and what is running. Its one button opens
/// the composer with the prompt carried over (owner decision 1): nothing here starts a paid generation.
struct SuiteHubView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        GeometryReader { g in
            let side = g.size.width >= 900
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s5) {
                    SuitePageHeader()
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: Space.s6) {
                            SuiteQuickBar()
                            recent
                            if !side { SuiteRunningPanel() }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        if side { SuiteRunningPanel().frame(width: 294) }
                    }
                }
                .padding(.horizontal, Space.s5)
                .padding(.top, 20)
                .padding(.bottom, Space.s6)
            }
        }
        .onAppear {
            // Home describes a shot: the bar's chips and model are the Shot composer's.
            if store.suite.composer.tool != .shot && store.suite.composer.tool != .photo { store.suite.composer.tool = .shot }
        }
    }

    // MARK: Recent takes

    /// The newest finished Suite jobs with a take to show (one tile per job).
    private var recentJobs: [(Job, Take)] {
        let done = store.jobs.filter { $0.isDone && ($0.request.engine == "suite" || $0.isPhoto || $0.suiteTool != nil) }
            .sorted { $0.createdAt > $1.createdAt }
        var out: [(Job, Take)] = []
        for j in done {
            guard let take = store.takes(of: j).first else { continue }
            out.append((j, take))
            if out.count == 10 { break }
        }
        return out
    }

    private var recent: some View {
        let list = recentJobs
        return VStack(alignment: .leading, spacing: Space.s4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent takes").font(t.body(19, .semibold)).foregroundStyle(t.roles.ink)
                Spacer(minLength: Space.s2)
                Button { store.go(.gallery) } label: {
                    HStack(spacing: 6) {
                        Ph("squares-four", 14)
                        Text("Open Library").font(t.scale.label.font)
                    }
                    .foregroundStyle(t.roles.ink2)
                    .frame(minHeight: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Everything you made, in the Library")
            }
            if list.isEmpty {
                Text("Your takes show up here as they finish. Describe a shot above to start.")
                    .font(t.scale.body.font).foregroundStyle(t.roles.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                GeometryReader { g in
                    let n = max(2, min(list.count, Int((g.size.width + Space.s3) / (110 + Space.s3))))
                    let w = (g.size.width - CGFloat(n - 1) * Space.s3) / CGFloat(n)
                    HStack(alignment: .top, spacing: Space.s3) {
                        ForEach(list.prefix(n), id: \.0.id) { item in tile(item.0, item.1, width: w) }
                    }
                }
                .frame(height: 290)
            }
        }
    }

    private func tile(_ j: Job, _ take: Take, width: CGFloat) -> some View {
        let h = min(200, width * 16 / 9)
        return Button { store.openTake(take.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                MuseImage(ref: take.thumb)
                    .frame(width: width, height: h)
                    .clipShape(RoundedRectangle(cornerRadius: t.radii.container))
                    .overlay(alignment: .topLeading) {
                        if take.isFinal {
                            Text("Kept").font(t.scale.micro.font).foregroundStyle(t.roles.ink)
                                .padding(.horizontal, 7).frame(height: 20)
                                .background(RoundedRectangle(cornerRadius: t.radii.chip).fill(t.roles.raised))
                                .padding(6)
                        }
                    }
                Text(j.title).font(t.scale.label.font).foregroundStyle(t.roles.ink).lineLimit(1).padding(.top, Space.s1)
                Text(Self.kindLine(j, take, count: store.takes(of: j).count)).font(t.scale.caption.font).monospacedDigit()
                    .foregroundStyle(t.roles.ink2).lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(j.title)")
        .accessibilityLabel("\(j.title), \(Self.kindLine(j, take, count: store.takes(of: j).count))\(take.isFinal ? ", kept" : "")")
    }

    /// "Shot, 8 s", "Swap, 9 s", "Photo, 2 photos".
    static func kindLine(_ j: Job, _ take: Take, count: Int) -> String {
        let tool = j.suiteTool ?? "shot"
        if j.isPhoto || tool == "photo" { return "Photo, \(count) photo\(count == 1 ? "" : "s")" }
        let name: String
        switch tool {
        case "swap", "remix": name = "Swap"
        case "recast": name = "Recast"
        case "extend": name = "Extend"
        default: name = "Shot"
        }
        guard let s = take.durationSec, s > 0 else { return name }
        return "\(name), \(Int(s.rounded())) s"
    }
}

/// Home's quick prompt bar: the same prompt as the composer (so @ and # work and the words carry over), its tool, length and
/// shape, the model, and "Open in composer". No price here because nothing here spends.
struct SuiteQuickBar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    private var tool: ComposerTool { store.suite.composer.tool == .photo ? .photo : .shot }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            ComposerPromptBox(placeholder: tool == .photo ? "Describe a photo. Use @ for a model." : "Describe a shot. Use @ for a model, # for a camera move.",
                              minHeight: 44, maxHeight: 160, suggestions: .below)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            HStack(spacing: Space.s2) {
                toolChip
                if tool == .shot {
                    lengthChip
                    shapeChip
                }
                Spacer(minLength: Space.s3)
                SuiteModelPill()
                Button { store.openTool(tool) } label: {
                    Text("Open in composer").font(t.body(14, .semibold)).foregroundStyle(t.roles.onAction).lineLimit(1).fixedSize()
                        .padding(.horizontal, Space.s4).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: t.radii.control).fill(t.roles.action))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Open the \(tool.title) composer with this prompt. Nothing is generated until you press Generate there.")
                .accessibilityIdentifier("suite.home.open")
            }
        }
        .padding(Space.s4)
        .suitePanel(t)
    }

    private var toolChip: some View {
        SuiteChoiceChip(icon: tool == .photo ? "camera" : "video-camera", value: tool.title, title: "Make",
                        options: [("Shot", ComposerTool.shot), ("Photo", ComposerTool.photo)], selected: tool) { v in
            store.suite.composer.tool = v
            if v == .photo { store.preparePhoto() }
        }
    }

    private var lengthChip: some View {
        SuiteChoiceChip(icon: "clock", value: "\(store.suite.composer.duration) s", title: "Length",
                        options: Array(store.composerLengthRange).map { ("\($0) s", $0) }, selected: store.suite.composer.duration) { store.setComposerLength($0) }
    }

    private var shapeChip: some View {
        SuiteChoiceChip(icon: "device-mobile", value: store.suite.composer.aspect, title: "Shape",
                        options: store.composerShapes.map { ($0, $0) }, selected: store.suite.composer.aspect) { store.suite.composer.aspect = $0 }
    }
}

/// A pill (icon and value on the field tone) that opens its short list with a check on the current value.
struct SuiteChoiceChip<T: Hashable>: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var icon: String
    var value: String
    var title: String
    var options: [(String, T)]
    var selected: T
    var onPick: (T) -> Void
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { SuitePillLabel(icon: icon, value: value, open: open) }
            .buttonStyle(.plain)
            .fixedSize()
            .help(title)
            .accessibilityLabel("\(title): \(value)")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                ScrollView {
                    PillList(title: title, options: options, selected: selected) { v in
                        onPick(v)
                        open = false
                    }
                }
                .frame(maxHeight: 360)
                .environment(\.theme, t)
            }
    }
}

/// What is rendering or waiting, with its model and progress; Queue opens the whole list.
struct SuiteRunningPanel: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let list = Array(store.activeJobs.prefix(5))
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack {
                Text("Running").font(t.body(19, .semibold)).foregroundStyle(t.roles.ink)
                Spacer(minLength: Space.s2)
                Button { store.go(.queue) } label: {
                    HStack(spacing: 6) {
                        Ph("list-bullets", 14)
                        Text("Queue").font(t.scale.label.font)
                    }
                    .foregroundStyle(t.roles.ink2).frame(minHeight: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the queue")
            }
            Rectangle().fill(t.roles.hairline).frame(height: 1)
            if list.isEmpty {
                Text("Nothing is rendering. Takes you start show here with their progress.")
                    .font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Space.s1)
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { i, j in
                row(j, position: i)
                if i < list.count - 1 { Rectangle().fill(t.roles.hairline).frame(height: 1) }
            }
        }
        .padding(Space.s4)
        .suitePanel(t)
    }

    private func row(_ j: Job, position: Int) -> some View {
        Button { store.go(.queue) } label: {
            HStack(alignment: .top, spacing: Space.s3) {
                MuseImage(ref: j.thumb)
                    .frame(width: 30, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: t.radii.chip))
                VStack(alignment: .leading, spacing: 3) {
                    Text(j.title).font(t.scale.label.font).foregroundStyle(t.roles.ink).lineLimit(1)
                    Text(j.engineLabel).font(t.scale.caption.font).foregroundStyle(t.roles.ink2).lineLimit(1)
                    RProgress(value: j.isWaiting ? 0 : j.progress / 100, height: 3).padding(.vertical, 3)
                    Text(timeLine(j, position: position)).font(t.scale.caption.font).monospacedDigit().foregroundStyle(t.roles.ink2).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .help(j.progressLine)
    }

    /// "About 1 min left", "Waiting for a slot", "Starts next".
    private func timeLine(_ j: Job, position: Int) -> String {
        if j.isWaiting || !j.isRunning {
            if let p = j.queuePosition, p <= 1 { return "Starts next" }
            return "Waiting for a slot"
        }
        if let eta = j.etaSeconds, eta > 0 { return "About \(Job.aboutTime(eta)) left" }
        return j.statusLine
    }
}

/// The video model, as the server names it ("Model · Provider"; "Auto" lets the quality pick), with a dot when it is
/// ready. Opens the same list as the composer's Model pill.
struct SuiteModelPill: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var open = false

    var body: some View {
        let label = store.composerModelLabel
        Button { open.toggle() } label: {
            HStack(spacing: Space.s2) {
                Circle().fill(t.roles.positive).frame(width: 6, height: 6)
                Text(label).font(t.body(13, .medium)).foregroundStyle(t.roles.ink).lineLimit(1).fixedSize()
                    .fitProbe("composer model")
                Ph("caret-down", 11).foregroundStyle(t.roles.ink2)
            }
            .padding(.horizontal, 10).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: t.radii.control).fill(open ? t.roles.field : .clear))
            .overlay(RoundedRectangle(cornerRadius: t.radii.control).strokeBorder(t.roles.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .background { if SnapshotRunner.probing { ComposerBarFrame(key: "pill model") } }
        .help("Model: \(label)")
        .accessibilityLabel("Model: \(label)")
        .popover(isPresented: $open, arrowEdge: .top) {
            ModelPickerList(onPick: { open = false }).environment(store).environment(\.theme, t)
        }
    }
}

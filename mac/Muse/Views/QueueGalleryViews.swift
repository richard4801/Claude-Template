import AVKit
import MuseCore
import SwiftUI

struct QueueView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let r = store.runningJob
        let active = store.activeJobs
        Page {
            PageHeader(eyebrow: "Jobs", title: "Queue") {
                if active.contains(where: \.isQueued) && r == nil {
                    MButton("Run queue · \(Pricing.money(store.queuedCost))", icon: "play.fill", kind: .primary) { store.runQueue() }
                }
            }
            HStack(spacing: 14) {
                HStack(spacing: 12) {
                    let rendering = active.contains { $0.isRunning && !$0.isWaiting }
                    let paused = active.contains(where: \.isPaused)
                    LED(on: rendering).id(rendering)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(paused ? "Paused · GPU credit low" : rendering ? "H100 80GB · rendering" : r != nil ? "Waiting for a GPU" : "GPU is off").font(t.body(14, .bold))
                        Muted(paused ? "The studio's RunPod balance is low. Jobs resume by themselves after a top-up."
                              : r != nil ? "Your own GPU shuts down 3 min after your last job" : "Starts on demand · setup takes 1–2 min from the network volume")
                    }
                    Spacer(minLength: 0)
                }
                .card()
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 4) {
                    Lbl("Spent today")
                    (Text(Pricing.money(store.todaySpent)).font(t.mono(20)) + Text(" of \(Pricing.money(store.balance.perDayLimit)) cap").font(t.body(12)).foregroundColor(t.muted))
                    ProgressLine(value: store.todaySpent / max(1, store.balance.perDayLimit))
                }
                .card()
                .frame(maxWidth: 300)
                VStack(alignment: .leading, spacing: 4) {
                    Lbl("Balance")
                    Text(Pricing.money(store.creditUsd)).font(t.mono(20))
                    LinkText("Credit") { store.go(.credits) }
                }
                .card()
                .frame(maxWidth: 300)
            }
            .padding(.bottom, 22)

            ForEach(store.visibleFailures) { f in
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.shield").font(.system(size: 16))
                    (Text("Render failed · \(f.title)").bold() + Text(" · \(f.error ?? "The render stopped.") \(Pricing.money(f.refunded)) refunded."))
                        .font(t.body(13))
                    Spacer()
                    MButton("Retry · \(Pricing.money(Pricing.totalCost(f.request.spec)))", size: .small) { store.retry(f) }
                    LinkText("Dismiss") { store.dismissFailure(f) }
                }
                .foregroundStyle(t.warnInk)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: t.controlRadius).fill(t.warnBg))
                .padding(.bottom, 18)
            }

            SectionHeader(title: "Active", top: 0) { Muted("\(active.count) job\(active.count == 1 ? "" : "s")") }
            if active.isEmpty {
                Note(icon: "list.bullet.below.rectangle", text: Text("Nothing in the queue. The GPU is off, so you're not paying for anything. "))
                MButton("Start a new video", size: .small) { store.go(.studio) }.padding(.top, 8)
            } else {
                JobTable(jobs: active, header: true)
            }
            SectionHeader(title: "Finished") { Muted("Last 7 days") }
            JobTable(jobs: store.finishedJobs, header: false)
        }
    }
}

struct JobTable: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var jobs: [Job]
    var header: Bool

    var body: some View {
        VStack(spacing: 0) {
            if header {
                HStack(spacing: 12) {
                    Color.clear.frame(width: 44, height: 1)
                    Lbl("Clip").frame(maxWidth: .infinity, alignment: .leading)
                    Lbl("Status").frame(width: 280, alignment: .leading)
                    Lbl("Cost").frame(width: 80, alignment: .leading)
                    Color.clear.frame(width: 140, height: 1)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                Rectangle().fill(t.strongLine).frame(height: t.lineWidth)
            }
            ForEach(jobs) { j in JobRow(job: j) }
        }
    }
}

struct JobRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var job: Job
    @State private var hover = false

    var body: some View {
        let j = job
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Media(ref: j.thumb, ratio: 44.0 / 58.0, radius: t.isA ? 0 : 6).frame(width: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(j.title).font(t.body(14, .bold))
                    Muted("\(j.modelName.split(separator: " ").first.map(String.init) ?? j.modelName) · \(j.engineName)\(j.engine == .h3 ? " · \(j.request.steps) steps" : "") · \(Pricing.trimNum(j.lengthSec))s\(j.request.takes > 1 ? " · \(j.request.takes) takes" : "")")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if j.isDone {
                        Pill("✓ Done", .good)
                    } else if j.isPaused {
                        VStack(alignment: .leading, spacing: 4) {
                            Pill("Paused", .warn)
                            Text(Job.pausedLine).font(t.mono(11.5)).foregroundStyle(t.warnInk).lineLimit(2)
                        }
                    } else if j.isWaiting, let line = j.waitLine {
                        VStack(alignment: .leading, spacing: 4) {
                            Pill(j.queuePosition.map { "#\($0) in line" } ?? "Waiting")
                            Text(line).font(t.mono(11.5)).foregroundStyle(t.muted)
                        }
                    } else if j.isRunning {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressLine(value: j.progress / 100)
                            Text(j.phase).font(t.mono(11.5)).foregroundStyle(t.muted)
                        }
                    } else if j.isFailed {
                        Pill("Failed · refunded", .warn)
                    } else {
                        Pill("Queued")
                    }
                }
                .frame(width: 280, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Pricing.money(j.cost)).font(t.mono(13))
                    if let w = j.warmupCost, w > 0 {
                        Text("+ \(Pricing.money(w)) warm-up").font(t.mono(10.5)).foregroundStyle(t.muted).help("GPU start-up and model load, charged as its own line")
                    }
                }
                .frame(width: 80, alignment: .leading)
                HStack(spacing: 4) {
                    if j.isDone { MButton("Review", size: .small) { store.watch(j) } }
                    MoreMenu {
                        Button("Watch") { store.watch(j) }
                        Button("Run again with same settings") { store.runAgain(j) }
                        Button("Copy prompt") { store.copy(j.prompt.isEmpty ? "(no prompt saved for this job)" : j.prompt) }
                        Divider()
                        Button("Remove from list", role: .destructive) { store.removeJob(j) }
                    }
                }
                .frame(width: 140, alignment: .trailing)
            }
            .padding(12)
            .background(hover ? t.surface : .clear)
            .onHover { hover = $0 }
            Rectangle().fill(t.isD ? Color(hex: 0x111111) : t.line).frame(height: t.lineWidth)
        }
    }
}

struct GalleryView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        @Bindable var store = store
        ZStack(alignment: .bottom) {
            if store.comparing {
                CompareView().transition(MotionStyle.of(t.id).transition)
            } else {
                Page {
                    PageHeader(eyebrow: "Results", title: "Gallery") {
                        Seg([(GalleryTab.tests, "Tests · \(store.takes.count)"), (GalleryTab.final, "Final · \(store.takes.filter(\.isFinal).count)")], selection: $store.galleryTab)
                            .frame(width: 300)
                    }
                    Muted("Test renders stay separate from your Final gallery. Select takes to compare them side by side.").padding(.top, -8).padding(.bottom, 16)
                    let list = store.galleryList
                    if list.isEmpty {
                        Note("Nothing approved yet. Approve a take to move it here.")
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 6), spacing: 14) {
                            ForEach(list) { take in GalleryTile(take: take) }
                        }
                    }
                    Color.clear.frame(height: 60)
                }
                if !store.picked.isEmpty {
                    HStack(spacing: 14) {
                        Text("\(store.picked.count) selected").font(t.body(14, .semibold))
                        MButton("Compare", kind: .primary, size: .small, off: store.picked.count < 2) { store.openCompare() }
                        MButton("Clear", size: .small) { store.picked = [] }
                    }
                    .foregroundStyle(t.bg)
                    .padding(.leading, 18)
                    .padding(.trailing, 10)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(t.ink).shadow(color: .black.opacity(0.3), radius: 15, y: 12))
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.picked.isEmpty)
    }
}

struct GalleryTile: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var take: Take

    var body: some View {
        let picked = store.picked.contains(take.id)
        let fresh = store.fresh.contains(take.id)
        Button { store.openTake(take.id) } label: {
            Media(ref: take.thumb, caption: (fresh ? "New · " : "") + take.caption, selectedColor: picked ? t.accent : fresh ? t.good : nil) {
                if take.isVideo { Image(systemName: "play.fill").font(.system(size: 12)).foregroundStyle(.white).shadow(radius: 2) }
            }
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Button { store.togglePick(take.id) } label: {
                ZStack {
                    Circle().fill(picked ? t.accent : .black.opacity(0.25))
                    Circle().strokeBorder(picked ? t.accent : .white, lineWidth: 2)
                    if picked { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) }
                }
                .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .padding(8)
            .help("Select to compare")
        }
        .contextMenu {
            Button(picked ? "Deselect" : "Select to compare") { store.togglePick(take.id) }
            Button(take.isFinal ? "Move back to Tests" : "Approve") { take.isFinal ? store.unapprove(take) : store.approve(take) }
            Button("Post…") { store.openPostSheet(take) }
            if !take.isVideo && store.canSaveAsTemplate(take) {
                Button("Save as template…") { store.saveAsTemplate(take) }
            }
            Divider()
            Button("Delete take", role: .destructive) { store.discard(take) }
        }
    }
}

struct CompareView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let items = store.picked.compactMap { id in store.takes.first { $0.id == id } }
        Page {
            PageHeader(eyebrow: "Compare takes", title: "\(items.count) takes side by side") {
                MButton("Done") { withAnimation { store.comparing = false } }
            }
            HStack(alignment: .top, spacing: 22) {
                ForEach(items) { take in
                    VStack(alignment: .leading, spacing: 10) {
                        Media(ref: take.thumb)
                        Text(take.caption).font(t.body(14, .bold))
                        Text(meta(take)).font(t.mono(12)).foregroundStyle(t.muted)
                        HStack {
                            MButton(take.isFinal ? "Approved ✓" : "Approve", kind: take.isFinal ? .secondary : .primary, size: .small, fill: true) { store.approve(take) }
                            MButton("Open", size: .small) { store.openTake(take.id) }
                        }
                    }
                    .frame(maxWidth: 300)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func meta(_ take: Take) -> String {
        let engine = take.engineLabel.isEmpty ? "Photo" : take.engineLabel
        return "\(engine) · \(Pricing.money(take.cost)) · seed \(take.seed)"
    }
}

struct ResultView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        if let take = store.openedTake {
            let job = store.job(for: take)
            let outfit = job.flatMap { j in store.outfits.first { $0.id == j.outfitId } }
            GeometryReader { g in
              ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                Breadcrumb(parent: "Gallery", title: take.caption) { store.go(.gallery) }
                    HStack(alignment: .top, spacing: 28) {
                        Spacer(minLength: 0)
                        Group {
                            if let v = take.videoUrl, let u = URL(string: v) {
                                TakePlayer(url: u, caption: take.mediaLine ?? "video")
                            } else {
                                Media(ref: take.thumb, caption: take.isVideo ? (take.mediaLine ?? "\(Take.clock(job?.lengthSec ?? 5.2)) · 768×1344") : nil, captionIcon: take.isVideo ? "play.fill" : nil)
                            }
                        }
                        .frame(height: min(720, max(360, g.size.height - 110)))
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Eyebrow(take.isVideo ? "Video take" : "Photo").styled()
                                    Text(t.headingsUppercase ? take.caption.uppercased() : take.caption).font(t.isA ? Fonts.font("Instrument Serif", 30, .regular) : t.display(26))
                                }
                                Spacer()
                                Pill(take.isFinal ? "Final" : "Test", take.isFinal ? .good : .neutral)
                                MoreMenu {
                                    Button("Post…") { store.openPostSheet(take) }
                                    Button("Download") { store.export(take) }
                                    Button("Share…") { store.share(take) }
                                    Button("Copy prompt") { store.copy(take.prompt.isEmpty ? (job?.prompt ?? "") : take.prompt) }
                                    if !take.isVideo {
                                        Button("Save as template…") { store.saveAsTemplate(take) }.disabled(!store.canSaveAsTemplate(take))
                                    }
                                    Button("Compare takes") { store.compareFromResult() }
                                    Button("Report a problem") { store.showToast("Thanks, we'll look at this take") }
                                    Divider()
                                    Button("Delete take", role: .destructive) { store.discard(take) }
                                }
                            }
                            ListBox {
                                let base: [(String, String)] = [
                                    ("Model", job?.modelName ?? store.currentModel?.name ?? "—"),
                                    ("Outfit", outfit?.name ?? store.currentOutfit?.name ?? "—"),
                                    ("Engine", job?.engineName ?? (take.isVideo ? "Standard" : "Photo")),
                                    ("Steps", job.map { $0.engine == .viggle ? "4" : "\($0.request.steps)" } ?? (take.isVideo ? "10" : "—")),
                                    ("Cost", Pricing.money(take.cost) + (job?.warmupCost.map { " + \(Pricing.money($0)) warm-up" } ?? "")),
                                    ("Seed", "\(take.seed)\(take.isVideo || (!take.isTemplateShot && store.shoot.lockSeed) ? " · locked" : "")"),
                                ]
                                let templateRow: [(String, String)] = take.templateName.map { name in [("Template", name)] } ?? []
                                let rows: [(String, String)] = base + templateRow
                                let media: [(String, String)] = take.isVideo ? [
                                    ("Length", take.durationSec.map { "\(Pricing.trimNum($0))s" } ?? "—"),
                                    ("Size", take.width.flatMap { w in take.height.map { "\(w)×\($0)" } } ?? "—"),
                                ] : []
                                let allRows = rows + media
                                ForEach(Array(allRows.enumerated()), id: \.offset) { i, row in
                                    ListRow(title: row.0, last: i == allRows.count - 1) { MonoValue(row.1) }
                                }
                            }
                            HStack {
                                MButton("Discard", fill: true) { store.discard(take) }
                                MButton(take.isFinal ? "Approved ✓" : "Approve", kind: .primary, fill: true) { store.approve(take) }
                            }
                            HStack {
                                MButton("Retake with changes", icon: "arrow.triangle.2.circlepath", fill: true) { store.retake(take) }
                                MButton("Export 1080×1920", icon: "square.and.arrow.up", fill: true) { store.export(take) }
                            }
                            let who = store.model(for: take)?.shortName ?? "her"
                            MButton("Post to \(who)'s accounts", icon: "paperplane", kind: .primary, fill: true) { store.openPostSheet(take) }
                            if !take.isVideo {
                                if store.canSaveAsTemplate(take) {
                                    MButton("Save as template", icon: "square.on.square.dashed", fill: true) { store.saveAsTemplate(take) }
                                } else {
                                    Muted("Made with \(take.templateName ?? "someone else's template"). Its look stays with its creator, so it can't be saved as a new template.")
                                }
                            }
                            if let posted = store.posts(for: take).first(where: \.isOut) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Lbl(posted.state == "posted" ? "Posted" : "Handed off")
                                    HStack(spacing: 6) { ForEach(posted.platforms) { PlatformBadge(platform: $0, size: 20) } }
                                    if let s = posted.stats { Text(s.line).font(t.mono(12)) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .card(14)
                            }
                        }
                        .frame(width: 380)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.top, 28)
                .padding(.bottom, 48)
              }
            }
        } else {
            Page { Note("Nothing to show yet. Finished takes appear in the Gallery.") }
        }
    }
}

/// A finished take's video (Take.videoUrl), played with AVKit.
struct TakePlayer: View {
    @Environment(\.theme) private var t
    var url: URL
    var caption: String
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let player {
                VideoPlayer(player: player)
            } else {
                Rectangle().fill(Color.black)
            }
            Text(caption).font(t.mono(11.5)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(.black.opacity(0.55)))
                .padding(10)
                .allowsHitTesting(false)
        }
        .aspectRatio(768.0 / 1344.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: t.isA ? 0 : t.cardRadius * 0.6))
        .onAppear { load() }
        .onChange(of: url) { load() }
        .onDisappear { player?.pause() }
    }

    private func load() {
        player?.pause()
        let p = AVPlayer(url: url)
        p.actionAtItemEnd = .pause
        player = p
    }
}

import AVKit
import MuseCore
import SwiftUI

struct QueueView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let r = store.runningJob
        let active = store.activeJobs
        let rendering = active.contains { $0.isRunning && !$0.isWaiting }
        ScreenPage {
            ScreenTitle("Queue", subtitle: rendering ? "Rendering" : r != nil ? MemberText.waitingToStart : "Nothing rendering") {
                if active.contains(where: \.isQueued) && r == nil {
                    RButton("Run queue · \(Pricing.money(store.queuedCost))", kind: .action) { store.runQueue() }
                }
            }
            // Plain facts on the canvas, grouped by space.
            HStack(alignment: .top, spacing: Space.s7) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spent today").scaled(t.scale.caption, t.roles.ink2)
                    Text("\(Pricing.money(store.todaySpent)) of \(Pricing.money(store.balance.perDayLimit))").monospacedDigit().scaled(t.scale.title, t.roles.ink)
                    RProgress(value: store.todaySpent / max(1, store.balance.perDayLimit)).frame(width: 180).padding(.top, Space.s1)
                }
                Button { store.go(.credits) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Balance").scaled(t.scale.caption, t.roles.ink2)
                        Text(Pricing.money(store.creditUsd)).monospacedDigit().scaled(t.scale.title, t.roles.ink)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open credit")
                Spacer(minLength: 0)
            }
            .padding(.bottom, Space.s5)

            if store.visibleFailures.count > 1 {
                HStack {
                    Text(ScreenCopy.count(store.visibleFailures.count, "failed job")).scaled(t.scale.caption, t.roles.ink2)
                    Spacer(minLength: 0)
                    RButton("Clear all failed", kind: .plain, small: true) { store.clearFailures() }
                }
                .padding(.bottom, Space.s2)
            }
            ForEach(store.visibleFailures) { f in
                HStack(alignment: .center, spacing: Space.s3) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(TakeText.displayTitle(f.title)) didn't finish").scaled(t.scale.label, t.roles.danger)
                        Text(ScreenCopy.failure(f.failureLine, charged: false)).scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Space.s3)
                    if f.canRecover {
                        // Already made and charged at the provider: Recover is free (owner only); Retry would pay again.
                        if store.isOwner { RButton(ScreenCopy.recoverLabel, small: true) { store.recover(f) } }
                        else { Text(ScreenCopy.recoverByOwner).scaled(t.scale.caption, t.roles.ink2) }
                    } else {
                        RButton(f.isPhoto ? "Make again" : ScreenCopy.retryLabel(cost: f.cost, estimate: Pricing.totalCost(f.request.spec)), small: true) { store.retry(f) }
                    }
                    RButton("Dismiss", kind: .plain, small: true) { store.dismissFailure(f) }
                }
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s3)
                .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.roles.field))
                .padding(.bottom, Space.s3)
            }

            SectionTitle("Active", top: Space.s3) { Text(ScreenCopy.count(active.count, "job")).scaled(t.scale.caption, t.roles.ink2) }
            if store.loading && store.jobs.isEmpty {
                SkeletonRows(count: 3)
            } else if active.isEmpty {
                EmptyState("Nothing in the queue", "Renders wait here until they start, so nothing is being charged right now.", actionTitle: "New shot") { store.openTool(.shot) }
            } else {
                JobTable(jobs: active, header: true)
            }
            let finished = store.finishedJobs
            SectionTitle("Finished") { Text(ScreenCopy.count(finished.count, "job")).scaled(t.scale.caption, t.roles.ink2) }
            if finished.isEmpty {
                Text("Finished renders stay here and in the Library.").scaled(t.scale.body, t.roles.ink2)
            } else {
                JobTable(jobs: finished, header: false)
            }
        }
    }
}

struct JobTable: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var jobs: [Job]
    var header: Bool

    var body: some View {
        // Lazy (performance pass): the finished list grows with every render; rows are built as they scroll into view.
        LazyVStack(spacing: 0) {
            if header {
                HStack(spacing: Space.s3) {
                    Color.clear.frame(width: 44, height: 1)
                    Text("Clip").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Status").frame(width: 280, alignment: .leading)
                    Text("Cost").frame(width: 80, alignment: .leading)
                    Color.clear.frame(width: 140, height: 1)
                }
                .scaled(t.scale.caption, t.roles.ink2)
                .padding(.horizontal, Space.s3)
                .padding(.bottom, Space.s2)
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
        HStack(spacing: Space.s3) {
            MediaFrame(ref: j.thumb, ratio: 44.0 / 58.0).frame(width: 44)
                .background { if SnapshotRunner.probing { ComposerBarFrame(key: "queue row \(j.id)") } }
            VStack(alignment: .leading, spacing: 2) {
                Text(TakeText.displayTitle(j.title)).scaled(t.scale.label, t.roles.ink).lineLimit(1)
                Text(ScreenCopy.meta([j.modelName.split(separator: " ").first.map(String.init) ?? j.modelName, j.engineLabel,
                                      j.isPhoto ? PhotoEstimate.photos(max(1, j.request.takes)) // WS19: a Photo run
                                        : "\(Pricing.trimNum(j.lengthSec)) s" + (j.request.takes > 1 ? ", \(j.request.takes) takes" : "")]))
                    .scaled(t.scale.caption, t.roles.ink2).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if j.isDone {
                    StateTag("Done", .positive)
                } else if j.isWaiting {
                    VStack(alignment: .leading, spacing: Space.s1) {
                        Text(j.queuePosition.map { $0 <= 1 ? "Next" : "#\($0) in line" } ?? "Waiting").scaled(t.scale.label, t.roles.ink)
                        Text(j.progressLine).monospacedDigit().scaled(t.scale.micro, t.roles.ink2)
                    }
                } else if j.isRunning {
                    VStack(alignment: .leading, spacing: Space.s1) {
                        RProgress(value: j.progress / 100)
                        Text(j.progressLine).monospacedDigit().scaled(t.scale.micro, t.roles.ink2)
                    }
                } else if j.isFailed {
                    StateTag("Failed, not charged", .danger)
                } else {
                    Text("Queued").scaled(t.scale.label, t.roles.ink2)
                }
            }
            .frame(width: 280, alignment: .leading)
            Text(Pricing.money(j.cost)).monospacedDigit().scaled(t.scale.body, t.roles.ink)
                .frame(width: 80, alignment: .leading)
            HStack(spacing: Space.s1) {
                if j.isDone { RButton("Review", small: true) { store.watch(j) } }
                MoreMenu {
                    Button("Watch") { store.watch(j) }
                    Button("Run again with same settings") { store.runAgain(j) }
                    Button("Copy prompt") { if j.prompt.isEmpty { store.showToast("No prompt was saved for this job") } else { store.copy(j.prompt) } }
                    Divider()
                    Button("Remove from list", role: .destructive) { store.removeJob(j) }
                }
            }
            .frame(width: 140, alignment: .trailing)
        }
        .padding(.horizontal, Space.s3)
        .padding(.vertical, Space.s2)
        .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(hover ? t.roles.field.opacity(0.6) : .clear))
        .onHover { hover = $0 }
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
                ScreenPage {
                    ScreenTitle("Library", subtitle: "Tests stay separate from Final. Select takes to compare them side by side.") {
                        HStack(spacing: Space.s3) {
                            RButton("Import from link") { store.openLinkImport(.library) } // WS6: import a video from a link
                                .help("Import a video from a TikTok, Instagram or YouTube link")
                            LibraryCollectionBar()
                            RSeg([(GalleryTab.tests, "Tests \(store.takes.count)"), (GalleryTab.final, "Final \(store.takes.filter(\.isFinal).count)")], selection: $store.galleryTab)
                                .frame(width: 240)
                        }
                    }
                    let list = store.galleryList
                    if store.loading && store.takes.isEmpty {
                        SkeletonGrid(columns: 6, count: 12)
                    } else if list.isEmpty, store.library.galleryCollection != nil {
                        EmptyState("Nothing in this collection", "Use Save to collection on a take, or select takes here and save them.", actionTitle: "Show all takes") {
                            store.setGalleryCollection(nil)
                        }
                    } else if list.isEmpty {
                        if store.galleryTab == .final {
                            EmptyState("Nothing approved yet", "Approve a test take and it moves here, ready to post.", actionTitle: "Show tests") { store.galleryTab = .tests }
                        } else {
                            EmptyState("No takes yet", "Every video and photo you render lands here as a test take first.", actionTitle: "New photo") { store.openTool(.photo) }
                        }
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s4), count: 6), alignment: .leading, spacing: Space.s5) {
                            ForEach(list) { take in GalleryTile(take: take) }
                        }
                    }
                    Color.clear.frame(height: 60)
                }
                if !store.picked.isEmpty {
                    HStack(spacing: Space.s3) {
                        Text("\(store.picked.count) selected").scaled(t.scale.label, t.roles.ink)
                        RButton("Compare", kind: .action, small: true, off: store.picked.count < 2) { store.openCompare() }
                            .help(store.picked.count < 2 ? "Select at least 2 takes" : "Compare the selected takes")
                        SaveToCollectionButton(takeIds: store.picked) {
                            Text("Save to collection").scaled(t.scale.label, t.roles.ink).padding(.horizontal, Space.s2).frame(minHeight: 28)
                        }
                        RButton("Clear", kind: .plain, small: true) { store.picked = [] }
                            .keyboardShortcut(.cancelAction)
                    }
                    .padding(.leading, Space.s4)
                    .padding(.trailing, Space.s2)
                    .padding(.vertical, Space.s2)
                    .background(RoundedRectangle(cornerRadius: t.radii.container, style: .continuous).fill(t.roles.raised))
                    .museFloat(t)
                    .padding(.bottom, Space.s5)
                    .transition(.opacity)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.picked.isEmpty)
    }
}

struct GalleryTile: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var take: Take
    @State private var hover = false

    var body: some View {
        let picked = store.picked.contains(take.id)
        let fresh = store.fresh.contains(take.id)
        Button { store.openTake(take.id) } label: {
            MediaTile(ref: take.thumb, caption: take.caption, meta: fresh ? "New" : take.isVideo ? "Video" : "Photo", selected: picked)
        }
        .buttonStyle(.plain)
        .help("Open \(take.caption)")
        .overlay(alignment: .topTrailing) {
            if hover || picked || !store.picked.isEmpty {
                Button { store.togglePick(take.id) } label: {
                    ZStack {
                        Circle().fill(picked ? t.roles.selection : .black.opacity(0.3))
                        Circle().strokeBorder(.white, lineWidth: 1.5)
                        if picked { Ph("checkmark", 11).foregroundStyle(t.isD ? .white : t.roles.canvas) }
                    }
                    .frame(width: 22, height: 22)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(Space.s1)
                .help(picked ? "Deselect" : "Select to compare")
                .accessibilityLabel(picked ? "Deselect \(take.caption)" : "Select \(take.caption) to compare")
            }
        }
        .onHover { hover = $0 }
        .accessibilityAction(named: Text(picked ? "Deselect" : "Select to compare")) { store.togglePick(take.id) }
        .contextMenu {
            Button(picked ? "Deselect" : "Select to compare") { store.togglePick(take.id) }
            Button(take.isFinal ? "Move back to Tests" : "Approve") { take.isFinal ? store.unapprove(take) : store.approve(take) }
            Button("Post…") { store.openPostSheet(take) }
            if store.canEdit(take) {
                Button("Edit video…") { store.openEditor(take) }
            }
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
        ScreenPage {
            ScreenTitle("Compare takes", subtitle: "\(items.count) takes side by side") {
                RButton("Done") { withAnimation { store.comparing = false } }
                    .keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top, spacing: Space.s5) {
                ForEach(items) { take in
                    VStack(alignment: .leading, spacing: Space.s2) {
                        MediaFrame(ref: take.thumb)
                        Text(take.caption).scaled(t.scale.heading, t.roles.ink).lineLimit(1).padding(.top, Space.s1)
                        Text(meta(take)).monospacedDigit().scaled(t.scale.caption, t.roles.ink2)
                        HStack(spacing: Space.s2) {
                            if take.isFinal {
                                StateTag("Approved", .positive)
                            } else {
                                RButton("Approve", small: true) { store.approve(take) }
                            }
                            RButton("Open", kind: .plain, small: true) { store.openTake(take.id) }
                        }
                        .padding(.top, Space.s1)
                    }
                    .frame(maxWidth: 300)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func meta(_ take: Take) -> String {
        let engine = take.displayEngineLabel.isEmpty ? (take.isVideo ? "Video" : "Photo") : take.displayEngineLabel
        return ScreenCopy.meta([engine, Pricing.money(take.cost), "seed \(take.seed)"])
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
                        Crumb(parent: "Library", title: take.caption) { store.go(.gallery) }
                        HStack(alignment: .top, spacing: Space.s6) {
                            Spacer(minLength: 0)
                            Group {
                                if let v = take.videoUrl, let u = URL(string: v) {
                                    TakePlayer(url: u, caption: take.mediaLine ?? "Video")
                                } else {
                                    MediaFrame(ref: take.thumb)
                                }
                            }
                            .frame(height: min(720, max(360, g.size.height - 110)))
                            inspector(take, job: job, outfit: outfit)
                                .frame(width: 360)
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.s5)
                    .padding(.bottom, Space.s7)
                }
            }
        } else {
            ScreenPage {
                EmptyState("Nothing open", "Pick a take in the Library to see it here.", actionTitle: "Open library") { store.go(.gallery) }
            }
        }
    }

    @ViewBuilder private func inspector(_ take: Take, job: Job?, outfit: Outfit?) -> some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(take.caption).scaled(t.scale.title, t.roles.ink).fixedSize(horizontal: false, vertical: true)
                    Text(take.isFinal ? "Final" : "Test").scaled(t.scale.caption, take.isFinal ? t.roles.positive : t.roles.ink2)
                }
                Spacer()
                MoreMenu {
                    if store.canEdit(take) { Button("Edit video…") { store.openEditor(take) } }
                    Button("Post…") { store.openPostSheet(take) }
                    Button("Download") { store.export(take) }
                    Button("Share…") { store.share(take) }
                    Button("Copy prompt") { store.copy(take.prompt.isEmpty ? (job?.prompt ?? "") : take.prompt) }
                    if !take.isVideo {
                        Button("Save as template…") { store.saveAsTemplate(take) }.disabled(!store.canSaveAsTemplate(take))
                    }
                    Button("Compare takes") { store.compareFromResult() }
                    Divider()
                    Button("Delete take", role: .destructive) { store.discard(take) }
                }
            }

            // Details: label and value, grouped by space (no box).
            VStack(alignment: .leading, spacing: Space.s2) {
                let base: [(String, String)] = [
                    ("Model", job?.modelName ?? store.currentModel?.name ?? "—"),
                    ("Outfit", outfit?.name ?? store.currentOutfit?.name ?? "—"),
                    ("Made with", take.isVideo ? (job?.engineLabel ?? (take.displayEngineLabel.isEmpty ? "Video" : take.displayEngineLabel)) : "Photo"),
                    ("Cost", Pricing.money(take.cost)),
                    ("Seed", "\(take.seed)\(take.isVideo ? ", locked" : "")"),
                ]
                let templateRow: [(String, String)] = take.templateName.map { name in [("Template", name)] } ?? []
                let editRow: [(String, String)] = take.isEdit
                    ? [("Edited from", take.parentTakeId.flatMap { id in store.takes.first { $0.id == id }?.caption } ?? "A take that was deleted")] : []
                let media: [(String, String)] = take.isVideo ? [
                    ("Length", take.durationSec.map { "\(Pricing.trimNum($0)) s" } ?? "—"),
                    ("Size", take.width.flatMap { w in take.height.map { "\(w)×\($0)" } } ?? "—"),
                ] : []
                let allRows = base + templateRow + editRow + media
                ForEach(Array(allRows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                        Text(row.0).scaled(t.scale.caption, t.roles.ink2).frame(width: 96, alignment: .leading)
                        Text(row.1).monospacedDigit().scaled(t.scale.body, t.roles.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }

            // One action per screen: Approve a test take; once it's final, Post it.
            VStack(alignment: .leading, spacing: Space.s2) {
                if take.isFinal {
                    RButton(store.model(for: take).map { "Post to \($0.shortName)'s accounts" } ?? "Post", kind: .action, fill: true) { store.openPostSheet(take) }
                } else {
                    RButton("Approve", kind: .action, fill: true) { store.approve(take) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Move to Final (⌘↩)")
                    RButton(store.model(for: take).map { "Post to \($0.shortName)'s accounts" } ?? "Post", fill: true) { store.openPostSheet(take) }
                }
                HStack(spacing: Space.s2) {
                    RButton("Retake with changes", fill: true) { store.retake(take) }
                    RButton("Export", fill: true) { store.export(take) }
                        .help("Save it to Downloads › MUSE")
                }
                SaveToCollectionButton(takeIds: [take.id]) {
                    Label("Save to collection", ph: "stack").scaled(t.scale.label, t.roles.link).frame(minHeight: 28)
                }
                if store.canEdit(take) {
                    RButton(take.isEdit ? "Edit again" : "Edit video", fill: true) { store.openEditor(take) }
                        .help("Trim, split, change speed or mute. Saved as a new version; the original is kept.")
                }
                if ExtendSource.take(take) != nil || take.canUpscale {
                    HStack(spacing: Space.s2) {
                        if ExtendSource.take(take) != nil {
                            RButton("Extend", fill: true) { store.openExtend(take) }
                                .help("A longer take: what happens next, or before")
                        }
                        if take.canUpscale { UpscaleButton(take: take, fill: true) }
                    }
                }
                if !take.isVideo {
                    if store.canSaveAsTemplate(take) {
                        RButton("Save as template", fill: true) { store.saveAsTemplate(take) }
                    } else {
                        Text("Made with \(take.templateName ?? "someone else's template"). Its look stays with its creator, so it can't be saved as a new template.")
                            .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                RButton("Delete take", kind: .danger) { store.discard(take) }
            }

            if let posted = store.posts(for: take).first(where: \.isOut) {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text(posted.state == "posted" ? "Posted" : "Handed off").scaled(t.scale.heading, t.roles.ink)
                    HStack(spacing: Space.s1) { ForEach(posted.platforms) { PlatformBadge(platform: $0, size: 20) } }
                    if let s = posted.stats { Text(s.line).monospacedDigit().scaled(t.scale.caption, t.roles.ink2) }
                }
                .padding(.top, Space.s3)
            }
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
            Text(caption).font(t.scale.micro.font).monospacedDigit().foregroundStyle(.white)
                .padding(.horizontal, Space.s2).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous).fill(.black.opacity(0.55)))
                .padding(Space.s3)
                .allowsHitTesting(false)
        }
        .aspectRatio(768.0 / 1344.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: t.radii.container, style: .continuous))
        .onAppear { load() }
        .onChange(of: url) { load() }
        .onDisappear {
            // Off screen: release the player and its item (decoder, buffers), not just pause it. onAppear makes a new one.
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
        }
    }

    private func load() {
        player?.pause()
        let p = AVPlayer(url: url)
        p.actionAtItemEnd = .pause
        player = p
    }
}

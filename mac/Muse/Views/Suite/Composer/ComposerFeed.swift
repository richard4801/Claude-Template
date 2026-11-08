import AVKit
import MuseCore
import SwiftUI

// The results feed beside the composer (plans/ai-suite-design.md §2 "Feed", approved for the current Suite on
// 2026-11-08): the header's "Takes" swaps the picture for the feed, in the picture's place beside the Setup rail and
// the prompt bar. Rendering and failed renders first as one card each, then every take, newest first, a page at a time
// (GET /v1/suite/feed), filtered by status, tool and model. Only the hovered card plays (muted); a click opens it large
// over the feed (← → move through the takes). A take's actions: Vary, Use as start frame and Compare on hover, and all
// of them (with Reuse settings, Extend, Open in Edit, Post and Open) in its context menu. Compare puts two takes side by
// side over the composer. Empty: the line and three presets to start from.

struct ComposerFeed: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    private var photo: Bool { store.suite.composer.tool == .photo }

    /// Reload when the tool, a filter or the studio's renders change (a job starts, finishes or fails; takes land).
    private var refreshKey: String {
        let s = store.suite
        let settled = store.jobs.filter { $0.isDone || $0.isFailed }.count
        return "\(photo)-\(s.feedFilter.rawValue)-\(s.feedTool ?? "")-\(s.feedModel ?? "")-\(s.feedCollection ?? "")-\(store.jobs.count)-\(settled)-\(store.takes.count)-\(store.serverKey)"
    }

    /// No filter beyond this composer's own tools.
    private var unfiltered: Bool {
        store.suite.feedFilter == .all && store.suite.feedTool == nil && store.suite.feedModel == nil && store.suite.feedCollection == nil
    }

    /// The feed's cards; with no filter and nothing listed (takes made before the feed, the demo) the Suite takes the
    /// app already has, so the feed never contradicts the picture.
    private var items: [SuiteFeedItem] {
        if !store.suite.feed.isEmpty || !unfiltered { return store.suite.feed }
        return store.suiteTakes(photo: photo).prefix(40).map { tk in
            var it = SuiteFeedItem(id: "local-\(tk.id)", kind: photo ? "photo" : "take", status: "done", tool: photo ? "photo" : "shot", jobId: tk.jobId,
                                   title: tk.displayLabel, createdAt: tk.createdAt, poster: tk.thumb,
                                   aspect: SuiteFeedText.aspect(width: tk.width.map { Double($0) }, height: tk.height.map { Double($0) }),
                                   durationSec: tk.durationSec, summary: tk.displayLabel)
            it.takeId = tk.id
            return it
        }
    }

    var body: some View {
        let list = items
        let viewTakes = list.compactMap { store.feedTake($0) }
        ZStack {
            VStack(alignment: .leading, spacing: Space.s3) {
                header
                if list.isEmpty && store.suite.queued.isEmpty {
                    empty
                } else {
                    ScrollView(.vertical) {
                        if !store.suite.queued.isEmpty { FeedQueuedGroup().padding(.bottom, Space.s2) }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: photo ? 140 : 180), spacing: Space.s3)], alignment: .leading, spacing: Space.s3) {
                            ForEach(list) { item in
                                card(item)
                                    .onAppear { if item.id == list.last?.id { Task { await store.loadFeed(photo: photo, reset: false) } } }
                            }
                        }
                        .padding(.bottom, Space.s3)
                    }
                }
            }
            .padding(Space.s4)
            // A card's large viewer, over the feed; the arrow keys move through the takes.
            if let id = store.suite.viewerTakeId, let i = viewTakes.firstIndex(where: { $0.id == id }) {
                FeedViewer(takes: viewTakes, index: i, photo: photo)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: t.radii.container).fill(t.roles.raised))
        .clipShape(RoundedRectangle(cornerRadius: t.radii.container))
        .task(id: refreshKey) {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            await store.loadFeed(photo: photo)
        }
        .task(id: store.serverKey) { await store.loadCollections() }
        .onDisappear { store.suite.viewerTakeId = nil }
        // Run on a queued shot: today's price, confirmed before anything is held.
        .alert(runTitle, isPresented: Binding(get: { store.suite.runAsk != nil }, set: { if !$0 { store.suite.runAsk = nil } }), presenting: store.suite.runAsk) { ask in
            Button("Run · \(Pricing.money(ask.item.estimate))") { store.confirmRunQueued() }
                .keyboardShortcut(.defaultAction)
            Button("Keep queued", role: .cancel) { store.suite.runAsk = nil }
        } message: { ask in
            Text(ask.changed
                 ? "The price changed since you queued it. It's \(Pricing.money(ask.item.estimate)) now, held from the studio's balance when it starts."
                 : "\(Pricing.money(ask.item.estimate)) is held from the studio's balance when it starts, and a take that fails is refunded.")
        }
    }

    private var runTitle: String { store.suite.runAsk.map { "Run \($0.item.title)?" } ?? "" }

    /// "Takes", then the tool and model filters and the status filter. Narrow: the status filter becomes one "All ▾".
    private var header: some View {
        HStack(spacing: Space.s3) {
            Text(photo ? "Photos" : "Takes").font(t.scale.heading.font).foregroundStyle(t.roles.ink).lineLimit(1).fixedSize()
            Spacer(minLength: Space.s2)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.s2) {
                    scopeMenus
                    FeedFilterSegments()
                        .background { if SnapshotRunner.probing { ComposerBarFrame(key: "feed filter") } }
                }
                HStack(spacing: Space.s2) {
                    scopeMenus
                    FeedFilterMenu()
                        .background { if SnapshotRunner.probing { ComposerBarFrame(key: "feed filter") } }
                }
            }
        }
        .background { if SnapshotRunner.probing { ComposerBarFrame(key: "feed header") } }
    }

    /// Which tool (the video tools only; Photo has one) and which model.
    @ViewBuilder private var scopeMenus: some View {
        if !photo {
            FeedScopeMenu(title: "Tool", allLabel: "All tools", options: FeedScope.tools, selected: store.suite.feedTool) { store.suite.feedTool = $0 }
        }
        let models = store.suiteCharacters.map { ($0.id, $0.shortName) }
        if !models.isEmpty {
            FeedScopeMenu(title: "Model", allLabel: "All models", options: models, selected: store.suite.feedModel) { store.suite.feedModel = $0 }
        }
        if !store.library.collections.isEmpty {
            FeedScopeMenu(title: "Collection", allLabel: "All takes", options: store.library.collections.map { ($0.id, $0.name) },
                          selected: store.suite.feedCollection) { store.suite.feedCollection = $0 }
        }
    }

    /// What this is, plus three presets to start from (the prompt is right there too).
    private var empty: some View {
        VStack(spacing: Space.s3) {
            Text(store.suite.feedLoading ? "Loading…" : emptyLine).font(t.scale.body.font).foregroundStyle(t.roles.ink2)
                .multilineTextAlignment(.center)
            if !unfiltered {
                Button("Show everything") {
                    store.suite.feedFilter = .all
                    store.suite.feedTool = nil
                    store.suite.feedModel = nil
                    store.suite.feedCollection = nil
                }
                .buttonStyle(.plain)
                .font(t.scale.label.font).foregroundStyle(t.roles.link)
            } else if !store.suite.feedLoading {
                presetSuggestions
            }
        }
        .padding(Space.s4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyLine: String {
        if store.suite.feedFilter != .all { return "Nothing \(store.suite.feedFilter.label.lowercased()) right now" }
        if !unfiltered { return "Nothing made like that yet" }
        return photo ? "Your photos appear here" : "Your takes appear here"
    }

    /// Three presets (Shot) or photo presets (Photo): one click puts it in the composer.
    @ViewBuilder private var presetSuggestions: some View {
        let shot = Array(store.suite.camera.presets.prefix(3))
        let stills = Array(store.templates.prefix(3))
        if photo ? !stills.isEmpty : !shot.isEmpty {
            VStack(spacing: Space.s2) {
                Text("Or start from a preset").font(t.scale.caption.font).foregroundStyle(t.roles.ink2)
                HStack(spacing: Space.s2) {
                    if photo {
                        ForEach(stills) { tpl in
                            suggestion(tpl.name) {
                                store.choosePhotoPreset(tpl)
                                store.suite.feedOpen = false
                            }
                        }
                    } else {
                        ForEach(shot) { p in
                            suggestion(p.label) {
                                if store.suite.composer.tool != .shot { store.openTool(.shot) }
                                store.applyPreset(p)
                                store.suite.feedOpen = false
                            }
                        }
                    }
                }
            }
        }
    }

    private func suggestion(_ name: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(name).font(t.scale.label.font).foregroundStyle(t.roles.ink).lineLimit(1).fixedSize()
                .padding(.horizontal, Space.s3).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: t.radii.control).fill(t.roles.field))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Start from \(name)")
    }

    @ViewBuilder private func card(_ item: SuiteFeedItem) -> some View {
        if item.isJob {
            if item.isFailed {
                FeedFailedCard(item: item, photo: photo)
            } else {
                let job = store.feedJob(item)
                FeedRunningCard(poster: job?.thumb ?? item.poster, state: job.map { SuiteResultState.of($0) }, progress: item.progress,
                                aspect: FeedCard.ratio(item.aspect, photo: photo))
            }
        } else {
            FeedTakeCard(item: item, take: store.feedTake(item), photo: photo)
        }
    }
}

/// The "Queued" group at the top of the feed: shots saved to run later. Each row: its title, "Run · $0.40" (prices it
/// again, then asks before it runs) and Remove. Nothing is held until Run is confirmed.
struct FeedQueuedGroup: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            Text("Queued").font(t.scale.label.font).foregroundStyle(t.roles.ink2)
            ForEach(store.suite.queued) { q in
                HStack(spacing: Space.s3) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(q.title).font(t.scale.label.font).foregroundStyle(t.roles.ink).lineLimit(1)
                        if !q.mine, let who = store.members.first(where: { $0.id == q.userId })?.email {
                            Text("Queued by \(who)").font(t.scale.caption.font).foregroundStyle(t.roles.ink2).lineLimit(1)
                        }
                    }
                    Spacer(minLength: Space.s2)
                    let pricing = store.suite.queuePricing == q.id
                    Button { store.askRunQueued(q) } label: {
                        HStack(spacing: Space.s1) {
                            if pricing { ProgressView().controlSize(.small) }
                            Text(q.buttonLabel).font(t.scale.label.font).monospacedDigit().lineLimit(1).fixedSize()
                                .fitProbe("composer queued run")
                        }
                        .foregroundStyle(t.roles.ink)
                        .padding(.horizontal, Space.s3).frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: t.radii.control).strokeBorder(t.roles.hairline))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(pricing)
                    .help("Price it again, then run it")
                    .accessibilityLabel(q.buttonLabel)
                    SuiteIconButton(systemName: "x", label: "Remove \(q.title) from the queue") { store.removeQueued(q) }
                }
                .padding(.horizontal, Space.s3).padding(.vertical, Space.s2)
                .background(RoundedRectangle(cornerRadius: t.radii.control).fill(t.roles.field))
            }
        }
        .background { if SnapshotRunner.probing { ComposerBarFrame(key: "queued") } }
    }
}

enum FeedScope {
    /// The video tools a feed can narrow to (ids as the server's `tool`).
    static let tools: [(String, String)] = [("shot", "Shot"), ("extend", "Extend"), ("upscale", "Upscale"), ("swap", "Character swap"), ("recast", "Recast")]
}

/// "All tools ▾" / "All models ▾": the current choice and a caret; the list opens in a popover.
struct FeedScopeMenu: View {
    @Environment(\.theme) private var t
    var title: String
    var allLabel: String
    var options: [(String, String)]
    var selected: String?
    var onPick: (String?) -> Void
    @State private var open = false

    var body: some View {
        let current = options.first { $0.0 == selected }?.1 ?? allLabel
        Button { open.toggle() } label: {
            HStack(spacing: Space.s1) {
                Text(current).font(t.scale.caption.font.weight(.medium)).lineLimit(1).fixedSize()
                    .fitProbe("composer feed \(title.lowercased()) menu")
                Ph("caret-down", 11)
            }
            .foregroundStyle(selected == nil ? t.roles.ink2 : t.roles.ink)
            .padding(.horizontal, Space.s3).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: t.radii.control).fill(t.roles.field))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(title)
        .accessibilityLabel("\(title): \(current)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            PillList(title: title, options: [(allLabel, String?.none)] + options.map { ($0.1, String?.some($0.0)) }, selected: selected) {
                onPick($0)
                open = false
            }
            .environment(\.theme, t)
        }
    }
}

/// A take large over the feed: the video playing (or the photo), its line, and its actions. ← and → move through the
/// feed's takes; Esc or Close goes back to the grid.
struct FeedViewer: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var takes: [Take]
    var index: Int
    var photo: Bool
    @State private var player: AVPlayer?

    private var take: Take { takes[index] }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(take.displayLabel).font(t.scale.heading.font).foregroundStyle(t.roles.ink).lineLimit(1)
                    Text(SuiteFeedText.summary(take.draft ?? store.job(for: take)?.draft, seconds: take.durationSec))
                        .font(t.scale.caption.font).monospacedDigit().foregroundStyle(t.roles.ink2).lineLimit(1)
                }
                Spacer(minLength: Space.s2)
                Text("\(index + 1) of \(takes.count)").font(t.scale.caption.font).monospacedDigit().foregroundStyle(t.roles.ink2)
                    .lineLimit(1).fixedSize()
                SuiteIconButton(systemName: "caret-left", label: "Previous take") { move(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(index == 0)
                SuiteIconButton(systemName: "caret-right", label: "Next take") { move(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(index >= takes.count - 1)
                SuiteIconButton(systemName: "x", label: "Close the viewer") { store.suite.viewerTakeId = nil }
                    .keyboardShortcut(.cancelAction)
            }
            Group {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    MuseImage(ref: take.thumb)
                }
            }
            .aspectRatio(ratio, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: t.radii.container))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(take.displayLabel)
            HStack(spacing: Space.s4) {
                link("Vary") { store.vary(take) }
                if !photo { link("Use as start frame") { store.useAsStartFrame(take) } }
                link(store.suite.compareIds.contains(take.id) ? "Remove from compare" : "Compare") { store.compareInSuite(take) }
                link("Reuse settings") { if !store.reuseSettings(take) { store.showToast("This take was made before Reuse settings") } }
                if take.isVideo { link("Open in Edit") { store.openEdit(takeId: take.id) } }
                SaveToCollectionButton(takeIds: [take.id]) {
                    Text("Save to collection").font(t.scale.label.font).foregroundStyle(t.roles.link).lineLimit(1).fixedSize()
                }
                Spacer(minLength: 0)
            }
        }
        .padding(Space.s4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: t.radii.container).fill(t.roles.raised))
        .background { if SnapshotRunner.probing { ComposerBarFrame(key: "viewer") } }
        .onAppear { load() }
        .onChange(of: take.id) { _, _ in load() }
        .onDisappear { release() }
    }

    private var ratio: CGFloat {
        if let w = take.width, let h = take.height, w > 0, h > 0 { return CGFloat(w) / CGFloat(h) }
        return take.isVideo ? 9.0 / 16.0 : 4.0 / 5.0
    }

    private func link(_ title: String, _ run: @escaping () -> Void) -> some View {
        Button(title, action: run).buttonStyle(.plain).font(t.scale.label.font).foregroundStyle(t.roles.link).lineLimit(1).fixedSize()
    }

    private func move(_ by: Int) {
        let i = index + by
        guard takes.indices.contains(i) else { return }
        store.suite.viewerTakeId = takes[i].id
    }

    private func load() {
        release()
        guard let v = take.videoUrl, let u = URL(string: v) else { return }
        let p = AVPlayer(url: u)
        p.actionAtItemEnd = .pause
        player = p
        p.play()
    }

    private func release() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}

/// Only the hovered card plays: muted, looping, released when the pointer leaves (plans/ai-suite-design.md refinement 7).
struct FeedHoverPlayer: View {
    var url: URL
    @State private var queue: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    var body: some View {
        Group {
            if let queue { PlayerLayerView(player: queue).allowsHitTesting(false) }
        }
        .onAppear {
            let q = AVQueuePlayer()
            q.isMuted = true
            looper = AVPlayerLooper(player: q, templateItem: AVPlayerItem(url: url))
            queue = q
            q.play()
        }
        .onDisappear {
            queue?.pause()
            looper?.disableLooping()
            queue?.removeAllItems()
            looper = nil
            queue = nil
        }
    }
}

/// All · Rendering · Finished · Failed as one segmented control: each label whole with 12 pt either side.
struct FeedFilterSegments: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SuiteFeedFilter.allCases) { f in
                let on = f == store.suite.feedFilter
                Button { store.suite.feedFilter = f } label: {
                    Text(f.label).font(t.scale.caption.font.weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? t.roles.ink : t.roles.ink2)
                        .lineLimit(1).fixedSize()
                        .fitProbe("composer feed filter \(f.label)")
                        .padding(.horizontal, Space.s3).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: t.radii.chip).fill(on ? t.roles.canvas : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(f.label)\(on ? ", selected" : "")")
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: t.radii.control).fill(t.roles.field))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Show")
    }
}

/// The narrow form: the current filter and a caret; the list opens in a popover.
struct FeedFilterMenu: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: Space.s1) {
                Text(store.suite.feedFilter.label).font(t.scale.caption.font.weight(.medium)).lineLimit(1).fixedSize()
                    .fitProbe("composer feed filter menu")
                Ph("caret-down", 11)
            }
            .foregroundStyle(t.roles.ink)
            .padding(.horizontal, Space.s3).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: t.radii.control).fill(t.roles.field))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Show")
        .accessibilityLabel("Show \(store.suite.feedFilter.label)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            PillList(title: "Show", options: SuiteFeedFilter.allCases.map { ($0.label, $0) }, selected: store.suite.feedFilter) {
                store.suite.feedFilter = $0
                open = false
            }
            .environment(\.theme, t)
        }
    }
}

enum FeedCard {
    /// "9:16" → 9/16; unknown: 4:5 for stills, 16:9 for video.
    static func ratio(_ aspect: String?, photo: Bool) -> CGFloat {
        let parts = (aspect ?? "").split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return photo ? 4.0 / 5.0 : 16.0 / 9.0 }
        return CGFloat(parts[0] / parts[1])
    }
}

struct FeedRunningCard: View {
    @Environment(\.theme) private var t
    var poster: ImageRef?
    /// The live job's state when the job is in the app; else the feed's progress (0–100) at fetch time.
    var state: SuiteResultState?
    var progress: Double?
    var aspect: CGFloat

    var body: some View {
        let pct: Int = {
            if case .rendering(let p, _)? = state { return p }
            return Int((progress ?? 0).rounded())
        }()
        let queued: Bool = {
            if case .queued? = state { return true }
            return state == nil && pct == 0
        }()
        let shape = RoundedRectangle(cornerRadius: t.radii.control)
        VStack(alignment: .leading, spacing: Space.s2) {
            Spacer(minLength: 0)
            Text(queued ? "Waiting to start" : "Rendering · \(pct)%").font(t.scale.caption.font).monospacedDigit().foregroundStyle(t.roles.ink)
            ProgressView(value: Double(pct), total: 100).tint(t.roles.accent)
        }
        .padding(Space.s3)
        .frame(maxWidth: .infinity)
        .aspectRatio(aspect, contentMode: .fit)
        .background(shape.fill(t.roles.field))
        .background(Color.clear.overlay(MuseImage(ref: poster).blur(radius: 10).opacity(0.35)).clipShape(shape))
        .clipShape(shape)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(queued ? "Waiting to start" : "Rendering, \(pct) percent")
    }
}

struct FeedFailedCard: View {
    @Environment(\.theme) private var t
    var item: SuiteFeedItem
    var photo: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            Label("Didn’t render", ph: "warning").font(t.scale.caption.font).foregroundStyle(t.roles.ink)
            if let e = item.error { Text(e).font(t.scale.caption.font).foregroundStyle(t.roles.ink2).lineLimit(3) }
            if let r = item.refunded, r > 0 { Text("\(Pricing.money(r)) refunded").font(t.scale.caption.font).foregroundStyle(t.roles.ink2) }
        }
        .padding(Space.s3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .aspectRatio(FeedCard.ratio(item.aspect, photo: photo), contentMode: .fit)
        .background(RoundedRectangle(cornerRadius: t.radii.control).fill(t.roles.field))
        .accessibilityElement(children: .combine)
    }
}

struct FeedTakeCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var item: SuiteFeedItem
    /// The take in the app (needed for its actions); cards from older pages may not be loaded in the app.
    var take: Take?
    var photo: Bool
    @State private var hover = false
    @State private var saving = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: t.radii.control)
        let comparing = take.map { store.suite.compareIds.contains($0.id) } ?? false
        VStack(alignment: .leading, spacing: Space.s1) {
            ZStack(alignment: .bottomLeading) {
                shape.fill(t.roles.field)
                Color.clear.overlay(MuseImage(ref: item.poster ?? take?.thumb)).clipped()
                if hover, let v = take?.videoUrl, let u = URL(string: v) { FeedHoverPlayer(url: u) }
                if hover, take != nil {
                    HStack(spacing: Space.s1) { quickActions }
                        .padding(Space.s2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                }
            }
            .aspectRatio(FeedCard.ratio(item.aspect, photo: photo), contentMode: .fit)
            .clipShape(shape)
            .overlay(shape.strokeBorder(comparing ? t.roles.accent : .clear, lineWidth: 2))
            Text(item.summary.isEmpty ? item.title : item.summary).font(t.scale.caption.font).monospacedDigit()
                .foregroundStyle(t.roles.ink2).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { open() }
        .onTapGesture { if let id = take?.id { store.suite.viewerTakeId = id } }
        .contextMenu { menu }
        .popover(isPresented: $saving, arrowEdge: .trailing) {
            if let take { SaveToCollectionPanel(takeIds: [take.id]) { saving = false }.environment(store).environment(\.theme, t) }
        }
        .help(item.title.isEmpty ? item.summary : item.title)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.title.isEmpty ? item.summary : item.title)
        .accessibilityAddTraits(comparing ? AccessibilityTraits([.isButton, .isSelected]) : AccessibilityTraits.isButton)
        .accessibilityAction(named: "Open") { open() }
        .accessibilityAction(named: "View large") { if let id = take?.id { store.suite.viewerTakeId = id } }
    }

    private func open() { if let id = item.takeId { store.openTake(id) } }

    @ViewBuilder private var quickActions: some View {
        if let take {
            action("shuffle", "Vary") { store.vary(take) }
            if !photo { action("frame-corners", "Use as start frame") { store.useAsStartFrame(take) } }
            action("columns", "Compare") { store.compareInSuite(take) }
        }
    }

    @ViewBuilder private var menu: some View {
        if let take {
            Button("Vary") { store.vary(take) }
            Button("Reuse settings") { if !store.reuseSettings(take) { store.showToast("This take was made before Reuse settings") } }
            if !photo { Button("Use as start frame") { store.useAsStartFrame(take) } }
            Button(store.suite.compareIds.contains(take.id) ? "Remove from compare" : "Compare") { store.compareInSuite(take) }
            if ExtendSource.take(take) != nil { Button("Extend") { store.openExtend(take) } }
            if take.isVideo { Button("Open in Edit") { store.openEdit(takeId: take.id) } }
            Button("Save to collection…") { saving = true }
            Button("Post…") { store.openPostSheet(take) }
        }
        Button("Open") { open() }
    }

    private func action(_ icon: String, _ name: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Ph(icon, 15).foregroundStyle(.white).frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: t.radii.chip).fill(.black.opacity(0.5)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
    }
}

/// Two takes side by side over the composer, playing together (Compare in the feed). Esc or Done closes it.
struct ComposerCompare: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var takes: [Take]
    @State private var players: [String: AVPlayer] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack(spacing: Space.s3) {
                Text("Compare takes").font(t.scale.title.font).foregroundStyle(t.roles.ink)
                Spacer(minLength: Space.s2)
                if takes.contains(where: { $0.videoUrl != nil }) {
                    Button { playBoth() } label: { Label("Play both", ph: "play").font(t.scale.label.font) }
                        .buttonStyle(.plain).foregroundStyle(t.roles.ink)
                        .frame(minHeight: 32)
                }
                MButton("Done") { store.suite.compareIds = [] }
                    .keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top, spacing: Space.s4) {
                ForEach(takes) { take in
                    VStack(alignment: .leading, spacing: Space.s2) {
                        media(take)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Text(take.displayLabel).font(t.scale.label.font).foregroundStyle(t.roles.ink).lineLimit(1)
                        Text(SuiteFeedText.summary(take.draft ?? store.job(for: take)?.draft, seconds: take.durationSec))
                            .font(t.scale.caption.font).monospacedDigit().foregroundStyle(t.roles.ink2).lineLimit(1)
                        HStack(spacing: Space.s3) {
                            Button("Vary") { store.suite.compareIds = []; store.vary(take) }
                            Button("Reuse settings") {
                                store.suite.compareIds = []
                                if !store.reuseSettings(take) { store.showToast("This take was made before Reuse settings") }
                            }
                        }
                        .buttonStyle(.plain).font(t.scale.label.font).foregroundStyle(t.roles.link)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(Space.s5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t.roles.canvas)
        .onAppear { load() }
        .onDisappear {
            players.values.forEach { $0.pause(); $0.replaceCurrentItem(with: nil) }
            players = [:]
        }
    }

    @ViewBuilder private func media(_ take: Take) -> some View {
        let ratio: CGFloat = {
            if let w = take.width, let h = take.height, w > 0, h > 0 { return CGFloat(w) / CGFloat(h) }
            return take.isVideo ? 9.0 / 16.0 : 4.0 / 5.0
        }()
        Group {
            if let p = players[take.id] {
                VideoPlayer(player: p)
            } else {
                MuseImage(ref: take.thumb)
            }
        }
        .aspectRatio(ratio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: t.radii.container))
        .accessibilityLabel(take.displayLabel)
    }

    private func load() {
        var out: [String: AVPlayer] = [:]
        for take in takes {
            guard let v = take.videoUrl, let u = URL(string: v) else { continue }
            let p = AVPlayer(url: u)
            p.isMuted = true
            p.actionAtItemEnd = .pause
            out[take.id] = p
        }
        players = out
    }

    /// Both from the start, together.
    private func playBoth() {
        for p in players.values { p.seek(to: .zero) }
        for p in players.values { p.play() }
    }
}

import AVKit
import MuseCore
import SwiftUI

// The results feed beside the composer (plans/ai-suite-design.md §2 "Feed", approved for the current Suite on
// 2026-11-08): the header's "Takes" swaps the picture for the feed, in the picture's place beside the Setup rail and
// the prompt bar. Rendering and failed renders first as one card each, then every take, newest first, a page at a time
// (GET /v1/suite/feed). A take's actions: Vary, Use as start frame and Compare on hover, and all of them (with Reuse
// settings, Open in Edit and Open) in its context menu. Compare puts two takes side by side over the composer.

struct ComposerFeed: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    private var photo: Bool { store.suite.composer.tool == .photo }

    /// Reload when the tool, the filter or the studio's renders change (a job starts, finishes or fails; takes land).
    private var refreshKey: String {
        let settled = store.jobs.filter { $0.isDone || $0.isFailed }.count
        return "\(photo)-\(store.suite.feedFilter.rawValue)-\(store.jobs.count)-\(settled)-\(store.takes.count)-\(store.serverKey)"
    }

    /// The feed's cards; on "All" with nothing listed (takes made before the feed, the demo) the Suite takes the app
    /// already has, so the feed never contradicts the picture.
    private var items: [SuiteFeedItem] {
        if !store.suite.feed.isEmpty || store.suite.feedFilter != .all { return store.suite.feed }
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
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s3) {
                Text(photo ? "Photos" : "Takes").font(t.scale.heading.font).foregroundStyle(t.roles.ink)
                Spacer(minLength: Space.s2)
                // The four filters with room around each label; when the feed is narrow, one "All ▾" that opens them.
                ViewThatFits(in: .horizontal) {
                    FeedFilterSegments()
                    FeedFilterMenu()
                }
                .background { if SnapshotRunner.probing { ComposerBarFrame(key: "feed filter") } }
            }
            .background { if SnapshotRunner.probing { ComposerBarFrame(key: "feed header") } }
            if list.isEmpty {
                empty
            } else {
                ScrollView(.vertical) {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: t.radii.container).fill(t.roles.raised))
        .task(id: refreshKey) {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            await store.loadFeed(photo: photo)
        }
    }

    /// What this is, plus where to start (the prompt is right there).
    private var empty: some View {
        VStack(spacing: Space.s2) {
            Text(store.suite.feedLoading ? "Loading…" : emptyLine).font(t.scale.body.font).foregroundStyle(t.roles.ink2)
                .multilineTextAlignment(.center)
            if store.suite.feedFilter != .all {
                Button("Show all") { store.suite.feedFilter = .all }.buttonStyle(.plain)
                    .font(t.scale.label.font).foregroundStyle(t.roles.link)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyLine: String {
        if store.suite.feedFilter != .all { return "Nothing \(store.suite.feedFilter.label.lowercased()) right now" }
        return photo ? "Your photos appear here" : "Your takes appear here"
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

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: t.radii.control)
        let comparing = take.map { store.suite.compareIds.contains($0.id) } ?? false
        VStack(alignment: .leading, spacing: Space.s1) {
            ZStack(alignment: .bottomLeading) {
                shape.fill(t.roles.field)
                Color.clear.overlay(MuseImage(ref: item.poster ?? take?.thumb)).clipped()
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
        .contextMenu { menu }
        .help(item.title.isEmpty ? item.summary : item.title)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.title.isEmpty ? item.summary : item.title)
        .accessibilityAddTraits(comparing ? AccessibilityTraits([.isButton, .isSelected]) : AccessibilityTraits.isButton)
        .accessibilityAction(named: "Open") { open() }
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

import MuseCore
import SwiftUI

// The cinematic Suite's takes rail (mock 1-shot) on GET /v1/suite/feed: queued, rendering and failed renders as one card
// each (live progress from the jobs stream), then every take or photo, newest first, a page at a time. The take on the
// stage carries the accent ring; the hovered one lifts and shows its four actions plus More. "All ▾" filters by status.
// Photo shows its stills in two columns. Reuse settings and Vary restore the take's draft.

struct CinemaTakesRail: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @Binding var picked: String?

    private var photo: Bool { store.suite.composer.tool == .photo }

    /// Reload when the tool, the filter or the studio's renders change (a job starts, finishes or fails; takes land).
    private var refreshKey: String {
        let settled = store.jobs.filter { $0.isDone || $0.isFailed }.count
        return "\(photo)-\(store.suite.feedFilter.rawValue)-\(store.jobs.count)-\(settled)-\(store.takes.count)-\(store.serverKey)"
    }

    @State private var filterOpen = false

    /// The feed's cards; when the feed has none on "All" (a studio whose takes predate the feed, the demo), the takes the
    /// app already has, so the rail never contradicts the stage.
    private func railItems(_ localTakes: [Take]) -> [SuiteFeedItem] {
        if !store.suite.feed.isEmpty || store.suite.feedFilter != .all { return store.suite.feed }
        return localTakes.prefix(40).map { tk in
            var it = SuiteFeedItem(id: "local-\(tk.id)", kind: photo ? "photo" : "take", status: "done", tool: photo ? "photo" : "shot", jobId: tk.jobId,
                                   title: tk.displayLabel, createdAt: tk.createdAt, poster: tk.thumb, durationSec: tk.durationSec, summary: tk.displayLabel)
            it.takeId = tk.id
            return it
        }
    }

    var body: some View {
        let localTakes = store.cinemaTakes(photo: photo)
        let items = railItems(localTakes)
        let onStage = picked ?? (photo ? localTakes.first?.id : (store.takes(of: store.shotJob).last ?? localTakes.first)?.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(photo ? "Photos" : "Takes").font(t.scale.caption.font.weight(.medium)).foregroundStyle(t.roles.ink)
                Spacer()
                filterMenu
            }
            .frame(height: 44).padding(.top, 8)
            if items.isEmpty || SnapshotRunner.state.cinemaEmpty {
                Text(emptyLine).font(t.scale.caption.font).foregroundStyle(t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    let cols = photo ? [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)] : [GridItem(.flexible())]
                    LazyVGrid(columns: cols, spacing: 10) {
                        ForEach(items) { item in
                            card(item, selected: item.takeId != nil && item.takeId == onStage)
                                .onAppear { if item.id == items.last?.id { Task { await store.loadFeed(photo: photo, reset: false) } } }
                        }
                    }
                    .padding(.top, 4).padding(.bottom, 60).padding(.trailing, 2)
                }
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
            }
        }
        .padding(.leading, 8).padding(.trailing, 20)
        .frame(maxHeight: .infinity, alignment: .top)
        .task(id: refreshKey) {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            await store.loadFeed(photo: photo)
        }
    }

    private var emptyLine: String {
        if store.suite.feedLoading { return "Loading…" }
        if store.suite.feedFilter != .all { return "Nothing \(store.suite.feedFilter.label.lowercased()) right now." }
        return photo ? "Photos land here as they render, newest on top." : "Takes land here as they render, newest on top."
    }

    @ViewBuilder private func card(_ item: SuiteFeedItem, selected: Bool) -> some View {
        if item.kind == "job" {
            if item.status == "failed" {
                CinemaFailedCard(item: item)
            } else {
                let job = store.feedJob(item)
                CinemaRunningCard(poster: job?.thumb ?? item.poster, state: job.map { SuiteResultState.of($0) },
                                  progress: item.progress, secondsLeft: job?.secondsLeft ?? item.secondsLeft, photo: photo)
            }
        } else {
            CinemaTakeCard(item: item, take: store.feedTake(item), photo: photo, selected: selected) {
                guard let id = item.takeId else { return }
                withAnimation(.easeInOut(duration: 0.25)) { picked = id }
            }
        }
    }

    private var filterMenu: some View {
        Button { filterOpen.toggle() } label: {
            HStack(spacing: 4) {
                Text(store.suite.feedFilter.label).font(t.scale.caption.font.weight(.medium))
                Ph("caret-down", 11)
            }
            .foregroundStyle(t.roles.ink)
            .padding(.horizontal, 10).frame(height: 28)
            .background(t.roles.ink.opacity(filterOpen ? 0.14 : 0.08)).clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show")
        .accessibilityLabel("Show \(store.suite.feedFilter.label)")
        .popover(isPresented: $filterOpen, arrowEdge: .bottom) {
            PillList(title: "Show", options: CinemaFeedFilter.allCases.map { ($0.label, $0) }, selected: store.suite.feedFilter) {
                store.suite.feedFilter = $0
                filterOpen = false
            }
            .environment(\.theme, t).environment(\.colorScheme, .dark)
        }
    }
}

struct CinemaRunningCard: View {
    @Environment(\.theme) private var t
    var poster: ImageRef?
    /// The live job's state when the job is in the app; else the feed's progress (0–100) at fetch time.
    var state: SuiteResultState?
    var progress: Double?
    var secondsLeft: Double?
    var photo: Bool

    var body: some View {
        let pct: Int = {
            if case .rendering(let p, _)? = state { return p }
            return Int((progress ?? 0).rounded())
        }()
        let queued: Bool = {
            if case .queued? = state { return true }
            return state == nil && pct == 0
        }()
        ZStack(alignment: .bottomLeading) {
            Color.clear.overlay(MuseImage(ref: poster).blur(radius: 10).brightness(-0.25)).clipped()
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(queued ? (state?.queueLine ?? MemberText.waitingToStart) : "\(pct)%")
                        .font(t.scale.caption.font.weight(.medium)).foregroundStyle(t.roles.ink)
                    Spacer()
                    if let s = secondsLeft, s > 0 {
                        Text("About \(Int(s.rounded())) s left").font(t.scale.micro.font).foregroundStyle(t.roles.ink.opacity(0.75))
                    }
                }
                Capsule().fill(t.roles.ink.opacity(0.2)).frame(height: 3)
                    .overlay(alignment: .leading) {
                        GeometryReader { g in
                            Capsule().fill(t.roles.accent).frame(width: g.size.width * CGFloat(pct) / 100).shadow(color: t.roles.accent, radius: 5)
                        }
                    }
            }
            .padding(12)
        }
        .aspectRatio(photo ? 4 / 5 : 16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: max(t.radii.control - 4, 8)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(queued ? "Waiting to start" : "Rendering, \(pct) percent")
    }
}

struct CinemaFailedCard: View {
    @Environment(\.theme) private var t
    var item: SuiteFeedItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Ph("warning", 14).foregroundStyle(t.roles.caution)
                Text("Didn’t render").font(t.scale.caption.font.weight(.medium)).foregroundStyle(t.roles.ink)
            }
            if let e = item.error { Text(e).font(t.scale.micro.font).foregroundStyle(t.roles.ink2).lineLimit(3) }
            if let r = item.refunded, r > 0 { Text("\(Pricing.money(r)) refunded").font(t.scale.micro.font).foregroundStyle(t.roles.ink2) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(t.roles.ink.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: max(t.radii.control - 4, 8)))
        .accessibilityElement(children: .combine)
    }
}

struct CinemaTakeCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var item: SuiteFeedItem
    /// The take in the app (needed for its actions); cards from older pages may not be loaded in the app.
    var take: Take?
    var photo: Bool
    var selected: Bool
    var onPick: () -> Void
    @State private var hover = false
    @State private var moreOpen = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: max(t.radii.control - 4, 8))
        ZStack(alignment: .bottomLeading) {
            Color.clear.overlay(MuseImage(ref: item.poster ?? take?.thumb)).clipped()
            if hover || moreOpen {
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.summary).font(t.scale.micro.font).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    HStack(spacing: 4) { actions }
                }
                .padding(8)
            }
        }
        .aspectRatio(photo ? 4 / 5 : 16 / 9, contentMode: .fit)
        .clipShape(shape)
        .overlay(shape.strokeBorder(selected ? t.roles.accent : .clear, lineWidth: 2))
        .shadow(color: selected ? t.roles.accent.opacity(0.5) : .clear, radius: 12)
        .shadow(color: hover ? .black.opacity(0.55) : .clear, radius: 14, y: 10)
        .offset(y: hover && !reduceMotion ? -3 : 0)
        .contentShape(shape)
        .onTapGesture(count: 2) { open() }
        .onTapGesture { onPick() }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.title.isEmpty ? item.summary : item.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "Open") { open() }
    }

    private func open() { if let id = item.takeId { store.openTake(id) } }

    @ViewBuilder private var actions: some View {
        if let take {
            action("shuffle", "Vary") { store.reuseSettings(take, vary: true) }
            if !photo { action("arrow-line-right", "Extend") { store.openExtend(take) } }
            action("frame-corners", "Use as start frame") { useAsStart(take) }
            if !photo { action("scissors", "Open in Edit") { store.openEdit(takeId: take.id) } }
            Button { moreOpen.toggle() } label: {
                Ph("dots-three", 15).foregroundStyle(.white).frame(width: 28, height: 28)
                    .background(.black.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("More")
            .accessibilityLabel("More")
            .popover(isPresented: $moreOpen, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    moreRow("Open") { open() }
                    moreRow("Reuse settings") { store.reuseSettings(take) }
                    moreRow("Post…") { store.openPostSheet(take) }
                }
                .padding(.vertical, 6).frame(width: 200)
                .environment(\.theme, t).environment(\.colorScheme, .dark)
            }
        } else {
            action("arrow-square-out", "Open") { open() }
        }
    }

    private func moreRow(_ title: String, _ run: @escaping () -> Void) -> some View {
        Button {
            moreOpen = false
            run()
        } label: {
            Text(title).font(t.scale.caption.font).foregroundStyle(t.roles.ink)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).frame(height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func action(_ icon: String, _ name: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Ph(icon, 15).foregroundStyle(.white).frame(width: 28, height: 28)
                .background(.black.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
    }

    /// The take's frame goes into the Shot composer's start frame.
    private func useAsStart(_ take: Take) {
        let slots = store.suite.composerSlots
        slots.slots = slots.slots.put(SlotId(.start), SlotValue(name: take.displayLabel, image: take.thumb))
        if store.suite.composer.tool != .shot { store.openTool(.shot) }
        store.showToast("Start frame set from \(take.displayLabel)")
    }
}

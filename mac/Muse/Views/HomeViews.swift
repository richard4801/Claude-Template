import MuseCore
import SwiftUI

/// A scrolling page with the prototype's `.page` padding.
struct Page<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, 36)
                .padding(.top, 28)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct Breadcrumb: View {
    @Environment(\.theme) private var t
    var parent: String
    var title: String
    var action: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            LinkText(parent, action: action)
            Text("›").foregroundStyle(t.muted)
            Text(title).foregroundStyle(t.muted)
        }
        .font(t.body(12))
        .padding(.bottom, 10)
    }
}

/// `.kpi`
struct KPI: View {
    @Environment(\.theme) private var t
    var label: String
    var value: String
    var hint: String?
    var index = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Lbl(label)
            Text(value).font(t.isA ? Fonts.font("Instrument Serif", 44, .regular) : t.mono(26, .medium)).foregroundStyle(t.isB ? t.accent : t.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
            if let hint { Muted(hint) }
        }
        .padding(t.isA ? EdgeInsets(top: 12, leading: 0, bottom: 0, trailing: 0) : EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .if(t.isA) { $0.overlay(alignment: .top) { Rectangle().fill(t.ink).frame(height: 1) } }
        .if(!t.isA) { $0.surface(t.isD ? [t.yellow, t.pink, t.mint, Color.white][index % 4] : nil) }
    }
}

struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }

    /// Takes made since the 1st of this month.
    private var monthTakes: Int {
        let start = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
        let ms = Int64(start.timeIntervalSince1970 * 1000)
        return store.takes.filter { $0.createdAt >= ms }.count
    }

    private var dateLine: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f.string(from: Date()).replacingOccurrences(of: ",", with: "")
    }

    /// First load with nothing to show yet: skeletons shaped like the page.
    private var firstLoad: Bool { store.loading && store.takes.isEmpty && store.models.isEmpty }

    var body: some View {
        let r = store.runningJob ?? store.activeJobs.first
        ScreenPage {
            ScreenTitle(greeting, subtitle: dateLine) {
                RButton("New shot", kind: .action) { store.openTool(.shot) }
                    .help("New shot in the AI Suite (⌘N)")
            }
            // Four plain facts on the canvas, not four boxed stat cards.
            HStack(alignment: .top, spacing: Space.s7) {
                fact("Balance", Pricing.money(store.creditUsd), "About \(Pricing.videosLeft(store.creditUsd)) Draft videos") { store.go(.credits) }
                fact("This month", Pricing.money(store.balance.month), ScreenCopy.count(monthTakes, "take"), nil)
                fact("In the queue", "\(store.activeJobs.count)", store.runningJob.map { $0.isWaiting ? MemberText.waitingToStart : "Rendering" } ?? "Nothing rendering") { store.go(.queue) }
                fact("To review", "\(store.toReview)", "Waiting for approval") { store.go(.gallery) }
                Spacer(minLength: 0)
            }
            .redacted(reason: firstLoad ? .placeholder : [])

            if let r {
                SectionTitle("In progress") { RButton("Open queue", kind: .plain, small: true) { store.go(.queue) } }
                HStack(alignment: .center, spacing: Space.s5) {
                    MediaFrame(ref: r.thumb).frame(width: 96)
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text(TakeText.displayTitle(r.title)).scaled(t.scale.heading, t.roles.ink).lineLimit(1)
                        Text(r.isRunning ? r.progressLine : "Starts when you run the queue").monospacedDigit().scaled(t.scale.caption, t.roles.ink2)
                        RProgress(value: r.progress / 100).frame(maxWidth: 360)
                        if r.isQueued && store.runningJob == nil {
                            RButton("Run queue · \(Pricing.money(store.queuedCost))", small: true) { store.runQueue() }
                                .padding(.top, Space.s1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            SectionTitle("Latest takes") {
                if !store.takes.isEmpty { RButton("Open library", kind: .plain, small: true) { store.go(.gallery) } }
            }
            if firstLoad {
                SkeletonGrid(columns: 6, count: 6)
            } else if store.takes.isEmpty {
                EmptyState("No takes yet", "Finished videos and photos land here, newest first.", actionTitle: "New photo") { store.openTool(.photo) }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s4), count: 6), alignment: .leading, spacing: Space.s5) {
                    ForEach(store.takes.prefix(6)) { take in
                        Button { store.openTake(take.id) } label: {
                            MediaTile(ref: take.thumb, caption: take.caption, meta: take.isVideo ? "Video" : "Photo")
                        }
                        .buttonStyle(.plain)
                        .help("Open \(take.caption)")
                    }
                }
            }

            SectionTitle("Your models") {
                if !store.models.isEmpty { RButton("All models", kind: .plain, small: true) { store.go(.models) } }
            }
            ModelGrid(limit: 5)
        }
    }

    /// A label, a figure and a short line. Clickable facts go where the number comes from.
    private func fact(_ label: String, _ value: String, _ hint: String, _ action: (() -> Void)?) -> some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            Text(label).scaled(t.scale.caption, t.roles.ink2)
            Text(value).monospacedDigit().scaled(t.scale.title, t.roles.ink).lineLimit(1)
            Text(hint).scaled(t.scale.caption, t.roles.ink2).lineLimit(1)
        }
        return Group {
            if let action {
                Button(action: action) { content.contentShape(Rectangle()) }.buttonStyle(.plain).help("Open \(label.lowercased())")
            } else {
                content
            }
        }
    }
}

/// The models as picture-plus-caption tiles. The empty state says what a model is and starts one.
struct ModelGrid: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var limit: Int?

    var body: some View {
        let list = limit.map { Array(store.models.prefix($0)) } ?? store.models
        if store.loading && store.models.isEmpty {
            SkeletonGrid(columns: 5, count: limit ?? 5, ratio: 0.75)
        } else if list.isEmpty {
            EmptyState("No models yet", "A model is a character you build from your own reference images. It keeps the same face in every photo and video.",
                       actionTitle: "New model") { store.go(.create) }
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s5), count: 5), alignment: .leading, spacing: Space.s5) {
                ForEach(list) { m in ModelCard(model: m) }
            }
        }
    }
}

struct ModelCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var model: MuseModel

    var body: some View {
        let meta = model.isDraft ? "Draft · needs face close-ups" : ScreenCopy.meta([model.niche, ScreenCopy.count(store.outfits(for: model).count, "outfit")], limit: 2)
        Button { store.openProfile(model.id) } label: {
            VStack(alignment: .leading, spacing: Space.s2) {
                if let cover = model.cover {
                    MediaFrame(ref: cover, ratio: 0.75)
                } else {
                    let shape = RoundedRectangle(cornerRadius: t.radii.container, style: .continuous)
                    Color.clear.aspectRatio(0.75, contentMode: .fit)
                        .background(shape.fill(t.roles.field))
                        .overlay(Text(model.initial).font(t.scale.display.font).foregroundStyle(t.roles.ink2))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name).scaled(t.scale.label, t.roles.ink).lineLimit(1)
                    Text(meta).scaled(t.scale.caption, model.isDraft ? t.roles.caution : t.roles.ink2).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(model.name)")
    }
}

struct ModelsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ScreenPage {
            ScreenTitle("Models") {
                RButton("New model", kind: .action) { store.go(.create) }
            }
            ModelGrid()
        }
    }
}

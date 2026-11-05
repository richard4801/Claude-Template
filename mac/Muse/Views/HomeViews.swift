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

    /// Takes made since the 1st of this month (the hint under "This month").
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

    var body: some View {
        let r = store.runningJob ?? store.activeJobs.first
        Page {
            PageHeader(eyebrow: dateLine, title: greeting) {
                MButton("Photoshoot", icon: "camera") { store.go(.shoot) }
                MButton("New video", icon: "plus", kind: .primary) { store.go(.studio) }
            }
            HStack(spacing: 14) {
                KPI(label: "Balance", value: Pricing.money(store.creditUsd), hint: "≈ \(Pricing.videosLeft(store.creditUsd)) Draft videos", index: 0)
                KPI(label: "This month", value: Pricing.money(store.balance.month), hint: "\(monthTakes) take\(monthTakes == 1 ? "" : "s") this month", index: 1)
                KPI(label: "In the queue", value: "\(store.activeJobs.count)", hint: store.runningJob.map { $0.isWaiting ? MemberText.waitingToStart : "Rendering" } ?? "Nothing rendering", index: 2)
                KPI(label: "To review", value: "\(store.toReview)", hint: "takes waiting for approval", index: 3)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        H2("Pick up where you left off")
                        Spacer()
                        if r?.isRunning == true { Sticker("live!", rotation: 4) }
                    }
                    if let r {
                        HStack(alignment: .center, spacing: 18) {
                            Media(ref: r.thumb).frame(width: 150)
                            VStack(alignment: .leading, spacing: 12) {
                                Lbl("\(r.isRunning ? "Rendering" : "Queued") · \(r.engineLabel)")
                                Text(r.title).font(t.h2).foregroundStyle(t.ink)
                                ProgressLine(value: r.progress / 100)
                                Text(r.isRunning ? r.progressLine : "Starts when you press Run queue").font(t.mono(12)).foregroundStyle(t.muted)
                                HStack {
                                    if r.isQueued && store.runningJob == nil {
                                        MButton("Run queue · \(Pricing.money(store.queuedCost))", icon: "play.fill", kind: .primary, size: .small) { store.runQueue() }
                                    }
                                    MButton("Open queue", size: .small) { store.go(.queue) }
                                }
                            }
                        }
                    } else {
                        Note("Nothing rendering. Start a new video or a photoshoot.")
                    }
                }
                .card()
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 10) {
                    H2("Create").padding(.bottom, 4)
                    QuickAction(icon: "video", title: "New video", hint: "Swap your model into a real clip", key: "⌘N") { store.go(.studio) }
                    QuickAction(icon: "camera", title: "Photoshoot", hint: "Stills in any scene, camera and light", key: nil) { store.go(.shoot) }
                    QuickAction(icon: "person.badge.plus", title: "New model", hint: "Upload your own reference images", key: nil) { store.go(.create) }
                }
                .card()
                .frame(minWidth: 300, maxWidth: 440)
            }
            .padding(.top, 22)

            SectionHeader(title: "Latest takes") { LinkText("Open gallery") { store.go(.gallery) } }
            if store.takes.isEmpty {
                Note(icon: "square.grid.2x2", "No takes yet. Finished videos and photoshoots show up here.")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6), spacing: 12) {
                ForEach(store.takes.prefix(6)) { take in
                    Button { store.openTake(take.id) } label: { Media(ref: take.thumb, caption: take.caption) }.buttonStyle(.plain)
                }
            }
            SectionHeader(title: "Your models") { LinkText("All models") { store.go(.models) } }
            ModelGrid(limit: 4)
        }
    }
}

struct QuickAction: View {
    @Environment(\.theme) private var t
    var icon: String
    var title: String
    var hint: String
    var key: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 16)).frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: t.isC ? 19 : t.controlRadius).fill(t.surface2))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(t.body(14, .bold))
                    Muted(hint)
                }
                Spacer()
                if let key { KeyCap(key) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: t.controlRadius).fill(t.isA ? .clear : t.surface))
            .overlay(RoundedRectangle(cornerRadius: t.controlRadius).strokeBorder(t.isC ? .clear : t.strongLine, lineWidth: t.lineWidth))
            .modifier(ThemeShadow(kind: t.isC ? .button : .none, radius: t.controlRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Model cards + the dashed "New model" tile (`.grid5`).
struct ModelGrid: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var limit: Int?

    var body: some View {
        let list = limit.map { Array(store.models.prefix($0)) } ?? store.models
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 5), alignment: .leading, spacing: 14) {
            ForEach(list) { m in ModelCard(model: m) }
            Button { store.go(.create) } label: {
                VStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 20))
                    Text("New model").font(t.body(14))
                    if limit == nil { Text("Bring your own images").font(t.body(12)) }
                }
                .foregroundStyle(t.muted)
                .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: t.cardRadius).strokeBorder(t.line, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

struct ModelCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var model: MuseModel

    var body: some View {
        Button { store.openProfile(model.id) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if let cover = model.cover {
                        Media(ref: cover, ratio: 0.75, radius: 0) {
                            Pill("\(model.filled)/\(SheetAngle.allCases.count) shots", model.isLocked ? .good : .warn)
                        }
                    } else {
                        InitialTile(letter: model.initial)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.name).font(t.body(14, .bold)).foregroundStyle(t.ink).lineLimit(1)
                    if model.isDraft {
                        // A narrow card (five across at 1280 px) drops the "Draft ·" prefix rather than clip the pill.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 6) {
                                Text("Draft ·").font(t.body(12)).foregroundStyle(t.muted)
                                Pill("needs face close-ups", .warn)
                            }
                            Pill("needs face close-ups", .warn)
                        }
                    } else {
                        Muted("\(model.niche) · \(store.outfits(for: model).count) outfits")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .clipShape(RoundedRectangle(cornerRadius: t.cardRadius, style: .continuous))
            .surface()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ModelsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Page {
            PageHeader(eyebrow: "Library", title: "Models") {
                MButton("New model", icon: "plus", kind: .primary) { store.go(.create) }
            }
            ModelGrid()
        }
    }
}

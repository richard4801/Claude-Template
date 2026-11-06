import MuseCore
import SwiftUI

// Identity LoRA screen, the profile's LoRA card and Accounts grid, the Post sheet and the Posts page
// (prototype/desktop/features.js; specs plans/lora-training.md and plans/socials.md).

/// A platform badge: a coloured rounded square with letters (TT, IG, f, YT, X), not a brand logo (`.pbadge`).
struct PlatformBadge: View {
    var platform: Platform
    var size: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Color(hex: platform.color))
            .frame(width: size, height: size)
            .overlay(
                Text(platform.badge)
                    .font(.system(size: (size * 0.38).rounded(), weight: .heavy))
                    .tracking(-0.2)
                    .foregroundStyle(.white)
            )
            .help(platform.label)
    }
}

/// `.ico-sq`
struct IconSquare: View {
    @Environment(\.theme) private var t
    var systemName: String
    var body: some View {
        Image(systemName: systemName).font(.system(size: 18))
            .frame(width: 44, height: 44)
            .background(RoundedRectangle(cornerRadius: t.isA ? 0 : t.r).fill(t.surface2))
    }
}

// MARK: Profile

struct ProfileLoraCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var model: MuseModel

    var body: some View {
        let l = store.lora(for: model)
        let untrained = l.state == "none" && l.version == 0
        SectionHeader(title: "Identity LoRA") { Muted("Locks face and physique across photos and videos") }
        HStack(spacing: 16) {
            IconSquare(systemName: "sparkles")
            VStack(alignment: .leading, spacing: 2) {
                Text(store.loraLine(l)).font(t.body(14, .bold))
                Muted(l.version > 0 && l.state == "ready"
                      ? "Trained on \(l.trainedOn ?? l.kept) shots you approved"
                      : "Train a photo and a video LoRA from \(LoraPricing.candidates) shots you approve · about \(Pricing.money(store.loraSetEstimate + LoraPricing.trainCost))")
            }
            Spacer(minLength: 8)
            if l.state == "training" { ProgressLine(value: l.progress / 100).frame(width: 120) }
            MButton(untrained ? "Train LoRA" : "Open", kind: untrained ? .primary : .secondary) { store.openLora(model.id) }
        }
        .card(16)
    }
}

struct ProfileAccounts: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var model: MuseModel

    var body: some View {
        let connected = store.accounts(for: model).count
        SectionHeader(title: "Accounts") { Muted("\(model.shortName)'s own social accounts · \(connected) of \(Platform.allCases.count) connected") }
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), alignment: .leading, spacing: 12) {
            ForEach(Platform.allCases) { p in AccountCard(model: model, platform: p, allowDisconnect: true) }
        }
    }
}

struct AccountCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var model: MuseModel
    var platform: Platform
    var allowDisconnect: Bool

    var body: some View {
        let a = store.account(model, platform)
        HStack(spacing: 12) {
            PlatformBadge(platform: platform, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(platform.label).font(t.body(13, .bold))
                Text(a?.handle ?? "Not connected").font(t.body(12)).foregroundStyle(t.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            if a != nil {
                if allowDisconnect { LinkText("Disconnect") { store.disconnect(model, platform) } }
            } else if store.isConnecting(model, platform) {
                Text("Signing in…").font(t.body(12)).foregroundStyle(t.muted)
            } else {
                MButton("Connect", size: .small) { store.connect(model, platform) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
    }
}

// MARK: Identity LoRA screen

struct LoraView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        if let m = store.profileModel {
            let l = store.lora(for: m)
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            LinkText("Models") { store.go(.models) }
                            Text("›").foregroundStyle(t.muted)
                            LinkText(m.name) { store.openProfile(m.id) }
                            Text("›").foregroundStyle(t.muted)
                            Text("Identity LoRA").foregroundStyle(t.muted)
                        }
                        .font(t.body(12))
                        .padding(.bottom, 10)
                        PageHeader(eyebrow: "Identity LoRA", title: m.shortName + (l.version > 0 && l.state == "ready" ? " · v\(l.version)" : ""))
                        center(m, l)
                    }
                    .padding(.horizontal, 36)
                    .padding(.top, 28)
                    .padding(.bottom, 48)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) { side(m, l) }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 344)
                .background(t.isD ? Color.white : t.surface)
                .overlay(alignment: .leading) { Rectangle().fill(t.isC ? t.line : t.strongLine).frame(width: t.lineWidth) }
            }
        } else {
            Page { Note("No model yet.") }
        }
    }

    private var grid: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 10), count: 6) }

    @ViewBuilder private func center(_ m: MuseModel, _ l: Lora) -> some View {
        switch l.state {
        case "building":
            LazyVGrid(columns: grid, spacing: 10) {
                ForEach(0..<18, id: \.self) { _ in Shimmer().aspectRatio(0.75, contentMode: .fit) }
            }
        case "review":
            HStack(alignment: .firstTextBaseline) {
                H2("\(l.kept) of \(l.candidates.count) kept")
                Spacer()
                Muted("Click a shot to drop it or bring it back · \(l.flagged) were flagged for you")
            }
            .padding(.bottom, 12)
            LazyVGrid(columns: grid, spacing: 10) {
                ForEach(l.candidates) { c in CandidateTile(candidate: c) { store.toggleCandidate(m, c) } }
            }
        case "training":
            LazyVGrid(columns: grid, spacing: 10) {
                ForEach(l.candidates.filter(\.keep).prefix(18)) { c in Media(ref: c.image, ratio: 0.75) }
            }
        case "ready":
            if store.isDemo {
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Media(ref: .asset("c_face"), ratio: 0.75, radius: t.cardRadius)
                        Muted("References only")
                    }
                    .frame(width: 280)
                    VStack(alignment: .leading, spacing: 8) {
                        Media(ref: .asset("face"), ratio: 0.75, radius: t.cardRadius)
                        Text("With LoRA v\(l.version)").font(t.body(12, .bold))
                    }
                    .frame(width: 280)
                }
                Muted("Same prompt and seed. The LoRA keeps her face shape, freckles and build steady across angles.").padding(.top, 12)
            } else {
                // A real studio sees her own training shots, never the demo's sample art.
                let kept = l.candidates.filter(\.keep)
                if kept.isEmpty {
                    Note(icon: "sparkles", "LoRA v\(l.version) is ready. Test it in Photo.")
                } else {
                    Lbl("Trained on these \(kept.count) shots").padding(.bottom, 8)
                    LazyVGrid(columns: grid, spacing: 10) {
                        ForEach(kept.prefix(18)) { c in Media(ref: c.image, ratio: 0.75) }
                    }
                }
            }
        default:
            // Her own sheet images (faded) when she has them; the neutral sample art only in demo mode or for an empty sheet.
            let own = m.slots.compactMap(\.image).prefix(6)
            LazyVGrid(columns: grid, spacing: 10) {
                if own.isEmpty {
                    ForEach(Array(["g_front", "g_tq", "face", "c_front", "g_side", "profile"].enumerated()), id: \.offset) { _, k in
                        Media(ref: store.isDemo ? ImageRef.asset(k) : nil, ratio: 0.75).opacity(0.35)
                    }
                } else {
                    ForEach(Array(own.enumerated()), id: \.offset) { _, img in
                        Media(ref: img, ratio: 0.75).opacity(0.35)
                    }
                }
            }
            Note(icon: "sparkles", "We generate \(LoraPricing.candidates) varied shots from her character sheet: new angles, outfits, light and expressions, with full-body shots so her physique is learned too. You keep the ones that look like her.")
                .padding(.top, 16)
            if l.state == "failed" {
                Note(icon: "exclamationmark.shield", warn: true, "The last training stopped. Nothing was charged for the part that failed. Build a new set to try again.").padding(.top, 10)
            }
        }
    }

    private var info: some View {
        ListBox {
            ListRow(icon: "camera", title: "Photo LoRA", hint: "Photos · ~\(Int(LoraPricing.photoMinutes)) min · \(Pricing.money(LoraPricing.photoCost))") { EmptyView() }
            ListRow(icon: "video", title: "Video LoRA", hint: "Videos · ~\(Int(LoraPricing.videoMinutes)) min · \(Pricing.money(LoraPricing.videoCost))", last: true) { EmptyView() }
        }
    }

    @ViewBuilder private func side(_ m: MuseModel, _ l: Lora) -> some View {
        switch l.state {
        case "building":
            Muted("Generating \(LoraPricing.candidates) shots…", size: 13)
            info
            MButton("Generating…", kind: .primary, size: .big, off: true) {}
        case "review":
            let enough = l.kept >= LoraPricing.minKept
            let cost = LoraPricing.trainCost
            HStack {
                Text("\(l.kept) kept").font(t.body(14, .bold))
                Spacer()
                Pill(enough ? "Enough to train" : "Keep at least \(LoraPricing.minKept)", enough ? .good : .warn)
            }
            Muted("Drop anything that doesn't look like her, or shows a tattoo, ring or choker. The LoRA learns whatever you keep.")
            info
            HStack(spacing: 0) {
                est("Time", LoraPricing.timeLabel)
                est("Cost", Pricing.money(cost))
                est("After", Pricing.money(max(0, store.balance.balance - cost)))
            }
            .card(14)
            if !enough {
                MButton("Keep \(LoraPricing.minKept - l.kept) more to train", kind: .primary, size: .big, off: true) { store.trainLora(m) }
            } else if cost > store.balance.balance + 1e-9 {
                Note(icon: "creditcard", warn: true, text: store.isMember ? Text(store.notEnoughMessage) : Text("Not enough balance. ") + Text("Credit").bold())
                    .onTapGesture { store.go(.credits) }
                MButton("Train both LoRAs · \(Pricing.money(cost))", kind: .primary, size: .big, off: true) { store.trainLora(m) }
            } else {
                MButton("Train both LoRAs · \(Pricing.money(cost))", kind: .primary, size: .big) { store.trainLora(m) }
            }
        case "training":
            Text("Training on \(l.kept) shots").font(t.body(14, .bold))
            Muted("You can keep working. We'll notify you when it's done.")
            bar("Photo LoRA", l.photo.progress > 0 || l.progress == 0 ? l.photo.progress : LoraPricing.photoProgress(l.progress))
            bar("Video LoRA", l.video.progress > 0 || l.progress == 0 ? l.video.progress : LoraPricing.videoProgress(l.progress))
            Text(LoraPricing.timeLeftLine(progress: l.progress, demo: store.isDemo)).font(t.mono(11.5)).foregroundStyle(t.muted)
        case "ready":
            ListBox {
                ListRow(title: "Use in new renders", hint: "Photos and videos") {
                    MToggle(isOn: Binding(get: { store.lora(for: m).use }, set: { store.setLoraUse(m, $0) }))
                }
                ListRow(title: "Trained on", last: true) { MonoValue("\(l.trainedOn ?? l.kept) shots · v\(l.version)") }
            }
            MButton("Retrain with more shots", fill: true) { store.retrainLora(m) }
            MButton("Test it in Photo", kind: .primary, size: .big) {
                store.selectModel(m)
                store.openPhoto(model: m.id)
            }
            Muted("Retraining makes v\(l.version + 1). v\(l.version) stays in use until the new one is ready, and older versions are kept.")
        default:
            (Text("A LoRA is a small add-on trained on one model. It keeps her ") + Text("face and physique").bold()
                + Text(" the same in every photo and video, beyond what \(max(1, m.filled)) reference shots can hold."))
                .font(t.body(13))
                .fixedSize(horizontal: false, vertical: true)
            info
            MButton("Build training set · \(PhotoPricing.label(store.loraSetEstimate))", kind: .primary, size: .big) { store.buildTrainingSet(m) }
            Muted("About \(Pricing.money(store.loraSetEstimate + LoraPricing.trainCost)) in all: about \(Pricing.money(store.loraSetEstimate)) for the training set and \(Pricing.money(LoraPricing.trainCost)) to train. Estimates until we've measured a real run.")
        }
    }

    private func est(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Lbl(label)
            Text(value).font(t.mono(14, .medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bar(_ name: String, _ p: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).font(t.body(13))
                Spacer()
                Text("\(Int(p.rounded()))%").font(t.mono(11.5))
            }
            ProgressLine(value: p / 100)
        }
    }
}

/// One training shot (`.lt`): click to keep or drop. Dropped shots go grey; flagged ones carry an amber tag.
struct CandidateTile: View {
    @Environment(\.theme) private var t
    var candidate: LoraCandidate
    var action: () -> Void

    var body: some View {
        let c = candidate
        Button(action: action) {
            Media(ref: c.image, ratio: 0.75)
                .grayscale(c.keep ? 0 : 1)
                .brightness(c.keep ? 0 : -0.35)
                .overlay(alignment: .topTrailing) {
                    ZStack {
                        Circle().fill(c.keep ? t.accent : .white)
                        if c.keep {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(t.accentInk)
                        } else {
                            Text("✕").font(.system(size: 11, weight: .bold)).foregroundStyle(Color(hex: 0x111111))
                        }
                    }
                    .frame(width: 22, height: 22)
                    .padding(6)
                }
                .overlay(alignment: .bottomLeading) {
                    if let f = c.flag {
                        Text(f).font(.system(size: 11, weight: .bold)).foregroundStyle(Color(hex: 0x6B3F00))
                            .padding(.horizontal, 7).padding(.vertical, 1)
                            .background(Capsule().fill(Color(hex: 0xF6E2C0)))
                            .padding(6)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(c.label + (c.flag.map { " · flagged: \($0)" } ?? ""))
    }
}

// MARK: Post sheet

struct PostSheetView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        if let d = store.postDraft {
            let model = store.models.first { $0.id == d.modelId }
            let take = store.takes.first { $0.id == d.takeId }
            let connected = store.accounts(for: model).map(\.platform)
            let suggestions = PostTime.suggestions()
            ZStack {
                Color.black.opacity(0.38).onTapGesture { withAnimation { store.postDraft = nil } }
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Eyebrow(model?.shortName ?? "Model").styled()
                            Text(t.headingsUppercase ? "POST" : "Post").font(t.isA ? Fonts.font("Instrument Serif", 48, .regular) : t.display(32, t.isD ? .heavy : .bold))
                        }
                        Spacer()
                        IconButton(systemName: "xmark", help: "Close") { withAnimation { store.postDraft = nil } }
                    }
                    HStack(alignment: .top, spacing: 22) {
                        Media(ref: take?.thumb, caption: take?.caption).frame(width: 170)
                        VStack(alignment: .leading, spacing: 16) {
                            Field("Post to") {
                                VStack(alignment: .leading, spacing: 8) {
                                    if !connected.isEmpty {
                                        FlowLayout {
                                            ForEach(connected) { p in platformChip(p, on: d.platforms.contains(p)) }
                                        }
                                    } else {
                                        Muted("No accounts connected yet.")
                                    }
                                    if connected.count < Platform.allCases.count {
                                        LinkText(connected.isEmpty ? "+ Connect \(model?.shortName ?? "her")'s accounts" : "+ Connect more accounts") { store.connectFromPostSheet() }
                                    }
                                }
                            }
                            Field("Caption") {
                                TextBox(placeholder: "Write a caption and hashtags", text: Binding(get: { store.postDraft?.caption ?? "" }, set: { store.postDraft?.caption = $0 }), lines: 3)
                            }
                            ListBox {
                                ListRow(title: "Mark as AI-generated", hint: labelHint("Turns on the platform's own AI label", d.platforms.filter { !$0.hasAILabel })) {
                                    MToggle(isOn: Binding(get: { store.postDraft?.aiLabel ?? false }, set: { store.postDraft?.aiLabel = $0 }))
                                }
                                ListRow(title: "Paid partnership", hint: labelHint("Turns on the platform's branded-content tag", d.platforms.filter { !$0.hasPaidLabel }), last: true) {
                                    MToggle(isOn: Binding(get: { store.postDraft?.paidPartnership ?? false }, set: { store.postDraft?.paidPartnership = $0 }))
                                }
                            }
                            Field("When") {
                                VStack(alignment: .leading, spacing: 10) {
                                    Seg([(false, "Now"), (true, "Schedule")], selection: Binding(get: { store.postDraft?.schedule ?? false }, set: { store.postDraft?.schedule = $0 }))
                                        .frame(width: 300)
                                    if d.schedule {
                                        FlowLayout {
                                            ForEach(suggestions, id: \.self) { s in
                                                Chip(PostTime.label(s), on: abs(d.when.timeIntervalSince(s)) < 30) { store.postDraft?.when = s }
                                            }
                                        }
                                        DatePicker("Or pick a time", selection: Binding(get: { store.postDraft?.when ?? Date() }, set: { store.postDraft?.when = $0 }),
                                                   in: Date()..., displayedComponents: [.date, .hourAndMinute])
                                            .datePickerStyle(.compact)
                                            .font(t.body(12))
                                            .fixedSize()
                                        Muted("We'll notify you at that time and open each app with the post ready.")
                                    }
                                }
                            }
                        }
                    }
                    HStack {
                        Muted("For now MUSE opens each app (or its upload page) with your video saved and the caption copied. You press Post there.")
                        Spacer(minLength: 16)
                        MButton("Cancel") { withAnimation { store.postDraft = nil } }
                        MButton(d.schedule ? "Schedule · \(PostTime.label(d.when))" : "Post to \(d.platforms.count) account\(d.platforms.count == 1 ? "" : "s")",
                                kind: .primary, off: d.platforms.isEmpty || d.busy) { store.submitPost() }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 26)
                .frame(width: 820)
                .background(RoundedRectangle(cornerRadius: t.rLg).fill(t.bg))
                .overlay(RoundedRectangle(cornerRadius: t.rLg).strokeBorder(t.strongLine, lineWidth: t.lineWidth))
                .modifier(ThemeShadow(kind: .card, radius: t.rLg))
                .shadow(color: .black.opacity(0.35), radius: 40, y: 30)
            }
        }
    }

    /// The hint, plus which selected platforms have no such field (socials.md: "the toggle shows as unavailable for that platform").
    private func labelHint(_ base: String, _ missing: [Platform]) -> String {
        missing.isEmpty ? base : "\(base) · not available on \(missing.map(\.label).joined(separator: ", "))"
    }

    private func platformChip(_ p: Platform, on: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: t.isA ? 0 : 16, style: .continuous)
        return Button {
            store.togglePostPlatform(p)
        } label: {
            HStack(spacing: 6) {
                PlatformBadge(platform: p, size: 18)
                Text(p.label).font(t.body(13, on ? .semibold : .regular))
            }
            .foregroundStyle(t.ink)
            .padding(.leading, 6).padding(.trailing, 12)
            .frame(height: 32)
            .background(shape.fill(on ? t.accent.opacity(0.14) : t.surface))
            .overlay(shape.strokeBorder(on ? t.accent : t.line, lineWidth: on ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
    }
}

// MARK: Posts page

struct PostsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        @Bindable var store = store
        let list = store.postTab == .scheduled ? store.scheduledPosts : store.postedPosts
        let m = store.currentModel
        Page {
            PageHeader(eyebrow: "Social", title: "Posts") {
                Seg([(PostTab.scheduled, "Scheduled · \(store.scheduledPosts.count)"), (PostTab.posted, "Posted · \(store.postedPosts.count)")], selection: $store.postTab)
                    .frame(width: 320)
            }
            if let m {
                // Five cards in one row left ~25 px for the name and handle at 1280 px: a wrapping grid instead.
                Lbl("\(m.shortName)'s accounts").padding(.bottom, 8)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(Platform.allCases) { p in AccountCard(model: m, platform: p, allowDisconnect: false) }
                }
                .padding(.bottom, 22)
            }
            if list.isEmpty {
                Note(icon: "sparkles", store.postTab == .scheduled ? "Nothing scheduled. Open a finished take in the Gallery and click Post." : "Nothing posted yet.")
            } else {
                LazyVStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Color.clear.frame(width: 44, height: 1)
                        Lbl("Post").frame(maxWidth: .infinity, alignment: .leading)
                        Lbl("Accounts").frame(width: 150, alignment: .leading)
                        Lbl(store.postTab == .scheduled ? "When" : "Results").frame(width: 300, alignment: .leading)
                        Lbl("Labels").frame(width: 110, alignment: .leading)
                        Color.clear.frame(width: 34, height: 1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    Rectangle().fill(t.strongLine).frame(height: t.lineWidth)
                    ForEach(list) { p in PostRow(post: p) }
                }
            }
            Muted("For now MUSE opens each app (or its upload page) with your video and caption ready. Direct posting and auto-scheduling switch on per platform once it approves MUSE.")
                .padding(.top, 16)
        }
        .task { await store.loadPostsIfStale() }
    }
}

struct PostRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var post: Post

    var body: some View {
        let p = post
        let take = store.take(for: p)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Media(ref: take?.thumb ?? p.thumb, ratio: 44.0 / 58.0, radius: t.isA ? 0 : 6).frame(width: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(take?.caption ?? (p.title.isEmpty ? "Take" : p.title)).font(t.body(14, .bold)).lineLimit(1)
                    Muted(p.caption.isEmpty ? "No caption" : p.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) { ForEach(p.platforms) { PlatformBadge(platform: $0, size: 20) } }
                    .frame(width: 150, alignment: .leading)
                Group {
                    if p.isScheduled {
                        Text(p.scheduledDate.map { PostTime.label($0) } ?? p.when)
                    } else if let s = p.stats {
                        Text(s.line)
                    } else {
                        Text(p.state == "failed" ? "Failed" : "Opened in each app")
                    }
                }
                .font(t.mono(12))
                .frame(width: 300, alignment: .leading)
                Text([p.aiLabel ? "AI label" : "", p.paidPartnership ? "Paid" : ""].filter { !$0.isEmpty }.joined(separator: " · ").ifEmpty("—"))
                    .font(t.body(12)).foregroundStyle(t.muted)
                    .frame(width: 110, alignment: .leading)
                MoreMenu {
                    if p.isScheduled {
                        Button("Open the apps now") { store.handoff(p) }
                        Button("Cancel scheduled post", role: .destructive) { store.cancelPost(p) }
                    } else {
                        Button("Open the apps again") { store.handoff(p) }
                    }
                    if let take { Button("Open take") { store.openTake(take.id) } }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Rectangle().fill(t.line).frame(height: t.lineWidth)
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

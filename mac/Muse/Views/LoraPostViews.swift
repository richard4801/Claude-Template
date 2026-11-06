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

// MARK: Profile

struct ProfileLoraCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var model: MuseModel

    var body: some View {
        let l = store.lora(for: model)
        let untrained = l.state == "none" && l.version == 0
        SectionTitle("Identity LoRA") { Text("Keeps her face and build the same everywhere").scaled(t.scale.caption, t.roles.ink2) }
        HStack(spacing: Space.s4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.loraLine(l)).scaled(t.scale.label, t.roles.ink)
                Text(l.version > 0 && l.state == "ready"
                     ? "Trained on \(l.trainedOn ?? l.kept) shots you approved"
                     : "Train a photo and a video LoRA from \(LoraPricing.candidates) shots you approve, about \(Pricing.money(store.loraSetEstimate + LoraPricing.trainCost))")
                    .scaled(t.scale.caption, t.roles.ink2)
            }
            Spacer(minLength: Space.s2)
            if l.state == "training" { RProgress(value: l.progress / 100).frame(width: 120) }
            RButton(untrained ? "Set up LoRA" : "Open LoRA", small: true) { store.openLora(model.id) }
        }
    }
}

struct ProfileAccounts: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var model: MuseModel

    var body: some View {
        let connected = store.accounts(for: model).count
        SectionTitle("Accounts") { Text("\(connected) of \(Platform.allCases.count) connected").scaled(t.scale.caption, t.roles.ink2) }
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s5), count: 3), alignment: .leading, spacing: Space.s3) {
            ForEach(Platform.allCases) { p in AccountCard(model: model, platform: p, allowDisconnect: true) }
        }
    }
}

/// One platform account: badge, name, handle and its action. A row on the canvas, not a card.
struct AccountCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var model: MuseModel
    var platform: Platform
    var allowDisconnect: Bool

    var body: some View {
        let a = store.account(model, platform)
        HStack(spacing: Space.s3) {
            PlatformBadge(platform: platform, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(platform.label).scaled(t.scale.label, t.roles.ink)
                Text(a?.handle ?? "Not connected").scaled(t.scale.caption, t.roles.ink2).lineLimit(1)
            }
            Spacer(minLength: Space.s1)
            if a != nil {
                if allowDisconnect { RButton("Disconnect", kind: .plain, small: true) { store.disconnect(model, platform) } }
            } else if store.isConnecting(model, platform) {
                Text("Signing in…").scaled(t.scale.caption, t.roles.ink2)
            } else {
                RButton("Connect", small: true) { store.connect(model, platform) }
            }
        }
        .frame(minHeight: 40)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                        HStack(spacing: Space.s1) {
                            Button { store.go(.models) } label: { Text("Models").foregroundStyle(t.roles.link) }.buttonStyle(.plain)
                            Text("›").foregroundStyle(t.roles.ink2)
                            Button { store.openProfile(m.id) } label: { Text(m.name).foregroundStyle(t.roles.link) }.buttonStyle(.plain)
                            Text("›").foregroundStyle(t.roles.ink2)
                            Text("Identity LoRA").foregroundStyle(t.roles.ink2)
                        }
                        .typeStep(t.scale.caption)
                        .padding(.bottom, Space.s3)
                        ScreenTitle("Identity LoRA", subtitle: m.shortName + (l.version > 0 && l.state == "ready" ? ", version \(l.version)" : ""))
                        center(m, l)
                    }
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.s5)
                    .padding(.bottom, Space.s7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
                // The inspector: one tone up from the canvas, no shadow.
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s4) { side(m, l) }
                        .padding(Space.s5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 344)
                .background(t.roles.raised)
                .overlay(alignment: .leading) { Rectangle().fill(t.roles.hairline).frame(width: 1) }
            }
        } else {
            ScreenPage {
                EmptyState("No model yet", "A LoRA is trained on one model. Make a model first.", actionTitle: "New model") { store.go(.create) }
            }
        }
    }

    private var grid: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: Space.s3), count: 6) }

    @ViewBuilder private func center(_ m: MuseModel, _ l: Lora) -> some View {
        switch l.state {
        case "building":
            SkeletonGrid(columns: 6, count: 18, ratio: 0.75, caption: false, spacing: Space.s3)
        case "review":
            HStack(alignment: .firstTextBaseline) {
                Text("\(l.kept) of \(l.candidates.count) kept").scaled(t.scale.heading, t.roles.ink)
                Spacer()
                Text("Click a shot to drop it or bring it back. \(l.flagged) were flagged for you.").scaled(t.scale.caption, t.roles.ink2)
            }
            .padding(.bottom, Space.s3)
            LazyVGrid(columns: grid, spacing: Space.s3) {
                ForEach(l.candidates) { c in CandidateTile(candidate: c) { store.toggleCandidate(m, c) } }
            }
        case "training":
            LazyVGrid(columns: grid, spacing: Space.s3) {
                ForEach(l.candidates.filter(\.keep).prefix(18)) { c in MediaFrame(ref: c.image, ratio: 0.75) }
            }
        case "ready":
            if store.isDemo {
                HStack(alignment: .top, spacing: Space.s5) {
                    MediaTile(ref: .asset("c_face"), ratio: 0.75, caption: "References only").frame(width: 280)
                    MediaTile(ref: .asset("face"), ratio: 0.75, caption: "With LoRA version \(l.version)").frame(width: 280)
                }
                Text("Same prompt and seed. The LoRA keeps her face shape, freckles and build steady across angles.")
                    .scaled(t.scale.body, t.roles.ink2).padding(.top, Space.s3)
            } else {
                // A real studio sees her own training shots, never the demo's sample art.
                let kept = l.candidates.filter(\.keep)
                if kept.isEmpty {
                    EmptyState("Version \(l.version) is ready", "Test it in Photo to see her face hold across angles.")
                } else {
                    SectionTitle("Trained on these \(kept.count) shots", top: 0)
                    LazyVGrid(columns: grid, spacing: Space.s3) {
                        ForEach(kept.prefix(18)) { c in MediaFrame(ref: c.image, ratio: 0.75) }
                    }
                }
            }
        default:
            // Her own sheet images (faded) when she has them; the neutral sample art only in demo mode or for an empty sheet.
            let own = m.slots.compactMap(\.image).prefix(6)
            if l.state == "failed" {
                ErrorState("The last training stopped", "You weren't charged for the part that failed. Build a new set to try again.")
                    .padding(.bottom, Space.s3)
            }
            LazyVGrid(columns: grid, spacing: Space.s3) {
                if own.isEmpty {
                    ForEach(Array(["g_front", "g_tq", "face", "c_front", "g_side", "profile"].enumerated()), id: \.offset) { _, k in
                        MediaFrame(ref: store.isDemo ? ImageRef.asset(k) : nil, ratio: 0.75).opacity(0.35)
                    }
                } else {
                    ForEach(Array(own.enumerated()), id: \.offset) { _, img in
                        MediaFrame(ref: img, ratio: 0.75).opacity(0.35)
                    }
                }
            }
            Text("We make \(LoraPricing.candidates) varied shots from her character sheet: new angles, outfits, light and expressions, with full-body shots so her build is learned too. You keep the ones that look like her.")
                .scaled(t.scale.body, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.top, Space.s4)
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            SettingRow("Photo LoRA", hint: "For photos, about \(Int(LoraPricing.photoMinutes)) min, \(Pricing.money(LoraPricing.photoCost))")
            SettingRow("Video LoRA", hint: "For videos, about \(Int(LoraPricing.videoMinutes)) min, \(Pricing.money(LoraPricing.videoCost))")
        }
    }

    @ViewBuilder private func side(_ m: MuseModel, _ l: Lora) -> some View {
        switch l.state {
        case "building":
            Text("Making \(LoraPricing.candidates) shots…").scaled(t.scale.label, t.roles.ink)
            info
            RButton("Making shots…", kind: .action, fill: true, off: true) {}
        case "review":
            let enough = l.kept >= LoraPricing.minKept
            let cost = LoraPricing.trainCost
            HStack {
                Text("\(l.kept) kept").scaled(t.scale.heading, t.roles.ink)
                Spacer()
                Text(enough ? "Enough to train" : "Keep at least \(LoraPricing.minKept)").scaled(t.scale.caption, enough ? t.roles.positive : t.roles.caution)
            }
            Text("Drop anything that doesn't look like her, or shows a tattoo, ring or choker. The LoRA learns whatever you keep.")
                .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            info
            HStack(spacing: 0) {
                est("Time", LoraPricing.timeLabel)
                est("Cost", Pricing.money(cost))
                est("After", Pricing.money(max(0, store.balance.balance - cost)))
            }
            .padding(.vertical, Space.s2)
            if !enough {
                RButton("Keep \(LoraPricing.minKept - l.kept) more to train", kind: .action, fill: true, off: true) { store.trainLora(m) }
            } else if cost > store.balance.balance + 1e-9 {
                InlineNotice(store.isMember ? store.notEnoughMessage : "Not enough balance to train.", tone: .caution,
                             actionTitle: store.isMember ? nil : "Add credit") { store.go(.credits) }
                RButton("Train both LoRAs · \(Pricing.money(cost))", kind: .action, fill: true, off: true) { store.trainLora(m) }
            } else {
                RButton("Train both LoRAs · \(Pricing.money(cost))", kind: .action, fill: true) { store.trainLora(m) }
            }
        case "training":
            Text("Training on \(l.kept) shots").scaled(t.scale.heading, t.roles.ink)
            Text("You can keep working. We'll notify you when it's done.").scaled(t.scale.caption, t.roles.ink2)
            bar("Photo LoRA", l.photo.progress > 0 || l.progress == 0 ? l.photo.progress : LoraPricing.photoProgress(l.progress))
            bar("Video LoRA", l.video.progress > 0 || l.progress == 0 ? l.video.progress : LoraPricing.videoProgress(l.progress))
            Text(LoraPricing.timeLeftLine(progress: l.progress, demo: store.isDemo)).monospacedDigit().scaled(t.scale.caption, t.roles.ink2)
        case "ready":
            SettingRow("Use in new renders", hint: "Photos and videos") {
                RSwitch(label: "Use in new renders", isOn: Binding(get: { store.lora(for: m).use }, set: { store.setLoraUse(m, $0) }))
            }
            SettingRow("Trained on") { RowValue("\(l.trainedOn ?? l.kept) shots, version \(l.version)") }
            RButton("Test it in Photo", kind: .action, fill: true) {
                store.selectModel(m)
                store.openPhoto(model: m.id)
            }
            RButton("Retrain with more shots", fill: true) { store.retrainLora(m) }
            Text("Retraining makes version \(l.version + 1). Version \(l.version) stays in use until the new one is ready, and older versions are kept.")
                .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
        default:
            (Text("A LoRA is a small add-on trained on one model. It keeps her ") + Text("face and build").bold()
                + Text(" the same in every photo and video, beyond what \(max(1, m.filled)) reference shots can hold."))
                .scaled(t.scale.body, t.roles.ink)
                .fixedSize(horizontal: false, vertical: true)
            info
            RButton("Build training set · \(Pricing.money(store.loraSetEstimate))", kind: .action, fill: true) { store.buildTrainingSet(m) }
            Text("About \(Pricing.money(store.loraSetEstimate + LoraPricing.trainCost)) in all: about \(Pricing.money(store.loraSetEstimate)) for the training set and \(Pricing.money(LoraPricing.trainCost)) to train. Estimates until we've measured a real run.")
                .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func est(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).scaled(t.scale.caption, t.roles.ink2)
            Text(value).monospacedDigit().scaled(t.scale.heading, t.roles.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bar(_ name: String, _ p: Double) -> some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            HStack {
                Text(name).scaled(t.scale.caption, t.roles.ink)
                Spacer()
                Text("\(Int(p.rounded()))%").monospacedDigit().scaled(t.scale.caption, t.roles.ink2)
            }
            RProgress(value: p / 100)
        }
    }
}

/// One training shot: click to keep or drop. Dropped shots go grey; flagged ones carry a caution tag.
struct CandidateTile: View {
    @Environment(\.theme) private var t
    var candidate: LoraCandidate
    var action: () -> Void

    var body: some View {
        let c = candidate
        Button(action: action) {
            MediaFrame(ref: c.image, ratio: 0.75) {
                if let f = c.flag { StateTag(f, .onMedia) }
            }
            .grayscale(c.keep ? 0 : 1)
            .brightness(c.keep ? 0 : -0.35)
            .overlay(alignment: .topTrailing) {
                Image(systemName: c.keep ? "checkmark" : "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(c.keep ? (t.isD ? Color.white : t.roles.canvas) : Color(hex: 0x111111))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(c.keep ? t.roles.selection : Color.white))
                    .padding(Space.s2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(c.label + (c.flag.map { ", flagged: \($0)" } ?? "") + (c.keep ? ". Click to drop it." : ". Click to keep it."))
        .accessibilityLabel(c.label)
        .accessibilityValue(c.keep ? "Kept" : "Dropped")
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
                VStack(alignment: .leading, spacing: Space.s5) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Post").scaled(t.scale.title, t.roles.ink).accessibilityAddTraits(.isHeader)
                            Text(model.map { "To \($0.shortName)'s accounts" } ?? "To her accounts").scaled(t.scale.caption, t.roles.ink2)
                        }
                        Spacer()
                        RIconButton(systemName: "xmark", help: "Close") { withAnimation { store.postDraft = nil } }
                    }
                    HStack(alignment: .top, spacing: Space.s5) {
                        MediaTile(ref: take?.thumb, caption: take?.caption).frame(width: 160)
                        VStack(alignment: .leading, spacing: Space.s4) {
                            RField("Post to") {
                                VStack(alignment: .leading, spacing: Space.s2) {
                                    if !connected.isEmpty {
                                        FlowLayout(spacing: Space.s2) {
                                            ForEach(connected) { p in platformChip(p, on: d.platforms.contains(p)) }
                                        }
                                    } else {
                                        Text("No accounts connected yet.").scaled(t.scale.caption, t.roles.ink2)
                                    }
                                    if connected.count < Platform.allCases.count {
                                        RButton(connected.isEmpty ? "Connect \(model?.shortName ?? "her")'s accounts" : "Connect more accounts", kind: .plain, small: true) {
                                            store.connectFromPostSheet()
                                        }
                                    }
                                }
                            }
                            RField("Caption") {
                                RTextBox(placeholder: "Write a caption and hashtags", text: Binding(get: { store.postDraft?.caption ?? "" }, set: { store.postDraft?.caption = $0 }), lines: 3)
                            }
                            VStack(alignment: .leading, spacing: Space.s1) {
                                SettingRow("Mark as AI-generated", hint: labelHint("Turns on the platform's own AI label", d.platforms.filter { !$0.hasAILabel })) {
                                    RSwitch(label: "Mark as AI-generated", isOn: Binding(get: { store.postDraft?.aiLabel ?? false }, set: { store.postDraft?.aiLabel = $0 }))
                                }
                                SettingRow("Paid partnership", hint: labelHint("Turns on the platform's branded-content tag", d.platforms.filter { !$0.hasPaidLabel })) {
                                    RSwitch(label: "Paid partnership", isOn: Binding(get: { store.postDraft?.paidPartnership ?? false }, set: { store.postDraft?.paidPartnership = $0 }))
                                }
                            }
                            RField("When") {
                                VStack(alignment: .leading, spacing: Space.s3) {
                                    RSeg([(false, "Now"), (true, "Schedule")], selection: Binding(get: { store.postDraft?.schedule ?? false }, set: { store.postDraft?.schedule = $0 }))
                                        .frame(width: 240)
                                    if d.schedule {
                                        FlowLayout(spacing: Space.s2) {
                                            ForEach(suggestions, id: \.self) { s in
                                                ChoiceChip(PostTime.label(s), on: abs(d.when.timeIntervalSince(s)) < 30) { store.postDraft?.when = s }
                                            }
                                        }
                                        DatePicker("Or pick a time", selection: Binding(get: { store.postDraft?.when ?? Date() }, set: { store.postDraft?.when = $0 }),
                                                   in: Date()..., displayedComponents: [.date, .hourAndMinute])
                                            .datePickerStyle(.compact)
                                            .font(t.scale.caption.font)
                                            .fixedSize()
                                        Text("We'll notify you at that time and open each app with the post ready.").scaled(t.scale.caption, t.roles.ink2)
                                    }
                                }
                            }
                        }
                    }
                    HStack(spacing: Space.s3) {
                        Text("MUSE opens each app (or its upload page) with your video saved and the caption copied. You press Post there.")
                            .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Space.s4)
                        RButton("Cancel", kind: .plain) { withAnimation { store.postDraft = nil } }
                            .keyboardShortcut(.cancelAction)
                        RButton(d.schedule ? "Schedule · \(PostTime.label(d.when))" : "Post to \(ScreenCopy.count(d.platforms.count, "account"))",
                                kind: .action, off: d.platforms.isEmpty || d.busy) { store.submitPost() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(Space.s6)
                .frame(width: 820)
                .background(RoundedRectangle(cornerRadius: t.radii.container, style: .continuous).fill(t.roles.raised))
                .museFloat(t)
            }
        }
    }

    /// The hint, plus which selected platforms have no such field (socials.md: "the toggle shows as unavailable for that platform").
    private func labelHint(_ base: String, _ missing: [Platform]) -> String {
        missing.isEmpty ? base : "\(base). Not available on \(missing.map(\.label).joined(separator: ", "))."
    }

    private func platformChip(_ p: Platform, on: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: t.radii.chip, style: .continuous)
        return Button {
            store.togglePostPlatform(p)
        } label: {
            HStack(spacing: Space.s2) {
                PlatformBadge(platform: p, size: 18)
                Text(p.label).font(t.scale.label.font)
            }
            .foregroundStyle(on ? t.roles.ink : t.roles.ink2)
            .padding(.leading, Space.s1).padding(.trailing, Space.s3)
            .frame(height: 28)
            .background(shape.fill(t.roles.field))
            .overlay(shape.strokeBorder(t.roles.selection, lineWidth: on ? 2 : 0))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
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
        ScreenPage {
            ScreenTitle("Posts") {
                RSeg([(PostTab.scheduled, "Scheduled \(store.scheduledPosts.count)"), (PostTab.posted, "Posted \(store.postedPosts.count)")], selection: $store.postTab)
                    .frame(width: 260)
            }
            if let m {
                SectionTitle("\(m.shortName)'s accounts", top: 0)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: Space.s5)], alignment: .leading, spacing: Space.s3) {
                    ForEach(Platform.allCases) { p in AccountCard(model: m, platform: p, allowDisconnect: false) }
                }
            }
            SectionTitle(store.postTab == .scheduled ? "Scheduled" : "Posted")
            if list.isEmpty {
                if store.postTab == .scheduled {
                    EmptyState("Nothing scheduled", "Open a finished take and choose Post to schedule it here.", actionTitle: "Open gallery") { store.go(.gallery) }
                } else {
                    EmptyState("Nothing posted yet", "Posts you hand off to the apps show up here with their results.")
                }
            } else {
                LazyVStack(spacing: 0) {
                    HStack(spacing: Space.s3) {
                        Color.clear.frame(width: 44, height: 1)
                        Text("Post").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Accounts").frame(width: 150, alignment: .leading)
                        Text(store.postTab == .scheduled ? "When" : "Results").frame(width: 300, alignment: .leading)
                        Text("Labels").frame(width: 110, alignment: .leading)
                        Color.clear.frame(width: 34, height: 1)
                    }
                    .scaled(t.scale.caption, t.roles.ink2)
                    .padding(.horizontal, Space.s3)
                    .padding(.bottom, Space.s2)
                    ForEach(list) { p in PostRow(post: p) }
                }
            }
            Text("For now MUSE opens each app (or its upload page) with your video and caption ready. Direct posting and auto-scheduling switch on per platform once it approves MUSE.")
                .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.s5)
        }
        .task { await store.loadPostsIfStale() }
    }
}

struct PostRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var post: Post
    @State private var hover = false

    var body: some View {
        let p = post
        let take = store.take(for: p)
        HStack(spacing: Space.s3) {
            MediaFrame(ref: take?.thumb ?? p.thumb, ratio: 44.0 / 58.0).frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(take?.caption ?? (p.title.isEmpty ? "Take" : p.title)).scaled(t.scale.label, t.roles.ink).lineLimit(1)
                Text(p.caption.isEmpty ? "No caption" : p.caption).scaled(t.scale.caption, t.roles.ink2).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Space.s1) { ForEach(p.platforms) { PlatformBadge(platform: $0, size: 20) } }
                .frame(width: 150, alignment: .leading)
            Group {
                if p.isScheduled {
                    Text(p.scheduledDate.map { PostTime.label($0) } ?? p.when).monospacedDigit().foregroundStyle(t.roles.ink)
                } else if let s = p.stats {
                    Text(s.line).monospacedDigit().foregroundStyle(t.roles.ink)
                } else if p.state == "failed" {
                    Text("Failed").foregroundStyle(t.roles.danger)
                } else {
                    Text("Opened in each app").foregroundStyle(t.roles.ink2)
                }
            }
            .typeStep(t.scale.caption)
            .frame(width: 300, alignment: .leading)
            Text([p.aiLabel ? "AI label" : "", p.paidPartnership ? "Paid" : ""].filter { !$0.isEmpty }.joined(separator: ", ").ifEmpty("—"))
                .scaled(t.scale.caption, t.roles.ink2)
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
        .padding(.horizontal, Space.s3)
        .padding(.vertical, Space.s2)
        .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(hover ? t.roles.field.opacity(0.6) : .clear))
        .onHover { hover = $0 }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

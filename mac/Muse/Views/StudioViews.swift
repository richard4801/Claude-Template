import AppKit
import MuseCore
import SwiftUI

// Credit, Members (owner) and Settings → Studio (owner). Everything is shown in US dollars; the API's whole tokens
// ($0.01 each) only appear on the wire. Talks to the real API's wallets, members and settings
// (plans/api.md, "Balance and wallets" and "Settings"); demo mode has the same screens with demo members.

/// "Credit". Members see their balance; the owner also sees the studio balance (owner-loaded top-ups), what's available to send,
/// and records top-ups (plans/api.md "App clean-up" §4).
struct CreditsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t

    var body: some View {
        let b = store.balance
        let w = store.wallet
        Page {
            PageHeader(eyebrow: store.isOwner ? "Studio owner" : "Wallet", title: "Credit") {
                if store.isOwner { MButton("Send credit", icon: "paperplane", kind: .primary) { store.go(.members) } }
            }
            HStack(spacing: 14) {
                KPI(label: store.isOwner ? "Available" : "Balance", value: Pricing.money(store.creditUsd), hint: "≈ \(Pricing.videosLeft(store.creditUsd)) Draft videos", index: 0)
                KPI(label: "Held by running jobs", value: Pricing.money(w?.heldUsd ?? b.heldUsd), index: 1)
                KPI(label: "Today", value: Pricing.money(store.todaySpent), hint: "of \(Pricing.money(b.perDayLimit)) cap", index: 2)
                KPI(label: "This month", value: Pricing.money(b.month), index: 3)
            }
            if store.isOwner {
                StudioBalanceSection()
            } else if store.isMember {
                Note(icon: "dollarsign.circle", "Your credit comes from the studio owner. A render holds its price when it starts and settles to the exact cost when it's done; a failed render gives everything back. Need more? Ask the studio owner.")
                    .padding(.top, 18)
            }
            SectionHeader("Recent spend")
            // UX audit M4-38: the newest 20 renders, a Photos row only when there are photos, and an empty state.
            let photos = store.takes.filter { !$0.isVideo }
            if myJobs.isEmpty && photos.isEmpty {
                Note(icon: "clock", "Nothing spent yet. Renders and photos show here as they finish.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(myJobs.prefix(20))) { j in
                        spendRow(j.title + (j.isFailed ? " (failed)" : ""), j.isFailed ? "Refunded" : j.engineName,
                                 j.isFailed ? "+\(Pricing.money(j.refunded))" : "−\(Pricing.money(j.cost))")
                    }
                    if !photos.isEmpty {
                        spendRow("Photos", photos.count == 1 ? "1 photo" : "\(photos.count) photos", "−\(Pricing.money(photos.reduce(0) { $0 + $1.cost }))")
                    }
                }
            }
        }
        .task { await store.loadStudioIfStale() }
    }

    private var myJobs: [Job] {
        store.jobs.filter { !$0.isQueued && (!store.isMember || $0.userId == nil || $0.userId == store.user?.id) }
    }

    private func spendRow(_ a: String, _ b: String, _ c: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(a).frame(maxWidth: .infinity, alignment: .leading)
                Text(b).foregroundStyle(t.muted).frame(width: 260, alignment: .leading)
                Text(c).font(t.mono(13)).frame(width: 100, alignment: .trailing)
            }
            .font(t.body(14))
            .padding(12)
            Rectangle().fill(t.isD ? Color(hex: 0x111111) : t.line).frame(height: t.lineWidth)
        }
    }
}

/// The owner's studio balance: what's loaded, what's been spent, what members hold, and recording top-ups.
struct StudioBalanceSection: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var amount = ""
    @State private var note = ""
    @State private var paidAt = Date()

    var body: some View {
        let sb = store.studioBalance
        let w = store.wallet
        let b = store.balance
        SectionHeader("Studio balance")
        if sb?.needsFirstTopUp ?? (b.needsFirstTopUp ?? false) {
            Note(icon: "plus.circle", warn: true, "Add your first top-up. Record what you've paid in, and members' renders and yours are tracked against it. Until then, what you can spend or send reads below zero.")
                .padding(.bottom, 12)
        }
        HStack(spacing: 14) {
            KPI(label: "Studio balance", value: (sb?.balanceUsd ?? b.studioBalance ?? w?.studioBalance).map(Pricing.money) ?? "—",
                hint: sb.map { "\(Pricing.money($0.toppedUpUsd)) added · \(Pricing.money($0.spentUsd)) spent" }, index: 1)
            KPI(label: "Available to send", value: (sb?.availableUsd ?? w?.availableToSend ?? b.availableToSend).map(Pricing.money) ?? "—", index: 2)
            KPI(label: "Members hold", value: (sb?.membersCreditUsd ?? w?.membersUnspentUsd).map(Pricing.money) ?? "—", index: 3)
        }
        Muted("Studio balance = what you've added, minus everything spent. Available to send = the studio balance, minus every member's unused credit, minus what running jobs hold.")
            .padding(.top, 10)
        SectionHeader("Add a top-up")
        HStack(alignment: .bottom, spacing: 10) {
            Field("Amount") {
                HStack(spacing: 4) {
                    Text("$").font(t.mono(13)).foregroundStyle(t.muted)
                    TextField("20.00", text: $amount).fieldChrome().font(t.mono(13)).frame(width: 110)
                        .onSubmit(save)
                }
            }
            .frame(width: 150)
            Field("Note (optional)") {
                TextField("e.g. Card payment", text: $note).fieldChrome().font(t.body(13))
            }
            Field("Paid on") {
                DatePicker("", selection: $paidAt, in: ...Date(), displayedComponents: .date).labelsHidden().frame(width: 130)
            }
            .frame(width: 150)
            MButton(store.topUpBusy ? "Adding…" : "Add top-up", icon: "plus", kind: .primary, off: store.topUpBusy || Pricing.parseDollars(amount) == nil) { save() }
        }
        Muted("Record money you've paid in. MUSE doesn't take payments; this keeps the studio's books.").padding(.top, 8)
        if let ups = sb?.topUps, !ups.isEmpty {
            SectionHeader("Top-ups")
            VStack(spacing: 0) {
                ForEach(ups) { u in
                    VStack(spacing: 0) {
                        HStack {
                            Text(u.line).frame(maxWidth: .infinity, alignment: .leading)
                            Text(Date(timeIntervalSince1970: Double(u.paidAt) / 1000).formatted(date: .abbreviated, time: .omitted))
                                .foregroundStyle(t.muted).frame(width: 160, alignment: .leading)
                            Text("+\(Pricing.money(u.amountUsd))").font(t.mono(13)).frame(width: 100, alignment: .trailing)
                        }
                        .font(t.body(14))
                        .padding(12)
                        Rectangle().fill(t.isD ? Color(hex: 0x111111) : t.line).frame(height: t.lineWidth)
                    }
                }
            }
        }
        HStack(spacing: 10) {
            MButton("Members", icon: "person.2") { store.go(.members) }
            MButton("Engines", icon: "server.rack") { store.openSettings(.engines) }
        }
        .padding(.top, 14)
    }

    private func save() {
        guard let v = Pricing.parseDollars(amount), v > 0 else {
            store.showToast("Type an amount first")
            return
        }
        store.addTopUp(amount: v, note: note, paidAt: Calendar.current.isDateInToday(paidAt) ? nil : paidAt) {
            amount = ""
            note = ""
            paidAt = Date()
        }
    }
}

// MARK: - Members

struct MembersView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var inviteOpen = false

    var body: some View {
        let b = store.balance
        let people = store.members.sorted { x, y in x.isOwner != y.isOwner ? x.isOwner : x.createdAt < y.createdAt }
        Page {
            PageHeader(eyebrow: "Studio", title: "Members") {
                MButton("Invite someone", icon: "envelope", kind: .primary) { inviteOpen = true }
                    .popover(isPresented: $inviteOpen, arrowEdge: .bottom) { InviteForm() }
            }
            HStack(spacing: 14) {
                KPI(label: "Studio balance", value: (store.studioBalance?.balanceUsd ?? b.studioBalance).map(Pricing.money) ?? "—", index: 0)
                KPI(label: "Available to send", value: (store.wallet?.availableToSend ?? b.availableToSend).map(Pricing.money) ?? "—", index: 1)
                KPI(label: "Members", value: "\(people.filter { !$0.isOwner }.count)", hint: "\(Pricing.money(people.filter { !$0.isOwner }.reduce(0.0) { $0 + $1.usd })) unused", index: 2)
            }
            if let inv = store.lastInvite {
                InviteCodeCard(invite: inv).padding(.top, 16)
            }
            SectionHeader(title: "People") {
                LinkText("Refresh") { store.loadMembers(force: true) }
            }
            if people.isEmpty {
                Note(icon: "person.2", "No one here yet. Invite someone: they sign up with the code and you send them credit.")
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Lbl("Person").frame(maxWidth: .infinity, alignment: .leading)
                        Lbl("Balance").frame(width: 110, alignment: .leading)
                        Lbl("Spent today · month").frame(width: 160, alignment: .leading)
                        Lbl("Daily cap").frame(width: 90, alignment: .leading)
                        Color.clear.frame(width: 150, height: 1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    Rectangle().fill(t.strongLine).frame(height: t.lineWidth)
                    ForEach(people) { m in MemberRow(member: m) }
                }
            }
            Muted("Members pay for their own renders from their balance. Amounts are rounded to the nearest cent. Taking back only moves unused credit, never what a running job holds. Switching someone off signs them out.")
                .padding(.top, 14)
        }
        .onAppear { store.loadMembers() }
    }
}

struct MemberRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var member: Member
    @State private var sendOpen = false
    @State private var backOpen = false
    @State private var capOpen = false
    @State private var hover = false

    var body: some View {
        let m = member
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(m.email).font(t.body(14, .bold)).lineLimit(1)
                        if m.isOwner { Pill("Owner", .acc) }
                        if m.disabled { Pill("Switched off", .warn) }
                    }
                    Muted(m.lastActiveAt.map { "Active \(Self.ago($0))" } ?? "Not active yet")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.isOwner ? "—" : Pricing.money(m.usd)).font(t.mono(14))
                    if !m.isOwner && m.heldTokens > 0 { Muted("\(Pricing.money(Double(m.heldTokens) * store.balance.tokenUsd)) held") }
                }
                .frame(width: 110, alignment: .leading)
                Text("\(Pricing.money(m.todayUsd)) · \(Pricing.money(m.monthUsd))").font(t.mono(12.5)).frame(width: 160, alignment: .leading)
                Text(Pricing.money(m.capPerDay)).font(t.mono(12.5)).frame(width: 90, alignment: .leading)
                    .popover(isPresented: $capOpen, arrowEdge: .bottom) {
                        CapForm(member: m) { capOpen = false }
                    }
                HStack(spacing: 4) {
                    if !m.isOwner {
                        MButton("Send", icon: "paperplane", size: .small) { sendOpen = true }
                            .popover(isPresented: $sendOpen, arrowEdge: .bottom) {
                                CreditMoveForm(title: "Send credit to \(m.email)", action: "Send", max: store.wallet?.availableToSend ?? store.balance.availableToSend) { usd, note in
                                    sendOpen = false
                                    store.sendCredit(to: m, usd: usd, note: note)
                                }
                            }
                        Color.clear.frame(width: 1, height: 1)
                            .popover(isPresented: $backOpen, arrowEdge: .bottom) {
                                CreditMoveForm(title: "Take back from \(m.email)", action: "Take back", max: m.usd) { usd, note in
                                    backOpen = false
                                    store.takeBackCredit(from: m, usd: usd, note: note)
                                }
                            }
                        MoreMenu {
                            Button("Send credit…") { sendOpen = true }
                            Button("Take back credit…") { backOpen = true }.disabled(m.usd <= 0)
                            Divider()
                            Button("Set daily cap…") { capOpen = true }
                            Button("Use the studio's daily cap") { store.setDailyCap(m, nil) }
                            Divider()
                            Button(m.disabled ? "Switch on" : "Switch off and sign out", role: m.disabled ? nil : ButtonRole.destructive) { store.setDisabled(m, !m.disabled) }
                        }
                    }
                }
                .frame(width: 150, alignment: .trailing)
            }
            .padding(12)
            .background(hover ? t.surface : .clear)
            .opacity(m.disabled ? 0.6 : 1)
            .onHover { hover = $0 }
            Rectangle().fill(t.isD ? Color(hex: 0x111111) : t.line).frame(height: t.lineWidth)
        }
    }

    static func ago(_ ms: Int64) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: Date(timeIntervalSince1970: Double(ms) / 1000), relativeTo: Date())
    }
}

/// Dollar amount + note, for Send credit and Take back. The store converts dollars to the API's whole tokens.
struct CreditMoveForm: View {
    @Environment(\.theme) private var t
    var title: String
    var action: String
    /// The most that can move, in dollars (nil = unknown).
    var max: Double?
    var submit: (Double, String) -> Void
    @State private var amount = ""
    @State private var note = ""

    private var fillMax: (() -> Void)? {
        guard let m = max else { return nil }
        return { amount = String(format: "%.2f", (m * 100).rounded(.down) / 100) }
    }

    var body: some View {
        let usd = Pricing.parseDollars(amount) ?? 0
        let over = max.map { usd > $0 + 1e-9 } ?? false
        let ok = usd >= 0.01 && !over
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(t.body(14, .bold))
            Field("Amount (US$)", trailing: max.map { "Max \(Pricing.money($0))" }, trailingAction: fillMax) {
                HStack(spacing: 4) {
                    Text("$").font(t.mono(14)).foregroundStyle(t.muted)
                    TextField("5.00", text: $amount).fieldChrome().font(t.mono(14)).onSubmit { if ok { submit(usd, note) } }
                }
            }
            HStack(spacing: 6) {
                ForEach([1.0, 5, 10, 25], id: \.self) { v in
                    Chip(Pricing.money(v), on: abs(usd - v) < 0.005) { amount = String(format: "%.2f", v) }
                }
            }
            Field("Note (optional)") {
                TextField("For this week's tests", text: $note).fieldChrome()
            }
            if over { Note(icon: "exclamationmark.triangle", warn: true, "That's more than the \(Pricing.money(max ?? 0)) available.") }
            MButton(usd > 0 ? "\(action) \(Pricing.money(usd))" : action, kind: .primary, off: !ok, fill: true) {
                if ok { submit(usd, note) }
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

struct CapForm: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var member: Member
    var done: () -> Void
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Daily cap for \(member.email)").font(t.body(14, .bold))
            Field("Dollars per day") {
                TextField(String(format: "%.2f", member.capPerDay), text: $value).fieldChrome().font(t.mono(14))
            }
            Muted("Today's spend counts running jobs too. The studio default is \(Pricing.money(store.studioSettings?.capPerUserDay ?? store.balance.perUserDayLimit ?? 10)).")
            HStack {
                MButton("Use studio default", size: .small) {
                    done()
                    store.setDailyCap(member, nil)
                }
                Spacer()
                MButton("Save", kind: .primary, size: .small) {
                    guard let v = Double(value.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)), v >= 0 else {
                        store.showToast("Enter an amount in dollars, like 5")
                        return
                    }
                    done()
                    store.setDailyCap(member, v)
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

/// POST /v1/invites: optional email (the code then only works for it) → the code, shown once, with Copy.
struct InviteForm: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var email = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Invite someone").font(t.body(14, .bold))
            Field("Their email (optional)") {
                TextField("tester@example.com", text: $email).fieldChrome().onSubmit { store.createInvite(email: email) }
            }
            Muted("With an email, the code only works for that address. Codes work once and last 14 days.")
            MButton("Create invite code", icon: "envelope", kind: .primary, fill: true) { store.createInvite(email: email) }
            if let inv = store.lastInvite { InviteCodeCard(invite: inv) }
        }
        .padding(16)
        .frame(width: 360)
    }
}

struct InviteCodeCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var invite: Invite

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Lbl("Invite code · shown once")
            HStack(spacing: 10) {
                Text(invite.code).font(t.mono(18, .medium)).textSelection(.enabled)
                Spacer()
                MButton("Copy", icon: "doc.on.doc", size: .small) { store.copy(invite.code, toast: "Invite code copied") }
                MButton("Share…", icon: "square.and.arrow.up", size: .small) { store.shareInvite(invite) }
            }
            Muted((invite.email.map { "For \($0) · " } ?? "For anyone · ") + "expires " + Date(timeIntervalSince1970: Double(invite.expiresAt) / 1000).formatted(date: .abbreviated, time: .omitted)
                + ". Share… sends the download link and the code; Copy copies the code only.")
        }
        .card(14)
    }
}

// MARK: - Settings → Studio

/// The owner's spend caps.
struct StudioSettingsSection: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var capJob = ""
    @State private var capDay = ""
    @State private var capUser = ""

    var body: some View {
        if let s = store.studioSettings {
            H2("Spend caps")
            ListBox {
                ListRow(title: "Per job", hint: "Doesn't apply to LoRA training") { capField($capJob, s.capPerJob) }
                ListRow(title: "Per person per day", hint: "The default for members; set someone's own cap in Members") { capField($capUser, s.capPerUserDay) }
                ListRow(title: "Whole studio per day", last: true) { capField($capDay, s.capPerDay) }
            }
            HStack {
                Muted("Running jobs count towards today. Owner renders and credit you send come out of the studio balance (Credit).")
                Spacer()
                MButton("Save caps", kind: .primary, size: .small) { saveCaps(s) }
            }
        } else {
            H2("Studio")
            Note(icon: "building.2", "This server has no studio settings yet. They come with the full MUSE server.")
        }
    }

    private func capField(_ text: Binding<String>, _ current: Double) -> some View {
        HStack(spacing: 4) {
            Text("$").font(t.mono(13)).foregroundStyle(t.muted)
            TextField(String(format: "%.2f", current), text: text).fieldChrome().font(t.mono(13)).frame(width: 90)
        }
    }

    private func saveCaps(_ s: StudioSettings) {
        func num(_ v: String) -> Double? { Double(v.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)) }
        let patch = StudioSettingsPatch(capPerJob: num(capJob), capPerDay: num(capDay), capPerUserDay: num(capUser))
        guard patch.capPerJob != nil || patch.capPerDay != nil || patch.capPerUserDay != nil else {
            store.showToast("Type a new cap first")
            return
        }
        store.updateStudio(patch)
        capJob = ""
        capDay = ""
        capUser = ""
        store.showToast("Caps saved")
    }
}

// MARK: - Settings → Engines (owner only: the one place provider names appear)

/// Engine status (Replicate, RunPod), which keys are set, the image engine, the add-on engine's limits, who pays start-up,
/// and Keep add-on engine ready.
struct EnginesSettingsSection: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var provider = "simulated"
    @State private var model = ""
    @State private var engineURL = ""

    var body: some View {
        if let s = store.studioSettings {
            H2("Engines")
            if let list = s.engines?.list, !list.isEmpty {
                ListBox {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, e in
                        ListRow(icon: e.id == "replicate" ? "cloud" : "server.rack", title: e.name,
                                hint: [e.usedFor, e.keySet ? "Key set" : "No key", e.message ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
                                last: i == list.count - 1) {
                            Pill(e.statusLabel, e.isProblem ? .warn : e.status == "ready" ? .good : .neutral)
                        }
                    }
                }
                Muted("Replicate renders Draft, Standard and HD video and makes photos. RunPod runs the add-ons (Edit, Fast · beta, Upscale). Keep both topped up on their own sites; MUSE tracks spending against the studio balance.")
            } else {
                Note(icon: "server.rack", "This server doesn't report engine status yet.")
            }
            H2("Add-on engine (RunPod)")
            ListBox {
                ListRow(icon: "cpu", title: "Max GPUs at once", hint: "Each Edit or Fast render gets its own H100. Over the cap, jobs wait in line.") {
                    NumStepper(value: s.maxGpus, dec: { store.updateStudio(StudioSettingsPatch(maxGpus: max(0, s.maxGpus - 1))) },
                               inc: { store.updateStudio(StudioSettingsPatch(maxGpus: min(16, s.maxGpus + 1))) })
                }
                ListRow(icon: "dollarsign.circle", title: "Who pays start-up", hint: "GPU start-up and model load before an add-on render. It's never shown to members.") {
                    Seg([("user", "The person rendering"), ("owner", "Me (studio)")], selection: Binding(get: { s.overheadPayer }, set: { _ in })) { v in
                        store.updateStudio(StudioSettingsPatch(overheadPayer: v))
                    }
                    .frame(width: 300)
                }
                ListRow(icon: "timer", title: "Turn off when idle after", hint: "Keep add-on engine ready: minutes without renders (5–120)") {
                    NumStepper(value: s.warmIdleMinutes, dec: { store.updateStudio(StudioSettingsPatch(warmIdleMinutes: max(5, s.warmIdleMinutes - 5))) },
                               inc: { store.updateStudio(StudioSettingsPatch(warmIdleMinutes: min(120, s.warmIdleMinutes + 5))) })
                }
                ListRow(icon: "timer", title: "Time limit", hint: "Keep add-on engine ready: \(WarmGpuText.duration(Double(s.warmMaxMinutes))) at most, extendable once", last: true) {
                    NumStepper(value: s.warmMaxMinutes, dec: { store.updateStudio(StudioSettingsPatch(warmMaxMinutes: max(30, s.warmMaxMinutes - 30))) },
                               inc: { store.updateStudio(StudioSettingsPatch(warmMaxMinutes: min(480, s.warmMaxMinutes + 30))) })
                }
            }
            ListBox { KeepReadyRow() }
            ImageModelsSection()
            imageEngineSection
            H2("Models")
            ListBox {
                ListRow(title: "Video", hint: "Draft (H3 Lite), Standard and HD on Replicate; Edit on RunPod") { Text("MiniMax H3").font(t.body(13)) }
                ListRow(title: "Upscale", hint: "Coming soon") { Text("SeedVR2").font(t.body(13)) }
                ListRow(title: "Lip sync", last: true) { Text("LatentSync").font(t.body(13)) }
            }
        } else {
            H2("Engines")
            Note(icon: "server.rack", "This server has no engine settings yet. They come with the full MUSE server.")
        }
    }

    @ViewBuilder private var imageEngineSection: some View {
        H2("Image engine")
        if let e = store.imageEngine {
            Muted("Makes photoshoots, outfit sets and missing sheet angles. Members only see the photos and their price.")
            HStack(spacing: 8) {
                ForEach(ImageEngine.providers) { p in
                    Chip(p.label + (e.isAvailable(p.id) ? "" : " · not set up"), on: provider == p.id) {
                        if e.isAvailable(p.id) { provider = p.id } else { store.showToast("\(p.label) isn't set up on the server yet") }
                    }
                    .opacity(e.isAvailable(p.id) ? 1 : 0.5)
                }
            }
            if provider != "simulated" {
                Field("Model") {
                    TextField(provider == "fal" ? "fal-ai/bytedance/seedream/v4/edit" : provider == "replicate" ? "black-forest-labs/flux-2-pro" : "model id", text: $model).fieldChrome().font(t.mono(13))
                }
            }
            if provider == "custom-http" {
                Field("Endpoint (https)") {
                    TextField("https://images.example.com/generate", text: $engineURL).fieldChrome().font(t.mono(13))
                }
            }
            HStack {
                Muted("Now: \(e.displayLabel)\(e.url.map { " · \($0)" } ?? "")")
                Spacer()
                MButton("Use this engine", kind: .primary, size: .small) {
                    store.setImageEngine(provider: provider, model: provider == "simulated" ? nil : model, url: provider == "custom-http" ? engineURL : nil)
                }
            }
            .onAppear { syncEngine(e) }
            .onChange(of: e) { syncEngine(e) }
        } else {
            Note(icon: "photo", "This server doesn't offer an image engine choice.")
        }
    }

    private func syncEngine(_ e: ImageEngine) {
        provider = e.provider
        model = e.provider == "simulated" ? "" : e.model
        engineURL = e.url ?? ""
    }
}

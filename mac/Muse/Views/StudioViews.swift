import AppKit
import MuseCore
import SwiftUI

// Credit, Members (owner) and Settings → Studio (owner). Everything is shown in US dollars; the API's whole tokens
// ($0.01 each) only appear on the wire. Talks to the real API's wallets, members and settings
// (plans/api.md, "Balance and wallets" and "Settings"); demo mode has the same screens with demo members.

/// "Credit". Members see their balance; the owner also sees the RunPod balance and what's available to send.
struct CreditsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var payOpen = false

    var body: some View {
        @Bindable var store = store
        let b = store.balance
        let w = store.wallet
        Page {
            PageHeader(eyebrow: store.isOwner ? "Studio owner" : "Wallet", title: "Credit") {
                if store.isOwner { MButton("Send credit", icon: "paperplane", kind: .primary) { store.go(.members) } }
            }
            HStack(spacing: 14) {
                KPI(label: "Balance", value: Pricing.money(store.creditUsd), hint: "≈ \(Pricing.videosLeft(store.creditUsd)) videos at 10 steps", index: 0)
                KPI(label: "Held by running jobs", value: Pricing.money(w?.heldUsd ?? b.heldUsd), index: 1)
                KPI(label: "Today", value: Pricing.money(store.todaySpent), hint: "of \(Pricing.money(b.perDayLimit)) cap", index: 2)
                KPI(label: "This month", value: Pricing.money(b.month), index: 3)
            }
            if store.isOwner {
                SectionHeader("Studio balance")
                HStack(spacing: 14) {
                    KPI(label: "RunPod balance", value: b.runpodBalance.map(Pricing.money) ?? "—", hint: sourceHint(b.balanceSource), index: 1)
                    KPI(label: "Available to send", value: (w?.availableToSend ?? b.availableToSend).map(Pricing.money) ?? "—", index: 2)
                    KPI(label: "Members hold", value: w?.membersUnspentUsd.map(Pricing.money) ?? "—", index: 3)
                }
                Muted("Available to send = the RunPod balance, minus every member's unused credit, minus what running jobs hold. You can't send more than that.")
                    .padding(.top, 10)
                if b.isUnavailable {
                    Note(icon: "exclamationmark.triangle", warn: true, "MUSE can't read the RunPod balance right now, so credit can't be sent. Jobs still respect the caps.").padding(.top, 10)
                }
                if store.studioSettings?.lowBalance == true {
                    Note(icon: "pause.circle", warn: true, "\(Job.pausedLine). New jobs wait until the RunPod balance is above the work in flight plus \(Pricing.money(store.studioSettings?.minRunpodBalance ?? 2)).").padding(.top, 10)
                }
                HStack(spacing: 10) {
                    MButton("Top up RunPod", icon: "arrow.up.right.square") {
                        if let u = URL(string: "https://www.runpod.io/console/user/billing") { NSWorkspace.shared.open(u) }
                    }
                    MButton("Members", icon: "person.2") { store.go(.members) }
                }
                .padding(.top, 14)
            } else if store.isMember {
                Note(icon: "dollarsign.circle", "Your credit comes from the studio owner. A render holds its price when it starts and settles to the real GPU time when it's done; a failed render gives everything back. Need more? Ask the studio owner.")
                    .padding(.top, 18)
            }
            if store.isDemo || store.wallet == nil {
                SectionHeader("Top up")
                HStack(spacing: 10) {
                    Seg([10.0, 25, 50, 100].map { ($0, "$\(Int($0))") }, selection: $store.topUpAmount).frame(width: 420)
                    MButton("Add \(Pricing.money(store.topUpAmount).replacingOccurrences(of: ".00", with: ""))", icon: "creditcard", kind: .primary) { payOpen = true }
                        .popover(isPresented: $payOpen, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach([("card", "Card · Visa / Mastercard"), ("usdt", "USDT (TRC-20)"), ("virtual", "Virtual dollar card")], id: \.0) { code, m in
                                    Button {
                                        payOpen = false
                                        store.topUp(method: code)
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: "creditcard")
                                            Text(m).font(t.body(13.5))
                                            Spacer()
                                        }
                                        .padding(.horizontal, 10)
                                        .frame(height: 36)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(6)
                            .frame(width: 260)
                        }
                }
                Muted("Payments are mocked here: no card is charged.").padding(.top, 8)
            }
            SectionHeader("Recent spend")
            VStack(spacing: 0) {
                ForEach(myJobs) { j in
                    let warm = j.warmupCost.map { " + \(Pricing.money($0)) warm-up" } ?? ""
                    spendRow(j.title + (j.isFailed ? " (failed)" : ""), j.isFailed ? "Refunded" : j.engineName + warm,
                             j.isFailed ? "+\(Pricing.money(j.refunded))" : "−\(Pricing.money(j.cost + (j.warmupCost ?? 0)))")
                }
                spendRow("Photoshoots", "\(store.takes.filter { !$0.isVideo }.count) stills", "−\(Pricing.money(store.takes.filter { !$0.isVideo }.reduce(0) { $0 + $1.cost }))")
            }
        }
        .task { await store.loadStudio() }
    }

    private var myJobs: [Job] {
        store.jobs.filter { !$0.isQueued && (!store.isMember || $0.userId == nil || $0.userId == store.user?.id) }
    }

    private func sourceHint(_ s: String?) -> String? {
        switch s {
        case "runpod": return "Read from RunPod"
        case "simulated": return "Simulated (test credit)"
        case "unavailable": return "Can't read RunPod right now"
        default: return nil
        }
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
                KPI(label: "RunPod balance", value: b.runpodBalance.map(Pricing.money) ?? "—", hint: b.balanceSource == "simulated" ? "Simulated (test credit)" : nil, index: 0)
                KPI(label: "Available to send", value: (store.wallet?.availableToSend ?? b.availableToSend).map(Pricing.money) ?? "—", index: 1)
                KPI(label: "Members", value: "\(people.filter { !$0.isOwner }.count)", hint: "\(Pricing.money(people.filter { !$0.isOwner }.reduce(0.0) { $0 + $1.usd })) unused", index: 2)
            }
            if let inv = store.lastInvite {
                InviteCodeCard(invite: inv).padding(.top, 16)
            }
            SectionHeader(title: "People") {
                LinkText("Refresh") { store.loadMembers() }
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
            Muted("Members pay for their own renders and GPU warm-up from their balance (unless you pay warm-up in Settings → Studio). Amounts are rounded to the nearest cent. Taking back only moves unused credit, never what a running job holds. Switching someone off signs them out.")
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

struct StudioSettingsSection: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var capJob = ""
    @State private var capDay = ""
    @State private var capUser = ""
    @State private var provider = "simulated"
    @State private var model = ""
    @State private var engineURL = ""
    @State private var loaded = false

    var body: some View {
        if let s = store.studioSettings {
            H2("GPUs")
            ListBox {
                ListRow(icon: "cpu", title: "Max GPUs at once", hint: "Each person gets their own H100 while they render. Over the cap, jobs wait in line.") {
                    NumStepper(value: s.maxGpus, dec: { store.updateStudio(StudioSettingsPatch(maxGpus: max(0, s.maxGpus - 1))) },
                               inc: { store.updateStudio(StudioSettingsPatch(maxGpus: min(16, s.maxGpus + 1))) })
                }
                ListRow(icon: "flame", title: "Who pays GPU warm-up", hint: "Start-up and model load on a person's own GPU. It shows as its own line on each job.", last: true) {
                    Seg([("user", "The person rendering"), ("owner", "Me (studio)")], selection: Binding(get: { s.overheadPayer }, set: { _ in })) { v in
                        store.updateStudio(StudioSettingsPatch(overheadPayer: v))
                    }
                    .frame(width: 300)
                }
            }
            H2("Spend caps")
            ListBox {
                ListRow(title: "Per job", hint: "Doesn't apply to LoRA training") { capField($capJob, s.capPerJob) }
                ListRow(title: "Per person per day", hint: "The default for members; set someone's own cap in Members") { capField($capUser, s.capPerUserDay) }
                ListRow(title: "Whole studio per day", last: true) { capField($capDay, s.capPerDay) }
            }
            HStack {
                Muted("Running jobs count towards today. New jobs pause when the RunPod balance drops below the work in flight plus \(Pricing.money(s.minRunpodBalance)).")
                Spacer()
                MButton("Save caps", kind: .primary, size: .small) { saveCaps(s) }
            }
            if s.lowBalance { Note(icon: "pause.circle", warn: true, "\(Job.pausedLine). Top up RunPod and jobs resume by themselves.") }
            imageEngineSection
        } else {
            H2("Studio")
            Note(icon: "building.2", "This server has no studio settings. They come with the MUSE server (server/api).")
        }
    }

    @ViewBuilder private var imageEngineSection: some View {
        H2("Image engine")
        if let e = store.imageEngine {
            Muted("Makes photoshoots, outfit sets and missing sheet angles. Video renders always use MiniMax H3 on the GPU.")
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
                    TextField(provider == "fal" ? "fal-ai/bytedance/seedream/v4/edit" : "model id", text: $model).fieldChrome().font(t.mono(13))
                }
            }
            if provider == "custom-http" {
                Field("Endpoint (https)") {
                    TextField("https://images.example.com/generate", text: $engineURL).fieldChrome().font(t.mono(13))
                }
            }
            HStack {
                Muted("Now: \(ImageEngine.providers.first { $0.id == e.provider }?.label ?? e.provider) · \(e.model)\(e.url.map { " · \($0)" } ?? "")")
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

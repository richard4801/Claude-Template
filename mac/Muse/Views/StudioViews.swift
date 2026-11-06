import AppKit
import MuseCore
import SwiftUI

// Credit, Members (owner) and Settings → Studio / Engines (owner). Everything is shown in US dollars; the API's whole tokens
// ($0.01 each) only appear on the wire. Talks to the real API's wallets, members and settings
// (plans/api.md, "Balance and wallets" and "Settings"); demo mode has the same screens with demo members.
// Styled on plans/design-direction.md: plain figures on the canvas (tabular digits), sentence-case headings, rows grouped by
// space, one filled button per screen, skeletons while loading.

/// A label, a figure and an optional line under it, on the canvas (no box).
struct PlainFigure: View {
    @Environment(\.theme) private var t
    var label: String
    var value: String
    var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).scaled(t.scale.caption, t.roles.ink2).lineLimit(1)
            Text(value).monospacedDigit().scaled(t.scale.title, t.roles.ink).lineLimit(1)
            if let hint { Text(hint).scaled(t.scale.caption, t.roles.ink2).lineLimit(1) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A row of plain figures, grouped by space.
private struct FigureRow: View {
    var figures: [(String, String, String?)]

    var body: some View {
        HStack(alignment: .top, spacing: Space.s7) {
            ForEach(figures.indices, id: \.self) { i in
                PlainFigure(label: figures[i].0, value: figures[i].1, hint: figures[i].2)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Skeletons shaped like a row of figures.
private struct FigureSkeleton: View {
    var count: Int

    var body: some View {
        HStack(alignment: .top, spacing: Space.s7) {
            ForEach(0..<count, id: \.self) { _ in
                VStack(alignment: .leading, spacing: Space.s2) {
                    SkeletonBlock(width: 70, height: 10)
                    SkeletonBlock(width: 110, height: 20)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}

/// A ledger line: what, a quieter detail, and an amount on the right in tabular figures. No divider; space groups the rows.
private struct LedgerRow: View {
    @Environment(\.theme) private var t
    var title: String
    var detail: String
    var amount: String
    var amountColor: Color?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s4) {
            Text(title).scaled(t.scale.body, t.roles.ink).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(detail).scaled(t.scale.caption, t.roles.ink2).lineLimit(1).frame(width: 220, alignment: .leading)
            Text(amount).monospacedDigit().scaled(t.scale.body, amountColor ?? t.roles.ink).frame(width: 100, alignment: .trailing)
        }
        .padding(.vertical, Space.s2)
    }
}

/// A "$ 20.00" amount field with the role chrome.
private struct DollarField: View {
    @Environment(\.theme) private var t
    var placeholder: String
    @Binding var text: String
    var width: CGFloat = 110
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Space.s1) {
            Text("$").scaled(t.scale.body, t.roles.ink2)
            TextField(placeholder, text: $text)
                .focused($focused)
                .monospacedDigit()
                .onSubmit(onSubmit)
        }
        .roleField(focused: focused)
        .frame(width: width)
    }
}

/// − value + on the `field` tone, for small whole numbers.
private struct RStepper: View {
    @Environment(\.theme) private var t
    var label: String
    var value: Int
    var dec: () -> Void
    var inc: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: dec) { Ph("minus", 14).foregroundStyle(t.roles.ink).frame(width: 32, height: 32).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help("Less")
                .accessibilityLabel("Decrease \(label)")
            Text("\(value)").monospacedDigit().scaled(t.scale.body, t.roles.ink).frame(minWidth: 36)
            Button(action: inc) { Ph("plus", 14).foregroundStyle(t.roles.ink).frame(width: 32, height: 32).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help("More")
                .accessibilityLabel("Increase \(label)")
        }
        .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(t.roles.field))
        .accessibilityElement(children: .contain)
        .accessibilityValue("\(value)")
    }
}

/// "Credit". Members see their balance; the owner also sees the studio balance (owner-loaded top-ups), what's available to send,
/// and records top-ups (plans/api.md "App clean-up" §4).
struct CreditsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var loaded = false

    var body: some View {
        let b = store.balance
        let w = store.wallet
        ScreenPage(maxWidth: 960) {
            ScreenTitle("Credit", subtitle: store.isOwner ? "Your balance, the studio's balance and its top-ups" : "Your balance and what you've spent") {
                if store.isOwner { RButton("Send credit") { store.go(.members) }.help("Send credit to a member") }
            }
            if !loaded && w == nil && store.jobs.isEmpty {
                FigureSkeleton(count: 4)
            } else {
                FigureRow(figures: [
                    (store.isOwner ? "Available" : "Balance", Pricing.money(store.creditUsd), "About \(Pricing.videosLeft(store.creditUsd)) Draft videos"),
                    ("Held by running jobs", Pricing.money(w?.heldUsd ?? b.heldUsd), nil),
                    ("Today", Pricing.money(store.todaySpent), "Cap \(Pricing.money(b.perDayLimit)) a day"),
                    ("This month", Pricing.money(b.month), nil),
                ])
            }
            if store.isOwner {
                StudioBalanceSection(loaded: loaded)
            } else if store.isMember {
                Text("Your credit comes from the studio owner. A render holds its price when it starts and settles to the exact cost when it's done; a failed render gives everything back. Need more? Ask the studio owner.")
                    .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(.top, Space.s5)
            }
            SectionTitle("Recent spend")
            // UX audit M4-38: the newest 20 renders, a Photos row only when there are photos, and an empty state.
            let photos = store.takes.filter { !$0.isVideo }
            if !loaded && myJobs.isEmpty && photos.isEmpty && store.loading {
                SkeletonRows(count: 4, thumb: false)
            } else if myJobs.isEmpty && photos.isEmpty {
                EmptyState("Nothing spent yet", "Renders and photos show here, with what each one cost, as they finish.")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(myJobs.prefix(20))) { j in
                        LedgerRow(title: TakeText.displayTitle(j.title) + (j.isFailed ? " (failed)" : ""), detail: j.isFailed ? "Refunded" : j.engineName,
                                  amount: j.isFailed ? "+\(Pricing.money(j.refunded))" : "−\(Pricing.money(j.cost))",
                                  amountColor: j.isFailed ? t.roles.positive : nil)
                    }
                    if !photos.isEmpty {
                        LedgerRow(title: "Photos", detail: photos.count == 1 ? "1 photo" : "\(photos.count) photos",
                                  amount: "−\(Pricing.money(photos.reduce(0) { $0 + $1.cost }))")
                    }
                }
            }
        }
        .task {
            await store.loadStudioIfStale()
            loaded = true
        }
    }

    private var myJobs: [Job] {
        store.jobs.filter { !$0.isQueued && (!store.isMember || $0.userId == nil || $0.userId == store.user?.id) }
    }
}

/// The owner's studio balance: what's loaded, what's been spent, what members hold, and recording top-ups.
struct StudioBalanceSection: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var loaded = true
    @State private var amount = ""
    @State private var note = ""
    @State private var paidAt = Date()

    var body: some View {
        let sb = store.studioBalance
        let w = store.wallet
        let b = store.balance
        let studio = sb?.balanceUsd ?? b.studioBalance ?? w?.studioBalance
        SectionTitle("Studio balance")
        if sb?.needsFirstTopUp ?? (b.needsFirstTopUp ?? false) {
            InlineNotice("Add your first top-up. Record what you've paid in, and members' renders and yours are tracked against it. Until then, what you can spend or send reads below zero.", tone: .caution)
                .padding(.bottom, Space.s4)
        }
        if !loaded && studio == nil {
            FigureSkeleton(count: 3)
        } else if studio == nil && sb == nil {
            InlineNotice("This server doesn't report a studio balance. It comes with the full MUSE server.")
        } else {
            FigureRow(figures: [
                ("Studio balance", studio.map(Pricing.money) ?? "—", sb.map { "\(Pricing.money($0.toppedUpUsd)) added, \(Pricing.money($0.spentUsd)) spent" }),
                ("Available to send", (sb?.availableUsd ?? w?.availableToSend ?? b.availableToSend).map(Pricing.money) ?? "—", nil),
                ("Members hold", (sb?.membersCreditUsd ?? w?.membersUnspentUsd).map(Pricing.money) ?? "—", nil),
            ])
            Text("Studio balance is what you've added, minus everything spent. Available to send is the studio balance, minus every member's unused credit, minus what running jobs hold.")
                .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.top, Space.s3)
        }

        SectionTitle("Add a top-up")
        HStack(alignment: .bottom, spacing: Space.s3) {
            RField("Amount") { DollarField(placeholder: "20.00", text: $amount, onSubmit: save) }
            RField("Note", hint: "Optional") { RTextField(placeholder: "Card payment", text: $note).frame(width: 220) }
            RField("Paid on") {
                DatePicker("", selection: $paidAt, in: ...Date(), displayedComponents: .date).labelsHidden().frame(width: 130).frame(height: 32)
            }
            RButton(store.topUpBusy ? "Adding…" : "Add top-up", kind: .action, off: store.topUpBusy || Pricing.parseDollars(amount) == nil) { save() }
            Spacer(minLength: 0)
        }
        Text("Record money you've paid in. MUSE doesn't take payments; this keeps the studio's books.")
            .scaled(t.scale.caption, t.roles.ink2).padding(.top, Space.s2)
        if let ups = sb?.topUps, !ups.isEmpty {
            SectionTitle("Top-ups")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(ups) { u in
                    LedgerRow(title: u.line, detail: Date(timeIntervalSince1970: Double(u.paidAt) / 1000).formatted(date: .abbreviated, time: .omitted),
                              amount: "+\(Pricing.money(u.amountUsd))")
                }
            }
        }
        HStack(spacing: Space.s4) {
            RButton("Members", kind: .plain) { store.go(.members) }
            RButton("Engines", kind: .plain) { store.openSettings(.engines) }
        }
        .padding(.top, Space.s5)
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
    @State private var settled = false

    var body: some View {
        let b = store.balance
        let people = store.members.sorted { x, y in x.isOwner != y.isOwner ? x.isOwner : x.createdAt < y.createdAt }
        let others = people.filter { !$0.isOwner }
        ScreenPage(maxWidth: 1040) {
            ScreenTitle("Members", subtitle: "People in your studio, their credit and their daily caps") {
                RButton("Invite someone", kind: .action) { inviteOpen = true }
                    .popover(isPresented: $inviteOpen, arrowEdge: .bottom) { InviteForm() }
            }
            if people.isEmpty && !settled {
                FigureSkeleton(count: 3)
            } else if !people.isEmpty {
                FigureRow(figures: [
                    ("Studio balance", (store.studioBalance?.balanceUsd ?? b.studioBalance).map(Pricing.money) ?? "—", nil),
                    ("Available to send", (store.wallet?.availableToSend ?? b.availableToSend).map(Pricing.money) ?? "—", nil),
                    ("Members", "\(others.count)", "\(Pricing.money(others.reduce(0.0) { $0 + $1.usd })) unused"),
                ])
            }
            if let inv = store.lastInvite {
                InviteCodeCard(invite: inv).padding(.top, Space.s5)
            }
            SectionTitle("People") {
                RButton("Refresh", kind: .plain, small: true) { store.loadMembers(force: true) }
            }
            if people.isEmpty && !settled {
                SkeletonRows(count: 4, thumb: false)
            } else if people.isEmpty {
                ErrorState("Members didn't load", "The server didn't send the member list. Check your connection, then try again.", actionTitle: "Try again") {
                    store.loadMembers(force: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Space.s4) {
                        Text("Person").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Balance").frame(width: 110, alignment: .leading)
                        Text("Today").frame(width: 80, alignment: .leading)
                        Text("This month").frame(width: 90, alignment: .leading)
                        Text("Daily cap").frame(width: 80, alignment: .leading)
                        Color.clear.frame(width: 110, height: 1)
                    }
                    .scaled(t.scale.caption, t.roles.ink2)
                    .padding(.horizontal, Space.s3)
                    .padding(.bottom, Space.s2)
                    ForEach(people) { m in MemberRow(member: m) }
                }
                if others.isEmpty {
                    EmptyState("No one here yet", "Invite someone: they sign up with the code, and you send them credit.")
                }
            }
            Text("Members pay for their own renders from their balance. Amounts are rounded to the nearest cent. Taking back only moves unused credit, never what a running job holds. Switching someone off signs them out.")
                .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.top, Space.s5)
        }
        .task {
            store.loadMembers()
            await store.loadStudioIfStale()
            settled = true
        }
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
        HStack(spacing: Space.s4) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.s2) {
                    Text(m.email).scaled(t.scale.body, t.roles.ink).lineLimit(1)
                    if m.isOwner { StateTag("Owner") }
                    if m.disabled { StateTag("Switched off", .caution) }
                }
                Text(m.lastActiveAt.map { "Active \(Self.ago($0))" } ?? "Not active yet").scaled(t.scale.caption, t.roles.ink2).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.isOwner ? "—" : Pricing.money(m.usd)).monospacedDigit().scaled(t.scale.body, t.roles.ink)
                if !m.isOwner && m.heldTokens > 0 {
                    Text("\(Pricing.money(Double(m.heldTokens) * store.balance.tokenUsd)) held").monospacedDigit().scaled(t.scale.caption, t.roles.ink2)
                }
            }
            .frame(width: 110, alignment: .leading)
            Text(Pricing.money(m.todayUsd)).monospacedDigit().scaled(t.scale.body, t.roles.ink).frame(width: 80, alignment: .leading)
            Text(Pricing.money(m.monthUsd)).monospacedDigit().scaled(t.scale.body, t.roles.ink).frame(width: 90, alignment: .leading)
            Text(Pricing.money(m.capPerDay)).monospacedDigit().scaled(t.scale.body, t.roles.ink).frame(width: 80, alignment: .leading)
                .popover(isPresented: $capOpen, arrowEdge: .bottom) {
                    CapForm(member: m) { capOpen = false }
                }
            HStack(spacing: Space.s1) {
                if !m.isOwner {
                    RButton("Send", small: true) { sendOpen = true }
                        .help("Send credit to \(m.email)")
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
                    Menu {
                        Button("Send credit…") { sendOpen = true }
                        Button("Take back credit…") { backOpen = true }.disabled(m.usd <= 0)
                        Divider()
                        Button("Set daily cap…") { capOpen = true }
                        Button("Use the studio's daily cap") { store.setDailyCap(m, nil) }
                        Divider()
                        Button(m.disabled ? "Switch on" : "Switch off and sign out", role: m.disabled ? nil : ButtonRole.destructive) { store.setDisabled(m, !m.disabled) }
                    } label: {
                        Image(nsImage: Ph.menuImage("ellipsis", 16))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .frame(width: 28, height: 28)
                    .foregroundStyle(t.roles.ink)
                    .help("More for \(m.email)")
                    .accessibilityLabel("More for \(m.email)")
                }
            }
            .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, Space.s3)
        .padding(.vertical, Space.s2)
        .background(RoundedRectangle(cornerRadius: t.radii.control, style: .continuous).fill(hover ? t.roles.field.opacity(0.6) : .clear))
        .opacity(m.disabled ? 0.6 : 1)
        .onHover { hover = $0 }
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

    var body: some View {
        let usd = Pricing.parseDollars(amount) ?? 0
        let over = max.map { usd > $0 + 1e-9 } ?? false
        let ok = usd >= 0.01 && !over
        VStack(alignment: .leading, spacing: Space.s3) {
            Text(title).scaled(t.scale.heading, t.roles.ink).lineLimit(2)
            RField("Amount", hint: max.map { "Up to \(Pricing.money($0))" }) {
                HStack(spacing: Space.s2) {
                    DollarField(placeholder: "5.00", text: $amount, width: 140) { if ok { submit(usd, note) } }
                    if let m = max {
                        RButton("Use all", kind: .plain, small: true) { amount = String(format: "%.2f", (m * 100).rounded(.down) / 100) }
                    }
                }
            }
            HStack(spacing: Space.s2) {
                ForEach([1.0, 5, 10, 25], id: \.self) { v in
                    ChoiceChip(Pricing.money(v), on: abs(usd - v) < 0.005) { amount = String(format: "%.2f", v) }
                }
            }
            RField("Note", hint: "Optional") {
                RTextField(placeholder: "For this week's tests", text: $note)
            }
            if over { Text("That's more than the \(Pricing.money(max ?? 0)) available.").scaled(t.scale.caption, t.roles.danger) }
            RButton(usd > 0 ? "\(action) \(Pricing.money(usd))" : action, kind: .action, fill: true, off: !ok) {
                if ok { submit(usd, note) }
            }
        }
        .padding(Space.s4)
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
        VStack(alignment: .leading, spacing: Space.s3) {
            Text("Daily cap for \(member.email)").scaled(t.scale.heading, t.roles.ink).lineLimit(2)
            RField("Dollars per day") {
                DollarField(placeholder: String(format: "%.2f", member.capPerDay), text: $value, width: 140)
            }
            Text("Today's spend counts running jobs too. The studio default is \(Pricing.money(store.studioSettings?.capPerUserDay ?? store.balance.perUserDayLimit ?? 10)).")
                .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            HStack {
                RButton("Use studio default", kind: .plain, small: true) {
                    done()
                    store.setDailyCap(member, nil)
                }
                Spacer()
                RButton("Save cap", kind: .action, small: true) {
                    guard let v = Double(value.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)), v >= 0 else {
                        store.showToast("Enter an amount in dollars, like 5")
                        return
                    }
                    done()
                    store.setDailyCap(member, v)
                }
            }
        }
        .padding(Space.s4)
        .frame(width: 300)
    }
}

/// POST /v1/invites: optional email (the code then only works for it) → the code, shown once, with Copy.
struct InviteForm: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    @State private var email = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text("Invite someone").scaled(t.scale.heading, t.roles.ink)
            RField("Their email", hint: "Optional") {
                RTextField(placeholder: "tester@example.com", text: $email) { store.createInvite(email: email) }
            }
            Text("With an email, the code only works for that address. Codes work once and last 14 days.")
                .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            RButton("Create invite code", kind: .action, fill: true) { store.createInvite(email: email) }
            if let inv = store.lastInvite { InviteCodeCard(invite: inv) }
        }
        .padding(Space.s4)
        .frame(width: 360)
    }
}

struct InviteCodeCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var t
    var invite: Invite

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("Invite code, shown once").scaled(t.scale.caption, t.roles.ink2)
            HStack(spacing: Space.s3) {
                Text(invite.code).monospacedDigit().scaled(t.scale.title, t.roles.ink).textSelection(.enabled)
                Spacer()
                RButton("Copy", small: true) { store.copy(invite.code, toast: "Invite code copied") }
                RButton("Share…", small: true) { store.shareInvite(invite) }
            }
            Text((invite.email.map { "For \($0), " } ?? "For anyone, ") + "expires " + Date(timeIntervalSince1970: Double(invite.expiresAt) / 1000).formatted(date: .abbreviated, time: .omitted)
                + ". Share… sends the download link and the code; Copy copies the code only.")
                .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.s4)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: t.radii.container, style: .continuous).fill(t.roles.field))
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
            SectionTitle("Spend caps", top: 0)
            SettingRow("Per job", hint: "Doesn't apply to LoRA training") { DollarField(placeholder: String(format: "%.2f", s.capPerJob), text: $capJob) }
            SettingRow("Per person per day", hint: "The default for members; set someone's own cap in Members") {
                DollarField(placeholder: String(format: "%.2f", s.capPerUserDay), text: $capUser)
            }
            SettingRow("Whole studio per day") { DollarField(placeholder: String(format: "%.2f", s.capPerDay), text: $capDay) }
            HStack(alignment: .center, spacing: Space.s4) {
                Text("Running jobs count towards today. Owner renders and credit you send come out of the studio balance (Credit).")
                    .scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.s4)
                RButton("Save caps", kind: .action, small: true) { saveCaps(s) }
            }
            .padding(.top, Space.s4)
        } else if store.loading {
            SectionTitle("Spend caps", top: 0)
            SkeletonRows(count: 3, thumb: false)
        } else {
            SectionTitle("Studio", top: 0)
            EmptyState("No studio settings on this server", "Spend caps come with the full MUSE server. Point MUSE at it under Developer.",
                       actionTitle: "Open Developer") { store.settingsSection = .developer }
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
            SectionTitle("Engines", top: 0)
            if let list = s.engines?.list, !list.isEmpty {
                ForEach(list, id: \.id) { e in
                    SettingRow(e.name, hint: engineHint(e)) {
                        StateTag(e.statusLabel, e.isProblem ? .caution : e.status == "ready" ? .positive : .neutral)
                    }
                }
                caption("Replicate renders Draft, Standard and HD video and makes photos. RunPod runs the add-ons (Edit, Fast in beta, Upscale). Keep both topped up on their own sites; MUSE tracks spending against the studio balance.")
            } else {
                InlineNotice("This server doesn't report engine status yet.")
            }
            SectionTitle("Add-on engine (RunPod)")
            SettingRow("Max GPUs at once", hint: "Each Edit or Fast render gets its own H100. Over the cap, jobs wait in line.") {
                RStepper(label: "max GPUs", value: s.maxGpus, dec: { store.updateStudio(StudioSettingsPatch(maxGpus: max(0, s.maxGpus - 1))) },
                         inc: { store.updateStudio(StudioSettingsPatch(maxGpus: min(16, s.maxGpus + 1))) })
            }
            SettingRow("Who pays start-up", hint: "GPU start-up and model load before an add-on render. It's never shown to members.") {
                RSeg([("user", "The person rendering"), ("owner", "Me (studio)")], selection: Binding(get: { s.overheadPayer }, set: { _ in })) { v in
                    store.updateStudio(StudioSettingsPatch(overheadPayer: v))
                }
                .frame(width: 300)
            }
            SettingRow("Turn off when idle after", hint: "Keep add-on engine ready: minutes without renders (5–120)") {
                RStepper(label: "idle minutes", value: s.warmIdleMinutes, dec: { store.updateStudio(StudioSettingsPatch(warmIdleMinutes: max(5, s.warmIdleMinutes - 5))) },
                         inc: { store.updateStudio(StudioSettingsPatch(warmIdleMinutes: min(120, s.warmIdleMinutes + 5))) })
            }
            SettingRow("Time limit", hint: "Keep add-on engine ready: \(WarmGpuText.duration(Double(s.warmMaxMinutes))) at most, extendable once") {
                RStepper(label: "time limit in minutes", value: s.warmMaxMinutes, dec: { store.updateStudio(StudioSettingsPatch(warmMaxMinutes: max(30, s.warmMaxMinutes - 30))) },
                         inc: { store.updateStudio(StudioSettingsPatch(warmMaxMinutes: min(480, s.warmMaxMinutes + 30))) })
            }
            KeepReadyRow()
            ImageModelsSection()
            imageEngineSection
            SectionTitle("Models")
            SettingRow("Video", hint: "Draft (H3 Lite), Standard and HD on Replicate; Edit on RunPod") { RowValue("MiniMax H3") }
            SettingRow("Upscale") { RowValue("SeedVR2") }
            SettingRow("Lip sync") { RowValue("LatentSync") }
        } else if store.loading {
            SectionTitle("Engines", top: 0)
            SkeletonRows(count: 4, thumb: false)
        } else {
            SectionTitle("Engines", top: 0)
            EmptyState("No engine settings on this server", "Engine status and limits come with the full MUSE server. Point MUSE at it under Developer.",
                       actionTitle: "Open Developer") { store.settingsSection = .developer }
        }
    }

    private func engineHint(_ e: EngineStatus) -> String {
        var parts = [e.usedFor, e.keySet ? "Key set." : "No key set."]
        if let m = e.message, !m.isEmpty { parts.append(m) }
        return parts.filter { !$0.isEmpty }.map { $0.hasSuffix(".") ? $0 : $0 + "." }.joined(separator: " ")
    }

    private func caption(_ text: String) -> some View {
        Text(text).scaled(t.scale.caption, t.roles.ink2).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.top, Space.s2)
    }

    @ViewBuilder private var imageEngineSection: some View {
        SectionTitle("Image engine")
        if let e = store.imageEngine {
            caption("Makes photos, outfit sets and missing sheet angles. Members only see the photos and their price.")
                .padding(.bottom, Space.s3)
            HStack(spacing: Space.s2) {
                ForEach(ImageEngine.providers) { p in
                    ChoiceChip(p.label + (e.isAvailable(p.id) ? "" : " (not set up)"), on: provider == p.id) {
                        if e.isAvailable(p.id) { provider = p.id } else { store.showToast("\(p.label) isn't set up on the server yet") }
                    }
                    .opacity(e.isAvailable(p.id) ? 1 : 0.5)
                }
            }
            if provider != "simulated" {
                RField("Model") {
                    RTextField(placeholder: provider == "fal" ? "fal-ai/bytedance/seedream/v4/edit" : provider == "replicate" ? "black-forest-labs/flux-2-pro" : "model id", text: $model)
                        .frame(maxWidth: 460)
                }
                .padding(.top, Space.s4)
            }
            if provider == "custom-http" {
                RField("Endpoint", hint: "https") {
                    RTextField(placeholder: "https://images.example.com/generate", text: $engineURL).frame(maxWidth: 460)
                }
                .padding(.top, Space.s3)
            }
            HStack(alignment: .center, spacing: Space.s4) {
                Text("Now: \(e.displayLabel)\(e.url.map { ", \($0)" } ?? "")").scaled(t.scale.caption, t.roles.ink2).lineLimit(2)
                Spacer(minLength: Space.s4)
                RButton("Use this engine", small: true) {
                    store.setImageEngine(provider: provider, model: provider == "simulated" ? nil : model, url: provider == "custom-http" ? engineURL : nil)
                }
            }
            .padding(.top, Space.s4)
            .onAppear { syncEngine(e) }
            .onChange(of: e) { syncEngine(e) }
        } else {
            InlineNotice("This server doesn't offer an image engine choice.")
        }
    }

    private func syncEngine(_ e: ImageEngine) {
        provider = e.provider
        model = e.provider == "simulated" ? "" : e.model
        engineURL = e.url ?? ""
    }
}

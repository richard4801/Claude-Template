import Foundation
import MuseCore
import Observation

/// One Claude (plans/one-claude.md): one Claude panel on every page, with several chats. A chat is about a piece of work
/// and follows the person across pages; Claude knows the page (sent with each message and when they move) and can open
/// pages itself ("Opened … · Back"), asking first when they are in the middle of something. Everyone (the owner and each
/// member) runs Claude on their own Claude plan through Claude Code on this Mac; memory is per person, and Claude
/// saves to it only when asked, or after "Shall I remember …?" → Remember.
@MainActor
@Observable
final class OneClaudeState {
    var open = false { didSet { syncChatLink() } }
    /// The open chat (kept on this Mac).
    var chatId: String? = UserDefaults.standard.string(forKey: OneClaudeState.chatKey) { didSet { syncChatLink() } }
    /// Results arrive in the chat: while the panel shows a chat, what the person starts reports back to it.
    private func syncChatLink() { ClaudeChatLink.set(open ? chatId : nil) }
    var chats: [ClaudeChatSummary] = []
    var listError: String?
    var loadingList = false
    /// What a screen reports about itself (Edit: its session; Recreate: its reference); nil: the screen's default.
    var viewPage: ClaudePage?
    /// Claude asks to open a page: Open / Stay here.
    var askOpen: ClaudeUI?
    /// Where the person was before Claude opened a page (Back), and what it opened.
    var back: ClaudePage?
    var opened: ClaudePage?
    /// "Remembered: …" (the person asked Claude to remember).
    var remembered: ClaudeUI?
    /// "Shall I remember: …?" (Remember / No): nothing is saved until Remember.
    var suggestion: ClaudeUI?
    /// Claude's gated actions waiting for the person (Approve / Decline); nothing happens until they press.
    var approvals: [ClaudeUI] = []
    /// Paid helpers Claude asked for on ANY of the owner's edits (ci_e546642a4026): shown whichever edit is open, each
    /// naming its edit, answered here by session id.
    var editApprovals = EditApprovalList()
    var answeringEdit: Set<String> = []
    /// Cards (ChatCards.swift): Approve cards answered here ("Approved, rendering"), answers and Undos in flight.
    var answeredCards: [String: String] = [:]
    var answering: Set<String> = []
    var undoing: Set<String> = []
    /// The Suite's own Claude panel's live chips (nil: its fixed ones, SuiteAssistClaude.suggestions).
    var suiteChips: [ClaudeChip]?
    /// The quick-action chips over the composer, for the page Claude sees.
    var chips: [ClaudeChip] = ClaudeChip.fallback(page: nil, tool: nil)
    /// A job started from a card (its progress fills the activity strip until it ends).
    var watchJob: String?
    /// The server puts cards in the chat (it answered GET v1/claude/chips): its Approve cards replace the strip's.
    var serverCards = false
    /// Approve cards in the chat still waiting for the person (by message id or action id): the orb shows "waiting".
    var waitingCards: Set<String> = []
    var memory: ClaudeMemory?
    var memoryError: String?
    /// Step 6b: the models and this person's default.
    var models: ClaudeModelList?

    @ObservationIgnored var feedTask: Task<Void, Never>?
    /// Live chips (owner 2026-11-12): the pending refresh, the Edit page's facts as it sees them, the edit's assets (a new
    /// video or sound = "just imported" for two minutes) and the page the chips are for (their places stay steady there).
    @ObservationIgnored var chipsTask: Task<Void, Never>?
    @ObservationIgnored var editFacts: ClaudeSuggestQuery?
    @ObservationIgnored var editAssets: Set<String>?
    @ObservationIgnored var imported: ClaudeImported?
    @ObservationIgnored var chipsPage: String?
    @ObservationIgnored var pageTask: Task<Void, Never>?
    @ObservationIgnored var lastSentPage: ClaudePage?
    @ObservationIgnored var lastSentChat: String?

    static let chatKey = "oneClaude.chatId"
    init() {}

    var current: ClaudeChatSummary? { chats.first { $0.id == chatId } }
}

/// A video or sound that just came into the open edit (the chips offer to watch or listen to it for two minutes).
struct ClaudeImported {
    var kind: String
    var id: String
    var at: Date
}

extension AppStore {
    // MARK: The page the person is on

    /// The page as Claude sees it ("Sees: Edit, Beach reel"), with the ids it has open.
    var claudePage: ClaudePage {
        // The Camera page (Directed blocking) reports itself with its camera session.
        if let v = oneClaude.viewPage, v.name == "camera" { return v }
        if recreate.open {
            var ids: [String: String] = [:]
            if let r = recreate.reference?.id { ids["referenceId"] = r }
            if let s = recreate.claudeSessionId { ids["sessionId"] = s }
            return ClaudePage(name: "recreate", label: recreate.reference?.name, ids: ids.isEmpty ? nil : ids)
        }
        switch screen {
        case .home: return ClaudePage(name: "home")
        case .models, .create, .lora: return ClaudePage(name: "cast")
        case .profile:
            guard let m = character(profileModelId) else { return ClaudePage(name: "cast") }
            return ClaudePage(name: "character", label: m.name, ids: ["modelId": m.id])
        case .suite:
            guard suite.mode != .hub else { return ClaudePage(name: "suite") }
            let tool = suite.composer.tool.rawValue
            return ClaudePage(name: "suite", tool: tool, ids: suite.claude.assist.map { ["assistId": $0.id] })
        case .edit, .editor: return oneClaude.viewPage ?? ClaudePage(name: "edit")
        case .result: return ClaudePage(name: "take", ids: openTakeId.map { ["takeId": $0] })
        case .gallery, .posts: return ClaudePage(name: "library")
        case .queue: return ClaudePage(name: "queue")
        case .settings, .credits: return ClaudePage(name: "settings")
        case .templates, .template: return ClaudePage(name: "suite", tool: "photo")
        }
    }

    // MARK: Open, chats

    func toggleOneClaude() {
        oneClaude.open.toggle()
        if oneClaude.open {
            ClaudeCodeService.shared.clearUnseenResults()
            Task { await startOneClaude() }
        }
    }

    func showOneClaude() {
        guard !oneClaude.open else { return }
        oneClaude.open = true
        ClaudeCodeService.shared.clearUnseenResults()
        Task { await startOneClaude() }
    }

    private var oneClaudeAPI: (any ClaudeAPI)? { ClaudeCodeService.shared.api }

    func startOneClaude() async {
        listenOneClaude()
        await loadEditApprovals()
        await loadClaudeModels()
        await refreshOneClaudeChats()
        if oneClaude.chatId == nil || !oneClaude.chats.contains(where: { $0.id == oneClaude.chatId }) {
            if let first = oneClaude.chats.first { pickOneClaudeChat(first.id) } else { await newOneClaudeChat() }
        }
        await oneClaudeLinkSuite()
        oneClaudePageChanged(now: true)
    }

    func refreshOneClaudeChats() async {
        guard let api = oneClaudeAPI else { oneClaude.listError = "Sign in to your MUSE server to chat with Claude."; return }
        oneClaude.loadingList = true
        defer { oneClaude.loadingList = false }
        do {
            oneClaude.chats = try await api.chats(query: nil)
            oneClaude.listError = nil
        } catch let e as ApiError where e.code == "not_found" {
            oneClaude.listError = "This server doesn't have one Claude yet. Update the server."
        } catch {
            oneClaude.listError = "Couldn't load your chats. \((error as? ApiError)?.friendlyMessage ?? error.localizedDescription)"
        }
    }

    func newOneClaudeChat() async {
        guard let api = oneClaudeAPI, let c = try? await api.newChat(page: claudePage) else { return }
        oneClaude.chats.insert(c, at: 0)
        pickOneClaudeChat(c.id)
    }

    func pickOneClaudeChat(_ id: String) {
        oneClaude.chatId = id
        UserDefaults.standard.set(id, forKey: OneClaudeState.chatKey)
        oneClaude.askOpen = nil
        oneClaude.remembered = nil
        oneClaude.suggestion = nil
        oneClaude.approvals = []
        Task { await loadClaudeApprovals(id) }
        oneClaude.lastSentChat = nil
        oneClaudePageChanged(now: true)
    }

    func archiveOneClaudeChat(_ id: String) async {
        guard let api = oneClaudeAPI else { return }
        try? await api.archiveChat(id)
        oneClaude.chats.removeAll { $0.id == id }
        if oneClaude.chatId == id {
            if let next = oneClaude.chats.first { pickOneClaudeChat(next.id) } else { await newOneClaudeChat() }
        }
    }

    /// Delete chats (owner, 2026-11-11): by id and/or every chat not used for `olderThanDays` days. Their messages go;
    /// memory and anything made stay. What each chat left on this Mac goes too (its Claude Code session included).
    /// Deleting the open chat opens a new one. → an error to show, or nil.
    @discardableResult
    func deleteOneClaudeChats(_ ids: [String], olderThanDays: Int? = nil) async -> String? {
        guard let api = oneClaudeAPI else { return "Sign in to your MUSE server first." }
        do {
            let gone = try await api.deleteChats(ids: ids, olderThanDays: olderThanDays)
            oneClaudeForget(Set(gone))
            if oneClaude.chatId == nil || !oneClaude.chats.contains(where: { $0.id == oneClaude.chatId }) { await newOneClaudeChat() }
            return nil
        } catch {
            return (error as? ApiError)?.friendlyMessage ?? error.localizedDescription
        }
    }

    /// Chats deleted here or on another device: off the list and off this Mac.
    func oneClaudeForget(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        oneClaude.chats.removeAll { ids.contains($0.id) }
        for id in ids { ClaudeLocalSessions.forget(chatId: id) }
        if let open = oneClaude.chatId, ids.contains(open) {
            oneClaude.chatId = nil
            UserDefaults.standard.removeObject(forKey: OneClaudeState.chatKey)
        }
    }

    // MARK: Following the person

    /// The page changed (screen, Suite tool, an edit or reference opened): tell the server after a moment.
    func oneClaudePageChanged(now: Bool = false) {
        guard oneClaude.open, let id = oneClaude.chatId, let api = oneClaudeAPI else { return }
        oneClaude.pageTask?.cancel()
        oneClaude.pageTask = Task { [weak self] in
            if !now { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            guard let self, !Task.isCancelled else { return }
            await self.oneClaudeLinkSuite()
            let p = self.claudePage
            if p != self.oneClaude.lastSentPage || id != self.oneClaude.lastSentChat { await self.loadClaudeChips() }
            guard p != self.oneClaude.lastSentPage || id != self.oneClaude.lastSentChat else { return }
            try? await api.setChatPage(id, page: p)
            self.oneClaude.lastSentPage = p
            self.oneClaude.lastSentChat = id
        }
    }

    /// On the AI Suite, Claude works on the composer through a shared draft (the same one the Suite's own Claude used).
    func oneClaudeLinkSuite() async {
        guard oneClaude.open, screen == .suite, suite.mode != .hub else { return }
        suite.claude.linked = true
        guard suite.claude.assist == nil, !suite.claude.creating, let api = suiteAssistAPI else { return }
        suite.claude.creating = true
        defer { suite.claude.creating = false }
        await newSuiteAssist(api: api, key: suiteClaudeKey)
    }

    /// Each message carries the page in front (Claude Code reads it there; the title leaves it out).
    func oneClaudeOutgoing(_ text: String) -> String { "\(claudePage.contextLine)\n\(text)" }

    // MARK: Lines Claude leaves (open a page, remembered)

    private func listenOneClaude() {
        guard oneClaude.feedTask == nil else { return }
        let feed = ClaudeCodeService.shared.feed()
        oneClaude.feedTask = Task { [weak self] in
            for await f in feed {
                guard let self, !Task.isCancelled else { break }
                if case .live(.ui(let tid, let name, let ui)) = f { self.oneClaudeUI(threadId: tid, name: name, ui) }
                if case .live(.editPending(let sid, let p)) = f { await self.editPendingChanged(sessionId: sid, p) }
                if case .live(.connected) = f { await self.loadEditApprovals() }
                if case .live(.threadDeleted(let tid)) = f, self.oneClaude.chats.contains(where: { $0.id == tid }) {
                    let wasOpen = self.oneClaude.chatId == tid
                    self.oneClaudeForget([tid])
                    if wasOpen { await self.newOneClaudeChat() }
                }
            }
        }
    }

    func oneClaudeUI(threadId: String, name: String, _ ui: ClaudeUI) {
        guard threadId == oneClaude.chatId else { return }
        switch name {
        case "open_page":
            if ui.ask == true { oneClaude.askOpen = ui } else { performOneClaudeOpen(ui) }
        case "memory_add":
            oneClaude.remembered = ui
            oneClaude.suggestion = nil
        case "memory_suggest":
            oneClaude.suggestion = ui
        case "card":
            if case .approve(_, _, _, _, let target, _, _)? = ui.card?.card { oneClaude.waitingCards.insert(Self.cardKey(target)) }
        case "approve":
            if let box = ui.card, case .approve(_, _, _, _, let target, _, _) = box.card { oneClaude.waitingCards.insert(Self.cardKey(target)) }
            // A newer server sends the Approve card in the chat itself (ui.card): no second card here.
            if ui.card == nil, let id = ui.approve, !oneClaude.approvals.contains(where: { $0.approve == id }) { oneClaude.approvals.append(ui) }
        case "approve_result":
            oneClaude.approvals.removeAll { $0.approve == ui.action }
            if let a = ui.action { oneClaude.waitingCards.remove(Self.cardKey(.action(a))) }
        default:
            break
        }
    }

    /// Opens what Claude asked for, remembering where the person was (Back).
    func performOneClaudeOpen(_ ui: ClaudeUI, keepBack: Bool = false) {
        oneClaude.askOpen = nil
        let from = claudePage
        guard let page = ui.page else { return }
        switch page {
        case "home": go(.home)
        case "cast": go(.models)
        case "character": if let id = ui.id { openProfile(id) } else { go(.models) }
        case "suite":
            if let t = ui.tool, let tool = ComposerTool(rawValue: t) { openTool(tool) } else if ui.id?.hasPrefix("sa_") == true { openTool(.shot) } else { openSuite() }
            // A shared draft (a camera session's Shot draft opens as one): the composer takes it, Directed camera and guides included.
            if let id = ui.id, id.hasPrefix("sa_") { Task { await openSuiteAssist(id) } }
        case "edit":
            // An edit session (es_…, a blank project included) opens the editor on it; a take id opens that take.
            if let id = ui.id, id.hasPrefix("es_") { Task { await openEditSession(id) } } else { openEdit(takeId: ui.id) }
        case "take": if let id = ui.id { openTake(id) } else { go(.gallery) }
        case "library": go(.gallery)
        case "queue": go(.queue)
        case "settings": go(.settings)
        case "memory": openLearn(.playbook)
        case "recreate":
            if let id = ui.id { Task { await openRecreateReference(id) } } else { openRecreate() }
        default: return
        }
        if !keepBack {
            oneClaude.back = from
            oneClaude.opened = ui.target
        }
        oneClaudePageChanged()
    }

    /// Back to where the person was before Claude opened a page.
    func oneClaudeBack() {
        guard let b = oneClaude.back else { return }
        oneClaude.back = nil
        oneClaude.opened = nil
        let id = b.name == "edit" ? (b.ids?["sessionId"] ?? b.ids?["takeId"]) : (b.ids?["takeId"] ?? b.ids?["modelId"] ?? b.ids?["referenceId"])
        performOneClaudeOpen(ClaudeUI(page: b.name, id: id, tool: b.tool, label: b.label), keepBack: true)
    }

    /// Remember (Claude's question): saved to this person's own memory.
    func rememberSuggestion() async {
        guard let ui = oneClaude.suggestion, let text = ui.suggest, let api = oneClaudeAPI else { return }
        oneClaude.suggestion = nil
        do {
            let r = try await api.saveMemory(text: text, area: ui.area ?? "other", characterId: ui.characterId)
            oneClaude.remembered = ClaudeUI(remembered: r.id, text: r.text)
        } catch {
            showToast("Couldn't remember that. \((error as? ApiError)?.friendlyMessage ?? error.localizedDescription)")
        }
    }

    /// The chat's cards still waiting (after a restart or a chat switch).
    func loadClaudeApprovals(_ chatId: String) async {
        guard let api = oneClaudeAPI, let list = try? await api.waitingActions() else { return }
        guard oneClaude.chatId == chatId else { return }
        // Actions of this chat show as Approve cards in the chat itself (claude/cards.ts); only those without a chat stay here.
        oneClaude.approvals = list.filter { $0.chatId == chatId && !oneClaude.serverCards }.map {
            ClaudeUI(label: $0.label, approve: $0.id, gate: $0.gate, summary: $0.summary, priceUsd: $0.priceUsd)
        }
    }

    // MARK: Cards in the chat (plan, clip, what changed, approve)

    /// Undo one row of "What I changed": the server puts back only that part, as it is now, and the card shows "Undone".
    func undoClaudeCardRow(messageId: String, row: Int, label: String) async {
        guard let api = oneClaudeAPI else { return }
        let key = "\(messageId)#\(row)"
        oneClaude.undoing.insert(key)
        defer { oneClaude.undoing.remove(key) }
        do {
            _ = try await api.undoCardRow(messageId: messageId, row: row)
            showToast("\(label) put back")
        } catch {
            showToast("Couldn't undo \(label.lowercased()). \((error as? ApiError)?.friendlyMessage ?? error.localizedDescription)")
        }
    }

    /// Approve or Decline on an Approve card in the chat: a gated action, or the Suite's waiting shot.
    func answerClaudeCard(messageId: String, target: ClaudeApproveTarget, approve: Bool) async {
        guard !oneClaude.answering.contains(messageId) else { return }
        oneClaude.answering.insert(messageId)
        defer { oneClaude.answering.remove(messageId); oneClaude.waitingCards.remove(Self.cardKey(target)) }
        do {
            switch target {
            case .action(let id):
                guard let api = oneClaudeAPI else { return }
                oneClaude.approvals.removeAll { $0.approve == id }
                let r = try await api.answerAction(id, approve: approve)
                oneClaude.answeredCards[messageId] = r.status == "failed" ? "Didn't work: \(r.error ?? "try again from its screen")" : approve ? "Approved" : "Declined"
            case .suite(let assistId, let pendingId):
                guard let api = suiteAssistAPI else { return }
                let r = try await api.answerSuitePending(assistId: assistId, pendingId: pendingId, approve: approve)
                if approve, let jid = r.jobId {
                    if let s = try? await self.api.suiteShot(id: jid) { upsert(s.job) }
                    suite.shotJobIds.append(jid)
                    oneClaude.watchJob = jid
                    if let b = try? await self.api.balance() { balance = b }
                    oneClaude.answeredCards[messageId] = "Approved, rendering"
                } else {
                    oneClaude.answeredCards[messageId] = approve ? "Approved" : "Declined"
                }
                if suite.claude.ask?.id == pendingId { suite.claude.ask = nil }
            }
        } catch let e as ApiError where e.code == "price_changed" || e.code == "not_found" || e.code == "already_answered" || e.code == "expired" {
            oneClaude.answeredCards[messageId] = e.code == "price_changed" ? e.message : "Already answered"
        } catch {
            showToast("Couldn't answer that. \((error as? ApiError)?.friendlyMessage ?? error.localizedDescription)")
        }
    }

    /// The live context strip (ClaudeContext): what Claude sees on this page now, from the same `screen` the composer
    /// syncs to the server for Claude. Only the AI Suite reports a screen today; other pages show their name only.
    var claudeContextItems: [ClaudeContextItem] {
        guard screen == .suite else { return [] }
        return ClaudeContext.items(screen: suiteScreen(at: nil), lookups: .init(
            character: { [self] id in character(id).map { ($0.shortName, $0.cover) } },
            outfit: { [self] id in outfits.first { $0.id == id }.map { ($0.name, $0.angles.first ?? nil) } },
            clipPoster: { [self] id in clip?.id == id ? clip?.thumb : nil }))
    }

    static func cardKey(_ t: ClaudeApproveTarget) -> String {
        switch t { case .action(let id): id; case .suite(_, let p): p }
    }

    // MARK: Paid helpers of every edit (ci_e546642a4026)

    /// Everything waiting on the owner's open edits (GET /v1/edit-sessions). Owner only: members don't edit with Claude.
    func loadEditApprovals() async {
        guard isOwner, let list = try? await api.recentEditSessions(limit: 50) else { return }
        oneClaude.editApprovals.replace(sessions: list)
    }

    /// A live `pending` event of any edit session: listed, updated or gone. A session the list doesn't know yet (Claude
    /// opened a new edit) is named after the next reload.
    func editPendingChanged(sessionId: String, _ p: EditPending) async {
        guard isOwner else { return }
        let known = oneClaude.editApprovals.items.contains { $0.sessionId == sessionId }
        oneClaude.editApprovals.apply(sessionId: sessionId, takeId: nil, p)
        if p.isWaiting, !known { await loadEditApprovals() }
    }

    /// The edit a card names: its take's title, "New project" for a blank one.
    func editApprovalName(_ a: EditApproval) -> String {
        let take = takes.first { $0.id == a.takeId }
        return EditApprovalList.editName(takeId: a.takeId, title: take.flatMap { $0.title.isEmpty ? nil : $0.displayTitle })
    }

    /// Allow / Not now from the Claude panel: answered on that edit's session, without switching edits.
    func answerEditApproval(_ a: EditApproval, approve: Bool) async {
        guard !oneClaude.answeringEdit.contains(a.id) else { return }
        oneClaude.answeringEdit.insert(a.id)
        defer { oneClaude.answeringEdit.remove(a.id) }
        do {
            _ = try await api.answerEditPending(sessionId: a.sessionId, pendingId: a.pending.id, approve: approve)
            oneClaude.editApprovals.remove(a.id)
            showToast(approve ? "\(a.pending.label) started in “\(editApprovalName(a))”. Claude's change lands when it's done." : "Told Claude not now")
        } catch let e as ApiError where e.code == "not_found" || e.code == "already_answered" || e.code == "expired" {
            oneClaude.editApprovals.remove(a.id)
            showToast("That was already answered")
        } catch {
            showToast("Couldn't answer Claude. \((error as? ApiError)?.friendlyMessage ?? error.localizedDescription)")
        }
    }

    /// What waits for the person now (Approve cards, Open?, Remember?, file questions): the orb's "waiting".
    var claudeWaitingCount: Int {
        oneClaude.approvals.count + oneClaude.editApprovals.count + oneClaude.waitingCards.count + (oneClaude.askOpen != nil ? 1 : 0) + (oneClaude.suggestion != nil ? 1 : 0)
            + ClaudeCodeService.shared.fileAsks.count
    }

    /// The watched job's progress for the activity strip (0…1), nil when none runs.
    var claudeJobProgress: Double? {
        guard let id = oneClaude.watchJob, let j = jobs.first(where: { $0.id == id }) else { return nil }
        if j.isDone || j.isFailed { return nil }
        return min(1, max(0, j.progress > 1 ? j.progress / 100 : j.progress))
    }

    /// What is on screen changed (the edit, the composer, a reply, a job): new live chips after a moment (~1 s), so a
    /// burst of changes asks once.
    func claudeChipsChanged(now: Bool = false) {
        guard oneClaude.open else { return }
        oneClaude.chipsTask?.cancel()
        oneClaude.chipsTask = Task { [weak self] in
            if !now { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            guard let self, !Task.isCancelled else { return }
            await self.loadClaudeChips()
        }
    }

    /// The Edit page's facts (EditSuiteView): asks for new chips when they change; a new video or sound in the edit is
    /// "just imported".
    func claudeEditChanged(_ facts: ClaudeSuggestQuery?, assets: [String: String] = [:]) {
        guard let facts else {
            oneClaude.editFacts = nil
            oneClaude.editAssets = nil
            oneClaude.imported = nil
            return
        }
        if let known = oneClaude.editAssets,
           let new = assets.filter({ !known.contains($0.key) && ($0.value == "video" || $0.value == "audio") }).min(by: { $0.key < $1.key }) {
            oneClaude.imported = ClaudeImported(kind: new.value, id: new.key, at: Date())
        }
        oneClaude.editAssets = Set(assets.keys)
        guard facts != oneClaude.editFacts else { return }
        oneClaude.editFacts = facts
        claudeChipsChanged()
    }

    /// Jobs that ended (done or failed): a change asks for new chips ("Why did it fail?", "Watch the new take").
    var claudeJobsEnded: String {
        let ended = jobs.filter { $0.isDone || $0.isFailed }
        return "\(ended.count)·\(ended.filter(\.isFailed).count)"
    }

    /// The Suite's own Claude panel (Shot composer): its chips follow the composer too (same server rules, page suite).
    func loadSuiteSuggestions() async {
        guard let api = oneClaudeAPI, let a = suite.claude.assist else { return }
        let q = ClaudeSuggestQuery(page: ClaudePage(name: "suite", tool: suite.composer.tool.rawValue, ids: ["assistId": a.id]), chatId: nil)
        guard let list = try? await api.claudeSuggestions(q), !list.isEmpty else { return }
        let old = oneClaude.suiteChips ?? []
        let next = ClaudeChip.steady(old: old, new: list)
        if oneClaude.suiteChips != next { oneClaude.suiteChips = next }
    }

    /// What the server needs for the live chips: the page Claude sees, the chat, and on Edit what is on screen there.
    var claudeSuggestQuery: ClaudeSuggestQuery {
        let p = claudePage
        var q = (p.name == "edit" ? oneClaude.editFacts : nil)?.on(p, chatId: oneClaude.chatId) ?? ClaudeSuggestQuery(page: p, chatId: oneClaude.chatId)
        if p.name == "edit", let i = oneClaude.imported, Date().timeIntervalSince(i.at) < 120 { q.imported = i.kind; q.importedId = i.id }
        return q
    }

    /// The chips for what Claude sees now (the server's live list; the page's fixed copy when it is older or offline).
    /// On the same page a chip that stays keeps its place, so the row doesn't jump.
    func loadClaudeChips() async {
        let q = claudeSuggestQuery
        var list = ClaudeChip.fallback(page: q.page, tool: q.tool)
        if let api = oneClaudeAPI {
            do { list = try await api.claudeSuggestions(q); oneClaude.serverCards = true }
            catch let e as ApiError where e.code == "not_found" { oneClaude.serverCards = false }
            catch {}
        }
        let samePage = oneClaude.chipsPage == q.page
        let next = samePage ? ClaudeChip.steady(old: oneClaude.chips, new: list) : list
        oneClaude.chipsPage = q.page
        if oneClaude.chips != next { oneClaude.chips = next }
    }

    /// Approve or Decline on Claude's card. The server runs it as this person and leaves "Done: …" in the chat.
    func answerClaudeAction(_ ui: ClaudeUI, approve: Bool) async {
        guard let id = ui.approve, let api = oneClaudeAPI else { return }
        oneClaude.approvals.removeAll { $0.approve == id }
        do {
            let r = try await api.answerAction(id, approve: approve)
            if r.status == "failed" { showToast("That didn't work. \(r.error ?? "")") }
        } catch {
            showToast("Couldn't answer that. \((error as? ApiError)?.friendlyMessage ?? error.localizedDescription)")
        }
    }

    func loadOneClaudeMemory() async {
        guard let api = oneClaudeAPI else { oneClaude.memoryError = "Sign in to your MUSE server first."; return }
        do { oneClaude.memory = try await api.memory(); oneClaude.memoryError = nil } catch {
            oneClaude.memoryError = (error as? ApiError)?.friendlyMessage ?? error.localizedDescription
        }
    }

    func pinOneClaudeMemory(_ r: ClaudeMemoryRule) async {
        guard let api = oneClaudeAPI else { return }
        _ = try? await api.pinMemory(r.id, pinned: !r.pinned)
        await loadOneClaudeMemory()
    }

    func deleteOneClaudeMemory(_ r: ClaudeMemoryRule) async {
        guard let api = oneClaudeAPI else { return }
        try? await api.deleteMemory(r.id)
        await loadOneClaudeMemory()
    }

    // MARK: The Claude model (step 6b)

    func loadClaudeModels() async {
        guard let api = oneClaudeAPI, let list = try? await api.claudeModels() else { return }
        oneClaude.models = list
        await ClaudeCodeService.shared.relayDefaultModel(list.default)
    }

    /// The model the open chat runs on, and whether it is the person's default.
    var oneClaudeModel: (info: ClaudeModelInfo?, isDefault: Bool) {
        let list = oneClaude.models
        let own = oneClaude.current?.model
        let id = own ?? list?.default ?? list?.studioDefault
        return (list?.models.first { $0.id == id }, own == nil)
    }

    /// Picks the open chat's model (nil: back to the person's default). The next message uses it.
    func setOneClaudeModel(_ id: String?) async {
        guard let api = oneClaudeAPI, let chat = oneClaude.chatId else { return }
        do {
            try await api.setChatModel(chat, model: id)
            if let i = oneClaude.chats.firstIndex(where: { $0.id == chat }) { oneClaude.chats[i].model = id }
            await ClaudeCodeService.shared.relayChatModel(threadId: chat, id)
        } catch {
            showToast("Couldn't change the model. \((error as? ApiError)?.friendlyMessage ?? error.localizedDescription)")
        }
    }

    /// The person's default for chats that don't pick one.
    func setOneClaudeDefaultModel(_ id: String?) async {
        guard let api = oneClaudeAPI else { return }
        try? await api.setDefaultModel(id)
        await loadClaudeModels()
    }
}

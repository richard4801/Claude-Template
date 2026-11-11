import Foundation
import MuseCore
import Observation

/// One Claude (plans/one-claude.md): one Claude panel on every page, with several chats. A chat is about a piece of work
/// and follows the person across pages; Claude knows the page (sent with each message and when they move) and can open
/// pages itself ("Opened … · Back"), asking first when they are in the middle of something. The owner's turns run on
/// her Mac's Claude Code; members' (and the owner's, when Claude Code isn't set up) on the studio's Claude in the app.
@MainActor
@Observable
final class OneClaudeState {
    var open = false
    /// The open chat (kept on this Mac).
    var chatId: String? = UserDefaults.standard.string(forKey: OneClaudeState.chatKey)
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
    /// "Remembered: …" (Undo for the owner).
    var remembered: ClaudeUI?
    var memory: ClaudeMemory?
    /// Members (and the owner without Claude Code): the chat on the studio's Claude.
    var lines: [MemberLine] = []
    var streaming = ""
    var sending = false
    var sendError: String?

    struct MemberLine: Identifiable, Hashable {
        let id: String
        var fromClaude: Bool
        var text: String
    }

    @ObservationIgnored var feedTask: Task<Void, Never>?
    @ObservationIgnored var pageTask: Task<Void, Never>?
    @ObservationIgnored var lastSentPage: ClaudePage?
    @ObservationIgnored var lastSentChat: String?
    @ObservationIgnored var memberAPI: HTTPClaudeAPI?

    static let chatKey = "oneClaude.chatId"
    init() {}

    var current: ClaudeChatSummary? { chats.first { $0.id == chatId } }
}

extension AppStore {
    // MARK: The page the person is on

    /// The page as Claude sees it ("Sees: Edit, Beach reel"), with the ids it has open.
    var claudePage: ClaudePage {
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

    /// Claude's chat runs on this Mac's Claude Code (the owner's), else on the studio's Claude in the app.
    var oneClaudeOnMac: Bool { isOwner && ClaudeCodeService.shared.configured && ClaudeCodeService.shared.info.ready }

    // MARK: Open, chats

    func toggleOneClaude() {
        oneClaude.open.toggle()
        if oneClaude.open { Task { await startOneClaude() } }
    }

    func showOneClaude() {
        guard !oneClaude.open else { return }
        oneClaude.open = true
        Task { await startOneClaude() }
    }

    private var oneClaudeAPI: (any ClaudeAPI)? {
        if let a = ClaudeCodeService.shared.api { return a }
        guard let http = api as? HTTPMuseAPI else { return nil }
        if let m = oneClaude.memberAPI { return m }
        let m = HTTPClaudeAPI(baseURL: http.baseURL) { [http] in http.sessionToken }
        oneClaude.memberAPI = m
        return m
    }

    func startOneClaude() async {
        listenOneClaude()
        await refreshOneClaudeChats()
        if oneClaude.chatId == nil || !oneClaude.chats.contains(where: { $0.id == oneClaude.chatId }) {
            if let first = oneClaude.chats.first { pickOneClaudeChat(first.id) } else { await newOneClaudeChat() }
        }
        await oneClaudeLinkSuite()
        oneClaudePageChanged(now: true)
        if !oneClaudeOnMac { await loadMemberLines() }
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
        oneClaude.lastSentChat = nil
        oneClaudePageChanged(now: true)
        if !oneClaudeOnMac { Task { await loadMemberLines() } }
    }

    func archiveOneClaudeChat(_ id: String) async {
        guard let api = oneClaudeAPI else { return }
        try? await api.archiveChat(id)
        oneClaude.chats.removeAll { $0.id == id }
        if oneClaude.chatId == id {
            if let next = oneClaude.chats.first { pickOneClaudeChat(next.id) } else { await newOneClaudeChat() }
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
            if let t = ui.tool, let tool = ComposerTool(rawValue: t) { openTool(tool) } else { openSuite() }
        case "edit": openEdit(takeId: ui.id)
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
        let id = b.ids?["takeId"] ?? b.ids?["modelId"] ?? b.ids?["referenceId"]
        performOneClaudeOpen(ClaudeUI(page: b.name, id: id, tool: b.tool, label: b.label), keepBack: true)
    }

    /// Undo "Remembered …" (the owner: deletes the rule Claude just saved).
    func undoOneClaudeMemory() async {
        guard isOwner, let id = oneClaude.remembered?.remembered else { return }
        oneClaude.remembered = nil
        await confirmDeleteRule(id)
    }

    func loadOneClaudeMemory() async {
        oneClaude.memory = try? await oneClaudeAPI?.memory()
    }

    // MARK: The chat on the studio's Claude (members)

    func loadMemberLines(after: Double? = nil) async {
        guard let id = oneClaude.chatId, let api = oneClaudeAPI, let d = try? await api.threadDetail(id) else { oneClaude.lines = []; return }
        // Lines Claude left during this turn (members get no live events): open the page, show "Remembered …".
        if let after {
            for m in d.messages where m.createdAt >= after { if let t = m.tool, let ui = t.ui { oneClaudeUI(threadId: id, name: t.name, ui) } }
        }
        oneClaude.lines = d.messages.filter { ($0.role == "user" || $0.role == "assistant") && !$0.text.isEmpty }
            .map { .init(id: $0.id, fromClaude: $0.role == "assistant", text: ClaudePage.stripContext($0.text)) }
    }

    func sendMemberLine(_ text: String) async {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, !oneClaude.sending, let id = oneClaude.chatId, let api = oneClaudeAPI as? HTTPClaudeAPI else { return }
        oneClaude.sending = true
        oneClaude.sendError = nil
        oneClaude.streaming = ""
        oneClaude.lines.append(.init(id: UUID().uuidString, fromClaude: false, text: words))
        let started = Date().timeIntervalSince1970 * 1000 - 5000
        defer { oneClaude.sending = false }
        do {
            for try await e in api.chatTurn(chatId: id, text: words, page: claudePage) {
                switch e {
                case .text(let d): oneClaude.streaming += d
                case .tool: oneClaude.streaming = ""
                case .error(_, let m): oneClaude.sendError = m
                default: break
                }
            }
        } catch {
            oneClaude.sendError = (error as? ApiError)?.friendlyMessage ?? error.localizedDescription
        }
        let answer = oneClaude.streaming.trimmingCharacters(in: .whitespacesAndNewlines)
        oneClaude.streaming = ""
        if !answer.isEmpty { oneClaude.lines.append(.init(id: UUID().uuidString, fromClaude: true, text: answer)) }
        await loadMemberLines(after: started)
        await refreshOneClaudeChats()
    }
}

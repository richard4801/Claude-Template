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
    /// "Remembered: …" (the person asked Claude to remember).
    var remembered: ClaudeUI?
    /// "Shall I remember: …?" (Remember / No): nothing is saved until Remember.
    var suggestion: ClaudeUI?
    var memory: ClaudeMemory?
    var memoryError: String?
    /// Step 6b: the models and this person's default.
    var models: ClaudeModelList?

    @ObservationIgnored var feedTask: Task<Void, Never>?
    @ObservationIgnored var pageTask: Task<Void, Never>?
    @ObservationIgnored var lastSentPage: ClaudePage?
    @ObservationIgnored var lastSentChat: String?

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

    private var oneClaudeAPI: (any ClaudeAPI)? { ClaudeCodeService.shared.api }

    func startOneClaude() async {
        listenOneClaude()
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
            oneClaude.suggestion = nil
        case "memory_suggest":
            oneClaude.suggestion = ui
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

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The `/v1/claude/*` endpoints and the Mac's MCP session token (plans/api.md "Claude on the owner's plan"). Owner only.
/// Kept apart from MuseAPI so the shared client files stay untouched.
/// Claude's gated action answered by the person (POST v1/claude/actions/:id): done, failed or declined.
public struct ClaudeActionAnswer: Decodable, Sendable { public var id: String; public var status: String; public var error: String? }
/// An Approve card still waiting (GET v1/claude/actions?status=waiting).
public struct ClaudeWaitingAction: Decodable, Sendable {
    public var id: String; public var gate: String; public var summary: String; public var priceUsd: Double?; public var chatId: String?
    /// The button, as the server's card names it.
    public var label: String {
        let verb = gate == "delete" ? "Delete" : gate == "post" ? "Post" : gate == "spend" ? "Approve" : "Change"
        return priceUsd.map { "\(verb) · $\(String(format: "%.2f", $0))" } ?? verb
    }
}

public protocol ClaudeAPI: Sendable {
    func status() async throws -> ClaudeStatus
    /// PATCH /v1/claude/settings. Off by default; billed per use.
    func setApiFallback(_ on: Bool) async throws -> ClaudeStatus
    func heartbeat(_ info: ClaudeCodeInfo) async throws -> ClaudeHeartbeatReply
    /// Get or create the thread of a camera or edit session.
    func thread(contextKind: String, contextId: String) async throws -> ClaudeThread
    func threadDetail(_ id: String) async throws -> ClaudeThreadDetail
    func setClaudeSession(threadId: String, claudeSessionId: String) async throws -> ClaudeThread
    /// From a device that can't run Claude (the phone; the Mac uses it only in tests). `mac_offline` / `claude_busy` are thrown.
    func postMessage(threadId: String, text: String) async throws -> ClaudeMessagePosted
    func pendingTurns() async throws -> [ClaudeTurn]
    func claim(turnId: String) async throws -> ClaudeTurn
    func stopTurn(_ turnId: String) async throws
    /// POST …/events: the Mac's mirror of its local Claude Code stream (≤ 4 MB a call).
    func postEvents(threadId: String, _ batch: ClaudeEventBatch) async throws
    /// The studio API key fallback (camera threads only for now): ChatEvents like the camera chat. `fallback_off` is thrown.
    func apiTurn(threadId: String, text: String) -> AsyncThrowingStream<ChatEvent, Error>
    func mcpSessionToken(ttlMinutes: Int?) async throws -> McpSessionToken
    /// `claude` live events; `.connected` each time the stream (re)opens.
    func events() -> AsyncStream<ClaudeLiveEvent>

    // Chat sessions (WS18): each place keeps a list of chats on the server.
    /// GET /v1/claude/threads?key=: the place's chats, newest first.
    func threads(key: String) async throws -> [ClaudeThread]
    /// POST /v1/claude/threads {new: true}: a new chat about the same context.
    func newThread(contextKind: String, contextId: String) async throws -> ClaudeThread
    /// PATCH {title}: "" goes back to the chat's first words.
    func renameThread(_ id: String, title: String) async throws -> ClaudeThread
    /// DELETE: the chat and its messages.
    func deleteThread(_ id: String) async throws

    // One Claude (plans/one-claude.md): the person's own chats, the page they are on, the studio's memory.
    /// GET /v1/claude/chats: newest first (old per-place chats included).
    func chats(query: String?) async throws -> [ClaudeChatSummary]
    /// POST /v1/claude/chats: a new chat, starting on this page.
    func newChat(page: ClaudePage?) async throws -> ClaudeChatSummary
    /// PUT …/page: where the person is now (Claude reads it each turn).
    func setChatPage(_ id: String, page: ClaudePage) async throws
    /// PATCH {archived: true}: out of the list, kept.
    func archiveChat(_ id: String) async throws
    /// Deletes the person's own chats (by id and/or not used for olderThanDays days) → the ids deleted.
    func deleteChats(ids: [String], olderThanDays: Int?) async throws -> [String]
    /// GET /v1/claude/memory: this person's own memory (per person).
    func memory() async throws -> ClaudeMemory
    func waitingActions() async throws -> [ClaudeWaitingAction]
    func answerAction(_ id: String, approve: Bool) async throws -> ClaudeActionAnswer
    /// POST: Remember (on Claude's question), or added by hand.
    func saveMemory(text: String, area: String, characterId: String?) async throws -> ClaudeMemoryRule
    func pinMemory(_ id: String, pinned: Bool) async throws -> ClaudeMemoryRule
    func deleteMemory(_ id: String) async throws
    /// Step 6b: the models, this person's default; a chat's model; this person's default.
    func claudeModels() async throws -> ClaudeModelList
    func setChatModel(_ id: String, model: String?) async throws
    func setDefaultModel(_ model: String?) async throws
    /// Files on this Mac: Claude Code's questions waiting for this person, and their answer.
    func pendingPermissions() async throws -> [ClaudePermissionAsk]
    func answerPermission(_ id: String, allow: Bool, message: String?) async throws
    /// upload_local_file: the person said yes and the Mac uploaded the file.
    func finishUpload(_ id: String, _ result: ClaudeLocalUpload) async throws
    /// Results arrive in the chat: this Mac answers it (false: another Mac of the person already does).
    func claimResult(_ id: String) async throws -> Bool
    /// Claude operating the MUSE window: calls waiting for this person; claim one (false: another Mac does it); answer it.
    func pendingUiCalls() async throws -> [UiCall]
    func claimUiCall(_ id: String, device: String) async throws -> Bool
    func answerUiCall(_ id: String, _ answer: UiAnswer) async throws
    /// Cards: Undo one row of a "What I changed" card; the page's quick-action chips.
    func undoCardRow(messageId: String, row: Int) async throws -> ClaudeCardUndo
    func claudeChips(page: String?, tool: String?) async throws -> [ClaudeChip]
    /// Live chips for what is on screen now (GET v1/claude/suggestions); the page's fixed chips from an older server.
    func claudeSuggestions(_ q: ClaudeSuggestQuery) async throws -> [ClaudeChip]
}

/// Older test doubles: an older server has no lists (`not_found`), which the app treats as "one chat per context".
public extension ClaudeAPI {
    func threads(key: String) async throws -> [ClaudeThread] { throw ApiError("not_found", "This server keeps one chat per place") }
    func newThread(contextKind: String, contextId: String) async throws -> ClaudeThread { throw ApiError("not_found", "This server keeps one chat per place") }
    func renameThread(_ id: String, title: String) async throws -> ClaudeThread { throw ApiError("not_found", "This server keeps one chat per place") }
    func deleteThread(_ id: String) async throws { throw ApiError("not_found", "This server keeps one chat per place") }
    func chats(query: String?) async throws -> [ClaudeChatSummary] { throw ApiError("not_found", "This server has one chat per place") }
    func newChat(page: ClaudePage?) async throws -> ClaudeChatSummary { throw ApiError("not_found", "This server has one chat per place") }
    func setChatPage(_ id: String, page: ClaudePage) async throws {}
    func archiveChat(_ id: String) async throws { throw ApiError("not_found", "This server has one chat per place") }
    func deleteChats(ids: [String], olderThanDays: Int?) async throws -> [String] { throw ApiError("not_found", "This server can't delete chats yet. Update the server.") }
    func memory() async throws -> ClaudeMemory { throw ApiError("not_found", "This server has no Claude memory yet") }
    func waitingActions() async throws -> [ClaudeWaitingAction] { [] }
    func answerAction(_ id: String, approve: Bool) async throws -> ClaudeActionAnswer { throw ApiError("not_found", "This server can't answer Claude's actions yet") }
    func saveMemory(text: String, area: String, characterId: String?) async throws -> ClaudeMemoryRule { throw ApiError("not_found", "This server has no Claude memory yet") }
    func pinMemory(_ id: String, pinned: Bool) async throws -> ClaudeMemoryRule { throw ApiError("not_found", "This server has no Claude memory yet") }
    func deleteMemory(_ id: String) async throws { throw ApiError("not_found", "This server has no Claude memory yet") }
    func claudeModels() async throws -> ClaudeModelList { throw ApiError("not_found", "This server has no model choice yet") }
    func setChatModel(_ id: String, model: String?) async throws { throw ApiError("not_found", "This server has no model choice yet") }
    func setDefaultModel(_ model: String?) async throws { throw ApiError("not_found", "This server has no model choice yet") }
    func pendingPermissions() async throws -> [ClaudePermissionAsk] { [] }
    func answerPermission(_ id: String, allow: Bool, message: String?) async throws { throw ApiError("not_found", "This server can't ask about files yet") }
    func finishUpload(_ id: String, _ result: ClaudeLocalUpload) async throws { throw ApiError("not_found", "This server can't take uploads from Claude yet") }
    func claimResult(_ id: String) async throws -> Bool { true }
    func pendingUiCalls() async throws -> [UiCall] { [] }
    func claimUiCall(_ id: String, device: String) async throws -> Bool { false }
    func answerUiCall(_ id: String, _ answer: UiAnswer) async throws {}
    func undoCardRow(messageId: String, row: Int) async throws -> ClaudeCardUndo { throw ApiError("not_found", "This server can't undo from the chat yet") }
    func claudeChips(page: String?, tool: String?) async throws -> [ClaudeChip] { ClaudeChip.fallback(page: page, tool: tool) }
    func claudeSuggestions(_ q: ClaudeSuggestQuery) async throws -> [ClaudeChip] { try await claudeChips(page: q.page, tool: q.tool) }
}

enum ClaudeIds {
    static func check(_ id: String) throws -> String {
        guard !id.isEmpty, id.count <= 120, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
            throw ApiError("bad_request", "Bad id")
        }
        return id
    }
}

/// ClaudeAPI over HTTP. The token is read per request from a closure, like the Blender relay:
///     HTTPClaudeAPI(baseURL: http.baseURL) { [http] in http.sessionToken }
public final class HTTPClaudeAPI: ClaudeAPI, @unchecked Sendable {
    public let baseURL: URL
    private let token: @Sendable () -> String?
    /// The signed-in token, for the chat's video upload through HTTPMuseAPI (same module only).
    var currentToken: String? { token() }
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// The app's one shared GET /v1/events connection (performance pass).
    private let hub: LiveEventHub

    public init(baseURL: URL, session: URLSession = .shared, hub: LiveEventHub = .shared, token: @escaping @Sendable () -> String?) {
        self.baseURL = baseURL
        self.session = session
        self.hub = hub
        self.token = token
    }

    // MARK: Plumbing

    func url(_ path: String) -> URL {
        var s = baseURL.absoluteString
        if !s.hasSuffix("/") { s += "/" }
        return URL(string: s + path)!
    }

    func request(_ method: String, _ path: String, body: Data? = nil, timeout: TimeInterval = 30) -> URLRequest {
        var r = URLRequest(url: url(path))
        r.httpMethod = method
        r.timeoutInterval = timeout
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let t = token() { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        // This app shows file and upload cards and answers results (the server asks only apps that say so).
        r.setValue(Self.capabilities, forHTTPHeaderField: "X-Muse-Caps")
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }
    public static let capabilities = "files,results,ui"

    private func send(_ r: URLRequest) async throws -> Data {
        let (data, resp): (Data, URLResponse?)
        do {
            (data, resp) = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, URLResponse?), Error>) in
                session.dataTask(with: r) { d, r, e in
                    if let e { cont.resume(throwing: e) } else { cont.resume(returning: (d ?? Data(), r)) }
                }.resume()
            }
        } catch {
            throw ApiError("offline", "Can't reach the server at \(baseURL.absoluteString)")
        }
        try HTTPCameraAPI.check(resp, data, decoder)
        return data
    }

    private func call<T: Decodable>(_ method: String, _ path: String) async throws -> T {
        try decode(try await send(request(method, path)))
    }

    private func call<T: Decodable, B: Encodable>(_ method: String, _ path: String, _ body: B) async throws -> T {
        try decode(try await send(request(method, path, body: try encoder.encode(body))))
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try decoder.decode(T.self, from: data) } catch { throw ApiError("bad_response", "Unexpected reply from the server (\(T.self))") }
    }

    private struct Settings: Encodable { var apiFallback: Bool }
    private struct NewThread: Encodable { var contextKind: String; var contextId: String; var new: Bool? = nil }
    private struct TitlePatch: Encodable { var title: String }
    private struct SessionPatch: Encodable { var claudeSessionId: String }
    private struct Text: Encodable { var text: String }
    private struct TokenReq: Encodable { var ttlMinutes: Int? }
    private struct NewChat: Encodable { var page: ClaudePage? }
    private struct PagePut: Encodable { var page: ClaudePage }
    private struct Archive: Encodable { var archived: Bool }

    // MARK: One Claude

    public func chats(query: String?) async throws -> [ClaudeChatSummary] {
        var path = "v1/claude/chats"
        if let q = query?.trimmingCharacters(in: .whitespaces), !q.isEmpty, let e = q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { path += "?q=\(e)" }
        let list: ClaudeChatList = try await call("GET", path)
        return list.chats
    }
    public func newChat(page: ClaudePage?) async throws -> ClaudeChatSummary { try await call("POST", "v1/claude/chats", NewChat(page: page)) }
    public func setChatPage(_ id: String, page: ClaudePage) async throws {
        _ = try await send(request("PUT", "v1/claude/chats/\(try ClaudeIds.check(id))/page", body: try encoder.encode(PagePut(page: page))))
    }
    private struct DeleteChats: Encodable { var ids: [String]?; var olderThanDays: Int? }
    private struct Deleted: Decodable { var deleted: [String] }
    public func deleteChats(ids: [String], olderThanDays: Int?) async throws -> [String] {
        let r: Deleted = try await call("POST", "v1/claude/chats/delete", DeleteChats(ids: ids.isEmpty ? nil : ids, olderThanDays: olderThanDays))
        return r.deleted
    }
    public func archiveChat(_ id: String) async throws {
        _ = try await send(request("PATCH", "v1/claude/chats/\(try ClaudeIds.check(id))", body: try encoder.encode(Archive(archived: true))))
    }
    /// The person answers Claude's Approve card (only theirs, once). Approve runs the stored action as them.
    private struct ActionPost: Encodable { var approve: Bool }
    private struct WaitingList: Decodable { var actions: [ClaudeWaitingAction] }
    public func waitingActions() async throws -> [ClaudeWaitingAction] {
        let l: WaitingList = try await call("GET", "v1/claude/actions?status=waiting")
        return l.actions
    }
    public func answerAction(_ id: String, approve: Bool) async throws -> ClaudeActionAnswer {
        try await call("POST", "v1/claude/actions/\(try ClaudeIds.check(id))", ActionPost(approve: approve))
    }
    public func memory() async throws -> ClaudeMemory { try await call("GET", "v1/claude/memory") }
    private struct MemoryNew: Encodable { var text: String; var area: String; var characterId: String? }
    private struct MemoryPin: Encodable { var pinned: Bool }
    public func saveMemory(text: String, area: String, characterId: String?) async throws -> ClaudeMemoryRule {
        try await call("POST", "v1/claude/memory", MemoryNew(text: text, area: area, characterId: characterId))
    }
    public func pinMemory(_ id: String, pinned: Bool) async throws -> ClaudeMemoryRule {
        try await call("PATCH", "v1/claude/memory/\(try ClaudeIds.check(id))", MemoryPin(pinned: pinned))
    }
    private struct ModelPatch: Encodable {
        var model: String?
        func encode(to e: Encoder) throws { var c = e.container(keyedBy: K.self); try c.encode(model, forKey: .model) } // null clears
        enum K: String, CodingKey { case model }
    }
    private struct PrefsPut: Encodable {
        var defaultModel: String?
        func encode(to e: Encoder) throws { var c = e.container(keyedBy: K.self); try c.encode(defaultModel, forKey: .defaultModel) }
        enum K: String, CodingKey { case defaultModel }
    }
    public func claudeModels() async throws -> ClaudeModelList { try await call("GET", "v1/claude/models") }
    public func setChatModel(_ id: String, model: String?) async throws {
        _ = try await send(request("PATCH", "v1/claude/chats/\(try ClaudeIds.check(id))", body: try encoder.encode(ModelPatch(model: model))))
    }
    public func pendingPermissions() async throws -> [ClaudePermissionAsk] {
        let list: ClaudePermissionList = try await call("GET", "v1/claude/permissions")
        return list.asks
    }
    private struct PermissionAnswer: Encodable { var allow: Bool; var message: String? }
    private struct UploadAnswer: Encodable { var allow = true; var result: ClaudeLocalUpload }
    public func finishUpload(_ id: String, _ result: ClaudeLocalUpload) async throws {
        _ = try await send(request("POST", "v1/claude/permissions/\(try ClaudeIds.check(id))", body: try encoder.encode(UploadAnswer(result: result))))
    }
    public func claimResult(_ id: String) async throws -> Bool {
        do {
            _ = try await send(request("POST", "v1/claude/results/\(try ClaudeIds.check(id))/claim"))
            return true
        } catch let e as ApiError where e.code == "already_claimed" || e.code == "result_gone" {
            return false
        } catch let e as ApiError where e.code == "not_found" {
            return true // an older server without claims
        }
    }
    private struct UiClaim: Encodable { var device: String }
    public func pendingUiCalls() async throws -> [UiCall] {
        let list: UiCallList = try await call("GET", "v1/claude/ui")
        return list.calls
    }
    public func claimUiCall(_ id: String, device: String) async throws -> Bool {
        do {
            _ = try await send(request("POST", "v1/claude/ui/\(try ClaudeIds.check(id))/claim", body: try encoder.encode(UiClaim(device: String(device.prefix(120))))))
            return true
        } catch let e as ApiError where e.code == "ui_claimed" || e.code == "ui_expired" {
            return false
        }
    }
    public func answerUiCall(_ id: String, _ answer: UiAnswer) async throws {
        _ = try await send(request("POST", "v1/claude/ui/\(try ClaudeIds.check(id))", body: try encoder.encode(answer), timeout: 60))
    }
    private struct UndoRow: Encodable { var row: Int }
    public func undoCardRow(messageId: String, row: Int) async throws -> ClaudeCardUndo {
        try await call("POST", "v1/claude/cards/\(try ClaudeIds.check(messageId))/undo", UndoRow(row: row))
    }
    public func claudeChips(page: String?, tool: String?) async throws -> [ClaudeChip] {
        var q: [String] = []
        if let p = page, p.allSatisfy({ $0.isASCII && $0.isLetter }) { q.append("page=\(p)") }
        if let t = tool, t.allSatisfy({ $0.isASCII && $0.isLowercase }) { q.append("tool=\(t)") }
        do {
            let l: ClaudeChipList = try await call("GET", "v1/claude/chips" + (q.isEmpty ? "" : "?" + q.joined(separator: "&")))
            return l.chips.isEmpty ? ClaudeChip.fallback(page: page, tool: tool) : l.chips
        } catch let e as ApiError where e.code == "offline" {
            return ClaudeChip.fallback(page: page, tool: tool) // no server now: this app's own copy (not_found: an older server, the caller decides)
        }
    }
    public func claudeSuggestions(_ q: ClaudeSuggestQuery) async throws -> [ClaudeChip] {
        do {
            let l: ClaudeSuggestionList = try await call("GET", "v1/claude/suggestions?" + q.queryString)
            if l.chips.isEmpty { return try await claudeChips(page: q.page, tool: q.tool) }
            return l.chips
        } catch let e as ApiError where e.code == "not_found" {
            return try await claudeChips(page: q.page, tool: q.tool)   // an older server: the page's fixed chips
        } catch let e as ApiError where e.code == "offline" {
            return ClaudeChip.fallback(page: q.page, tool: q.tool)
        }
    }
    public func answerPermission(_ id: String, allow: Bool, message: String?) async throws {
        _ = try await send(request("POST", "v1/claude/permissions/\(try ClaudeIds.check(id))", body: try encoder.encode(PermissionAnswer(allow: allow, message: message))))
    }
    public func setDefaultModel(_ model: String?) async throws {
        _ = try await send(request("PUT", "v1/claude/prefs", body: try encoder.encode(PrefsPut(defaultModel: model))))
    }
    public func deleteMemory(_ id: String) async throws {
        _ = try await send(request("DELETE", "v1/claude/memory/\(try ClaudeIds.check(id))"))
    }

    // MARK: ClaudeAPI

    public func status() async throws -> ClaudeStatus { try await call("GET", "v1/claude/status") }
    public func setApiFallback(_ on: Bool) async throws -> ClaudeStatus { try await call("PATCH", "v1/claude/settings", Settings(apiFallback: on)) }
    public func heartbeat(_ info: ClaudeCodeInfo) async throws -> ClaudeHeartbeatReply { try await call("POST", "v1/claude/mac/heartbeat", ClaudeHeartbeat(claudeCode: info)) }
    public func thread(contextKind: String, contextId: String) async throws -> ClaudeThread {
        try await call("POST", "v1/claude/threads", NewThread(contextKind: contextKind, contextId: contextId))
    }
    public func threadDetail(_ id: String) async throws -> ClaudeThreadDetail { try await call("GET", "v1/claude/threads/\(try ClaudeIds.check(id))") }
    public func threads(key: String) async throws -> [ClaudeThread] {
        guard let q = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "_-"))) else { throw ApiError("bad_request", "Bad key") }
        let list: ClaudeThreadList = try await call("GET", "v1/claude/threads?key=\(q)")
        return list.threads
    }
    public func newThread(contextKind: String, contextId: String) async throws -> ClaudeThread {
        try await call("POST", "v1/claude/threads", NewThread(contextKind: contextKind, contextId: contextId, new: true))
    }
    public func renameThread(_ id: String, title: String) async throws -> ClaudeThread {
        try await call("PATCH", "v1/claude/threads/\(try ClaudeIds.check(id))", TitlePatch(title: title))
    }
    public func deleteThread(_ id: String) async throws {
        _ = try await send(request("DELETE", "v1/claude/threads/\(try ClaudeIds.check(id))"))
    }
    public func setClaudeSession(threadId: String, claudeSessionId: String) async throws -> ClaudeThread {
        try await call("PATCH", "v1/claude/threads/\(try ClaudeIds.check(threadId))", SessionPatch(claudeSessionId: claudeSessionId))
    }
    public func postMessage(threadId: String, text: String) async throws -> ClaudeMessagePosted {
        try await call("POST", "v1/claude/threads/\(try ClaudeIds.check(threadId))/messages", Text(text: text))
    }
    public func pendingTurns() async throws -> [ClaudeTurn] { try await call("GET", "v1/claude/turns") }
    public func claim(turnId: String) async throws -> ClaudeTurn { try await call("POST", "v1/claude/turns/\(try ClaudeIds.check(turnId))/claim", Empty()) }
    public func stopTurn(_ turnId: String) async throws { _ = try await send(request("POST", "v1/claude/turns/\(try ClaudeIds.check(turnId))/stop", body: Data("{}".utf8))) }
    public func postEvents(threadId: String, _ batch: ClaudeEventBatch) async throws {
        _ = try await send(request("POST", "v1/claude/threads/\(try ClaudeIds.check(threadId))/events", body: try encoder.encode(batch), timeout: 60))
    }
    public func mcpSessionToken(ttlMinutes: Int?) async throws -> McpSessionToken { try await call("POST", "v1/mcp/session-token", TokenReq(ttlMinutes: ttlMinutes)) }

    public func apiTurn(threadId: String, text: String) -> AsyncThrowingStream<ChatEvent, Error> {
        turnStream { ("v1/claude/threads/\(try ClaudeIds.check(threadId))/api-turn", try JSONEncoder().encode(Text(text: text))) }
    }

    private struct ChatTurn: Encodable { var text: String; var page: ClaudePage? }
    /// One Claude: a turn on the studio's Claude key (members; the owner when her Mac's Claude Code isn't there).
    /// The `ui` lines (open a page, "Remembered …") also arrive as live events.
    public func chatTurn(chatId: String, text: String, page: ClaudePage?) -> AsyncThrowingStream<ChatEvent, Error> {
        turnStream { ("v1/claude/chats/\(try ClaudeIds.check(chatId))/turn", try JSONEncoder().encode(ChatTurn(text: text, page: page))) }
    }

    private func turnStream(_ target: @escaping @Sendable () throws -> (String, Data)) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task { [weak self] in
                guard let self else { cont.finish(); return }
                do {
                    let (path, body) = try target()
                    var r = self.request("POST", path, body: body, timeout: 600)
                    r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    #if canImport(FoundationNetworking)
                    let data = try await self.send(r)
                    for e in ChatStreamParser.parseAll(String(decoding: data, as: UTF8.self)) { cont.yield(e) }
                    #else
                    let (bytes, resp): (URLSession.AsyncBytes, URLResponse)
                    do { (bytes, resp) = try await self.session.bytes(for: r) } catch {
                        throw ApiError("offline", "Can't reach the server at \(self.baseURL.absoluteString)")
                    }
                    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = Data()
                        for try await b in bytes { body.append(b) }
                        try HTTPCameraAPI.check(resp, body, self.decoder)
                    }
                    var parser = ChatStreamParser()
                    var line = [UInt8]()
                    for try await b in bytes {
                        if Task.isCancelled { break }
                        if b == 0x0A {
                            if let e = parser.feed(String(decoding: line, as: UTF8.self)) { cont.yield(e) }
                            line.removeAll(keepingCapacity: true)
                        } else {
                            line.append(b)
                        }
                    }
                    if let e = parser.feed(String(decoding: line, as: UTF8.self)) { cont.yield(e) }
                    if let e = parser.feed("") { cont.yield(e) }
                    #endif
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Live events

    /// GET /v1/events filtered to `claude`. Reconnects with back-off while someone listens.
    /// (Linux builds have no streaming bytes API: they poll the queued turns every 5 s instead.)
    public func events() -> AsyncStream<ClaudeLiveEvent> {
        // Apple platforms: the app's shared stream (LiveEventHub), mapped to these events. Linux: the polling fallback below.
        if hub.canStream {
            return hub.events(baseURL: baseURL, token: token(), session: session, buffer: 512) { f -> ClaudeLiveEvent? in
                switch f {
                case .connected: return .connected
                case .disconnected: return .disconnected
                case .payload(let p): return ClaudeLiveEventFilter.parse(Data(p.utf8))
                }
            }
        }
        return AsyncStream(bufferingPolicy: .bufferingNewest(512)) { cont in
            let task = Task { [weak self] in
                var attempt = 0
                while !Task.isCancelled, let self {
                    do {
                        try await self.stream { e in
                            attempt = 0
                            cont.yield(e)
                        }
                    } catch {
                        attempt += 1
                    }
                    if Task.isCancelled { break }
                    cont.yield(.disconnected)
                    try? await Task.sleep(nanoseconds: UInt64(min(10, attempt + 1)) * 1_000_000_000)
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    private func stream(_ yield: @escaping (ClaudeLiveEvent) -> Void) async throws {
        #if canImport(FoundationNetworking)
        var first = true
        while !Task.isCancelled {
            let turns = try await pendingTurns()
            if first { yield(.connected); first = false }
            for t in turns { yield(.turn(t)) }
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        #else
        // Apple platforms stream through the shared hub (`events()`); this fallback is never reached there.
        throw ApiError("offline", "Live updates aren't available")
        #endif
    }
}

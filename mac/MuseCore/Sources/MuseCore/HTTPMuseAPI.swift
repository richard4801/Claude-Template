import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Incremental Server-Sent Events parser (text/event-stream). Feed it lines without their line ending;
/// it returns the `data` payload when a blank line ends an event.
public struct SSEParser: Sendable {
    private var data: [String] = []
    public private(set) var eventType: String?

    public init() {}

    public mutating func feed(_ rawLine: String) -> String? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty {
            defer { data = []; eventType = nil }
            return data.isEmpty ? nil : data.joined(separator: "\n")
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring = ""
        if let c = line.firstIndex(of: ":") {
            field = line[..<c]
            value = line[line.index(after: c)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
        }
        switch field {
        case "data": data.append(String(value))
        case "event": eventType = String(value)
        default: break
        }
        return nil
    }
}

/// MuseAPI over HTTP (plans/api.md): JSON over REST with a bearer token, and progress from the SSE stream at GET /v1/events.
public final class HTTPMuseAPI: MuseAPI, ClaudeVideoUploading, @unchecked Sendable {
    public let baseURL: URL
    private let session: URLSession
    private let lock = NSLock()
    private var token: String?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Performance pass: identical GETs in flight share one request; with `cacheCatalogs` (the app turns it on) the
    /// slow-changing catalogs (`CatalogCachePolicy`) are kept for a few minutes, dropped on any write, on the live events
    /// that change them, and on every (re)connect of the live stream.
    private let gets = RequestCoalescer<Data>()
    private let catalogCache = TTLCache<Data>()
    private let cacheCatalogs: Bool
    private let coalesceGets: Bool
    /// The shared GET /v1/events connection (one per server and session for the whole app).
    public let hub: LiveEventHub
    private let statsLock = NSLock()
    private var sentCount = 0
    private var cacheHits = 0

    public init(baseURL: URL, session: URLSession = .shared, cacheCatalogs: Bool = false, coalesceGets: Bool = true, hub: LiveEventHub = .shared) {
        self.baseURL = baseURL
        self.session = session
        self.cacheCatalogs = cacheCatalogs
        self.coalesceGets = coalesceGets
        self.hub = hub
    }

    /// Requests sent, GETs answered by one already in flight, and catalog cache hits (Settings → Developer's readout).
    public var requestStats: (sent: Int, joined: Int, cacheHits: Int) {
        statsLock.lock()
        defer { statsLock.unlock() }
        return (sentCount, gets.joined, cacheHits)
    }

    private func bump(_ hit: Bool) {
        statsLock.lock()
        if hit { cacheHits += 1 } else { sentCount += 1 }
        statsLock.unlock()
    }

    /// Forgets the cached catalogs (a manual Reload, a server switch).
    public func invalidateCache() { catalogCache.invalidate() }

    /// GET with coalescing and the catalog cache.
    private func get(_ path: String) async throws -> Data {
        let key = (currentToken ?? "") + " " + path
        let ttl = cacheCatalogs ? CatalogCachePolicy.ttl(for: path) : nil
        if ttl != nil, let d = catalogCache.get(key) {
            bump(true)
            return d
        }
        let version = catalogCache.version
        let d: Data
        if coalesceGets {
            d = try await gets.run(key) { [self] in try await send(request("GET", path)) }
        } else {
            d = try await send(request("GET", path))
        }
        if let ttl { catalogCache.put(key, d, ttl: ttl, ifVersion: version) }
        return d
    }

    public func setToken(_ token: String?) async { storeToken(token) }

    private func storeToken(_ t: String?) {
        lock.lock()
        token = t
        lock.unlock()
    }

    private var currentToken: String? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    /// The signed-in session's token, in memory whether or not "Remember me" kept it in the Keychain (workstream 2: the Blender relay).
    public var sessionToken: String? { currentToken }

    // MARK: Plumbing

    public func url(_ path: String) -> URL {
        var s = baseURL.absoluteString
        if !s.hasSuffix("/") { s += "/" }
        return URL(string: s + path)!
    }

    func request(_ method: String, _ path: String, body: Data? = nil, contentType: String = "application/json") -> URLRequest {
        var r = URLRequest(url: url(path))
        r.httpMethod = method
        // Shoots and outfit sets make the images before answering, which can take a few minutes.
        let long = method == "POST" && (path == "v1/shoots" || path == "v1/outfits" || (path.hasPrefix("v1/outfits/") && path.hasSuffix("/save")))
        r.timeoutInterval = long ? 360 : 30
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let t = currentToken { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if let body {
            r.httpBody = body
            r.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func send(_ r: URLRequest) async throws -> Data {
        bump(false)
        // Any write may change what a cached catalog says.
        if r.httpMethod != "GET" { catalogCache.invalidate() }
        let (data, resp): (Data, URLResponse?)
        do {
            (data, resp) = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, URLResponse?), Error>) in
                session.dataTask(with: r) { d, r, e in
                    if let e { cont.resume(throwing: e) } else { cont.resume(returning: (d ?? Data(), r)) }
                }.resume()
            }
        } catch let e as URLError where e.code == .timedOut {
            throw ApiError("still_working", "Still working on it. It keeps going on the server, and the results will appear in the Library.")
        } catch {
            throw ApiError("offline", "Can't reach the server at \(baseURL.absoluteString)")
        }
        guard let http = resp as? HTTPURLResponse else { return data }
        if !(200..<300).contains(http.statusCode) {
            let err = try? decoder.decode(ErrorBody.self, from: data)
            throw ApiError(err?.code ?? "http_\(http.statusCode)", err?.error ?? ApiError.plainHTTP(http.statusCode))
        }
        return data
    }

    private func call<T: Decodable>(_ method: String, _ path: String) async throws -> T {
        if method == "GET" { return try decode(try await get(path)) }
        return try decode(try await send(request(method, path)))
    }

    private func call<T: Decodable, B: Encodable>(_ method: String, _ path: String, _ body: B) async throws -> T {
        try decode(try await send(request(method, path, body: try encoder.encode(body))))
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ApiError("bad_response", "Unexpected reply from the server (\(T.self))")
        }
    }

    // AI suite (workstream 1): the JSON round trip for Suite/SuiteHTTP.swift.
    func suiteCall<T: Decodable>(_ method: String, _ path: String, body: Data? = nil) async throws -> T {
        if method == "GET" && body == nil { return try decode(try await get(path)) }
        return try decode(try await send(request(method, path, body: body)))
    }
    /// A call whose reply has nothing to read (DELETE).
    func suiteSend(_ method: String, _ path: String) async throws { _ = try await send(request(method, path)) }
    /// A reference video or audio track for a shot's input slots: editor presign (an upload in this studio) + PUT → its storage key.
    public func uploadSuiteMedia(_ file: URL, contentType: String, progress: UploadProgress?) async throws -> SuiteVideoRef {
        let body = UploadBody.file(file)
        let ticket: PresignedUpload = try await call("POST", "v1/editor/uploads/presign", EditorPresignBody(contentType: contentType, bytes: body.size, purpose: nil))
        guard let target = resolve(ticket.url) else { throw ApiError("upload_failed", "Couldn't upload the file") }
        var put = URLRequest(url: target)
        put.httpMethod = ticket.method.isEmpty ? "PUT" : ticket.method
        put.timeoutInterval = 600
        for (k, v) in ticket.headers { put.setValue(v, forHTTPHeaderField: k) }
        if put.value(forHTTPHeaderField: "Content-Type") == nil { put.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if target.host == baseURL.host, target.port == baseURL.port, let t = currentToken { put.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        try await putBytes(put, body: body, progress: progress)
        guard let f = ticket.fileUrl else { throw ApiError("upload_failed", "The upload has no address") }
        if let r = f.range(of: "/uploads/"), !f[r.upperBound...].isEmpty { return SuiteVideoRef(key: String(f[r.upperBound...])) }
        return SuiteVideoRef(url: f)
    }
    /// Recreate this edit (workstream 2): a video to analyse, presigned and uploaded like the editor's; returns its upload id.
    func uploadVideoForAnalysis(_ file: URL, contentType: String, progress: UploadProgress?) async throws -> String {
        let body = UploadBody.file(file)
        let ticket: PresignedUpload = try await call("POST", "v1/editor/uploads/presign", EditorPresignBody(contentType: contentType, bytes: body.size, purpose: nil))
        guard let target = resolve(ticket.url) else { throw ApiError("upload_failed", "Couldn't upload the video") }
        var put = URLRequest(url: target)
        put.httpMethod = ticket.method.isEmpty ? "PUT" : ticket.method
        put.timeoutInterval = 600
        for (k, v) in ticket.headers { put.setValue(v, forHTTPHeaderField: k) }
        if put.value(forHTTPHeaderField: "Content-Type") == nil { put.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if target.host == baseURL.host, target.port == baseURL.port, let t = currentToken { put.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        try await putBytes(put, body: body, progress: progress)
        return ticket.uploadId
    }
    // End AI suite (workstream 1)

    /// Server image paths ("/files/x.jpg") become absolute so the app can load them.
    func absolutize(_ ref: ImageRef) -> ImageRef {
        guard let u = ref.url, u.hasPrefix("/") else { return ref }
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return ImageRef(asset: ref.asset, url: base + u)
    }

    // MARK: MuseAPI

    public func signIn(_ req: SignInRequest) async throws -> AuthResponse { try await call("POST", "v1/auth/signin", req) }
    public func signUp(_ req: SignUpRequest) async throws -> AuthResponse { try await call("POST", "v1/auth/signup", req) }
    public func signOut() async throws { _ = try await send(request("POST", "v1/auth/signout", body: try encoder.encode(Empty()))) }
    public func me() async throws -> User { try await call("GET", "v1/auth/me") }

    // Tokens, members and studio settings
    public func wallet() async throws -> Wallet { try await call("GET", "v1/wallet") }
    public func createInvite(_ req: InviteRequest) async throws -> Invite { try await call("POST", "v1/invites", req) }
    public func listMembers() async throws -> [Member] { try await call("GET", "v1/members") }
    public func updateMember(id: String, _ patch: MemberPatch) async throws -> Member { try await call("PATCH", "v1/members/\(id)", patch) }
    public func sendTokens(_ move: TokenMove) async throws -> TokenMoveResult {
        try await call("POST", "v1/wallets/transfer", TransferBody(toUserId: move.userId, tokens: move.tokens, note: move.note))
    }
    public func takeBackTokens(_ move: TokenMove) async throws -> TokenMoveResult {
        try await call("POST", "v1/wallets/reclaim", ReclaimBody(fromUserId: move.userId, tokens: move.tokens, note: move.note))
    }
    public func imageEngine() async throws -> ImageEngine { try await call("GET", "v1/settings/image-engine") }
    public func setImageEngine(_ req: ImageEngineRequest) async throws -> ImageEngine { try await call("PATCH", "v1/settings/image-engine", req) }
    public func studioSettings() async throws -> StudioSettings { try await call("GET", "v1/settings/studio") }
    public func updateStudioSettings(_ patch: StudioSettingsPatch) async throws -> StudioSettings { try await call("PATCH", "v1/settings/studio", patch) }
    public func listModels() async throws -> [MuseModel] { try await call("GET", "v1/models") }
    public func createModel(_ req: CreateModelRequest) async throws -> MuseModel { try await call("POST", "v1/models", req) }
    public func setSlot(modelId: String, slot: String, _ req: SetSlotRequest) async throws -> MuseModel { try await call("PUT", "v1/models/\(modelId)/slots/\(slot)", req) }
    public func fillAngles(modelId: String) async throws -> FillAnglesResponse { try await call("POST", "v1/models/\(modelId)/fill-angles", Empty()) }
    /// Owner only (WS13): the sheet's missing angles on this image model.
    public func fillAngles(modelId: String, imageModel: String) async throws -> FillAnglesResponse {
        struct Body: Encodable { var imageModel: String }
        return try await call("POST", "v1/models/\(modelId)/fill-angles", Body(imageModel: imageModel))
    }
    public func listOutfits() async throws -> [Outfit] { try await call("GET", "v1/outfits") }
    public func createOutfit(_ req: CreateOutfitRequest) async throws -> Outfit { try await call("POST", "v1/outfits", req) }
    public func saveOutfit(outfitId: String, name: String?) async throws -> Outfit { try await call("POST", "v1/outfits/\(Self.pathKey(outfitId))/save", OutfitName(name: name)) }
    public func renameOutfit(id: String, name: String) async throws -> Outfit { try await call("PATCH", "v1/outfits/\(Self.pathKey(id))", OutfitName(name: name)) }
    public func deleteOutfit(id: String) async throws { _ = try await send(request("DELETE", "v1/outfits/\(Self.pathKey(id))")) }
    public func fillOutfit(id: String, imageModel: String?) async throws -> OutfitFill {
        try await call("POST", "v1/outfits/\(Self.pathKey(id))/fill", OutfitFillBody(imageModel: imageModel))
    }
    private struct OutfitName: Encodable { var name: String? }
    private struct OutfitFillBody: Encodable { var imageModel: String? }

    /// Images: presign → PUT → confirm. A server without presigned uploads (server/mock), or a PUT that can't reach storage, falls back to multipart.
    public func uploadImage(name: String, data: Data, mime: String, progress: UploadProgress?) async throws -> ImageRef {
        progress?(0)
        if let ref: ImageRef = try await presigned(kind: "image", contentType: mime, body: .data(data), meta: nil, progress: progress) {
            progress?(1)
            return absolutize(ref)
        }
        var form = Multipart()
        form.addFile("file", filename: name, mime: mime, data: data)
        let ref: ImageRef = try decode(try await send(request("POST", "v1/uploads/images", body: form.finish(), contentType: form.contentType)))
        progress?(1)
        return absolutize(ref)
    }

    /// Clips: with a file, presign → PUT → confirm {meta}; without one (the sample clips), or as the fallback, multipart.
    public func uploadClip(_ meta: ClipMeta, file: URL?, progress: UploadProgress?) async throws -> Clip {
        progress?(0)
        if let file, let clip: Clip = try await presigned(kind: "clip", contentType: HTTPMuseAPI.videoType(file), body: .file(file), meta: meta, progress: progress) {
            progress?(1)
            return absolutize(clip)
        }
        var form = Multipart()
        form.addField("meta", value: try encoder.encode(meta), mime: "application/json")
        if let file { form.addFile("file", filename: file.lastPathComponent, mime: HTTPMuseAPI.videoType(file), data: try Data(contentsOf: file)) }
        let clip: Clip = try decode(try await send(request("POST", "v1/uploads/clips", body: form.finish(), contentType: form.contentType)))
        progress?(1)
        return absolutize(clip)
    }

    static func videoType(_ file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "mov", "qt": return "video/quicktime"
        case "m4v": return "video/x-m4v"
        case "webm": return "video/webm"
        default: return "video/mp4"
        }
    }

    enum UploadBody {
        case data(Data)
        case file(URL)
        var size: Int? {
            switch self {
            case .data(let d): return d.count
            case .file(let u): return (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.intValue
            }
        }
    }

    /// presign → PUT the bytes → confirm. Returns nil when the server has no presigned uploads or the PUT can't reach storage,
    /// so the caller can use the multipart upload instead. Errors from confirm (and from presign other than "not there") are thrown.
    func presigned<T: Decodable>(kind: String, contentType: String, body: UploadBody, meta: ClipMeta?, progress: UploadProgress?) async throws -> T? {
        guard let uploadId = try await presignAndPut(kind: kind, contentType: contentType, body: body, progress: progress) else { return nil }
        return try await call("POST", "v1/uploads/\(uploadId)/confirm", ConfirmBody(meta: meta))
    }

    /// presign → PUT, without confirm. The upload id, or nil when the server has no presigned uploads or storage can't be reached.
    func presignAndPut(kind: String, contentType: String, body: UploadBody, progress: UploadProgress?) async throws -> String? {
        let ticket: PresignedUpload
        do {
            ticket = try await call("POST", "v1/uploads/presign", PresignBody(kind: kind, contentType: contentType, bytes: body.size))
        } catch let e as ApiError where e.code == "not_found" || e.code == "http_404" || e.code == "bad_response" {
            return nil
        }
        // Local storage (dev servers) answers with a link to this API, possibly relative: resolve it against the base URL.
        guard let target = resolve(ticket.url) else { return nil }
        var put = URLRequest(url: target)
        put.httpMethod = ticket.method.isEmpty ? "PUT" : ticket.method
        put.timeoutInterval = 600
        for (k, v) in ticket.headers { put.setValue(v, forHTTPHeaderField: k) }
        if put.value(forHTTPHeaderField: "Content-Type") == nil { put.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if target.host == baseURL.host, target.port == baseURL.port, let t = currentToken { put.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        do {
            try await putBytes(put, body: body, progress: progress)
        } catch {
            return nil
        }
        return ticket.uploadId
    }

    /// A video for a Claude chat message (plans/claude-video-vision.md): an upload of kind "clip", presigned, PUT and
    /// confirmed with its meta. → its upload id, marked as a video. Confirm also lists it among the studio's clips.
    public func uploadClaudeVideo(_ file: URL, meta: ClipMeta, contentType: String, progress: UploadProgress?) async throws -> ClaudeAttachment {
        let body = UploadBody.file(file)
        guard let id = try await presignAndPut(kind: "clip", contentType: contentType, body: body, progress: progress) else {
            throw ApiError("upload_failed", "Couldn't upload the video. Try again.")
        }
        let _: ClaudeVideoConfirmed = try await call("POST", "v1/uploads/\(Self.pathKey(id))/confirm", ConfirmBody(meta: meta))
        return ClaudeAttachment(uploadId: id, mimeType: contentType, bytes: body.size, video: true)
    }
    /// Confirm's reply (a clip) is not needed here: any JSON object reads.
    private struct ClaudeVideoConfirmed: Decodable {}

    // MARK: Edit suite (workstream 3): Editor v2 jobs, uploads, LUT check, v2 versions

    private struct EditorPresignBody: Encodable { var contentType: String; var bytes: Int?; var purpose: String? }
    private struct LutValidateBody: Encodable { var uploadId: String }
    private struct StateReply: Decodable { var state: String? }

    public func editorEstimate(_ req: EditorJobRequest) async throws -> EditorEstimate { try await call("POST", "v1/editor/estimate", req) }
    public func editorFeatures() async throws -> EditorFeatures? { try await call("GET", "v1/editor/features") }
    public func startEditorJob(_ req: EditorJobRequest) async throws -> EditorJob { try await call("POST", "v1/editor/jobs", req) }
    public func editorJob(id: String) async throws -> EditorJob { try await call("GET", "v1/editor/jobs/\(Self.pathKey(id))") }
    public func cancelEditorJob(id: String) async throws { let _: StateReply = try await call("DELETE", "v1/editor/jobs/\(Self.pathKey(id))") }
    public func editKits() async throws -> [EditKit] { let r: EditKitList = try await call("GET", "v1/editor/kits"); return r.kits }
    public func saveEditKit(name: String, kit: EditV2.StyleKit) async throws -> EditKit { try await call("POST", "v1/editor/kits", EditKitBody(name: name, kit: kit)) }
    public func updateEditKit(id: String, name: String?, kit: EditV2.StyleKit?) async throws -> EditKit {
        try await call("PATCH", "v1/editor/kits/\(Self.pathKey(id))", EditKitBody(name: name, kit: kit))
    }
    public func deleteEditKit(id: String) async throws { _ = try await send(request("DELETE", "v1/editor/kits/\(Self.pathKey(id))")) }
    public func editorContent() async throws -> ContentCatalog? {
        do { return try await call("GET", "v1/editor/content") as ContentCatalog } catch let e as ApiError where e.code == "not_found" || e.code == "http_404" { return nil }
    }
    public func editorContentFile(_ path: String, version: String) async throws -> URL {
        let dst = try ContentFiles.local(path, version: version)
        if FileManager.default.fileExists(atPath: dst.path) { return dst }
        // Public and static: no token, and the redirect to storage is followed.
        var r = URLRequest(url: url("v1/editor/content/files/" + path))
        r.timeoutInterval = 60
        let data = try await send(r)
        try ContentFiles.store(data, at: dst)
        return dst
    }
    public func validateLut(uploadId: String) async throws -> LutValidation { try await call("POST", "v1/editor/luts/validate", LutValidateBody(uploadId: uploadId)) }
    public func checkFont(uploadId: String) async throws -> FontCheck { try await call("POST", "v1/editor/uploads/font-check", LutValidateBody(uploadId: uploadId)) }

    public func uploadEditorFile(_ file: URL, contentType: String, purpose: String?, progress: UploadProgress?) async throws -> String {
        let body = UploadBody.file(file)
        let ticket: PresignedUpload = try await call("POST", "v1/editor/uploads/presign", EditorPresignBody(contentType: contentType, bytes: body.size, purpose: purpose))
        guard let target = resolve(ticket.url) else { throw ApiError("upload_failed", "Couldn't upload the file") }
        var put = URLRequest(url: target)
        put.httpMethod = ticket.method.isEmpty ? "PUT" : ticket.method
        put.timeoutInterval = 600
        for (k, v) in ticket.headers { put.setValue(v, forHTTPHeaderField: k) }
        if put.value(forHTTPHeaderField: "Content-Type") == nil { put.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if target.host == baseURL.host, target.port == baseURL.port, let t = currentToken { put.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        try await putBytes(put, body: body, progress: progress)
        return ticket.uploadId
    }

    public func createTakeVersionV2(takeId: String, _ req: TakeVersionV2Request) async throws -> Take {
        // A blank project's first save (no source take): POST /v1/edits makes it a new Library video.
        if takeId == EditV2.blankSourceId { return absolutize(try await call("POST", "v1/edits", req)) }
        return absolutize(try await call("POST", "v1/takes/\(Self.pathKey(takeId))/versions", req))
    }

    // MARK: Edit sessions (workstream 3): the live edit shared with Claude (plans/api.md "Edit sessions")

    private struct UndoBody: Encodable { var entryId: Int; var device: String }
    private struct FrameBody: Encodable { var uploadId: String }
    private struct ApproveBody: Encodable { var approve: Bool }
    private struct OkReply: Decodable { var ok: Bool? }

    private func es(_ id: String) -> String { "v1/edit-sessions/\(Self.pathKey(id))" }
    public func openEditSession(_ req: EditSessionOpenRequest) async throws -> EditSession { try await call("POST", "v1/edit-sessions", req) }
    public func editSession(id: String) async throws -> EditSession { try await call("GET", es(id)) }
    public func pushEditPatch(sessionId: String, _ req: EditPatchRequest) async throws -> EditChangeResult { try await call("POST", "\(es(sessionId))/patch", req) }
    public func undoEditChange(sessionId: String, entryId: Int, device: String) async throws -> EditChangeResult {
        try await call("POST", "\(es(sessionId))/undo", UndoBody(entryId: entryId, device: device))
    }
    public func announceEditPresence(sessionId: String, _ p: EditPresence) async throws { let _: OkReply = try await call("POST", "\(es(sessionId))/presence", p) }
    public func leaveEditSession(sessionId: String, device: String) async throws {
        let _: OkReply = try await call("DELETE", "\(es(sessionId))/presence/\(Self.pathKey(device))")
    }
    public func uploadEditFrame(png: Data) async throws -> String {
        guard let id = try await presignAndPut(kind: "image", contentType: "image/png", body: .data(png), progress: nil) else {
            throw ApiError("upload_failed", "Couldn't upload the frame")
        }
        return id
    }
    public func answerEditFrame(sessionId: String, requestId: String, uploadId: String) async throws {
        let _: OkReply = try await call("POST", "\(es(sessionId))/frames/\(Self.pathKey(requestId))", FrameBody(uploadId: uploadId))
    }
    public func answerEditAppRequest(sessionId: String, requestId: String, _ answer: EditAppRequestAnswer) async throws {
        let _: EditAppRequest = try await call("POST", "\(es(sessionId))/requests/\(Self.pathKey(requestId))", answer)
    }
    public func answerEditPending(sessionId: String, pendingId: String, approve: Bool) async throws -> EditPending {
        try await call("POST", "\(es(sessionId))/pending/\(Self.pathKey(pendingId))", ApproveBody(approve: approve))
    }
    public func closeEditSession(id: String) async throws { let _: OkReply = try await call("POST", "\(es(id))/close", Empty()) }
    // End edit sessions (workstream 3)

    // MARK: Video editor (edited versions of a take)


    /// The edited .mp4 (presigned `clip`, PUT, no confirm: confirming would add it to the clip library) and its JPEG thumbnail
    /// (presigned `image`, PUT). A thumbnail that can't be uploaded is left out (the server then uses the source's).
    public func uploadEditedVideo(_ video: EditedVideo, progress: UploadProgress?) async throws -> EditedUpload {
        progress?(0)
        guard let id = try await presignAndPut(kind: "clip", contentType: "video/mp4", body: .file(video.file), progress: { p in progress?(p * 0.97) }) else {
            throw ApiError("upload_failed", "Couldn't upload the edit. Check your connection and try again.")
        }
        var thumbId: String?
        if let jpeg = video.thumbJPEG {
            thumbId = try? await presignAndPut(kind: "image", contentType: "image/jpeg", body: .data(jpeg), progress: nil)
        }
        progress?(1)
        return EditedUpload(uploadId: id, thumbUploadId: thumbId)
    }

    public func createTakeVersion(takeId: String, _ req: TakeVersionRequest) async throws -> Take {
        absolutize(try await call("POST", "v1/takes/\(Self.pathKey(takeId))/versions", req))
    }

    public func takeVersions(takeId: String) async throws -> [Take] {
        (try await call("GET", "v1/takes/\(Self.pathKey(takeId))/versions") as [Take]).map(absolutize)
    }

    func resolve(_ link: String) -> URL? {
        if link.hasPrefix("/") { return url(String(link.dropFirst())) }
        return URL(string: link)
    }

    private func putBytes(_ r: URLRequest, body: UploadBody, progress: UploadProgress?) async throws {
        let resp: URLResponse?
        #if canImport(FoundationNetworking)
        // swift-corelibs-foundation: no per-task delegates, so no progress until the end (Linux builds only, for tests).
        let data: Data
        switch body {
        case .data(let d): data = d
        case .file(let u): data = try Data(contentsOf: u)
        }
        resp = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URLResponse?, Error>) in
            session.uploadTask(with: r, from: data) { _, r, e in
                if let e { cont.resume(throwing: e) } else { cont.resume(returning: r) }
            }.resume()
        }
        #else
        let delegate = UploadProgressDelegate(progress)
        switch body {
        case .data(let d): resp = try await session.upload(for: r, from: d, delegate: delegate).1
        case .file(let u): resp = try await session.upload(for: r, fromFile: u, delegate: delegate).1
        }
        #endif
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ApiError("http_\(http.statusCode)", "Upload refused (\(http.statusCode))")
        }
    }

    public func updateModel(id: String, _ req: UpdateModelRequest) async throws -> MuseModel { try await call("PATCH", "v1/models/\(id)", req) }
    public func deleteModel(id: String) async throws { _ = try await send(request("DELETE", "v1/models/\(id)")) }

    // Identity LoRA
    public func lora(modelId: String) async throws -> Lora { absolutize(try await call("GET", "v1/models/\(modelId)/lora")) }
    public func buildLoraCandidates(modelId: String) async throws -> Lora { absolutize(try await call("POST", "v1/models/\(modelId)/lora/candidates", Empty())) }
    public func setLoraCandidate(modelId: String, candidateId: String, keep: Bool) async throws -> Lora {
        absolutize(try await call("PATCH", "v1/models/\(modelId)/lora/candidates/\(candidateId)", LoraCandidateRequest(keep: keep)))
    }
    public func trainLora(modelId: String) async throws -> Lora { absolutize(try await call("POST", "v1/models/\(modelId)/lora/train", Empty())) }
    public func setLoraUse(modelId: String, use: Bool) async throws -> Lora { absolutize(try await call("PATCH", "v1/models/\(modelId)/lora", LoraPatchRequest(use: use))) }

    public func retrainLora(modelId: String) async throws -> Lora { absolutize(try await call("PATCH", "v1/models/\(modelId)/lora", LoraPatchRequest(state: "review"))) }

    func absolutize(_ l: Lora) -> Lora {
        var out = l
        for i in out.candidates.indices { out.candidates[i].image = absolutize(out.candidates[i].image) }
        return out
    }

    // Social accounts and posts
    public func listAccounts(modelId: String) async throws -> [Account] { try await call("GET", "v1/models/\(modelId)/accounts") }
    public func connectAccount(modelId: String, platform: Platform) async throws -> ConnectResult {
        let data = try await send(request("POST", "v1/models/\(modelId)/accounts/\(platform.rawValue)/connect", body: try encoder.encode(Empty())))
        do { return try ConnectResult.decode(data, decoder: decoder) } catch { throw ApiError("bad_response", "Unexpected reply from the server (connect)") }
    }
    public func disconnectAccount(modelId: String, platform: Platform) async throws {
        _ = try await send(request("DELETE", "v1/models/\(modelId)/accounts/\(platform.rawValue)"))
    }
    public func listPosts(state: String?) async throws -> [Post] {
        let list: [Post]
        if let state, let q = state.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { list = try await call("GET", "v1/posts?state=\(q)") } else { list = try await call("GET", "v1/posts") }
        return list.map(absolutize)
    }
    public func createPost(_ req: CreatePostRequest) async throws -> Post { absolutize(try await call("POST", "v1/posts", req)) }

    func absolutize(_ p: Post) -> Post {
        var out = p
        out.thumb = p.thumb.map(absolutize)
        return out
    }
    public func deletePost(id: String) async throws { _ = try await send(request("DELETE", "v1/posts/\(id)")) }

    public func listJobs() async throws -> [Job] { (try await call("GET", "v1/jobs") as [Job]).map(absolutize) }
    public func createJob(_ req: JobRequest) async throws -> Job { absolutize(try await call("POST", "v1/jobs", req)) }
    public func removeJob(id: String) async throws { _ = try await send(request("DELETE", "v1/jobs/\(id)")) }

    public func runQueue() async throws {
        // In plans/api.md since 2026-11-04. Older servers start jobs on their own and answer 404, which is ignored.
        do { _ = try await send(request("POST", "v1/queue/run", body: try encoder.encode(Empty()))) } catch let e as ApiError where e.code == "http_404" || e.code == "not_found" {}
    }

    public func listTakes() async throws -> [Take] { (try await call("GET", "v1/takes") as [Take]).map(absolutize) }
    public func setTakeStatus(id: String, status: String) async throws -> Take { absolutize(try await call("PATCH", "v1/takes/\(id)", SetTakeStatusRequest(status: status))) }
    public func deleteTake(id: String) async throws { _ = try await send(request("DELETE", "v1/takes/\(id)")) }
    public func shoot(_ req: ShootRequest) async throws -> [Take] { (try await call("POST", "v1/shoots", req) as [Take]).map(absolutize) }
    public func shootPreview(_ req: ShootRequest) async throws -> ShootPreview { try await call("POST", "v1/shoots/preview", req) }

    public func prompts() async throws -> PromptLibrary { try await call("GET", "v1/prompts") }
    public func setPrompt(key: String, text: String) async throws -> PromptEntry { try await call("PUT", "v1/prompts/\(Self.pathKey(key))", SetPromptRequest(text: text)) }
    public func resetPrompt(key: String) async throws -> PromptEntry { try await call("DELETE", "v1/prompts/\(Self.pathKey(key))") }
    public func previewPrompt(_ req: PromptPreviewRequest) async throws -> PromptPreview { try await call("POST", "v1/prompts/preview", req) }

    // Prompt scripts (workstream 4)
    public func promptScripts() async throws -> PromptScriptsList { try await call("GET", "v1/prompt-scripts") }
    public func promptScript(id: String) async throws -> ScriptView { try await call("GET", "v1/prompt-scripts/\(Self.pathKey(id))") }
    public func savePromptScript(id: String, rules: [ScriptRule]) async throws -> ScriptView {
        try await call("PUT", "v1/prompt-scripts/\(Self.pathKey(id))", SaveScriptRequest(rules: rules))
    }
    public func resetPromptScript(id: String) async throws -> ScriptView { try await call("DELETE", "v1/prompt-scripts/\(Self.pathKey(id))") }
    public func previewPromptScript(_ req: ScriptPreviewRequest) async throws -> ScriptPreview { try await call("POST", "v1/prompt-scripts/preview", req) }

    /// Library keys are dotted ("shoot.camera"); anything else is percent-encoded for the path.
    static func pathKey(_ key: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: ".-_")
        return key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
    }

    /// Relative video and image links ("/uploads/x.mp4") become absolute.
    func absolutize(_ t: Take) -> Take {
        var out = t
        out.thumb = absolutize(t.thumb)
        if let v = t.videoUrl, v.hasPrefix("/") { out.videoUrl = absolutize(ImageRef(url: v)).url }
        return out
    }

    func absolutize(_ j: Job) -> Job {
        var out = j
        out.thumb = j.thumb.map(absolutize)
        return out
    }
    // Photo templates
    public func listTemplates(_ query: TemplateQuery) async throws -> [MuseTemplate] {
        var c = URLComponents()
        c.queryItems = query.queryItems
        return (try await call("GET", "v1/templates" + (c.percentEncodedQuery.map { "?" + $0 } ?? "")) as [MuseTemplate]).map(absolutize)
    }
    public func template(id: String) async throws -> MuseTemplate { absolutize(try await call("GET", "v1/templates/\(id)")) }
    public func createTemplate(_ req: CreateTemplateRequest) async throws -> MuseTemplate { absolutize(try await call("POST", "v1/templates", req)) }
    public func templateDraft(fromShotId: String) async throws -> TemplateDraft {
        var d: TemplateDraft = try await call("POST", "v1/templates/draft", TemplateDraftRequest(fromShotId: fromShotId))
        d.cover = d.cover.map(absolutize)
        return d
    }
    public func updateTemplate(id: String, _ patch: TemplatePatch) async throws -> MuseTemplate { absolutize(try await call("PATCH", "v1/templates/\(id)", patch)) }
    public func deleteTemplate(id: String) async throws { _ = try await send(request("DELETE", "v1/templates/\(id)")) }
    public func duplicateTemplate(id: String) async throws -> MuseTemplate { absolutize(try await call("POST", "v1/templates/\(id)/duplicate", Empty())) }
    public func setTemplateFavourite(id: String, _ on: Bool) async throws -> MuseTemplate {
        on ? absolutize(try await call("POST", "v1/templates/\(id)/favourite", Empty())) : absolutize(try await call("DELETE", "v1/templates/\(id)/favourite"))
    }
    public func templatePrompt(id: String, _ req: TemplatePromptRequest) async throws -> TemplatePrompt { try await call("POST", "v1/templates/\(id)/prompt", req) }

    func absolutize(_ t: MuseTemplate) -> MuseTemplate {
        var t = t
        t.cover = t.cover.map(absolutize)
        t.recent = t.recent?.map { r in
            var r = r
            r.thumb = absolutize(r.thumb)
            return r
        }
        return t
    }

    public func warmGpu() async throws -> WarmGpu { try await call("GET", "v1/gpu/warm") }
    public func setWarmGpu(_ req: WarmGpuRequest) async throws -> WarmGpu { try await call("POST", "v1/gpu/warm", req) }

    public func balance() async throws -> Balance { try await call("GET", "v1/balance") }
    public func topUp(_ req: TopUpRequest) async throws -> Balance { try await call("POST", "v1/balance/topup", req) }
    public func studioBalance() async throws -> StudioBalance { try await call("GET", "v1/studio/balance") }
    public func recordTopUp(_ req: TopUpRecord) async throws -> StudioBalance { try await call("POST", "v1/studio/topups", req) }
    public func upscale(takeId: String, _ req: UpscaleRequest) async throws -> Job { absolutize(try await call("POST", "v1/takes/\(takeId)/upscale", req)) }
    // MARK: Model tools

    public func imageModels() async throws -> [StepModel] { (try await call("GET", "v1/image-models") as ImageModelsResponse).steps }
    public func setImageModel(step: ImageStep, _ req: SetImageModelRequest) async throws -> StepModel { try await call("PUT", "v1/image-models/\(step.rawValue)", req) }
    public func resetImageModel(step: ImageStep) async throws -> StepModel { try await call("DELETE", "v1/image-models/\(step.rawValue)") }
    public func imageModelCatalog(_ query: CatalogQuery) async throws -> CatalogResponse {
        var c = URLComponents()
        c.queryItems = query.queryItems
        return try await call("GET", "v1/image-models/catalog" + (c.percentEncodedQuery.map { "?" + $0 } ?? ""))
    }
    public func imageModelCollections() async throws -> [CatalogCollectionRef] { try await call("GET", "v1/image-models/collections") }
    public func imageModelDetail(id: String, step: ImageStep) async throws -> ModelDetail {
        var c = URLComponents()
        c.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "step", value: step.rawValue)]
        return try await call("GET", "v1/image-models/model?" + (c.percentEncodedQuery ?? ""))
    }

    public func enhanceEstimate(modelId: String, _ req: EnhanceRequest) async throws -> ToolEstimate { try await call("POST", "v1/models/\(modelId)/enhance/estimate", req) }
    public func enhance(modelId: String, _ req: EnhanceRequest) async throws -> ToolRun { absolutize(try await call("POST", "v1/models/\(modelId)/enhance", req)) }
    public func dressUpEstimate(modelId: String, _ req: DressUpEstimateRequest) async throws -> ToolEstimate {
        try await call("POST", "v1/models/\(modelId)/dress-up/estimate", req)
    }
    public func dressUp(modelId: String, _ req: DressUpRequest) async throws -> ToolRun { absolutize(try await call("POST", "v1/models/\(modelId)/dress-up", req)) }
    public func listToolRuns(_ query: ToolRunQuery) async throws -> [ToolRun] {
        var c = URLComponents()
        c.queryItems = [query.modelId.map { URLQueryItem(name: "modelId", value: $0) }, query.kind.map { URLQueryItem(name: "kind", value: $0) }].compactMap { $0 }
        let q = (c.queryItems?.isEmpty ?? true) ? "" : "?" + (c.percentEncodedQuery ?? "")
        return (try await call("GET", "v1/tool-runs" + q) as [ToolRun]).map(absolutize)
    }
    public func toolRun(id: String) async throws -> ToolRun { absolutize(try await call("GET", "v1/tool-runs/\(id)")) }
    public func decideToolItem(runId: String, slot: String, _ req: ToolDecisionRequest) async throws -> ToolRun {
        absolutize(try await call("PATCH", "v1/tool-runs/\(runId)/items/\(slot)", req))
    }
    public func pickToolRun(runId: String, pick: String) async throws -> ToolRun { absolutize(try await call("POST", "v1/tool-runs/\(runId)/pick", ToolPickRequest(pick: pick))) }
    public func retryToolItem(runId: String, slot: String, engine: String?) async throws -> ToolRun {
        absolutize(try await call("POST", "v1/tool-runs/\(runId)/items/\(slot)/retry", ToolRetryRequest(engine: engine)))
    }
    public func applyToolRun(runId: String, _ req: ToolApplyRequest) async throws -> ToolApplyResponse {
        var r: ToolApplyResponse = try await call("POST", "v1/tool-runs/\(runId)/apply", req)
        r.run = absolutize(r.run)
        r.model = absolutize(r.model)
        r.outfit = r.outfit.map(absolutize)
        return r
    }
    public func discardToolRun(runId: String) async throws { _ = try await send(request("DELETE", "v1/tool-runs/\(runId)")) }
    public func sheetVersions(modelId: String) async throws -> [SheetVersion] {
        (try await call("GET", "v1/models/\(modelId)/sheet-versions") as [SheetVersion]).map { v in
            var v = v
            v.slots = v.slots.map(absolutize)
            return v
        }
    }
    public func restoreSheetVersion(modelId: String, versionId: String) async throws -> MuseModel {
        absolutize(try await call("POST", "v1/models/\(modelId)/sheet-versions/\(versionId)/restore", Empty()))
    }
    public func archiveModel(id: String) async throws -> MuseModel { absolutize(try await call("POST", "v1/models/\(id)/archive", Empty())) }
    public func unarchiveModel(id: String) async throws -> MuseModel { absolutize(try await call("POST", "v1/models/\(id)/unarchive", Empty())) }
    public func listArchivedModels() async throws -> [MuseModel] { (try await call("GET", "v1/models?archived=true") as [MuseModel]).map(absolutize) }

    func absolutize(_ r: ImageRef?) -> ImageRef? { r.map(absolutize) }
    /// A clip's thumb ("/uploads/…" for imports) made absolute, so the Swap slot and canvas can show it.
    public func absolutize(_ c: Clip) -> Clip {
        var x = c
        x.thumb = absolutize(c.thumb)
        return x
    }
    func absolutize(_ s: SheetSlot) -> SheetSlot {
        var s = s
        s.image = absolutize(s.image)
        return s
    }
    func absolutize(_ m: MuseModel) -> MuseModel {
        var m = m
        m.slots = m.slots.map(absolutize)
        return m
    }
    func absolutize(_ o: Outfit) -> Outfit {
        var o = o
        o.angles = o.angles.map(absolutize)
        o.faces = o.faces?.map(absolutize)
        return o
    }
    func absolutize(_ run: ToolRun) -> ToolRun {
        var run = run
        run.options.outfitImage = absolutize(run.options.outfitImage)
        run.items = run.items.map { i in
            var i = i
            i.before = absolutize(i.before)
            i.results = ToolResults(a: absolutize(i.results.a), b: absolutize(i.results.b))
            return i
        }
        return run
    }

    public func setFailNext(_ fail: Bool) async throws { _ = try await send(request("POST", "v1/dev/fail-next", body: try encoder.encode(DevFailRequest(failNext: fail)))) }

    /// Events from GET /v1/events. Reconnects with back-off while the subscriber is listening. On Apple platforms every
    /// subscriber shares the app's one connection (`LiveEventHub`); Linux builds (tests) poll instead.
    public func events() -> AsyncStream<ApiEvent> {
        if hub.canStream {
            return hub.events(baseURL: baseURL, token: currentToken, session: session, buffer: 256) { [weak self] f -> ApiEvent? in
                guard let self else { return nil }
                switch f {
                case .connected:
                    self.catalogCache.invalidate()
                    return ApiEvent(type: ApiEvent.connected)
                case .payload(let p):
                    guard let e = self.liveEvent(p) else { return nil }
                    if let stale = CatalogCachePolicy.stale(forEvent: e.type) {
                        if !stale.isEmpty { self.catalogCache.invalidate(stale) }
                    } else {
                        self.catalogCache.invalidate()
                    }
                    return e
                case .disconnected:
                    return nil
                }
            }
        }
        return AsyncStream(bufferingPolicy: .bufferingNewest(256)) { cont in
            let task = Task { [weak self] in
                var attempt = 0
                while !Task.isCancelled, let self {
                    // A stream that opened and later dropped retries after 1 s; one that can't connect backs off to 10 s.
                    let opened = OpenFlag()
                    do {
                        try await self.stream { e in
                            if e.type == ApiEvent.connected { opened.set() }
                            cont.yield(e)
                        }
                        attempt = 0
                    } catch {
                        attempt = opened.value ? 0 : attempt + 1
                    }
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: UInt64(min(10, attempt + 1)) * 1_000_000_000)
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Restarts the shared live stream (a network change, wake from sleep).
    public func reconnectEvents() { hub.reconnect(baseURL: baseURL) }

    /// The shared live stream is open and heard from the server lately (it sends a keep-alive every 10 s).
    public var liveStreamHealthy: Bool { hub.isHealthy(baseURL: baseURL) }

    /// One SSE payload as an event, with its server paths made absolute.
    func liveEvent(_ payload: String) -> ApiEvent? {
        guard var e = try? decoder.decode(ApiEvent.self, from: Data(payload.utf8)) else { return nil }
        if let l = e.lora { e.lora = absolutize(l) }
        if let p = e.post { e.post = absolutize(p) }
        if let j = e.job { e.job = absolutize(j) }
        if let t = e.tool { e.tool = absolutize(t) }
        if let m = e.model { e.model = absolutize(m) }
        if let o = e.outfit { e.outfit = absolutize(o) }
        if let t = e.take { e.take = absolutize(t) }
        if let t = e.template { e.template = absolutize(t) }
        e.takes = e.takes.map(absolutize)
        return e
    }

    /// The polling fallback for builds without a streaming transport (Linux, for tests).
    private func stream(_ yield: @escaping (ApiEvent) -> Void) async throws {
        #if canImport(FoundationNetworking)
        // swift-corelibs-foundation has no streaming bytes API; poll instead (Linux builds only, for tests).
        yield(ApiEvent(type: ApiEvent.connected))
        while !Task.isCancelled {
            let jobs = try await listJobs()
            for j in jobs where j.isActive { yield(ApiEvent(type: "job", job: j)) }
            yield(ApiEvent(type: "balance", balance: try await balance()))
            if let g = try? await warmGpu() { yield(ApiEvent(type: "gpu", gpu: g)) }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        #else
        // Apple platforms stream through the shared hub (`events()`); this fallback is never reached there.
        throw ApiError("offline", "Live updates aren't available")
        #endif
    }
}

struct Empty: Codable {}

/// Set once the event stream has opened.
final class OpenFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    func set() { lock.lock(); on = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return on }
}

#if !canImport(FoundationNetworking)
/// Reports a PUT's bytes sent as 0…1.
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: UploadProgress?
    init(_ progress: UploadProgress?) { self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        progress?(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}
#endif

/// multipart/form-data body builder.
struct Multipart {
    let boundary = "muse-\(UUID().uuidString)"
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(_ name: String, value: Data, mime: String? = nil) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n")
        if let mime { body.append("Content-Type: \(mime)\r\n") }
        body.append("\r\n")
        body.append(value)
        body.append("\r\n")
    }

    mutating func addFile(_ name: String, filename: String, mime: String, data: Data) {
        let safe = filename.replacingOccurrences(of: "\"", with: "")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(safe)\"\r\nContent-Type: \(mime)\r\n\r\n")
        body.append(data)
        body.append("\r\n")
    }

    mutating func finish() -> Data {
        var out = body
        out.append("--\(boundary)--\r\n")
        return out
    }
}

private extension Data {
    mutating func append(_ s: String) { append(s.data(using: .utf8)!) }
}

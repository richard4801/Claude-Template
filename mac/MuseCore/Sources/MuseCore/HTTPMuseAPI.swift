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
public final class HTTPMuseAPI: MuseAPI, @unchecked Sendable {
    public let baseURL: URL
    private let session: URLSession
    private let lock = NSLock()
    private var token: String?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
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
        let (data, resp): (Data, URLResponse?)
        do {
            (data, resp) = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, URLResponse?), Error>) in
                session.dataTask(with: r) { d, r, e in
                    if let e { cont.resume(throwing: e) } else { cont.resume(returning: (d ?? Data(), r)) }
                }.resume()
            }
        } catch let e as URLError where e.code == .timedOut {
            throw ApiError("still_working", "Still working on it. It keeps going on the server, and the results will appear in Gallery.")
        } catch {
            throw ApiError("offline", "Can't reach the server at \(baseURL.absoluteString)")
        }
        guard let http = resp as? HTTPURLResponse else { return data }
        if !(200..<300).contains(http.statusCode) {
            let err = try? decoder.decode(ErrorBody.self, from: data)
            throw ApiError(err?.code ?? "http_\(http.statusCode)", err?.error ?? "Server error \(http.statusCode)")
        }
        return data
    }

    private func call<T: Decodable>(_ method: String, _ path: String) async throws -> T {
        try decode(try await send(request(method, path)))
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
    public func listOutfits() async throws -> [Outfit] { try await call("GET", "v1/outfits") }
    public func createOutfit(_ req: CreateOutfitRequest) async throws -> Outfit { try await call("POST", "v1/outfits", req) }
    public func saveOutfit(outfitId: String) async throws -> Outfit { try await call("POST", "v1/outfits/\(outfitId)/save", Empty()) }

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
            return clip
        }
        var form = Multipart()
        form.addField("meta", value: try encoder.encode(meta), mime: "application/json")
        if let file { form.addFile("file", filename: file.lastPathComponent, mime: HTTPMuseAPI.videoType(file), data: try Data(contentsOf: file)) }
        let clip: Clip = try decode(try await send(request("POST", "v1/uploads/clips", body: form.finish(), contentType: form.contentType)))
        progress?(1)
        return clip
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

    /// Events from GET /v1/events. Reconnects with back-off while the subscriber is listening.
    public func events() -> AsyncStream<ApiEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(256)) { cont in
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

    private func stream(_ yield: @escaping (ApiEvent) -> Void) async throws {
        var r = request("GET", "v1/events")
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // The server sends a comment every 10 s (15 s on older builds): 40 s without a byte means the stream died quietly
        // (the Mac slept, the network changed, a proxy dropped it), so the request times out and the loop reconnects.
        r.timeoutInterval = 40
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
        let (bytes, resp) = try await session.bytes(for: r)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw ApiError("http_\(http.statusCode)", "Event stream refused") }
        yield(ApiEvent(type: ApiEvent.connected))
        var parser = SSEParser()
        var line = [UInt8]()
        for try await b in bytes {
            if b == 0x0A {
                if let payload = parser.feed(String(decoding: line, as: UTF8.self)), let d = payload.data(using: .utf8), var e = try? decoder.decode(ApiEvent.self, from: d) {
                    if let l = e.lora { e.lora = absolutize(l) }
                    if let p = e.post { e.post = absolutize(p) }
                    if let j = e.job { e.job = absolutize(j) }
                    if let t = e.tool { e.tool = absolutize(t) }
                    if let m = e.model { e.model = absolutize(m) }
                    if let o = e.outfit { e.outfit = absolutize(o) }
                    if let t = e.take { e.take = absolutize(t) }
                    if let t = e.template { e.template = absolutize(t) }
                    e.takes = e.takes.map(absolutize)
                    yield(e)
                }
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(b)
            }
        }
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

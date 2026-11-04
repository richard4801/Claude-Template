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

    // MARK: Plumbing

    func url(_ path: String) -> URL {
        var s = baseURL.absoluteString
        if !s.hasSuffix("/") { s += "/" }
        return URL(string: s + path)!
    }

    func request(_ method: String, _ path: String, body: Data? = nil, contentType: String = "application/json") -> URLRequest {
        var r = URLRequest(url: url(path))
        r.httpMethod = method
        r.timeoutInterval = 30
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
    public func listModels() async throws -> [MuseModel] { try await call("GET", "v1/models") }
    public func createModel(_ req: CreateModelRequest) async throws -> MuseModel { try await call("POST", "v1/models", req) }
    public func setSlot(modelId: String, slot: String, _ req: SetSlotRequest) async throws -> MuseModel { try await call("PUT", "v1/models/\(modelId)/slots/\(slot)", req) }
    public func fillAngles(modelId: String) async throws -> FillAnglesResponse { try await call("POST", "v1/models/\(modelId)/fill-angles", Empty()) }
    public func listOutfits() async throws -> [Outfit] { try await call("GET", "v1/outfits") }
    public func createOutfit(_ req: CreateOutfitRequest) async throws -> Outfit { try await call("POST", "v1/outfits", req) }
    public func saveOutfit(outfitId: String) async throws -> Outfit { try await call("POST", "v1/outfits/\(outfitId)/save", Empty()) }

    public func uploadImage(name: String, data: Data, mime: String) async throws -> ImageRef {
        var form = Multipart()
        form.addFile("file", filename: name, mime: mime, data: data)
        let ref: ImageRef = try decode(try await send(request("POST", "v1/uploads/images", body: form.finish(), contentType: form.contentType)))
        return absolutize(ref)
    }

    public func uploadClip(_ meta: ClipMeta, file: URL?) async throws -> Clip {
        var form = Multipart()
        form.addField("meta", value: try encoder.encode(meta), mime: "application/json")
        if let file { form.addFile("file", filename: file.lastPathComponent, mime: "video/mp4", data: try Data(contentsOf: file)) }
        return try decode(try await send(request("POST", "v1/uploads/clips", body: form.finish(), contentType: form.contentType)))
    }

    public func listJobs() async throws -> [Job] { try await call("GET", "v1/jobs") }
    public func createJob(_ req: JobRequest) async throws -> Job { try await call("POST", "v1/jobs", req) }
    public func removeJob(id: String) async throws { _ = try await send(request("DELETE", "v1/jobs/\(id)")) }

    public func runQueue() async throws {
        // Not in the Android contract; the mock server starts jobs on its own. Ignore a 404.
        do { _ = try await send(request("POST", "v1/queue/run", body: try encoder.encode(Empty()))) } catch let e as ApiError where e.code == "http_404" || e.code == "not_found" {}
    }

    public func listTakes() async throws -> [Take] { try await call("GET", "v1/takes") }
    public func setTakeStatus(id: String, status: String) async throws -> Take { try await call("PATCH", "v1/takes/\(id)", SetTakeStatusRequest(status: status)) }
    public func deleteTake(id: String) async throws { _ = try await send(request("DELETE", "v1/takes/\(id)")) }
    public func shoot(_ req: ShootRequest) async throws -> [Take] { try await call("POST", "v1/shoots", req) }
    public func balance() async throws -> Balance { try await call("GET", "v1/balance") }
    public func topUp(_ req: TopUpRequest) async throws -> Balance { try await call("POST", "v1/balance/topup", req) }
    public func setFailNext(_ fail: Bool) async throws { _ = try await send(request("POST", "v1/dev/fail-next", body: try encoder.encode(DevFailRequest(failNext: fail)))) }

    /// Events from GET /v1/events. Reconnects with back-off while the subscriber is listening.
    public func events() -> AsyncStream<ApiEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(256)) { cont in
            let task = Task { [weak self] in
                var attempt = 0
                while !Task.isCancelled, let self {
                    do {
                        try await self.stream { cont.yield($0) }
                        attempt = 0
                    } catch {
                        attempt += 1
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
        r.timeoutInterval = 3600
        #if canImport(FoundationNetworking)
        // swift-corelibs-foundation has no streaming bytes API; poll instead (Linux builds only, for tests).
        while !Task.isCancelled {
            let jobs = try await listJobs()
            for j in jobs where j.isActive { yield(ApiEvent(type: "job", job: j)) }
            yield(ApiEvent(type: "balance", balance: try await balance()))
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        #else
        let (bytes, resp) = try await session.bytes(for: r)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw ApiError("http_\(http.statusCode)", "Event stream refused") }
        var parser = SSEParser()
        var line = [UInt8]()
        for try await b in bytes {
            if b == 0x0A {
                if let payload = parser.feed(String(decoding: line, as: UTF8.self)), let d = payload.data(using: .utf8), let e = try? decoder.decode(ApiEvent.self, from: d) {
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

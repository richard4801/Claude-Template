import Foundation

/// The backend contract (plans/api.md). Two implementations:
///  - `FakeMuseAPI`: in-process, no server. The app's default data source.
///  - `HTTPMuseAPI`: REST + Server-Sent Events against server/mock (or the real backend later).
/// Settings → Developer switches between them.
public protocol MuseAPI: AnyObject, Sendable {
    // Auth (stub: any email works; sign-up requires both attestations)
    func signIn(_ req: SignInRequest) async throws -> AuthResponse
    func signUp(_ req: SignUpRequest) async throws -> AuthResponse
    func setToken(_ token: String?) async

    // Models and character sheets
    func listModels() async throws -> [MuseModel]
    func createModel(_ req: CreateModelRequest) async throws -> MuseModel
    func setSlot(modelId: String, slot: String, _ req: SetSlotRequest) async throws -> MuseModel
    /// Generates the missing angles from the user's images ($0.02 each). Slots come back busy; a model event follows.
    func fillAngles(modelId: String) async throws -> FillAnglesResponse

    // Outfit sets
    func listOutfits() async throws -> [Outfit]
    /// Starts generating an outfit set preview (state=generating; an outfit event follows with state=preview).
    func createOutfit(_ req: CreateOutfitRequest) async throws -> Outfit
    /// Attaches a generated preview to the model.
    func saveOutfit(outfitId: String) async throws -> Outfit

    // Uploads
    func uploadImage(name: String, data: Data, mime: String) async throws -> ImageRef
    /// Registers a source clip and runs the clip checks. `file` is nil for the sample clips.
    func uploadClip(_ meta: ClipMeta, file: URL?) async throws -> Clip

    // Jobs and takes
    func listJobs() async throws -> [Job]
    func createJob(_ req: JobRequest) async throws -> Job
    func removeJob(id: String) async throws
    /// Starts the GPU on queued jobs ("Run queue"). Servers that start jobs on their own treat it as a no-op.
    func runQueue() async throws
    func listTakes() async throws -> [Take]
    func setTakeStatus(id: String, status: String) async throws -> Take
    func deleteTake(id: String) async throws
    func shoot(_ req: ShootRequest) async throws -> [Take]

    // Balance
    func balance() async throws -> Balance
    func topUp(_ req: TopUpRequest) async throws -> Balance

    // Developer
    func setFailNext(_ fail: Bool) async throws

    /// Live job progress, balance and generation updates. Each call returns a new subscription.
    func events() -> AsyncStream<ApiEvent>
}

/// Fan-out of events to any number of subscribers.
public final class EventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var subs: [UUID: AsyncStream<ApiEvent>.Continuation] = [:]

    public init() {}

    public func stream() -> AsyncStream<ApiEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(256)) { cont in
            let id = UUID()
            lock.lock()
            subs[id] = cont
            lock.unlock()
            cont.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.subs[id] = nil
                self.lock.unlock()
            }
        }
    }

    public func emit(_ e: ApiEvent) {
        lock.lock()
        let all = Array(subs.values)
        lock.unlock()
        for c in all { c.yield(e) }
    }
}

func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
func shortId() -> String { String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)) }

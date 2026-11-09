import AppKit
import MuseCore
import Observation
import SwiftUI

enum Screen: String, CaseIterable {
    // Photoshoot is gone: it is the AI suite's Photo tool (workstream 3); `openPhoto()` is the route to it.
    case home, models, profile, create, queue, gallery, result, settings, credits, lora, posts, templates, template, editor
    // AI suite (workstream 1): the Video suite (hub and modes) and the top-level Edit.
    case suite, edit

    /// Which sidebar item is highlighted.
    var navParent: Screen {
        switch self {
        case .profile, .create, .lora: return .models
        case .result, .editor: return .gallery
        case .credits: return .settings
        case .template: return .templates
        default: return self
        }
    }
}

struct NavItem: Identifiable {
    let screen: Screen
    let title: String
    let icon: String
    let key: Character
    var id: Screen { screen }

    static let main: [NavItem] = [
        NavItem(screen: .home, title: "Home", icon: "house", key: "1"),
        NavItem(screen: .models, title: "Models", icon: "person", key: "2"),
        NavItem(screen: .suite, title: "Video suite", icon: "video", key: "3"), // AI suite (workstream 1): was "Video studio"
        NavItem(screen: .queue, title: "Queue", icon: "list.bullet.below.rectangle", key: "5"),
        NavItem(screen: .gallery, title: "Library", icon: "square.grid.2x2", key: "6"),
        NavItem(screen: .posts, title: "Posts", icon: "paperplane", key: "7"),
    ]
}

enum DataSource: String, CaseIterable, Codable {
    case fake, http
    var label: String { self == .fake ? "Demo mode (no server)" : "MUSE server" }
}

/// The hosted MUSE API (server/api on Railway).
let defaultServerURL = "https://angelic-elegance-production-c42b.up.railway.app"

enum ShootState { case idle, busy, done }
enum GalleryTab { case tests, final }
/// Settings (owner-approved redesign 2026-11-09, plans/settings-redesign.md): six sections and a hidden Advanced.
enum SettingsSection: String, CaseIterable {
    case account, studio, members, spending, providers, apps, advanced
    var title: String {
        switch self {
        case .account: return "Account"
        case .studio: return "Studio"
        case .members: return "Members"
        case .spending: return "AI & spending"
        case .providers: return "Providers"
        case .apps: return "Apps & devices"
        case .advanced: return "Advanced"
        }
    }

    /// The line under the section's title.
    var intro: String {
        switch self {
        case .account: return "You, how MUSE looks, and when it tells you things."
        case .studio: return "How new videos and photos start, the studio's prompts, and archived models."
        case .members: return "Who works in the studio, what each person can spend, and invitations."
        case .spending: return "Your balance, spend caps and the models behind each quality."
        case .providers: return "Your own accounts with AI providers. Their models join the AI Suite's model picker."
        case .apps: return "Claude, Blender and your phone working with MUSE."
        case .advanced: return "Server, testing and performance tools. Hidden unless turned on under Account."
        }
    }

    /// Members see Account, Studio and AI & spending.
    var ownerOnly: Bool { self == .members || self == .providers || self == .apps || self == .advanced }
}

enum PostTab: Hashable { case scheduled, posted }

/// The Post sheet (Result → Post). Both labels start off and only the user turns them on.
struct PostDraft {
    var takeId: String
    var modelId: String
    var platforms: [Platform]
    var caption = ""
    var aiLabel = false
    var paidPartnership = false
    var schedule = false
    var when: Date
    var busy = false
}

struct Toast: Identifiable {
    let id = UUID()
    var message: String
    var actionLabel: String?
    var action: (() -> Void)?
}

/// A character-sheet slot while a new model is being made.
enum DraftSlot: Equatable {
    case local(URL)
    case remote(ImageRef, ai: Bool)
    case busy
}

struct CreateDraft {
    var step = 1
    var name = ""
    var age = 24
    var niche = "Beauty"
    var personality = ""
    var notes = ""
    var slots: [SheetAngle: DraftSlot] = [:]
    /// Set once the model exists on the backend (made lazily on Save or "Fill missing angles").
    var modelId: String?

    var filled: Int { slots.values.filter { $0 != .busy }.count }
    var faces: Int { [SheetAngle.face, .profile].filter { slots[$0] != nil && slots[$0] != .busy }.count }
    var busy: Bool { slots.values.contains(.busy) }
}

struct OutfitDraft {
    var modelId: String
    var mode: OutfitMode = .describe
    var name = ""
    var description = ""
    var images: [URL] = []
    var state: ShootState = .idle
    var outfitId: String?
    var angles: [ImageRef?] = [nil, nil, nil, nil]
    /// The angle open full size (ImageLightbox), an index into `lightboxItems`.
    var viewing: Int?
}

enum Niches {
    static let all = ["Beauty", "Fashion", "Fitness", "Food", "Tech", "Travel", "Lifestyle"]
}

/// All app state, observed by the views. Talks to the backend through `MuseAPI` (the in-process fake by default).
@MainActor
@Observable
final class AppStore {
    // MARK: Preferences (UserDefaults)

    private let defaults = UserDefaults.standard

    var themeID: ThemeID { didSet { defaults.set(themeID.rawValue, forKey: "muse.theme") } }
    var pro: Bool { didSet { defaults.set(pro, forKey: "muse.pro") } }
    /// The Render picker's default (Draft). Until the user picks one, the server's `features.video` default applies.
    var defaultQuality: VideoQuality { didSet { defaults.set(defaultQuality.rawValue, forKey: "muse.defaultQuality") } }
    var notifyDone: Bool { didSet { defaults.set(notifyDone, forKey: "muse.notifyDone") } }
    var notifyFailed: Bool { didSet { defaults.set(notifyFailed, forKey: "muse.notifyFailed") } }
    var notifyLowBalance: Bool { didSet { defaults.set(notifyLowBalance, forKey: "muse.notifyLow") } }
    var notifyPhone: Bool { didSet { defaults.set(notifyPhone, forKey: "muse.notifyPhone") } }
    var warnOverBudget: Bool { didSet { defaults.set(warnOverBudget, forKey: "muse.warnBudget") } }
    var dataSource: DataSource { didSet { defaults.set(dataSource.rawValue, forKey: "muse.dataSource.v2") } }
    /// "Remember me" on sign-in (default on). On: the session stays in the Keychain across launches and the email is pre-filled.
    /// Off: the token lives in memory only (quitting signs out) and the email isn't saved. The password is never stored by MUSE;
    /// macOS Passwords / iCloud Keychain offers to save it through the fields' content types.
    var rememberMe: Bool { didSet { defaults.set(rememberMe, forKey: "muse.rememberMe") } }
    var baseURL: String { didSet { defaults.set(baseURL, forKey: "muse.baseURL.v2") } }
    /// Never-add edits not yet saved on the server (PATCH /v1/models/{id}); kept on this Mac when an older server doesn't have the endpoint.
    var neverOverrides: [String: [String]] { didSet { defaults.set(neverOverrides, forKey: "muse.never") } }

    var theme: Theme { Theme.get(themeID) }

    // MARK: Session and backend

    var user: User?
    var authTab: AuthTab = .signIn
    var attest = [false, false]
    var authEmail = ""
    var authPassword = ""
    var authInvite = ""
    var authBusy = false
    /// Shown under the sign-in form (friendly text for the API's error codes).
    var authError: String?
    /// True while GET /v1/auth/me checks a stored session at launch.
    var restoring = false
    enum AuthTab { case signIn, signUp }

    private let fake: FakeMuseAPI
    @ObservationIgnored private(set) var api: any MuseAPI
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    /// Live stream bookkeeping: opens seen on this stream, when it started, and the last catch-up refetch.
    @ObservationIgnored private var streamConnects = 0
    @ObservationIgnored private var eventsStartedAt = Date.distantPast
    @ObservationIgnored private var lastCatchUp = Date.distantPast
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// Performance pass: a reload already running is joined, not repeated.
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    /// When each live-kept list was last loaded, so a screen's `.task` doesn't refetch it (Credit, Templates, Posts, Members).
    @ObservationIgnored var listFreshness = Freshness()
    /// How old a live-kept list may be before a screen appearing refetches it. The live stream keeps it current meanwhile.
    static let listMaxAge: TimeInterval = 60
    var offlineMessage: String?
    var loading = false

    // MARK: Navigation and overlays

    var screen: Screen = .home
    var navForward = true
    var toast: Toast?
    var paletteOpen = false
    var paletteQuery = ""
    var paletteIndex = 0
    var settingsSection: SettingsSection = .account
    /// Settings → Studio → Prompts (the prompt library, a page inside Studio).
    var settingsPrompts = false

    // MARK: Data

    var models: [MuseModel] = []
    var outfits: [Outfit] = []
    var jobs: [Job] = []
    var takes: [Take] = []
    var balance = Balance(balance: 0, month: 0)
    /// GET /v1/wallet (real API). nil on servers without wallets (server/mock).
    var wallet: Wallet?
    /// Owner only: the studio's people, settings and image engine.
    var members: [Member] = []
    var studioSettings: StudioSettings?
    var imageEngine: ImageEngine?
    /// Owner only: the owner-loaded studio balance and its top-ups (GET /v1/studio/balance). nil on servers without it.
    var studioBalance: StudioBalance?
    var topUpBusy = false
    /// The last invite made on this Mac (its code is shown once).
    var lastInvite: Invite?
    /// An upload in flight: 0…1 and what's being uploaded.
    var uploadProgress: Double?
    var uploadLabel = ""
    var hiddenFailures: Set<String> = []
    /// Identity LoRA per model id.
    var loras: [String: Lora] = [:]
    /// Connected social accounts per model id.
    var accounts: [String: [Account]] = [:]
    var posts: [Post] = []
    /// "modelId/platform" while its sign-in runs.
    var connecting: Set<String> = []

    // MARK: Posts

    var postTab: PostTab = .scheduled
    var postDraft: PostDraft?

    // AI suite (workstream 1): the Video suite's state (AppStore+Suite.swift).
    let suite = SuiteState()
    /// "Recreate this edit" in Edit (AppStore+Recreate.swift).
    let recreate = RecreateState()
    /// "Import a video from a link" (WS6, AppStore+LinkImport.swift).
    let linkImport = LinkImportState()
    /// The owner's model picks per purpose and the engine catalog (WS6, AppStore+EngineChoice.swift).
    let engineChoice = EngineChoiceState()
    /// Settings → Providers (WS6, AppStore+Providers.swift).
    let providersState = ProvidersState()
    /// The learning editor in Edit: Playbook and Recipes (AppStore+Learn.swift).
    let learn = LearnState()
    /// Library collections (AppStore+LibraryQueue.swift).
    let library = LibraryState()
    /// Owner Settings → Studio: the paid AI editing helpers' switch, daily limit and today's spend (AppStore+EditorSettings.swift).
    var editorSettings: EditorSettings?
    var editorSettingsError: String?
    @ObservationIgnored let editorSettingsFake = FakeEditorSettingsAPI()

    // MARK: Video studio

    var modelId = SampleData.demo
    var outfitIdByModel: [String: String] = [:]
    /// The selected clip. Changing it (or its late talking detection arriving) re-sets "Performer is speaking".
    var clip: Clip? { didSet { clipChangedForSpeaking(from: oldValue) } }
    var clipFile: URL?
    var clipThumb: ImageRef?
    /// Render (Draft / Standard / HD) or an add-on (Edit, Fast · beta). Every option renders the whole clip.
    var quality: VideoQuality
    /// The server's default quality is applied once per launch (until the user sets a default in Settings).
    @ObservationIgnored var appliedServerQuality = false
    var takeCount = 1
    var keepAudio = true
    var lipSync = false
    // Prompt scripts (workstream 4): the studio's "Performer is speaking" switch, pre-set from the clip's detection, sent as
    // `speaking`. `speakingTouched`: the user flipped it for this clip (a late detection then leaves it alone).
    var speaking = false
    var speakingTouched = false
    var background = "keep"
    var motion = "subtle"
    var generating = false
    /// Renders started from the studio this session, oldest first: the stage (its right pane) follows the newest one that is
    /// still for the current clip, model and outfit (`StudioStage`).
    var stageJobIds: [String] = []
    /// The take picked in the stage's take switcher (nil = take 1).
    var stageTakeId: String?
    /// POST /v1/takes/{id}/upscale in flight.
    var upscaling = false

    // MARK: Prompt library versions

    /// Bumped by `prompts` events (the owner saved or reset an entry).
    var promptsVersion = 0

    // MARK: Prompt library (owner: Settings → Prompts)

    var promptLibrary: PromptLibrary?
    var promptLibraryError: String?
    /// The entry open in the editor.
    var promptEditKey: String?
    var promptDraft = ""
    /// The saved text the draft started from (a live update replaces an untouched draft, never one being edited).
    var promptDraftBase = ""
    var promptLivePreview: PromptPreview?
    /// `prompt_invalid` while typing or on Save, shown under the editor as-is.
    var promptError: String?
    var promptSaving = false

    // MARK: Prompt scripts (workstream 4, owner: Settings → Prompts → Scripts)

    var promptsTab: PromptsTab = .blocks
    var scriptList: PromptScriptsList?
    var scriptListError: String?
    /// The script open on the script screen.
    var scriptOpenId: String?
    /// Its rules as edited (Save sends them all, in order).
    var scriptDraft: [ScriptRule] = []
    /// The saved rules the draft started from (a live update replaces an untouched draft, never one being edited).
    var scriptDraftBase: [ScriptRule] = []
    /// `script_invalid` from Save or the preview, shown inline as-is.
    var scriptError: String?
    var scriptSaving = false
    /// The preview's inputs (pre-filled with the samples) and its last answer.
    var scriptInputs: [String: JSONValue] = [:]
    var scriptPreview: ScriptPreview?
    /// The rule in the edit sheet (a copy; Done puts it back into the draft).
    var scriptEditingRule: ScriptRule?

    // MARK: Photo templates (plans/templates.md)

    var templates: [MuseTemplate] = []
    var templateScope: TemplateScope = .all
    var templateQuery = ""
    var templateTag: String?
    /// The detail screen's template (GET /v1/templates/{id}, with recent results).
    var openTemplateId: String?
    var templateDetail: MuseTemplate?
    /// The template editor sheet (Save as template, Edit, New template).
    var templateForm: TemplateForm?
    var templateFormBusy = false

    // MARK: Gallery

    var galleryTab: GalleryTab = .tests
    var picked: [String] = []
    var fresh: Set<String> = []
    var comparing = false
    var openTakeId: String?
    /// The open video editor (Screen.editor).
    var editor: VideoEditorSession?

    // MARK: Models

    var profileModelId = SampleData.demo
    var create = CreateDraft()
    var outfitSheet: OutfitDraft?

    // MARK: Model tools (plans/api.md "Model tools")

    /// Owner: the model per image step (Settings → Engines → Image models).
    var stepModels: [StepModel] = []
    /// Owner: archived models (Settings → Archived models).
    var archivedModels: [MuseModel] = []
    /// The model catalog sheet (owner only).
    var catalog: CatalogDraft?
    var enhanceDraft: EnhanceDraft?
    var dressUpDraft: DressUpDraft?
    var versionsDraft: VersionsDraft?
    /// Enhance and Dress up runs by id (from `tool` events and the API).
    var toolRuns: [String: ToolRun] = [:]

    // MARK: Keep add-on engine ready (owner only, Settings → Engines)

    /// The owner's add-on engine (GET /v1/gpu/warm and `gpu` events). Members never load it.
    var warmGpu = WarmGpu.off
    /// False for members and on servers without /v1/gpu/warm (server/mock).
    var warmAvailable = false
    /// The switch-on confirmation (cost warning), when showing.
    var warmPrompt: WarmPrompt?
    /// The 5-minute auto-off warning (shown in Settings → Engines).
    var warmWarning: WarmGpuWarning?
    var warmBusy = false
    /// "Now" for the indicator's minutes and cost; ticks every 15 s while it's on.
    var warmClock = Date()
    @ObservationIgnored var warmTicker: Task<Void, Never>?
    /// The last warning shown (kind + time), so each one is announced once.
    @ObservationIgnored var warmWarnedKey: String?

    // MARK: Credits

    init() {
        let d = UserDefaults.standard
        themeID = ThemeID(rawValue: d.string(forKey: "muse.theme") ?? "a") ?? .a
        pro = d.bool(forKey: "muse.pro")
        d.removeObject(forKey: "muse.sound") // the old interface-sound preference; MUSE no longer plays UI sounds
        // Steps and the Exact edit engine aren't settings any more (Edit always uses the default steps and the whole clip).
        d.removeObject(forKey: "muse.defaultSteps")
        d.removeObject(forKey: "muse.defaultEngine")
        defaultQuality = VideoQuality(id: d.string(forKey: "muse.defaultQuality")).replicateOrDefault
        // The house style is the server's now (Settings → Prompts · House style).
        d.removeObject(forKey: "muse.houseStyle")
        notifyDone = d.object(forKey: "muse.notifyDone") as? Bool ?? true
        notifyFailed = d.object(forKey: "muse.notifyFailed") as? Bool ?? true
        notifyLowBalance = d.object(forKey: "muse.notifyLow") as? Bool ?? true
        notifyPhone = d.object(forKey: "muse.notifyPhone") as? Bool ?? true
        warnOverBudget = d.object(forKey: "muse.warnBudget") as? Bool ?? true
        d.removeObject(forKey: "muse.newSuite") // the cinematic Suite preview was removed (the owner kept this Suite)
        // v2 keys: the real server is the default now (older builds defaulted to the in-process fake and localhost).
        dataSource = DataSource(rawValue: d.string(forKey: "muse.dataSource.v2") ?? "http") ?? .http
        baseURL = d.string(forKey: "muse.baseURL.v2") ?? defaultServerURL
        neverOverrides = d.dictionary(forKey: "muse.never") as? [String: [String]] ?? [:]
        rememberMe = d.object(forKey: "muse.rememberMe") as? Bool ?? true
        quality = VideoQuality(id: d.string(forKey: "muse.defaultQuality")).replicateOrDefault
        let store = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("MUSE/uploads")
        fake = FakeMuseAPI(storeDir: store)
        api = fake
        d.removeObject(forKey: "muse.token") // older builds kept the token in UserDefaults; it lives in the Keychain now
        if let data = d.data(forKey: "muse.user"), let u = try? JSONDecoder().decode(User.self, from: data) { user = u }
        if rememberMe, let email = d.string(forKey: "muse.rememberedEmail") { authEmail = email }
    }

    // MARK: Lifecycle

    func bootstrap() {
        api = makeAPI()
        Notifier.shared.requestAuthorization()
        Notifier.shared.onOpenPost = { [weak self] id in self?.openScheduledPost(id) }
        Task { await restoreSession() }
    }

    var isDemo: Bool { !(api is HTTPMuseAPI) }
    var isOwner: Bool { user?.isOwner ?? false }
    /// The Keychain account for the current server's session token.
    var serverKey: String { (api as? HTTPMuseAPI)?.baseURL.absoluteString ?? "demo" }
    var serverHost: String { (api as? HTTPMuseAPI)?.baseURL.host ?? "demo" }

    private func makeAPI() -> any MuseAPI {
        if dataSource == .http, let u = URL(string: baseURL.trimmingCharacters(in: .whitespaces)), u.scheme != nil { return HTTPMuseAPI(baseURL: u, cacheCatalogs: true) }
        return fake
    }

    /// Demo mode keeps the signed-in user on this Mac. A server session is restored from the Keychain token with GET /v1/auth/me.
    func restoreSession() async {
        if isDemo {
            if var u = user {
                if u.role == nil { u.role = "owner" }
                user = u
                _ = try? await api.signIn(SignInRequest(email: u.email, password: ""))
                await connect()
            }
            return
        }
        guard let token = Keychain.token(for: serverKey) else {
            user = nil
            return
        }
        await api.setToken(token)
        restoring = true
        defer { restoring = false }
        do {
            let me = try await api.me()
            setUser(me)
            await connect()
        } catch let e as ApiError where e.endsSession {
            endSession(e.friendlyMessage)
        } catch let e as ApiError where e.code == "not_found" || e.code == "http_404" {
            // server/mock has no /v1/auth/me: keep the cached user.
            if user != nil { await connect() }
        } catch {
            // Offline: keep the cached user and show the offline note; the next reload tries again.
            if user != nil { await connect() } else { authError = (error as? ApiError)?.friendlyMessage }
        }
    }

    private func setUser(_ u: User) {
        user = u
        if rememberMe { defaults.set(try? JSONEncoder().encode(u), forKey: "muse.user") } else { defaults.removeObject(forKey: "muse.user") }
    }

    /// Switches between demo mode and a server, then restores that server's session (or asks to sign in).
    func applyDataSource() {
        eventsTask?.cancel()
        listFreshness.invalidateAll()
        api = makeAPI()
        clip = nil
        clipFile = nil
        clipThumb = nil
        stageJobIds = []
        stageTakeId = nil
        wallet = nil
        members = []
        studioSettings = nil
        appliedServerQuality = false
        imageEngine = nil
        studioBalance = nil
        offlineMessage = nil
        resetModelTools()
        resetPromptLibrary()
        resetWarm()
        suite.reset() // AI suite (workstream 1)
        recreate.reset()
        learn.reset()
        editorSettings = nil
        editorSettingsError = nil
        Task { await restoreSession() }
    }

    func connect() async {
        startEvents()
        await reload()
        // Workstream 2: the Blender relay (owner only, off until switched on in its debug view).
        BlenderRelayService.shared.configure(baseURL: (api as? HTTPMuseAPI)?.baseURL, isOwner: isOwner) { [http = api as? HTTPMuseAPI] in http?.sessionToken }
    }

    private func startEvents() {
        eventsTask?.cancel()
        streamConnects = 0
        eventsStartedAt = Date()
        let stream = api.events()
        eventsTask = Task { [weak self] in
            for await e in stream {
                guard let self else { return }
                self.apply(e)
            }
        }
    }

    /// The app became active again, or the Mac woke from sleep or changed networks: the stream may have died quietly,
    /// so it starts afresh and the lists are refetched (anything changed on the phone meanwhile shows up).
    /// Performance pass: just coming back to the front (`force` false) does nothing while the shared stream is healthy (it
    /// heard the server's 10 s keep-alive lately), so ⌘-Tab no longer refetches every list. Wake and network changes force it.
    func resumeLive(force: Bool = false) {
        guard user != nil, eventsTask != nil, Date().timeIntervalSince(eventsStartedAt) > 5 else { return }
        if let http = api as? HTTPMuseAPI {
            if !force && http.liveStreamHealthy { return }
            // The connection is shared with the other listeners: restart it (they all hear `connected` again).
            eventsStartedAt = Date()
            http.reconnectEvents()
        } else {
            startEvents()
        }
        catchUp()
    }

    /// Refetch after a reconnect or on becoming active; at most once every 3 s.
    private func catchUp() {
        guard Date().timeIntervalSince(lastCatchUp) > 3 else { return }
        lastCatchUp = Date()
        Task { [weak self] in await self?.reload() }
    }

    /// Settings → Developer → Reload: forget the cached catalogs too.
    func forceReload() async {
        (api as? HTTPMuseAPI)?.invalidateCache()
        listFreshness.invalidateAll()
        await reload()
    }

    /// One reload at a time: a caller arriving while one runs waits for it instead of sending every request again.
    func reload() async {
        if let running = reloadTask {
            await running.value
            return
        }
        let t = Task { [weak self] in
            await self?.reloadNow()
            self?.reloadTask = nil // on the main actor, before anyone else can see the finished task
        }
        reloadTask = t
        await t.value
    }

    private func reloadNow() async {
        loading = true
        defer { loading = false }
        let api = self.api
        do {
            async let m = api.listModels()
            async let o = api.listOutfits()
            async let j = api.listJobs()
            async let t = api.listTakes()
            async let b = api.balance()
            let (mm, oo, jj, tt, bb) = try await (m, o, j, t, b)
            models = mm
            outfits = oo
            jobs = jj
            takes = tt
            balance = bb
            offlineMessage = nil
            StartupMetrics.firstContentShown(models: mm.count, takes: tt.count)
            if !models.contains(where: { $0.id == modelId }), let first = models.first(where: { !$0.isDraft }) ?? models.first { modelId = first.id }
            if !models.contains(where: { $0.id == profileModelId }), let first = models.first { profileModelId = first.id }
            // The sample clip is demo mode's only: on a server the studio starts empty until a clip is uploaded.
            if clip == nil && isDemo { await useSampleClip(bad: false, quiet: true) }
            // Performance pass: the rest loads side by side (it used to be one request after another: ~16 round trips).
            async let studio: Void = loadStudio()
            async let social: Void = loadSocial()
            async let tpl: Void = loadTemplates()
            async let warm: Void = loadWarmGpu()
            _ = await (studio, social, tpl, warm)
            for k in ["studio", "templates", "posts", "members", "archived"] { listFreshness.mark(k) }
        } catch let e as ApiError where e.endsSession {
            endSession(e.friendlyMessage)
        } catch {
            offlineMessage = (error as? ApiError)?.friendlyMessage ?? error.localizedDescription
        }
    }

    /// Wallet, and for the owner: members, the studio balance, the engines and the image engine. Servers without them (server/mock) are fine.
    func loadStudio() async {
        let api = self.api
        let owner = isOwner
        // Side by side (performance pass); each may fail on its own (servers without them).
        async let w = attempt { try await api.wallet() }
        // Everyone reads the studio settings: `features.video` drives the Render picker and add-ons, `features.photo` the photo estimates.
        async let st = attempt { try await api.studioSettings() }
        async let mem = attempt(owner) { try await api.listMembers() }
        async let sb = attempt(owner) { try await api.studioBalance() }
        async let ie = attempt(owner) { try await api.imageEngine() }
        async let sm = attempt(owner) { try await api.imageModels() }
        async let ar = attempt(owner) { try await api.listArchivedModels() }
        wallet = await w
        studioSettings = await st
        syncQualityWithServer()
        let (m, b, e, s, a) = await (mem, sb, ie, sm, ar)
        listFreshness.mark("studio")
        guard isOwner else { return }
        if let m { members = m }
        studioBalance = b
        imageEngine = e
        stepModels = s ?? []
        archivedModels = a ?? []
        if settingsPrompts { await loadPrompts() }
    }

    /// A screen appeared (Credit, Settings): the studio data the live stream keeps current, unless it's over a minute old.
    func loadStudioIfStale() async {
        guard !listFreshness.isFresh("studio", maxAge: Self.listMaxAge) else { return }
        await loadStudio()
    }

    /// Runs an API call and shows its error as a toast, in MUSE's words.
    func perform(_ work: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await work() } catch let e as ApiError {
                handle(e)
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    func handle(_ e: ApiError) {
        if e.code == "offline" { offlineMessage = e.message }
        if e.endsSession {
            endSession(e.friendlyMessage)
        } else if e.code == "insufficient_balance" && !isMember {
            showToast(e.friendlyMessage, action: "Credit") { [weak self] in self?.go(.credits) }
        } else {
            showToast(e.friendlyMessage)
        }
    }

    var isMember: Bool { user?.isMember ?? false }

    // MARK: Events

    func apply(_ e: ApiEvent) {
        if e.type == ApiEvent.connected {
            // The first connect comes with the initial load; every later one is a reconnect after a drop: catch up.
            streamConnects += 1
            if streamConnects > 1 { catchUp() }
            return
        }
        // Performance pass: with @Observable, passing a list `inout` counts as changing it, so every event (a Claude
        // streaming delta, a camera message, a balance tick) used to re-render every view that reads jobs, takes, posts,
        // accounts and members. Each list is now touched only by the events that can change it.
        let jobBefore = e.job.flatMap { j in jobs.first { $0.id == j.id } }
        if e.job != nil || e.type == "job" { LiveEvents.applyJobs(&jobs, e) }
        if e.type == "take" || !e.takes.isEmpty { LiveEvents.applyTakes(&takes, e) }
        if let j = e.job, e.op != "delete" {
            let wasActive = jobBefore.map(\.isActive) ?? true
            if wasActive && j.isDone { jobFinished(j, newTakes: e.takes) }
            if wasActive && j.isFailed { jobFailed(j) }
        }
        if e.type == "template" {
            LiveEvents.applyTemplates(&templates, e)
            if let id = suite.photo.presetId, !templates.contains(where: { $0.id == id }) { suite.photo.presetId = nil }
            if let d = templateDetail, let t = templates.first(where: { $0.id == d.id }) { var n = t; n.recent = d.recent; templateDetail = n }
        }
        if let id = LiveEvents.isModelDelete(e), let m = models.first(where: { $0.id == id }) {
            dropArchived(m)
            archivedModels.removeAll { $0.id == id }
            accounts[id] = nil
            posts.removeAll { $0.modelId == id && !$0.isOut }
        }
        if e.type == "post" || e.post != nil { LiveEvents.applyPosts(&posts, e) }
        // Build step 3: a collection made, changed or deleted, or the queue changed: read them again.
        if e.type == "collection" { Task { await loadCollections() } }
        if e.type == "queue" { Task { await loadQueue() } }
        // Claude in the Suite: Claude or another device changed the shared composer draft.
        if e.type == "suiteAssist", let a = e.assist { suiteAssistEvent(a) }
        if e.type == "account" { LiveEvents.applyAccounts(&accounts, e) }
        if isOwner {
            if e.type == "member" { LiveEvents.applyMembers(&members, e) }
            if e.type == "studio", let sb = e.studioBalance { studioBalance = sb }
            if e.type == "settings", e.settings == nil { Task { [weak self] in await self?.loadStudio() } }
        }
        if isOwner, e.type == "prompts", let p = LiveEvents.applyPrompts(&promptLibrary, e) { promptChanged(p) }
        // Prompt scripts (workstream 4): a script saved or reset elsewhere; a late `clip` event with the talking detection.
        if isOwner, e.type == "promptScript", let v = LiveEvents.applyPromptScript(&scriptList, e) { promptScriptChanged(v) }
        if e.type == "clip", let c = e.clip, c.id == clip?.id { clip = (api as? HTTPMuseAPI)?.absolutize(c) ?? c }
        if e.type == "settings", let st = e.settings {
            studioSettings = st
            syncQualityWithServer()
        }
        if let b = e.balance {
            let wasAbove = balance.balance >= 5
            balance = b
            if wasAbove && b.balance < 5 && notifyLowBalance && !isMember {
                Notifier.shared.post(title: "Balance below $5", body: "You have \(Pricing.money(b.balance)) left · about \(Pricing.videosLeft(b.balance)) Draft videos.")
            }
        }
        if let w = e.wallet { walletChanged(w) }
        if let n = e.notice { studioNotice(n) }
        // Keep add-on engine ready is the owner's; a member never gets these, and ignores one if an older server sends it.
        if let g = e.gpu, isOwner { applyWarm(g, warning: e.event == "warning" ? e.warning : nil) }
        if let m = e.model {
            if m.archived {
                // Archived models vanish from every list and picker.
                dropArchived(m)
            } else {
                if let i = models.firstIndex(where: { $0.id == m.id }) { models[i] = m } else { models.append(m) }
                archivedModels.removeAll { $0.id == m.id }
                syncDraftSlots(from: m)
            }
        }
        if let r = e.tool { applyToolRun(r) }
        if let l = e.lora { applyLora(l) }
        if let o = e.outfit {
            LiveEvents.applyOutfit(&outfits, &models, o)
            if outfitSheet?.outfitId == o.id && o.state == "preview" {
                outfitSheet?.state = .done
                outfitSheet?.angles = o.angles
            }
        }
    }

    private func jobFinished(_ j: Job, newTakes: [Take]) {
        let ids = newTakes.map(\.id)
        fresh.formUnion(ids)
        showToast("\(j.title) is ready.", action: "Review") { [weak self] in
            guard let self else { return }
            self.openTake(ids.first ?? self.takes.first { $0.jobId == j.id }?.id ?? "")
        }
        if notifyDone {
            Notifier.shared.post(title: "\(j.title) is ready", body: "\(j.engineLabel) · \(Pricing.money(j.cost)) · \(max(1, j.request.takes)) take\(j.request.takes > 1 ? "s" : "") to review.")
        }
    }

    private func jobFailed(_ j: Job) {
        showToast("Render failed · \(j.title). \(Pricing.money(j.refunded)) refunded.", action: "Open queue") { [weak self] in self?.go(.queue) }
        if notifyFailed {
            Notifier.shared.post(title: "Render failed · \(j.title)", body: j.failureLine)
        }
    }

    /// A `wallet` event: refresh the credit and say what changed (in dollars; the API counts whole tokens of $0.01).
    private func walletChanged(_ w: Wallet) {
        let before = wallet
        wallet = w
        Task { [weak self] in
            guard let self, let b = try? await self.api.balance() else { return }
            self.balance = b
        }
        guard let before, before.userId == w.userId else { return }
        let delta = ((w.usd - before.usd) * 100).rounded() / 100
        // Holds and settles for my own renders move credit too (and change what's held); only tell about the owner's sends and take-backs.
        guard delta != 0, !w.isOwner, w.heldTokens == before.heldTokens else { return }
        if delta < 0 && jobs.contains(where: { $0.isActive && ($0.userId == nil || $0.userId == user?.id) }) { return }
        if delta > 0 {
            showToast("You received \(Pricing.money(delta)) · balance \(Pricing.money(w.usd))", action: "Credit") { [weak self] in self?.go(.credits) }
            Notifier.shared.post(title: "You received \(Pricing.money(delta))", body: "From the studio owner. Your balance is \(Pricing.money(w.usd)).")
        } else {
            showToast("The studio owner took back \(Pricing.money(-delta)) · balance \(Pricing.money(w.usd))")
            Notifier.shared.post(title: "\(Pricing.money(-delta)) taken back", body: "By the studio owner. Your balance is \(Pricing.money(w.usd)).")
        }
    }

    /// Owners: an engine's own account refused for lack of credit (the job failed and was refunded). Retired notices are ignored.
    private func studioNotice(_ n: EventNotice) {
        guard isOwner, n.code == "provider_out_of_credit" else { return }
        let msg = n.message.isEmpty ? "An engine is out of credit · see Settings → Engines" : n.message
        showToast(msg, action: "Models") { [weak self] in self?.openSettings(.spending) }
        Notifier.shared.post(title: "An engine is out of credit", body: msg)
        Task { [weak self] in await self?.loadStudio() }
    }

    // MARK: Auth

    func signIn() {
        authBusy = true
        authError = nil
        let email = authEmail.trimmingCharacters(in: .whitespaces)
        authPerform { [self] in
            let r = try await api.signIn(SignInRequest(email: email.isEmpty && isDemo ? "you@studio.com" : email, password: authPassword))
            await finishAuth(r)
        }
    }

    /// Like `perform`, but the error shows under the form (and as a toast) instead of signing out.
    private func authPerform(_ work: @escaping @MainActor () async throws -> Void) {
        Task {
            defer { authBusy = false }
            do { try await work() } catch let e as ApiError {
                authError = e.friendlyMessage
                if e.code == "email_taken" { withAnimation { authTab = .signIn } }
            } catch {
                authError = error.localizedDescription
            }
        }
    }

    /// Apple / Google buttons. Mocked: they sign in with a demo account.
    func signInSSO(_ provider: String) {
        authEmail = authEmail.isEmpty ? "studio@\(provider.lowercased()).example" : authEmail
        signIn()
    }

    func signUp() {
        guard attest[0] && attest[1] else {
            authError = ApiError.friendly("attestation_required")
            return
        }
        let invite = authInvite.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isDemo && invite.isEmpty {
            authError = ApiError.friendly("invite_required")
            return
        }
        authBusy = true
        authError = nil
        let email = authEmail.trimmingCharacters(in: .whitespaces)
        authPerform { [self] in
            let r = try await api.signUp(SignUpRequest(studioName: "", email: email.isEmpty && isDemo ? "you@studio.com" : email, password: authPassword,
                                                       inviteCode: invite, attestAdultRightsOriginal: attest[0], attestLabelAi: attest[1]))
            await finishAuth(r)
        }
    }

    private func finishAuth(_ r: AuthResponse) async {
        await api.setToken(r.token)
        if rememberMe {
            if !isDemo { Keychain.setToken(r.token, for: serverKey) }
            defaults.set(r.user.email, forKey: "muse.rememberedEmail")
        } else {
            // Memory only: quitting MUSE signs out.
            if !isDemo { Keychain.deleteToken(for: serverKey) }
            defaults.removeObject(forKey: "muse.rememberedEmail")
        }
        var u = r.user
        if isDemo && u.role == nil { u.role = "owner" }
        setUser(u)
        screen = .home
        authPassword = ""
        authInvite = ""
        authError = nil
        await connect()
    }

    /// Sign out: revokes the session on the server (POST /v1/auth/signout), then forgets it on this Mac.
    func signOut() {
        let api = self.api
        Task {
            try? await api.signOut()
            await api.setToken(nil)
        }
        endSession(nil, forgetToken: false)
    }

    /// Back to the sign-in screen, with `message` under the form (session ended, account switched off).
    func endSession(_ message: String?, forgetToken: Bool = true) {
        eventsTask?.cancel()
        listFreshness.invalidateAll()
        (api as? HTTPMuseAPI)?.invalidateCache()
        BlenderRelayService.shared.stop() // workstream 2
        if !isDemo { Keychain.deleteToken(for: serverKey) }
        user = nil
        wallet = nil
        members = []
        studioSettings = nil
        appliedServerQuality = false
        imageEngine = nil
        studioBalance = nil
        lastInvite = nil
        stageJobIds = []
        stageTakeId = nil
        resetModelTools()
        resetPromptLibrary()
        templates = []
        templateDetail = nil
        templateForm = nil
        resetWarm()
        authTab = .signIn
        attest = [false, false]
        authError = message
        defaults.removeObject(forKey: "muse.user")
        if forgetToken {
            let api = self.api
            Task { await api.setToken(nil) }
        }
    }

    // MARK: Navigation

    func openSettings(_ section: SettingsSection) {
        // Advanced is hidden until switched on under Account: going there (offline notice, palette) switches it on.
        if section == .advanced { UserDefaults.standard.set(true, forKey: "showAdvancedSettings") }
        if section != .studio { settingsPrompts = false }
        settingsSection = section
        go(.settings)
    }

    func go(_ s: Screen) {
        guard s != screen else { return }
        if s != .gallery { comparing = false }
        navForward = true
        // A fixed-duration curve, not a spring: a spring still settling when another animated change lands (an overlay
        // closing) could leave the old screen drawn (plans/claude-chat-mac.md, "the old screen stays drawn").
        withAnimation(MotionStyle.of(themeID).screenAnimation) { screen = s }
    }

    func setTheme(_ id: ThemeID) {
        guard id != themeID else { return }
        withAnimation(.easeOut(duration: 0.35)) { themeID = id }
    }

    func showToast(_ message: String, action: String? = nil, perform: (() -> Void)? = nil) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { toast = Toast(message: message, actionLabel: action, action: perform) }
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_600_000_000)
            if Task.isCancelled { return }
            withAnimation(.easeIn(duration: 0.25)) { self?.toast = nil }
        }
    }

    // MARK: Derived

    var currentModel: MuseModel? { models.first { $0.id == modelId } ?? models.first }
    var profileModel: MuseModel? { models.first { $0.id == profileModelId } ?? models.first }

    func outfits(for m: MuseModel?) -> [Outfit] {
        guard let m else { return [] }
        return m.outfitIds.compactMap { id in outfits.first { $0.id == id && $0.state == "ready" } }
    }

    var currentOutfits: [Outfit] { outfits(for: currentModel) }

    var currentOutfit: Outfit? {
        let list = currentOutfits
        if let id = outfitIdByModel[modelId], let o = list.first(where: { $0.id == id }) { return o }
        return list.first
    }


    func neverList(_ m: MuseModel?) -> [String] {
        guard let m else { return [] }
        return neverOverrides[m.id] ?? m.neverAdd
    }

    func identity(_ m: MuseModel?) -> PromptIdentity {
        guard let m else { return PromptIdentity(name: "Model", look: "") }
        var id = m.promptIdentity(lora: loras[m.id])
        id.neverAdd = neverList(m)
        return id
    }

    var spec: RenderSpec { spec(for: quality) }

    /// The price and labels for one option with the current clip and takes (always the whole clip).
    func spec(for q: VideoQuality) -> RenderSpec {
        RenderSpec.choice(q, clipSeconds: clip?.durationSec, takes: takeCount, lipSync: lipSync, pricePerSec: videoFeatures.pricePerSec(q))
    }

    /// `features.video` from the server, or the contract's table.
    var videoFeatures: VideoFeatures { studioSettings?.features.video ?? .fallback }
    /// `features.photo` from the server, or the contract's prices: photo estimates ("about $0.46").
    var photoPricing: PhotoPricing { studioSettings?.features.photo ?? .standard }
    var outfitSetEstimate: Double { photoPricing.estimates?.outfitSet ?? photoPricing.outfitSet() }
    func sheetAnglesEstimate(_ missing: Int) -> Double { photoPricing.estimates?.sheetAngle.map { $0 * Double(missing) } ?? photoPricing.sheetAngles(missing) }
    var loraSetEstimate: Double { photoPricing.estimates?.loraSet ?? photoPricing.loraSet() }
    /// Edit is picked: lip sync and a new background photo apply.
    var isEdit: Bool { quality == .edit }

    /// After reading the studio settings: the server's default until the user picks one, and never an option that's switched off.
    func syncQualityWithServer() {
        let f = videoFeatures
        if !appliedServerQuality, studioSettings != nil {
            appliedServerQuality = true
            if defaults.string(forKey: "muse.defaultQuality") == nil { quality = f.defaultOption }
        }
        if !f.isAvailable(quality), let first = f.ordered.first(where: \.available) { quality = first.videoQuality }
    }

    func setQuality(_ q: VideoQuality) {
        guard q != quality else { return }
        guard videoFeatures.isAvailable(q) else {
            showToast("\(q.label) isn't available right now")
            return
        }
        quality = q
    }

    var totalCost: Double { Pricing.totalCost(spec) }
    /// The toast for "can't afford this".
    var notEnoughMessage: String { isMember ? ApiError.friendly("insufficient_tokens")! : ApiError.friendly("insufficient_balance")! }
    /// What I can spend, in dollars: my wallet (member) or what I can spend or send (owner). Prefers the API's `usd` fields.
    var creditUsd: Double { wallet?.usd ?? balance.balance }
    /// The public address for invite links (the download page is `{server}/get`).
    var publicServerURL: String { (api as? HTTPMuseAPI)?.baseURL.absoluteString ?? defaultServerURL }
    var clipBad: Bool { !(clip?.ok ?? true) }
    /// The source clip's picture: its grabbed first frame, else the clip's own thumb, else neutral clip art. nil = no clip yet.
    var clipPoster: ImageRef? {
        guard let c = clip else { return nil }
        return clipThumb ?? c.thumb ?? .asset("src_clip")
    }
    /// The stage's right pane: the target, or the render started from here for this clip, model and outfit.
    var stage: StudioStage {
        StudioStage.resolve(jobs: jobs, takes: takes, started: stageJobIds, clipId: clip?.id, modelId: currentModel?.id, outfitId: currentOutfit?.id)
    }
    var lowBalance: Bool { totalCost > balance.balance + 1e-9 }
    /// Clip checks are advice only (owner decision): a failing clip shows a disclaimer but doesn't block generating.
    var generateBlocked: Bool { lowBalance || clip == nil || currentOutfit == nil || generating }

    var runningJob: Job? { jobs.first { $0.isRunning } }
    var activeJobs: [Job] { jobs.filter(\.isActive).sorted { a, b in a.isRunning != b.isRunning ? a.isRunning : a.createdAt < b.createdAt } }
    var finishedJobs: [Job] { jobs.filter(\.isDone) }
    var visibleFailures: [Job] { jobs.filter { $0.isFailed && !hiddenFailures.contains($0.id) } }
    var queuedCost: Double { jobs.filter(\.isQueued).reduce(0) { $0 + $1.cost } }
    var toReview: Int { takes.filter { $0.isVideo && !$0.isFinal }.count }
    var todaySpent: Double {
        if let t = balance.today { return t }
        let start = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
        return jobs.filter { $0.createdAt >= start }.reduce(0) { $0 + $1.cost - $1.refunded }
    }

    var galleryAll: [Take] { takes }
    var galleryList: [Take] {
        let list = galleryTab == .final ? takes.filter(\.isFinal) : takes
        // A collection picked in Library: its takes and photos only, in the order they were added (newest first).
        guard library.galleryCollection != nil else { return list }
        let byId = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return library.galleryCollectionTakes.compactMap { byId[$0] }
    }
    var openedTake: Take? { takes.first { $0.id == openTakeId } ?? takes.first }

    func job(for take: Take) -> Job? { take.jobId.flatMap { id in jobs.first { $0.id == id } } }
}

/// Runs one API call off the main actor for `async let` fan-out; nil when `on` is false or the call fails.
func attempt<T: Sendable>(_ on: Bool = true, _ call: @Sendable () async throws -> T) async -> T? {
    guard on else { return nil }
    return try? await call()
}

/// Screen transitions per theme (the prototype's `MOTION`).
enum MotionStyle {
    case a, b, c, d
    static func of(_ t: ThemeID) -> MotionStyle {
        switch t {
        case .a: return .a
        case .b: return .b
        case .c: return .c
        case .d: return .d
        }
    }

    var animation: Animation {
        switch self {
        case .a: return .timingCurve(0.22, 0.61, 0.36, 1, duration: 0.42)
        case .b: return .timingCurve(0.4, 0, 0.2, 1, duration: 0.2)
        case .c: return .spring(response: 0.45, dampingFraction: 0.72)
        case .d: return .spring(response: 0.42, dampingFraction: 0.6)
        }
    }

    /// Screen changes (`AppStore.go`): fixed-duration curves in every theme. C and D keep their springs' feel with a
    /// slight overshoot, but always finish on time, so the outgoing screen is never left mid-removal.
    var screenAnimation: Animation {
        switch self {
        case .a, .b: return animation
        case .c: return .timingCurve(0.3, 1.2, 0.5, 1, duration: 0.42)
        case .d: return .timingCurve(0.3, 1.45, 0.5, 1, duration: 0.4)
        }
    }

    /// The screen swap in `Shell`: the new screen comes in with the theme's insertion; the old one goes at once
    /// (`.identity`), so no removal can be left unfinished and only `store.screen` is ever drawn.
    var screenTransition: AnyTransition {
        switch self {
        case .a: return .asymmetric(insertion: .opacity.combined(with: .offset(y: 14)), removal: .identity)
        case .b: return .asymmetric(insertion: .opacity.combined(with: .offset(x: 24)), removal: .identity)
        case .c: return .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97)), removal: .identity)
        case .d: return .asymmetric(insertion: .opacity.combined(with: .offset(y: 26)), removal: .identity)
        }
    }

    var transition: AnyTransition {
        switch self {
        case .a: return .asymmetric(insertion: .opacity.combined(with: .offset(y: 14)), removal: .opacity)
        case .b: return .asymmetric(insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity)
        case .c: return .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97)), removal: .opacity)
        case .d: return .asymmetric(insertion: .opacity.combined(with: .offset(y: 26)), removal: .opacity)
        }
    }
}

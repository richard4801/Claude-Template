package studio.muse.app.data

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job as CoJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** Everything the screens show, kept live from the active MuseApi. */
data class StudioState(
    val models: List<Model> = emptyList(),
    val outfits: List<Outfit> = emptyList(),
    val jobs: List<Job> = emptyList(),
    val takes: List<Take> = emptyList(),
    val balance: Balance = Balance(0.0, 0.0),
    val loras: Map<String, Lora> = emptyMap(),
    val accounts: Map<String, List<Account>> = emptyMap(),
    val posts: List<Post> = emptyList(),
    /** My token wallet (real API). Null in demo mode against an older server. */
    val wallet: Wallet? = null,
    /** The template library (scope=all: mine + the studio's public ones). Tabs, search and tags filter it on the phone. */
    val templates: List<Template> = emptyList(),
    /** Keep add-on engine ready: the owner only (members never load it). Null for members and servers without it. */
    val warm: WarmGpu? = null,
    /** Render and add-ons from GET /v1/settings/studio (features.video). Null = the contract's defaults. */
    val video: VideoFeatures? = null,
    /** Photo prices for the estimates ("about $0.46"), from features.photo. */
    val photo: studio.muse.core.PhotoPrices = studio.muse.core.PhotoPrices(),
    /** Enhance and Dress up options (features.tools); the owner's copy also names the current models. */
    val tools: ToolsFeatures = ToolsFeatures(),
    /** Enhance and Dress up runs this session has seen, by id (kept live by `tool` events). */
    val toolRuns: Map<String, ToolRun> = emptyMap(),
    /** The owner's studio balance card, kept live by `studio` events (null until loaded; never for members). */
    val studioBalance: StudioBalance? = null,
    val loaded: Boolean = false,
    val error: String? = null,
) {
    fun lora(modelId: String?): Lora = loras[modelId] ?: Lora(modelId ?: "")
    fun accountsOf(modelId: String?): List<Account> = accounts[modelId].orEmpty()
    fun account(modelId: String?, platform: String) = accountsOf(modelId).firstOrNull { it.platform == platform }
    fun model(id: String?) = models.firstOrNull { it.id == id }
    fun outfit(id: String?) = outfits.firstOrNull { it.id == id }
    fun outfitsOf(modelId: String?): List<Outfit> = model(modelId)?.outfitIds?.mapNotNull { outfit(it) } ?: emptyList()
    fun job(id: String?) = jobs.firstOrNull { it.id == id }
    val running: Job? get() = jobs.firstOrNull { it.running }
}

/** A toast line, optionally tappable. */
data class Toast(val message: String, val route: String? = null, val id: Long = System.nanoTime())

/** Hooks the repository calls when jobs finish or fail (local notification, toast). */
fun interface JobListener {
    fun onJobFinished(job: Job)
}

class MuseRepository(
    private val scope: CoroutineScope,
    private val prefs: PrefsStore,
    private val fake: MuseApi,
    private val httpFactory: (String) -> MuseApi = { HttpMuseApi(it) },
) {
    private val _state = MutableStateFlow(StudioState())
    val state: StateFlow<StudioState> = _state.asStateFlow()
    private val _toasts = MutableSharedFlow<Toast>(extraBufferCapacity = 16)
    val toasts: SharedFlow<Toast> = _toasts
    var listener: JobListener? = null
    /** Called once when a LoRA training finishes (notification + toast). */
    var onLoraReady: ((Model?, Lora) -> Unit)? = null

    @Volatile var api: MuseApi = fake
        private set
    private var eventsJob: CoJob? = null
    private var refreshJob: CoJob? = null

    /** The session ended (unauthorized / account switched off): the app goes back to sign-in with this message. */
    private val _signedOut = MutableSharedFlow<String>(extraBufferCapacity = 4)
    val signedOut: SharedFlow<String> = _signedOut

    /** The 5-minute warning before a warm GPU turns itself off (in-app banner and notification). */
    /** Owner-screen events (members, invites, settings) for screens that hold their own lists. */
    private val _live = MutableSharedFlow<ApiEvent>(extraBufferCapacity = 32)
    val live: SharedFlow<ApiEvent> = _live

    private val _warmWarnings = MutableSharedFlow<WarmWarning>(extraBufferCapacity = 4)
    val warmWarnings: SharedFlow<WarmWarning> = _warmWarnings

    /** 0..1 while a file uploads (presigned PUT or multipart), null otherwise. */
    private val _upload = MutableStateFlow<Float?>(null)
    val uploadProgress: StateFlow<Float?> = _upload.asStateFlow()

    /** True for the in-app demo studio. */
    val demo: Boolean get() = api === fake

    init {
        scope.launch {
            prefs.prefs.map { Triple(it.useFake, it.serverUrl, it.token) }.distinctUntilChanged().collect { (useFake, url, token) ->
                val next = if (useFake) fake else (api.takeIf { it is HttpMuseApi && lastUrl == url } ?: httpFactory(url))
                lastUrl = url
                next.setToken(token)
                switchTo(next, token)
            }
        }
    }

    private var lastUrl: String? = null
    private var sessionToken: String? = null

    private fun switchTo(next: MuseApi, token: String?) {
        val changed = next !== api
        api = next
        sessionToken = token
        eventsJob?.cancel()
        refreshJob?.cancel()
        if (changed) _state.value = StudioState()
        // The real API needs a session for everything under /v1: nothing to load until signed in.
        if (next !== fake && token == null) { _state.value = StudioState(loaded = true); eventsJob = null; return }
        startEvents(next)
        refreshJob = scope.launch {
            if (next !== fake) restoreSession()
            refresh()
        }
    }

    private var eventsStartedAt = 0L
    private var connects = 0
    private var lastCatchUp = 0L

    private fun startEvents(a: MuseApi) {
        eventsJob?.cancel()
        connects = 0
        eventsStartedAt = System.currentTimeMillis()
        eventsJob = scope.launch { runCatching { a.events().collect { onEvent(it) } } }
    }

    /**
     * The app came to the foreground (Activity onStart): the stream may have died quietly while the phone slept or
     * changed networks, so it starts afresh, and the lists are refetched so nothing that happened meanwhile is missed.
     */
    fun onForeground() {
        val a = api
        if (a !== fake && sessionToken == null) return
        val now = System.currentTimeMillis()
        if (now - eventsStartedAt < 5_000) return // just started (launch, rotation)
        startEvents(a)
        catchUp()
    }

    /** Refetch after a reconnect or on foreground; at most once every 3 s. */
    private fun catchUp() {
        val now = System.currentTimeMillis()
        if (now - lastCatchUp < 3_000) return
        lastCatchUp = now
        scope.launch { refresh(); if (_state.value.templates.isNotEmpty()) loadTemplates(quiet = true) }
    }

    /** GET /v1/auth/me on launch: keeps the role current, or signs out if the session has ended. Offline keeps the session. */
    private suspend fun restoreSession() {
        try {
            val me = api.me()
            prefs.update { it.copy(role = me.role, email = me.email, studioName = me.studioName.ifBlank { it.studioName }, userId = me.id) }
        } catch (e: ApiException) {
            if (e.code in ErrorText.SIGN_OUT_CODES) endSession(ErrorText.of(e))
        }
    }

    fun toast(msg: String, route: String? = null) { _toasts.tryEmit(Toast(msg, route)) }

    suspend fun refresh() {
        try {
            val a = api
            val models = a.listModels()
            val outfits = a.listOutfits()
            val jobs = a.listJobs()
            val takes = a.listTakes()
            val bal = a.balance()
            val wallet = runCatching { a.wallet() }.getOrNull()
            // LoRAs, accounts and posts are newer endpoints: an older server without them still loads.
            val loras = models.mapNotNull { m -> runCatching { a.lora(m.id) }.getOrNull()?.let { m.id to it } }.toMap()
            val accounts = models.mapNotNull { m -> runCatching { a.listAccounts(m.id) }.getOrNull()?.let { m.id to it } }.toMap()
            val posts = runCatching { a.listPosts() }.getOrDefault(emptyList())
            // Keep add-on engine ready is owner-only: members never ask for it (the server answers 403 anyway).
            val owner = wallet?.owner ?: (bal.role == "owner")
            val warm = if (owner) runCatching { a.warmGpu() }.getOrNull() else null
            val features = runCatching { a.studioSettings().features }.getOrNull()
            if (a !== api) return
            _state.update {
                StudioState(models, outfits, jobs.sortedByDescending { it.createdAt }, takes, bal, loras, accounts, posts, wallet, warm = warm, video = features?.video,
                    photo = features?.photo?.prices ?: studio.muse.core.PhotoPrices(), tools = features?.tools ?: ToolsFeatures(), toolRuns = it.toolRuns,
                    templates = it.templates, studioBalance = it.studioBalance, loaded = true)
            }
        } catch (e: ApiException) {
            _state.update { it.copy(loaded = true, error = ErrorText.of(e)) }
            if (e.code in ErrorText.SIGN_OUT_CODES) endSession(ErrorText.of(e)) else toast(ErrorText.of(e))
        }
    }

    private suspend fun endSession(message: String) {
        if (sessionToken == null && api !== fake) return
        sessionToken = null
        prefs.update { it.copy(token = null) }
        _signedOut.tryEmit(message)
    }

    private fun onEvent(ev: ApiEvent) {
        if (ev.type == ApiEvent.CONNECTED) {
            // The first connect comes with the initial load; every later one is a reconnect after a drop: catch up.
            if (connects++ > 0) catchUp()
            return
        }
        val before = _state.value
        val owner = isOwner()
        val prevJob = ev.job?.let { before.job(it.id) }
        val prevTool = ev.tool?.let { before.toolRuns[it.id] }
        val prevLora = ev.lora?.let { before.loras[it.modelId] }
        val prevWallet = before.wallet
        // gpu events only ever reach the owner who switched Keep add-on engine ready on; never shown to members.
        val apply = if (ev.type == "gpu" && !owner) ev.copy(gpu = null) else ev
        _state.update { LiveEvents.apply(it, apply, owner) }
        ev.wallet?.let { w -> onWallet(w, prevWallet) }
        // Owner notices only (an engine's own account is out of credit): Settings → Engines says which.
        ev.notice?.let { n ->
            if (n.code == "provider_out_of_credit") toast("An engine is out of credit · see Settings → Engines", "studio")
            else if (n.message.isNotBlank() && !Regex("(?i)gpu|runpod").containsMatchIn(n.message)) toast(n.message)
        }
        ev.tool?.let { r -> toolToasts(prevTool, r) }
        ev.lora?.let { l -> if (prevLora?.state == "training" && l.state == "ready") onLoraReady?.invoke(_state.value.model(l.modelId), l) }
        if (owner) {
            ev.gpu?.let { g -> putWarm(g) }
            if (ev.type == "gpu" && ev.event == "warning") ev.warning?.let { _warmWarnings.tryEmit(it) }
        }
        ev.job?.let { j -> if (ev.op != "delete" && (prevJob == null || prevJob.running) && (j.done || j.failed)) listener?.onJobFinished(j) }
        if (ev.type in setOf("member", "invite", "settings", "studio", "prompts")) _live.tryEmit(ev)
    }

    /** A `wallet` event: refresh the balance, and say so when the owner sent or took back tokens. */
    private fun onWallet(w: Wallet, prev: Wallet?) {
        if (prev == null || w.owner || prev.userId != w.userId) return
        val delta = w.tokens - prev.tokens
        // A transfer moves tokens without touching holds; refunds and settlements release a hold, so they aren't gifts.
        val holdsSame = w.heldTokens >= prev.heldTokens
        if (delta > 0 && holdsSame) toast("You received ${Credit.money(Credit.usdOf(delta, w.tokenUsd))} from ${ownerName()}", "credits")
        else if (delta < 0 && w.heldTokens == prev.heldTokens) toast("${ownerName().replaceFirstChar { it.uppercase() }} took back ${Credit.money(Credit.usdOf(-delta, w.tokenUsd))}", "credits")
        scope.launch { refreshBalance() }
    }

    private var ownerLabel: String = ""
    /** Who sends tokens. The wallet event doesn't say, so it's the studio (its owner). */
    private fun ownerName() = ownerLabel.ifBlank { "the studio owner" }
    fun setStudioName(name: String) { ownerLabel = name }

    private fun putLora(l: Lora) {
        val prev = _state.value.loras[l.modelId]
        _state.update { s -> s.copy(loras = s.loras + (l.modelId to l)) }
        if (prev?.state == "training" && l.state == "ready") onLoraReady?.invoke(_state.value.model(l.modelId), l)
    }

    private fun isOwner() = _state.value.wallet?.owner ?: (_state.value.balance.role == "owner")

    /** A new Keep add-on engine ready state (owner). When it turned itself off, say why. */
    private fun putWarm(g: WarmGpu) {
        val prev = _state.value.warm
        _state.update { it.copy(warm = g) }
        val off = g.lastOff
        if (prev?.on == true && !g.on && off != null && off.reason != "user") toast("Add-on engine turned off · ${warmOffWhy(off.reason, g.idleMinutes)} · ${Credit.money(off.costUsd)}")
    }

    // ---- Keep add-on engine ready (owner only)
    suspend fun refreshWarm() { if (isOwner()) runCatching { api.warmGpu() }.onSuccess { putWarm(it) } }
    suspend fun setWarm(on: Boolean) = attempt { setWarmGpu(WarmRequest(on = on)) }?.also { putWarm(it); refreshBalance() }
    /** "Keep warm": restarts the idle clock, or extends the time limit once. */
    suspend fun keepWarm() = attempt { setWarmGpu(WarmRequest(extend = true)) }?.also { putWarm(it) }

    private inline fun <T> List<T>.upsert(item: T, match: (T) -> Boolean): List<T> =
        if (any(match)) map { if (match(it)) item else it } else listOf(item) + this

    /** Runs an API call; on failure shows a friendly message as a toast and returns null. An ended session goes to sign-in. */
    suspend fun <T> attempt(block: suspend MuseApi.() -> T): T? = try {
        api.block()
    } catch (e: ApiException) {
        if (e.code in ErrorText.SIGN_OUT_CODES) endSession(ErrorText.of(e)) else toast(ErrorText.of(e), routeFor(e.code))
        null
    }

    /** Like [attempt], but hands the friendly error back instead of a toast (for inline messages). */
    suspend fun <T> attemptInline(block: suspend MuseApi.() -> T): Pair<T?, String?> = try {
        api.block() to null
    } catch (e: ApiException) {
        null to ErrorText.of(e)
    }

    private fun routeFor(code: String) = when (code) { "insufficient_tokens", "insufficient_balance", "over_user_day_limit" -> "credits"; else -> null }

    /** Wraps an upload so the app shows its progress. */
    suspend fun <T> withUploadProgress(block: suspend ((Float) -> Unit) -> T): T {
        _upload.value = 0f
        return try { block { p -> _upload.value = p.coerceIn(0f, 1f) } } finally { _upload.value = null }
    }

    // ---- Model tools (plans/api.md "Model tools")
    fun putTool(r: ToolRun) {
        val prev = _state.value.toolRuns[r.id]
        _state.update { it.copy(toolRuns = it.toolRuns + (r.id to r)) }
        toolToasts(prev, r)
    }
    private fun toolToasts(prev: ToolRun?, r: ToolRun) {
        if (prev?.state == "running" && r.state == "review") toast("${if (r.kind == "enhance") "Enhance" else "Dress up"} is ready to review")
        if (prev?.state == "running" && r.state == "failed") toast(r.error ?: "Something went wrong · you weren't charged")
    }
    suspend fun enhanceEstimate(modelId: String, req: EnhanceRequest) = attemptInline { enhanceEstimate(modelId, req) }
    suspend fun dressUpEstimate(modelId: String, req: DressUpRequest) = attemptInline { dressUpEstimate(modelId, req) }
    suspend fun startEnhance(modelId: String, req: EnhanceRequest) = attempt { startEnhance(modelId, req) }?.also { putTool(it); refreshBalance() }
    suspend fun startDressUp(modelId: String, req: DressUpRequest) = attempt { startDressUp(modelId, req) }?.also { putTool(it); refreshBalance() }
    suspend fun loadToolRuns(modelId: String) = attempt { toolRuns(modelId) }?.also { list -> _state.update { s -> s.copy(toolRuns = s.toolRuns + list.associateBy { it.id }) } }
    suspend fun decideTool(id: String, slot: String, keep: Boolean, pick: String? = null) = attempt { decideTool(id, slot, DecideRequest(if (keep) "keep" else "reject", pick)) }?.also(::putTool)
    suspend fun pickTool(id: String, pick: String) = attempt { pickTool(id, pick) }?.also(::putTool)
    suspend fun retryTool(id: String, slot: String, engine: String? = null) = attempt { retryTool(id, slot, engine) }?.also { putTool(it); refreshBalance() }
    suspend fun applyTool(id: String, name: String? = null) = attempt { applyTool(id, name) }?.also { r ->
        putTool(r.run)
        _state.update { s -> s.copy(models = s.models.upsert(r.model) { it.id == r.model.id }, outfits = r.outfit?.let { o -> s.outfits.upsert(o) { it.id == o.id } } ?: s.outfits) }
    }
    suspend fun discardTool(id: String) = attempt { discardTool(id) }?.also { _state.value.toolRuns[id]?.let { putTool(it.copy(state = "discarded")) } }
    suspend fun sheetVersions(modelId: String) = attempt { sheetVersions(modelId) }
    suspend fun restoreSheet(modelId: String, vid: String) = attempt { restoreSheet(modelId, vid) }?.also { m -> _state.update { s -> s.copy(models = s.models.upsert(m) { it.id == m.id }) } }
    suspend fun archiveModel(id: String, archived: Boolean) = attempt { archiveModel(id, archived) }?.also { m ->
        _state.update { s -> s.copy(models = if (m.archived) s.models.filterNot { it.id == m.id } else s.models.upsert(m) { it.id == m.id }) }
        if (!archived) refresh()
    }
    suspend fun archivedModels() = attempt { archivedModels() }
    suspend fun imageModels() = attemptInline { imageModels() }
    suspend fun imageCatalog(step: String, q: String?) = attemptInline { imageCatalog(step, q) }
    suspend fun imageModel(id: String, step: String) = attemptInline { imageModel(id, step) }
    suspend fun setImageModel(step: String, model: String) = attemptInline { setImageModel(step, SetStepModelRequest(model)) }
    suspend fun resetImageModel(step: String) = attemptInline { resetImageModel(step) }

    // ---- actions ----
    /** Returns null on success, or the friendly error to show under the form. */
    /**
     * [remember] (Sign in's Remember me): on keeps the session and the email across restarts; off keeps the token in memory
     * only, so the app is signed out once its process ends, and doesn't save the email. The password is never stored.
     */
    suspend fun signIn(email: String, password: String, remember: Boolean = true): String? = auth(remember) { signIn(SignInRequest(email.trim(), password)) }
    suspend fun signUp(req: SignUpRequest): String? = auth(true) { signUp(req) }

    private suspend fun auth(remember: Boolean, block: suspend MuseApi.() -> AuthResponse): String? = try {
        onAuth(api.block(), remember); null
    } catch (e: ApiException) {
        ErrorText.of(e)
    }

    private suspend fun onAuth(r: AuthResponse, remember: Boolean) {
        api.setToken(r.token)
        prefs.update { it.copy(token = r.token, studioName = r.user.studioName, email = r.user.email, role = r.user.role, userId = r.user.id, rememberMe = remember) }
    }

    /** POST /v1/auth/signout (best effort), then forget the session on this phone. */
    suspend fun signOut() {
        val a = api
        runCatching { kotlinx.coroutines.withTimeoutOrNull(4000) { a.signOut() } }
        prefs.update { it.copy(token = null, role = "member", userId = "") }
        _state.value = StudioState(loaded = true)
    }

    suspend fun createModel(req: CreateModelRequest) = attempt { createModel(req) }?.also { m -> _state.update { s -> s.copy(models = s.models.filterNot { it.id == m.id } + m) } }

    suspend fun setSlot(modelId: String, slot: String, image: ImageRef?, source: String = "upload") =
        attempt { setSlot(modelId, slot, SetSlotRequest(image, source)) }?.also { m -> _state.update { s -> s.copy(models = s.models.upsert(m) { it.id == m.id }) } }

    suspend fun fillAngles(modelId: String) = attempt { fillAngles(modelId) }?.also { r ->
        _state.update { s -> s.copy(models = s.models.upsert(r.model) { it.id == r.model.id }) }
        refreshBalance()
    }

    suspend fun createOutfit(req: CreateOutfitRequest) = attempt { createOutfit(req) }?.also { o -> _state.update { s -> s.copy(outfits = s.outfits.upsert(o) { it.id == o.id }) } }

    suspend fun saveOutfit(id: String) = attempt { saveOutfit(id) }?.also { o ->
        _state.update { s ->
            s.copy(
                outfits = s.outfits.upsert(o) { it.id == o.id },
                models = s.models.map { if (it.id == o.modelId && o.id !in it.outfitIds) it.copy(outfitIds = it.outfitIds + o.id) else it },
            )
        }
    }

    suspend fun uploadImage(name: String, bytes: ByteArray, mime: String) = withUploadProgress { p -> attempt { uploadImage(name, bytes, mime, p) } }
    suspend fun uploadClip(meta: ClipMeta, bytes: ByteArray?, mime: String = "video/mp4") =
        if (bytes == null) attempt { uploadClip(meta, null, mime) } else withUploadProgress { p -> attempt { uploadClip(meta, bytes, mime, p) } }

    suspend fun createJob(req: JobRequest) = attempt { createJob(req) }?.also { j ->
        _state.update { s -> s.copy(jobs = s.jobs.upsert(j) { it.id == j.id }.sortedByDescending { it.createdAt }) }
        refreshBalance()
    }

    suspend fun removeJob(id: String) = attempt { removeJob(id) }?.also { _state.update { s -> s.copy(jobs = s.jobs.filterNot { it.id == id }) } }

    suspend fun setTakeStatus(id: String, status: String) = attempt { setTakeStatus(id, status) }?.also { t -> _state.update { s -> s.copy(takes = s.takes.upsert(t) { it.id == t.id }) } }

    suspend fun deleteTake(id: String) = attempt { deleteTake(id) }?.also { _state.update { s -> s.copy(takes = s.takes.filterNot { it.id == id }) } }

    suspend fun shoot(req: ShootRequest) = attempt { shoot(req) }?.also { shots ->
        _state.update { s -> s.copy(takes = LiveEvents.putTakes(s.takes, shots)) }
        refreshBalance()
    }

    /**
     * The final prompt, images and price of a shoot, from the server (POST /v1/shoots/preview). Quiet: null when it can't be
     * reached (an older server, offline), and the Prompt tool falls back to the app's own engine. A bad_request (bad refs) is said.
     */
    suspend fun previewShoot(req: ShootRequest): ShootPreview? = try {
        api.previewShoot(req)
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (e: ApiException) {
        if (e.code == "bad_request") toast(ErrorText.of(e))
        null
    } catch (e: Exception) {
        null
    }

    // ---- prompt library (owner Settings → Prompts)
    suspend fun prompts(): Pair<PromptLibrary?, String?> = try {
        api.prompts() to null
    } catch (e: ApiException) {
        null to if (e.code == "not_found" || e.code == "http_404") "This server doesn't have the prompt library yet." else ErrorText.of(e)
    }
    /** Save (PUT): the entry, or the server's prompt_invalid message to show under the editor (other failures are toasts). */
    suspend fun savePrompt(key: String, text: String): Pair<PromptEntry?, String?> = try {
        api.savePrompt(key, text) to null
    } catch (e: ApiException) {
        if (e.code == "prompt_invalid") null to ErrorText.of(e) else { toast(ErrorText.of(e)); null to null }
    }
    suspend fun resetPrompt(key: String) = attemptInline { resetPrompt(key) }
    /** The editor's live preview: the preview, or the server's prompt_invalid message (null for any other failure: the old preview stays). */
    suspend fun previewPrompt(key: String, text: String?): Pair<PromptPreview?, String?> = try {
        api.previewPrompt(PromptPreviewRequest(key, text)) to null
    } catch (e: ApiException) {
        null to if (e.code == "prompt_invalid") ErrorText.of(e) else null
    }

    // ---- photo templates
    private fun putTemplate(t: Template) = _state.update { s -> s.copy(templates = s.templates.upsert(t) { it.id == t.id }) }
    /** [quiet]: no toast on failure (the Photoshoot strip, against a server without templates). */
    suspend fun loadTemplates(quiet: Boolean = false): List<Template>? =
        (if (quiet) attemptInline { listTemplates("all") }.first else attempt { listTemplates("all") })?.also { l -> _state.update { it.copy(templates = l) } }
    suspend fun template(id: String) = attemptInline { template(id) }.also { (t, _) -> t?.let { putTemplate(it.copy(recent = null)) } }
    suspend fun templateDraft(shotId: String) = attemptInline { templateDraft(shotId) }
    suspend fun createTemplate(req: CreateTemplateRequest) = attemptInline { createTemplate(req) }.also { (t, _) -> t?.let(::putTemplate) }
    suspend fun patchTemplate(id: String, req: PatchTemplateRequest) = attempt { patchTemplate(id, req) }?.also(::putTemplate)
    suspend fun duplicateTemplate(id: String) = attempt { duplicateTemplate(id) }?.also(::putTemplate)
    suspend fun favouriteTemplate(id: String, on: Boolean) = attempt { favouriteTemplate(id, on) }?.also(::putTemplate)
    suspend fun deleteTemplate(id: String) = attempt { deleteTemplate(id) }?.also { _state.update { s -> s.copy(templates = s.templates.filterNot { it.id == id }) } }
    suspend fun templatePrompt(id: String, req: TemplatePromptRequest) = attemptInline { templatePrompt(id, req) }

    suspend fun topUp(amount: Double, method: String) = attempt { topUp(TopUpRequest(amount, method)) }?.also { b -> _state.update { it.copy(balance = b) } }

    // ---- the owner-loaded studio balance
    suspend fun studioBalance() = attemptInline { studioBalance() }.also { (b, _) -> b?.let { v -> _state.update { it.copy(studioBalance = v) } } }
    /** Records "Added $20" (owner). Returns the new studio balance, or the friendly error. */
    suspend fun addTopUp(amountUsd: Double, note: String?) =
        attemptInline { addTopUp(AddTopUpRequest(amountUsd, note?.trim()?.ifBlank { null })) }.also { (r, _) -> if (r != null) { _state.update { it.copy(studioBalance = r) }; refreshBalance() } }

    /** Upscale a finished render (coming soon). */
    suspend fun upscale(takeId: String, size: String) = attempt { upscale(takeId, size) }?.also { j ->
        _state.update { s -> s.copy(jobs = s.jobs.upsert(j) { it.id == j.id }.sortedByDescending { it.createdAt }) }
        refreshBalance()
    }

    suspend fun setFailNext(fail: Boolean) = attempt { setFailNext(fail) }

    suspend fun runQueue() = attempt { runQueue() }?.also { started ->
        _state.update { s -> started.fold(s.jobs) { acc, j -> acc.upsert(j) { it.id == j.id } }.let { s.copy(jobs = it.sortedByDescending { j -> j.createdAt }) } }
        refreshBalance()
    }

    // ---- models
    suspend fun updateModel(id: String, req: UpdateModelRequest) = attempt { updateModel(id, req) }?.also { m -> _state.update { s -> s.copy(models = s.models.upsert(m) { it.id == m.id }) } }

    suspend fun deleteModel(id: String) = attempt { deleteModel(id) }?.also { _state.update { s -> LiveEvents.dropModel(s, id) } }

    // ---- Identity LoRA
    suspend fun buildLoraSet(modelId: String) = attempt { buildLoraSet(modelId) }?.also { putLora(it); refreshBalance() }

    /** Optimistic: the tile flips at once, then the server's copy replaces it. */
    suspend fun keepCandidate(modelId: String, cid: String, keep: Boolean): Lora? {
        val l = _state.value.lora(modelId)
        putLora(l.copy(candidates = l.candidates.map { if (it.id == cid) it.copy(keep = keep) else it }))
        return attempt { keepCandidate(modelId, cid, keep) }?.also { putLora(it) } ?: run { putLora(l); null }
    }

    suspend fun trainLora(modelId: String) = attempt { trainLora(modelId) }?.also { putLora(it); refreshBalance() }
    suspend fun setLoraUse(modelId: String, use: Boolean) = attempt { patchLora(modelId, PatchLoraRequest(use = use)) }?.also { putLora(it) }
    suspend fun retrainLora(modelId: String) = attempt { patchLora(modelId, PatchLoraRequest(state = "review")) }?.also { putLora(it) }

    // ---- accounts and posts
    suspend fun connect(modelId: String, platform: String) = attempt { connectAccount(modelId, platform) }?.also { r ->
        r.account?.let { a -> _state.update { s -> s.copy(accounts = s.accounts + (modelId to (s.accountsOf(modelId).filterNot { it.platform == a.platform } + a))) } }
    }

    suspend fun disconnect(modelId: String, platform: String) = attempt { disconnectAccount(modelId, platform) }?.also {
        _state.update { s -> s.copy(accounts = s.accounts + (modelId to s.accountsOf(modelId).filterNot { it.platform == platform })) }
    }

    suspend fun createPost(req: CreatePostRequest) = attempt { createPost(req) }?.also { p -> _state.update { s -> s.copy(posts = s.posts.upsert(p) { it.id == p.id }) } }
    suspend fun deletePost(id: String) = attempt { deletePost(id) }?.also { _state.update { s -> s.copy(posts = s.posts.filterNot { it.id == id }) } }

    // ---- tokens, members, invites and studio settings (owner screens fetch these on demand)
    suspend fun refreshWallet() { runCatching { api.wallet() }.onSuccess { w -> _state.update { it.copy(wallet = w) } } }
    suspend fun members() = attempt { listMembers() }
    suspend fun invites() = attempt { listInvites() }

    /** Owner → member. The server refuses over-allocation with a message saying what the studio balance has free. */
    suspend fun transfer(member: Member, tokens: Long, note: String?) =
        attemptInline { transfer(TransferRequest(member.id, tokens, note?.ifBlank { null })) }.also { (r, _) -> r?.let { res -> _state.update { it.copy(wallet = res.wallet) }; refreshBalance() } }

    suspend fun reclaim(member: Member, tokens: Long, note: String?) =
        attemptInline { reclaim(ReclaimRequest(member.id, tokens, note?.ifBlank { null })) }.also { (r, _) -> r?.let { res -> _state.update { it.copy(wallet = res.wallet) }; refreshBalance() } }

    suspend fun patchMember(id: String, patch: MemberPatch) = attemptInline { patchMember(id, patch) }
    suspend fun createInvite(email: String?) = attemptInline { createInvite(CreateInviteRequest(email = email?.trim()?.ifBlank { null })) }
    suspend fun studioSettings() = attempt { studioSettings() }
    suspend fun patchStudioSettings(p: StudioSettingsPatch) = attemptInline { patchStudioSettings(p) }
    suspend fun imageEngine() = attempt { imageEngine() }
    suspend fun setImageEngine(p: ImageEnginePatch) = attemptInline { setImageEngine(p) }

    private suspend fun refreshBalance() {
        runCatching { api.balance() }.onSuccess { b -> _state.update { it.copy(balance = b) } }
        refreshWallet()
    }
}

/** Why Keep add-on engine ready turned itself off, for the owner's toast. */
fun warmOffWhy(reason: String, idleMinutes: Int) = when (reason) {
    "idle" -> "$idleMinutes min without renders"
    "cap" -> "it reached its time limit"
    "credit", "owner_balance" -> "the studio balance is running low"
    "gpu_lost" -> "the engine stopped responding"
    else -> "turned off"
}

/** 12,500 */
fun fmtTokens(n: Long): String = String.format(java.util.Locale.US, "%,d", n)

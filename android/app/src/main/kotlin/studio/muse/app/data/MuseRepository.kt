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

    init {
        scope.launch {
            prefs.prefs.map { Triple(it.useFake, it.serverUrl, it.token) }.distinctUntilChanged().collect { (useFake, url, token) ->
                val next = if (useFake) fake else (api.takeIf { it is HttpMuseApi && lastUrl == url } ?: httpFactory(url))
                lastUrl = url
                next.setToken(token)
                if (next !== api || eventsJob == null) switchTo(next)
            }
        }
    }

    private var lastUrl: String? = null

    private fun switchTo(next: MuseApi) {
        api = next
        eventsJob?.cancel()
        eventsJob = scope.launch { runCatching { next.events().collect { onEvent(it) } } }
        scope.launch { refresh() }
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
            // LoRAs, accounts and posts are newer endpoints: an older server without them still loads.
            val loras = models.mapNotNull { m -> runCatching { a.lora(m.id) }.getOrNull()?.let { m.id to it } }.toMap()
            val accounts = models.mapNotNull { m -> runCatching { a.listAccounts(m.id) }.getOrNull()?.let { m.id to it } }.toMap()
            val posts = runCatching { a.listPosts() }.getOrDefault(emptyList())
            _state.update { StudioState(models, outfits, jobs.sortedByDescending { it.createdAt }, takes, bal, loras, accounts, posts, loaded = true) }
        } catch (e: ApiException) {
            _state.update { it.copy(loaded = true, error = e.message) }
            toast(e.message ?: "Error")
        }
    }

    private fun onEvent(ev: ApiEvent) {
        ev.balance?.let { b -> _state.update { it.copy(balance = b) } }
        ev.model?.let { m -> _state.update { s -> s.copy(models = s.models.upsert(m) { it.id == m.id }) } }
        ev.outfit?.let { o -> _state.update { s -> s.copy(outfits = s.outfits.upsert(o) { it.id == o.id }) } }
        ev.lora?.let { l -> putLora(l) }
        ev.post?.let { p -> _state.update { s -> s.copy(posts = s.posts.upsert(p) { it.id == p.id }) } }
        if (ev.takes.isNotEmpty()) _state.update { s -> s.copy(takes = ev.takes + s.takes.filterNot { t -> ev.takes.any { it.id == t.id } }) }
        ev.job?.let { j ->
            val prev = _state.value.job(j.id)
            _state.update { s -> s.copy(jobs = s.jobs.upsert(j) { it.id == j.id }.sortedByDescending { it.createdAt }) }
            if ((prev == null || prev.running) && (j.done || j.failed)) listener?.onJobFinished(j)
        }
    }

    private fun putLora(l: Lora) {
        val prev = _state.value.loras[l.modelId]
        _state.update { s -> s.copy(loras = s.loras + (l.modelId to l)) }
        if (prev?.state == "training" && l.state == "ready") onLoraReady?.invoke(_state.value.model(l.modelId), l)
    }

    private inline fun <T> List<T>.upsert(item: T, match: (T) -> Boolean): List<T> =
        if (any(match)) map { if (match(it)) item else it } else listOf(item) + this

    /** Runs an API call; on failure shows the server's message as a toast and returns null. */
    suspend fun <T> attempt(block: suspend MuseApi.() -> T): T? = try {
        api.block()
    } catch (e: ApiException) {
        toast(e.message ?: "Something went wrong")
        null
    }

    // ---- actions ----
    suspend fun signIn(email: String, password: String) = attempt { signIn(SignInRequest(email, password)) }?.also { onAuth(it) }
    suspend fun signUp(req: SignUpRequest) = attempt { signUp(req) }?.also { onAuth(it) }

    private suspend fun onAuth(r: AuthResponse) {
        api.setToken(r.token)
        prefs.update { it.copy(token = r.token, studioName = r.user.studioName, email = r.user.email) }
        refresh()
    }

    suspend fun signOut() = prefs.update { it.copy(token = null) }

    suspend fun createModel(req: CreateModelRequest) = attempt { createModel(req) }?.also { m -> _state.update { it.copy(models = it.models + m) } }

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

    suspend fun uploadImage(name: String, bytes: ByteArray, mime: String) = attempt { uploadImage(name, bytes, mime) }
    suspend fun uploadClip(meta: ClipMeta, bytes: ByteArray?) = attempt { uploadClip(meta, bytes) }

    suspend fun createJob(req: JobRequest) = attempt { createJob(req) }?.also { j ->
        _state.update { s -> s.copy(jobs = s.jobs.upsert(j) { it.id == j.id }.sortedByDescending { it.createdAt }) }
        refreshBalance()
    }

    suspend fun removeJob(id: String) = attempt { removeJob(id) }?.also { _state.update { s -> s.copy(jobs = s.jobs.filterNot { it.id == id }) } }

    suspend fun setTakeStatus(id: String, status: String) = attempt { setTakeStatus(id, status) }?.also { t -> _state.update { s -> s.copy(takes = s.takes.upsert(t) { it.id == t.id }) } }

    suspend fun deleteTake(id: String) = attempt { deleteTake(id) }?.also { _state.update { s -> s.copy(takes = s.takes.filterNot { it.id == id }) } }

    suspend fun shoot(req: ShootRequest) = attempt { shoot(req) }?.also { shots ->
        _state.update { s -> s.copy(takes = shots + s.takes) }
        refreshBalance()
    }

    suspend fun topUp(amount: Double, method: String) = attempt { topUp(TopUpRequest(amount, method)) }?.also { b -> _state.update { it.copy(balance = b) } }

    suspend fun setFailNext(fail: Boolean) = attempt { setFailNext(fail) }

    suspend fun runQueue() = attempt { runQueue() }?.also { started ->
        _state.update { s -> started.fold(s.jobs) { acc, j -> acc.upsert(j) { it.id == j.id } }.let { s.copy(jobs = it.sortedByDescending { j -> j.createdAt }) } }
        refreshBalance()
    }

    // ---- models
    suspend fun updateModel(id: String, req: UpdateModelRequest) = attempt { updateModel(id, req) }?.also { m -> _state.update { s -> s.copy(models = s.models.upsert(m) { it.id == m.id }) } }

    suspend fun deleteModel(id: String) = attempt { deleteModel(id) }?.also {
        _state.update { s ->
            s.copy(models = s.models.filterNot { it.id == id }, outfits = s.outfits.filterNot { it.modelId == id }, loras = s.loras - id, accounts = s.accounts - id,
                posts = s.posts.filterNot { it.modelId == id && !it.out })
        }
    }

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

    private suspend fun refreshBalance() {
        runCatching { api.balance() }.onSuccess { b -> _state.update { it.copy(balance = b) } }
    }
}

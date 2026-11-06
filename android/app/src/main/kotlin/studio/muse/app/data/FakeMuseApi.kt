package studio.muse.app.data

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job as CoJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonArray // Edit suite (workstream 3)
import kotlinx.serialization.json.JsonElement // Edit suite (workstream 3)
import kotlinx.serialization.json.JsonObject // Edit suite (workstream 3)
import kotlinx.serialization.json.JsonPrimitive // Edit suite (workstream 3)
import studio.muse.core.ClipUse
import studio.muse.core.Engine
import studio.muse.core.Quality
import studio.muse.core.Identity
import studio.muse.core.OutfitSource
import studio.muse.core.OutfitSpec
import studio.muse.core.Pricing
import studio.muse.core.PhotoPricing
import studio.muse.core.PromptEngine
import studio.muse.core.SourcePerformer
import studio.muse.core.VideoSwapSpec
import studio.muse.core.edit.Asset as EdAsset // Edit sessions (workstream 3)
import studio.muse.core.edit.AssetKind as EdAssetKind // Edit sessions (workstream 3)
import studio.muse.core.edit.Canvas as EdCanvas // Edit sessions (workstream 3)
import studio.muse.core.edit.EditJson as EdEditJson // Edit sessions (workstream 3)
import studio.muse.core.edit.EditProject as EdEditProject // Edit sessions (workstream 3)
import studio.muse.core.edit.JsonPatch as EdJsonPatch // Edit sessions (workstream 3)
import studio.muse.core.edit.Look as EdLook // Edit sessions (workstream 3)
import studio.muse.core.edit.PatchException as EdPatchException // Edit sessions (workstream 3)
import studio.muse.core.edit.PatchOp as EdPatchOp // Edit sessions (workstream 3)
import studio.muse.core.edit.Track as EdTrack // Edit sessions (workstream 3)
import studio.muse.core.edit.TrackKind as EdTrackKind // Edit sessions (workstream 3)
import studio.muse.core.edit.VideoClip as EdVideoClip // Edit sessions (workstream 3)
import studio.muse.core.edit.durationSec as edDurationSec // Edit sessions (workstream 3)
import studio.muse.core.edit.problemOf as edProblemOf // Edit sessions (workstream 3)
import java.io.File
import java.util.UUID

/**
 * In-process backend so the APK works standalone. Same rules as server/mock: renders run [speed]× faster than real
 * time, the balance is held when a job starts and refunded if it fails, and progress arrives as events.
 *
 * @param speed simulation speed; 0 freezes running jobs (used by screenshot tests).
 * @param storeDir where uploaded images are copied.
 */
class FakeMuseApi(
    private val scope: CoroutineScope,
    private val storeDir: File? = null,
    private val speed: Double = DEMO_SPEED,
    private val now: () -> Long = System::currentTimeMillis,
    private val genDelayMs: Long = 1600,
) : MuseApi {
    private val lock = Mutex()
    private val events = MutableSharedFlow<ApiEvent>(extraBufferCapacity = 256)
    private val models = SampleData.models().toMutableList()
    private val outfits = SampleData.outfits().toMutableList()
    private val jobs = SampleData.jobs(now()).toMutableList()
    private val takes = SampleData.takes(now()).toMutableList()
    private val clips = mutableMapOf<String, Clip>()
    private var balance = SampleData.balance()
    private var failNext = false
    private val runners = mutableMapOf<String, CoJob>()
    private val loras = mutableMapOf<String, Lora>()
    private val accounts = mutableMapOf<String, MutableMap<String, Account>>()
    private val posts = mutableListOf<Post>()
    private val postTimers = mutableMapOf<String, CoJob>()
    private val tpl = FakeTemplates(now = now)
    private val promptLib = FakePromptLibrary(now)
    private val promptScripts = FakePromptScripts(promptLib, now)

    override fun events(): Flow<ApiEvent> = events

    // Workstream 2: camera sessions (the demo studio's seeded session, chat playback, tokens).
    override val camera: FakeCameraApi by lazy {
        FakeCameraApi(now, { models.toList().map { it.id to it.name } }, { events.tryEmit(it) }, stepDelayMs = if (speed == 0.0) 0 else 700)
    }
    override val claude: FakeClaudeApi by lazy { FakeClaudeApi(scope, now, { events.tryEmit(it) }, stepDelayMs = if (speed == 0.0) 0 else 700) }
    override fun setToken(token: String?) {}

    override suspend fun signIn(req: SignInRequest): AuthResponse {
        if (req.email.isBlank()) throw ApiException("bad_request", "Enter your email")
        return AuthResponse("fake-token", User("u1", "Jenne Studio", req.email, "owner"))
    }

    override suspend fun signOut() {}
    override suspend fun me() = User("u1", "Jenne Studio", "jenne@studio.com", "owner")

    override suspend fun signUp(req: SignUpRequest): AuthResponse {
        if (!req.attestAdultRightsOriginal || !req.attestLabelAi) throw ApiException("attestation_required", "Tick both boxes to continue")
        return AuthResponse("fake-token", User("u1", req.studioName.ifBlank { "My Studio" }, req.email, "owner"))
    }

    override suspend fun listModels() = lock.withLock { models.filter { !it.archived } }

    override suspend fun createModel(req: CreateModelRequest): Model = lock.withLock {
        val m = Model("m_" + uid(), req.name.ifBlank { "New model" }, req.age.coerceIn(18, 70), req.niche, slots = SampleData.SLOT_SAMPLE.keys.map { SheetSlot(it) })
        models += m
        m
    }

    override suspend fun setSlot(modelId: String, slot: String, req: SetSlotRequest): Model = lock.withLock {
        val m = model(modelId)
        val updated = m.copy(slots = m.slots.map { if (it.key == slot) SheetSlot(slot, req.image, req.source) else it })
        replaceModel(updated)
        updated
    }

    override suspend fun fillAngles(modelId: String): FillAnglesResponse {
        val (busy, cost) = lock.withLock {
            val m = model(modelId)
            val missing = m.slots.filter { it.image == null }
            val cost = PhotoPricing.sheetAngles(photoPrices, missing.size, m.slots.count { it.image != null })
            if (cost > balance.balance) throw ApiException("insufficient_balance", ErrorText.NOT_ENOUGH_STUDIO)
            charge(cost)
            val busy = m.copy(slots = m.slots.map { if (it.image == null) it.copy(busy = true) else it })
            replaceModel(busy)
            busy to cost
        }
        events.tryEmit(ApiEvent("balance", balance = balance))
        scope.launch {
            delay(genDelayMs)
            val done = lock.withLock {
                val m = model(modelId)
                val d = m.copy(slots = m.slots.map { if (it.busy) SheetSlot(it.key, ImageRef.asset(SampleData.SLOT_SAMPLE.getValue(it.key)), "generated") else it })
                replaceModel(d)
                d
            }
            events.emit(ApiEvent("model", model = done))
        }
        return FillAnglesResponse(busy, cost)
    }

    override suspend fun listOutfits() = lock.withLock { outfits.filter { o -> models.none { it.id == o.modelId && it.archived } } }

    override suspend fun createOutfit(req: CreateOutfitRequest): Outfit {
        val cost = if (req.mode == "own") 0.0 else PhotoPricing.outfitSet(photoPrices)
        val o = lock.withLock {
            if (cost > balance.balance) throw ApiException("insufficient_balance", ErrorText.NOT_ENOUGH_STUDIO)
            charge(cost)
            val m = model(req.modelId)
            val spec = OutfitSpec(req.name, req.description, if (req.mode == "describe") OutfitSource.DESCRIBED else if (req.mode == "photo") OutfitSource.PRODUCT_PHOTO else OutfitSource.REFERENCE_SET)
            val prompt = PromptEngine.outfitSet(identity(m, loras[m.id]), spec).first().text
            val o = Outfit("o_" + uid(), req.modelId, req.name.ifBlank { "New outfit" }, req.mode, req.description, listOf(null, null, null, null), "generating", prompt, cost = cost.takeIf { it > 0 })
            outfits += o
            o
        }
        if (cost > 0) events.tryEmit(ApiEvent("balance", balance = balance))
        scope.launch {
            delay(if (req.mode == "own") 300 else genDelayMs + 100)
            val ready = lock.withLock {
                val angles = if (req.mode == "own" && req.images.isNotEmpty()) (0 until 4).map { req.images.getOrNull(it) }
                else listOf("c_front", "c_tq", "c_face", "c_front").map(ImageRef::asset)
                val r = outfit(o.id).copy(angles = angles, state = "preview")
                replaceOutfit(r)
                r
            }
            events.emit(ApiEvent("outfit", outfit = ready))
        }
        return o
    }

    override suspend fun saveOutfit(outfitId: String): Outfit {
        val (o, m) = lock.withLock {
            val o = outfit(outfitId).copy(state = "ready")
            replaceOutfit(o)
            val m = model(o.modelId).let { it.copy(outfitIds = it.outfitIds + o.id) }
            replaceModel(m)
            o to m
        }
        events.tryEmit(ApiEvent("model", model = m))
        return o
    }

    override suspend fun uploadImage(name: String, bytes: ByteArray, mime: String, onProgress: (Float) -> Unit): ImageRef {
        val dir = storeDir ?: return ImageRef(url = "data:$mime;name=$name")
        dir.mkdirs()
        val ext = if (mime.contains("png")) "png" else "jpg"
        val f = File(dir, "img_${uid()}.$ext")
        f.writeBytes(bytes)
        return ImageRef(url = f.toURI().toString())
    }

    override suspend fun uploadClip(meta: ClipMeta, bytes: ByteArray?, mime: String, onProgress: (Float) -> Unit): Clip = lock.withLock {
        val id = when (meta) {
            SampleData.sampleMeta -> SampleData.SAMPLE_CLIP
            SampleData.badMeta -> SampleData.BAD_CLIP
            else -> "clip_" + uid()
        }
        // The server classifies the clip's audio on upload (prompt scripts); the demo takes it from the meta.
        val audio = ClipAudio(if (meta.talking) "speech" else "music", meta.talking, true)
        val c = Clip(id, meta.name, meta.durationSec, meta.width, meta.height, meta.fps, ClipRules.checks(meta), audio = audio)
        clips[id] = c
        c
    }

    override suspend fun listJobs() = lock.withLock { jobs.sortedByDescending { it.createdAt } }

    override suspend fun createJob(request: JobRequest): Job {
        // Render (Draft / Standard / HD): whole clip, priced per output second; lip sync and a background photo are Edit only.
        val replicate = request.engine == Engine.REPLICATE.id
        if (replicate && request.lipSync) throw ApiException("bad_request", "Lip sync is only on Edit")
        if (replicate && request.background == "photo") throw ApiException("bad_request", "A new background photo is only on Edit for now")
        val req = if (!replicate) request.copy(quality = null)
            else Quality.fromId(request.quality).let { q -> request.copy(use = ClipUse.FULL.id, quality = q.id, pricePerSec = studio.features.video?.pricePerSec(q) ?: q.pricePerSec) }
        val job = lock.withLock {
            // Clip checks are advice only (2026-11-05): a failing clip can still be rendered; the studio shows a disclaimer.
            val spec = req.spec()
            val cost = Pricing.totalCost(spec)
            if (spec.engine == Engine.H3 && (spec.steps < Pricing.STEPS_MIN || spec.steps > Pricing.STEPS_MAX)) throw ApiException("bad_request", "Steps must be 4–30")
            if (cost > balance.balance + 1e-9) throw ApiException("insufficient_balance", "Not enough balance · top up in Credits")
            if (cost > balance.perJobLimit) throw ApiException("over_job_limit", "Over your ${Pricing.money(balance.perJobLimit)} per-job limit")
            val m = model(req.modelId)
            val o = outfits.firstOrNull { it.id == req.outfitId }
            val seed = (1000..99999).random().toLong()
            if (req.queue) {
                val q = Job("j_" + uid(), req.title, m.id, m.name, req.outfitId, req, "queued", 0.0, 1, 0, JobClock.progress(req, 0.0).totalSteps, "Queued", Pricing.totalSeconds(spec),
                    Pricing.totalSeconds(spec), cost, createdAt = now(), seed = seed, thumb = o?.front ?: m.cover,
                    prompt = PromptEngine.videoSwap(VideoSwapSpec(identity(m, loras[m.id]), OutfitSpec(o?.name ?: "outfit"), SourcePerformer(), req.keepAudio, req.background == "keep", req.backgroundMotion, req.steps, seed)).text)
                jobs += q
                return@withLock q
            }
            val prompt = if (replicate) "Replace the person in the clip with ${m.name} in ${o?.name ?: "her outfit"} · keep the exact framing and crop · remove captions"
                else PromptEngine.videoSwap(
                VideoSwapSpec(identity(m, loras[m.id]), OutfitSpec(o?.name ?: "outfit"), SourcePerformer(), req.keepAudio, req.background == "keep", req.backgroundMotion, req.steps, seed),
            ).text
            charge(cost)
            val p = JobClock.progress(req, 0.0)
            val j = Job(
                "j_" + uid(), req.title, m.id, m.name, req.outfitId, req, "running", 0.0, 1, 0, p.totalSteps, p.phase, p.secondsLeft,
                Pricing.totalSeconds(spec), cost, createdAt = now(), prompt = prompt, seed = seed, thumb = o?.front ?: m.cover,
            )
            jobs += j
            j
        }
        if (job.state == "queued") { events.tryEmit(ApiEvent("job", job = job)); return job }
        events.tryEmit(ApiEvent("balance", balance = balance))
        events.tryEmit(ApiEvent("job", job = job))
        run(job)
        return job
    }

    override suspend fun runQueue(): List<Job> {
        val started = lock.withLock {
            val queued = jobs.filter { it.state == "queued" }.sortedBy { it.createdAt }
            val out = mutableListOf<Job>()
            for (q in queued) {
                if (q.cost > balance.balance + 1e-9) break
                charge(q.cost)
                val p = JobClock.progress(q.request, 0.0)
                val r = q.copy(state = "running", phase = p.phase, secondsLeft = p.secondsLeft)
                replaceJob(r)
                out += r
            }
            if (queued.isNotEmpty() && out.isEmpty()) throw ApiException("insufficient_balance", "Not enough balance · top up in Credits")
            out
        }
        if (started.isNotEmpty()) events.tryEmit(ApiEvent("balance", balance = balance))
        started.forEach { events.tryEmit(ApiEvent("job", job = it)); run(it) }
        return started
    }

    // ---------------------------------------------------------------- models: edit / delete

    override suspend fun updateModel(modelId: String, req: UpdateModelRequest): Model {
        if (req.name != null && req.name.isBlank()) throw ApiException("bad_request", "Give her a name")
        val m = lock.withLock {
            val m0 = model(modelId)
            val m = m0.copy(
                name = req.name ?: m0.name, niche = req.niche ?: m0.niche, personality = req.personality ?: m0.personality, notes = req.notes ?: m0.notes,
                neverAdd = req.neverAdd?.map { it.trim() }?.filter { it.isNotEmpty() } ?: m0.neverAdd,
            )
            replaceModel(m)
            m
        }
        events.tryEmit(ApiEvent("model", model = m))
        return m
    }

    override suspend fun deleteModel(modelId: String) {
        lock.withLock {
            model(modelId)
            models.removeAll { it.id == modelId }
            outfits.removeAll { it.modelId == modelId }
            loras.remove(modelId); runners.remove("lora_$modelId")?.cancel()
            accounts.remove(modelId)
            posts.filter { it.modelId == modelId && !it.out }.forEach { postTimers.remove(it.id)?.cancel() }
            posts.removeAll { it.modelId == modelId && !it.out }
        }
    }

    // ---------------------------------------------------------------- Identity LoRA

    override suspend fun lora(modelId: String): Lora = lock.withLock { loraOf(modelId) }

    override suspend fun buildLoraSet(modelId: String): Lora {
        val l = lock.withLock {
            val l0 = loraOf(modelId)
            if (l0.state == "building" || l0.state == "training") throw ApiException("busy", "Already working on it")
            val setCost = PhotoPricing.loraSet(photoPrices)
            if (setCost > balance.balance + 1e-9) throw ApiException("insufficient_balance", ErrorText.NOT_ENOUGH_STUDIO)
            charge(setCost)
            l0.copy(state = "building", candidates = emptyList(), progress = 0.0, cost = l0.cost + setCost).also { loras[modelId] = it }
        }
        events.tryEmit(ApiEvent("balance", balance = balance))
        scope.launch {
            delay(genDelayMs)
            val r = lock.withLock {
                val cur = loras[modelId] ?: return@launch
                if (cur.state != "building") return@launch
                cur.copy(state = "review", candidates = LoraSim.candidates()).also { loras[modelId] = it }
            }
            events.emit(ApiEvent("lora", lora = r))
        }
        return l
    }

    override suspend fun keepCandidate(modelId: String, candidateId: String, keep: Boolean): Lora = lock.withLock {
        val l = loraOf(modelId)
        if (l.candidates.none { it.id == candidateId }) throw ApiException("not_found", "Candidate not found")
        if (l.state == "training") throw ApiException("busy", "Training is running")
        l.copy(candidates = l.candidates.map { if (it.id == candidateId) it.copy(keep = keep) else it }).also { loras[modelId] = it }
    }

    override suspend fun trainLora(modelId: String): Lora {
        val cost = Pricing.loraTrainCost
        val l = lock.withLock {
            val l0 = loraOf(modelId)
            if (l0.state !in setOf("review", "ready") || l0.candidates.isEmpty()) throw ApiException("bad_request", "Build the training set first")
            if (l0.kept < Pricing.LORA_MIN_KEEP) throw ApiException("bad_request", "Keep at least ${Pricing.LORA_MIN_KEEP} shots so the LoRA learns her well")
            if (cost > balance.balance + 1e-9) throw ApiException("insufficient_balance", "Not enough balance · top up in Credits")
            charge(cost)
            val p = LoraSim.parts(0.0)
            l0.copy(state = "training", progress = 0.0, photo = p.first, video = p.second, cost = l0.cost + cost).also { loras[modelId] = it }
        }
        events.tryEmit(ApiEvent("balance", balance = balance))
        events.tryEmit(ApiEvent("lora", lora = l))
        if (speed > 0) runners["lora_$modelId"] = scope.launch {
            val t0 = now()
            val total = Pricing.loraTrainMinutes * 60.0
            while (true) {
                delay(250)
                val pr = ((now() - t0) / 1000.0 * speed * LoraSim.SPEEDUP / total * 100).coerceAtMost(100.0)
                val upd = lock.withLock {
                    val cur = loras[modelId]?.takeIf { it.state == "training" } ?: return@launch
                    val (ph, vi) = LoraSim.parts(pr)
                    val u = if (pr >= 100) cur.copy(state = "ready", progress = 100.0, photo = ph, video = vi, version = cur.version + 1, trainedOn = cur.kept)
                    else cur.copy(progress = pr, photo = ph, video = vi)
                    loras[modelId] = u
                    u
                }
                events.emit(ApiEvent("lora", lora = upd))
                if (upd.state == "ready") break
            }
        }
        return l
    }

    override suspend fun patchLora(modelId: String, req: PatchLoraRequest): Lora {
        val l = lock.withLock {
            var l = loraOf(modelId)
            if (req.use != null) l = l.copy(use = req.use)
            if (req.state == "review") {
                if (l.state != "ready") throw ApiException("bad_request", "Nothing to retrain yet")
                l = l.copy(state = "review")
            }
            loras[modelId] = l
            l
        }
        events.tryEmit(ApiEvent("lora", lora = l))
        return l
    }

    // ---------------------------------------------------------------- social accounts and posts

    override suspend fun listAccounts(modelId: String): List<Account> = lock.withLock {
        model(modelId)
        val a = accounts[modelId].orEmpty()
        Platform.entries.mapNotNull { a[it.id] }
    }

    override suspend fun connectAccount(modelId: String, platform: String): ConnectResponse {
        val p = Platform.of(platform) ?: throw ApiException("bad_request", "Unknown platform $platform")
        lock.withLock { model(modelId) }
        delay(minOf(genDelayMs, 900)) // "Signing in…"
        return lock.withLock {
            val m = model(modelId)
            val a = Account(modelId, p.id, LoraSim.handle(p, m.name), now())
            accounts.getOrPut(modelId) { mutableMapOf() }[p.id] = a
            ConnectResponse(account = a)
        }
    }

    override suspend fun disconnectAccount(modelId: String, platform: String) {
        lock.withLock { accounts[modelId]?.remove(platform) }
    }

    override suspend fun listPosts(state: String?): List<Post> = lock.withLock { posts.filter { state == null || it.state == state } }

    override suspend fun createPost(req: CreatePostRequest): Post {
        val post = lock.withLock {
            val m = model(req.modelId)
            val t = takes.firstOrNull { it.id == req.takeId } ?: throw ApiException("not_found", "Take not found")
            val platforms = req.platforms.distinct()
            if (platforms.isEmpty()) throw ApiException("bad_request", "Pick at least one account")
            platforms.forEach { if (Platform.of(it) == null) throw ApiException("bad_request", "Unknown platform $it") }
            platforms.firstOrNull { accounts[m.id]?.containsKey(it) != true }?.let { throw ApiException("bad_request", "Connect $it first") }
            val at = if (req.`when` == "now") now() else runCatching { java.time.Instant.parse(req.`when`).toEpochMilli() }.getOrNull()
                ?: throw ApiException("bad_request", "when must be \"now\" or an ISO time")
            val p = Post("p_" + uid(), m.id, t.id, t.title, t.thumb, platforms, req.caption, req.aiLabel, req.paidPartnership, req.`when`, "scheduled", now())
            posts.add(0, p)
            p to at
        }
        val (p, at) = post
        if (p.`when` == "now") return handoff(p)
        postTimers[p.id] = scope.launch {
            delay((at - now()).coerceAtLeast(0))
            val cur = lock.withLock { posts.firstOrNull { it.id == p.id && it.scheduled } } ?: return@launch
            handoff(cur)
        }
        return p
    }

    /** Stage 1: the app opens each platform; then the mock "reads back" stats. */
    private suspend fun handoff(p: Post): Post {
        val h = lock.withLock { p.copy(state = "handoff").also { replacePost(it) } }
        events.tryEmit(ApiEvent("post", post = h))
        postTimers[p.id] = scope.launch {
            delay(genDelayMs)
            val done = lock.withLock {
                if (posts.none { it.id == p.id }) return@launch
                val views = 1240L + (0..900).random()
                h.copy(state = "posted", postedAt = now(), stats = PostStats(views, views * 11 / 100, views * 8 / 1000)).also { replacePost(it) }
            }
            events.emit(ApiEvent("post", post = done))
        }
        return h
    }

    override suspend fun deletePost(postId: String) {
        lock.withLock { posts.removeAll { it.id == postId } }
        postTimers.remove(postId)?.cancel()
    }

    /** Test hooks: put the LoRA, an account or a post in a fixed state. */
    suspend fun debugPutLora(l: Lora) = lock.withLock { loras[l.modelId] = l }
    suspend fun debugPutAccount(a: Account) = lock.withLock { accounts.getOrPut(a.modelId) { mutableMapOf() }[a.platform] = a }
    suspend fun debugPutTake(t: Take) = lock.withLock { takes.removeAll { it.id == t.id }; takes.add(0, t) }
        suspend fun debugPutPost(p: Post) = lock.withLock { posts.removeAll { it.id == p.id }; posts.add(p) }

    private fun run(job: Job) {
        if (speed <= 0) return
        val failThis = failNext.also { failNext = false }
        runners[job.id] = scope.launch {
            val t0 = now()
            val failAt = if (failThis) JobClock.failAt(job.request) else Double.MAX_VALUE
            while (true) {
                delay(250)
                val elapsed = (now() - t0) / 1000.0 * speed
                val ev = lock.withLock {
                    val cur = jobs.firstOrNull { it.id == job.id } ?: return@launch
                    if (elapsed >= failAt) {
                        val p = JobClock.progress(cur.request, failAt)
                        val failed = cur.copy(state = "failed", progress = p.progress, step = p.step, phase = "Failed", refunded = cur.cost,
                            error = ErrorText.WENT_WRONG, finishedAt = now())
                        refund(cur.cost)
                        replaceJob(failed)
                        ApiEvent("job", job = failed)
                    } else if (elapsed >= cur.totalSeconds) {
                        val done = cur.copy(state = "done", progress = 100.0, step = cur.totalSteps, take = cur.request.takes, phase = "Done", secondsLeft = 0.0, finishedAt = now())
                        replaceJob(done)
                        if (cur.request.engine == SuiteRules.ENGINE) refund(cur.cost) // AI suite: demo renders are test renders, settled at $0
                        val newTakes = (1..cur.request.takes).map { i ->
                            val o = outfits.firstOrNull { it.id == cur.outfitId }
                            val thumb = o?.angles?.filterNotNull()?.let { if (it.isEmpty()) null else it[(i - 1) % it.size] } ?: cur.thumb ?: ImageRef.asset("g_front")
                            Take("t_${cur.id}_$i", "take", cur.id, i, cur.request.takes, cur.title,
                                when (cur.request.engine) { Engine.VIGGLE.id -> "Fast · beta"; Engine.REPLICATE.id -> Quality.fromId(cur.request.quality).label
                                    SuiteRules.ENGINE -> SuiteRules.tierLabel(cur.request.quality); else -> "Edit" }, cur.engineLabel,
                                cur.cost / cur.request.takes, cur.seed + i - 1, "test", thumb, cur.prompt, now(),
                                look = if (cur.request.engine == SuiteRules.ENGINE) suite.looks[cur.id] else null)
                        }
                        takes.addAll(0, newTakes)
                        ApiEvent("job", job = done, takes = newTakes)
                    } else {
                        val p = JobClock.progress(cur.request, elapsed)
                        val upd = cur.copy(progress = p.progress, take = p.take, step = p.step, phase = p.phase, secondsLeft = p.secondsLeft)
                        replaceJob(upd)
                        ApiEvent("job", job = upd)
                    }
                }
                events.emit(ev)
                if (ev.job?.state == "failed") events.emit(ApiEvent("balance", balance = balance))
                if (ev.job?.state != "running") break
            }
        }
    }

    override suspend fun removeJob(jobId: String) {
        lock.withLock { jobs.removeAll { it.id == jobId } }
        runners.remove(jobId)?.cancel()
    }

    override suspend fun listTakes() = lock.withLock { takes.map { tpl.shotView(it) } }

    override suspend fun setTakeStatus(takeId: String, status: String): Take = lock.withLock {
        val i = takes.indexOfFirst { it.id == takeId }
        if (i < 0) throw ApiException("not_found", "Take not found")
        takes[i] = takes[i].copy(status = status)
        takes[i]
    }

    override suspend fun deleteTake(takeId: String) {
        lock.withLock { takes.removeAll { it.id == takeId } }
    }

    override suspend fun shoot(req: ShootRequest): List<Take> {
        val cost = lock.withLock {
            ShootRef.problem(req.refs)?.let { throw ApiException("bad_request", it) }
            if (req.templateId != null) tpl.name(req.templateId) // not_found before charging
            val cost = previewNow(req).estimate
            if (cost > balance.balance) throw ApiException("insufficient_balance", ErrorText.NOT_ENOUGH_STUDIO)
            charge(cost)
            cost
        }
        events.tryEmit(ApiEvent("balance", balance = balance))
        delay(genDelayMs)
        return lock.withLock {
            val o = outfits.firstOrNull { it.id == req.outfitId }
            val pool = listOf(o?.front?.asset ?: "g_front", "c_face", "face", "g_tq")
            val t = now()
            val each = cost / req.count.coerceAtLeast(1)
            val refs = req.refs?.ifEmpty { null }
            val shots = if (req.templateId != null) {
                val name = tpl.name(req.templateId)
                val m = model(req.modelId)
                val shuffle = req.shuffleSeed ?: kotlin.random.Random.nextLong(1L shl 31)
                val refLines = templateRefLines(m, req)
                pool.take(req.count).mapIndexed { n, k ->
                    val b = tpl.prompt(req.templateId, identity(m, loras[m.id]), o?.name, req.direction, shuffle, req.lockSeed == true, n)
                    val id = "s_${uid()}"
                    tpl.recordShot(id, req.templateId, b.full.withRefLines(refLines), b.draws)
                    // Stored with the public prompt; shotView() swaps in the full one for the template's owner.
                    Take(id, "shot", null, n + 1, req.count, "Shoot · $name", "${name.take(28)} · ${n + 1}", "", each,
                        b.shown.seed ?: 0, "test", ImageRef.asset(k), b.visible.withRefLines(refLines), t + n, templateId = req.templateId, templateName = name, shuffleSeed = shuffle,
                        refs = refs)
                }.also { tpl.bumpUses(req.templateId) }
            } else {
                val label = (req.scene?.takeIf { it.isNotBlank() } ?: PromptEngine.DEFAULT_SCENE).substringBefore(" · ").take(28)
                val built = previewNow(req)
                pool.take(req.count).mapIndexed { n, k ->
                    Take("s_${uid()}", "shot", null, n + 1, req.count, "Shoot · $label", "$label · ${n + 1}", "", each,
                        req.seed ?: built.seed ?: 0, "test", ImageRef.asset(k), built.text, t, refs = refs)
                }
            }
            takes.addAll(0, shots)
            shots.map { tpl.shotView(it) }
        }
    }

    /** POST /v1/shoots/preview: the prompt a shoot sends (the demo library's wording), the images and the estimate. Free. */
    override suspend fun previewShoot(req: ShootRequest): ShootPreview = lock.withLock {
        ShootRef.problem(req.refs)?.let { throw ApiException("bad_request", it) }
        previewNow(req)
    }

    private fun previewNow(req: ShootRequest): ShootPreview {
        val m = model(req.modelId)
        val o = outfits.firstOrNull { it.id == req.outfitId }
        val id = identity(m, loras[m.id])
        if (req.templateId != null) {
            val p = tpl.prompt(req.templateId, id, o?.name, req.direction, req.shuffleSeed ?: 0, req.lockSeed == true).shown
            return promptLib.templatePreview(p.slots, p.seed, p.removed.orEmpty(), id.referenceCount, req, photoPrices)
        }
        return promptLib.shootPreview(id, o?.name, req, photoPrices)
    }

    /** A template shoot's reference lines (the prompt the shot keeps), as the preview places them. */
    private fun templateRefLines(m: Model, req: ShootRequest): List<String> =
        promptLib.templatePreview(emptyList(), null, emptyList(), identity(m, loras[m.id]).referenceCount, req, photoPrices).slots.map { it.text }

    private fun String.withRefLines(lines: List<String>): String {
        if (lines.isEmpty()) return this
        val rows = split("\n")
        val at = rows.indexOfFirst { it.startsWith("Style:") || it.startsWith("Never add:") || it.startsWith("Seed:") }.takeIf { it >= 0 } ?: rows.size
        return (rows.take(at) + lines + rows.drop(at)).joinToString("\n")
    }

    // ---- prompt library (owner): the server's entries with their defaults, edited in memory
    override suspend fun prompts() = lock.withLock { promptLib.list() }
    override suspend fun savePrompt(key: String, text: String) = lock.withLock { promptLib.save(key, text) }.also { events.tryEmit(ApiEvent("prompts", prompt = it)) }
    override suspend fun resetPrompt(key: String) = lock.withLock { promptLib.reset(key) }.also { events.tryEmit(ApiEvent("prompts", prompt = it)) }
    override suspend fun previewPrompt(req: PromptPreviewRequest) = lock.withLock { promptLib.preview(req) }
    // Prompt scripts (workstream 4)
    override suspend fun listPromptScripts() = lock.withLock { promptScripts.list() }
    override suspend fun getPromptScript(id: String) = lock.withLock { promptScripts.get(id) }
    override suspend fun savePromptScript(id: String, rules: List<Rule>) = lock.withLock { promptScripts.save(id, rules) }.also { events.tryEmit(ApiEvent("promptScript", script = it)) }
    override suspend fun resetPromptScript(id: String) = lock.withLock { promptScripts.reset(id) }.also { events.tryEmit(ApiEvent("promptScript", script = it)) }
    override suspend fun previewPromptScript(id: String, inputs: kotlinx.serialization.json.JsonObject?, rules: List<Rule>?, texts: Map<String, String>?, direction: String?) =
        lock.withLock { promptScripts.preview(id, inputs, rules, texts, direction) }

    // ---- photo templates (FakeTemplates holds the same owner-only rules as server/api)
    override suspend fun listTemplates(scope: String, q: String?, tag: String?) = lock.withLock { tpl.list(scope, q, tag) }
    override suspend fun template(id: String) = lock.withLock { tpl.detail(id, takes) }
    override suspend fun createTemplate(req: CreateTemplateRequest) = lock.withLock {
        val shot = req.fromShotId?.let { id -> takes.firstOrNull { it.id == id } ?: throw ApiException("not_found", "That shot isn't there any more") }
        tpl.create(req, shot)
    }
    override suspend fun templateDraft(fromShotId: String) = lock.withLock {
        tpl.draft(tpl.shotView(takes.firstOrNull { it.id == fromShotId } ?: throw ApiException("not_found", "That shot isn't there any more")))
    }
    override suspend fun patchTemplate(id: String, req: PatchTemplateRequest) = lock.withLock { tpl.patch(id, req) }
    override suspend fun deleteTemplate(id: String) = lock.withLock { tpl.delete(id) }
    override suspend fun duplicateTemplate(id: String) = lock.withLock { tpl.duplicate(id) }
    override suspend fun favouriteTemplate(id: String, on: Boolean) = lock.withLock { tpl.favourite(id, on) }
    override suspend fun templatePrompt(id: String, req: TemplatePromptRequest) = lock.withLock {
        val m = model(req.modelId)
        tpl.prompt(id, identity(m, loras[m.id]), req.outfitId?.let { oid -> outfits.firstOrNull { it.id == oid }?.name }, req.direction,
            req.shuffleSeed ?: kotlin.random.Random.nextLong(1L shl 31), req.lockSeed == true).shown
    }

    override suspend fun balance() = lock.withLock { balance }

    override suspend fun topUp(req: TopUpRequest): Balance {
        addTopUp(AddTopUpRequest(req.amount))
        return lock.withLock { balance }
    }

    // ---- the owner-loaded studio balance (demo): balance.balance is top-ups − spending.
    private val topUps = mutableListOf(TopUp("top_demo", 25.0, "Opening balance", now() - 86_400_000L, now() - 86_400_000L, "u1"))

    private fun studioBalanceView(): StudioBalance {
        val unspent = members.sumOf { it.usd }
        val topped = topUps.sumOf { it.amountUsd }
        return StudioBalance(balance.balance, topped, (topped - balance.balance).coerceAtLeast(0.0), unspent, 0.0, balance.balance - unspent, topUps.lastOrNull()?.createdAt ?: now(),
            topUps.isEmpty(), topUps.take(20))
    }

    override suspend fun studioBalance(): StudioBalance = lock.withLock { studioBalanceView() }

    override suspend fun addTopUp(req: AddTopUpRequest): StudioBalance {
        if (!(req.amountUsd > 0 && req.amountUsd <= 10_000)) throw ApiException("bad_request", "Amount must be between $0.01 and $10,000")
        val (sb, b) = lock.withLock {
            val amt = Math.round(req.amountUsd * 100) / 100.0
            topUps.add(0, TopUp("top_" + uid(), amt, req.note?.trim()?.ifBlank { null }, req.paidAt ?: now(), now(), "u1"))
            balance = balance.copy(balance = balance.balance + amt, needsFirstTopUp = false)
            studioBalanceView() to balance
        }
        events.tryEmit(ApiEvent("balance", balance = b))
        return sb
    }

    override suspend fun upscale(takeId: String, size: String): Job = throw ApiException("upscale_unavailable", "Upscale is coming soon")

    override suspend fun setFailNext(fail: Boolean) {
        failNext = fail
    }

    // ---- Edit suite (workstream 3): the Editor v2 AI helpers as instant mocks (like the server's mock provider)
    private val editorJobs = mutableMapOf<String, EditorJob>()
    private var editorSeq = 0

    private fun editorDuration(src: EditorSourceDto): Double =
        src.durationSec ?: takes.firstOrNull { it.id == src.takeId }?.durationSec ?: 8.0

    override suspend fun editorEstimate(req: EditorJobRequest): EditorEstimate {
        val d = editorDuration(req.source)
        val silenceOnly = (req.options?.get("silenceOnly") as? kotlinx.serialization.json.JsonPrimitive)?.content == "true"
        val usd = when (req.kind) {
            "beats" -> 0.0
            "cuts" -> if (silenceOnly || editorJobs.values.any { it.kind == "captions" && it.state == "done" }) 0.0 else 0.02
            "matte" -> maxOf(0.01, Math.round((10 + 4 * d) * 0.00025 * 100) / 100.0)
            "denoise" -> if ((req.options?.get("analyzeOnly") as? kotlinx.serialization.json.JsonPrimitive)?.content == "true") 0.0 else maxOf(0.01, Math.round((5 + 0.3 * d) * 0.00025 * 100) / 100.0)
            else -> 0.02
        }
        return EditorEstimate(req.kind, usd, usd * 100, usd == 0.0, req.kind == "cuts" && usd == 0.0 && !silenceOnly, d)
    }

    override suspend fun startEditorJob(req: EditorJobRequest): EditorJob = lock.withLock {
        if (failNext) { failNext = false; throw ApiException("failed", "Something went wrong · try again") }
        val d = editorDuration(req.source)
        val id = "ej_${++editorSeq}"
        val result = FakeEditorResults.result(req.kind, d, id, req.options)
        val est = editorEstimate(req)
        val job = EditorJob(id, req.kind, "done", 100, "Done", est.usd, est.usd, result, createdAt = now())
        editorJobs[id] = job
        job.copy(state = "running", progress = 10, phase = "Listening", result = null)
    }

    override suspend fun editorJob(id: String): EditorJob = lock.withLock { editorJobs[id] ?: throw ApiException("not_found", "Job not found") }

    override suspend fun cancelEditorJob(id: String) { lock.withLock { editorJobs[id]?.let { editorJobs[id] = it.copy(state = "cancelled", result = null) } } }

    override suspend fun saveProjectVersion(takeId: String, video: EditedVideo, project: kotlinx.serialization.json.JsonObject, name: String?, onProgress: (Float) -> Unit): Take = lock.withLock {
        val src = takes.firstOrNull { it.id == takeId } ?: throw ApiException("not_found", "Take not found")
        onProgress(1f)
        val dto = EditListDto(2, takeId, 0.0, emptyList(), false).also { it.project = project }
        val t = src.copy(
            id = "t_edit_${now()}", kind = "edit", parentTakeId = takeId, label = "Edited", edits = dto, createdAt = now(), cost = 0.0,
            videoUrl = "file://" + video.file.absolutePath, durationSec = video.durationSec, width = video.width, height = video.height, fps = video.fps,
            name = versionName(name), // Edit sessions (workstream 3)
        )
        takes.add(0, t)
        events.tryEmit(ApiEvent("take", takes = listOf(t)))
        t
    }

    override suspend fun uploadEditorFile(file: java.io.File, contentType: String, purpose: String?, onProgress: (Float) -> Unit): String { onProgress(1f); return "up_${purpose ?: "audio"}_${++editorSeq}" }

    // ---- Edit sessions (workstream 3): in memory, with the server's revision checks (plans/api.md "Edit sessions").
    // The demo studio is its owner. `claude*` stand in for Claude's MCP calls (demo and tests).
    private class FakeEditSession(
        val id: String, val takeId: String, var project: kotlinx.serialization.json.JsonObject, var revision: Int = 0,
        val history: MutableList<Triple<EditHistoryEntry, List<EdPatchOp>, List<EdPatchOp>>> = mutableListOf(),
        val pending: MutableList<EditPending> = mutableListOf(), val requests: MutableList<EditAppRequest> = mutableListOf(),
        val online: MutableMap<String, EditPresence> = mutableMapOf(),
    )
    private val editSessions = mutableMapOf<String, FakeEditSession>()
    private var editSessionSeq = 0
    private var editEntrySeq = 0L
    /** What the app answered (tests read these). */
    val editFrameAnswers = mutableMapOf<String, String>()
    val editRequestAnswers = mutableMapOf<String, EditRequestAnswer>()
    val editUploads = mutableMapOf<String, ByteArray>()
    /** Every patch an app pushed, in order (label, patch). */
    val editPushes = mutableListOf<Pair<String, List<EdPatchOp>>>()

    private fun editView(s: FakeEditSession) = EditSessionDto(
        s.id, s.takeId, null, s.revision, s.project, durationSec = runCatching { edDurationSec(EdEditJson.parse(s.project)) }.getOrDefault(0.0),
        pending = s.pending.filter { it.status == "waiting" || it.status == "running" }, online = s.online.values.toList(), requests = s.requests.takeLast(10),
        history = s.history.asReversed().take(60).map { it.first },
    )

    private fun editRow(id: String) = editSessions[id] ?: throw ApiException("not_found", "Edit session not found")

    private fun editCheck(p: kotlinx.serialization.json.JsonElement, takeId: String): kotlinx.serialization.json.JsonObject {
        val project = try { EdEditJson.parse(p) } catch (e: Exception) { throw ApiException("bad_request", "project: ${e.message}") }
        edProblemOf(project)?.let { throw ApiException("bad_request", "project.${it.field}: ${it.reason}") }
        if (project.sourceTakeId != takeId) throw ApiException("bad_request", "project.sourceTakeId: must be the session's take")
        return p as kotlinx.serialization.json.JsonObject
    }

    /** Stores [next] as one change with its patch and inverse, and tells the apps (like the server's commit). */
    private fun editCommit(s: FakeEditSession, next: kotlinx.serialization.json.JsonObject, author: String, kind: String, label: String, undoes: Long? = null): EditHistoryEntry? {
        val patch = EdJsonPatch.diff(s.project, next)
        val inverse = EdJsonPatch.diff(next, s.project)
        if (patch.isEmpty()) return null
        val base = s.revision
        s.project = next; s.revision++
        val entry = EditHistoryEntry(++editEntrySeq, s.revision, author, author == "claude", kind, label.take(200), undoes, false, now())
        s.history += Triple(entry, patch, inverse)
        if (undoes != null) s.history.replaceAll { if (it.first.id == undoes) it.copy(first = it.first.copy(undone = true)) else it }
        events.tryEmit(ApiEvent("edit", sessionId = s.id, op = "patch", revision = s.revision, baseRevision = base, patch = EdJsonPatch.encode(patch), entry = entry))
        return entry
    }

    private fun editStale(s: FakeEditSession, base: Int) = ApiException("stale_revision", "The edit moved on (revision ${s.revision}, you sent $base) · get it again and re-apply")

    override suspend fun openEditSession(req: OpenEditSessionRequest): EditSessionDto = lock.withLock {
        val t = takes.firstOrNull { it.id == req.takeId } ?: throw ApiException("not_found", "Take not found")
        if (req.fresh != true) editSessions.values.lastOrNull { it.takeId == t.id }?.let { return@withLock editView(it) }
        val project = req.project?.let { editCheck(it, t.id) } ?: (t.edits?.project?.takeIf { (it["sourceTakeId"] as? kotlinx.serialization.json.JsonPrimitive)?.content == t.id })
            ?: EdEditJson.encode(EdEditProject(
                2, t.id, EdCanvas(t.width ?: 1080, t.height ?: 1920, (t.fps ?: 30.0), "#000000"),
                listOf(EdAsset("src", EdAssetKind.VIDEO, take = t.id, durationSec = t.durationSec ?: 8.0, width = t.width ?: 1080, height = t.height ?: 1920, hasAudio = true)),
                listOf(EdTrack("main", EdTrackKind.MAIN, items = listOf(EdVideoClip("c1", "src", 0.0, t.durationSec ?: 8.0, 1.0,
                    look = t.look?.lut?.takeIf { it.isNotBlank() }?.let { EdLook(lut = it, strength = 1.0) })))),
            ))
        val s = FakeEditSession("es_${++editSessionSeq}", t.id, project)
        editSessions[s.id] = s
        editView(s)
    }

    override suspend fun editSession(id: String): EditSessionDto = lock.withLock { editView(editRow(id)) }

    override suspend fun pushEditPatch(id: String, req: EditPatchRequest): EditChangeResult = lock.withLock {
        val s = editRow(id)
        if (req.baseRevision != s.revision) throw editStale(s, req.baseRevision)
        val ops = try { EdPatchOp.listOf(req.patch) } catch (e: EdPatchException) { throw ApiException("bad_request", "patch: ${e.message}") }
        val next = try { EdJsonPatch.apply(s.project, ops) } catch (e: EdPatchException) { throw ApiException("bad_request", "patch: ${e.message}") }
        editCheck(next, s.takeId)
        editPushes += req.label to ops
        val entry = editCommit(s, next as kotlinx.serialization.json.JsonObject, "app:${req.device}", "edit", req.label.ifBlank { "Edit" })
        EditChangeResult(s.revision, entry)
    }

    override suspend fun undoEditEntry(id: String, req: EditUndoRequest): EditChangeResult = lock.withLock {
        val s = editRow(id)
        val e = s.history.firstOrNull { it.first.id == req.entryId } ?: throw ApiException("not_found", "Change not found")
        if (e.first.undone) throw ApiException("already_undone", "That change was already undone")
        val next = try { editCheck(EdJsonPatch.apply(s.project, e.third), s.takeId) }
            catch (_: Exception) { throw ApiException("cannot_undo", "Later changes touch the same parts · undo those first") }
        val entry = editCommit(s, next, "app:${req.device}", "undo", "Undo: ${e.first.label}", undoes = e.first.id)
        EditChangeResult(s.revision, entry)
    }

    override suspend fun editPresence(id: String, presence: EditPresence) { lock.withLock { editRow(id).online[presence.device] = presence } }
    override suspend fun leaveEditSession(id: String, device: String) { lock.withLock { editSessions[id]?.online?.remove(device) } }

    override suspend fun uploadEditFrame(png: ByteArray): String = lock.withLock { "up_frame_${++editorSeq}".also { editUploads[it] = png } }

    override suspend fun answerEditFrame(id: String, requestId: String, uploadId: String) {
        lock.withLock { editRow(id); if (uploadId !in editUploads) throw ApiException("bad_request", "uploadId: an image upload of the studio"); editFrameAnswers[requestId] = uploadId }
    }

    override suspend fun answerEditRequest(id: String, requestId: String, answer: EditRequestAnswer) {
        lock.withLock {
            val s = editRow(id)
            val i = s.requests.indexOfFirst { it.id == requestId }.takeIf { it >= 0 } ?: throw ApiException("not_found", "Request not found")
            s.requests[i] = s.requests[i].copy(status = if (answer.status == "failed") "failed" else "done", versionId = answer.versionId, error = answer.error)
            editRequestAnswers[requestId] = answer
            events.tryEmit(ApiEvent("edit", sessionId = id, op = "app_request", request = s.requests[i]))
        }
    }

    override suspend fun answerEditPending(id: String, pendingId: String, approve: Boolean): EditPending = lock.withLock {
        val s = editRow(id)
        val i = s.pending.indexOfFirst { it.id == pendingId && it.status == "waiting" }.takeIf { it >= 0 } ?: throw ApiException("not_found", "Waiting request not found")
        s.pending[i] = s.pending[i].copy(status = if (approve) "running" else "declined", jobId = if (approve) "ej_${++editorSeq}" else null)
        events.tryEmit(ApiEvent("edit", sessionId = id, op = "pending", pending = s.pending[i]))
        s.pending[i]
    }

    /** Claude's change (MCP apply_edit_ops): [change] on the current project, committed as Claude's, badged. Null when stale or no change. */
    suspend fun claudeEdit(sessionId: String, label: String, baseRevision: Int? = null, change: (EdEditProject) -> EdEditProject?): EditHistoryEntry? = lock.withLock {
        val s = editRow(sessionId)
        if (baseRevision != null && baseRevision != s.revision) throw editStale(s, baseRevision)
        val next = change(EdEditJson.parse(s.project)) ?: return@withLock null
        editCommit(s, editCheck(EdEditJson.encode(next), s.takeId), "claude", "edit", label)
    }

    /** Claude's get_frame when this app is online: a frame_request event; the answer lands in [editFrameAnswers]. */
    fun claudeFrame(sessionId: String, t: Double, width: Int = 540, device: String = ""): String {
        val rid = "fr_${++editorSeq}"
        events.tryEmit(ApiEvent("edit", sessionId = sessionId, op = "frame_request", requestId = rid, t = t, width = width, revision = editSessions[sessionId]?.revision, device = device))
        return rid
    }

    /** Claude's save_version / export_video: an app_request (the owner's AI-label and C2PA switches never travel). */
    suspend fun claudeAppRequest(sessionId: String, kind: String, name: String? = null, preset: kotlinx.serialization.json.JsonObject? = null, device: String = ""): EditAppRequest = lock.withLock {
        val s = editRow(sessionId)
        val clean = preset?.let { kotlinx.serialization.json.JsonObject(it.filterKeys { k -> k != "aiLabel" && k != "c2pa" }) }
        val r = EditAppRequest("ar_${++editorSeq}", kind, name, clean, device, "sent", at = now())
        s.requests += r
        events.tryEmit(ApiEvent("edit", sessionId = sessionId, op = "app_request", request = r))
        r
    }

    /** A paid helper Claude asked for with confirm: true; waits for the owner's answer in the app. */
    suspend fun claudeAsk(sessionId: String, kind: String, label: String, estimateUsd: Double): EditPending = lock.withLock {
        val s = editRow(sessionId)
        val p = EditPending("pa_${++editorSeq}", kind, label, estimateUsd, "waiting", createdAt = now())
        s.pending += p
        events.tryEmit(ApiEvent("edit", sessionId = sessionId, op = "pending", pending = p))
        p
    }

    /** The session's current project (tests). */
    suspend fun editProjectOf(sessionId: String): kotlinx.serialization.json.JsonObject = lock.withLock { editRow(sessionId).project }


    // ---- the demo studio's owner side: members, tokens, invites, settings (in memory, like the real API's rules)
    private val members = SampleData.members(now()).toMutableList()
    private val invites = mutableListOf<InviteInfo>()
    private var studio = StudioSettings(features = StudioFeatures(replicate = true, video = VideoFeatures.DEFAULT, photo = PhotoFeatures(), tools = FakeCatalog.ownerTools()),
        engines = Engines(listOf(EngineStatus("replicate", "Replicate", "Draft, Standard and HD video · photos", keySet = false, status = "simulated"),
            EngineStatus("runpod", "RunPod", "Edit, Fast · beta, Upscale", keySet = false, status = "simulated"))))
    private val photoPrices get() = (studio.features.photo ?: PhotoFeatures()).prices
    private var engine = ImageEngine("simulated", "bundled-stills", "Simulated", available = mapOf("simulated" to true, "fal" to false, "custom-http" to true, "replicate" to false))
    private val tokenUsd = 0.01

    private fun ownerWallet(): Wallet {
        val unspent = members.sumOf { it.usd }
        val available = balance.balance - unspent
        return Wallet("u1", "owner", kotlin.math.floor(available.coerceAtLeast(0.0) / tokenUsd + 1e-6).toLong(), available, 0, 0.0, balance.today, balance.month, tokenUsd, "studio",
            availableToSend = available, studioBalance = balance.balance, membersUnspentUsd = unspent)
    }

    /** Test hook: act as a member with this wallet (screenshots of the member's Credit screen). */
    @Volatile var debugWallet: Wallet? = null

    override suspend fun wallet(): Wallet = lock.withLock { debugWallet ?: ownerWallet() }
    override suspend fun listMembers(): List<Member> = lock.withLock { listOf(Member("u1", "jenne@studio.com", "owner", ownerWallet().tokens, ownerWallet().usd, lastActiveAt = now())) + members }

    private fun member(id: String) = members.firstOrNull { it.id == id }
        ?: if (id == "u1") throw ApiException("bad_request", "The owner's wallet is the studio balance; send credit to members only") else throw ApiException("not_found", "Member not found")

    override suspend fun transfer(req: TransferRequest): WalletMemberResponse = lock.withLock {
        val m = member(req.toUserId)
        val w = ownerWallet()
        if (req.tokens <= 0) throw ApiException("bad_request", "Send at least $0.01")
        if (req.tokens > w.tokens) throw ApiException("over_allocation", "You can send at most ${w.tokens} tokens (${Pricing.money(w.usd.coerceAtLeast(0.0))}): the rest of the studio balance is already with members or on hold")
        val n = m.copy(tokens = m.tokens + req.tokens, usd = (m.tokens + req.tokens) * tokenUsd)
        members[members.indexOf(m)] = n
        WalletMemberResponse(ownerWallet(), n)
    }

    override suspend fun reclaim(req: ReclaimRequest): WalletMemberResponse = lock.withLock {
        val m = member(req.fromUserId)
        if (req.tokens > m.tokens) throw ApiException("bad_request", "They have ${m.tokens} unused tokens")
        val n = m.copy(tokens = m.tokens - req.tokens, usd = (m.tokens - req.tokens) * tokenUsd)
        members[members.indexOf(m)] = n
        WalletMemberResponse(ownerWallet(), n)
    }

    override suspend fun patchMember(memberId: String, patch: MemberPatch): Member = lock.withLock {
        val m = member(memberId)
        val n = m.copy(capPerDay = if (patch.clearCapPerDay) null else patch.capPerDay ?: m.capPerDay, disabled = patch.disabled ?: m.disabled)
        members[members.indexOf(m)] = n
        n
    }

    override suspend fun createInvite(req: CreateInviteRequest): InviteCreated = lock.withLock {
        val abc = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        val r = java.util.Random(now() + invites.size)
        val code = "MUSE-" + (0 until 3).joinToString("-") { (0 until 4).map { abc[r.nextInt(abc.length)] }.joinToString("") }
        val inv = InviteInfo("inv_" + uid(), req.email, req.role ?: "member", now(), now() + 14 * 86_400_000L)
        invites.add(0, inv)
        InviteCreated(code, inv.id, inv.email, inv.role, inv.expiresAt)
    }

    override suspend fun listInvites(): List<InviteInfo> = lock.withLock { invites.toList() }
    override suspend fun studioSettings(): StudioSettings = lock.withLock { studio }
    override suspend fun patchStudioSettings(req: StudioSettingsPatch): StudioSettings = lock.withLock {
        studio = studio.copy(maxGpus = req.maxGpus ?: studio.maxGpus, overheadPayer = req.overheadPayer ?: studio.overheadPayer, capPerJob = req.capPerJob ?: studio.capPerJob,
            capPerDay = req.capPerDay ?: studio.capPerDay, capPerUserDay = req.capPerUserDay ?: studio.capPerUserDay)
        studio
    }

    // ---- Keep add-on engine ready (demo, the owner): ready in a few seconds, then bills $3.99/h from the studio balance once a minute.
    private var warm = WarmGpu()
    private var warmRunner: CoJob? = null
    override suspend fun warmGpu(): WarmGpu = lock.withLock { warmView() }
    private fun warmView(t: Long = now()): WarmGpu {
        val w = warm
        if (!w.on) return w.copy(idleMinutes = studio.warmIdleMinutes, maxMinutes = studio.warmMaxMinutes)
        val start = w.startedAt ?: t
        val idleAt = if (w.state == "warm") (w.readyAt ?: t) + w.idleMinutes * 60_000L else null
        val capAt = start + w.maxMinutes * 60_000L
        val (at, why) = if (idleAt != null && idleAt < capAt) idleAt to "idle" else capAt to "cap"
        return w.copy(minutes = ((t - start) / 60_000).toInt(), autoOffAt = at, autoOffReason = why, warningAt = at - 5 * 60_000L)
    }
    override suspend fun setWarmGpu(req: WarmRequest): WarmGpu = lock.withLock {
        when {
            req.extend == true -> {
                if (!warm.on) throw ApiException("not_warm", "The add-on engine is off")
                val v = warmView()
                warm = if (v.autoOffReason == "cap" && warm.canExtend) warm.copy(maxMinutes = warm.maxMinutes * 2, canExtend = false) else warm.copy(readyAt = now().takeIf { warm.state == "warm" } ?: warm.readyAt)
            }
            req.on == true -> if (!warm.on) {
                if (balance.balance < 3.99 * 10 / 60) throw ApiException("insufficient_balance", ErrorText.NOT_ENOUGH_STUDIO)
                warm = WarmGpu("starting", startedAt = now(), idleMinutes = studio.warmIdleMinutes, maxMinutes = studio.warmMaxMinutes, canExtend = true)
                warmRunner?.cancel()
                if (speed > 0) warmRunner = scope.launch {
                    delay(4000)
                    lock.withLock { if (warm.state == "starting") warm = warm.copy(state = "warm", readyAt = now()) }
                    emitWarm("state")
                    var billed = 0
                    while (true) {
                        delay(15_000)
                        val v = lock.withLock { warmView() }
                        if (!v.on) break
                        if (v.minutes > billed) {
                            lock.withLock {
                                val usd = (v.minutes - billed) * 3.99 / 60
                                billed = v.minutes
                                warm = warm.copy(costUsd = warm.costUsd + usd)
                                balance = balance.copy(balance = (balance.balance - usd).coerceAtLeast(0.0))
                            }
                            events.emit(ApiEvent("balance", balance = balance))
                            emitWarm("tick")
                        }
                        val at = v.autoOffAt ?: continue
                        if (now() >= at) { lock.withLock { warm = WarmGpu(lastOff = WarmLastOff(v.autoOffReason ?: "idle", now(), v.minutes, warm.costUsd)) }; emitWarm("state"); break }
                    }
                }
            }
            req.on == false -> if (warm.on) {
                warmRunner?.cancel()
                val v = warmView()
                warm = WarmGpu(lastOff = WarmLastOff("user", now(), v.minutes, warm.costUsd))
            }
        }
        warmView().also { events.tryEmit(ApiEvent("gpu", gpu = it, event = "state")) }
    }
    private suspend fun emitWarm(event: String) { events.emit(ApiEvent("gpu", gpu = lock.withLock { warmView() }, event = event)) }
    /** Test hook: a fixed warm GPU state (no runner). */
    suspend fun debugSetWarm(w: WarmGpu) = lock.withLock { warmRunner?.cancel(); warm = w }
    override suspend fun imageEngine(): ImageEngine = lock.withLock { engine }
    override suspend fun setImageEngine(req: ImageEnginePatch): ImageEngine = lock.withLock {
        if (engine.available[req.provider] != true) throw ApiException("bad_request", "${req.provider} is not set up on the server")
        if (req.provider == "custom-http" && req.url?.startsWith("https://") != true) throw ApiException("bad_request", "Use an https:// URL")
        engine = engine.copy(provider = req.provider, model = req.model ?: if (req.provider == "simulated") "bundled-stills" else engine.model, url = req.url)
        engine
    }

    // ---- AI suite (workstream 1): demo answers from FakeSuite; shots run on the job pipeline above.
    val suite by lazy { FakeSuite() }
    /** Demo mode is the owner; tests flip this to see a member's answers. */
    var suiteOwner = true
    /** false shows the suite-off state (SUITE_MODE=off on a server). */
    var suiteEnabled = true
    private fun suiteOn() { if (!suiteEnabled) throw ApiException("engine_unavailable", "The AI suite isn't switched on yet") }
    private fun suiteClipSeconds(id: String?) = clips[id]?.durationSec ?: if (id == SampleData.SAMPLE_CLIP) SampleData.sampleMeta.durationSec else null
    override suspend fun suiteCatalog() = suite.catalog(suiteOwner).let { if (suiteEnabled) it else it.copy(enabled = false, test = false, tiers = it.tiers.map { t -> t.copy(available = false) }) }
    override suspend fun suiteEstimate(req: SuiteShotRequest) = lock.withLock { suiteOn(); suite.estimate(req, suiteOwner, models, suiteClipSeconds(req.clipId)) }
    override suspend fun createSuiteShot(req: SuiteShotRequest): Job {
        val job = lock.withLock {
            suiteOn()
            val e = suite.estimate(req, suiteOwner, models, suiteClipSeconds(req.clipId))
            if (e.estimate > balance.balance + 1e-9) throw ApiException("insufficient_balance", "Not enough balance · top up in Credits")
            val lead = req.modelId ?: req.cast?.firstOrNull()?.characterId
            val m = lead?.let { id -> models.firstOrNull { it.id == id } }
            val o = (req.outfitId ?: req.cast?.firstOrNull()?.outfitId)?.let { id -> outfits.firstOrNull { it.id == id } }
            val j = suite.job("j_" + uid(), req, e, m, o, now())
            e.look?.let { suite.looks[j.id] = it } // AI suite (workstream 1): the takes carry the shot's Look
            charge(j.cost)
            jobs += j
            j
        }
        events.tryEmit(ApiEvent("balance", balance = balance))
        events.tryEmit(ApiEvent("job", job = job))
        run(job)
        return job
    }
    override suspend fun suiteShot(id: String) = lock.withLock {
        val j = jobs.firstOrNull { it.id == id && it.request.engine == SuiteRules.ENGINE } ?: throw ApiException("not_found", "Shot not found")
        SuiteShot(j, emptyList(), if (suiteOwner) suite.estimate(SuiteShotRequest(prompt = j.prompt.ifBlank { "shot" }, quality = j.request.quality), true, models, null).engine else null)
    }
    override suspend fun suiteCompile(req: SuiteCompileRequest): SuiteCompiled {
        fun id(k: String) = ((req.camera as? kotlinx.serialization.json.JsonObject)?.get(k) as? kotlinx.serialization.json.JsonObject)?.get("id")?.let { (it as? kotlinx.serialization.json.JsonPrimitive)?.content }
        return SuiteCompiled("Camera: ${id("move") ?: "static"}", listOfNotNull(id("move"), id("mix")))
    }
    override suspend fun suiteSettings() = lock.withLock {
        if (!suiteOwner) throw ApiException("owner_only", "Only the studio owner can do that")
        suite.settings()
    }
    override suspend fun patchSuiteSettings(req: SuiteSettingsPatch) = lock.withLock {
        if (!suiteOwner) throw ApiException("owner_only", "Only the studio owner can do that")
        suite.patch(req)
    }
    override suspend fun uploadSuiteMedia(name: String, bytes: ByteArray, mime: String, onProgress: (Float) -> Unit): SuiteMediaRef {
        onProgress(1f)
        val ext = name.substringAfterLast('.', if (mime.startsWith("audio/")) "m4a" else "mp4")
        return SuiteMediaRef(key = "c/demo_${uid()}.$ext")
    }

    /** Test hook: put a job in a fixed state (no runner). */
    suspend fun debugPut(job: Job) = lock.withLock {
        jobs.removeAll { it.id == job.id }
        jobs += job
    }

    // ---- Model tools (demo): the default models and a small catalog, Enhance and Dress up that return the sheet's own
    // stills (no engine), charged at the estimate from the studio balance.
    private val stepModels = mutableMapOf<String, String>()
    private val toolRuns = mutableListOf<ToolRun>()
    private val sheetVersions = mutableMapOf<String, MutableList<SheetVersion>>()

    override suspend fun imageModels(): StepModels = lock.withLock { StepModels(Sheet.STEPS.map { stepView(it) }) }
    private fun stepView(step: String): StepModel {
        val def = FakeCatalog.DEFAULTS.getValue(step)
        val id = stepModels[step] ?: def
        val m = FakeCatalog.model(id)
        return StepModel(step, FakeCatalog.STEP_LABELS.getValue(step), id, def, id == def, m?.name ?: id, m?.official ?: true, m?.description ?: "", m?.price,
            m?.priceLine ?: "price unknown")
    }
    override suspend fun imageCatalog(step: String, q: String?, collection: String?): CatalogPage {
        val list = FakeCatalog.forStep(step).filter { q.isNullOrBlank() || it.id.contains(q, true) || it.description.contains(q, true) }
        return CatalogPage(step, FakeCatalog.STEP_LABELS[step] ?: step, FakeCatalog.collections(step), list, now())
    }
    override suspend fun imageModel(id: String, step: String): ModelDetail {
        val m = FakeCatalog.forStep(step).firstOrNull { it.id == id } ?: throw ApiException("not_found", "Replicate has no model $id")
        return ModelDetail(m.id, m.name, m.owner, m.description, m.runCount, m.official, m.priceLine, m.compatible, m.reasons, m.warnings)
    }
    override suspend fun setImageModel(step: String, req: SetStepModelRequest): StepModel = lock.withLock {
        val m = FakeCatalog.forStep(step).firstOrNull { it.id == req.model } ?: throw ApiException("not_found", "Replicate has no model ${req.model}")
        if (m.compatible == false) throw ApiException("model_incompatible", "This model can't do ${FakeCatalog.STEP_LABELS[step]}: ${m.reasons.joinToString()}")
        stepModels[step] = req.model
        stepView(step)
    }
    override suspend fun resetImageModel(step: String): StepModel = lock.withLock { stepModels.remove(step); stepView(step) }

    private fun modelFor(step: String, over: Map<String, String>?) = over?.get(step) ?: stepModels[step] ?: FakeCatalog.DEFAULTS.getValue(step)
    private fun filledSlots(m: Model, only: List<String>? = null) = Sheet.SLOTS.mapNotNull { si ->
        m.slot(si.key)?.image?.takeIf { only == null || si.key in only }?.let { si to it }
    }
    private fun enhancePer(req: EnhanceRequest): Double {
        var v = 0.0
        if (req.realism != "off") v += FakeCatalog.estimate(modelFor("realism", req.models), 1.0, 0.79)
        if (req.upscale != "off") v += FakeCatalog.estimate(modelFor("upscale", req.models), 4.0, 0.79, if (req.upscale == "4x") 4.0 else 2.0)
        return v
    }
    private fun dressEngines(e: String) = when (e) { "both" -> listOf("a", "b"); "b" -> listOf("b"); else -> listOf("a") }
    private fun dressTotal(n: Int, engines: List<String>, over: Map<String, String>?) = engines.sumOf { e ->
        val model = modelFor(if (e == "a") "dressA" else "dressB", over)
        (0 until n).sumOf { i -> FakeCatalog.estimate(model, 1.0, 0.79 * if (i == 0) 2 else 3) }
    }
    private fun estimateLabel(n: Int, est: Double, options: Int = 1) = "$n image${if (n == 1) "" else "s"}${if (options > 1) " · $options options" else ""} · ${PhotoPricing.about(est)}"

    override suspend fun enhanceEstimate(modelId: String, req: EnhanceRequest): ToolEstimate = lock.withLock {
        val n = filledSlots(model(modelId), req.slots).size
        val per = enhancePer(req)
        ToolEstimate(n, per * n, estimateLabel(n, per * n), per)
    }
    override suspend fun dressUpEstimate(modelId: String, req: DressUpRequest): ToolEstimate = lock.withLock {
        val n = filledSlots(model(modelId)).size
        val engines = dressEngines(req.engine)
        val est = dressTotal(n, engines, req.models)
        ToolEstimate(n, est, estimateLabel(n, est, engines.size))
    }
    private fun archivedCheck(m: Model) { if (m.archived) throw ApiException("model_archived", "This model is archived · restore her in Settings → Archived models") }

    override suspend fun startEnhance(modelId: String, req: EnhanceRequest): ToolRun {
        if (req.realism == "off" && req.upscale == "off") throw ApiException("bad_request", "Turn on realism or upscale")
        val run = lock.withLock {
            val m = model(modelId); archivedCheck(m)
            val slots = filledSlots(m, req.slots)
            if (slots.isEmpty()) throw ApiException("bad_request", "Add photos to the character sheet first")
            val est = enhancePer(req) * slots.size
            if (est > balance.balance) throw ApiException("insufficient_balance", ErrorText.NOT_ENOUGH_STUDIO)
            charge(est)
            val models = buildMap { if (req.realism != "off") put("realism", modelFor("realism", req.models)); if (req.upscale != "off") put("upscale", modelFor("upscale", req.models)) }
            ToolRun("tool_" + uid(), "enhance", modelId, "running", ToolOptions(realism = req.realism, upscale = req.upscale), listOf("a"),
                slots.map { (si, img) -> ToolItem(si.key, si.label, img) }, est, 0.0, 0.0, "Enhancing · 1 of ${slots.size}", createdAt = now(), models = models).also { toolRuns.add(0, it) }
        }
        events.tryEmit(ApiEvent("balance", balance = balance))
        simulate(run.id)
        return run
    }
    override suspend fun startDressUp(modelId: String, req: DressUpRequest): ToolRun {
        val image = req.outfitImage ?: throw ApiException("bad_request", "Add the outfit photo")
        val run = lock.withLock {
            val m = model(modelId); archivedCheck(m)
            val order = listOf("front", "tq", "side", "back", "face", "faceTq", "profile")
            val slots = filledSlots(m).sortedBy { order.indexOf(it.first.key) }
            if (slots.isEmpty()) throw ApiException("bad_request", "Add photos to the character sheet first")
            val engines = dressEngines(req.engine)
            val est = dressTotal(slots.size, engines, req.models)
            if (est > balance.balance) throw ApiException("insufficient_balance", ErrorText.NOT_ENOUGH_STUDIO)
            charge(est)
            val models = engines.associate { e -> (if (e == "a") "dressA" else "dressB").let { it to modelFor(it, req.models) } }
            ToolRun("tool_" + uid(), "dressup", modelId, "running", ToolOptions(engine = req.engine, name = req.name?.ifBlank { null }, outfitImage = image), engines,
                slots.map { (si, img) -> ToolItem(si.key, si.label, img) }, est, 0.0, 0.0, "Dressing up · 1 of ${slots.size * engines.size}", createdAt = now(), models = models).also { toolRuns.add(0, it) }
        }
        events.tryEmit(ApiEvent("balance", balance = balance))
        simulate(run.id)
        return run
    }
    /** The demo "engine": each image after a moment; the result is the sheet image itself (Option B: the outfit photo for full-body shots). */
    private fun simulate(id: String) {
        scope.launch {
            val r0 = lock.withLock { toolRuns.first { it.id == id } }
            val per = if (r0.items.isEmpty()) 0.0 else r0.estimate / (r0.items.size * r0.engines.size)
            for ((i, item) in r0.items.withIndex()) {
                delay(genDelayMs / 4)
                val next = lock.withLock {
                    val r = toolRuns.firstOrNull { it.id == id } ?: return@launch
                    if (r.state != "running") return@launch
                    val res = ToolResults(a = item.before, b = if ("b" in r.engines) (if (Sheet.SLOTS.first { it.key == item.slot }.face) item.before else r.options.outfitImage ?: item.before) else null)
                    val items = r.items.mapIndexed { k, it -> if (k == i) it.copy(state = "done", results = res, cost = per * r.engines.size) else it }
                    val done = i == r.items.lastIndex
                    r.copy(items = items, progress = (i + 1) * 100.0 / r.items.size, cost = r.cost + per * r.engines.size, state = if (done) "review" else "running",
                        phase = if (done) "Ready to review" else "${if (r.kind == "enhance") "Enhancing" else "Dressing up"} · ${i + 2} of ${r.items.size * r.engines.size}",
                        finishedAt = if (done) now() else null).also { replaceRun(it) }
                }
                events.emit(ApiEvent("tool", tool = next))
            }
        }
    }
    private fun replaceRun(r: ToolRun) { toolRuns[toolRuns.indexOfFirst { it.id == r.id }] = r }
    private fun run(id: String) = toolRuns.firstOrNull { it.id == id } ?: throw ApiException("not_found", "Run not found")
    private fun inReview(r: ToolRun) { if (r.state != "review") throw ApiException("bad_request", if (r.state == "running") "Still working · wait for it to finish" else "This run is closed") }
    private fun update(id: String, f: (ToolRun) -> ToolRun): ToolRun { val r = f(run(id)); replaceRun(r); events.tryEmit(ApiEvent("tool", tool = r)); return r }

    override suspend fun toolRuns(modelId: String?): List<ToolRun> = lock.withLock { toolRuns.filter { modelId == null || it.modelId == modelId }.take(20) }
    override suspend fun toolRun(id: String): ToolRun = lock.withLock { run(id) }
    override suspend fun decideTool(id: String, slot: String, req: DecideRequest): ToolRun = lock.withLock {
        inReview(run(id))
        update(id) { r -> r.copy(items = r.items.map { if (it.slot != slot) it else if (req.decision == "reject") it.copy(decision = "reject", pick = null)
            else { val pick = req.pick ?: if (it.results.a != null) "a" else "b"; if (it.results.of(pick) == null) throw ApiException("bad_request", "That option has no image"); it.copy(decision = "keep", pick = pick) } }) }
    }
    override suspend fun pickTool(id: String, pick: String): ToolRun = lock.withLock {
        inReview(run(id))
        update(id) { r -> r.copy(items = r.items.map { if (it.results.of(pick) != null) it.copy(decision = "keep", pick = pick) else it }) }
    }
    override suspend fun retryTool(id: String, slot: String, engine: String?): ToolRun {
        val r = lock.withLock {
            inReview(run(id))
            update(id) { r -> r.copy(items = r.items.map { if (it.slot == slot) it.copy(state = "running", decision = "pending", pick = null) else it }) }
        }
        scope.launch {
            delay(genDelayMs / 2)
            val next = lock.withLock { update(id) { x -> x.copy(items = x.items.map { if (it.slot == slot) it.copy(state = "done") else it }) } }
            events.emit(ApiEvent("tool", tool = next))
        }
        return r
    }
    override suspend fun applyTool(id: String, name: String?): ApplyResponse = lock.withLock {
        val r = run(id); inReview(r)
        val kept = r.items.filter { it.decision == "keep" && it.pick != null }.associate { it.slot to it.results.of(it.pick!!)!! }
        if (kept.isEmpty()) throw ApiException("bad_request", "Keep at least one image")
        val m = model(r.modelId)
        if (r.kind == "enhance") {
            sheetVersions.getOrPut(m.id) { mutableListOf() }.add(0, SheetVersion("sv_" + uid(), now(), "enhance", m.slots))
            val nm = m.copy(slots = m.slots.map { s -> kept[s.key]?.let { s.copy(image = it, source = "generated", busy = false) } ?: s })
            replaceModel(nm)
            val done = update(id) { it.copy(state = "applied", appliedAt = now(), phase = "Saved") }
            events.tryEmit(ApiEvent("model", model = nm))
            ApplyResponse(done, nm)
        } else {
            val o = Outfit("o_" + uid(), m.id, name?.ifBlank { null } ?: r.options.name ?: "Dressed look", "dressup", "", listOf("front", "tq", "side", "back").map { kept[it] }, "ready",
                cost = r.cost, faces = listOf("face", "faceTq", "profile").map { kept[it] })
            outfits += o
            val nm = m.copy(outfitIds = m.outfitIds + o.id)
            replaceModel(nm)
            val done = update(id) { it.copy(state = "applied", appliedAt = now(), phase = "Saved", outfitId = o.id) }
            events.tryEmit(ApiEvent("outfit", outfit = o)); events.tryEmit(ApiEvent("model", model = nm))
            ApplyResponse(done, nm, o)
        }
    }
    override suspend fun discardTool(id: String) { lock.withLock { update(id) { it.copy(state = "discarded", phase = "Discarded") } } }
    override suspend fun sheetVersions(modelId: String): List<SheetVersion> = lock.withLock { sheetVersions[modelId]?.toList() ?: emptyList() }
    override suspend fun restoreSheet(modelId: String, versionId: String): Model = lock.withLock {
        val m = model(modelId)
        val list = sheetVersions.getOrPut(modelId) { mutableListOf() }
        val v = list.firstOrNull { it.id == versionId } ?: throw ApiException("not_found", "Version not found")
        list.remove(v); list.add(0, SheetVersion("sv_" + uid(), now(), "restore", m.slots))
        val nm = m.copy(slots = m.slots.map { s -> v.slots.firstOrNull { it.key == s.key } ?: s })
        replaceModel(nm); events.tryEmit(ApiEvent("model", model = nm)); nm
    }
    override suspend fun archiveModel(modelId: String, archived: Boolean): Model = lock.withLock {
        val nm = model(modelId).copy(archived = archived, archivedAt = if (archived) now() else null)
        replaceModel(nm); events.tryEmit(ApiEvent("model", model = nm)); nm
    }
    override suspend fun archivedModels(): List<Model> = lock.withLock { models.filter { it.archived } }

    // ---- helpers (call under lock) ----
    private fun charge(cost: Double) {
        balance = balance.copy(balance = (balance.balance - cost).coerceAtLeast(0.0), month = balance.month + cost, today = balance.today + cost)
    }

    private fun refund(cost: Double) {
        balance = balance.copy(balance = balance.balance + cost, month = (balance.month - cost).coerceAtLeast(0.0), today = (balance.today - cost).coerceAtLeast(0.0))
    }

    private fun model(id: String) = models.firstOrNull { it.id == id } ?: throw ApiException("not_found", "Model not found")
    private fun outfit(id: String) = outfits.firstOrNull { it.id == id } ?: throw ApiException("not_found", "Outfit not found")
    private fun replaceModel(m: Model) { models[models.indexOfFirst { it.id == m.id }] = m }
    private fun replaceOutfit(o: Outfit) { outfits[outfits.indexOfFirst { it.id == o.id }] = o }
    private fun replaceJob(j: Job) { jobs[jobs.indexOfFirst { it.id == j.id }] = j }
    private fun replacePost(p: Post) { posts.indexOfFirst { it.id == p.id }.takeIf { it >= 0 }?.let { posts[it] = p } }
    private fun loraOf(modelId: String): Lora { model(modelId); return loras.getOrPut(modelId) { Lora(modelId) } }
    private fun uid() = UUID.randomUUID().toString().take(8)

    companion object {
        /** The prompt identity; names her Identity LoRA when it's trained and switched on. */
        fun identity(m: Model, lora: Lora? = null) = Identity(m.name, m.look.ifBlank { "${m.age}-year-old woman" }, m.filled.coerceAtLeast(1), m.neverAdd, lora?.token(m.name))
    }
}

// ======================================================================= Edit suite (workstream 3)
/**
 * Demo results of the Editor v2 AI helpers (the same shapes as plans/api.md "Editor v2"): a café transcript spread over
 * the video, its silences and fillers, a 118 BPM beat grid, a voice stem and a green-screen matte as uploads.
 */
object FakeEditorResults {
    private val SCRIPT = listOf(
        "I", "um", "always", "order", "the", "oat", "flat", "white", "and", "like", "they", "remember", "my", "name", "you", "know",
        "this", "place", "is", "unreal", "honestly", "the", "light", "in", "here", "uh", "ten", "out", "of", "ten", "go",
    )
    private val FILLERS = setOf("um", "uh", "like")

    /** The sample transcript over [d] seconds, with pauses after "white" and after "unreal" (scaled to the length). */
    fun words(d: Double): List<Triple<String, Double, Double>> {
        val k = (d / 18.0).coerceIn(0.2, 1.0)
        val pauseAfter = mapOf(7 to 1.4 * k, 19 to 0.9 * k)
        val unit = (d - 0.6 - pauseAfter.values.sum()).coerceAtLeast(1.0) / SCRIPT.size
        var t = 0.3
        return SCRIPT.mapIndexed { i, w ->
            val len = unit * (0.55 + w.length.coerceAtMost(8) * 0.05)
            val out = Triple(w, r3(t), r3(t + len))
            t += unit + (pauseAfter[i] ?: 0.0)
            out
        }.filter { it.third <= d }
    }

    private fun r3(v: Double) = Math.round(v * 1000) / 1000.0
    private fun p(v: Any): JsonPrimitive = when (v) { is Number -> JsonPrimitive(v); is Boolean -> JsonPrimitive(v); else -> JsonPrimitive(v.toString()) }
    private fun obj(vararg kv: Pair<String, JsonElement>) = JsonObject(mapOf(*kv))

    fun result(kind: String, d: Double, id: String, options: JsonObject?): JsonObject {
        val ws = words(d)
        val wordsArray = JsonArray(ws.map { (w, s, e) -> obj("text" to p(w), "startSec" to p(s), "endSec" to p(e)) })
        return when (kind) {
            "captions" -> obj("language" to p("en"), "words" to wordsArray, "durationSec" to p(d), "reused" to p(false))
            "cuts" -> {
                val silenceOnly = (options?.get("silenceOnly") as? JsonPrimitive)?.content == "true"
                val cuts = ArrayList<Triple<Double, Double, String>>()
                for (i in 0 until ws.size - 1) {
                    val gap = ws[i + 1].second - ws[i].third
                    if (gap > 0.7) cuts += Triple(r3(ws[i].third + 0.12), r3(ws[i + 1].second - 0.12), "silence")
                }
                if (!silenceOnly) ws.forEach { (w, s, e) -> if (w.lowercase() in FILLERS) cuts += Triple(s, e, "filler") }
                val list = cuts.sortedBy { it.first }
                obj(
                    "cuts" to JsonArray(list.map { (s, e, r) -> obj("startSec" to p(s), "endSec" to p(e), "reason" to p(r)) }),
                    "savedSec" to p(r3(list.sumOf { it.second - it.first })), "words" to (if (silenceOnly) JsonArray(emptyList()) else wordsArray), "durationSec" to p(d),
                )
            }
            "beats" -> {
                val period = 60.0 / 118
                val beats = generateSequence(0.21) { it + period }.takeWhile { it < d }.map(::r3).toList()
                obj("bpm" to p(118), "beats" to JsonArray(beats.map(::p)), "strong" to JsonArray(beats.filterIndexed { i, _ -> i % 4 == 0 }.map(::p)), "durationSec" to p(d))
            }
            "denoise" -> obj(
                "asset" to obj("kind" to p("audio"), "upload" to p("up_voice_$id"), "durationSec" to p(d)),
                "suggestion" to obj("level" to p("light"), "reason" to p("Some background hum")),
            )
            "matte" -> obj(
                "asset" to obj("kind" to p("video"), "upload" to p("up_matte_$id"), "durationSec" to p(d)),
                "chroma" to obj("color" to p("#00FF00"), "similarity" to p(0.4), "smoothness" to p(0.08), "spill" to p(0.5)),
            )
            else -> obj()
        }
    }
}

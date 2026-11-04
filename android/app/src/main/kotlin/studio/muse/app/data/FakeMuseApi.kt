package studio.muse.app.data

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job as CoJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import studio.muse.core.ClipUse
import studio.muse.core.Engine
import studio.muse.core.Quality
import studio.muse.core.Identity
import studio.muse.core.OutfitSource
import studio.muse.core.OutfitSpec
import studio.muse.core.Pricing
import studio.muse.core.PromptEngine
import studio.muse.core.SourcePerformer
import studio.muse.core.VideoSwapSpec
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

    override fun events(): Flow<ApiEvent> = events
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

    override suspend fun listModels() = lock.withLock { models.toList() }

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
            val cost = Pricing.fillAnglesCost(missing.size)
            if (cost > balance.balance) throw ApiException("insufficient_balance", "Not enough balance · top up in Credits")
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

    override suspend fun listOutfits() = lock.withLock { outfits.toList() }

    override suspend fun createOutfit(req: CreateOutfitRequest): Outfit {
        val cost = if (req.mode == "own") 0.0 else Pricing.OUTFIT_SET_COST
        val o = lock.withLock {
            if (cost > balance.balance) throw ApiException("insufficient_balance", "Not enough balance · top up in Credits")
            charge(cost)
            val m = model(req.modelId)
            val spec = OutfitSpec(req.name, req.description, if (req.mode == "describe") OutfitSource.DESCRIBED else if (req.mode == "photo") OutfitSource.PRODUCT_PHOTO else OutfitSource.REFERENCE_SET)
            val prompt = PromptEngine.outfitSet(identity(m, loras[m.id]), spec).first().text
            val o = Outfit("o_" + uid(), req.modelId, req.name.ifBlank { "New outfit" }, req.mode, req.description, listOf(null, null, null, null), "generating", prompt)
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
        val c = Clip(id, meta.name, meta.durationSec, meta.width, meta.height, meta.fps, ClipRules.checks(meta))
        clips[id] = c
        c
    }

    override suspend fun listJobs() = lock.withLock { jobs.sortedByDescending { it.createdAt } }

    override suspend fun createJob(request: JobRequest): Job {
        // Replicate (Draft / Standard / HD): whole clip, priced per output second; lip sync and a background photo are Exact edit only.
        val replicate = request.engine == Engine.REPLICATE.id
        if (replicate && request.lipSync) throw ApiException("bad_request", "Lip sync is only on Exact edit")
        if (replicate && request.background == "photo") throw ApiException("bad_request", "A new background photo is only on Exact edit for now")
        val req = if (!replicate) request.copy(quality = null)
            else Quality.fromId(request.quality).let { q -> request.copy(use = ClipUse.FULL.id, quality = q.id, pricePerSec = studio.features.video?.pricePerSec(q) ?: q.pricePerSec) }
        val job = lock.withLock {
            val clip = clips[req.clipId]
            if (clip != null && !clip.ok) throw ApiException("clip_failed_checks", "Fix the clip checks first")
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
            if (Pricing.LORA_SET_COST > balance.balance + 1e-9) throw ApiException("insufficient_balance", "Not enough balance · top up in Credits")
            charge(Pricing.LORA_SET_COST)
            l0.copy(state = "building", candidates = emptyList(), progress = 0.0, cost = Pricing.LORA_SET_COST).also { loras[modelId] = it }
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
                        val failed = cur.copy(state = "failed", progress = p.progress, step = p.step, phase = "Failed at step ${p.step}", refunded = cur.cost,
                            error = "The GPU disconnected at step ${p.step}.", finishedAt = now())
                        refund(cur.cost)
                        replaceJob(failed)
                        ApiEvent("job", job = failed)
                    } else if (elapsed >= cur.totalSeconds) {
                        val done = cur.copy(state = "done", progress = 100.0, step = cur.totalSteps, take = cur.request.takes, phase = "Done", secondsLeft = 0.0, finishedAt = now())
                        replaceJob(done)
                        val newTakes = (1..cur.request.takes).map { i ->
                            val o = outfits.firstOrNull { it.id == cur.outfitId }
                            val thumb = o?.angles?.filterNotNull()?.let { if (it.isEmpty()) null else it[(i - 1) % it.size] } ?: cur.thumb ?: ImageRef.asset("g_front")
                            Take("t_${cur.id}_$i", "take", cur.id, i, cur.request.takes, cur.title,
                                when (cur.request.engine) { Engine.VIGGLE.id -> "Fast · beta"; Engine.REPLICATE.id -> Quality.fromId(cur.request.quality).label; else -> "${cur.request.steps} steps" }, cur.engineLabel,
                                cur.cost / cur.request.takes, cur.seed + i - 1, "test", thumb, cur.prompt, now())
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
        lock.withLock {
            if (req.templateId != null) tpl.name(req.templateId) // not_found before charging
            if (Pricing.SHOOT_COST > balance.balance) throw ApiException("insufficient_balance", "Not enough balance · top up in Credits")
            charge(Pricing.SHOOT_COST)
        }
        events.tryEmit(ApiEvent("balance", balance = balance))
        delay(genDelayMs)
        return lock.withLock {
            val o = outfits.firstOrNull { it.id == req.outfitId }
            val pool = listOf(o?.front?.asset ?: "g_front", "c_face", "face", "g_tq")
            val t = now()
            val shots = if (req.templateId != null) {
                val name = tpl.name(req.templateId)
                val m = model(req.modelId)
                val shuffle = req.shuffleSeed ?: kotlin.random.Random.nextLong(1L shl 31)
                pool.take(req.count).mapIndexed { n, k ->
                    val b = tpl.prompt(req.templateId, identity(m, loras[m.id]), o?.name, req.direction, shuffle, req.lockSeed == true, n)
                    val id = "s_${uid()}"
                    tpl.recordShot(id, req.templateId, b.full, b.draws)
                    // Stored with the public prompt; shotView() swaps in the full one for the template's owner.
                    Take(id, "shot", null, n + 1, req.count, "Shoot · $name", "${name.take(28)} · ${n + 1}", "", Pricing.SHOOT_COST / req.count,
                        b.shown.seed ?: 0, "test", ImageRef.asset(k), b.visible, t + n, templateId = req.templateId, templateName = name, shuffleSeed = shuffle)
                }.also { tpl.bumpUses(req.templateId) }
            } else {
                val label = req.scene.substringBefore(" · ").take(28)
                pool.take(req.count).mapIndexed { n, k ->
                    Take("s_${uid()}", "shot", null, n + 1, req.count, "Shoot · $label", "$label · ${n + 1}", "", Pricing.SHOOT_COST / req.count,
                        req.seed ?: 0, "test", ImageRef.asset(k), req.prompt, t)
                }
            }
            takes.addAll(0, shots)
            shots.map { tpl.shotView(it) }
        }
    }

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
        val b = lock.withLock {
            balance = balance.copy(balance = balance.balance + req.amount)
            balance
        }
        events.tryEmit(ApiEvent("balance", balance = b))
        return b
    }

    override suspend fun setFailNext(fail: Boolean) {
        failNext = fail
    }

    // ---- the demo studio's owner side: members, tokens, invites, settings (in memory, like the real API's rules)
    private val members = SampleData.members(now()).toMutableList()
    private val invites = mutableListOf<InviteInfo>()
    private var studio = StudioSettings(features = StudioFeatures(replicate = true, video = VideoFeatures.DEFAULT))
    private var engine = ImageEngine("simulated", "bundled-stills", "Simulated", available = mapOf("simulated" to true, "fal" to false, "custom-http" to true, "replicate" to false))
    private val tokenUsd = 0.01

    private fun ownerWallet(): Wallet {
        val unspent = members.sumOf { it.usd }
        val available = (balance.balance - unspent).coerceAtLeast(0.0)
        return Wallet("u1", "owner", kotlin.math.floor(available / tokenUsd + 1e-6).toLong(), available, 0, 0.0, balance.today, balance.month, tokenUsd, "simulated",
            availableToSend = available, runpodBalance = balance.balance, membersUnspentUsd = unspent)
    }

    /** Test hook: act as a member with this wallet (screenshots of the member's Credit screen). */
    @Volatile var debugWallet: Wallet? = null

    override suspend fun wallet(): Wallet = lock.withLock { debugWallet ?: ownerWallet() }
    override suspend fun listMembers(): List<Member> = lock.withLock { listOf(Member("u1", "jenne@studio.com", "owner", ownerWallet().tokens, ownerWallet().usd, lastActiveAt = now())) + members }

    private fun member(id: String) = members.firstOrNull { it.id == id }
        ?: if (id == "u1") throw ApiException("bad_request", "The owner's wallet is the RunPod balance; send credit to members only") else throw ApiException("not_found", "Member not found")

    override suspend fun transfer(req: TransferRequest): WalletMemberResponse = lock.withLock {
        val m = member(req.toUserId)
        val w = ownerWallet()
        if (req.tokens <= 0) throw ApiException("bad_request", "Send at least $0.01")
        if (req.tokens > w.tokens) throw ApiException("over_allocation", "You can send at most ${w.tokens} tokens (${Pricing.money(w.usd)}): that's what your RunPod balance backs")
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
    override suspend fun studioSettings(): StudioSettings = lock.withLock { studio.copy(lowBalance = balance.balance < studio.minRunpodBalance) }
    override suspend fun patchStudioSettings(req: StudioSettingsPatch): StudioSettings = lock.withLock {
        studio = studio.copy(maxGpus = req.maxGpus ?: studio.maxGpus, overheadPayer = req.overheadPayer ?: studio.overheadPayer, capPerJob = req.capPerJob ?: studio.capPerJob,
            capPerDay = req.capPerDay ?: studio.capPerDay, capPerUserDay = req.capPerUserDay ?: studio.capPerUserDay, warmGpuAllowed = req.warmGpuAllowed ?: studio.warmGpuAllowed)
        studio
    }

    // ---- Keep GPU warm (demo): boots in a few seconds, then bills $3.99/h from the balance once a minute.
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
                if (!warm.on) throw ApiException("not_warm", "The GPU is not warm")
                val v = warmView()
                warm = if (v.autoOffReason == "cap" && warm.canExtend) warm.copy(maxMinutes = warm.maxMinutes * 2, canExtend = false) else warm.copy(readyAt = now().takeIf { warm.state == "warm" } ?: warm.readyAt)
            }
            req.on == true -> if (!warm.on) {
                if (balance.balance < 3.99 * 10 / 60) throw ApiException("insufficient_balance", "Not enough credit to keep a GPU warm")
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

    /** Test hook: put a job in a fixed state (no runner). */
    suspend fun debugPut(job: Job) = lock.withLock {
        jobs.removeAll { it.id == job.id }
        jobs += job
    }

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

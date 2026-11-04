package studio.muse.app.data

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job as CoJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import studio.muse.core.Engine
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

    override fun events(): Flow<ApiEvent> = events
    override fun setToken(token: String?) {}

    override suspend fun signIn(req: SignInRequest): AuthResponse {
        if (req.email.isBlank()) throw ApiException("bad_request", "Enter your email")
        return AuthResponse("fake-token", User("u1", "Jenne Studio", req.email))
    }

    override suspend fun signUp(req: SignUpRequest): AuthResponse {
        if (!req.attestAdultRightsOriginal || !req.attestLabelAi) throw ApiException("attestation_required", "Tick both boxes to continue")
        return AuthResponse("fake-token", User("u1", req.studioName.ifBlank { "My Studio" }, req.email))
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
            val prompt = PromptEngine.outfitSet(identity(m), spec).first().text
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

    override suspend fun uploadImage(name: String, bytes: ByteArray, mime: String): ImageRef {
        val dir = storeDir ?: return ImageRef(url = "data:$mime;name=$name")
        dir.mkdirs()
        val ext = if (mime.contains("png")) "png" else "jpg"
        val f = File(dir, "img_${uid()}.$ext")
        f.writeBytes(bytes)
        return ImageRef(url = f.toURI().toString())
    }

    override suspend fun uploadClip(meta: ClipMeta, bytes: ByteArray?): Clip = lock.withLock {
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

    override suspend fun createJob(req: JobRequest): Job {
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
            val prompt = PromptEngine.videoSwap(
                VideoSwapSpec(identity(m), OutfitSpec(o?.name ?: "outfit"), SourcePerformer(), req.keepAudio, req.background == "keep", req.backgroundMotion, req.steps, seed),
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
        events.tryEmit(ApiEvent("balance", balance = balance))
        events.tryEmit(ApiEvent("job", job = job))
        run(job)
        return job
    }

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
                                if (cur.request.engine == Engine.VIGGLE.id) "Fast · beta" else "${cur.request.steps} steps", cur.engineLabel,
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

    override suspend fun listTakes() = lock.withLock { takes.toList() }

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
            if (Pricing.SHOOT_COST > balance.balance) throw ApiException("insufficient_balance", "Not enough balance · top up in Credits")
            charge(Pricing.SHOOT_COST)
        }
        events.tryEmit(ApiEvent("balance", balance = balance))
        delay(genDelayMs)
        return lock.withLock {
            val o = outfits.firstOrNull { it.id == req.outfitId }
            val pool = listOf(o?.front?.asset ?: "g_front", "c_face", "face", "g_tq")
            val label = req.scene.substringBefore(" · ").take(28)
            val t = now()
            val shots = pool.take(req.count).mapIndexed { n, k ->
                Take("s_${uid()}", "shot", null, n + 1, req.count, "Shoot · $label", "$label · ${n + 1}", "", Pricing.SHOOT_COST / req.count,
                    req.seed ?: 0, "test", ImageRef.asset(k), req.prompt, t)
            }
            takes.addAll(0, shots)
            shots
        }
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

    /** Test hook: put a job in a fixed state (no runner). */
    suspend fun debugPut(job: Job) = lock.withLock {
        jobs.removeAll { it.id == job.id }
        jobs += job
    }

    // ---- helpers (call under lock) ----
    private fun charge(cost: Double) {
        balance = balance.copy(balance = (balance.balance - cost).coerceAtLeast(0.0), month = balance.month + cost)
    }

    private fun refund(cost: Double) {
        balance = balance.copy(balance = balance.balance + cost, month = (balance.month - cost).coerceAtLeast(0.0))
    }

    private fun model(id: String) = models.firstOrNull { it.id == id } ?: throw ApiException("not_found", "Model not found")
    private fun outfit(id: String) = outfits.firstOrNull { it.id == id } ?: throw ApiException("not_found", "Outfit not found")
    private fun replaceModel(m: Model) { models[models.indexOfFirst { it.id == m.id }] = m }
    private fun replaceOutfit(o: Outfit) { outfits[outfits.indexOfFirst { it.id == o.id }] = o }
    private fun replaceJob(j: Job) { jobs[jobs.indexOfFirst { it.id == j.id }] = j }
    private fun uid() = UUID.randomUUID().toString().take(8)

    companion object {
        fun identity(m: Model) = Identity(m.name, m.look.ifBlank { "${m.age}-year-old woman" }, m.filled.coerceAtLeast(1), m.neverAdd)
    }
}

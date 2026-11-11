package studio.muse.app.data

import studio.muse.core.edit.RecipeJson
import studio.muse.core.edit.SharedLink
import studio.muse.core.edit.RecipeReference
import studio.muse.core.edit.RecreateBackground
import studio.muse.core.edit.RecreateRender
import studio.muse.core.edit.RecreateUseSound
import studio.muse.core.edit.RecreateReplaceResult
import studio.muse.core.edit.RecreateBriefsEstimate
import studio.muse.core.edit.RecreateMatch
import studio.muse.core.edit.RecreateApplyResult
import studio.muse.core.edit.RecreateFillStart
import studio.muse.core.edit.RecreateSlotEstimate
import studio.muse.core.edit.RecreateText
import studio.muse.core.edit.RecreateSlotFill
import studio.muse.core.edit.RecreateFill
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
    // AI suite build step 2: the demo model comes with a default rig (filled into Auto rows when she's @-mentioned).
    private val models = SampleData.models().map { if (it.id == SampleData.DEMO) it.copy(defaultRig = FakeSuiteRigs.DEMO_DEFAULT_RIG) else it }.toMutableList()
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
    override val claude: FakeClaudeApi by lazy { FakeClaudeApi(scope, now, { events.tryEmit(it) }, stepDelayMs = if (speed == 0.0) 0 else 700).also { c -> c.suiteTurn = ::demoSuiteTurn; c.suiteToolOf = { id -> assists[id]?.draft?.tool ?: "shot" } } }
    // WS7: bring your own provider (a demo key, a sample catalog, two added models).
    override val providers: FakeProvidersApi by lazy { FakeProvidersApi(now, if (speed == 0.0) 0 else 400) }
    // WS7: import a video from a link (TikTok, Instagram and YouTube links; the sample clip as the result).
    override val imports: FakeImportsApi by lazy { FakeImportsApi(now) }
    // WS7: models per purpose (the demo catalog's engines) and defaults.
    override val modelChoice: FakeModelsApi by lazy { FakeModelsApi { p -> suite.enginesFor(p.id, p.kind) } }
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

    override suspend fun fillAngles(modelId: String, imageModel: String?): FillAnglesResponse {
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
            val o = Outfit("o_" + uid(), req.modelId, req.name.ifBlank { "New outfit" }, req.mode, req.description, listOf(null, null, null, null), "generating", prompt, cost = cost.takeIf { it > 0 },
                createdAt = System.currentTimeMillis())
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

    private fun outfitName(name: String): String {
        val n = name.trim()
        if (n.isEmpty()) throw ApiException("bad_request", "Give the outfit a name")
        if (n.length > 80) throw ApiException("bad_request", "At most 80 characters")
        return n
    }

    override suspend fun renameOutfit(outfitId: String, name: String): Outfit {
        val o = lock.withLock { outfit(outfitId).copy(name = outfitName(name)).also { replaceOutfit(it) } }
        events.tryEmit(ApiEvent("outfit", outfit = o))
        return o
    }

    override suspend fun deleteOutfit(outfitId: String) {
        val m = lock.withLock {
            val o = outfit(outfitId)
            if (o.state == "generating") throw ApiException("outfit_busy", "This outfit is still being made · delete it when it finishes")
            outfits.removeAll { it.id == outfitId }
            model(o.modelId).takeIf { outfitId in it.outfitIds }?.let { it.copy(outfitIds = it.outfitIds - outfitId) }?.also { replaceModel(it) }
        }
        events.tryEmit(ApiEvent("outfit", op = "delete", id = outfitId))
        m?.let { events.tryEmit(ApiEvent("model", model = it)) }
    }

    override suspend fun fillOutfit(outfitId: String, imageModel: String?): OutfitFill {
        val (o, cost) = lock.withLock {
            val o0 = outfit(outfitId)
            if (o0.front == null) throw ApiException("bad_request", "Its front picture is missing · make a new outfit instead")
            val missing = (1 until 4).filter { o0.angles.getOrNull(it) == null }
            val cost = missing.size * photoPrices.perEdit
            if (cost > balance.balance) throw ApiException("insufficient_balance", ErrorText.NOT_ENOUGH_STUDIO)
            charge(cost)
            val fill = listOf("c_tq", "c_face", "c_front")
            val o = o0.copy(angles = (0 until 4).map { i -> o0.angles.getOrNull(i) ?: if (i in missing) ImageRef(asset = fill[i - 1]) else null })
            replaceOutfit(o)
            o to cost
        }
        events.tryEmit(ApiEvent("outfit", outfit = o))
        return OutfitFill(o, cost)
    }

    override suspend fun saveOutfit(outfitId: String, name: String?): Outfit {
        val (o, m) = lock.withLock {
            val o = outfit(outfitId).let { if (name != null) it.copy(name = outfitName(name)) else it }.copy(state = "ready")
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
                                    SuiteRules.ENGINE -> SuiteRules.tierLabel(cur.request.quality); UPSCALE_ENGINE -> cur.engineLabel; else -> "Edit" }, cur.engineLabel,
                                cur.cost / cur.request.takes, cur.seed + i - 1, "test", thumb, cur.prompt, now(),
                                // AI suite: how long the take lasts (Extend: source + the new part; Upscale: the source take's length).
                                durationSec = when (cur.request.engine) { SuiteRules.ENGINE -> suite.takeSeconds[cur.id] ?: cur.request.seconds; UPSCALE_ENGINE -> cur.request.seconds; else -> null },
                                look = if (cur.request.engine == SuiteRules.ENGINE) suite.looks[cur.id] else null,
                                draft = cur.draft) // AI suite build step 2: every take keeps its job's draft
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
        lock.withLock { jobs.removeAll { it.id == jobId }; hiddenJobs += jobId }
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
                    Take(id, "shot", null, n + 1, req.count, "Photo · $name", "${name.take(28)} · ${n + 1}", "", each,
                        b.shown.seed ?: 0, "test", ImageRef.asset(k), b.visible.withRefLines(refLines), t + n, templateId = req.templateId, templateName = name, shuffleSeed = shuffle,
                        refs = refs)
                }.also { tpl.bumpUses(req.templateId) }
            } else {
                val label = (req.scene?.takeIf { it.isNotBlank() } ?: PromptEngine.DEFAULT_SCENE).substringBefore(" · ").take(28)
                val built = previewNow(req)
                pool.take(req.count).mapIndexed { n, k ->
                    Take("s_${uid()}", "shot", null, n + 1, req.count, "Photo · $label", "$label · ${n + 1}", "", each,
                        req.seed ?: built.seed ?: 0, "test", ImageRef.asset(k), built.text, t, refs = refs)
                }
            }
            takes.addAll(0, shots)
            shots.forEach { takeModels[it.id] = req.modelId } // the feed's model filter (a still has no job to say who)
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

    /**
     * Upscale (server routes POST /v1/takes/{id}/upscale): a finished render take, a size the features price, held at
     * price × the take's seconds; `upscale_unavailable` (409) while the add-on or the size isn't available.
     */
    override suspend fun upscale(takeId: String, size: String, engineModel: String?): Job {
        val job = lock.withLock {
            val t = takes.firstOrNull { it.id == takeId } ?: throw ApiException("not_found", "Take not found")
            if (t.kind != "take") throw ApiException("bad_request", "Only a finished render can be upscaled")
            if (size !in setOf("1080p", "2k", "4k")) throw ApiException("bad_request", "Pick 1080p, 2K or 4K")
            val up = (studio.features.video ?: VideoFeatures.DEMO).upscale
            val z = up.sizes.firstOrNull { it.id == size }
            if (!up.available || z == null || !z.available || z.price == null) throw ApiException(UpscaleOffer.UNAVAILABLE, UpscaleOffer.SOON_TEXT)
            val src = jobs.firstOrNull { it.id == t.jobId }
            val secs = UpscaleOffer.seconds(t, src) ?: 8.0
            val cost = UpscaleOffer.price(z, secs) ?: 0.0
            if (cost > balance.balance + 1e-9) throw ApiException("insufficient_balance", "Not enough balance · top up in Credits")
            val req = JobRequest(title = t.title, modelId = src?.modelId.orEmpty(), outfitId = src?.outfitId.orEmpty(), engine = UPSCALE_ENGINE, takes = 1, seconds = secs, takeId = t.id, size = z.id)
            val total = SuiteClock.total(req)
            val p = SuiteClock.progress(req, 0.0)
            val j = Job("j_" + uid(), t.title, req.modelId, src?.modelName.orEmpty(), req.outfitId, req, "running", 0.0, 1, 0, p.totalSteps, p.phase, total, total, cost,
                createdAt = now(), prompt = t.prompt, seed = t.seed, thumb = t.thumb, serverEngineLabel = "Upscale · ${z.label}")
            charge(cost)
            jobs += j
            j
        }
        events.tryEmit(ApiEvent("balance", balance = balance))
        events.tryEmit(ApiEvent("job", job = job))
        run(job)
        return job
    }

    /** Test hook: Upscale live at the demo prices (true) or coming soon like a server without measured prices (false). */
    suspend fun debugSetUpscale(live: Boolean) = lock.withLock {
        val v = studio.features.video ?: VideoFeatures.DEMO
        val up = if (live) VideoFeatures.DEMO.upscale else VideoFeatures.DEFAULT.upscale
        studio = studio.copy(features = studio.features.copy(video = v.copy(addons = v.addons.map { if (it.id == "upscale") up else it })))
    }

    override suspend fun setFailNext(fail: Boolean) {
        failNext = fail
    }

    // ---- Edit suite (workstream 3): the Editor v2 AI helpers as instant mocks (like the server's mock provider)
    private val editorJobs = mutableMapOf<String, EditorJob>()
    private var editorSeq = 0

    private fun editorDuration(src: EditorSourceDto): Double =
        src.durationSec ?: takes.firstOrNull { it.id == src.takeId }?.durationSec ?: 8.0

    /** Tap to keep's points (workstream 1): 1–10, 0–1 of the frame, at least one keep; the server's plain messages. */
    private fun checkKeepPoints(req: EditorJobRequest) {
        val pts = (req.options?.get("points") as? JsonArray) ?: return
        if (pts.isEmpty() || pts.size > 10) throw ApiException("bad_request", "Tap 1 to 10 points")
        val objs = pts.map { it as? kotlinx.serialization.json.JsonObject ?: throw ApiException("bad_request", "Each tap needs x and y") }
        fun n(o: kotlinx.serialization.json.JsonObject, k: String) = (o[k] as? JsonPrimitive)?.content?.toDoubleOrNull()
        if (objs.any { o -> listOf("x", "y").any { k -> n(o, k)?.let { it !in 0.0..1.0 } ?: true } }) throw ApiException("bad_request", "Taps must be inside the frame")
        if (objs.none { (it["keep"] as? JsonPrimitive)?.content != "false" }) throw ApiException("bad_request", "Tap at least one thing to keep")
    }

    override suspend fun editorEstimate(req: EditorJobRequest): EditorEstimate {
        val d = editorDuration(req.source)
        checkKeepPoints(req)
        val silenceOnly = (req.options?.get("silenceOnly") as? kotlinx.serialization.json.JsonPrimitive)?.content == "true"
        val usd = when (req.kind) {
            "beats", "reverse", "stabilize" -> 0.0
            // Smooth slow motion: priced per second of output (range × factor).
            "slowmo" -> {
                fun opt(k: String) = (req.options?.get(k) as? JsonPrimitive)?.content?.toDoubleOrNull()
                maxOf(0.01, Math.round(((opt("endSec") ?: 1.0) - (opt("startSec") ?: 0.0)) * (opt("factor") ?: 2.0) * 0.01 * 100) / 100.0)
            }
            "translate" -> if ((req.options?.get("quality") as? JsonPrimitive)?.content == "best") 0.05 else 0.01
            "cuts" -> if (silenceOnly || editorJobs.values.any { it.kind == "captions" && it.state == "done" }) 0.0 else 0.02
            // Tap to keep has its own price: GPU 15 + 3·d seconds (plans/api.md).
            "matte" -> if (req.options?.get("points") != null) maxOf(0.01, Math.round((15 + 3 * d) * 0.0004 * 100) / 100.0) else maxOf(0.01, Math.round((10 + 4 * d) * 0.00025 * 100) / 100.0)
            "separate" -> maxOf(0.01, Math.round((5 + 0.3 * d) * 0.00025 * 100) / 100.0)
            "cutout" -> 0.01
            "denoise" -> if ((req.options?.get("analyzeOnly") as? kotlinx.serialization.json.JsonPrimitive)?.content == "true") 0.0 else maxOf(0.01, Math.round((5 + 0.3 * d) * 0.00025 * 100) / 100.0)
            else -> 0.02
        }
        return EditorEstimate(req.kind, usd, usd * 100, usd == 0.0, req.kind == "cuts" && usd == 0.0 && !silenceOnly, d)
    }

    override suspend fun startEditorJob(req: EditorJobRequest): EditorJob = lock.withLock {
        checkKeepPoints(req)
        // WS1 guardrails: paid helpers switched off by the owner (the free ones, cuts and beats, still run).
        if (!editorSettingsDemo.on && req.kind in listOf("captions", "matte", "denoise", "translate", "slowmo", "separate", "cutout")) throw ApiException("editor_paid_off", "AI editing helpers are switched off for this studio")
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

    override suspend fun saveProjectVersion(takeId: String, video: EditedVideo, project: kotlinx.serialization.json.JsonObject, name: String?, onProgress: (Float) -> Unit, aiLabel: Boolean): Take = lock.withLock {
        val src = takes.firstOrNull { it.id == takeId } ?: throw ApiException("not_found", "Take not found")
        onProgress(1f)
        val dto = EditListDto(2, takeId, 0.0, emptyList(), false).also { it.project = project }
        val t = src.copy(
            id = "t_edit_${now()}", kind = "edit", parentTakeId = takeId, label = "Edited", edits = dto, createdAt = now(), cost = 0.0, aiLabel = aiLabel,
            videoUrl = "file://" + video.file.absolutePath, durationSec = video.durationSec, width = video.width, height = video.height, fps = video.fps,
            name = versionName(name), // Edit sessions (workstream 3)
        )
        takes.add(0, t)
        events.tryEmit(ApiEvent("take", takes = listOf(t)))
        t
    }

    override suspend fun uploadClipFile(file: java.io.File, onProgress: (Float) -> Unit): String { onProgress(1f); return "up_clip_${++editorSeq}" } // WS7
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
    private var studio = StudioSettings(features = StudioFeatures(replicate = true, video = VideoFeatures.DEMO, photo = PhotoFeatures(), tools = FakeCatalog.ownerTools()),
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
                if (!warm.on) throw ApiException("not_warm", "The GPU is off")
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
    /** Suite uploads of this demo studio (their keys), so Extend can tell an upload of the studio from a stranger's key. */
    private val suiteUploads = mutableSetOf<String>()

    /**
     * Extend's source (server SuiteService.extendSource): a take of the studio (its stored key, or demo's stand-in for a
     * simulated take), else an upload of the studio with the client's `seconds`. The length, or null = not in this studio.
     */
    private fun extendSourceOf(req: SuiteShotRequest): Pair<Take?, Double?> {
        val v = req.extend?.video ?: return null to null
        val key = v.key ?: ExtendRules.keyOf(v.url) ?: return null to null
        takes.firstOrNull { ExtendRules.keyOf(it, demo = true) == key }?.let { t ->
            return t to (UpscaleOffer.seconds(t, jobs.firstOrNull { it.id == t.jobId }) ?: v.seconds ?: 0.0)
        }
        if (key in suiteUploads) return null to (v.seconds ?: 0.0)
        return null to null
    }

    override suspend fun suiteEstimate(req: SuiteShotRequest) = lock.withLock { suiteOn(); suite.estimate(req, suiteOwner, models, suiteClipSeconds(req.clipId), extendSourceOf(req).second) }
    override suspend fun suiteRigCheck(req: SuiteShotRequest) = lock.withLock { suiteOn(); SuiteRigCheck(suite.rig(req)) }
    override suspend fun createSuiteShot(req: SuiteShotRequest): Job {
        val job = lock.withLock {
            suiteOn()
            FakeSuiteRigs.checkDraft(req.draft) // a bad draft is refused before anything is held (server draftOf)
            val (srcTake, srcSeconds) = extendSourceOf(req)
            val e = suite.estimate(req, suiteOwner, models, suiteClipSeconds(req.clipId), srcSeconds)
            if (e.mode == ExtendRules.MODE) {
                if (e.estimate > balance.balance + 1e-9) throw ApiException("insufficient_balance", "Not enough balance · top up in Credits")
                val src = jobs.firstOrNull { it.id == srcTake?.jobId }
                val m = models.firstOrNull { it.id == src?.modelId }
                val j = suite.job("j_" + uid(), req, e, null, null, now(), srcSeconds).let { j ->
                    j.copy(modelId = m?.id.orEmpty(), modelName = m?.name.orEmpty(), thumb = srcTake?.thumb ?: src?.thumb, title = req.title ?: srcTake?.title?.let { "$it · extended" } ?: j.title,
                        draft = req.draft)
                }
                charge(j.cost)
                jobs += j
                return@withLock j
            }
            if (e.estimate > balance.balance + 1e-9) throw ApiException("insufficient_balance", "Not enough balance · top up in Credits")
            val lead = req.modelId ?: req.cast?.firstOrNull()?.characterId
            val m = lead?.let { id -> models.firstOrNull { it.id == id } }
            val o = (req.outfitId ?: req.cast?.firstOrNull()?.outfitId)?.let { id -> outfits.firstOrNull { it.id == id } }
            val j = suite.job("j_" + uid(), req, e, m, o, now()).copy(draft = req.draft)
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
    // The learning editor (workstream 3's /v1/learn): demo's playbook, lessons, corrections, library and gaps, in memory.
    private val learnRules = FakeLearn.rules().toMutableList()
    // Edit style kits (the demo keeps them in memory).
    private val kits = mutableListOf<EditKit>()
    override suspend fun editKits(): List<EditKit> = lock.withLock { kits.sortedByDescending { it.updatedAt } }
    override suspend fun saveEditKit(name: String, kit: kotlinx.serialization.json.JsonObject): EditKit = lock.withLock {
        val now = System.currentTimeMillis()
        EditKit("kit_${kits.size + 1}", name.trim().take(60), kit, "u_owner", now, now + kits.size).also { kits += it }
    }
    override suspend fun deleteEditKit(id: String) { lock.withLock { kits.removeAll { it.id == id } } }
    private val learnRecipes = FakeLearn.recipes().toMutableList()
    private var learnSeq = 100
    override suspend fun playbook(): List<LearnRule> = lock.withLock { learnRules.sortedWith(compareByDescending<LearnRule> { it.pinned }.thenByDescending { it.evidence.size }.thenByDescending { it.createdAt }) }
    override suspend fun addRule(req: LearnRuleRequest): LearnRule = lock.withLock {
        val text = req.text?.trim().orEmpty()
        if (text.isEmpty()) throw ApiException("bad_request", "Say what Claude should do")
        if (learnRules.size >= 200) throw ApiException("limit", "The playbook holds 200 rules · delete some first")
        val now = System.currentTimeMillis()
        LearnRule("rule_${++learnSeq}", text.take(300), req.area ?: "other", "owner", req.pinned ?: false, req.evidence.orEmpty(), now, now).also { learnRules += it }
    }
    override suspend fun patchRule(id: String, req: LearnRuleRequest): LearnRule = lock.withLock {
        val i = learnRules.indexOfFirst { it.id == id }.takeIf { it >= 0 } ?: throw ApiException("not_found", "Rule not found")
        val r = learnRules[i]
        learnRules[i] = r.copy(text = req.text?.trim()?.take(300) ?: r.text, area = req.area ?: r.area, evidence = req.evidence ?: r.evidence, pinned = req.pinned ?: r.pinned, updatedAt = System.currentTimeMillis())
        learnRules[i]
    }
    override suspend fun deleteRule(id: String) { lock.withLock { learnRules.removeAll { it.id == id } } }
    override suspend fun lessons(): List<LearnLesson> = FakeLearn.lessons()
    override suspend fun corrections(limit: Int): List<LearnCorrection> = FakeLearn.corrections().take(limit)
    override suspend fun recipes(q: String?, tags: List<String>, origin: String?): List<LearnRecipeEntry> = lock.withLock {
        learnRecipes.filter { r ->
            (q.isNullOrBlank() || listOf(r.name, r.summary).plus(r.tags).any { it.contains(q.trim(), ignoreCase = true) }) &&
                r.tags.containsAll(tags) && (origin == null || r.origin == origin)
        }.sortedByDescending { it.createdAt }.map { it.copy(recipe = null) }
    }
    override suspend fun recipe(id: String): LearnRecipeEntry = lock.withLock { learnRecipes.firstOrNull { it.id == id } ?: throw ApiException("not_found", "Recipe not found") }
    override suspend fun patchRecipe(id: String, req: LearnRecipePatch): LearnRecipeEntry = lock.withLock {
        val i = learnRecipes.indexOfFirst { it.id == id }.takeIf { it >= 0 } ?: throw ApiException("not_found", "Recipe not found")
        learnRecipes[i] = learnRecipes[i].let { r -> r.copy(name = req.name?.trim()?.take(80) ?: r.name, tags = req.tags?.map { it.lowercase().trim() }?.filter { it.isNotEmpty() }?.distinct() ?: r.tags) }
        learnRecipes[i]
    }
    override suspend fun deleteRecipe(id: String) { lock.withLock { learnRecipes.removeAll { it.id == id } } }
    override suspend fun nearestRecipes(id: String, k: Int): LearnNearest = lock.withLock {
        LearnNearest(id, learnRecipes.filter { it.id != id }.mapIndexed { i, r -> r.copy(recipe = null, distance = .2 + i * .25) }.take(k))
    }
    override suspend fun learnGaps(limit: Int): List<LearnGap> = FakeLearn.gaps().take(limit)

    // Recreate this edit (workstream 1's /v1/recreate/references): the analysis steps the server reports, then demo's recipe.
    private val recreatePolls = LinkedHashMap<String, Int>()
    private val recreatePhases = listOf("Finding the cuts", "Listening for the beat", "Reading the text", "Reading the look", "Writing the recipe")
    override suspend fun createReference(uploadId: String, name: String?, sourceUrl: String?): RecipeReference = lock.withLock {
        val id = "rx_${++editorSeq}"
        recreatePolls[id] = 0
        name?.let { recreateNames[id] = it }
        RecipeReference(id, name ?: "Reference", "analyzing", 5, "Waiting")
    }
    // Claude in the AI Suite (demo): the shared draft. Claude's turn sets it up and asks to generate; only the owner's
    // approval runs it (in demo, the fake suite, which never spends).
    private val assists = LinkedHashMap<String, SuiteAssist>()
    private fun pushAssist(a: SuiteAssist): SuiteAssist { assists[a.id] = a; events.tryEmit(ApiEvent("suiteAssist", assist = a)); return a }
    override suspend fun createSuiteAssist(draft: SuiteDraft?, fromJobId: String?) = lock.withLock {
        val d = draft ?: fromJobId?.let { id -> jobs.firstOrNull { it.id == id }?.draft } ?: SuiteDrafts.of("shot", "draft", "9:16", 5.0, 1, sound = true)
        SuiteAssist("sa_${++editorSeq}", "u_demo", d, 1, updatedAt = now()).also { assists[it.id] = it }
    }
    override suspend fun suiteAssist(id: String) = lock.withLock { assists[id] ?: throw ApiException("not_found", "Assist not found") }
    override suspend fun patchSuiteAssist(id: String, draft: SuiteDraft, baseRevision: Int?) = lock.withLock {
        val a = assists[id] ?: throw ApiException("not_found", "Assist not found")
        if (baseRevision != null && baseRevision != a.revision) throw ApiException("stale", "Claude changed the shot meanwhile · reload it")
        pushAssist(a.copy(draft = draft, revision = a.revision + 1, updatedAt = now()))
    }
    override suspend fun answerSuitePending(id: String, pendingId: String, approve: Boolean): SuitePending {
        val (a, p) = lock.withLock {
            val a = assists[id] ?: throw ApiException("not_found", "Assist not found")
            a to (a.pending.firstOrNull { it.id == pendingId } ?: throw ApiException("not_found", "Nothing waiting"))
        }
        if (p.status != "waiting") return p
        val done = if (!approve) p.copy(status = "declined") else {
            val req = demoAssistRequest(a.draft)
            val price = suiteEstimate(req).estimate
            if (price > p.maxUsd + 1e-9) throw ApiException("price_changed", "The price rose to ${Pricing.money(price)} · nothing was generated")
            p.copy(status = "done", jobId = createSuiteShot(req).id)
        }
        lock.withLock { assists[id]?.let { cur -> pushAssist(cur.copy(pending = cur.pending.map { if (it.id == pendingId) done else it }, updatedAt = now())) } }
        return done
    }
    /** Tests: Claude's Generate waiting on an assist (as `suite_request_shot` with confirm leaves it). */
    suspend fun debugAssistPending(id: String, p: SuitePending) = lock.withLock { assists[id]?.let { pushAssist(it.copy(pending = it.pending + p, revision = it.revision + 1, draft = it.draft)) } }
    override suspend fun uploadClaudeImage(name: String, bytes: ByteArray, mime: String, onProgress: (Float) -> Unit): String {
        if (bytes.size > 10 * 1024 * 1024) throw ApiException("bad_request", "Images can be up to 10 MB")
        onProgress(1f); return "up_img_${++editorSeq}"
    }
    /** What Generate would send for a demo draft. */
    private fun demoAssistRequest(d: SuiteDraft): SuiteShotRequest {
        val toks = (d["tokens"] as? kotlinx.serialization.json.JsonArray).orEmpty().mapNotNull { it as? kotlinx.serialization.json.JsonObject }
        fun s(o: kotlinx.serialization.json.JsonObject, k: String) = (o[k] as? kotlinx.serialization.json.JsonPrimitive)?.content
        val model = toks.firstOrNull { s(it, "t") == "mention" && s(it, "kind") == "character" }?.let { s(it, "id") }
        val prompt = toks.joinToString("") { o -> when (s(o, "t")) { "text" -> s(o, "text").orEmpty(); "mention" -> " ${s(o, "label").orEmpty()} "; else -> " " } }.replace(Regex("\\s+"), " ").trim()
        return SuiteShotRequest(modelId = model, prompt = prompt, duration = (d.duration ?: 5.0).toInt(), aspectRatio = d.aspect ?: "9:16", quality = d.quality ?: "draft", takes = d.takes ?: 1, draft = d)
    }
    /** Claude's demo turn: the first character at a café window, HD, 8 s; any attached photo as the pose reference; then it asks. */
    private suspend fun demoSuiteTurn(assistId: String, text: String, attachments: List<String>) {
        val m = lock.withLock { models.firstOrNull() }
        val a = lock.withLock { assists[assistId] } ?: return
        val j = kotlinx.serialization.json.Json
        val tokens = j.parseToJsonElement(buildString {
            append("[")
            if (m != null) append("""{"t":"mention","kind":"character","id":"${m.id}","label":"${m.name.substringBefore(' ')}","key":1},""")
            append("""{"t":"text","text":" sits by the café window in soft morning light, looks up and smiles"}]""")
        })
        val refs = kotlinx.serialization.json.JsonArray(attachments.take(3).map { id ->
            j.parseToJsonElement("""{"uploadId":"$id","url":"https://demo.muse.studio/uploads/$id.jpg","use":"pose","label":"Your photo"}""")
        })
        val draft = SuiteDraft(kotlinx.serialization.json.JsonObject(a.draft.json + mapOf("tokens" to tokens, "quality" to kotlinx.serialization.json.JsonPrimitive("hd"),
            "duration" to kotlinx.serialization.json.JsonPrimitive(8.0)) + (if (attachments.isNotEmpty()) mapOf("references" to refs) else emptyMap())))
        val price = runCatching { suiteEstimate(demoAssistRequest(draft)).estimate }.getOrDefault(1.04)
        val label = "Generate · 8 s · ${Pricing.money(price)}"
        lock.withLock {
            val cur = assists[assistId] ?: return
            pushAssist(cur.copy(draft = draft, revision = cur.revision + 1, updatedAt = now(),
                pending = cur.pending + SuitePending("sp_${++editorSeq}", label = label, estimateUsd = price, maxUsd = price, createdAt = now())))
        }
    }

    // Demo: Recreate's link rules (the owner can edit them).
    private var linkSettings = RecreateLinkSettings(canEdit = true)
    override suspend fun recreateSettings() = lock.withLock { linkSettings }
    override suspend fun patchRecreateSettings(strictLinks: Boolean) = lock.withLock {
        linkSettings = linkSettings.copy(strictLinks = strictLinks, platforms = if (strictLinks) listOf("tiktok", "instagram", "youtube") else listOf("any"),
            tiktokDownloadsOff = if (strictLinks) "refuse" else "allow"); linkSettings
    }
    /** Demo: links from other sites are refused while strict rules are on. */
    override suspend fun checkRecreateLink(url: String): RecreateLinkCheck {
        val platform = SharedLink.platform(url)
        val strict = lock.withLock { linkSettings.strictLinks }
        return if (platform == null && strict) RecreateLinkCheck(false, url, code = "link_unsupported", reason = "Paste a TikTok, Instagram Reel or YouTube link")
            else RecreateLinkCheck(true, url, platform ?: "other")
    }
    /** Demo: a failed reference analysed again (tests mark one failed with [debugFailReference]). */
    private val failedRefs = HashSet<String>()
    fun debugFailReference(id: String) = failedRefs.add(id)
    override suspend fun retryReference(id: String): RecipeReference {
        if (lock.withLock { !failedRefs.remove(id) }) throw ApiException("not_failed", "This reference isn't failed")
        lock.withLock { recreatePolls[id] = 0 }
        return reference(id)
    }
    /** Demo: a link with "private" in it answers like a private video; any other link runs the analysis. */
    override suspend fun createReferenceFromLink(url: String, name: String?): RecipeReference {
        if ("private" in url) throw ApiException("link_private", "This video is private · save it and share the file instead")
        return createReference("link", name)
    }
    /** Demo: the references made this session, newest first, each ready (its recipe) once its analysis has run. */
    override suspend fun listReferences(): List<RecipeReference> = lock.withLock {
        recreatePolls.entries.reversed().map { (id, n) ->
            if (n < recreatePhases.size) RecipeReference(id, recreateNames[id] ?: "Reference", "analyzing", 5 + 90 * n / recreatePhases.size, recreatePhases[n.coerceAtMost(recreatePhases.size - 1)])
            else RecipeReference(id, recreateNames[id] ?: "Reference", "ready", 100, durationSec = 15.0, createdAt = now(), expiresAt = now() + 30L * 86_400_000)
        }
    }
    private val recreateNames = HashMap<String, String>()
    override suspend fun reference(id: String): RecipeReference = lock.withLock {
        val n = recreatePolls[id] ?: throw ApiException("not_found", "Reference not found")
        if (id in failedRefs) return@withLock RecipeReference(id, recreateNames[id] ?: "Reference", "failed", error = "The analysis stopped the server twice · tap Retry for a lighter analysis", errorCode = "analysis_crashed")
        recreatePolls[id] = n + 1
        if (n < recreatePhases.size) RecipeReference(id, "Reference", "analyzing", 5 + 90 * n / recreatePhases.size, recreatePhases[n])
        else RecipeJson.reference("""{"id":"$id","name":"${recreateNames[id] ?: "Reference"}","state":"ready","progress":100,"phase":"Done","durationSec":15.0,"keep":false,"createdAt":${now()},"expiresAt":${now() + 30L * 86_400_000},"recipe":${FakeRecipes.cafeTrendJson()}}""")
    }

    // Recreate phases 2–3, demo mode (the Mac's FakeRecreateAPI): shots 1, 3 and 6 match the studio's takes, the others are
    // to generate at $0.64 each. Nothing is held or charged: a filled shot reads generating on the next fill and ready on
    // the one after (a demo job id), and apply returns a match without touching any edit.
    private val recreateMade = HashMap<String, HashMap<String, Int>>()
    private fun recreateSlots(id: String): List<String> {
        if (id !in recreatePolls) throw ApiException("not_found", "Reference not found")
        return FakeRecipes.cafeTrend().slots.map { it.id }
    }
    // WS1 guardrails, demo: the paid helpers' switch and daily limit (nothing is ever charged in demo mode).
    private var editorSettingsDemo = EditorSettings(paidHelpers = "on", capPerDayUsd = null, todayUsd = 0.42, markup = 2.0, provider = "mock")
    override suspend fun editorSettings() = lock.withLock { editorSettingsDemo }
    override suspend fun patchEditorSettings(paidHelpers: String?, cap: Double?, resetCap: Boolean) = lock.withLock {
        if (paidHelpers != null && paidHelpers != "on" && paidHelpers != "off") throw ApiException("bad_request", "paidHelpers: on or off")
        if (cap != null && (cap < 0 || cap > 1000)) throw ApiException("bad_request", "capPerDayUsd: 0 to 1000")
        editorSettingsDemo = editorSettingsDemo.copy(paidHelpers = paidHelpers ?: editorSettingsDemo.paidHelpers,
            capPerDayUsd = if (resetCap) null else cap ?: editorSettingsDemo.capPerDayUsd)
        editorSettingsDemo
    }
    /** Demo: the editor's features follow the switch (paid helpers off: captions, matte and denoise unavailable). */
    override suspend fun editorFeatures(): kotlinx.serialization.json.JsonObject = lock.withLock {
        val on = editorSettingsDemo.on
        fun avail(b: Boolean) = kotlinx.serialization.json.JsonObject(mapOf("available" to kotlinx.serialization.json.JsonPrimitive(b)))
        kotlinx.serialization.json.JsonObject(mapOf("paid" to avail(on), "captions" to avail(on), "matte" to avail(on), "denoise" to avail(on), "separate" to avail(on), "cutout" to avail(on),
            "translate" to kotlinx.serialization.json.JsonObject(mapOf("available" to kotlinx.serialization.json.JsonPrimitive(on),
            // Only what the export draws (Latin and Cyrillic for now; WS16).
            "languages" to kotlinx.serialization.json.JsonObject(listOf("en" to "English", "es" to "Spanish", "pt" to "Portuguese", "fr" to "French", "de" to "German", "it" to "Italian",
                "nl" to "Dutch", "pl" to "Polish", "tr" to "Turkish", "ru" to "Russian", "uk" to "Ukrainian").associate { (k, v) -> k to kotlinx.serialization.json.JsonPrimitive(v) }))),
            "slowmo" to avail(on), "cuts" to avail(true)))
    }

    override suspend fun matchReference(id: String, modelId: String?) { lock.withLock { recreateSlots(id) } }
    override suspend fun referenceFill(id: String): RecreateFill = lock.withLock {
        val slots = recreateSlots(id)
        val made = recreateMade.getOrPut(id) { HashMap() }
        made.keys.forEach { made[it] = made.getValue(it) + 1 }
        val videoTakes = takes.filter { it.kind == "take" }.map { it.id }
        RecreateFill(id, slots.mapIndexed { i, s ->
            val n = made[s]
            when {
                n != null && n >= 2 -> RecreateSlotFill(s, "ready", takeId = "t_rx_$s", jobId = "job_rx_$s", reason = "Generated for this shot")
                n != null -> RecreateSlotFill(s, "generating", jobId = "job_rx_$s", estimate = RECREATE_PRICE)
                i in listOf(0, 2, 5) && videoTakes.isNotEmpty() -> RecreateSlotFill(s, "matched", takeId = videoTakes[i % videoTakes.size],
                    score = listOf(.82, .74, .79)[listOf(0, 2, 5).indexOf(i)], reason = listOf("Your take has the same push-in on a close-up", "Your take walks through a door in a wide shot", "Your take sits by a window, still")[listOf(0, 2, 5).indexOf(i)])
                else -> RecreateSlotFill(s, "to_generate", estimate = RECREATE_SWAP_PRICE, estimateLabel = RecreateText.money(RECREATE_SWAP_PRICE), method = "swap")
            }
        })
    }
    /** Demo (G2): swap by default (your model into the reference's own segment, $0.41), or a new shot ($0.64). */
    override suspend fun estimateReferenceSlot(id: String, slotId: String, modelId: String, quality: String?, method: String?, keepBackground: Boolean?, locationId: String?, engineModel: String?, imageModel: String?) = lock.withLock {
        recreateSlots(id)
        val slot = FakeRecipes.cafeTrend().slots.firstOrNull { it.id == slotId } ?: throw ApiException("not_found", "That shot is gone")
        if (method == "generate") RecreateSlotEstimate(slotId, RECREATE_PRICE, maxOf(2.0, kotlin.math.ceil(slot.lengthSec)), method = "generate",
            buttonLabel = "Generate · ${maxOf(2.0, kotlin.math.ceil(slot.lengthSec)).toInt()} s · ${RecreateText.money(RECREATE_PRICE)}")
        else {
            // "Use your own setting": a studio location is free; otherwise a background is made from the brief ($0.06, added in).
            val own = keepBackground == false
            val place = if (own && locationId != null) suite.locations.firstOrNull { it.id == locationId } else null
            val bg = if (!own) null else if (place != null) RecreateBackground("location", place.id, place.name)
                else RecreateBackground("generated", setting = "From the brief", usd = RECREATE_PLATE_PRICE)
            val total = RECREATE_SWAP_PRICE + (bg?.usd ?: 0.0)
            RecreateSlotEstimate(slotId, total, slot.lengthSec, method = "swap", keepBackground = keepBackground ?: true,
                segmentStart = slot.startSec, segmentEnd = slot.endSec, buttonLabel = "Swap in · ${String.format(java.util.Locale.ROOT, "%.1f", slot.lengthSec)} s · ${RecreateText.money(total)}",
                background = bg, swapUsd = if (bg != null && bg.usd > 0) RECREATE_SWAP_PRICE else null, backgroundUsd = bg?.usd?.takeIf { it > 0 })
        }
    }
    override suspend fun fillReferenceSlot(id: String, slotId: String, modelId: String, quality: String?, method: String?, keepBackground: Boolean?, locationId: String?, engineModel: String?, imageModel: String?) = lock.withLock {
        recreateSlots(id)
        val made = recreateMade.getOrPut(id) { HashMap() }
        // Demo: a shot still being made can't be started again; a finished one can be made anew ("Make a new one").
        if ((made[slotId] ?: 2) < 2) throw ApiException("already_filled", "This shot is already being made")
        made[slotId] = 0
        RecreateFillStart(slotId, "job_rx_$slotId")
    }
    /** Demo (G8): Claude on the server writes the briefs for $0.02 (never charged in demo mode). */
    override suspend fun estimateReferenceBriefs(id: String) = lock.withLock {
        recreateSlots(id)
        RecreateBriefsEstimate(true, slots = FakeRecipes.cafeTrend().slots.count { it.brief == null }, estimateUsd = 0.02, label = "Write the shot briefs · about $0.02")
    }
    override suspend fun writeReferenceBriefs(id: String): RecipeReference = reference(id)
    /** Demo: Fix shot swaps the clip in place (a running fill's job is refused, as on the server). */
    override suspend fun replaceRecipeSlot(id: String, slotId: String, sessionId: String, take: String, baseRevision: Int?) = lock.withLock {
        val all = recreateSlots(id)
        if (slotId !in all) throw ApiException("slot_not_in_edit", "This shot isn't in the edit any more · rebuild the edit")
        if (take.startsWith("job_rx_") && (recreateMade[id]?.get(slotId) ?: 0) < 2) throw ApiException("job_not_done", "This shot is still being made")
        RecreateReplaceResult(sessionId, (baseRevision ?: 0) + 1, slotId, "Fixed shot ${all.indexOf(slotId) + 1}")
    }
    // Demo: the server's renders (free). The first read says rendering; the next says ready. The file is a stand-in.
    private val renderPolls = HashMap<String, Int>()
    /** Tests: the reference's sound isn't kept, so a guide export is refused (409 no_reference_sound). */
    @Volatile var debugNoReferenceSound = false
    private fun demoRender(key: String, sessionId: String, start: Boolean, sound: String?): RecreateRender {
        val n = if (start) 0.also { renderPolls[key] = 0 } else (renderPolls[key] ?: -1) + 1
        if (n >= 0) renderPolls[key] = n
        val state = when { n < 0 -> "none"; n == 0 -> "rendering"; else -> "ready" }
        val use = if (sound == null) null else RecreateUseSound(null, "Post with the original sound",
            listOf("Open the original post", "Tap its sound, then Use this sound", "Add this video and line it up at the start"),
            "The guide sound is only for timing. Post with the platform's own sound.")
        return RecreateRender(sessionId, 1, state, durationSec = 14.2, unsupported = if (sound == null) listOf("captions") else emptyList(), sound = sound, useThisSound = use)
    }
    override suspend fun editPreview(sessionId: String, start: Boolean, revision: Int?) = lock.withLock { demoRender("p:$sessionId", sessionId, start, null) }
    override suspend fun editPreviewFile(sessionId: String, revision: Int?, into: java.io.File): Boolean {
        if (lock.withLock { (renderPolls["p:$sessionId"] ?: 0) < 1 }) return false
        into.writeBytes(ByteArray(16)); return true
    }
    override suspend fun recreateExport(id: String, sessionId: String, sound: String, start: Boolean, revision: Int?) = lock.withLock {
        if (sound == "guide" && debugNoReferenceSound) throw ApiException("no_reference_sound", "The original's sound isn't kept any more · export it silent")
        demoRender("e:$id:$sessionId:$sound", sessionId, start, sound)
    }
    override suspend fun recreateExportFile(id: String, sessionId: String, sound: String, revision: Int?, into: java.io.File): Boolean {
        if (lock.withLock { (renderPolls["e:$id:$sessionId:$sound"] ?: 0) < 1 }) return false
        into.writeBytes(ByteArray(16)); return true
    }
    override suspend fun applyRecipe(id: String, sessionId: String, baseRevision: Int?, slots: Map<String, String>) = lock.withLock {
        val all = recreateSlots(id)
        val made = recreateMade[id].orEmpty()
        val waiting = slots.filter { (s, v) -> v.startsWith("job_rx_") && (made[s] ?: 0) < 2 }.keys.sorted()
        val scores = listOf(.93, .81, .84, .77, .62, .88, .9)
        RecreateApplyResult(sessionId, (baseRevision ?: 0) + 1, missing = all.filter { it !in slots }, waiting = waiting,
            match = RecreateMatch(.86, .97, .9, .78, .84, .8, all.mapIndexed { i, s -> s to scores[i % scores.size] }.toMap()))
    }

    override suspend fun uploadSuiteMedia(name: String, bytes: ByteArray, mime: String, onProgress: (Float) -> Unit): SuiteMediaRef {
        onProgress(1f)
        val ext = name.substringAfterLast('.', if (mime.startsWith("audio/")) "m4a" else "mp4")
        return SuiteMediaRef(key = "c/demo_${uid()}.$ext").also { r -> lock.withLock { suiteUploads += r.key!! } }
    }

    override suspend fun suiteLocations() = lock.withLock { suite.locations.toList() }
    override suspend fun createSuiteLocation(req: SuiteLocationCreate) = lock.withLock {
        if (req.name.isBlank() || req.name.length > 60) throw ApiException("bad_request", "Name the location (up to 60 characters)")
        SuiteLocation("loc_" + uid(), req.name.trim(), req.image, now()).also { suite.locations.add(0, it) }
    }
    override suspend fun deleteSuiteLocation(id: String) { lock.withLock { suite.locations.removeAll { it.id == id } } }

    // ---- AI suite build step 2 (plans/api.md "The new Suite's server pieces"): saved rigs, default rigs, the takes feed.
    /** Who the demo acts as while [suiteOwner] is false (a member of the demo studio). */
    var suiteMemberId = FakeSuiteRigs.MEMBER_ID
    private val suiteUserId get() = if (suiteOwner) FakeSuiteRigs.OWNER_ID else suiteMemberId
    val suiteRigStore by lazy { FakeSuiteRigs(now) { suite.camera } }
    /** Jobs deleted from Queue: the feed drops them with their takes. */
    private val hiddenJobs = mutableSetOf<String>()
    /** Each photo's character (a still has no job to say it), for the feed's model filter. */
    private val takeModels = mutableMapOf<String, String>()

    override suspend fun suiteRigs() = lock.withLock { suiteRigStore.list(suiteUserId, suiteOwner) }
    override suspend fun createSuiteRig(name: String, rig: SuiteRig) = lock.withLock { suiteRigStore.create(suiteUserId, name, rig) }
    override suspend fun updateSuiteRig(id: String, name: String?, rig: SuiteRig?) = lock.withLock { suiteRigStore.update(suiteUserId, suiteOwner, id, name, rig) }
    override suspend fun deleteSuiteRig(id: String) { lock.withLock { suiteRigStore.delete(suiteUserId, suiteOwner, id) } }
    override suspend fun setModelDefaultRig(modelId: String, rig: SuiteRig?): Model {
        val m = lock.withLock {
            rig?.let { FakeSuiteRigs.check(it, suite.camera, "defaultRig") }
            val m = model(modelId).copy(defaultRig = rig?.takeIf { !it.isEmpty }) // null or {} clears it
            replaceModel(m)
            m
        }
        events.tryEmit(ApiEvent("model", model = m))
        return m
    }
    override suspend fun suiteFeed(q: SuiteFeedQuery): SuiteFeedPage = lock.withLock {
        val page = FakeSuiteFeed.page(q.copy(collection = null), jobs.toList(), takes.toList(), models.toList(), hiddenJobs.toSet(), takeModels.toMap())
        val coll = q.collection?.let { id -> collections.firstOrNull { it.id == id } ?: throw ApiException("bad_request", "collection: unknown") }
        when {
            // A collection's feed: its takes and photos only (no pending jobs, no queue).
            coll != null -> page.copy(items = page.items.filter { it.takeId != null && it.takeId in coll.takeIds.orEmpty() })
            q.cursor == null -> page.copy(queued = queue.filter { q.status.isEmpty() || "queued" in q.status })
            else -> page
        }
    }

    // Build step 3, demo (plans/api.md "Library collections and the Suite queue"): nothing is held until Run.
    private val queue = mutableListOf<QueuedShot>()
    private val collections = mutableListOf<LibraryCollection>()
    override suspend fun queueSuiteShot(req: SuiteShotRequest): QueuedShot {
        val e = suiteEstimate(req)
        return lock.withLock {
            if (queue.size >= 50) throw ApiException("queue_full", "Up to 50 shots in the queue")
            QueuedShot("q_" + uid(), title = req.title ?: req.prompt?.take(60)?.ifBlank { null } ?: "Shot", modelId = req.modelId, estimate = e.estimate,
                buttonLabel = "Run · ${RecreateText.money(e.estimate)}", prompt = req.prompt, draft = req.draft, createdAt = now()).also { queue.add(0, it); queuedReqs[it.id] = req }
        }
    }
    private val queuedReqs = HashMap<String, SuiteShotRequest>()
    override suspend fun suiteQueue() = lock.withLock { queue.toList() }
    override suspend fun estimateQueuedShot(id: String): QueuedEstimate {
        val q = lock.withLock { queue.firstOrNull { it.id == id } } ?: throw ApiException("not_found", "That queued shot is gone")
        val e = suiteEstimate(queuedReqs.getValue(id))
        return QueuedEstimate(id, e.estimate, "Run · ${RecreateText.money(e.estimate)}", changed = e.estimate != q.estimate)
    }
    override suspend fun runQueuedShot(id: String): QueuedRun {
        val req = lock.withLock { queuedReqs[id]?.takeIf { queue.any { q -> q.id == id } } } ?: throw ApiException("not_found", "That queued shot is gone")
        val j = createSuiteShot(req)
        lock.withLock { queue.removeAll { it.id == id }; queuedReqs.remove(id) }
        return QueuedRun(id, j)
    }
    override suspend fun deleteQueuedShot(id: String) { lock.withLock { queue.removeAll { it.id == id }; queuedReqs.remove(id) } }
    private fun collectionView(c: LibraryCollection) = c.copy(count = c.takeIds.orEmpty().count { id -> takes.any { it.id == id } },
        cover = c.takeIds.orEmpty().firstNotNullOfOrNull { id -> takes.firstOrNull { it.id == id }?.thumb })
    override suspend fun libraryCollections() = lock.withLock { collections.sortedByDescending { it.updatedAt }.map(::collectionView) }
    override suspend fun createLibraryCollection(name: String, takeIds: List<String>) = lock.withLock {
        val n = name.trim()
        if (n.isEmpty() || n.length > 60) throw ApiException("bad_request", "name: 1–60 characters")
        LibraryCollection("col_" + uid(), n, "u_demo", mine = true, canEdit = true, createdAt = now(), updatedAt = now(), takeIds = takeIds.distinct())
            .also { collections.add(0, it) }.let(::collectionView)
    }
    private fun editCollection(id: String, f: (LibraryCollection) -> LibraryCollection): LibraryCollection {
        val i = collections.indexOfFirst { it.id == id }.takeIf { it >= 0 } ?: throw ApiException("not_found", "That collection is gone")
        collections[i] = f(collections[i]).copy(updatedAt = now())
        return collectionView(collections[i])
    }
    override suspend fun renameLibraryCollection(id: String, name: String) = lock.withLock { editCollection(id) { it.copy(name = name.trim().take(60)) } }
    override suspend fun deleteLibraryCollection(id: String) { lock.withLock { collections.removeAll { it.id == id } } }
    override suspend fun addToLibraryCollection(id: String, takeIds: List<String>) = lock.withLock {
        takeIds.firstOrNull { t -> takes.none { it.id == t } }?.let { throw ApiException("bad_request", "takeIds: no take or photo $it") }
        editCollection(id) { c -> c.copy(takeIds = (takeIds + c.takeIds.orEmpty()).distinct()) }
    }
    override suspend fun removeFromLibraryCollection(id: String, takeIds: List<String>) = lock.withLock { editCollection(id) { c -> c.copy(takeIds = c.takeIds.orEmpty() - takeIds.toSet()) } }
    override suspend fun takeCollections(takeId: String) = lock.withLock { collections.filter { takeId in it.takeIds.orEmpty() }.map(::collectionView) }

    // ---- AI suite · Photo tool (workstream 3): the shoot pipeline above, priced like its preview, with the still rig check.
    /** The Photo request as the shoot it runs: the prompt is the scene, the preset is the template. */
    private fun photoShoot(req: PhotoRequest): ShootRequest {
        val count = req.count ?: PhotoRules.DEFAULT_COUNT
        if (count !in 1..PhotoRules.MAX_COUNT) throw ApiException("bad_request", "Invalid photo: count must be 1–${PhotoRules.MAX_COUNT}")
        if ((req.references?.size ?: 0) > ShootRef.MAX) throw ApiException("bad_request", "Up to ${ShootRef.MAX} reference images")
        ShootRef.problem(req.references)?.let { throw ApiException("bad_request", it) }
        // No character (owner 2026-11-11): an image is needed and no preset; the demo renders on the sample model.
        if (req.modelId == null && req.presetId != null) throw ApiException("bad_request", "Presets need a character · pick one with @")
        if (req.modelId == null && req.references.isNullOrEmpty() && req.prompt.isBlank()) throw ApiException("bad_request", "Describe the photo or add an image")
        return ShootRequest(req.modelId ?: SampleData.DEMO, req.outfitId.orEmpty(), scene = req.prompt.trim().ifBlank { null }?.take(200), seed = req.seed, count = count,
            templateId = req.presetId, shuffleSeed = req.shuffleSeed, lockSeed = req.lockSeed, productImage = req.productImage, refs = req.references?.ifEmpty { null })
    }

    override suspend fun photoEstimate(req: PhotoRequest): PhotoEstimate = lock.withLock {
        val shoot = photoShoot(req)
        if (req.presetId != null) tpl.name(req.presetId) // not_found for an unknown preset
        val p = previewNow(shoot)
        photoEstimateOf(req, shoot.count, p.estimate, p.text)
    }

    /** The server's PhotoEstimate for [total] (count × perPhoto): notes for what a still can't use, the still rig rules, the look. */
    private fun photoEstimateOf(req: PhotoRequest, count: Int, total: Double, prompt: String): PhotoEstimate {
        val cam = req.camera as? JsonObject
        val notes = buildList {
            if (cam?.get("move") != null || cam?.get("mix") != null) add(PhotoRules.NO_MOVEMENT)
            if ((cam?.get("style") as? JsonObject)?.get("tempo") != null) add(PhotoRules.NO_TEMPO)
            if (req.presetId != null && cam != null && cam.keys.any { it != "mode" }) add(PhotoRules.PRESET_RIG)
        }
        val still = cam?.let { JsonObject(it - "move" - "mix") }
        val rig = RigRules.check(req.prompt, still, false, suite.camera).filter { it.id in PhotoRules.STILL_RULES }
        val look = suite.lookFor(SuiteShotRequest(camera = req.camera, gradeLook = req.gradeLook))
        val preset = req.presetId?.let { PhotoPresetRef(it, tpl.name(it)) }
        return PhotoEstimate(count = count, perPhoto = total / count, estimate = total, priceLine = "${PhotoPricing.about(total)} · ${PhotoRules.noun(count)}",
            buttonLabel = PhotoRules.button(count, Pricing.money(total)), warnings = notes, rig = rig, look = look,
            prompt = if (preset == null) prompt else null, preset = preset)
    }

    /** POST /v1/suite/photos: holds and makes the stills as a shoot does, saved as "Photo · …" takes. */
    override suspend fun createPhotos(req: PhotoRequest): PhotoResult {
        val shoot = lock.withLock { FakeSuiteRigs.checkDraft(req.draft); photoShoot(req) }
        val made = shoot(shoot)
        return lock.withLock {
            val ids = made.map { it.id }.toSet()
            // AI suite build step 2: every still keeps the composer draft ("Reuse settings").
            for (i in takes.indices) if (takes[i].id in ids) takes[i] = takes[i].copy(title = "Photo · " + takes[i].title.removePrefix("Photo · ").removePrefix("Shoot · "), draft = req.draft)
            PhotoResult(takes = takes.filter { it.id in ids }.map { tpl.shotView(it) })
        }
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
        /** Demo mode's price for a Recreate shot to generate (never charged). */
        const val RECREATE_PRICE = 0.64
        /** Demo: a swap into the reference's own shot (never charged). */
        const val RECREATE_SWAP_PRICE = 0.41
        /** Demo: a background made from the brief for "Use your own setting". */
        const val RECREATE_PLATE_PRICE = 0.06
        /** `request.engine` of an Upscale job (the server's). */
        const val UPSCALE_ENGINE = "upscale"
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
            // Translated captions (demo): the same timings, each word tagged with the target language.
            "translate" -> {
                val lang = (options?.get("targetLanguage") as? JsonPrimitive)?.content ?: "es"
                // With lines (the captions as shown), their words; else the transcript's.
                val given = (options?.get("lines") as? JsonArray)?.flatMap { l ->
                    val o = l as JsonObject
                    val t = (o["text"] as JsonPrimitive).content.split(' ').filter { it.isNotBlank() }
                    val s0 = (o["startSec"] as JsonPrimitive).content.toDouble(); val e0 = (o["endSec"] as JsonPrimitive).content.toDouble()
                    t.mapIndexed { i, w -> Triple(w, r3(s0 + (e0 - s0) * i / t.size), r3(s0 + (e0 - s0) * (i + 1) / t.size)) }
                }
                obj("language" to p(lang), "sourceLanguage" to p((options?.get("sourceLanguage") as? JsonPrimitive)?.content ?: "en"), "words" to JsonArray((given ?: ws).map { (w, s, e) -> obj("text" to p("${w.substringBefore('·')}·$lang"), "startSec" to p(s), "endSec" to p(e)) }),
                    "quality" to p((options?.get("quality") as? JsonPrimitive)?.content ?: "standard"), "durationSec" to p(d))
            }
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
            // Split voice and music (demo): two audio uploads the length of the source.
            "separate" -> obj(
                "vocals" to obj("kind" to p("audio"), "upload" to p("up_vocals_$id"), "durationSec" to p(d)),
                "instrumental" to obj("kind" to p("audio"), "upload" to p("up_instr_$id"), "durationSec" to p(d)),
                "durationSec" to p(d), "reused" to p(false),
            )
            // Cut out a picture (demo): a 600×900 subject from a 1200×1600 photo.
            "cutout" -> obj(
                "asset" to obj("kind" to p("image"), "upload" to p("up_cut_$id"), "width" to p(600), "height" to p(900)),
                "width" to p(600), "height" to p(900), "box" to obj("x" to p(300), "y" to p(350), "w" to p(600), "h" to p(900)),
                "sourceWidth" to p(1200), "sourceHeight" to p(1600), "mode" to p("person"),
            )
            "denoise" -> obj(
                "asset" to obj("kind" to p("audio"), "upload" to p("up_voice_$id"), "durationSec" to p(d)),
                "suggestion" to obj("level" to p("light"), "reason" to p("Some background hum")),
            )
            // Workstream 1's alpha matte: a grey video aligned with the source, white = keep; tracked when there are taps.
            "matte" -> {
                val pts = options?.get("points") as? JsonArray
                obj(
                    "asset" to obj("kind" to p("video"), "upload" to p("up_matte_$id"), "durationSec" to p(d)),
                    "alpha" to p(true), "mode" to p(if (pts != null) "tracked" else "person"),
                ).let { if (pts != null) kotlinx.serialization.json.JsonObject(it + ("points" to pts)) else it }
            }
            // Reverse: the whole source backwards, as a new video upload (free; local ffmpeg on the server).
            "reverse" -> obj(
                "asset" to obj("kind" to p("video"), "upload" to p("up_rev_$id"), "durationSec" to p(d)),
                "width" to p(1080), "height" to p(1920), "hasAudio" to p(true), "durationSec" to p(d),
            )
            // Smooth slow motion: the range factor× as long, silent.
            "slowmo" -> {
                val o = options
                val s = (o?.get("startSec") as? JsonPrimitive)?.content?.toDoubleOrNull() ?: 0.0
                val e = (o?.get("endSec") as? JsonPrimitive)?.content?.toDoubleOrNull() ?: 1.0
                val f = (o?.get("factor") as? JsonPrimitive)?.content?.toIntOrNull() ?: 2
                obj("asset" to obj("kind" to p("video"), "upload" to p("up_sm_$id"), "durationSec" to p((e - s) * f)),
                    "factor" to p(f), "startSec" to p(s), "endSec" to p(e), "fps" to p(30), "width" to p(1080), "height" to p(1920), "hasAudio" to p(false), "durationSec" to p((e - s) * f))
            }
            // Stabilise: the steadied copy, same length and timing (free; vidstab on the server).
            "stabilize" -> obj(
                "asset" to obj("kind" to p("video"), "upload" to p("up_st_$id"), "durationSec" to p(d)),
                "width" to p(1080), "height" to p(1920), "hasAudio" to p(true), "durationSec" to p(d),
            )
            else -> obj()
        }
    }
}

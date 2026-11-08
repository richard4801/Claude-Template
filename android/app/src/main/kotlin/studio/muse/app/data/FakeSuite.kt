package studio.muse.app.data

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import studio.muse.core.Pricing
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.roundToInt

/**
 * Demo mode's AI suite (workstream 1): the catalog, camera bag, settings and engine names are the server's own answers
 * (resources/suite_camera.json and suite_demo.json, captured from server/api in mock mode); estimates follow the server's
 * rules (price per output second × seconds × takes, labels, caps); shots run on the fake job pipeline with [SuiteClock].
 */
class FakeSuite {
    @Serializable
    private data class Bundle(val catalog: SuiteCatalog, val settings: SuiteSettings)

    private val json = Json { ignoreUnknownKeys = true; coerceInputValues = true }
    private val bundle: Bundle = json.decodeFromString(Bundle.serializer(), resource("/suite_demo.json"))
    val camera: CameraCatalog = json.decodeFromString(CameraCatalog.serializer(), resource("/suite_camera.json"))
    private var settings: SuiteSettings = bundle.settings.copy(mode = "mock")
    /** The Look each demo shot's takes carry (by job id), like the server's take.look. */
    val looks = mutableMapOf<String, SuiteLook>()
    /** The demo studio's locations library (two places, from the demo's own images), newest first. */
    val locations = mutableListOf(
        SuiteLocation("loc_loft", "Sunlit loft", ImageRef.asset("g_front"), 1_762_300_000_000),
        SuiteLocation("loc_studio", "Grey studio", ImageRef.asset("hero"), 1_762_200_000_000),
    )
    /** Spent today on suite shots (demo, never settled: test renders). */
    var spentToday = 0.0
        private set

    fun catalog(owner: Boolean): SuiteCatalog {
        val c = bundle.catalog.copy(enabled = true, test = true, camera = camera)
        return if (owner) withEngineDetail(c) else SuiteRules.memberSafe(c)
    }

    /**
     * WS7 (owner model picker), as the server's ownerEngines (WS5): every enabled registry model on a ladder, flat, with its
     * qualities, resolutions and $/s, lengths and shapes; the studio's custom video model; and the image models (the studio's
     * photo model and a custom one). Members never get any of it (memberSafe).
     */
    private fun withEngineDetail(c: SuiteCatalog): SuiteCatalog {
        val ladders = c.tiers.associate { t -> t.id to t.models.orEmpty() }
        val video = settings.models.filter { m -> m.enabled && !m.blocked && ladders.values.any { l -> l.any { it.model == m.id } } }.map { m ->
            val tiers = c.tiers.map { it.id }.filter { t -> ladders[t].orEmpty().any { it.model == m.id } }
            val res = tiers.firstNotNullOfOrNull { t -> ladders[t]?.firstOrNull { it.model == m.id }?.resolution } ?: m.resolutions.lastOrNull()?.id
            SuiteCatalogEngine(m.id, m.name, "video", false, tiers.firstOrNull(), tiers, res, m.resolutions.map { it.copy(perSec = round4(it.perSec * m.priceScale)) },
                m.perSec(res)?.let(::round4), null, m.duration?.min, m.duration?.max, m.duration?.allowed, m.aspectRatios,
                ladders.values.flatten().firstOrNull { it.model == m.id }?.inputs)
        }
        val custom = DEMO_CUSTOM.let { k -> SuiteCatalogEngine(k.id, k.name, "video", true, null, emptyList(), null, emptyList(), k.price?.usd, null, k.minSeconds, k.maxSeconds, listOf(5, 10), k.aspectRatios, k.inputs) }
        val image = listOf(
            SuiteCatalogEngine("google/nano-banana", "Nano Banana", "image", perRun = 0.039, inputs = SuiteInputs(images = 6)),
            SuiteCatalogEngine("c_demo1", "Seedream", "image", custom = true, perRun = 0.03, aspectRatios = listOf("1:1", "9:16", "16:9"), inputs = SuiteInputs(images = 6)),
        )
        return c.copy(custom = c.custom ?: listOf(DEMO_CUSTOM), engines = c.engines ?: (video + custom + image))
    }

    private fun round4(v: Double) = kotlin.math.round(v * 10000) / 10000

    /** The pinned engine's $/s (owner, demo): a ladder model at its resolution, or the demo custom model. */
    private fun pinnedPerSec(r: SuiteShotRequest): Double? {
        val id = r.engineModel ?: return null
        if (id == DEMO_CUSTOM.id) return DEMO_CUSTOM.price?.usd
        return settings.model(id)?.perSec(r.resolution)
    }

    fun settings(): SuiteSettings = settings.copy(spentToday = round2(spentToday))

    fun patch(req: SuiteSettingsPatch): SuiteSettings {
        req.models?.forEach { (id, p) ->
            val m = settings.model(id) ?: throw ApiException("bad_request", "Unknown model $id")
            if (p.enabled == true && m.blocked) throw ApiException("model_blocked", "${m.name} can't be switched on (licence)")
            settings = settings.copy(models = settings.models.map { if (it.id == id) it.copy(enabled = p.enabled ?: it.enabled) else it })
        }
        return settings()
    }

    /** The first usable ladder step of a tier (owner: names the engine). */
    private fun engineFor(tier: String, recast: Boolean): Pair<SuiteModelView?, String?> {
        if (recast) return settings.model(RECAST_MODEL[tier]) to RECAST_RES[tier]
        val step = settings.ladder[tier].orEmpty().firstOrNull { s -> settings.model(s.model)?.let { it.enabled && !it.blocked } == true }
        return settings.model(step?.model) to step?.resolution
    }

    /**
     * The estimate for a shot (server rules): seconds snap to the tier's limits, price = $/s × seconds × takes.
     * [characters]: the studio's characters (recast checks their sheets).
     */
    fun estimate(r: SuiteShotRequest, owner: Boolean, characters: List<Model>, clipSeconds: Double?, extendSource: Double? = null): SuiteEstimate {
        if (r.mode == ExtendRules.MODE || r.extend != null) return extendEstimate(r, owner, extendSource)
        val tier = r.quality ?: "draft"
        val recast = r.mode == "recast" || !r.cast.isNullOrEmpty()
        if (recast) {
            if (r.clipId.isNullOrBlank()) throw ApiException("bad_request", "Recast needs the source clip (clipId)")
            val cast = r.cast.orEmpty()
            if (cast.isEmpty()) throw ApiException("bad_request", "Recast needs a cast: who in the clip becomes which character")
            if (cast.size > SuiteRules.MAX_CAST) throw ApiException("bad_request", "Invalid shot: cast Array must contain at most 4 element(s)")
            val keys = cast.mapNotNull { c -> c.personIndex?.let { "i$it" } ?: c.personHint?.let { "h$it" } }
            if (keys.size != keys.toSet().size) throw ApiException("bad_request", "Two cast entries point at the same person")
            cast.forEach { c ->
                val m = characters.firstOrNull { it.id == c.characterId } ?: throw ApiException("not_found", "Model not found")
                if (m.filled == 0) throw ApiException("bad_request", "Each recast character needs a character sheet")
            }
        } else if (r.mode != "swap" && r.prompt.isBlank() && r.modelId == null) throw ApiException("bad_request", "Describe the shot")
        val max = if (tier == "draft") 15 else 30
        val wanted = if (recast) (clipSeconds ?: 6.0) else (r.duration ?: 5).toDouble()
        if (wanted > max) throw ApiException("nothing_fits", "${SuiteRules.tierLabel(tier)} can't make this shot · try another quality, a shorter length or fewer references")
        val min = if (recast) 4.0 else (bundle.catalog.tier(tier)?.minSeconds ?: 4).toDouble()
        val seconds = ceil(wanted).coerceAtLeast(min)
        val takes = if (recast) (r.takes ?: 1) else (r.takes ?: 1)
        val perSec = (if (owner && !recast) pinnedPerSec(r) else null) ?: (if (recast) RECAST_PER_SEC else PER_SEC)[tier] ?: 0.02
        val estimate = round2(perSec * seconds * takes)
        val res = (if (recast) RECAST_RES_LABEL else RES_LABEL)[tier] ?: "768p"
        val kind = if (recast) "Recast" else "Shot"
        val label = "$kind · ${SuiteRules.tierLabel(tier)} · $res"
        val secs = fmtSeconds(seconds)
        val caps = caps(estimate)
        val mode = r.mode ?: when { recast -> "recast"; r.modelId != null -> "reference"; else -> "text" }
        val moves = listOfNotNull(cameraMove(r, "move"), cameraMove(r, "mix"))
        val warnings = buildList {
            if (!recast && r.duration != null && seconds.toInt() != r.duration) add("length set to $secs s")
        }
        val castView = if (recast) r.cast.orEmpty().map { c ->
            SuiteEstimateCast(c.characterId, c.outfitId, who(c), when (c.speaking) { true -> "yes"; false -> "no"; null -> "unknown" })
        } else null
        val base = SuiteEstimate(
            quality = tier, label = label, resolution = res, seconds = seconds, takes = takes, mode = mode, estimate = estimate,
            priceLine = "about ${Pricing.money(estimate)} · $secs s${if (takes > 1) " · $takes takes" else ""}",
            buttonLabel = "Generate · $secs s · ${Pricing.money(estimate)}${if (takes > 1) " · $takes takes" else ""}",
            ok = caps.ok, code = caps.code, message = caps.message, caps = caps, warnings = warnings,
            camera = SuiteEstimateCamera(moves, false), test = true,
            speaking = SuiteSpeaking(r.speaking ?: false, if (r.speaking != null) "switch" else "default"),
            cast = castView, keepAudio = if (recast) r.keepAudio ?: true else null,
            prompt = if (owner) "Demo prompt · ${r.prompt.ifBlank { "the shot" }}" else "",
            look = lookFor(r),
            rig = rig(r),
        )
        if (!owner) return base
        val (m, resId) = engineFor(tier, recast)
        return base.copy(engine = m?.let { SuiteEngine(it.id, it.name, it.provider, it.ref, resId, it.perSec(resId), seconds, it.licence, it.licence.notice) })
    }

    /**
     * Extend (server suite/extend.ts): the tier's extend ladder picks the engine for the direction (Draft after = 720p, the
     * others on the 480p/720p reference engine); the new part's length snaps to that engine's range; price = $/s × seconds
     * × takes. [sourceSeconds]: the source's length, resolved by the caller (take, clip or upload); null = not in this studio.
     */
    fun extendEstimate(r: SuiteShotRequest, owner: Boolean, sourceSeconds: Double?): SuiteEstimate {
        val ex = r.extend ?: throw ApiException("bad_request", "Extend needs the video to continue (extend.video)")
        if (ex.video.key == null && ex.video.url == null) throw ApiException("bad_request", "Invalid shot: a video needs key or url")
        val source = sourceSeconds ?: throw ApiException("bad_request", "That video isn’t in this studio")
        if (!(source > 0)) throw ApiException("bad_request", "Extend needs the video’s length (extend.video.seconds)")
        val tier = r.quality ?: "draft"
        val before = ex.direction == "before"
        val step = extendStep(tier, before)
        val wanted = r.duration ?: 5
        if (source < 0.5 || wanted > step.max) throw ApiException("nothing_fits", "${SuiteRules.tierLabel(tier)} can't extend this clip ${if (before) "backwards" else "forwards"} · try another quality or length")
        val seconds = wanted.coerceIn(step.min, step.max).toDouble()
        val takes = r.takes ?: 1
        val estimate = round2(step.perSec * seconds * takes)
        val secs = fmtSeconds(seconds)
        val caps = caps(estimate)
        val warnings = buildList { if (seconds.toInt() != wanted) add("length set to $secs s (this quality makes ${step.min}–${step.max} s)") }
        val base = SuiteEstimate(
            quality = tier, label = "Extend · ${SuiteRules.tierLabel(tier)} · ${step.res}", resolution = step.res, seconds = seconds, takes = takes, mode = ExtendRules.MODE,
            estimate = estimate, priceLine = "about ${Pricing.money(estimate)} · $secs s${if (takes > 1) " · $takes takes" else ""}",
            buttonLabel = "Generate · $secs s · ${Pricing.money(estimate)}${if (takes > 1) " · $takes takes" else ""}",
            ok = caps.ok, code = caps.code, message = caps.message, caps = caps, warnings = warnings, camera = SuiteEstimateCamera(), test = true,
            speaking = SuiteSpeaking(false, "default"), prompt = if (owner) "Demo prompt · ${r.prompt.ifBlank { if (before) "the action leads naturally into it" else "the action carries on naturally" }}" else "",
        )
        if (!owner) return base
        val m = settings.model(step.model)
        return base.copy(engine = m?.let { SuiteEngine(it.id, it.name, it.provider, it.ref, step.res, step.perSec, seconds, it.licence, it.licence.notice) })
    }

    /** The first step of the demo's extend ladder for a tier and direction. */
    private fun extendStep(tier: String, before: Boolean): ExtendStep = when {
        tier == "draft" && !before -> EXTEND_STEPS.getValue("wan")
        tier == "draft" || tier == "standard" -> EXTEND_STEPS.getValue("seedance480")
        else -> EXTEND_STEPS.getValue("seedance720")
    }

    /** What each finished take of a job lasts (extend: source + the new part), by job id. */
    val takeSeconds = mutableMapOf<String, Double>()

    /** The rig check (server suite/rigcheck.ts, ported in [RigRules]): swap and recast have none. */
    fun rig(r: SuiteShotRequest): List<SuiteRigWarning> =
        if (r.mode == "swap" || r.mode == "recast" || !r.cast.isNullOrEmpty()) emptyList() else RigRules.check(r.prompt, r.camera, r.speaking == true, camera)

    /** The server's rule (suite/looks.ts shotLook): the palette, else the film stock, presets included; none when grading is off. */
    fun lookFor(r: SuiteShotRequest): SuiteLook? {
        if (r.gradeLook == false) return null
        val cam = r.camera as? kotlinx.serialization.json.JsonObject ?: return null
        fun str(o: kotlinx.serialization.json.JsonElement?, vararg path: String): String? {
            var e = o
            for (k in path) e = (e as? kotlinx.serialization.json.JsonObject)?.get(k)
            return (e as? kotlinx.serialization.json.JsonPrimitive)?.takeIf { it.isString }?.content
        }
        val preset = camera.presets.firstOrNull { it.id == str(cam, "preset") }?.spec
        val pal = str(cam, "palette", "preset") ?: str(preset, "palette", "preset")
        val stock = str(cam, "rig", "look") ?: str(preset, "rig", "look")
        camera.palettes.firstOrNull { it.id == pal }?.let { o -> o.lut?.let { return SuiteLook(o.id, "palette", o.label, it) } }
        camera.looks.firstOrNull { it.id == stock }?.let { o -> o.lut?.let { return SuiteLook(o.id, "stock", o.label, it) } }
        return null
    }

    private fun cameraMove(r: SuiteShotRequest, key: String): String? = runCatching {
        ((r.camera as? kotlinx.serialization.json.JsonObject)?.get(key) as? kotlinx.serialization.json.JsonObject)?.get("id")?.let { (it as kotlinx.serialization.json.JsonPrimitive).content }
    }.getOrNull()

    private fun who(c: SuiteCastMember) = when {
        c.personNote != null -> c.personNote
        c.personHint != null -> when (c.personHint) {
            "left", "center", "right" -> "the person on the ${if (c.personHint == "center") "centre" else c.personHint}"
            "foreground", "background" -> "the person in the ${c.personHint}"
            else -> "the ${c.personHint} person"
        }
        c.personIndex != null -> "person ${c.personIndex}"
        else -> "the person"
    }

    private fun caps(cost: Double): SuiteCaps {
        val perJob = settings.caps.perJob
        val perDay = settings.caps.perDay
        val left = round2((perDay - spentToday).coerceAtLeast(0.0))
        return when {
            cost > perJob + 1e-9 -> SuiteCaps(perJob, perDay, round2(spentToday), left, false, "suite_over_job_limit", "Over the studio's ${Pricing.money(perJob)} per-shot limit")
            spentToday + cost > perDay + 1e-9 -> SuiteCaps(perJob, perDay, round2(spentToday), left, false, "suite_over_day_limit",
                "Over the studio's ${Pricing.money(perDay)} daily AI suite limit · ${Pricing.money(left)} left today")
            else -> SuiteCaps(perJob, perDay, round2(spentToday), left)
        }
    }

    /** The render job for a shot (the fake pipeline runs it with [SuiteClock]). */
    fun job(id: String, r: SuiteShotRequest, e: SuiteEstimate, model: Model?, outfit: Outfit?, createdAt: Long, extendSource: Double? = null): Job {
        if (!e.ok) throw ApiException(e.code ?: "suite_over_job_limit", e.message ?: "Over the studio's limit")
        spentToday += e.estimate
        // Extend: the take is the whole longer clip (source + the new part, joined); other shots last what they render.
        takeSeconds[id] = if (e.mode == ExtendRules.MODE) (extendSource ?: 0.0) + e.seconds else e.seconds
        if (e.mode == ExtendRules.MODE) return job0(id, r.copy(title = r.title ?: "Extend"), e, null, null, createdAt)
        val recast = e.mode == "recast"
        val lead = model ?: return job0(id, r, e, null, null, createdAt)
        return job0(id, r, e, lead, outfit, createdAt).copy(modelId = lead.id, modelName = lead.name, thumb = outfit?.front ?: lead.cover,
            title = r.title ?: if (recast) "Recast" else "Untitled shot")
    }

    private fun job0(id: String, r: SuiteShotRequest, e: SuiteEstimate, model: Model?, outfit: Outfit?, createdAt: Long): Job {
        val req = JobRequest(title = r.title ?: "Untitled shot", modelId = model?.id ?: "", outfitId = outfit?.id ?: r.outfitId.orEmpty(), clipId = r.clipId.orEmpty(),
            engine = SuiteRules.ENGINE, takes = e.takes, keepAudio = e.keepAudio ?: true, quality = e.quality, speaking = e.speaking?.speaking, mode = e.mode, seconds = e.seconds)
        val total = SuiteClock.total(req)
        val p = SuiteClock.progress(req, 0.0)
        return Job(id, r.title ?: "Untitled shot", model?.id ?: "", model?.name ?: "", req.outfitId, req, "running", 0.0, 1, 0, p.totalSteps, p.phase, total, total,
            e.estimate, createdAt = createdAt, prompt = r.prompt, seed = (1000..99000).random().toLong(), serverEngineLabel = e.label)
    }

    private val DEMO_CUSTOM = SuiteCustomEngine("c_demo2", "Kling turbo", "video", SuiteInputs(start = true), 5, 10, listOf("9:16", "16:9", "1:1"), MemberPrice("per_second", 0.07))

    companion object {
        /** $ per output second per tier (the demo ladder's first steps, as the server prices them). */
        val PER_SEC = mapOf("draft" to 0.02, "standard" to 0.08, "hd" to 0.13, "cinema" to 0.235)
        val RES_LABEL = mapOf("draft" to "768p", "standard" to "768p", "hd" to "2K", "cinema" to "1080p")
        val RECAST_PER_SEC = mapOf("draft" to 0.1, "standard" to 0.25, "hd" to 0.45, "cinema" to 0.6)
        val RECAST_RES_LABEL = mapOf("draft" to "480p", "standard" to "720p", "hd" to "1080p", "cinema" to "1080p")
        private val RECAST_MODEL = mapOf("draft" to "wan-2.2-animate", "standard" to "kling-o1", "hd" to "h3-max-recast", "cinema" to "h3-max-recast")
        private val RECAST_RES = mapOf("draft" to "480", "standard" to "720p", "hd" to "1080P", "cinema" to "1080P")
        /** The demo's extend engines (the server's EXTEND_LADDER first steps): resolution, $ per output second with the clip, lengths. */
        val EXTEND_STEPS = mapOf(
            "wan" to ExtendStep("wan-2.7", "720p", 0.10, 2, 15),
            "seedance480" to ExtendStep("seedance-2.5", "480p", 0.4304, 4, 30),
            "seedance720" to ExtendStep("seedance-2.5", "720p", 0.9676, 4, 30),
        )

        private fun resource(path: String) = FakeSuite::class.java.getResource(path)?.readText() ?: error("missing $path")
        fun round2(v: Double) = (v * 100).roundToInt() / 100.0
        fun fmtSeconds(s: Double) = if (s == floor(s)) s.toInt().toString() else String.format(java.util.Locale.US, "%.1f", s)
    }
}

/** One step of the demo's extend ladder (owner-only words: [model] never reaches a member). */
data class ExtendStep(val model: String, val res: String, val perSec: Double, val min: Int, val max: Int)

/** How a suite shot moves in demo mode: per take 45 s + 10 s per output second, scaled by the tier (the server's estimate). */
object SuiteClock {
    private fun factor(q: String?) = when (q) { "draft" -> .6; "hd" -> 1.5; "cinema" -> 2.0; else -> 1.0 }
    fun perTake(req: JobRequest) = 45 + (req.seconds ?: 5.0) * 10 * factor(req.quality)
    fun total(req: JobRequest) = perTake(req) * req.takes.coerceAtLeast(1)

    /** step counts finished takes (like the server: totalSteps = takes). */
    fun progress(req: JobRequest, elapsed: Double): JobProgress {
        val takes = req.takes.coerceAtLeast(1)
        val per = perTake(req)
        val total = per * takes
        val e = elapsed.coerceIn(0.0, total)
        val take = minOf(takes, floor(e / per).toInt() + 1)
        val prefix = if (takes > 1) "take $take/$takes · " else ""
        val phase = if (e >= total) "Done" else "${prefix}Rendering · ${JobClock.leftText(total - e)}"
        return JobProgress((e / total * 100).coerceIn(0.0, 100.0), take, if (e >= total) takes else take - 1, takes, phase, total - e)
    }

    fun failAt(req: JobRequest) = perTake(req) * .3
}

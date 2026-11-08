package studio.muse.app.data

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import studio.muse.app.ui.screens.suite.composer.ComposerSettings
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.roundToInt

// AI suite (workstream 1, build step 2; plans/api.md "The new Suite's server pieces"): saved rigs, a model's default
// rig, the composer draft stored with each job and photo ("Reuse settings"), and the takes feed. Pure wire types and
// helpers; the server is strict (unknown fields are refused), so every optional field is null and left out of the JSON.

/** The JSON these types are written with: nulls left out (the server refuses unknown and null rig fields), unknown keys read past. */
val SuiteWireJson = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true; coerceInputValues = true }

/** One optional move of a rig, applied as a `#` chip. [intensity] 0–1. */
@Serializable
data class SuiteRigMove(val id: String, val intensity: Double? = null)

/**
 * A rig: the composer's rig rows by catalog id, with the same names as [ComposerSettings]. Every field is optional:
 * null (left out) is Auto. Ids are checked by the server against `GET /v1/suite/camera`.
 */
@Serializable
data class SuiteRig(
    val body: String? = null,
    val lens: String? = null,
    /** 8–200. */
    val focalMm: Double? = null,
    val aperture: String? = null,
    val height: String? = null,
    val shotSize: String? = null,
    val lighting: String? = null,
    val palette: String? = null,
    val stock: String? = null,
    /** Grade the take with the Look (false = only describe it in the prompt). */
    val gradeLook: Boolean? = null,
    val genre: String? = null,
    val era: String? = null,
    val tempo: String? = null,
    val format: String? = null,
    /** At most 2. */
    val moves: List<SuiteRigMove>? = null,
) {
    /** All Auto (the server stores `{}` as no default rig). An empty `moves` list still counts as a field, as on the server. */
    val isEmpty: Boolean get() = this == SuiteRig()

    /** The rig's rows as composer settings (moves aside: they are `#` chips). Rows the rig leaves on Auto are Auto. */
    fun toSettings(): ComposerSettings = ComposerSettings(
        body = body, lens = lens, focalMm = focalMm?.roundToInt(), aperture = aperture, height = height, shotSize = shotSize,
        genre = genre, era = era, tempo = tempo, format = format, palette = palette, stock = stock, gradeLook = gradeLook ?: true, lighting = lighting,
    )

    fun toJson(): JsonObject = SuiteWireJson.encodeToJsonElement(SuiteRig.serializer(), this) as JsonObject

    companion object {
        /**
         * The composer's rows as a rig (Auto rows left out; the preset id is not a rig row). `gradeLook` is kept only when
         * it says something: off, or on with a look picked. [moves] are the prompt's `#` chips, if any.
         */
        fun from(s: ComposerSettings, moves: List<SuiteRigMove>? = null): SuiteRig = SuiteRig(
            body = s.body, lens = s.lens, focalMm = s.focalMm?.toDouble(), aperture = s.aperture, height = s.height, shotSize = s.shotSize,
            lighting = s.lighting, palette = s.palette, stock = s.stock,
            gradeLook = s.gradeLook.takeIf { !it || s.palette != null || s.stock != null },
            genre = s.genre, era = s.era, tempo = s.tempo, format = s.format, moves = moves,
        )
    }
}

/**
 * The model default-rig rule (plans/api.md "Model default rig", plans/ai-suite-design.md "Refinements" 3): fill only the
 * rows still on Auto, never overwrite one the user set. Returns the new settings and the names of the fields it filled
 * (empty = nothing to apply, so no "Applied <name>'s rig · Undo"). `gradeLook` belongs to the Look row: it is applied only
 * while that row (palette and stock) is still Auto. Moves are the caller's (`#` chips, only if the prompt has none).
 */
fun applyDefaultRig(rig: SuiteRig, settings: ComposerSettings): Pair<ComposerSettings, List<String>> {
    val filled = mutableListOf<String>()
    fun <T> fill(name: String, cur: T?, v: T?): T? = if (cur == null && v != null) { filled += name; v } else cur
    val lookAuto = settings.palette == null && settings.stock == null
    val s = settings.copy(
        body = fill("body", settings.body, rig.body),
        lens = fill("lens", settings.lens, rig.lens),
        focalMm = fill("focalMm", settings.focalMm, rig.focalMm?.roundToInt()),
        aperture = fill("aperture", settings.aperture, rig.aperture),
        height = fill("height", settings.height, rig.height),
        shotSize = fill("shotSize", settings.shotSize, rig.shotSize),
        lighting = fill("lighting", settings.lighting, rig.lighting),
        palette = fill("palette", settings.palette, rig.palette),
        stock = fill("stock", settings.stock, rig.stock),
        genre = fill("genre", settings.genre, rig.genre),
        era = fill("era", settings.era, rig.era),
        tempo = fill("tempo", settings.tempo, rig.tempo),
        format = fill("format", settings.format, rig.format),
    ).let { s ->
        val g = rig.gradeLook
        if (lookAuto && g != null && g != s.gradeLook) { filled += "gradeLook"; s.copy(gradeLook = g) } else s
    }
    return s to filled
}

/** `GET /v1/suite/rigs`: a saved rig. [mine]: made by the viewer (the owner sees every rig in the studio, theirs first). */
@Serializable
data class SuiteRigView(
    val id: String,
    val name: String = "",
    val rig: SuiteRig = SuiteRig(),
    val userId: String = "",
    val mine: Boolean = false,
    val createdAt: Long = 0,
    val updatedAt: Long = 0,
)

/** `POST /v1/suite/rigs`. */
@Serializable
data class SuiteRigCreate(val name: String, val rig: SuiteRig)

/** `PATCH /v1/suite/rigs/{id}`: only what is sent changes; `rig` replaces the whole rig. */
@Serializable
data class SuiteRigPatch(val name: String? = null, val rig: SuiteRig? = null)

/**
 * The composer's full draft as the client sent it (plans/api.md `Draft`), kept as JSON so unknown keys round-trip: the
 * server stores it with the job (or every still) and hands it back on `Job.draft` / `Take.draft`, and "Reuse settings"
 * restores exactly what was sent. The typed accessors read the few values the server reads too.
 */
@Serializable(with = SuiteDraftSerializer::class)
data class SuiteDraft(val json: JsonObject) {
    private fun prim(k: String) = json[k] as? JsonPrimitive
    private fun str(k: String) = prim(k)?.takeIf { it.isString }?.content

    val v: Int get() = prim("v")?.intOrNull ?: 1
    /** shot | photo | storyboard | swap | recast | extend | upscale | talking | ugc */
    val tool: String? get() = str("tool")
    val quality: String? get() = str("quality")
    val aspect: String? get() = str("aspect")
    /** Seconds. */
    val duration: Double? get() = prim("duration")?.takeIf { !it.isString }?.doubleOrNull
    val takes: Int? get() = prim("takes")?.takeIf { !it.isString }?.intOrNull
    val count: Int? get() = prim("count")?.takeIf { !it.isString }?.intOrNull
    val sound: Boolean? get() = prim("sound")?.takeIf { !it.isString }?.booleanOrNull
    /** true, false, or null (absent or `null`) = auto. */
    val speaking: Boolean? get() = prim("speaking")?.takeIf { !it.isString }?.booleanOrNull
    /** The draft's rig, if it reads as one. */
    val rig: SuiteRig? get() = (json["rig"] as? JsonObject)?.let { runCatching { SuiteWireJson.decodeFromJsonElement(SuiteRig.serializer(), it) }.getOrNull() }

    operator fun get(key: String): JsonElement? = json[key]
}

/** Building drafts, and the tools a draft may name. */
object SuiteDrafts {
    /** The tools a draft may name (server suite/drafts.ts TOOLS). */
    val TOOLS = listOf("shot", "photo", "storyboard", "swap", "recast", "extend", "upscale", "talking", "ugc")

    /** A draft from the composer's values; [extra] carries everything else (tokens, slots, …) as JSON. Nulls are left out. */
    fun of(
        tool: String, quality: String? = null, aspect: String? = null, duration: Double? = null, takes: Int? = null, count: Int? = null,
        sound: Boolean? = null, rig: SuiteRig? = null, extra: Map<String, JsonElement> = emptyMap(),
    ): SuiteDraft = SuiteDraft(JsonObject(buildMap {
        put("v", JsonPrimitive(1))
        put("tool", JsonPrimitive(tool))
        quality?.let { put("quality", JsonPrimitive(it)) }
        aspect?.let { put("aspect", JsonPrimitive(it)) }
        duration?.let { put("duration", JsonPrimitive(it)) }
        takes?.let { put("takes", JsonPrimitive(it)) }
        count?.let { put("count", JsonPrimitive(it)) }
        sound?.let { put("sound", JsonPrimitive(it)) }
        rig?.let { put("rig", it.toJson()) }
        putAll(extra)
    }))
}

/** Writes and reads a [SuiteDraft] as its JSON object, unchanged. */
object SuiteDraftSerializer : KSerializer<SuiteDraft> {
    @OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
    override val descriptor: SerialDescriptor = SerialDescriptor("studio.muse.app.data.SuiteDraft", JsonObject.serializer().descriptor)
    override fun serialize(encoder: Encoder, value: SuiteDraft) = encoder.encodeSerializableValue(JsonObject.serializer(), value.json)
    override fun deserialize(decoder: Decoder): SuiteDraft = SuiteDraft(decoder.decodeSerializableValue(JsonObject.serializer()))
}

/**
 * One card in the takes rail (`GET /v1/suite/feed`). kind: job | take | photo. status: queued | running | failed | done.
 * Jobs (queued, running, failed) carry progress, phase, secondsLeft, error…; takes and photos carry takeId, videoUrl
 * (videos), index/of and final. Member-safe: [label] is the tier label, never an engine.
 */
@Serializable
data class SuiteFeedItem(
    val id: String,
    val kind: String = "job",
    val status: String = "done",
    val tool: String = "shot",
    val jobId: String? = null,
    val title: String = "",
    val modelId: String? = null,
    val modelName: String? = null,
    val createdAt: Long = 0,
    val poster: ImageRef? = null,
    val aspect: String? = null,
    val durationSec: Double? = null,
    val price: Double = 0.0,
    /** The caption line: "9:16, 10 s, 1 take, sound on" or "9:16, 4 photos". */
    val summary: String = "",
    // job
    val progress: Double? = null,
    val phase: String? = null,
    val secondsLeft: Double? = null,
    val blocked: String? = null,
    val error: String? = null,
    val errorCode: String? = null,
    val refunded: Double? = null,
    val label: String? = null,
    val takes: Int? = null,
    // take and photo
    val takeId: String? = null,
    val videoUrl: String? = null,
    val index: Int? = null,
    val of: Int? = null,
    val final: Boolean? = null,
) {
    val isJob get() = kind == "job"
    val isPhoto get() = kind == "photo"
}

/** `GET /v1/suite/feed`: a page, newest first. Pass [nextCursor] back until it is null. */
@Serializable
data class SuiteFeedPage(val items: List<SuiteFeedItem> = emptyList(), val nextCursor: String? = null,
    /** Build step 3: the "Queued" group, on the first page only (no cursor, no collection). */
    val queued: List<QueuedShot> = emptyList())

/** Build step 3 (plans/api.md "The Suite queue"): a shot saved to run later. Nothing is held until Run. */
@Serializable
data class QueuedShot(
    val id: String,
    val kind: String = "queued",
    val title: String = "",
    val tool: String = "shot",
    val modelId: String? = null,
    val userId: String = "",
    val mine: Boolean = true,
    val estimate: Double = 0.0,
    /** "Run · $0.40". */
    val buttonLabel: String = "Run",
    val prompt: String? = null,
    val draft: SuiteDraft? = null,
    val createdAt: Long = 0,
)

/** `POST /v1/suite/queue/{id}/estimate`: today's price ([changed]: it moved since queuing). */
@Serializable
data class QueuedEstimate(val id: String, val estimate: Double = 0.0, val buttonLabel: String = "Run", val changed: Boolean = false)

/** `POST /v1/suite/queue/{id}/run`: the job that started. */
@Serializable
data class QueuedRun(val queuedId: String, val job: Job)

/** Build step 3 (plans/api.md "Library collections"): a named group of the studio's takes and photos. */
@Serializable
data class LibraryCollection(
    val id: String,
    val name: String,
    val userId: String = "",
    val mine: Boolean = false,
    val canEdit: Boolean = false,
    val count: Int = 0,
    val cover: ImageRef? = null,
    val createdAt: Long = 0,
    val updatedAt: Long = 0,
    val takeIds: List<String>? = null,
)

/** The feed's filters and paging. [tool] and [status] are sent as comma lists; empty = all. [limit] 1–60 (server default 30). */
data class SuiteFeedQuery(
    val tool: List<String> = emptyList(),
    val status: List<String> = emptyList(),
    val model: String? = null,
    val cursor: String? = null,
    val limit: Int? = null,
    /** Only this collection's takes and photos (no pending jobs, no queue). */
    val collection: String? = null,
) {
    /** The query parameters, in a fixed order, without empty ones. */
    fun params(): Map<String, String> = buildMap {
        tool.filter { it.isNotBlank() }.takeIf { it.isNotEmpty() }?.let { put("tool", it.joinToString(",")) }
        status.filter { it.isNotBlank() }.takeIf { it.isNotEmpty() }?.let { put("status", it.joinToString(",")) }
        model?.takeIf { it.isNotBlank() }?.let { put("model", it) }
        cursor?.takeIf { it.isNotBlank() }?.let { put("cursor", it) }
        limit?.let { put("limit", it.toString()) }
        collection?.takeIf { it.isNotBlank() }?.let { put("collection", it) }
    }

    /** "tool=shot,photo&status=done&limit=30" (unencoded; for logs and tests). */
    fun queryString(): String = params().entries.joinToString("&") { "${it.key}=${it.value}" }

    companion object {
        val STATUSES = listOf("queued", "running", "failed", "done")
        const val PAGE = 30
        const val PAGE_MAX = 60
    }
}

/** The feed rules shared by demo mode and the UI (server suite/drafts.ts draftSummary and aspectOf). */
object SuiteFeedRules {
    private fun secs(n: Double): String {
        val r = if (n == floor(n)) n else Math.round(n * 10) / 10.0
        return "${if (r == floor(r)) r.toLong().toString() else r.toString()} s"
    }

    /**
     * The feed's caption line: "9:16, 10 s, 1 take, sound on" (photos: "9:16, 4 photos"). The draft's values win; the
     * fallbacks come from the job or take. Zero counts and lengths are left out, as on the server.
     */
    fun summary(d: SuiteDraft?, aspect: String? = null, seconds: Double? = null, takes: Int? = null, count: Int? = null, sound: Boolean? = null): String {
        val parts = mutableListOf<String>()
        (d?.aspect ?: aspect)?.takeIf { it.isNotEmpty() }?.let { parts += it }
        val tool = d?.tool
        if (tool == "photo" || (tool == null && (count ?: 0) != 0)) {
            val n = d?.count ?: count
            if (n != null && n != 0) parts += "$n photo${if (n == 1) "" else "s"}"
            return parts.joinToString(", ")
        }
        val s = d?.duration ?: seconds
        if (s != null && s != 0.0 && !s.isNaN()) parts += secs(s)
        val t = d?.takes ?: takes
        if (t != null && t != 0) parts += "$t take${if (t == 1) "" else "s"}"
        val snd = d?.sound ?: sound
        if (snd != null) parts += if (snd) "sound on" else "sound off"
        return parts.joinToString(", ")
    }

    private val SHAPES = listOf("9:16" to 9.0 / 16, "16:9" to 16.0 / 9, "1:1" to 1.0, "4:5" to 4.0 / 5, "3:4" to 3.0 / 4, "4:3" to 4.0 / 3, "21:9" to 21.0 / 9, "2:3" to 2.0 / 3)

    /** "9:16" from a width and height (the closest of the composer's shapes), or null. */
    fun aspectOf(w: Number?, h: Number?): String? {
        val W = w?.toDouble() ?: return null
        val H = h?.toDouble() ?: return null
        if (!(W > 0 && H > 0)) return null
        val r = W / H
        return SHAPES.reduce { a, b -> if (abs(ln(b.second / r)) < abs(ln(a.second / r))) b else a }.first
    }
}

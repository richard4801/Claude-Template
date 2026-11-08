package studio.muse.core.edit

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

/*
 * "Recreate this edit", phases 2–3 (plans/api.md "Recreate this edit · slots and assembly"; the Mac's
 * MuseCore/Recreate/Recreate.swift, RecreateSwatches.swift): how each shot of the reference is made (from a take, or
 * generated), what that costs, and how close the built edit is. Read leniently from WS1's server, like [RecipeJson].
 */

/** One shot's fill (`GET …/fill`). [state]: empty | matched | to_generate | generating | ready. */
data class RecreateSlotFill(
    val slotId: String,
    val state: String,
    val takeId: String? = null,
    val jobId: String? = null,
    val score: Double? = null,
    /** The server's own price for a shot to generate (the slot estimate replaces it once priced). */
    val estimate: Double? = null,
    val estimateLabel: String? = null,
    /** One plain line on the choice ("Your take has the same pan on a wide shot"). */
    val reason: String? = null,
    /** G2: how a new shot is made: "swap" (your model in the reference's own shot) or "generate" (a new Suite shot). */
    val method: String? = null,
    /** A swap that failed (refunded): "generate" is offered instead, priced on its own. */
    val fallback: String? = null,
    val failedJobId: String? = null,
)

/** How close the built edit is, 0–1 per element. */
data class RecreateMatch(
    val overall: Double? = null,
    val cuts: Double? = null,
    val text: Double? = null,
    val ramps: Double? = null,
    val grade: Double? = null,
    val shots: Double? = null,
    val perSlot: Map<String, Double> = emptyMap(),
)

data class RecreateFill(val referenceId: String, val slots: List<RecreateSlotFill>, val match: RecreateMatch? = null) {
    fun slot(id: String): RecreateSlotFill? = slots.firstOrNull { it.slotId == id }

    /** What the shots to generate cost: the slot estimates' prices where there are some, leaving out shots that can't be made. */
    fun generateTotal(prices: Map<String, Double> = emptyMap(), unavailable: Set<String> = emptySet()): Double =
        slots.filter { it.state == "to_generate" && it.slotId !in unavailable }.mapNotNull { prices[it.slotId] ?: it.estimate }.sum()
}

/**
 * `POST …/slots/{slotId}/estimate`: a shot's price (nothing held). [problem]: why it can't be made, in plain words.
 * G2: [method] "swap" (the default when it can run: your model in the reference's own segment, [segmentStart]–[segmentEnd])
 * or "generate"; [swapUnavailable]: why the default fell back to generate; [buttonLabel]: "Swap in · 2.0 s · $0.41".
 */
data class RecreateSlotEstimate(
    val slotId: String, val amount: Double, val seconds: Double, val problem: String? = null,
    val method: String = "generate", val keepBackground: Boolean = true, val segmentStart: Double? = null, val segmentEnd: Double? = null,
    val swapUnavailable: String? = null, val buttonLabel: String? = null, val promptFrom: String? = null,
) {
    val ok: Boolean get() = problem == null
}

/** `POST …/slots/{slotId}/fill`: the Suite job making the shot. */
data class RecreateFillStart(val slotId: String, val jobId: String)

data class RecreateApplyResult(
    val sessionId: String,
    val revision: Int? = null,
    val missing: List<String> = emptyList(),
    val waiting: List<String> = emptyList(),
    val notes: List<String> = emptyList(),
    val match: RecreateMatch? = null,
    /** G2: swapped shots already carry the reference's camera, speed and look ("baked"). */
    val baked: Map<String, List<String>> = emptyMap(),
)

/**
 * G8, `POST …/briefs/estimate`: "Write the shot briefs · about $0.02" (one Claude call on the server). [available] false:
 * [reason] says why (Claude on the server is off; asking Claude on the Mac is free).
 */
data class RecreateBriefsEstimate(val available: Boolean, val reason: String? = null, val slots: Int = 0, val estimateUsd: Double = 0.0, val label: String = "Write the shot briefs")

/** `POST …/slots/{slotId}/replace`: one shot's clip swapped in the built edit (one undoable change). */
data class RecreateReplaceResult(val sessionId: String, val revision: Int?, val slotId: String, val label: String? = null, val note: String? = null)

/** The server's JSON for the above. */
object RecreateJson {
    fun briefsEstimate(el: JsonElement): RecreateBriefsEstimate {
        val o = el as? JsonObject ?: throw IllegalArgumentException("briefs estimate is not an object")
        return RecreateBriefsEstimate((o["available"] as? JsonPrimitive)?.booleanOrNull ?: false, o.str("reason"), o.num("slots")?.toInt() ?: 0,
            o.num("estimateUsd") ?: 0.0, o.str("label") ?: "Write the shot briefs")
    }

    fun replace(el: JsonElement): RecreateReplaceResult {
        val o = el as? JsonObject ?: throw IllegalArgumentException("replace is not an object")
        return RecreateReplaceResult(o.str("sessionId") ?: "", (o["revision"] as? JsonPrimitive)?.intOrNull, o.str("slotId") ?: "", o.str("label"), o.str("note"))
    }

    private val json = Json { ignoreUnknownKeys = true }

    fun fill(text: String): RecreateFill = fill(json.parseToJsonElement(text))

    fun fill(el: JsonElement): RecreateFill {
        val o = el as? JsonObject ?: throw IllegalArgumentException("fill is not an object")
        val slots = o.arr("slots").mapNotNull { s ->
            (s as? JsonObject)?.let {
                val e = it.obj("estimate")
                RecreateSlotFill(
                    slotId = it.str("slotId") ?: return@mapNotNull null, state = it.str("state") ?: "empty",
                    takeId = it.str("takeId"), jobId = it.str("jobId"), score = it.num("score"),
                    estimate = e?.num("amount"), estimateLabel = e?.str("label"), reason = it.str("reason"),
                    method = it.str("method"), fallback = it.str("fallback"), failedJobId = it.str("failedJobId"),
                )
            }
        }
        return RecreateFill(o.str("referenceId") ?: "", slots, o.obj("match")?.let(::match))
    }

    fun match(o: JsonObject): RecreateMatch = RecreateMatch(
        o.num("overall"), o.num("cuts"), o.num("text"), o.num("ramps"), o.num("grade"), o.num("shots"),
        o.arr("perSlot").mapNotNull { p -> (p as? JsonObject)?.let { (it.str("slotId") ?: return@mapNotNull null) to (it.num("score") ?: 0.0) } }.toMap(),
    )

    fun estimate(el: JsonElement): RecreateSlotEstimate {
        val o = el as? JsonObject ?: throw IllegalArgumentException("estimate is not an object")
        val e = o.obj("estimate") ?: JsonObject(emptyMap())
        val ok = (e["ok"] as? JsonPrimitive)?.booleanOrNull ?: true
        val problem = if (ok) null else (e.str("message") ?: "This shot can’t be made at this length and quality.")
        val seg = o.obj("segment")
        return RecreateSlotEstimate(o.str("slotId") ?: "", e.num("estimate") ?: 0.0, e.num("seconds") ?: 0.0, problem,
            method = o.str("method") ?: e.str("method") ?: "generate", keepBackground = (o["keepBackground"] as? JsonPrimitive)?.booleanOrNull ?: true,
            segmentStart = seg?.num("startSec"), segmentEnd = seg?.num("endSec"), swapUnavailable = o.str("swapUnavailable"),
            buttonLabel = e.str("buttonLabel"), promptFrom = o.str("promptFrom"))
    }

    fun fillStart(el: JsonElement): RecreateFillStart {
        val o = el as? JsonObject ?: throw IllegalArgumentException("fill is not an object")
        return RecreateFillStart(o.str("slotId") ?: "", o.obj("job")?.str("id") ?: o.str("jobId") ?: "")
    }

    fun apply(el: JsonElement): RecreateApplyResult {
        val o = el as? JsonObject ?: throw IllegalArgumentException("apply is not an object")
        fun list(k: String) = o.arr(k).mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
        val baked = o.obj("baked")?.mapValues { (_, v) -> (v as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.content } }.orEmpty()
        return RecreateApplyResult(o.str("sessionId") ?: "", (o["revision"] as? JsonPrimitive)?.intOrNull, list("missing"), list("waiting"), list("notes"), o.obj("match")?.let(::match), baked)
    }

    private fun JsonObject.str(k: String): String? = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
    private fun JsonObject.num(k: String): Double? = (this[k] as? JsonPrimitive)?.doubleOrNull
    private fun JsonObject.obj(k: String): JsonObject? = this[k] as? JsonObject
    private fun JsonObject.arr(k: String): List<JsonElement> = (this[k] as? JsonArray).orEmpty()
}

/** Plain words for Recreate's build and compare (members see these: no model, provider or GPU names). */
object RecreateText {
    const val APPROVE_NOTE = "You approve before anything is made."

    /** The analysis steps, in the order the server reports them as `phase` (server/api/src/recreate/analyze.ts). */
    val ANALYSIS_STEPS = listOf("Finding the cuts", "Listening for the beat", "Reading the text", "Reading the look", "Reading the poses", "Writing the recipe")

    /** The step the analysis is on (its index in [ANALYSIS_STEPS]): -1 before the first, the size once done. */
    fun analysisStep(phase: String?, state: String = "analyzing"): Int {
        if (state == "ready") return ANALYSIS_STEPS.size
        val i = ANALYSIS_STEPS.indexOfFirst { it.equals(phase, ignoreCase = true) }
        return if (i >= 0) i else if (phase.equals("done", true)) ANALYSIS_STEPS.size else -1
    }

    /** "$1.28". */
    fun money(amount: Double): String = "$" + String.format(java.util.Locale.ROOT, "%.2f", amount)

    fun percent(v: Double?): String = v?.let { "${(it.coerceIn(0.0, 1.0) * 100).roundToInt()}%" } ?: "–"

    /**
     * "1 from your takes, 2 to generate · $1.28 in all", from the fill (never hard-coded). [prices] (slotId → amount, from
     * the slot estimates) replace the fill's own figures; [unavailable] slots couldn't be priced and are left out.
     */
    fun makingSummary(fill: RecreateFill, prices: Map<String, Double> = emptyMap(), unavailable: Set<String> = emptySet(), generating: Set<String> = emptySet()): String {
        fun state(s: RecreateSlotFill) = if (s.slotId in generating) "generating" else s.state
        val yours = fill.slots.count { state(it) == "matched" }
        val made = fill.slots.count { state(it) == "ready" }
        val generate = fill.slots.count { state(it) == "to_generate" && it.slotId !in unavailable }
        val cant = fill.slots.count { state(it) == "to_generate" && it.slotId in unavailable }
        val making = fill.slots.count { state(it) == "generating" }
        val empty = fill.slots.size - yours - made - generate - cant - making
        val parts = buildList {
            if (yours > 0) add("$yours from your takes")
            if (made > 0) add("$made generated")
            if (generate > 0) add("$generate to generate")
            if (making > 0) add("$making generating")
            if (cant > 0) add("$cant can’t be made")
            if (empty > 0) add("$empty to fill")
        }
        val head = if (parts.isEmpty()) "No shots yet" else parts.joinToString(", ")
        val toMake = fill.copy(slots = fill.slots.filter { it.slotId !in generating })
        return when {
            generate > 0 -> "$head · ${money(toMake.generateTotal(prices, unavailable))} in all"
            making > 0 -> head
            else -> "$head · nothing to pay"
        }
    }

    /** The confirmation's words: who makes the new shots, what comes from the takes, what is left out. */
    fun confirmMessage(paid: Int, yours: Int, cant: Int): String = buildList {
        if (paid == 1) add("The new shot is made with your model and charged to the studio.")
        if (paid > 1) add("The $paid new shots are made with your model and charged to the studio.")
        if (yours > 0) add(if (yours == 1) "1 shot comes from your takes." else "$yours shots come from your takes.")
        if (cant > 0) add(if (cant == 1) "1 shot can’t be made and is left out." else "$cant shots can’t be made and are left out.")
        add(if (paid > 0) "They take a few minutes; you can leave this page meanwhile." else "Nothing is generated or charged.")
    }.joinToString(" ")

    /** "A 2 s shot, cut to 1.2 s": what is made, and how much of it the edit uses. */
    fun madeLength(seconds: Double, slotSec: Double): String? {
        if (seconds <= 0) return null
        val made = "A ${seconds.roundToInt()} s shot"
        return if (slotSec < seconds - 0.05) "$made, cut to ${String.format(java.util.Locale.ROOT, "%.1f", slotSec)} s" else made
    }

    /** A shot tile's badge in the Recipe: Yours, To generate, Generating… */
    fun tag(state: String?, failed: Boolean = false, cant: Boolean = false): String = when {
        failed -> "Didn’t generate"
        state == "matched" -> "Yours"
        state == "ready" -> "Ready"
        state == "to_generate" -> if (cant) "Can’t be made" else "To generate"
        state == "generating" -> "Generating"
        state == null -> "…"
        else -> "To fill"
    }

    /** The fill box's heading for the selected shot. */
    fun fillState(state: String): String = when (state) {
        "matched" -> "From your takes"
        "to_generate" -> "To generate"
        "generating" -> "Generating"
        "ready" -> "Ready"
        else -> "Not filled"
    }

    /** A price error, in plain words, with the way out. */
    fun priceProblem(code: String?, message: String?): String = when (code) {
        "nothing_fits" -> "This shot can’t be made at this length and quality. Use one of your takes for it."
        "engine_unavailable" -> "New shots can’t be made right now. Use one of your takes for this shot."
        null -> "This shot couldn’t be priced. Check the connection and try again."
        else -> message ?: "This shot couldn’t be priced."
    }
}

/**
 * The Look swatches as Recreate shows them (owner note: "never garish"). The analysis reports the reference's real
 * colours, which can include pure greens and yellows that look broken on screen. The display keeps each colour's hue
 * but calms it: saturation is clamped, brightness kept in a mid range, and the strip is 3–5 swatches ordered by tone
 * (dark to light). The same rule as the Mac's RecreateSwatches.
 */
object RecreateSwatches {
    const val MAX_SATURATION = 0.38
    const val MIN_BRIGHTNESS = 0.35
    const val MAX_BRIGHTNESS = 0.76
    const val MIN_COUNT = 3
    const val MAX_COUNT = 5

    private data class Hsb(val h: Double, val s: Double, val v: Double)

    /** The softened strip: `#RRGGBB` strings, 3–5 of them (none when no colour could be read), dark to light. */
    fun soften(hexes: List<String>): List<String> {
        // A little under the clamp, so rounding to 8-bit channels never lands above it.
        val sCap = MAX_SATURATION - 0.015
        val hsb = hexes.mapNotNull(::rgb).map { c -> toHsb(c).let { Hsb(it.h, min(it.s, sCap), it.v.coerceIn(MIN_BRIGHTNESS, MAX_BRIGHTNESS)) } }.toMutableList()
        if (hsb.isEmpty()) return emptyList()
        // Fewer than three: add a darker and a lighter tone of the middle colour.
        while (hsb.size < MIN_COUNT) {
            val mid = hsb[hsb.size / 2]
            hsb += if (hsb.size % 2 == 1) Hsb(mid.h, mid.s, max(MIN_BRIGHTNESS, mid.v - 0.2)) else Hsb(mid.h, mid.s * 0.8, min(MAX_BRIGHTNESS, mid.v + 0.2))
        }
        var out = hsb.map { hex(fromHsb(it.h, it.s, it.v)) }.sortedBy(::luminance)
        if (out.size > MAX_COUNT) {
            // Keep the darkest, the lightest and evenly spaced tones between.
            val n = out.size
            out = (0 until MAX_COUNT).map { out[(it.toDouble() * (n - 1) / (MAX_COUNT - 1)).roundToInt()] }
        }
        return out
    }

    /** `#RRGGBB` (or `RRGGBB`) → 0–1 channels. */
    fun rgb(hex: String): Triple<Double, Double, Double>? {
        val s = hex.trim().removePrefix("#")
        if (s.length != 6) return null
        val v = s.toLongOrNull(16) ?: return null
        return Triple(((v shr 16) and 0xFF) / 255.0, ((v shr 8) and 0xFF) / 255.0, (v and 0xFF) / 255.0)
    }

    fun hex(c: Triple<Double, Double, Double>): String {
        fun b(x: Double) = (x * 255).roundToInt().coerceIn(0, 255)
        return String.format(java.util.Locale.ROOT, "#%02X%02X%02X", b(c.first), b(c.second), b(c.third))
    }

    /** HSB saturation of a hex colour (0 for one that can't be read). */
    fun saturation(hex: String): Double = rgb(hex)?.let { toHsb(it).s } ?: 0.0

    /** Relative luminance (WCAG), for ordering by tone. */
    fun luminance(hex: String): Double {
        val c = rgb(hex) ?: return 0.0
        fun lin(x: Double) = if (x <= 0.04045) x / 12.92 else ((x + 0.055) / 1.055).pow(2.4)
        return 0.2126 * lin(c.first) + 0.7152 * lin(c.second) + 0.0722 * lin(c.third)
    }

    private fun toHsb(c: Triple<Double, Double, Double>): Hsb {
        val (r, g, b) = c
        val mx = maxOf(r, g, b); val mn = minOf(r, g, b); val d = mx - mn
        var h = 0.0
        if (d > 0) {
            h = when (mx) { r -> ((g - b) / d) % 6; g -> (b - r) / d + 2; else -> (r - g) / d + 4 }
            h /= 6
            if (h < 0) h += 1
        }
        return Hsb(h, if (mx == 0.0) 0.0 else d / mx, mx)
    }

    private fun fromHsb(h: Double, s: Double, v: Double): Triple<Double, Double, Double> {
        val hh = (h - floor(h)) * 6; val i = hh.toInt() % 6; val f = hh - floor(hh)
        val p = v * (1 - s); val q = v * (1 - s * f); val t = v * (1 - s * (1 - f))
        return when (i) { 0 -> Triple(v, t, p); 1 -> Triple(q, v, p); 2 -> Triple(p, v, t); 3 -> Triple(p, q, v); 4 -> Triple(t, p, v); else -> Triple(v, p, q) }
    }
}

/**
 * Recreate's export (plans/recreate-edit.md step 7; Release 1): the built edit with the reference's sound as a guide
 * track, so it lands on the beat (then post it with the platform's "Use this sound"), or silent, timed for the sound.
 */
object RecreateExport {
    /** The guide's asset: the reference video saved on the device (its sound only is used). */
    const val GUIDE_ASSET = "recreate_guide"
    const val GUIDE_TRACK = "recreate_guide_track"

    /** Plain words for the reminder shown with the export. */
    const val REMINDER = "When you post, tap Use this sound on the original so your edit plays with its sound."

    /**
     * The edit's own sound is muted and the reference's sound plays under it from the start, for [durationSec] (the
     * reference's length, which the built edit matches).
     */
    fun withGuide(p: EditProject, durationSec: Double): EditProject {
        val muted = p.tracks.filter { it.id != GUIDE_TRACK }.map { if (it.kind == TrackKind.CAPTION) it else it.copy(muted = true) }
        val guide = Track(GUIDE_TRACK, TrackKind.MUSIC, name = "Guide sound",
            items = listOf(AudioClip("recreate_guide_clip", GUIDE_ASSET, 0.0, 0.0, durationSec)))
        val assets = p.assets.filter { it.id != GUIDE_ASSET } + Asset(GUIDE_ASSET, AssetKind.AUDIO, upload = "local:$GUIDE_ASSET", durationSec = durationSec) // on this device only; never saved
        return p.copy(assets = assets, tracks = muted + guide, mute = null)
    }

    /** No sound at all: the edit is timed for the sound, which is attached when posting. */
    fun silent(p: EditProject): EditProject = p.copy(tracks = p.tracks.filter { it.id != GUIDE_TRACK }.map { if (it.kind == TrackKind.CAPTION) it else it.copy(muted = true) },
        assets = p.assets.filter { it.id != GUIDE_ASSET }, mute = true)
}

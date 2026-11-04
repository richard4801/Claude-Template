package studio.muse.core

import java.math.BigDecimal
import java.math.RoundingMode
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.pow

/**
 * Video engine (the wire id; never shown). "replicate" = Render (Draft / Standard / HD, the default), "h3" = the Edit add-on,
 * "viggle" = the Fast · beta add-on. plans/api.md "App clean-up" §2.
 */
enum class Engine(val id: String, val label: String) {
    REPLICATE("replicate", "Render"),
    H3("h3", "Edit"),
    VIGGLE("viggle", "Fast · beta");

    companion object {
        fun fromId(id: String): Engine = entries.firstOrNull { it.id == id } ?: H3
    }
}

/** Replicate quality: price per output second (defaults; the server's features.video carries the live ones). */
enum class Quality(val id: String, val label: String, val resolution: String, val detail: String, val pricePerSec: Double) {
    DRAFT("draft", "Draft", "768P", "Quick preview · 768P", 0.02),
    STANDARD("standard", "Standard", "768P", "768P", 0.08),
    HD("hd", "HD", "2K", "2K", 0.13);

    companion object {
        fun fromId(id: String?): Quality = entries.firstOrNull { it.id == id } ?: DRAFT
    }
}

/**
 * The video studio's options (plans/api.md "App clean-up" §2): **Render** = Draft (the default) / Standard / HD, and the
 * **add-ons** Edit (the whole clip, default steps) and Fast · beta. Upscale is an add-on on a finished take.
 */
enum class VideoOption(val id: String, val label: String, val engine: Engine, val quality: Quality?, val detail: String) {
    DRAFT("draft", "Draft", Engine.REPLICATE, Quality.DRAFT, Quality.DRAFT.detail),
    STANDARD("standard", "Standard", Engine.REPLICATE, Quality.STANDARD, Quality.STANDARD.detail),
    HD("hd", "HD", Engine.REPLICATE, Quality.HD, Quality.HD.detail),
    EDIT("edit", "Edit", Engine.H3, null, "Swaps her into every frame of the whole clip"),
    FAST("fast", "Fast · beta", Engine.VIGGLE, null, "Quicker and rougher · beta");

    val addon: Boolean get() = quality == null

    companion object {
        val RENDER = listOf(DRAFT, STANDARD, HD)
        val ADDONS = listOf(EDIT, FAST)
        /** "exact" is the old id of Edit. */
        fun fromId(id: String?): VideoOption = if (id == "exact") EDIT else entries.firstOrNull { it.id == id } ?: DRAFT
        fun of(engine: Engine, quality: Quality): VideoOption = when (engine) {
            Engine.REPLICATE -> RENDER.first { it.quality == quality }
            Engine.H3 -> EDIT
            Engine.VIGGLE -> FAST
        }
    }
}

/** Upscale a finished take (an add-on; coming soon until the server says it's available). */
enum class UpscaleSize(val id: String, val label: String, val width: Int, val height: Int) {
    P1080("1080p", "1080p", 1080, 1920),
    K2("2k", "2K", 1440, 2560),
    K4("4k", "4K", 2160, 3840);

    companion object {
        fun fromId(id: String?): UpscaleSize? = entries.firstOrNull { it.id == id }
    }
}

/**
 * Pass-through photo prices (plans/api.md "App clean-up" §3): the server holds an estimate and settles each photo to
 * what the engine really charged. The defaults are Replicate's published prices; the server's features.photo wins.
 */
data class PhotoPrices(
    val perRun: Double = 0.015,
    val perInputMp: Double = 0.015,
    val perOutputMp: Double = 0.015,
    val perEdit: Double = 0.03,
    /** A reference shrunk to fit 1024 px at 3:4 (1024×768). */
    val refMp: Double = 0.79,
    val maxRefs: Int = 6,
    val loraShots: Int = 30,
)

/** The estimate formula, evaluated in doubles left to right exactly like the server and the Mac app. */
object PhotoPricing {
    /** One new shot: run + output megapixels + input megapixels. */
    fun newShot(p: PhotoPrices, outMp: Double, refs: Int): Double = p.perRun + p.perOutputMp * outMp + p.perInputMp * p.refMp * minOf(maxOf(refs, 0), p.maxRefs)
    /** A photoshoot of [count] stills at 2 MP. */
    fun shoot(p: PhotoPrices, count: Int = 4, refs: Int = p.maxRefs): Double = count * newShot(p, 2.0, refs)
    /** An outfit set: a new front, then three edits of it. "My own set" is free. */
    fun outfitSet(p: PhotoPrices, refs: Int = p.maxRefs): Double = newShot(p, 1.0, refs) + 3 * p.perEdit
    fun sheetAngles(p: PhotoPrices, missing: Int, refs: Int = p.maxRefs): Double = missing * newShot(p, 1.0, refs)
    fun loraSet(p: PhotoPrices, refs: Int = p.maxRefs): Double = p.loraShots * newShot(p, 1.0, refs)
    /** "about $0.46". */
    fun about(v: Double): String = "about ${Pricing.money(v)}"
}

/** Which part of the source clip is rendered. */
enum class ClipUse(val id: String, val seconds: Double, val label: String) {
    FIRST("first", 5.2, "First 5.2s"),
    FULL("full", 9.4, "Full 9.4s");

    companion object {
        fun fromId(id: String): ClipUse = entries.firstOrNull { it.id == id } ?: FIRST
    }
}

/** Everything that changes the price of a render. Mirrors the prototype's `S.engine/S.use/S.steps/S.lip`. */
data class RenderSpec(
    val engine: Engine = Engine.H3,
    val use: ClipUse = ClipUse.FIRST,
    val steps: Int = Pricing.STEPS_DEFAULT,
    val lipSync: Boolean = false,
    val takes: Int = 1,
    /** Real length of the picked clip. Null = the prototype's sample clip (9.4 s). */
    val clipSeconds: Double? = null,
    /** Replicate only. */
    val quality: Quality = Quality.DRAFT,
    /** Replicate only: $ per output second from the server (null = the [Quality] default). */
    val pricePerSec: Double? = null,
) {
    /** Replicate: the whole clip, rounded up to whole seconds (4–15). */
    val replicateSeconds: Int get() = Pricing.replicateSeconds(clipSeconds)

    /** Seconds actually rendered: the first 5.2 s, or the whole clip (max 15 s, H3's single-pass limit). */
    val lengthSec: Double
        get() = if (engine == Engine.REPLICATE) minOf(clipSeconds ?: ClipUse.FULL.seconds, Pricing.MAX_CLIP_SEC) else when (use) {
            ClipUse.FIRST -> minOf(ClipUse.FIRST.seconds, clipSeconds ?: ClipUse.FIRST.seconds)
            ClipUse.FULL -> minOf(clipSeconds ?: ClipUse.FULL.seconds, Pricing.MAX_CLIP_SEC)
        }
}

/**
 * The pricing math from prototype/app/app.js, ported 1:1 (secPerLen, estMin, estCost, stepsDelta, genLabel).
 * Measured on an H100 with FlashAttention 3: 57.8 s per step for a 5.2 s clip, billed at $3.99/h.
 * Unit tests check every value against fixtures generated by running the JS itself.
 */
object Pricing {
    const val STEPS_MIN = 4
    const val STEPS_MAX = 30
    const val STEPS_DEFAULT = 10
    const val TAKES_MAX = 4
    const val SEC_PER_STEP_5S = 57.8
    const val GPU_PER_HOUR = 3.99
    const val GPU_STARTUP_MIN = 0.5
    const val LIP_SYNC_MIN = 4.0
    const val VIGGLE_MIN_5S = 1.6
    const val VIGGLE_COST_5S = 0.13
    const val BASE_LEN = 5.2
    const val MAX_CLIP_SEC = 15.0

    // Photos are pass-through since 2026-11-04 (see [PhotoPricing]); the old fixed prices are gone.

    // Identity LoRA (plans/lora-training.md). Training is an estimate until one real run is measured.
    const val LORA_CANDIDATES = 30
    const val LORA_MIN_KEEP = 20
    const val LORA_PHOTO_MIN = 25
    const val LORA_VIDEO_MIN = 75
    val loraTrainMinutes: Int get() = LORA_PHOTO_MIN + LORA_VIDEO_MIN
    /** Photo + video training at the GPU rate, rounded to cents: (25 + 75) / 60 × 3.99 = $6.65. */
    val loraTrainCost: Double get() = Math.round(loraTrainMinutes / 60.0 * GPU_PER_HOUR * 100) / 100.0

    // ---- Replicate (plans/api.md "Pricing"): $ per output second × whole seconds × takes.
    const val REPLICATE_MIN_SEC = 4
    const val REPLICATE_MAX_SEC = 15

    /** min(15, max(4, ceil(clipSeconds − 0.001))); no clip length = the 9.4 s sample. */
    fun replicateSeconds(clipSeconds: Double?): Int =
        ceil((clipSeconds ?: ClipUse.FULL.seconds) - 0.001).toInt().coerceIn(REPLICATE_MIN_SEC, REPLICATE_MAX_SEC)

    private fun pricePerSec(spec: RenderSpec) = spec.pricePerSec ?: spec.quality.pricePerSec

    /** Rough wall time of one Replicate take, for the progress estimate only (same as the server). */
    fun replicateTakeSeconds(spec: RenderSpec): Double =
        45 + 10.0 * spec.replicateSeconds * when (spec.quality) { Quality.HD -> 1.5; Quality.DRAFT -> 0.6; else -> 1.0 }

    /** "about $0.56 · 7 s" (+ " · 2 takes"): the price line under the quality picker. */
    fun priceLine(spec: RenderSpec): String {
        val takes = if (spec.takes > 1) " · ${spec.takes} takes" else ""
        return "about ${money(totalCost(spec))} · ${spec.replicateSeconds} s$takes"
    }

    /** "Draft · 768P", "Standard · 768P", "HD · 2K", "Edit", "Fast · beta" (Job/Take engineLabel). */
    fun engineLabel(spec: RenderSpec): String = when (spec.engine) {
        Engine.REPLICATE -> "${spec.quality.label} · ${spec.quality.resolution}"
        Engine.VIGGLE -> "Fast · beta"
        Engine.H3 -> "Edit"
    }

    /** "about $0.56 · 7 s" for Render; "about $0.67" for the add-ons (no steps, no start-up). */
    fun optionPriceLine(spec: RenderSpec): String = if (spec.engine == Engine.REPLICATE) priceLine(spec)
        else "about ${money(totalCost(spec))}" + (if (spec.takes > 1) " · ${spec.takes} takes" else "")

    /** Seconds per denoising step for a clip of [len] seconds. */
    fun secPerLen(len: Double): Double = SEC_PER_STEP_5S * (len / BASE_LEN).pow(1.3)

    fun clampSteps(n: Int): Int = n.coerceIn(STEPS_MIN, STEPS_MAX)

    /** Estimated minutes for ONE take. */
    fun estMin(spec: RenderSpec): Double {
        if (spec.engine == Engine.REPLICATE) return replicateTakeSeconds(spec) / 60
        val len = spec.lengthSec
        return if (spec.engine == Engine.VIGGLE) VIGGLE_MIN_5S * (len / BASE_LEN)
        else spec.steps * secPerLen(len) / 60 + GPU_STARTUP_MIN + (if (spec.lipSync) LIP_SYNC_MIN else 0.0)
    }

    /** Estimated dollars for ONE take. */
    fun estCost(spec: RenderSpec): Double {
        if (spec.engine == Engine.REPLICATE) return pricePerSec(spec) * spec.replicateSeconds
        val len = spec.lengthSec
        return if (spec.engine == Engine.VIGGLE) VIGGLE_COST_5S * (len / BASE_LEN)
        else estMin(spec) / 60 * GPU_PER_HOUR
    }

    /** All takes run back to back on the same GPU. */
    fun totalMin(spec: RenderSpec): Double = estMin(spec) * spec.takes.coerceAtLeast(1)
    fun totalCost(spec: RenderSpec): Double = estCost(spec) * spec.takes.coerceAtLeast(1)

    /** "Generate · 10 min · $0.67" (takes > 1 adds "· 2 takes"). */
    fun genLabel(spec: RenderSpec): String {
        if (spec.engine == Engine.REPLICATE) {
            return "Generate · ${spec.replicateSeconds} s · ${money(totalCost(spec))}" + (if (spec.takes > 1) " · ${spec.takes} takes" else "")
        }
        val m = totalMin(spec)
        val time = if (m < 2) "${jsRound(m * 60)}s" else "${jsRound(m)} min"
        val takes = if (spec.takes > 1) " · ${spec.takes} takes" else ""
        return "Generate · $time · ${money(totalCost(spec))}$takes"
    }

    /** The hint under the steps slider. */
    fun stepsDelta(spec: RenderSpec): String {
        if (spec.steps == STEPS_DEFAULT) return "Same quality as 15 or 20 steps in testing, for less time."
        val d = (spec.steps - STEPS_DEFAULT) * secPerLen(spec.lengthSec) / 60
        val c = d / 60 * GPU_PER_HOUR
        val sign = if (d > 0) "+" else "−"
        val tail = if (spec.steps > STEPS_DEFAULT) " · no visible gain in testing" else " · may lose detail"
        return "$sign${toFixed(kotlin.math.abs(d), 1)} min · $sign${money(kotlin.math.abs(c))} vs 10 steps$tail"
    }

    /** Badge next to the steps value. */
    fun stepsBadge(steps: Int, loud: Boolean = false): String = when {
        steps == STEPS_DEFAULT -> if (loud) "RECOMMENDED" else "Recommended"
        steps > STEPS_DEFAULT -> if (loud) "TAKES LONGER" else "Rarely worth it"
        else -> if (loud) "TOO FEW?" else "Below tested range"
    }

    /** Clip length option on the New video screen: "First 5.2s · ~10m · $0.67" (no lip sync). */
    fun sourceOption(use: ClipUse, steps: Int, clipSeconds: Double? = null): String {
        val spec = RenderSpec(use = use, steps = steps, clipSeconds = clipSeconds)
        val m = steps * secPerLen(spec.lengthSec) / 60 + GPU_STARTUP_MIN
        val c = m / 60 * GPU_PER_HOUR
        val label = if (clipSeconds == null) use.label else if (use == ClipUse.FIRST) "First ${trimNum(spec.lengthSec)}s" else "Full ${trimNum(spec.lengthSec)}s"
        return "$label · ~${jsRound(m)}m · ${money(c)}"
    }

    private fun trimNum(v: Double): String = toFixed(v, 1).removeSuffix(".0")

    /** How many 10-step 5.2 s videos the balance covers (the server's `videos` field). */
    fun videosLeft(balance: Double, spec: RenderSpec = RenderSpec()): Int = floor(balance / estCost(spec.copy(takes = 1))).toInt()

    /** A typical video for the Credits card: a Draft render of the 9.4 s sample. */
    val typicalVideo: RenderSpec get() = RenderSpec(engine = Engine.REPLICATE, quality = Quality.DRAFT)
    /** How many typical (Draft) videos [balance] covers. */
    fun draftVideosLeft(balance: Double): Int = if (balance <= 0) 0 else floor(balance / estCost(typicalVideo)).toInt()

    /** Seconds of GPU time, used by the mock to drive progress. */
    fun totalSeconds(spec: RenderSpec): Double = totalMin(spec) * 60

    /** JavaScript `'$' + v.toFixed(2)`. */
    fun money(v: Double): String = "$" + toFixed(v, 2)

    /** JavaScript Number.prototype.toFixed: rounds the exact binary value half-up. */
    fun toFixed(v: Double, digits: Int): String {
        val neg = v < 0
        val s = BigDecimal(kotlin.math.abs(v)).setScale(digits, RoundingMode.HALF_UP).toPlainString()
        return if (neg && s.any { it in '1'..'9' }) "-$s" else s
    }

    /** JavaScript Math.round: halves round towards +infinity. */
    fun jsRound(v: Double): Long = floor(v + 0.5).toLong()
}

/** "05:35" countdowns, like the prototype's fmt(). */
fun formatClock(seconds: Double): String {
    val s = Pricing.jsRound(seconds.coerceAtLeast(0.0))
    return "%02d:%02d".format(s / 60, s % 60)
}

/** "00:01:35" time-code style used for finished jobs. */
fun formatTimecode(seconds: Double): String {
    val s = Pricing.jsRound(seconds.coerceAtLeast(0.0))
    return "%02d:%02d:%02d".format(s / 3600, (s % 3600) / 60, s % 60)
}

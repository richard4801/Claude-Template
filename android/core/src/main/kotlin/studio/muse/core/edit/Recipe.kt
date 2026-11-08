package studio.muse.core.edit

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlin.math.abs
import kotlin.math.roundToInt

/*
 * "Recreate this edit" (plans/recreate-edit.md, APPROVED), build phase 1: a reference video broken into its edit recipe.
 * The fields follow the plan's list (slots with their shot brief, rig, move, speed and transform; text; transitions; the
 * grade; the beat map; the sound). WS1 owns the server's `recipe` schema; until it lands this is read leniently (unknown
 * fields ignored, missing optional ones null) so switching to the server's exact names is a mapping in [RecipeJson] only.
 * Every element carries its confidence, 0–1.
 */

/** One shot of the reference: where it sits, what it shows and how the camera moves. */
data class RecipeSlot(
    val startSec: Double,
    val endSec: Double,
    /** "Close-up", "Medium", "Wide"… */
    val shotSize: String? = null,
    /** "Eye level", "Low", "High"… */
    val angle: String? = null,
    /** What happens, for the slot's brief ("Turns to camera with a smile"). */
    val brief: String? = null,
    /** The camera move ("Push in", "Handheld", "Whip pan"); null = locked off. */
    val move: String? = null,
    /** A speed ramp or freeze ("Ramp 1× → 0.4×", "Freeze"); null = normal speed. */
    val speed: String? = null,
    /** Zoom, shake or push in post ("Zoom 1.0 → 1.2", "Shake"); null = none. */
    val transform: String? = null,
    val confidence: Double = 1.0,
) {
    val lengthSec: Double get() = (endSec - startSec).coerceAtLeast(0.0)
}

/** A text or caption on screen. */
data class RecipeText(
    val startSec: Double,
    val endSec: Double,
    val text: String,
    /** "Top", "Middle", "Lower third"… */
    val position: String? = null,
    /** The nearest font and style we have ("Bold sans, white with a black box"). */
    val style: String? = null,
    /** In / out animation ("Pop in", "Typewriter"). */
    val animation: String? = null,
    val confidence: Double = 1.0,
)

/** What joins two shots. [kind] is null when it couldn't be told (flagged for review). */
data class RecipeTransition(val atSec: Double, val kind: String?, val confidence: Double = 1.0)

/** The grade, as the Look it becomes: a name and its palette, darkest first ("#RRGGBB"). */
data class RecipeGrade(val name: String, val swatches: List<String> = emptyList(), val confidence: Double = 1.0)

/** The sound's beat map: tempo, every beat and the strong ones (seconds). */
data class RecipeBeats(val bpm: Double?, val beats: List<Double> = emptyList(), val strong: List<Double> = emptyList(), val confidence: Double = 1.0)

data class Recipe(
    val version: Int = 1,
    val title: String? = null,
    val durationSec: Double,
    val slots: List<RecipeSlot>,
    val texts: List<RecipeText> = emptyList(),
    val transitions: List<RecipeTransition> = emptyList(),
    val grade: RecipeGrade? = null,
    val beats: RecipeBeats? = null,
    /** The sound to attach when posting ("Use this sound"); its name when known. */
    val sound: String? = null,
) {
    /** The cut points between shots. */
    val cuts: List<Double> get() = slots.drop(1).map { it.startSec }

    /** Pacing: the average shot and cuts per minute. */
    val averageShotSec: Double get() = if (slots.isEmpty()) 0.0 else slots.sumOf { it.lengthSec } / slots.size
    val cutsPerMinute: Double get() = if (durationSec <= 0) 0.0 else cuts.size * 60.0 / durationSec

    /** The share of cuts that land within [toleranceSec] of a beat (null without a beat map). */
    fun cutsOnBeat(toleranceSec: Double = 0.06): Double? {
        val b = beats?.beats?.takeIf { it.isNotEmpty() } ?: return null
        val c = cuts
        if (c.isEmpty()) return null
        return c.count { cut -> b.any { abs(it - cut) <= toleranceSec } }.toDouble() / c.size
    }

    /** Elements under [threshold] confidence: the parts worth a look before building. */
    fun lowConfidence(threshold: Double = RecipeConfidence.LOW): Int =
        slots.count { it.confidence < threshold } + texts.count { it.confidence < threshold } +
            transitions.count { it.confidence < threshold || it.kind == null } + (if ((grade?.confidence ?: 1.0) < threshold) 1 else 0)
}

object RecipeConfidence {
    /** Below this an element is marked "Check". */
    const val LOW = 0.6

    /** "92%". */
    fun percent(c: Double): String = "${(c.coerceIn(0.0, 1.0) * 100).roundToInt()}%"
}

/** The recipe's JSON, read leniently (see the file comment). */
object RecipeJson {
    private val json = Json { ignoreUnknownKeys = true }

    fun parse(text: String): Recipe = parse(json.parseToJsonElement(text))

    fun parse(el: JsonElement): Recipe {
        val o = el as? JsonObject ?: throw IllegalArgumentException("recipe is not an object")
        val slots = o.arr("slots").mapNotNull { (it as? JsonObject)?.slot() }
        require(slots.isNotEmpty()) { "recipe has no slots" }
        return Recipe(
            version = o.num("version")?.toInt() ?: 1,
            title = o.str("title"),
            durationSec = o.num("durationSec") ?: slots.maxOf { it.endSec },
            slots = slots,
            texts = o.arr("texts").mapNotNull { (it as? JsonObject)?.text() },
            transitions = o.arr("transitions").mapNotNull { t ->
                (t as? JsonObject)?.let { RecipeTransition(it.num("atSec") ?: return@mapNotNull null, it.str("kind"), it.num("confidence") ?: 1.0) }
            },
            grade = o.obj("grade")?.let { g -> g.str("name")?.let { RecipeGrade(it, g.arr("swatches").mapNotNull { s -> (s as? JsonPrimitive)?.content }, g.num("confidence") ?: 1.0) } },
            beats = o.obj("beats")?.let { b -> RecipeBeats(b.num("bpm"), b.nums("beats"), b.nums("strong"), b.num("confidence") ?: 1.0) },
            sound = o.str("sound"),
        )
    }

    private fun JsonObject.slot(): RecipeSlot? = RecipeSlot(
        startSec = num("startSec") ?: return null, endSec = num("endSec") ?: return null,
        shotSize = str("shotSize"), angle = str("angle"), brief = str("brief"), move = str("move"), speed = str("speed"), transform = str("transform"),
        confidence = num("confidence") ?: 1.0,
    )

    private fun JsonObject.text(): RecipeText? = RecipeText(
        startSec = num("startSec") ?: return null, endSec = num("endSec") ?: return null, text = str("text") ?: return null,
        position = str("position"), style = str("style"), animation = str("animation"), confidence = num("confidence") ?: 1.0,
    )

    private fun JsonObject.str(k: String): String? = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
    private fun JsonObject.num(k: String): Double? = (this[k] as? JsonPrimitive)?.doubleOrNull
    private fun JsonObject.obj(k: String): JsonObject? = this[k] as? JsonObject
    private fun JsonObject.arr(k: String): List<JsonElement> = (this[k] as? JsonArray).orEmpty()
    private fun JsonObject.nums(k: String): List<Double> = arr(k).mapNotNull { (it as? JsonPrimitive)?.doubleOrNull }
}

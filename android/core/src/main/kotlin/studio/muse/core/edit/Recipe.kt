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
 * [RecipeJson] reads WS1's `muse.recipe/1` (plans/api.md "Recreate this edit"; the fixture
 * server/api/test/fixtures/recipe-v1.json) into this view model: ids become words ("cu" → "Close-up", "zoom_in" →
 * "Zoom in"), unknown fields are ignored and missing optional ones stay null. Every element carries its confidence, 0–1.
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
    /** The body pose was read (keypoints only, never the reference's pixels): it guides a generated shot. */
    val poseRead: Boolean = false,
    /** The server's slot id ("s1"), for the fill, estimate and apply calls (phases 2–3). */
    val id: String = "",
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

/** Something in the reference MUSE can't recreate yet. */
data class RecipeGap(val what: String, val note: String? = null, val atSec: Double? = null)

/** The analysis around a recipe (`Reference`): its state and step while it runs, its recipe once ready. */
data class RecipeReference(
    val id: String,
    val name: String,
    /** "analyzing" | "ready" | "failed" | "expired". */
    val state: String,
    val progress: Int = 0,
    val phase: String? = null,
    val error: String? = null,
    val recipe: Recipe? = null,
)

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
    /** Claude's one-line summary of the edit, once it has read the contact sheet. */
    val summary: String? = null,
    /** What MUSE can't recreate yet ("Body poses · Not read yet"). */
    val gaps: List<RecipeGap> = emptyList(),
    /** The reference's shape ("9:16"), when known. */
    val aspect: String? = null,
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

/** WS1's `muse.recipe/1` and its `Reference`, read into [Recipe] (see the file comment). */
object RecipeJson {
    /** A text item whose words weren't read (they stay null until OCR is approved). */
    const val UNREAD_WORDS = "Text, words not read yet"
    private val json = Json { ignoreUnknownKeys = true }

    /** A `GET /v1/recreate/references/{id}` response (or a bare recipe, which reads as a ready reference). */
    fun reference(text: String): RecipeReference = reference(json.parseToJsonElement(text))

    fun reference(el: JsonElement): RecipeReference {
        val o = el as? JsonObject ?: throw IllegalArgumentException("reference is not an object")
        if (o.str("schema") != null) return RecipeReference(o.str("id") ?: "", o.str("summary") ?: "Reference", "ready", 100, recipe = parse(o))
        val name = o.str("name") ?: "Reference"
        return RecipeReference(
            id = o.str("id") ?: "", name = name, state = o.str("state") ?: "analyzing", progress = o.num("progress")?.toInt() ?: 0,
            phase = o.str("phase"), error = o.str("error"), recipe = o.obj("recipe")?.let { parse(it, name) },
        )
    }

    fun parse(text: String): Recipe = parse(json.parseToJsonElement(text))

    fun parse(el: JsonElement, title: String? = null): Recipe {
        val o = el as? JsonObject ?: throw IllegalArgumentException("recipe is not an object")
        val slots = o.arr("slots").mapNotNull { (it as? JsonObject)?.slot() }.sortedBy { it.startSec }
        require(slots.isNotEmpty()) { "recipe has no slots" }
        val sound = o.obj("sound")
        return Recipe(
            version = o.str("schema")?.substringAfterLast('/')?.toIntOrNull() ?: 1,
            title = title ?: o.str("summary"),
            durationSec = o.obj("source")?.num("durationSec") ?: slots.maxOf { it.endSec },
            slots = slots,
            texts = o.arr("text").mapNotNull { (it as? JsonObject)?.text() },
            transitions = o.arr("transitions").mapNotNull { t ->
                (t as? JsonObject)?.let { RecipeTransition(it.num("atSec") ?: return@mapNotNull null, transitionKind(it.str("kind")), it.num("confidence") ?: 1.0) }
            },
            grade = o.obj("grade")?.let { g ->
                val sw = g.arr("swatches").mapNotNull { s -> (s as? JsonPrimitive)?.takeIf { it.isString }?.content }
                RecipeGrade(g.obj("look")?.str("label") ?: "Its own grade", sw, g.num("confidence") ?: 1.0)
            },
            beats = sound?.let { b -> RecipeBeats(b.num("bpm"), b.nums("beats"), b.nums("strong"), b.num("confidence") ?: 1.0) },
            sound = when {
                sound != null -> "Original sound" + (sound.num("bpm")?.let { ", ${it.roundToInt()} BPM" } ?: "")
                o.obj("source")?.bool("hasAudio") == false -> null
                else -> null
            },
            summary = o.str("summary"),
            gaps = o.arr("gaps").mapNotNull { (it as? JsonObject)?.let { g -> g.str("what")?.let { w -> RecipeGap(w, g.str("note"), g.num("atSec")) } } },
            aspect = o.obj("source")?.str("aspect"),
        )
    }

    private fun JsonObject.slot(): RecipeSlot? {
        val brief = obj("brief"); val rig = obj("rig"); val cam = obj("camera"); val speed = obj("speed")
        val action = listOfNotNull(brief?.str("subject"), brief?.str("action")).joinToString(" ").ifBlank { null }
        val where = brief?.str("location")?.let { "in $it" }
        val line = listOfNotNull(action, where).joinToString(" ").ifBlank { null }?.replaceFirstChar { it.uppercase() }
        val motion = cam?.str("motion")
        val shake = (cam?.num("shake") ?: 0.0) > 0.15
        return RecipeSlot(
            startSec = num("startSec") ?: return null, endSec = num("endSec") ?: return null,
            shotSize = (brief?.str("shotSize") ?: rig?.str("shotSize"))?.let(::shotSizeLabel),
            angle = (brief?.str("angle") ?: rig?.str("height"))?.let(::angleLabel),
            brief = listOfNotNull(line, brief?.str("notes")?.replaceFirstChar { it.uppercase() }).joinToString(". ").ifBlank { null },
            move = motion?.takeIf { it != "static" && it != "shake" }?.let(::words),
            speed = speed?.str("ramp")?.takeIf { it != "none" }?.let { when (it) { "speed_up" -> "Speeds up"; "slow_down" -> "Slows down"; "freeze" -> "Freeze"; else -> "Speed ramp" } },
            transform = if (shake || motion == "shake") "Shake" else null,
            confidence = num("confidence") ?: 1.0,
            poseRead = obj("pose")?.str("status") == "done",
            id = str("id") ?: "",
        )
    }

    private fun JsonObject.text(): RecipeText? {
        val box = obj("box")
        val cy = box?.let { (it.num("y") ?: 0.0) + (it.num("h") ?: 0.0) / 2 }
        val font = when (str("fontId")) { "serif" -> "Serif"; "rounded" -> "Rounded sans"; "condensed" -> "Condensed sans"; "mono" -> "Monospaced"; "marker" -> "Marker"; null -> null; else -> "Sans" }
        val anim = listOfNotNull(str("animIn")?.takeIf { it != "cut" }?.let { words(it) + " in" }, str("animOut")?.takeIf { it != "cut" }?.let { words(it) + " out" }).joinToString(", ").ifBlank { null }
        return RecipeText(
            startSec = num("startSec") ?: return null, endSec = num("endSec") ?: return null,
            // Words stay null until OCR is approved (Claude reads them from the contact sheet).
            text = str("words") ?: UNREAD_WORDS,
            position = cy?.let { if (it < .34) "Top" else if (it < .62) "Middle" else "Lower third" },
            style = listOfNotNull(font, str("color")?.let(::colorName)).joinToString(", ").ifBlank { null },
            animation = anim,
            confidence = num("confidence") ?: 1.0,
        )
    }

    /** `cut`… → "Cut"; `unknown` → null (flagged). */
    private fun transitionKind(k: String?): String? = when (k) { null, "unknown" -> null; "crossfade" -> "Crossfade"; else -> words(k) }

    private fun shotSizeLabel(id: String): String = when (id) {
        "ecu" -> "Extreme close-up"; "cu" -> "Close-up"; "mcu" -> "Medium close-up"; "ms", "medium", "mid" -> "Medium"
        "mws", "cowboy", "mls" -> "Medium wide"; "ws", "wide", "ls", "full" -> "Wide"; "ews", "els" -> "Extreme wide"; else -> words(id)
    }

    private fun angleLabel(id: String): String = when (id) {
        "eye" -> "Eye level"; "low" -> "Low angle"; "high" -> "High angle"; "overhead", "top" -> "Overhead"; "ground" -> "Ground level"
        "dutch" -> "Dutch angle"; else -> words(id)
    }

    private fun colorName(hex: String): String = when (hex.uppercase()) { "#FFFFFF" -> "white"; "#000000" -> "black"; else -> hex.uppercase() }

    /** `zoom_in` → "Zoom in". */
    private fun words(id: String): String = id.replace('_', ' ').replaceFirstChar { it.uppercase() }

    private fun JsonObject.str(k: String): String? = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
    private fun JsonObject.num(k: String): Double? = (this[k] as? JsonPrimitive)?.doubleOrNull
    private fun JsonObject.bool(k: String): Boolean? = (this[k] as? JsonPrimitive)?.content?.toBooleanStrictOrNull()
    private fun JsonObject.obj(k: String): JsonObject? = this[k] as? JsonObject
    private fun JsonObject.arr(k: String): List<JsonElement> = (this[k] as? JsonArray).orEmpty()
    private fun JsonObject.nums(k: String): List<Double> = arr(k).mapNotNull { (it as? JsonPrimitive)?.doubleOrNull }
}

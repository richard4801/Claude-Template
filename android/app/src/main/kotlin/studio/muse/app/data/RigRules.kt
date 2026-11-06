package studio.muse.app.data

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull

/**
 * Demo mode's rig check: a port of the server's pure rule set (server/api/src/suite/rigcheck.ts, plans/video-composer.md
 * "Rig check"), so the demo shows the same warnings, reasons and one-tap fixes as a real studio. Labels come from the
 * bundled camera catalog (the server's own answer). Keep in step with rigcheck.ts; RigCheckTest replays the server's
 * output for a set of shots (test/resources/suite/suite_rigcheck_cases.json).
 */
object RigRules {
    private val DEEP_FOCUS_BODIES = setOf("camcorder", "phone", "webcam", "security_cam")
    private val SHALLOW_APERTURES = setOf("f1.2", "f1.4", "f2", "f2.8")
    private val CLOSE_SIZES = setOf("cu", "ecu")
    private val WORM_CLOSE_SIZES = setOf("mcu", "cu", "ecu")

    private val LOOK_TONES = mapOf(
        "phone_hdr" to listOf("saturated"), "portrait_negative" to listOf("warm"), "tungsten_stock" to listOf("cold"), "slide_film" to listOf("saturated"),
        "bw_film" to listOf("mono"), "bleach_bypass" to listOf("muted"), "cross_process" to listOf("saturated"), "reversal_16" to listOf("saturated"),
        "faded_print" to listOf("muted"),
    )
    private val PALETTE_TONES = mapOf(
        "bleached_warm" to listOf("warm", "muted"), "hyper_neon" to listOf("saturated"), "teal_orange" to listOf("saturated"), "sodium_decay" to listOf("warm"),
        "cold_steel" to listOf("cold", "muted"), "bleach_bypass" to listOf("muted"), "classic_bw" to listOf("mono"), "muted_earth" to listOf("muted"),
        "golden_warmth" to listOf("warm"), "moody_blue" to listOf("cold"), "vintage_fade" to listOf("muted"), "cyber_magenta" to listOf("saturated"),
        "desert_sand" to listOf("warm"), "retro_80s" to listOf("saturated"), "nineties_mall" to listOf("saturated", "warm"), "y2k_gloss" to listOf("cold"),
        "candy_pop" to listOf("saturated"), "autumn" to listOf("warm"), "winter_frost" to listOf("cold"), "sepia" to listOf("mono"),
        "kodachrome_like" to listOf("saturated"), "matte_film" to listOf("muted"),
    )
    private val OPPOSITE = listOf("mono" to "saturated", "mono" to "warm", "mono" to "cold", "warm" to "cold", "saturated" to "muted")

    private class Words(val re: Regex, val ids: List<String>)
    private fun w(re: String, vararg ids: String) = Words(Regex(re), ids.toList())

    /** What a prompt says about the camera; the first id is the fix. More specific phrases first. */
    private val MOVE_WORDS = listOf(
        w("\\bwhip[- ]?pans?\\b", "whip_pan"),
        w("\\bcrash[- ]?zooms?\\b", "crash_zoom"),
        w("\\b(dolly[- ]?zoom|vertigo (shot|effect))\\b", "dolly_zoom"),
        w("\\b(rack(s|ing)? focus|focus (pull|rack)s?|pulls? focus)\\b", "rack_focus"),
        w("\\b(360|full circle|all the way around)\\b", "orbit_360", "bullet_time"),
        w("\\b(orbit(s|ing)?|circles? (around|round)|arcs? (around|round))\\b", "orbit_right", "orbit_left", "orbit_360", "top_down_spin", "bullet_time"),
        w("\\bfpv\\b", "fpv"),
        w("\\b(drone|aerial|fly ?over|flies over)\\b", "drone_reveal", "flyover", "fpv"),
        w("\\b(pull(s|ing)? back|dolly(ing)? out|dollies out|backs? away)\\b", "dolly_out", "drone_reveal", "zoom_out"),
        w("\\b(push(es|ing)? in|dolly(ing)? in|dollies in|moves? in (on|toward|towards))\\b", "dolly_in", "micro_push", "dutch_push", "zoom_in"),
        w("\\bzoom(s|ing)? in\\b", "zoom_in", "crash_zoom", "dolly_zoom"),
        w("\\bzoom(s|ing)? out\\b", "zoom_out", "dolly_zoom"),
        w("\\bpan(s|ning)? (to the )?left\\b", "pan_left", "whip_pan"),
        w("\\bpan(s|ning)? (to the )?right\\b", "pan_right", "whip_pan"),
        w("\\btilt(s|ing)? up\\b", "tilt_up", "crane_up"),
        w("\\btilt(s|ing)? down\\b", "tilt_down", "crane_up"),
        w("\\b(crane(s|ing)? (up|over)|jib(s|bing)? up|camera rises)\\b", "crane_up", "pedestal_up", "crane_overhead", "drone_reveal"),
        w("\\b(crane(s|ing)? down|jib(s|bing)? down|camera (descends|lowers))\\b", "crane_down", "pedestal_down"),
        w("\\b(follow(s|ing)? (her|him|them|the|behind)|tracking shot|track(s|ing)? (with|alongside|behind))\\b",
            "follow", "track_side", "lead", "steadicam", "handheld", "handheld_run", "selfie", "fpv"),
        w("\\bselfie\\b", "selfie", "handheld"),
        w("\\b(handheld|hand-held|shaky cam)\\b", "handheld", "handheld_run", "selfie"),
        w("\\b(static|locked[- ]off|on a tripod|still camera|camera (stays|is) still)\\b", "static", "rack_focus", "micro_push"),
    )
    private val ANGLE_WORDS = listOf(
        w("\\bworm[’']?s[- ]eye\\b", "worm", "ground"),
        w("\\b(bird[’']?s[- ]eye|top[- ]down|overhead (shot|view))\\b", "overhead"),
        w("\\b(low[- ]angle|from below|looking up at)\\b", "low", "worm", "ground", "hip"),
        w("\\b(high[- ]angle|from above|looking down (at|on))\\b", "high", "overhead"),
        w("\\beye[- ]level\\b", "eye", "shoulder"),
    )
    private val SIZE_WORDS = listOf(
        w("\\bextreme close[- ]?ups?\\b", "ecu", "insert", "cu"),
        w("\\b(close[- ]?ups?|closeups?)\\b", "cu", "ecu", "mcu", "insert"),
        w("\\b(extreme wide|establishing shot)\\b", "els", "ls"),
        w("\\bwide shot\\b", "ls", "els", "full"),
    )
    private val REVEAL_WORDS = Regex("\\b(open(s|ing)? on|start(s|ing)? on|begin(s|ning)? on|reveal(s|ed|ing)?|comes? into view|to find (her|him|them))\\b")
    private val NO_REVEAL = setOf("static", "micro_push", "dolly_in", "dutch_push", "zoom_in", "crash_zoom", "crane_up", "crane_overhead", "snorricam", "selfie", "top_down_spin", "bullet_time")
    private val NEGATED = Regex("\\b(no|not|never|without|don[’']?t|doesn[’']?t|avoid)\\b( (a|an|any|the))? [a-z’'-]+( [a-z’'-]+)?")

    /** Prompt words, lower-cased, with the composer's own #tokens (option labels) and any negated phrase taken out. */
    fun promptWords(prompt: String, cat: CameraCatalog): String {
        var p = " ${prompt.lowercase().replace('“', '"').replace('”', '"')} "
        val labels = (cat.moves.map { it.label } + cat.heights.map { it.label } + cat.shotSizes.map { it.label }).map { it.lowercase() }.sortedByDescending { it.length }
        for (l in labels) p = p.split("#$l").joinToString(" ")
        return NEGATED.replace(p, " ")
    }

    private fun cam(c: JsonObject) = JsonObject(mapOf("camera" to c))
    private fun obj(vararg pairs: Pair<String, JsonElement>) = JsonObject(mapOf(*pairs))
    private fun setMove(id: String) = cam(obj("move" to obj("id" to JsonPrimitive(id))))
    private fun label(list: List<SuiteOption>, id: String?) = list.firstOrNull { it.id == id }?.label ?: id.orEmpty()
    private fun survivor(list: List<SuiteOption>, id: String?) = id?.let { list.firstOrNull { o -> o.id == it }?.mergedInto ?: it }

    /** The clashes in a shot, most serious first: [camera] is the request's camera (the preset underneath, as the shot compiles). */
    fun check(prompt: String?, camera: JsonElement?, speaking: Boolean, cat: CameraCatalog): List<SuiteRigWarning> {
        val out = mutableListOf<SuiteRigWarning>()
        val c = resolve(camera as? JsonObject, cat)
        fun str(vararg path: String): String? {
            var e: JsonElement? = c
            for (k in path) e = (e as? JsonObject)?.get(k)
            return (e as? JsonPrimitive)?.takeIf { it.isString }?.content
        }
        val body = survivor(cat.bodies, str("rig", "body"))
        val aperture = str("rig", "aperture")
        val focal = ((c?.get("rig") as? JsonObject)?.get("focalMm") as? JsonPrimitive)?.intOrNull
        val height = str("angle", "height")
        val size = str("angle", "shotSize")
        val move = cat.move(str("move", "id"))
        val mix = cat.move(str("mix", "id"))
        val moves = listOfNotNull(move, mix)
        val words = prompt?.takeIf { it.isNotEmpty() }?.let { promptWords(it, cat) }.orEmpty()

        // 1 · Deep-focus cameras can't show shallow focus or a focus pull.
        if (body != null && body in DEEP_FOCUS_BODIES) {
            val rack = moves.firstOrNull { it.id == "rack_focus" }
            val shallow = aperture != null && aperture in SHALLOW_APERTURES
            if (rack != null || shallow) {
                val what = if (rack != null) "the rack focus won’t show" else "${label(cat.apertures, aperture)} won’t blur the background"
                out += SuiteRigWarning("deep_focus", "warn", "${label(cat.bodies, body)} keeps everything in focus, so $what",
                    SuiteRigFix("Use Cinema camera", cam(obj("rig" to obj("body" to JsonPrimitive("cinema_digital"))))),
                    if (rack != null) SuiteRigFix("Drop the rack focus", dropMove("rack_focus", c!!)) else SuiteRigFix("Use f/11", cam(obj("rig" to obj("aperture" to JsonPrimitive("f11"))))))
            }
        }
        // 2 · A wide lens this close distorts the face.
        if (focal != null && focal <= 24 && size != null && size in CLOSE_SIZES && str("rig", "lens") != "fisheye") {
            out += SuiteRigWarning("wide_close", "warn", "A ${focal}mm lens this close stretches the face",
                SuiteRigFix("Use 85mm", cam(obj("rig" to obj("focalMm" to JsonPrimitive(85))))), SuiteRigFix("Medium shot", cam(obj("angle" to obj("shotSize" to JsonPrimitive("ms"))))))
        }
        // 3 · From the ground you can't frame chest-up.
        if (height == "worm" && size != null && size in WORM_CLOSE_SIZES) {
            out += SuiteRigWarning("worm_close", "warn", "Worm’s-eye from the ground can’t frame a ${label(cat.shotSizes, size).lowercase()}",
                SuiteRigFix("Low angle", cam(obj("angle" to obj("height" to JsonPrimitive("low"))))), SuiteRigFix("Full body", cam(obj("angle" to obj("shotSize" to JsonPrimitive("full"))))))
        }
        // 4 · Looks that pull the colour opposite ways.
        val look = survivor(cat.looks, str("rig", "look"))
        val palette = survivor(cat.palettes, str("palette", "preset"))
        if (look != null && palette != null && look != palette) {
            val a = LOOK_TONES[look].orEmpty()
            val b = PALETTE_TONES[palette].orEmpty()
            val hit = OPPOSITE.firstOrNull { (x, y) -> (x in a && y in b) || (y in a && x in b) }
            if (hit != null) {
                val l = label(cat.looks, look)
                val p = label(cat.palettes, palette)
                val reason = if (hit.first == "mono") (if ("mono" in a) "$l is black and white, so $p won’t show" else "$p is black and white, so $l won’t show")
                else "$l and $p pull the colour opposite ways"
                out += SuiteRigWarning("look_clash", "tip", reason,
                    SuiteRigFix("Keep $l", cam(obj("palette" to obj("preset" to JsonPrimitive("naturalistic"))))), SuiteRigFix("Keep $p", cam(obj("rig" to obj("look" to JsonPrimitive("digital_clean"))))))
            }
        }
        if (words.isNotEmpty()) {
            // 5 · The prompt describes a different move, angle or size from the chips.
            val mw = MOVE_WORDS.firstOrNull { it.re.containsMatchIn(words) }
            if (mw != null && move != null && moves.none { it.id in mw.ids }) {
                cat.move(mw.ids[0])?.let { to ->
                    out += SuiteRigWarning("prompt_move", "warn", "The prompt says “${mw.re.find(words)?.value.orEmpty()}” but the move is ${move.label}", SuiteRigFix("Use ${to.label}", setMove(to.id)))
                }
            }
            val aw = ANGLE_WORDS.firstOrNull { it.re.containsMatchIn(words) }
            if (aw != null && height != null && height !in aw.ids) {
                out += SuiteRigWarning("prompt_angle", "warn", "The prompt says “${aw.re.find(words)?.value.orEmpty()}” but the angle is ${label(cat.heights, height)}",
                    SuiteRigFix("Use ${label(cat.heights, aw.ids[0])}", cam(obj("angle" to obj("height" to JsonPrimitive(aw.ids[0]))))))
            }
            val sw = SIZE_WORDS.firstOrNull { it.re.containsMatchIn(words) }
            if (sw != null && size != null && size !in sw.ids) {
                out += SuiteRigWarning("prompt_size", "tip", "The prompt says “${sw.re.find(words)?.value.orEmpty()}” but the framing is ${label(cat.shotSizes, size)}",
                    SuiteRigFix("Use ${label(cat.shotSizes, sw.ids[0])}", cam(obj("angle" to obj("shotSize" to JsonPrimitive(sw.ids[0]))))))
            }
            // 6 · "Open on X / reveal" needs a move that starts away from the subject.
            if (move != null && REVEAL_WORDS.containsMatchIn(words) && move.id in NO_REVEAL && !(mix != null && mix.id !in NO_REVEAL)) {
                revealFor(move.id, cat)?.let { to ->
                    val rise = move.id == "crane_up" || move.id == "crane_overhead"
                    out += SuiteRigWarning("no_reveal", "warn", "The prompt opens on something else, but ${move.label} ${if (rise) "starts at the subject" else "can’t reveal"}",
                        SuiteRigFix("Use ${to.label}", setMove(to.id)))
                }
            }
        }
        // 7 · Speaking shots need a move that won't fight lip sync.
        val bad = if (speaking) moves.firstOrNull { !it.talkSafe } else null
        if (bad != null) {
            val isMix = bad === mix
            out += SuiteRigWarning("talk_move", "warn", "${bad.label} can fight lip sync on a speaking shot",
                if (isMix) SuiteRigFix("Drop ${bad.label}", cam(obj("mix" to JsonNull))) else SuiteRigFix("Lock it off", setMove("static")),
                if (bad === move) SuiteRigFix("Handheld UGC", setMove("handheld")) else null)
        }
        // A reveal clash already names the move to use, so a second "use this move" line would only compete with it.
        return if (out.any { it.id == "no_reveal" }) out.filter { it.id != "prompt_move" } else out
    }

    /** The camera with its preset merged underneath (the user's choices win), like the server's resolvePreset. */
    private fun resolve(c: JsonObject?, cat: CameraCatalog): JsonObject? {
        val id = (c?.get("preset") as? JsonPrimitive)?.content ?: return c
        val p = cat.presets.firstOrNull { it.id == id }?.spec ?: return c
        return buildJsonObject {
            for (k in (p.keys + c.keys)) {
                val a = p[k]; val b = c[k]
                put(k, if (a is JsonObject && b is JsonObject && k != "move" && k != "mix") JsonObject(a + b) else b ?: a!!)
            }
        }
    }

    /** Take one move out without letting a preset put another back: the mix is removed, or the main move becomes the mix / static. */
    private fun dropMove(id: String, c: JsonObject): JsonObject {
        val mix = c["mix"] as? JsonObject
        if ((mix?.get("id") as? JsonPrimitive)?.content == id) return cam(obj("mix" to JsonNull))
        if (mix != null) return cam(obj("move" to mix, "mix" to JsonNull))
        return setMove("static")
    }

    /** The reveal that fits: a rise when the move was a rise ("Rise to reveal" once it exists, else tilt up), else a pull back. */
    private fun revealFor(id: String, cat: CameraCatalog): SuiteMoveOption? {
        val rise = cat.moves.firstOrNull { Regex("^rise.*reveal|reveal.*rise").containsMatchIn(it.id) }
        return if (id == "crane_up" || id == "crane_overhead") rise ?: cat.move("tilt_up") else cat.move("dolly_out")
    }
}

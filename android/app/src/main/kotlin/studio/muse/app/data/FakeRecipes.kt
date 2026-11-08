package studio.muse.app.data

import studio.muse.core.edit.Recipe
import studio.muse.core.edit.RecipeJson

/**
 * "Recreate this edit" (plans/recreate-edit.md): demo mode's recipe, in WS1's `muse.recipe/1` (plans/api.md), read by
 * [RecipeJson] like the server's.
 */
object FakeRecipes {
    /** A 15 s café "day in my life" edit at 118 BPM: seven shots cut on the beat, three captions, a whip and a flash, and a warm film grade. */
    fun cafeTrend(): Recipe = RecipeJson.parse(cafeTrendJson())

    /** The same recipe as the server would send it. */
    fun cafeTrendJson(): String {
        val beat = 60.0 / 118
        val beats = generateSequence(0.21) { it + beat }.takeWhile { it < 15.0 }.map { Math.round(it * 1000) / 1000.0 }.toList()
        val strong = beats.filterIndexed { i, _ -> i % 4 == 0 }
        // Cuts land on beats 4, 8, 12, 16, 20 and 24.
        val cuts = listOf(0.0) + listOf(4, 8, 12, 16, 20, 24).map { beats[it] } + 15.0
        // (size id, angle id, subject, action, location, camera motion, speed ramp, confidence)
        data class Sh(val size: String, val angle: String, val action: String, val where: String?, val motion: String, val ramp: String, val conf: Double)
        val shots = listOf(
            Sh("cu", "eye", "hands set a flat white on the counter", null, "zoom_in", "none", .94),
            Sh("ms", "eye", "she looks up from her phone and smiles", "a café", "mixed", "none", .91),
            Sh("ws", "low", "she walks through the door into the light", null, "pan", "none", .88),
            Sh("cu", "high", "the latte art, the cup turning", null, "static", "slow_down", .82),
            Sh("mcu", "eye", "she laughs at something off camera", null, "zoom_in", "none", .55),
            Sh("ws", "eye", "she sits by the window, sunlight on the table", "a café", "static", "none", .9),
            Sh("cu", "eye", "she turns to camera and raises the cup", null, "zoom_in", "speed_up", .93),
        )
        val slots = shots.indices.joinToString(",") { i ->
            val h = shots[i]
            val where = h.where?.let { ",\"location\":\"$it\"" } ?: ""
            """{"id":"s${i + 1}","index":$i,"startSec":${cuts[i]},"endSec":${cuts[i + 1]},"confidence":${h.conf},
               "brief":{"shotSize":"${h.size}","angle":"${h.angle}","action":"${h.action}"$where},
               "camera":{"motion":"${h.motion}","shake":0,"keys":[],"confidence":0.65},"speed":{"ramp":"${h.ramp}","curve":[],"confidence":0.55},"peaks":[],"pose":{"status":"pending"}}"""
        }
        fun box(y: Double) = """{"x":0.1,"y":$y,"w":0.8,"h":0.07}"""
        val json = """
            {"schema":"muse.recipe/1","origin":"reference","summary":"Café morning, day in my life",
             "source":{"durationSec":15.0,"width":1080,"height":1920,"fps":30,"aspect":"9:16","hasAudio":true},
             "sound":{"bpm":118,"beats":[${beats.joinToString(",")}],"strong":[${strong.joinToString(",")}],"confidence":0.95},
             "slots":[$slots],
             "text":[
               {"id":"x1","startSec":0.0,"endSec":${cuts[2]},"box":${box(0.1)},"words":"POV: your favourite café opens at 7","sizeFrac":0.04,"color":"#FFFFFF","fontId":"sans","animIn":"pop","animOut":"cut","confidence":0.96},
               {"id":"x2","startSec":${cuts[4]},"endSec":${cuts[5]},"box":${box(0.72)},"words":"the oat flat white >>>","sizeFrac":0.035,"color":"#FFFFFF","fontId":"marker","animIn":"typewriter","animOut":"cut","confidence":0.71},
               {"id":"x3","startSec":${cuts[6]},"endSec":15.0,"box":${box(0.46)},"words":null,"sizeFrac":0.04,"color":"#000000","fontId":"sans","animIn":"fade","animOut":"fade","confidence":0.58}
             ],
             "transitions":[
               {"atSec":${cuts[1]},"kind":"cut","durationSec":0,"confidence":0.97},
               {"atSec":${cuts[2]},"kind":"whip","durationSec":0.2,"confidence":0.86},
               {"atSec":${cuts[3]},"kind":"cut","durationSec":0,"confidence":0.97},
               {"atSec":${cuts[4]},"kind":"cut","durationSec":0,"confidence":0.95},
               {"atSec":${cuts[5]},"kind":"flash","durationSec":0.067,"confidence":0.74},
               {"atSec":${cuts[6]},"kind":"unknown","durationSec":0.3,"confidence":0.3}
             ],
             "grade":{"swatches":["#1E1813","#4A3A2C","#8A6A4E","#C9A57E","#F1E2C8"],"contrast":0.6,"saturation":0.4,"warmth":0.5,"look":{"id":"warm_film","kind":"palette","label":"Warm film","distance":0.18},"confidence":0.84},
             "gaps":[{"key":"transition:unknown@${cuts[6]}","kind":"transition","what":"A transition MUSE couldn’t name","atSec":${cuts[6]},"note":"Not supported yet"},
                     {"key":"text:words","kind":"text","what":"The words of one caption","note":"Not read yet"},
                     {"key":"pose","kind":"motion","what":"Body poses","note":"Not read yet"}]}
        """.trimIndent()
        return json
    }
}

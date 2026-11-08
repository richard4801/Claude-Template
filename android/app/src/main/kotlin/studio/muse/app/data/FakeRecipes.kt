package studio.muse.app.data

import studio.muse.core.edit.Recipe
import studio.muse.core.edit.RecipeJson

/**
 * "Recreate this edit" (plans/recreate-edit.md), build phase 1: a stand-in recipe until WS1's analysis service and
 * `recipe` schema land. It goes through [RecipeJson] like the server's will, and is only shown in demo mode.
 */
object FakeRecipes {
    /** A 15 s café "day in my life" edit at 118 BPM: seven shots cut on the beat, a hook, two whips and a warm film grade. */
    fun cafeTrend(): Recipe {
        val beat = 60.0 / 118
        val beats = generateSequence(0.21) { it + beat }.takeWhile { it < 15.0 }.map { Math.round(it * 1000) / 1000.0 }.toList()
        val strong = beats.filterIndexed { i, _ -> i % 4 == 0 }
        // Cuts land on beats 4, 8, 12, 16, 20 and 24.
        val cuts = listOf(0.0) + listOf(4, 8, 12, 16, 20, 24).map { beats[it] } + 15.0
        val shots = listOf(
            Triple("Close-up, eye level", "Hands set a flat white on the counter", "Push in, slow"),
            Triple("Medium, eye level", "She looks up from her phone and smiles", "Handheld"),
            Triple("Wide, low angle", "Walks through the door into the light", "Whip pan in"),
            Triple("Close-up, high angle", "The latte art, turning the cup", "Ramp 1× → 0.4×"),
            Triple("Medium close-up, eye level", "Laughs at something off camera", "Zoom 1.0 → 1.15"),
            Triple("Wide, eye level", "Sits by the window, sunlight on the table", "Locked off"),
            Triple("Close-up, eye level", "Turns to camera, raises the cup", "Push in, fast"),
        )
        val conf = listOf(.94, .91, .88, .82, .55, .9, .93)
        val slots = shots.indices.joinToString(",") { i ->
            val (size, brief, move) = shots[i]
            val (sz, ang) = size.split(", ")
            val speed = if (move.startsWith("Ramp")) "\"speed\":\"$move\"," else ""
            val zoom = if (move.startsWith("Zoom")) "\"transform\":\"$move\"," else ""
            val mv = if (speed.isEmpty() && zoom.isEmpty() && move != "Locked off") "\"move\":\"$move\"," else ""
            """{"startSec":${cuts[i]},"endSec":${cuts[i + 1]},"shotSize":"$sz","angle":"${ang.replaceFirstChar { it.uppercase() }}","brief":"$brief",$mv$speed$zoom"confidence":${conf[i]}}"""
        }
        val json = """
            {"version":1,"title":"Café morning, day in my life","durationSec":15.0,
             "slots":[$slots],
             "texts":[
               {"startSec":0.0,"endSec":${cuts[2]},"text":"POV: your favourite café opens at 7","position":"Top","style":"Bold sans, white with a soft shadow","animation":"Pop in","confidence":0.96},
               {"startSec":${cuts[4]},"endSec":${cuts[5]},"text":"the oat flat white >>>","position":"Lower third","style":"Handwritten, white","animation":"Typewriter","confidence":0.71},
               {"startSec":${cuts[6]},"endSec":15.0,"text":"save for your next slow morning","position":"Middle","style":"Bold sans, black on a white box","animation":"Fade","confidence":0.58}
             ],
             "transitions":[
               {"atSec":${cuts[2]},"kind":"Whip","confidence":0.86},
               {"atSec":${cuts[3]},"kind":"Cut","confidence":0.97},
               {"atSec":${cuts[5]},"kind":"Flash","confidence":0.74},
               {"atSec":${cuts[6]}}
             ],
             "grade":{"name":"Warm film","swatches":["#1E1813","#4A3A2C","#8A6A4E","#C9A57E","#F1E2C8"],"confidence":0.84},
             "beats":{"bpm":118,"beats":[${beats.joinToString(",")}],"strong":[${strong.joinToString(",")}],"confidence":0.95},
             "sound":"Original sound, 118 BPM"}
        """.trimIndent()
        return RecipeJson.parse(json)
    }
}

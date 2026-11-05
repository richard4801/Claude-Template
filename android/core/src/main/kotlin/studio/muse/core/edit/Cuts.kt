package studio.muse.core.edit

import kotlin.math.max
import kotlin.math.min

/*
 * Silence, filler-word and repeated-word cuts from word timestamps (server/api/src/editor/cuts.ts; plans/api.md
 * "Editor v2" → cuts). Times are SOURCE seconds of the transcribed media. Pure.
 */

data class Word(val text: String, val startSec: Double, val endSec: Double, val score: Double? = null)

enum class CutReason(override val wire: String) : Wire { SILENCE("silence"), FILLER("filler"), REPEAT("repeat") }

data class Cut(val startSec: Double, val endSec: Double, val reason: CutReason, val text: String? = null) {
    val range: Range get() = Range(startSec, endSec)
}

data class CutOptions(
    val minSilenceSec: Double? = null,
    val keepPadSec: Double? = null,
    val fillers: Boolean? = null,
    val repeats: Boolean? = null,
    val extraFillers: List<String>? = null,
)

data class SuggestedCuts(val cuts: List<Cut>, val savedSec: Double)

object CutDefaults {
    val FILLERS = listOf("um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "hmm", "mm", "mhm")
    const val MIN_SILENCE_SEC = 0.7
    const val KEEP_PAD_SEC = 0.12
    const val FILLERS_ON = true
    const val REPEATS_ON = false
}

private fun r3(v: Double): Double = Math.round(v * 1000).toDouble() / 1000
private val NON_WORD = Regex("[^\\p{L}\\p{N}']+")

/** A word for comparing: lower case, letters/digits/apostrophes only. */
fun normWord(s: String): String = s.lowercase().replace(NON_WORD, "")

fun suggestCuts(words: List<Word>, durationSec: Double, o: CutOptions = CutOptions()): SuggestedCuts {
    val minSil = o.minSilenceSec ?: CutDefaults.MIN_SILENCE_SEC
    val pad = o.keepPadSec ?: CutDefaults.KEEP_PAD_SEC
    val fillers = (CutDefaults.FILLERS + (o.extraFillers ?: emptyList()).map(::normWord)).filter { it.isNotEmpty() }.toSet()
    val ws = words.sortedBy { it.startSec }
    if (ws.isEmpty()) return SuggestedCuts(emptyList(), 0.0)
    val raw = ArrayList<Cut>()
    fun silence(a: Double, b: Double) {
        val s = a + pad; val e = b - pad
        if (b - a >= minSil && e - s >= 0.1) raw += Cut(s, e, CutReason.SILENCE)
    }
    // Leading and trailing silence keep no pad on the outer side.
    if (ws[0].startSec >= minSil && ws[0].startSec - pad >= 0.1) raw += Cut(0.0, ws[0].startSec - pad, CutReason.SILENCE)
    for (i in 1 until ws.size) silence(ws[i - 1].endSec, ws[i].startSec)
    val last = ws.last()
    if (durationSec - last.endSec >= minSil && durationSec - (last.endSec + pad) >= 0.1) raw += Cut(last.endSec + pad, durationSec, CutReason.SILENCE)
    ws.forEachIndexed { i, w ->
        val n = normWord(w.text)
        if ((o.fillers ?: CutDefaults.FILLERS_ON) && n in fillers) raw += Cut(w.startSec, w.endSec, CutReason.FILLER, w.text)
        val next = ws.getOrNull(i + 1)
        if ((o.repeats ?: CutDefaults.REPEATS_ON) && next != null && n.isNotEmpty() && normWord(next.text) == n && next.startSec - w.endSec < 1)
            raw += Cut(w.startSec, next.startSec, CutReason.REPEAT, w.text)
    }
    val sorted = raw.sortedWith(compareBy<Cut> { it.startSec }.thenBy { it.endSec })
    val out = ArrayList<Cut>()
    for (c in sorted) {
        val prev = out.lastOrNull()
        if (prev != null && c.startSec <= prev.endSec + 1e-9) {
            out[out.size - 1] = prev.copy(endSec = max(prev.endSec, c.endSec), text = if (c.text != null && prev.text == null) c.text else prev.text)
            continue
        }
        out += c
    }
    val cuts = out.map { it.copy(startSec = r3(max(0.0, it.startSec)), endSec = r3(min(durationSec, it.endSec))) }.filter { it.endSec - it.startSec >= 0.05 }
    return SuggestedCuts(cuts, r3(cuts.fold(0.0) { s, c -> s + c.endSec - c.startSec }))
}

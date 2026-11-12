package studio.muse.core.claude

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.contentOrNull
import kotlin.math.roundToLong

// Claude panel cards (owner's chosen chat reference, 2026-11-12; server/api/src/claude/cards.ts; the Mac's
// MuseCore/Claude/ClaudeCards.swift). Claude's replies can carry structured parts drawn as cards instead of plain bubbles:
// a plan that ticks, a clip with its key moments, "What I changed" with Undo per row, and an Approve card with price lines
// and a Total. Each arrives as a tool line (tool.name "card" or "approve", tool.ui.card). Pure and lenient: an unknown or
// broken card is null (the app keeps the plain tool row), never an error.

data class PlanStep(val text: String, val done: Boolean)
data class Moment(val from: Double, val to: Double?, val label: String) {
    /** "0:04–0:10", or "0:04" for one moment. */
    val timecode: String get() = to?.let { "${CardText.clock(from)}–${CardText.clock(it)}" } ?: CardText.clock(from)
}
data class CardVideo(val id: String, val kind: String, val url: String, val title: String?)
data class ChangeRow(val what: String, val to: String, val undoable: Boolean, val undone: Boolean)
data class PriceLine(val label: String, val usd: Double)

/** Who answers an Approve card: a gated action, or the Suite composer's waiting shot. */
sealed interface ApproveTarget {
    data class Action(val id: String) : ApproveTarget
    data class Suite(val assistId: String, val pendingId: String) : ApproveTarget
}

sealed interface ClaudeCard {
    data class Plan(val planId: String, val title: String, val steps: List<PlanStep>) : ClaudeCard {
        val done get() = steps.count { it.done }
    }
    data class Media(val title: String, val summary: String?, val video: CardVideo, val durationSec: Double?, val moments: List<Moment>) : ClaudeCard
    data class Changes(val title: String, val rows: List<ChangeRow>) : ClaudeCard
    data class Approve(val title: String, val subtitle: String?, val lines: List<PriceLine>, val totalUsd: Double?, val target: ApproveTarget,
                       val approveLabel: String, val declineLabel: String) : ClaudeCard

    companion object {
        /** A card from its JSON (`tool.ui.card`), or null when unknown or broken. */
        fun parse(e: JsonElement?): ClaudeCard? {
            val o = e as? JsonObject ?: return null
            val title = o.str("title")
            return when (o.str("kind")) {
                "plan" -> {
                    val steps = o.arr("steps")?.mapNotNull { s -> (s as? JsonObject)?.let { st -> st.str("text")?.let { PlanStep(it, st.bool("done") ?: false) } } } ?: return null
                    Plan(o.str("planId") ?: "plan", title ?: "Plan", steps)
                }
                "media" -> {
                    val v = o["video"] as? JsonObject ?: return null
                    val video = CardVideo(v.str("id") ?: return null, v.str("kind") ?: "take", v.str("url") ?: return null, v.str("title"))
                    val moments = o.arr("moments")?.mapNotNull { m -> (m as? JsonObject)?.let { x -> x.num("from")?.let { Moment(it, x.num("to"), x.str("label") ?: "") } } }.orEmpty()
                    Media(title ?: "Clip analysis", o.str("summary"), video, o.num("durationSec"), moments)
                }
                "changes" -> Changes(title ?: "What I changed", o.arr("rows")?.mapNotNull { r ->
                    (r as? JsonObject)?.let { x -> val w = x.str("what"); val t = x.str("to"); if (w == null || t == null) null else ChangeRow(w, t, x.bool("undoable") ?: false, x.bool("undone") ?: false) }
                }.orEmpty())
                "approve" -> {
                    val a = o["answer"] as? JsonObject ?: return null
                    val target = a.str("actionId")?.let { ApproveTarget.Action(it) }
                        ?: a.str("assistId")?.let { s -> a.str("pendingId")?.let { p -> ApproveTarget.Suite(s, p) } } ?: return null
                    val lines = o.arr("lines")?.mapNotNull { l -> (l as? JsonObject)?.let { x -> x.str("label")?.let { lb -> x.num("usd")?.let { PriceLine(lb, it) } } } }.orEmpty()
                    Approve(title ?: "", o.str("subtitle"), lines, o.num("totalUsd"), target, o.str("approveLabel") ?: "Approve", o.str("declineLabel") ?: "Decline")
                }
                else -> null
            }
        }
    }
}

object CardText {
    /** "0:04", "1:02:05". */
    fun clock(s: Double): String {
        val t = maxOf(0L, s.toLong())
        return if (t >= 3600) "%d:%02d:%02d".format(t / 3600, (t % 3600) / 60, t % 60) else "%d:%02d".format(t / 60, t % 60)
    }
    /** "$1.17". */
    fun money(v: Double) = "$" + "%.2f".format(java.util.Locale.US, v)
    /** The Total under the lines: the card's own, else the lines added up. */
    fun total(lines: List<PriceLine>, total: Double?) = total ?: (lines.sumOf { it.usd } * 100).roundToLong() / 100.0
    /** "Outfit changed to Hoodie". */
    fun change(r: ChangeRow) = "${r.what} changed to ${r.to}" + if (r.undone) ", undone" else ""
}

internal fun JsonObject.str(k: String): String? = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull?.trim()?.ifEmpty { null }
internal fun JsonObject.num(k: String): Double? = (this[k] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull
internal fun JsonObject.bool(k: String): Boolean? = (this[k] as? JsonPrimitive)?.booleanOrNull
internal fun JsonObject.arr(k: String): JsonArray? = this[k] as? JsonArray
internal fun JsonObject.obj(k: String): JsonObject = this[k] as? JsonObject ?: JsonObject(emptyMap())

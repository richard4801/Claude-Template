package studio.muse.app.ui.screens.camera

// Pure logic of the Directed (Blender) mode and Direct with Claude (plans/mcp-bridge.md "Phase 2 · UI"): plan geometry,
// timeline labels, status rows, transcript grouping, the working strip, the footer and drag edits. No Compose here.

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import studio.muse.app.data.CamKey
import studio.muse.app.data.CameraAsset
import studio.muse.app.data.CameraMessage
import studio.muse.app.data.CameraPath
import studio.muse.app.data.CameraSession
import studio.muse.app.data.CharKey
import studio.muse.app.data.CharacterTrack
import studio.muse.app.data.Connections
import java.util.Locale
import kotlin.math.abs
import kotlin.math.atan
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.roundToInt
import kotlin.math.sin

/** A point on the plan, in metres (x right, y away from the camera). */
data class P2(val x: Double, val y: Double)

data class Bounds(val minX: Double, val minY: Double, val maxX: Double, val maxY: Double) {
    val w get() = maxX - minX
    val h get() = maxY - minY
}

/** Metres ↔ pixels for a drawing of [widthPx]×[heightPx]. Y up on screen = +Y (away from the camera). */
data class PlanFit(val bounds: Bounds, val widthPx: Float, val heightPx: Float) {
    val scale: Double = minOf(widthPx / bounds.w.coerceAtLeast(1e-6), heightPx / bounds.h.coerceAtLeast(1e-6))
    private val ox = (widthPx - bounds.w * scale) / 2
    private val oy = (heightPx - bounds.h * scale) / 2
    fun x(m: Double) = (ox + (m - bounds.minX) * scale).toFloat()
    fun y(m: Double) = (oy + (bounds.maxY - m) * scale).toFloat()
    fun px(p: P2) = x(p.x) to y(p.y)
    /** Pixels back to metres (drag). */
    fun toMetres(px: Float, py: Float) = P2(bounds.minX + (px - ox) / scale, bounds.maxY - (py - oy) / scale)
    fun len(m: Double) = (m * scale).toFloat()
}

object Plan {
    const val MARGIN_M = 1.0
    const val GRID_M = 0.5
    const val SENSOR_MM = 36.0

    /** Every point of the camera path (positions and targets) and the blocking, plus [MARGIN_M]; null with nothing to draw. */
    fun bounds(path: CameraPath?, tracks: List<CharacterTrack>, side: Boolean = false): Bounds? {
        val pts = buildList {
            path?.keyframes?.forEach { k -> add(k.position); k.target?.let { add(it) } }
            tracks.forEach { t -> t.keyframes.forEach { add(it.position) } }
        }.filter { it.size >= 2 }
        if (pts.isEmpty()) return null
        val xs = pts.map { it[0] }
        val ys = pts.map { if (side) it.getOrElse(2) { 0.0 } else it[1] }
        val b = Bounds(xs.min() - MARGIN_M, (if (side) minOf(0.0, ys.min()) else ys.min()) - MARGIN_M, xs.max() + MARGIN_M, ys.max() + MARGIN_M)
        return b
    }

    fun ease(kind: String?, u0: Double): Double {
        val u = u0.coerceIn(0.0, 1.0)
        return when (kind) {
            "in" -> u * u
            "out" -> 1 - (1 - u) * (1 - u)
            "in_out" -> u * u * (3 - 2 * u)
            else -> u
        }
    }

    /** Index i with keys[i].t ≤ t < keys[i+1].t and the eased fraction (by the later key's ease). */
    private fun <K> span(keys: List<K>, t: Double, time: (K) -> Double, easeOf: (K) -> String?): Triple<Int, Int, Double> {
        if (keys.size == 1 || t <= time(keys.first())) return Triple(0, 0, 0.0)
        if (t >= time(keys.last())) return Triple(keys.lastIndex, keys.lastIndex, 0.0)
        val i = keys.indexOfLast { time(it) <= t }.coerceAtMost(keys.lastIndex - 1)
        val a = keys[i]; val b = keys[i + 1]
        val d = time(b) - time(a)
        val u = if (d <= 0) 1.0 else (t - time(a)) / d
        return Triple(i, i + 1, ease(easeOf(b) ?: easeOf(a), u))
    }

    private fun lerp(a: Double, b: Double, u: Double) = a + (b - a) * u
    private fun lerp3(a: List<Double>, b: List<Double>, u: Double) = List(3) { lerp(a.getOrElse(it) { 0.0 }, b.getOrElse(it) { 0.0 }, u) }

    /** Shortest-way angle interpolation in degrees. */
    fun lerpAngle(a: Double, b: Double, u: Double): Double {
        var d = (b - a) % 360.0
        if (d > 180) d -= 360.0
        if (d < -180) d += 360.0
        return a + d * u
    }

    fun characterAt(keys: List<CharKey>, t: Double): CharKey? {
        if (keys.isEmpty()) return null
        val (i, j, u) = span(keys, t, { it.t }, { null })
        val a = keys[i]; val b = keys[j]
        return CharKey(t, lerp3(a.position, b.position, u), lerpAngle(a.facingDeg ?: 0.0, b.facingDeg ?: a.facingDeg ?: 0.0, u), activeAction(keys, t))
    }

    /** The action of the newest key at or before [t] that has one. */
    fun activeAction(keys: List<CharKey>, t: Double): String? = keys.filter { it.t <= t + 1e-6 }.lastOrNull { !it.action.isNullOrBlank() }?.action

    fun cameraAt(keys: List<CamKey>, t: Double): CamKey? {
        if (keys.isEmpty()) return null
        val (i, j, u) = span(keys, t, { it.t }, { it.ease })
        val a = keys[i]; val b = keys[j]
        val target = when {
            a.target != null && b.target != null -> lerp3(a.target!!, b.target!!, u)
            else -> a.target ?: b.target
        }
        return CamKey(t, lerp3(a.position, b.position, u), target, lerp(a.focalMm ?: 35.0, b.focalMm ?: a.focalMm ?: 35.0, u), lerp(a.rollDeg ?: 0.0, b.rollDeg ?: 0.0, u), b.ease)
    }

    /** Horizontal field of view in degrees: 2·atan(sensor/2 / f). */
    fun hfovDeg(focalMm: Double, sensorMm: Double = SENSOR_MM): Double = Math.toDegrees(2 * atan((sensorMm / 2) / focalMm.coerceAtLeast(1.0)))

    /** The view cone on the plan: the camera and the two edge points [length] metres out, toward the target (default +Y). */
    fun viewCone(cam: CamKey, sensorMm: Double = SENSOR_MM, length: Double? = null): Triple<P2, P2, P2> {
        val c = P2(cam.position[0], cam.position[1])
        val dir = cam.target?.let { atan2(it[1] - c.y, it[0] - c.x) } ?: (Math.PI / 2)
        val half = Math.toRadians(hfovDeg(cam.focalMm ?: 35.0, sensorMm) / 2)
        val len = length ?: cam.target?.let { (hypot(it[0] - c.x, it[1] - c.y) * 1.25).coerceIn(1.0, 6.0) } ?: 3.0
        fun at(a: Double) = P2(c.x + cos(a) * len, c.y + sin(a) * len)
        return Triple(c, at(dir - half), at(dir + half))
    }

    /** The facing direction on the plan (facingDeg 0 faces -Y, toward the camera; positive turns counter-clockwise). */
    fun facing(deg: Double): P2 { val r = Math.toRadians(deg); return P2(sin(r), -cos(r)) }

    /** Grid lines every [GRID_M] metres inside the bounds. */
    fun gridLines(b: Bounds, step: Double = GRID_M): Pair<List<Double>, List<Double>> {
        fun range(a: Double, z: Double) = generateSequence(Math.ceil(a / step) * step) { it + step }.takeWhile { it <= z + 1e-9 }.toList()
        return range(b.minX, b.maxX) to range(b.minY, b.maxY)
    }

    /** "0.0s", "1.2s": the keyframe time ticks on a path. */
    fun tick(t: Double) = String.format(Locale.US, "%.1fs", t)

    /** Ruler labels 0s…duration s, whole seconds. */
    fun ruler(durationSec: Double): List<Pair<Double, String>> = (0..floor(durationSec + 1e-9).toInt()).map { it.toDouble() to "${it}s" }

    /** "2.4 s" for the playhead chip. */
    fun chip(t: Double) = String.format(Locale.US, "%.1f s", t)

    fun initials(name: String): String {
        val parts = name.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
        return when {
            parts.isEmpty() -> "?"
            parts.size == 1 -> parts[0].take(2).uppercase()
            else -> (parts[0].take(1) + parts[1].take(1)).uppercase()
        }
    }

    /** `CAM A · 35 mm · 1.5 m`. */
    fun camLabel(cam: CamKey) = "CAM A · ${(cam.focalMm ?: 35.0).roundToInt()} mm · ${String.format(Locale.US, "%.1f", cam.position.getOrElse(2) { 0.0 })} m"
}

// ---------------------------------------------------------------- timeline

data class Span(val start: Double, val end: Double, val label: String)

object Timeline {
    private fun f1(d: Double) = String.format(Locale.US, "%.1f", d)
    fun easeText(e: String?) = when (e) { "in_out" -> "ease in-out"; "in" -> "ease in"; "out" -> "ease out"; else -> null }

    /** What the camera does between two keys: an orbit around the target (≥ 15°), a push / pull / move, or a hold. */
    fun cameraMove(a: CamKey, b: CamKey): String {
        val tgt = b.target ?: a.target
        val ease = easeText(b.ease ?: a.ease)
        if (tgt != null) {
            val a0 = atan2(a.position[1] - tgt[1], a.position[0] - tgt[0])
            val a1 = atan2(b.position[1] - tgt[1], b.position[0] - tgt[0])
            var d = Math.toDegrees(a1 - a0)
            while (d > 180) d -= 360
            while (d < -180) d += 360
            if (abs(d) >= 15) return "orbit ${abs(d).roundToInt()}°"
        }
        val dist = hypot3(a.position, b.position)
        val fa = a.focalMm; val fb = b.focalMm
        val zoom = if (fa != null && fb != null && abs(fa - fb) >= 1) "zoom ${fa.roundToInt()}→${fb.roundToInt()} mm" else null
        val move = when {
            dist < 0.05 -> null
            tgt != null && hypot3(b.position, tgt) < hypot3(a.position, tgt) - 0.02 -> "push ${f1(dist)} m"
            tgt != null && hypot3(b.position, tgt) > hypot3(a.position, tgt) + 0.02 -> "pull ${f1(dist)} m"
            abs(b.position.getOrElse(2) { 0.0 } - a.position.getOrElse(2) { 0.0 }) > dist * 0.7 -> if (b.position[2] > a.position[2]) "crane up ${f1(dist)} m" else "crane down ${f1(dist)} m"
            else -> "track ${f1(dist)} m"
        }
        val main = listOfNotNull(move, zoom).joinToString(" · ").ifEmpty { return "hold" }
        return listOfNotNull(main, ease).joinToString(" · ")
    }

    private fun hypot3(a: List<Double>, b: List<Double>) =
        Math.sqrt((0..2).sumOf { val d = a.getOrElse(it) { 0.0 } - b.getOrElse(it) { 0.0 }; d * d })

    fun cameraSpans(path: CameraPath?): List<Span> {
        val k = path?.keyframes.orEmpty()
        return k.zipWithNext { a, b -> Span(a.t, b.t, cameraMove(a, b)) }.filter { it.end > it.start }
    }

    /** One bar per key with an action, until the next key with an action (or the end). */
    fun characterSpans(keys: List<CharKey>, durationSec: Double): List<Span> {
        val acted = keys.filter { !it.action.isNullOrBlank() }
        return acted.mapIndexed { i, k -> Span(k.t, acted.getOrNull(i + 1)?.t ?: durationSec, k.action!!) }
    }
}

// ---------------------------------------------------------------- session text

enum class Dot { GOOD, WARN, OFF }

data class StatusRow(val dot: Dot, val title: String, val text: String)

object SessionText {
    const val FIVE_MIN = 5 * 60_000L
    const val BURST_MS = 90_000L

    /** `cs_7Q2M`: the first 4 characters after `cs_`, upper-case. */
    fun idChip(id: String) = "cs_" + id.removePrefix("cs_").take(4).uppercase()

    fun seconds(s: Double) = String.format(Locale.US, "%.1f s", s)

    /** `cs_7Q2M · 6.0 s · rev 4` */
    fun subtitle(s: CameraSession) = "${idChip(s.id)} · ${seconds(s.durationSec)} · rev ${s.revision}"

    /** `9:16 · 24 fps · 6.0 s · rev 4` */
    fun specLine(s: CameraSession) = "${s.aspect} · ${s.fps} fps · ${seconds(s.durationSec)} · rev ${s.revision}"

    fun hasGuides(s: CameraSession) = s.assets.any { it.kind == "greybox" && it.ready }

    /** The session pill: label and kind ("good" / "warn" / ""). */
    fun pill(s: CameraSession): Pair<String, String> = when {
        s.status == "failed" -> "Failed" to "warn"
        s.status == "generating" -> "Generating" to ""
        s.status == "done" -> "Done" to "good"
        s.status == "rendering" -> "Rendering" to "warn"
        s.status == "ready" || hasGuides(s) -> "Guides ready" to "good"
        s.status == "blocking" -> "Blocking" to ""
        else -> "Drafting" to ""
    }

    fun claudeRow(s: CameraSession, conn: Connections?, busy: Boolean, now: Long): StatusRow = when {
        busy || s.claude.chatBusy -> StatusRow(Dot.WARN, "Claude session", "Working…")
        s.claude.appLastSeenAt?.let { now - it < FIVE_MIN } == true -> StatusRow(Dot.GOOD, "Claude session", "Connected · your Claude app")
        else -> StatusRow(Dot.GOOD, "Claude session", "In MUSE (this chat)")
    }

    fun blenderRow(s: CameraSession): StatusRow {
        val title = "Blender" + (s.relay.addonVersion?.let { " $it" } ?: "")
        return when {
            s.relay.blender -> StatusRow(Dot.GOOD, title, "Mac · localhost")
            s.relay.online -> StatusRow(Dot.WARN, title, "Mac app online · Blender not connected")
            else -> StatusRow(Dot.OFF, title, "Mac app offline")
        }
    }

    /** "Uploading n of m to MUSE" while assets are pending (m = the batch since the oldest pending one), else guides / none. */
    fun rendersRow(s: CameraSession): StatusRow {
        val sorted = s.assets.sortedBy { it.createdAt }
        val first = sorted.indexOfFirst { !it.ready }
        if (first >= 0) {
            // The batch: the pending uploads and the burst of uploads just before them (each within 90 s of the next).
            var start = first
            while (start > 0 && sorted[start].createdAt - sorted[start - 1].createdAt < BURST_MS) start--
            val batch = sorted.drop(start)
            val done = batch.count { it.ready }
            return StatusRow(Dot.WARN, "Renders", "Uploading ${(done + 1).coerceAtMost(batch.size)} of ${batch.size} to MUSE")
        }
        return if (hasGuides(s)) StatusRow(Dot.GOOD, "Renders", "Guides ready") else StatusRow(Dot.OFF, "Renders", "None yet")
    }

    fun rows(s: CameraSession, conn: Connections?, busy: Boolean, now: Long) = listOf(claudeRow(s, conn, busy, now), blenderRow(s), rendersRow(s))

    fun quality(q: String?) = when (q) { "draft" -> "Draft"; "standard" -> "Standard"; "hd" -> "HD"; "cinema" -> "Cinema"; null, "" -> null; else -> q.replaceFirstChar { it.uppercase() } }

    /** The panel's footer, with the draft's price and quality when there is a draft. */
    fun footer(s: CameraSession?): String {
        val base = "Claude never spends money. Generating waits for your tap"
        val d = s?.shotDraft ?: return "$base."
        val q = quality((d.request?.get("quality") as? JsonPrimitive)?.contentOrNull)
        return "$base · est. ${money(d.estimate.usd)}" + (q?.let { " at $it" } ?: "") + "."
    }

    fun money(usd: Double) = String.format(Locale.US, "$%.2f", usd)

    /** The guides line: "Greybox · depth · pose · 3 keyframes". */
    fun guidesLine(assets: List<CameraAsset>): String {
        val ready = assets.filter { it.ready }.map { it.kind }.toSet()
        val parts = buildList {
            if ("greybox" in ready) add("Greybox")
            if ("depth" in ready) add("depth")
            if ("pose" in ready) add("pose")
            if ("tracks" in ready) add("tracks")
            val k = listOf("keyframe_start", "keyframe_mid", "keyframe_end").count { it in ready }
            if (k > 0) add("$k keyframe" + if (k == 1) "" else "s")
        }
        return parts.joinToString(" · ").replaceFirstChar { it.uppercase() }
    }

    fun ago(at: Long, now: Long): String {
        val s = ((now - at) / 1000).coerceAtLeast(0)
        return when {
            s < 45 -> "just now"
            s < 3600 -> "${(s + 30) / 60} min ago"
            s < 86_400 -> "${s / 3600} h ago"
            else -> "${s / 86_400} d ago"
        }
    }

    fun bytes(n: Long?): String = when {
        n == null -> ""
        n >= 1_000_000 -> String.format(Locale.US, "%.1f MB", n / 1_000_000.0)
        n >= 1_000 -> "${n / 1000} KB"
        else -> "$n B"
    }

    fun sourceLabel(src: String) = when (src) { "relay" -> "Mac app"; "mcp" -> "your Claude"; "chat" -> "chat"; else -> "MUSE app" }

    fun assetLabel(kind: String) = when (kind) {
        "greybox" -> "Greybox"; "depth" -> "Depth"; "pose" -> "Pose"; "tracks" -> "Tracks"
        "keyframe_start" -> "START"; "keyframe_mid" -> "MID"; "keyframe_end" -> "END"
        "camera_json" -> "camera.json"; "characters_json" -> "characters.json"; "blend" -> ".blend"
        "still" -> "Still"; "preview" -> "Preview"; else -> kind
    }

    /** Guide kinds in the order the Guides tab lists them. */
    val GUIDE_ORDER = listOf("greybox", "depth", "pose", "tracks", "keyframe_start", "keyframe_mid", "keyframe_end", "camera_json", "characters_json", "blend", "preview", "still")
}

// ---------------------------------------------------------------- transcript

/** BUILD_STAGE: the upper-case tool name without the `blender_` prefix. */
fun toolChipName(name: String) = name.removePrefix("blender_").replace('_', ' ').replaceFirstChar { it.uppercase() }

data class ToolChip(val name: String, val count: Int, val ok: Boolean) {
    val label get() = if (count > 1) "$name ×$count" else name
}

/** Consecutive tool steps with the same name collapse into one chip (`PLACE_CHARACTER ×2`); a failed one makes it red. */
fun collapseTools(tools: List<Pair<String, Boolean>>): List<ToolChip> {
    val out = mutableListOf<ToolChip>()
    for ((n, ok) in tools) {
        val name = toolChipName(n)
        val last = out.lastOrNull()
        if (last != null && last.name == name) out[out.lastIndex] = last.copy(count = last.count + 1, ok = last.ok && ok) else out += ToolChip(name, 1, ok)
    }
    return out
}

sealed interface Turn {
    data class You(val text: String, val label: String, val at: Long) : Turn
    /** Claude's text with the tool steps of the same turn. */
    data class Claude(val text: String, val tools: List<ToolChip>, val at: Long) : Turn
}

object Transcript {
    /** "YOU · PHONE" for messages sent from this device, else "YOU" (the API doesn't carry the device). */
    fun youLabel(m: CameraMessage, sentHere: Set<String>) = if (m.text in sentHere) "YOU · PHONE" else "YOU"

    fun turns(messages: List<CameraMessage>, sentHere: Set<String> = emptySet()): List<Turn> {
        val out = mutableListOf<Turn>()
        var tools = mutableListOf<Pair<String, Boolean>>()
        var text: String? = null
        var at = 0L
        fun flush() {
            if (text != null || tools.isNotEmpty()) out += Turn.Claude(text.orEmpty(), collapseTools(tools), at)
            text = null; tools = mutableListOf()
        }
        for (m in messages) when (m.role) {
            "user" -> { flush(); out += Turn.You(m.text, youLabel(m, sentHere), m.createdAt) }
            "tool" -> { if (text != null) flush(); tools += (m.tool?.name ?: "tool") to (m.tool?.ok ?: true); at = m.createdAt }
            else -> { text = listOfNotNull(text, m.text.takeIf { it.isNotBlank() }).joinToString("\n\n"); at = m.createdAt; if (tools.isNotEmpty()) flush() }
        }
        flush()
        return out
    }
}

// ---------------------------------------------------------------- the working strip

/** A chat turn while it streams. */
data class ChatTurn(
    val message: String, val baseRevision: Int, val toolsSeen: Int = 0, val toolsDone: Int = 0, val lastStep: String? = null,
    val text: String = "", val waitingMac: Boolean = false, val renderProgress: Float? = null,
) {
    /** "CLAUDE · WORKING ON REV n+1" */
    val title get() = "Claude · working on rev ${baseRevision + 1}"
    /** The last tool step or text, as a quote. */
    val quote: String get() = text.trim().lines().lastOrNull { it.isNotBlank() }?.trim() ?: lastStep ?: "Reading the session…"
    /** Steps done / steps seen, or the render's own progress when the Mac reports it. */
    val progress: Float get() = renderProgress ?: if (toolsSeen == 0) 0.05f else (toolsDone.toFloat() / toolsSeen).coerceIn(0.05f, 1f)
    val percent get() = "${(progress * 100).roundToInt()}%"
}

/** A chat refusal or failure shown above the composer. */
data class ChatNotice(val code: String, val text: String) {
    val directorUnavailable get() = code == "director_unavailable"

    companion object {
        const val UNAVAILABLE = "Direct with Claude isn't set up on the server yet (ANTHROPIC_API_KEY) · you can still direct from your own Claude app"
        const val BUSY = "Claude is still working on this shot"
        fun of(code: String?, error: String?) = when (code) {
            "director_unavailable" -> ChatNotice("director_unavailable", UNAVAILABLE)
            "chat_busy" -> ChatNotice("chat_busy", BUSY)
            else -> ChatNotice(code ?: "error", error?.takeIf { it.isNotBlank() } ?: "Claude couldn't finish this step")
        }
    }
}

// ---------------------------------------------------------------- drag

object Drag {
    const val SNAP_S = 0.05
    const val MAX_KEYS = 64

    private fun r2(d: Double) = Math.round(d * 100) / 100.0

    /** Moves the character key at [t] (within [SNAP_S]) to [to], or inserts one there (z and facing interpolated). */
    fun moveCharacter(tracks: List<CharacterTrack>, modelId: String, t: Double, to: P2): List<CharacterTrack> = tracks.map { tr ->
        if (tr.modelId != modelId) return@map tr
        val i = tr.keyframes.indexOfFirst { abs(it.t - t) <= SNAP_S }
        if (i >= 0) {
            val k = tr.keyframes[i]
            tr.copy(keyframes = tr.keyframes.toMutableList().also { it[i] = k.copy(position = listOf(r2(to.x), r2(to.y), k.position.getOrElse(2) { 0.0 })) })
        } else {
            if (tr.keyframes.size >= MAX_KEYS) return@map tr
            val at = Plan.characterAt(tr.keyframes, t)
            val k = CharKey(r2(t), listOf(r2(to.x), r2(to.y), at?.position?.getOrElse(2) { 0.0 } ?: 0.0), at?.facingDeg)
            tr.copy(keyframes = (tr.keyframes + k).sortedBy { it.t })
        }
    }

    /** Moves the camera key at [t] (within [SNAP_S]) to [to], or inserts one there (height, target and lens interpolated). */
    fun moveCamera(path: CameraPath, t: Double, to: P2): CameraPath {
        val i = path.keyframes.indexOfFirst { abs(it.t - t) <= SNAP_S }
        if (i >= 0) {
            val k = path.keyframes[i]
            return path.copy(keyframes = path.keyframes.toMutableList().also { it[i] = k.copy(position = listOf(r2(to.x), r2(to.y), k.position.getOrElse(2) { 1.5 })) })
        }
        if (path.keyframes.size >= MAX_KEYS) return path
        val at = Plan.cameraAt(path.keyframes, t) ?: CamKey(t, listOf(to.x, to.y, 1.5))
        val k = CamKey(r2(t), listOf(r2(to.x), r2(to.y), at.position.getOrElse(2) { 1.5 }), at.target, at.focalMm, null, at.ease)
        return path.copy(keyframes = (path.keyframes + k).sortedBy { it.t })
    }
}

// ---------------------------------------------------------------- the handoff to the Shot builder

/** What "Use for Shot" hands over: workstream 1's `CameraSpec.guide` (plans/api.md "AI suite"). */
data class CameraGuideHandoff(
    val sessionId: String, val videoKey: String, val seconds: Double? = null,
    val start: String? = null, val middle: List<String> = emptyList(), val end: String? = null,
) {
    /** `{"mode":"directed","guide":{"video":{"key":…,"seconds":…},"use":"blocking","cameraSessionId":…,"keyframes":{…}}}` */
    fun cameraJson(): String = JSON.encodeToString(JsonObject.serializer(), JsonObject(mapOf(
        "mode" to JsonPrimitive("directed"),
        "guide" to JsonObject(buildMap {
            put("video", JsonObject(buildMap { put("key", JsonPrimitive(videoKey)); seconds?.let { put("seconds", JsonPrimitive(it)) } }))
            put("use", JsonPrimitive("blocking"))
            put("cameraSessionId", JsonPrimitive(sessionId))
            if (start != null || middle.isNotEmpty() || end != null) put("keyframes", JsonObject(buildMap {
                start?.let { put("start", JsonPrimitive(it)) }
                if (middle.isNotEmpty()) put("middle", JsonArray(middle.map { JsonPrimitive(it) }))
                end?.let { put("end", JsonPrimitive(it)) }
            }))
        }),
    )))

    companion object {
        private val JSON = Json { encodeDefaults = false }

        /** From the session's Shot draft (`shotDraft.request.camera.guide`); null without a draft or a greybox guide. */
        fun of(s: CameraSession): CameraGuideHandoff? {
            val cam = s.shotDraft?.request?.get("camera") as? JsonObject ?: s.shotDraft?.camera ?: return null
            val g = cam["guide"] as? JsonObject ?: return null
            val video = g["video"] as? JsonObject ?: return null
            val key = (video["key"] as? JsonPrimitive)?.contentOrNull ?: return null
            val kf = g["keyframes"] as? JsonObject
            fun str(o: JsonObject?, k: String) = (o?.get(k) as? JsonPrimitive)?.contentOrNull
            return CameraGuideHandoff(
                (g["cameraSessionId"] as? JsonPrimitive)?.contentOrNull ?: s.id, key, (video["seconds"] as? JsonPrimitive)?.doubleOrNull,
                str(kf, "start"), (kf?.get("middle") as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.orEmpty(), str(kf, "end"),
            )
        }
    }
}

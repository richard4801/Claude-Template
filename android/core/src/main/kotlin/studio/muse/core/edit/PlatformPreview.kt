package studio.muse.core.edit

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// Edit's platform preview (owner decision 2026-11-12, plans/edit-platform-preview.md). The platform views live in Edit,
// merged with its safe-area guide:
// - View: Clean · TikTok · Reels · Shorts · Facebook (portrait, square, 4:5) or Clean · YouTube · Facebook (16:9). A
//   platform view draws that app's generic chrome over the edit; Clean draws nothing.
// - Safe area: a switch that works in every view. A platform view shows that app's red box; Clean shows the box safe on
//   every app; landscape views use their own boxes (title-safe in Clean).
// - Remembered per project, falling back to this device's last choice.
// - The check that warns when captions or text sit outside the box.
// The same rules as the Mac (MuseCore Edit/EditPlatformPreview.swift) and the server (src/editor/safeArea.ts).

/** What Edit's preview shows over the edit. [id] is the wire name (presence, server table). */
enum class PreviewView(val id: String, val label: String) {
    CLEAN("clean", "Clean"), TIKTOK("tiktok", "TikTok"), REELS("reels", "Reels"), SHORTS("shorts", "Shorts"),
    FACEBOOK("facebook", "Facebook"), YOUTUBE("youtube", "YouTube");

    companion object {
        fun of(id: String?): PreviewView? = entries.firstOrNull { it.id == id }
        fun isLandscape(width: Int, height: Int): Boolean = width.toDouble() / max(1, height) > 1.05
        /** The views for a canvas of this shape. */
        fun options(width: Int, height: Int): List<PreviewView> =
            if (isLandscape(width, height)) listOf(CLEAN, YOUTUBE, FACEBOOK) else listOf(CLEAN, TIKTOK, REELS, SHORTS, FACEBOOK)
    }
}

/** The parts of the frame an app's own buttons and captions cover, as fractions of the frame. */
data class SafeZone(val top: Double, val bottom: Double, val left: Double, val right: Double) {
    private fun c(v: Double) = if (v.isFinite()) v.coerceIn(0.0, 0.5) else 0.0
    val x get() = c(left)
    val y get() = c(top)
    val w get() = max(0.0, 1 - c(left) - c(right))
    val h get() = max(0.0, 1 - c(top) - c(bottom))
}

/** The safe zones per view (GET /v1/preview/layouts merged over these defaults; approximate). */
data class PreviewLayouts(val zones: Map<String, SafeZone>, val landscape: Map<String, SafeZone> = emptyMap(), val note: String? = null) {
    fun zone(v: PreviewView): SafeZone? = if (v == PreviewView.CLEAN || v == PreviewView.YOUTUBE) null else zones[v.id] ?: DEFAULTS.zones[v.id]
    fun landscapeZone(v: PreviewView): SafeZone? =
        if (v != PreviewView.YOUTUBE && v != PreviewView.FACEBOOK) null else landscape[v.id] ?: DEFAULTS.landscape[v.id]

    /** This table (the server's) over the defaults: a view it leaves out keeps its default. */
    fun merged(): PreviewLayouts = PreviewLayouts(DEFAULTS.zones + zones, DEFAULTS.landscape + landscape, note ?: DEFAULTS.note)

    companion object {
        val DEFAULTS = PreviewLayouts(
            zones = mapOf(
                "tiktok" to SafeZone(.11, .29, .03, .17), "reels" to SafeZone(.10, .30, .03, .16),
                "shorts" to SafeZone(.09, .30, .03, .17), "facebook" to SafeZone(.10, .28, .03, .16),
            ),
            landscape = mapOf("youtube" to SafeZone(.12, .16, .03, .03), "facebook" to SafeZone(.08, .16, .03, .03)),
            note = "Approximate. Each app moves its buttons now and then.",
        )

        /** The server's reply (`{zones, landscape?, note?}`); a bad entry is left out. */
        fun parse(o: JsonObject): PreviewLayouts {
            fun zones(k: String) = (o[k] as? JsonObject)?.mapNotNull { (name, z) ->
                val m = z as? JsonObject ?: return@mapNotNull null
                fun d(f: String) = (m[f] as? JsonPrimitive)?.doubleOrNull
                val t = d("top"); val b = d("bottom"); val r = d("right")
                if (t == null || b == null || r == null) null else name to SafeZone(t, b, d("left") ?: 0.0, r)
            }?.toMap() ?: emptyMap()
            return PreviewLayouts(zones("zones"), zones("landscape"), (o["note"] as? JsonPrimitive)?.contentOrNull).merged()
        }
    }
}

/** The view and the Safe area switch. */
data class EditPreview(val view: PreviewView = PreviewView.CLEAN, val safeArea: Boolean = true) {
    /** The view this canvas can show (a TikTok choice on a 16:9 project shows Clean). */
    fun resolved(width: Int, height: Int): EditPreview =
        if (view in PreviewView.options(width, height)) this else copy(view = PreviewView.CLEAN)
}

object EditSafeBox {
    val TITLE_SAFE = SafeZone(.05, .05, .05, .05)

    /** The box safe on every phone app: the largest inset of each side. */
    fun everyApp(l: PreviewLayouts = PreviewLayouts.DEFAULTS): SafeZone {
        val zs = listOf(PreviewView.TIKTOK, PreviewView.REELS, PreviewView.SHORTS, PreviewView.FACEBOOK).mapNotNull { l.zone(it) }
        return SafeZone(zs.maxOf { it.top }, zs.maxOf { it.bottom }, zs.maxOf { it.left }, zs.maxOf { it.right })
    }

    /** The red box for this choice on a canvas of this shape (null: the switch is off). */
    fun zone(p: EditPreview, width: Int, height: Int, layouts: PreviewLayouts = PreviewLayouts.DEFAULTS): SafeZone? {
        if (!p.safeArea) return null
        val v = p.resolved(width, height).view
        return if (PreviewView.isLandscape(width, height)) { if (v == PreviewView.CLEAN) TITLE_SAFE else layouts.landscapeZone(v) }
        else { if (v == PreviewView.CLEAN) everyApp(layouts) else layouts.zone(v) }
    }

    /** What the app's chrome covers, for the warning line ("TikTok's caption and buttons"). */
    fun covers(p: EditPreview, width: Int, height: Int): String {
        val v = p.resolved(width, height).view
        val wide = PreviewView.isLandscape(width, height)
        return when (v) {
            PreviewView.CLEAN -> if (wide) "the edge of some screens" else "some apps' captions and buttons"
            PreviewView.YOUTUBE -> "YouTube's title and controls"
            else -> if (wide) "${v.label}'s controls" else "${v.label}'s caption and buttons"
        }
    }

    /** What the box is, for its description. */
    fun name(p: EditPreview, width: Int, height: Int): String {
        val v = p.resolved(width, height).view
        return if (v == PreviewView.CLEAN) { if (PreviewView.isLandscape(width, height)) "the title-safe area" else "the area safe on every app" }
        else "${v.label}'s safe area"
    }
}

/** Captions ([itemId] null) or a text item outside the red box, the times it shows and which edges cross the box. */
data class SafeIssue(val captions: Boolean, val itemId: String?, val startSec: Double, val endSec: Double, val edges: List<String>)

/** An approximate box for a block of text (fractions of the canvas). */
data class TextBox(val x: Double, val y: Double, val w: Double, val h: Double) {
    fun edges(z: SafeZone): List<String> {
        val tol = .005
        return buildList {
            if (y - h / 2 < z.y - tol) add("top")
            if (y + h / 2 > z.y + z.h + tol) add("bottom")
            if (x - w / 2 < z.x - tol) add("left")
            if (x + w / 2 > z.x + z.w + tol) add("right")
        }
    }

    companion object {
        /** Glyphs ≈ 0.55 em (0.62 uppercase): good enough for a warning, not for layout. */
        fun estimate(text: String, x: Double, y: Double, sizePct: Double, maxWidthPct: Double?, lineHeight: Double?, uppercase: Boolean,
                     maxLines: Int?, aspect: Double): TextBox {
            val em = sizePct / max(.1, aspect)
            val glyph = em * if (uppercase) .62 else .55
            val wrap = maxWidthPct ?: .85
            var lines = 0
            var widest = 0.0
            for (raw in text.split("\n")) {
                val w = raw.codePointCount(0, raw.length) * glyph
                lines += max(1, ceil(w / max(.01, wrap)).toInt())
                widest = max(widest, min(w, wrap))
            }
            if (maxLines != null) lines = min(lines, max(1, maxLines))
            return TextBox(x, y, widest, max(1, lines) * sizePct * (lineHeight ?: 1.15))
        }
    }
}

object EditSafeCheck {
    private fun aspect(p: EditProject) = p.canvas.width.toDouble() / max(1, p.canvas.height)

    fun box(it: TextItem, aspect: Double): TextBox {
        val sc = it.transform?.scale ?: 1.0
        return TextBox.estimate(it.text, it.transform?.x ?: .5, it.transform?.y ?: .5, it.style.sizePct * sc, it.style.maxWidthPct?.let { w -> w * sc },
            it.style.lineHeight, it.style.uppercase == true, null, aspect)
    }

    private fun pageBox(p: EditProject, page: CaptionPage, s: CaptionStyle, language: String?, y: Double, maxWidthPct: Double?) =
        TextBox.estimate(captionText(page.words.map { it.text }, language), .5, y, s.text.sizePct, maxWidthPct, s.text.lineHeight,
            s.text.uppercase == true, s.maxLines ?: 2, aspect(p))

    /** Captions (each page) and text items (at rest) outside [z]; captions as one issue over every page that crosses it. */
    fun issues(p: EditProject, z: SafeZone): List<SafeIssue> {
        val out = ArrayList<SafeIssue>()
        val capTrack = p.tracks.firstOrNull { it.kind == TrackKind.CAPTION && it.caption != null }
        val ct = capTrack?.caption
        if (ct != null && capTrack.hidden != true) {
            var from: Double? = null
            var to = 0.0
            val es = LinkedHashSet<String>()
            for (page in captionPages(p)) {
                val e = pageBox(p, page, ct.style, ct.language, ct.style.y ?: .72, ct.style.text.maxWidthPct).edges(z)
                if (e.isEmpty()) continue
                if (from == null) from = page.startSec
                to = max(to, page.endSec)
                es += e
            }
            if (from != null) out += SafeIssue(true, null, from, to, listOf("top", "bottom", "left", "right").filter { it in es })
        }
        for (t in p.tracks) {
            if (t.kind != TrackKind.TEXT || t.hidden == true) continue
            for (it in t.items) {
                val item = it as? TextItem ?: continue
                val e = box(item, aspect(p)).edges(z)
                if (e.isNotEmpty()) out += SafeIssue(false, item.id, item.startSec, item.startSec + item.durationSec, e)
            }
        }
        return out
    }

    private fun clock(s: Double): String { val n = max(0, s.roundToInt()); return "${n / 60}:${(n % 60).toString().padStart(2, '0')}" }

    /** "Captions sit under TikTok's caption and buttons (0:01–0:09)." null when everything is inside. */
    fun line(issues: List<SafeIssue>, covers: String): String? {
        val first = issues.firstOrNull() ?: return null
        val caps = issues.firstOrNull { it.captions }
        val texts = issues.filter { !it.captions }
        fun range(i: SafeIssue) = "${clock(i.startSec)}–${clock(i.endSec)}"
        return when {
            caps != null && texts.isEmpty() -> "Captions sit under $covers (${range(caps)})."
            caps == null && texts.size == 1 -> "A text sits under $covers (${range(first)})."
            caps == null -> "${texts.size} texts sit under $covers."
            else -> "Captions and ${if (texts.size == 1) "a text" else "${texts.size} texts"} sit under $covers."
        }
    }

    /** "Move into the safe area": the captions' height and wrap width and each text item's position, just inside [z]. */
    fun fixed(p: EditProject, z: SafeZone): EditProject? {
        val found = issues(p, z)
        if (found.isEmpty()) return null
        val margin = .01
        val a = aspect(p)
        val tracks = p.tracks.map { t ->
            val ct = t.caption
            when {
                t.kind == TrackKind.CAPTION && ct != null && found.any { it.captions } -> {
                    val half = min(.5 - z.x, z.x + z.w - .5) - margin
                    val wrap = ct.style.text.maxWidthPct ?: .85
                    val newWrap = if (half > .1 && wrap > 2 * half) kotlin.math.floor(2 * half * 100) / 100 else ct.style.text.maxWidthPct
                    val tallest = captionPages(p).maxOfOrNull { pageBox(p, it, ct.style, ct.language, .5, newWrap).h } ?: 0.0
                    val y = clampCentre(ct.style.y ?: .72, tallest / 2, z.y + margin, z.y + z.h - margin)
                    t.copy(caption = ct.copy(style = ct.style.copy(y = y, text = ct.style.text.copy(maxWidthPct = newWrap))))
                }
                t.kind == TrackKind.TEXT -> t.copy(items = t.items.map { it ->
                    val item = it as? TextItem
                    if (item == null || found.none { f -> f.itemId == item.id }) it else {
                        // Wrap no wider than the box, then the block's centre inside it.
                        val sc = item.transform?.scale ?: 1.0
                        val room = z.w - 2 * margin
                        val narrowed = if (box(item, a).w > room && room > .1)
                            item.copy(style = item.style.copy(maxWidthPct = kotlin.math.floor(room / sc * 100) / 100)) else item
                        val b = box(narrowed, a)
                        val tr = narrowed.transform ?: Transform()
                        narrowed.copy(transform = tr.copy(x = clampCentre(b.x, b.w / 2, z.x + margin, z.x + z.w - margin),
                            y = clampCentre(b.y, b.h / 2, z.y + margin, z.y + z.h - margin)))
                    }
                })
                else -> t
            }
        }
        return p.copy(tracks = tracks)
    }

    /** A centre kept so [c − half, c + half] sits in [lo, hi] (centred when it can't fit), to 3 decimals. */
    fun clampCentre(c: Double, half: Double, lo: Double, hi: Double): Double {
        val v = if (hi - lo < 2 * half) (lo + hi) / 2 else c.coerceIn(lo + half, hi - half)
        return (v * 1000).roundToInt() / 1000.0
    }
}

/** The choice per project (keyed by the project's source take) and this device's last choice; at most [KEPT] projects. */
data class EditPreviewPrefs(val last: EditPreview? = null, val byProject: Map<String, EditPreview> = emptyMap(), val order: List<String> = emptyList()) {
    fun choice(project: String): EditPreview = byProject[project] ?: last ?: EditPreview()

    fun set(p: EditPreview, project: String): EditPreviewPrefs {
        val o = (order - project) + project
        val keep = o.takeLast(KEPT)
        return EditPreviewPrefs(p, (byProject + (project to p)).filterKeys { it in keep }, keep)
    }

    fun encode(): String = buildJsonObject {
        last?.let { put("last", enc(it)) }
        put("byProject", JsonObject(byProject.mapValues { enc(it.value) }))
        put("order", buildJsonArray { order.forEach { add(JsonPrimitive(it)) } })
    }.toString()

    companion object {
        const val KEPT = 200
        private fun enc(p: EditPreview) = buildJsonObject { put("view", p.view.id); put("safeArea", p.safeArea) }
        private fun dec(o: JsonObject?): EditPreview? {
            val v = PreviewView.of(o?.get("view")?.jsonPrimitive?.contentOrNull) ?: return null
            return EditPreview(v, o?.get("safeArea")?.jsonPrimitive?.booleanOrNull ?: true)
        }

        fun decode(s: String?): EditPreviewPrefs = runCatching {
            val o = kotlinx.serialization.json.Json.parseToJsonElement(s ?: return EditPreviewPrefs()).jsonObject
            EditPreviewPrefs(dec(o["last"] as? JsonObject),
                (o["byProject"] as? JsonObject)?.mapNotNull { (k, v) -> dec(v as? JsonObject)?.let { k to it } }?.toMap() ?: emptyMap(),
                o["order"]?.jsonArray?.mapNotNull { it.jsonPrimitive.contentOrNull } ?: emptyList())
        }.getOrDefault(EditPreviewPrefs())
    }
}

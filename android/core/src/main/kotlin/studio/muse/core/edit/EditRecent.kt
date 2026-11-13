package studio.muse.core.edit

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/*
 * Continue a draft (owner, 2026-11-12; plans/edit-continue-draft.md): opening Edit reopens the last edit where it was left.
 * The owner's edits are server sessions; each also keeps where an editor was left ([EditPlace], POST …/{id}/view, shared
 * with the Mac). Members' editors are local, so their last edits (project and place) are kept on the phone
 * ([EditRecentEntry], [EditRecent.encode]). Pure, so the rules are unit-tested.
 */

/**
 * Where the editor was left. The same JSON as the Mac and the server (`view`): `playhead`, `zoom` (timeline dp / points
 * per second), `tab` (the open panel, lower case: Mac inspector tabs "captions"/"text"/"audio" match), `selection`,
 * `safeArea` (the platform view: "tiktok", "reels", …; "off" or null = Clean), `title`, `at` (ms, set by the server).
 */
data class EditPlace(
    val playhead: Double? = null,
    val zoom: Double? = null,
    val tab: String? = null,
    val binTab: String? = null,
    val mode: String? = null,
    val selection: String? = null,
    val safeArea: String? = null,
    val title: String? = null,
    val at: Long? = null,
) {
    fun toJson(): JsonObject = JsonObject(buildMap {
        playhead?.let { put("playhead", JsonPrimitive(it)) }
        zoom?.let { put("zoom", JsonPrimitive(it)) }
        tab?.let { put("tab", JsonPrimitive(it)) }
        binTab?.let { put("binTab", JsonPrimitive(it)) }
        mode?.let { put("mode", JsonPrimitive(it)) }
        selection?.let { put("selection", JsonPrimitive(it)) }
        safeArea?.let { put("safeArea", JsonPrimitive(it)) }
        title?.let { put("title", JsonPrimitive(it)) }
        at?.let { put("at", JsonPrimitive(it)) }
    })

    /** The same place (when it was saved aside). */
    fun samePlace(o: EditPlace): Boolean = copy(at = null) == o.copy(at = null)

    /** The platform view it names (null: not saved; Clean for "off"). */
    val view: PreviewView? get() = when (safeArea) { null -> null; "off" -> PreviewView.CLEAN; else -> PreviewView.of(safeArea) }

    companion object {
        /** Lenient: odd types are dropped, a non-object is no place. A present `safeArea: null` (the server's "off") reads "off". */
        fun of(e: JsonElement?): EditPlace? {
            val o = e as? JsonObject ?: return null
            fun num(k: String) = (o[k] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull?.takeIf { it.isFinite() }
            fun str(k: String) = (o[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
            return EditPlace(
                playhead = num("playhead"), zoom = num("zoom"), tab = str("tab"), binTab = str("binTab"), mode = str("mode"), selection = str("selection"),
                safeArea = if (o.containsKey("safeArea") && o["safeArea"] is JsonNull) "off" else str("safeArea"),
                title = str("title"), at = (o["at"] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull ?: num("at")?.toLong(),
            )
        }
    }
}

/** One open server session as the recent list needs it (the app maps its DTO). */
data class RecentSession(val id: String, val takeId: String, val status: String = "open", val updatedAt: Long = 0, val lastTouchedAt: Long? = null,
                         val place: EditPlace? = null,
                         /** A blank project nothing was added to ("New" pressed and left): not an edit yet, not listed. */
                         val emptyBlank: Boolean = false)

/** A member's edit kept on this phone (the project and where it was left), or the owner's own record of a session's place. */
data class EditRecentEntry(
    val takeId: String,
    val sessionId: String? = null,
    /** Members: the edit itself. Null for the owner (the server holds the project). */
    val project: JsonObject? = null,
    val place: EditPlace = EditPlace(),
    val title: String = "",
    val savedAt: Long = 0,
) {
    val key: String get() = takeId
}

/** A row of Recent edits. [sessionId] for the owner's server edits, else an edit kept on this phone. */
data class EditRecentItem(val id: String, val takeId: String, val sessionId: String?, val title: String, val lastEditedAt: Long, val place: EditPlace?)

object EditRecent {
    const val SHOWN = 8
    const val KEPT = 12
    const val UNTITLED = "Untitled edit"

    /** The server's sessions and this phone's entries, the last worked on first. A session's newer local place wins. */
    fun items(sessions: List<RecentSession>, local: List<EditRecentEntry>, takeTitle: (String) -> String?): List<EditRecentItem> {
        val out = LinkedHashMap<String, EditRecentItem>()
        for (s in sessions) {
            if (s.status != "open" || s.emptyBlank) continue
            // When the person last worked on it (the saved place); an edit no app has opened (Claude's) by its last change.
            // A change landing later with no one there (a helper's result, Claude's note) doesn't move it up (run 604).
            val at = s.place?.at?.takeIf { it > 0 } ?: maxOf(s.lastTouchedAt ?: 0, s.updatedAt)
            out[s.id] = EditRecentItem(s.id, s.takeId, s.id, title(s.place, s.takeId, takeTitle), at, s.place)
        }
        for (d in local) {
            val sid = d.sessionId
            if (sid != null) {
                val it = out[sid] ?: continue // a session the server no longer lists is closed
                if (d.savedAt > it.lastEditedAt) out[sid] = it.copy(place = d.place.copy(at = d.savedAt), lastEditedAt = d.savedAt)
                continue
            }
            if (d.project == null) continue
            val id = "local:${d.key}"
            out[id] = EditRecentItem(id, d.takeId, null, d.title.ifBlank { title(d.place, d.takeId, takeTitle) }, d.savedAt, d.place.copy(at = d.savedAt))
        }
        return out.values.sortedWith(compareByDescending<EditRecentItem> { it.lastEditedAt }.thenBy { it.id })
    }

    private fun title(p: EditPlace?, takeId: String, takeTitle: (String) -> String?): String =
        p?.title?.trim()?.takeIf { it.isNotEmpty() } ?: takeTitle(takeId) ?: UNTITLED

    /** This phone's entries with [e] as the newest (the same edit's older one replaced), at most [KEPT]. */
    fun saved(list: List<EditRecentEntry>, e: EditRecentEntry): List<EditRecentEntry> = (listOf(e) + list.filter { it.key != e.key }).take(KEPT)

    fun encode(list: List<EditRecentEntry>): String = JsonArray(list.map { e ->
        JsonObject(buildMap {
            put("takeId", JsonPrimitive(e.takeId))
            e.sessionId?.let { put("sessionId", JsonPrimitive(it)) }
            e.project?.let { put("project", it) }
            put("place", e.place.toJson())
            put("title", JsonPrimitive(e.title))
            put("savedAt", JsonPrimitive(e.savedAt))
        })
    }).toString()

    /** A damaged or missing file reads as empty. */
    fun decode(text: String?): List<EditRecentEntry> {
        if (text.isNullOrBlank()) return emptyList()
        val arr = runCatching { Json.parseToJsonElement(text) as? JsonArray }.getOrNull() ?: return emptyList()
        return arr.mapNotNull { el ->
            val o = el as? JsonObject ?: return@mapNotNull null
            val take = (o["takeId"] as? JsonPrimitive)?.content ?: return@mapNotNull null
            EditRecentEntry(take, (o["sessionId"] as? JsonPrimitive)?.content, o["project"] as? JsonObject, EditPlace.of(o["place"]) ?: EditPlace(),
                (o["title"] as? JsonPrimitive)?.content ?: "", (o["savedAt"] as? JsonPrimitive)?.longOrNull ?: 0)
        }
    }

    /** Assets a clip uses (a take's or an upload's video, picture or sound; not library items or LUTs) with no file here: shown "Missing". */
    fun missingAssets(p: EditProject, have: Set<String>): Set<String> {
        val used = p.tracks.flatMap { it.items }.mapNotNull {
            when (it) { is VideoClip -> it.asset; is ImageItem -> it.asset; is AudioClip -> it.asset; else -> null }
        }.toSet()
        return p.assets.filter { a ->
            a.id in used && (a.take != null || a.upload != null) && (a.kind == AssetKind.VIDEO || a.kind == AssetKind.IMAGE || a.kind == AssetKind.AUDIO) && a.id !in have
        }.map { it.id }.toSet()
    }

    /** "Just now", "5 min ago", "3 h ago", "Yesterday", "Monday", "13 Oct", "8 Oct 2025". */
    fun lastEditedText(atMs: Long, nowMs: Long, zone: ZoneId = ZoneId.systemDefault()): String {
        val s = (nowMs - atMs) / 1000
        if (s < 60) return "Just now"
        if (s < 3600) return "${s / 60} min ago"
        val at = Instant.ofEpochMilli(atMs).atZone(zone); val now = Instant.ofEpochMilli(nowMs).atZone(zone)
        val day: LocalDate = at.toLocalDate()
        if (day == now.toLocalDate()) return "${s / 3600} h ago"
        if (day == now.toLocalDate().minusDays(1)) return "Yesterday"
        val f = when {
            s < 6 * 86_400 -> "EEEE"
            at.year == now.year -> "d MMM"
            else -> "d MMM yyyy"
        }
        return DateTimeFormatter.ofPattern(f, Locale.UK).format(at)
    }
}


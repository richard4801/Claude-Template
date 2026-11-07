package studio.muse.app.data

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.longOrNull
import java.util.Base64
import java.util.UUID

// Demo mode's AI suite build step 2 (plans/api.md "The new Suite's server pieces"), with the server's rules
// (server/api/src/suite/drafts.ts, rigs.ts, feed.ts): saved rigs, rig and draft checks, and the takes feed.

/**
 * The studio's saved rigs. A member keeps their own; the owner sees, renames and deletes every rig in the studio.
 * Ids are checked against the demo camera catalog ([FakeSuite.camera], the server's own answer).
 */
class FakeSuiteRigs(private val now: () -> Long, private val camera: () -> CameraCatalog) {
    private data class Row(val id: String, val name: String, val rig: SuiteRig, val userId: String, val createdAt: Long, val updatedAt: Long)

    private val rows = mutableListOf<Row>().apply {
        val t = now()
        add(Row("rig_golden", "Golden film", GOLDEN_FILM, OWNER_ID, t - 3 * DAY, t - 2 * HOUR))
        add(Row("rig_talk", "Talking head", SuiteRig(body = "phone", lighting = "ring_light", shotSize = "mcu", height = "eye", genre = "ugc"), OWNER_ID, t - 5 * DAY, t - DAY))
        add(Row("rig_neon", "Neon night", SuiteRig(palette = "hyper_neon", lighting = "practicals", lens = "anamorphic", tempo = "dynamic"), MEMBER_ID, t - 2 * DAY, t - 6 * HOUR))
    }

    private fun view(r: Row, userId: String) = SuiteRigView(r.id, r.name, r.rig, r.userId, r.userId == userId, r.createdAt, r.updatedAt)

    /** Most recently changed first; the owner gets everyone's, theirs first. */
    fun list(userId: String, owner: Boolean): List<SuiteRigView> = rows
        .filter { owner || it.userId == userId }
        .sortedWith(compareByDescending<Row> { it.updatedAt }.thenBy { it.id })
        .map { view(it, userId) }
        .sortedByDescending { it.mine }

    fun create(userId: String, name: String, rig: SuiteRig): SuiteRigView {
        val n = checkName(name)
        check(rig, camera(), "rig")
        if (rows.count { it.userId == userId } >= MAX_PER_USER) throw ApiException("too_many_rigs", "You can keep $MAX_PER_USER rigs · delete one first")
        val t = now()
        val r = Row("rig_" + UUID.randomUUID().toString().take(10), n, rig, userId, t, t)
        rows += r
        return view(r, userId)
    }

    fun update(userId: String, owner: Boolean, id: String, name: String?, rig: SuiteRig?): SuiteRigView {
        val n = name?.let(::checkName)
        rig?.let { check(it, camera(), "rig") }
        val r = editable(userId, owner, id)
        if (n == null && rig == null) return view(r, userId)
        val u = r.copy(name = n ?: r.name, rig = rig ?: r.rig, updatedAt = now())
        rows[rows.indexOf(r)] = u
        return view(u, userId)
    }

    fun delete(userId: String, owner: Boolean, id: String) { rows.remove(editable(userId, owner, id)) }

    /** Your own rig, or any for the owner; anyone else's reads as not found. */
    private fun editable(userId: String, owner: Boolean, id: String): Row =
        rows.firstOrNull { it.id == id && (owner || it.userId == userId) } ?: throw ApiException("not_found", "Rig not found")

    companion object {
        const val MAX_PER_USER = 100
        /** The demo studio's owner and the member tests act as (SampleData.members). */
        const val OWNER_ID = "u1"
        const val MEMBER_ID = "u_maya"
        private const val HOUR = 3_600_000L
        private const val DAY = 24 * HOUR
        /** Demo model's default rig (and the owner's "Golden film"). */
        val GOLDEN_FILM = SuiteRig(body = "film_35", lens = "vintage", focalMm = 50.0, aperture = "f2", lighting = "golden_hour", palette = "golden_warmth",
            gradeLook = true, era = "1990s", moves = listOf(SuiteRigMove("dolly_in", 0.4)))
        val DEMO_DEFAULT_RIG = SuiteRig(body = "film_35", lighting = "golden_hour", palette = "golden_warmth", shotSize = "mcu", moves = listOf(SuiteRigMove("micro_push")))

        private fun bad(msg: String): Nothing = throw ApiException("bad_request", msg)

        fun checkName(name: String): String {
            val n = name.trim()
            if (n.isEmpty()) bad("name: Give the rig a name")
            if (n.length > 60) bad("name: String must contain at most 60 character(s)")
            return n
        }

        /** Server RigSchema: catalog ids (hidden and merged ones too), focal 8–200, at most 2 moves with intensity 0–1. */
        fun check(rig: SuiteRig, cat: CameraCatalog, at: String) {
            fun pick(field: String, what: String, v: String?, ids: List<String>) { if (v != null && v !in ids) bad("$at.$field: unknown $what \"$v\"") }
            pick("body", "camera body", rig.body, cat.bodies.map { it.id })
            pick("lens", "lens", rig.lens, cat.lenses.map { it.id })
            pick("aperture", "aperture", rig.aperture, cat.apertures.map { it.id })
            pick("height", "angle", rig.height, cat.heights.map { it.id })
            pick("shotSize", "framing", rig.shotSize, cat.shotSizes.map { it.id })
            pick("lighting", "lighting", rig.lighting, cat.lighting.map { it.id })
            pick("palette", "palette", rig.palette, cat.palettes.map { it.id })
            pick("stock", "film stock", rig.stock, cat.looks.map { it.id })
            pick("genre", "genre", rig.genre, cat.genres.map { it.id })
            pick("era", "era", rig.era, cat.eras.map { it.id })
            pick("tempo", "tempo", rig.tempo, cat.tempos.map { it.id })
            pick("format", "format", rig.format, cat.ugcFormats.map { it.id })
            rig.focalMm?.let { if (it < 8) bad("$at.focalMm: Number must be greater than or equal to 8"); if (it > 200) bad("$at.focalMm: Number must be less than or equal to 200") }
            val moves = rig.moves ?: return
            if (moves.size > 2) bad("$at.moves: Array must contain at most 2 element(s)")
            val ids = (cat.moves.map { it.id } + cat.library.map { it.id }).toSet()
            moves.forEachIndexed { i, m ->
                if (m.id !in ids) bad("$at.moves.$i.id: unknown move \"${m.id}\"")
                m.intensity?.let { if (it < 0 || it > 1) bad("$at.moves.$i.intensity: Number must be between 0 and 1") }
            }
        }

        /** Server DraftSchema (refused, not dropped): a known tool, at most 64 KB, the bottom-bar values in range. */
        fun checkDraft(d: SuiteDraft?) {
            d ?: return
            val tool = d["tool"]
            if (tool == null || (tool as? JsonPrimitive)?.isString != true) bad("Invalid draft: tool Required")
            if (d.tool !in SuiteDrafts.TOOLS) bad("Invalid draft: tool Invalid enum value. Expected ${SuiteDrafts.TOOLS.joinToString(" | ") { "'$it'" }}, received '${d.tool}'")
            d["tokens"]?.let { if (it !is JsonArray) bad("Invalid draft: tokens Expected array"); if (it.size > 400) bad("Invalid draft: tokens Array must contain at most 400 element(s)") }
            d.takes?.let { if (it !in 1..8) bad("Invalid draft: takes Number must be between 1 and 8") }
            d.count?.let { if (it !in 1..8) bad("Invalid draft: count Number must be between 1 and 8") }
            if (d.json.toString().length > MAX_DRAFT_BYTES) bad("Invalid draft:  a draft is at most ${MAX_DRAFT_BYTES / 1024} KB")
        }

        private const val MAX_DRAFT_BYTES = 64 * 1024
    }
}

/** The takes feed over demo mode's jobs and takes (server suite/feed.ts): the same items, order, filters and cursor. */
object FakeSuiteFeed {
    private fun bad(msg: String): Nothing = throw ApiException("bad_request", msg)

    /** The cursor is the last item's (createdAt, id), base64url JSON like the server's. */
    fun encodeCursor(createdAt: Long, id: String): String =
        Base64.getUrlEncoder().withoutPadding().encodeToString(buildJsonArray { add(JsonPrimitive(createdAt)); add(JsonPrimitive(id)) }.toString().toByteArray())

    private fun decodeCursor(c: String): Pair<Long, String> = runCatching {
        val a = kotlinx.serialization.json.Json.parseToJsonElement(String(Base64.getUrlDecoder().decode(c))) as JsonArray
        val t = (a[0] as JsonPrimitive).takeIf { !it.isString }!!.longOrNull!!
        val id = (a[1] as JsonPrimitive).takeIf { it.isString }!!.content
        t to id
    }.getOrElse { bad("Invalid cursor") }

    /** The tool a job was made with: its draft's, else from its request (suite mode, upscale, or the video studio's swap). */
    fun jobTool(j: Job?): String = j?.draft?.tool ?: when (j?.request?.engine) {
        "upscale" -> "upscale"
        SuiteRules.ENGINE -> when (j.request.mode) { "extend" -> "extend"; "recast" -> "recast"; else -> "shot" }
        else -> "swap"
    }

    /** A take's tool: its own draft's (photos), a still is a photo, else its job's. */
    fun takeTool(t: Take, job: Job?): String = t.draft?.tool ?: if (t.kind == "shot") "photo" else jobTool(job)

    /**
     * One page. [hiddenJobs]: jobs deleted from Queue (they drop out with their takes). [takeModels]: the character of each
     * photo (stills have no job to say it).
     */
    fun page(q: SuiteFeedQuery, jobs: List<Job>, takes: List<Take>, models: List<Model>, hiddenJobs: Set<String>, takeModels: Map<String, String>): SuiteFeedPage {
        q.tool.firstOrNull { it !in SuiteDrafts.TOOLS }?.let { bad("Invalid feed query: tool unknown value \"$it\" (one of ${SuiteDrafts.TOOLS.joinToString(", ")})") }
        q.status.firstOrNull { it !in SuiteFeedQuery.STATUSES }?.let { bad("Invalid feed query: status unknown value \"$it\" (one of ${SuiteFeedQuery.STATUSES.joinToString(", ")})") }
        val limit = q.limit ?: SuiteFeedQuery.PAGE
        if (limit !in 1..SuiteFeedQuery.PAGE_MAX) bad("Invalid feed query: limit Number must be between 1 and ${SuiteFeedQuery.PAGE_MAX}")
        val cursor = q.cursor?.takeIf { it.isNotEmpty() }?.let(::decodeCursor)
        val tools = q.tool.toSet().ifEmpty { null }
        val wantPending = listOf("queued", "running", "failed").filter { q.status.isEmpty() || it in q.status }
        val wantDone = q.status.isEmpty() || "done" in q.status
        val byId = jobs.associateBy { it.id }

        val pending = jobs.filter { it.state in wantPending && it.id !in hiddenJobs }
            .filter { q.model == null || it.modelId == q.model }
            .filter { tools == null || jobTool(it) in tools }
            .map(::jobItem)
        val done = if (!wantDone) emptyList() else takes.filter { it.kind == "take" || it.kind == "shot" }
            .filter { it.jobId == null || it.jobId !in hiddenJobs }
            .map { t -> t to byId[t.jobId] }
            .filter { (t, j) -> q.model == null || (takeModels[t.id] ?: j?.modelId?.ifEmpty { null }) == q.model }
            .filter { (t, j) -> tools == null || takeTool(t, j) in tools }
            .map { (t, j) -> takeItem(t, j, takeModels[t.id] ?: j?.modelId?.ifEmpty { null }, models) }

        val all = (pending + done)
            .filter { i -> cursor == null || i.createdAt < cursor.first || (i.createdAt == cursor.first && i.id < cursor.second) }
            .sortedWith(compareByDescending<SuiteFeedItem> { it.createdAt }.thenByDescending { it.id })
        val page = all.take(limit)
        val last = page.lastOrNull()
        return SuiteFeedPage(page, if (all.size > limit && last != null) encodeCursor(last.createdAt, last.id) else null)
    }

    private fun jobItem(j: Job): SuiteFeedItem {
        val seconds = (j.request.seconds ?: j.request.clipSeconds)?.takeIf { it > 0 }
        val aspect = j.draft?.aspect
        val takes = j.request.takes.takeIf { it > 0 } ?: 1
        val failed = j.state == "failed"
        return SuiteFeedItem(
            id = j.id, kind = "job", status = j.state, tool = jobTool(j), jobId = j.id, title = j.title, modelId = j.modelId.ifEmpty { null }, modelName = j.modelName.ifEmpty { null },
            createdAt = j.createdAt, poster = j.thumb, aspect = aspect, durationSec = seconds, takes = takes, price = j.cost,
            progress = j.progress, phase = j.phase.ifEmpty { null }, secondsLeft = if (j.state == "running") j.secondsLeft else null, blocked = j.blocked,
            error = if (failed) j.error ?: "It didn’t finish" else null, errorCode = if (failed) j.errorCode else null, refunded = j.refunded.takeIf { it > 0 },
            label = j.engineLabel.ifEmpty { null },
            summary = SuiteFeedRules.summary(j.draft, aspect = aspect, seconds = seconds, takes = takes),
        )
    }

    private fun takeItem(t: Take, j: Job?, modelId: String?, models: List<Model>): SuiteFeedItem {
        val draft = t.draft ?: j?.draft
        val photo = t.kind == "shot"
        val aspect = SuiteFeedRules.aspectOf(t.width, t.height) ?: draft?.aspect ?: if (photo) "9:16" else null
        val seconds = if (photo) null else (t.durationSec ?: j?.request?.seconds)?.takeIf { it > 0 }
        val summary = if (photo) SuiteFeedRules.summary(draft, aspect = aspect, count = t.of)
            else SuiteFeedRules.summary(draft, aspect = aspect, seconds = j?.request?.seconds?.takeIf { it > 0 } ?: seconds, takes = j?.request?.takes?.takeIf { it > 0 } ?: t.of)
        return SuiteFeedItem(
            id = t.id, kind = if (photo) "photo" else "take", status = "done", tool = takeTool(t, j), jobId = t.jobId, takeId = t.id, title = t.title, label = t.label,
            modelId = modelId, modelName = models.firstOrNull { it.id == modelId }?.name, createdAt = t.createdAt, poster = t.thumb,
            videoUrl = if (photo) null else t.videoUrl, aspect = aspect, durationSec = seconds, index = t.index, of = t.of, price = t.cost, final = t.status == "final",
            summary = summary,
        )
    }
}

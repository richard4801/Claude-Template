package studio.muse.app.ui.screens.suite.composer

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.put
import studio.muse.app.data.SuiteDraft
import studio.muse.app.data.SuiteDrafts
import studio.muse.app.data.SuiteRig
import studio.muse.app.data.SuiteRigMove

/*
 * AI suite, Reuse settings (plans/ai-suite-design.md; the Mac's MuseCore ComposerDrafts, same JSON so a take made on either
 * app comes back on the other): the composer's draft goes with each Shot and Photo request as `draft` and returns on the
 * job and every take. Restoring puts the prompt (with its chip keys), the rig and the bar's values back exactly. Slots are
 * not restored (their uploads may be gone).
 */
object ComposerDrafts {
    /** The prompt's parts: {t:"text",text} · {t:"move",id,label,category,intensity,key} · {t:"mention",kind,id,label,key}. */
    fun encode(tokens: PromptTokens): JsonArray = JsonArray(tokens.parts.map { p ->
        when (p) {
            is PromptPart.Text -> buildJsonObject { put("t", "text"); put("text", p.text) }
            is PromptPart.Move -> buildJsonObject {
                put("t", "move"); put("id", p.id); put("label", p.label); put("category", p.category); put("intensity", p.intensity); put("key", p.key)
            }
            is PromptPart.Mention -> buildJsonObject { put("t", "mention"); put("kind", p.kind); put("id", p.id); put("label", p.label); put("key", p.key) }
        }
    })

    fun decode(values: List<JsonElement>): PromptTokens = PromptTokens(values.mapNotNull { v ->
        val o = v as? JsonObject ?: return@mapNotNull null
        fun str(k: String) = (o[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
        fun num(k: String) = (o[k] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull
        when (str("t")) {
            "text" -> str("text")?.let { PromptPart.Text(it) }
            "move" -> {
                val id = str("id") ?: return@mapNotNull null
                val key = num("key")?.toLong() ?: return@mapNotNull null
                PromptPart.Move(id, str("label") ?: id, str("category") ?: "", num("intensity")?.toInt() ?: 50, key)
            }
            "mention" -> {
                val kind = str("kind") ?: return@mapNotNull null
                val id = str("id") ?: return@mapNotNull null
                val key = num("key")?.toLong() ?: return@mapNotNull null
                PromptPart.Mention(kind, id, str("label") ?: id, key)
            }
            else -> null
        }
    })

    /** The draft sent with a request ([photoCount], [presetId]: the Photo tool's). */
    fun draft(d: ComposerDraft, photoCount: Int? = null, presetId: String? = null): SuiteDraft {
        val extra = buildMap<String, JsonElement> {
            put("tokens", encode(d.tokens))
            d.outfitId?.let { put("outfitId", JsonPrimitive(it)) }
            if (d.references.isNotEmpty()) put("references", JsonArray(d.references.map { r ->
                JsonObject(buildMap {
                    put("uploadId", JsonPrimitive(r.uploadId)); put("url", JsonPrimitive(r.url)); put("use", JsonPrimitive(r.use))
                    r.label?.let { put("label", JsonPrimitive(it)) }
                })
            }))
            presetId?.let { put("presetId", JsonPrimitive(it)) }
            // Speaking: on or off; Auto is left out (the strict server refuses nulls), and reads back as Auto.
            if (d.tool != ComposerTool.PHOTO) d.speaking?.let { put("speaking", JsonPrimitive(it)) }
            // Movement → Directed and the pinned model travel with the draft, so Claude's choices and the composer's agree
            // (server suite/assist.ts requestOf reads directed.camera, engineModel and resolution).
            d.directed?.let { j -> runCatching { kotlinx.serialization.json.Json.parseToJsonElement(j) as? JsonObject }.getOrNull()?.let { put("directed", JsonObject(mapOf("camera" to it))) } }
            d.engineModel?.let { e -> put("engineModel", JsonPrimitive(e)); d.resolution?.let { put("resolution", JsonPrimitive(it)) } }
        }
        val rig = SuiteRig.from(d.settings)
        return if (d.tool == ComposerTool.PHOTO) SuiteDrafts.of("photo", count = photoCount, rig = rig, extra = extra)
        else SuiteDrafts.of(d.tool.id, quality = d.quality, aspect = d.aspect, duration = d.duration.toDouble(), takes = d.takes, sound = d.sound, rig = rig, extra = extra)
    }

    /** The composer as the draft left it. Unknown or missing fields keep the current values. */
    fun restore(s: SuiteDraft, into: ComposerDraft): ComposerDraft {
        var out = into
        s.tool?.let { t -> ComposerTool.entries.firstOrNull { it.id == t || it.wire == t }?.let { out = out.copy(tool = it) } }
        s.quality?.let { out = out.copy(quality = it) }
        s.aspect?.let { out = out.copy(aspect = it) }
        s.duration?.let { out = out.copy(duration = Math.round(it).toInt()) }
        s.takes?.let { out = out.copy(takes = it) }
        s.sound?.let { out = out.copy(sound = it) }
        out = out.copy(speaking = s.speaking)
        s.rig?.let { out = out.copy(settings = it.toSettings()) }
        (s["tokens"] as? JsonArray)?.let { out = out.copy(tokens = decode(it)) }
        (s["outfitId"] as? JsonPrimitive)?.takeIf { it.isString }?.content?.let { out = out.copy(outfitId = it) }
        // Claude in the Suite: the draft's reference images; a draft without the field has none.
        out = out.copy(references = (s["references"] as? JsonArray).orEmpty().mapNotNull { e ->
            val o = e as? JsonObject ?: return@mapNotNull null
            fun str(k: String) = (o[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
            val url = str("url") ?: return@mapNotNull null
            studio.muse.app.data.DraftReference(str("uploadId").orEmpty(), url, str("use") ?: "style", str("label"))
        })
        // Directed (Claude's suite_set_draft directed: a camera session's camera and guides) and the pinned model come back.
        val dir = ((s["directed"] as? JsonObject)?.get("camera") as? JsonObject)?.let { JsonObject(it + ("mode" to JsonPrimitive("directed"))).toString() }
        val e = (s["engineModel"] as? JsonPrimitive)?.takeIf { it.isString }?.content
        val r = (s["resolution"] as? JsonPrimitive)?.takeIf { it.isString }?.content
        return out.copy(collapsed = false, directed = dir, engineModel = e, resolution = if (e == null) null else r)
    }

    /** The characters @-mentioned in the prompt, in order (a model's default rig applies only when there is exactly one). */
    fun characterIds(t: PromptTokens): List<String> = t.mentions.filter { it.kind == "character" }.map { it.id }

    /** The prompt's #moves as a saved rig's moves (intensity 0–1). */
    fun rigMoves(t: PromptTokens): List<SuiteRigMove>? = t.moves.map { SuiteRigMove(it.id, it.intensity.coerceIn(0, 100) / 100.0) }.ifEmpty { null }

}

package studio.muse.app.ui.screens.suite

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import studio.muse.app.data.SuiteShotRequest
import studio.muse.app.data.SuiteWireJson

/**
 * Claude sees what is on screen (owner, 2026-11-11: "Claude still can't see clips added to swap or anywhere"). The shared
 * draft the composer syncs (PATCH /v1/suite/assist) carries `screen`: the request Generate would send now (Swap/Recast's
 * clip, Extend's video, the slots' frames and references, a Directed camera with its Blender guides, the pinned model)
 * and every input in words, each with the id Claude watches or sees it by. Server: suite/screen.ts. Same as the Mac's
 * SuiteScreen.swift.
 */
object SuiteScreen {
    data class Input(
        val slot: String, val kind: String, val label: String? = null, val role: String? = null, val clipId: String? = null, val uploadId: String? = null,
        val takeId: String? = null, val cameraSessionId: String? = null, val key: String? = null, val url: String? = null, val seconds: Double? = null,
        val state: String? = null,
    ) {
        fun json(): JsonObject = JsonObject(buildMap<String, JsonElement> {
            put("slot", JsonPrimitive(slot.take(40))); put("kind", JsonPrimitive(kind))
            fun s(k: String, v: String?, max: Int = 80) { if (!v.isNullOrEmpty()) put(k, JsonPrimitive(v.take(max))) }
            s("label", label, 120); s("role", role, 20); s("clipId", clipId); s("uploadId", uploadId); s("takeId", takeId)
            s("cameraSessionId", cameraSessionId); s("key", key, 300); s("url", url, 2000); s("state", state, 20)
            seconds?.takeIf { it > 0 && it.isFinite() }?.let { put("seconds", JsonPrimitive(minOf(it, 3600.0))) }
        })
    }

    /** The filled slots in the composer's order ("start", "middle 1", "reference 2", "video 1", "audio"). */
    fun inputs(slots: InputSlots): List<Input> =
        slots.values.entries.sortedWith(compareBy({ it.key.kind.ordinal }, { it.key.index })).map { (id, v) ->
            val slot = when (id.kind) {
                SlotKind.START -> "start"; SlotKind.END -> "end"; SlotKind.AUDIO -> "audio"
                SlotKind.MIDDLE -> "middle ${id.index + 1}"; SlotKind.IMAGE -> "reference ${id.index + 1}"; SlotKind.VIDEO -> "video ${id.index + 1}"
            }
            val state = when { v.progress != null -> "uploading"; v.error != null -> "failed"; else -> null }
            val name = v.name.substringBeforeLast('.').ifBlank { null }
            if (id.kind.isImage) Input(slot, "image", name, if (id.kind == SlotKind.IMAGE) v.role else null, url = v.image?.url, state = state)
            else Input(slot, if (id.kind == SlotKind.AUDIO) "audio" else "video", name, if (id.kind == SlotKind.VIDEO) v.use else null,
                key = v.media?.key, url = v.media?.url, seconds = v.media?.seconds, state = state)
        }

    /** The Blender guide clip of a Directed camera (the camera JSON the camera stage applied), when it has one. */
    fun guide(directed: String?): Input? {
        val cam = directed?.let { runCatching { kotlinx.serialization.json.Json.parseToJsonElement(it) as? JsonObject }.getOrNull() } ?: return null
        if ((cam["mode"] as? JsonPrimitive)?.content != "directed") return null
        val g = cam["guide"] as? JsonObject ?: return null
        val v = g["video"] as? JsonObject
        fun str(o: JsonObject?, k: String) = (o?.get(k) as? JsonPrimitive)?.takeIf { it.isString }?.content
        val key = str(v, "key"); val url = str(v, "url"); val session = str(g, "cameraSessionId")
        if (key == null && url == null && session == null) return null
        return Input("guide", "video", "Blender guide", str(g, "use") ?: "blocking", cameraSessionId = session, key = key, url = url,
            seconds = (v?.get("seconds") as? JsonPrimitive)?.content?.toDoubleOrNull())
    }

    /** The draft's `screen`. [at] null leaves the time out (to compare with what was sent). */
    fun json(tool: String, request: SuiteShotRequest?, inputs: List<Input>, at: Long? = System.currentTimeMillis()): JsonObject = JsonObject(buildMap {
        put("tool", JsonPrimitive(tool))
        put("inputs", JsonArray(inputs.take(24).map { it.json() }))
        at?.let { put("at", JsonPrimitive(it)) }
        request?.let { r ->
            val o = SuiteWireJson.encodeToJsonElement(SuiteShotRequest.serializer(), r) as? JsonObject
            if (o != null) put("request", JsonObject(o - "draft"))
        }
    })
}

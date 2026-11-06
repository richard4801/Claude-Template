package studio.muse.core.edit

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull

/*
 * Edit sessions (workstream 3, plans/claude-editing.md A): the pure parts of keeping the Edit suite in step with the
 * server's session — rebasing a local pending change on a newer server project, and Claude's export preset.
 */
object SessionSync {
    /**
     * The local project after the server moved from [synced] to [server] while the app had [local] (not yet sent):
     * the local change `diff(synced, local)` re-applied on top of [server] when it still applies and gives a valid
     * project, else [server] (last writer wins per change). Also returns whether the local change survived.
     */
    fun rebase(synced: JsonElement, local: JsonElement, server: JsonElement, valid: (JsonElement) -> Boolean = { true }): Pair<JsonElement, Boolean> {
        val mine = JsonPatch.diff(synced, local)
        if (mine.isEmpty()) return server to false
        val merged = try { JsonPatch.apply(server, mine) } catch (_: PatchException) { return server to false }
        return if (valid(merged)) merged to true else server to false
    }

    /**
     * Claude's export preset (`{ratio?, resolution?, fps?, codec?, captions?}`) over the owner's settings. The
     * Disclosure switches (AI label, Content Credentials) are never taken from it: they stay as the owner set them.
     */
    fun applyExportPreset(s: ExportSettings, preset: JsonObject?): ExportSettings {
        preset ?: return s
        fun str(k: String) = (preset[k] as? JsonPrimitive)?.takeIf { it.isString }?.content?.lowercase()
        val shape = str("ratio")?.let { r -> ExportShape.entries.firstOrNull { it.label == r } } ?: s.shape
        val res = when (str("resolution")) { "720p" -> ExportResolution.HD; "1080p" -> ExportResolution.FULL_HD; "4k", "2160p" -> ExportResolution.UHD; else -> s.resolution }
        val fps = (preset["fps"] as? JsonPrimitive)?.doubleOrNull?.toInt()?.takeIf { it in setOf(24, 25, 30, 60) } ?: s.fps
        val codec = when (str("codec")) { "h264" -> ExportCodec.H264; "hevc", "h265" -> ExportCodec.HEVC; else -> s.codec }
        val captions = when (str("captions")) { "burn" -> CaptionExport.BURN_IN; "srt" -> CaptionExport.SRT; else -> s.captions }
        return s.copy(shape = shape, resolution = res, fps = fps, codec = codec, captions = captions)
    }
}

package studio.muse.app.ui.screens.edit

import kotlinx.coroutines.delay
import studio.muse.app.data.ApiException
import studio.muse.app.data.MuseApi
import studio.muse.core.edit.RecreateRender
import java.io.File

/**
 * Recreate's built edit rendered on the studio server (plans/api.md "The built edit, rendered" and Recreate "Export"),
 * so Compare and the export show the same pixels on every app. The device's own engine ([RecreateLocalEdit]) is the
 * fallback: each call returns null when the server can't render (an older server, a failed render, no file), and the
 * caller then renders on the phone. Renders are free (the server's CPU, no charge).
 */
class RecreateServerRender(private val api: MuseApi, private val cacheDir: File, private val pollMs: Long = 1_500, private val maxWaitMs: Long = 5 * 60_000) {
    /** A rendered file and what the server said about it. */
    class Rendered(val file: File, val render: RecreateRender)

    /** Compare: the edit session's current revision as a preview video, or null (play it on the device instead). */
    suspend fun preview(sessionId: String): Rendered? = fallbackOnError {
        val r = follow(api.editPreview(sessionId, start = true)) { rev -> api.editPreview(sessionId, start = false, revision = rev) } ?: return@fallbackOnError null
        val f = File(cacheDir, "recreate_preview_${safe(sessionId)}_${r.revision ?: 0}.mp4")
        if (f.length() > 0 || api.editPreviewFile(sessionId, r.revision, f)) Rendered(f, r) else null
    }

    /**
     * The export: [guide] puts the reference's own sound under it (else silent). Throws [ApiException]
     * `no_reference_sound` when the original's sound isn't kept any more (offer silent); null means export on the device.
     */
    suspend fun export(referenceId: String, sessionId: String, guide: Boolean, onRendering: () -> Unit = {}): Rendered? {
        val sound = if (guide) "guide" else "silent"
        return fallbackOnError(rethrow = { it is ApiException && it.code == NO_SOUND }) {
            val first = api.recreateExport(referenceId, sessionId, sound, start = true)
            if (first.rendering) onRendering()
            val r = follow(first) { rev -> api.recreateExport(referenceId, sessionId, sound, start = false, revision = rev) } ?: return@fallbackOnError null
            val f = File(cacheDir, "recreate_export_${safe(referenceId)}_${sound}_${r.revision ?: 0}.mp4")
            f.delete()
            if (api.recreateExportFile(referenceId, sessionId, sound, r.revision, f)) Rendered(f, r) else null
        }
    }

    /** Polls a render until it is ready (returned) or failed, gone or too slow (null). */
    private suspend fun follow(start: RecreateRender, poll: suspend (Int?) -> RecreateRender): RecreateRender? {
        var r = start
        var waited = 0L
        while (r.rendering && waited < maxWaitMs) { delay(pollMs); waited += pollMs; r = poll(r.revision ?: start.revision) }
        return r.takeIf { it.ready }
    }

    private suspend fun <T> fallbackOnError(rethrow: (Throwable) -> Boolean = { false }, block: suspend () -> T?): T? = try { block() } catch (e: Throwable) {
        if (e is kotlinx.coroutines.CancellationException || rethrow(e)) throw e
        null
    }

    private fun safe(id: String) = id.replace(Regex("[^A-Za-z0-9_]"), "_").take(64)

    companion object { const val NO_SOUND = "no_reference_sound" }
}

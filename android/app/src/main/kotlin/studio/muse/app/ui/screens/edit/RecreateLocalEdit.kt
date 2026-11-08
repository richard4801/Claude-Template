package studio.muse.app.ui.screens.edit

import android.content.Context
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.CompositionPlayer
import studio.muse.app.data.MuseApi
import studio.muse.app.platform.VideoEditEngine
import studio.muse.app.platform.edit.EditCompositionEngine
import studio.muse.app.platform.edit.LookLibrary
import studio.muse.core.edit.EditJson
import studio.muse.core.edit.EditProject
import java.io.File

/**
 * Recreate's built edit, on the device (Release 1: Compare and export are local on both apps; there is no server
 * render). After apply, the edit session holds the recipe built from your takes and the new shots; this loads that
 * project, downloads each take it uses once, and hands it to the editor's own composition engine: a preview player for
 * Compare (its timeline is the reference's, since the cuts land on the reference's times), and the export.
 */
@androidx.annotation.OptIn(UnstableApi::class)
class RecreateLocalEdit(context: Context, private val api: MuseApi) {
    private val app = context.applicationContext
    private val looks by lazy { LookLibrary(app) }
    private val engine by lazy { VideoEditEngine(app) }
    private val composer by lazy { EditCompositionEngine(app, looks) }
    private val files = HashMap<String, File>()
    var project: EditProject? = null
        private set

    /** The session's project, with a local file for every take it uses that has a video (the others are left out). */
    suspend fun load(sessionId: String): EditProject {
        val p = EditJson.parse(api.editSession(sessionId).project)
        val takes = api.listTakes()
        for (a in p.assets) {
            if (a.id in files) continue
            val url = a.take?.let { id -> takes.firstOrNull { it.id == id }?.videoUrl } ?: continue
            runCatching { engine.fetchSource(url) {} }.onFailure { if (it is kotlinx.coroutines.CancellationException) throw it }.getOrNull()?.let { files[a.id] = it }
        }
        project = p
        return p
    }

    /** True when the built edit has something to play (at least one take on the device). */
    val playable: Boolean get() = project != null && files.isNotEmpty()

    /** A prepared preview player for the built edit, or null when nothing can play. The caller releases it. */
    fun player(): CompositionPlayer? {
        val p = project?.takeIf { playable } ?: return null
        return runCatching {
            composer.previewPlayer(composer.plan(playableProject(p, files.keys), files), files).also { it.prepare() }
        }.getOrNull()
    }
}

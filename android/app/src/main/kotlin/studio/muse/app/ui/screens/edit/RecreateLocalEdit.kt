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
 * Recreate's built edit, on the device: the fallback when the studio server can't render it ([RecreateServerRender]
 * comes first, so pixels match across apps). After apply, the edit session holds the recipe built from your takes and the new shots; this loads that
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

    /**
     * Exports the built edit to an MP4 with the reference's sound as the guide track ([guide]: the reference video on
     * this device, its sound only), or silent and timed for the sound ([guide] null), and saves it to the phone
     * (Movies/MUSE). Returns the saved name.
     */
    suspend fun export(guide: File?, guideSec: Double, onProgress: (Float) -> Unit): String {
        val p = project?.takeIf { playable } ?: throw IllegalStateException("The built edit has no video on this phone yet")
        val all = HashMap(files)
        val shaped = if (guide != null) { all[studio.muse.core.edit.RecreateExport.GUIDE_ASSET] = guide; studio.muse.core.edit.RecreateExport.withGuide(playableProject(p, files.keys), guideSec) }
            else studio.muse.core.edit.RecreateExport.silent(playableProject(p, files.keys))
        val made = composer.export(composer.plan(shaped, all), all, onProgress)
        try { return saveToMovies(made.file) } finally { made.file.delete() }
    }

    /** Saves a finished video to the phone (Movies/MUSE), from the server's export or the device's. Returns its name. */
    suspend fun saveToMovies(file: File): String {
        val name = "MUSE Recreate ${System.currentTimeMillis() / 1000}"
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            val r = app.contentResolver
            if (android.os.Build.VERSION.SDK_INT >= 29) {
                val v = android.content.ContentValues().apply {
                    put(android.provider.MediaStore.Video.Media.DISPLAY_NAME, "$name.mp4"); put(android.provider.MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                    put(android.provider.MediaStore.Video.Media.RELATIVE_PATH, "Movies/MUSE")
                }
                r.insert(android.provider.MediaStore.Video.Media.EXTERNAL_CONTENT_URI, v)?.let { uri -> r.openOutputStream(uri)?.use { o -> file.inputStream().use { it.copyTo(o) } } }
            } else {
                @Suppress("DEPRECATION") val dir = File(android.os.Environment.getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_MOVIES), "MUSE").apply { mkdirs() }
                file.copyTo(File(dir, "$name.mp4"), overwrite = true)
            }
        }
        return name
    }

    /** A prepared preview player for the built edit, or null when nothing can play. The caller releases it. */
    fun player(): CompositionPlayer? {
        val p = project?.takeIf { playable } ?: return null
        return runCatching {
            composer.previewPlayer(composer.plan(playableProject(p, files.keys), files), files).also { it.prepare() }
        }.getOrNull()
    }
}

package studio.muse.app.platform.edit

import android.graphics.Typeface
import androidx.compose.ui.text.font.FontFamily
import studio.muse.core.edit.AssetKind
import studio.muse.core.edit.EditProject
import studio.muse.core.edit.TextStyle
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * Own fonts on this phone: each font upload's local file, and its typeface (the engine's text overlay) and font family
 * (the Compose preview). Text whose font isn't here yet draws with its fallback family.
 */
object OwnFonts {
    private val files = ConcurrentHashMap<String, File>()
    private val faces = ConcurrentHashMap<String, Typeface>()
    private val families = ConcurrentHashMap<String, FontFamily>()

    fun register(upload: String, file: File) { files[upload] = file; faces.remove(upload); families.remove(upload) }
    fun has(upload: String) = files.containsKey(upload)

    /** The upload of [s]'s own font in [p], if it has one. */
    fun uploadOf(p: EditProject, s: TextStyle): String? = s.fontAsset?.let { id -> p.assets.firstOrNull { it.id == id && it.kind == AssetKind.FONT }?.upload }

    fun typeface(upload: String?): Typeface? {
        val u = upload ?: return null
        faces[u]?.let { return it }
        val f = files[u] ?: return null
        return runCatching { Typeface.createFromFile(f) }.getOrNull()?.also { faces[u] = it }
    }

    fun family(upload: String?): FontFamily? {
        val u = upload ?: return null
        families[u]?.let { return it }
        val f = files[u] ?: return null
        return runCatching { FontFamily(androidx.compose.ui.text.font.Font(f)) }.getOrNull()?.also { families[u] = it }
    }
}

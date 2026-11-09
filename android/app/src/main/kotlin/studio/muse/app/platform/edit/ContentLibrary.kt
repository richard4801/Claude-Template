package studio.muse.app.platform.edit

import android.graphics.Typeface
import androidx.compose.ui.text.font.FontFamily
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import studio.muse.core.edit.Font
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/** One catalog item (plans/api.md "GET /v1/editor/content"), its fields kept as JSON for the kind-specific parts. */
data class ContentItem(val packId: String, val kind: String, val id: String, val name: String, val category: String?, val tags: List<String>, val file: String?, val raw: JsonObject) {
    /** The project's reference to it: `content:<pack>/<item>`. */
    val ref: String get() = "content:$packId/$id"
    val durationSec: Double? get() = (raw["durationSec"] as? JsonPrimitive)?.doubleOrNull
    val width: Int? get() = (raw["width"] as? JsonPrimitive)?.intOrNull
    val height: Int? get() = (raw["height"] as? JsonPrimitive)?.intOrNull
}
data class ContentPack(val id: String, val kind: String, val title: String, val licence: String, val attribution: String?, val categories: List<Pair<String, String>>, val items: List<ContentItem>)
data class ContentCatalog(val version: String, val packs: List<ContentPack>) {
    fun pack(kind: String): List<ContentPack> = packs.filter { it.kind == kind }
    fun item(ref: String): ContentItem? {
        val m = REF.matchEntire(ref) ?: return null
        return packs.firstOrNull { it.id == m.groupValues[1] }?.items?.firstOrNull { it.id == m.groupValues[2] }
    }
    /** The catalog path of a content font family's file for [weight] (400/700/900, nearest below). */
    fun fontPath(font: Font, weight: Int): String? {
        val files = pack("fonts").flatMap { it.items }.firstOrNull { it.id == font.wire }?.raw?.get("files") as? JsonObject ?: return null
        val w = if (weight >= 900) "900" else if (weight >= 700) "700" else "400"
        return ((files[w] ?: files["400"]) as? JsonPrimitive)?.content
    }

    companion object {
        private val REF = Regex("^content:([a-z0-9-]+)/([a-z0-9_.-]+)$")
        fun parse(text: String): ContentCatalog {
            val o = Json.parseToJsonElement(text) as JsonObject
            fun s(j: JsonObject, k: String) = (j[k] as? JsonPrimitive)?.content
            val packs = (o["packs"] as JsonArray).map { pe ->
                val p = pe as JsonObject
                val pid = s(p, "id")!!; val kind = s(p, "kind")!!
                ContentPack(pid, kind, s(p, "title") ?: pid, s(p, "licence") ?: "", s(p, "attribution"),
                    (p["categories"] as? JsonArray).orEmpty().map { c -> (c as JsonObject).let { s(it, "id")!! to (s(it, "label") ?: s(it, "id")!!) } },
                    (p["items"] as JsonArray).map { ie ->
                        val i = ie as JsonObject
                        ContentItem(pid, kind, s(i, "id")!!, s(i, "name") ?: s(i, "id")!!, s(i, "category"), (i["tags"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.content }, s(i, "file"), i)
                    })
            }
            return ContentCatalog(s(o, "version")!!, packs)
        }
    }
}

/**
 * The content library on this phone: the catalog and the files downloaded so far (catalog path → local file), and the
 * content fonts' typefaces (engine overlay) and families (Compose preview). A content font whose file isn't here yet
 * draws in its bundled fallback family.
 */
object ContentLibrary {
    @Volatile var catalog: ContentCatalog? = null
    private val files = ConcurrentHashMap<String, File>()
    private val faces = ConcurrentHashMap<String, Typeface>()
    private val families = ConcurrentHashMap<String, FontFamily>()

    fun register(path: String, file: File) { files[path] = file; faces.remove(path); families.remove(path) }
    fun file(path: String?): File? = path?.let { files[it] }
    fun has(path: String) = files.containsKey(path)

    /** The local file of a sticker or sound-effect ref, if downloaded. */
    fun fileOf(ref: String): File? = catalog?.item(ref)?.file?.let { files[it] }

    fun typeface(font: Font, weight: Int): Typeface? {
        if (!font.isContent) return null
        val path = catalog?.fontPath(font, weight) ?: return null
        faces[path]?.let { return it }
        val f = files[path] ?: return null
        return runCatching { Typeface.createFromFile(f) }.getOrNull()?.also { faces[path] = it }
    }

    fun family(font: Font, weight: Int): FontFamily? {
        if (!font.isContent) return null
        val path = catalog?.fontPath(font, weight) ?: return null
        families[path]?.let { return it }
        val f = files[path] ?: return null
        return runCatching { FontFamily(androidx.compose.ui.text.font.Font(f)) }.getOrNull()?.also { families[path] = it }
    }

    /** For tests. */
    fun reset() { catalog = null; files.clear(); faces.clear(); families.clear() }
}

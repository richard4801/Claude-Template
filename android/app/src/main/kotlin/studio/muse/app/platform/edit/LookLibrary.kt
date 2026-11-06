package studio.muse.app.platform.edit

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import studio.muse.core.edit.CubeCheck
import studio.muse.core.edit.CubeException
import studio.muse.core.edit.Look
import studio.muse.core.edit.LookImage
import studio.muse.core.edit.LookLimits
import studio.muse.core.edit.LookPack
import studio.muse.core.edit.Lut
import studio.muse.core.edit.SuiteLooks
import studio.muse.core.edit.checkCube
import studio.muse.core.edit.parseCube
import studio.muse.core.edit.renderLook
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * The looks the app can apply (plans/video-editor.md "Looks"): the bundled pack, read from the app's assets
 * (`assets/looks/looks.json` + one 17³ .cube per look — server/api/assets/lookpack added as an assets dir, single
 * copy), and imported .cube files (an Asset of kind "lut", downloaded to a local file by the caller).
 *
 * Parsed LUTs are cached for the process (a pack cube parses in a few ms; imported ones are keyed by path + mtime).
 */
class LookLibrary(context: Context) {
    private val assets = context.applicationContext.assets

    /** The bundled pack (parsed once). */
    val pack: LookPack by lazy { assets.open("${LookPack.ASSET_DIR}/${LookPack.INDEX_FILE}").use { LookPack.parse(it.readBytes().decodeToString()) } }

    /** A bundled look's LUT. Throws when the pack has no such look or its file is broken (a build error). */
    fun packLut(id: String): Lut = PACK_LUTS.getOrPut(id) {
        val e = pack.entry(id) ?: throw IllegalArgumentException("no bundled look $id")
        assets.open("${LookPack.ASSET_DIR}/${e.file}").use { parseCube(it.readBytes().decodeToString()) }
    }

    /**
     * The suite looks generated from palettes and film stocks (`assets/palettes/palettes.json` + cubes; parsed once).
     * The folder ships with the suite-looks work and may be absent: then there are none.
     */
    val palettes: SuiteLooks by lazy {
        try { assets.open("${SuiteLooks.ASSET_DIR}/${SuiteLooks.INDEX_FILE}").use { SuiteLooks.parse(it.readBytes().decodeToString()) } }
        catch (e: java.io.IOException) { SuiteLooks.NONE }
    }

    /** The suite look ids a `palette:<id>` LUT may name (what the app validates projects against). */
    val paletteIds: Set<String> get() = palettes.ids

    /** A suite look's LUT. Throws when there is no such look or its file is broken. */
    fun paletteLut(id: String): Lut = PACK_LUTS.getOrPut("${Look.PALETTE_PREFIX}$id") {
        val e = palettes.entry(id) ?: throw IllegalArgumentException("no suite look $id")
        assets.open("${SuiteLooks.ASSET_DIR}/${e.file}").use { parseCube(it.readBytes().decodeToString()) }
    }

    /**
     * The LUT a look names: `pack:<id>` / `palette:<id>` from the assets, otherwise the imported cube of that asset id
     * in [files] (asset id → downloaded file). Null when there is no LUT or it can't be loaded (logged; the rest of the
     * look still applies, so a missing download never breaks preview or export).
     */
    fun lutFor(look: Look?, files: Map<String, File>): Lut? {
        val ref = look?.lut ?: return null
        return try {
            look.packId?.let(::packLut) ?: look.paletteId?.let(::paletteLut) ?: look.lutAssetId?.let { files[it] }?.let(::importedLut)
        } catch (e: Exception) {
            Log.w(TAG, "look LUT $ref could not be loaded", e)
            null
        }
    }

    /** An imported .cube file (cached by path and modification time). */
    fun importedLut(file: File): Lut = FILE_LUTS.getOrPut("${file.absolutePath}@${file.lastModified()}:${file.length()}") { readCube(file) }

    companion object {
        private const val TAG = "LookLibrary"
        private val PACK_LUTS = ConcurrentHashMap<String, Lut>()
        private val FILE_LUTS = ConcurrentHashMap<String, Lut>()

        /** Reads and parses a .cube file, refusing files over the contract's 12 MB before reading them. */
        fun readCube(file: File): Lut {
            if (file.length() > LookLimits.MAX_CUBE_BYTES) throw CubeException("the file is over ${LookLimits.MAX_CUBE_BYTES / 1024 / 1024} MB")
            return parseCube(file.readText())
        }

        /**
         * Checks a user's .cube before it is uploaded (the same rules as the server's `POST /v1/editor/luts/validate`):
         * its size and title, or the line that is wrong. Runs on [io].
         */
        suspend fun checkImport(file: File, io: CoroutineDispatcher = Dispatchers.IO): CubeCheck = withContext(io) {
            try { readCube(file).let { CubeCheck.Ok(it.size, it.title, it) } }
            catch (e: CubeException) { CubeCheck.Bad(e.message ?: "not a .cube file") }
            catch (e: java.io.IOException) { CubeCheck.Bad("the file could not be read") }
        }

        /** [checkImport] for text already in memory. */
        fun checkImportText(text: String): CubeCheck = checkCube(text)
    }
}

/**
 * Filter thumbnails: the current frame, downscaled to ~[heightPx] tall, with each look rendered by the CPU port of the
 * reference renderer (studio.muse.core.edit.renderLook — blur radii scale with the picture, so a thumbnail looks like
 * the full frame). Runs on [dispatcher], looks in parallel.
 */
object LookThumbnails {
    const val HEIGHT_PX = 96

    /** [frame] downscaled to [heightPx] tall (aspect kept), as a [LookImage]. */
    fun downscale(frame: Bitmap, heightPx: Int = HEIGHT_PX): LookImage {
        val h = minOf(heightPx, frame.height).coerceAtLeast(1)
        val w = max(1, (frame.width.toDouble() * h / frame.height).roundToInt())
        val small = if (w == frame.width && h == frame.height) frame else Bitmap.createScaledBitmap(frame, w, h, true)
        val px = IntArray(w * h)
        small.getPixels(px, 0, w, 0, 0, w, h)
        if (small !== frame) small.recycle()
        return LookImage.fromArgb(w, h, px)
    }

    fun toBitmap(img: LookImage): Bitmap = Bitmap.createBitmap(img.toArgb(), img.width, img.height, Bitmap.Config.ARGB_8888)

    /** One look on an already downscaled picture ([matrix] = the item's colour matrix, if any). */
    fun render(small: LookImage, look: Look, lut: Lut?, matrix: List<Double>? = null): Bitmap = toBitmap(renderLook(small, look, matrix, lut))

    /** Every look of [library]'s pack on [frame], keyed by look id (pack order). */
    suspend fun renderPack(
        frame: Bitmap, library: LookLibrary, matrix: List<Double>? = null, heightPx: Int = HEIGHT_PX, dispatcher: CoroutineDispatcher = Dispatchers.Default,
    ): Map<String, Bitmap> = withContext(dispatcher) {
        val small = downscale(frame, heightPx)
        val pack = library.pack
        val rendered = coroutineScope {
            pack.looks.map { e -> async { e.id to render(small, e.look, library.packLut(e.id), matrix) } }.awaitAll()
        }
        linkedMapOf(*rendered.toTypedArray())
    }
}

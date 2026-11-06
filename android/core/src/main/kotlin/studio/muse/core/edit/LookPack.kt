package studio.muse.core.edit

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * The bundled look pack (plans/video-editor.md "Looks"): `looks.json` + one 17³ .cube per look, single copy in
 * server/api/assets/lookpack/looks (the Android app ships that folder as `assets/looks/`). This parses `looks.json`;
 * reading the files is the caller's job.
 */
class LookPack(val version: Int, val cubeSize: Int, val looks: List<Entry>) {
    /** One look: [look] is what choosing it sets on an item (`lut: "pack:<id>"`, strength 1 and its default effects). */
    data class Entry(val id: String, val name: String, val category: String, val file: String, val look: Look)

    private val byId = looks.associateBy { it.id }

    val ids: List<String> get() = looks.map { it.id }
    fun entry(id: String): Entry? = byId[id]

    /** The look that choosing [id] sets (null when the pack has no such look). Like the reference's `packLook`. */
    fun packLook(id: String): Look? = byId[id]?.look

    /** The looks grouped by category, in pack order. */
    val categories: Map<String, List<Entry>> get() = looks.groupBy { it.category }

    companion object {
        /** Asset path of the pack inside the app (the folder added as an assets dir). */
        const val ASSET_DIR = "looks"
        const val INDEX_FILE = "looks.json"

        /**
         * The ids of the bundled looks (checked against the pack's looks.json and the shared fixture), so [validate]
         * can refuse an unknown `pack:` look without reading files.
         */
        val IDS: Set<String> = linkedSetOf(
            "natural-clean", "natural-glow", "natural-soft", "natural-pop", "natural-bright",
            "film-gold", "film-pastel", "film-cine", "film-chrome",
            "moody-teal", "moody-forest", "moody-night", "moody-shadow",
            "warm-sunset", "warm-honey", "warm-peach", "warm-amber",
            "cool-ice", "cool-mint", "cool-blue-hour", "cool-crisp",
            "bw-classic", "bw-contrast", "bw-soft", "bw-sepia",
            "vintage-70s", "vintage-instant", "vintage-faded",
            "cine-teal-orange", "cine-bleach", "cine-noir", "cine-golden",
        )

        /** Parses looks.json; a malformed file is an [EditProblem] naming the field (path starting `looks`). */
        fun parse(text: String): LookPack {
            val el = try { Json.parseToJsonElement(text) } catch (e: Exception) { throw EditProblem("looks", "is not valid JSON") }
            val o = Obj.of(el, "looks")
            return LookPack(
                version = o.int("version"), cubeSize = o.int("cubeSize"),
                looks = o.arr("looks").map { (e, f) ->
                    val l = Obj.of(e, f)
                    Entry(l.str("id"), l.str("name"), l.str("category"), l.str("file"), EditJson.lookOf(l.obj("look")))
                },
            )
        }
    }
}

/**
 * The suite looks generated from palettes and film stocks (`lut: "palette:<id>"`): `palettes.json`
 * (`{version, cubeSize, looks: [{id, name, kind, file, lut, swatches}]}`) + one .cube per look, in
 * server/api/assets/lookpack/palettes (the Android app ships it as `assets/palettes/`). The folder may be absent: then
 * there are none. Read leniently like the reference's `paletteFiles` (photo.ts): an entry needs a text id and a plain
 * `<name>.cube` file name, anything else is skipped; a missing or broken index is no suite looks.
 */
class SuiteLooks(val looks: List<Entry>) {
    /** One suite look; [name] falls back to the id. */
    data class Entry(val id: String, val name: String, val kind: String?, val file: String)

    private val byId = looks.associateBy { it.id }

    val ids: Set<String> get() = byId.keys
    fun entry(id: String): Entry? = byId[id]

    /** The display name of suite look [id] (the id itself when it isn't listed). */
    fun nameOf(id: String): String = byId[id]?.name ?: id

    companion object {
        const val ASSET_DIR = "palettes"
        const val INDEX_FILE = "palettes.json"
        val NONE = SuiteLooks(emptyList())
        private val FILE = Regex("^[A-Za-z0-9._-]+\\.cube$")

        /** Parses palettes.json; never throws (bad entries are skipped, a bad file is [NONE]). */
        fun parse(text: String): SuiteLooks {
            val root = runCatching { Json.parseToJsonElement(text) }.getOrNull() as? JsonObject ?: return NONE
            val arr = root["looks"] as? JsonArray ?: return NONE
            fun JsonObject.text(k: String) = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
            val seen = LinkedHashMap<String, Entry>()
            for (e in arr) {
                val o = e as? JsonObject ?: continue
                val id = o.text("id") ?: continue
                val file = o.text("file")?.takeIf { FILE.matches(it) } ?: continue
                seen[id] = Entry(id, o.text("name")?.takeIf { it.isNotBlank() } ?: id, o.text("kind"), file)
            }
            return SuiteLooks(seen.values.toList())
        }
    }
}

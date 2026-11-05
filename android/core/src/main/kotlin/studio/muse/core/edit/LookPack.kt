package studio.muse.core.edit

import kotlinx.serialization.json.Json

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

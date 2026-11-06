package studio.muse.app.ui.screens.suite.composer

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import studio.muse.app.data.CameraCatalog
import studio.muse.app.data.SuiteOption

// AI suite (workstream 1): the video composer's setting chips (plans/video-composer.md "Composer anatomy"), pure (no
// Compose, no layout). Every value starts as Auto (null). A chip shows only the non-Auto values ("Camera · 35mm film,
// Anamorphic"), truncated with "…". Moves are not here: they are #move tokens in the prompt (PromptTokens.kt).

/** The five chips above the prompt, in order. `key` is the mono label. */
enum class ComposerChip(val key: String, val title: String) {
    REFERENCES("REFERENCES", "References"),
    STYLE("STYLE", "Style"),
    CAMERA("CAMERA", "Camera"),
    LOOK("LOOK", "Look"),
    LIGHTING("LIGHTING", "Lighting"),
}

/** Everything the chips set. Null = Auto (the server decides). */
data class ComposerSettings(
    // Camera · Setup
    val body: String? = null,
    val lens: String? = null,
    val focalMm: Int? = null,
    val aperture: String? = null,
    // Camera · Angle
    val height: String? = null,
    val shotSize: String? = null,
    // Style
    val genre: String? = null,
    val era: String? = null,
    val tempo: String? = null,
    /** UGC ad: the ad format (catalog `ugcFormats`: unboxing, review, try_on…), sent as `camera.style.format`. */
    val format: String? = null,
    // Look: a palette and/or a film stock, and whether the take is graded with it (on by default)
    val palette: String? = null,
    val stock: String? = null,
    val gradeLook: Boolean = true,
    // Lighting
    val lighting: String? = null,
    /** A ready-made combo the settings started from (catalog `presets`); the user's picks win over it. */
    val preset: String? = null,
) {
    /** "Reset all" in a picker: that chip back to Auto. */
    fun reset(chip: ComposerChip): ComposerSettings = when (chip) {
        ComposerChip.REFERENCES -> this
        ComposerChip.STYLE -> copy(genre = null, era = null, tempo = null, format = null)
        ComposerChip.CAMERA -> copy(body = null, lens = null, focalMm = null, aperture = null, height = null, shotSize = null)
        ComposerChip.LOOK -> copy(palette = null, stock = null, gradeLook = true)
        ComposerChip.LIGHTING -> copy(lighting = null)
    }

    /** The picker's left-rail dot: does this chip have any non-Auto value? */
    fun isSet(chip: ComposerChip): Boolean = when (chip) {
        ComposerChip.REFERENCES -> false
        ComposerChip.STYLE -> genre != null || era != null || tempo != null || format != null
        ComposerChip.CAMERA -> body != null || lens != null || focalMm != null || aperture != null || height != null || shotSize != null
        ComposerChip.LOOK -> palette != null || stock != null
        ComposerChip.LIGHTING -> lighting != null
    }

    /**
     * Starts from a catalog preset: its values fill the chips (so "Edit settings" shows them), the preset id is kept.
     * Values members can't pick (a hidden aperture, a merged camera) are shown as their nearest visible option.
     */
    fun fromPreset(cat: CameraCatalog, id: String): ComposerSettings {
        val p = cat.presets.firstOrNull { it.id == id }?.spec ?: return copy(preset = id)
        fun s(vararg path: String): String? {
            var e: kotlinx.serialization.json.JsonElement? = p
            for (k in path) e = (e as? JsonObject)?.get(k)
            return (e as? JsonPrimitive)?.content
        }
        return ComposerSettings(
            body = ComposerCatalog.survivor(cat.bodies, s("rig", "body")),
            lens = ComposerCatalog.survivor(cat.lenses, s("rig", "lens")),
            focalMm = s("rig", "focalMm")?.toIntOrNull()?.let { ComposerCatalog.nearestFocal(cat, it) },
            aperture = s("rig", "aperture")?.let { ComposerCatalog.nearestAperture(cat, it) },
            height = s("angle", "height"), shotSize = s("angle", "shotSize"),
            genre = s("style", "genre"), era = s("style", "era"), tempo = s("style", "tempo"),
            palette = s("palette", "preset"), stock = s("rig", "look"), gradeLook = gradeLook,
            lighting = s("lighting", "preset"), preset = id,
        )
    }

    /**
     * The request's `camera`: only non-Auto values, plus the prompt's #move tokens (first = move, second = mix). Null when
     * everything is Auto and there are no moves. The preset is not sent: its values are already in the chips.
     */
    fun cameraJson(moves: List<PromptPart.Move> = emptyList()): JsonObject? {
        val o = buildJsonObject {
            val rig = buildJsonObject {
                body?.let { put("body", it) }; lens?.let { put("lens", it) }; focalMm?.let { put("focalMm", it) }
                aperture?.let { put("aperture", it) }; stock?.let { put("look", it) }
            }
            if (rig.isNotEmpty()) put("rig", rig)
            lighting?.let { put("lighting", buildJsonObject { put("preset", it) }) }
            palette?.let { put("palette", buildJsonObject { put("preset", it) }) }
            val angle = buildJsonObject { height?.let { put("height", it) }; shotSize?.let { put("shotSize", it) } }
            if (angle.isNotEmpty()) put("angle", angle)
            val style = buildJsonObject { genre?.let { put("genre", it) }; era?.let { put("era", it) }; tempo?.let { put("tempo", it) }; format?.let { put("format", it) } }
            if (style.isNotEmpty()) put("style", style)
            moves.getOrNull(0)?.let { put("move", it.wire()) }
            moves.getOrNull(1)?.let { put("mix", it.wire()) }
        }
        return if (o.isEmpty()) null else JsonObject(mapOf("mode" to JsonPrimitive("preset")) + o)
    }
}

/** A chip as the composer draws it: its mono label and its value ("Auto", or the non-Auto values joined). */
data class ChipSummary(val chip: ComposerChip, val values: List<String>, val auto: Boolean, val counter: String? = null) {
    /** "Auto", "35mm film, Anamorphic", or for References "2/9". */
    val value: String get() = counter ?: if (auto) "Auto" else values.joinToString(", ")

    /** "Camera · 35mm film, Anamorphic", cut to [max] characters with "…". */
    fun text(max: Int = 40): String = ComposerCatalog.ellipsize("${chip.title} · $value", max)
}

/** Catalog lookups the composer needs: labels through merges, the visible subsets, nearest visible steps. */
object ComposerCatalog {
    /** The option an id shows as: itself, or the survivor it was merged into. */
    fun survivor(list: List<SuiteOption>, id: String?): String? {
        if (id == null) return null
        return list.firstOrNull { it.id == id }?.mergedInto ?: id
    }

    /** The label of an option (through merges), or the id when the catalog doesn't know it. */
    fun label(list: List<SuiteOption>, id: String?): String? {
        val s = survivor(list, id) ?: return null
        return list.firstOrNull { it.id == s }?.label ?: s
    }

    /** What members see in a group: visible options (Auto comes first in every grid; the picker adds it). */
    fun visible(list: List<SuiteOption>): List<SuiteOption> = list.filter { it.visible }

    /** The focal wheel: the visible steps (older catalogs without `focals`: every length). */
    fun focalSteps(cat: CameraCatalog): List<Int> = cat.focals.filter { it.visible }.map { it.mm }.ifEmpty { cat.focalLengths }

    fun focalLabel(cat: CameraCatalog, mm: Int): String = cat.focals.firstOrNull { it.mm == mm }?.label?.ifBlank { null } ?: "${mm}mm"

    fun nearestFocal(cat: CameraCatalog, mm: Int): Int = focalSteps(cat).minByOrNull { kotlin.math.abs(it - mm) } ?: mm

    /** The nearest visible aperture by f-number, in stops ("f2" → "f2.8", "f8" → "f11"). */
    fun nearestAperture(cat: CameraCatalog, id: String): String {
        val vis = visible(cat.apertures).ifEmpty { return id }
        if (vis.any { it.id == id }) return id
        val f = id.removePrefix("f").toDoubleOrNull() ?: return id
        return vis.minByOrNull { o -> o.id.removePrefix("f").toDoubleOrNull()?.let { kotlin.math.abs(kotlin.math.ln(it / f)) } ?: Double.MAX_VALUE }!!.id
    }

    fun ellipsize(s: String, max: Int): String = if (s.length <= max || max < 2) s else s.take(max - 1).trimEnd(' ', ',', '·') + "…"

    /**
     * A chip's summary: only the non-Auto values, in the picker's order. [refs] / [refsMax] = filled reference slots and
     * the engine's limit (References shows "0/9" always).
     */
    fun summary(chip: ComposerChip, s: ComposerSettings, cat: CameraCatalog, refs: Int = 0, refsMax: Int = 0): ChipSummary {
        val values: List<String> = when (chip) {
            ComposerChip.REFERENCES -> return ChipSummary(chip, emptyList(), refs == 0, "$refs/$refsMax")
            ComposerChip.STYLE -> listOfNotNull(label(cat.ugcFormats, s.format), label(cat.genres, s.genre), label(cat.eras, s.era), label(cat.tempos, s.tempo))
            ComposerChip.CAMERA -> listOfNotNull(
                label(cat.bodies, s.body), label(cat.lenses, s.lens), s.focalMm?.let { focalLabel(cat, it) },
                label(cat.apertures, s.aperture), label(cat.heights, s.height), label(cat.shotSizes, s.shotSize),
            )
            ComposerChip.LOOK -> listOfNotNull(label(cat.palettes, s.palette), label(cat.looks, s.stock))
            ComposerChip.LIGHTING -> listOfNotNull(label(cat.lighting, s.lighting))
        }
        return ChipSummary(chip, values, values.isEmpty())
    }

    /** All five chips in order. */
    fun summaries(s: ComposerSettings, cat: CameraCatalog, refs: Int = 0, refsMax: Int = 0): List<ChipSummary> =
        ComposerChip.entries.map { summary(it, s, cat, refs, refsMax) }
}

/**
 * The shot request a composer sends: the prompt text, the @character / @outfit, the camera from the chips and #moves,
 * and the Look toggle (sent only when it is off and a Look is picked; the server's default is on). Bottom-bar values
 * (quality, shape, length, speaking, takes) are passed through; null = the server's default.
 */
fun composerRequest(
    tokens: PromptTokens, settings: ComposerSettings, quality: String? = null, aspectRatio: String? = null, duration: Int? = null,
    takes: Int? = null, speaking: Boolean? = null, title: String? = null,
): studio.muse.app.data.SuiteShotRequest = studio.muse.app.data.SuiteShotRequest(
    title = title,
    modelId = tokens.character?.id,
    outfitId = tokens.outfit?.id,
    prompt = tokens.promptText(),
    duration = duration, aspectRatio = aspectRatio, quality = quality, takes = takes, speaking = speaking,
    camera = settings.cameraJson(tokens.moves),
    gradeLook = if (!settings.gradeLook && (settings.palette != null || settings.stock != null)) false else null,
)

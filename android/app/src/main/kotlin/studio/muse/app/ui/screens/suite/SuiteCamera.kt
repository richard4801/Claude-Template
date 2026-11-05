package studio.muse.app.ui.screens.suite

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import studio.muse.app.data.CameraCatalog
import studio.muse.app.data.SuiteOption
import studio.muse.app.data.SuitePreset
import studio.muse.app.data.SuiteRules
import kotlin.math.roundToInt

// Picker-friendly camera options, independent of any screen (pure Kotlin): whatever composer the owner's revised design
// lands on (prompt-first chips, each "Auto" by default, opening a small picker with the real renders) reads these groups
// and edits a CameraDraft through select / pick / toggleMove, and the shot sends CameraDraft.spec().

/** One camera option as any picker shows it: the real render (`hardware/<render>.webp`) when there is one, its name and caption. */
data class PickOption(val id: String, val title: String, val caption: String, val render: String? = null, val tag: String? = null, val category: String? = null)

/** A group of the camera (Camera body, Lens, Lighting, Look…): its options, and how many can be picked (moves: 2). */
data class CameraGroup(val id: String, val label: String, val options: List<PickOption>, val max: Int = 1)

/**
 * The camera catalog as picker groups, in the order a composer shows its chips. Hardware with a render comes first in
 * each group. Every group is "Auto" (nothing picked → the server's default) until the user picks.
 */
object CameraGroups {
    const val PRESET = "preset"; const val BODY = "body"; const val LENS = "lens"; const val FOCAL = "focal"; const val APERTURE = "aperture"
    const val SHUTTER = "shutter"; const val LIGHTING = "lighting"; const val LOOK = "look"; const val PALETTE = "palette"; const val MOVE = "move"
    const val HEIGHT = "height"; const val SHOT_SIZE = "shotSize"

    private fun opts(l: List<SuiteOption>) = l.map { PickOption(it.id, it.title, it.caption ?: it.description, it.render) }.sortedBy { if (it.render != null) 0 else 1 }

    fun all(cat: CameraCatalog): List<CameraGroup> = listOf(
        CameraGroup(PRESET, "Preset", cat.presets.map { PickOption(it.id, it.label, it.description) }),
        CameraGroup(BODY, "Camera", opts(cat.bodies)),
        CameraGroup(LENS, "Lens", opts(cat.lenses)),
        CameraGroup(FOCAL, "Focal length", cat.focalLengths.map { PickOption("$it", "$it mm", "") }),
        CameraGroup(APERTURE, "Aperture", cat.apertures.map { PickOption(it.id, CameraDraft.tStop(it.id), it.description, cat.optics.firstOrNull { o -> o.id == "aperture" }?.render) }),
        CameraGroup(SHUTTER, "Shutter", cat.shutters.map { PickOption(it.id, it.label, it.description, cat.optics.firstOrNull { o -> o.id == "shutter" }?.render) }),
        CameraGroup(LIGHTING, "Lighting", opts(cat.lighting)),
        CameraGroup(PALETTE, "Look", opts(cat.palettes)),
        CameraGroup(LOOK, "Film / sensor", opts(cat.looks)),
        CameraGroup(MOVE, "Move", cat.library.map { m -> PickOption(m.id, m.label, m.description, cat.grips.firstOrNull { it.move == m.id }?.render, m.tag, m.category) }, SuiteRules.MAX_MOVES),
        CameraGroup(HEIGHT, "Angle", opts(cat.heights)),
        CameraGroup(SHOT_SIZE, "Framing", opts(cat.shotSizes)),
    ).filter { it.options.isNotEmpty() }

    fun group(cat: CameraCatalog, id: String) = all(cat).firstOrNull { it.id == id }
}

/** Every group on Auto: nothing sent, the server decides. */
val CAMERA_AUTO = CameraDraft(body = null, lens = null, focalMm = null, aperture = null, lighting = null, palette = null, moves = emptyList(), height = null, shotSize = null)

/** The picked ids of a group (empty = Auto). */
fun CameraDraft.selected(group: String): List<String> = when (group) {
    CameraGroups.BODY -> listOfNotNull(body); CameraGroups.LENS -> listOfNotNull(lens); CameraGroups.FOCAL -> listOfNotNull(focalMm?.toString())
    CameraGroups.APERTURE -> listOfNotNull(aperture); CameraGroups.SHUTTER -> listOfNotNull(shutter); CameraGroups.LIGHTING -> listOfNotNull(lighting)
    CameraGroups.PALETTE -> listOfNotNull(palette); CameraGroups.LOOK -> listOfNotNull(look); CameraGroups.MOVE -> moves.map { it.id }
    CameraGroups.HEIGHT -> listOfNotNull(height); CameraGroups.SHOT_SIZE -> listOfNotNull(shotSize); else -> emptyList()
}

/** Picks [id] in a single-choice group (null = back to Auto). Moves are added with [CameraDraft.toggleMove] (Mix 2/2); null clears them. */
fun CameraDraft.pick(group: String, id: String?): CameraDraft = when (group) {
    CameraGroups.BODY -> copy(body = id); CameraGroups.LENS -> copy(lens = id); CameraGroups.FOCAL -> copy(focalMm = id?.toIntOrNull())
    CameraGroups.APERTURE -> copy(aperture = id); CameraGroups.SHUTTER -> copy(shutter = id); CameraGroups.LIGHTING -> copy(lighting = id)
    CameraGroups.PALETTE -> copy(palette = id); CameraGroups.LOOK -> copy(look = id); CameraGroups.HEIGHT -> copy(height = id)
    CameraGroups.SHOT_SIZE -> copy(shotSize = id); CameraGroups.MOVE -> if (id == null) copy(moves = emptyList(), active = 0) else this
    else -> this
}

/** A composer chip's value: "Auto", or the picked option's name ("Dolly in + Rack focus"). */
fun CameraDraft.chipLabel(cat: CameraCatalog, group: String): String {
    val ids = selected(group)
    if (ids.isEmpty()) return "Auto"
    val g = CameraGroups.group(cat, group)
    return ids.joinToString(" + ") { id -> g?.options?.firstOrNull { it.id == id }?.title ?: id }
}

/** Applies a catalog preset (its `spec`) from Auto; later picks win. */
fun CameraDraft.applyPreset(p: SuitePreset): CameraDraft {
    val spec = p.spec ?: return this
    fun s(o: String, k: String) = ((spec[o] as? JsonObject)?.get(k) as? JsonPrimitive)?.content
    val move = s("move", "id")
    val intensity = s("move", "intensity")?.toDoubleOrNull()
    return CAMERA_AUTO.copy(
        body = s("rig", "body"), lens = s("rig", "lens"), focalMm = s("rig", "focalMm")?.toDoubleOrNull()?.toInt(), aperture = s("rig", "aperture"), look = s("rig", "look"),
        shutter = s("rig", "shutter"), lighting = s("lighting", "preset"), palette = s("palette", "preset"), height = s("angle", "height"), shotSize = s("angle", "shotSize"),
        moves = listOfNotNull(move?.let { MovePick(it, ((intensity ?: .5) * 100).roundToInt()) }), directed = directed,
    )
}

package studio.muse.app.ui.screens.suite

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import studio.muse.app.data.CameraCatalog
import studio.muse.app.data.Job
import studio.muse.app.data.SuiteAngle
import studio.muse.app.data.SuiteCameraSpec
import studio.muse.app.data.SuiteCastMember
import studio.muse.app.data.SuiteLighting
import studio.muse.app.data.SuiteMove
import studio.muse.app.data.SuiteOption
import studio.muse.app.data.SuitePalette
import studio.muse.app.data.SuiteRig
import studio.muse.app.data.SuiteRules
import studio.muse.app.data.SuiteShotRequest
import studio.muse.app.data.Take
import studio.muse.app.ui.screens.StagePhase
import studio.muse.app.ui.screens.StudioStage
import kotlin.math.ceil
import kotlin.math.roundToInt

// The AI suite's state, pure (no Compose, no I/O), so the rules are unit-tested: the camera bag (rig, light, look, at most
// two moves with intensity and speed), the Shot, Recast and Storyboard drafts and the requests they send, and the
// result pane's member-safe wording.

private val specJson = Json { encodeDefaults = false; explicitNulls = false }

/** One picked move: intensity 0–100 %, speed slow / normal / fast. */
data class MovePick(val id: String, val intensity: Int = 60, val speed: String = "normal") {
    fun wire() = SuiteMove(id, intensity.coerceIn(0, 100) / 100.0, speed)
}

/** The camera of a shot, as the camera bag edits it. Option ids come from the catalog. */
data class CameraDraft(
    val body: String? = "super35",
    val lens: String? = "anamorphic",
    val focalMm: Int? = 40,
    val aperture: String? = "f2",
    val shutter: String? = null,
    val look: String? = null,
    val lighting: String? = "soft_cross",
    val palette: String? = "teal_orange",
    val moves: List<MovePick> = listOf(MovePick("dolly_in", 60), MovePick("rack_focus", 50)),
    /** The move the sheet edits (index into [moves]). */
    val active: Int = 0,
    val height: String? = "eye",
    val shotSize: String? = "mcu",
    /** Directed mode: the camera JSON the camera stage (workstream 2) applied. Null = Preset. */
    val directed: JsonElement? = null,
) {
    val mixLabel: String get() = "Mix ${moves.size}/${SuiteRules.MAX_MOVES}"
    val activeMove: MovePick? get() = moves.getOrNull(active) ?: moves.firstOrNull()

    /**
     * Taps a move in the library: a picked one comes out; a new one is added as move 2 when it mixes with move 1, replaces
     * move 1 when it doesn't, and is refused at Mix 2/2. Returns the new draft and what to tell the user (null = nothing).
     */
    fun toggleMove(id: String, cat: CameraCatalog): Pair<CameraDraft, String?> {
        val i = moves.indexOfFirst { it.id == id }
        if (i >= 0) {
            val rest = moves.filterIndexed { k, _ -> k != i }
            return copy(moves = rest, active = 0) to null
        }
        val pick = MovePick(id, if (cat.move(id)?.category == "static") 0 else 60)
        return when (moves.size) {
            0 -> copy(moves = listOf(pick), active = 0) to null
            1 -> if (SuiteRules.canMix(cat.move(moves[0].id), cat.move(id))) copy(moves = moves + pick, active = 1) to null
                else copy(moves = listOf(pick), active = 0) to "${cat.moveLabel(moves[0].id)} and ${cat.moveLabel(id)} can't be combined · one move"
            else -> this to "Mix 2/2 · tap a numbered move to take it out"
        }
    }

    fun setActive(i: Int) = copy(active = i.coerceIn(0, (moves.size - 1).coerceAtLeast(0)))
    fun tune(intensity: Int? = null, speed: String? = null): CameraDraft {
        val a = activeMove ?: return this
        val next = a.copy(intensity = intensity ?: a.intensity, speed = speed ?: a.speed)
        return copy(moves = moves.map { if (it === a) next else it })
    }

    /** Keeps only ids the catalog knows (an older or newer server), so the shot never sends an unknown id. */
    fun fit(cat: CameraCatalog): CameraDraft {
        fun ok(id: String?, l: List<SuiteOption>) = id?.takeIf { x -> l.isEmpty() || l.any { it.id == x } }
        return copy(body = ok(body, cat.bodies), lens = ok(lens, cat.lenses), aperture = ok(aperture, cat.apertures), shutter = ok(shutter, cat.shutters),
            look = ok(look, cat.looks), lighting = ok(lighting, cat.lighting), palette = ok(palette, cat.palettes), height = ok(height, cat.heights), shotSize = ok(shotSize, cat.shotSizes),
            moves = moves.filter { m -> cat.moves.isEmpty() || cat.moves.any { it.id == m.id } }.take(SuiteRules.MAX_MOVES),
            focalMm = focalMm?.takeIf { f -> cat.focalLengths.isEmpty() || f in 8..200 })
    }

    /** The CameraSpec the shot sends: Directed mode's JSON as applied, else the preset spec. */
    fun spec(): JsonElement = directed ?: specJson.encodeToJsonElement(SuiteCameraSpec.serializer(), presetSpec())

    fun presetSpec() = SuiteCameraSpec(
        mode = "preset",
        rig = SuiteRig(body, lens, focalMm, aperture, look, null, shutter).takeIf { listOf(body, lens, focalMm, aperture, look, shutter).any { it != null } },
        lighting = lighting?.let { SuiteLighting(it) },
        palette = palette?.let { SuitePalette(it) },
        move = moves.getOrNull(0)?.wire(),
        mix = moves.getOrNull(1)?.wire(),
        angle = SuiteAngle(height, shotSize).takeIf { height != null || shotSize != null },
    )

    /** "Super 35 · Anamorphic 40 mm · T2 · Soft Cross · Teal & Orange". */
    fun summary(cat: CameraCatalog): String = listOfNotNull(
        cat.bodies.find(body)?.let { short(it.title) },
        cat.lenses.find(lens)?.let { short(it.title) + (focalMm?.let { f -> " $f mm" } ?: "") },
        aperture?.let { tStop(it) },
        cat.lighting.find(lighting)?.title,
        cat.palettes.find(palette)?.title ?: cat.looks.find(look)?.title,
    ).joinToString(" · ")

    /** "Dolly in · 60%". */
    fun moveTitle(cat: CameraCatalog): String = moves.firstOrNull()?.let { "${cat.moveLabel(it.id)} · ${it.intensity}%" } ?: "No move · locked-off"

    /** "+ Rack focus · Eye · MCU". */
    fun moveSub(cat: CameraCatalog): String = listOfNotNull(
        moves.getOrNull(1)?.let { "+ ${cat.moveLabel(it.id)}" },
        cat.heights.find(height)?.label?.removeSuffix(" level")?.removeSuffix(" angle"),
        shotSize?.let { SHOT_SHORT[it] ?: cat.shotSizes.find(it)?.label },
    ).joinToString(" · ")

    companion object {
        private val SHOT_SHORT = mapOf("els" to "EWS", "ls" to "WS", "full" to "Full", "cowboy" to "Cowboy", "ms" to "MS", "mcu" to "MCU", "cu" to "CU", "ecu" to "ECU", "ots" to "OTS", "pov" to "POV")
        private fun List<SuiteOption>.find(id: String?) = firstOrNull { it.id == id }
        /** "Super 35 Digital" → "Super 35"; "Anamorphic 2×" → "Anamorphic". */
        fun short(s: String) = s.removeSuffix(" Digital").removeSuffix(" digital").removeSuffix(" 2×").removeSuffix(" Prime")
        /** "f2" → "T2", "f1.4" → "T1.4" (cine lenses are marked in T-stops). */
        fun tStop(id: String) = "T" + id.removePrefix("f")
    }
}

/** The Shot builder (M2): one lead character and outfit, the scene in words, the camera, length and quality. */
data class ShotDraft(
    val title: String = "",
    val modelId: String? = null,
    val outfitId: String? = null,
    val scene: String = "",
    val sceneTab: String = "text",
    val duration: Int = 5,
    val quality: String = "draft",
    val takes: Int = 1,
    val aspect: String = "9:16",
    /** null = the server decides (the audio's talking flag, else no). */
    val speaking: Boolean? = null,
    val camera: CameraDraft = CameraDraft(),
    val tab: String = "camera",
) {
    fun request(): SuiteShotRequest = SuiteShotRequest(
        title = title.trim().ifBlank { null }, modelId = modelId, outfitId = outfitId?.takeIf { modelId != null }, prompt = scene.trim(),
        duration = duration, aspectRatio = aspect, quality = quality, takes = takes, speaking = speaking, camera = camera.spec(),
    )

    /** What stops Generate, in plain words (null = ready). */
    fun problem(): String? = when {
        modelId == null && scene.isBlank() -> "Pick a character or describe the shot"
        else -> null
    }

    companion object {
        val LENGTHS = listOf(3, 4, 5, 6, 8, 10)
    }
}

/** Recast: one person of the source clip and who they become. [hint]: left / center / right / foreground / background. */
data class RecastPerson(val hint: String, val characterId: String? = null, val outfitId: String? = null, val speaking: Boolean? = null)

/** Character swap (M6) with Recast inside: up to 4 people of one clip, each → a studio character. */
data class RecastDraft(
    val clipId: String? = null,
    val people: List<RecastPerson> = listOf(RecastPerson("center")),
    val quality: String = "standard",
    val keepAudio: Boolean = true,
    val takes: Int = 1,
) {
    val canAdd: Boolean get() = people.size < SuiteRules.MAX_CAST

    fun add(): RecastDraft = if (!canAdd) this else {
        // Two people read left and right; a third and fourth take the next free spot.
        val spread = if (people.size == 1 && people[0].hint == "center") listOf(people[0].copy(hint = "left")) else people
        val free = HINTS.first { h -> spread.none { it.hint == h } }
        copy(people = spread + RecastPerson(free))
    }

    fun remove(i: Int) = if (people.size <= 1) this else copy(people = people.filterIndexed { k, _ -> k != i })
    fun update(i: Int, f: (RecastPerson) -> RecastPerson) = copy(people = people.mapIndexed { k, p -> if (k == i) f(p) else p })

    /** What stops Generate (null = ready). */
    fun problem(): String? = when {
        clipId == null -> "Choose the source clip"
        people.any { it.characterId == null } -> "Pick who each person becomes"
        people.map { it.hint }.toSet().size != people.size -> "Two people point at the same spot"
        else -> null
    }

    fun request(): SuiteShotRequest = SuiteShotRequest(
        mode = "recast", clipId = clipId, quality = quality, keepAudio = keepAudio, takes = takes,
        cast = people.mapIndexedNotNull { i, p ->
            p.characterId?.let { SuiteCastMember(it, p.outfitId, personHint = p.hint, speaking = if (people.size == 1 && p.speaking == null) null else p.speaking) }
        },
    )

    companion object {
        val HINTS = listOf("center", "left", "right", "foreground", "background")
        fun hintLabel(h: String) = when (h) { "center" -> "Centre"; "foreground" -> "Front"; "background" -> "Back"; else -> h.replaceFirstChar { it.uppercase() } }
    }
}

/** One shot of a storyboard: its own words, move and length; cast, look and lens are locked across the board. */
data class StoryShot(val id: String, val title: String, val prompt: String, val move: String, val seconds: Int, val jobId: String? = null)

/** Storyboard (M7): shots with one cast and a look lock. */
data class Storyboard(
    val title: String,
    val cast: List<String>,
    val lookLock: String = "cinematic",
    val quality: String = "hd",
    val shots: List<StoryShot> = emptyList(),
) {
    val seconds: Int get() = shots.sumOf { it.seconds }

    /** Shots Generate makes: never made, or failed (refunded). */
    fun pending(jobs: List<Job>): List<StoryShot> = shots.filter { s -> s.jobId == null || jobs.firstOrNull { it.id == s.jobId }?.failed == true }

    fun request(s: StoryShot, camera: CameraDraft, index: Int): SuiteShotRequest = SuiteShotRequest(
        title = "$title · ${index + 1}", modelId = cast.firstOrNull(), prompt = s.prompt, duration = s.seconds, quality = quality,
        camera = camera.copy(moves = listOf(MovePick(s.move, 60))).spec(),
    )

    fun withJob(shotId: String, jobId: String) = copy(shots = shots.map { if (it.id == shotId) it.copy(jobId = jobId) else it })
}

/** A storyboard shot's badge: READY, 40%, #2 IN LINE, FAILED or NOT MADE. kind: good | busy | warn | bad | "" */
data class StoryStatus(val label: String, val kind: String)

fun storyStatus(s: StoryShot, jobs: List<Job>): StoryStatus {
    val j = s.jobId?.let { id -> jobs.firstOrNull { it.id == id } } ?: return StoryStatus("Not made", "")
    val st = SuitePane.of(j, emptyList(), null)
    return when (st.phase) {
        StagePhase.READY -> StoryStatus("Ready", "good")
        StagePhase.FAILED -> StoryStatus("Failed · free retry", "bad")
        StagePhase.QUEUED -> StoryStatus(st.badge, "warn")
        StagePhase.RENDERING -> StoryStatus(st.percent, "busy")
        StagePhase.IDLE -> StoryStatus("Not made", "")
    }
}

/**
 * The result pane (D10 / M8) for one shot job: empty, in line, rendering (take n of N, %, the named step and time left),
 * ready (its takes) or failed (plain words, no charge). Member-safe: built on [StudioStage], never engine words.
 */
data class SuitePane(
    val phase: StagePhase = StagePhase.IDLE,
    /** "Rendering take 2 of 2", "#2 in line · ~1 min", "Ready", "Failed". */
    val headline: String = "",
    val percent: String = "",
    val progress: Float = 0f,
    /** "#2 in line" for small badges. */
    val badge: String = "",
    /** The named step and time ("Motion & camera · ~2 min"). */
    val step: String = "",
    /** The three named steps and where the take is (0 keyframe, 1 motion & camera, 2 sharpen & finish). */
    val stepIndex: Int = 0,
    val price: String = "",
    val takes: List<Take> = emptyList(),
    val failure: String? = null,
) {
    companion object {
        val STEPS = listOf("Keyframe from %s’s sheet", "Motion & camera", "Sharpen & finish")

        fun stepNames(lead: String?) = listOf(if (lead.isNullOrBlank()) "Keyframe" else STEPS[0].format(lead.substringBefore(' ')), STEPS[1], STEPS[2])

        fun of(job: Job?, takes: List<Take>, lead: String?): SuitePane {
            val st = StudioStage.of(job, takes)
            val j = job ?: return SuitePane()
            val left = j.etaSeconds ?: j.secondsLeft
            val time = if (left > 0) " · ~${about(left)}" else ""
            return when (st.phase) {
                StagePhase.IDLE -> SuitePane()
                StagePhase.READY -> SuitePane(StagePhase.READY, "Ready", "100%", 1f, "Ready", price = st.price, takes = st.takes)
                StagePhase.FAILED -> SuitePane(StagePhase.FAILED, "Failed", st.percent, st.progress, "Failed", price = st.price, failure = st.failure)
                StagePhase.QUEUED -> {
                    val pos = j.queuePosition
                    val badge = if (pos != null && pos > 1) "#$pos in line" else "In line"
                    SuitePane(StagePhase.QUEUED, badge + time, "0%", 0f, badge, "Leaving is safe · we'll tell you when it's ready", price = st.price)
                }
                StagePhase.RENDERING -> {
                    val n = j.request.takes.coerceAtLeast(1)
                    val take = j.take.coerceIn(1, n)
                    val inTake = (st.progress * n - (take - 1)).coerceIn(0f, 1f)
                    val idx = when { inTake < .2f -> 0; inTake < .85f -> 1; else -> 2 }
                    val head = if (n > 1) "Rendering take $take of $n" else "Rendering"
                    SuitePane(StagePhase.RENDERING, head, st.percent, st.progress, st.percent, stepNames(lead)[idx] + time, idx, st.price)
                }
            }
        }

        /** "2 min", "40 s". */
        fun about(sec: Double): String = if (sec >= 60) "${ceil(sec / 60).toInt()} min" else "${ceil(sec).toInt().coerceAtLeast(1)} s"
    }
}

/** The quality ladder's next step up ("Try Standard" after a failed Draft), or null at Cinema. */
fun nextTier(id: String?): String? = SuiteRules.TIERS.indexOf(id ?: "draft").let { i -> SuiteRules.TIERS.getOrNull(i + 1) }

/** "62%" as a whole number. */
fun pct(p: Float) = "${(p * 100).roundToInt()}%"

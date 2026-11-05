package studio.muse.core

/**
 * The layered prompt engine from plans/prompt-system.md. Every generator (character sheet, outfit set,
 * photoshoot, video swap) builds its prompt here. Users never write prompts from scratch: their choices fill
 * slots, empty slots are dropped, and the user's direction can add detail but never override identity or the
 * never-add list.
 */

/** Prompt layers, merged top to bottom. */
enum class Layer(val key: String) {
    IDENTITY("identity"), OUTFIT("outfit"), TASK("task"), SCENE("scene"), CAMERA("camera"), LIGHT("light"),
    DIRECTION("direction"), STYLE("style"), NEGATIVE("negative"), SEED("seed");
}

/**
 * Who the model is. [look] is the written look; references are the locked character-sheet images.
 * [lora] is the Identity LoRA trigger token ("demo_v1") when one is trained and switched on (plans/lora-training.md);
 * null means references only.
 */
data class Identity(
    val name: String,
    val look: String,
    val referenceCount: Int = 6,
    val neverAdd: List<String> = emptyList(),
    val lora: String? = null,
)

/** Identity LoRA naming: first name, lower case, plus the version ("demo_v2"). */
object LoraToken {
    fun of(modelName: String, version: Int): String =
        modelName.trim().split(Regex("\\s+")).first().lowercase().filter { it.isLetterOrDigit() }.ifEmpty { "model" } + "_v$version"
}

/** The selected outfit set. Either described in words, from a product photo, or an uploaded set. */
data class OutfitSpec(
    val name: String,
    val description: String? = null,
    val source: OutfitSource = OutfitSource.REFERENCE_SET,
)

enum class OutfitSource { REFERENCE_SET, DESCRIBED, PRODUCT_PHOTO }

data class CameraSpec(val shot: String = "Medium", val lensMm: Int = 35, val aperture: String = "f/2.8")

/** The photoshoot tool state (scene chip or custom text, camera, light, direction, Lock look). */
data class ShootSpec(
    val identity: Identity,
    val outfit: OutfitSpec,
    val scene: String? = null,
    val camera: CameraSpec = CameraSpec(),
    val light: String = "Golden hour",
    val grade: String? = null,
    val direction: String? = null,
    val lockSeed: Boolean = false,
)

data class PromptSlot(val layer: Layer, val text: String) {
    /** The slot body without its "Label: " prefix, as shown in the "final prompt by slot" box. */
    val body: String get() = text.replaceFirst(LABEL_PREFIX, "")

    private companion object {
        val LABEL_PREFIX = Regex("^[A-Za-z ]+: ")
    }
}

/** A built prompt: ordered non-empty slots, the seed policy, and anything the engine removed. */
data class BuiltPrompt(
    val slots: List<PromptSlot>,
    val seed: Long? = null,
    val removed: List<String> = emptyList(),
) {
    val text: String get() = slots.joinToString("\n") { it.text }
    operator fun get(layer: Layer): String? = slots.firstOrNull { it.layer == layer }?.text
}

/** Structured MiniMax H3 Ref2VA prompt (the format proven in testing). */
data class H3Prompt(
    val subjectDefinitions: String,
    val summary: String,
    val retentionAnalysis: String,
    val detailedDescription: String,
    val audioMode: String,
    val steps: Int,
    val seed: Long,
    val removed: List<String> = emptyList(),
) {
    val text: String
        get() = "subject_definitions:\n$subjectDefinitions\n\nsummary:\n$summary\n\nretention_analysis:\n$retentionAnalysis\n\ndetailed_description:\n$detailedDescription\n"
}

/** What we know about the source performer, from the clip checks. Named so carried-over features can be removed. */
data class SourcePerformer(
    val description: String = "the person",
    val tattoos: Boolean = false,
    val rings: Boolean = false,
    val setting: String = "the room",
)

data class VideoSwapSpec(
    val identity: Identity,
    val outfit: OutfitSpec,
    val performer: SourcePerformer = SourcePerformer(),
    val keepAudio: Boolean = true,
    val keepBackground: Boolean = true,
    val backgroundMotion: String? = null,
    val steps: Int = Pricing.STEPS_DEFAULT,
    val seed: Long = 42,
    val direction: String? = null,
)

/** Character-sheet angles (7 slots; FACE_TQ added 2026-11-04 and kept last so the original order stays). */
enum class SheetAngle(val key: String, val label: String, val framing: String) {
    FACE_FRONT("face", "Face · front", "head-and-shoulders, facing the camera"),
    FACE_PROFILE("profile", "Face · profile", "head-and-shoulders, side profile"),
    BODY_FRONT("front", "Body · front", "full body, facing the camera"),
    BODY_TQ("tq", "Body · ¾", "full body, three-quarter view"),
    BODY_SIDE("side", "Body · side", "full body, side view"),
    BODY_BACK("back", "Body · back", "full body, from behind"),
    FACE_TQ("faceTq", "Face · ¾", "head-and-shoulders, turned three-quarters");

    companion object {
        fun fromKey(k: String): SheetAngle? = entries.firstOrNull { it.key == k }
        /** The order the apps show them: the three face close-ups, then the four full-body angles. */
        val DISPLAY = listOf(FACE_FRONT, FACE_TQ, FACE_PROFILE, BODY_FRONT, BODY_TQ, BODY_SIDE, BODY_BACK)
    }
}

/** Outfit-set angles (4, same seed). */
enum class OutfitAngle(val label: String, val words: String) {
    FRONT("Front", "full body front view"),
    TQ("¾", "full body three-quarter view"),
    SIDE("Side", "full body side view"),
    BACK("Back", "full body back view"),
}

object PromptEngine {
    /** Global house style (editable in settings later). */
    const val HOUSE_STYLE = "realistic smartphone photo, natural skin texture, true-to-life colour, no beauty filter, no AI gloss"
    /** Global never-add defaults, appended after the model's own list. */
    val GLOBAL_NEVER = listOf("logos", "extra fingers", "warped jewellery")
    const val DEFAULT_SCENE = "Rooftop · golden hour"
    const val DEFAULT_GRADE = "Phone-natural"

    /** Words that would change who she is. A direction clause containing one is dropped. */
    private val IDENTITY_OVERRIDE = Regex(
        "\\b(blonde|brunette|redhead|ginger|bald|(blue|green|brown|hazel|grey|gray) eyes|eye colou?r|hair colou?r|dyed hair|skin tone|different (face|person|woman|girl|model)|another (face|person|woman|model)|older|younger|look like)\\b",
        RegexOption.IGNORE_CASE,
    )

    /** The never-add list for a model: her own items, then the global defaults, de-duplicated. */
    fun neverList(identity: Identity): List<String> =
        (identity.neverAdd + GLOBAL_NEVER).map { it.trim() }.filter { it.isNotEmpty() }.distinctBy { it.lowercase() }

    /**
     * Applies the "direction never overrides identity or never-add" rule. Returns the cleaned direction and the
     * clauses that were dropped.
     */
    fun sanitizeDirection(direction: String?, identity: Identity): Pair<String, List<String>> {
        val raw = direction?.trim().orEmpty()
        if (raw.isEmpty()) return "" to emptyList()
        val never = neverList(identity).map { stem(it) }
        val clauses = raw.split(Regex("(?<=[,.;])\\s*|\\s+and\\s+(?=with\\b)")).map { it.trim() }.filter { it.isNotEmpty() }
        val kept = mutableListOf<String>()
        val removed = mutableListOf<String>()
        for (c in clauses) {
            val words = c.lowercase()
            val hitsNever = never.any { n -> Regex("\\b${Regex.escape(n)}").containsMatchIn(words) }
            if (hitsNever || IDENTITY_OVERRIDE.containsMatchIn(c)) removed += c.trimEnd(',', ';', '.').trim() else kept += c
        }
        if (removed.isEmpty()) return raw to emptyList()
        val joined = kept.joinToString(" ").trim().trimEnd(',', ';').trim()
        return joined to removed
    }

    /** Singular stem for matching "rings" against "ring", "tattoos" against "tattoo". */
    private fun stem(s: String): String {
        val w = s.lowercase().trim()
        return when {
            w.endsWith("ies") -> w.dropLast(3)
            w.endsWith("es") && (w.endsWith("ches") || w.endsWith("shes") || w.endsWith("xes")) -> w.dropLast(2)
            w.endsWith("s") && !w.endsWith("ss") -> w.dropLast(1)
            else -> w
        }
    }

    /** The identity layer. With a LoRA on it reads "... 6 locked reference images + LoRA demo_v1 (photo)." (prototype features.js). */
    private fun identitySlot(id: Identity) =
        PromptSlot(Layer.IDENTITY, "${id.name}: ${id.look}. Identity from ${id.referenceCount} locked reference images${id.lora?.let { " + LoRA $it (photo)" } ?: ""}.")

    private fun negativeSlot(id: Identity) = PromptSlot(Layer.NEGATIVE, "Never add: ${neverList(id).joinToString(", ")}.")

    private fun styleSlot() = PromptSlot(Layer.STYLE, "Style: $HOUSE_STYLE.")

    private fun cameraWords(c: CameraSpec): String {
        val extra = when {
            c.lensMm <= 24 -> ", slight wide-angle distortion"
            c.lensMm >= 85 -> ", compressed background, creamy bokeh"
            else -> ""
        }
        return "Camera: ${c.shot.lowercase()} shot, ${c.lensMm}mm lens, ${c.aperture}$extra."
    }

    private fun outfitWords(o: OutfitSpec): String = when (o.source) {
        OutfitSource.REFERENCE_SET -> "Wearing: ${o.name.lowercase()} (outfit reference set)."
        OutfitSource.DESCRIBED -> "Wearing: ${(o.description ?: o.name).trim().trimEnd('.')}."
        OutfitSource.PRODUCT_PHOTO -> "Wearing: the outfit from the product photo reference (${o.name.lowercase()})."
    }

    /** Photoshoot: all layers. Matches the prototype's buildPrompt('shoot') slot for slot. */
    fun photoshoot(s: ShootSpec): BuiltPrompt {
        val (dir, removed) = sanitizeDirection(s.direction, s.identity)
        val scene = s.scene?.takeIf { it.isNotBlank() } ?: DEFAULT_SCENE
        val slots = listOf(
            identitySlot(s.identity),
            PromptSlot(Layer.OUTFIT, outfitWords(s.outfit)),
            PromptSlot(Layer.SCENE, "Scene: ${scene.lowercase()}."),
            PromptSlot(Layer.CAMERA, cameraWords(s.camera)),
            PromptSlot(Layer.LIGHT, "Light: ${s.light.lowercase()}; grade: ${(s.grade ?: DEFAULT_GRADE).lowercase()}."),
            PromptSlot(Layer.DIRECTION, if (dir.isNotEmpty()) "Direction: $dir" else ""),
            styleSlot(),
            negativeSlot(s.identity),
            PromptSlot(Layer.SEED, if (s.lockSeed) "Seed: locked (variations keep the same look)." else "Seed: new each shot."),
        ).filter { it.text.isNotBlank() }
        return BuiltPrompt(slots, seed = if (s.lockSeed) seedFor(s.identity.name) else null, removed = removed)
    }

    /** Character-sheet shot: identity + task + house style + never add. */
    fun characterSheetShot(identity: Identity, angle: SheetAngle): BuiltPrompt = BuiltPrompt(
        listOf(
            identitySlot(identity),
            PromptSlot(Layer.TASK, "Task: ${angle.label.lowercase()} shot on a plain light-grey studio background, even soft light, neutral expression, ${angle.framing}."),
            styleSlot(),
            negativeSlot(identity),
        ),
    )

    /** One outfit-set angle. All four angles share [seed]. */
    fun outfitAngle(identity: Identity, outfit: OutfitSpec, angle: OutfitAngle, seed: Long): BuiltPrompt {
        val never = identity.copy(neverAdd = identity.neverAdd + "visible brand logos")
        return BuiltPrompt(
            listOf(
                identitySlot(identity),
                PromptSlot(Layer.OUTFIT, outfitWords(outfit)),
                PromptSlot(Layer.TASK, "Task: ${angle.words}, plain studio background."),
                styleSlot(),
                negativeSlot(never),
                PromptSlot(Layer.SEED, "Seed: $seed (shared by all four angles)."),
            ),
            seed = seed,
        )
    }

    fun outfitSet(identity: Identity, outfit: OutfitSpec, seed: Long = seedFor(outfit.name)): List<BuiltPrompt> =
        OutfitAngle.entries.map { outfitAngle(identity, outfit, it, seed) }

    /** The structured H3 Ref2VA prompt for a character swap. */
    fun videoSwap(v: VideoSwapSpec): H3Prompt {
        val id = v.identity
        val n = id.referenceCount.coerceIn(1, 6)
        val refs = SheetAngle.entries.take(n).mapIndexed { i, a -> "<Image ${i + 1}> (${a.label.lowercase().replace(" · ", ", ")})" }
        val refList = if (refs.size == 1) refs[0] else refs.dropLast(1).joinToString(", ") + " and " + refs.last()
        val performerExtras = buildList {
            if (v.performer.tattoos) add("tattoos")
            if (v.performer.rings) add("rings")
        }
        val performer = v.performer.description + if (performerExtras.isNotEmpty()) " with ${performerExtras.joinToString(" and ")}" else ""
        val never = neverList(id)
        val (dir, removed) = sanitizeDirection(v.direction, id)

        val subjects = buildString {
            append("<Subject 1> is $performer in <Video 1>, in ${v.performer.setting}.\n")
            append("<Subject 2> is ${id.name}: ${id.look}, with NO tattoos, shown in $refList")
            id.lora?.let { append(", with LoRA $it video") }
            append(".\n")
            append("<Video 1> is the source video for the editing task.")
            if (v.keepAudio) append("\n<Audio 1> is the synchronized audio track of <Video 1>.")
        }
        val summary = buildString {
            append("[video editing + character replacement")
            if (v.keepAudio) append(" + audio reuse")
            append("] The target video is an edited version of <Video 1> in which <Subject 1> is replaced by <Subject 2>. ")
            append("Every movement, pose, gesture, hand position, head turn, facial expression and mouth movement of <Subject 1> is kept exactly, frame by frame, at exactly the same moments. ")
            append(if (v.keepBackground) "The camera, framing, background, lighting and timing of <Video 1> are unchanged." else "The camera, framing and timing of <Video 1> are unchanged; the background is replaced by the background reference photo${v.backgroundMotion?.let { " ($it)" } ?: ""}.")
            if (v.keepAudio) append(" <Audio 1> is fully reused.")
        }
        val clean = buildList {
            if (v.performer.tattoos) add("None of <Subject 1>'s tattoos remain.")
            if (v.performer.rings) add("None of <Subject 1>'s rings remain.")
        }.joinToString(" ")
        val retention = buildString {
            append("<Video 1> (source video editing): ")
            append(if (v.keepBackground) "fully_preserved - the background, camera position, lighting and the full body motion and timing are maintained exactly.\n"
            else "motion_preserved - the full body motion and timing are maintained exactly; the background is replaced.\n")
            append("<Subject 1>: replaced - identity, face, hair, skin, ${if (v.performer.tattoos) "tattoos, " else ""}body and clothing are all replaced by <Subject 2>; only motion and expressions are kept.")
            if (clean.isNotEmpty()) append(" $clean")
            append("\n<Subject 2>: reference - identity, face, hair, clean tattoo-free skin, body shape and outfit follow <Image 1>-<Image $n>")
            append(" and the ${v.outfit.name.lowercase()} outfit reference set. She wears no ${never.joinToString(", no ")}.")
            append("\n<Audio 1>: ")
            append(if (v.keepAudio) "fully_copy - the original audio is kept unchanged." else "replaced - a new audio track is supplied.")
        }
        val detailed = buildString {
            append("The target video is in realistic photographic style, like a casual smartphone video. ")
            append("[Shot 1] <Subject 2> performs exactly the same motion as <Subject 1> with the same timing, wearing the ${v.outfit.name.lowercase()}. ")
            append("Her skin is smooth and clean with no tattoos. Her face is sharp and detailed and matches <Image 1>, with natural skin texture, natural expressions, stable eyes, natural lips and teeth, and realistic hands with five fingers.")
            if (dir.isNotEmpty()) append(" $dir")
        }
        return H3Prompt(subjects, summary, retention, detailed, if (v.keepAudio) "fully_copy" else "replace", v.steps, v.seed, removed)
    }

    /** Deterministic seed from a name, used when Lock look is on. */
    fun seedFor(key: String): Long = (key.hashCode().toLong() and 0x7fffffff) % 1_000_000
}

/** Every render saves its exact recipe so it can be reproduced or retaken with changes. */
data class RenderRecipe(
    val prompt: String,
    val seed: Long?,
    val model: String,
    val steps: Int?,
    val references: List<String>,
)

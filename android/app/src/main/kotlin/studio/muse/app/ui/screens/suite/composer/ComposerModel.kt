package studio.muse.app.ui.screens.suite.composer

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import studio.muse.app.data.CameraCatalog
import studio.muse.app.data.SuiteCatalog
import studio.muse.app.data.SuiteEstimate
import studio.muse.app.data.SuiteInputs
import studio.muse.app.data.SuiteRules
import studio.muse.app.data.SuiteRefAudio
import studio.muse.app.data.SuiteRefImage
import studio.muse.app.data.SuiteRefVideo
import studio.muse.app.data.SuiteReferences
import studio.muse.app.data.SuiteShotRequest
import studio.muse.app.ui.screens.suite.InputSlots
import studio.muse.app.ui.screens.suite.RecastDraft
import studio.muse.app.ui.screens.suite.SlotId
import studio.muse.app.ui.screens.suite.SlotKind
import studio.muse.core.Pricing

// AI suite (workstream 1): the video composer's state, pure (no Compose, no I/O), so the rules are unit-tested
// (plans/video-composer.md "Decisions", "Tools on the shell", "Presets"). One composer shell; every tool is a preset of
// it with its own tool card, slots and chips. Members choose a quality, never a model.

/** A tool of the shell. [live] false = no backend yet: the tool card shows a quiet "Coming soon" instead of Generate. */
enum class ComposerTool(
    val id: String,
    val title: String,
    val tagline: String,
    val render: String,
    val live: Boolean,
    val chips: List<ComposerChip>,
    val placeholder: String,
) {
    SHOT("shot", "Shot", "Your character in a scene", "palette-04-bleached-warm", true, ComposerChip.entries.toList(),
        "Describe the scene · type @ for your characters, # for a camera move"),
    SWAP("swap", "Character swap", "Your character into a real clip", "palette-01-naturalistic", true, listOf(ComposerChip.LOOK),
        "What changes in the clip (optional)"),
    RECAST("recast", "Recast", "Swap up to 4 people in a clip", "palette-02-teal-orange", true, emptyList(), ""),
    TALKING("talking", "Talking", "Voice & lipsync", "light-06-ring-creator", false, listOf(ComposerChip.CAMERA, ComposerChip.LOOK, ComposerChip.LIGHTING),
        "What she says, or describe the moment · # for a talk-safe move"),
    UGC("ugc", "UGC ad", "Product → ad", "grip-05-slider", false, listOf(ComposerChip.STYLE),
        "What the ad shows · type @ for your characters"),
    EXTEND("extend", "Extend & upscale", "Longer, sharper", "stock-03-sensor", false, emptyList(), "");

    /** The id in the catalog's `tools`. */
    val wire: String get() = if (this == UGC) "ugc_ad" else id

    /** Can Generate now: the catalog's `tools` says (an older catalog without it: [live]). */
    fun isLive(cat: SuiteCatalog?): Boolean = cat?.toolAvailable(wire, live) ?: live

    companion object {
        fun of(id: String?): ComposerTool = entries.firstOrNull { it.id == id || it.wire == id } ?: SHOT
    }
}

/** A slot card beside the prompt. [kind]: character | start | end | clip | people | audio | product | location | refad | video. */
data class ToolSlot(val kind: String, val label: String, val caption: String, val optional: Boolean = false, val enabled: Boolean = true)

/** Phone vs tablet/desktop: at 600 dp and wider the composer uses the desktop layout (pills in the bottom bar). */
object ComposerLayout {
    const val WIDE_DP = 600
    fun wide(widthDp: Int) = widthDp >= WIDE_DP
}

/**
 * The composer: which tool, the prompt with its tokens, the chips' settings and the bottom bar's values. [collapsed]
 * is the preset path: only who, the shape and Generate show until "Edit settings".
 */
data class ComposerDraft(
    val tool: ComposerTool = ComposerTool.SHOT,
    val tokens: PromptTokens = PromptTokens(),
    val settings: ComposerSettings = ComposerSettings(),
    /** The character picked in the CHARACTER slot (an @character token in the prompt wins). */
    val modelId: String? = null,
    val outfitId: String? = null,
    val quality: String = "draft",
    val aspect: String = "9:16",
    val duration: Int = 8,
    /** Native sound (ambience and effects). */
    val sound: Boolean = true,
    /** Speaking: null = Auto. */
    val speaking: Boolean? = null,
    val takes: Int = 1,
    val collapsed: Boolean = false,
    /** Character swap: the prompt sits behind a toggle, off by default. */
    val swapPrompt: Boolean = false,
    val title: String = "",
    /** Directed mode (owner): the camera JSON the camera stage applied; it replaces the chips' camera when set. */
    val directed: String? = null,
) {
    /** The tool card's name and tagline: the preset's when one was picked, else the tool's. */
    fun cardTitle(cat: CameraCatalog): String = settings.preset?.let { id -> cat.presets.firstOrNull { it.id == id }?.label } ?: tool.title
    fun cardTagline(cat: CameraCatalog): String = settings.preset?.let { id -> cat.presets.firstOrNull { it.id == id }?.description } ?: tool.tagline

    /** The lead character: the prompt's @character, else the slot's. */
    val characterId: String? get() = tokens.character?.id ?: modelId
    val characterOutfit: String? get() = tokens.outfit?.id ?: outfitId.takeIf { tokens.character == null || tokens.character?.id == modelId }

    /** Switches tool without leaving the page (Change). The prompt and chips stay; a tool's own defaults apply. */
    fun withTool(t: ComposerTool): ComposerDraft = copy(tool = t, collapsed = false, settings = if (t == ComposerTool.SHOT) settings else settings.copy(preset = null))

    /**
     * Picks a ready-made combo (the beginner path): the tool card becomes the preset, the chips take its values, its move
     * becomes the prompt's #move, and the composer collapses to who + shape + Generate. [defaultCharacter] fills an empty
     * CHARACTER slot so the preset is a one-tap state.
     */
    fun pickPreset(cat: CameraCatalog, id: String, defaultCharacter: String? = null): ComposerDraft {
        val p = cat.presets.firstOrNull { it.id == id } ?: return this
        var t = tokens
        t.moves.forEach { t = t.remove(it.key) }
        val mv = (p.spec?.get("move") as? JsonObject)
        val mvId = (mv?.get("id") as? JsonPrimitive)?.content
        val intensity = (mv?.get("intensity") as? JsonPrimitive)?.content?.toDoubleOrNull()
        cat.move(mvId)?.let { m -> t = t.addMove(m, t.caretAtEnd, ((intensity ?: .5) * 100).toInt()).first }
        // One tap from here: the studio's first character stands in until another is picked (not for photo presets).
        val who = modelId ?: defaultCharacter?.takeIf { id !in PHOTO_PRESETS }
        return copy(tool = ComposerTool.SHOT, settings = settings.fromPreset(cat, id), tokens = t, collapsed = true, modelId = who)
    }

    /** "Edit settings": the full composer with the preset's values in the chips. */
    fun expand(): ComposerDraft = copy(collapsed = false)

    /** Leaves the preset: chips back to Auto, the tool card back to Shot. */
    fun clearPreset(): ComposerDraft = copy(settings = ComposerSettings(gradeLook = settings.gradeLook), collapsed = false)

    /** What the collapsed preset asks for: the character, or a photo for presets built around a product. */
    fun collapsedSlot(): ToolSlot = if (settings.preset in PHOTO_PRESETS) ToolSlot("start", "Photo", "Your product shot") else ToolSlot("character", "Character", "Your models")

    /** The chips this tool shows. */
    val chips: List<ComposerChip> get() = tool.chips

    /** The Length slider's range on [tier]: the tier's min and max seconds (the catalog's), 2–15 when unknown. */
    fun lengthRange(cat: SuiteCatalog?): IntRange {
        val t = cat?.tier(quality)
        val lo = (t?.minSeconds ?: 2).coerceAtLeast(1)
        val hi = (t?.maxSeconds ?: 15).coerceAtLeast(lo)
        return lo..hi
    }

    /** Keeps the length inside the tier's range after a quality change. */
    fun fit(cat: SuiteCatalog?): ComposerDraft = lengthRange(cat).let { r -> if (duration in r) this else copy(duration = duration.coerceIn(r)) }

    /** Phone bar summary: "8 s · 9:16" and "1 take". */
    val barSummary: Pair<String, String> get() = "$duration s · $aspect" to "$takes take${if (takes > 1) "s" else ""}"

    /**
     * What stops Generate, in plain words (null = ready). [slots] are the filled input slots; [recast] carries the clip and
     * the people for Character swap and Recast.
     */
    fun problem(slots: InputSlots, recast: RecastDraft, own: InputSlots = InputSlots()): String? = when (tool) {
        ComposerTool.SHOT -> if (characterId == null && tokens.isEmpty && slots.isEmpty) "Pick a character or describe the shot" else if (slots.uploading) "Waiting for the upload" else null
        ComposerTool.TALKING -> when {
            characterId == null -> "Pick who talks"
            own.uploading -> "Waiting for the upload"
            own[ToolSlots.TALK_AUDIO]?.ready != true -> "Add the audio"
            else -> null
        }
        ComposerTool.UGC -> when {
            characterId == null -> "Pick who presents it"
            own.uploading -> "Waiting for the upload"
            own[ToolSlots.UGC_PRODUCT]?.ready != true -> "Add the product photo"
            else -> null
        }
        ComposerTool.SWAP -> when { recast.clipId == null -> "Choose the source clip"; characterId == null -> "Pick who she becomes"; else -> null }
        ComposerTool.RECAST -> recast.problem()
        else -> "Coming soon"
    }

    /**
     * The request Generate sends (and the estimate prices). Shot: the prompt, tokens, chips and bottom bar, plus the input
     * slots the tier takes. Character swap and Recast: the clip and cast (Recast's people), the quality, takes and the Look.
     */
    fun request(slots: InputSlots, inputs: SuiteInputs, recast: RecastDraft, own: InputSlots = InputSlots()): SuiteShotRequest = when (tool) {
        ComposerTool.SWAP -> {
            val person = recast.people.first().copy(characterId = characterId, outfitId = characterOutfit, speaking = speaking)
            recast.copy(people = listOf(person), quality = quality, takes = takes).request().copy(
                prompt = if (swapPrompt) tokens.promptText() else "",
                camera = settings.copy(body = null, lens = null, focalMm = null, aperture = null, height = null, shotSize = null, genre = null, era = null, tempo = null, lighting = null).cameraJson(),
                gradeLook = if (!settings.gradeLook && (settings.palette != null || settings.stock != null)) false else null,
            )
        }
        ComposerTool.RECAST -> recast.copy(quality = quality, takes = takes).request()
        // Talking and UGC ad are shots: their own slots go in as references (the audio and an optional location photo;
        // the product photo and an optional reference ad), the rest is the composer's.
        ComposerTool.TALKING, ComposerTool.UGC -> {
            val r = composerRequest(tokens, settings, quality, aspect, duration, takes, speaking, title.trim().ifBlank { null })
            val talking = tool == ComposerTool.TALKING
            val image = own[if (talking) ToolSlots.TALK_LOCATION else ToolSlots.UGC_PRODUCT]?.takeIf { it.ready }
                ?.let { v -> v.image?.let { SuiteRefImage(it, if (talking) "location" else "product", v.name.substringBeforeLast('.').take(80).ifBlank { null }) } }
            val audio = if (talking) own[ToolSlots.TALK_AUDIO]?.takeIf { it.ready }?.media?.let { SuiteRefAudio(it) } else null
            val video = if (talking) null else own[ToolSlots.UGC_REFAD]?.takeIf { it.ready }?.media?.let { SuiteRefVideo(it, "style") }
            val refs = SuiteReferences(listOfNotNull(image).ifEmpty { null }, listOfNotNull(video).ifEmpty { null }, audio)
            r.copy(modelId = characterId, outfitId = characterOutfit, audio = if (sound) null else false,
                speaking = if (talking) speaking ?: true else speaking,
                references = refs.takeIf { it.images != null || it.videos != null || it.audio != null })
        }
        else -> {
            val r = composerRequest(tokens, settings, quality, aspect, duration, takes, speaking, title.trim().ifBlank { null })
            val camera = directed?.let { runCatching { kotlinx.serialization.json.Json.parseToJsonElement(it) }.getOrNull() } ?: r.camera
            slots.applyTo(r.copy(modelId = characterId, outfitId = characterOutfit, audio = if (sound) null else false, camera = camera), inputs)
        }
    }

    companion object {
        /** Presets that start from a product photo rather than a character. */
        val PHOTO_PRESETS = setOf("product_hero")
        val SHAPES = listOf("9:16", "1:1", "16:9")
    }
}

/**
 * The slot cards beside the prompt, per tool (the spec's tools table). Shot's start and end frames show only when the
 * tier takes them, and END FRAME is greyed until a start frame exists.
 */
object ToolSlots {
    fun of(tool: ComposerTool, inputs: SuiteInputs, slots: InputSlots, recastMax: Int = SuiteRules.MAX_CAST): List<ToolSlot> = when (tool) {
        ComposerTool.SHOT -> buildList {
            add(ToolSlot("character", "Character", "Your models"))
            if (inputs.start) add(ToolSlot("start", "Start frame", SlotKind.START.caption(inputs), optional = true))
            if (inputs.end) {
                val ok = slots.enabled(SlotId(SlotKind.END))
                add(ToolSlot("end", "End frame", if (ok) SlotKind.END.caption(inputs) else "After a start frame", optional = true, enabled = ok))
            }
        }
        ComposerTool.SWAP -> listOf(ToolSlot("clip", "Clip", "Clip 3–30 s"), ToolSlot("character", "Character", "Your models"))
        ComposerTool.RECAST -> listOf(ToolSlot("clip", "Clip", "Clip 3–30 s"), ToolSlot("people", "People", "1–$recastMax people"))
        ComposerTool.TALKING -> listOf(ToolSlot("character", "Character", "Your models"), ToolSlot("audio", "Audio", "One voice track"),
            ToolSlot("location", "Location", "A photo of the place", optional = true))
        ComposerTool.UGC -> listOf(ToolSlot("character", "Character", "Your models"), ToolSlot("product", "Product", "A photo of it"),
            ToolSlot("refad", "Reference ad", "A video ad to follow", optional = true))
        ComposerTool.EXTEND -> listOf(ToolSlot("video", "Video", "A take or a clip"))
    }

    /** Where the slot cards of Talking and UGC ad keep their files (the store's own slots of those tools). */
    val TALK_AUDIO = SlotId(SlotKind.AUDIO)
    val TALK_LOCATION = SlotId(SlotKind.IMAGE)
    val UGC_PRODUCT = SlotId(SlotKind.IMAGE)
    val UGC_REFAD = SlotId(SlotKind.VIDEO)

    /** The own slot behind a slot card of Talking or UGC ad (null for the others). */
    fun ownSlot(tool: ComposerTool, kind: String): SlotId? = when {
        tool == ComposerTool.TALKING && kind == "audio" -> TALK_AUDIO
        tool == ComposerTool.TALKING && kind == "location" -> TALK_LOCATION
        tool == ComposerTool.UGC && kind == "product" -> UGC_PRODUCT
        tool == ComposerTool.UGC && kind == "refad" -> UGC_REFAD
        else -> null
    }

    /** Tools whose chips are hidden on the shell. */
    fun chipsOf(tool: ComposerTool) = tool.chips
}

/**
 * The price on a Generate button: "—" until it is known, "Free" for test renders, else the estimate's price. A cap
 * problem (estimate not ok) shows the estimate's message and stops Generate.
 */
object ComposerPrice {
    /** The round button and pills: "—", "Free" or "$0.16". */
    fun short(e: SuiteEstimate?): String = when {
        e == null -> "—"
        e.test -> "Free"
        else -> Pricing.money(e.estimate)
    }

    /** A full Generate button: "Generate · —", "Generate · Free", else the estimate's `buttonLabel`. */
    fun button(e: SuiteEstimate?): String = when {
        e == null -> "Generate · —"
        e.test -> "Generate · Free"
        else -> e.buttonLabel.ifBlank { "Generate · ${Pricing.money(e.estimate)}" }
    }

    /** The line under a price ("about $0.16 · 8 s"), "Test render · free" for test renders, null until known. */
    fun line(e: SuiteEstimate?): String? = when {
        e == null -> null
        e.test -> "Test render · free"
        else -> e.priceLine.ifBlank { null }
    }

    /** Why Generate can't go (null = it can): the draft's problem, the estimate's error, or a cap message. */
    fun blocker(problem: String?, e: SuiteEstimate?, error: String?): String? = problem ?: error ?: e?.takeIf { !it.ok }?.let { it.message ?: "Over the studio's limit" }
}

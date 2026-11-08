package studio.muse.app.ui.screens.suite.composer

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import studio.muse.app.data.CameraCatalog
import studio.muse.app.data.SuiteCatalog
import studio.muse.app.data.SuiteEstimate
import studio.muse.app.data.SuiteInputs
import studio.muse.app.data.SuiteRules
import studio.muse.app.data.JobRequest
import studio.muse.app.data.VideoDraft
import studio.muse.app.data.VideoFeatures
import studio.muse.core.VideoOption
import studio.muse.app.data.SuiteLocation
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
    /** Photo tool (workstream 3): Photoshoot on the composer (PhotoTool.kt). Stills: no moves, no tempo. */
    PHOTO("photo", "Photo", "Stills of your character", "lens-01-clean-prime", true, PhotoComposer.CHIPS,
        "Describe the scene and what she does · type @ for your characters"),
    SWAP("swap", "Character swap", "Your character into a real clip", "palette-01-naturalistic", true, listOf(ComposerChip.LOOK),
        "What changes in the clip (optional)"),
    RECAST("recast", "Recast", "Swap up to 4 people in a clip", "palette-02-teal-orange", true, emptyList(), ""),
    TALKING("talking", "Talking", "Voice & lipsync", "light-06-ring-creator", false, listOf(ComposerChip.CAMERA, ComposerChip.LOOK, ComposerChip.LIGHTING),
        "What she says, or describe the moment · # for a talk-safe move"),
    UGC("ugc", "UGC ad", "Product → ad", "grip-05-slider", false, listOf(ComposerChip.STYLE),
        "What the ad shows · type @ for your characters"),
    /** Extend: a longer take from a finished one (after or before). Upscale lives on the finished take itself. */
    EXTEND("extend", "Extend", "A longer take, after or before", "stock-03-sensor", false, emptyList(), "What happens next");

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
    /** Character swap: an add-on (edit | fast) instead of the quality render; null = the quality ladder. */
    val addon: String? = null,
    /** Owner only: the engine pinned for this shot (one of the tier's `models`) and its resolution; null = Auto (the ladder). */
    val engineModel: String? = null,
    val resolution: String? = null,
    /** Extend: "after" (what happens next) or "before" (what happens before). */
    val extendDirection: String = "after",
    /** Claude in the Suite: reference images on the draft (pose, style, location, outfit), ≤ 3; removable chips. */
    val references: List<studio.muse.app.data.DraftReference> = emptyList(),
) {
    /** The prompt's placeholder: Extend's follows the direction. */
    val placeholder: String get() = if (tool == ComposerTool.EXTEND) studio.muse.app.data.ExtendRules.placeholder(extendDirection) else tool.placeholder

    /** The input slots on this quality, or on the pinned engine when the owner pinned one. */
    fun inputsFor(cat: SuiteCatalog?): SuiteInputs = ModelPicker.find(cat, engineModel)?.inputs ?: cat?.tier(quality)?.slotsFor(engineModel) ?: SuiteInputs.NONE

    /** Pins one of the tier's engines (null = Auto). */
    fun pin(m: studio.muse.app.data.SuiteTierModel?): ComposerDraft = copy(engineModel = m?.model, resolution = m?.resolution?.ifBlank { null }).let { d ->
        // The pinned engine's length limits apply at once (a 15 s take on a 10 s engine becomes 10 s).
        val lo = m?.minSeconds; val hi = m?.maxSeconds
        if (lo != null && hi != null && hi >= lo) d.copy(duration = d.duration.coerceIn(lo, hi)) else d
    }

    /** The Settings row's value: "Auto", or the pinned engine's name (owner only: members' catalogs carry no engines). */
    fun engineLabel(cat: SuiteCatalog?): String = modelLabel(cat)
    /** The picked add-on of Character swap (null on other tools or on the quality ladder). */
    val swapAddon: SwapAddon? get() = if (tool == ComposerTool.SWAP) SwapAddon.of(addon)?.takeIf { it.option != null } else null
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

    /**
     * The prompt was backspaced to empty (owner decision 2026-11-08): the selected preset is unselected and the composer is
     * the normal one again ([clearPreset]). Nothing changes while the prompt has anything in it or no preset is picked.
     */
    fun unselectingPreset(): ComposerDraft = if (tokens.isEmpty && (collapsed || settings.preset != null)) clearPreset() else this

    /** What the collapsed preset asks for: the character, or a photo for presets built around a product. */
    fun collapsedSlot(): ToolSlot = if (settings.preset in PHOTO_PRESETS) ToolSlot("start", "Photo", "Your product shot") else ToolSlot("character", "Character", "Your models")

    /** The chips this tool shows. */
    val chips: List<ComposerChip> get() = tool.chips

    /** The Length slider's range on [tier]: the tier's min and max seconds (the catalog's), 2–15 when unknown. */
    fun lengthRange(cat: SuiteCatalog?): IntRange {
        val t = cat?.tier(quality)
        // An engine the owner pinned has its own limits (when the server sends them); otherwise the tier's.
        val e = ModelPicker.find(cat, engineModel)
        val lo = (e?.minSeconds ?: t?.minSeconds ?: 2).coerceAtLeast(1)
        val hi = (e?.maxSeconds ?: t?.maxSeconds ?: 15).coerceAtLeast(lo)
        return lo..hi
    }

    /** Keeps the length inside the tier's range after a quality change. */
    fun fit(cat: SuiteCatalog?): ComposerDraft {
        val r = lengthRange(cat)
        val sized = if (duration in r) this else copy(duration = duration.coerceIn(r))
        // A pin the catalog doesn't have (a member's catalog has none), or a ladder engine of another quality, goes back to Auto.
        val e = ModelPicker.find(cat, engineModel)
        val ok = engineModel == null || (e != null && (e.tiers.isEmpty() || quality in e.tiers))
        return if (ok) sized else sized.copy(engineModel = null, resolution = null)
    }

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
        // Photo tool (workstream 3): the uploads and the run are checked by PhotoComposer.problem.
        ComposerTool.PHOTO -> if (characterId == null) "Pick a character" else null
        ComposerTool.RECAST -> recast.problem()
        ComposerTool.EXTEND -> {
            val v = own[ToolSlots.EXTEND_VIDEO]
            when {
                v == null -> "Pick the video to extend"
                own.uploading -> "Waiting for the upload"
                v.error != null -> v.error
                !v.ready -> "Pick the video to extend"
                // An upload carries its own length (the server's limit is 60 s); a take's comes from the take.
                v.media?.seconds?.let { it > studio.muse.app.data.ExtendRules.MAX_UPLOAD_SECONDS } == true -> "Pick a video up to 60 s"
                v.use == ExtendSlot.UPLOAD && v.media?.seconds == null -> "Couldn't read that video's length"
                else -> null
            }
        }
    }

    /**
     * The request Generate sends (and the estimate prices). Shot: the prompt, tokens, chips and bottom bar, plus the input
     * slots the tier takes. Character swap and Recast: the clip and cast (Recast's people), the quality, takes and the Look.
     */
    fun request(slots: InputSlots, inputs: SuiteInputs, recast: RecastDraft, own: InputSlots = InputSlots(), locations: List<SuiteLocation> = emptyList()): SuiteShotRequest =
        baseRequest(slots, inputs, recast, own).let { r ->
            if (tool in PROMPT_TOOLS) withLocations(r, inputs, locations).copy(engineModel = engineModel, resolution = resolution.takeIf { engineModel != null }) else r
        }.let { r -> if (tool in PROMPT_TOOLS) withDraftReferences(r) else r }
            .copy(draft = ComposerDrafts.draft(this)) // Reuse settings: the composer as it was, stored with the job and its takes

    /**
     * The draft's reference images (Claude adds the owner's photos as pose, style, location or outfit) as
     * `references.images[{image, role: use, label}]` after the slots and @locations. The model's own references always
     * carry her identity; the engine may send fewer when the quality has less room (the estimate says so).
     */
    fun withDraftReferences(r: SuiteShotRequest): SuiteShotRequest {
        if (references.isEmpty()) return r
        val add = references.take(3).map { SuiteRefImage(studio.muse.app.data.ImageRef(url = it.url), it.use, it.label ?: it.useLabel) }
        return r.copy(references = (r.references ?: SuiteReferences()).copy(images = r.references?.images.orEmpty() + add))
    }

    /**
     * The prompt's @locations as references: `{image, role: "location", label: name}` after the slots' images, never more
     * than the quality's References limit (`inputs.images`). A location the library no longer has is left out.
     */
    fun withLocations(r: SuiteShotRequest, inputs: SuiteInputs, locations: List<SuiteLocation>): SuiteShotRequest {
        val places = tokens.mentions.filter { it.kind == "location" }.mapNotNull { m -> locations.firstOrNull { it.id == m.id } }
        if (places.isEmpty()) return r
        val have = r.references?.images.orEmpty()
        val room = (SlotKind.IMAGE.capacity(inputs) - have.size).coerceAtLeast(0)
        val add = places.distinctBy { it.id }.take(room).map { SuiteRefImage(it.image, "location", it.name.take(80)) }
        if (add.isEmpty()) return r
        return r.copy(references = (r.references ?: SuiteReferences()).copy(images = have + add))
    }

    /** Reference images in use: the filled image slots the quality takes, plus the prompt's @locations. */
    fun referencesUsed(slots: InputSlots, inputs: SuiteInputs, own: InputSlots = InputSlots()): Int {
        val cap = SlotKind.IMAGE.capacity(inputs)
        val slotImages = when (tool) {
            ComposerTool.TALKING, ComposerTool.UGC -> own.values.keys.count { it.kind == SlotKind.IMAGE }
            else -> slots.values.keys.count { it.kind == SlotKind.IMAGE && it.index < cap }
        }
        return slotImages + tokens.mentions.filter { it.kind == "location" }.distinctBy { it.id }.size
    }

    /** Why another @location can't go in (null = it can): the References limit is `inputs.images`. */
    fun locationProblem(slots: InputSlots, inputs: SuiteInputs, own: InputSlots = InputSlots(), id: String? = null): String? {
        if (id != null && tokens.mentions.any { it.kind == "location" && it.id == id }) return null
        val cap = SlotKind.IMAGE.capacity(inputs)
        return when {
            cap == 0 -> "${SuiteRules.tierLabel(quality)} doesn't take reference images · try another quality"
            referencesUsed(slots, inputs, own) >= cap -> "References are full · up to $cap on ${SuiteRules.tierLabel(quality)}"
            else -> null
        }
    }

    private fun baseRequest(slots: InputSlots, inputs: SuiteInputs, recast: RecastDraft, own: InputSlots): SuiteShotRequest = when (tool) {
        ComposerTool.SWAP -> {
            val person = recast.people.first().copy(characterId = characterId, outfitId = characterOutfit, speaking = speaking)
            recast.copy(people = listOf(person), quality = quality, takes = takes).request().copy(
                prompt = if (swapPrompt) tokens.promptText() else "",
                camera = settings.copy(body = null, lens = null, focalMm = null, aperture = null, height = null, shotSize = null, genre = null, era = null, tempo = null, lighting = null).cameraJson(),
                gradeLook = if (!settings.gradeLook && (settings.palette != null || settings.stock != null)) false else null,
            )
        }
        ComposerTool.RECAST -> recast.copy(quality = quality, takes = takes).request()
        // Extend: the VIDEO slot's take key (or upload key + seconds), the direction, the new part's length and the prompt.
        // The shape comes from the source, so no aspect ratio; no camera, sound or speaking (the server doesn't take them here).
        ComposerTool.EXTEND -> SuiteShotRequest(
            mode = studio.muse.app.data.ExtendRules.MODE,
            extend = own[ToolSlots.EXTEND_VIDEO]?.takeIf { it.ready }?.media?.let { m -> studio.muse.app.data.SuiteExtend(ExtendSlot.ref(m), extendDirection) },
            title = title.trim().ifBlank { null }, prompt = tokens.promptText(), duration = duration, quality = quality, takes = takes,
        )
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
        /** Tools with a prompt that takes @ tokens and reference images. */
        val PROMPT_TOOLS = setOf(ComposerTool.SHOT, ComposerTool.TALKING, ComposerTool.UGC)
        val SHAPES = listOf("9:16", "1:1", "16:9")
    }
}

/**
 * Character swap's add-ons (plans/api.md "App clean-up" §2): Edit and Fast · beta render the swap on their own engines
 * (POST /v1/jobs), Upscale sharpens a finished take (coming soon). They sit beside the quality ladder as pills; the
 * ladder stays the main choice.
 */
enum class SwapAddon(val id: String, val label: String, val option: VideoOption?, val detail: String) {
    EDIT("edit", "Edit", VideoOption.EDIT, VideoOption.EDIT.detail),
    FAST("fast", "Fast · beta", VideoOption.FAST, VideoOption.FAST.detail),
    UPSCALE("upscale", "Upscale", null, "Sharper 1080p, 2K or 4K from a finished take");

    companion object {
        fun of(id: String?) = entries.firstOrNull { it.id == id }
    }
}

/** A pill: the add-on, whether it can be picked now, and its price ("$0.67", "—", "Soon"). */
data class AddonPill(val addon: SwapAddon, val available: Boolean, val price: String)

object SwapAddons {
    /**
     * The pills: Edit, Fast · beta (only with the Fast beta switch on and when the server offers it) and Upscale
     * (greyed "Soon" until the server says it's available).
     */
    fun pills(video: VideoFeatures, fastBeta: Boolean, takes: Int, clipSeconds: Double?): List<AddonPill> = SwapAddon.entries.mapNotNull { a ->
        when (a) {
            SwapAddon.UPSCALE -> studio.muse.app.data.UpscaleOffer.live(video.upscale).let { live -> AddonPill(a, live, if (live) "On the take" else "Soon") }
            SwapAddon.FAST -> if (!fastBeta || !video.available(a.id)) null else AddonPill(a, true, price(a, takes, clipSeconds))
            SwapAddon.EDIT -> AddonPill(a, video.available(a.id), price(a, takes, clipSeconds))
        }
    }

    /** The add-on's render, set up exactly as the video studio sends it: the whole clip, the default steps. */
    fun draft(a: SwapAddon, takes: Int, keepAudio: Boolean, speaking: Boolean?): VideoDraft =
        VideoDraft(takes = takes, keepAudio = keepAudio, speaking = speaking ?: false).pick(a.option ?: VideoOption.EDIT)

    /** The price from the add-on estimate (the server's formula, Pricing): "—" without a clip length. */
    fun price(a: SwapAddon, takes: Int, clipSeconds: Double?): String =
        if (clipSeconds == null || a.option == null) "—" else Pricing.money(Pricing.totalCost(draft(a, takes, true, null).spec().copy(clipSeconds = clipSeconds)))

    /** The add-on's estimate as the Generate button shows it ("Generate · 10 min · $0.67", "about $0.67"). */
    fun estimate(a: SwapAddon, takes: Int, clipSeconds: Double): SuiteEstimate {
        val spec = draft(a, takes, true, null).spec().copy(clipSeconds = clipSeconds)
        return SuiteEstimate(quality = a.id, label = a.label, takes = takes, mode = "swap", estimate = Pricing.totalCost(spec),
            priceLine = Pricing.optionPriceLine(spec), buttonLabel = Pricing.genLabel(spec))
    }

    /** POST /v1/jobs for the add-on: the clip, the character and outfit, takes, the clip's audio and the speaking switch. */
    fun request(d: ComposerDraft, recast: RecastDraft, a: SwapAddon, clipSeconds: Double?): JobRequest =
        draft(a, d.takes, recast.keepAudio, d.speaking).request(d.title.trim().ifBlank { "Character swap · ${a.label}" }, d.characterId.orEmpty(),
            d.characterOutfit.orEmpty(), recast.clipId.orEmpty(), clipSeconds)
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
        ComposerTool.EXTEND -> listOf(ToolSlot("video", "Video", "A take or a video"))
        // Photo tool (workstream 3): drawn by PhotoSlotRow (PhotoViews.kt), with sentence-case labels.
        ComposerTool.PHOTO -> listOf(ToolSlot("character", "Character", "Your models"), ToolSlot("outfit", "Outfit", "Her outfits"),
            ToolSlot("product", "Product", "A photo of it", optional = true), ToolSlot("refs", "References", "Pose, look or scene", optional = true))
    }

    /** Extend's VIDEO slot (the store's extendSlots). */
    val EXTEND_VIDEO = SlotId(SlotKind.VIDEO)

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
        tool == ComposerTool.EXTEND && kind == "video" -> EXTEND_VIDEO
        else -> null
    }

    /** Tools whose chips are hidden on the shell. */
    fun chipsOf(tool: ComposerTool) = tool.chips
}

/**
 * What goes in Extend's VIDEO slot. A take: its stored key only (the server reads its length). An upload: its key and the
 * `seconds` read from the file. [SlotValue.use] tells them apart ("take" | "upload").
 */
object ExtendSlot {
    const val TAKE = "take"
    const val UPLOAD = "upload"

    fun fromTake(t: studio.muse.app.data.Take, key: String): studio.muse.app.ui.screens.suite.SlotValue =
        studio.muse.app.ui.screens.suite.SlotValue(
            name = listOfNotNull(t.title.ifBlank { "Take" }, "Take ${t.index}", t.durationSec?.let { "${studio.muse.app.data.FakeSuite.fmtSeconds(Math.round(it * 10) / 10.0)} s" }).joinToString(" · "),
            image = t.thumb, media = studio.muse.app.data.SuiteMediaRef(key = key), use = TAKE,
        )

    /** The video ref sent: a take is `{key}`; an upload `{key, seconds}` (or `{url, seconds}` for a link). */
    fun ref(m: studio.muse.app.data.SuiteMediaRef): studio.muse.app.data.SuiteMediaRef =
        if (m.key != null) studio.muse.app.data.SuiteMediaRef(key = m.key, seconds = m.seconds?.let { Math.round(it * 100) / 100.0 })
        else studio.muse.app.data.SuiteMediaRef(url = m.url, seconds = m.seconds?.let { Math.round(it * 100) / 100.0 })

    /** The takes that can go in the slot, newest first: finished renders with a stored video (demo: simulated takes too). */
    fun candidates(takes: List<studio.muse.app.data.Take>, demo: Boolean, max: Int = 24): List<studio.muse.app.data.Take> =
        takes.filter { studio.muse.app.data.ExtendRules.keyOf(it, demo) != null }.sortedByDescending { it.createdAt }.take(max)
}

/**
 * The price on a Generate button: "—" until it is known, "Free" for test renders, else the estimate's price. A cap
 * problem (estimate not ok) shows the estimate's message and stops Generate.
 */
object ComposerPrice {
    /** The round button and pills: "—", "Free" or "$0.16"; "…" while the estimate is on its way ([pricing]). */
    fun short(e: SuiteEstimate?, pricing: Boolean = false): String = when {
        e == null -> if (pricing) "…" else "—"
        e.test -> "Free"
        else -> Pricing.money(e.estimate)
    }

    /** A full Generate button: "Generate · —", "Generate · Pricing…" while estimating, "Generate · Free", else the estimate's `buttonLabel`. */
    fun button(e: SuiteEstimate?, pricing: Boolean = false): String = when {
        e == null -> if (pricing) "Generate · Pricing…" else "Generate · —"
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

package studio.muse.app.ui.screens.suite

import studio.muse.app.data.ImageRef
import studio.muse.app.data.SuiteFrames
import studio.muse.app.data.SuiteInputs
import studio.muse.app.data.SuiteMediaRef
import studio.muse.app.data.SuiteRefAudio
import studio.muse.app.data.SuiteRefImage
import studio.muse.app.data.SuiteRefVideo
import studio.muse.app.data.SuiteReferences
import studio.muse.app.data.SuiteShotRequest

// AI suite (workstream 1): the Shot's input slots (start / middle / end frames, reference images and videos, one audio
// track), pure (no Compose, no I/O) so the rules are unit-tested. Which slots show comes from the catalog's `inputs` for
// the chosen tier (or, for the owner, the chosen engine): a slot shows only when that tier takes it. No layout here:
// a screen asks for [InputSlots.visible] and arranges the tiles (InputSlotTile) itself.

/** The kinds of slot, in the order a screen usually lists them. `mime` is what the picker asks for. */
enum class SlotKind(val label: String, val hint: String, val mime: String) {
    START("Start frame", "The shot opens on this", "image/*"),
    MIDDLE("Middle frame", "A moment the shot passes through", "image/*"),
    END("End frame", "The shot ends on this", "image/*"),
    IMAGE("Reference", "A product, place, style or prop", "image/*"),
    VIDEO("Video", "Motion or camera to follow", "video/*"),
    AUDIO("Audio", "A voice or a beat", "audio/*");

    val isImage: Boolean get() = mime.startsWith("image")
    val isFrame: Boolean get() = this == START || this == MIDDLE || this == END

    /** How many of this kind the tier takes. */
    fun capacity(i: SuiteInputs): Int = when (this) {
        START -> if (i.start) 1 else 0
        END -> if (i.end) 1 else 0
        MIDDLE -> i.middle.coerceIn(0, 8)
        IMAGE -> i.images.coerceIn(0, 6)
        VIDEO -> i.videos.coerceIn(0, 3)
        AUDIO -> if (i.audio) 1 else 0
    }
}

/** One slot: its kind and its place among slots of the same kind (0-based). */
data class SlotId(val kind: SlotKind, val index: Int = 0) {
    /** "Reference 2", "Start frame". */
    val title: String get() = if (kind == SlotKind.MIDDLE || kind == SlotKind.IMAGE || kind == SlotKind.VIDEO) "${kind.label} ${index + 1}" else kind.label
}

/**
 * What is in a slot: the picked file's name and, once uploaded, its image or media ref. [progress] is 0..1 while it
 * uploads; [error] is a member-safe line when it failed. [preview] is a local URI string to draw before the upload ends.
 * [role] (references only): product | location | style | prop | person; video [use]: motion | camera | style.
 */
data class SlotValue(
    val name: String = "",
    val image: ImageRef? = null,
    val media: SuiteMediaRef? = null,
    val preview: String? = null,
    val progress: Float? = null,
    val error: String? = null,
    val role: String = "product",
    val use: String = "motion",
    /** Identifies one pick across renumbering (an upload finishing after the slots above it were cleared). */
    val token: Long = 0,
) {
    val ready: Boolean get() = (image != null || media != null) && progress == null && error == null
    val uploading: Boolean get() = progress != null
}

/** The filled slots of a shot. Immutable: each change returns a new one (keep it in a StateFlow or `mutableStateOf`). */
data class InputSlots(val values: Map<SlotId, SlotValue> = emptyMap()) {
    operator fun get(id: SlotId): SlotValue? = values[id]

    private fun filled(kind: SlotKind) = values.keys.filter { it.kind == kind }.sortedBy { it.index }

    /**
     * The slots to show for [inputs], in [SlotKind] order: for one-of kinds the single slot; for many-of kinds the filled
     * ones the tier takes, then one empty "add" slot while there is room. Kinds the tier doesn't take don't show.
     */
    fun visible(inputs: SuiteInputs): List<SlotId> = SlotKind.entries.flatMap { k ->
        val cap = k.capacity(inputs)
        if (cap == 0) return@flatMap emptyList()
        if (cap == 1) return@flatMap listOf(SlotId(k))
        val have = filled(k).filter { it.index < cap }
        if (have.size < cap) have + SlotId(k, have.size) else have
    }

    /** Filled slots this tier doesn't take: they stay (switching back brings them back) but aren't sent. */
    fun hidden(inputs: SuiteInputs): List<SlotId> = values.keys.filter { it.index >= it.kind.capacity(inputs) }.sortedWith(compareBy({ it.kind.ordinal }, { it.index }))

    /** Puts [v] in [id]. A many-of kind fills from the front, so a new value lands in the first free place. */
    fun put(id: SlotId, v: SlotValue): InputSlots = copy(values = values + (place(id) to v))

    /** Where [put] would store a value for [id]: itself when filled, else the first free place of its kind. */
    fun place(id: SlotId): SlotId = if (id in values) id else SlotId(id.kind, minOf(id.index, filled(id.kind).size))

    /** Changes a slot's value in place (upload progress, done, failed). Does nothing if it was cleared meanwhile. */
    fun update(id: SlotId, f: (SlotValue) -> SlotValue): InputSlots = values[id]?.let { copy(values = values + (id to f(it))) } ?: this

    /** Changes the value picked with [token], wherever it has moved. Does nothing if it was cleared meanwhile. */
    fun updateToken(token: Long, f: (SlotValue) -> SlotValue): InputSlots =
        values.entries.firstOrNull { it.value.token == token }?.let { e -> copy(values = values + (e.key to f(e.value))) } ?: this

    /** Empties a slot; the others of its kind move up so there are no gaps. */
    fun clear(id: SlotId): InputSlots {
        if (id !in values) return this
        val rest = values - id
        val moved = rest.filterKeys { it.kind != id.kind } +
            rest.filterKeys { it.kind == id.kind }.entries.sortedBy { it.key.index }.mapIndexed { i, e -> SlotId(id.kind, i) to e.value }
        return InputSlots(moved)
    }

    val uploading: Boolean get() = values.values.any { it.uploading }
    val isEmpty: Boolean get() = values.isEmpty()

    /** Ready values the tier takes, in order. */
    private fun sent(kind: SlotKind, inputs: SuiteInputs) = filled(kind).filter { it.index < kind.capacity(inputs) }.mapNotNull { values[it]?.takeIf { v -> v.ready } }

    private fun hasFrames(inputs: SuiteInputs) = listOf(SlotKind.START, SlotKind.MIDDLE, SlotKind.END).any { sent(it, inputs).isNotEmpty() }
    private fun hasRefs(inputs: SuiteInputs) = listOf(SlotKind.IMAGE, SlotKind.VIDEO, SlotKind.AUDIO).any { sent(it, inputs).isNotEmpty() }

    /**
     * A line to show near the slots, or null: when frames and references are both filled but this quality can't combine
     * them (`framesWithRefs` false), or when filled slots aren't taken on this quality.
     */
    fun note(inputs: SuiteInputs): String? = when {
        hasFrames(inputs) && hasRefs(inputs) && !inputs.framesWithRefs -> "On this quality the frames carry the look · references aren't used"
        hidden(inputs).isNotEmpty() -> hidden(inputs).let { h -> "${h.size} input${if (h.size > 1) "s" else ""} not used on this quality" }
        else -> null
    }

    /** [req] with the frames and references of the ready slots this tier takes (others left out, as the server would refuse them). */
    fun applyTo(req: SuiteShotRequest, inputs: SuiteInputs): SuiteShotRequest {
        val start = sent(SlotKind.START, inputs).firstOrNull()?.image
        val end = sent(SlotKind.END, inputs).firstOrNull()?.image
        val middle = sent(SlotKind.MIDDLE, inputs).mapNotNull { it.image }
        val frames = if (start != null || end != null || middle.isNotEmpty()) SuiteFrames(start, middle.ifEmpty { null }, end) else null
        val images = sent(SlotKind.IMAGE, inputs).mapNotNull { v -> v.image?.let { SuiteRefImage(it, v.role, v.name.substringBeforeLast('.').take(80).ifBlank { null }) } }
        val videos = sent(SlotKind.VIDEO, inputs).mapNotNull { v -> v.media?.let { SuiteRefVideo(it, v.use) } }
        val audio = sent(SlotKind.AUDIO, inputs).firstOrNull()?.media?.let { SuiteRefAudio(it) }
        val refs = if (images.isNotEmpty() || videos.isNotEmpty() || audio != null) SuiteReferences(images.ifEmpty { null }, videos.ifEmpty { null }, audio) else null
        return req.copy(frames = frames, references = refs)
    }

    companion object {
        /** Image roles a reference can have, as the server names them. */
        val ROLES = listOf("product", "location", "style", "prop", "person")
        /** What a reference video is for. */
        val USES = listOf("motion", "camera", "style")
        /** Upload limits the apps check before sending (the server checks too). */
        const val MAX_IMAGE_BYTES = 20L * 1024 * 1024
        const val MAX_MEDIA_BYTES = 200L * 1024 * 1024
    }
}

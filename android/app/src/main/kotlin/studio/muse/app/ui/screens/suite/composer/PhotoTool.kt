package studio.muse.app.ui.screens.suite.composer

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.serialization.json.JsonObject
import studio.muse.app.AppContainer
import studio.muse.app.data.ErrorText
import studio.muse.app.data.ImageRef
import studio.muse.app.data.PhotoEstimate
import studio.muse.app.data.PhotoRequest
import studio.muse.app.data.PhotoRules
import studio.muse.app.data.ShootRef
import studio.muse.app.data.SuiteEstimate
import studio.muse.app.data.SuiteRules
import studio.muse.app.data.Take

// AI suite · the Photo tool (workstream 3, plans/video-composer.md "Photo tool"). Photoshoot folded into the composer:
// the character and her outfit, an optional product photo and up to 3 references, the Style / Camera / Look / Lighting
// chips compiled for a still, and a Photos 1–4 count. This file is the pure part (unit-tested) and the store; the views
// are in PhotoViews.kt.

/** What the Photo tool adds to the composer's draft. [presetId] is a photo template (GET /v1/templates). */
data class PhotoDraft(
    val count: Int = PhotoRules.DEFAULT_COUNT,
    val presetId: String? = null,
    /** Up to 3 references, each guiding pose, look and/or scene (never her face, body or outfit). */
    val refs: List<ShootRef> = emptyList(),
    /** The optional product photo, once uploaded. */
    val product: ImageRef? = null,
    /** An upload in progress: "product" or "ref". */
    val uploading: String? = null,
    /** Owner only (WS5/WS7): the image model for this run ("owner/name" or a custom `c_…`); null = the studio's photo model. */
    val imageModel: String? = null,
) {
    val canAddRef: Boolean get() = refs.size < ShootRef.MAX
}

object PhotoComposer {
    /** The chips Photo shows: Style (without Tempo), Camera (Setup and Angle), Look and Lighting. */
    val CHIPS = listOf(ComposerChip.STYLE, ComposerChip.CAMERA, ComposerChip.LOOK, ComposerChip.LIGHTING)
    /** The Camera picker's tabs on Photo: no Movement, no Directed (a still has no camera path). */
    val CAMERA_TABS = setOf("setup", "angle")
    /** The Style picker's tabs on Photo: no Tempo. */
    val STYLE_TABS = setOf("genre", "era")

    /**
     * The rig as a still takes it: the composer's camera JSON with no move, no mix and no tempo (#move tokens in the prompt
     * are never sent). Null when everything is Auto.
     */
    fun camera(s: ComposerSettings): JsonObject? = s.copy(tempo = null, format = null, preset = null).cameraJson(emptyList())

    /**
     * POST /v1/suite/photos[/estimate] from the composer: the character and outfit (an @character in the prompt wins),
     * the prompt's words (tokens' labels, no #moves), the rig for a still, the count, the product and the references.
     * With a preset, the camera isn't sent: the preset carries its own camera and light. Null without a character.
     */
    fun request(d: ComposerDraft, p: PhotoDraft): PhotoRequest? {
        val who = d.characterId ?: return null
        val s = d.settings
        return PhotoRequest(
            modelId = who, outfitId = d.characterOutfit, prompt = d.tokens.promptText().take(2000),
            camera = if (p.presetId != null) null else camera(s),
            gradeLook = if (!s.gradeLook && (s.palette != null || s.stock != null)) false else null,
            count = p.count.coerceIn(1, PhotoRules.MAX_COUNT), presetId = p.presetId, productImage = p.product,
            references = p.refs.take(ShootRef.MAX).ifEmpty { null }, title = d.title.trim().ifBlank { null },
            // Reuse settings: the composer as it was, stored on every still.
            draft = ComposerDrafts.draft(d, photoCount = p.count, presetId = p.presetId),
            imageModel = p.imageModel,
        )
    }

    /** What stops Generate on Photo (null = ready). */
    fun problem(d: ComposerDraft, p: PhotoDraft, busy: Boolean = false): String? = when {
        busy -> "Making the photos…"
        d.characterId == null -> "Pick a character"
        p.uploading != null -> "Waiting for the upload"
        else -> null
    }

    /**
     * The estimate in the shape the composer's bar and rig row read (Generate shows [PhotoEstimate.buttonLabel], the rig
     * row its `rig`). Photos are never test renders: the price is always shown.
     */
    fun asEstimate(e: PhotoEstimate): SuiteEstimate = SuiteEstimate(
        quality = PhotoRules.TOOL, label = "Photo", takes = e.count, mode = PhotoRules.TOOL, estimate = e.estimate,
        priceLine = e.priceLine, buttonLabel = e.buttonLabel.ifBlank { PhotoRules.button(e.count, studio.muse.core.Pricing.money(e.estimate)) },
        ok = e.ok, warnings = e.warnings, prompt = e.prompt.orEmpty(), look = e.look, rig = e.rig,
    )

    /** The member's view: no model or provider words in the notes or the rig row, and no prompt. */
    fun memberSafe(e: PhotoEstimate): PhotoEstimate = e.copy(prompt = null, warnings = e.warnings.filterNot { SuiteRules.PROVIDER_WORDS.containsMatchIn(it) },
        rig = SuiteRules.memberSafe(e.rig))

    /** The bar's "Photos" list: "1 photo" … "4 photos". */
    fun countItems(current: Int): List<Pair<String, Boolean>> = (1..PhotoRules.MAX_COUNT).map { PhotoRules.noun(it) to (it == current) }

    /** The stills of the library, newest first (old Photoshoot shots and Photo takes alike). */
    fun recent(takes: List<Take>, max: Int = 12): List<Take> = takes.filter { it.kind == "shot" }.sortedByDescending { it.createdAt }.take(max)

    /**
     * Opens Photo with [modelId] and [outfitId] picked (the outfit set generator's link, the profile's Photo button, a
     * redirected Photoshoot link). The prompt and chips stay; a character token naming someone else gives way.
     */
    fun open(d: ComposerDraft, modelId: String?, outfitId: String?): ComposerDraft {
        val base = d.withTool(ComposerTool.PHOTO)
        if (modelId == null) return base
        val t = base.tokens.character?.takeIf { it.id != modelId }?.let { base.tokens.remove(it.key) } ?: base.tokens
        return base.copy(modelId = modelId, outfitId = outfitId, tokens = t)
    }
}

/** The Photo tool's session state (held by SuiteStore): the draft, the estimate and the run. */
class PhotoStore(private val c: AppContainer) {
    val draft = MutableStateFlow(PhotoDraft())
    val busy = MutableStateFlow(false)

    private val owner: Boolean get() = c.repo.state.value.wallet?.owner ?: c.prefs.value.owner

    /** The price, notes and still rig check (free; holds nothing); a member never gets engine words. */
    suspend fun estimate(req: PhotoRequest): Pair<PhotoEstimate?, String?> {
        val (e, err) = c.repo.attemptInline { photoEstimate(req) }
        return (e?.let { if (owner) it else PhotoComposer.memberSafe(it) }) to err?.let { safe(it) }
    }

    /** Generate: the stills (in the library at once), or null with a toast. Only a tap calls this. */
    suspend fun generate(req: PhotoRequest): List<Take>? {
        if (busy.value) return null
        busy.value = true
        try {
            val (r, err) = c.repo.createPhotos(req)
            if (err != null) c.repo.toast(safe(err))
            val takes = r?.takes?.takeIf { it.isNotEmpty() } ?: return null
            c.drafts.freshShots.value = takes.size
            c.drafts.galleryTab.value = "tests"
            return takes
        } finally { busy.value = false }
    }

    /** Adds the product photo or a reference (uploaded first). A new reference starts on the first guide the others don't use. */
    suspend fun upload(kind: String, name: String, bytes: ByteArray, mime: String) {
        if (draft.value.uploading != null) return
        if (kind == "ref" && !draft.value.canAddRef) return c.repo.toast("Up to ${ShootRef.MAX} references")
        draft.update { it.copy(uploading = kind) }
        try {
            val ref = c.repo.uploadImage(name, bytes, mime) ?: return
            draft.update { d ->
                if (kind == "product") d.copy(product = ref)
                else if (!d.canAddRef) d else d.copy(refs = d.refs + ShootRef(ref, listOf(ShootRef.defaultGuide(d.refs))))
            }
        } finally { draft.update { it.copy(uploading = null) } }
    }

    /** Pose & framing / Look & colour / Scene: at least one stays on. */
    fun toggleGuide(i: Int, guide: String) = draft.update { d ->
        val r = d.refs.getOrNull(i) ?: return@update d
        val next = r.toggled(guide) ?: run { c.repo.toast("Keep at least one on: pose, look or scene"); return@update d }
        d.copy(refs = d.refs.toMutableList().also { it[i] = next })
    }

    fun removeRef(i: Int) = draft.update { d -> d.copy(refs = d.refs.filterIndexed { k, _ -> k != i }) }
    fun clearProduct() = draft.update { it.copy(product = null) }
    fun setCount(n: Int) = draft.update { it.copy(count = n.coerceIn(1, PhotoRules.MAX_COUNT)) }
    /** Owner only: pin an image model for the next runs (null = the studio's photo model). */
    fun setImageModel(id: String?) = draft.update { it.copy(imageModel = id) }
    /** Picks a photo preset; picking the same one again clears it. */
    fun pickPreset(id: String?) = draft.update { it.copy(presetId = if (id == it.presetId) null else id) }
    /** The prompt was backspaced to empty (owner decision 2026-11-08): the photo preset is unselected. */
    fun clearPreset() = draft.update { it.copy(presetId = null) }

    private fun safe(s: String) = if (!owner && SuiteRules.PROVIDER_WORDS.containsMatchIn(s)) ErrorText.WENT_WRONG else s
}

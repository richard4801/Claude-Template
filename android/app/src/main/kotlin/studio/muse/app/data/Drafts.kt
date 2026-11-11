package studio.muse.app.data

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import studio.muse.core.ClipUse
import studio.muse.core.Engine
import studio.muse.core.Pricing
import studio.muse.core.Quality
import studio.muse.core.RenderSpec
import studio.muse.core.VideoOption

/** The video being set up across New video → Direct. Retry and "Run again" load a past job into it. */
data class VideoDraft(
    val clip: Clip? = null,
    val showBadExample: Boolean = false,
    /** Render (Draft / Standard / HD) by default; the Edit add-on = h3; Fast · beta = viggle. */
    val engine: Engine = Engine.REPLICATE,
    /** Replicate quality. Draft is the default (the owner's choice). */
    val quality: Quality = Quality.DRAFT,
    val steps: Int = Pricing.STEPS_DEFAULT,
    /** Always the whole clip (the First 5.2s choice is gone). */
    val use: ClipUse = ClipUse.FULL,
    val takes: Int = 1,
    val keepAudio: Boolean = true,
    val lipSync: Boolean = false,
    val background: String = "keep",
    val motion: String = "subtle",
    val tool: String = "quality",
    /** "Performer is speaking" (prompt scripts): pre-set from the clip's detection, off when unknown; sent as `speaking`. */
    val speaking: Boolean = false,
    /** The user switched "Performer is speaking" for this clip: a late detection no longer moves it. */
    val speakingTouched: Boolean = false,
    /** AI suite: the picked clip's local file (content:// URI), so Recast can read its first frame on the device. */
    val clipUri: String? = null,
) {
    /** A new or changed clip: the speaking switch starts again from that clip's detection. */
    fun withClip(c: Clip?) = copy(clip = c, clipUri = null, speaking = speakingFor(c), speakingTouched = false)

    /** The user flips the switch. */
    fun toggleSpeaking() = copy(speaking = !speaking, speakingTouched = true)

    /**
     * A `clip` event (the detection finished after the upload answered): for the selected clip, store its audio and checks
     * (the local thumb stays) and, unless the user switched it, re-apply the pre-set. Other clips are ignored.
     */
    fun onClipEvent(c: Clip): VideoDraft {
        val cur = clip ?: return this
        if (cur.id != c.id) return this
        val next = cur.copy(audio = c.audio ?: cur.audio, checks = c.checks.ifEmpty { cur.checks })
        return copy(clip = next, speaking = if (speakingTouched) speaking else speakingFor(next))
    }

    /** [pricePerSec]: the server's live price for the quality (features.video), null = the built-in default. */
    fun spec(pricePerSec: Double? = null) = RenderSpec(engine, use, steps, lipSync, takes, clip?.takeIf { it.id != SampleData.SAMPLE_CLIP }?.durationSec, quality,
        pricePerSec.takeIf { engine == Engine.REPLICATE })

    /** The selected option: a Render quality (Draft / Standard / HD) or an add-on (Edit, Fast · beta). */
    val option: VideoOption get() = VideoOption.of(engine, quality)
    val replicate: Boolean get() = engine == Engine.REPLICATE
    /** The Edit add-on (was "Exact edit"). */
    val edit: Boolean get() = engine == Engine.H3

    /**
     * Picks an option. Edit and Fast · beta always use the whole clip and the default steps (plans/api.md "App clean-up" §2):
     * nothing technical is chosen by the member.
     */
    fun pick(o: VideoOption) = copy(engine = o.engine, quality = o.quality ?: quality, use = ClipUse.FULL, steps = Pricing.STEPS_DEFAULT)

    /** What goes to POST /v1/jobs: always the whole clip; Edit sends the default steps; lip sync and a background photo are Edit only. */
    fun request(title: String, modelId: String, outfitId: String, clipId: String, clipSeconds: Double?) = JobRequest(
        title = title, modelId = modelId, outfitId = outfitId, clipId = clipId, engine = engine.id, quality = quality.id.takeIf { replicate },
        steps = Pricing.STEPS_DEFAULT, use = ClipUse.FULL.id, takes = takes, keepAudio = keepAudio, lipSync = lipSync && edit,
        background = if (edit) background else "keep", backgroundMotion = motion, clipSeconds = clipSeconds, speaking = speaking,
    )

    companion object {
        /** The switch's starting position for a clip: its detection, off when unknown (no clip, still running, failed). */
        fun speakingFor(c: Clip?): Boolean = c?.audio?.speaking ?: false
        /** The hint under the switch. */
        fun speakingHint(on: Boolean) = if (on) "She talks or sings: her lips follow the clip's sound" else "Her mouth follows the clip; she won't lip-sync to the music"
    }
}

/** Using a template: the user's own choices (the template's layers stay on the server). Lock look is off by default. */
data class TemplateUseDraft(
    val templateId: String? = null,
    val direction: String = "",
    val shuffleSeed: Long = kotlin.random.Random.nextLong(1L shl 31),
    val lockSeed: Boolean = false,
    val product: ImageRef? = null,
    val showPrompt: Boolean = false,
    /** Up to 3 reference images (pose, look, scene), as in the Photo tool. */
    val refs: List<ShootRef> = emptyList(),
)

/** Template library filters. tab: all | mine | public | favourites. */
data class TemplateFilter(val tab: String = "all", val query: String = "", val tag: String? = null)

/** New model, step 1. */
data class ModelDraft(val name: String = "", val age: Int = 27, val niche: String = "Beauty")

/** New outfit set. mode: describe | photo | own. */
data class OutfitDraft(
    val mode: String = "describe",
    val description: String = "",
    /** §5: filled with a suggestion when the set is made (what was typed, the photo's file name, else "Outfit · 11 Nov"). */
    val name: String = "",
    val previewId: String? = null,
    val images: List<ImageRef> = emptyList(),
    /** The picked photo's file name (the name suggestion, §5). */
    val photoName: String? = null,
    /** WS7/WS13: the owner's model for the set (null = the studio's default). */
    val imageModel: String? = null,
)

/** Cross-screen selections and drafts (the prototype's global `S`), shared by the screen ViewModels. */
class Drafts {
    val modelId = MutableStateFlow(SampleData.DEMO)
    val outfitId = MutableStateFlow(SampleData.GREEN)
    /** The outfit folders' page (0-based; plans/outfit-head-looks.md §4). */
    val outfitPage = MutableStateFlow(0)
    val video = MutableStateFlow(VideoDraft())
    val templateUse = MutableStateFlow(TemplateUseDraft())
    val templateFilter = MutableStateFlow(TemplateFilter())
    val model = MutableStateFlow(ModelDraft())
    /** Owner screens: the member whose Send/Take back panel is open, and the last invite code made (shown once). */
    val memberOpen = MutableStateFlow<String?>(null)
    val lastInvite = MutableStateFlow<InviteCreated?>(null)
    val outfit = MutableStateFlow(OutfitDraft())
    /** Enhance and Dress up setup, and the run being reviewed (plans/api.md "Model tools"). */
    val enhance = MutableStateFlow(EnhanceDraft())
    val dressUp = MutableStateFlow(DressUpDraft())
    /** Owner Settings → Engines → Image models: the step whose catalog is open; the owner's per-run model choice ("Model" chooser). */
    val catalogStep = MutableStateFlow("shot")
    /** Where the catalog picker returns its choice: "settings" (the studio default) or "run" (this run only). */
    val catalogFor = MutableStateFlow("settings")
    /** Gallery tab: tests | final. Newly shot items are highlighted once. */
    val galleryTab = MutableStateFlow("tests")
    val freshShots = MutableStateFlow(0)
    /** Failed-job cards the user has dealt with (Retry). */
    val dismissedFails = MutableStateFlow(emptySet<String>())
    /** Posts screen tab: scheduled | posted. */
    val postsTab = MutableStateFlow("scheduled")
    /** Starts the Post sheet in Schedule mode once (used by the Posts empty state and screenshot tests). */
    val postStartScheduled = MutableStateFlow(false)
    /** Owner Settings → Prompts: "blocks" or "scripts" (prompt scripts). */
    val promptsTab = MutableStateFlow("blocks")

    /** Loads a past job's settings (Retry / Run again with same settings). */
    fun loadJob(job: Job) {
        val r = job.request
        modelId.value = r.modelId
        outfitId.value = r.outfitId
        video.update {
            it.copy(
                engine = Engine.fromId(r.engine), quality = Quality.fromId(r.quality), steps = Pricing.STEPS_DEFAULT, use = ClipUse.FULL, takes = r.takes, keepAudio = r.keepAudio,
                lipSync = r.lipSync, background = r.background, motion = r.backgroundMotion, tool = "quality",
                clip = it.clip ?: Clip(r.clipId, r.title, r.clipSeconds ?: SampleData.sampleMeta.durationSec, 1080, 1920, 30, ClipRules.checks(SampleData.sampleMeta)),
            ).let { d -> d.copy(speaking = r.speaking ?: VideoDraft.speakingFor(d.clip), speakingTouched = r.speaking != null) }
        }
    }

    fun resetVideo() = video.update { VideoDraft(tool = it.tool).withClip(it.clip) }

    /** Signing out or switching studios: reference images are that account's uploads, and "Edit as text" was written for its prompts. */
    fun forgetAccount() {
        templateUse.update { it.copy(refs = emptyList()) }
    }
}

/** Enhance setup: realism off | subtle | balanced | strong, upscale off | 2x | 4x; [runId] once started. models: the owner's per-run choice. */
data class EnhanceDraft(val realism: String = "balanced", val upscale: String = "2x", val runId: String? = null, val models: Map<String, String> = emptyMap())

/** Dress up setup: one outfit-sheet photo, a name, Option A / B / Both; [runId] once started. */
data class DressUpDraft(val outfitImage: ImageRef? = null, val name: String = "", val engine: String = "a", val runId: String? = null, val models: Map<String, String> = emptyMap())

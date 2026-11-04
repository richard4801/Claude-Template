package studio.muse.app.data

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import studio.muse.core.ClipUse
import studio.muse.core.Engine
import studio.muse.core.Pricing
import studio.muse.core.RenderSpec

/** The video being set up across New video → Direct. Retry and "Run again" load a past job into it. */
data class VideoDraft(
    val clip: Clip? = null,
    val showBadExample: Boolean = false,
    val engine: Engine = Engine.H3,
    val steps: Int = Pricing.STEPS_DEFAULT,
    val use: ClipUse = ClipUse.FIRST,
    val takes: Int = 1,
    val keepAudio: Boolean = true,
    val lipSync: Boolean = false,
    val background: String = "keep",
    val motion: String = "subtle",
    val tool: String = "quality",
) {
    fun spec() = RenderSpec(engine, use, steps, lipSync, takes, clip?.takeIf { it.id != SampleData.SAMPLE_CLIP }?.durationSec)
}

/** Photoshoot tool state. */
data class ShootDraft(
    val scene: String? = null,
    val sceneCustom: String = "",
    val shot: String = "Medium",
    val lens: Int = 35,
    val aperture: String = "f/2.8",
    val light: String = "Golden hour",
    val grade: String? = null,
    val direction: String = "",
    val lockSeed: Boolean = false,
    val tool: String = "camera",
    val lastShots: Int = 0,
)

/** New model, step 1. */
data class ModelDraft(val name: String = "", val age: Int = 27, val niche: String = "Beauty")

/** New outfit set. mode: describe | photo | own. */
data class OutfitDraft(
    val mode: String = "describe",
    val description: String = "Cream cable-knit sweater, light-wash straight jeans, white sneakers",
    val name: String = "Cream knit + jeans",
    val previewId: String? = null,
    val images: List<ImageRef> = emptyList(),
)

/** Cross-screen selections and drafts (the prototype's global `S`), shared by the screen ViewModels. */
class Drafts {
    val modelId = MutableStateFlow(SampleData.SIENNA)
    val outfitId = MutableStateFlow(SampleData.GREEN)
    val video = MutableStateFlow(VideoDraft())
    val shoot = MutableStateFlow(ShootDraft())
    val model = MutableStateFlow(ModelDraft())
    val outfit = MutableStateFlow(OutfitDraft())
    /** Gallery tab: tests | final. Newly shot items are highlighted once. */
    val galleryTab = MutableStateFlow("tests")
    val freshShots = MutableStateFlow(0)
    /** Failed-job cards the user has dealt with (Retry). */
    val dismissedFails = MutableStateFlow(emptySet<String>())
    /** Posts screen tab: scheduled | posted. */
    val postsTab = MutableStateFlow("scheduled")
    /** Starts the Post sheet in Schedule mode once (used by the Posts empty state and screenshot tests). */
    val postStartScheduled = MutableStateFlow(false)

    /** Loads a past job's settings (Retry / Run again with same settings). */
    fun loadJob(job: Job) {
        val r = job.request
        modelId.value = r.modelId
        outfitId.value = r.outfitId
        video.update {
            it.copy(
                engine = Engine.fromId(r.engine), steps = r.steps, use = ClipUse.fromId(r.use), takes = r.takes, keepAudio = r.keepAudio,
                lipSync = r.lipSync, background = r.background, motion = r.backgroundMotion, tool = "quality",
                clip = it.clip ?: Clip(r.clipId, r.title, r.clipSeconds ?: SampleData.sampleMeta.durationSec, 1080, 1920, 30, ClipRules.checks(SampleData.sampleMeta)),
            )
        }
    }

    fun resetVideo() = video.update { VideoDraft(clip = it.clip, tool = it.tool) }
}

package studio.muse.app.ui.screens.suite

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import studio.muse.app.AppContainer
import studio.muse.app.data.Clip
import studio.muse.app.data.ImageRef
import studio.muse.app.data.Job
import studio.muse.app.data.RemixDraft
import studio.muse.app.data.RemixModels
import studio.muse.app.data.RemixModelsRequest
import studio.muse.app.data.SampleData
import studio.muse.app.data.SuiteEstimate
import studio.muse.app.data.SuiteShotRequest
import studio.muse.app.data.Take

/**
 * New Swap on Android (owner-approved 2026-11-14; the Mac's AppStore+NewSwap.swift): the Swap tab's second variant. The
 * clip, the toggles' draft, the server's estimate (the only source of the price on Generate) and the model list. Nothing
 * here spends: [generate] runs only from the Generate button, which shows the estimate's price.
 */
class NewSwapState(private val c: AppContainer, private val store: SuiteStore) {
    /** The Swap tab shows New Swap (true) or the classic Swap. The Mac's default: classic. */
    val on = MutableStateFlow(false)
    val draft = MutableStateFlow(RemixDraft())
    val clip = MutableStateFlow<Clip?>(null)
    val estimate = MutableStateFlow<SuiteEstimate?>(null)
    val error = MutableStateFlow<String?>(null)
    val models = MutableStateFlow<RemixModels?>(null)
    val generating = MutableStateFlow(false)
    /** Jobs started here (newest last): the stage follows them. */
    val jobs = MutableStateFlow<List<String>>(emptyList())
    /** Demo mode starts with the sample clip (off for the empty screen's screenshots). */
    var demoSample = true

    /** What Generate sends (null until a clip is in and every turned-on toggle is complete). */
    val request: SuiteShotRequest? get() = draft.value.request(clip.value?.id, clip.value?.name)

    /** No price yet and no reason why: the estimate is on its way. */
    val pricing: Boolean get() = estimate.value == null && error.value == null && request != null

    /** Re-prices: the estimate for the request, then the model list for these toggles (both from the server). */
    suspend fun refresh() {
        val req = request
        if (req == null) { estimate.value = null; error.value = null } else {
            val (e, err) = c.repo.attemptInline { suiteEstimate(req) }
            estimate.value = e; error.value = err
        }
        val d = draft.value
        models.value = if (!d.anyOn) null else c.repo.attemptInline {
            suiteRemixModels(RemixModelsRequest(d.toggles, clip.value?.id, d.range?.let { listOf(it.from, it.to) }))
        }.first
    }

    /** Why Generate can't go now (null = it can, at the estimate's price). */
    val blocker: String? get() {
        if (clip.value == null) return "Add a clip first"
        draft.value.missing?.let { return it }
        error.value?.let { return it }
        val e = estimate.value ?: return null
        e.remix?.trim?.takeIf { it.needed }?.let { return "Trim the clip first: this model takes up to ${studio.muse.app.data.trimNum(it.maxSeconds)} s" }
        if (!e.ok) return e.message ?: "Over the studio's limit"
        return null
    }

    /** Generate: only with a price from the server on the button (never without an estimate). */
    suspend fun generate(): Job? {
        val req = request ?: return null
        if (estimate.value == null || blocker != null || generating.value) return null
        generating.value = true
        return try { store.generate(req, jobs) } finally { generating.value = false }
    }

    /** A clip picked elsewhere (Source, a share) becomes the clip; the trimmer starts over. */
    fun useClip(c: Clip?) {
        if (c?.id == clip.value?.id) return
        clip.value = c
        draft.update { it.copy(range = null) }
    }

    /** Demo mode's sample clip ("Living-room dance", 9.4 s). */
    fun useSample() {
        val m = SampleData.sampleMeta
        useClip(Clip(SampleData.SAMPLE_CLIP, m.name, m.durationSec, m.width, m.height, m.fps, emptyList(), ImageRef.asset("g_tq")))
    }

    /** A Library take as the clip (copied on the server; the take stays as it is). */
    suspend fun useTake(t: Take) {
        val (clipFrom, err) = c.repo.attemptInline { clipFromTake(t.id) }
        if (clipFrom != null) { useClip(clipFrom); c.repo.toast("Added ${t.title} · ${studio.muse.app.data.trimNum(clipFrom.durationSec)} s") }
        if (err != null) c.repo.toast(err)
    }

    /** The trimmer's part, inside the clip ("the whole clip" is null). */
    fun setRange(from: Double, to: Double) {
        val s = clip.value?.durationSec ?: return
        draft.update { it.copy(range = RemixDraft.clampRange(from, to, s)) }
    }

    /** The default Character: her, the composer's character or the studio's first (owner's rule: the strict figure lock). */
    fun preselectHer() {
        val d = draft.value
        if (d.characterOn || d.modelId != null) return
        val her = store.composer.value.characterId ?: c.repo.state.value.models.firstOrNull()?.id ?: return
        draft.update { it.copy(characterOn = true, modelId = her) }
    }
}

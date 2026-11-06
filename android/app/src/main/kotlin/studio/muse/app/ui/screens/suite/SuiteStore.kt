package studio.muse.app.ui.screens.suite

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import studio.muse.app.AppContainer
import studio.muse.app.data.ApiException
import studio.muse.app.data.ErrorText
import studio.muse.app.data.Job
import studio.muse.app.data.SuiteCatalog
import studio.muse.app.data.SuiteEstimate
import studio.muse.app.data.SuiteModelPatch
import studio.muse.app.data.SuiteRules
import studio.muse.app.data.SuiteSettings
import studio.muse.app.data.SuiteSettingsPatch
import studio.muse.app.data.SuiteShotRequest
import studio.muse.app.ui.screens.suite.composer.ComposerDraft
import studio.muse.app.ui.screens.suite.composer.ComposerSheet

/**
 * The AI suite's session state (one per app): the catalog (null until loaded), the composer, Recast and Storyboard drafts
 * and the renders started from each screen. Members only ever hold member-safe copies: the
 * catalog and estimates go through [SuiteRules.memberSafe] whatever the server sent.
 */
class SuiteStore(private val c: AppContainer) {
    val catalog = MutableStateFlow<SuiteCatalog?>(null)
    /** Why the catalog couldn't load (offline, an older server), shown on the hub. */
    val catalogError = MutableStateFlow<String?>(null)
    /** The video composer (every tool is a preset of it), its filled input slots and the open picker sheet. */
    val composer = MutableStateFlow(ComposerDraft())
    val composerSlots = MutableStateFlow(InputSlots())
    /** Talking's own slots (audio, location photo) and UGC ad's (product photo, reference ad): ToolSlots.TALK_* / UGC_*. */
    val talkingSlots = MutableStateFlow(InputSlots())
    val ugcSlots = MutableStateFlow(InputSlots())
    val sheet = MutableStateFlow<ComposerSheet?>(null)
    /** The clip and people of Character swap and Recast (the composer's quality and takes are used). */
    val recast = MutableStateFlow(RecastDraft())
    val board = MutableStateFlow<Storyboard?>(null)
    /** The request of each composer render (by job id), for Retake on the result. */
    val requests = MutableStateFlow<Map<String, SuiteShotRequest>>(emptyMap())
    /** Renders started from the composer this session (newest last): its pane follows them. */
    val shotJobs = MutableStateFlow<List<String>>(emptyList())
    val settings = MutableStateFlow<SuiteSettings?>(null)
    /** The studio's locations library (`@location`); empty on a server without it. */
    val locations = MutableStateFlow<List<studio.muse.app.data.SuiteLocation>>(emptyList())

    /** Loads the locations quietly: an older server simply has none. */
    suspend fun loadLocations() {
        runCatching { c.repo.api.suiteLocations() }.onSuccess { locations.value = it }
    }

    /** "+ New location": uploads the photo, then adds it to the library. The new location, or null (with a toast). */
    suspend fun createLocation(name: String, bytes: ByteArray, mime: String): studio.muse.app.data.SuiteLocation? {
        val (img, err) = c.repo.attemptInline { uploadImage("${name.take(40)}.jpg", bytes, mime) }
        if (img == null) { c.repo.toast(err ?: ErrorText.WENT_WRONG); return null }
        val (loc, err2) = c.repo.attemptInline { createSuiteLocation(studio.muse.app.data.SuiteLocationCreate(name.trim().take(60), img)) }
        if (loc == null) { c.repo.toast(err2 ?: ErrorText.WENT_WRONG); return null }
        locations.update { listOf(loc) + it.filter { l -> l.id != loc.id } }
        return loc
    }

    val owner: Boolean get() = c.repo.state.value.wallet?.owner ?: c.prefs.value.owner

    /** Extend's VIDEO slot (ToolSlots.EXTEND_VIDEO): one of the studio's takes, or an uploaded video with its length. */
    val extendSlots = MutableStateFlow(InputSlots())
    /** The take the Upscale sheet is open for (null = closed); [upscaleSoon]: the server just said Upscale is coming soon. */
    val upscaleFor = MutableStateFlow<String?>(null)
    val upscaleSoon = MutableStateFlow(false)

    /** Puts [t] in Extend's VIDEO slot. False when the take has no stored video to continue from. */
    fun pickExtendTake(t: studio.muse.app.data.Take): Boolean {
        val key = studio.muse.app.data.ExtendRules.keyOf(t, c.repo.demo) ?: return false
        extendSlots.value = InputSlots().put(studio.muse.app.ui.screens.suite.composer.ToolSlots.EXTEND_VIDEO, studio.muse.app.ui.screens.suite.composer.ExtendSlot.fromTake(t, key))
        return true
    }

    /** "Extend" on a finished take: the composer on Extend with that take in the VIDEO slot. */
    fun startExtend(t: studio.muse.app.data.Take): Boolean {
        if (!pickExtendTake(t)) { c.repo.toast("This take has no video to extend yet"); return false }
        composer.update { it.withTool(studio.muse.app.ui.screens.suite.composer.ComposerTool.EXTEND).fit(catalog.value) }
        sheet.value = null
        return true
    }

    /** Opens the Upscale sheet on [takeId] (the sizes start pickable again). */
    fun openUpscale(takeId: String) { upscaleSoon.value = false; upscaleFor.value = takeId }

    /**
     * Upscale [takeId] to [size]: the job (followed like any render), or null. `upscale_unavailable` (409) greys every size
     * with "Upscale is coming soon" and keeps the sheet open; other errors are a toast.
     */
    suspend fun upscale(takeId: String, size: String): Job? {
        val (j, code, msg) = c.repo.upscaleInline(takeId, size)
        if (j != null) {
            shotJobs.update { (it - j.id) + j.id }
            upscaleFor.value = null
            return j
        }
        if (code == studio.muse.app.data.UpscaleOffer.UNAVAILABLE) upscaleSoon.value = true
        else c.repo.toast(memberSafeText(msg ?: ErrorText.WENT_WRONG))
        return null
    }

    suspend fun load() {
        try {
            val cat = c.repo.api.suiteCatalog()
            catalog.value = if (owner) cat else SuiteRules.memberSafe(cat)
            catalogError.value = null
            composer.update { d -> d.copy(quality = if (d.quality in cat.tiers.map { t -> t.id } || cat.tiers.isEmpty()) d.quality else cat.defaultQuality).fit(cat) }
            if (board.value == null && c.repo.demo) board.value = demoBoard()
        } catch (e: ApiException) {
            catalogError.value = ErrorText.of(e)
        }
    }

    /** The price and any cap message; a member never gets engine words, whatever the server sends. */
    suspend fun estimate(req: SuiteShotRequest): Pair<SuiteEstimate?, String?> {
        val (e, err) = c.repo.attemptInline { suiteEstimate(req) }
        return (e?.let { if (owner) it else SuiteRules.memberSafe(it) }) to err?.let { memberSafeText(it) }
    }

    /** Generate: the job, or the plain reason it couldn't start (as a toast too). Claude never calls this: only a tap does. */
    suspend fun generate(req: SuiteShotRequest, into: MutableStateFlow<List<String>>? = null): Job? {
        val (j, err) = c.repo.createSuiteShot(req)
        if (err != null) c.repo.toast(memberSafeText(err))
        if (j != null) { into?.update { (it - j.id) + j.id }; requests.update { it + (j.id to req) } }
        return j
    }

    suspend fun loadSettings(): String? {
        if (!owner) return null
        val (s, err) = c.repo.attemptInline { suiteSettings() }
        if (s != null) settings.value = s
        return err
    }

    suspend fun setModel(id: String, enabled: Boolean) {
        val (s, err) = c.repo.attemptInline { patchSuiteSettings(SuiteSettingsPatch(mapOf(id to SuiteModelPatch(enabled)))) }
        if (s != null) { settings.value = s; load() } else if (err != null) c.repo.toast(err)
    }

    private fun memberSafeText(s: String) = if (!owner && SuiteRules.PROVIDER_WORDS.containsMatchIn(s)) ErrorText.WENT_WRONG else s

    /** Demo mode's sample storyboard, cast from the demo studio's own models. */
    private fun demoBoard(): Storyboard {
        val models = c.repo.state.value.models
        val lead = models.firstOrNull()
        val second = models.getOrNull(1)
        val name = lead?.name?.substringBefore(' ') ?: "She"
        return Storyboard("Café GRWM", listOfNotNull(lead?.id, second?.id), "cinematic", "hd", listOf(
            StoryShot("s1", "Street → café door", "$name walks in from the rain and pushes the café door open.", "handheld", 3),
            StoryShot("s2", "Order at the counter", "$name orders a flat white at the counter.", "dolly_in", 4),
            StoryShot("s3", "Turn to camera, smile", "$name turns from the counter to camera and smiles; steam rises.", "orbit_left", 5),
            StoryShot("s4", "${second?.name?.substringBefore(' ') ?: "A friend"} joins at the window", "A friend joins $name at the window seat.", "track_side", 4),
            StoryShot("s5", "Selfie review, close", "$name gives the café a 10/10 to her phone camera.", "selfie", 5),
        ))
    }
}

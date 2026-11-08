package studio.muse.app.ui.screens.edit

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import studio.muse.app.data.ApiException
import studio.muse.app.data.MuseApi
import studio.muse.app.data.OpenEditSessionRequest
import studio.muse.core.edit.Recipe
import studio.muse.core.edit.RecreateFill
import studio.muse.core.edit.RecreateMatch
import studio.muse.core.edit.RecreateSlotEstimate
import studio.muse.core.edit.RecreateSlotFill
import studio.muse.core.edit.RecreateText

/*
 * "Recreate this edit", phases 2–3 on Android (the Mac's AppStore+Recreate.swift; WS1's flow in
 * server/api/test/recreate-e2e.test.ts): match the studio's takes to the reference's shots (free) → price each shot to
 * generate (nothing held) → one confirmation listing each shot with the real total → fill each confirmed shot (a paid
 * Suite job) → watch the fill until they're ready → apply into an edit session → Compare. Nothing is spent before the
 * person's yes, and demo mode (FakeMuseApi) never spends.
 */

enum class RecreateMode { Recipe, Compare }

/** [guide]: the reference's sound as the guide track (else silent, timed for the sound). [progress]: 0–1 while exporting. */
/**
 * The export sheet. [progress]: the device's export (0..1), or null; [rendering]: the studio server is making it (no
 * fraction). After saving, [saved] says where, and [useThisSound] is the server's reminder to post with the original
 * sound (null: the general reminder).
 */
data class RecreateExportUi(
    val guide: Boolean = true, val progress: Float? = null, val error: String? = null, val rendering: Boolean = false,
    val saved: String? = null, val useThisSound: studio.muse.core.edit.RecreateUseSound? = null,
) {
    val busy: Boolean get() = progress != null || rendering
}

/** A take that can fill a shot ("Use one of my takes"). */
/** [label]: what tells takes with the same title apart ("Take 2 of 3"). */
/** A character who can play the lead. */
data class RecreateCastChoice(val id: String, val name: String)

data class RecreateTakeChoice(val id: String, val caption: String, val durationSec: Double?, val thumb: studio.muse.app.data.ImageRef? = null, val label: String? = null)

/** A build the server refused (a validator's text, any 4xx): what the owner sees; the detail goes to the log. */
const val BUILD_FAILED = "Couldn't build this edit. Try again, or change a shot."

data class RecreateBuildUi(
    val referenceId: String,
    val recipe: Recipe,
    val referenceName: String? = null,
    /** "kept 12 days" / "kept" (the reference is deleted after 30 days unless kept); null when unknown. */
    val kept: String? = null,
    val fill: RecreateFill? = null,
    val loadingFill: Boolean = false,
    val mode: RecreateMode = RecreateMode.Recipe,
    val selected: Int = 0,
    /** slotId → the shot's price (nothing held). */
    val estimates: Map<String, RecreateSlotEstimate> = emptyMap(),
    /** Shots that can't be priced or made, in plain words: never offered to spend on. */
    val estimateErrors: Map<String, String> = emptyMap(),
    /** Shots whose new version didn't generate (the server refunds them). */
    val fillErrors: Map<String, String> = emptyMap(),
    /** Takes picked here, kept over each fill refresh. */
    val picks: Map<String, RecreateSlotFill> = emptyMap(),
    /** Fills confirmed and still being started (never started twice). */
    val starting: Set<String> = emptySet(),
    val estimating: Boolean = false,
    val building: Boolean = false,
    /** The edit is built as soon as the new shots are ready (Build asked for it). */
    val buildWhenReady: Boolean = false,
    /** The confirmation is open, covering these shots (priced, to generate), frozen when it opened. */
    val confirmSlots: List<String>? = null,
    /** "Pick which shots to make": shots unticked in the confirmation (they stay to generate). */
    val confirmSkip: Set<String> = emptySet(),
    val match: RecreateMatch? = null,
    /** The take the built edit lives on (Open in the editor). */
    val builtTakeId: String? = null,
    /** The edit session the recipe was built into (Compare previews it on the device), and its revision. */
    val builtSessionId: String? = null,
    val builtRevision: Int? = null,
    /** Shots to make again ("Make a new one"): filled before, generated anew on the next Build. */
    val remake: Set<String> = emptySet(),
    /** Shots made anew after the edit was built: swapped into it in place (Fix shot) instead of rebuilding it. */
    val fixing: Set<String> = emptySet(),
    /** G2, per shot: "swap" (your model into the reference's own shot) or "generate"; absent = the server's default (swap). */
    val methods: Map<String, String> = emptyMap(),
    /** G2, swap only: keep the reference's setting (true, the default) or use your own (the shot's brief). */
    val keepBackground: Map<String, Boolean> = emptyMap(),
    /** "Use your own setting": the studio location picked per shot (absent: the brief's place, or a background made from it). */
    val locations: Map<String, String> = emptyMap(),
    /** WS7/WS13 (owner): the model picked per shot (purpose fill) and for its background plate (purpose plate); absent = the defaults. */
    val shotModels: Map<String, String> = emptyMap(),
    val plateModels: Map<String, String> = emptyMap(),
    /** The studio's locations, loaded the first time a shot uses its own setting. */
    val places: List<RecreateCastChoice> = emptyList(),
    /** G8: "Write the shot briefs · about $0.02" while shots have no brief; its confirmation, and while it runs. */
    val briefs: studio.muse.core.edit.RecreateBriefsEstimate? = null,
    val askBriefs: Boolean = false,
    val writingBriefs: Boolean = false,
    val takes: List<RecreateTakeChoice> = emptyList(),
    /** One line to show once (a toast), then [RecreateBuildModel.consumeMessage]. */
    val message: String? = null,
    /** The shared playhead (seconds in the reference): the reference and your edit both follow it. */
    val time: Double = 0.0,
    val playing: Boolean = false,
    /** jobId → 0–100, from the studio's live jobs, for shots being made; a job not listed shows a calm indeterminate state. */
    val jobProgress: Map<String, Int> = emptyMap(),
    /** The export sheet (Compare): open, with the sound as a guide or silent, its progress while it runs. */
    val export: RecreateExportUi? = null,
    /** Cast (plan step 3): the studio's characters, and who plays the lead (new shots are made with them, takes matched to them). */
    val cast: List<RecreateCastChoice> = emptyList(),
    val castId: String? = null,
) {
    val duration: Double get() = recipe.durationSec.coerceAtLeast(0.1)
    /** The shot under the playhead. */
    val slotAtTime: Int get() = slots.indexOfLast { it.startSec <= time + 1e-6 }.coerceAtLeast(0)
    /** A shot's job progress (0–100) while it is being made, when known. */
    fun progress(slotId: String): Int? = slotFill(slotId)?.jobId?.let { jobProgress[it] }?.takeIf { it > 0 }
    val slots get() = recipe.slots
    fun slotFill(id: String): RecreateSlotFill? = fill?.slot(id)
    fun score(id: String): Double? = match?.perSlot?.get(id)
    val generating: Set<String> get() = slots.map { it.id }.filter { slotFill(it)?.state == "generating" || it in starting }.toSet()
    val isGenerating: Boolean get() = generating.isNotEmpty()
    /** The shots to generate, not yet started. */
    val toGenerate: List<String> get() = fill?.slots.orEmpty().filter { it.state == "to_generate" && it.slotId !in starting }.map { it.slotId }
    val prices: Map<String, Double> get() = estimates.filterValues { it.ok }.mapValues { it.value.amount }
    /** The shots ticked in the Build confirmation (all by default; at least one stays ticked). */
    val confirmChosen: List<String> get() = confirmSlots.orEmpty().filter { it !in confirmSkip }
    val confirmTotal: Double get() = confirmChosen.mapNotNull { estimates[it]?.amount }.sum()
    /** "1 from your takes, 2 to generate · $1.28 in all", beside Build. */
    val summary: String? get() = fill?.let { RecreateText.makingSummary(it, prices, estimateErrors.keys, starting, estimates.mapValues { e -> e.value.method } + methods) }
    /** Under the total: the approval promise, or what happens while new shots generate. */
    val note: String get() = when {
        !isGenerating -> RecreateText.APPROVE_NOTE
        buildWhenReady -> "The edit is built when they’re ready."
        else -> "Build the edit once they’re ready."
    }
    /** Build is busy (pricing, generating, building): it steps back from the accent. */
    val buildBusy: Boolean get() = fill == null || building || estimating || isGenerating
    fun shotName(id: String): String = slots.indexOfFirst { it.id == id }.takeIf { it >= 0 }?.let { "Shot ${it + 1}" } ?: "A shot"
    /** The shot with the lowest match after Build ("Fix shot 2"). */
    val weakest: Int? get() = match?.perSlot?.takeIf { it.isNotEmpty() }?.minByOrNull { it.value }?.key?.let { k -> slots.indexOfFirst { it.id == k }.takeIf { it >= 0 } }
    /** "Yours", "To generate", a score after Build… */
    fun tag(id: String, scores: Boolean): String {
        if (scores) score(id)?.let { return RecreateText.percent(it) }
        if (id in starting) return "Generating"
        return RecreateText.tag(slotFill(id)?.state, failed = fillErrors[id] != null, cant = estimateErrors[id] != null)
    }
}

/**
 * The build's state and steps. [modelId] is the character new shots are made with (the studio's current model).
 * [pollMs] is how often the fill is watched while shots generate.
 */
class RecreateBuildModel(
    private val api: MuseApi,
    private val scope: CoroutineScope,
    start: RecreateBuildUi,
    /** The default lead when none is picked (the studio's current character). */
    private val defaultModelId: () -> String?,
    private val pollMs: Long = 3_000,
) {
    private val _ui = MutableStateFlow(start)
    val ui: StateFlow<RecreateBuildUi> = _ui
    private var watch: Job? = null
    private val id get() = _ui.value.referenceId
    private fun modelId(): String? = _ui.value.castId ?: defaultModelId()

    /**
     * Cast: a new lead. The takes are matched again for them (free) and every shot to generate is priced again; takes
     * picked here stay.
     */
    suspend fun setCast(modelId: String) {
        if (modelId == _ui.value.castId || _ui.value.building || _ui.value.isGenerating) return
        _ui.update { it.copy(castId = modelId, estimates = emptyMap(), estimateErrors = emptyMap(), loadingFill = true) }
        try {
            api.matchReference(id, modelId)
            take(api.referenceFill(id))
        } catch (e: CancellationException) { throw e } catch (e: Exception) {
            _ui.update { it.copy(message = studio.muse.app.data.ErrorText.plain(e, "Couldn’t match your takes for the new lead")) }
        } finally { _ui.update { it.copy(loadingFill = false) } }
        price()
    }

    fun consumeMessage() = _ui.update { it.copy(message = null) }
    fun setMode(m: RecreateMode) {
        if (m == RecreateMode.Compare && _ui.value.match == null) _ui.update { it.copy(message = "Compare opens once the edit is built") }
        else _ui.update { it.copy(mode = m) }
    }
    /** Selects a shot and moves the playhead to its middle. */
    fun select(i: Int) {
        val s = _ui.value.slots.getOrNull(i) ?: return
        _ui.update { it.copy(selected = i, time = (s.startSec + s.endSec) / 2) }
    }

    fun togglePlay() = _ui.update { it.copy(playing = !it.playing) }

    /** One frame back or forward (the reference's frame rate is taken as 30). */
    fun step(frames: Int) = seek(_ui.value.time + frames / 30.0, stop = true)

    fun seek(sec: Double, stop: Boolean = false) = _ui.update { u ->
        val t = sec.coerceIn(0.0, u.duration)
        u.copy(time = t, playing = if (stop) false else u.playing).let { v -> v.copy(selected = v.slotAtTime) }
    }

    /** While playing: the playhead moves on (looping at the end) and the selected shot follows it. */
    fun advance(dtSec: Double) = _ui.update { u ->
        if (!u.playing) return@update u
        var t = u.time + dtSec
        if (t >= u.duration) t = 0.0
        u.copy(time = t).let { v -> v.copy(selected = v.slotAtTime) }
    }

    fun openExport() = _ui.update { it.copy(export = RecreateExportUi(), playing = false) }
    fun closeExport() = _ui.update { if (it.export?.busy == true) it else it.copy(export = null) }
    fun setExportGuide(on: Boolean) = _ui.update { u -> u.copy(export = u.export?.copy(guide = on, error = null)) }
    fun setExportProgress(p: Float?, error: String? = null) = _ui.update { u -> u.copy(export = u.export?.copy(progress = p, error = error, rendering = false)) }
    /** The studio server is rendering the export. */
    fun setExportRendering() = _ui.update { u -> u.copy(export = u.export?.copy(rendering = true, progress = null, error = null)) }
    /** The original's sound isn't kept any more (409 no_reference_sound): switch to silent and say so. */
    fun exportNeedsSilent() = _ui.update { u -> u.copy(export = u.export?.copy(guide = false, rendering = false, progress = null,
        error = "The original's sound isn't kept any more. Export it silent.")) }
    /** Saved: the sheet stays open with where it went and how to post it with the original sound. */
    fun exportSaved(message: String, use: studio.muse.core.edit.RecreateUseSound?) = _ui.update { u ->
        u.copy(export = u.export?.copy(progress = null, rendering = false, error = null, saved = message, useThisSound = use)) }
    fun exportDone(message: String) = _ui.update { it.copy(export = null, message = message) }

    fun setJobProgress(p: Map<String, Int>) { if (p != _ui.value.jobProgress) _ui.update { it.copy(jobProgress = p) } }

    /** The fill; when nothing is scored yet, the takes are matched once (free) first. Then every shot to generate is priced. */
    suspend fun load() {
        _ui.update { it.copy(loadingFill = true) }
        try {
            var f = api.referenceFill(id)
            if (f.slots.isNotEmpty() && f.slots.all { it.state == "empty" }) {
                runCatching { api.matchReference(id, modelId()) }.onFailure { if (it is CancellationException) throw it }
                f = api.referenceFill(id)
            }
            take(f)
            f.match?.let { m -> _ui.update { it.copy(match = m) } }
        } catch (e: CancellationException) { throw e } catch (e: Exception) {
            _ui.update { it.copy(loadingFill = false, message = studio.muse.app.data.ErrorText.plain(e, "Couldn’t load how the shots are made")) }
            return
        }
        _ui.update { it.copy(loadingFill = false) }
        if (_ui.value.isGenerating) startWatch()
        price()
        loadBriefs()
    }

    /** G8: offered while any shot has no brief (a closer match when shots are generated). */
    private suspend fun loadBriefs() {
        if (_ui.value.recipe.slots.none { it.brief == null }) { _ui.update { it.copy(briefs = null) }; return }
        runCatching { api.estimateReferenceBriefs(id) }.onFailure { if (it is CancellationException) throw it }.getOrNull()?.let { b -> _ui.update { it.copy(briefs = b) } }
    }

    fun askBriefs() = _ui.update { if (it.briefs?.available == true) it.copy(askBriefs = true) else it.copy(message = it.briefs?.reason) }
    fun cancelBriefs() = _ui.update { it.copy(askBriefs = false) }

    /** The confirmed price: Claude writes every shot's brief, the summary and tags; the recipe on screen updates. */
    suspend fun writeBriefs() {
        _ui.update { it.copy(askBriefs = false, writingBriefs = true) }
        try {
            val ref = api.writeReferenceBriefs(id)
            val n = _ui.value.recipe.slots.count { it.brief == null }
            _ui.update { u -> u.copy(recipe = ref.recipe ?: u.recipe, writingBriefs = false, briefs = null, message = if (n == 1) "The brief is written" else "Briefs written for $n shots") }
            price()
        } catch (e: CancellationException) { throw e } catch (e: Exception) {
            _ui.update { it.copy(writingBriefs = false, message = e.message ?: "The briefs weren't written · you weren't charged") }
        }
    }

    /** A fetched fill: takes picked here stay, and a shot that was generating and came back without its version is marked. */
    private fun take(new: RecreateFill) = _ui.update { u ->
        val was = u.generating
        val fillErrors = u.fillErrors.toMutableMap(); val picks = u.picks.toMutableMap(); val methods = u.methods.toMutableMap()
        val slots = new.slots.map { s ->
            if (s.state == "generating" || s.state == "ready") { fillErrors -= s.slotId; picks -= s.slotId; return@map s }
            // G2: a swap that didn't work (refunded) comes back to generate, which is then offered and priced on its own.
            if (s.fallback == "generate") methods[s.slotId] = "generate"
            if (s.slotId in was && s.slotId !in u.starting) fillErrors[s.slotId] =
                if (s.fallback == "generate") s.reason ?: "The swap didn’t work and you weren’t charged · generate this shot instead"
                else "This shot didn’t generate. You weren’t charged for it."
            picks[s.slotId] ?: s
        }
        u.copy(fill = new.copy(slots = slots), fillErrors = fillErrors, picks = picks, methods = methods)
    }

    /** Prices every shot still to generate (free; nothing is held). */
    suspend fun price() {
        val todo = _ui.value.toGenerate
        if (todo.isEmpty()) return
        val model = modelId()
        if (model == null) {
            _ui.update { u -> u.copy(estimateErrors = u.estimateErrors + todo.associateWith { "Add a model first: new shots are made with her." }) }
            return
        }
        val got = kotlinx.coroutines.coroutineScope {
            val u = _ui.value
            todo.map { s -> async { s to runCatching { api.estimateReferenceSlot(id, s, model, method = u.methods[s], keepBackground = u.keepBackground[s], locationId = u.locations[s]?.takeIf { u.keepBackground[s] == false },
                engineModel = u.shotModels[s], imageModel = u.plateModels[s]) }.onFailure { if (it is CancellationException) throw it } } }.awaitAll()
        }
        _ui.update { u ->
            val est = u.estimates.toMutableMap(); val errs = u.estimateErrors.toMutableMap()
            got.forEach { (s, r) ->
                r.onSuccess { e ->
                    est[s] = e
                    val p = e.problem
                    if (p != null) errs[s] = (if (p.endsWith(".")) p else "$p.") + " Use one of your takes for this shot." else errs -= s
                }.onFailure { err ->
                    est -= s
                    errs[s] = RecreateText.priceProblem((err as? ApiException)?.code, err.message)
                }
            }
            u.copy(estimates = est, estimateErrors = errs)
        }
    }

    /** G2: how this shot is made, swap into the reference's own shot or generate a new one; it is priced again. */
    suspend fun setMethod(slotId: String, method: String) {
        _ui.update { it.copy(methods = it.methods + (slotId to method), estimates = it.estimates - slotId, estimateErrors = it.estimateErrors - slotId) }
        price()
    }

    /** G2, swap: keep the reference's setting, or use your own (the shot's brief names the place); priced again. */
    suspend fun setKeepBackground(slotId: String, keep: Boolean) {
        _ui.update { it.copy(keepBackground = it.keepBackground + (slotId to keep), estimates = it.estimates - slotId) }
        if (!keep && _ui.value.places.isEmpty()) runCatching { api.suiteLocations() }.onFailure { if (it is CancellationException) throw it }
            .getOrNull()?.let { l -> _ui.update { u -> u.copy(places = l.map { RecreateCastChoice(it.id, it.name) }) } }
        price()
    }

    /** WS7/WS13 (owner): the model that makes this shot (null = the default); priced again, so the price follows the model. */
    suspend fun setShotModel(slotId: String, model: String?) {
        _ui.update { u -> u.copy(shotModels = if (model == null) u.shotModels - slotId else u.shotModels + (slotId to model), estimates = u.estimates - slotId) }
        price()
    }

    /** WS7/WS13 (owner): the image model for the shot's made background (null = the default); priced again. */
    suspend fun setPlateModel(slotId: String, model: String?) {
        _ui.update { u -> u.copy(plateModels = if (model == null) u.plateModels - slotId else u.plateModels + (slotId to model), estimates = u.estimates - slotId) }
        price()
    }

    /** "Use your own setting": one of the studio's locations (free), or null for the brief's place; priced again. */
    suspend fun setLocation(slotId: String, locationId: String?) {
        _ui.update { u -> u.copy(locations = if (locationId == null) u.locations - slotId else u.locations + (slotId to locationId), estimates = u.estimates - slotId) }
        price()
    }

    /** "Use one of my takes": the shot comes from that take (nothing to generate, nothing to pay for it). */
    fun useTake(slotId: String, t: RecreateTakeChoice) = _ui.update { u ->
        val f = u.fill ?: return@update u
        val s = f.slot(slotId) ?: return@update u
        val p = s.copy(state = "matched", takeId = t.id, jobId = null, estimate = null, estimateLabel = null, score = null, reason = "You picked “${t.caption}”")
        u.copy(fill = f.copy(slots = f.slots.map { if (it.slotId == slotId) p else it }), picks = u.picks + (slotId to p),
            fillErrors = u.fillErrors - slotId, estimateErrors = u.estimateErrors - slotId)
    }.also {
        // Fix shot: once the edit is built, the take goes straight into it, in place (or the edit is rebuilt).
        if (_ui.value.builtSessionId != null) scope.launch { if (!replace(slotId, t.id)) apply() }
    }

    /**
     * Fix shot (WS1 a7302fb): swaps one shot in the built edit, keeping its timing, transition, ramp, camera moves and
     * look and the owner's other edits. False when the shot isn't in that edit any more (the caller rebuilds it).
     */
    private suspend fun replace(slotId: String, take: String): Boolean {
        val u = _ui.value
        val sid = u.builtSessionId ?: return false
        return try {
            val r = api.replaceRecipeSlot(id, slotId, sid, take, u.builtRevision)
            _ui.update { it.copy(builtRevision = r.revision ?: it.builtRevision, message = r.note ?: "${it.shotName(slotId)} is swapped in the edit") }
            true
        } catch (e: CancellationException) { throw e } catch (e: ApiException) {
            if (e.code == "slot_not_in_edit" || e.code == "not_built_here") false
            else { _ui.update { it.copy(message = studio.muse.app.data.ErrorText.plain(e, "Couldn’t swap the shot")) }; true }
        }
    }

    /**
     * Build: prices the shots to generate, then asks once with the real total. Nothing is spent before the yes. With
     * nothing to generate it asks too ("Build the edit?", nothing charged). While shots are generating, it waits for them.
     */
    suspend fun requestBuild() {
        val u = _ui.value
        if (u.fill == null || u.building || u.estimating) return
        if (u.toGenerate.isEmpty() && u.isGenerating) {
            _ui.update { it.copy(buildWhenReady = true, building = true, message = "The new shots are still generating. The edit is built when they’re ready.") }
            startWatch()
            return
        }
        _ui.update { it.copy(estimating = true) }
        price()
        _ui.update { v -> v.copy(estimating = false, confirmSkip = emptySet(), confirmSlots = v.toGenerate.filter { v.estimates[it]?.ok == true && v.estimateErrors[it] == null }) }
    }

    fun cancelBuild() = _ui.update { it.copy(confirmSlots = null, confirmSkip = emptySet()) }

    /** Ticks or unticks a shot in the Build confirmation; the last ticked shot can't be unticked. */
    fun toggleConfirmShot(slotId: String) = _ui.update { u ->
        if (u.confirmSlots?.contains(slotId) != true) u
        else if (slotId in u.confirmSkip) u.copy(confirmSkip = u.confirmSkip - slotId)
        else if (u.confirmChosen.size <= 1) u
        else u.copy(confirmSkip = u.confirmSkip + slotId)
    }

    /**
     * The yes to the total: each confirmed shot is made (one at a time; the server holds and charges it), then, once all
     * are ready, the edit is built and Compare opens. The server's own fill decides: a shot already generating or ready is
     * never filled again.
     */
    fun confirmBuild(): Job = scope.launch {
        if (_ui.value.confirmSlots == null) return@launch
        val confirmed = _ui.value.confirmChosen // unticked shots stay to generate
        val model = modelId()
        // Shots made anew after a build go into that edit in place when they're ready.
        _ui.update { u -> u.copy(fixing = if (u.builtSessionId != null) confirmed.filter { it in u.remake }.toSet() else emptySet()) }
        _ui.update { it.copy(confirmSlots = null, confirmSkip = emptySet(), building = true, buildWhenReady = true, starting = if (model != null) it.starting + confirmed else it.starting) }
        if (confirmed.isEmpty() || model == null) {
            if (_ui.value.isGenerating) startWatch() else { _ui.update { it.copy(building = false) }; apply() }
            return@launch
        }
        val current = runCatching { api.referenceFill(id) }.getOrNull()
        for (s in confirmed) {
            try {
                // The server's own fill decides (never a shot filled twice), unless the person asked for this one anew.
                if (s !in _ui.value.remake && current?.slot(s)?.state.let { it != null && it != "to_generate" }) continue
                // The shot is made the way it was priced and confirmed (swap or generate, and its setting).
                val e = _ui.value.estimates[s]
                val started = api.fillReferenceSlot(id, s, model, method = e?.method, keepBackground = e?.keepBackground?.takeIf { e.method == "swap" },
                    locationId = e?.background?.locationId?.takeIf { e.method == "swap" && !e.keepBackground },
                    // The models it was priced with (owner picks).
                    engineModel = _ui.value.shotModels[s], imageModel = _ui.value.plateModels[s])
                _ui.update { u ->
                    val f = u.fill
                    u.copy(fillErrors = u.fillErrors - s, picks = u.picks - s, remake = u.remake - s, fill = f?.copy(slots = f.slots.map { if (it.slotId == s) it.copy(state = "generating", jobId = started.jobId) else it }))
                }
            } catch (e: CancellationException) { throw e } catch (e: Exception) {
                // WS1: a background plate that couldn't be made (502 background_failed) is never charged.
                val line = if ((e as? ApiException)?.code == "background_failed") "The background couldn’t be made, so this shot didn’t start. You weren’t charged. Try again, or pick one of your locations."
                    else "This shot didn’t start: ${studio.muse.app.data.ErrorText.plain(e, "try again")}"
                _ui.update { u -> u.copy(fillErrors = u.fillErrors + (s to line)) }
            } finally {
                _ui.update { it.copy(starting = it.starting - s) }
            }
        }
        runCatching { api.referenceFill(id) }.getOrNull()?.let(::take)
        if (_ui.value.isGenerating) startWatch() else finish()
    }

    /** While shots generate: the fill every [pollMs] until none is generating, then the edit is built (when Build asked). */
    private fun startWatch() {
        watch?.cancel()
        watch = scope.launch {
            while (true) {
                delay(pollMs)
                val f = runCatching { api.referenceFill(id) }.onFailure { if (it is CancellationException) throw it }.getOrNull() ?: continue
                take(f)
                if (!_ui.value.isGenerating) { finish(); return@launch }
            }
        }
    }

    /** Every new shot is ready or didn't generate. All ready: build and compare. Some didn't: stop and say so. */
    private suspend fun finish() {
        val u = _ui.value
        if (!u.buildWhenReady) { _ui.update { it.copy(building = false) }; return }
        val failed = u.slots.map { it.id }.filter { u.fillErrors[it] != null }
        if (failed.isNotEmpty()) {
            val names = failed.joinToString(" and ") { u.shotName(it) }
            _ui.update { it.copy(buildWhenReady = false, building = false,
                message = "$names didn’t generate. You weren’t charged for ${if (failed.size == 1) "it" else "them"}. Try again, or use one of your takes.") }
            return
        }
        _ui.update { it.copy(building = false) }
        val fix = u.fixing
        // Fix shot: only shots made anew after the build, each swapped into the edit in place; otherwise a full build.
        val toBuild = u.toGenerate.isNotEmpty() || u.slots.any { s -> u.slotFill(s.id)?.state == "ready" && s.id !in fix && u.builtSessionId == null }
        val swapped = fix.isNotEmpty() && u.builtSessionId != null && !toBuild &&
            fix.all { s -> u.slotFill(s)?.jobId?.let { j -> replace(s, j) } == true }
        if (swapped) _ui.update { it.copy(mode = RecreateMode.Compare) } else apply()
        _ui.update { it.copy(buildWhenReady = false, fixing = emptySet()) }
    }

    /** Builds the edit in an edit session on the take the first shot comes from, then shows Compare. */
    suspend fun apply() {
        val u = _ui.value
        val fill = u.fill ?: return
        if (u.building) return
        _ui.update { it.copy(building = true, playing = false) }
        val slots = buildMap {
            fill.slots.forEach { s ->
                when (s.state) {
                    "matched" -> s.takeId?.let { put(s.slotId, it) }
                    "ready" -> (s.jobId ?: s.takeId)?.let { put(s.slotId, it) }
                }
            }
        }
        val known = u.takes.map { it.id }.toSet()
        val base = fill.slots.mapNotNull { it.takeId }.firstOrNull { it in known } ?: u.takes.firstOrNull()?.id
        try {
            if (base == null) throw ApiException("no_takes", "Make a video first: the edit is built on one of your takes")
            val session = api.openEditSession(OpenEditSessionRequest(takeId = base, device = "android"))
            val r = api.applyRecipe(id, session.id, session.revision, slots)
            _ui.update { v ->
                v.copy(building = false, match = r.match ?: v.match, builtTakeId = base, builtSessionId = session.id, builtRevision = r.revision, mode = RecreateMode.Compare,
                    message = r.waiting.takeIf { it.isNotEmpty() }?.let { w -> "${w.joinToString(" and ") { v.shotName(it) }} isn’t ready yet, so the edit leaves it out for now" })
            }
        } catch (e: CancellationException) { throw e } catch (e: Exception) {
            // A validator's or other internal text never reaches the owner (it goes to the log): plain words instead.
            val code = (e as? ApiException)?.code.orEmpty()
            val invalid = code == "bad_request" || code == "validation" || code == "conflict" || code.matches(Regex("http_4\\d\\d"))
            _ui.update { it.copy(building = false, message = if (invalid || studio.muse.app.data.ErrorText.looksInternal(e.message)) {
                studio.muse.app.data.ErrorText.plain(Exception(e.message), BUILD_FAILED); BUILD_FAILED } else studio.muse.app.data.ErrorText.plain(e, BUILD_FAILED)) }
        }
    }

    /**
     * "Make a new one": a shot that comes from a take (or was generated) is made anew. It reads "To generate" with its
     * price, and the next Build confirms and generates it like any other new shot.
     */
    suspend fun remake(slotId: String) {
        _ui.update { u ->
            val f = u.fill ?: return@update u
            val s = f.slot(slotId) ?: return@update u
            val p = s.copy(state = "to_generate", takeId = null, jobId = null, score = null, reason = "A new shot will be made for this one")
            u.copy(fill = f.copy(slots = f.slots.map { if (it.slotId == slotId) p else it }), picks = u.picks + (slotId to p), remake = u.remake + slotId,
                fillErrors = u.fillErrors - slotId)
        }
        price()
    }

    /** "Fix shot 2": back to the recipe on the weakest shot, to pick another take for it or make it anew. */
    fun fixWeakest() = _ui.update { u -> u.copy(selected = u.weakest ?: u.selected, mode = RecreateMode.Recipe) }
}

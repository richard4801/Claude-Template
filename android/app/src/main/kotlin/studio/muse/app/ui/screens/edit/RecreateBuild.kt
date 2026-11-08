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

/** A take that can fill a shot ("Use one of my takes"). */
/** [label]: what tells takes with the same title apart ("Take 2 of 3"). */
data class RecreateTakeChoice(val id: String, val caption: String, val durationSec: Double?, val thumb: studio.muse.app.data.ImageRef? = null, val label: String? = null)

data class RecreateBuildUi(
    val referenceId: String,
    val recipe: Recipe,
    val referenceName: String? = null,
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
    val match: RecreateMatch? = null,
    /** The take the built edit lives on (Open in the editor). */
    val builtTakeId: String? = null,
    val takes: List<RecreateTakeChoice> = emptyList(),
    /** One line to show once (a toast), then [RecreateBuildModel.consumeMessage]. */
    val message: String? = null,
) {
    val slots get() = recipe.slots
    fun slotFill(id: String): RecreateSlotFill? = fill?.slot(id)
    fun score(id: String): Double? = match?.perSlot?.get(id)
    val generating: Set<String> get() = slots.map { it.id }.filter { slotFill(it)?.state == "generating" || it in starting }.toSet()
    val isGenerating: Boolean get() = generating.isNotEmpty()
    /** The shots to generate, not yet started. */
    val toGenerate: List<String> get() = fill?.slots.orEmpty().filter { it.state == "to_generate" && it.slotId !in starting }.map { it.slotId }
    val prices: Map<String, Double> get() = estimates.filterValues { it.ok }.mapValues { it.value.amount }
    val confirmTotal: Double get() = confirmSlots.orEmpty().mapNotNull { estimates[it]?.amount }.sum()
    /** "1 from your takes, 2 to generate · $1.28 in all", beside Build. */
    val summary: String? get() = fill?.let { RecreateText.makingSummary(it, prices, estimateErrors.keys, starting) }
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
    private val modelId: () -> String?,
    private val pollMs: Long = 3_000,
) {
    private val _ui = MutableStateFlow(start)
    val ui: StateFlow<RecreateBuildUi> = _ui
    private var watch: Job? = null
    private val id get() = _ui.value.referenceId

    fun consumeMessage() = _ui.update { it.copy(message = null) }
    fun setMode(m: RecreateMode) {
        if (m == RecreateMode.Compare && _ui.value.match == null) _ui.update { it.copy(message = "Compare opens once the edit is built") }
        else _ui.update { it.copy(mode = m) }
    }
    fun select(i: Int) { if (i in _ui.value.slots.indices) _ui.update { it.copy(selected = i) } }

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
            _ui.update { it.copy(loadingFill = false, message = e.message ?: "Couldn’t load how the shots are made") }
            return
        }
        _ui.update { it.copy(loadingFill = false) }
        if (_ui.value.isGenerating) startWatch()
        price()
    }

    /** A fetched fill: takes picked here stay, and a shot that was generating and came back without its version is marked. */
    private fun take(new: RecreateFill) = _ui.update { u ->
        val was = u.generating
        val fillErrors = u.fillErrors.toMutableMap(); val picks = u.picks.toMutableMap()
        val slots = new.slots.map { s ->
            if (s.state == "generating" || s.state == "ready") { fillErrors -= s.slotId; picks -= s.slotId; return@map s }
            if (s.slotId in was && s.slotId !in u.starting) fillErrors[s.slotId] = "This shot didn’t generate. You weren’t charged for it."
            picks[s.slotId] ?: s
        }
        u.copy(fill = new.copy(slots = slots), fillErrors = fillErrors, picks = picks)
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
            todo.map { s -> async { s to runCatching { api.estimateReferenceSlot(id, s, model) }.onFailure { if (it is CancellationException) throw it } } }.awaitAll()
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

    /** "Use one of my takes": the shot comes from that take (nothing to generate, nothing to pay for it). */
    fun useTake(slotId: String, t: RecreateTakeChoice) = _ui.update { u ->
        val f = u.fill ?: return@update u
        val s = f.slot(slotId) ?: return@update u
        val p = s.copy(state = "matched", takeId = t.id, jobId = null, estimate = null, estimateLabel = null, score = null, reason = "You picked “${t.caption}”")
        u.copy(fill = f.copy(slots = f.slots.map { if (it.slotId == slotId) p else it }), picks = u.picks + (slotId to p),
            fillErrors = u.fillErrors - slotId, estimateErrors = u.estimateErrors - slotId)
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
        _ui.update { v -> v.copy(estimating = false, confirmSlots = v.toGenerate.filter { v.estimates[it]?.ok == true && v.estimateErrors[it] == null }) }
    }

    fun cancelBuild() = _ui.update { it.copy(confirmSlots = null) }

    /**
     * The yes to the total: each confirmed shot is made (one at a time; the server holds and charges it), then, once all
     * are ready, the edit is built and Compare opens. The server's own fill decides: a shot already generating or ready is
     * never filled again.
     */
    fun confirmBuild(): Job = scope.launch {
        val confirmed = _ui.value.confirmSlots ?: return@launch
        val model = modelId()
        _ui.update { it.copy(confirmSlots = null, building = true, buildWhenReady = true, starting = if (model != null) it.starting + confirmed else it.starting) }
        if (confirmed.isEmpty() || model == null) {
            if (_ui.value.isGenerating) startWatch() else { _ui.update { it.copy(building = false) }; apply() }
            return@launch
        }
        val current = runCatching { api.referenceFill(id) }.getOrNull()
        for (s in confirmed) {
            try {
                if (current?.slot(s)?.state.let { it != null && it != "to_generate" }) continue
                val started = api.fillReferenceSlot(id, s, model)
                _ui.update { u ->
                    val f = u.fill
                    u.copy(fillErrors = u.fillErrors - s, fill = f?.copy(slots = f.slots.map { if (it.slotId == s) it.copy(state = "generating", jobId = started.jobId) else it }))
                }
            } catch (e: CancellationException) { throw e } catch (e: Exception) {
                _ui.update { u -> u.copy(fillErrors = u.fillErrors + (s to "This shot didn’t start: ${e.message ?: "try again"}")) }
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
        apply()
        _ui.update { it.copy(buildWhenReady = false) }
    }

    /** Builds the edit in an edit session on the take the first shot comes from, then shows Compare. */
    suspend fun apply() {
        val u = _ui.value
        val fill = u.fill ?: return
        if (u.building) return
        _ui.update { it.copy(building = true) }
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
                v.copy(building = false, match = r.match ?: v.match, builtTakeId = base, mode = RecreateMode.Compare,
                    message = r.waiting.takeIf { it.isNotEmpty() }?.let { w -> "${w.joinToString(" and ") { v.shotName(it) }} isn’t ready yet, so the edit leaves it out for now" })
            }
        } catch (e: CancellationException) { throw e } catch (e: Exception) {
            _ui.update { it.copy(building = false, message = e.message ?: "Couldn’t build the edit") }
        }
    }

    /** "Fix shot 2": back to the recipe on the weakest shot, to pick another take for it. */
    fun fixWeakest() = _ui.update { u -> u.copy(selected = u.weakest ?: u.selected, mode = RecreateMode.Recipe) }
}

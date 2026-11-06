package studio.muse.app.ui.screens.edit

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

import kotlinx.serialization.json.doubleOrNull
import studio.muse.app.data.EditorEstimate
import studio.muse.app.data.EditorJob
import studio.muse.app.data.EditorSourceDto
import studio.muse.core.edit.Adjust

import studio.muse.core.edit.Asset
import studio.muse.core.edit.AssetKind
import studio.muse.core.edit.AudioClip
import studio.muse.core.edit.CaptionPreset
import studio.muse.core.edit.CaptionWord
import studio.muse.core.edit.Chroma
import studio.muse.core.edit.CutOptions
import studio.muse.core.edit.EditProject
import studio.muse.core.edit.ExportSettings
import studio.muse.core.edit.ExportShape
import studio.muse.core.edit.Font
import studio.muse.core.edit.Grain
import studio.muse.core.edit.ImageItem
import studio.muse.core.edit.KfProp
import studio.muse.core.edit.Look
import studio.muse.core.edit.Mask
import studio.muse.core.edit.MediaClip
import studio.muse.core.edit.Presets
import studio.muse.core.edit.ProjectHistory
import studio.muse.core.edit.Range
import studio.muse.core.edit.SPEED_PRESETS
import studio.muse.core.edit.SpeedCurve
import studio.muse.core.edit.SpeedPoint
import studio.muse.core.edit.SpeedPreset
import studio.muse.core.edit.TextItem
import studio.muse.core.edit.Track
import studio.muse.core.edit.TrackKind
import studio.muse.core.edit.Transform
import studio.muse.core.edit.Transition
import studio.muse.core.edit.TransitionKind
import studio.muse.core.edit.VideoClip
import studio.muse.core.edit.VoiceEffect
import studio.muse.core.edit.Word
import studio.muse.core.edit.applyCuts
import studio.muse.core.edit.durationSec
import studio.muse.core.edit.itemSpan
import studio.muse.core.edit.locate
import studio.muse.core.edit.newId
import studio.muse.core.edit.problemOf
import studio.muse.core.edit.setTransition
import studio.muse.core.edit.splitAt
import studio.muse.core.edit.suggestCuts
import studio.muse.core.edit.updateItem
import studio.muse.core.edit.updateTrack
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * The AI helpers and saving, as the controller needs them. [estimate] and [run] answer (value, null) or (null, the
 * message to show). Implemented over the app's repository (real API or the demo backend); tests use a stub.
 */
interface EditBackend {
    suspend fun estimate(kind: String, source: EditorSourceDto, options: JsonObject?): Pair<EditorEstimate?, String?>
    suspend fun run(kind: String, source: EditorSourceDto, options: JsonObject?, onProgress: (EditorJob) -> Unit): Pair<JsonObject?, String?>
}

/** Everything the editor can be asked to do (one sealed list, so the screen is a pure function of state + [act]). */
sealed interface EditAction {
    data object Undo : EditAction
    data object Redo : EditAction
    data object PlayPause : EditAction
    data class Seek(val sec: Double) : EditAction
    data class Zoom(val pxPerSec: Float) : EditAction
    data class Select(val id: String?) : EditAction
    data class Open(val panel: Panel?) : EditAction
    data class SafeAreaOf(val area: SafeArea?) : EditAction
    data object Fullscreen : EditAction
    data object ClearMessage : EditAction
    // Edit
    data object Split : EditAction
    data object Delete : EditAction
    data object Duplicate : EditAction
    data class Ripple(val on: Boolean) : EditAction
    data class SpeedTab(val curve: Boolean) : EditAction
    data class Speed(val speed: Double, val done: Boolean = true) : EditAction
    data class CurvePreset(val preset: SpeedPreset) : EditAction
    data class CurvePoint(val index: Int, val x: Double, val speed: Double, val done: Boolean) : EditAction
    data class AddCurvePoint(val x: Double) : EditAction
    data class SetTransform(val transform: Transform, val done: Boolean = true) : EditAction
    data class AddKeyframe(val prop: KfProp) : EditAction
    data class SetMask(val mask: Mask?, val done: Boolean = true) : EditAction
    data object RemoveBackground : EditAction
    data class SetTransition(val kind: TransitionKind?, val durationSec: Double = 0.4, val done: Boolean = true) : EditAction
    data object TransitionToAll : EditAction
    data class EffectsTab(val tab: String) : EditAction
    // Audio
    data class Volume(val db: Double, val done: Boolean = true) : EditAction
    data class Fades(val inSec: Double, val outSec: Double, val done: Boolean = true) : EditAction
    data class AutoDuck(val on: Boolean) : EditAction
    data class DuckTimes(val attackSec: Double, val releaseSec: Double, val done: Boolean = true) : EditAction
    data class NoiseReduction(val on: Boolean) : EditAction
    data class Enhance(val on: Boolean) : EditAction
    data class Voice(val effect: VoiceEffect) : EditAction
    data class Beats(val marks: BeatMarks) : EditAction
    data class SnapToBeats(val on: Boolean) : EditAction
    data object DetectBeats : EditAction
    data class AddAudio(val upload: String, val durationSec: Double, val voiceOver: Boolean) : EditAction
    // Text & captions
    data class AddHook(val id: String) : EditAction
    data class EditText(val id: String, val text: String) : EditAction
    data object AutoCaptions : EditAction
    data class CaptionTab(val tab: String) : EditAction
    data class CaptionStyleOf(val preset: CaptionPreset) : EditAction
    data class CaptionFont(val font: Font) : EditAction
    data class CaptionColors(val text: String? = null, val highlight: String? = null) : EditAction
    data class CaptionY(val y: Double) : EditAction
    data class CaptionWordsPerPage(val n: Int) : EditAction
    data class WordHighlight(val on: Boolean) : EditAction
    data class DeleteWord(val index: Int) : EditAction
    data object CutSilences : EditAction
    data object RemoveFillers : EditAction
    // Looks & adjust
    data class FiltersTab(val tab: String) : EditAction
    data class LookCategory(val category: String) : EditAction
    data class PickLook(val id: String?, val look: Look?) : EditAction
    data class LookStrength(val strength: Double, val done: Boolean = true) : EditAction
    data object LookToAll : EditAction
    data class ImportedCube(val uploadId: String?, val note: String) : EditAction
    data class AdjustField(val field: String, val value: Double, val done: Boolean = true) : EditAction
    // Overlay, ratio, export
    data class AddPip(val take: TakeChoice) : EditAction
    data class Ratio(val shape: ExportShape) : EditAction
    data class ExportOf(val settings: ExportSettings) : EditAction
    // Edit sessions (workstream 3): owner only, handled by the session sync ([EditSuiteController.sessionActions]).
    data class ClaudePanel(val open: Boolean) : EditAction
    /** Undo one history entry through the server (Claude's, or any). */
    data class UndoEntry(val entryId: Long) : EditAction
    /** The owner's answer to a paid helper Claude asked for. */
    data class AnswerPending(val id: String, val approve: Boolean) : EditAction
    data object ClearClaudeNote : EditAction
    /** Opening a session while this device has edits it doesn't: keep them (pushed on top) or use the latest. */
    data class ResolveConflict(val keepLocal: Boolean) : EditAction
}

/** Edit sessions (workstream 3): what the controller hands to the session sync. */
interface SessionActions {
    fun undoEntry(entryId: Long)
    fun answerPending(id: String, approve: Boolean)
    fun resolveConflict(keepLocal: Boolean)
}

/**
 * The Edit suite's state machine: owns the project history (every change is one undo step; a drag is one step via
 * `done`), the selection and panels, and runs the AI helpers through [EditBackend] (estimate shown first; free ones say
 * Free). Playback, frames, rendering and saving are the view-model's (Android); this class is pure Kotlin + coroutines.
 */
class EditSuiteController(
    private val scope: CoroutineScope,
    private val backend: EditBackend,
    initial: EditSuiteUi = EditSuiteUi(),
    /** The look a bundled look id sets (the pack's own; by default just its LUT at full strength). */
    private val lookOf: (String) -> Look? = { Look(lut = "pack:$it", strength = 1.0) },
) {

    private val _ui = MutableStateFlow(initial)
    val ui: StateFlow<EditSuiteUi> = _ui.asStateFlow()
    private var history: ProjectHistory? = initial.project?.let { ProjectHistory(it) }
    /** The project before the current drag (null when not dragging). */
    private var dragBase: EditProject? = null
    private val jobs = HashMap<String, Job>()

    /** Called by the view-model when playback moves or stops (not an undo step). */
    fun setPlayback(sec: Double, playing: Boolean) = _ui.update { it.copy(playheadSec = sec.coerceIn(0.0, it.duration), playing = playing) }

    fun setPhase(phase: SuitePhase) = _ui.update { it.copy(phase = phase) }

    fun update(f: (EditSuiteUi) -> EditSuiteUi) = _ui.update(f)

    /** Loads [project] (a fresh history). */
    fun load(project: EditProject, title: String, sourceTakeId: String, poster: studio.muse.app.data.ImageRef?, reopened: Boolean) {
        history = ProjectHistory(project)
        dragBase = null
        editedLocally = false
        loadedProject = project
        _ui.update {
            it.copy(
                project = project, title = title, sourceTakeId = sourceTakeId, poster = poster, reopened = reopened, phase = SuitePhase.Ready,
                canUndo = false, canRedo = false, export = ExportSettings.forProject(project), playheadSec = 0.0,
            )
        }
    }

    val project: EditProject? get() = history?.current

    // ------------------------------------------------------------------ Edit sessions (workstream 3)
    /** Set by the session sync for the owner; null = a purely local editor (members, offline). */
    var sessionActions: SessionActions? = null
    /** True while a slider/drag is between its first move and its end (one undo step, not synced yet). */
    val dragging: Boolean get() = dragBase != null
    /** The labels of the local changes since the sync last took them (for the session history). */
    private val labels = ArrayList<String>()
    private var actionLabel: String = "Edit"

    /** The labels of local changes since the last call ("Split · Look"), and forgets them. */
    fun takeLabels(): String {
        val out = labels.distinct().let { if (it.size > 3) it.take(3) + "…" else it }.joinToString(" · ").ifBlank { "Edit" }
        labels.clear()
        return out
    }

    /**
     * A change that came from the session (Claude's, another device's, a server undo): the project becomes [next]
     * without an undo step, and the undo/redo states carry the same change ([carry]) — local undo only ever takes back
     * this device's own edits. Undoing someone else's change goes through the History panel (server undo).
     */
    fun applyRemote(next: EditProject, carry: (EditProject) -> EditProject?) {
        val h = history ?: return
        dragBase = null
        if (h.rebase(next, carry)) synced()
    }

    /** True once this device changed the project since it was loaded (edits the session may not have yet). */
    var editedLocally: Boolean = false
        private set

    /** The project as loaded (before this device's edits). */
    var loadedProject: EditProject? = initial.project
        private set

    /** This device's unsent edits from last time ([project], made on [base]): shown as one local undo step. */
    fun restoreDraft(base: EditProject, project: EditProject) {
        replaceProject(base)
        if (base != project) { history?.apply(project); labels += "This device's changes"; editedLocally = true; synced() }
    }

    /** Starts over from [p] (the session's project when it differs from the one the app built), no undo step. */
    fun replaceProject(p: EditProject) {
        history = ProjectHistory(p); dragBase = null; editedLocally = false; loadedProject = p
        _ui.update { it.copy(project = p, canUndo = false, canRedo = false, selectedId = null, playheadSec = it.playheadSec.coerceIn(0.0, durationSec(p))) }
    }

    fun updateSession(f: (SessionUi) -> SessionUi) = _ui.update { u -> u.session?.let { u.copy(session = f(it)) } ?: u }

    /** The history label of an action that changes the project (null for the rest). */
    private fun labelOf(a: EditAction): String? = when (a) {
        EditAction.Undo -> "Undo"; EditAction.Redo -> "Redo"
        EditAction.Split -> "Split"; EditAction.Delete -> "Delete"; EditAction.Duplicate -> "Duplicate"
        is EditAction.Speed, is EditAction.CurvePreset, is EditAction.CurvePoint, is EditAction.AddCurvePoint -> "Speed"
        is EditAction.SetTransform -> "Transform"; is EditAction.AddKeyframe -> "Keyframe"; is EditAction.SetMask -> "Mask"
        EditAction.RemoveBackground -> "Remove background"; is EditAction.SetTransition, EditAction.TransitionToAll -> "Transition"
        is EditAction.Volume -> "Volume"; is EditAction.Fades -> "Fades"; is EditAction.AutoDuck, is EditAction.DuckTimes -> "Ducking"
        is EditAction.NoiseReduction -> "Noise reduction"; is EditAction.Enhance -> "Enhance voice"; is EditAction.Voice -> "Voice effect"
        EditAction.DetectBeats -> "Beats"; is EditAction.AddAudio -> if (a.voiceOver) "Voice-over" else "Music"
        is EditAction.AddHook -> "Hook"; is EditAction.EditText -> "Text"; EditAction.AutoCaptions -> "Captions"
        is EditAction.CaptionStyleOf, is EditAction.CaptionFont, is EditAction.CaptionColors, is EditAction.CaptionY,
        is EditAction.CaptionWordsPerPage, is EditAction.WordHighlight -> "Caption style"
        is EditAction.DeleteWord -> "Cut word"; EditAction.CutSilences -> "Cut silences"; EditAction.RemoveFillers -> "Remove fillers"
        is EditAction.PickLook, is EditAction.LookStrength, EditAction.LookToAll, is EditAction.ImportedCube -> "Look"
        is EditAction.AdjustField -> "Adjust"; is EditAction.AddPip -> "Overlay"; is EditAction.Ratio, is EditAction.ExportOf -> "Ratio"
        else -> null
    }

    private fun say(msg: String) = _ui.update { it.copy(message = msg) }

    /**
     * Applies [op] to the current project as one undo step ([done] = true) or as a live drag (false: shown, merged into
     * one step when the drag ends). A result that breaks the contract's rules is refused with its reason.
     */
    private fun change(done: Boolean = true, refused: String? = null, op: (EditProject) -> EditProject?): Boolean {
        val h = history ?: return false
        val base = h.current
        val next = op(base)
        if (next == null) { if (refused != null && done) say(refused); if (done) endDrag(); return false }
        problemOf(next, paletteIds = _ui.value.suiteLooks.keys)?.let { p -> if (done) { say(refused ?: friendly(p.field, p.reason)); endDrag() }; return false }
        if (!done) {
            if (dragBase == null) { dragBase = base; h.apply(next) } else h.amend(next)
        } else if (dragBase != null) { h.amend(next); dragBase = null } else h.apply(next)
        labels += actionLabel
        editedLocally = true
        synced()
        return true
    }

    private fun endDrag() { if (dragBase != null) { dragBase = null; synced() } }

    private fun friendly(field: String, reason: String): String = when {
        reason.contains("at least 0.5") -> "The edit must stay at least 0.5 s long"
        field.endsWith("speed") -> "Speed goes from 0.1× to 10×"
        reason.contains("half of each clip") -> "A transition can be at most half of each clip"
        reason.contains("overlap") -> "That doesn't fit there · try another spot"
        else -> "Can't do that here · $reason"
    }

    private fun synced() {
        val h = history ?: return
        _ui.update { u ->
            val p = h.current
            val sel = u.selectedId?.takeIf { id -> p.locate(id) != null }
            u.copy(project = p, canUndo = h.canUndo, canRedo = h.canRedo, selectedId = sel, playheadSec = u.playheadSec.coerceIn(0.0, durationSec(p)))
        }
    }

    // =================================================================== actions
    fun act(a: EditAction) {
        val u = _ui.value
        labelOf(a)?.let { actionLabel = it }
        when (a) {
            // Local undo/redo: this device's own edits only (changes from elsewhere are undone in the History panel).
            EditAction.Undo -> { dragBase = null; if (history?.undo() == true) { labels += "Undo"; editedLocally = true; synced() } }
            EditAction.Redo -> { dragBase = null; if (history?.redo() == true) { labels += "Redo"; editedLocally = true; synced() } }
            is EditAction.ResolveConflict -> sessionActions?.resolveConflict(a.keepLocal)
            is EditAction.ClaudePanel ->
                if (u.session == null) { if (a.open) say("Claude joins once this edit is online · check your connection") }
                else updateSession { it.copy(chatOpen = a.open) }
            is EditAction.UndoEntry -> sessionActions?.undoEntry(a.entryId)
            is EditAction.AnswerPending -> sessionActions?.answerPending(a.id, a.approve)
            EditAction.ClearClaudeNote -> updateSession { it.copy(claudeNote = null) }
            EditAction.PlayPause -> _ui.update { it.copy(playing = !it.playing) }
            is EditAction.Seek -> _ui.update { it.copy(playheadSec = a.sec.coerceIn(0.0, it.duration)) }
            is EditAction.Zoom -> _ui.update { it.copy(pxPerSec = a.pxPerSec.coerceIn(8f, 240f)) }
            is EditAction.Select -> _ui.update { it.copy(selectedId = a.id) }
            is EditAction.Open -> open(a.panel)
            is EditAction.SafeAreaOf -> _ui.update { it.copy(safeArea = a.area) }
            EditAction.Fullscreen -> _ui.update { it.copy(fullscreen = !it.fullscreen) }
            EditAction.ClearMessage -> _ui.update { it.copy(message = null) }

            EditAction.Split -> {
                val t = if (u.snapToBeats) SuiteOps.snap(u.playheadSec, beatsShown(u)) else u.playheadSec
                change(refused = "Move the playhead inside a clip, at least 0.1 s from its edges") { it.splitAt(t) }
            }
            EditAction.Delete -> {
                val id = u.selectedId ?: u.activeClip?.id ?: return
                if (change(refused = "The last clip can't be deleted") { SuiteOps.delete(it, id, u.ripple) }) _ui.update { it.copy(selectedId = null) }
            }
            EditAction.Duplicate -> { val id = u.selectedId ?: u.activeClip?.id ?: return; change(refused = "No room for a copy there") { SuiteOps.duplicate(it, id) } }
            is EditAction.Ripple -> _ui.update { it.copy(ripple = a.on) }
            is EditAction.SpeedTab -> _ui.update { it.copy(speedCurveTab = a.curve) }
            is EditAction.Speed -> { val c = u.activeClip ?: return; change(a.done) { SuiteOps.setSpeed(it, c.id, a.speed) } }
            is EditAction.CurvePreset -> {
                val c = u.activeClip ?: return
                val pts = SPEED_PRESETS[a.preset] ?: c.speedCurve?.points ?: listOf(SpeedPoint(0.0, 1.0), SpeedPoint(0.5, 2.0), SpeedPoint(1.0, 1.0))
                change { SuiteOps.setCurve(it, c.id, SpeedCurve(a.preset, pts)) }
            }
            is EditAction.CurvePoint -> {
                val c = u.activeClip ?: return
                val curve = c.speedCurve ?: return
                val pts = curve.points.toMutableList()
                if (a.index !in pts.indices) return
                val lo = if (a.index == 0) 0.0 else pts[a.index - 1].x + 0.02
                val hi = if (a.index == pts.lastIndex) 1.0 else pts[a.index + 1].x - 0.02
                val x = when (a.index) { 0 -> 0.0; pts.lastIndex -> 1.0; else -> a.x.coerceIn(lo, hi) }
                pts[a.index] = SpeedPoint(r3(x), r3(a.speed.coerceIn(0.1, 10.0)))
                change(a.done) { SuiteOps.setCurve(it, c.id, SpeedCurve(SpeedPreset.CUSTOM, pts)) }
            }
            is EditAction.AddCurvePoint -> {
                val c = u.activeClip ?: return
                val curve = c.speedCurve ?: SpeedCurve(SpeedPreset.CUSTOM, listOf(SpeedPoint(0.0, 1.0), SpeedPoint(1.0, 1.0)))
                if (curve.points.size >= 16 || curve.points.any { abs(it.x - a.x) < 0.03 }) return
                val pts = (curve.points + SpeedPoint(r3(a.x), r3(studio.muse.core.edit.curveSpeed(curve, a.x)))).sortedBy { it.x }
                change { SuiteOps.setCurve(it, c.id, SpeedCurve(SpeedPreset.CUSTOM, pts)) }
            }
            is EditAction.SetTransform -> { val id = visualId(u) ?: return; change(a.done) { p -> p.updateItem(id) { withTransform(it, a.transform) } } }
            is EditAction.AddKeyframe -> addKeyframe(u, a.prop)
            is EditAction.SetMask -> { val id = visualId(u) ?: return; change(a.done) { p -> p.updateItem(id) { when (it) { is VideoClip -> it.copy(mask = a.mask); is ImageItem -> it.copy(mask = a.mask); else -> it } } } }
            EditAction.RemoveBackground -> removeBackground(u)
            is EditAction.SetTransition -> {
                val c = u.activeClip ?: return
                val p = project ?: return
                val i = p.mainClips.indexOfFirst { it.id == c.id }
                if (i <= 0) return say("Transitions go between clips · pick the second clip or later")
                change(a.done, "That transition is too long for these clips") { it.setTransition(c.id, a.kind?.let { k -> Transition(k, a.durationSec) }) }
            }
            EditAction.TransitionToAll -> {
                val tr = u.activeClip?.transitionIn
                if (change { SuiteOps.transitionAll(it, tr) }) say(if (tr == null) "Cuts on every clip" else "Applied to all cuts")
            }
            is EditAction.EffectsTab -> { _ui.update { it.copy(effectsTab = a.tab) }; if (a.tab == "Mask") estimate("matte") }

            is EditAction.Volume -> { val c = soundClip(u) ?: return; change(a.done) { p -> p.updateItem(c.id) { setVolume(it, SuiteOps.dbToGain(a.db).coerceIn(0.0, 2.0)) } } }
            is EditAction.Fades -> { val c = soundClip(u) ?: return; change(a.done) { p -> p.updateItem(c.id) { setFades(it, a.inSec, a.outSec) } } }
            is EditAction.AutoDuck -> if (SuiteOps.musicTrack(project ?: return) == null) say("Add music first · Audio → Music") else change { SuiteOps.duck(it, a.on) }
            is EditAction.DuckTimes -> change(a.done) { p -> val t = SuiteOps.musicTrack(p) ?: return@change null; val d = t.duck ?: return@change null
                p.updateTrack(t.id) { it.copy(duck = d.copy(attackSec = r2(a.attackSec.coerceIn(0.05, 2.0)), releaseSec = r2(a.releaseSec.coerceIn(0.05, 3.0)))) } }
            is EditAction.NoiseReduction -> noiseReduction(u, a.on)
            is EditAction.Enhance -> { val c = soundClip(u) ?: return; change { p -> p.updateItem(c.id) { setVoice(it, enhance = a.on) } } }
            is EditAction.Voice -> { val c = soundClip(u) ?: return; change { p -> p.updateItem(c.id) { setVoice(it, effect = a.effect) } } }
            is EditAction.Beats -> _ui.update { it.copy(beatMarks = a.marks) }
            is EditAction.SnapToBeats -> _ui.update { it.copy(snapToBeats = a.on) }
            EditAction.DetectBeats -> detectBeats()
            is EditAction.AddAudio -> {
                val at = if (a.voiceOver) u.playheadSec else 0.0
                if (change(refused = "Couldn't add that audio") { SuiteOps.addAudio(it, a.upload, a.durationSec, at, if (a.voiceOver) TrackKind.VOICE else TrackKind.MUSIC) })
                    say(if (a.voiceOver) "Voice-over added" else "Music added")
            }

            is EditAction.AddHook -> {
                val hook = Presets.hook(a.id) ?: return
                var newId: String? = null
                if (change(refused = "No room for text there") { p -> SuiteOps.addHook(p, hook, u.playheadSec)?.let { (np, id) -> newId = id; np } }) _ui.update { it.copy(selectedId = newId) }
            }
            is EditAction.EditText -> change(done = true) { p -> p.updateItem(a.id) { (it as? TextItem)?.copy(text = a.text.take(500).ifBlank { it.text }) ?: it } }
            EditAction.AutoCaptions -> autoCaptions()
            is EditAction.CaptionTab -> _ui.update { it.copy(captionTab = a.tab) }
            is EditAction.CaptionStyleOf -> if (u.captionTrack == null) say("Make captions first · Auto-captions") else change { p -> SuiteOps.captionStyle(p) { SuiteOps.switchPreset(it, a.preset) } }
            is EditAction.CaptionFont -> change { p -> SuiteOps.captionStyle(p) { it.copy(text = it.text.copy(font = a.font, weight = if (a.font == Font.MARKER || a.font == Font.SERIF) 400 else it.text.weight.coerceAtLeast(700))) } }
            is EditAction.CaptionColors -> change { p -> SuiteOps.captionStyle(p) { s -> s.copy(text = a.text?.let { c -> s.text.copy(color = c) } ?: s.text, highlightColor = a.highlight ?: s.highlightColor) } }
            is EditAction.CaptionY -> change { p -> SuiteOps.captionStyle(p) { it.copy(y = a.y) } }
            is EditAction.CaptionWordsPerPage -> change { p -> SuiteOps.captionStyle(p) { it.copy(wordsPerPage = a.n.coerceIn(1, 8)) } }
            is EditAction.WordHighlight -> change { p ->
                SuiteOps.captionStyle(p) { s -> if (a.on) s.copy(highlightColor = Presets.CAPTION_STYLES.getValue(s.preset).highlightColor.takeIf { c -> c != s.text.color } ?: "#FFE600") else s.copy(highlightColor = s.text.color) }
            }
            is EditAction.DeleteWord -> deleteWord(a.index)
            EditAction.CutSilences -> cutSilences()
            EditAction.RemoveFillers -> removeFillers()

            is EditAction.FiltersTab -> _ui.update { it.copy(filtersTab = a.tab) }
            is EditAction.LookCategory -> _ui.update { it.copy(lookCategory = a.category) }
            is EditAction.PickLook -> {
                val id = visualId(u) ?: return
                val look = (a.look ?: a.id?.let(lookOf))?.let { l -> l.copy(strength = currentLook(u)?.takeIf { it.lut != null }?.strength ?: l.strength) }
                change { SuiteOps.setLook(it, listOf(id), look) }
            }
            is EditAction.LookStrength -> { val id = visualId(u) ?: return; val l = currentLook(u) ?: return; change(a.done) { SuiteOps.setLook(it, listOf(id), l.copy(strength = r2(a.strength.coerceIn(0.0, 1.0)))) } }
            EditAction.LookToAll -> {
                val l = currentLook(u)
                if (change { p -> SuiteOps.setLook(p, p.mainClips.map { it.id }, l) }) say("Look applied to every clip")
            }
            is EditAction.ImportedCube -> importedCube(u, a)
            is EditAction.AdjustField -> adjust(u, a)

            is EditAction.AddPip -> {
                var newId: String? = null
                if (change(refused = "Couldn't add that overlay here") { p -> SuiteOps.addPip(p, a.take.id, a.take.durationSec ?: 5.0, u.playheadSec)?.let { (np, id) -> newId = id; np } })
                    _ui.update { it.copy(selectedId = newId) }
            }
            is EditAction.Ratio -> if (change { SuiteOps.ratio(it, a.shape) }) _ui.update { it.copy(export = it.export.copy(shape = a.shape)) }
            is EditAction.ExportOf -> {
                val shapeChanged = a.settings.shape != u.export.shape
                _ui.update { it.copy(export = a.settings) }
                if (shapeChanged) change { SuiteOps.ratio(it, a.settings.shape) }
            }
        }
    }

    // =================================================================== panels and estimates
    private fun open(panel: Panel?) {
        _ui.update { it.copy(panel = panel) }
        when (panel) {
            Panel.CAPTIONS -> { if (_ui.value.captionTrack == null) estimate("captions"); estimate("cuts", silenceOnly()) }
            Panel.AUDIO -> { estimate("denoise"); if (SuiteOps.musicTrack(project ?: return) != null) estimate("beats", source = musicSource()) }
            Panel.EFFECTS -> if (_ui.value.effectsTab == "Mask") estimate("matte")
            Panel.SPEED -> _ui.update { it.copy(speedCurveTab = it.activeClip?.speedCurve != null) }
            else -> {}
        }
    }

    private fun silenceOnly() = JsonObject(mapOf("silenceOnly" to JsonPrimitive(true)))

    private fun sourceOf(asset: Asset?): EditorSourceDto? = when {
        asset == null -> null
        asset.take != null -> EditorSourceDto(takeId = asset.take)
        asset.upload != null -> EditorSourceDto(uploadId = asset.upload, durationSec = asset.durationSec)
        else -> null
    }

    private fun mainSource(): EditorSourceDto? = project?.let { sourceOf(SuiteOps.sourceAsset(it)) } ?: _ui.value.sourceTakeId.takeIf { it.isNotEmpty() }?.let { EditorSourceDto(takeId = it) }

    private fun musicSource(): EditorSourceDto? {
        val p = project ?: return null
        val clip = SuiteOps.musicTrack(p)?.items?.firstOrNull() as? AudioClip ?: return null
        return sourceOf(p.asset(clip.asset))
    }

    private fun aiKey(kind: String, options: JsonObject?) = if (kind == "cuts" && options?.get("silenceOnly") != null) "silences" else kind

    /** Fetches what a helper costs, for its button ("about $0.02" / "Free"). */
    fun estimate(kind: String, options: JsonObject? = null, source: EditorSourceDto? = mainSource()) {
        val src = source ?: return
        val key = aiKey(kind, options)
        if (_ui.value.ai[key]?.running == true) return
        scope.launch {
            val (e, err) = backend.estimate(kind, src, options)
            setAi(key) { it.copy(price = e?.let(::priceOf) ?: it.price, error = if (e == null) err else null) }
        }
    }

    private fun setAi(key: String, f: (AiTask) -> AiTask) = _ui.update { u -> u.copy(ai = u.ai + (key to f(u.ai[key] ?: AiTask(key)))) }

    /** Runs a helper and hands its result to [apply] on success (one undo step). */
    private fun runAi(kind: String, options: JsonObject?, source: EditorSourceDto?, apply: (JsonObject) -> Unit) {
        val src = source ?: return say("This video can't be sent to the helpers")
        val key = aiKey(kind, options)
        if (_ui.value.ai[key]?.running == true) return
        setAi(key) { it.copy(running = true, progress = 0, phase = "Starting", error = null) }
        jobs[key] = scope.launch {
            val (result, err) = backend.run(kind, src, options) { j -> setAi(key) { it.copy(progress = j.progress, phase = j.phase) } }
            setAi(key) { it.copy(running = false, progress = if (result != null) 100 else it.progress, done = result != null, error = err) }
            if (result != null) {
                actionLabel = when (key) { "captions" -> "Captions"; "silences" -> "Cut silences"; "denoise" -> "Noise reduction"; "beats" -> "Beats"; "matte" -> "Remove background"; else -> "Edit" }
                apply(result)
            } else if (err != null) say(err)
        }
    }

    fun cancelAi(key: String) { jobs.remove(key)?.cancel(); setAi(key) { it.copy(running = false) } }

    // =================================================================== AI helpers
    private fun autoCaptions() {
        val p = project ?: return
        val asset = SuiteOps.sourceAsset(p) ?: return
        runAi("captions", null, sourceOf(asset)) { r ->
            val words = (r["words"] as? JsonArray).orEmpty().mapNotNull { w ->
                val o = w as? JsonObject ?: return@mapNotNull null
                val text = (o["text"] as? JsonPrimitive)?.content?.trim()?.take(60)?.ifEmpty { null } ?: return@mapNotNull null
                val s = (o["startSec"] as? JsonPrimitive)?.doubleOrNull ?: return@mapNotNull null
                val e = (o["endSec"] as? JsonPrimitive)?.doubleOrNull ?: return@mapNotNull null
                CaptionWord(text, s, maxOf(s, e))
            }
            if (words.isEmpty()) say("No speech found in this video")
            else if (change { SuiteOps.withCaptions(it, asset.id, words) }) say("Captions added · ${words.size} words")
        }
    }

    private fun cuts(r: JsonObject): List<Range> = (r["cuts"] as? JsonArray).orEmpty().mapNotNull { c ->
        val o = c as? JsonObject ?: return@mapNotNull null
        val s = (o["startSec"] as? JsonPrimitive)?.doubleOrNull ?: return@mapNotNull null
        val e = (o["endSec"] as? JsonPrimitive)?.doubleOrNull ?: return@mapNotNull null
        Range(s, e)
    }

    /** Free: the server finds the silences from the audio level (no transcript needed). */
    private fun cutSilences() {
        val p = project ?: return
        val asset = SuiteOps.sourceAsset(p) ?: return
        runAi("cuts", silenceOnly(), sourceOf(asset)) { r ->
            val cs = cuts(r)
            if (cs.isEmpty()) say("No long silences found")
            else if (change { applyCuts(it, asset.id, cs) }) say("Cut ${cs.size} silence${if (cs.size == 1) "" else "s"} · ${"%.1f".format(cs.sumOf { it.endSec - it.startSec })} s shorter")
        }
    }

    /** The transcript's filler words ("um", "uh", "like"…), as source ranges (free, on the device). */
    fun fillerCuts(p: EditProject): List<Range> {
        val ct = p.tracks.firstOrNull { it.kind == TrackKind.CAPTION }?.caption ?: return emptyList()
        val words = ct.words.map { Word(it.text, it.startSec, it.endSec) }
        val dur = p.asset(ct.asset)?.durationSec ?: (words.lastOrNull()?.endSec ?: 0.0)
        return suggestCuts(words, dur, CutOptions(minSilenceSec = 5.0, fillers = true, repeats = false, extraFillers = listOf("like"))).cuts
            .filter { it.reason == studio.muse.core.edit.CutReason.FILLER }
            .filter { k -> SuiteOps.words(p).any { w -> w.kept && w.startSec < k.endSec && w.endSec > k.startSec } }
            .map { Range(it.startSec, it.endSec) }
    }

    private fun removeFillers() {
        val p = project ?: return
        val ct = p.tracks.firstOrNull { it.kind == TrackKind.CAPTION }?.caption ?: return say("Make captions first · the fillers come from the transcript")
        val cs = fillerCuts(p)
        if (cs.isEmpty()) return say("No filler words left")
        if (change { applyCuts(it, ct.asset, cs) }) say("Removed ${cs.size} filler word${if (cs.size == 1) "" else "s"}")
    }

    /** Edit by text: deleting a word cuts its source time out of the video. */
    private fun deleteWord(index: Int) {
        val p = project ?: return
        val ct = p.tracks.firstOrNull { it.kind == TrackKind.CAPTION }?.caption ?: return
        val w = ct.words.getOrNull(index) ?: return
        change(refused = "That word can't be cut (the clip would get too short)") { applyCuts(it, ct.asset, listOf(Range(w.startSec, w.endSec))).takeIf { n -> n != it } }
    }

    private fun noiseReduction(u: EditSuiteUi, on: Boolean) {
        val p = project ?: return
        val clip = soundClip(u) as? VideoClip ?: return say("Pick a video clip for noise reduction")
        if (!on) { change { pp -> pp.updateItem(clip.id) { (it as VideoClip).copy(audioAsset = null) } }; return }
        runAi("denoise", null, sourceOf(p.asset(clip.asset))) { r ->
            val a = r["asset"] as? JsonObject ?: return@runAi say("The helper found nothing to clean")
            val upload = (a["upload"] as? JsonPrimitive)?.content
            val take = (a["take"] as? JsonPrimitive)?.content
            val dur = (a["durationSec"] as? JsonPrimitive)?.doubleOrNull
            change { pp ->
                val id = SuiteOps.newAssetId(pp, "voice")
                val withAsset = pp.copy(assets = pp.assets + Asset(id, AssetKind.AUDIO, take = take, upload = if (take == null) upload else null, durationSec = dur, hasAudio = true))
                withAsset.mainClips.filter { it.asset == clip.asset }.fold(withAsset) { acc, c -> acc.updateItem(c.id) { (it as VideoClip).copy(audioAsset = id) } ?: acc }
            }
            say("Noise reduced · the voice is clean")
        }
    }

    private fun detectBeats() {
        val p = project ?: return
        val t = SuiteOps.musicTrack(p) ?: return say("Add music first")
        val clip = t.items.firstOrNull() as? AudioClip ?: return
        runAi("beats", null, sourceOf(p.asset(clip.asset))) { r ->
            fun list(k: String) = (r[k] as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.doubleOrNull }.take(2000)
            val beats = list("beats"); val strong = list("strong")
            val bpm = (r["bpm"] as? JsonPrimitive)?.doubleOrNull
            change { pp ->
                val tr = SuiteOps.musicTrack(pp) ?: return@change null

                tr.items.fold(pp) { acc, it -> acc.updateItem(it.id) { a -> (a as AudioClip).copy(beats = beats, strongBeats = strong) } ?: acc }.takeIf { it != pp }
            }
            _ui.update { it.copy(bpm = bpm) }
            say("Beats found · ${bpm?.let { "${it.roundToInt()} BPM" } ?: "${beats.size} marks"}")
        }
    }

    private fun removeBackground(u: EditSuiteUi) {
        val p = project ?: return
        val clip = u.activeClip ?: return
        val src = sourceOf(p.asset(clip.asset))
        runAi("matte", null, src) { r ->
            val a = r["asset"] as? JsonObject ?: return@runAi
            val upload = (a["upload"] as? JsonPrimitive)?.content
            val take = (a["take"] as? JsonPrimitive)?.content
            val ch = r["chroma"] as? JsonObject
            val chroma = Chroma((ch?.get("color") as? JsonPrimitive)?.content ?: "#00FF00", (ch?.get("similarity") as? JsonPrimitive)?.doubleOrNull,
                (ch?.get("smoothness") as? JsonPrimitive)?.doubleOrNull, (ch?.get("spill") as? JsonPrimitive)?.doubleOrNull)
            change { pp ->
                // The cut-out person goes on an overlay track over the same span of the timeline, keyed.
                val id = SuiteOps.newAssetId(pp, "matte")
                val withAsset = pp.copy(assets = pp.assets + Asset(id, AssetKind.VIDEO, take = take, upload = if (take == null) upload else null,
                    durationSec = (a["durationSec"] as? JsonPrimitive)?.doubleOrNull, hasAudio = false))
                val span = itemSpan(withAsset, withAsset.main, withAsset.main.items.first { it.id == clip.id })
                val track = Track(withAsset.newId("cutout"), TrackKind.VIDEO, name = "Cut-out")
                val c = VideoClip(withAsset.newId("k"), id, clip.inSec, clip.outSec, clip.speed, speedCurve = clip.speedCurve,
                    startSec = span.startSec, muted = true, chroma = chroma)
                withAsset.copy(tracks = withAsset.tracks + track.copy(items = listOf(c)))
            }
            say("Background removed · the person is on an overlay track")
        }
    }

    // =================================================================== looks, adjust, transform
    /** The visual item the look/adjust/mask/transform tools act on: the selected video/image, else the active main clip. */
    private fun visualId(u: EditSuiteUi): String? = (u.selection?.second?.takeIf { it is VideoClip || it is ImageItem } ?: u.activeClip)?.id

    private fun currentVisual(u: EditSuiteUi): studio.muse.core.edit.Visual? {
        val id = visualId(u) ?: return null
        return project?.tracks?.flatMap { it.items }?.firstOrNull { it.id == id } as? studio.muse.core.edit.Visual
    }

    private fun currentLook(u: EditSuiteUi): Look? = currentVisual(u)?.look

    private fun importedCube(u: EditSuiteUi, a: EditAction.ImportedCube) {
        _ui.update { it.copy(cubeNote = a.note) }
        val upload = a.uploadId ?: return
        val id = visualId(u) ?: return
        change { p ->
            val assetId = p.assets.firstOrNull { it.kind == AssetKind.LUT && it.upload == upload }?.id ?: SuiteOps.newAssetId(p, "lut")
            val withAsset = if (p.assets.any { it.id == assetId }) p else p.copy(assets = p.assets + Asset(assetId, AssetKind.LUT, upload = upload))
            SuiteOps.setLook(withAsset, listOf(id), (currentLook(u) ?: Look()).copy(lut = assetId, strength = 1.0))
        }
    }

    private fun adjust(u: EditSuiteUi, a: EditAction.AdjustField) {
        val id = visualId(u) ?: return
        val v = r2(a.value)
        change(a.done) { p ->
            p.updateItem(id) { it ->
                val vis = it as? studio.muse.core.edit.Visual ?: return@updateItem it
                if (a.field == "grain") {
                    val look = (vis.look ?: Look()).let { l -> l.copy(grain = if (v <= 0) null else Grain(v.coerceIn(0.0, 1.0), l.grain?.size)) }
                    when (it) { is VideoClip -> it.copy(look = look); is ImageItem -> it.copy(look = look); else -> it }
                } else {
                    val ad = vis.adjust ?: Adjust()
                    val x = v.coerceIn(-1.0, 1.0).takeIf { n -> n != 0.0 }
                    val n = when (a.field) {
                        "exposure" -> ad.copy(exposure = x); "contrast" -> ad.copy(contrast = x); "saturation" -> ad.copy(saturation = x)
                        "temperature" -> ad.copy(temperature = x); "highlights" -> ad.copy(highlights = x); "shadows" -> ad.copy(shadows = x); else -> ad
                    }.takeIf { n -> n != Adjust() }
                    when (it) { is VideoClip -> it.copy(adjust = n); is ImageItem -> it.copy(adjust = n); else -> it }
                }
            }
        }
    }

    private fun addKeyframe(u: EditSuiteUi, prop: KfProp) {
        val p = project ?: return
        val id = visualId(u) ?: return
        val (t, item) = p.locate(id)?.let { (tr, i) -> tr to tr.items[i] } ?: return
        val span = itemSpan(p, t, item)
        if (u.playheadSec < span.startSec || u.playheadSec > span.endSec) return say("Move the playhead over this clip to add a keyframe")
        val local = u.playheadSec - span.startSec
        val vis = item as? studio.muse.core.edit.Visual ?: return
        val tr = vis.transform
        val v = when (prop) {
            KfProp.X -> tr?.x ?: 0.5; KfProp.Y -> tr?.y ?: 0.5; KfProp.SCALE -> tr?.scale ?: 1.0; KfProp.ROTATION -> tr?.rotation ?: 0.0
            KfProp.OPACITY -> vis.opacity ?: 1.0; KfProp.VOLUME -> (item as? MediaClip)?.volume ?: 1.0
        }
        if (change { SuiteOps.keyframe(it, id, prop, local, v) }) say("Keyframe added at ${"%.1f".format(local)} s")
    }

    private fun withTransform(it: studio.muse.core.edit.Item, t: Transform) = when (it) {
        is VideoClip -> it.copy(transform = t); is ImageItem -> it.copy(transform = t); is TextItem -> it.copy(transform = t); else -> it
    }

    // =================================================================== audio helpers
    private fun soundClip(u: EditSuiteUi): MediaClip? = SuiteOps.soundClip(project ?: return null, u.selectedId, u.activeClip)

    private fun setVolume(it: studio.muse.core.edit.Item, v: Double) = when (it) {
        is VideoClip -> it.copy(volume = r2(v).takeIf { x -> x != 1.0 }, muted = if (v <= 0.0) true else null)
        is AudioClip -> it.copy(volume = r2(v).takeIf { x -> x != 1.0 }, muted = if (v <= 0.0) true else null)
        else -> it
    }

    private fun setFades(it: studio.muse.core.edit.Item, i: Double, o: Double) = when (it) {
        is VideoClip -> it.copy(fadeInSec = r2(i).takeIf { x -> x > 0 }, fadeOutSec = r2(o).takeIf { x -> x > 0 })
        is AudioClip -> it.copy(fadeInSec = r2(i).takeIf { x -> x > 0 }, fadeOutSec = r2(o).takeIf { x -> x > 0 })
        else -> it
    }

    private fun setVoice(it: studio.muse.core.edit.Item, effect: VoiceEffect? = null, enhance: Boolean? = null) = when (it) {
        is VideoClip -> it.copy(voiceEffect = effect?.takeIf { e -> e != VoiceEffect.NONE } ?: if (effect != null) null else it.voiceEffect, enhance = if (enhance != null) enhance.takeIf { x -> x } else it.enhance)
        is AudioClip -> it.copy(voiceEffect = effect?.takeIf { e -> e != VoiceEffect.NONE } ?: if (effect != null) null else it.voiceEffect, enhance = if (enhance != null) enhance.takeIf { x -> x } else it.enhance)
        else -> it
    }

    private fun beatsShown(u: EditSuiteUi) = project?.let { SuiteOps.beatTimes(it, u.beatMarks == BeatMarks.STRONG) }.orEmpty()

    companion object {
        fun r2(v: Double) = Math.round(v * 100) / 100.0
        fun r3(v: Double) = Math.round(v * 1000) / 1000.0

        /** "about $0.02" or "Free" (never a provider or model). */
        fun priceOf(e: EditorEstimate): String = if (e.free || e.usd <= 0.0) "Free" else "about $" + String.format(java.util.Locale.ROOT, "%.2f", e.usd)
    }
}



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
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import studio.muse.app.data.EditorEstimate
import studio.muse.app.data.EditorJob
import studio.muse.app.data.EditorSourceDto
import studio.muse.core.edit.Adjust
import studio.muse.core.edit.AlphaMatte

import studio.muse.core.edit.Asset
import studio.muse.core.edit.AssetKind
import studio.muse.core.edit.AudioClip
import studio.muse.core.edit.clipSourceAt
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
import studio.muse.core.edit.freezeAt
import studio.muse.core.edit.splitAt
import studio.muse.core.edit.trimClip
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
    /** The same, on the owner's chosen model ([engineModel], WS13; null = the studio's default). */
    suspend fun estimate(kind: String, source: EditorSourceDto, options: JsonObject?, engineModel: String?): Pair<EditorEstimate?, String?> = estimate(kind, source, options)
    suspend fun run(kind: String, source: EditorSourceDto, options: JsonObject?, engineModel: String?, onProgress: (EditorJob) -> Unit): Pair<JsonObject?, String?> = run(kind, source, options, onProgress)
    /** A helper's result added an asset the device doesn't have yet (background removal's matte): fetch [url] for it. */
    fun assetArrived(assetId: String, url: String) {}
    /**
     * The paid helpers that can't run now, each with the plain line shown instead (WS1 guardrails: `GET /v1/editor/features`
     * paid.available and each helper's available): captions, matte, denoise. Empty = all available.
     */
    suspend fun helpersOff(): Map<String, String> = emptyMap()
}

/** Everything the editor can be asked to do (one sealed list, so the screen is a pure function of state + [act]). */
sealed interface EditAction {
    data object Undo : EditAction
    data object Redo : EditAction
    data object PlayPause : EditAction
    data class Seek(val sec: Double) : EditAction
    /**
     * The timeline is being dragged / flung to [sec] (playback pauses). [end]: the finger is up and the fling stopped;
     * the playhead then lands on the nearest frame, so a split cuts on a real frame.
     */
    data class Scrub(val sec: Double, val end: Boolean = false) : EditAction
    /** Long-press drag of a non-main item: moved by [deltaSec] from where the drag began (snaps within [snapSec]). */
    data class MoveBy(val itemId: String, val deltaSec: Double, val snapSec: Double = 0.0, val done: Boolean = true) : EditAction
    /** Long-press drag of a main clip: it goes to position [toIndex]. */
    data class Reorder(val clipId: String, val toIndex: Int, val done: Boolean = true) : EditAction
    /** Dragging a selected item's [left] or right edge by [deltaSec] from where the drag began. */
    data class TrimBy(val itemId: String, val left: Boolean, val deltaSec: Double, val done: Boolean = true) : EditAction
    /** Dragging a selected main clip's edge: its new source in/out ([done] when the finger lifts: one undo step). */
    data class Trim(val clipId: String, val inSec: Double, val outSec: Double, val done: Boolean = true) : EditAction
    data class Zoom(val pxPerSec: Float) : EditAction
    data class Select(val id: String?) : EditAction
    data class Open(val panel: Panel?) : EditAction
    data class SafeAreaOf(val area: SafeArea?) : EditAction
    data object Fullscreen : EditAction
    /** Tablet: "Hide inspector" / "Show inspector" (plans/edit-layout.md). */
    data class InspectorHidden(val hidden: Boolean) : EditAction
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
    /** Removes the selected item's keyframes at the playhead ([prop] null = every property). */
    data class RemoveKeyframes(val prop: KfProp? = null) : EditAction
    /** Easing of the keyframes at the playhead, and of the next ones added. */
    data class KeyEase(val ease: studio.muse.core.edit.Ease) : EditAction
    /** Opacity of the selected picture or text (a keyframe at the playhead when opacity is keyframed). */
    data class SetOpacity(val opacity: Double, val done: Boolean = true) : EditAction
    /** Mirror the selected picture or text (null leaves that axis as it is). */
    data class Mirror(val x: Boolean? = null, val y: Boolean? = null) : EditAction
    /** Slip: the selected main clip plays another part of its source from [inSec], keeping its length. */
    data class Slip(val inSec: Double, val done: Boolean = true) : EditAction
    /** Replace the selected (or current) main clip's video with [take], keeping its edits and length where the take allows. */
    data class ReplaceClip(val take: TakeChoice) : EditAction
    /** A beat mark at the playhead on the music under it (manual beats; they snap like detected ones). */
    data object MarkBeat : EditAction
    /** Removes every beat mark of the music under the playhead (or the selected music). */
    data object ClearBeats : EditAction
    /** Another take's sound only, at the playhead, on a sound effects track. */
    data class AddTakeSound(val take: TakeChoice) : EditAction
    /** The selected audio clip repeated to the end of the video. */
    data object LoopAudio : EditAction
    /** Fixes a caption word's text ([index] into the caption track's words). */
    data class CaptionWordText(val index: Int, val text: String) : EditAction
    /** The selected overlay's blend mode over what is below it (normal = none). */
    data class SetBlend(val mode: studio.muse.core.edit.BlendMode) : EditAction
    /** Freeze frame: a hold of the frame under the playhead, [durationSec] long, cut into the main track. */
    data class Freeze(val durationSec: Double = 1.0) : EditAction
    /** The selected freeze frame's length. */
    data class HoldLength(val sec: Double, val done: Boolean = true) : EditAction
    /** What fills the frame around a contain-fitted clip: the colour or a blur of the clip. */
    data class Fill(val fill: studio.muse.core.edit.CanvasFill) : EditAction
    /** The selected (or current) main clip: fill the frame (cover) or show the whole picture (contain). */
    data class ClipFit(val fit: studio.muse.core.edit.Fit) : EditAction
    /** −1 / +1 frame. */
    data class StepFrame(val frames: Int) : EditAction
    /** The canvas colour behind the picture ("#RRGGBB"). */
    data class Background(val color: String) : EditAction
    data class SetMask(val mask: Mask?, val done: Boolean = true) : EditAction
    /** Crop of the selected picture (fractions cut from each side, 0–0.45); null = no crop. */
    data class SetCrop(val crop: studio.muse.core.edit.Crop?, val done: Boolean = true) : EditAction
    data object RemoveBackground : EditAction
    /** Turns a clip's background removal off (its alpha matte goes; the matte asset stays in the project for undo). */
    data object KeepBackground : EditAction
    /** Remove background → tap what to keep (workstream 1, plans/api.md "KeepPoint"): on / off. */
    data class TapToKeep(val on: Boolean) : EditAction
    /** A tap on the paused picture at (x, y), 0–1 of the frame. */
    data class KeepTapAt(val x: Double, val y: Double) : EditAction
    /** Whether the next tap keeps (true) or leaves out. */
    data class KeepNext(val keep: Boolean) : EditAction
    data object UndoKeepTap : EditAction
    /** Runs the tracked cut-out (its price is on the button: one run per press). */
    data object RunTapToKeep : EditAction
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
    data class AddAudio(val upload: String, val durationSec: Double, val voiceOver: Boolean, val atSec: Double? = null) : EditAction
    /** Detach audio: the clip's own sound becomes its own clip on the "Clip sound" lane; the video clip goes silent. */
    data object DetachAudio : EditAction
    /** The selected clip's (or the clip under the playhead's) sound on / off. */
    data class MuteClip(val muted: Boolean) : EditAction
    // Text & captions
    data class AddHook(val id: String) : EditAction
    data class EditText(val id: String, val text: String) : EditAction
    /** New plain text at the playhead (selected, so its style shows). */
    data object AddText : EditAction
    /** The selected text's whole style ([done] false while a slider moves). */
    data class SetTextStyle(val id: String, val style: studio.muse.core.edit.TextStyle, val done: Boolean = true) : EditAction
    /** The selected text's or image's in / out animation (null = none). */
    data class SetAnim(val id: String, val animIn: studio.muse.core.edit.Anim?, val animOut: studio.muse.core.edit.Anim?, val done: Boolean = true) : EditAction
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
    /** Tablet track headers (plans/edit-layout.md): a track's sound on / off, and a picture track shown / hidden. */
    data class ToggleTrackMuted(val trackId: String) : EditAction
    data class ToggleTrackHidden(val trackId: String) : EditAction
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
    /** The owner's model for a helper ([purpose] captions / matte / track / denoise; null = the studio's default). */
    data class PickModel(val purpose: String, val model: String?) : EditAction
    /** Another take added whole to the end of the video. */
    data class AppendTake(val take: TakeChoice) : EditAction
    /** The clips on screen at the playhead arranged in a split-screen layout. */
    data class SplitScreen(val layout: SuiteOps.SplitLayout) : EditAction
    /** Main clips cut to end on the music's beats ([SuiteOps.syncToBeats]). */
    data object CutToBeats : EditAction
    /** Spoken clips evened out to one level ([SuiteOps.evenVolume]) from the decoded sound levels. */
    data class EvenVolume(val waves: Map<String, Peaks>) : EditAction
    /** The selected clip moved between the main track and an overlay track (plans/edit-parity.md, S). */
    data object SwapTrack : EditAction
    /** A video imported from a link (or picked from the phone), added at the end. */
    data class AppendUpload(val upload: String, val durationSec: Double, val width: Int? = null, val height: Int? = null, val hasAudio: Boolean? = true) : EditAction
    /** Green/blue screen on the selected video: the key colour and how much around it goes (null = off). */
    data class SetChroma(val chroma: studio.muse.core.edit.Chroma?, val done: Boolean = true) : EditAction
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
        is EditAction.Trim, is EditAction.TrimBy -> "Trim"; is EditAction.MoveBy -> "Move"; is EditAction.Reorder -> "Reorder"; EditAction.DetachAudio -> "Detach audio"; is EditAction.MuteClip -> if (a.muted) "Mute" else "Unmute"
        is EditAction.Speed, is EditAction.CurvePreset, is EditAction.CurvePoint, is EditAction.AddCurvePoint -> "Speed"
        is EditAction.SetTransform -> "Transform"; is EditAction.AddKeyframe, is EditAction.RemoveKeyframes, is EditAction.KeyEase -> "Keyframe"; is EditAction.SetOpacity -> "Opacity"; is EditAction.Background, is EditAction.Fill -> "Background";
        is EditAction.Mirror -> "Mirror"; EditAction.MarkBeat, EditAction.ClearBeats -> "Beats"; is EditAction.AddTakeSound -> "Sound"; EditAction.LoopAudio -> "Loop"; is EditAction.CaptionWordText -> "Caption word"; is EditAction.Slip -> "Slip"; is EditAction.ReplaceClip -> "Replace"; is EditAction.SetBlend -> "Blend"; is EditAction.Freeze, is EditAction.HoldLength -> "Freeze frame"; is EditAction.ClipFit -> "Fit"; is EditAction.SetMask -> "Mask"; is EditAction.SetCrop -> "Crop"
        EditAction.RemoveBackground, EditAction.KeepBackground -> "Remove background"; is EditAction.SetTransition, EditAction.TransitionToAll -> "Transition"
        is EditAction.Volume -> "Volume"; is EditAction.Fades -> "Fades"; is EditAction.AutoDuck, is EditAction.DuckTimes -> "Ducking"
        is EditAction.NoiseReduction -> "Noise reduction"; is EditAction.Enhance -> "Enhance voice"; is EditAction.Voice -> "Voice effect"
        EditAction.DetectBeats -> "Beats"; is EditAction.AddAudio -> if (a.voiceOver) "Voice-over" else "Music"
        is EditAction.AddHook -> "Hook"; is EditAction.EditText, EditAction.AddText, is EditAction.SetTextStyle -> "Text"; is EditAction.SetAnim -> "Animation"; EditAction.AutoCaptions -> "Captions"
        is EditAction.CaptionStyleOf, is EditAction.CaptionFont, is EditAction.CaptionColors, is EditAction.CaptionY,
        is EditAction.CaptionWordsPerPage, is EditAction.WordHighlight -> "Caption style"
        is EditAction.DeleteWord -> "Cut word"; EditAction.CutSilences -> "Cut silences"; EditAction.RemoveFillers -> "Remove fillers"
        is EditAction.ToggleTrackMuted -> "Mute track"; is EditAction.ToggleTrackHidden -> "Hide track"
        is EditAction.PickLook, is EditAction.LookStrength, EditAction.LookToAll, is EditAction.ImportedCube -> "Look"
        is EditAction.AdjustField -> "Adjust"; is EditAction.AddPip -> "Overlay"; is EditAction.AppendTake, is EditAction.AppendUpload -> "Add clip"; EditAction.SwapTrack -> "Move clip"; EditAction.CutToBeats -> "Cut to beats"; is EditAction.SplitScreen -> "Split screen"; is EditAction.EvenVolume -> "Even out volume"; is EditAction.SetChroma -> "Chroma key"; is EditAction.Ratio, is EditAction.ExportOf -> "Ratio"
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
            is EditAction.Scrub -> _ui.update {
                val fps = it.project?.canvas?.fps ?: 30.0
                val t = if (a.end) TimelineMath.snapFrame(a.sec, fps) else a.sec
                it.copy(playheadSec = t.coerceIn(0.0, it.duration), playing = false, scrubbing = !a.end)
            }
            is EditAction.MoveBy -> {
                val base = dragBase ?: project ?: return
                val next = SuiteOps.moveBy(base, a.itemId, a.deltaSec, snapPoints(base, a.itemId, u), a.snapSec)
                if (next == null) { if (a.done) endDrag() } else change(a.done, "That doesn't fit there · try another spot") { next }
            }
            is EditAction.Reorder -> {
                val next = SuiteOps.reorder(dragBase ?: project ?: return, a.clipId, a.toIndex)
                if (next == null) { if (a.done) endDrag() } else change(a.done) { next }
            }
            is EditAction.TrimBy -> {
                val next = SuiteOps.trimBy(dragBase ?: project ?: return, a.itemId, a.left, a.deltaSec)
                if (next == null) { if (a.done) endDrag() } else change(a.done, "That doesn't fit there") { next }
            }
            is EditAction.Trim -> {
                // Lifting the finger where the last move left it is no change: the drag just ends as one step.
                val next = project?.trimClip(a.clipId, a.inSec, a.outSec)
                if (next == null) { if (a.done) endDrag() } else change(a.done, "The edit must stay at least 0.5 s long") { next }
            }
            EditAction.DetachAudio -> {
                val c = (u.selection?.second as? VideoClip)?.takeIf { sel -> project?.main?.items?.any { it.id == sel.id } == true } ?: u.activeClip ?: return
                val p0 = project ?: return
                val why = when {
                    !SuiteOps.hasSound(p0, c) -> "This clip has no sound"
                    c.muted == true -> "This clip's sound is off · turn it on to detach it"
                    c.speedCurve != null || c.speed != 1.0 -> "Set the clip to 1× to detach its sound"
                    else -> "Couldn't detach the sound here"
                }
                var newId: String? = null
                if (change(refused = why) { p -> SuiteOps.detachAudio(p, c.id)?.let { (np, id) -> newId = id; np } }) {
                    _ui.update { it.copy(selectedId = newId) }
                    say("Sound detached · it's on its own lane now")
                }
            }
            is EditAction.MuteClip -> { val c = soundClip(u) ?: return; change { p -> p.updateItem(c.id) { when (it) { is VideoClip -> it.copy(muted = if (a.muted) true else null); is studio.muse.core.edit.AudioClip -> it.copy(muted = if (a.muted) true else null); else -> it } } } }
            is EditAction.Zoom -> _ui.update { it.copy(pxPerSec = a.pxPerSec.coerceIn(8f, 240f)) }
            is EditAction.Select -> _ui.update { it.copy(selectedId = a.id) }
            is EditAction.Open -> open(a.panel)
            is EditAction.SafeAreaOf -> _ui.update { it.copy(safeArea = a.area) }
            EditAction.Fullscreen -> _ui.update { it.copy(fullscreen = !it.fullscreen) }
            is EditAction.InspectorHidden -> _ui.update { it.copy(inspectorHidden = a.hidden) }
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
            is EditAction.SetTransform -> setTransform(u, a)
            is EditAction.SetOpacity -> setOpacity(u, a)
            is EditAction.RemoveKeyframes -> {
                val id = transformId(u) ?: return
                val local = localAt(u, id) ?: return say("Move the playhead over this item")
                if (!change { SuiteOps.removeKeysAt(it, id, local, a.prop) }) say("No keyframe at the playhead")
            }
            is EditAction.KeyEase -> {
                _ui.update { it.copy(keyEase = a.ease) }
                val id = transformId(u) ?: return
                val local = localAt(u, id) ?: return
                change { SuiteOps.easeAt(it, id, local, a.ease) }
            }
            is EditAction.Mirror -> {
                val id = transformId(u) ?: return
                change { p -> p.updateItem(id) { it ->
                    val tr = when (it) { is studio.muse.core.edit.Visual -> it.transform; is TextItem -> it.transform; else -> null } ?: Transform()
                    withTransform(it, tr.copy(flipX = (a.x ?: (tr.flipX == true)).takeIf { v -> v }, flipY = (a.y ?: (tr.flipY == true)).takeIf { v -> v }))
                } }
            }
            EditAction.MarkBeat -> {
                val p0 = project ?: return
                val (t, m) = SuiteOps.musicAt(p0, u.playheadSec, u.selectedId) ?: return say("Move the playhead over the music to mark a beat")
                val sp = itemSpan(p0, t, m)
                val src = r3(clipSourceAt(m, u.playheadSec - sp.startSec))
                change { p -> p.updateItem(m.id) { (it as AudioClip).copy(beats = ((it.beats ?: emptyList()).filter { b -> kotlin.math.abs(b - src) > 0.02 } + src).sorted()) } }
            }
            EditAction.ClearBeats -> {
                val (_, m) = SuiteOps.musicAt(project ?: return, u.playheadSec, u.selectedId) ?: return
                change { p -> p.updateItem(m.id) { (it as AudioClip).copy(beats = null, strongBeats = null) } }
            }
            is EditAction.AddTakeSound -> {
                val dur = a.take.durationSec ?: return
                var newId: String? = null
                if (change(refused = "No room for that sound there") { p -> SuiteOps.addTakeSound(p, a.take.id, dur, u.playheadSec)?.let { (np, id) -> newId = id; np } }) {
                    _ui.update { it.copy(selectedId = newId) }; say("Sound added · on the sound effects lane")
                }
            }
            EditAction.LoopAudio -> {
                val id = (u.selection?.second as? AudioClip)?.id ?: return say("Select a sound on the timeline to loop it")
                if (change(refused = "Nothing to loop: it already reaches the end") { p -> SuiteOps.loopToEnd(p, id) }) say("Looped to the end")
            }
            is EditAction.CaptionWordText -> {
                val text = a.text.trim().take(60)
                if (text.isEmpty()) return
                change { p -> p.copy(tracks = p.tracks.map { t -> t.caption?.let { cap -> if (a.index !in cap.words.indices) t else t.copy(caption = cap.copy(words = cap.words.toMutableList().apply { set(a.index, get(a.index).copy(text = text)) })) } ?: t }) }
            }
            is EditAction.Slip -> {
                val c = (u.selection?.second as? VideoClip)?.takeIf { s -> project?.main?.items?.any { it.id == s.id } == true } ?: u.activeClip ?: return
                if (c.holdSec != null) return
                val len = c.outSec - c.inSec
                val dur = project?.asset(c.asset)?.durationSec ?: return
                val i = r3(a.inSec.coerceIn(0.0, maxOf(0.0, dur - len)))
                change(a.done) { p -> p.updateItem(c.id) { (it as VideoClip).copy(inSec = i, outSec = r3(i + len)) } }
            }
            is EditAction.ReplaceClip -> {
                val c = (u.selection?.second as? VideoClip)?.takeIf { s -> project?.main?.items?.any { it.id == s.id } == true } ?: u.activeClip ?: return
                val dur = a.take.durationSec ?: return say("That video has no length yet")
                if (change(refused = "That video is too short to replace this clip") { p -> SuiteOps.replaceClip(p, c.id, a.take.id, dur) }) say("Clip replaced · its edits stay")
            }
            is EditAction.SetBlend -> {
                val (t, item) = u.selection ?: return say("Pick an overlay to blend")
                if (t.kind != TrackKind.VIDEO && t.kind != TrackKind.IMAGE) return say("Only overlays blend with what is below them")
                val b = a.mode.takeIf { it != studio.muse.core.edit.BlendMode.NORMAL }
                change { p -> p.updateItem(item.id) { when (it) { is VideoClip -> it.copy(blend = b); is ImageItem -> it.copy(blend = b); else -> it } } }
            }
            is EditAction.Freeze -> {
                var newId: String? = null
                if (change(refused = "Move the playhead over a clip to freeze a frame") { p -> p.freezeAt(u.playheadSec, a.durationSec)?.let { (np, id) -> newId = id; np } }) {
                    _ui.update { it.copy(selectedId = newId) }
                    say("Freeze frame added · drag its edge to change its length")
                }
            }
            is EditAction.HoldLength -> {
                val c = (u.selection?.second as? VideoClip)?.takeIf { it.holdSec != null } ?: return
                change(a.done) { p -> p.updateItem(c.id) { (it as VideoClip).copy(holdSec = r2(a.sec.coerceIn(studio.muse.core.edit.HOLD_MIN_SEC, studio.muse.core.edit.HOLD_MAX_SEC))) } }
            }
            is EditAction.Fill -> change { p -> val f = a.fill.takeIf { it == studio.muse.core.edit.CanvasFill.BLUR }; if (p.canvas.fill == f) null else p.copy(canvas = p.canvas.copy(fill = f)) }
            is EditAction.ClipFit -> {
                val c = (u.selection?.second as? VideoClip)?.takeIf { s -> project?.main?.items?.any { it.id == s.id } == true } ?: u.activeClip ?: return
                change { p -> p.updateItem(c.id) { (it as VideoClip).copy(fit = a.fit.takeIf { f -> f == studio.muse.core.edit.Fit.CONTAIN }) } }
            }
            is EditAction.StepFrame -> { val fps = u.project?.canvas?.fps ?: 30.0; act(EditAction.Scrub(TimelineMath.snapFrame(u.playheadSec, fps) + a.frames / fps, end = true)) }
            is EditAction.Background -> change { p -> if (p.canvas.background.equals(a.color, true)) null else p.copy(canvas = p.canvas.copy(background = a.color)) }
            is EditAction.AddKeyframe -> addKeyframe(u, a.prop)
            is EditAction.SetMask -> { val id = visualId(u) ?: return; change(a.done) { p -> p.updateItem(id) { when (it) { is VideoClip -> it.copy(mask = a.mask); is ImageItem -> it.copy(mask = a.mask); else -> it } } } }
            is EditAction.SetCrop -> {
                val id = visualId(u) ?: return
                val c = a.crop?.let { k -> studio.muse.core.edit.Crop(k.left?.let { r2(it.coerceIn(0.0, .45)) }, k.top?.let { r2(it.coerceIn(0.0, .45)) }, k.right?.let { r2(it.coerceIn(0.0, .45)) }, k.bottom?.let { r2(it.coerceIn(0.0, .45)) }) }
                    ?.takeIf { k -> listOf(k.left, k.top, k.right, k.bottom).any { (it ?: 0.0) > 0 } }
                change(a.done) { p -> p.updateItem(id) { when (it) { is VideoClip -> it.copy(crop = c); is ImageItem -> it.copy(crop = c); else -> it } } }
            }
            EditAction.RemoveBackground -> if (u.matteOff == null) removeBackground(u, null)
            EditAction.KeepBackground -> u.activeClip?.takeIf { it.alphaMatte != null }?.let { clip ->
                change { pp -> pp.updateItem(clip.id) { (it as VideoClip).copy(alphaMatte = null) } }
            }
            is EditAction.TapToKeep -> if (u.matteOff == null || !a.on) {
                if (u.playing && a.on) act(EditAction.PlayPause) // taps go on a paused frame
                _ui.update { it.copy(keep = if (a.on) KeepUi() else null) }
            }
            is EditAction.KeepTapAt -> keepTap(u, a.x, a.y)
            is EditAction.KeepNext -> _ui.update { it.copy(keep = it.keep?.copy(keepNext = a.keep)) }
            EditAction.UndoKeepTap -> { _ui.update { it.copy(keep = it.keep?.copy(taps = it.keep.taps.dropLast(1))) }; estimateKeep() }
            EditAction.RunTapToKeep -> {
                val k = u.keep ?: return
                if (!k.ready) return say("Tap at least one thing to keep")
                removeBackground(u, k.taps)
            }
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
            is EditAction.EffectsTab -> { _ui.update { it.copy(effectsTab = a.tab) }; if (a.tab == "Mask") matteTab() }

            is EditAction.Volume -> {
                val c = soundClip(u) ?: return
                val gain = SuiteOps.dbToGain(a.db).coerceIn(0.0, 2.0)
                val keys = c.keyframes?.get(KfProp.VOLUME)
                val local = localAt(u, c.id)
                // Volume keyframed: the slider sets the key at the playhead (keys multiply the clip's own volume).
                if (!keys.isNullOrEmpty() && local != null) change(a.done) { p -> SuiteOps.keyframe(p, c.id, KfProp.VOLUME, local, r2((gain / (c.volume ?: 1.0).coerceAtLeast(.01)).coerceIn(0.0, 2.0)), u.keyEase) }
                else change(a.done) { p -> p.updateItem(c.id) { setVolume(it, gain) } }
            }
            is EditAction.Fades -> { val c = soundClip(u) ?: return; change(a.done) { p -> p.updateItem(c.id) { setFades(it, a.inSec, a.outSec) } } }
            is EditAction.AutoDuck -> if (SuiteOps.musicTrack(project ?: return) == null) say("Add music first · Audio → Music") else change { SuiteOps.duck(it, a.on) }
            is EditAction.DuckTimes -> change(a.done) { p -> val t = SuiteOps.musicTrack(p) ?: return@change null; val d = t.duck ?: return@change null
                p.updateTrack(t.id) { it.copy(duck = d.copy(attackSec = r2(a.attackSec.coerceIn(0.05, 2.0)), releaseSec = r2(a.releaseSec.coerceIn(0.05, 3.0)))) } }
            is EditAction.NoiseReduction -> u.helpersOff["denoise"]?.takeIf { a.on }?.let { say(it) } ?: noiseReduction(u, a.on)
            is EditAction.Enhance -> { val c = soundClip(u) ?: return; change { p -> p.updateItem(c.id) { setVoice(it, enhance = a.on) } } }
            is EditAction.Voice -> { val c = soundClip(u) ?: return; change { p -> p.updateItem(c.id) { setVoice(it, effect = a.effect) } } }
            is EditAction.Beats -> _ui.update { it.copy(beatMarks = a.marks) }
            is EditAction.SnapToBeats -> _ui.update { it.copy(snapToBeats = a.on) }
            EditAction.DetectBeats -> detectBeats()
            is EditAction.AddAudio -> {
                val at = a.atSec ?: if (a.voiceOver) u.playheadSec else 0.0
                if (change(refused = "Couldn't add that audio") { SuiteOps.addAudio(it, a.upload, a.durationSec, at, if (a.voiceOver) TrackKind.VOICE else TrackKind.MUSIC) })
                    say(if (a.voiceOver) "Voice-over added" else "Music added")
            }

            is EditAction.AddHook -> {
                val hook = Presets.hook(a.id) ?: return
                var newId: String? = null
                if (change(refused = "No room for text there") { p -> SuiteOps.addHook(p, hook, u.playheadSec)?.let { (np, id) -> newId = id; np } }) _ui.update { it.copy(selectedId = newId) }
            }
            EditAction.AddText -> {
                var newId: String? = null
                if (change(refused = "No room for text there") { p -> SuiteOps.addText(p, u.playheadSec)?.let { (np, id) -> newId = id; np } }) _ui.update { it.copy(selectedId = newId) }
            }
            is EditAction.SetTextStyle -> change(a.done, "That style can't be used") { p -> p.updateItem(a.id) { (it as? TextItem)?.copy(style = a.style) ?: it } }
            is EditAction.SetAnim -> change(a.done, "That animation is too long for the item") { p ->
                p.updateItem(a.id) { when (it) { is TextItem -> it.copy(animIn = a.animIn, animOut = a.animOut); is ImageItem -> it.copy(animIn = a.animIn, animOut = a.animOut); else -> it } }
            }
            is EditAction.EditText -> change(done = true) { p -> p.updateItem(a.id) { (it as? TextItem)?.copy(text = a.text.take(500).ifBlank { it.text }) ?: it } }
            EditAction.AutoCaptions -> u.helpersOff["captions"]?.let { say(it) } ?: autoCaptions()
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
            is EditAction.ToggleTrackMuted -> change { pp -> pp.copy(tracks = pp.tracks.map { t -> if (t.id == a.trackId) t.copy(muted = if (t.muted == true) null else true) else t }) }
            is EditAction.ToggleTrackHidden -> change { pp -> pp.copy(tracks = pp.tracks.map { t -> if (t.id == a.trackId) t.copy(hidden = if (t.hidden == true) null else true) else t }) }
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
            is EditAction.PickModel -> {
                _ui.update { it.copy(helperModels = it.helperModels + (a.purpose to a.model)) }
                // The price may change with the model: ask again.
                when (a.purpose) {
                    "captions" -> { if (u.captionTrack == null) estimate("captions") }
                    "matte" -> estimate("matte")
                    "track" -> estimateKeep()
                    "denoise" -> estimate("denoise")
                }
            }
            is EditAction.AppendTake -> {
                var newId: String? = null
                if (change(refused = "That video can't be added at the end") { p -> SuiteOps.appendTake(p, a.take.id, a.take.durationSec ?: return@change null)?.let { (np, id) -> newId = id; np } }) {
                    _ui.update { it.copy(selectedId = newId) }
                    say("Added to the end")
                }
            }
            is EditAction.SplitScreen -> {
                val p0 = project ?: return
                val ids = SuiteOps.clipsAt(p0, u.playheadSec).map { it.id }
                if (ids.size < 2) return say("Add an overlay at the playhead first · split screen needs two or more clips on screen")
                if (change(refused = "These clips can't be cropped to that layout") { p -> SuiteOps.splitScreen(p, ids, a.layout) })
                    say(a.layout.label)
            }
            EditAction.CutToBeats -> {
                val beats = project?.let { SuiteOps.beatTimes(it, false) }.orEmpty()
                if (beats.isEmpty()) return say("Detect beats in Audio first")
                var n = 0
                if (change(refused = "The clips already end on beats") { p -> SuiteOps.syncToBeats(p, beats)?.let { (q, k) -> n = k; q } })
                    say(if (n == 1) "1 clip now ends on a beat" else "$n clips now end on beats")
            }
            is EditAction.EvenVolume -> {
                var n = 0
                if (change(refused = "Nothing to even out · it needs two or more clips with sound") { p -> SuiteOps.evenVolume(p, a.waves)?.let { (q, k) -> n = k; q } })
                    say(if (n == 1) "Volume evened out on 1 clip" else "Volume evened out on $n clips")
            }
            EditAction.SwapTrack -> {
                val id = (u.selection?.second as? VideoClip)?.id ?: u.activeClip?.id ?: return
                val p0 = project ?: return
                val onMain = p0.locate(id)?.first?.kind == TrackKind.MAIN
                if (change(refused = if (onMain) "The main track needs at least one clip" else "That clip can't go on the main track") { p -> if (onMain) SuiteOps.toOverlay(p, id) else SuiteOps.toMain(p, id) }) {
                    _ui.update { it.copy(selectedId = id) }
                    say(if (onMain) "Moved to an overlay track" else "Moved to the main track")
                }
            }
            is EditAction.AppendUpload -> {
                var newId: String? = null
                if (change(refused = "That video can't be added at the end") { p -> SuiteOps.appendUpload(p, a.upload, a.durationSec, a.width, a.height, a.hasAudio)?.let { (np, id) -> newId = id; np } }) {
                    _ui.update { it.copy(selectedId = newId) }
                    say("Added to the end")
                }
            }
            is EditAction.SetChroma -> {
                val id = (u.selection?.second as? VideoClip ?: u.activeClip)?.id ?: return
                val k = a.chroma?.let { c -> c.copy(similarity = c.similarity?.let { r2(it.coerceIn(0.0, 1.0)) }, smoothness = c.smoothness?.let { r2(it.coerceIn(0.0, 1.0)) }, spill = c.spill?.let { r2(it.coerceIn(0.0, 1.0)) }) }
                change(a.done) { p -> p.updateItem(id) { (it as? VideoClip)?.copy(chroma = k) ?: it } }
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
            Panel.CAPTIONS -> { checkHelpers { if (_ui.value.captionTrack == null && "captions" !in _ui.value.helpersOff) estimate("captions") }; estimate("cuts", silenceOnly()) }
            Panel.AUDIO -> { checkHelpers { if ("denoise" !in _ui.value.helpersOff) estimate("denoise") }; if (SuiteOps.musicTrack(project ?: return) != null) estimate("beats", source = musicSource()) }
            Panel.EFFECTS -> if (_ui.value.effectsTab == "Mask") matteTab()
            Panel.SPEED -> _ui.update { it.copy(speedCurveTab = it.activeClip?.speedCurve != null) }
            else -> {}
        }
    }

    private var helpersChecked = false

    /**
     * Which paid helpers can run (asked once per editor), then [then]. While the server says one can't (the owner
     * switched paid helpers off, or the cut-out is still the mock), it reads as a plain line and nothing is priced.
     */
    private fun checkHelpers(then: () -> Unit) {
        if (helpersChecked) { then(); return }
        helpersChecked = true
        scope.launch {
            val off = runCatching { backend.helpersOff() }.getOrDefault(emptyMap())
            _ui.update { it.copy(helpersOff = off, matteOff = off["matte"], keep = if (off["matte"] != null) null else it.keep) }
            then()
        }
    }

    /** The Mask tab: background removal's availability, then its price. */
    private fun matteTab() = checkHelpers { if (_ui.value.matteOff == null) estimate("matte") }

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

    private fun aiKey(kind: String, options: JsonObject?) = when {
        kind == "cuts" && options?.get("silenceOnly") != null -> "silences"
        kind == "matte" && options?.get("points") != null -> "matte_keep" // tap to keep has its own price
        else -> kind
    }

    /** Which model list a helper runs on (WS13): captions and cuts → captions, matte → matte (with tapped points → track), denoise. */
    fun helperPurpose(kind: String, options: JsonObject?): String? = when (kind) {
        "captions", "cuts" -> "captions"
        "matte" -> if (options?.containsKey("points") == true) "track" else "matte"
        "denoise" -> "denoise"
        else -> null
    }

    /** Fetches what a helper costs, for its button ("about $0.02" / "Free"). */
    fun estimate(kind: String, options: JsonObject? = null, source: EditorSourceDto? = mainSource()) {
        val src = source ?: return
        val key = aiKey(kind, options)
        if (_ui.value.ai[key]?.running == true) return
        scope.launch {
            val model = _ui.value.helperModels[helperPurpose(kind, options)]
            val (e, err) = if (model == null) backend.estimate(kind, src, options) else backend.estimate(kind, src, options, model)
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
            val model = _ui.value.helperModels[helperPurpose(kind, options)]
            val progress: (EditorJob) -> Unit = { j -> setAi(key) { it.copy(progress = j.progress, phase = j.phase) } }
            // No pick: the studio's default (the original call); a pick goes with the model-aware one (WS13).
            val (result, err) = if (model == null) backend.run(kind, src, options, progress) else backend.run(kind, src, options, model, progress)
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

    /** Tap to keep: a tap at the playhead's source time of the clip being cut out (1–10 taps). */
    private fun keepTap(u: EditSuiteUi, x: Double, y: Double) {
        val k = u.keep ?: return
        if (k.taps.size >= 10) return say("Ten taps at most · undo one first")
        val p = project ?: return
        val clip = u.activeClip ?: return
        val span = itemSpan(p, p.main, p.main.items.firstOrNull { it.id == clip.id } ?: return)
        val t = (clip.inSec + (u.playheadSec - span.startSec).coerceAtLeast(0.0) * clip.speed).coerceIn(clip.inSec, clip.outSec)
        _ui.update { it.copy(keep = k.copy(taps = k.taps + KeepTap(x.coerceIn(0.0, 1.0), y.coerceIn(0.0, 1.0), Math.round(t * 1000) / 1000.0, k.keepNext))) }
        estimateKeep()
    }

    private fun keepOptions(taps: List<KeepTap>): JsonObject = buildJsonObject {
        put("points", buildJsonArray {
            taps.forEach { tp -> add(buildJsonObject { put("x", tp.x); put("y", tp.y); put("t", tp.t); put("keep", tp.keep) }) }
        })
    }

    /** The tracked cut-out's price, once there is something to keep (its own price: plans/api.md). */
    private fun estimateKeep() {
        val k = _ui.value.keep ?: return
        if (!k.ready) return
        val clip = _ui.value.activeClip ?: return
        estimate("matte", keepOptions(k.taps), sourceOf(project?.asset(clip.asset)))
    }

    /**
     * Remove background (workstream 1): the person ([taps] null), or what the owner tapped (tracked). The result is an
     * alpha matte: the original clip gets `alphaMatte {asset}` (its chroma key goes) and the matte joins the project's
     * assets; the device fetches it to render. An older server's green composite still goes on a keyed overlay track.
     */
    private fun removeBackground(u: EditSuiteUi, taps: List<KeepTap>?) {
        val p = project ?: return
        val clip = u.activeClip ?: return
        val src = sourceOf(p.asset(clip.asset))
        runAi("matte", taps?.let(::keepOptions), src) { r ->
            val a = r["asset"] as? JsonObject ?: return@runAi
            val upload = (a["upload"] as? JsonPrimitive)?.content
            val take = (a["take"] as? JsonPrimitive)?.content
            val url = (a["url"] as? JsonPrimitive)?.content
            val alpha = (r["alpha"] as? JsonPrimitive)?.content == "true"
            var matteId: String? = null
            if (alpha) {
                change { pp ->
                    val id = SuiteOps.newAssetId(pp, "matte").also { matteId = it }
                    val withAsset = pp.copy(assets = pp.assets + Asset(id, AssetKind.VIDEO, take = take, upload = if (take == null) upload else null,
                        durationSec = (a["durationSec"] as? JsonPrimitive)?.doubleOrNull, hasAudio = false))
                    withAsset.updateItem(clip.id) { it2 -> (it2 as VideoClip).copy(alphaMatte = AlphaMatte(id), chroma = null) }
                }
                _ui.update { it.copy(keep = null) }
                say(if (taps != null) "Cut out · what you tapped stays" else "Background removed")
            } else {
                val ch = r["chroma"] as? JsonObject
                val chroma = Chroma((ch?.get("color") as? JsonPrimitive)?.content ?: "#00FF00", (ch?.get("similarity") as? JsonPrimitive)?.doubleOrNull,
                    (ch?.get("smoothness") as? JsonPrimitive)?.doubleOrNull, (ch?.get("spill") as? JsonPrimitive)?.doubleOrNull)
                change { pp ->
                    // An older server: the cut-out person goes on an overlay track over the same span of the timeline, keyed.
                    val id = SuiteOps.newAssetId(pp, "matte").also { matteId = it }
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
            val id = matteId
            if (id != null && url != null) backend.assetArrived(id, url)
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
                if (a.field in LOOK_FIELDS) {
                    // The look's effects (plans/video-editor.md "Looks"): 0 removes the effect.
                    val l = vis.look ?: Look()
                    val pos = v.coerceIn(0.0, 1.0).takeIf { n -> n > 0.0 }
                    val look = when (a.field) {
                        "grain" -> l.copy(grain = pos?.let { Grain(it, l.grain?.size) })
                        "vignette" -> l.copy(vignette = v.coerceIn(-1.0, 1.0).takeIf { n -> n != 0.0 }?.let { studio.muse.core.edit.Vignette(it, l.vignette?.size, l.vignette?.softness) })
                        "sharpen" -> l.copy(sharpen = pos)
                        "fade" -> l.copy(lift = pos)
                        "chromatic" -> l.copy(chromatic = pos)
                        "halation" -> l.copy(halation = pos?.let { studio.muse.core.edit.Halation(it, l.halation?.radius, l.halation?.threshold) })
                        "leak" -> l.copy(leak = pos?.let { studio.muse.core.edit.Leak(l.leak?.kind ?: studio.muse.core.edit.LeakKind.WARM, it, l.leak?.angle) })
                        else -> l
                    }.takeIf { n -> n != Look() }
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

    /** The item the Transform panel acts on: the selected picture or text, else the clip under the playhead. */
    private fun transformId(u: EditSuiteUi): String? = (u.selection?.second?.takeIf { it is studio.muse.core.edit.Visual || it is TextItem } ?: u.activeClip)?.id

    /** Seconds from item [id]'s start to the playhead, or null when the playhead isn't over it. */
    private fun localAt(u: EditSuiteUi, id: String): Double? {
        val p = project ?: return null
        val (t, i) = p.locate(id) ?: return null
        val sp = itemSpan(p, t, t.items[i])
        return if (u.playheadSec < sp.startSec - 1e-6 || u.playheadSec > sp.endSec + 1e-6) null else u.playheadSec - sp.startSec
    }

    /** Position/scale/rotation: a keyframed property gets a key at the playhead (else the static value changes). */
    private fun setTransform(u: EditSuiteUi, a: EditAction.SetTransform) {
        val id = transformId(u) ?: return
        val p0 = project ?: return
        val item = p0.locate(id)?.let { (t, i) -> t.items[i] } ?: return
        val keys = when (item) { is studio.muse.core.edit.Visual -> item.keyframes; is TextItem -> item.keyframes; else -> null }
        val cur = when (item) { is studio.muse.core.edit.Visual -> item.transform; is TextItem -> item.transform; else -> null } ?: Transform()
        val local = localAt(u, id)
        change(a.done) { p ->
            var n: EditProject = p
            var static = cur
            fun prop(kp: KfProp, old: Double?, new: Double?, def: Double, setStatic: (Transform, Double?) -> Transform) {
                if (new == null || new == (old ?: def)) return
                if (!keys?.get(kp).isNullOrEmpty() && local != null) n = SuiteOps.keyframe(n, id, kp, local, new, u.keyEase) ?: n
                else static = setStatic(static, new)
            }
            prop(KfProp.X, cur.x, a.transform.x, .5) { t, v -> t.copy(x = v) }
            prop(KfProp.Y, cur.y, a.transform.y, .5) { t, v -> t.copy(y = v) }
            prop(KfProp.SCALE, cur.scale, a.transform.scale, 1.0) { t, v -> t.copy(scale = v) }
            prop(KfProp.ROTATION, cur.rotation, a.transform.rotation, 0.0) { t, v -> t.copy(rotation = v) }
            if (static != cur) n = n.updateItem(id) { withTransform(it, static) } ?: n
            n
        }
    }

    private fun setOpacity(u: EditSuiteUi, a: EditAction.SetOpacity) {
        val id = transformId(u) ?: return
        val v = r2(a.opacity.coerceIn(0.0, 1.0))
        val item = project?.locate(id)?.let { (t, i) -> t.items[i] } ?: return
        val keys = when (item) { is studio.muse.core.edit.Visual -> item.keyframes; is TextItem -> item.keyframes; else -> null }
        val local = localAt(u, id)
        if (!keys?.get(KfProp.OPACITY).isNullOrEmpty() && local != null) change(a.done) { SuiteOps.keyframe(it, id, KfProp.OPACITY, local, v, u.keyEase) }
        else change(a.done) { p -> p.updateItem(id) { when (it) { is VideoClip -> it.copy(opacity = v.takeIf { o -> o < 1 }); is ImageItem -> it.copy(opacity = v.takeIf { o -> o < 1 }); is TextItem -> it.copy(opacity = v.takeIf { o -> o < 1 }); else -> it } } }
    }

    private fun addKeyframe(u: EditSuiteUi, prop: KfProp) {
        val p = project ?: return
        if (prop == KfProp.VOLUME) {
            val c = soundClip(u) ?: return
            val local = localAt(u, c.id) ?: return say("Move the playhead over this clip to add a keyframe")
            val v = c.keyframes?.get(KfProp.VOLUME)?.let { studio.muse.core.edit.keyframeValue(it, local) } ?: 1.0
            if (change { SuiteOps.keyframe(it, c.id, prop, local, v, u.keyEase) }) say("Volume keyframe at ${"%.1f".format(local)} s")
            return
        }
        val id = transformId(u) ?: return
        val (t, item) = p.locate(id)?.let { (tr, i) -> tr to tr.items[i] } ?: return
        val span = itemSpan(p, t, item)
        if (u.playheadSec < span.startSec || u.playheadSec > span.endSec) return say("Move the playhead over this clip to add a keyframe")
        val local = u.playheadSec - span.startSec
        val tr = when (item) { is studio.muse.core.edit.Visual -> item.transform; is TextItem -> item.transform; else -> return }
        val keys = when (item) { is studio.muse.core.edit.Visual -> item.keyframes; is TextItem -> item.keyframes; else -> null }
        val op = when (item) { is studio.muse.core.edit.Visual -> item.opacity; is TextItem -> item.opacity; else -> null }
        val static = when (prop) {
            KfProp.X -> tr?.x ?: 0.5; KfProp.Y -> tr?.y ?: 0.5; KfProp.SCALE -> tr?.scale ?: 1.0; KfProp.ROTATION -> tr?.rotation ?: 0.0
            KfProp.OPACITY -> op ?: 1.0; KfProp.VOLUME -> 1.0
        }
        // The value showing now (the curve's, when the property is already keyframed).
        val v = studio.muse.core.edit.propAt(keys, prop, static, local)
        if (change { SuiteOps.keyframe(it, id, prop, local, v, u.keyEase) }) say("Keyframe added at ${"%.1f".format(local)} s")
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

    /** Where a moved item's edges snap: the playhead, every other item's edges, the main clips' cuts and the beats. */
    private fun snapPoints(p: EditProject, movingId: String, u: EditSuiteUi): List<Double> {
        val out = ArrayList<Double>()
        out += u.playheadSec; out += 0.0
        for (t in p.tracks) for (it in t.items) if (it.id != movingId) { val sp = itemSpan(p, t, it); out += sp.startSec; out += sp.endSec }
        out += SuiteOps.beatTimes(p, u.beatMarks == BeatMarks.STRONG)
        return out
    }

    private fun beatsShown(u: EditSuiteUi) = project?.let { SuiteOps.beatTimes(it, u.beatMarks == BeatMarks.STRONG) }.orEmpty()

    companion object {
        fun r2(v: Double) = Math.round(v * 100) / 100.0
        /** Adjust fields that are look effects rather than colour adjustments. */
        val LOOK_FIELDS = setOf("grain", "vignette", "sharpen", "fade", "chromatic", "halation", "leak")
        fun r3(v: Double) = Math.round(v * 1000) / 1000.0

        /** "about $0.02" or "Free" (never a provider or model). */
        fun priceOf(e: EditorEstimate): String = if (e.free || e.usd <= 0.0) "Free" else "about $" + String.format(java.util.Locale.ROOT, "%.2f", e.usd)
    }
}



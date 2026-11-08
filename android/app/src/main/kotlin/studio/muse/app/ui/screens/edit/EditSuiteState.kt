package studio.muse.app.ui.screens.edit

import studio.muse.app.data.ImageRef
import studio.muse.core.edit.CaptionPreset
import studio.muse.core.edit.EditProject
import studio.muse.core.edit.ExportSettings
import studio.muse.core.edit.Item
import studio.muse.core.edit.Track
import studio.muse.core.edit.TrackKind
import studio.muse.core.edit.VideoClip
import studio.muse.core.edit.durationSec
import studio.muse.core.edit.itemSpan

/*
 * Edit suite (designs EM1–EM5, E1–E4): what the editor shows, as plain values, so the screen is a function of
 * [EditSuiteUi] (screenshots render it without a player) and every change goes through [EditSuiteController].
 */

/** The bottom tool row (EM1), in the design's order. */
enum class EditTool(val label: String, val icon: String, val panel: Panel) {
    EDIT("Edit", "scissors", Panel.EDIT), AUDIO("Audio", "music", Panel.AUDIO), TEXT("Text", "type", Panel.TEXT),
    CAPTIONS("Captions", "cc", Panel.CAPTIONS), EFFECTS("Effects", "fx", Panel.EFFECTS), FILTERS("Filters", "palette", Panel.FILTERS),
    OVERLAY("Overlay", "layers", Panel.OVERLAY), RATIO("Ratio", "ratio", Panel.RATIO),
}

/** The bottom sheets. Speed, transform and export open from inside other panels / the top bar. */
enum class Panel(val title: String) {
    EDIT("Edit"), SPEED("Speed"), TRANSFORM("Transform & keyframes"), AUDIO("Audio"), TEXT("Text & hooks"), CAPTIONS("Captions"),
    EFFECTS("Effects"), FILTERS("Filters"), OVERLAY("Overlay"), RATIO("Ratio"), EXPORT("Export"),
    /** Edit sessions (workstream 3): the shared history (Claude's changes badged), owner only. */
    HISTORY("History");

    /** The tool lit in the tool row while this panel is open. */
    val tool: EditTool?
        get() = when (this) {
            EDIT, SPEED, TRANSFORM -> EditTool.EDIT
            AUDIO -> EditTool.AUDIO; TEXT -> EditTool.TEXT; CAPTIONS -> EditTool.CAPTIONS; EFFECTS -> EditTool.EFFECTS
            FILTERS -> EditTool.FILTERS; OVERLAY -> EditTool.OVERLAY; RATIO -> EditTool.RATIO; EXPORT, HISTORY -> null
        }
}

/** Platform safe areas drawn over the preview (UI chrome of each app). */
enum class SafeArea(val label: String, val top: Float, val bottom: Float, val right: Float) {
    TIKTOK("TikTok", .11f, .20f, .16f), REELS("Reels", .10f, .22f, .14f), SHORTS("Shorts", .09f, .18f, .15f),
}

/** An AI helper's row: what it costs (shown before running), whether it runs, how far, and what went wrong. */
data class AiTask(
    val kind: String,
    /** "about $0.02" or "Free"; null while the estimate loads. */
    val price: String? = null,
    val running: Boolean = false,
    val progress: Int = 0,
    val phase: String = "",
    val error: String? = null,
    val done: Boolean = false,
)

sealed interface SuitePhase {
    data class Loading(val progress: Float? = null) : SuitePhase
    data object Ready : SuitePhase
    data class Exporting(val progress: Float) : SuitePhase
    data class Saving(val progress: Float) : SuitePhase
    data class Failed(val message: String, val canRetry: Boolean = true) : SuitePhase
}

/** Which beat marks show and snap (EM3 "All / Strong"). */
enum class BeatMarks { ALL, STRONG }

/** One take the Edit home or the Overlay panel can open / add (a render or an edited version). */
data class TakeChoice(val id: String, val title: String, val label: String, val thumb: ImageRef?, val durationSec: Double?, val edited: Boolean, val hasVideo: Boolean)

/**
 * Edit sessions (workstream 3, plans/claude-editing.md A): what the owner's editor shows about the session it shares
 * with Claude. [history] is newest first (the server's entries; Claude's carry `byClaude`); [pending] are paid helpers
 * Claude asked for, waiting for the owner's yes; [claudeNote] is the "Claude edited this" line ("Claude · Trimmed …").
 */
data class SessionUi(
    val id: String,
    val revision: Int = 0,
    val history: List<studio.muse.app.data.EditHistoryEntry> = emptyList(),
    val pending: List<studio.muse.app.data.EditPending> = emptyList(),
    val claudeNote: String? = null,
    /** The Claude panel (tablet) / sheet (phone) is open. */
    val chatOpen: Boolean = false,
    /** An answer to a pending ask is on its way. */
    val answering: String? = null,
    /**
     * This device has edits the session doesn't (made before it connected) and the session moved on: "Keep this
     * device's changes" / "Use the latest". Nothing is sent until the owner picks.
     */
    val conflict: Boolean = false,
) {
    /** The first paid helper waiting for the owner. */
    val asking: studio.muse.app.data.EditPending? get() = pending.firstOrNull { it.status == "waiting" && it.id != answering }
    /** Claude's recent changes and looks (the Claude panel). */
    val claudeEntries: List<studio.muse.app.data.EditHistoryEntry> get() = history.filter { it.byClaude }
}

/** "about $0.04" for a paid helper Claude asks to run (never a provider or model). */
fun aboutUsd(usd: Double): String = "about $" + String.format(java.util.Locale.ROOT, "%.2f", usd)

/** A look in the picker. */
data class LookChoice(val id: String, val name: String, val category: String)

data class EditSuiteUi(
    val title: String = "",
    val sourceTakeId: String = "",
    val poster: ImageRef? = null,
    val project: EditProject? = null,
    val playheadSec: Double = 0.0,
    val playing: Boolean = false,
    val canUndo: Boolean = false,
    val canRedo: Boolean = false,
    /** The item the edit tools act on (a main clip by default: the one under the playhead). */
    val selectedId: String? = null,
    val panel: Panel? = null,
    val safeArea: SafeArea? = SafeArea.TIKTOK,
    /** Timeline zoom: dp per second (pinch). */
    val pxPerSec: Float = 34f,
    val phase: SuitePhase = SuitePhase.Loading(),
    val ai: Map<String, AiTask> = emptyMap(),
    /** Sheet tabs. */
    val speedCurveTab: Boolean = false,
    val captionTab: String = "Style",
    val effectsTab: String = "Transitions",
    val filtersTab: String = "Looks",
    val lookCategory: String = "all",
    val beatMarks: BeatMarks = BeatMarks.STRONG,
    val snapToBeats: Boolean = false,
    val ripple: Boolean = true,
    val export: ExportSettings = ExportSettings(),
    /** Beat detection's tempo of the music track, when known. */
    val bpm: Double? = null,
    val fullscreen: Boolean = false,
    /** A one-line answer to the last action (refused edits, finished helpers), shown as a toast by the screen. */
    val message: String? = null,
    /** Takes for the Overlay panel (PiP sources). */
    val takes: List<TakeChoice> = emptyList(),
    /** The looks of the bundled pack, in pack order. */
    val looks: List<LookChoice> = emptyList(),
    /**
     * The suite looks the app ships (`palette:<id>` → name, from palettes.json; empty when none are shipped). Not listed
     * in the picker; projects are validated against these ids and a clip's suite look shows as its current look.
     */
    val suiteLooks: Map<String, String> = emptyMap(),
    /** The last .cube import's verdict ("Teal grade · 33³" or the reason it can't be used). */
    val cubeNote: String? = null,
    /** True when the project was reopened from an edited version. */
    val reopened: Boolean = false,
    /** Export finished and saved: the new version's take id. */
    val savedTakeId: String? = null,
    /** Edit sessions (workstream 3): the live session shared with Claude; null for members and when offline/local only. */
    val session: SessionUi? = null,
    /** The owner's editor: the Claude button shows (dimmed until the session is there). */
    val claudeOwner: Boolean = false,
    /** Remove background → tap what to keep (workstream 1's tracked matte): the taps so far, while it is on. */
    val keep: KeepUi? = null,
    /** Background removal can't run yet (the server's `matte.available` is false): the line shown instead. */
    val matteOff: String? = null,
    /** Paid helpers that can't run now (captions, matte, denoise), each with its plain line (WS1 guardrails). */
    val helpersOff: Map<String, String> = emptyMap(),
    /** Tablet (plans/edit-layout.md): the inspector is hidden ("Show inspector" in the top bar). It starts shown. */
    val inspectorHidden: Boolean = false,
) {
    val duration: Double get() = project?.let(::durationSec) ?: 0.0
    val ready: Boolean get() = phase == SuitePhase.Ready && project != null

    /** The selected item and its track. */
    val selection: Pair<Track, Item>? get() {
        val p = project ?: return null
        val id = selectedId ?: return null
        for (t in p.tracks) t.items.firstOrNull { it.id == id }?.let { return t to it }
        return null
    }

    /** The main clip the clip tools act on: the selected one, else the one under the playhead. */
    val activeClip: VideoClip? get() {
        val p = project ?: return null
        (selection?.second as? VideoClip)?.let { return it }
        val main = p.main
        return main.items.firstOrNull { val s = itemSpan(p, main, it); playheadSec >= s.startSec && playheadSec < s.endSec } as VideoClip?
            ?: p.mainClips.lastOrNull()
    }

    val captionTrack: Track? get() = project?.tracks?.firstOrNull { it.kind == TrackKind.CAPTION && it.caption != null }
    val captionPreset: CaptionPreset? get() = captionTrack?.caption?.style?.preset
}

/** One tap on the paused picture: where (0–1 of the frame), when (source seconds of the clip) and whether to keep it. */
data class KeepTap(val x: Double, val y: Double, val t: Double, val keep: Boolean = true)

/** Tap to keep: the taps (1–10, at least one keep) and whether the next tap keeps or leaves out. */
data class KeepUi(val taps: List<KeepTap> = emptyList(), val keepNext: Boolean = true) {
    val ready: Boolean get() = taps.any { it.keep }
}

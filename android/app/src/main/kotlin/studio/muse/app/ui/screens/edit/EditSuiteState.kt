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
    CAPTIONS("Captions", "cc", Panel.CAPTIONS), EFFECTS("Effects", "sparkle", Panel.EFFECTS), FILTERS("Filters", "palette", Panel.FILTERS),
    OVERLAY("Overlay", "layers", Panel.OVERLAY), RATIO("Ratio", "ratio", Panel.RATIO),
}

/** The bottom sheets. Speed, transform and export open from inside other panels / the top bar. */
enum class Panel(val title: String) {
    EDIT("Edit"), SPEED("Speed"), TRANSFORM("Transform & keyframes"), AUDIO("Audio"), TEXT("Text & hooks"), CAPTIONS("Captions"),
    EFFECTS("Effects"), FILTERS("Filters"), OVERLAY("Overlay"), RATIO("Ratio"), EXPORT("Export");

    /** The tool lit in the tool row while this panel is open. */
    val tool: EditTool?
        get() = when (this) {
            EDIT, SPEED, TRANSFORM -> EditTool.EDIT
            AUDIO -> EditTool.AUDIO; TEXT -> EditTool.TEXT; CAPTIONS -> EditTool.CAPTIONS; EFFECTS -> EditTool.EFFECTS
            FILTERS -> EditTool.FILTERS; OVERLAY -> EditTool.OVERLAY; RATIO -> EditTool.RATIO; EXPORT -> null
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

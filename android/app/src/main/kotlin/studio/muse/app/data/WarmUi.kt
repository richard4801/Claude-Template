package studio.muse.app.data

import kotlinx.coroutines.flow.MutableStateFlow

/**
 * App-wide Keep GPU warm prompts (plans/backend.md "Keep GPU warm").
 *
 * - **Nudge** when creating starts: a clip is picked or uploaded in the video studio, or the video studio (Generate)
 *   opens, and no warm GPU is running. Once per creating flow: moving between the flow's screens (New video ↔ Video
 *   studio) never nudges again; leaving the flow (Queue after Generate, Home, ...) ends it, so the next start nudges.
 * - **Confirm** on every manual switch-on, with the same cost warning. There is no "don't ask again".
 * - **Banner**: the 5-minute warning before an idle or cap auto-off, with "Keep warm".
 */
class WarmUi {
    /** "nudge" | "confirm" | null */
    val prompt = MutableStateFlow<String?>(null)
    val banner = MutableStateFlow<WarmWarning?>(null)
    private var flowScreens = 0
    private var startedThisFlow = false

    /** A screen of the creating flow appeared / went away. */
    fun enterFlow() { flowScreens++ }
    fun leaveFlow() {
        flowScreens = (flowScreens - 1).coerceAtLeast(0)
        if (flowScreens == 0) startedThisFlow = false
    }

    /** Creating started (clip picked or uploaded, or Generate opened): nudge once per flow when nothing is warm. */
    fun creatingStarted(warm: WarmGpu?) {
        if (startedThisFlow) return
        startedThisFlow = true
        if (warm != null && !warm.on && warm.allowed && prompt.value == null) prompt.value = NUDGE
    }

    fun confirm() { prompt.value = CONFIRM }
    fun dismiss() { prompt.value = null }

    companion object {
        const val NUDGE = "nudge"
        const val CONFIRM = "confirm"
    }
}

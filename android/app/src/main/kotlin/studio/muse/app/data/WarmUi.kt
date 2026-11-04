package studio.muse.app.data

import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Keep add-on engine ready (was "Keep GPU warm"; plans/api.md "App clean-up" §6): owner-only, switched on in
 * Settings → Engines. There is no nudge any more, and members never see any of this.
 *
 * - **Confirm** on every switch-on, with the cost warning. There is no "don't ask again".
 * - **Banner**: the 5-minute warning before an idle or cap auto-off, with "Keep ready" (owner).
 */
class WarmUi {
    /** [CONFIRM] while the cost warning is open, else null. */
    val prompt = MutableStateFlow<String?>(null)
    val banner = MutableStateFlow<WarmWarning?>(null)

    fun confirm() { prompt.value = CONFIRM }
    fun dismiss() { prompt.value = null }

    companion object {
        const val CONFIRM = "confirm"
    }
}

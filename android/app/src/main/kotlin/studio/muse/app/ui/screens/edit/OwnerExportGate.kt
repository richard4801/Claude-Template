package studio.muse.app.ui.screens.edit

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import studio.muse.core.edit.SessionSync

/**
 * Edit sessions (workstream 3; guardrails in plans/claude-editing.md A): Claude's `export` request never runs on its
 * own. It opens the export sheet with Claude's preset (the AI-label and Content Credentials switches stay as the owner
 * set them) and waits for the owner: their export finishing answers (versionId, null); closing or cancelling the sheet
 * answers (null, the reason).
 */
class OwnerExportGate(private val scope: CoroutineScope, private val controller: EditSuiteController) {
    private var waiting: CompletableDeferred<Pair<String?, String?>>? = null

    /** True while an export Claude asked for waits for the owner. */
    val isWaiting: Boolean get() = waiting?.isActive == true

    suspend fun request(preset: JsonObject?): Pair<String?, String?> {
        waiting?.complete(null to "A newer export request replaced this one")
        val d = CompletableDeferred<Pair<String?, String?>>()
        waiting = d
        controller.update {
            it.copy(export = SessionSync.applyExportPreset(it.export, preset), panel = Panel.EXPORT,
                message = "Claude asked to export this edit · check the settings and tap Export")
        }
        // The sheet closing (not because an export is under way) is the owner's no.
        val watch = scope.launch {
            controller.ui.map { it.panel == Panel.EXPORT || it.phase is SuitePhase.Exporting || it.phase is SuitePhase.Saving }
                .distinctUntilChanged().collect { open -> if (!open) d.complete(null to "The owner closed the export") }
        }
        try { return d.await() } finally { watch.cancel(); if (waiting === d) waiting = null }
    }

    /** The owner's export finished and was saved as [takeId] (call before the sheet closes). */
    fun exported(takeId: String) { waiting?.complete(takeId to null) }

    /** The owner cancelled the export. */
    fun cancelled() { waiting?.complete(null to "The owner cancelled the export") }
}

package studio.muse.app.ui.screens.edit

import androidx.compose.runtime.Composable
import studio.muse.app.ui.screens.VideoEditorScreen

// Entry point of workstream 3 (the Edit suite). Minimal stub: workstream 3 replaces this file at merge with the same
// signature. Until then a take opens the existing on-device video editor; top-level Edit (no take) opens an empty one.

/** Edit (Routes.EDIT, Routes.EDIT_TAKE, and "Edit video" on a take). */
@Composable
fun EditSuiteScreen(takeId: String?, onBack: () -> Unit) {
    VideoEditorScreen(takeId ?: "")
}

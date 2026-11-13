package studio.muse.app.ui.screens.edit

import studio.muse.app.AppContainer
import studio.muse.core.edit.EditPlace
import studio.muse.core.edit.EditRecent
import studio.muse.core.edit.EditRecentEntry
import studio.muse.core.edit.EditRecentItem
import studio.muse.core.edit.PreviewView
import studio.muse.core.edit.RecentSession
import java.io.File

/*
 * Continue a draft (owner, 2026-11-12; plans/edit-continue-draft.md): "When you click on Edit, you should see the last draft
 * you were editing." The owner's recent edits come from the server (they match the Mac), a member's from this phone (their
 * editor is local). The rules are core's [EditRecent].
 */

/** This phone's recent edits (a member's projects; the owner's own record of where each session was left). */
class EditRecentFile(private val file: File) {
    @Synchronized fun load(): List<EditRecentEntry> = EditRecent.decode(runCatching { file.readText() }.getOrNull())
    @Synchronized fun save(e: EditRecentEntry) {
        val next = EditRecent.saved(load(), e)
        runCatching { file.parentFile?.mkdirs(); val tmp = File(file.path + ".tmp"); tmp.writeText(EditRecent.encode(next)); tmp.renameTo(file) }
    }
    companion object { fun of(dir: File) = EditRecentFile(File(dir, "edit-recent.json")) }
}

/** Recent edits, the last worked on first (owner: the server's sessions joined with this phone's record; member: this phone's). */
suspend fun recentEdits(c: AppContainer, dir: File): List<EditRecentItem> {
    val owner = c.repo.demo || c.prefs.value.owner
    val sessions = if (!owner) emptyList() else runCatching { c.repo.api.recentEditSessions(20) }.getOrDefault(emptyList()).map {
        RecentSession(it.id, it.takeId, it.status, it.updatedAt, it.lastTouchedAt, EditPlace.of(it.view),
            emptyBlank = it.takeId == studio.muse.core.edit.BLANK_SOURCE && (it.project["assets"] as? kotlinx.serialization.json.JsonArray).isNullOrEmpty())
    }
    val takes = c.repo.state.value.takes
    return EditRecent.items(sessions, EditRecentFile.of(dir).load()) { id -> takes.firstOrNull { it.id == id }?.title?.takeIf { it.isNotBlank() } }
}

/** Where the editor is now, on top of [base] (fields this app doesn't show, such as the Mac's media bin tab, are kept). */
fun placeOf(u: EditSuiteUi, base: EditPlace?): EditPlace = (base ?: EditPlace()).copy(
    playhead = (u.playheadSec * 1000).let { kotlin.math.round(it) / 1000 },
    zoom = u.pxPerSec.toDouble(),
    tab = u.panel?.takeIf { it != Panel.EXPORT && it != Panel.HISTORY }?.name?.lowercase(),
    selection = u.selectedId,
    safeArea = if (u.preview.view == PreviewView.CLEAN) "off" else u.preview.view.id,
    title = u.title.ifBlank { null },
    at = null,
)

/** Puts the editor back where [p] says (anything the edit no longer has is skipped, so a saved place never breaks opening). */
fun EditSuiteController.restorePlace(p: EditPlace) {
    p.zoom?.let { act(EditAction.Zoom(it.toFloat())) }
    p.selection?.let { id -> if (project?.tracks?.any { t -> t.items.any { it.id == id } } == true) act(EditAction.Select(id)) }
    p.view?.let { v -> act(EditAction.PreviewOf(ui.value.preview.copy(view = v))) }
    p.playhead?.let { act(EditAction.Seek(it)) }
    p.tab?.let { t -> Panel.entries.firstOrNull { it.name.equals(t, ignoreCase = true) && it != Panel.EXPORT && it != Panel.HISTORY }?.let { act(EditAction.Open(it)) } }
}

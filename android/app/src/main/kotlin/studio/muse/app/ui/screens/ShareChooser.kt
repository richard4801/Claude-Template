package studio.muse.app.ui.screens

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import kotlinx.coroutines.flow.update
import studio.muse.app.data.ImportedVideo
import studio.muse.app.data.SharedReference
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.components.Opt
import studio.muse.app.ui.theme.MuseSpace
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.roles

/**
 * Share → MUSE (WS7, owner-approved 2026-11-08): what to do with a shared link or video. "Recreate an edit" is first,
 * and back takes it there too (WS4: a share with no choice made still lands in Recreate). "Use for swap" and "Import to
 * library" import it (platform/LinkPipeline.kt for a link, an upload for a file).
 */
@Composable
fun ShareChooserScreen() {
    val c = LocalContainer.current
    val nav = LocalNav.current
    val shared by c.shared.collectAsState()
    var importing by rememberSaveable { mutableStateOf<String?>(null) } // "swap" | "library"
    val item = shared
    // Nothing shared (already used): back to where the app was.
    if (item == null) { androidx.compose.runtime.LaunchedEffect(Unit) { nav.back() }; return }
    fun recreate() = nav.go(Routes.EDIT) // EditSuiteScreen takes c.shared into Recreate
    fun swap(v: ImportedVideo) {
        c.shared.value = null
        c.drafts.video.update { it.copy(clip = v.asClip()) }
        c.suite.recast.update { it.copy(clipId = v.clipId) }
        nav.go(Routes.SUITE_SWAP)
    }
    BackHandler { recreate() }
    ShareChooserContent(item, onRecreate = ::recreate, onSwap = { importing = "swap" }, onLibrary = { importing = "library" }, onClose = ::recreate)
    importing?.let { what ->
        val purpose = if (what == "swap") ImportPurpose.SWAP else ImportPurpose.LIBRARY
        ImportLinkDialog(purpose, link = (item as? SharedReference.Link)?.url, file = (item as? SharedReference.File)?.uri,
            onClose = { importing = null }, onPickFile = { importing = null; c.shared.value = null; nav.go(Routes.SOURCE) }) { v ->
            importing = null
            if (what == "swap") swap(v) else { c.shared.value = null; c.repo.toast("Imported: ${v.name}"); nav.tab(Routes.GALLERY) }
        }
    }
}

/** The chooser's content: what was shared, then the three ways to use it. */
@Composable
fun ShareChooserContent(item: SharedReference, onRecreate: () -> Unit, onSwap: () -> Unit, onLibrary: () -> Unit, onClose: () -> Unit) {
    val m = muse
    ScreenBox(bg = m.roles.canvas) {
        Column(Modifier.fillMaxSize().testTag("share_chooser")) {
            CalmTopBar("Use this video", onBack = onClose)
            Column(Modifier.padding(horizontal = MuseSpace.gutter), verticalArrangement = Arrangement.spacedBy(MuseSpace.s3)) {
                Caption(when (item) {
                    is SharedReference.Link -> studio.muse.core.edit.SharedLink.name(item.url) + ": " + item.url.removePrefix("https://").removePrefix("www.").take(60)
                    is SharedReference.File -> "A video from your phone"
                }, maxLines = 2)
                Opt("Recreate an edit", "Read its cuts, timing and look, then make it with your characters", icon = "retry", onClick = onRecreate)
                Opt("Use for swap", "Put your character into this video", icon = "user", onClick = onSwap)
                Opt("Import to library", "Keep it for a swap or an edit later", icon = "link", onClick = onLibrary)
            }
        }
    }
}

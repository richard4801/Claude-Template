package studio.muse.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import studio.muse.app.data.ApiException
import studio.muse.app.data.ImportedVideo
import studio.muse.app.data.importFromLink
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.components.Bar
import studio.muse.app.ui.components.RefImage
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.radii
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale

// "Import a video from a link" (WS7, owner-approved 2026-11-08): one screen for every way in (Swap's source, Library,
// Edit's Add, Share → MUSE). The same field, rules line and fallback as Recreate's link (they share platform/LinkPipeline.kt).

/** Where the import was opened from: decides the title and what Done does. */
enum class ImportPurpose(val title: String, val done: String) {
    LIBRARY("Import from link", "Open in Library"),
    SWAP("Use a video from a link", "Use for swap"),
    EDIT("Add a video from a link", "Add to the edit"),
}

/** The import's state: typing, working (progress and its line), done, or failed (and whether the saved file is the way in). */
sealed interface ImportPhase {
    data object Enter : ImportPhase
    data class Working(val progress: Float, val step: String) : ImportPhase
    data class Done(val video: ImportedVideo) : ImportPhase
    data class Failed(val message: String, val pickFile: Boolean) : ImportPhase
}

/**
 * The import, full screen over whatever opened it. [link] prefills the field (Share → MUSE), and starts at once.
 * [onDone] gets the imported video; [onPickFile] is "Pick the saved video" when a link can't be fetched.
 */
@Composable
fun ImportLinkDialog(purpose: ImportPurpose, link: String? = null, onClose: () -> Unit, onPickFile: () -> Unit, onDone: (ImportedVideo) -> Unit) {
    val c = LocalContainer.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var phase by remember { mutableStateOf<ImportPhase>(ImportPhase.Enter) }
    var job by remember { mutableStateOf<Job?>(null) }
    fun start(url: String) {
        job?.cancel()
        phase = ImportPhase.Working(.02f, "Checking the link")
        job = scope.launch {
            phase = try {
                // No name: the video's own title (or the server's) names it.
                ImportPhase.Done(importFromLink(c.repo.api, c.linkFetcher.takeIf { !c.repo.demo }, url, null, context.cacheDir) { p, s -> phase = ImportPhase.Working(p, s) })
            } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: ApiException) {
                // A rule the link breaks: try another link. The phone and the server both failed: the saved file is the way in.
                ImportPhase.Failed(e.message?.ifBlank { null } ?: "Couldn't get this video", pickFile = e.code in FETCH_FAILED)
            } catch (e: Exception) {
                ImportPhase.Failed("Couldn't get this video. Save it to your phone and pick it instead.", pickFile = true)
            }
        }
    }
    androidx.compose.runtime.LaunchedEffect(link) { link?.let { studio.muse.core.edit.SharedLink.first(it)?.let(::start) } }
    Dialog({ job?.cancel(); onClose() }, DialogProperties(usePlatformDefaultWidth = false)) {
        ImportLinkContent(purpose, phase, link.orEmpty(), onClose = { job?.cancel(); onClose() }, onLink = ::start, onPickFile = onPickFile,
            onAnother = { phase = ImportPhase.Enter }, onDone = onDone)
    }
}

/** Codes that mean "the video couldn't be fetched" (as opposed to "this link breaks a rule"). */
private val FETCH_FAILED = setOf("fetch_failed", "link_fetch_failed", "link_blocked", "link_private", "link_downloads_off", "offline", "provider_unreachable")

/** [ImportLinkDialog]'s content, without the window (screenshot tests render this). */
@Composable
fun ImportLinkContent(
    purpose: ImportPurpose, phase: ImportPhase, draft: String,
    onClose: () -> Unit, onLink: (String) -> Unit, onPickFile: () -> Unit, onAnother: () -> Unit, onDone: (ImportedVideo) -> Unit,
) {
    val m = muse
    ScreenBox(bg = m.roles.canvas) {
        Column(Modifier.fillMaxSize().testTag("import_link")) {
            CalmTopBar(purpose.title, onBack = onClose)
            Column(Modifier.fillMaxWidth().padding(horizontal = studio.muse.app.ui.theme.MuseSpace.gutter), verticalArrangement = Arrangement.spacedBy(studio.muse.app.ui.theme.MuseSpace.s4)) {
                when (phase) {
                    ImportPhase.Enter -> {
                        Body("Paste a TikTok, Instagram Reel or YouTube link. The video goes into your library, ready for a swap or an edit.")
                        ImportLinkField(onLink, draft)
                    }
                    is ImportPhase.Working -> {
                        T(phase.step + "…", m.scale.body, m.roles.ink)
                        Bar(phase.progress, Modifier.fillMaxWidth())
                        Caption("You can leave this screen open; it takes about as long as the video.")
                    }
                    is ImportPhase.Done -> ImportedCard(phase.video)
                    is ImportPhase.Failed -> {
                        T(phase.message, m.scale.body, m.roles.ink)
                        if (phase.pickFile) Caption("Save the video to your phone from the app it's in, then pick it here.")
                    }
                }
            }
            androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
            Row(Modifier.fillMaxWidth().navigationBarsPadding().padding(studio.muse.app.ui.theme.MuseSpace.gutter), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                when (phase) {
                    is ImportPhase.Done -> PrimaryButton(purpose.done, { onDone(phase.video) }, Modifier.weight(1f))
                    is ImportPhase.Failed -> {
                        SecondaryButton("Try another link", onAnother, Modifier.weight(1f))
                        if (phase.pickFile) PrimaryButton("Pick the saved video", onPickFile, Modifier.weight(1f))
                    }
                    else -> Unit
                }
            }
        }
    }
}

/** The link field (Recreate's, shared look): the button wakes up once the text holds a link. */
@Composable
private fun ImportLinkField(onLink: (String) -> Unit, draft: String) {
    val m = muse
    var text by remember { mutableStateOf(draft) }
    val url = studio.muse.core.edit.SharedLink.first(text)
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.weight(1f).heightIn(min = 48.dp).clip(RoundedCornerShape(m.radii.control)).background(m.roles.field).padding(horizontal = 12.dp), contentAlignment = Alignment.CenterStart) {
                BasicTextField(text, { text = it.take(500) }, Modifier.fillMaxWidth().semantics { contentDescription = "Link to a video" }, singleLine = true,
                    textStyle = m.scale.body.copy(color = m.roles.ink), cursorBrush = SolidColor(m.roles.accent),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go),
                    keyboardActions = KeyboardActions(onGo = { url?.let(onLink) }),
                    decorationBox = { inner -> Box { if (text.isEmpty()) T("TikTok, Reel or YouTube link", m.scale.body, m.roles.ink2, maxLines = 1); inner() } })
            }
            Box(Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(m.radii.control)).border(1.dp, m.roles.hairline, RoundedCornerShape(m.radii.control))
                .press(enabled = url != null) { url?.let(onLink) }.padding(horizontal = 16.dp).semantics { role = Role.Button }, contentAlignment = Alignment.Center) {
                T("Import", m.scale.label, if (url != null) m.roles.ink else m.roles.ink2, maxLines = 1)
            }
        }
        Caption("MUSE fetches it only where the platform allows; otherwise save the video and pick it.")
    }
}

/** The imported video: its first frame, name, length and where it came from. */
@Composable
private fun ImportedCard(v: ImportedVideo) {
    val m = muse
    Row(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
        RefImage(v.thumb, Modifier.width(96.dp).aspectRatio(9f / 16f).clip(RoundedCornerShape(m.radii.control)))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            T(v.name, m.scale.heading, m.roles.ink, maxLines = 2)
            T(listOfNotNull(v.durationSec.takeIf { it > 0 }?.let { "${"%.1f".format(java.util.Locale.US, it)} s" }, v.platform?.let(::platformName)).joinToString(", "), m.scale.caption, m.roles.ink2, maxLines = 1)
            Caption("Saved to your library")
        }
    }
}

private fun platformName(p: String) = when (p) { "tiktok" -> "TikTok"; "instagram" -> "Instagram"; "youtube" -> "YouTube"; else -> "a link" }

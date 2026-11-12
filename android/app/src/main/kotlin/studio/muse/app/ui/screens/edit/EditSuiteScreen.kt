package studio.muse.app.ui.screens.edit

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.CompositionPlayer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonObject
import studio.muse.app.AppContainer
import studio.muse.app.data.EditorEstimate
import studio.muse.app.data.EditorJob
import studio.muse.app.data.EditorJobRequest
import studio.muse.app.data.EditorSourceDto
import studio.muse.app.data.Take
import studio.muse.app.data.editTargetFor
import studio.muse.app.platform.SourceInfo
import studio.muse.app.platform.VideoEditEngine
import studio.muse.app.platform.edit.EditCompositionEngine
import studio.muse.app.platform.edit.LookLibrary
import studio.muse.app.platform.edit.OwnFonts
import studio.muse.app.platform.edit.LookThumbnails
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.components.Pill
import studio.muse.app.ui.components.RefImage
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.TopBar
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.ScreenBox
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.scale
import studio.muse.core.edit.Asset
import studio.muse.core.edit.AssetKind
import studio.muse.core.edit.AudioClip
import studio.muse.core.edit.Canvas
import studio.muse.core.edit.CaptionExport
import studio.muse.core.edit.CubeCheck
import studio.muse.core.edit.EditJson
import studio.muse.core.edit.EditProject
import studio.muse.core.edit.ExportBitrate
import studio.muse.core.edit.ExportCodec
import studio.muse.core.edit.ExportFormat
import studio.muse.core.edit.ExportResolution
import studio.muse.core.edit.GIF_FPS
import studio.muse.core.edit.SOUND_BITRATE
import studio.muse.core.edit.videoBitrate
import studio.muse.core.edit.ImageItem
import studio.muse.core.edit.SourceSize
import studio.muse.core.edit.Track
import studio.muse.core.edit.TrackKind
import studio.muse.core.edit.VideoClip
import studio.muse.core.edit.exportProject
import studio.muse.core.edit.itemSpan
import studio.muse.core.edit.locate
import studio.muse.core.edit.fromV1
import studio.muse.core.edit.problemOf
import studio.muse.core.edit.toSrt
import java.io.File
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/**
 * The Edit suite (designs EM1–EM5 / E1–E4), the editor for every video take and edited version. With a [takeId] it
 * opens that video (an edited version reopens its project on its source: v2 projects as saved, v1 edit lists through
 * `fromV1`); without one it shows the Edit home — recent videos and edited versions to open. Navigation entries are
 * the app shell's (workstream 1).
 */
@Composable
fun EditSuiteScreen(takeId: String?, onBack: () -> Unit) {
    var open by rememberSaveable(takeId) { mutableStateOf(takeId) }
    // Continue a draft (owner, 2026-11-12): the Edit home opens on a choice, New or Continue draft (the last edit, where it
    // was left); older Recent edits are listed below it.
    val filesDir = LocalContext.current.filesDir
    var resume by remember { mutableStateOf<studio.muse.core.edit.EditRecentItem?>(null) }
    var recent by remember { mutableStateOf<List<studio.muse.core.edit.EditRecentItem>>(emptyList()) }
    /** Each "New" is its own blank project (the editor is kept per key, so a second New mustn't reopen the first). */
    var newCount by rememberSaveable { mutableStateOf(0) }
    var recreating by rememberSaveable { mutableStateOf(false) } // "Recreate an edit" (plans/recreate-edit.md)
    var reference by rememberSaveable { mutableStateOf<String?>(null) } // a library reference opened in the Recipe view
    var learn by rememberSaveable { mutableStateOf<String?>(null) } // "playbook" | "recipes" (plans/learning-editor-ui.md), owner only
    // Share → MUSE: what another app shared opens Recreate with it, once.
    val c = LocalContainer.current
    val sharedNow by c.shared.collectAsState()
    var shared by remember { mutableStateOf<studio.muse.app.data.SharedReference?>(null) }
    LaunchedEffect(sharedNow) { sharedNow?.let { shared = it; c.shared.value = null; open = null; learn = null; reference = null; recreating = true } }
    // On the home (and back on it): the draft and Recent edits show where each edit now stands.
    LaunchedEffect(open) { if (open == null) recent = recentEdits(c, filesDir) }
    val openTake: (String) -> Unit = { t -> resume = recent.firstOrNull { it.takeId == t }; open = t }
    val id = open
    if (recreating) androidx.compose.runtime.key(shared) {
        RecipeScreen(onBack = { recreating = false; reference = null; shared = null }, referenceId = reference, shared = shared,
            onOpenTake = { recreating = false; reference = null; shared = null; open = it })
    }
    else if (id == null && learn == "playbook") studio.muse.app.ui.screens.edit.learn.PlaybookScreen(onBack = { learn = null }, onOpenTake = { open = it })
    else if (id == null && learn == "recipes") studio.muse.app.ui.screens.edit.learn.RecipesScreen(
        onBack = { learn = null }, onOpenTake = { open = it }, onOpenReference = { reference = it; recreating = true }, onRecreate = { recreating = true })
    else if (id == null) EditHome(onBack, onRecreate = { recreating = true }, onLearn = { learn = it }, recent = recent,
        onResume = { r -> resume = r; open = r.takeId }, onNew = { resume = null; newCount++; open = studio.muse.core.edit.BLANK_SOURCE }, onOpen = openTake)
    // "Open playbook" in the editor's Claude sheet leaves the editor for the Playbook.
    else androidx.compose.runtime.CompositionLocalProvider(LocalOpenPlaybook provides { open = null; learn = "playbook" }) {
        val r = resume?.takeIf { it.takeId == id }
        EditSuiteEditor(id, r, key = if (id == studio.muse.core.edit.BLANK_SOURCE) "edit-suite-blank-${r?.id ?: "new$newCount"}" else "edit-suite-$id", onBack = { if (takeId == null) { open = null; resume = null } else onBack() })
    }
}

// ======================================================================= home
/** The videos the suite can open, newest first (renders and edited versions). */
fun editableTakes(takes: List<Take>): List<TakeChoice> = takes.filter { it.kind == "take" || it.kind == "edit" }.sortedByDescending { it.createdAt }.map {
    TakeChoice(it.id, it.title, if (it.kind == "edit") "Edited" else it.label, it.thumb, it.durationSec, it.kind == "edit", it.videoUrl != null)
}

@Composable
fun EditHome(onBack: () -> Unit, onRecreate: () -> Unit, onLearn: (String) -> Unit = {}, recent: List<studio.muse.core.edit.EditRecentItem> = emptyList(),
             onResume: (studio.muse.core.edit.EditRecentItem) -> Unit = {}, onNew: () -> Unit = {}, onOpen: (String) -> Unit) {
    val c = LocalContainer.current
    val state by c.repo.state.collectAsState()
    val prefs by c.prefs.collectAsState()
    val owner = c.repo.demo || prefs.owner // the learning editor is the owner's (the server answers members 403)
    // "Recreate an edit": WS1's /v1/recreate/references (demo mode: FakeMuseApi's).
    val rows = recent.take(studio.muse.core.edit.EditRecent.SHOWN).map { r ->
        RecentRow(r, state.takes.firstOrNull { it.id == r.takeId }?.thumb, studio.muse.core.edit.EditRecent.lastEditedText(r.lastEditedAt, System.currentTimeMillis()))
    }
    EditHomeContent(editableTakes(state.takes), onBack, onOpen, onRecreate = onRecreate, onLearn = onLearn.takeIf { owner }, recent = rows, onResume = onResume, onNew = onNew)
}

@Composable
fun EditHomeContent(takes: List<TakeChoice>, onBack: () -> Unit, onOpen: (String) -> Unit, onRecreate: (() -> Unit)? = null, onLearn: ((String) -> Unit)? = null,
                    recent: List<RecentRow> = emptyList(), onResume: (studio.muse.core.edit.EditRecentItem) -> Unit = {}, onNew: () -> Unit = {}) {
    val m = muse
    ScreenBox(statusPad = true) {
        Column(Modifier.fillMaxSize()) {
            TopBar("Edit", onBack = onBack)
            LazyColumn(Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                // Owner decision 2026-11-12: two ways in, New and Continue draft (only New when there is no draft).
                item("start") { StartChoice(recent.firstOrNull(), onNew = onNew, onResume = onResume) }
                item { T("Open a video to cut, caption, grade and export it. Edits are saved as new versions; the original stays.", m.type.body.copy(fontSize = 13.5.sp), m.t.muted) }
                // "Recreate an edit" (plans/recreate-edit.md): an edit you love, broken into its recipe.
                if (onRecreate != null) item {
                    Row(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(m.t.r)).background(m.t.surface).press(onClick = onRecreate).padding(14.dp)
                            .semantics(mergeDescendants = true) { contentDescription = "Recreate an edit" },
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        EIc("film-strip", 22.dp, m.t.ink)
                        Column(Modifier.weight(1f)) {
                            T("Recreate an edit", m.scale.label, m.t.ink, maxLines = 1)
                            T("Pick an edit you love and see its recipe: shots, beats, text and grade", m.scale.caption, m.t.muted, maxLines = 2)
                        }
                        EIc("chev-r", 16.dp, m.t.muted)
                    }
                }
                // The learning editor (plans/learning-editor-ui.md): two quiet text buttons, owner only.
                if (onLearn != null) item {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        studio.muse.app.ui.screens.edit.learn.LearnQuiet("Playbook", "book-open-text") { onLearn("playbook") }
                        studio.muse.app.ui.screens.edit.learn.LearnQuiet("Recipes", "stack") { onLearn("recipes") }
                    }
                }
                // Continue a draft: the edits last worked on, each opening where it was left.
                if (recent.size > 1) { item { SuiteLabel("Recent edits", color = m.t.muted) }; recent.drop(1).forEach { r -> item("recent-${r.item.id}") { RecentEditRow(r, onResume) } } }
                val edited = takes.filter { it.edited }; val renders = takes.filter { !it.edited }
                if (takes.isEmpty()) item { T("No videos yet · make one in the Video suite", m.type.body, m.t.muted) }
                if (edited.isNotEmpty()) { item { SuiteLabel("Edited versions", color = m.t.muted) }; edited.forEach { t -> item(t.id) { HomeRow(t, onOpen) } } }
                if (renders.isNotEmpty()) { item { SuiteLabel("Recent videos", color = m.t.muted) }; renders.forEach { t -> item(t.id) { HomeRow(t, onOpen) } } }
            }
        }
    }
}

/** The Edit home's two ways in: New, and Continue draft (the last edit's picture, name and when) as the primary. */
@Composable
private fun StartChoice(last: RecentRow?, onNew: () -> Unit, onResume: (studio.muse.core.edit.EditRecentItem) -> Unit) {
    val m = muse
    Row(Modifier.fillMaxWidth().height(androidx.compose.foundation.layout.IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        StartTile("New", "Blank project", accent = last == null, label = "New edit", modifier = Modifier.weight(1f), onClick = onNew) {
            Box(Modifier.size(44.dp, 62.dp).clip(RoundedCornerShape(2.dp)).background(m.t.surface2), contentAlignment = Alignment.Center) { EIc("plus", 18.dp, m.t.ink) }
        }
        if (last != null) StartTile("Continue draft", last.item.title, meta = last.whenText, accent = true,
            label = "Continue draft: ${last.item.title}, edited ${last.whenText}", modifier = Modifier.weight(1f), onClick = { onResume(last.item) }) {
            Box(Modifier.size(44.dp, 62.dp).clip(RoundedCornerShape(2.dp)).background(m.t.surface2), contentAlignment = Alignment.Center) {
                if (last.thumb != null) RefImage(last.thumb, Modifier.fillMaxSize()) else EIc("film-strip", 18.dp, m.t.muted)
            }
        }
    }
}

@Composable
private fun StartTile(title: String, detail: String, meta: String? = null, accent: Boolean, label: String, modifier: Modifier, onClick: () -> Unit,
                      picture: @Composable () -> Unit) {
    val m = muse
    Row(
        modifier.fillMaxHeight().clip(RoundedCornerShape(m.t.r)).background(m.t.surface)
            .border(if (accent) 1.5.dp else 1.dp, if (accent) m.t.accent else m.t.line, RoundedCornerShape(m.t.r))
            .press(onClick = onClick).padding(10.dp).semantics(mergeDescendants = true) { contentDescription = label },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        picture()
        Column(Modifier.weight(1f)) {
            T(title, m.type.body.copy(fontSize = 14.5.sp, fontWeight = FontWeight.Bold), m.t.ink, maxLines = 1)
            T(detail, m.type.tiny.copy(fontSize = 12.sp), m.t.muted, maxLines = 1)
            if (meta != null) T(meta, m.type.tiny.copy(fontSize = 12.sp), m.t.muted, maxLines = 1)
        }
    }
}

/** A row of Recent edits: its picture (none when the take is gone), its name and when it was last worked on. */
data class RecentRow(val item: studio.muse.core.edit.EditRecentItem, val thumb: studio.muse.app.data.ImageRef?, val whenText: String)

@Composable
private fun RecentEditRow(r: RecentRow, onResume: (studio.muse.core.edit.EditRecentItem) -> Unit) {
    val m = muse
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(m.t.r)).background(m.t.surface).press { onResume(r.item) }.padding(10.dp)
            .semantics(mergeDescendants = true) { contentDescription = "Continue ${r.item.title}, edited ${r.whenText}" },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.size(44.dp, 62.dp).clip(RoundedCornerShape(2.dp)).background(m.t.surface2), contentAlignment = Alignment.Center) {
            if (r.thumb != null) RefImage(r.thumb, Modifier.fillMaxSize()) else EIc("film-strip", 18.dp, m.t.muted)
        }
        Column(Modifier.weight(1f)) {
            T(r.item.title, m.type.body.copy(fontSize = 14.5.sp, fontWeight = FontWeight.Bold), m.t.ink, maxLines = 1)
            T(r.whenText, m.type.tiny.copy(fontSize = 12.sp), m.t.muted, maxLines = 1)
        }
        EIc("chev-r", 16.dp, m.t.muted)
    }
}

@Composable
private fun HomeRow(t: TakeChoice, onOpen: (String) -> Unit) {
    val m = muse
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(m.t.r)).background(m.t.surface).press { onOpen(t.id) }.padding(10.dp).semantics { contentDescription = "Open ${t.title}" },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.size(44.dp, 62.dp).clip(RoundedCornerShape(2.dp)).background(m.t.surface2)) { RefImage(t.thumb, Modifier.fillMaxSize()) }
        Column(Modifier.weight(1f)) {
            T(t.title, m.type.body.copy(fontSize = 14.5.sp, fontWeight = FontWeight.Bold), m.t.ink, maxLines = 1)
            T(listOfNotNull(t.label, t.durationSec?.let { suiteTime(it) }, if (!t.hasVideo) "still only" else null).joinToString(" · "), m.type.tiny.copy(fontSize = 12.sp), m.t.muted, maxLines = 1)
        }
        if (t.edited) Pill("Edited", "good")
        EIc("chev-r", 16.dp, m.t.muted)
    }
}

// ======================================================================= editor
@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun EditSuiteEditor(takeId: String, resume: studio.muse.core.edit.EditRecentItem?, key: String, onBack: () -> Unit) {
    val c = LocalContainer.current
    val context = LocalContext.current
    val vm: EditSuiteViewModel = viewModel(key = key) { EditSuiteViewModel(c, takeId, context, resume) }
    val ui by vm.controller.ui.collectAsState()
    val soundPlaying by vm.soundPlaying.collectAsState()
    val frames by vm.frames.collectAsState()
    val thumbs by vm.lookThumbs.collectAsState()
    val fxThumbs by vm.effectThumbs.collectAsState()
    val nav = studio.muse.app.ui.LocalNav.current
    val player by vm.player.collectAsState()
    val waves by vm.waves.collectAsState()
    LaunchedEffect(ui.message) { ui.message?.let { c.repo.toast(it); vm.controller.act(EditAction.ClearMessage) } }
    LaunchedEffect(ui.panel) { if (ui.panel == Panel.FILTERS) vm.renderLookThumbs() }
    androidx.lifecycle.compose.LifecycleResumeEffect(vm) { onPauseOrDispose { vm.pause() } }
    val audio = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri -> uri?.let { vm.addAudio(it, voiceOver = false) } }
    val micPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        if (ok) vm.startVoiceOver() else c.repo.toast("Record VO needs the microphone · allow it in the phone's settings")
    }
    val cube = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri -> uri?.let { vm.importCube(it) } }
    // "Add a video from a link": WS7's import screen; when the link can't be fetched, the saved video is picked and imported there too.
    var importing by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(false) }
    var savedVideo by remember { mutableStateOf<Uri?>(null) }
    val video = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri -> if (uri != null) { savedVideo = uri; importing = true } }
    // "Add a photo": the system photo picker (images only; no storage permission).
    val photo = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri -> uri?.let { vm.addPhoto(it) } }
    // "Your font": the system file picker (fonts have no reliable MIME type, so any file; the view model checks it).
    val font = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> uri?.let { vm.addFont(it) } }
    if (importing) studio.muse.app.ui.screens.ImportLinkDialog(studio.muse.app.ui.screens.ImportPurpose.EDIT, file = savedVideo,
        onClose = { importing = false; savedVideo = null }, onPickFile = { importing = false; video.launch("video/*") }) { v ->
        importing = false; savedVideo = null; vm.addImported(v)
    }
    val host = SuiteHost(
        pickAudio = { audio.launch("audio/*") },
        // Record VO: records in the editor from the playhead (the phone's own recorder app isn't there on most phones).
        recordVo = {
            when {
                ui.recordingAt != null -> vm.stopVoiceOver()
                androidx.core.content.ContextCompat.checkSelfPermission(context, android.Manifest.permission.RECORD_AUDIO) == android.content.pm.PackageManager.PERMISSION_GRANTED -> vm.startVoiceOver()
                else -> micPermission.launch(android.Manifest.permission.RECORD_AUDIO)
            }
        },
        importCube = { cube.launch("*/*") },
        export = vm::export,
        cancelExport = vm::cancelExport,
        lookThumbs = thumbs,
        effectThumbs = fxThumbs,
        renderEffectThumbs = vm::renderEffectThumbs,
        waves = waves,
        saveFrame = vm::saveFrame,
        importLink = { importing = true },
        post = { id -> nav.go(studio.muse.app.ui.Routes.post(id)) },
        headphones = androidx.compose.runtime.remember(ui.recordingAt, ui.panel) { vm.outputRoute().headphones },
        addPhoto = { photo.launch(androidx.activity.result.PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
        reframe = vm::reframe,
        contentUrl = { path -> vm.contentUrl(path) },
        addContent = vm::addContent,
        previewSound = vm::previewSound,
        soundPlaying = soundPlaying,
        addFont = { font.launch(arrayOf("font/ttf", "font/otf", "font/sfnt", "application/x-font-ttf", "application/vnd.ms-opentype", "application/octet-stream")) },
        autoAdjust = vm::autoAdjust,
        saveKit = vm::saveKit,
        deleteKit = vm::deleteKit,
        modelRow = { purpose ->
            studio.muse.app.data.ModelPurpose.of(purpose)?.let { mp ->
                studio.muse.app.ui.screens.ModelChoiceRow(mp, studio.muse.app.ui.screens.ModelPick(ui.helperModels[purpose]), onPick = { pick -> vm.controller.act(EditAction.PickModel(purpose, pick.model)) })
            }
        },
    )
    EditSuiteContent(ui, frames, host, vm.controller::act, onClose = onBack, drawText = player == null) { mod ->
        val p = player
        if (p != null) PlayerSurface(p, mod) else RefImage(ui.poster, mod, 30)
    }
}

@androidx.annotation.OptIn(UnstableApi::class)
@Composable
private fun PlayerSurface(player: CompositionPlayer, modifier: Modifier) {
    androidx.compose.ui.viewinterop.AndroidView(
        factory = { ctx ->
            androidx.media3.ui.PlayerView(ctx).apply {
                this.player = player
                useController = false
                resizeMode = androidx.media3.ui.AspectRatioFrameLayout.RESIZE_MODE_FIT
                setShutterBackgroundColor(android.graphics.Color.BLACK)
            }
        },
        modifier = modifier,
        update = { it.player = player },
    )
}

// ======================================================================= backend over the repository
/** The AI helpers through the app's repository (the real API, or the demo backend), polled to their result. */
class RepoEditBackend(private val c: AppContainer, private val pollMs: Long = 700, private val onAsset: (String, String) -> Unit = { _, _ -> }) : EditBackend {
    override fun assetArrived(assetId: String, url: String) = onAsset(assetId, url)

    /**
     * WS1 guardrails (`GET /v1/editor/features`): paid helpers switched off by the owner read "Turned off by the studio
     * owner" (or the server's reason); a helper the server can't run yet (the cut-out on the mock) reads "Coming soon".
     */
    private var features: kotlinx.serialization.json.JsonObject? = null
    private suspend fun features() = features ?: c.repo.api.editorFeatures()?.also { features = it }

    override suspend fun translateLanguages(): List<Pair<String, String>> {
        val t = features()?.get("translate") as? kotlinx.serialization.json.JsonObject ?: return emptyList()
        if ((t["available"] as? kotlinx.serialization.json.JsonPrimitive)?.content == "false") return emptyList()
        val langs = t["languages"] as? kotlinx.serialization.json.JsonObject ?: return emptyList()
        return langs.mapNotNull { (code, name) -> (name as? kotlinx.serialization.json.JsonPrimitive)?.content?.let { code to it } }
            .filter { studio.muse.core.edit.LANGUAGE_CODE.matches(it.first) }
    }

    override suspend fun helpersOff(): Map<String, String> {
        val f = features() ?: return emptyMap()
        fun obj(k: String) = f[k] as? kotlinx.serialization.json.JsonObject
        fun off(o: kotlinx.serialization.json.JsonObject?) = (o?.get("available") as? kotlinx.serialization.json.JsonPrimitive)?.content == "false"
        fun note(o: kotlinx.serialization.json.JsonObject?, k: String) = (o?.get(k) as? kotlinx.serialization.json.JsonPrimitive)?.takeIf { it.isString }?.content?.takeIf { it.isNotBlank() }
        val paid = obj("paid")
        val paidOff = if (off(paid)) note(paid, "reason") ?: "Turned off by the studio owner" else null
        return listOf("captions", "matte", "denoise", "translate", "slowmo", "separate", "cutout").mapNotNull { k ->
            val o = obj(k)
            (paidOff ?: if (off(o)) (note(o, "note") ?: "Coming soon") else null)?.let { k to it }
        }.toMap()
    }

    override suspend fun estimate(kind: String, source: EditorSourceDto, options: JsonObject?): Pair<EditorEstimate?, String?> = estimate(kind, source, options, null)
    override suspend fun estimate(kind: String, source: EditorSourceDto, options: JsonObject?, engineModel: String?): Pair<EditorEstimate?, String?> =
        runCatching { c.repo.attemptInline { editorEstimate(EditorJobRequest(kind, source, options, engineModel)) } }.getOrElse { null to "Couldn't reach the studio · try again" }

    override suspend fun run(kind: String, source: EditorSourceDto, options: JsonObject?, onProgress: (EditorJob) -> Unit): Pair<JsonObject?, String?> = run(kind, source, options, null, onProgress)
    override suspend fun run(kind: String, source: EditorSourceDto, options: JsonObject?, engineModel: String?, onProgress: (EditorJob) -> Unit): Pair<JsonObject?, String?> {
        val (started, err) = runCatching { c.repo.attemptInline { startEditorJob(EditorJobRequest(kind, source, options, engineModel)) } }.getOrElse { null to "Couldn't reach the studio · try again" }
        var job = started ?: return null to (err ?: "Couldn't start the helper")
        try {
            onProgress(job)
            while (!job.finished) {
                delay(pollMs)
                job = runCatching { c.repo.attemptInline { editorJob(job.id) }.first }.getOrNull() ?: continue
                onProgress(job)
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            runCatching { c.repo.attemptInline { cancelEditorJob(job.id) } }
            throw e
        }
        // Made at the provider but not saved: the owner gets a free Recover (members see the server's words).
        if (job.canRecover && c.repo.ownerNow()) recoverable = job.id
        return if (job.state == "done" && job.result != null) job.result to null else null to (job.error ?: if (job.state == "cancelled") "Stopped" else "The helper stopped · try again")
    }

    private var recoverable: String? = null
    override fun takeRecoverable(): String? = recoverable.also { recoverable = null }

    override suspend fun recover(jobId: String, onProgress: (EditorJob) -> Unit): Pair<JsonObject?, String?> {
        if (c.repo.recoverJob(jobId) == null) return null to "Couldn't recover it · try again"
        var job = runCatching { c.repo.attemptInline { editorJob(jobId) }.first }.getOrNull() ?: return null to "Couldn't reach the studio · try again"
        onProgress(job)
        while (!job.finished) {
            delay(pollMs)
            job = runCatching { c.repo.attemptInline { editorJob(jobId) }.first }.getOrNull() ?: continue
            onProgress(job)
        }
        return if (job.state == "done" && job.result != null) job.result to null else null to (job.error ?: "The helper stopped · try again")
    }
}

// ======================================================================= view-model (Android side)
/**
 * The Android half of the editor: loads the video and the project, keeps local files per asset, runs the
 * CompositionPlayer preview (rebuilt shortly after each change) and the export (Media3 Transformer), saves the new
 * version with its v2 project, and feeds the controller the playhead.
 */
@androidx.annotation.OptIn(UnstableApi::class)
@OptIn(FlowPreview::class)
class EditSuiteViewModel(private val c: AppContainer, private val takeId: String, context: Context,
                         /** Continue a draft: the recent edit this opens, as it was left (null: opened from a take as usual). */
                         private val resume: studio.muse.core.edit.EditRecentItem? = null) : ViewModel() {
    private val app = context.applicationContext
    private val looks = LookLibrary(app)
    val controller = EditSuiteController(viewModelScope, RepoEditBackend(c, onAsset = { id, url -> fetchAsset(id, url) }), lookOf = { id -> runCatching { looks.pack.packLook(id) }.getOrNull() })
    private val engine = VideoEditEngine(app)
    private val composer by lazy { EditCompositionEngine(app, looks) }
    private val files = HashMap<String, File>()
    private var sourceFile: File? = null
    private var sourceInfo: SourceInfo? = null
    private val _frames = MutableStateFlow<Map<String, List<ImageBitmap>>>(emptyMap())
    val frames: StateFlow<Map<String, List<ImageBitmap>>> = _frames.asStateFlow()
    private val _thumbs = MutableStateFlow<Map<String, ImageBitmap>>(emptyMap())
    val lookThumbs: StateFlow<Map<String, ImageBitmap>> = _thumbs.asStateFlow()
    private val _waves = MutableStateFlow<Map<String, Peaks>>(emptyMap())
    /** Decoded sound levels per asset (the timeline's sound lanes). */
    val waves: StateFlow<Map<String, Peaks>> = _waves.asStateFlow()
    private val _player = MutableStateFlow<CompositionPlayer?>(null)
    val player: StateFlow<CompositionPlayer?> = _player.asStateFlow()
    private var work: Job? = null
    private var exporting: Job? = null
    private var lastExportError: String? = null
    /** Edit sessions (workstream 3): the owner's live session with Claude (null for members / local only). */
    private var sync: EditSessionSync? = null

    /** Edit's preview choice per project (plans/edit-platform-preview.md), on this device. */
    private val previewStore = app.getSharedPreferences("edit-preview", Context.MODE_PRIVATE)
    /** Continue a draft: this phone's recent edits, whether the place is being saved yet, and the last place sent to the session. */
    private val recentFile = EditRecentFile.of(app.filesDir)
    private var placeTracking = false
    private var lastSentPlace: studio.muse.core.edit.EditPlace? = null
    /** A member's (or an unshared) edit kept on this phone: what the editor reopens instead of the take's saved edit. */
    private val localResume: EditProject? get() = resume?.takeIf { it.sessionId == null }?.let { r ->
        recentFile.load().firstOrNull { "local:${it.key}" == r.id }?.project?.let { runCatching { EditJson.parse(it) }.getOrNull() }
    }
    private var previewKey: String? = null
    private fun previewPrefs() = studio.muse.core.edit.EditPreviewPrefs.decode(previewStore.getString("prefs", null))

    init {
        controller.onPreviewChanged = { p ->
            previewKey?.let { k -> previewStore.edit().putString("prefs", previewPrefs().set(p, k).encode()).apply() }
        }
        load()
        loadKits()
        // Continue a draft: where the editor stands (and a member's edit) is saved shortly after it changes.
        viewModelScope.launch {
            controller.ui.map { u -> if (u.phase is SuitePhase.Ready) placeOf(u, resume?.place) to u.project else null }.distinctUntilChanged().debounce(800)
                .collect { if (it != null) savePlace() }
        }
        viewModelScope.launch {
            controller.ui.map { it.project }.distinctUntilChanged().debounce(500).collect { p ->
                if (p == null) return@collect
                // A take added while editing (an overlay, or a clip at the end): its file first, so the preview and the
                // export include it (before, only takes in the project when it opened were fetched).
                if ((sourceFile != null || p.isBlank) && p.assets.any { (it.take != null || (it.upload != null && it.kind != AssetKind.LUT && it.kind != AssetKind.FONT && it.id !in fetchTried)) && it.id !in files }) { fetchTakeAssets(p); loadWaves(p) }
                if (p.assets.any { it.kind == AssetKind.FONT && it.upload?.let(OwnFonts::has) == false }) fetchFonts(p)
                if (contentMissing(p).isNotEmpty()) ensureContent(p)
                rebuildPreview(p)
            }
        }
        viewModelScope.launch { controller.ui.map { it.playing }.distinctUntilChanged().collect { on -> _player.value?.let { if (on) it.play() else it.pause() } } }
        // The chroma eyedropper: its frame once it opens (the source picture at the playhead, 720 px).
        viewModelScope.launch {
            controller.ui.map { it.pick?.takeIf { pk -> pk.argb == null }?.clipId }.distinctUntilChanged().collect { id ->
                if (id == null) return@collect
                val fr = sourceFrame(id, 720)
                if (fr == null) { controller.act(EditAction.PickColor(false)); c.repo.toast("This clip's file isn't on the phone yet") }
                else controller.act(EditAction.PickFrame(fr.first, fr.second, fr.third))
            }
        }
        viewModelScope.launch {
            // Scrubbing: the preview follows the playhead frame by frame. Seeks are conflated (only the latest position
            // waits while one is being decoded), so a fast drag never queues up stale frames; when the finger stops,
            // the last seek is the exact frame. Paused, anything more than half a frame away is sought.
            controller.ui.map { Triple(it.playheadSec, it.playing, it.project?.canvas?.fps ?: 30.0) }.distinctUntilChanged().conflate().collect { (t, playing, fps) ->
                val p = _player.value ?: return@collect
                if (playing) return@collect
                if (kotlin.math.abs(p.currentPosition / 1000.0 - t) * fps < 0.5) return@collect
                p.seekTo((t * 1000).roundToLong())
                withTimeoutOrNull(250) { while (p.playbackState == androidx.media3.common.Player.STATE_BUFFERING) delay(8) }
            }
        }
        viewModelScope.launch {
            while (isActive) {
                val p = _player.value
                if (p != null && p.isPlaying) controller.setPlayback(p.currentPosition / 1000.0, true)
                delay(50)
            }
        }
    }

    private fun load() {
        work?.cancel()
        work = viewModelScope.launch {
            controller.setPhase(SuitePhase.Loading())
            val takes = c.repo.state.value.takes
            // "New" (owner 2026-11-12): a blank project, no source video; or a blank edit continued from Recent edits.
            if (takeId == studio.muse.core.edit.BLANK_SOURCE) return@launch loadBlank()
            val take = takes.firstOrNull { it.id == takeId } ?: run {
                // Continue a draft: an edit whose take was deleted still opens (its clips read "Missing").
                if (resume != null && loadWithoutTake(resume)) return@launch
                return@launch controller.setPhase(SuitePhase.Failed("This video isn't in your studio any more", canRetry = false))
            }
            val target = editTargetFor(take, takes)
            val source = target?.source ?: take
            controller.update { u ->
                u.copy(
                    looks = runCatching { looks.pack.looks.map { LookChoice(it.id, it.name, it.category) } }.getOrDefault(emptyList()),
                    suiteLooks = runCatching { looks.palettes.looks.associate { it.id to it.name } }.getOrDefault(emptyMap()),
                    takes = editableTakes(takes).filter { it.id != source.id },
                )
            }
            try {
                val url = source.videoUrl
                if (url != null) {
                    val f = engine.fetchSource(url) { p -> controller.setPhase(SuitePhase.Loading(p)) }
                    sourceFile = f; sourceInfo = engine.probe(f)
                }
                val project = localResume?.takeIf { it.sourceTakeId == source.id } ?: savedBlank(take) ?: projectFor(source, target?.initial)
                for (a in project.assets) if (a.take == source.id && a.kind == AssetKind.VIDEO) sourceFile?.let { files[a.id] = it }
                controller.load(project, source.title, source.id, source.thumb, reopened = take.kind == "edit")
                // Edit's preview: this project's remembered view (else this device's last), and the server's safe zones.
                previewKey = source.id
                controller.act(EditAction.PreviewOf(previewPrefs().choice(source.id)))
                viewModelScope.launch { runCatching { c.repo.api.previewLayouts() }.getOrNull()?.let { controller.act(EditAction.PreviewLayoutsOf(studio.muse.core.edit.PreviewLayouts.parse(it))) } }
                startSession(source.id, project, fromVersion = if (target?.initial != null && take.kind == "edit") take.id else null)
                loadFrames(project)
                fetchTakeAssets(controller.project ?: project)
                fetchFonts(controller.project ?: project)
                startPlace()
                loadContent()
                loadWaves(controller.project ?: project)
            } catch (e: kotlinx.coroutines.CancellationException) { throw e
            } catch (e: Exception) {
                controller.setPhase(SuitePhase.Failed("Couldn't open the video · check your connection and try again"))
            }
        }
    }

    /** A saved blank project (a Library video with no source): its own project again, this video now its source. */
    private fun savedBlank(take: Take): EditProject? {
        if (take.kind != "edit" || take.parentTakeId != null) return null
        val p = take.edits?.project?.let { runCatching { EditJson.parse(it) }.getOrNull() } ?: return null
        return if (p.isBlank) p.copy(sourceTakeId = take.id) else null
    }

    /** A blank project's first save made this Library video; later saves are its versions. */
    private var blankSavedId: String? = null

    /** "New": nothing on the timeline yet (or the blank edit continued as it was left); videos come from the Overlay panel. */
    private suspend fun loadBlank() {
        val takes = c.repo.state.value.takes
        controller.update { u ->
            u.copy(
                looks = runCatching { looks.pack.looks.map { LookChoice(it.id, it.name, it.category) } }.getOrDefault(emptyList()),
                suiteLooks = runCatching { looks.palettes.looks.associate { it.id to it.name } }.getOrDefault(emptyMap()),
                takes = editableTakes(takes),
            )
        }
        val r = resume
        val project = r?.sessionId?.let { sid -> runCatching { EditJson.parse(c.repo.api.editSession(sid).project) }.getOrNull() }
            ?: localResume ?: studio.muse.core.edit.blankProject()
        val title = r?.title?.takeIf { it != studio.muse.core.edit.EditRecent.UNTITLED } ?: "New project"
        controller.load(project, title, studio.muse.core.edit.BLANK_SOURCE, null, reopened = false)
        viewModelScope.launch { runCatching { c.repo.api.previewLayouts() }.getOrNull()?.let { controller.act(EditAction.PreviewLayoutsOf(studio.muse.core.edit.PreviewLayouts.parse(it))) } }
        startSession(studio.muse.core.edit.BLANK_SOURCE, project, fromVersion = null, attach = r?.sessionId)
        fetchTakeAssets(project)
        fetchFonts(project)
        startPlace()
        loadContent()
        loadWaves(project)
        rebuildPreview(controller.project ?: project)
    }

    /** A blank project with nothing on its main track yet: nothing to play or render. */
    private val emptyBlank: Boolean get() = controller.project?.let { it.isBlank && it.main.items.isEmpty() } == true
    /** There is something to play or render: the source video, or a blank project's first clip. */
    private val canRender: Boolean get() = sourceFile != null || (controller.project?.isBlank == true && !emptyBlank)
    /** A file to take a still from for the look and effect tiles: the source, else a blank project's first clip. */
    private fun stillSource(): File? = sourceFile ?: controller.project?.mainClips?.firstNotNullOfOrNull { files[it.asset] }

    /** The project to start from: a saved v2 project, a v1 edit list, or the whole source as one clip. */
    private fun projectFor(source: Take, initial: studio.muse.app.data.EditListDto?): EditProject {
        val info = sourceInfo
        initial?.project?.let { json -> runCatching { EditJson.parse(json) }.getOrNull()?.takeIf { problemOf(it, paletteIds = looks.paletteIds) == null }?.let { return it } }
        val size = SourceSize(info?.width ?: source.width ?: 1080, info?.height ?: source.height ?: 1920, (info?.fps?.takeIf { it > 0 } ?: source.fps ?: 30.0).roundToInt().toDouble(), info?.hasAudio)
        initial?.toEdit()?.let { e -> runCatching { fromV1(e, source.id, size) }.getOrNull()?.takeIf { problemOf(it, paletteIds = looks.paletteIds) == null }?.let { return it } }
        // A suite take graded with a look (workstream 1, Take.look) starts with it on its main clip (reversible like any look).
        return newProject(source.id, info?.durationSec?.takeIf { it > 0 } ?: source.durationSec ?: 8.0, size, lut = source.look?.lut)
    }

    private suspend fun loadFrames(p: EditProject) {
        val f = sourceFile ?: return
        val dur = sourceInfo?.durationSec ?: return
        val px = (52 * app.resources.displayMetrics.density).toInt()
        val times = List(12) { i -> dur * (i + 0.5) / 12 }
        val bmps = runCatching { engine.frames(f, times, px).mapNotNull { it?.asImageBitmap() } }.getOrDefault(emptyList())
        val src = p.assets.firstOrNull { it.take == p.sourceTakeId }?.id ?: return
        _frames.value = _frames.value + (src to bmps)
    }

    /** The timeline's waveforms: every asset with a local file and sound, decoded once. */
    private fun loadWaves(p: EditProject) {
        viewModelScope.launch {
            for (a in p.assets) {
                if (a.id in _waves.value || a.hasAudio == false || (a.kind != AssetKind.VIDEO && a.kind != AssetKind.AUDIO)) continue
                val f = files[a.id] ?: continue
                studio.muse.app.platform.edit.WaveformDecoder.peaks(f)?.let { _waves.value = _waves.value + (a.id to it) }
            }
        }
    }

    /** A helper's new asset (background removal's matte): its file, then the preview again with it. */
    private fun fetchAsset(assetId: String, url: String) {
        viewModelScope.launch {
            val f = runCatching { engine.fetchSource(url) {} }.getOrNull() ?: return@launch c.repo.toast("Couldn't download the cut-out · try again")
            files[assetId] = f
            controller.project?.let { rebuildPreview(it); loadWaves(it) }
        }
    }

    /** PiP takes and editor uploads (photos, sounds, reversed copies, cut-outs): their files (for preview/export). */
    /** Upload assets already asked for once (so a missing one isn't fetched on every change). */
    private val fetchTried = HashSet<String>()

    private suspend fun fetchTakeAssets(p: EditProject) {
        val takes = c.repo.state.value.takes
        for (a in p.assets) {
            if (a.id in files || a.kind == AssetKind.LUT || a.kind == AssetKind.FONT) continue
            if (a.take == null && !fetchTried.add(a.id)) continue
            val url = when {
                a.take != null -> takes.firstOrNull { it.id == a.take }?.videoUrl
                a.upload != null -> runCatching { c.repo.api.editorUploadUrl(a.upload!!) }.getOrNull()
                else -> null
            } ?: continue
            runCatching { engine.fetchSource(url) {} }.getOrNull()?.let { files[a.id] = it }
        }
        // Continue a draft: what still has no file is marked "Missing" (the edit opens anyway).
        val gone = studio.muse.core.edit.EditRecent.missingAssets(p, files.keys)
        if (gone != controller.ui.value.missing) controller.update { it.copy(missing = gone) }
    }

    /**
     * Continue a draft, the take deleted: the edit as it was left (the session's, or the one kept on this phone) opens
     * without its source. False when there is nothing to open.
     */
    private suspend fun loadWithoutTake(r: studio.muse.core.edit.EditRecentItem): Boolean {
        // This phone's copy first (changes made here since the take went), else the session's.
        val json = recentFile.load().firstOrNull { it.key == r.takeId && it.project != null }?.project
            ?: r.sessionId?.let { sid -> runCatching { c.repo.api.editSession(sid).project }.getOrNull() }
        val project = json?.let { runCatching { EditJson.parse(it) }.getOrNull() } ?: return false
        controller.load(project, r.title, project.sourceTakeId, null, reopened = true)
        fetchTakeAssets(project)
        fetchFonts(project)
        startPlace()
        return true
    }

    /** Continue a draft: back where the edit was left, then where the editor stands is saved as it changes. */
    private fun startPlace() {
        resume?.place?.let { controller.restorePlace(it) }
        placeTracking = true
        savePlace()
    }

    /** Saves where the editor stands: on this phone (with a member's project) and, for the owner, on the session. */
    private fun savePlace() {
        if (!placeTracking) return
        val u = controller.ui.value
        val project = u.project ?: return
        val place = placeOf(u, resume?.place)
        // The owner's live session (or, its take deleted, the session it was opened from); a member's edit has none.
        val live = sync
        val sid = live?.sessionId ?: resume?.sessionId?.takeIf { live == null }
        if (live != null && sid == null) return // the owner's session is still connecting: saved once it's there
        // Kept here when no session shares it: a member's edit, or one whose take was deleted (it can't be shared any more).
        recentFile.save(studio.muse.core.edit.EditRecentEntry(takeId, sid, if (live == null) EditJson.encode(project) else null, place,
            u.title, System.currentTimeMillis()))
        if (sid != null && lastSentPlace?.samePlace(place) != true) {
            lastSentPlace = place
            c.scope.launch { runCatching { c.repo.api.saveEditView(sid, place.toJson()) } }
        }
    }

    private fun playable(p: EditProject): EditProject = playableProject(p, files.keys)

    private fun rebuildPreview(p: EditProject) {
        if (p.isBlank && p.main.items.isEmpty()) { _player.value?.release(); _player.value = null; return } // the viewer shows "Add a video"
        if (sourceFile == null && !p.isBlank) return
        val pos = _player.value?.currentPosition ?: (controller.ui.value.playheadSec * 1000).toLong()
        runCatching {
            val plan = composer.plan(playable(p), files)
            val old = _player.value
            val next = composer.previewPlayer(plan, files)
            next.prepare()
            next.seekTo(pos)
            _player.value = next
            old?.release()
        }.onFailure { _player.value?.release(); _player.value = null }
    }

    fun pause() { _player.value?.pause(); controller.setPlayback(controller.ui.value.playheadSec, false) }

    // ------------------------------------------------------------ files the user adds
    /** The project's own fonts on this phone: from the cache, else downloaded (text draws its fallback until then). */
    private suspend fun fetchFonts(p: EditProject) {
        for (a in p.assets) {
            val up = a.upload ?: continue
            if (a.kind != AssetKind.FONT || OwnFonts.has(up)) continue
            val cached = fontFile(up)
            val f = if (cached.exists()) cached else {
                val url = runCatching { c.repo.api.editorUploadUrl(up) }.getOrNull() ?: continue
                runCatching { engine.fetchSource(url) {} }.getOrNull()?.let { got -> withContext(Dispatchers.IO) { runCatching { got.copyTo(cached, overwrite = true) }.getOrNull() } } ?: continue
            }
            OwnFonts.register(up, f)
        }
    }

    private fun fontFile(upload: String) = File(app.cacheDir, "edit-suite/fonts/$upload.font").apply { parentFile?.mkdirs() }

    /**
     * "Your font": a .ttf/.otf from the phone, checked and named here ([studio.muse.core.edit.FontFile]), uploaded, then
     * set on the selected text (the server checks it again when the edit is saved).
     */
    fun addFont(uri: Uri) {
        viewModelScope.launch {
            controller.update { it.copy(message = "Adding the font…") }
            val f = copyIn(uri, "font_${System.currentTimeMillis()}") ?: return@launch c.repo.toast("Couldn't read that file")
            if (f.length() > studio.muse.core.edit.FontFile.MAX_BYTES) return@launch c.repo.toast("Fonts can be up to 10 MB")
            val bytes = withContext(Dispatchers.IO) { f.readBytes() }
            val name = studio.muse.core.edit.FontFile.name(bytes) ?: return@launch c.repo.toast("That isn't a .ttf or .otf font")
            val otf = bytes.size >= 4 && String(bytes, 0, 4, Charsets.ISO_8859_1) == "OTTO"
            val (id, err) = runCatching { c.repo.attemptInline { uploadEditorFile(f, if (otf) "font/otf" else "font/ttf", "font") } }.getOrElse { null to "Couldn't upload · try again" }
            if (id == null) return@launch c.repo.toast(err ?: "Couldn't upload · try again")
            val kept = withContext(Dispatchers.IO) { runCatching { f.copyTo(fontFile(id), overwrite = true) }.getOrNull() } ?: f
            OwnFonts.register(id, kept)
            controller.act(EditAction.AddFont(id, name))
            controller.project?.let { rebuildPreview(it) }
        }
    }

    private suspend fun copyIn(uri: Uri, name: String): File? = withContext(Dispatchers.IO) {
        runCatching {
            val f = File(app.cacheDir, "edit-suite/$name").apply { parentFile?.mkdirs() }
            app.contentResolver.openInputStream(uri)?.use { i -> f.outputStream().use { i.copyTo(it) } } ?: return@runCatching null
            f
        }.getOrNull()
    }

    fun addAudio(uri: Uri, voiceOver: Boolean, atSec: Double? = null) {
        viewModelScope.launch {
            val f = copyIn(uri, "audio_${System.currentTimeMillis()}") ?: return@launch c.repo.toast("Couldn't read that file")
            val dur = withContext(Dispatchers.IO) {
                runCatching { MediaMetadataRetriever().run { setDataSource(f.absolutePath); val d = extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toDouble(); release(); d } }.getOrNull()
            }?.div(1000) ?: return@launch c.repo.toast("That isn't an audio file this phone can read")
            val mime = app.contentResolver.getType(uri) ?: "audio/mp4"
            val (id, err) = runCatching { c.repo.attemptInline { uploadEditorFile(f, mime) } }.getOrElse { null to "Couldn't upload · try again" }
            if (id == null) return@launch c.repo.toast(err ?: "Couldn't upload · try again")
            controller.act(EditAction.AddAudio(id, (dur * 1000).roundToInt() / 1000.0, voiceOver, atSec))
            controller.project?.assets?.firstOrNull { it.upload == id }?.let { files[it.id] = f }
            controller.project?.let { loadWaves(it) }
        }
    }

    /**
     * A video imported from a link (WS7's import; or the saved file it falls back to): its file for the preview, then
     * added after the last clip as an upload asset (the export reads the same upload on the server).
     */
    fun addImported(v: studio.muse.app.data.ImportedVideo) {
        val upload = v.uploadId ?: return c.repo.toast("This video can't be added · import it again")
        if (v.durationSec < studio.muse.core.edit.EditLimits.MIN_CLIP_SOURCE_SEC) return c.repo.toast("This video is too short to add")
        viewModelScope.launch {
            val f = v.videoUrl?.let { url -> runCatching { engine.fetchSource(url) {} }.getOrNull() }
            controller.act(EditAction.AppendUpload(upload, v.durationSec, v.width.takeIf { it > 0 }, v.height.takeIf { it > 0 }, v.audio?.let { it.kind != "none" } ?: true))
            val p = controller.project ?: return@launch
            val a = p.assets.firstOrNull { it.upload == upload && it.kind == AssetKind.VIDEO } ?: return@launch
            if (f == null) return@launch c.repo.toast("Added · the preview can't show it until it downloads")
            files[a.id] = f
            rebuildPreview(p); loadWaves(p)
        }
    }

    /**
     * "Add a photo" (owner-approved design pass): the picked image, scaled to 2048 px on the long side at most (PNG when
     * it has transparency, else JPEG), uploaded as an editor asset and placed over the edit at the playhead.
     */
    fun addPhoto(uri: Uri) {
        viewModelScope.launch {
            controller.update { it.copy(message = "Adding the photo…") }
            val made = withContext(Dispatchers.IO) {
                runCatching {
                    val src = app.contentResolver.openInputStream(uri)?.use { android.graphics.BitmapFactory.decodeStream(it) } ?: return@runCatching null
                    val k = minOf(1f, 2048f / maxOf(src.width, src.height))
                    val bmp = if (k < 1f) android.graphics.Bitmap.createScaledBitmap(src, maxOf(1, (src.width * k).roundToInt()), maxOf(1, (src.height * k).roundToInt()), true) else src
                    val png = bmp.hasAlpha()
                    val f = File(app.cacheDir, "edit-suite/photo_${System.currentTimeMillis()}.${if (png) "png" else "jpg"}").apply { parentFile?.mkdirs() }
                    f.outputStream().use { bmp.compress(if (png) android.graphics.Bitmap.CompressFormat.PNG else android.graphics.Bitmap.CompressFormat.JPEG, 90, it) }
                    Triple(f, if (png) "image/png" else "image/jpeg", bmp.width to bmp.height)
                }.getOrNull()
            } ?: return@launch c.repo.toast("Couldn't read that photo")
            val (f, mime, size) = made
            val (id, err) = runCatching { c.repo.attemptInline { uploadEditorFile(f, mime) } }.getOrElse { null to "Couldn't upload · try again" }
            if (id == null) return@launch c.repo.toast(err ?: "Couldn't upload · try again")
            controller.act(EditAction.AddImage(id, size.first, size.second))
            controller.project?.assets?.firstOrNull { it.upload == id }?.let { files[it.id] = f }
            controller.project?.let { rebuildPreview(it) }
        }
    }

    // ------------------------------------------------------------ style kits
    private fun kitsOf(list: List<studio.muse.app.data.EditKit>) = list.mapNotNull { k -> runCatching { KitChoice(k.id, k.name, studio.muse.core.edit.parseKit(k.kit)) }.getOrNull() }

    // ------------------------------------------------------------ content library
    private val contentDir get() = File(app.cacheDir, "edit-suite/content").apply { mkdirs() }

    /** The catalog: from the server (kept on disk for next time), else the copy on disk. */
    private suspend fun loadContent() {
        val disk = File(contentDir, "catalog.json")
        val text = runCatching { c.repo.api.editorContentCatalog() }.getOrNull()?.also { t -> withContext(Dispatchers.IO) { runCatching { disk.writeText(t) } } }
            ?: withContext(Dispatchers.IO) { disk.takeIf { it.exists() }?.readText() } ?: return
        val cat = runCatching { studio.muse.app.platform.edit.ContentCatalog.parse(text) }.getOrNull() ?: return
        studio.muse.app.platform.edit.ContentLibrary.catalog = cat
        // Files already on disk for this version.
        val here = HashSet<String>()
        File(contentDir, cat.version).takeIf { it.exists() }?.walkTopDown()?.filter { it.isFile }?.forEach { f ->
            val rel = f.relativeTo(File(contentDir, cat.version)).path
            studio.muse.app.platform.edit.ContentLibrary.register(rel, f); here += rel
        }
        controller.update { it.copy(content = cat, contentHere = here) }
        controller.project?.let { if (contentMissing(it).isNotEmpty()) ensureContent(it) }
    }

    /** Catalog paths the edit uses that aren't on this phone yet: its stickers and sounds, and its content fonts' weights. */
    private fun contentMissing(p: EditProject): List<String> {
        val cat = studio.muse.app.platform.edit.ContentLibrary.catalog ?: return emptyList()
        val paths = p.assets.mapNotNull { a -> a.library?.let { cat.item(it)?.file } } +
            p.tracks.flatMap { t -> t.items.filterIsInstance<studio.muse.core.edit.TextItem>().map { it.style } + listOfNotNull(t.caption?.style?.text) }
                .filter { it.font.isContent }.mapNotNull { cat.fontPath(it.font, it.weight) }
        return paths.distinct().filter { !studio.muse.app.platform.edit.ContentLibrary.has(it) }
    }

    private var contentJob: kotlinx.coroutines.Job? = null
    /** Downloads what the edit uses from the content library, then links its assets' files and redraws. */
    private fun ensureContent(p: EditProject) {
        if (contentJob?.isActive == true) return
        contentJob = viewModelScope.launch {
            for (path in contentMissing(p)) contentFile(path)
            val cur = controller.project ?: return@launch
            for (a in cur.assets) a.library?.let { studio.muse.app.platform.edit.ContentLibrary.fileOf(it) }?.let { files[a.id] = it }
            rebuildPreview(cur)
        }
    }

    /** One catalog file on this phone (downloaded once per catalog version). */
    suspend fun contentFile(path: String): File? {
        studio.muse.app.platform.edit.ContentLibrary.file(path)?.let { return it }
        val cat = studio.muse.app.platform.edit.ContentLibrary.catalog ?: return null
        val url = c.repo.api.editorContentUrl(path) ?: return null
        val dst = File(contentDir, "${cat.version}/$path").apply { parentFile?.mkdirs() }
        val got = runCatching { engine.fetchSource(url) {} }.getOrNull() ?: return null
        withContext(Dispatchers.IO) { runCatching { got.copyTo(dst, overwrite = true) } }.getOrNull() ?: return null
        studio.muse.app.platform.edit.ContentLibrary.register(path, dst)
        controller.update { it.copy(contentHere = it.contentHere + path) }
        return dst
    }

    /**
     * Auto reframe: the active clip's source sampled at 5 fps, faces found on this phone (ML Kit), then its x keyframes
     * set to follow the speaker (studio.muse.core.edit.Reframe).
     */
    fun reframe() {
        val u = controller.ui.value
        val p = controller.project ?: return
        val clip = (u.selection?.second as? studio.muse.core.edit.VideoClip) ?: u.activeClip ?: return
        if (u.reframing != null) return
        val a = p.asset(clip.asset) ?: return
        val file = files[clip.asset] ?: return c.repo.toast("This clip isn't on the phone yet · try again in a moment")
        val cover = studio.muse.core.edit.Reframe.coverWidth(a.width ?: return, a.height ?: return, p.canvas.width, p.canvas.height, clip.transform?.scale ?: 1.0)
        if (cover <= 1.05) return c.repo.toast("This clip already fills the frame")
        viewModelScope.launch {
            controller.update { it.copy(reframing = 0f) }
            try {
                val times = studio.muse.core.edit.Reframe.sampleTimes(studio.muse.core.edit.clipLength(clip))
                val samples = studio.muse.app.platform.edit.FaceSampler.sample(file, times, { studio.muse.core.edit.clipSourceAt(clip, it) }) { f -> controller.update { it.copy(reframing = f) } }
                val keys = studio.muse.core.edit.Reframe.keyframes(samples, cover)
                if (keys.isEmpty()) c.repo.toast("No face found in this clip") else controller.act(EditAction.ApplyReframe(clip.id, keys))
            } catch (e: kotlinx.coroutines.CancellationException) { throw e
            } catch (e: Exception) { c.repo.toast("Couldn't look for faces · try again")
            } finally { controller.update { it.copy(reframing = null) } }
        }
    }

    /** A sticker or sound effect: its file first (so the preview has it), then into the edit. */
    fun addContent(item: studio.muse.app.platform.edit.ContentItem) {
        viewModelScope.launch {
            val f = item.file?.let { contentFile(it) } ?: return@launch c.repo.toast("Couldn't download that · try again")
            if (item.kind == "stickers") controller.act(EditAction.AddSticker(item.ref, item.width ?: 160, item.height ?: 160))
            else controller.act(EditAction.AddSoundEffect(item.ref, item.durationSec ?: 1.0, item.name))
            controller.project?.assets?.firstOrNull { it.library == item.ref }?.let { files[it.id] = f }
            controller.project?.let { rebuildPreview(it); loadWaves(it) }
        }
    }

    /** The local file if downloaded, else the server's URL (sticker thumbnails). */
    fun contentUrl(path: String): String? = studio.muse.app.platform.edit.ContentLibrary.file(path)?.absolutePath ?: c.repo.api.editorContentUrl(path)

    private val _soundPlaying = kotlinx.coroutines.flow.MutableStateFlow<String?>(null)
    val soundPlaying: kotlinx.coroutines.flow.StateFlow<String?> = _soundPlaying

    private var preview: android.media.MediaPlayer? = null
    /** Plays a sound effect once (the list's preview); a second tap or another sound stops it. */
    fun previewSound(item: studio.muse.app.platform.edit.ContentItem?) {
        preview?.runCatching { stop(); release() }; preview = null
        _soundPlaying.value = item?.ref
        val path = item?.file ?: return
        viewModelScope.launch {
            val f = contentFile(path) ?: return@launch
            preview = android.media.MediaPlayer().apply { runCatching { setDataSource(f.absolutePath); prepare(); start(); setOnCompletionListener { it.release(); if (preview === it) { preview = null; _soundPlaying.value = null } } } }
        }
    }

    fun loadKits() {
        viewModelScope.launch {
            runCatching { c.repo.api.editKits() }
                .onSuccess { l -> controller.update { it.copy(kits = kitsOf(l), kitsNote = null) } }
                .onFailure { e -> controller.update { it.copy(kitsNote = (e as? studio.muse.app.data.ApiException)?.message ?: "Couldn't load your style kits") } }
        }
    }

    /** Saves the edit's style ([studio.muse.core.edit.kitOf]) as kit [name]. */
    fun saveKit(name: String) {
        val p = controller.project ?: return
        val kit = studio.muse.core.edit.kitOf(p)
        if (kit.isEmpty) return c.repo.toast("This edit has no style to save yet · add a look, colour, transition or captions")
        viewModelScope.launch {
            runCatching { c.repo.api.saveEditKit(name.trim().take(60).ifEmpty { "${controller.ui.value.title} style" }, studio.muse.core.edit.encodeKit(kit)) }
                .onSuccess { c.repo.toast("Saved “${it.name}”"); loadKits() }
                .onFailure { e -> c.repo.toast((e as? studio.muse.app.data.ApiException)?.message ?: "Couldn't save the style kit · try again") }
        }
    }

    fun deleteKit(id: String) {
        viewModelScope.launch {
            runCatching { c.repo.api.deleteEditKit(id) }.onSuccess { loadKits() }.onFailure { c.repo.toast("Couldn't delete that style kit · try again") }
        }
    }

    /**
     * Auto adjust: the selected picture's (or the clip under the playhead's) source frame at the playhead, read small
     * (96 px) from its file, then the controller's [EditAction.AutoAdjust].
     */
    fun autoAdjust() {
        val u = controller.ui.value
        val clip = (u.selection?.second as? VideoClip) ?: u.activeClip ?: return c.repo.toast("Select a clip to adjust")
        viewModelScope.launch {
            val (_, _, px) = sourceFrame(clip.id, 96) ?: return@launch c.repo.toast("Couldn't read this frame · try another spot")
            controller.act(EditAction.AutoAdjust(DoubleArray(px.size * 3) { j -> ((px[j / 3] shr (16 - 8 * (j % 3))) and 0xFF) / 255.0 }))
        }
    }

    /**
     * Clip [clipId]'s source frame at the playhead (before its look), at most [maxSide] px on the long side, as ARGB: for
     * Auto adjust and the chroma eyedropper. Null when the clip's file isn't on the phone or the frame can't be read.
     */
    private suspend fun sourceFrame(clipId: String, maxSide: Int): Triple<Int, Int, IntArray>? {
        val p = controller.project ?: return null
        val (tr, i) = p.locate(clipId) ?: return null
        val clip = tr.items[i] as? VideoClip ?: return null
        val f = files[clip.asset] ?: return null
        val local = (controller.ui.value.playheadSec - itemSpan(p, tr, clip).startSec).coerceAtLeast(0.0)
        val src = studio.muse.core.edit.clipSourceAt(clip, local)
        return withContext(Dispatchers.IO) {
            runCatching {
                val r = MediaMetadataRetriever()
                try {
                    r.setDataSource(f.absolutePath)
                    val bmp = r.getFrameAtTime((src * 1_000_000).toLong(), MediaMetadataRetriever.OPTION_CLOSEST) ?: return@runCatching null
                    val k = minOf(1f, maxSide.toFloat() / maxOf(bmp.width, bmp.height))
                    val small = if (k < 1f) android.graphics.Bitmap.createScaledBitmap(bmp, maxOf(1, (bmp.width * k).roundToInt()), maxOf(1, (bmp.height * k).roundToInt()), true) else bmp
                    Triple(small.width, small.height, IntArray(small.width * small.height).also { small.getPixels(it, 0, small.width, 0, 0, small.width, small.height) })
                } finally { r.release() }
            }.getOrNull()
        }
    }

    /** The frame under the playhead, rendered like the export (looks, text, captions), into Pictures/MUSE. */
    fun saveFrame() {
        val p = controller.project ?: return
        if (!canRender) return c.repo.toast(if (emptyBlank) "Add a video first" else "This video has no file to take a frame from")
        val t = controller.ui.value.playheadSec
        viewModelScope.launch {
            val png = runCatching {
                studio.muse.app.platform.edit.FrameStill(app, looks).png(composer.plan(playable(p), files), files, t, minOf(p.canvas.width, 2160))
            }.getOrNull() ?: return@launch c.repo.toast("Couldn't take that frame · try again")
            val ok = withContext(Dispatchers.IO) {
                runCatching {
                    val v = ContentValues().apply {
                        put(MediaStore.Images.Media.DISPLAY_NAME, "MUSE frame ${System.currentTimeMillis() / 1000}.png"); put(MediaStore.Images.Media.MIME_TYPE, "image/png")
                        if (Build.VERSION.SDK_INT >= 29) put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/MUSE")
                    }
                    val uri = app.contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, v) ?: return@runCatching false
                    app.contentResolver.openOutputStream(uri)?.use { it.write(png) } != null
                }.getOrDefault(false)
            }
            c.repo.toast(if (ok) "Frame saved to Photos · Pictures/MUSE" else "Couldn't save the frame to this phone")
        }
    }

    // ------------------------------------------------------------ voice-over
    private var recorder: android.media.MediaRecorder? = null
    private var voFile: File? = null

    /** Starts recording a voice-over at the playhead (the preview pauses so its sound isn't recorded). */
    fun startVoiceOver() {
        if (recorder != null) return
        pause()
        val f = File(app.cacheDir, "edit-suite/vo_${System.currentTimeMillis()}.m4a").apply { parentFile?.mkdirs() }
        val r = (if (Build.VERSION.SDK_INT >= 31) android.media.MediaRecorder(app) else @Suppress("DEPRECATION") android.media.MediaRecorder())
        try {
            r.setAudioSource(android.media.MediaRecorder.AudioSource.MIC)
            r.setOutputFormat(android.media.MediaRecorder.OutputFormat.MPEG_4)
            r.setAudioEncoder(android.media.MediaRecorder.AudioEncoder.AAC)
            r.setAudioEncodingBitRate(128_000); r.setAudioSamplingRate(44_100)
            r.setOutputFile(f.absolutePath)
            r.prepare(); r.start()
        } catch (e: Exception) { r.release(); f.delete(); c.repo.toast("Couldn't start the microphone · try again"); return }
        recorder = r; voFile = f
        controller.update { it.copy(recordingAt = it.playheadSec) }
        // Hearing the video while recording: the preview plays from the playhead with the edit's sound.
        val route = outputRoute()
        voLatency = if (controller.ui.value.voPlayback ?: route.headphones) route.latencySec else null
        if (voLatency != null) controller.setPlayback(controller.ui.value.playheadSec, true)
    }

    /** Stops the voice-over and adds it to the Voice-over lane where recording started. */
    fun stopVoiceOver() {
        val r = recorder ?: return
        val f = voFile
        val at = controller.ui.value.recordingAt
        recorder = null; voFile = null
        val lag = voLatency ?: 0.0
        voLatency = null
        if (controller.ui.value.playing) pause()
        val ok = runCatching { r.stop() }.isSuccess
        r.release()
        controller.update { it.copy(recordingAt = null) }
        if (!ok || f == null || f.length() == 0L) { f?.delete(); c.repo.toast("That recording was too short · hold on a little longer"); return }
        // Heard late by the output's latency, the voice is late by it too: the take goes that much earlier.
        addAudio(Uri.fromFile(f), voiceOver = true, atSec = at?.let { maxOf(0.0, it - lag) })
    }

    /** While recording with the video playing: the output route's latency (s); null when the video isn't playing. */
    private var voLatency: Double? = null

    data class OutputRoute(val headphones: Boolean, val latencySec: Double)

    /**
     * The current audio output: headphones (wired, USB, Bluetooth) or the speaker, and its latency. Android has no
     * public output-latency API, so the latency is the typical figure for the route (Bluetooth about 200 ms, wired and
     * USB about 20 ms); measured per route on a device later if the takes drift.
     */
    fun outputRoute(): OutputRoute {
        val am = app.getSystemService(android.content.Context.AUDIO_SERVICE) as android.media.AudioManager
        val outs = am.getDevices(android.media.AudioManager.GET_DEVICES_OUTPUTS).map { it.type }
        val bt = outs.any { it == android.media.AudioDeviceInfo.TYPE_BLUETOOTH_A2DP || (Build.VERSION.SDK_INT >= 31 && it == android.media.AudioDeviceInfo.TYPE_BLE_HEADSET) }
        val wired = outs.any { it == android.media.AudioDeviceInfo.TYPE_WIRED_HEADPHONES || it == android.media.AudioDeviceInfo.TYPE_WIRED_HEADSET || it == android.media.AudioDeviceInfo.TYPE_USB_HEADSET }
        return OutputRoute(bt || wired, if (bt) 0.2 else if (wired) 0.02 else 0.0)
    }

    fun importCube(uri: Uri) {
        viewModelScope.launch {
            val f = copyIn(uri, "look_${System.currentTimeMillis()}.cube") ?: return@launch controller.act(EditAction.ImportedCube(null, "Couldn't read that file"))
            when (val check = LookLibrary.checkImport(f)) {
                is CubeCheck.Bad -> controller.act(EditAction.ImportedCube(null, ".cube: ${check.message}"))
                is CubeCheck.Ok -> {
                    val (id, err) = runCatching { c.repo.attemptInline { uploadEditorFile(f, "application/x-cube", "lut") } }.getOrElse { null to "Couldn't upload · try again" }
                    if (id == null) return@launch controller.act(EditAction.ImportedCube(null, err ?: "Couldn't upload · try again"))
                    controller.act(EditAction.ImportedCube(id, "${check.title ?: "Imported look"} · ${check.size}³"))
                    controller.project?.assets?.firstOrNull { it.upload == id }?.let { files[it.id] = f }
                }
            }
        }
    }

    private val _fxThumbs = MutableStateFlow<Map<String, ImageBitmap>>(emptyMap())
    val effectThumbs: StateFlow<Map<String, ImageBitmap>> = _fxThumbs.asStateFlow()

    /** Effect tiles: each effect (at 80 %) on a small frame under the playhead, on the CPU reference (once per editor). */
    fun renderEffectThumbs() {
        if (_fxThumbs.value.isNotEmpty()) return
        val f = stillSource() ?: return
        viewModelScope.launch {
            val frame = runCatching { engine.frames(f, listOf(controller.ui.value.playheadSec.coerceAtLeast(0.1)), 120).firstOrNull() }.getOrNull() ?: return@launch
            val map = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) {
                runCatching { studio.muse.app.platform.edit.EffectThumbnails.render(frame, controller.ui.value.playheadSec) }.getOrNull()
            } ?: return@launch
            _fxThumbs.value = map.mapValues { it.value.asImageBitmap() }
        }
    }

    /** Filter thumbnails: every look on the frame under the playhead. */
    fun renderLookThumbs() {
        if (_thumbs.value.isNotEmpty()) return
        val f = stillSource() ?: return
        viewModelScope.launch {
            val frame = runCatching { engine.frames(f, listOf(controller.ui.value.playheadSec.coerceAtLeast(0.1)), 240).firstOrNull() }.getOrNull() ?: return@launch
            val map = runCatching { LookThumbnails.renderPack(frame, looks) }.getOrNull() ?: return@launch
            _thumbs.value = map.mapValues { it.value.asImageBitmap() }
        }
    }

    // ------------------------------------------------------------ Edit sessions (workstream 3): owner only
    /** The owner's editor joins the take's edit session (Claude edits it too); members and offline stay local. */
    private fun startSession(sourceTakeId: String, project: EditProject, fromVersion: String?, attach: String? = null) {
        if (!(c.repo.demo || c.prefs.value.owner)) return
        controller.update { it.copy(claudeOwner = true) } // the Claude button shows, dimmed until the session is there
        val s = EditSessionSync(viewModelScope, { c.repo.api }, c.repo.live, controller, sessionHost, deviceId(), Build.MODEL ?: "Android phone", looks.paletteIds,
            drafts = FileEditDrafts(File(app.filesDir, "edit-drafts")))
        sync = s
        // The app's own project goes up only when it was built from a saved version (else the server starts from the take).
        // Offline: the editor works locally and joins when the connection is back (asking first if this device has edits).
        viewModelScope.launch { s.connect(sourceTakeId, if (fromVersion != null) EditJson.encode(project) else null, fromVersion, attach = attach) }
    }

    private fun deviceId(): String {
        val raw = runCatching { android.provider.Settings.Secure.getString(app.contentResolver, android.provider.Settings.Secure.ANDROID_ID) }.getOrNull() ?: "device"
        return "android-" + raw.hashCode().toUInt().toString(16)
    }

    private val sessionHost by lazy { object : SessionHost {
        override suspend fun renderFrame(project: EditProject, t: Double, width: Int): Pair<ByteArray?, String?> {
            if (!canRender) return null to "No video file"
            return runCatching { studio.muse.app.platform.edit.FrameStill(app, looks).png(composer.plan(playable(project), files), files, t, width) }
                .fold({ it to null }, { null to "Couldn't render the frame" })
        }
        override suspend fun saveVersion(name: String?): Pair<String?, String?> {
            val take = exportAndSave(toPhone = false, name = name) ?: return null to (lastExportError ?: "Couldn't save the video")
            return take.id to null
        }
        /** Never unattended: the export sheet opens with Claude's preset and waits for the owner's tap (or close). */
        override suspend fun export(preset: JsonObject?): Pair<String?, String?> = exportGate.request(preset)
    } }
    private val exportGate by lazy { OwnerExportGate(viewModelScope, controller) }

    // ------------------------------------------------------------ export

    fun export(toPhone: Boolean) {
        exporting?.cancel()
        val format = controller.ui.value.export.format
        exporting = viewModelScope.launch { if (format == ExportFormat.VIDEO) exportAndSave(toPhone) else exportToPhone(format) }
    }

    /**
     * Sound only or a GIF (plans/edit-parity.md, S rows): the edit rendered by the same engine (small for sound; at the
     * GIF's size and rate for a GIF), then remuxed / turned into GIF frames, into Music/MUSE or Pictures/MUSE. Neither is
     * saved as a version (versions are videos).
     */
    private suspend fun exportToPhone(format: ExportFormat) {
        val p = controller.project ?: return
        val u = controller.ui.value
        if (!canRender) return c.repo.toast(if (emptyBlank) "Add a video first · the main track is empty" else "This video has no file to render · open a finished render")
        u.export.refusal(u.duration, SuiteOps.editHasSound(playable(p)))?.let { return controller.setPhase(SuitePhase.Failed(it)) }
        withContext(Dispatchers.Main) { pause() }
        // Sound only: a small, quick picture (it's thrown away); a GIF: its own size and frame rate.
        val s = if (format == ExportFormat.SOUND) u.export.copy(format = ExportFormat.VIDEO, resolution = ExportResolution.HD, fps = 24, bitrate = ExportBitrate.LOWER) else u.export
        val renderShare = if (format == ExportFormat.GIF) .6f else 1f
        controller.setPhase(SuitePhase.Exporting(0f))
        var made: File? = null
        val out = File(app.cacheDir, "edit-suite/export_${System.currentTimeMillis()}.${if (format == ExportFormat.GIF) "gif" else "m4a"}").apply { parentFile?.mkdirs() }
        try {
            val plan = composer.plan(exportProject(playable(p), s), files)
            val (w, h) = s.size
            val video = composer.export(plan, files, androidx.media3.common.MimeTypes.VIDEO_H264, videoBitrate(w, h, s.outFps, s.bitrate), SOUND_BITRATE) { pr -> controller.setPhase(SuitePhase.Exporting(pr * renderShare)) }
            made = video.file
            val ok = when (format) {
                ExportFormat.SOUND -> withContext(Dispatchers.IO) { studio.muse.app.platform.edit.ExportFormats.soundOnly(video.file, out) }
                else -> studio.muse.app.platform.edit.ExportFormats.gif(video.file, out, GIF_FPS) { pr -> controller.setPhase(SuitePhase.Exporting(renderShare + pr * (1 - renderShare))) } > 0
            }
            if (!ok) return controller.setPhase(SuitePhase.Failed(if (format == ExportFormat.SOUND) "This edit has no sound to export" else "Couldn't make the GIF · try again"))
            controller.setPhase(SuitePhase.Saving(0f))
            val where = withContext(Dispatchers.IO) { savePhoneFile(out, format, u.title) }
                ?: return controller.setPhase(SuitePhase.Failed("Couldn't save to this phone"))
            controller.update { it.copy(phase = SuitePhase.Ready, panel = null, message = "Saved to this phone · $where") }
        } catch (e: kotlinx.coroutines.CancellationException) { controller.setPhase(SuitePhase.Ready); throw e
        } catch (e: Exception) {
            controller.setPhase(SuitePhase.Failed(if (format == ExportFormat.GIF) "This phone couldn't make the GIF · try again" else "This phone couldn't make the sound file · try again"))
        } finally { made?.delete(); out.delete() }
    }

    /** An .m4a into Music/MUSE or a .gif into Pictures/MUSE; the folder, or null. */
    private fun savePhoneFile(f: File, format: ExportFormat, title: String): String? {
        val name = "MUSE ${title.take(40)} ${System.currentTimeMillis() / 1000}"
        val r = app.contentResolver
        val sound = format == ExportFormat.SOUND
        val folder = if (sound) "Music/MUSE" else "Pictures/MUSE"
        val v = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, "$name.${if (sound) "m4a" else "gif"}")
            put(MediaStore.MediaColumns.MIME_TYPE, if (sound) "audio/mp4" else "image/gif")
            if (Build.VERSION.SDK_INT >= 29) put(MediaStore.MediaColumns.RELATIVE_PATH, folder)
        }
        val uri = r.insert(if (sound) MediaStore.Audio.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI, v) ?: return null
        r.openOutputStream(uri)?.use { o -> f.inputStream().use { it.copyTo(o) } } ?: return null
        return folder
    }

    /** Renders and saves a new version (and a copy on the phone); the saved take, or null with [lastExportError]. */
    private suspend fun exportAndSave(toPhone: Boolean, name: String? = null): Take? {
        lastExportError = null
        val p = controller.project ?: return null
        val u = controller.ui.value
        if (!canRender) {
            lastExportError = if (emptyBlank) "Add a video first · the main track is empty" else "No video file"
            c.repo.toast(if (emptyBlank) lastExportError!! else "This video has no file to render · open a finished render"); return null
        }
        withContext(Dispatchers.Main) { pause() }
        val s = u.export.copy(format = ExportFormat.VIDEO) // versions are videos (Claude's export asks for one too)
        controller.setPhase(SuitePhase.Exporting(0f))
        val made = try {
            val plan = composer.plan(exportProject(playable(p), s), files)
            val (w, h) = s.size
            composer.export(plan, files, if (s.codec == ExportCodec.HEVC) androidx.media3.common.MimeTypes.VIDEO_H265 else androidx.media3.common.MimeTypes.VIDEO_H264,
                videoBitrate(w, h, s.fps, s.bitrate, s.codec), null) { pr ->
                controller.setPhase(SuitePhase.Exporting(pr))
            }
        } catch (e: kotlinx.coroutines.CancellationException) { controller.setPhase(SuitePhase.Ready); throw e
        } catch (e: Exception) {
            lastExportError = "This phone couldn't make the video · try 1080p or H.264"
            controller.setPhase(SuitePhase.Failed(lastExportError!!)); return null
        }
        val srt = if (s.captions == CaptionExport.SRT) toSrt(p).takeIf { it.isNotEmpty() } else null
        controller.setPhase(SuitePhase.Saving(0f))
        try {
            // The saved project is the edit as made (canvas = the exported size and fps; captions kept for reopening).
            // A blank project: its first save is a new Library video (POST /v1/edits), later ones versions of that video.
            val sourceId = blankSavedId ?: u.sourceTakeId
            val saved = p.copy(sourceTakeId = sourceId, canvas = p.canvas.copy(width = made.width, height = made.height, fps = s.fps.toDouble()))
            val (take, err) = c.repo.attemptInline { saveProjectVersion(sourceId, made, EditJson.encode(saved), name, { pr -> controller.setPhase(SuitePhase.Saving(pr)) }, aiLabel = s.aiLabel) }
            if (toPhone) withContext(Dispatchers.IO) { saveToPhone(made.file, srt, u.title) }
            if (take == null) { lastExportError = err ?: "Couldn't save the video"; controller.setPhase(SuitePhase.Failed(lastExportError!!)); return null }
            exportGate.exported(take.id) // answers an export Claude asked for, before the sheet closes
            if (sourceId == studio.muse.core.edit.BLANK_SOURCE) blankSavedId = take.id
            val newVideo = take.parentTakeId == null
            controller.update { it.copy(phase = SuitePhase.Ready, savedTakeId = take.id, panel = null, message = when {
                toPhone -> "Saved to Library and to this phone"
                newVideo -> "Saved to the Library as a new video"
                else -> "Saved as a new version · Edited"
            }) }
            return take
        } finally { made.file.delete() }
    }

    fun cancelExport() { exporting?.cancel(); controller.setPhase(SuitePhase.Ready); exportGate.cancelled() }

    /** The MP4 into Movies/MUSE (and the .srt into Downloads/MUSE on Android 10+). */
    private fun saveToPhone(mp4: File, srt: String?, title: String) {
        val name = "MUSE ${title.take(40)} ${System.currentTimeMillis() / 1000}"
        val r = app.contentResolver
        if (Build.VERSION.SDK_INT >= 29) {
            val v = ContentValues().apply {
                put(MediaStore.Video.Media.DISPLAY_NAME, "$name.mp4"); put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
                put(MediaStore.Video.Media.RELATIVE_PATH, "Movies/MUSE")
            }
            r.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, v)?.let { uri -> r.openOutputStream(uri)?.use { o -> mp4.inputStream().use { it.copyTo(o) } } }
            if (srt != null) {
                val sv = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, "$name.srt"); put(MediaStore.Downloads.MIME_TYPE, "application/x-subrip")
                    put(MediaStore.Downloads.RELATIVE_PATH, "Download/MUSE")
                }
                r.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, sv)?.let { uri -> r.openOutputStream(uri)?.use { it.write(srt.toByteArray()) } }
            }
        }
    }

    override fun onCleared() {
        savePlace()
        placeTracking = false
        recorder?.let { runCatching { it.stop() }; it.release() }; recorder = null
        work?.cancel(); exporting?.cancel()
        sync?.stop(c.scope); sync = null
        _player.value?.release(); _player.value = null
    }

    companion object {
        /**
         * The whole source as one clip on a canvas the size of the source. [lut]: the take's suite look (workstream 1,
         * `Take.look.lut`, e.g. "palette:<id>"), put on the clip at full strength like the server's edit sessions do.
         */
        fun newProject(takeId: String, durationSec: Double, size: SourceSize, lut: String? = null): EditProject = EditProject(
            2, takeId, Canvas(size.width, size.height, size.fps, "#000000"),
            listOf(Asset("src", AssetKind.VIDEO, take = takeId, durationSec = durationSec, width = size.width, height = size.height, hasAudio = size.hasAudio ?: true)),
            listOf(Track("main", TrackKind.MAIN, items = listOf(VideoClip("c1", "src", 0.0, durationSec, 1.0,
                look = lut?.takeIf { it.isNotBlank() }?.let { studio.muse.core.edit.Look(lut = it, strength = 1.0) })))),
        )
    }
}

/** The project with only what has a local file in [have] (assets made on the server without a URL are left out of the preview/export). */
fun playableProject(p: EditProject, have: Set<String>): EditProject {
    val tracks = p.tracks.mapNotNull { t ->
        val items = t.items.filter { it ->
            when (it) { is VideoClip -> it.asset in have; is AudioClip -> it.asset in have; is ImageItem -> it.asset in have; else -> true }
        }.map { if (it is VideoClip && it.audioAsset != null && it.audioAsset !in have) it.copy(audioAsset = null) else it }
        if (t.kind == TrackKind.MAIN || items.isNotEmpty() || t.kind == TrackKind.CAPTION) t.copy(items = items) else null
    }
    val looksOk = tracks.map { t -> t.copy(items = t.items.map { it -> if (it is VideoClip && it.look?.lutAssetId?.let { l -> l !in have } == true) it.copy(look = it.look!!.copy(lut = null)) else it }) }
    return p.copy(tracks = looksOk)
}

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
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
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
import studio.muse.core.edit.ExportCodec
import studio.muse.core.edit.ImageItem
import studio.muse.core.edit.SourceSize
import studio.muse.core.edit.Track
import studio.muse.core.edit.TrackKind
import studio.muse.core.edit.VideoClip
import studio.muse.core.edit.exportProject
import studio.muse.core.edit.fromV1
import studio.muse.core.edit.problemOf
import studio.muse.core.edit.toSrt
import java.io.File
import kotlin.math.roundToInt

/**
 * The Edit suite (designs EM1–EM5 / E1–E4), the editor for every video take and edited version. With a [takeId] it
 * opens that video (an edited version reopens its project on its source: v2 projects as saved, v1 edit lists through
 * `fromV1`); without one it shows the Edit home — recent videos and edited versions to open. Navigation entries are
 * the app shell's (workstream 1).
 */
@Composable
fun EditSuiteScreen(takeId: String?, onBack: () -> Unit) {
    var open by rememberSaveable(takeId) { mutableStateOf(takeId) }
    var recreating by rememberSaveable { mutableStateOf(false) } // "Recreate an edit" (plans/recreate-edit.md)
    var reference by rememberSaveable { mutableStateOf<String?>(null) } // a library reference opened in the Recipe view
    var learn by rememberSaveable { mutableStateOf<String?>(null) } // "playbook" | "recipes" (plans/learning-editor-ui.md), owner only
    // Share → MUSE: what another app shared opens Recreate with it, once.
    val c = LocalContainer.current
    val sharedNow by c.shared.collectAsState()
    var shared by remember { mutableStateOf<studio.muse.app.data.SharedReference?>(null) }
    LaunchedEffect(sharedNow) { sharedNow?.let { shared = it; c.shared.value = null; open = null; learn = null; reference = null; recreating = true } }
    val id = open
    if (recreating) androidx.compose.runtime.key(shared) {
        RecipeScreen(onBack = { recreating = false; reference = null; shared = null }, referenceId = reference, shared = shared,
            onOpenTake = { recreating = false; reference = null; shared = null; open = it })
    }
    else if (id == null && learn == "playbook") studio.muse.app.ui.screens.edit.learn.PlaybookScreen(onBack = { learn = null }, onOpenTake = { open = it })
    else if (id == null && learn == "recipes") studio.muse.app.ui.screens.edit.learn.RecipesScreen(
        onBack = { learn = null }, onOpenTake = { open = it }, onOpenReference = { reference = it; recreating = true }, onRecreate = { recreating = true })
    else if (id == null) EditHome(onBack, onRecreate = { recreating = true }, onLearn = { learn = it }) { open = it }
    // "Open playbook" in the editor's Claude sheet leaves the editor for the Playbook.
    else androidx.compose.runtime.CompositionLocalProvider(LocalOpenPlaybook provides { open = null; learn = "playbook" }) {
        EditSuiteEditor(id, onBack = { if (takeId == null) open = null else onBack() })
    }
}

// ======================================================================= home
/** The videos the suite can open, newest first (renders and edited versions). */
fun editableTakes(takes: List<Take>): List<TakeChoice> = takes.filter { it.kind == "take" || it.kind == "edit" }.sortedByDescending { it.createdAt }.map {
    TakeChoice(it.id, it.title, if (it.kind == "edit") "Edited" else it.label, it.thumb, it.durationSec, it.kind == "edit", it.videoUrl != null)
}

@Composable
fun EditHome(onBack: () -> Unit, onRecreate: () -> Unit, onLearn: (String) -> Unit = {}, onOpen: (String) -> Unit) {
    val c = LocalContainer.current
    val state by c.repo.state.collectAsState()
    val prefs by c.prefs.collectAsState()
    val owner = c.repo.demo || prefs.owner // the learning editor is the owner's (the server answers members 403)
    // "Recreate an edit": WS1's /v1/recreate/references (demo mode: FakeMuseApi's).
    EditHomeContent(editableTakes(state.takes), onBack, onOpen, onRecreate = onRecreate, onLearn = onLearn.takeIf { owner })
}

@Composable
fun EditHomeContent(takes: List<TakeChoice>, onBack: () -> Unit, onOpen: (String) -> Unit, onRecreate: (() -> Unit)? = null, onLearn: ((String) -> Unit)? = null) {
    val m = muse
    ScreenBox(statusPad = true) {
        Column(Modifier.fillMaxSize()) {
            TopBar("Edit", onBack = onBack)
            LazyColumn(Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
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
                val edited = takes.filter { it.edited }; val renders = takes.filter { !it.edited }
                if (takes.isEmpty()) item { T("No videos yet · make one in the Video suite", m.type.body, m.t.muted) }
                if (edited.isNotEmpty()) { item { SuiteLabel("Edited versions", color = m.t.muted) }; edited.forEach { t -> item(t.id) { HomeRow(t, onOpen) } } }
                if (renders.isNotEmpty()) { item { SuiteLabel("Recent videos", color = m.t.muted) }; renders.forEach { t -> item(t.id) { HomeRow(t, onOpen) } } }
            }
        }
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
private fun EditSuiteEditor(takeId: String, onBack: () -> Unit) {
    val c = LocalContainer.current
    val context = LocalContext.current
    val vm: EditSuiteViewModel = viewModel(key = "edit-suite-$takeId") { EditSuiteViewModel(c, takeId, context) }
    val ui by vm.controller.ui.collectAsState()
    val frames by vm.frames.collectAsState()
    val thumbs by vm.lookThumbs.collectAsState()
    val player by vm.player.collectAsState()
    LaunchedEffect(ui.message) { ui.message?.let { c.repo.toast(it); vm.controller.act(EditAction.ClearMessage) } }
    LaunchedEffect(ui.panel) { if (ui.panel == Panel.FILTERS) vm.renderLookThumbs() }
    androidx.lifecycle.compose.LifecycleResumeEffect(vm) { onPauseOrDispose { vm.pause() } }
    val audio = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri -> uri?.let { vm.addAudio(it, voiceOver = false) } }
    val record = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { r -> r.data?.data?.let { vm.addAudio(it, voiceOver = true) } }
    val cube = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri -> uri?.let { vm.importCube(it) } }
    val host = SuiteHost(
        pickAudio = { audio.launch("audio/*") },
        recordVo = {
            val i = Intent(MediaStore.Audio.Media.RECORD_SOUND_ACTION)
            if (i.resolveActivity(context.packageManager) != null) record.launch(i) else c.repo.toast("No voice recorder on this phone · pick a recording with Music from uploads")
        },
        importCube = { cube.launch("*/*") },
        export = vm::export,
        cancelExport = vm::cancelExport,
        lookThumbs = thumbs,
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

    override suspend fun matteUnavailable(): String? {
        val m = c.repo.api.editorFeatures()?.get("matte") as? kotlinx.serialization.json.JsonObject ?: return null
        if ((m["available"] as? kotlinx.serialization.json.JsonPrimitive)?.content != "false") return null
        return (m["note"] as? kotlinx.serialization.json.JsonPrimitive)?.takeIf { it.isString }?.content?.takeIf { it.isNotBlank() } ?: "Coming soon"
    }

    override suspend fun estimate(kind: String, source: EditorSourceDto, options: JsonObject?): Pair<EditorEstimate?, String?> =
        runCatching { c.repo.attemptInline { editorEstimate(EditorJobRequest(kind, source, options)) } }.getOrElse { null to "Couldn't reach the studio · try again" }

    override suspend fun run(kind: String, source: EditorSourceDto, options: JsonObject?, onProgress: (EditorJob) -> Unit): Pair<JsonObject?, String?> {
        val (started, err) = runCatching { c.repo.attemptInline { startEditorJob(EditorJobRequest(kind, source, options)) } }.getOrElse { null to "Couldn't reach the studio · try again" }
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
        return if (job.state == "done" && job.result != null) job.result to null else null to (job.error ?: if (job.state == "cancelled") "Stopped" else "The helper stopped · try again")
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
class EditSuiteViewModel(private val c: AppContainer, private val takeId: String, context: Context) : ViewModel() {
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
    private val _player = MutableStateFlow<CompositionPlayer?>(null)
    val player: StateFlow<CompositionPlayer?> = _player.asStateFlow()
    private var work: Job? = null
    private var exporting: Job? = null
    private var lastExportError: String? = null
    /** Edit sessions (workstream 3): the owner's live session with Claude (null for members / local only). */
    private var sync: EditSessionSync? = null

    init {
        load()
        viewModelScope.launch { controller.ui.map { it.project }.distinctUntilChanged().debounce(500).collect { p -> if (p != null) rebuildPreview(p) } }
        viewModelScope.launch { controller.ui.map { it.playing }.distinctUntilChanged().collect { on -> _player.value?.let { if (on) it.play() else it.pause() } } }
        viewModelScope.launch {
            controller.ui.map { it.playheadSec to it.playing }.distinctUntilChanged().collect { (t, playing) ->
                val p = _player.value ?: return@collect
                if (!playing && kotlin.math.abs(p.currentPosition / 1000.0 - t) > 0.05) p.seekTo((t * 1000).toLong())
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
            val take = takes.firstOrNull { it.id == takeId } ?: return@launch controller.setPhase(SuitePhase.Failed("This video isn't in your studio any more", canRetry = false))
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
                val project = projectFor(source, target?.initial)
                for (a in project.assets) if (a.take == source.id && a.kind == AssetKind.VIDEO) sourceFile?.let { files[a.id] = it }
                controller.load(project, source.title, source.id, source.thumb, reopened = take.kind == "edit")
                startSession(source.id, project, fromVersion = if (target?.initial != null && take.kind == "edit") take.id else null)
                loadFrames(project)
                fetchTakeAssets(controller.project ?: project)
            } catch (e: kotlinx.coroutines.CancellationException) { throw e
            } catch (e: Exception) {
                controller.setPhase(SuitePhase.Failed("Couldn't open the video · check your connection and try again"))
            }
        }
    }

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

    /** A helper's new asset (background removal's matte): its file, then the preview again with it. */
    private fun fetchAsset(assetId: String, url: String) {
        viewModelScope.launch {
            val f = runCatching { engine.fetchSource(url) {} }.getOrNull() ?: return@launch c.repo.toast("Couldn't download the cut-out · try again")
            files[assetId] = f
            controller.project?.let { rebuildPreview(it) }
        }
    }

    /** PiP takes: their files (for preview/export). */
    private suspend fun fetchTakeAssets(p: EditProject) {
        val takes = c.repo.state.value.takes
        for (a in p.assets) {
            if (a.id in files || a.take == null) continue
            val url = takes.firstOrNull { it.id == a.take }?.videoUrl ?: continue
            runCatching { engine.fetchSource(url) {} }.getOrNull()?.let { files[a.id] = it }
        }
    }

    private fun playable(p: EditProject): EditProject = playableProject(p, files.keys)

    private fun rebuildPreview(p: EditProject) {
        if (sourceFile == null) return
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
    private suspend fun copyIn(uri: Uri, name: String): File? = withContext(Dispatchers.IO) {
        runCatching {
            val f = File(app.cacheDir, "edit-suite/$name").apply { parentFile?.mkdirs() }
            app.contentResolver.openInputStream(uri)?.use { i -> f.outputStream().use { i.copyTo(it) } } ?: return@runCatching null
            f
        }.getOrNull()
    }

    fun addAudio(uri: Uri, voiceOver: Boolean) {
        viewModelScope.launch {
            val f = copyIn(uri, "audio_${System.currentTimeMillis()}") ?: return@launch c.repo.toast("Couldn't read that file")
            val dur = withContext(Dispatchers.IO) {
                runCatching { MediaMetadataRetriever().run { setDataSource(f.absolutePath); val d = extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toDouble(); release(); d } }.getOrNull()
            }?.div(1000) ?: return@launch c.repo.toast("That isn't an audio file this phone can read")
            val mime = app.contentResolver.getType(uri) ?: "audio/mp4"
            val (id, err) = runCatching { c.repo.attemptInline { uploadEditorFile(f, mime) } }.getOrElse { null to "Couldn't upload · try again" }
            if (id == null) return@launch c.repo.toast(err ?: "Couldn't upload · try again")
            controller.act(EditAction.AddAudio(id, (dur * 1000).roundToInt() / 1000.0, voiceOver))
            controller.project?.assets?.firstOrNull { it.upload == id }?.let { files[it.id] = f }
        }
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

    /** Filter thumbnails: every look on the frame under the playhead. */
    fun renderLookThumbs() {
        if (_thumbs.value.isNotEmpty()) return
        val f = sourceFile ?: return
        viewModelScope.launch {
            val frame = runCatching { engine.frames(f, listOf(controller.ui.value.playheadSec.coerceAtLeast(0.1)), 240).firstOrNull() }.getOrNull() ?: return@launch
            val map = runCatching { LookThumbnails.renderPack(frame, looks) }.getOrNull() ?: return@launch
            _thumbs.value = map.mapValues { it.value.asImageBitmap() }
        }
    }

    // ------------------------------------------------------------ Edit sessions (workstream 3): owner only
    /** The owner's editor joins the take's edit session (Claude edits it too); members and offline stay local. */
    private fun startSession(sourceTakeId: String, project: EditProject, fromVersion: String?) {
        if (!(c.repo.demo || c.prefs.value.owner)) return
        controller.update { it.copy(claudeOwner = true) } // the Claude button shows, dimmed until the session is there
        val s = EditSessionSync(viewModelScope, { c.repo.api }, c.repo.live, controller, sessionHost, deviceId(), Build.MODEL ?: "Android phone", looks.paletteIds,
            drafts = FileEditDrafts(File(app.filesDir, "edit-drafts")))
        sync = s
        // The app's own project goes up only when it was built from a saved version (else the server starts from the take).
        // Offline: the editor works locally and joins when the connection is back (asking first if this device has edits).
        viewModelScope.launch { s.connect(sourceTakeId, if (fromVersion != null) EditJson.encode(project) else null, fromVersion) }
    }

    private fun deviceId(): String {
        val raw = runCatching { android.provider.Settings.Secure.getString(app.contentResolver, android.provider.Settings.Secure.ANDROID_ID) }.getOrNull() ?: "device"
        return "android-" + raw.hashCode().toUInt().toString(16)
    }

    private val sessionHost by lazy { object : SessionHost {
        override suspend fun renderFrame(project: EditProject, t: Double, width: Int): Pair<ByteArray?, String?> {
            if (sourceFile == null) return null to "No video file"
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
        exporting = viewModelScope.launch { exportAndSave(toPhone) }
    }

    /** Renders and saves a new version (and a copy on the phone); the saved take, or null with [lastExportError]. */
    private suspend fun exportAndSave(toPhone: Boolean, name: String? = null): Take? {
        lastExportError = null
        val p = controller.project ?: return null
        val u = controller.ui.value
        if (sourceFile == null) { c.repo.toast("This video has no file to render · open a finished render"); lastExportError = "No video file"; return null }
        withContext(Dispatchers.Main) { pause() }
        val s = u.export
        controller.setPhase(SuitePhase.Exporting(0f))
        val made = try {
            val plan = composer.plan(exportProject(playable(p), s), files)
            composer.export(plan, files, if (s.codec == ExportCodec.HEVC) androidx.media3.common.MimeTypes.VIDEO_H265 else androidx.media3.common.MimeTypes.VIDEO_H264) { pr ->
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
            val saved = p.copy(canvas = p.canvas.copy(width = made.width, height = made.height, fps = s.fps.toDouble()))
            val (take, err) = c.repo.attemptInline { saveProjectVersion(u.sourceTakeId, made, EditJson.encode(saved), name) { pr -> controller.setPhase(SuitePhase.Saving(pr)) } }
            if (toPhone) withContext(Dispatchers.IO) { saveToPhone(made.file, srt, u.title) }
            if (take == null) { lastExportError = err ?: "Couldn't save the video"; controller.setPhase(SuitePhase.Failed(lastExportError!!)); return null }
            exportGate.exported(take.id) // answers an export Claude asked for, before the sheet closes
            controller.update { it.copy(phase = SuitePhase.Ready, savedTakeId = take.id, panel = null, message = if (toPhone) "Saved to Library and to this phone" else "Saved as a new version · Edited") }
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

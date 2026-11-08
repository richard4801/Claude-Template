package studio.muse.app.ui.screens.edit

import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.graphics.asImageBitmap
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.screens.claude.ClaudeChatSheet
import studio.muse.app.ui.components.Bar
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.TopBar
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.ScreenBox
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.scale
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.radii
import studio.muse.core.edit.Recipe
import studio.muse.core.edit.RecipeConfidence
import studio.muse.core.edit.RecipeSlot

// "Recreate this edit" (plans/recreate-edit.md, APPROVED), build phase 1 on Android: pick a reference video and see its
// recipe. The video is uploaded to the studio (the editor's upload), WS1's server analyses it
// (`POST /v1/recreate/references`, then `GET …/{id}` until it is ready; plans/api.md) and [RecipeJson] reads the
// `muse.recipe/1` it returns. Demo mode runs the same flow on FakeMuseApi. Building your version (cast, fill, assemble)
// comes next.

/** Where the reference is in its analysis. */
sealed interface RecipePhase {
    /** Nothing picked yet. */
    data object Pick : RecipePhase
    /** [phase]: the server's step, for the checklist (null before the server reports one). */
    data class Analysing(val progress: Float, val step: String, val phase: String? = null) : RecipePhase
    /** [referenceId]: the server's reference, for building your version (phases 2–3); null for a recipe shown alone. */
    data class Ready(val recipe: Recipe, val referenceId: String? = null, val kept: String? = null) : RecipePhase
    /** [fromLink]: a link couldn't be used; the saved file is offered instead. */
    data class Failed(val message: String, val fromLink: Boolean = false) : RecipePhase
}

/** [references]: the studio's references, newest first, on the start page (null while loading). */
data class RecipeUi(val phase: RecipePhase = RecipePhase.Pick, val referenceName: String? = null, val references: List<studio.muse.core.edit.RecipeReference>? = null)

/** The screen: the picker, the upload and the server's analysis, then the recipe. */
@Composable
fun RecipeScreen(onBack: () -> Unit, referenceId: String? = null, shared: studio.muse.app.data.SharedReference? = null, onOpenTake: (String) -> Unit = {}) {
    val c = LocalContainer.current
    val context = androidx.compose.ui.platform.LocalContext.current
    var ui by remember { mutableStateOf(RecipeUi()) }
    var picked by remember { mutableStateOf((shared as? studio.muse.app.data.SharedReference.File)?.uri) } // Share → MUSE: a saved video
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri -> if (uri != null) picked = uri }
    BackHandler(onBack = onBack)
    // A reference from the library (Recipes → "Use in Recreate") or the start page's list: its recipe straight away, or
    // its analysis while it still runs.
    var opened by remember { mutableStateOf(referenceId) }
    LaunchedEffect(Unit) {
        if (opened == null && shared == null) runCatching { c.repo.api.listReferences() }.getOrNull()?.let { list -> if (ui.phase == RecipePhase.Pick) ui = ui.copy(references = list) }
    }
    LaunchedEffect(opened) {
        val rid = opened ?: return@LaunchedEffect
        ui = RecipeUi(RecipePhase.Analysing(.5f, "Opening the reference"), null)
        ui = runCatching { c.repo.api.reference(rid) }.fold(
            { ref -> if (ref.state == "analyzing") follow(c.repo.api, ref) { ui = it }
                else ref.recipe?.let { RecipeUi(RecipePhase.Ready(it, ref.id, ref.keptLine()), ref.name) } ?: RecipeUi(RecipePhase.Failed(ref.error ?: "This reference has expired."), ref.name) },
            { e -> RecipeUi(RecipePhase.Failed(e.message ?: "Couldn't open the reference"), null) })
    }
    // Share → MUSE: a link. The server fetches it within the platforms' rules; when it can't, its message says why and the
    // saved file is offered instead.
    // A link: shared from another app, or pasted on the start page.
    var link by remember { mutableStateOf((shared as? studio.muse.app.data.SharedReference.Link)?.url) }
    LaunchedEffect(link) {
        val url = link ?: return@LaunchedEffect
        val name = studio.muse.core.edit.SharedLink.name(url)
        ui = RecipeUi(RecipePhase.Analysing(.05f, "Getting the video from the link"), name)
        ui = runCatching { follow(c.repo.api, c.repo.api.createReferenceFromLink(url, name)) { ui = it } }.getOrElse { e ->
            if (e is kotlinx.coroutines.CancellationException) throw e
            RecipeUi(RecipePhase.Failed(e.message?.takeIf { it.isNotBlank() } ?: "Couldn't fetch this link — save the video and drop the file in", fromLink = true), name)
        }
    }
    LaunchedEffect(picked) {
        val uri = picked ?: return@LaunchedEffect
        val name = c.media?.displayName(uri)?.substringBeforeLast('.')?.take(80) ?: "Your reference"
        ui = RecipeUi(RecipePhase.Analysing(0f, "Uploading the video"), name)
        ui = runCatching {
            val file = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                val f = java.io.File(context.cacheDir, "reference_${System.currentTimeMillis()}.mp4")
                (context.contentResolver.openInputStream(uri) ?: error("Couldn't read that video")).use { i -> f.outputStream().use { o -> i.copyTo(o) } }
                f
            }
            val mime = context.contentResolver.getType(uri)?.takeIf { it.startsWith("video/") } ?: "video/mp4"
            val uploadId = try {
                c.repo.api.uploadEditorFile(file, mime) { p -> ui = RecipeUi(RecipePhase.Analysing(p * .2f, "Uploading the video"), name) }
            } finally { file.delete() }
            follow(c.repo.api, c.repo.api.createReference(uploadId, name)) { ui = it }
        }.getOrElse { e ->
            if (e is kotlinx.coroutines.CancellationException) throw e
            RecipeUi(RecipePhase.Failed(e.message?.takeIf { it.isNotBlank() } ?: "Couldn't read that video · try another"), name)
        }
    }
    val ready = ui.phase as? RecipePhase.Ready
    if (ready?.referenceId != null) RecreateBuild(ready.referenceId, ready.recipe, ui.referenceName, ready.kept, onBack, onOpenTake)
    else RecipeContent(ui, onBack = onBack, onPick = { pick.launch("video/*") }, onLink = { link = it }, onOpen = { opened = it })
}

/**
 * Phases 2–3 on a ready reference: Recipe (how each shot is made, the total beside Build) and Compare. The model runs
 * match → estimate → one confirmation → fill → watch → apply (see [RecreateBuildModel]); demo mode runs it on FakeMuseApi,
 * which never spends.
 */
@Composable
private fun RecreateBuild(referenceId: String, recipe: Recipe, name: String?, kept: String?, onBack: () -> Unit, onOpenTake: (String) -> Unit) {
    val c = LocalContainer.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val model = remember(referenceId) {
        val state = c.repo.state.value
        val takes = state.takes.filter { it.kind == "take" }.sortedByDescending { it.createdAt }.take(12)
            .map { RecreateTakeChoice(it.id, it.title, it.durationSec, it.thumb, it.label) }
        RecreateBuildModel(c.repo.api, scope, RecreateBuildUi(referenceId, recipe, name, takes = takes, kept = kept,
            cast = state.models.map { RecreateCastChoice(it.id, it.name) }, castId = state.models.firstOrNull()?.id),
            defaultModelId = { c.repo.state.value.models.firstOrNull()?.id })
    }
    val ui by model.ui.collectAsState()
    val studio by c.repo.state.collectAsState()
    val context = androidx.compose.ui.platform.LocalContext.current
    var poster by remember(referenceId) { mutableStateOf<androidx.compose.ui.graphics.ImageBitmap?>(null) }
    var video by remember(referenceId) { mutableStateOf<String?>(null) }
    LaunchedEffect(referenceId) {
        if (!c.repo.demo) poster = c.repo.api.referencePoster(referenceId)?.let { b -> android.graphics.BitmapFactory.decodeByteArray(b, 0, b.size)?.asImageBitmap() }
        model.load()
    }
    // The reference video, from its authenticated route into the cache (≤ 60 s), so the player needs no token.
    LaunchedEffect(referenceId) {
        if (c.repo.demo) return@LaunchedEffect
        val f = java.io.File(context.cacheDir, "recreate_$referenceId.mp4")
        if ((f.length() > 0) || c.repo.api.referenceVideo(referenceId, f)) video = f.toURI().toString()
    }
    // After Build: the real built edit, from the edit session, previewed on the device (Compare). Until it is ready,
    // your edit plays each shot's take.
    val local = remember(referenceId) { RecreateLocalEdit(context, c.repo.api) }
    var exportJob by remember { mutableStateOf<kotlinx.coroutines.Job?>(null) }
    // Claude on this reference (owner only; the server answers members 403).
    val prefs by c.prefs.collectAsState()
    var claude by remember { mutableStateOf(false) }
    var built by remember(referenceId) { mutableStateOf<androidx.media3.common.Player?>(null) }
    LaunchedEffect(ui.builtSessionId, ui.builtRevision) {
        val sid = ui.builtSessionId ?: return@LaunchedEffect
        if (c.repo.demo) return@LaunchedEffect // demo mode has no media to build from
        runCatching { local.load(sid) }.onFailure { if (it is kotlinx.coroutines.CancellationException) throw it }
        val next = local.player()
        built?.release()
        built = next
    }
    androidx.compose.runtime.DisposableEffect(referenceId) { onDispose { built?.release() } }
    // Shots being made: their progress from the studio's live jobs.
    LaunchedEffect(studio.jobs) { model.setJobProgress(studio.jobs.filter { it.running }.associate { it.id to it.progress.toInt() }) }
    // The shared playhead while playing (both players follow it).
    LaunchedEffect(ui.playing) {
        if (!ui.playing) return@LaunchedEffect
        var last = androidx.compose.runtime.withFrameNanos { it }
        while (true) androidx.compose.runtime.withFrameNanos { now -> model.advance((now - last) / 1e9); last = now }
    }
    LaunchedEffect(ui.message) { ui.message?.let { c.repo.toast(it); model.consumeMessage() } }
    RecreateBuildScreen(ui, RecreateActions(
        onBack = onBack, onMode = model::setMode, onSelect = model::select,
        onBuild = { scope.launch { model.requestBuild() } }, onConfirm = { model.confirmBuild() }, onCancel = model::cancelBuild,
        onCast = { id -> scope.launch { model.setCast(id) } },
        onBriefs = model::askBriefs, onBriefsCancel = model::cancelBriefs, onBriefsConfirm = { scope.launch { model.writeBriefs() } },
        onMethod = { s, m -> scope.launch { model.setMethod(s, m) } }, onKeepBackground = { s, k -> scope.launch { model.setKeepBackground(s, k) } },
        onUseTake = model::useTake, onFix = model::fixWeakest, onRemake = { s -> scope.launch { model.remake(s) } },
        onOpenEditor = { ui.builtTakeId?.let(onOpenTake) ?: c.repo.toast("The built edit opens with its take in the editor") },
        onPlay = model::togglePlay, onStep = model::step,
        onClaude = if (c.repo.demo || prefs.owner) ({ claude = true }) else null,
        onExport = model::openExport, onExportGuide = model::setExportGuide,
        onExportClose = { exportJob?.cancel(); exportJob = null; model.setExportProgress(null); model.closeExport() }, // Cancel stops a running export
        onExportRun = {
            val e = ui.export
            if (e != null && e.progress == null) exportJob = scope.launch {
                if (c.repo.demo || !local.playable) { model.setExportProgress(null, "The built edit's videos aren't on this phone yet. Try again in a moment."); return@launch }
                val guide = video?.let { java.io.File(java.net.URI(it)) }?.takeIf { e.guide && it.exists() }
                if (e.guide && guide == null) { model.setExportProgress(null, "The original's sound isn't on this phone yet. Export it silent, or try again in a moment."); return@launch }
                model.setExportProgress(0f)
                runCatching { local.export(guide, recipe.durationSec) { p -> model.setExportProgress(p) } }.fold(
                    { model.exportDone("Saved to this phone, in Movies/MUSE") },
                    { err -> if (err is kotlinx.coroutines.CancellationException) throw err; model.setExportProgress(null, "This phone couldn't make the video. Try again.") })
            }
        },
    ), picture = poster, media = RecreateMedia(video, { id -> studio.takes.firstOrNull { it.id == id }?.videoUrl }, built))
    // The chat refreshes the recipe's fill when Claude has matched or priced shots.
    ClaudeChatSheet(open = claude, onDismiss = { claude = false; scope.launch { model.load() } },
        contextKind = "recreate", contextId = referenceId, title = name ?: "Recreate")
}

/** Polls a reference (showing the server's step) until it is ready or failed. */
private suspend fun follow(api: studio.muse.app.data.MuseApi, start: studio.muse.core.edit.RecipeReference, show: (RecipeUi) -> Unit): RecipeUi {
    var ref = start
    while (ref.state == "analyzing") {
        show(RecipeUi(RecipePhase.Analysing(.2f + .8f * ref.progress / 100f, ref.phase?.takeIf { it != "Waiting" } ?: "Waiting for its turn", ref.phase), ref.name))
        delay(1500)
        ref = api.reference(ref.id)
    }
    val recipe = ref.recipe
    return if (ref.state == "ready" && recipe != null) RecipeUi(RecipePhase.Ready(recipe, ref.id, ref.keptLine()), ref.name)
    else RecipeUi(RecipePhase.Failed(ref.error ?: if (ref.state == "expired") "This reference has expired." else "The analysis didn’t finish.", fromLink = ref.error?.contains("link", true) == true), ref.name)
}

/** The screen as a function of [ui] (screenshots render it). */
@Composable
fun RecipeContent(ui: RecipeUi, onBack: () -> Unit, onPick: () -> Unit, onLink: (String) -> Unit = {}, draftLink: String = "", onOpen: (String) -> Unit = {}) {
    val m = muse
    ScreenBox(statusPad = true) {
        Column(Modifier.fillMaxSize()) {
            TopBar("Recreate an edit", onBack = onBack)
            BoxWithConstraints(Modifier.fillMaxSize()) {
                val wide = maxWidth >= 720.dp
                Column(
                    // A readable measure on a tablet: at most 880 dp, centred.
                    Modifier.align(Alignment.TopCenter).let { if (wide) it.widthIn(max = 880.dp) else it }.fillMaxWidth().fillMaxHeight()
                        .verticalScroll(rememberScrollState()).padding(horizontal = if (wide) 32.dp else 16.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(24.dp),
                ) {
                    when (val ph = ui.phase) {
                        RecipePhase.Pick -> { PickBody(onPick, onLink, draftLink); ui.references?.takeIf { it.isNotEmpty() }?.let { YourReferences(it, wide, onOpen) } }
                        is RecipePhase.Analysing -> AnalysingBody(ui.referenceName, ph)
                        is RecipePhase.Failed -> {
                            T(ph.message, m.scale.body, m.t.ink)
                            // A link MUSE couldn't use: the saved video is the way in (the one action here).
                            if (ph.fromLink) Primary("Pick the saved video", onPick) else Secondary("Pick another video", onPick)
                        }
                        is RecipePhase.Ready -> RecipeBody(ph.recipe, ui.referenceName, wide, onPick)
                    }
                    Spacer(Modifier.height(24.dp))
                }
            }
        }
    }
}

@Composable
private fun ColumnScope.PickBody(onPick: () -> Unit, onLink: (String) -> Unit, draftLink: String) {
    val m = muse
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        T("See how an edit is made", m.scale.title, m.t.ink)
        T("Pick a video you saved: an edit you love, up to 60 s. MUSE breaks it into its recipe: the shots and their cuts, the beats, the text, the transitions, the grade and the pacing.",
            m.scale.body, m.t.ink2())
        T("The video stays private to your studio and is only used to read the recipe.", m.scale.caption, m.t.muted)
    }
    Primary("Pick a video", onPick)
    LinkField(onLink, draftLink)
}

/**
 * Or paste a link (TikTok, Instagram Reel, YouTube). The server fetches it within each platform's rules; when it can't,
 * it says why and the saved file is the way in. The button wakes up once the text holds a link.
 */
@Composable
private fun LinkField(onLink: (String) -> Unit, draft: String) {
    val m = muse
    var text by remember { mutableStateOf(draft) }
    val url = studio.muse.core.edit.SharedLink.first(text)
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        T("Or paste a link", m.scale.label, m.t.ink)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.weight(1f).heightIn(min = 48.dp).clip(RoundedCornerShape(m.radii.control)).background(m.roles.field).padding(horizontal = 12.dp), contentAlignment = Alignment.CenterStart) {
                androidx.compose.foundation.text.BasicTextField(text, { text = it.take(500) }, Modifier.fillMaxWidth().semantics { contentDescription = "Link to a video" }, singleLine = true,
                    textStyle = m.scale.body.copy(color = m.roles.ink), cursorBrush = androidx.compose.ui.graphics.SolidColor(m.roles.accent),
                    keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.Uri, imeAction = androidx.compose.ui.text.input.ImeAction.Go),
                    keyboardActions = androidx.compose.foundation.text.KeyboardActions(onGo = { url?.let(onLink) }),
                    decorationBox = { inner -> Box { if (text.isEmpty()) T("TikTok, Reel or YouTube link", m.scale.body, m.roles.ink2, maxLines = 1); inner() } })
            }
            Box(Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(m.radii.control)).border(1.dp, m.roles.hairline, RoundedCornerShape(m.radii.control))
                .press(enabled = url != null) { url?.let(onLink) }.padding(horizontal = 16.dp).semantics { role = Role.Button }, contentAlignment = Alignment.Center) {
                T("Read it", m.scale.label, if (url != null) m.roles.ink else m.roles.ink2, maxLines = 1)
            }
        }
        T("MUSE fetches it only where the platform allows; otherwise save the video and pick it.", m.scale.caption, m.t.muted)
    }
}

@Composable
private fun AnalysingBody(name: String?, ph: RecipePhase.Analysing) {
    val m = muse
    val current = studio.muse.core.edit.RecreateText.analysisStep(ph.phase)
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        T(name ?: "Your reference", m.scale.heading, m.t.ink, maxLines = 1)
        T(ph.step + "…", m.scale.body, m.t.ink2())
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(Modifier.weight(1f)) { Bar(ph.progress) }
            T("${(ph.progress * 100).toInt()}%", m.scale.caption.tabular(), m.roles.ink2, maxLines = 1)
        }
        T("About a minute. You can leave this page; it carries on.", m.scale.caption, m.roles.ink2)
    }
    // The server's steps as they finish (once it reports one): done, in progress, waiting.
    if (current >= 0) Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        studio.muse.core.edit.RecreateText.ANALYSIS_STEPS.forEachIndexed { i, step ->
            Row(Modifier.semantics(mergeDescendants = true) { stateDescription = when { i < current -> "Done"; i == current -> "In progress"; else -> "Waiting" } },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(Modifier.size(20.dp), contentAlignment = Alignment.Center) {
                    when {
                        i < current -> EIc("check", 16.dp, m.roles.ink)
                        i == current -> Box(Modifier.size(10.dp).clip(androidx.compose.foundation.shape.CircleShape).background(m.roles.accent))
                        else -> Box(Modifier.size(14.dp).clip(androidx.compose.foundation.shape.CircleShape).border(1.5.dp, m.roles.hairline, androidx.compose.foundation.shape.CircleShape))
                    }
                }
                T(step, m.scale.body, if (i <= current) m.roles.ink else m.roles.ink2, maxLines = 1)
            }
        }
    }
}

/** The studio's references, newest first: open one to see its recipe (or its analysis while it runs). */
@Composable
private fun YourReferences(refs: List<studio.muse.core.edit.RecipeReference>, wide: Boolean, onOpen: (String) -> Unit) {
    val m = muse
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        T("Your references", m.scale.heading, m.roles.ink)
        refs.chunked(if (wide) 5 else 3).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                row.forEach { r ->
                    Column(Modifier.weight(1f).press { onOpen(r.id) }.semantics(mergeDescendants = true) { contentDescription = "Open ${r.name}"; role = Role.Button },
                        verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Box(Modifier.fillMaxWidth().aspectRatio(9f / 16f).clip(RoundedCornerShape(m.radii.container)).background(m.roles.field), contentAlignment = Alignment.Center) {
                            EIc("film-strip", 22.dp, m.roles.ink2)
                        }
                        T(r.name, m.scale.label, m.roles.ink, maxLines = 1)
                        T(when (r.state) {
                            "analyzing" -> "Reading · ${r.progress}%"
                            "failed" -> "Couldn’t be read"
                            "expired" -> "Expired"
                            else -> r.durationSec?.let { String.format(java.util.Locale.ROOT, "%.1f s", it) } ?: "Ready"
                        }, m.scale.caption.tabular(), m.roles.ink2, maxLines = 1)
                    }
                }
                repeat((if (wide) 5 else 3) - row.size) { Spacer(Modifier.weight(1f)) }
            }
        }
    }
}

// ------------------------------------------------------------------------------------------------------------- Recipe

@Composable
private fun RecipeBody(r: Recipe, name: String?, wide: Boolean, onPick: () -> Unit) {
    val m = muse
    // The summary: what the reference is, in one line of value pairs, and what needs a look.
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        T(r.title ?: name ?: "Your reference", m.scale.title, m.t.ink, maxLines = 2)
        r.summary?.takeIf { it != r.title }?.let { T(it, m.scale.body, m.t.ink) } // Claude's line, once it has read the contact sheet
        T(listOfNotNull(suiteTime(r.durationSec), "${r.slots.size} shots", r.beats?.bpm?.let { "${it.toInt()} BPM" }).joinToString(" · "), m.scale.body.tabular(), m.t.ink2())
        val low = r.lowConfidence()
        T(if (low == 0) "Every part was read with confidence." else "$low ${if (low == 1) "part needs" else "parts need"} a look: marked Check below.", m.scale.caption, m.t.muted)
    }
    Section("Timeline") { RecipeStrip(r) }
    Section("Shots") { r.slots.forEachIndexed { i, s -> SlotRow(i + 1, s) } }
    if (wide) Row(horizontalArrangement = Arrangement.spacedBy(32.dp)) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(24.dp)) { TextSection(r); TransitionSection(r) }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(24.dp)) { GradeSection(r); PacingSection(r) }
    } else {
        TextSection(r); TransitionSection(r); GradeSection(r); PacingSection(r)
    }
    r.sound?.let { s ->
        Section("Sound") {
            T(s, m.scale.body, m.t.ink)
            T("Your version is timed to its beats. Attach it with Use this sound when you post.", m.scale.caption, m.t.muted)
        }
    }
    if (r.gaps.isNotEmpty()) Section("Not recreated yet") {
        r.gaps.forEach { g -> T(listOfNotNull(g.what, g.note).joinToString(": "), m.scale.body, m.t.ink2()) }
    }
    Secondary("Pick another video", onPick)
}

@Composable
private fun Section(title: String, body: @Composable ColumnScope.() -> Unit) {
    val m = muse
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        T(title, m.scale.heading, m.t.ink)
        body()
    }
}

/** A part's confidence: the percentage, or "Check" (in the warning tone) under the threshold. */
@Composable
private fun Confidence(c: Double) {
    val m = muse
    if (c < RecipeConfidence.LOW) T("Check · ${RecipeConfidence.percent(c)}", m.scale.caption.tabular(), m.t.warn, maxLines = 1)
    else T(RecipeConfidence.percent(c), m.scale.caption.tabular(), m.t.muted, maxLines = 1)
}

/** The shots as blocks in proportion to their length, beat marks above (strong ones taller), transitions as diamonds. */
@Composable
private fun RecipeStrip(r: Recipe) {
    val m = muse
    val strong = r.beats?.strong.orEmpty().toSet()
    Canvas(Modifier.fillMaxWidth().height(64.dp).semantics { contentDescription = "Recipe timeline: ${r.slots.size} shots over ${suiteTime(r.durationSec)}" }) {
        val d = r.durationSec.coerceAtLeast(0.1)
        fun x(t: Double) = (t / d * size.width).toFloat()
        val top = 16.dp.toPx(); val h = size.height - top
        r.beats?.beats?.forEach { b ->
            val tall = b in strong
            drawRect(if (tall) m.t.ink else m.t.muted, Offset(x(b) - .5f.dp.toPx(), if (tall) 0f else 6.dp.toPx()), Size(1.dp.toPx(), if (tall) 12.dp.toPx() else 6.dp.toPx()))
        }
        r.slots.forEachIndexed { i, s ->
            val l = x(s.startSec) + (if (i == 0) 0f else 1.dp.toPx()); val rr = x(s.endSec) - 1.dp.toPx()
            drawRoundRect(m.t.ink.copy(alpha = if (i % 2 == 0) .14f else .26f), Offset(l, top), Size((rr - l).coerceAtLeast(1f), h), CornerRadius(3.dp.toPx()))
            if (s.confidence < RecipeConfidence.LOW) drawRect(m.t.warn, Offset(l, size.height - 3.dp.toPx()), Size((rr - l).coerceAtLeast(1f), 3.dp.toPx()))
        }
        r.transitions.filter { it.kind != null && it.kind != "Cut" }.forEach { t ->
            val cx = x(t.atSec); val cy = top + h / 2; val rad = 6.dp.toPx()
            drawPath(Path().apply { moveTo(cx, cy - rad); lineTo(cx + rad, cy); lineTo(cx, cy + rad); lineTo(cx - rad, cy); close() }, m.t.accent)
        }
    }
}

@Composable
private fun SlotRow(n: Int, s: RecipeSlot) {
    val m = muse
    Row(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        T("$n", m.scale.label.tabular(), m.t.muted, Modifier.width(20.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                T(listOfNotNull(s.shotSize, s.angle).joinToString(", ").ifEmpty { "Shot $n" }, m.scale.label, m.t.ink, Modifier.weight(1f), maxLines = 1)
                Confidence(s.confidence)
            }
            T("${suiteTime(s.startSec)} – ${suiteTime(s.endSec)}  ·  ${fmtSec(s.lengthSec)}", m.scale.caption.tabular(), m.t.muted, maxLines = 1)
            s.brief?.let { T(it, m.scale.body, m.t.ink, maxLines = 2) }
            val camera = listOfNotNull(s.move, s.speed, s.transform, if (s.poseRead) "Pose read" else null)
            if (camera.isNotEmpty()) T(camera.joinToString(", "), m.scale.caption, m.t.ink2(), maxLines = 2)
        }
    }
}

@Composable
private fun TextSection(r: Recipe) = Section("Text") {
    val m = muse
    if (r.texts.isEmpty()) T("No text on screen.", m.scale.body, m.t.muted)
    r.texts.forEach { t ->
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (t.text == studio.muse.core.edit.RecipeJson.UNREAD_WORDS) T(t.text, m.scale.label, m.t.muted, Modifier.weight(1f), maxLines = 1)
                else T("“${t.text}”", m.scale.label, m.t.ink, Modifier.weight(1f), maxLines = 2)
                Confidence(t.confidence)
            }
            T(listOfNotNull("${suiteTime(t.startSec)} – ${suiteTime(t.endSec)}", t.position, t.animation).joinToString("  ·  "), m.scale.caption.tabular(), m.t.muted, maxLines = 1)
            t.style?.let { T(it, m.scale.caption, m.t.ink2(), maxLines = 1) }
        }
    }
}

@Composable
private fun TransitionSection(r: Recipe) = Section("Transitions") {
    val m = muse
    if (r.transitions.isEmpty()) T("Straight cuts.", m.scale.body, m.t.muted)
    r.transitions.forEach { t ->
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            T(suiteTime(t.atSec), m.scale.caption.tabular(), m.t.muted, Modifier.width(52.dp), maxLines = 1)
            T(t.kind ?: "Not recognised", m.scale.label, if (t.kind == null) m.t.muted else m.t.ink, Modifier.weight(1f), maxLines = 1)
            if (t.kind == null) T("Check", m.scale.caption, m.t.warn, maxLines = 1) else Confidence(t.confidence)
        }
    }
}

@Composable
private fun GradeSection(r: Recipe) {
    val g = r.grade ?: return
    Section("Grade") {
        val m = muse
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(Modifier.clip(RoundedCornerShape(if (m.isA) 0.dp else 6.dp)).border(1.dp, m.t.line, RoundedCornerShape(if (m.isA) 0.dp else 6.dp))) {
                g.swatches.forEach { hex -> Box(Modifier.size(24.dp, 32.dp).background(parseHex(hex))) }
            }
            T(g.name, m.scale.label, m.t.ink, Modifier.weight(1f), maxLines = 1)
            Confidence(g.confidence)
        }
        T("Becomes a Look on your version.", m.scale.caption, m.t.muted)
    }
}

@Composable
private fun PacingSection(r: Recipe) = Section("Pacing") {
    val m = muse
    @Composable fun pair(k: String, v: String) = Row {
        T(k, m.scale.body, m.t.ink2(), Modifier.weight(1f), maxLines = 1)
        T(v, m.scale.label.tabular(), m.t.ink, maxLines = 1)
    }
    pair("Average shot", fmtSec(r.averageShotSec))
    pair("Cuts per minute", "${r.cutsPerMinute.toInt()}")
    r.cutsOnBeat()?.let { pair("Cuts on the beat", RecipeConfidence.percent(it)) }
}

// ------------------------------------------------------------------------------------------------------------ Helpers

private fun fmtSec(s: Double): String = String.format(java.util.Locale.ROOT, "%.1f s", s)

private fun parseHex(hex: String): Color = runCatching { Color(android.graphics.Color.parseColor(hex)) }.getOrDefault(Color.Gray)

/** Secondary text: the muted ink for body copy that still has to read well. */
private fun studio.muse.app.ui.theme.Tokens.ink2(): Color = ink.copy(alpha = .78f)

@Composable
private fun Primary(label: String, onClick: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(if (m.isA) 0.dp else if (m.isB) 8.dp else 999.dp)
    Box(
        Modifier.fillMaxWidth().heightIn(min = 52.dp).clip(shape).background(m.t.cta).press(onClick = onClick).semantics { role = Role.Button },
        contentAlignment = Alignment.Center,
    ) { T(label, m.scale.label, m.t.ctaInk, maxLines = 1) }
}

@Composable
private fun Secondary(label: String, onClick: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(if (m.isA) 0.dp else if (m.isB) 8.dp else 999.dp)
    Box(
        Modifier.fillMaxWidth().heightIn(min = 48.dp).clip(shape).border(1.dp, m.t.line, shape).press(onClick = onClick).semantics { role = Role.Button },
        contentAlignment = Alignment.Center,
    ) { T(label, m.scale.label, m.t.ink, maxLines = 1) }
}

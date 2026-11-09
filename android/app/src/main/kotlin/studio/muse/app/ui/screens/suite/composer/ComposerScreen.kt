package studio.muse.app.ui.screens.suite.composer

import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.requiredHeight
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import studio.muse.app.data.SampleData
import studio.muse.app.data.SuiteEstimate
import studio.muse.app.data.SuiteInputs
import studio.muse.app.data.SuiteMoveOption
import studio.muse.app.data.SuiteRules
import studio.muse.app.data.SuiteShotRequest
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.components.PlayBadge
import studio.muse.app.ui.components.MenuItem
import studio.muse.app.ui.components.MoreMenu
import studio.muse.app.ui.components.MuseSlider
import studio.muse.app.ui.components.RefImage
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.TopBar
import studio.muse.app.ui.components.Toggle
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.BlurredStageArt
import studio.muse.app.ui.screens.ScreenBox
import studio.muse.app.ui.screens.StagePhase
import studio.muse.app.ui.screens.suite.HardwareImage
import studio.muse.app.ui.screens.suite.undoRig
import studio.muse.app.ui.screens.suite.queueShot
import studio.muse.app.ui.screens.suite.answerClaude
import studio.muse.app.ui.screens.suite.askClaude
import studio.muse.app.ui.screens.suite.applyAssist
import studio.muse.app.ui.screens.suite.openClaude
import studio.muse.app.ui.screens.suite.claudeHooks
import studio.muse.app.ui.screens.suite.claudeToolDone
import studio.muse.app.ui.screens.suite.pushComposerToAssist
import studio.muse.app.ui.screens.suite.removeDraftReference
import studio.muse.app.ui.screens.suite.applyDefaultRigIfAny
import studio.muse.app.ui.screens.suite.ComposerRigRow
import studio.muse.app.ui.screens.suite.InputSlotUploader
import studio.muse.app.ui.screens.suite.SIc
import studio.muse.app.ui.screens.suite.SlotId
import studio.muse.app.ui.screens.suite.SlotKind
import studio.muse.app.ui.screens.suite.SuiteOffScreen
import studio.muse.app.ui.screens.suite.SuitePane
import studio.muse.app.ui.screens.suite.SuiteResultPane
import studio.muse.app.ui.screens.suite.UpscaleSheet
import studio.muse.app.ui.screens.suite.nextTier
import studio.muse.app.ui.screens.suite.rememberInputSlotPicker
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse
import androidx.compose.foundation.layout.aspectRatio
import studio.muse.app.ui.theme.radii
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale

// AI suite (workstream 1): the video composer (plans/video-composer.md, mockups composer__P1…P5 phone, C1…C6 wide). One
// prompt-first shell; every tool is a preset of it. Phone: recent takes on top, the composer docked at the bottom with
// Quality, Settings and a round Generate showing the price. 600 dp and wider: the desktop layout with pills in the bar.

/** The estimate for [req], fetched ~300 ms after it stops changing (free; holds nothing). */
@Composable
fun rememberEstimate(req: SuiteShotRequest?, enabled: Boolean): Pair<SuiteEstimate?, String?> {
    val store = LocalContainer.current.suite
    val st = produceState<Pair<SuiteEstimate?, String?>>(null to null, req, enabled) {
        if (req == null || !enabled) { value = null to null; return@produceState }
        delay(300)
        value = store.estimate(req)
    }
    return st.value
}

@Composable
fun SuiteComposerScreen(toolId: String? = null) {
    val c = LocalContainer.current
    val nav = LocalNav.current
    val store = c.suite
    val cat by store.catalog.collectAsState()
    val d by store.composer.collectAsState()
    val slots by store.composerSlots.collectAsState()
    val recast by store.recast.collectAsState()
    val sheet by store.sheet.collectAsState()
    val st by c.repo.state.collectAsState()
    val prefs by c.prefs.collectAsState()
    val video by c.drafts.video.collectAsState()
    val started by store.shotJobs.collectAsState()
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { if (store.catalog.value == null) store.load() }
    LaunchedEffect(Unit) { store.loadLocations() }
    val locations by store.locations.collectAsState()
    // A model's default rig (the AI suite plan): when the prompt's one @character changes to someone with a default rig,
    // it fills only the rows still on Auto ("Applied <name>'s rig", with Undo on the Rigs row).
    val sole = ComposerDrafts.characterIds(d.tokens).distinct().singleOrNull()
    var lastSole by remember { mutableStateOf(sole) }
    LaunchedEffect(sole) { if (sole != lastSole) { lastSole = sole; if (sole != null) store.applyDefaultRigIfAny() } }
    // "Takes": the results feed in place of the composer.
    var showFeed by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(false) }
    val catalogError by store.catalogError.collectAsState()
    LaunchedEffect(toolId) { ComposerTool.entries.firstOrNull { it.id == toolId }?.let { t -> if (store.composer.value.tool != t) store.composer.update { it.withTool(t) } } }
    // The clip picked in New video becomes Character swap's / Recast's source.
    LaunchedEffect(video.clip?.id) { video.clip?.id?.let { id -> if (store.recast.value.clipId != id) store.recast.update { it.copy(clipId = id) } } }
    val catalog = cat
    if (catalog != null && !catalog.enabled) { SuiteOffScreen(d.tool.title); return }
    val camCat = catalog?.camera ?: studio.muse.app.data.CameraCatalog()
    // The owner's pinned engine decides the slots (tier.slotsFor); members never have one.
    val inputs = d.inputsFor(catalog)
    val talkingSlots by store.talkingSlots.collectAsState()
    val ugcSlots by store.ugcSlots.collectAsState()
    val extendSlots by store.extendSlots.collectAsState()
    val upscaleFor by store.upscaleFor.collectAsState()
    val ownFlow = when (d.tool) { ComposerTool.TALKING -> store.talkingSlots; ComposerTool.EXTEND -> store.extendSlots; else -> store.ugcSlots }
    val own = when (d.tool) { ComposerTool.TALKING -> talkingSlots; ComposerTool.UGC -> ugcSlots; ComposerTool.EXTEND -> extendSlots; else -> studio.muse.app.ui.screens.suite.InputSlots() }
    val live = d.tool.isLive(catalog)
    val req = d.request(slots, inputs, recast, own, locations)
    val problem = d.problem(slots, recast, own)
    // Character swap's add-ons (Edit, Fast · beta) are priced by the add-on estimate (the video studio's), not the ladder's.
    val clipSeconds = recast.clipId?.let { id -> video.clip?.takeIf { it.id == id }?.durationSec ?: if (id == SampleData.SAMPLE_CLIP) SampleData.sampleMeta.durationSec else null }
    // WS7/WS13 (coordinator, 2026-11-08): for the owner, Swap's model list replaces the Edit / Fast·beta toggles (H3 open
    // weights and Viggle are models in it), so there's one way to choose; Upscale stays. Members keep the pills.
    val ownerPicks = store.owner || prefs.owner
    LaunchedEffect(ownerPicks, d.addon) { if (ownerPicks && d.tool == ComposerTool.SWAP && SwapAddon.of(d.addon)?.let { it == SwapAddon.EDIT || it == SwapAddon.FAST } == true) store.composer.update { it.copy(addon = null) } }
    val addon = d.swapAddon?.takeIf { !ownerPicks || it == SwapAddon.UPSCALE }
    val addonPills = if (d.tool == ComposerTool.SWAP) SwapAddons.pills(st.video ?: studio.muse.app.data.VideoFeatures.DEFAULT, prefs.fastBeta, d.takes, clipSeconds)
        .filter { !ownerPicks || it.addon == SwapAddon.UPSCALE } else emptyList()
    val photo = rememberPhotoTool(d) // Photo tool (workstream 3): its own estimate (POST /v1/suite/photos/estimate) and Generate
    val (suiteEst, estErr) = rememberEstimate(req.takeIf { problem == null && live && addon == null && photo == null }, catalog?.enabled == true)
    val est = if (addon != null) clipSeconds?.takeIf { problem == null }?.let { SwapAddons.estimate(addon, d.takes, it) } else photo?.est ?: suiteEst
    val blocker = ComposerPrice.blocker(problem, est, photo?.error ?: estErr)
    val owner = store.owner || prefs.owner
    val wantTiers = sheet?.kind == SheetKind.SETTINGS || d.collapsed
    val tierEstimates = (catalog?.tiers?.map { it.id } ?: SuiteRules.TIERS).associateWith { t ->
        rememberEstimate(req.copy(quality = t, engineModel = null, resolution = null).takeIf { wantTiers && problem == null && live }, catalog?.enabled == true).first
    }
    val uploader = remember(c) { InputSlotUploader(c) }
    val pickFile = rememberInputSlotPicker { id, uri -> scope.launch { uploader.upload(store.composerSlots, id, uri) } }
    val pickOwn = rememberInputSlotPicker { id, uri -> scope.launch { uploader.upload(ownFlow, id, uri) } }
    // Extend's upload: the existing upload path, plus the video's length (sent as `seconds`) and a still for the card.
    val pickExtendUpload = rememberInputSlotPicker { id, uri ->
        scope.launch {
            val media = c.media
            val secs = media?.let { runCatching { it.clipMeta(uri).durationSec }.getOrNull() }?.takeIf { it > 0 }
            val still = media?.clipThumb(uri)
            uploader.upload(store.extendSlots, id, uri)
            store.extendSlots.update { s -> s.update(id) { v -> v.copy(use = ExtendSlot.UPLOAD, preview = still ?: v.preview, media = v.media?.copy(seconds = secs)) } }
        }
    }
    fun update(f: (ComposerDraft) -> ComposerDraft) = store.composer.update(f)
    fun open(s: ComposerSheet?) { store.sheet.value = s }
    fun generate() {
        if (!live) { c.repo.toast("${d.tool.title} is coming soon"); return }
        if (blocker != null) { c.repo.toast(blocker); return }
        if (est == null) return
        open(null)
        if (photo != null) { photo.generate(); return } // Photo tool (workstream 3): POST /v1/suite/photos
        if (addon != null) {
            scope.launch { c.repo.createJob(SwapAddons.request(d, recast, addon, clipSeconds))?.let { j -> store.shotJobs.update { (it - j.id) + j.id } } }
            return
        }
        scope.launch { store.generate(req, store.shotJobs) }
    }
    fun onAddon(a: SwapAddon) {
        val pill = addonPills.firstOrNull { it.addon == a } ?: return
        when {
            // Upscale sharpens a finished take: the latest render of this composer once it is done.
            a == SwapAddon.UPSCALE -> {
                val latest = store.shotJobs.value.lastOrNull()?.let { id -> st.jobs.firstOrNull { it.id == id } }
                val take = latest?.takeIf { it.state == "done" }?.let { j -> st.takes.firstOrNull { it.jobId == j.id && studio.muse.app.data.UpscaleOffer.canUpscale(it, c.repo.demo) } }
                when {
                    !pill.available -> c.repo.toast(studio.muse.app.data.UpscaleOffer.SOON_TEXT)
                    take == null -> c.repo.toast("Upscale works on a finished take · generate the swap first")
                    else -> store.openUpscale(take.id)
                }
            }
            !pill.available -> c.repo.toast("${a.label} isn't available right now")
            else -> update { it.copy(addon = if (it.addon == a.id) null else a.id) }
        }
    }
    fun pickCharacter(id: String?, outfit: String?) = update { x ->
        val t = when {
            id == null -> x.tokens.character?.let { x.tokens.remove(it.key) } ?: x.tokens
            x.tokens.character != null -> x.tokens.addMention("character", id, st.model(id)?.name?.substringBefore(' ') ?: "").first
            else -> x.tokens
        }
        x.copy(modelId = id, outfitId = outfit, tokens = t)
    }
    fun onMove(mv: SuiteMoveOption) {
        val (t, msg) = d.tokens.addMove(mv)
        if (msg != null) c.repo.toast(msg) else { update { it.copy(tokens = t) }; open(null) }
    }
    fun onSlot(s: ToolSlot) {
        when (s.kind) {
            "character" -> if (live || d.tool == ComposerTool.TALKING || d.tool == ComposerTool.UGC) open(ComposerSheet(SheetKind.CHARACTER))
            "start" -> pickFile(SlotId(SlotKind.START))
            "end" -> if (s.enabled) pickFile(SlotId(SlotKind.END)) else c.repo.toast("Add a start frame first")
            "clip" -> if (recast.clipId == null && c.repo.demo) store.recast.update { it.copy(clipId = SampleData.SAMPLE_CLIP) } else nav.go(Routes.SOURCE)
            "people" -> open(ComposerSheet(SheetKind.PEOPLE))
            "video" -> if (live) open(ComposerSheet(SheetKind.VIDEO)) else c.repo.toast("${d.tool.title} is coming soon")
            else -> ToolSlots.ownSlot(d.tool, s.kind)?.takeIf { live }?.let { pickOwn(it) } ?: c.repo.toast("${d.tool.title} is coming soon")
        }
    }
    // Recast's "tap a face": the clip's first frame (the picked file, else its thumb; demo: the sample's stand-in still).
    val frame = recast.clipId?.let { id ->
        when {
            video.clip?.id == id -> FrameSource(video.clipUri, video.clip?.thumb)
            id == SampleData.SAMPLE_CLIP -> FrameSource(null, FirstFrame.DEMO)
            else -> FrameSource(null, null)
        }
    }
    // The chosen clip's picture for its slot and the empty canvas: its thumb, else the file's first frame.
    val appCtx = androidx.compose.ui.platform.LocalContext.current
    val clipFrame by androidx.compose.runtime.produceState<android.graphics.Bitmap?>(null, frame) {
        value = frame?.let { f -> kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            FirstFrame.ofThumb(appCtx, f.thumb) ?: f.video?.let { FirstFrame.ofVideo(appCtx, it) }
        } }
    }
    fun tapFace(bmp: android.graphics.Bitmap, fx: Float, fy: Float): Int? {
        val max = catalog?.recastMaxPeople ?: SuiteRules.MAX_CAST
        val id = System.nanoTime()
        val before = store.recast.value
        val (next, i) = before.tapFace(fx, fy, max, id)
        if (i == null) { c.repo.toast("Up to $max people · clear a face first"); return null }
        if (next === before) return i
        store.recast.value = next
        scope.launch {
            val bytes = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) { runCatching { FirstFrame.cropJpeg(bmp, fx, fy) }.getOrNull() }
            val (ref, err) = if (bytes == null) null to "Couldn't read that face" else c.repo.attemptInline { uploadImage("face-${i + 1}.jpg", bytes, "image/jpeg") }
            store.recast.update { it.setCrop(id, ref) }
            if (err != null) c.repo.toast(err)
        }
        return i
    }
    val job = started.lastOrNull()?.let { id -> st.jobs.firstOrNull { it.id == id } }
    val ui = ComposerUi(
        d = d, cat = camCat, catalog = catalog, slots = slots, recast = recast, inputs = inputs, est = est, blocker = blocker, tierEstimates = tierEstimates, live = live, own = own,
        addons = addonPills, onAddon = ::onAddon, owner = owner, locations = locations, refsUsed = d.referencesUsed(slots, inputs, own),
        lead = st.model(d.characterId), clipFrame = clipFrame, clipName = recast.clipId?.let { id -> video.clip?.takeIf { it.id == id }?.name ?: if (id == SampleData.SAMPLE_CLIP) SampleData.sampleMeta.name else "Your clip" },
        models = st.models, outfits = st.outfitsOf(d.characterId),
        catalogNote = if (catalog == null) catalogError ?: "" else null, onRetryCatalog = { scope.launch { store.load() } },
        photo = photo, // Photo tool (workstream 3)
        onPromptEmptied = { if (d.tool == ComposerTool.PHOTO) c.suite.photo.clearPreset() else update { it.unselectingPreset() } },
        refChips = { SuiteReferenceChips(d.references, { r -> store.removeDraftReference(r.uploadId, r.url) }) },
        rigRow = { w ->
            // Claude in the Suite: the draft's reference images (Claude adds the owner's photos), removable.
            if (w && photo == null && d.references.isNotEmpty()) SuiteReferenceChips(d.references, { r -> store.removeDraftReference(r.uploadId, r.url) }, Modifier.padding(horizontal = 16.dp).padding(bottom = 8.dp))
            if (photo != null) PhotoRigRow(photo, w) else ComposerRigRow(req.takeIf { live && addon == null && d.tool in ComposerDraft.PROMPT_TOOLS }, suiteEst, suiteEst == null && (estErr != null || problem != null), w)
        },
        update = ::update, open = ::open, onGenerate = ::generate, onSlot = ::onSlot, onClearSlot = { k ->
            when (k) {
                "start" -> store.composerSlots.update { it.clear(SlotId(SlotKind.START)) }
                "end" -> store.composerSlots.update { it.clear(SlotId(SlotKind.END)) }
                "character" -> pickCharacter(null, null)
                "clip" -> store.recast.update { it.copy(clipId = null) }
                else -> ToolSlots.ownSlot(d.tool, k)?.let { id -> ownFlow.update { it.clear(id) } }
            }
        },
        onPick = { base, at, sg ->
            val (t, msg) = when (sg) {
                is Suggestion.Character -> base.addMention("character", sg.model.id, sg.model.name.substringBefore(' '), at)
                is Suggestion.Dress -> base.addMention("outfit", sg.outfit.id, sg.outfit.name, at)
                is Suggestion.Move -> if (photo != null) base to studio.muse.app.data.PhotoRules.NO_MOVEMENT else base.addMove(sg.move, at) // Photo tool (workstream 3)
                // A location is a reference image: refused when References are full on this quality.
                is Suggestion.Place -> d.locationProblem(slots, inputs, own, sg.location.id)?.let { base to it } ?: base.addMention("location", sg.location.id, sg.location.name, at)
                Suggestion.NewPlace -> {
                    d.locationProblem(slots, inputs, own)?.let { base to it } ?: run { open(ComposerSheet(SheetKind.NEW_LOCATION)); base to null }
                }
            }
            if (msg != null) c.repo.toast(msg)
            if (t === base) null else { update { it.copy(tokens = t, modelId = t.character?.id ?: it.modelId) }; t }
        },
    )
    val recent = st.jobs.filter { it.request.engine == SuiteRules.ENGINE && it.id != job?.id }.take(8)
    // Claude in the AI Suite (owner): a shared draft Claude fills in live; the owner's own edits go back to it; Claude's
    // Generate waits for the owner's approval at the price shown.
    val assist by store.assist.collectAsState()
    var claudeOpen by remember { mutableStateOf(false) }
    var chipsUsed by remember(assist?.id) { mutableStateOf(false) }
    val canClaude = owner || c.repo.demo
    LaunchedEffect(Unit) {
        c.repo.live.collect { ev ->
            if (ev.type == "suiteAssist") ev.assist?.let { store.applyAssist(it) }
            else if (ev.type == studio.muse.app.data.ApiEvent.CONNECTED) store.assist.value?.let { a -> runCatching { c.repo.api.suiteAssist(a.id) }.getOrNull()?.let { store.applyAssist(it) } }
        }
    }
    LaunchedEffect(d, assist?.id) { if (assist != null) { delay(600); store.pushComposerToAssist() } }
    ScreenBox {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val wide = ComposerLayout.wide(maxWidth.value.toInt())
            Column(Modifier.fillMaxSize()) {
                TopBar(if (showFeed) "Takes" else if (wide) "" else d.tool.title, onBack = { if (showFeed) showFeed = false else nav.back() },
                    onTitle = if (wide || showFeed) null else ({ open(ComposerSheet(SheetKind.TOOLS)) })) {
                    Box(Modifier.heightIn(min = 48.dp).press { showFeed = !showFeed }.padding(horizontal = 12.dp).semantics { role = Role.Button },
                        contentAlignment = Alignment.Center) { T(if (showFeed) "Composer" else "Takes", muse.scale.label, muse.t.ink, maxLines = 1) }
                    if (canClaude && !showFeed && d.tool in ComposerDraft.PROMPT_TOOLS) Box(Modifier.heightIn(min = 48.dp)
                        .press { scope.launch { if (store.openClaude() != null) claudeOpen = true } }.padding(horizontal = 12.dp)
                        .semantics { role = Role.Button; contentDescription = studio.muse.app.ui.screens.suite.SuiteClaudeWords.toggle(claudeOpen) },
                        contentAlignment = Alignment.Center) { T("Claude", muse.scale.label, muse.t.ink, maxLines = 1) }
                    MoreMenu(listOfNotNull(
                        // Build step 3: save this shot to run later (priced, nothing held; Run from Takes).
                        if (live && problem == null && photo == null && addon == null && d.tool in ComposerDraft.PROMPT_TOOLS)
                            MenuItem("clock", "Queue this shot") { scope.launch { store.queueShot(req) } } else null,
                        MenuItem("grid", "Storyboard") { nav.go(Routes.SUITE_STORYBOARD) },
                        if (owner) MenuItem("quality", "Models and prices (owner)") { nav.go(Routes.SUITE_ENGINES) } else null,
                    ))
                }
                if (showFeed) SuiteFeedView(photo = d.tool == ComposerTool.PHOTO, wide = wide, onOpen = { j -> nav.go(Routes.suiteTake(j)) }, modifier = Modifier.weight(1f))
                else if (wide) WideComposer(ui, job, recent, st.takes) { j -> nav.go(Routes.suiteTake(j)) }
                else PhoneComposer(ui, job, recent, st.takes, { j -> nav.go(Routes.suiteTake(j)) }, { r -> scope.launch { store.generate(r, store.shotJobs) } })
            }
            sheet?.let { sh ->
                ComposerSheetHost(sh, SheetContext(
                    d = d, catalog = catalog, slots = slots, recast = recast, models = st.models, outfitsOf = { st.outfitsOf(it) }, owner = owner, wide = wide, live = live,
                    estimate = est, blocker = blocker, tierEstimates = tierEstimates, update = ::update, updateRecast = { f -> store.recast.update(f) },
                    setTab = { t -> store.sheet.update { it?.copy(tab = t) } }, open = { open(it) }, close = { open(null) }, onMove = ::onMove,
                    onPickSlot = { id -> pickFile(id) }, onClearSlot = { id -> store.composerSlots.update { it.clear(id) } },
                    onPickCharacter = { id, o -> pickCharacter(id, o) }, onGenerate = ::generate, onStoryboard = { nav.go(Routes.SUITE_STORYBOARD) }, onCameraStage = { nav.go(Routes.CAMERA_STAGE) },
                    frame = frame, onTapFace = ::tapFace,
                    takes = ExtendSlot.candidates(st.takes, c.repo.demo), extendKey = extendSlots[ToolSlots.EXTEND_VIDEO]?.media?.key,
                    onPickTake = { t -> if (store.pickExtendTake(t)) open(null) else c.repo.toast("This take has no video to extend yet") },
                    onUploadVideo = { open(null); pickExtendUpload(ToolSlots.EXTEND_VIDEO) },
                    onCreateLocation = { name, uri ->
                        scope.launch {
                            val media = c.media ?: return@launch c.repo.toast("Couldn't read that photo")
                            val bytes = media.bytes(uri) ?: return@launch c.repo.toast("Couldn't read that photo")
                            val loc = store.createLocation(name, bytes, media.mime(uri).takeIf { it.startsWith("image/") } ?: "image/jpeg") ?: return@launch
                            open(null)
                            val cur = store.composer.value
                            if (cur.locationProblem(store.composerSlots.value, inputs, own) == null)
                                update { it.copy(tokens = it.tokens.addMention("location", loc.id, loc.name).first) }
                        }
                    },
                ))
            }
            upscaleFor?.let { id -> UpscaleSheet(id, wide) { j -> nav.go(Routes.suiteTake(j.id)) } }
            SuiteCompareOverlay(wide) { showFeed = false }
            SuiteRunConfirm { j -> nav.go(Routes.suiteTake(j)) }
            // Claude's Generate while the sheet is closed: the approval over the composer's bar.
            assist?.takeIf { !claudeOpen && (it.pending != null || it.message != null) }?.let { a ->
                SuiteClaudeApproval(a, { yes -> scope.launch { store.answerClaude(yes) } }, Modifier.align(Alignment.BottomCenter).padding(16.dp).padding(bottom = 88.dp).widthIn(max = 520.dp))
            }
            assist?.let { a ->
                studio.muse.app.ui.screens.claude.ClaudeChatSheet(claudeOpen, { claudeOpen = false }, "suite", a.id, "Claude", heightFraction = .62f,
                    hooks = store.claudeHooks(scope), onToolDone = { name -> store.claudeToolDone(name, scope) },
                    above = {
                        SuiteClaudeTop(a, showChips = !chipsUsed, onChip = { prompt -> chipsUsed = true; scope.launch { store.askClaude(prompt) } })
                        if (a.pending != null || a.message != null) SuiteClaudeApproval(a, { yes -> scope.launch { store.answerClaude(yes) } }, Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
                    })
            }
        }
    }
}

/** Everything the composer's layouts draw. */
class ComposerUi(
    val d: ComposerDraft,
    val cat: studio.muse.app.data.CameraCatalog,
    val catalog: studio.muse.app.data.SuiteCatalog?,
    val slots: studio.muse.app.ui.screens.suite.InputSlots,
    val recast: studio.muse.app.ui.screens.suite.RecastDraft,
    val inputs: SuiteInputs,
    val est: SuiteEstimate?,
    val blocker: String?,
    val tierEstimates: Map<String, SuiteEstimate?>,
    /** The tool can Generate now (catalog `tools`). */
    val live: Boolean,
    /** Talking's or UGC ad's own slots. */
    val own: studio.muse.app.ui.screens.suite.InputSlots,
    val lead: studio.muse.app.data.Model?,
    val clipName: String?,
    /** The chosen clip's first frame (its thumb or the file's frame), null while loading or without one. */
    val clipFrame: android.graphics.Bitmap? = null,
    val models: List<studio.muse.app.data.Model>,
    val outfits: List<studio.muse.app.data.Outfit>,
    val update: ((ComposerDraft) -> ComposerDraft) -> Unit,
    val open: (ComposerSheet?) -> Unit,
    val onGenerate: () -> Unit,
    val onSlot: (ToolSlot) -> Unit,
    val onClearSlot: (String) -> Unit,
    val onPick: (PromptTokens, Caret, Suggestion) -> PromptTokens?,
    /** The studio's locations (`@location`) and the reference images in use (slots + @locations). */
    val locations: List<studio.muse.app.data.SuiteLocation> = emptyList(),
    val refsUsed: Int = 0,
    /** The studio owner (the engine pin); members never see engines. */
    val owner: Boolean = false,
    /** Character swap's add-on pills (empty on other tools). */
    val addons: List<AddonPill> = emptyList(),
    val onAddon: (SwapAddon) -> Unit = {},
    /** Claude in the Suite: the draft's reference chips (phone: under the prompt). */
    val refChips: @Composable () -> Unit = {},
    /** The rig check's warning row (RigCheckRow.kt), drawn just above the bottom bar; the argument is `wide`. */
    val rigRow: @Composable (Boolean) -> Unit = {},
    /** Photo tool (workstream 3): its draft, estimate and Generate; null on the other tools. */
    val photo: PhotoUi? = null,
    /** The catalog isn't here yet: "" while it loads, else why it couldn't load. null = loaded. */
    val catalogNote: String? = null,
    val onRetryCatalog: () -> Unit = {},
    /** Backspace cleared the prompt (owner decision 2026-11-08): the preset is unselected. */
    val onPromptEmptied: () -> Unit = {},
) {
    /** No price yet and no reason why: the estimate is on its way (the button says "Pricing…"). */
    val pricing: Boolean get() = live && est == null && blocker == null
    val toolSlots: List<ToolSlot> get() = ToolSlots.of(d.tool, inputs, slots, catalog?.recastMaxPeople ?: SuiteRules.MAX_CAST)
    val showPrompt: Boolean get() = d.tool == ComposerTool.SHOT || d.tool == ComposerTool.TALKING || d.tool == ComposerTool.UGC || d.tool == ComposerTool.EXTEND ||
        (d.tool == ComposerTool.SWAP && d.swapPrompt) || d.tool == ComposerTool.PHOTO // Photo tool (workstream 3)
    /** Before anything is typed or picked: the preset row shows under the composer. */
    val empty: Boolean get() = d.tool == ComposerTool.SHOT && d.tokens.isEmpty && d.characterId == null && slots.isEmpty && d.settings.preset == null
    val canGo: Boolean get() = live && blocker == null && est != null
}

// ---------------------------------------------------------------- phone

// Workstream 4: the phone composer follows the approved render (plans/design-direction/composer-b.png): the picture first,
// then the prompt, the input slots with their names under them, plain setting rows, and one full-width Generate.
@Composable
private fun PhoneComposer(ui: ComposerUi, job: studio.muse.app.data.Job?, recent: List<studio.muse.app.data.Job>, takes: List<studio.muse.app.data.Take>, openTake: (String) -> Unit, retry: (SuiteShotRequest) -> Unit) {
    val m = muse
    Column(Modifier.fillMaxSize()) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(top = 8.dp, bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            // Photo tool (workstream 3): the library's recent stills and the photo presets (templates) in place of the hero.
            if (ui.photo != null) { PhotoRecent(ui, takes, wide = false); PhotoPresets(wide = false) }
            else MediaHero(ui, job, takes, openTake, retry, Modifier.fillMaxWidth().aspectRatio(4f / 3f))
            if (ui.catalogNote != null) CatalogNote(ui)
            else if (ui.photo == null && (ui.empty || ui.d.collapsed)) PresetRow(ui, tileW = 120.dp, tileH = 76.dp)
            if (ui.d.collapsed) { CollapsedBody(ui, wide = false); return@Column }
            if (ui.d.tool == ComposerTool.SWAP) SwapPromptToggle(ui)
            if (ui.d.tool == ComposerTool.EXTEND) ExtendDirection(ui)
            // The prompt sits on the raised tone, as in the render.
            if (ui.showPrompt) Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(m.radii.control)).background(m.roles.raised).padding(horizontal = 14.dp, vertical = 12.dp)) { Prompt(ui) }
            if (ui.photo == null && ui.d.references.isNotEmpty()) ui.refChips()
            if (ui.photo != null) PhotoSlotRow(ui, wide = false) // Photo tool (workstream 3)
            else SlotThumbs(ui)
            if (ui.d.tool == ComposerTool.EXTEND) ExtendLength(ui, Modifier.fillMaxWidth())
            SettingRows(ui)
            if (ui.addons.isNotEmpty()) AddonPills(ui)
            ui.rigRow(false)
        }
        Column(Modifier.fillMaxWidth().drawBehind { drawLine(m.t.line, Offset(0f, 0f), Offset(size.width, 0f), 1.dp.toPx()) }.background(m.t.bg).navigationBarsPadding()
            .padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            PhoneBar(ui)
        }
    }
}

/**
 * The picture at the top: the take in progress or the latest take. Before any take it is a quiet empty canvas: the shot's
 * shape outlined on the surface tone with a one-line hint and the shape and length under it (owner fix A1: no sample or
 * scene stills).
 */
@Composable
private fun MediaHero(ui: ComposerUi, job: studio.muse.app.data.Job?, takes: List<studio.muse.app.data.Take>, openTake: (String) -> Unit, retry: (SuiteShotRequest) -> Unit, modifier: Modifier) {
    val m = muse
    val pane = SuitePane.of(job, takes, ui.lead?.name)
    val shape = RoundedCornerShape(m.radii.container)
    if (pane.phase == StagePhase.IDLE) { EmptyCanvas(ui, modifier); return }
    Box(modifier.clip(shape).background(m.roles.field)) {
        run {
            SuiteResultPane(pane, ui.lead?.cover, emptyTitle = "", emptyHint = "", compact = true,
                onRetry = { job?.let { retry(ui.d.request(ui.slots, ui.inputs, ui.recast)) } }, onTry = nextTier(ui.d.quality)?.let { t -> { ui.update { it.copy(quality = t) } } },
                tryLabel = nextTier(ui.d.quality)?.let { "Try ${SuiteRules.tierLabel(it)}" }, onOpen = { job?.let { openTake(it.id) } })
        }
    }
}

/** No take yet: the shot's shape (9:16, 16:9, …) outlined on the surface tone, centred, with a one-line hint. */
@Composable
private fun EmptyCanvas(ui: ComposerUi, modifier: Modifier) {
    val m = muse
    val shape = RoundedCornerShape(m.radii.container)
    val ratio = ui.d.aspect.split(":").mapNotNull { it.trim().toFloatOrNull() }.takeIf { it.size == 2 && it[0] > 0f && it[1] > 0f }?.let { it[0] / it[1] } ?: (16f / 9f)
    val hint = when {
        ui.photo != null -> "Your photos appear here"
        ui.d.tool == ComposerTool.SWAP || ui.d.tool == ComposerTool.RECAST -> "Choose a clip to start"
        ui.d.tool == ComposerTool.EXTEND -> "Choose a video to extend"
        else -> "Your shot appears here"
    }
    val tag = if (ui.photo != null) null else if (ui.d.tool == ComposerTool.EXTEND) "+${ui.d.duration} s" else "${ui.d.aspect} · ${ui.d.duration} s"
    val frame = ui.clipFrame.takeIf { ui.recast.clipId != null && (ui.d.tool == ComposerTool.SWAP || ui.d.tool == ComposerTool.RECAST) }
    if (frame != null) {
        // The chosen clip, as it will be swapped: its first frame in the shot's shape.
        Box(modifier, contentAlignment = Alignment.Center) {
            androidx.compose.foundation.Image(frame.asImageBitmap(), ui.clipName ?: "Your clip", Modifier.aspectRatio(ratio).clip(shape).border(1.dp, m.roles.hairline, shape),
                contentScale = androidx.compose.ui.layout.ContentScale.Crop)
        }
        return
    }
    Box(modifier, contentAlignment = Alignment.Center) {
        Column(Modifier.aspectRatio(ratio).clip(shape).background(m.roles.raised).border(1.dp, m.roles.hairline, shape).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterVertically), horizontalAlignment = Alignment.CenterHorizontally) {
            T(hint, m.scale.label, m.roles.ink2, align = TextAlign.Center, maxLines = 2)
            if (tag != null) T(tag, m.scale.caption, m.roles.ink2, align = TextAlign.Center, maxLines = 1)
        }
    }
}

/** The input slots as thumbnails with their names under them; an empty one is a dashed "+" named for what it adds (owner fix 4). */
@Composable
private fun SlotThumbs(ui: ComposerUi) {
    val m = muse
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top) {
        ui.toolSlots.forEach { s ->
            val filled = slotFill(ui, s)
            val enabled = s.enabled && (ui.live || s.kind == "character")
            Column(Modifier.width(72.dp).alpha(if (enabled) 1f else .45f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                val shape = RoundedCornerShape(m.radii.control)
                Box(Modifier.padding(bottom = 6.dp).size(64.dp).clip(shape).press { ui.onSlot(s) }
                    .let { if (filled == null) it.dashed(m.t.muted.copy(alpha = .7f), m.radii.control) else it }
                    .semantics(mergeDescendants = true) { role = Role.Button; contentDescription = "${s.label}${if (s.optional) ", optional" else ""}${filled?.let { ": " + it.second } ?: ""}" },
                    contentAlignment = Alignment.Center) {
                    val img = filled?.first
                    val frameBmp = if (s.kind == "clip" && filled != null) ui.clipFrame else null
                    if (frameBmp != null) androidx.compose.foundation.Image(frameBmp.asImageBitmap(), null, Modifier.matchParentSize(), contentScale = androidx.compose.ui.layout.ContentScale.Crop)
                    else if (img != null) RefImage(img, Modifier.matchParentSize(), 20)
                    else if (s.kind == "clip" && filled != null) Box(Modifier.matchParentSize().background(m.t.surface2))
                    else SIc("plus", 20.dp, m.t.muted)
                    if (filled != null && s.kind in setOf("character", "start", "end", "clip", "audio", "location", "product", "refad", "video"))
                        Box(Modifier.align(Alignment.TopEnd).size(28.dp).press { ui.onClearSlot(s.kind) }.semantics { contentDescription = "Remove ${s.label}"; role = Role.Button }, contentAlignment = Alignment.Center) {
                            Box(Modifier.size(18.dp).clip(CircleShape).background(Color(0x8C0E0C0A)), contentAlignment = Alignment.Center) { SIc("close", 10.dp, Color(0xFFF8F5EF)) }
                        }
                }
                T(s.label, m.scale.caption, if (filled != null) m.t.ink else m.t.muted, maxLines = 1)
                if (s.optional && filled == null) T("Optional", m.scale.caption, m.t.muted, maxLines = 1)
            }
        }
    }
}

/** What a slot holds now: its picture (null without one) and its name. Null when the slot is empty. */
private fun slotFill(ui: ComposerUi, s: ToolSlot): Pair<studio.muse.app.data.ImageRef?, String>? = when (s.kind) {
    "character" -> ui.lead?.let { l -> (ui.outfits.firstOrNull { it.id == ui.d.characterOutfit }?.front ?: l.cover) to l.name.substringBefore(' ') }
    "start" -> ui.slots[SlotId(SlotKind.START)]?.let { v -> (v.image ?: v.preview?.let { studio.muse.app.data.ImageRef(url = it) }) to s.label }
    "end" -> ui.slots[SlotId(SlotKind.END)]?.let { v -> (v.image ?: v.preview?.let { studio.muse.app.data.ImageRef(url = it) }) to s.label }
    "clip" -> ui.recast.clipId?.let { null to (ui.clipName ?: "Clip") }
    "people" -> ui.recast.people.takeIf { p -> p.any { it.characterId != null } }?.let { p -> null to "${p.size} ${if (p.size == 1) "person" else "people"}" }
    else -> ToolSlots.ownSlot(ui.d.tool, s.kind)?.let { ui.own[it] }?.let { v -> (if (v.image != null || v.preview != null) (v.image ?: studio.muse.app.data.ImageRef(url = v.preview)) else null) to (v.error ?: if (v.uploading) "Uploading…" else v.name.ifBlank { s.label }) }
}

/** The settings as plain rows (the render): icon, name, value on the right, chevron. Auto values stay quiet. */
@Composable
private fun SettingRows(ui: ComposerUi) {
    val m = muse
    val d = ui.d
    val refsMax = SlotKind.IMAGE.capacity(ui.inputs)
    val order = listOf(ComposerChip.CAMERA, ComposerChip.LIGHTING, ComposerChip.LOOK, ComposerChip.STYLE, ComposerChip.REFERENCES)
    Column(Modifier.fillMaxWidth()) {
        order.filter { it in d.chips }.forEach { chip ->
            val sum = ComposerCatalog.summary(chip, d.settings, ui.cat, ui.refsUsed, refsMax)
            val directed = chip == ComposerChip.CAMERA && d.directed != null
            // Camera reads as the body and lens ("35 mm film · Anamorphic"); Style as genre · tempo: value pairs (design direction §7).
            val cam = if (chip == ComposerChip.CAMERA) listOfNotNull(
                ui.cat.bodies.firstOrNull { it.id == ComposerCatalog.survivor(ui.cat.bodies, d.settings.body) }?.label,
                ui.cat.lenses.firstOrNull { it.id == ComposerCatalog.survivor(ui.cat.lenses, d.settings.lens) }?.label,
            ).joinToString(" · ").ifBlank { null } else null
            val value = when {
                directed -> "Directed"
                cam != null -> cam
                chip == ComposerChip.STYLE && !sum.auto -> sum.value.replace(", ", " · ")
                else -> sum.value
            }
            val (icon, name) = when (chip) {
                ComposerChip.CAMERA -> "film" to "Camera"; ComposerChip.LIGHTING -> "light" to "Light"; ComposerChip.LOOK -> "palette" to "Look"
                ComposerChip.STYLE -> "sliders" to "Style"; ComposerChip.REFERENCES -> "image" to "References"
            }
            SettingRow(icon, name, value, auto = sum.auto && !directed) {
                ui.open(ComposerSheet(when (chip) { ComposerChip.REFERENCES -> SheetKind.REFERENCES; ComposerChip.STYLE -> SheetKind.STYLE; ComposerChip.CAMERA -> SheetKind.CAMERA; ComposerChip.LOOK -> SheetKind.LOOK; ComposerChip.LIGHTING -> SheetKind.LIGHTING }))
            }
        }
        // Rigs (the AI suite plan): saved rigs and a character's default; after one is applied, the row offers Undo.
        RigsRow(ui)
        if (ui.photo == null) {
            // Shape, length, sound, speaking and takes live in Settings; the row says what they are now.
            val (a, b) = if (d.tool == ComposerTool.EXTEND) "+${d.duration} s ${if (d.extendDirection == "before") "before" else "after"}" to d.barSummary.second else d.barSummary
            SettingRow("ratio", "Settings", "$a, $b", auto = false) { ui.open(ComposerSheet(SheetKind.SETTINGS)) }
        }
    }
}

@Composable
private fun RigsRow(ui: ComposerUi) {
    val m = muse
    val store = LocalContainer.current.suite
    val undo by store.rigUndo.collectAsState()
    val rigs by store.savedRigs.collectAsState()
    val applied = undo
    if (applied != null) Row(Modifier.fillMaxWidth().heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        SIc("stack", 20.dp, m.t.muted)
        T(applied.first, m.scale.label, m.t.ink, Modifier.weight(1f), maxLines = 1)
        Box(Modifier.heightIn(min = 48.dp).press { store.undoRig() }.semantics { role = Role.Button }, contentAlignment = Alignment.Center) { T("Undo", m.scale.label, m.roles.link, maxLines = 1) }
    } else SettingRow("stack", "Rigs", if (rigs.isEmpty()) "Save or apply" else "${rigs.size} saved", auto = true) { ui.open(ComposerSheet(SheetKind.RIGS)) }
}

@Composable
private fun SettingRow(icon: String, name: String, value: String, auto: Boolean, onClick: () -> Unit) {
    val m = muse
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).press(onClick = onClick).semantics(mergeDescendants = true) { role = Role.Button; contentDescription = "$name: $value" },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        SIc(icon, 20.dp, m.t.muted)
        T(name, m.scale.label, m.t.muted, maxLines = 1)
        T(value, m.scale.label.copy(fontWeight = if (auto) FontWeight.Normal else FontWeight.Medium), if (auto) m.t.muted else m.t.ink, Modifier.weight(1f), maxLines = 1, align = TextAlign.End)
        SIc("chev", 16.dp, m.t.muted)
    }
}

/** The bottom bar (the render): Quality, sound, and the one filled Generate with the price in its label. */
@Composable
private fun PhoneBar(ui: ComposerUi) {
    val m = muse
    if (!ui.live) { ComingSoonLine(ui); return }
    ui.blocker?.takeIf { !ui.empty }?.let { T(it, m.type.tiny, m.t.muted, maxLines = 2) }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        // Photo tool (workstream 3): one Photos 1–4 list in place of Quality and sound.
        val p = ui.photo
        if (p != null) { MenuPill("layers", photoCountLabel(p.draft.count), "Photos", PhotoComposer.countItems(p.draft.count)) { i -> p.setCount(i + 1) }; PhotoModelPill(ui) }
        else {
            Row(Modifier.heightIn(min = 48.dp).press { ui.open(ComposerSheet(SheetKind.SETTINGS)) }.semantics { contentDescription = "Quality ${SuiteRules.tierLabel(ui.d.quality)}"; role = Role.Button }
                .padding(horizontal = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                T(SuiteRules.tierLabel(ui.d.quality), m.scale.label, m.t.ink, maxLines = 1); SIc("chevd", 14.dp, m.t.muted)
            }
            if (ui.d.tool != ComposerTool.EXTEND) Box(Modifier.size(48.dp).press { ui.update { it.copy(sound = !it.sound) } }
                .semantics { contentDescription = if (ui.d.sound) "Sound on" else "Sound off"; role = Role.Switch }, contentAlignment = Alignment.Center) {
                SIc(if (ui.d.sound) "audio" else "mute", 20.dp, m.t.ink)
            }
        }
        Spacer(Modifier.width(4.dp))
        GenerateButton(ui, Modifier.weight(1f))
    }
}

/** The one filled action: "Generate · $0.64" ("Generate · —" before a price). */
@Composable
private fun GenerateButton(ui: ComposerUi, modifier: Modifier) {
    val m = muse
    val label = ComposerPrice.button(ui.est, ui.pricing)
    Box(modifier.height(48.dp).alpha(if (ui.canGo) 1f else .5f).clip(RoundedCornerShape(m.radii.control)).background(m.roles.action).press(onClick = ui.onGenerate)
        .semantics { contentDescription = label; role = Role.Button }, contentAlignment = Alignment.Center) {
        T(label, m.scale.label.copy(fontWeight = FontWeight.SemiBold), m.roles.onAction, maxLines = 1)
    }
}

@Composable
private fun ComingSoonLine(ui: ComposerUi) {
    val m = muse
    Row(Modifier.fillMaxWidth().heightIn(min = 52.dp).clip(RoundedCornerShape(if (m.isA) 0.dp else 10.dp)).background(m.t.surface2).padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        T("Coming soon", m.type.body.copy(fontSize = 14.sp, fontWeight = FontWeight.SemiBold), m.t.ink)
        T("${ui.d.tool.title} isn't ready yet · Shot makes most of it", m.type.tiny, m.t.muted, Modifier.weight(1f), maxLines = 2)
    }
}

// ---------------------------------------------------------------- shared pieces

@Composable
private fun ToolRow(ui: ComposerUi, wide: Boolean) {
    val m = muse
    val d = ui.d
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        val thumb = d.settings.preset?.let { presetPreview(ui.cat, it, "").still } ?: d.tool.render
        HardwareImage(thumb, Modifier.size(34.dp, 40.dp), sample = 8)
        if (wide) {
            T(d.cardTitle(ui.cat), m.scale.label, m.t.ink, maxLines = 1)
            Box(Modifier.size(3.dp).clip(CircleShape).background(m.t.line))
            T(d.cardTagline(ui.cat), m.type.body.copy(fontSize = 13.5.sp), m.t.muted, maxLines = 1)
        } else Column(Modifier.weight(1f)) {
            T(d.cardTitle(ui.cat), m.scale.label, m.t.ink, maxLines = 1)
            T(if (ui.live) d.cardTagline(ui.cat) else "Coming soon · ${d.tool.tagline}", m.type.body.copy(fontSize = 13.sp), m.t.muted, maxLines = 1)
        }
        val shape = RoundedCornerShape(if (m.isA) 0.dp else 8.dp)
        Box(Modifier.heightIn(min = 48.dp).press { ui.open(ComposerSheet(SheetKind.TOOLS)) }.semantics { contentDescription = "Change mode"; role = Role.Button }, contentAlignment = Alignment.Center) {
            Row(Modifier.height(36.dp).clip(shape).background(m.t.surface).border(1.dp, m.t.line, shape).padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                SIc("swap", 15.dp, m.t.ink); T("Change", m.type.body.copy(fontSize = 14.sp, fontWeight = FontWeight.SemiBold), m.t.ink, maxLines = 1)
            }
        }
        if (wide) {
            Spacer(Modifier.weight(1f))
            if (!ui.live) T("Coming soon", m.type.tiny, m.t.muted)
        }
    }
}

/** The five setting chips (those the tool shows): a tiny visual, the mono label and the value ("Auto" or the picks). */
@Composable
private fun ChipsRow(ui: ComposerUi, wide: Boolean = false) {
    val m = muse
    val d = ui.d
    val refsMax = SlotKind.IMAGE.capacity(ui.inputs)
    val refs = ui.refsUsed
    // Wide: the chips wrap, so all five show and their values aren't cut. Phone: one scrolling line that fades at the
    // right edge, so the chips past it read as "more this way".
    val scroll = rememberScrollState()
    val chipsBody: @Composable () -> Unit = {
        d.chips.forEach { chip ->
            val sum = ComposerCatalog.summary(chip, d.settings, ui.cat, refs, refsMax)
            val value = if (chip == ComposerChip.CAMERA && d.directed != null) "Directed" else ComposerCatalog.ellipsize(sum.value, if (wide) 40 else 26)
            val auto = sum.auto && !(chip == ComposerChip.CAMERA && d.directed != null)
            val render = when (chip) {
                ComposerChip.REFERENCES -> null
                ComposerChip.STYLE -> "stock-02-16mm"
                ComposerChip.CAMERA -> ui.cat.bodies.firstOrNull { it.id == ComposerCatalog.survivor(ui.cat.bodies, d.settings.body) }?.render ?: "body-05-film35"
                ComposerChip.LOOK -> (ui.cat.palettes.firstOrNull { it.id == d.settings.palette } ?: ui.cat.looks.firstOrNull { it.id == d.settings.stock })?.render ?: "palette-02-teal-orange"
                ComposerChip.LIGHTING -> ui.cat.lighting.firstOrNull { it.id == d.settings.lighting }?.render ?: "light-04-window"
            }
            val shape = RoundedCornerShape(if (m.isA) 0.dp else 8.dp)
            Box(Modifier.heightIn(min = 48.dp).press {
                ui.open(ComposerSheet(when (chip) { ComposerChip.REFERENCES -> SheetKind.REFERENCES; ComposerChip.STYLE -> SheetKind.STYLE; ComposerChip.CAMERA -> SheetKind.CAMERA; ComposerChip.LOOK -> SheetKind.LOOK; ComposerChip.LIGHTING -> SheetKind.LIGHTING }))
            }.semantics(mergeDescendants = true) { contentDescription = "${chip.title}: $value"; role = Role.Button }, contentAlignment = Alignment.Center) {
                Row(Modifier.height(38.dp).clip(shape).background(m.t.bg).border(if (m.isD) 1.5.dp else 1.dp, m.t.line, shape).padding(start = 6.dp, end = 11.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                    if (render == null) Box(Modifier.size(26.dp).dashedBox(m.t.muted), contentAlignment = Alignment.Center) { SIc("image", 14.dp, m.t.muted) }
                    else HardwareImage(render, Modifier.size(26.dp), sample = 8, gray = auto)
                    T(chip.title, m.scale.micro, m.t.muted, maxLines = 1)
                    T(value, m.type.body.copy(fontSize = 13.sp, fontWeight = if (auto) FontWeight.Normal else FontWeight.SemiBold), if (auto) m.t.muted else m.t.ink, maxLines = 1)
                }
            }
        }
    }
    if (wide) FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(0.dp)) { chipsBody() }
    else {
        val fade = m.t.surface
        Row(Modifier.fillMaxWidth().horizontalScroll(scroll).drawWithContent {
            drawContent()
            if (scroll.value < scroll.maxValue) {
                val w = 28.dp.toPx()
                drawRect(androidx.compose.ui.graphics.Brush.horizontalGradient(listOf(fade.copy(alpha = 0f), fade), startX = size.width - w, endX = size.width),
                    topLeft = Offset(size.width - w, 0f), size = androidx.compose.ui.geometry.Size(w, size.height))
            }
        }, horizontalArrangement = Arrangement.spacedBy(6.dp)) { chipsBody() }
    }
}

private fun Modifier.dashedBox(c: Color): Modifier = drawBehind {
    drawRoundRect(c, style = Stroke(1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 2.dp.toPx()))), cornerRadius = CornerRadius(2.dp.toPx()))
}

@Composable
private fun Prompt(ui: ComposerUi, modifier: Modifier = Modifier, maxHeight: Dp = 120.dp) {
    PromptBox(ui.d.tokens, ui.d.placeholder, ui.models, ui.outfits, ui.cat, ui.d.tool == ComposerTool.TALKING,
        onChange = { t -> ui.update { it.copy(tokens = t, modelId = if (it.tokens.character != null && t.character == null && it.modelId == it.tokens.character?.id) null else (t.character?.id ?: it.modelId)) } },
        onPick = ui.onPick, onToken = { k -> ui.open(ComposerSheet(SheetKind.TOKEN, token = k)) }, modifier = modifier.fillMaxWidth(), maxHeight = maxHeight,
        locations = ui.locations, onEmptied = ui.onPromptEmptied)
}

@Composable
private fun SwapPromptToggle(ui: ComposerUi) {
    val m = muse
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).press { ui.update { it.copy(swapPrompt = !it.swapPrompt) } }, verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            T("Describe a change", m.type.body.copy(fontSize = 14.sp, fontWeight = FontWeight.SemiBold), m.t.ink, maxLines = 1)
            T("Camera and light come from the clip", m.type.tiny, m.t.muted, maxLines = 1)
        }
        Toggle(ui.d.swapPrompt, { ui.update { it.copy(swapPrompt = !it.swapPrompt) } })
    }
}

/** Extend's After / Before: a segmented control (each half 48 dp tall). The prompt's placeholder follows it. */
@Composable
private fun ExtendDirection(ui: ComposerUi, modifier: Modifier = Modifier, captions: Boolean = false) {
    val m = muse
    val shape = RoundedCornerShape(if (m.isA) 0.dp else 10.dp)
    Row(modifier.fillMaxWidth().clip(shape).background(m.t.bg).border(if (m.isD) 2.dp else 1.dp, m.t.line, shape).padding(3.dp), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
        listOf("after" to "After", "before" to "Before").forEach { (k, l) ->
            val on = ui.d.extendDirection == k
            Row(Modifier.weight(1f).heightIn(min = 48.dp).clip(RoundedCornerShape(if (m.isA) 0.dp else 8.dp)).background(if (on) m.t.ink else Color.Transparent)
                .press { ui.update { it.copy(extendDirection = k) } }.semantics(mergeDescendants = true) { selected = on; role = Role.RadioButton; contentDescription = "Extend $l" },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally)) {
                T(l, m.type.body.copy(fontSize = 14.sp, fontWeight = FontWeight.SemiBold), if (on) m.t.bg else m.t.ink, maxLines = 1)
                if (captions) T(if (k == "after") "what happens next" else "what led up to it", m.type.body.copy(fontSize = 12.sp), if (on) m.t.bg.copy(alpha = .75f) else m.t.muted, maxLines = 1)
            }
        }
    }
}

/** Extend's Length: the new part, on the quality's range (the catalog's min and max seconds). */
@Composable
private fun ExtendLength(ui: ComposerUi, modifier: Modifier = Modifier) {
    val m = muse
    val range = ui.d.lengthRange(ui.catalog)
    Column(modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            T("New part", m.scale.label, m.t.muted, Modifier.weight(1f), maxLines = 1)
            T("+${ui.d.duration} s", m.type.mono.copy(fontSize = 14.sp, fontWeight = FontWeight.SemiBold), m.t.ink, maxLines = 1)
        }
        Box(Modifier.fillMaxWidth().heightIn(min = 48.dp).semantics { contentDescription = "New part length, ${ui.d.duration} seconds" }, contentAlignment = Alignment.Center) {
            MuseSlider(ui.d.duration.coerceIn(range), range.first, range.last, { v -> ui.update { it.copy(duration = v) } })
        }
        Row(Modifier.fillMaxWidth()) {
            T("${range.first} s", m.type.tiny, m.t.muted, Modifier.weight(1f)); T("${range.last} s", m.type.tiny, m.t.muted)
        }
    }
}

/** A slot card: "+", the caps label, the caption that states its limit, an Optional pill; greyed when it waits on another. */
@Composable
private fun SlotCard(ui: ComposerUi, s: ToolSlot, modifier: Modifier) {
    val m = muse
    val enabled = s.enabled && (ui.live || s.kind == "character")
    val filled = slotFill(ui, s)
    val shape = RoundedCornerShape(if (m.isA) 0.dp else 10.dp)
    val sub = when {
        filled == null -> s.caption
        s.kind == "character" -> ui.outfits.firstOrNull { it.id == ui.d.characterOutfit }?.name ?: "Tap to change"
        s.kind == "start" || s.kind == "end" -> s.caption
        s.kind == "people" -> ui.recast.people.joinToString(", ") { p -> ui.models.firstOrNull { it.id == p.characterId }?.name?.substringBefore(' ') ?: "—" }
        else -> "Tap to change"
    }
    Box(modifier.clip(shape).background(m.t.bg).let { if (filled == null) it.dashed(if (enabled) m.t.muted.copy(alpha = .6f) else m.t.line) else it.border(1.dp, m.t.line, shape) }
        .alpha(if (enabled) 1f else .45f).press { ui.onSlot(s) }
        .semantics(mergeDescendants = true) { role = Role.Button; contentDescription = "${s.label}${if (s.optional) ", optional" else ""}${filled?.let { ": " + it.second } ?: ""} · $sub" }) {
        val img = filled?.first
        if (img != null) {
            RefImage(img, Modifier.matchParentSize(), 20)
            Box(Modifier.matchParentSize().background(androidx.compose.ui.graphics.Brush.verticalGradient(0f to Color.Transparent, .45f to Color.Transparent, 1f to Color(0xC70E0C0A))))
        }
        // "Optional" as a quiet word, not another boxed badge on a dashed card.
        if (s.optional && filled == null) T("Optional", m.type.body.copy(fontSize = 10.5.sp), m.t.muted, Modifier.align(Alignment.TopEnd).padding(horizontal = 7.dp, vertical = 5.dp), maxLines = 1)
        val onImg = img != null
        Column(Modifier.align(if (onImg) Alignment.BottomStart else Alignment.Center).padding(horizontal = 6.dp, vertical = 6.dp).padding(top = if (onImg) 0.dp else 10.dp),
            horizontalAlignment = if (onImg) Alignment.Start else Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(3.dp)) {
            // Workstream 4 (design direction): a plain plus, no icon in a circle; a filled slot shows its picture or name instead.
            if (!onImg && filled == null) SIc("plus", 20.dp, m.t.ink)
            // On a picture every card reads the same way: the name (or the slot's own name) in bold, then the caption.
            T(when { onImg && s.kind == "character" -> filled.second; else -> s.label }, if (onImg) m.type.body.copy(fontSize = 13.sp, fontWeight = FontWeight.SemiBold) else m.scale.label,
                if (onImg) Color(0xFFF8F5EF) else m.t.ink, maxLines = 1, align = if (onImg) null else TextAlign.Center)
            T(if (filled != null && !onImg) filled.second else sub, m.type.body.copy(fontSize = 10.5.sp, lineHeight = 13.sp), if (onImg) Color(0xFFE7E1D6) else m.t.muted, maxLines = if (onImg) 1 else 2,
                align = if (onImg) null else TextAlign.Center)
        }
        if (filled != null && s.kind in setOf("character", "start", "end", "clip", "audio", "location", "product", "refad", "video")) {
            Box(Modifier.align(Alignment.TopEnd).size(48.dp).press { ui.onClearSlot(s.kind) }.semantics { contentDescription = "Remove ${s.label}"; role = Role.Button }, contentAlignment = Alignment.Center) {
                Box(Modifier.size(20.dp).clip(CircleShape).background(Color(0x8C0E0C0A)), contentAlignment = Alignment.Center) { SIc("close", 11.dp, Color(0xFFF8F5EF)) }
            }
        }
    }
}

/** A rounded dashed outline at the thumbnails' radius (the render's empty slot), drawn inside the bounds so no dash is clipped. */
private fun Modifier.dashed(c: Color, radius: Dp = 10.dp): Modifier = drawBehind {
    val w = 1.5.dp.toPx()
    drawRoundRect(c, topLeft = Offset(w / 2, w / 2), size = androidx.compose.ui.geometry.Size(size.width - w, size.height - w),
        cornerRadius = CornerRadius(radius.toPx()), style = Stroke(w, pathEffect = PathEffect.dashPathEffect(floatArrayOf(5.dp.toPx(), 4.dp.toPx()))))
}

/** The preset path: who (or the photo), the Shape tiles and Generate with the price; "Edit settings" opens the full composer. */
@Composable
private fun CollapsedBody(ui: ComposerUi, wide: Boolean) {
    val m = muse
    val d = ui.d
    val slot = d.collapsedSlot()
    val summary = listOfNotNull(SuiteRules.tierLabel(d.quality), "${d.duration} s", ui.cat.presets.firstOrNull { it.id == d.settings.preset }?.description?.lowercase()).joinToString(" · ")
    if (wide) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(28.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) { T("Who", m.scale.label, m.t.muted); SlotCard(ui, slot, Modifier.size(108.dp)) }
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                T("Shape", m.scale.label, m.t.muted)
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) { ComposerDraft.SHAPES.forEach { a -> ShapeTile(a, a == d.aspect, Modifier.size(108.dp)) { ui.update { it.copy(aspect = a) } } } }
            }
            Spacer(Modifier.weight(1f))
            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                T(summary, m.type.body.copy(fontSize = 13.sp), m.t.muted, Modifier.widthIn(max = 300.dp), maxLines = 2, align = TextAlign.End)
                WideGenerate(ui)
                EditSettingsLink(ui)
            }
        }
        return
    }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        SlotCard(ui, slot, Modifier.weight(1.2f).height(92.dp))
        ComposerDraft.SHAPES.forEach { a -> ShapeTile(a, a == d.aspect, Modifier.weight(1f).height(92.dp)) { ui.update { it.copy(aspect = a) } } }
    }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Column(Modifier.weight(1f)) {
            EditSettingsLink(ui)
            T(summary, m.type.body.copy(fontSize = 12.5.sp), m.t.muted, maxLines = 2)
        }
    }
}

@Composable
private fun EditSettingsLink(ui: ComposerUi) {
    val m = muse
    Box(Modifier.heightIn(min = 48.dp).press { ui.update { it.expand() } }.semantics { role = Role.Button }, contentAlignment = Alignment.CenterStart) {
        T("Edit settings", m.type.body.copy(fontSize = 14.sp, fontWeight = FontWeight.SemiBold, textDecoration = androidx.compose.ui.text.style.TextDecoration.Underline), m.t.ink, maxLines = 1)
    }
}

/** "Start from a preset": tiles with big names (the server's presets). Picking one collapses the composer. */
@Composable
private fun PresetRow(ui: ComposerUi, modifier: Modifier = Modifier, tileW: Dp, tileH: Dp) {
    val m = muse
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        // A fixed-height header: "Clear" keeps its 48 dp touch box without pushing the tiles down when a preset is picked.
        Row(Modifier.fillMaxWidth().height(20.dp), verticalAlignment = Alignment.CenterVertically) {
            T("Start from a preset", m.scale.label, m.t.ink, Modifier.weight(1f), maxLines = 1)
            if (ui.d.settings.preset != null) Box(Modifier.requiredHeight(48.dp).widthIn(min = 48.dp).press { ui.update { it.clearPreset() } }
                .semantics { contentDescription = "Clear preset"; role = Role.Button }, contentAlignment = Alignment.CenterEnd) { T("Clear", m.type.tiny, m.link) }
            else T("${ui.cat.presets.size} presets", m.type.tiny, m.t.muted)
        }
        // The picked preset is scrolled into view (it can sit past the screen's edge).
        val scroll = rememberScrollState()
        val step = with(androidx.compose.ui.platform.LocalDensity.current) { (tileW + 16.dp).roundToPx() }
        val pickedAt = ui.cat.presets.indexOfFirst { it.id == ui.d.settings.preset }
        LaunchedEffect(pickedAt) { if (pickedAt > 0) scroll.animateScrollTo((pickedAt * step - step / 2).coerceAtLeast(0)) }
        Row(Modifier.fillMaxWidth().horizontalScroll(scroll), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            ui.cat.presets.forEach { p ->
                val on = ui.d.settings.preset == p.id
                Column(Modifier.width(tileW + 6.dp).press { ui.update { it.pickPreset(ui.cat, p.id, ui.models.firstOrNull()?.id) } }
                    .semantics(mergeDescendants = true) { contentDescription = "Preset ${p.label}"; role = Role.Button; selected = on }) {
                    Box(Modifier.picked(on, m.t.accent, m.radii.control)) {
                        PreviewTile(presetPreview(ui.cat, p.id, p.label).copy(draw = null), Modifier.size(tileW, tileH).clip(RoundedCornerShape(m.radii.control)))
                    }
                    T(p.label, m.scale.caption, if (on) m.t.ink else m.t.muted, Modifier.padding(top = 4.dp, start = 3.dp), maxLines = 1)
                }
            }
        }
    }
}

/** While the catalog loads (presets, cameras, prices) or when it couldn't: say so, with Try again, instead of "0 presets". */
@Composable
private fun CatalogNote(ui: ComposerUi, modifier: Modifier = Modifier) {
    val m = muse
    val err = ui.catalogNote?.ifBlank { null }
    Row(modifier.fillMaxWidth().heightIn(min = 56.dp).clip(RoundedCornerShape(if (m.isA) 0.dp else 10.dp)).background(m.t.surface2).padding(start = 14.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        T(err ?: "Loading presets and cameras…", m.type.body.copy(fontSize = 13.sp, lineHeight = 17.sp), if (err != null) m.t.ink else m.t.muted, Modifier.weight(1f).padding(vertical = 10.dp), maxLines = 3)
        if (err != null) Box(Modifier.heightIn(min = 48.dp).widthIn(min = 48.dp).press(onClick = ui.onRetryCatalog).semantics { role = Role.Button }.padding(horizontal = 10.dp),
            contentAlignment = Alignment.Center) {
            T("Try again", m.type.body.copy(fontSize = 14.sp, fontWeight = FontWeight.SemiBold), m.link, maxLines = 1)
        }
    }
}

/** The result pane of the latest render and the recent takes (P1 / C1's strip). */
@Composable
private fun RecentTakes(ui: ComposerUi, job: studio.muse.app.data.Job?, recent: List<studio.muse.app.data.Job>, takes: List<studio.muse.app.data.Take>, openTake: (String) -> Unit,
                        retry: (SuiteShotRequest) -> Unit, wide: Boolean) {
    val m = muse
    val pane = SuitePane.of(job, takes, ui.lead?.name)
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        T("Recent takes", m.scale.label, m.t.ink, Modifier.padding(horizontal = if (wide) 0.dp else 16.dp))
        BoxWithConstraints(Modifier.fillMaxWidth()) {
        val rowW = maxWidth - 32.dp
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = if (wide) 0.dp else 16.dp), horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.Bottom) {
            // Nothing rendering yet: a wide empty card (the 9:16 pane is for a take in progress).
            val idle = pane.phase == StagePhase.IDLE
            val big = if (wide) 100.dp else 140.dp
            // Phone: the empty card is as tall as a recent take (146 dp) so the presets under it stay in view at 360 dp.
            val idleMod = when {
                wide -> Modifier.size(320.dp, 178.dp)
                recent.isEmpty() -> Modifier.size(rowW, 146.dp)
                else -> Modifier.size(240.dp, 146.dp)
            }
            Box((if (idle) idleMod else Modifier.size(big, big * 16 / 9)).clip(RoundedCornerShape(if (m.isA) 0.dp else 10.dp))) {
                SuiteResultPane(pane, ui.lead?.cover, emptyTitle = "Your shot appears here", emptyHint = "Describe it below, press Generate.", compact = true,
                    onRetry = { job?.let { retry(ui.d.request(ui.slots, ui.inputs, ui.recast)) } }, onTry = nextTier(ui.d.quality)?.let { t -> { ui.update { it.copy(quality = t) } } },
                    tryLabel = nextTier(ui.d.quality)?.let { "Try ${SuiteRules.tierLabel(it)}" }, onOpen = { job?.let { openTake(it.id) } })
            }
            recent.forEach { j ->
                val p = SuitePane.of(j, takes, j.modelName)
                val w = if (wide) 100.dp else 82.dp
                Box(Modifier.size(w, w * 16 / 9).clip(RoundedCornerShape(if (m.isA) 0.dp else 8.dp)).press { openTake(j.id) }.semantics { contentDescription = j.title }) {
                    if (p.phase == StagePhase.READY) {
                        RefImage(takes.firstOrNull { it.jobId == j.id }?.thumb ?: j.thumb, Modifier.matchParentSize(), 20)
                        PlayBadge(compact = w < 100.dp)
                    } else {
                        BlurredStageArt(j.thumb, moving = false)
                        T(if (p.phase == StagePhase.FAILED) "Failed" else p.badge, m.scale.micro, Color.White, Modifier.align(Alignment.Center), maxLines = 1)
                    }
                }
            }
        }
        }
        if (job != null && pane.step.isNotBlank()) T("${job.title} · ${pane.step}", m.type.tiny, m.t.muted, Modifier.padding(horizontal = if (wide) 0.dp else 16.dp), maxLines = 1)
    }
}

// ---------------------------------------------------------------- tablet and desktop

// Workstream 4: tablets follow the approved desktop render (plans/design-direction/composer-mac-b.png): the picture fills
// the height on the left, Setup and Inputs on the right, and the prompt bar with the pills and Generate along the bottom.
@Composable
private fun WideComposer(ui: ComposerUi, job: studio.muse.app.data.Job?, recent: List<studio.muse.app.data.Job>, takes: List<studio.muse.app.data.Take>, openTake: (String) -> Unit) {
    val m = muse
    var presets by remember { mutableStateOf(ui.empty) }
    Column(Modifier.fillMaxSize().padding(horizontal = 24.dp).padding(top = 8.dp, bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
            Row(Modifier.heightIn(min = 48.dp).press { ui.open(ComposerSheet(SheetKind.TOOLS)) }.semantics { contentDescription = "${ui.d.tool.title}, change mode"; role = Role.Button },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                T(ui.d.tool.title, m.scale.title, m.t.ink, maxLines = 1); SIc("chevd", 16.dp, m.t.muted)
            }
            Spacer(Modifier.weight(1f))
            if (ui.photo == null) Box(Modifier.heightIn(min = 48.dp).press { presets = !presets }.semantics { role = Role.Button }.padding(horizontal = 8.dp), contentAlignment = Alignment.Center) {
                T(if (presets) "Hide presets" else "Presets", m.scale.label, m.t.muted, maxLines = 1)
            }
        }
        if (ui.catalogNote != null) CatalogNote(ui)
        else if (ui.photo != null) PhotoPresets(wide = true) // Photo tool (workstream 3)
        else if (presets || ui.d.collapsed) PresetRow(ui, tileW = 150.dp, tileH = 96.dp)
        Row(Modifier.weight(1f).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            MediaHero(ui, job, takes, openTake, {}, Modifier.weight(1f).fillMaxHeight())
            Column(Modifier.width(360.dp).fillMaxHeight().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (ui.d.collapsed) { CollapsedBody(ui, wide = false); return@Column }
                T("Setup", m.scale.heading, m.t.ink)
                SettingRows(ui)
                T("Inputs", m.scale.heading, m.t.ink, Modifier.padding(top = 8.dp))
                if (ui.photo != null) PhotoSlotRow(ui, wide = false) else SlotThumbs(ui) // Photo tool (workstream 3)
                if (ui.d.tool == ComposerTool.SWAP) SwapPromptToggle(ui)
                if (ui.d.tool == ComposerTool.EXTEND) { ExtendDirection(ui); ExtendLength(ui, Modifier.fillMaxWidth()) }
                if (ui.addons.isNotEmpty()) AddonPills(ui)
                ui.rigRow(true)
            }
        }
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(m.radii.control)).background(m.roles.raised).padding(start = 16.dp, end = 12.dp, top = 12.dp, bottom = 8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (ui.showPrompt) Prompt(ui, Modifier.fillMaxWidth(), maxHeight = 96.dp)
            WideBar(ui)
        }
    }
}

@Composable
private fun WideGenerate(ui: ComposerUi) {
    val m = muse
    GenerateButton(ui, Modifier.widthIn(min = 200.dp))
}

/** The desktop bar: Quality, Shape, Length, Sound, Speaking and Takes pills (each a small list or slider), then Generate. */
@Composable
private fun WideBar(ui: ComposerUi) {
    val m = muse
    val d = ui.d
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (!ui.live) { Box(Modifier.weight(1f)) { ComingSoonLine(ui) }; return@Row }
        // Icon + value pills; when they don't all fit, the row scrolls and fades at the edge that has more (WS4 audit).
        val scroll = rememberScrollState()
        Row(Modifier.weight(1f).barScrollFade(scroll).horizontalScroll(scroll), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            // Photo tool (workstream 3): one Photos 1–4 list; no Quality, Shape, Length, Sound, Speaking or Takes (stills render at the shoot's size).
            ui.photo?.let { p -> MenuPill("layers", photoCountLabel(p.draft.count), "Photos", PhotoComposer.countItems(p.draft.count)) { i -> p.setCount(i + 1) }; PhotoModelPill(ui); return@Row }
            val tiers = ui.catalog?.tiers?.ifEmpty { null }?.map { it.id } ?: SuiteRules.TIERS
            MenuPill("gauge", SuiteRules.tierLabel(d.quality), "Quality", tiers.map { t -> "${SuiteRules.tierLabel(t)} · ${ComposerPrice.short(ui.tierEstimates[t])}" to (t == d.quality) }) { i -> ui.update { it.copy(quality = tiers[i]).fit(ui.catalog) } }
            // Owner only (WS7, as the Mac's "Model" pill): any engine, this quality's ladder first, then the others, then "Your providers".
            val groups = ModelPicker.groups(ui.catalog, d.quality, purpose = d.pickPurpose)
            if (ui.owner && !groups.isEmpty && d.tool in ComposerDraft.PROMPT_TOOLS) {
                MenuPill("cube", d.modelPill(ui.catalog), "Model, only you see models", modelMenuItems(d, groups)) { i -> ui.update { it.pinEngine(groups.all.getOrNull(i - 1)).fit(ui.catalog) } }
            }
            // Shape, length and takes are in the Settings row (as on the phone); the bar keeps sound and speaking.
            if (d.tool != ComposerTool.EXTEND) {
                Pill(if (d.sound) "volume" else "mute", "Sound", if (d.sound) null else "off", "Sound") { ui.update { it.copy(sound = !it.sound) } }
                val sp = listOf(null, true, false)
                MenuPill(if (d.speaking == false) "mic" else "talk", when (d.speaking) { true -> "Speaking"; false -> "Not speaking"; null -> "Speaking: auto" }, "Speaking",
                    listOf("Auto", "Speaking", "Not speaking").mapIndexed { i, l -> l to (sp[i] == d.speaking) }) { i -> ui.update { it.copy(speaking = sp[i]) } }
            }
        }
        ui.blocker?.takeIf { !ui.empty }?.let { T(it, m.type.tiny, m.t.warn, Modifier.widthIn(max = 200.dp), maxLines = 2) }
        WideGenerate(ui)
    }
}

/**
 * Character swap's add-ons as pills beside the quality ladder: Edit, Fast · beta, Upscale, each with its own price. One
 * picked replaces the quality render; tapping it again goes back to the ladder.
 */
@Composable
private fun AddonPills(ui: ComposerUi) {
    val m = muse
    val picked = ui.d.swapAddon
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            T("Add-ons", m.scale.label, m.t.muted, maxLines = 1)
            ui.addons.forEach { p ->
                val on = picked == p.addon
                val shape = RoundedCornerShape(if (m.isA) 0.dp else 999.dp)
                Box(Modifier.heightIn(min = 48.dp).press { ui.onAddon(p.addon) }
                    .semantics(mergeDescendants = true) { selected = on; role = Role.Button; contentDescription = "Add-on ${p.addon.label}, ${p.price}" }, contentAlignment = Alignment.Center) {
                    Row(Modifier.height(36.dp).alpha(if (p.available) 1f else .5f).clip(shape).background(if (on) m.t.ink else m.t.bg).border(if (on) 2.dp else 1.dp, if (on) m.t.ink else m.t.line, shape)
                        .padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        T(p.addon.label, m.type.body.copy(fontSize = 13.sp, fontWeight = FontWeight.SemiBold), if (on) m.t.bg else m.t.ink, maxLines = 1)
                        T(p.price, m.type.mono.copy(fontSize = 12.sp), if (on) m.t.bg.copy(alpha = .8f) else m.t.muted, maxLines = 1)
                    }
                }
            }
        }
        picked?.let { T("${it.label} · ${it.detail} · tap again for ${SuiteRules.tierLabel(ui.d.quality)}", m.type.tiny, m.t.muted, maxLines = 2) }
    }
}

@Composable
private fun Pill(icon: String, label: String, value: String?, tip: String, onClick: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(if (m.isA) 0.dp else 8.dp)
    Box(Modifier.heightIn(min = 48.dp).press(onClick = onClick).semantics(mergeDescendants = true) { contentDescription = "$tip: $label ${value.orEmpty()}"; role = Role.Button }, contentAlignment = Alignment.Center) {
        // A plain text item (the render's "HD ▾ · Sound · Not speaking"), no border or fill.
        Row(Modifier.padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            SIc(icon, 18.dp, m.t.muted)
            T(label, m.scale.label, m.t.ink, maxLines = 1)
            if (value != null) T(value, m.scale.label, m.t.muted, maxLines = 1)
        }
    }
}

@Composable
internal fun MenuPill(icon: String, label: String, tip: String, items: List<Pair<String, Boolean>>, onPick: (Int) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        Pill(icon, label, null, tip) { open = true }
        DropdownMenu(open, { open = false }) {
            items.forEachIndexed { i, (l, on) ->
                DropdownMenuItem(text = { T(l, muse.type.body.copy(fontSize = 14.sp, fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal), muse.t.ink) },
                    onClick = { onPick(i); open = false }, trailingIcon = if (on) ({ SIc("check", 16.dp, muse.t.accent) }) else null)
            }
        }
    }
}

@Composable
private fun SliderPill(icon: String, label: String, tip: String, value: Int, range: IntRange, onChange: (Int) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        Pill(icon, label, null, tip) { open = true }
        DropdownMenu(open, { open = false }) {
            Column(Modifier.width(260.dp).padding(horizontal = 16.dp, vertical = 8.dp)) {
                T("$value s", muse.type.mono.copy(fontSize = 14.sp), muse.t.ink)
                MuseSlider(value.coerceIn(range), range.first, range.last, onChange)
                Row(Modifier.fillMaxWidth()) { T("${range.first} s", muse.type.tiny, muse.t.muted, Modifier.weight(1f)); T("${range.last} s", muse.type.tiny, muse.t.muted) }
            }
        }
    }
}

/**
 * The bottom bar's scroll cue (AI suite, workstream 1): the pills fade out over 24 dp at an edge with more to scroll to,
 * so a cut-off pill reads as "scroll", not as a bug. An alpha mask, so it works on any theme's background.
 */
private fun Modifier.barScrollFade(scroll: androidx.compose.foundation.ScrollState): Modifier =
    graphicsLayer { compositingStrategy = androidx.compose.ui.graphics.CompositingStrategy.Offscreen }
        .drawWithContent {
            drawContent()
            val w = 24.dp.toPx().coerceAtMost(size.width / 2)
            if (scroll.canScrollForward) drawRect(
                androidx.compose.ui.graphics.Brush.horizontalGradient(listOf(Color.Black, Color.Transparent), startX = size.width - w, endX = size.width),
                topLeft = androidx.compose.ui.geometry.Offset(size.width - w, 0f), size = androidx.compose.ui.geometry.Size(w, size.height),
                blendMode = androidx.compose.ui.graphics.BlendMode.DstIn)
            if (scroll.canScrollBackward) drawRect(
                androidx.compose.ui.graphics.Brush.horizontalGradient(listOf(Color.Transparent, Color.Black), startX = 0f, endX = w),
                size = androidx.compose.ui.geometry.Size(w, size.height), blendMode = androidx.compose.ui.graphics.BlendMode.DstIn)
        }

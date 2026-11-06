package studio.muse.app.ui.screens.suite.composer

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
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
import studio.muse.app.ui.screens.suite.InputSlotUploader
import studio.muse.app.ui.screens.suite.SIc
import studio.muse.app.ui.screens.suite.SlotId
import studio.muse.app.ui.screens.suite.SlotKind
import studio.muse.app.ui.screens.suite.SuiteOffScreen
import studio.muse.app.ui.screens.suite.SuitePane
import studio.muse.app.ui.screens.suite.SuiteResultPane
import studio.muse.app.ui.screens.suite.nextTier
import studio.muse.app.ui.screens.suite.rememberInputSlotPicker
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse

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
    LaunchedEffect(toolId) { ComposerTool.entries.firstOrNull { it.id == toolId }?.let { t -> if (store.composer.value.tool != t) store.composer.update { it.withTool(t) } } }
    // The clip picked in New video becomes Character swap's / Recast's source.
    LaunchedEffect(video.clip?.id) { video.clip?.id?.let { id -> if (store.recast.value.clipId != id) store.recast.update { it.copy(clipId = id) } } }
    val catalog = cat
    if (catalog != null && !catalog.enabled) { SuiteOffScreen(d.tool.title); return }
    val camCat = catalog?.camera ?: studio.muse.app.data.CameraCatalog()
    val inputs = catalog?.tier(d.quality)?.slots ?: SuiteInputs.NONE
    val talkingSlots by store.talkingSlots.collectAsState()
    val ugcSlots by store.ugcSlots.collectAsState()
    val ownFlow = if (d.tool == ComposerTool.TALKING) store.talkingSlots else store.ugcSlots
    val own = when (d.tool) { ComposerTool.TALKING -> talkingSlots; ComposerTool.UGC -> ugcSlots; else -> studio.muse.app.ui.screens.suite.InputSlots() }
    val live = d.tool.isLive(catalog)
    val req = d.request(slots, inputs, recast, own)
    val problem = d.problem(slots, recast, own)
    // Character swap's add-ons (Edit, Fast · beta) are priced by the add-on estimate (the video studio's), not the ladder's.
    val clipSeconds = recast.clipId?.let { id -> video.clip?.takeIf { it.id == id }?.durationSec ?: if (id == SampleData.SAMPLE_CLIP) SampleData.sampleMeta.durationSec else null }
    val addon = d.swapAddon
    val addonPills = if (d.tool == ComposerTool.SWAP) SwapAddons.pills(st.video ?: studio.muse.app.data.VideoFeatures.DEFAULT, prefs.fastBeta, d.takes, clipSeconds) else emptyList()
    val (suiteEst, estErr) = rememberEstimate(req.takeIf { problem == null && live && addon == null }, catalog?.enabled == true)
    val est = if (addon != null) clipSeconds?.takeIf { problem == null }?.let { SwapAddons.estimate(addon, d.takes, it) } else suiteEst
    val blocker = ComposerPrice.blocker(problem, est, estErr)
    val owner = store.owner || prefs.owner
    val wantTiers = sheet?.kind == SheetKind.SETTINGS || d.collapsed
    val tierEstimates = (catalog?.tiers?.map { it.id } ?: SuiteRules.TIERS).associateWith { t ->
        rememberEstimate(req.copy(quality = t).takeIf { wantTiers && problem == null && live }, catalog?.enabled == true).first
    }
    val uploader = remember(c) { InputSlotUploader(c) }
    val pickFile = rememberInputSlotPicker { id, uri -> scope.launch { uploader.upload(store.composerSlots, id, uri) } }
    val pickOwn = rememberInputSlotPicker { id, uri -> scope.launch { uploader.upload(ownFlow, id, uri) } }
    fun update(f: (ComposerDraft) -> ComposerDraft) = store.composer.update(f)
    fun open(s: ComposerSheet?) { store.sheet.value = s }
    fun generate() {
        if (!live) { c.repo.toast("${d.tool.title} is coming soon"); return }
        if (blocker != null) { c.repo.toast(blocker); return }
        if (est == null) return
        open(null)
        if (addon != null) {
            scope.launch { c.repo.createJob(SwapAddons.request(d, recast, addon, clipSeconds))?.let { j -> store.shotJobs.update { (it - j.id) + j.id } } }
            return
        }
        scope.launch { store.generate(req, store.shotJobs) }
    }
    fun onAddon(a: SwapAddon) {
        val pill = addonPills.firstOrNull { it.addon == a } ?: return
        when {
            a == SwapAddon.UPSCALE -> c.repo.toast(if (pill.available) "Upscale a finished take from its result" else "Upscale is coming soon")
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
        addons = addonPills, onAddon = ::onAddon,
        lead = st.model(d.characterId), clipName = recast.clipId?.let { id -> video.clip?.takeIf { it.id == id }?.name ?: if (id == SampleData.SAMPLE_CLIP) SampleData.sampleMeta.name else "Your clip" },
        models = st.models, outfits = st.outfitsOf(d.characterId),
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
                is Suggestion.Move -> base.addMove(sg.move, at)
            }
            if (msg != null) c.repo.toast(msg)
            if (t === base) null else { update { it.copy(tokens = t, modelId = t.character?.id ?: it.modelId) }; t }
        },
    )
    val recent = st.jobs.filter { it.request.engine == SuiteRules.ENGINE && it.id != job?.id }.take(8)
    ScreenBox {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val wide = ComposerLayout.wide(maxWidth.value.toInt())
            Column(Modifier.fillMaxSize()) {
                TopBar(if (wide) "" else d.tool.title, onBack = { nav.back() }) {
                    MoreMenu(listOfNotNull(
                        MenuItem("grid", "Storyboard") { nav.go(Routes.SUITE_STORYBOARD) },
                        if (owner) MenuItem("quality", "Engines (owner)") { nav.go(Routes.SUITE_ENGINES) } else null,
                    ))
                }
                if (wide) WideComposer(ui, job, recent, st.takes) { j -> nav.go(Routes.suiteTake(j)) }
                else PhoneComposer(ui, job, recent, st.takes, { j -> nav.go(Routes.suiteTake(j)) }, { r -> scope.launch { store.generate(r, store.shotJobs) } })
            }
            sheet?.let { sh ->
                ComposerSheetHost(sh, SheetContext(
                    d = d, catalog = catalog, slots = slots, recast = recast, models = st.models, outfitsOf = { st.outfitsOf(it) }, owner = owner, wide = wide, live = live,
                    estimate = est, blocker = blocker, tierEstimates = tierEstimates, update = ::update, updateRecast = { f -> store.recast.update(f) },
                    setTab = { t -> store.sheet.update { it?.copy(tab = t) } }, open = { open(it) }, close = { open(null) }, onMove = ::onMove,
                    onPickSlot = { id -> pickFile(id) }, onClearSlot = { id -> store.composerSlots.update { it.clear(id) } },
                    onPickCharacter = { id, o -> pickCharacter(id, o) }, onGenerate = ::generate, onStoryboard = { nav.go(Routes.SUITE_STORYBOARD) },
                    frame = frame, onTapFace = ::tapFace,
                ))
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
    val models: List<studio.muse.app.data.Model>,
    val outfits: List<studio.muse.app.data.Outfit>,
    val update: ((ComposerDraft) -> ComposerDraft) -> Unit,
    val open: (ComposerSheet?) -> Unit,
    val onGenerate: () -> Unit,
    val onSlot: (ToolSlot) -> Unit,
    val onClearSlot: (String) -> Unit,
    val onPick: (PromptTokens, Caret, Suggestion) -> PromptTokens?,
    /** Character swap's add-on pills (empty on other tools). */
    val addons: List<AddonPill> = emptyList(),
    val onAddon: (SwapAddon) -> Unit = {},
) {
    val toolSlots: List<ToolSlot> get() = ToolSlots.of(d.tool, inputs, slots, catalog?.recastMaxPeople ?: SuiteRules.MAX_CAST)
    val showPrompt: Boolean get() = d.tool == ComposerTool.SHOT || d.tool == ComposerTool.TALKING || d.tool == ComposerTool.UGC || (d.tool == ComposerTool.SWAP && d.swapPrompt)
    /** Before anything is typed or picked: the preset row shows under the composer. */
    val empty: Boolean get() = d.tool == ComposerTool.SHOT && d.tokens.isEmpty && d.characterId == null && slots.isEmpty && d.settings.preset == null
    val canGo: Boolean get() = live && blocker == null && est != null
}

// ---------------------------------------------------------------- phone

@Composable
private fun PhoneComposer(ui: ComposerUi, job: studio.muse.app.data.Job?, recent: List<studio.muse.app.data.Job>, takes: List<studio.muse.app.data.Take>, openTake: (String) -> Unit, retry: (SuiteShotRequest) -> Unit) {
    val m = muse
    Column(Modifier.fillMaxSize()) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(top = 12.dp, bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            RecentTakes(ui, job, recent, takes, openTake, retry, wide = false)
            if (ui.empty || ui.d.collapsed) PresetRow(ui, Modifier.padding(horizontal = 16.dp), tileW = 128.dp, tileH = 84.dp)
        }
        Column(Modifier.fillMaxWidth().drawBehind { drawLine(m.t.line, Offset(0f, 0f), Offset(size.width, 0f), 1.dp.toPx()) }.background(m.t.surface).navigationBarsPadding()
            .padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 10.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            ToolRow(ui, wide = false)
            if (ui.d.collapsed) {
                CollapsedBody(ui, wide = false)
                return@Column
            }
            if (ui.d.chips.isNotEmpty()) ChipsRow(ui)
            if (ui.d.tool == ComposerTool.SWAP) SwapPromptToggle(ui)
            if (ui.showPrompt) Prompt(ui)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                ui.toolSlots.forEach { s -> SlotCard(ui, s, Modifier.weight(1f).height(96.dp)) }
                repeat((3 - ui.toolSlots.size).coerceAtLeast(0)) { Spacer(Modifier.weight(1f)) }
            }
            if (ui.addons.isNotEmpty()) AddonPills(ui)
            PhoneBar(ui)
        }
    }
}

@Composable
private fun PhoneBar(ui: ComposerUi) {
    val m = muse
    if (!ui.live) { ComingSoonLine(ui); return }
    ui.blocker?.takeIf { !ui.empty }?.let { T(it, m.type.tiny, m.t.muted, maxLines = 2) }
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        BarButton(Modifier.press { ui.open(ComposerSheet(SheetKind.SETTINGS)) }.semantics { contentDescription = "Quality ${SuiteRules.tierLabel(ui.d.quality)}"; role = Role.Button }) {
            SIc("gauge", 18.dp, m.t.muted); T(SuiteRules.tierLabel(ui.d.quality), m.type.body.copy(fontSize = 15.sp, fontWeight = FontWeight.SemiBold), m.t.ink, maxLines = 1); SIc("chevd", 14.dp, m.t.muted)
        }
        BarButton(Modifier.width(48.dp).press { ui.open(ComposerSheet(SheetKind.SETTINGS)) }.semantics { contentDescription = "Settings"; role = Role.Button }, square = true) { SIc("sliders", 20.dp, m.t.ink) }
        Spacer(Modifier.weight(1f))
        val (a, b) = ui.d.barSummary
        Column(horizontalAlignment = Alignment.End) {
            T(a, m.type.body.copy(fontSize = 13.sp), m.t.muted, maxLines = 1)
            T(b, m.type.body.copy(fontSize = 13.sp), m.t.muted, maxLines = 1)
        }
        RoundGenerate(ui)
    }
}

@Composable
private fun BarButton(modifier: Modifier, square: Boolean = false, content: @Composable RowScope.() -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(if (m.isA) 0.dp else 10.dp)
    Row(modifier.height(48.dp).clip(shape).background(m.t.bg).border(if (m.isD) 2.dp else 1.dp, m.t.line, shape).padding(horizontal = if (square) 0.dp else 12.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally), content = content)
}

/** The phone's round Generate: a spark and the live price ("—", "Free", "$0.16"). */
@Composable
private fun RoundGenerate(ui: ComposerUi) {
    val m = muse
    val price = ComposerPrice.short(ui.est)
    Column(Modifier.size(62.dp).alpha(if (ui.canGo) 1f else .5f).clip(CircleShape).background(m.t.cta).press(onClick = ui.onGenerate)
        .semantics { contentDescription = "Generate, $price"; role = Role.Button }, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        SIc("sparkle", 18.dp, m.t.ctaInk)
        T(price, m.type.mono.copy(fontSize = 11.sp, letterSpacing = .04.em), m.t.ctaInk, maxLines = 1)
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
            T(d.cardTitle(ui.cat).uppercase(), m.type.mono.copy(fontSize = 11.sp, letterSpacing = .14.em, fontWeight = FontWeight.Medium), m.t.ink, maxLines = 1)
            Box(Modifier.size(3.dp).clip(CircleShape).background(m.t.line))
            T(d.cardTagline(ui.cat), m.type.body.copy(fontSize = 13.5.sp), m.t.muted, maxLines = 1)
        } else Column(Modifier.weight(1f)) {
            T(d.cardTitle(ui.cat).uppercase(), m.type.mono.copy(fontSize = 11.5.sp, letterSpacing = .14.em, fontWeight = FontWeight.Medium), m.t.ink, maxLines = 1)
            T(if (ui.live) d.cardTagline(ui.cat) else "Coming soon · ${d.tool.tagline}", m.type.body.copy(fontSize = 13.sp), m.t.muted, maxLines = 1)
        }
        val shape = RoundedCornerShape(if (m.isA) 0.dp else 8.dp)
        Box(Modifier.heightIn(min = 48.dp).press { ui.open(ComposerSheet(SheetKind.TOOLS)) }.semantics { contentDescription = "Change tool"; role = Role.Button }, contentAlignment = Alignment.Center) {
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
private fun ChipsRow(ui: ComposerUi) {
    val m = muse
    val d = ui.d
    val refsMax = SlotKind.IMAGE.capacity(ui.inputs)
    val refs = ui.slots.values.keys.count { it.kind == SlotKind.IMAGE }
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        d.chips.forEach { chip ->
            val sum = ComposerCatalog.summary(chip, d.settings, ui.cat, refs, refsMax)
            val value = if (chip == ComposerChip.CAMERA && d.directed != null) "Directed" else ComposerCatalog.ellipsize(sum.value, 26)
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
                Row(Modifier.height(38.dp).clip(shape).background(m.t.bg).border(if (m.isD) 2.dp else 1.dp, m.t.line, shape).padding(start = 6.dp, end = 11.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                    if (render == null) Box(Modifier.size(26.dp).dashedBox(m.t.muted), contentAlignment = Alignment.Center) { SIc("image", 14.dp, m.t.muted) }
                    else HardwareImage(render, Modifier.size(26.dp), sample = 8, gray = auto)
                    T(chip.key, m.type.mono.copy(fontSize = 10.sp, letterSpacing = .08.em), m.t.muted, maxLines = 1)
                    T(value, m.type.body.copy(fontSize = 13.sp, fontWeight = if (auto) FontWeight.Normal else FontWeight.SemiBold), if (auto) m.t.muted else m.t.ink, maxLines = 1)
                }
            }
        }
    }
}

private fun Modifier.dashedBox(c: Color): Modifier = drawBehind {
    drawRoundRect(c, style = Stroke(1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 2.dp.toPx()))), cornerRadius = CornerRadius(2.dp.toPx()))
}

@Composable
private fun Prompt(ui: ComposerUi, modifier: Modifier = Modifier, maxHeight: Dp = 120.dp) {
    PromptBox(ui.d.tokens, ui.d.tool.placeholder, ui.models, ui.outfits, ui.cat, ui.d.tool == ComposerTool.TALKING,
        onChange = { t -> ui.update { it.copy(tokens = t, modelId = if (it.tokens.character != null && t.character == null && it.modelId == it.tokens.character?.id) null else (t.character?.id ?: it.modelId)) } },
        onPick = ui.onPick, onToken = { k -> ui.open(ComposerSheet(SheetKind.TOKEN, token = k)) }, modifier = modifier.fillMaxWidth(), maxHeight = maxHeight)
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

/** A slot card: "+", the caps label, the caption that states its limit, an Optional pill; greyed when it waits on another. */
@Composable
private fun SlotCard(ui: ComposerUi, s: ToolSlot, modifier: Modifier) {
    val m = muse
    val enabled = s.enabled && (ui.live || s.kind == "character")
    val filled: Pair<studio.muse.app.data.ImageRef?, String>? = when (s.kind) {
        "character" -> ui.lead?.let { l -> (ui.outfits.firstOrNull { it.id == ui.d.characterOutfit }?.front ?: l.cover) to l.name.substringBefore(' ') }
        "start" -> ui.slots[SlotId(SlotKind.START)]?.let { v -> (v.image ?: v.preview?.let { studio.muse.app.data.ImageRef(url = it) }) to s.label }
        "end" -> ui.slots[SlotId(SlotKind.END)]?.let { v -> (v.image ?: v.preview?.let { studio.muse.app.data.ImageRef(url = it) }) to s.label }
        "clip" -> ui.recast.clipId?.let { null to (ui.clipName ?: "Clip") }
        "people" -> ui.recast.people.takeIf { p -> p.any { it.characterId != null } }?.let { p -> null to "${p.size} ${if (p.size == 1) "person" else "people"}" }
        else -> ToolSlots.ownSlot(ui.d.tool, s.kind)?.let { ui.own[it] }?.let { v -> (if (v.image != null || v.preview != null) (v.image ?: studio.muse.app.data.ImageRef(url = v.preview)) else null) to (v.error ?: if (v.uploading) "Uploading…" else v.name.ifBlank { s.label }) }
    }
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
        if (s.optional && filled == null) Box(Modifier.align(Alignment.TopEnd).padding(5.dp).background(m.t.surface).border(1.dp, m.t.line).padding(horizontal = 4.dp, vertical = 1.dp)) {
            T("OPTIONAL", m.type.mono.copy(fontSize = 8.5.sp, letterSpacing = .08.em), m.t.muted, maxLines = 1)
        }
        val onImg = img != null
        Column(Modifier.align(if (onImg) Alignment.BottomStart else Alignment.Center).padding(horizontal = 6.dp, vertical = 6.dp).padding(top = if (onImg) 0.dp else 10.dp),
            horizontalAlignment = if (onImg) Alignment.Start else Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(3.dp)) {
            if (!onImg) Box(Modifier.size(28.dp).clip(CircleShape).background(m.t.surface).border(1.dp, m.t.line, CircleShape), contentAlignment = Alignment.Center) {
                if (filled != null) SIc("check", 14.dp, m.t.ink) else SIc("plus", 14.dp, m.t.ink)
            }
            T(if (onImg && s.kind == "character") filled.second else s.label.uppercase(), if (onImg && s.kind == "character") m.type.body.copy(fontSize = 13.sp, fontWeight = FontWeight.SemiBold) else m.type.mono.copy(fontSize = 9.5.sp, letterSpacing = .1.em),
                if (onImg) Color(0xFFF8F5EF) else m.t.ink, maxLines = 1, align = if (onImg) null else TextAlign.Center)
            T(if (filled != null && !onImg) filled.second else sub, m.type.body.copy(fontSize = 10.5.sp, lineHeight = 13.sp), if (onImg) Color(0xFFE7E1D6) else m.t.muted, maxLines = if (onImg) 1 else 2,
                align = if (onImg) null else TextAlign.Center)
        }
        if (filled != null && s.kind in setOf("character", "start", "end", "clip", "audio", "location", "product", "refad")) {
            Box(Modifier.align(Alignment.TopEnd).size(48.dp).press { ui.onClearSlot(s.kind) }.semantics { contentDescription = "Remove ${s.label}"; role = Role.Button }, contentAlignment = Alignment.Center) {
                Box(Modifier.size(20.dp).clip(CircleShape).background(Color(0x8C0E0C0A)), contentAlignment = Alignment.Center) { SIc("close", 11.dp, Color(0xFFF8F5EF)) }
            }
        }
    }
}

private fun Modifier.dashed(c: Color): Modifier = drawBehind {
    drawRect(c, style = Stroke(1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 3.dp.toPx()))))
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
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) { T("WHO", m.type.mono.copy(fontSize = 10.5.sp, letterSpacing = .14.em), m.t.muted); SlotCard(ui, slot, Modifier.size(108.dp)) }
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                T("SHAPE", m.type.mono.copy(fontSize = 10.5.sp, letterSpacing = .14.em), m.t.muted)
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) { ComposerDraft.SHAPES.forEach { a -> ShapeTile(a, a == d.aspect, Modifier.size(108.dp)) { ui.update { it.copy(aspect = a) } } } }
            }
            Spacer(Modifier.weight(1f))
            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                T(summary, m.type.body.copy(fontSize = 13.sp), m.t.muted, maxLines = 1)
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
        RoundGenerate(ui)
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
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            T("START FROM A PRESET", m.type.mono.copy(fontSize = 11.sp, letterSpacing = .16.em, fontWeight = FontWeight.Medium), m.t.ink, Modifier.weight(1f), maxLines = 1)
            if (ui.d.settings.preset != null) Box(Modifier.heightIn(min = 48.dp).press { ui.update { it.clearPreset() } }, contentAlignment = Alignment.CenterEnd) { T("Clear", m.type.tiny, m.t.muted) }
            else T("${ui.cat.presets.size} presets", m.type.tiny, m.t.muted)
        }
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            ui.cat.presets.forEach { p ->
                val on = ui.d.settings.preset == p.id
                Box(Modifier.let { if (on) it.border(2.dp, m.t.ink).padding(3.dp) else it.padding(3.dp) }) {
                    PreviewTile(presetPreview(ui.cat, p.id, p.label), Modifier.size(tileW, tileH).press { ui.update { it.pickPreset(ui.cat, p.id, ui.models.firstOrNull()?.id) } }
                        .semantics { contentDescription = "Preset ${p.label}"; role = Role.Button })
                }
            }
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
        T("RECENT TAKES", m.type.mono.copy(fontSize = 11.sp, letterSpacing = .16.em, fontWeight = FontWeight.Medium), m.t.ink, Modifier.padding(horizontal = if (wide) 0.dp else 16.dp))
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = if (wide) 0.dp else 16.dp), horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.Bottom) {
            // Nothing rendering yet: a wide empty card (the 9:16 pane is for a take in progress).
            val idle = pane.phase == StagePhase.IDLE
            val big = if (wide) 100.dp else 140.dp
            Box((if (idle) Modifier.size(if (wide) 320.dp else 240.dp, if (wide) 178.dp else 200.dp) else Modifier.size(big, big * 16 / 9)).clip(RoundedCornerShape(if (m.isA) 0.dp else 10.dp))) {
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
                        Box(Modifier.align(Alignment.Center).size(30.dp).clip(CircleShape).background(Color.White.copy(alpha = .9f)), contentAlignment = Alignment.Center) { Ic("play", 14.dp, Color(0xFF141210)) }
                    } else {
                        BlurredStageArt(j.thumb, moving = false)
                        T(if (p.phase == StagePhase.FAILED) "FAILED" else p.badge.uppercase(), m.type.mono.copy(fontSize = 10.sp), Color.White, Modifier.align(Alignment.Center), maxLines = 1)
                    }
                }
            }
        }
        if (job != null && pane.step.isNotBlank()) T("${job.title} · ${pane.step}", m.type.tiny, m.t.muted, Modifier.padding(horizontal = if (wide) 0.dp else 16.dp), maxLines = 1)
    }
}

// ---------------------------------------------------------------- tablet and desktop

@Composable
private fun WideComposer(ui: ComposerUi, job: studio.muse.app.data.Job?, recent: List<studio.muse.app.data.Job>, takes: List<studio.muse.app.data.Take>, openTake: (String) -> Unit) {
    val m = muse
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 32.dp, vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Column {
            T("VIDEO SUITE", m.type.mono.copy(fontSize = 11.sp, letterSpacing = .16.em), m.t.muted)
            T(ui.d.tool.title, m.type.h2, m.t.ink, upper = m.isB, maxLines = 1)
        }
        RecentTakes(ui, job, recent, takes, openTake, {}, wide = true)
        val shape = RoundedCornerShape(if (m.isA) 0.dp else 14.dp)
        Column(Modifier.widthIn(max = 960.dp).fillMaxWidth().align(Alignment.CenterHorizontally).clip(shape).background(m.t.surface).border(if (m.isD) 2.5.dp else 1.dp, m.t.line, shape)) {
            Box(Modifier.padding(horizontal = 14.dp, vertical = 6.dp)) { ToolRow(ui, wide = true) }
            Box(Modifier.fillMaxWidth().height(1.dp).background(m.t.line))
            if (ui.d.collapsed) {
                Box(Modifier.padding(16.dp)) { CollapsedBody(ui, wide = true) }
            } else {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (ui.d.chips.isNotEmpty()) ChipsRow(ui)
                    if (ui.d.tool == ComposerTool.SWAP) SwapPromptToggle(ui)
                    Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                        if (ui.showPrompt) Prompt(ui, Modifier.weight(1f), maxHeight = 160.dp) else Spacer(Modifier.weight(1f))
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) { ui.toolSlots.forEach { s -> SlotCard(ui, s, Modifier.size(104.dp)) } }
                    }
                    if (ui.addons.isNotEmpty()) AddonPills(ui)
                }
                Box(Modifier.fillMaxWidth().height(1.dp).background(m.t.line))
                WideBar(ui)
            }
        }
        if (ui.empty || ui.d.collapsed) PresetRow(ui, Modifier.widthIn(max = 960.dp).align(Alignment.CenterHorizontally), tileW = 150.dp, tileH = 96.dp)
    }
}

@Composable
private fun WideGenerate(ui: ComposerUi) {
    val m = muse
    Box(Modifier.height(48.dp).alpha(if (ui.canGo) 1f else .5f).clip(RoundedCornerShape(if (m.isA) 0.dp else 10.dp)).background(m.t.cta).press(onClick = ui.onGenerate)
        .semantics { role = Role.Button }.padding(horizontal = 22.dp), contentAlignment = Alignment.Center) {
        T(ComposerPrice.button(ui.est).let { if (m.isA) it.uppercase() else it }, m.type.mono.copy(fontSize = 12.5.sp, letterSpacing = .12.em, fontWeight = FontWeight.Medium), m.t.ctaInk, maxLines = 1)
    }
}

/** The desktop bar: Quality, Shape, Length, Sound, Speaking and Takes pills (each a small list or slider), then Generate. */
@Composable
private fun WideBar(ui: ComposerUi) {
    val m = muse
    val d = ui.d
    Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (!ui.live) { Box(Modifier.weight(1f)) { ComingSoonLine(ui) }; return@Row }
        Row(Modifier.weight(1f).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            val tiers = ui.catalog?.tiers?.ifEmpty { null }?.map { it.id } ?: SuiteRules.TIERS
            MenuPill("gauge", SuiteRules.tierLabel(d.quality), "Quality", tiers.map { t -> "${SuiteRules.tierLabel(t)} · ${ComposerPrice.short(ui.tierEstimates[t])}" to (t == d.quality) }) { i -> ui.update { it.copy(quality = tiers[i]).fit(ui.catalog) } }
            MenuPill("ratio", d.aspect, "Shape", ComposerDraft.SHAPES.map { it to (it == d.aspect) }) { i -> ui.update { it.copy(aspect = ComposerDraft.SHAPES[i]) } }
            val range = d.lengthRange(ui.catalog)
            SliderPill("clock", "${d.duration}s", "Length", d.duration, range) { v -> ui.update { it.copy(duration = v) } }
            Pill("volume", "Sound", if (d.sound) "On" else "Off", "Sound") { ui.update { it.copy(sound = !it.sound) } }
            val sp = listOf(null, true, false)
            MenuPill("talk", "Speaking ${when (d.speaking) { true -> "On"; false -> "Off"; null -> "Auto" }}", "Speaking", listOf("Auto", "On", "Off").mapIndexed { i, l -> l to (sp[i] == d.speaking) }) { i -> ui.update { it.copy(speaking = sp[i]) } }
            val max = ui.catalog?.takesMax ?: 4
            MenuPill("layers", "${d.takes}/$max", "Takes", (1..max).map { "$it take${if (it > 1) "s" else ""}" to (it == d.takes) }) { i -> ui.update { it.copy(takes = i + 1) } }
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
            T("ADD-ONS", m.type.mono.copy(fontSize = 10.5.sp, letterSpacing = .14.em), m.t.muted, maxLines = 1)
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
        Row(Modifier.height(36.dp).clip(shape).background(m.t.bg).border(1.dp, m.t.line, shape).padding(horizontal = 11.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(7.dp)) {
            SIc(icon, 15.dp, m.t.muted)
            T(label, m.type.body.copy(fontSize = 13.sp, fontWeight = FontWeight.Medium), m.t.ink, maxLines = 1)
            if (value != null) T(value, m.type.body.copy(fontSize = 13.sp), m.t.muted, maxLines = 1)
        }
    }
}

@Composable
private fun MenuPill(icon: String, label: String, tip: String, items: List<Pair<String, Boolean>>, onPick: (Int) -> Unit) {
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

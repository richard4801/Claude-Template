package studio.muse.app.ui.screens.suite

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import studio.muse.app.data.SuiteCatalog
import studio.muse.app.data.SuiteEstimate
import studio.muse.app.data.SuiteRules
import studio.muse.app.data.SuiteShotRequest
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.components.Chip
import studio.muse.app.ui.components.Cta2
import studio.muse.app.ui.components.FlowRow
import studio.muse.app.ui.components.Input
import studio.muse.app.ui.components.MenuItem
import studio.muse.app.ui.components.MoreMenu
import studio.muse.app.ui.components.NoteBox
import studio.muse.app.ui.components.Pill
import studio.muse.app.ui.components.RefImage
import studio.muse.app.ui.components.Seg
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.Tiny
import studio.muse.app.ui.components.TopBar
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.OutfitTile
import studio.muse.app.ui.screens.ScreenBox
import studio.muse.app.ui.screens.StagePhase
import studio.muse.app.ui.screens.camera.DirectedModePanel
import studio.muse.app.ui.theme.muse

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

/** The Generate label: the estimate's `buttonLabel`, or why it can't go. */
fun generateLabel(e: SuiteEstimate?, fallback: String = "Generate") = e?.buttonLabel?.ifBlank { null } ?: fallback

/** M2 · Shot builder: the result pane on top (blurred render with live progress), Cast / Scene / Camera / Length / Quality, Generate with its price. */
@Composable
fun SuiteShotScreen() {
    val c = LocalContainer.current
    val nav = LocalNav.current
    val m = muse
    val store = c.suite
    val cat by store.catalog.collectAsState()
    val d by store.shot.collectAsState()
    val st by c.repo.state.collectAsState()
    val started by store.shotJobs.collectAsState()
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { if (store.catalog.value == null) store.load() }
    val catalog = cat
    if (catalog != null && !catalog.enabled) { SuiteOffScreen("Shot"); return }
    // The lead character: the picked one, else the studio's first.
    LaunchedEffect(st.models) { if (d.modelId == null && st.models.isNotEmpty()) store.shot.update { it.copy(modelId = st.models.first().id, outfitId = st.outfitsOf(st.models.first().id).firstOrNull()?.id) } }
    val model = st.model(d.modelId)
    val job = started.lastOrNull()?.let { id -> st.jobs.firstOrNull { it.id == id } }
    val pane = SuitePane.of(job, st.takes, model?.name)
    val req = d.request()
    val (est, estErr) = rememberEstimate(req.takeIf { d.problem() == null }, catalog?.enabled == true)
    val busy = pane.phase == StagePhase.RENDERING || pane.phase == StagePhase.QUEUED
    fun go(r: SuiteShotRequest = req) { scope.launch { store.generate(r, store.shotJobs) } }
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar("Shot", onBack = { nav.back() }) {
                MoreMenu(listOfNotNull(
                    MenuItem("grid", "Add to storyboard") { addToBoard(c, d); nav.go(Routes.SUITE_STORYBOARD) },
                    if (store.owner) MenuItem("quality", "Engines (owner)") { nav.go(Routes.SUITE_ENGINES) } else null,
                ))
            }
            Box(Modifier.fillMaxWidth().height(286.dp).clip(RoundedCornerShape(0.dp))) {
                SuiteResultPane(pane, model?.cover, emptyTitle = "Your shot appears here", compact = true,
                    onRetry = { job?.let { go() } }, onTry = nextTier(d.quality)?.let { t -> { store.shot.update { it.copy(quality = t) }; go(req.copy(quality = t)) } },
                    tryLabel = nextTier(d.quality)?.let { "Try ${SuiteRules.tierLabel(it)}" }, onOpen = { job?.let { nav.go(Routes.suiteTake(it.id)) } })
            }
            ToolTabs(listOf("users" to "Cast", "type" to "Scene", "camera" to "Camera", "clock" to "Length", "sliders" to "Quality"), d.tab.replaceFirstChar { it.uppercase() }) { t ->
                store.shot.update { it.copy(tab = t.lowercase()) }
            }
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                when (d.tab) {
                    "cast" -> CastPanel(d, st)
                    "scene" -> ScenePanel(d)
                    "length" -> LengthPanel(d, catalog)
                    "quality" -> QualityPanel(d, catalog)
                    else -> CameraPanel(d, catalog)
                }
                catalog?.takeIf { it.test }?.let { Pill("Test renders · free", "good") }
            }
            Column(Modifier.fillMaxWidth().navigationBarsPadding().padding(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 12.dp)) {
                val note = d.problem() ?: estErr ?: est?.message?.takeIf { !est.ok } ?: est?.warnings?.firstOrNull()
                GenerateBar(if (busy) "Rendering · ${pane.percent}" else generateLabel(est), { if (!busy && d.problem() == null && est?.ok != false) go() },
                    off = busy || d.problem() != null || est == null || !est.ok, note = note)
            }
        }
    }
}

private fun addToBoard(c: studio.muse.app.AppContainer, d: ShotDraft) {
    val shot = StoryShot("s" + System.nanoTime(), d.title.ifBlank { d.scene.take(32).ifBlank { "New shot" } }, d.scene, d.camera.moves.firstOrNull()?.id ?: "static", d.duration)
    c.suite.board.update { b -> (b ?: Storyboard("Untitled storyboard", listOfNotNull(d.modelId))).let { it.copy(shots = it.shots + shot) } }
    c.repo.toast("Added to the storyboard")
}

@Composable
private fun CastPanel(d: ShotDraft, st: studio.muse.app.data.StudioState) {
    val m = muse
    val store = LocalContainer.current.suite
    Row(Modifier.fillMaxWidth()) { SLbl("Cast", Modifier.weight(1f)); Tiny("Lead · identity locked") }
    if (st.models.isEmpty()) NoteBox("Make a model first: her character sheet keeps her the same in every shot.")
    st.models.forEach { mod ->
        val on = mod.id == d.modelId
        Row(Modifier.fillMaxWidth().suiteCard(m, on).press { store.shot.update { it.copy(modelId = mod.id, outfitId = st.outfitsOf(mod.id).firstOrNull()?.id) } }.padding(10.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            RefImage(mod.cover, Modifier.size(42.dp, 52.dp).background(m.t.surface2))
            Column(Modifier.weight(1f)) {
                T(mod.name, m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink, maxLines = 1)
                Tiny("${mod.niche} · ${mod.age}" + if (mod.filled == 0) " · no sheet yet" else "")
            }
            if (on) SBadge(if (mod.locked) "Locked" else "Lead", if (mod.locked) "good" else "")
        }
    }
    val outfits = st.outfitsOf(d.modelId)
    if (outfits.isNotEmpty()) {
        SLbl("Outfit")
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            outfits.forEach { o -> OutfitTile(o, o.id == d.outfitId, { store.shot.update { it.copy(outfitId = o.id) } }) }
        }
    }
    SLbl("Speaking")
    Seg(listOf("auto" to "Auto", "yes" to "Speaks", "no" to "Silent"), when (d.speaking) { true -> "yes"; false -> "no"; null -> "auto" }, { k ->
        store.shot.update { it.copy(speaking = when (k) { "yes" -> true; "no" -> false; else -> null }) }
    }, Modifier.fillMaxWidth())
    Tiny(when (d.speaking) { true -> "She speaks the lines in quotes in the scene"; false -> "She doesn't speak, sing or mouth words"; null -> "From the audio, else silent" })
}

@Composable
private fun ScenePanel(d: ShotDraft) {
    val store = LocalContainer.current.suite
    Seg(listOf("text" to "Text", "image" to "Image", "refs" to "Refs"), d.sceneTab, { k -> store.shot.update { it.copy(sceneTab = k) } }, Modifier.fillMaxWidth(), small = true)
    if (d.sceneTab != "text") NoteBox("Start frames and reference images are added on the Mac for now. Describe the moment here.")
    Input(d.title, { v -> store.shot.update { it.copy(title = v) } }, placeholder = "Title (optional)")
    Input(d.scene, { v -> store.shot.update { it.copy(scene = v.take(2000)) } }, placeholder = "Describe the moment: where she is, what she does, how she feels. Lines in quotes are spoken.", area = true)
    Tiny("${d.scene.length} / 2000")
}

@Composable
private fun CameraPanel(d: ShotDraft, catalog: SuiteCatalog?) {
    val m = muse
    val nav = LocalNav.current
    val store = LocalContainer.current.suite
    val cam = catalog?.camera ?: studio.muse.app.data.CameraCatalog()
    var directed by remember { mutableStateOf(d.camera.directed != null) }
    Seg(listOf("preset" to "Preset", "directed" to "Directed · Blender"), if (directed) "directed" else "preset", { directed = it == "directed" }, Modifier.fillMaxWidth(), small = true)
    if (directed) {
        DirectedModePanel(d.title.ifBlank { "Shot" }) { json ->
            val el = runCatching { Json.parseToJsonElement(json) }.getOrNull()
            store.shot.update { it.copy(camera = it.camera.copy(directed = el)) }
        }
        if (d.camera.directed != null) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            SBadge("Directed camera applied", "good"); T("Use preset", m.type.tiny, m.t.accent, Modifier.press { store.shot.update { it.copy(camera = it.camera.copy(directed = null)) }; directed = false })
        }
        return
    }
    val plates = listOf(
        "Body" to cam.bodies.firstOrNull { it.id == d.camera.body }?.render,
        "Lens" to cam.lenses.firstOrNull { it.id == d.camera.lens }?.render,
        "Light" to cam.lighting.firstOrNull { it.id == d.camera.lighting }?.render,
        "Look" to (cam.palettes.firstOrNull { it.id == d.camera.palette }?.render ?: cam.looks.firstOrNull { it.id == d.camera.look }?.render),
    )
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        plates.forEach { (label, render) ->
            Column(Modifier.weight(1f).press { openBag(store, nav, label) }, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                HardwareImage(render, Modifier.fillMaxWidth().height(76.dp), sample = 4)
                T(label.uppercase(), m.type.mono.copy(fontSize = 9.5.sp), m.t.muted)
            }
        }
    }
    T(d.camera.summary(cam), m.type.mono.copy(fontSize = 12.5.sp), m.t.ink)
    Row(Modifier.fillMaxWidth().suiteCard(m).press { openBag(store, nav, "Move") }.padding(8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        val mv = d.camera.moves.firstOrNull()
        Box(Modifier.size(72.dp, 40.dp).border(1.dp, m.t.line)) { MovePictogram(mv?.id ?: "static", cam.move(mv?.id)?.category ?: "static", Modifier.fillMaxSize()) }
        Column(Modifier.weight(1f)) {
            T(d.camera.moveTitle(cam), m.type.body.copy(fontSize = 13.5.sp, fontWeight = FontWeight.Bold), m.t.ink, maxLines = 1)
            T(d.camera.moveSub(cam), m.type.tiny, m.t.muted, maxLines = 1)
        }
        SIc("chev", 18.dp, m.t.ink)
    }
    Cta2("Open camera bag", { openBag(store, nav, "Body") }, Modifier.fillMaxWidth(), height = 46.dp)
}

/** Opens the camera bag (always dark) on [tab] with a working copy of the shot's camera. */
fun openBag(store: SuiteStore, nav: studio.muse.app.ui.Nav, tab: String) {
    store.bag.value = store.shot.value.camera
    nav.go(Routes.suiteCamera(tab))
}

@Composable
private fun LengthPanel(d: ShotDraft, catalog: SuiteCatalog?) {
    val store = LocalContainer.current.suite
    val max = catalog?.tier(d.quality)?.maxSeconds ?: 30
    SLbl("Length")
    FlowRow { ShotDraft.LENGTHS.forEach { s -> Chip("$s s", d.duration == s, { store.shot.update { it.copy(duration = s) } }) } }
    if (d.duration > max) NoteBox("${SuiteRules.tierLabel(d.quality)} makes up to $max s. Pick a shorter length or another quality.", warn = true)
    SLbl("Takes")
    Seg((1..(catalog?.takesMax ?: 4)).map { "$it" to "$it" }, "${d.takes}", { k -> store.shot.update { it.copy(takes = k.toInt()) } }, Modifier.fillMaxWidth(), small = true)
    SLbl("Frame")
    FlowRow { (catalog?.aspectRatios?.ifEmpty { null } ?: listOf("9:16", "16:9", "1:1")).forEach { a -> Chip(a, d.aspect == a, { store.shot.update { it.copy(aspect = a) } }) } }
}

@Composable
private fun QualityPanel(d: ShotDraft, catalog: SuiteCatalog?) {
    val m = muse
    val store = LocalContainer.current.suite
    SLbl("Quality")
    (catalog?.tiers ?: SuiteRules.TIERS.map { studio.muse.app.data.SuiteTier(it, SuiteRules.tierLabel(it)) }).forEach { t ->
        val on = t.id == d.quality
        Row(Modifier.fillMaxWidth().suiteCard(m, on).press(enabled = t.available || catalog == null) { store.shot.update { it.copy(quality = t.id) } }.padding(12.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                T(t.label, m.type.body.copy(fontWeight = FontWeight.Bold), if (t.available || catalog == null) m.t.ink else m.t.muted)
                Tiny(listOfNotNull(t.detail.ifBlank { null }, t.resolution?.lowercase()?.replace("p", "p"), t.maxSeconds?.let { "up to $it s" }).joinToString(" · ").ifBlank { "—" })
            }
            T(when { !t.available && catalog != null -> "Not available"; t.fromPerSec != null -> "from $${"%.2f".format(java.util.Locale.US, t.fromPerSec)}/s"; else -> "" },
                m.type.mono.copy(fontSize = 12.sp), m.t.ink)
        }
    }
    Tiny("Draft is the default. Every Generate shows its price first.")
}

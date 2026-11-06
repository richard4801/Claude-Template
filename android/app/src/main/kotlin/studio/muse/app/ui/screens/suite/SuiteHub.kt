package studio.muse.app.ui.screens.suite

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.widthIn
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.role
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import studio.muse.app.data.Job
import studio.muse.app.data.SuiteRules
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.TabBar
import studio.muse.app.ui.components.Cta2
import studio.muse.app.ui.components.NoteBox
import studio.muse.app.ui.components.Pill
import studio.muse.app.ui.components.RefImage
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.Tiny
import studio.muse.app.ui.components.TopBar
import studio.muse.app.ui.components.Wordmark
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.ScreenBox
import studio.muse.app.ui.screens.StagePhase
import studio.muse.app.ui.screens.BlurredStageArt
import studio.muse.app.ui.screens.creditLabel
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse

/** A mode of the Video suite: each opens the composer on its tool (Storyboard has its own screen). [soon] = no backend yet. */
data class SuiteMode(val id: String, val title: String, val sub: String, val render: String, val route: String, val soon: Boolean = false)

val SUITE_MODES = listOf(
    SuiteMode("shot", "Shot", "Text/image → video", "palette-01-naturalistic", Routes.SUITE_SHOT),
    SuiteMode("swap", "Character swap", "Into a real clip", "palette-04-bleached-warm", Routes.SUITE_SWAP),
    SuiteMode("photo", "Photo", "Stills of your character", "lens-01-clean-prime", Routes.SUITE_PHOTO), // Photo tool (workstream 3): Photoshoot moved here
    SuiteMode("storyboard", "Storyboard", "Shots, one cast", "palette-02-teal-orange", Routes.SUITE_STORYBOARD),
    SuiteMode("talking", "Talking", "Voice & lipsync", "light-06-ring-creator", Routes.suiteCompose("talking"), soon = true),
    SuiteMode("ugc", "UGC ad", "Product → ad", "grip-05-slider", Routes.suiteCompose("ugc"), soon = true),
    SuiteMode("extend", "Extend & upscale", "Longer, sharper", "stock-03-sensor", Routes.suiteCompose("extend"), soon = true),
)

/** M1 · the Video suite hub: mode tiles, the camera stage, Edit, recent takes. Suite off: the owner's or member's state. */
@Composable
fun SuiteHubScreen() {
    val c = LocalContainer.current
    val nav = LocalNav.current
    val m = muse
    val store = c.suite
    val cat by store.catalog.collectAsState()
    val err by store.catalogError.collectAsState()
    val st by c.repo.state.collectAsState()
    val prefs by c.prefs.collectAsState()
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { store.load() }
    ScreenBox {
        BoxWithConstraints(Modifier.fillMaxSize()) {
        // Tablets: three mode tiles a row (two would be 400 dp wide strips) and a readable column.
        val cols = if (maxWidth >= 600.dp) 3 else 2
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(top = 10.dp, bottom = 110.dp)
            .widthIn(max = 960.dp).align(Alignment.TopCenter), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            // The wordmark alone: a bell here did nothing when tapped (Home's bell is the one with the render status).
            Row(Modifier.fillMaxWidth().height(48.dp), verticalAlignment = Alignment.CenterVertically) { Wordmark() }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
                T("Video suite", m.type.h2, m.t.ink, Modifier.weight(1f), upper = m.isB, maxLines = 1)
                Pill(creditLabel(st.wallet, st.balance))
            }
            val catalog = cat
            if (catalog?.test == true) Pill("Test renders · free", "good")
            if (catalog != null && !catalog.enabled) {
                SuiteOff(store.owner || prefs.owner)
            } else {
                // The reason and Try again (NoteBox with content drops its text, so both go in the content).
                if (err != null && catalog == null) NoteBox(err!!, warn = true) {
                    T(err!!, m.type.body.copy(fontSize = 13.sp, lineHeight = 18.sp), m.t.ink, Modifier.weight(1f))
                    Box(Modifier.heightIn(min = 48.dp).press { scope.launch { store.load() } }.semantics { role = Role.Button }, contentAlignment = Alignment.Center) {
                        T("Try again", m.type.tiny.copy(fontWeight = FontWeight.Bold), m.link)
                    }
                }
                SUITE_MODES.chunked(cols).forEach { row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        // "Coming soon" follows the catalog's `tools` (an older catalog: the built-in list).
                        row.forEach { mode -> ModeTile(mode.copy(soon = !(catalog?.toolAvailable(if (mode.id == "ugc") "ugc_ad" else mode.id, !mode.soon) ?: !mode.soon)), Modifier.weight(1f)) { nav.go(mode.route) } }
                        repeat(cols - row.size) { Spacer(Modifier.weight(1f)) }
                    }
                }
                LinkCard("cube", "Camera stage", "Direct the camera in Blender · Directed mode") { nav.go(Routes.CAMERA_STAGE) }
                LinkCard("scissors", "Edit", "Cut, colour and captions on your takes") { nav.go(Routes.EDIT) }
                val recent = st.jobs.filter { it.request.engine == SuiteRules.ENGINE }.take(8)
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    SLbl("Recent takes", Modifier.weight(1f))
                    Box(Modifier.heightIn(min = 48.dp).widthIn(min = 48.dp).press { nav.tab(Routes.GALLERY) }.semantics { contentDescription = "All takes"; role = Role.Button },
                        contentAlignment = Alignment.CenterEnd) { T("All →", m.type.tiny, m.t.muted) }
                }
                if (recent.isEmpty()) Tiny("Your shots show up here while they render and when they're ready.")
                else Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    recent.forEach { j -> RecentTile(j, st.takes.filter { it.jobId == j.id }) { nav.go(Routes.suiteTake(j.id)) } }
                }
            }
        }
        }
        TabBar(Routes.SUITE)
    }
}

@Composable
private fun ModeTile(mode: SuiteMode, modifier: Modifier, onClick: () -> Unit) {
    val m = muse
    Column(modifier.suiteCard(m).press(onClick = onClick).semantics(mergeDescendants = true) { contentDescription = mode.title }) {
        Box(Modifier.fillMaxWidth().height(78.dp)) {
            HardwareImage(mode.render, Modifier.fillMaxSize(), sample = 4)
            if (mode.soon) Box(Modifier.align(Alignment.TopEnd).padding(6.dp).background(Color.Black.copy(alpha = .55f)).padding(horizontal = 6.dp, vertical = 2.dp)) {
                T("SOON", m.type.mono.copy(fontSize = 9.5.sp, letterSpacing = 1.sp), Color.White)
            }
        }
        Column(Modifier.padding(start = 10.dp, end = 10.dp, top = 8.dp, bottom = 10.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(mode.title, m.type.body.copy(fontSize = 13.5.sp, fontWeight = FontWeight.Bold), m.t.ink, maxLines = 1)
            T(if (mode.soon) "Coming soon" else mode.sub, m.type.tiny.copy(fontSize = 12.sp), m.t.muted, maxLines = 1)
        }
    }
}

@Composable
fun LinkCard(icon: String, title: String, sub: String, onClick: () -> Unit) {
    val m = muse
    Row(Modifier.fillMaxWidth().suiteCard(m).press(onClick = onClick).padding(horizontal = 12.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(Modifier.size(30.dp, 44.dp).clip(RoundedCornerShape(if (m.isA) 0.dp else 6.dp)).background(m.t.surface2), contentAlignment = Alignment.Center) { SIc(icon, 18.dp, m.t.muted) }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(title, m.type.body.copy(fontSize = 13.5.sp, fontWeight = FontWeight.Bold), m.t.ink, maxLines = 1)
            T(sub, m.type.tiny.copy(fontSize = 12.sp), m.t.muted, maxLines = 2)
        }
        SIc("chev", 18.dp, m.t.ink)
    }
}

@Composable
private fun RecentTile(j: Job, takes: List<studio.muse.app.data.Take>, onClick: () -> Unit) {
    val m = muse
    val pane = SuitePane.of(j, takes, j.modelName)
    Column(Modifier.width(72.dp).press(onClick = onClick).semantics(mergeDescendants = true) { contentDescription = "${j.title}, ${pane.badge.ifBlank { "ready" }}" },
        verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(Modifier.size(72.dp, 128.dp).clip(RoundedCornerShape(if (m.isA) 0.dp else 8.dp))) {
            when (pane.phase) {
                StagePhase.READY -> { RefImage(takes.firstOrNull()?.thumb ?: j.thumb, Modifier.fillMaxSize(), 20)
                    Box(Modifier.align(Alignment.BottomCenter).padding(8.dp).size(30.dp).clip(RoundedCornerShape(999.dp)).background(Color.White.copy(alpha = .9f)), contentAlignment = Alignment.Center) { Ic("play", 14.dp, Color(0xFF141210)) } }
                StagePhase.RENDERING -> { BlurredStageArt(j.thumb, moving = false); T(pane.percent, m.type.body.copy(fontSize = 22.sp), Color.White, Modifier.align(Alignment.Center)) }
                StagePhase.QUEUED -> { BlurredStageArt(j.thumb, moving = false); Box(Modifier.align(Alignment.BottomStart).background(Color(0xFF141210)).padding(horizontal = 4.dp, vertical = 2.dp)) {
                    T(pane.badge.uppercase(), m.type.mono.copy(fontSize = 8.5.sp), Color.White, maxLines = 1) } }
                else -> { BlurredStageArt(j.thumb, moving = false); T("FAILED", m.type.mono.copy(fontSize = 10.sp), Color.White, Modifier.align(Alignment.Center)) }
            }
        }
        T(j.title.uppercase(), m.type.mono.copy(fontSize = 9.5.sp), m.t.muted, maxLines = 1)
    }
}

/**
 * The suite is off (server SUITE_MODE=off, the production default). The owner learns how to turn it on (with Copy for
 * the variable name); a member is told to ask the owner.
 */
@Composable
fun SuiteOff(owner: Boolean) {
    val m = muse
    val clip = LocalClipboardManager.current
    val c = LocalContainer.current
    Column(Modifier.fillMaxWidth().suiteCard(m).padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SIc("film", 26.dp, m.t.muted)
        if (owner) {
            T("Turn on the AI suite", m.type.h3, m.t.ink)
            T("The server's AI suite is switched off. In Railway → Variables, set ${SuiteRules.MODE_VAR} to one of:", m.type.body.copy(fontSize = 14.sp), m.t.ink)
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                T("live · real renders, charged at the shown price", m.type.tiny, m.t.ink)
                T("mock · free test renders (a test pattern) to try everything", m.type.tiny, m.t.ink)
            }
            Row(Modifier.fillMaxWidth().background(m.t.surface2).padding(horizontal = 12.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                T(SuiteRules.MODE_VAR, m.type.mono.copy(fontSize = 14.sp), m.t.ink, Modifier.weight(1f))
                Row(Modifier.heightIn(min = 48.dp).press { clip.setText(AnnotatedString(SuiteRules.MODE_VAR)); c.repo.toast("Copied ${SuiteRules.MODE_VAR}") }.semantics { contentDescription = "Copy ${SuiteRules.MODE_VAR}" },
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    SIc("copy", 16.dp, m.t.ink); T("Copy", m.type.tiny.copy(fontWeight = FontWeight.Bold), m.t.ink)
                }
            }
            Tiny("Railway restarts the server; the suite appears here on its own.")
        } else {
            T("The AI suite isn't on yet", m.type.h3, m.t.ink)
            Tiny("Ask the studio owner to switch it on. Your other tools work as usual.")
        }
    }
}

/** Shown in place of a mode screen while the suite is off. */
@Composable
fun SuiteOffScreen(title: String) {
    val nav = LocalNav.current
    val c = LocalContainer.current
    val prefs by c.prefs.collectAsState()
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar(title, onBack = { nav.back() })
            Column(Modifier.padding(16.dp)) { SuiteOff(c.suite.owner || prefs.owner) }
        }
    }
}

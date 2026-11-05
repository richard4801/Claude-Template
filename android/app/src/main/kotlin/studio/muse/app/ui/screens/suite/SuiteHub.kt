package studio.muse.app.ui.screens.suite

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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

/** A mode of the Video suite. [route] null = coming soon (no backend yet). */
data class SuiteMode(val id: String, val title: String, val sub: String, val render: String, val route: String?)

val SUITE_MODES = listOf(
    SuiteMode("shot", "Shot", "Text/image → video", "palette-01-naturalistic", Routes.SUITE_SHOT),
    SuiteMode("swap", "Character swap", "Into a real clip", "palette-04-bleached-warm", Routes.SUITE_SWAP),
    SuiteMode("storyboard", "Storyboard", "Shots, one cast", "palette-02-teal-orange", Routes.SUITE_STORYBOARD),
    SuiteMode("talking", "Talking", "Voice & lipsync", "light-06-ring-creator", null),
    SuiteMode("ugc", "UGC ad", "Product → ad", "grip-05-slider", null),
    SuiteMode("extend", "Extend & upscale", "Longer, sharper", "stock-03-sensor", null),
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
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(top = 10.dp, bottom = 110.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Wordmark(); Spacer(Modifier.weight(1f)); Ic("bell", 22.dp, m.t.ink)
            }
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
                T("Video suite", m.type.h2, m.t.ink, Modifier.weight(1f), upper = m.isB, maxLines = 1)
                Pill(creditLabel(st.wallet, st.balance))
            }
            val catalog = cat
            if (catalog?.test == true) Pill("Test renders · free", "good")
            if (catalog != null && !catalog.enabled) {
                SuiteOff(store.owner || prefs.owner)
            } else {
                if (err != null && catalog == null) NoteBox(err!!, warn = true) { T("Try again", m.type.tiny.copy(fontWeight = FontWeight.Bold), m.t.accent, Modifier.press { scope.launch { store.load() } }) }
                SUITE_MODES.chunked(2).forEach { row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        row.forEach { mode -> ModeTile(mode, Modifier.weight(1f)) { nav.go(mode.route ?: Routes.suiteSoon(mode.id)) } }
                    }
                }
                LinkCard("cube", "Camera stage", "Direct the camera in Blender · Directed mode") { nav.go(Routes.CAMERA_STAGE) }
                LinkCard("scissors", "Edit", "Cut, colour and captions on your takes") { nav.go(Routes.EDIT) }
                val recent = st.jobs.filter { it.request.engine == SuiteRules.ENGINE }.take(8)
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    SLbl("Recent takes", Modifier.weight(1f))
                    T("All →", m.type.tiny, m.t.muted, Modifier.press { nav.tab(Routes.GALLERY) })
                }
                if (recent.isEmpty()) Tiny("Your shots show up here while they render and when they're ready.")
                else Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    recent.forEach { j -> RecentTile(j, st.takes.filter { it.jobId == j.id }) { nav.go(Routes.suiteTake(j.id)) } }
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
            if (mode.route == null) Box(Modifier.align(Alignment.TopEnd).padding(6.dp).background(Color.Black.copy(alpha = .55f)).padding(horizontal = 6.dp, vertical = 2.dp)) {
                T("SOON", m.type.mono.copy(fontSize = 9.5.sp, letterSpacing = 1.sp), Color.White)
            }
        }
        Column(Modifier.padding(start = 10.dp, end = 10.dp, top = 8.dp, bottom = 10.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(mode.title, m.type.body.copy(fontSize = 13.5.sp, fontWeight = FontWeight.Bold), m.t.ink, maxLines = 1)
            T(if (mode.route == null) "Coming soon" else mode.sub, m.type.tiny.copy(fontSize = 12.sp), m.t.muted, maxLines = 1)
        }
    }
}

@Composable
fun LinkCard(icon: String, title: String, sub: String, onClick: () -> Unit) {
    val m = muse
    Row(Modifier.fillMaxWidth().suiteCard(m).press(onClick = onClick).padding(horizontal = 12.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(Modifier.size(30.dp, 44.dp).background(m.t.surface2), contentAlignment = Alignment.Center) { SIc(icon, 18.dp, m.t.muted) }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(title, m.type.body.copy(fontSize = 13.5.sp, fontWeight = FontWeight.Bold), m.t.ink, maxLines = 1)
            T(sub, m.type.tiny.copy(fontSize = 12.sp), m.t.muted, maxLines = 1)
        }
        SIc("chev", 18.dp, m.t.ink)
    }
}

@Composable
private fun RecentTile(j: Job, takes: List<studio.muse.app.data.Take>, onClick: () -> Unit) {
    val m = muse
    val pane = SuitePane.of(j, takes, j.modelName)
    Column(Modifier.width(72.dp).press(onClick = onClick), verticalArrangement = Arrangement.spacedBy(4.dp)) {
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
                Row(Modifier.press { clip.setText(AnnotatedString(SuiteRules.MODE_VAR)); c.repo.toast("Copied ${SuiteRules.MODE_VAR}") }.semantics { contentDescription = "Copy ${SuiteRules.MODE_VAR}" },
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

/** Talking · lipsync, UGC ad, Extend & upscale: no backend yet, so a quiet coming-soon state. */
@Composable
fun SuiteSoonScreen(id: String) {
    val nav = LocalNav.current
    val m = muse
    val mode = SUITE_MODES.firstOrNull { it.id == id } ?: SUITE_MODES.last()
    ScreenBox {
        Column(Modifier.fillMaxSize()) {
            TopBar(mode.title, onBack = { nav.back() })
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                HardwareImage(mode.render, Modifier.fillMaxWidth().height(200.dp).clip(RoundedCornerShape(if (m.isA) 0.dp else m.t.r)), sample = 2)
                T("Coming soon", m.type.h2, m.t.ink, upper = m.isB)
                T("${mode.title} (${mode.sub.lowercase()}) is on its way to the Video suite. Until then, Shot and Character swap make most of it.", m.type.body, m.t.muted)
                Cta2("Make a Shot", { nav.go(Routes.SUITE_SHOT) }, Modifier.fillMaxWidth())
            }
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

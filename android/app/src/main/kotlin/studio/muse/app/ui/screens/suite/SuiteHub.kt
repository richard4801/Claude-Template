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
import androidx.compose.runtime.setValue
import studio.muse.app.data.Job
import studio.muse.app.data.SuiteRules
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.TabBar
import studio.muse.app.ui.components.Cta2
import studio.muse.app.ui.components.NoteBox
import studio.muse.app.ui.components.Pill
import studio.muse.app.ui.components.PlayBadge
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
import studio.muse.app.ui.theme.scale
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.radii
import kotlin.math.roundToInt

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

/**
 * Suite home (redesign frame "Suite home", owner decision 1): the header and tabs, the quick prompt bar whose one button
 * opens the Shot composer with the words carried over (it never generates), recent takes as portrait cards, and what is
 * running. Suite off or not loaded: the owner's or member's state, as before.
 */
@Composable
fun SuiteHubScreen() {
    val c = LocalContainer.current
    val nav = LocalNav.current
    val store = c.suite
    val cat by store.catalog.collectAsState()
    val err by store.catalogError.collectAsState()
    val st by c.repo.state.collectAsState()
    val prefs by c.prefs.collectAsState()
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { store.load() }
    SuiteTokens {
    val m = muse
    ScreenBox(bg = m.roles.canvas) {
        BoxWithConstraints(Modifier.fillMaxSize()) {
        val wide = maxWidth >= 720.dp
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = if (wide) 24.dp else 16.dp).padding(top = 12.dp, bottom = 110.dp)
            .widthIn(max = 1120.dp).align(Alignment.TopCenter), verticalArrangement = Arrangement.spacedBy(20.dp)) {
            SuiteHeader(current = null) { Pill(creditLabel(st.wallet, st.balance)) }
            val catalog = cat
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
                val running = st.jobs.filter { it.state == "running" || it.state == "queued" }.take(5)
                if (wide) Row(horizontalArrangement = Arrangement.spacedBy(20.dp), verticalAlignment = Alignment.Top) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(28.dp)) {
                        QuickBar(wide = true) { nav.go(it) }
                        RecentTakes(st.jobs, st.takes, wide = true, open = { j -> nav.go(Routes.suiteTake(j)) }, library = { nav.tab(Routes.GALLERY) })
                    }
                    RunningPanel(running, Modifier.width(294.dp)) { nav.go(Routes.QUEUE) }
                } else {
                    QuickBar(wide = false) { nav.go(it) }
                    RecentTakes(st.jobs, st.takes, wide = false, open = { j -> nav.go(Routes.suiteTake(j)) }, library = { nav.tab(Routes.GALLERY) })
                    RunningPanel(running, Modifier.fillMaxWidth()) { nav.go(Routes.QUEUE) }
                }
            }
        }
        }
        TabBar(Routes.SUITE)
    }
    }
}

/**
 * The quick prompt: plain words here (the composer adds @ and #), the length and shape it will use, and "Open in
 * composer": the Shot composer with these words added to its prompt. No price because nothing here spends.
 */
@Composable
private fun QuickBar(wide: Boolean, go: (String) -> Unit) {
    val m = muse
    val c = LocalContainer.current
    val d by c.suite.composer.collectAsState()
    var words by androidx.compose.runtime.saveable.rememberSaveable { androidx.compose.runtime.mutableStateOf("") }
    Column(Modifier.fillMaxWidth().suitePanel().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(Modifier.fillMaxWidth().heightIn(min = 44.dp)) {
            if (words.isEmpty()) T("Describe a shot. Add @ and # in the composer.", m.scale.body, m.roles.ink2, maxLines = 2)
            androidx.compose.foundation.text.BasicTextField(words, { words = it }, Modifier.fillMaxWidth().semantics { contentDescription = "Describe a shot" },
                textStyle = m.scale.body.copy(color = m.roles.ink), cursorBrush = androidx.compose.ui.graphics.SolidColor(m.roles.accent))
        }
        val open = {
            val text = words.trim()
            if (text.isNotEmpty()) c.suite.composer.value = c.suite.composer.value.let { cur ->
                val next = (cur.tokens.parts.maxOfOrNull { it.key } ?: 0) + 1
                val lead = if (cur.tokens.isEmpty) text else " $text"
                cur.copy(tokens = studio.muse.app.ui.screens.suite.composer.PromptTokens(cur.tokens.parts + studio.muse.app.ui.screens.suite.composer.PromptPart.Text(lead, next)))
            }
            words = ""
            go(Routes.SUITE_SHOT)
        }
        val button = @Composable { mod: Modifier ->
            val shape = RoundedCornerShape(m.radii.control)
            Box(mod.heightIn(min = 48.dp).clip(shape).background(m.roles.action).press(onClick = open).padding(horizontal = 16.dp)
                .semantics { role = Role.Button; contentDescription = "Open in composer. Nothing is generated until you press Generate there." },
                contentAlignment = Alignment.Center) {
                T("Open in composer", m.scale.label.copy(fontWeight = FontWeight.SemiBold), m.roles.onAction, maxLines = 1)
            }
        }
        // Phones: the chips, then the button across the bar (it never truncates); wide: one row.
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            SuitePill("video-camera", "Shot")
            SuitePill("clock", "${d.duration} s")
            SuitePill("device-mobile", d.aspect)
            if (wide) { Spacer(Modifier.weight(1f)); button(Modifier) }
        }
        if (!wide) button(Modifier.fillMaxWidth())
    }
}

/** The newest finished Suite takes, one portrait card per job ("Kept" on kept takes), and Open Library. */
@Composable
private fun RecentTakes(jobs: List<Job>, takes: List<studio.muse.app.data.Take>, wide: Boolean, open: (String) -> Unit, library: () -> Unit) {
    val m = muse
    val done = jobs.filter { it.state == "done" }.mapNotNull { j -> takes.firstOrNull { it.jobId == j.id }?.let { j to it } }.take(10)
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            T("Recent takes", m.scale.title, m.roles.ink, Modifier.weight(1f), maxLines = 1)
            Row(Modifier.heightIn(min = 48.dp).press(onClick = library).semantics(mergeDescendants = true) { role = Role.Button; contentDescription = "Open Library" },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                SIc("squares-four", 16.dp, m.roles.ink2); T("Open Library", m.scale.label, m.roles.ink2, maxLines = 1)
            }
        }
        if (done.isEmpty()) T("Your takes show up here as they finish. Describe a shot above to start.", m.scale.body, m.roles.ink2)
        else Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            done.forEach { (j, t) -> TakeCard(j, t, if (wide) 110.dp else 96.dp) { open(j.id) } }
        }
    }
}

@Composable
private fun TakeCard(j: Job, take: studio.muse.app.data.Take, w: androidx.compose.ui.unit.Dp, onClick: () -> Unit) {
    val m = muse
    val kind = take.durationSec?.takeIf { it > 0 }?.let { "Video, ${it.roundToInt()} s" } ?: "Photo"
    Column(Modifier.width(w).press(onClick = onClick).semantics(mergeDescendants = true) { contentDescription = "${j.title}, $kind${if (take.status == "final") ", kept" else ""}" },
        verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(Modifier.width(w).height(w * 16 / 9).clip(RoundedCornerShape(m.radii.container))) {
            RefImage(take.thumb ?: j.thumb, Modifier.fillMaxSize(), 20)
            if (take.status == "final") Box(Modifier.align(Alignment.TopStart).padding(6.dp).clip(RoundedCornerShape(m.radii.chip)).background(m.roles.raised)
                .padding(horizontal = 7.dp, vertical = 2.dp)) { T("Kept", m.scale.micro, m.roles.ink) }
        }
        T(j.title, m.scale.label, m.roles.ink, maxLines = 1)
        T(kind, m.scale.caption, m.roles.ink2, maxLines = 1)
    }
}

/** What is rendering or waiting: its picture, title, model, progress and time; Queue opens the whole list. */
@Composable
private fun RunningPanel(running: List<Job>, modifier: Modifier, queue: () -> Unit) {
    val m = muse
    Column(modifier.suitePanel().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            T("Running", m.scale.title, m.roles.ink, Modifier.weight(1f), maxLines = 1)
            Row(Modifier.heightIn(min = 48.dp).press(onClick = queue).semantics(mergeDescendants = true) { role = Role.Button; contentDescription = "Open the queue" },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                SIc("list-bullets", 16.dp, m.roles.ink2); T("Queue", m.scale.label, m.roles.ink2, maxLines = 1)
            }
        }
        Box(Modifier.fillMaxWidth().height(1.dp).background(m.roles.hairline))
        if (running.isEmpty()) T("Nothing running", m.scale.caption, m.roles.ink2)
        running.forEach { j ->
            Row(Modifier.fillMaxWidth().press(onClick = queue), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(Modifier.size(30.dp, 52.dp).clip(RoundedCornerShape(m.radii.chip))) { RefImage(j.thumb, Modifier.fillMaxSize(), 20) }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    T(j.title, m.scale.label, m.roles.ink, maxLines = 1)
                    T(j.serverEngineLabel ?: j.modelName, m.scale.caption, m.roles.ink2, maxLines = 1)
                    val p = if (j.state == "running") (j.progress / 100).toFloat().coerceIn(0f, 1f) else 0f
                    Box(Modifier.fillMaxWidth().height(3.dp).clip(RoundedCornerShape(2.dp)).background(m.roles.field)) {
                        Box(Modifier.fillMaxWidth(p).height(3.dp).background(m.roles.ink))
                    }
                    val line = when {
                        j.state != "running" -> if ((j.queuePosition ?: 2) <= 1) "Starts next" else "Waiting for a slot"
                        (j.etaSeconds ?: j.secondsLeft) > 0 -> "About ${maxOf(1, ((j.etaSeconds ?: j.secondsLeft) / 60).roundToInt())} min left"
                        else -> "Rendering"
                    }
                    T(line, m.scale.caption, m.roles.ink2, maxLines = 1)
                }
            }
        }
    }
}

@Composable
private fun ModeTile(mode: SuiteMode, modifier: Modifier, onClick: () -> Unit) {
    val m = muse
    Column(modifier.suiteCard(m).press(onClick = onClick).semantics(mergeDescendants = true) { contentDescription = mode.title }) {
        Box(Modifier.fillMaxWidth().height(78.dp)) {
            HardwareImage(mode.render, Modifier.fillMaxSize(), sample = 4)
            if (mode.soon) Box(Modifier.align(Alignment.TopEnd).padding(6.dp).background(Color.Black.copy(alpha = .55f)).padding(horizontal = 6.dp, vertical = 2.dp)) {
                T("Soon", m.scale.micro, Color.White)
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
                    PlayBadge(compact = true) }
                StagePhase.RENDERING -> { BlurredStageArt(j.thumb, moving = false); T(pane.percent, m.type.body.copy(fontSize = 22.sp), Color.White, Modifier.align(Alignment.Center)) }
                StagePhase.QUEUED -> { BlurredStageArt(j.thumb, moving = false); Box(Modifier.align(Alignment.BottomStart).background(Color(0xFF141210)).padding(horizontal = 4.dp, vertical = 2.dp)) {
                    T(pane.badge, m.scale.micro, Color.White, maxLines = 1) } }
                else -> { BlurredStageArt(j.thumb, moving = false); T("Failed", m.scale.label, Color.White, Modifier.align(Alignment.Center)) }
            }
        }
        T(j.title, m.scale.caption, m.t.muted, maxLines = 1)
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

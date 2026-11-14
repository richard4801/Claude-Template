package studio.muse.app.ui.screens.suite

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
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
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.RangeSlider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import studio.muse.app.data.ImageRef
import studio.muse.app.data.RemixBackgroundMode
import studio.muse.app.data.RemixCharacterKind
import studio.muse.app.data.RemixDraft
import studio.muse.app.data.RemixOutfitKind
import studio.muse.app.data.trimNum
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.components.RefImage
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.dashed
import studio.muse.app.ui.screens.suite.composer.ComposerPrice
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.radii
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale
import studio.muse.core.Pricing

// New Swap on Android (owner-approved 2026-11-14; redesign frames "New Swap" empty and filled, the Mac's NewSwapScreen.swift
// and NewSwapPanel.swift): the clip and its trimmer on the stage, the changes in the panel (Background, Outfit, Character,
// Look & light, the clip's sound) with the server's price, and the bar with the model and Generate · $x. Generate never
// runs without the estimate's price on it.

private fun take(x: Double) = Take.clock(x)
private object Take { fun clock(s: Double): String { val t = s.toInt().coerceAtLeast(0); return "${t / 60}:${(t % 60).toString().padStart(2, '0')}" } }

/** The Swap tab when New Swap is on. [wide]: stage and panel side by side. */
@Composable
fun NewSwapScreen(wide: Boolean, modifier: Modifier = Modifier) {
    val c = LocalContainer.current
    val ns = c.suite.newSwap
    val d by ns.draft.collectAsState()
    val clip by ns.clip.collectAsState()
    val est by ns.estimate.collectAsState()
    val err by ns.error.collectAsState()
    val video by c.drafts.video.collectAsState()
    // A clip picked on the Source screen becomes New Swap's clip; demo mode starts with the sample clip.
    LaunchedEffect(video.clip?.id) { video.clip?.let { ns.useClip(it) } }
    LaunchedEffect(Unit) { if (ns.clip.value == null && c.repo.demo && ns.demoSample) ns.useSample(); ns.preselectHer() }
    // Re-price when anything that changes the request changes (the server's estimate is the only price shown).
    LaunchedEffect(d, clip?.id) { delay(300); ns.refresh() }
    Column(modifier.fillMaxSize()) {
        if (wide) Row(Modifier.weight(1f).fillMaxWidth().padding(horizontal = 24.dp), horizontalArrangement = Arrangement.spacedBy(20.dp)) {
            Box(Modifier.weight(1f).fillMaxHeight().suiteStage().padding(16.dp)) { NewSwapStage(Modifier.fillMaxSize()) }
            Column(Modifier.width(320.dp).fillMaxHeight().suitePanel().verticalScroll(rememberScrollState()).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp)) { NewSwapPanel() }
        } else Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Box(Modifier.fillMaxWidth().suiteStage().padding(12.dp)) { NewSwapStage(Modifier.fillMaxWidth()) }
            Column(Modifier.fillMaxWidth().suitePanel().padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) { NewSwapPanel() }
        }
        NewSwapBar(wide, est, err)
    }
}

// ---------------------------------------------------------------- the stage

@Composable
private fun NewSwapStage(modifier: Modifier) {
    val m = muse
    val c = LocalContainer.current
    val nav = LocalNav.current
    val ns = c.suite.newSwap
    val clip by ns.clip.collectAsState()
    val d by ns.draft.collectAsState()
    val est by ns.estimate.collectAsState()
    val st by c.repo.state.collectAsState()
    val scope = rememberCoroutineScope()
    var library by remember { mutableStateOf(false) }
    val videos = st.takes.filter { it.videoUrl != null }.take(12)
    val k = clip
    Column(modifier, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (k == null) {
            // Before a clip (frame "New Swap, empty"): a dashed drop zone with what to add and the ways in.
            Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(m.radii.container)).dashed(m.roles.ink2.copy(alpha = .6f), m.radii.container).padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                SIc("film-strip", 24.dp, m.roles.ink)
                T("Add a clip to swap into", m.scale.heading, m.roles.ink, maxLines = 1)
                T("MP4 or MOV. Vertical clips work best.", m.scale.caption, m.roles.ink2)
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box {
                        SourceButton("Choose from Library", "squares-four") { library = true }
                        DropdownMenu(library, { library = false }) {
                            if (videos.isEmpty()) DropdownMenuItem({ T("No finished videos yet", m.scale.label, m.roles.ink2) }, onClick = { library = false })
                            videos.forEach { t -> DropdownMenuItem({ T(t.title, m.scale.label, m.roles.ink, maxLines = 1) }, onClick = { library = false; scope.launch { ns.useTake(t) } }) }
                        }
                    }
                    SourceButton("Upload file", "upload-simple") { nav.go(Routes.SOURCE) }
                    if (c.repo.demo) SourceButton("Sample clip", "film-strip") { ns.useSample() }
                }
            }
            if (videos.isNotEmpty()) {
                T("Recent clips", m.scale.caption, m.roles.ink2)
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    videos.take(5).forEach { t ->
                        Column(Modifier.width(80.dp).press { scope.launch { ns.useTake(t) } }.semantics(mergeDescendants = true) { contentDescription = "Use ${t.title}"; role = Role.Button },
                            verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Box(Modifier.size(80.dp, 142.dp).clip(RoundedCornerShape(m.radii.chip))) { RefImage(t.thumb, Modifier.fillMaxSize(), 20) }
                            T(t.title, m.scale.caption, m.roles.ink, maxLines = 1)
                            t.durationSec?.let { T(take(it), m.scale.micro, m.roles.ink2) }
                        }
                    }
                }
            }
            return@Column
        }
        // The clip: its name and real specs, Replace clip, the picture, and the trimmer.
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                T(k.name, m.scale.heading, m.roles.ink, maxLines = 1)
                T(listOfNotNull(take(k.durationSec), shape(k.width, k.height), "${k.width} × ${k.height}").joinToString(" · "), m.scale.caption, m.roles.ink2, maxLines = 1)
            }
            Box {
                SourceButton("Replace clip", "upload-simple") { library = true }
                DropdownMenu(library, { library = false }) {
                    DropdownMenuItem({ T("Upload a file…", m.scale.label, m.roles.ink) }, onClick = { library = false; nav.go(Routes.SOURCE) })
                    videos.forEach { t -> DropdownMenuItem({ T(t.title, m.scale.label, m.roles.ink, maxLines = 1) }, onClick = { library = false; scope.launch { ns.useTake(t) } }) }
                }
            }
        }
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            val ratio = if (k.width > 0 && k.height > 0) k.width.toFloat() / k.height else 9f / 16f
            Box(Modifier.heightIn(max = 420.dp).aspectRatio(ratio).clip(RoundedCornerShape(m.radii.container)).background(Color.Black)) {
                RefImage(k.thumb, Modifier.fillMaxSize(), 20)
            }
        }
        Trimmer(k.durationSec, d, est?.remix?.trim?.maxSeconds) { a, b -> ns.setRange(a, b) }
    }
}

/** The part of the clip used: a range on the clip's length, its line, and "Use the whole clip". A clip longer than the
 * model takes is never cut silently: the line asks for the part (Generate waits). */
@Composable
private fun Trimmer(seconds: Double, d: RemixDraft, maxS: Double?, set: (Double, Double) -> Unit) {
    val m = muse
    val r = d.range
    val from = r?.from ?: 0.0; val to = r?.to ?: seconds
    val needed = maxS != null && r == null && seconds > maxS + 0.05
    var live by remember(from, to) { mutableStateOf(from.toFloat()..to.toFloat()) }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        RangeSlider(live, { v -> live = v }, valueRange = 0f..seconds.toFloat().coerceAtLeast(0.1f),
            onValueChangeFinished = { set(live.start.toDouble(), live.endInclusive.toDouble()) },
            colors = SliderDefaults.colors(thumbColor = m.roles.ink, activeTrackColor = m.roles.ink2, inactiveTrackColor = m.roles.hairline, activeTickColor = Color.Transparent, inactiveTickColor = Color.Transparent),
            modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Part of the clip used: ${take(from)} to ${take(to)}" })
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            T(if (needed) "Pick the part to use: this model takes up to ${trimNum(maxS!!)} s" else "Uses ${take(from)}–${take(to)} of ${take(seconds)}, ${trimNum(to - from)} s",
                m.scale.caption, if (needed) m.roles.caution else m.roles.ink2, Modifier.weight(1f))
            if (needed) Box(Modifier.heightIn(min = 48.dp).press { set(0.0, maxS!!) }.semantics { role = Role.Button }, contentAlignment = Alignment.Center) {
                T("Use 0:00–${take(maxS!!)}", m.scale.label, m.roles.link, maxLines = 1)
            } else if (r != null) Box(Modifier.heightIn(min = 48.dp).press { set(0.0, seconds) }.semantics { role = Role.Button }, contentAlignment = Alignment.Center) {
                T("Use the whole clip", m.scale.label, m.roles.link, maxLines = 1)
            }
        }
    }
}

@Composable
private fun SourceButton(title: String, icon: String, onClick: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(m.radii.control)
    Row(Modifier.heightIn(min = 44.dp).clip(shape).background(m.roles.raised).border(1.dp, m.roles.hairline, shape).press(onClick = onClick).padding(horizontal = 12.dp)
        .semantics(mergeDescendants = true) { role = Role.Button }, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        SIc(icon, 16.dp, m.roles.ink); T(title, m.scale.label, m.roles.ink, maxLines = 1)
    }
}

/** "9:16", "16:9", "1:1", "4:5" when the size is one of them. */
fun shape(w: Int, h: Int): String? {
    if (w <= 0 || h <= 0) return null
    val r = w.toDouble() / h
    return listOf("9:16" to 9.0 / 16, "16:9" to 16.0 / 9, "1:1" to 1.0, "4:5" to 0.8, "3:4" to 0.75).firstOrNull { kotlin.math.abs(r - it.second) < 0.02 }?.first
}

// ---------------------------------------------------------------- the panel

@Composable
private fun ColumnScope.NewSwapPanel() {
    val m = muse
    val c = LocalContainer.current
    val ns = c.suite.newSwap
    val d by ns.draft.collectAsState()
    val clip by ns.clip.collectAsState()
    val est by ns.estimate.collectAsState()
    val st by c.repo.state.collectAsState()
    val firstSwap = st.jobs.none { it.request.engine == "suite" && (it.prompt.isBlank() || it.title.startsWith("New Swap") || it.title.contains("swap", ignoreCase = true)) }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        T("New Swap", m.scale.title, m.roles.ink, maxLines = 1)
        Box(Modifier.border(1.dp, m.roles.hairline, RoundedCornerShape(m.radii.chip)).padding(horizontal = 6.dp, vertical = 1.dp)) { T("Beta", m.scale.micro, m.roles.ink2) }
        Spacer(Modifier.weight(1f))
        studio.muse.app.ui.components.MoreMenu(listOf(studio.muse.app.ui.components.MenuItem("arrows-left-right", "Use the classic Swap") { ns.on.value = false }),
            tint = m.roles.ink2, icon = "dots-three")
    }
    // Owner decision 3: the three steps show until the studio's first swap.
    if (clip == null && firstSwap) {
        listOf("Add a clip" to "The motion, timing and camera come from it.", "Pick what changes" to "Background, outfit, character, look and light.",
            "Generate" to "You see the price before anything runs.").forEachIndexed { i, (t, l) ->
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(Modifier.size(24.dp).border(1.dp, if (i == 0) m.roles.ink else m.roles.hairline, CircleShape), contentAlignment = Alignment.Center) { T("${i + 1}", m.scale.caption, m.roles.ink) }
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) { T(t, m.scale.label.copy(fontWeight = FontWeight.SemiBold), m.roles.ink); T(l, m.scale.caption, m.roles.ink2) }
            }
        }
        return
    }
    T("Pick what changes. Everything else stays from the clip.", m.scale.caption, m.roles.ink2)
    Section("Changes")
    ToggleRow("Background", "image", d.backgroundOn, { on -> ns.draft.update { it.copy(backgroundOn = on) } }) { BackgroundField(d) }
    ToggleRow("Outfit", "t-shirt", d.outfitOn, { on -> ns.draft.update { it.copy(outfitOn = on) } }) { OutfitField(d) }
    ToggleRow("Character", "user", d.characterOn, { on -> ns.draft.update { it.copy(characterOn = on, modelId = it.modelId ?: st.models.firstOrNull()?.id) } }) { CharacterField(d) }
    ToggleRow("Look & light", "sun", d.lookOn, { on -> ns.draft.update { it.copy(lookOn = on) } }) {
        Words("Night, neon signs, teal grade", d.lookWords) { w -> ns.draft.update { it.copy(lookWords = w) } }
    }
    Section("Sound")
    ToggleRow("Keep clip sound", "speaker-high", d.keepAudio, { on -> ns.draft.update { it.copy(keepAudio = on) } }) {}
    // The price, as the server worked it out for this clip, and when it is charged.
    val e = est
    if (e != null && e.ok) Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(m.radii.control)).background(m.roles.canvas).padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            T(e.priceLine, m.scale.caption, m.roles.ink, Modifier.weight(1f), maxLines = 2)
            T(if (e.test) "Free" else Pricing.money(e.estimate), m.scale.label.copy(fontWeight = FontWeight.SemiBold), m.roles.ink, maxLines = 1)
        }
        T(if (e.test) "A test render: nothing is charged" else "Charged when the take finishes. A failed take is refunded.", m.scale.caption, m.roles.ink2)
    } else T(d.keptLine, m.scale.caption, m.roles.ink2)
}

@Composable
private fun Section(title: String) {
    val m = muse
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        T(title, m.scale.caption, m.roles.ink2)
        Box(Modifier.fillMaxWidth().height(1.dp).background(m.roles.hairline))
    }
}

/** One change: icon, name, "Keep from clip" while off, the switch; when on, its field under it. */
@Composable
private fun ToggleRow(title: String, icon: String, on: Boolean, set: (Boolean) -> Unit, field: @Composable () -> Unit) {
    val m = muse
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).press { set(!on) }.semantics(mergeDescendants = true) { role = Role.Switch; contentDescription = "$title, ${if (on) "on" else "kept from the clip"}" },
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            SIc(icon, 18.dp, if (on) m.roles.ink else m.roles.ink2)
            T(title, m.scale.label.copy(fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal), if (on) m.roles.ink else m.roles.ink2, Modifier.weight(1f), maxLines = 1)
            if (!on) T("Keep from clip", m.scale.caption, m.roles.ink2, maxLines = 1)
            Switch(on, { set(it) }, colors = SwitchDefaults.colors(checkedTrackColor = m.roles.action, checkedThumbColor = m.roles.onAction))
        }
        if (on) field()
    }
}

@Composable
private fun Seg(options: List<String>, selected: Int, pick: (Int) -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(m.radii.control)
    Row(Modifier.fillMaxWidth().clip(shape).background(m.roles.field).padding(3.dp), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        options.forEachIndexed { i, o ->
            Box(Modifier.weight(1f).heightIn(min = 40.dp).clip(RoundedCornerShape(m.radii.chip)).background(if (i == selected) m.roles.raised else Color.Transparent)
                .press { pick(i) }.semantics { role = Role.RadioButton; contentDescription = o }, contentAlignment = Alignment.Center) {
                T(o, m.scale.caption.copy(fontWeight = if (i == selected) FontWeight.SemiBold else FontWeight.Normal), if (i == selected) m.roles.ink else m.roles.ink2, maxLines = 1)
            }
        }
    }
}

/** A text field on the canvas tone with a hairline, 1–3 lines. */
@Composable
private fun Words(placeholder: String, value: String, set: (String) -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(m.radii.control)
    Box(Modifier.fillMaxWidth().heightIn(min = 44.dp).clip(shape).background(m.roles.canvas).border(1.dp, m.roles.hairline, shape).padding(horizontal = 12.dp, vertical = 10.dp)) {
        if (value.isEmpty()) T(placeholder, m.scale.body, m.roles.ink2, maxLines = 2)
        BasicTextField(value, set, Modifier.fillMaxWidth().semantics { contentDescription = placeholder }, textStyle = m.scale.body.copy(color = m.roles.ink),
            cursorBrush = SolidColor(m.roles.accent), maxLines = 3)
    }
}

/** A picked thing on the canvas tone: thumbnail, name and a line, and its action. */
@Composable
private fun Picked(image: ImageRef?, name: String, line: String, action: String, onAction: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(m.radii.control)
    Row(Modifier.fillMaxWidth().clip(shape).background(m.roles.canvas).border(1.dp, m.roles.hairline, shape).padding(8.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(Modifier.size(36.dp).clip(RoundedCornerShape(m.radii.chip)).background(m.roles.field).alpha(if (image == null) .4f else 1f)) { RefImage(image, Modifier.fillMaxSize(), 20) }
        Column(Modifier.weight(1f)) { T(name, m.scale.label, m.roles.ink, maxLines = 1); T(line, m.scale.caption, m.roles.ink2, maxLines = 1) }
        Box(Modifier.heightIn(min = 48.dp).press(onClick = onAction).semantics { role = Role.Button }.padding(horizontal = 4.dp), contentAlignment = Alignment.Center) {
            T(action, m.scale.label, m.roles.link, maxLines = 1)
        }
    }
}

/** Uploads a picked picture and hands back its reference (null with a toast when it can't). */
@Composable
private fun rememberPicturePicker(onPicked: (ImageRef, String) -> Unit): () -> Unit {
    val c = LocalContainer.current
    val scope = rememberCoroutineScope()
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            val media = c.media ?: return@launch c.repo.toast("Couldn't read that picture")
            val bytes = media.bytes(uri) ?: return@launch c.repo.toast("Couldn't read that picture")
            val name = media.displayName(uri)
            val (ref, err) = c.repo.attemptInline { uploadImage(name, bytes, media.mime(uri).takeIf { it.startsWith("image/") } ?: "image/jpeg") }
            if (ref != null) onPicked(ref, name.substringBeforeLast('.'))
            if (err != null) c.repo.toast(err)
        }
    }
    return { pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
}

@Composable
private fun BackgroundField(d: RemixDraft) {
    val c = LocalContainer.current
    val ns = c.suite.newSwap
    val locations by c.suite.locations.collectAsState()
    LaunchedEffect(Unit) { c.suite.loadLocations() }
    val upload = rememberPicturePicker { ref, name -> ns.draft.update { it.copy(backgroundMode = RemixBackgroundMode.PHOTO, backgroundImage = ref, backgroundName = name) } }
    Seg(RemixBackgroundMode.entries.map { it.label }, d.backgroundMode.ordinal) { i -> ns.draft.update { it.copy(backgroundMode = RemixBackgroundMode.entries[i]) } }
    if (d.backgroundMode == RemixBackgroundMode.DESCRIBE) Words("A rooftop at golden hour, city lights behind", d.backgroundWords) { w -> ns.draft.update { it.copy(backgroundWords = w) } }
    else {
        Picked(d.backgroundImage, d.backgroundName ?: "Pick a picture", "A studio location or your photo", if (d.backgroundImage == null) "Upload" else "Change", upload)
        if (locations.isNotEmpty()) Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            locations.forEach { l -> SourceButton(l.name, "map-pin") { ns.draft.update { it.copy(backgroundMode = RemixBackgroundMode.PHOTO, backgroundImage = l.image, backgroundName = l.name) } } }
        }
    }
}

@Composable
private fun OutfitField(d: RemixDraft) {
    val m = muse
    val c = LocalContainer.current
    val ns = c.suite.newSwap
    val st by c.repo.state.collectAsState()
    val upload = rememberPicturePicker { ref, name -> ns.draft.update { it.copy(outfitKind = RemixOutfitKind.PRODUCT, productImage = ref, productName = name) } }
    Seg(RemixOutfitKind.entries.map { it.label }, d.outfitKind.ordinal) { i -> ns.draft.update { it.copy(outfitKind = RemixOutfitKind.entries[i]) } }
    when (d.outfitKind) {
        RemixOutfitKind.OUTFIT -> {
            val owner = d.modelId ?: st.models.firstOrNull()?.id
            val list = st.outfitsOf(owner)
            if (list.isEmpty()) T("No outfits yet for her", m.scale.caption, m.roles.ink2)
            else Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                list.forEach { o ->
                    val on = o.id == d.outfitId
                    val shape = RoundedCornerShape(m.radii.control)
                    Column(Modifier.width(72.dp).press { ns.draft.update { it.copy(outfitId = o.id, characterOn = true, characterKind = RemixCharacterKind.MODEL, modelId = it.modelId ?: o.modelId) } }
                        .semantics(mergeDescendants = true) { contentDescription = "${o.name}${if (on) ", picked" else ""}"; role = Role.RadioButton }, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Box(Modifier.size(72.dp, 90.dp).clip(shape).border(if (on) 2.dp else 0.dp, if (on) m.roles.selection else Color.Transparent, shape)) {
                            RefImage(o.angles.firstOrNull { it != null }, Modifier.fillMaxSize(), 15)
                        }
                        T(o.name, m.scale.caption, if (on) m.roles.ink else m.roles.ink2, maxLines = 1)
                    }
                }
            }
        }
        RemixOutfitKind.PRODUCT -> Picked(d.productImage, d.productName ?: "Product photo", "The clothes to put on", if (d.productImage == null) "Upload" else "Change", upload)
        RemixOutfitKind.WORDS -> Words("A black linen two-piece", d.outfitWords) { w -> ns.draft.update { it.copy(outfitWords = w) } }
    }
}

@Composable
private fun CharacterField(d: RemixDraft) {
    val m = muse
    val c = LocalContainer.current
    val ns = c.suite.newSwap
    val st by c.repo.state.collectAsState()
    var pickHer by remember { mutableStateOf(false) }
    val upload = rememberPicturePicker { ref, name -> ns.draft.update { it.copy(characterKind = RemixCharacterKind.FACE, faceImage = ref, faceName = name) } }
    if (d.characterKind == RemixCharacterKind.MODEL) {
        val her = st.model(d.modelId)
        Box {
            Picked(her?.cover, her?.name ?: "Pick her", "Face and figure from her pictures", if (her == null) "Pick" else "Change") { pickHer = true }
            DropdownMenu(pickHer, { pickHer = false }) {
                st.models.forEach { mm -> DropdownMenuItem({ T(mm.name, m.scale.label, m.roles.ink, maxLines = 1) }, onClick = { pickHer = false; ns.draft.update { it.copy(modelId = mm.id) } }) }
            }
        }
        Box(Modifier.heightIn(min = 48.dp).press { ns.draft.update { it.copy(characterKind = RemixCharacterKind.FACE) } }.semantics { role = Role.Button }, contentAlignment = Alignment.CenterStart) {
            T("Face swap from a photo instead", m.scale.label, m.roles.ink2, maxLines = 1)
        }
    } else {
        Picked(d.faceImage, d.faceName ?: "Add a face photo", "Only the face changes", if (d.faceImage == null) "Upload" else "Change", upload)
        T("Face swap: only the face changes. Their hair, body and figure stay as in the video. Use a photo of someone who agreed to this.", m.scale.caption, m.roles.ink2)
        Box(Modifier.heightIn(min = 48.dp).press { ns.draft.update { it.copy(characterKind = RemixCharacterKind.MODEL) } }.semantics { role = Role.Button }, contentAlignment = Alignment.CenterStart) {
            T("Use her instead", m.scale.label, m.roles.ink2, maxLines = 1)
        }
    }
}

// ---------------------------------------------------------------- the bar

/** The part used, the shape and the resolution as read-outs, the model (Auto first), Test render when free, Generate · $x. */
@Composable
private fun NewSwapBar(wide: Boolean, est: studio.muse.app.data.SuiteEstimate?, err: String?) {
    val m = muse
    val c = LocalContainer.current
    val ns = c.suite.newSwap
    val nav = LocalNav.current
    val d by ns.draft.collectAsState()
    val clip by ns.clip.collectAsState()
    val models by ns.models.collectAsState()
    val generating by ns.generating.collectAsState()
    val scope = rememberCoroutineScope()
    var pick by remember { mutableStateOf(false) }
    val row = models?.models?.firstOrNull { if (d.engineModel == null) it.auto else it.model == d.engineModel }
    val label = when {
        clip == null -> "Generate"
        ns.pricing -> "Generate · Pricing…"
        else -> ComposerPrice.button(est, false)
    }
    val blocker = ns.blocker
    val canGo = clip != null && est != null && blocker == null && !generating
    val secs = clip?.let { k -> d.range?.seconds ?: minOf(k.durationSec, row?.limits?.maxSeconds?.takeIf { it > 0 } ?: k.durationSec) }
    Column(Modifier.fillMaxWidth().background(m.roles.canvas).navigationBarsPadding().padding(horizontal = if (wide) 24.dp else 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (clip != null) (blocker ?: est?.remix?.why ?: models?.auto?.why)?.let { T(it, m.scale.caption, if (blocker != null) m.roles.caution else m.roles.ink2, maxLines = 2) }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(Modifier.weight(1f).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                SuitePill("clock", secs?.let { "${trimNum(it)} s" } ?: "—")
                SuitePill("device-mobile", clip?.let { shape(it.width, it.height) } ?: "9:16")
                if (wide) SuitePill("stack", row?.price?.resolution?.ifBlank { null } ?: "—")
                // The model: Auto first and why; every model that edits a video, with its price for this clip.
                Box {
                    val shape = RoundedCornerShape(m.radii.control)
                    Row(Modifier.heightIn(min = 40.dp).clip(shape).border(1.dp, m.roles.hairline, shape).press { pick = true }.padding(horizontal = 10.dp)
                        .semantics(mergeDescendants = true) { role = Role.Button; contentDescription = "Model: ${row?.label ?: "Auto"}" },
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        T(if (d.engineModel == null) "Auto" else row?.label ?: "Model", m.scale.label.copy(fontWeight = FontWeight.Medium), m.roles.ink, maxLines = 1)
                        SIc("caret-down", 12.dp, m.roles.ink2)
                    }
                    DropdownMenu(pick, { pick = false }) {
                        DropdownMenuItem({ Column { T("Auto${models?.models?.firstOrNull { it.auto }?.let { " (${it.label})" } ?: ""}", m.scale.label, m.roles.ink); T(models?.auto?.why ?: "MUSE picks the model for these changes", m.scale.caption, m.roles.ink2, maxLines = 2) } },
                            onClick = { pick = false; ns.draft.update { it.copy(engineModel = null) } })
                        models?.grouped?.forEach { (g, rows) ->
                            DropdownMenuItem({ T(g.label, m.scale.caption, m.roles.ink2) }, onClick = {}, enabled = false)
                            rows.forEach { r ->
                                DropdownMenuItem({
                                    Column(Modifier.widthIn(max = 320.dp)) {
                                        Row { T(r.label, m.scale.label, if (r.pickable) m.roles.ink else m.roles.ink2, Modifier.weight(1f, fill = false), maxLines = 1)
                                            r.price.usd?.let { T("  ${Pricing.money(it)}", m.scale.caption, m.roles.ink2, maxLines = 1) } }
                                        T(r.line, m.scale.caption, if (r.warning != null && r.pickable) m.roles.caution else m.roles.ink2, maxLines = 3)
                                    }
                                }, onClick = { pick = false; ns.draft.update { it.copy(engineModel = r.model) } }, enabled = r.pickable)
                            }
                        }
                        if (models == null) DropdownMenuItem({ T(if (d.anyOn) "Loading models…" else "Turn on a change to see the models for it", m.scale.caption, m.roles.ink2) }, onClick = { pick = false })
                    }
                }
            }
            SuiteTestRenderSwitch(free = est?.test == true, compact = !wide)
            // The one filled action: always the server's price on it ("Generate · $0.93"; "Test render · Free").
            Box(Modifier.heightIn(min = 48.dp).alpha(if (canGo) 1f else .45f).clip(RoundedCornerShape(m.radii.control)).background(m.roles.action)
                .press(enabled = canGo) { scope.launch { ns.generate()?.let { j -> nav.go(Routes.suiteTake(j.id)) } } }.padding(horizontal = 18.dp)
                .semantics { role = Role.Button; contentDescription = label }, contentAlignment = Alignment.Center) {
                T(label, m.scale.label.copy(fontWeight = FontWeight.SemiBold), m.roles.onAction, maxLines = 1)
            }
        }
    }
}


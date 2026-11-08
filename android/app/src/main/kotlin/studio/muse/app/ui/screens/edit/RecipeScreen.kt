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
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import studio.muse.app.data.FakeRecipes
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.components.Bar
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.TopBar
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.ScreenBox
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.scale
import studio.muse.core.edit.Recipe
import studio.muse.core.edit.RecipeConfidence
import studio.muse.core.edit.RecipeSlot

// "Recreate this edit" (plans/recreate-edit.md, APPROVED), build phase 1 on Android: pick a reference video and see its
// recipe. The analysis is WS1's server service; until it lands the recipe comes from [FakeRecipes] and the entry shows in
// demo mode only, so nobody sees a made-up recipe for their own video. Building your version (cast, fill, assemble) is
// phase 2.

/** Where the reference is in its analysis. */
sealed interface RecipePhase {
    /** Nothing picked yet. */
    data object Pick : RecipePhase
    data class Analysing(val progress: Float, val step: String) : RecipePhase
    data class Ready(val recipe: Recipe) : RecipePhase
    data class Failed(val message: String) : RecipePhase
}

data class RecipeUi(val phase: RecipePhase = RecipePhase.Pick, val referenceName: String? = null)

/** The screen: the picker, the (fake, for now) analysis, then the recipe. */
@Composable
fun RecipeScreen(onBack: () -> Unit) {
    val c = LocalContainer.current
    var ui by remember { mutableStateOf(RecipeUi()) }
    var picked by remember { mutableStateOf<Uri?>(null) }
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri -> if (uri != null) picked = uri }
    BackHandler(onBack = onBack)
    LaunchedEffect(picked) {
        val uri = picked ?: return@LaunchedEffect
        val name = uri.lastPathSegment?.substringAfterLast('/') ?: "Your reference"
        // The steps the analysis reports (plans/recreate-edit.md §2); a stand-in until the service lands.
        for ((i, step) in listOf("Finding the cuts", "Reading the beats", "Reading the text", "Working out each shot").withIndex()) {
            ui = RecipeUi(RecipePhase.Analysing((i + 1) / 5f, step), name)
            delay(600)
        }
        ui = RecipeUi(RecipePhase.Ready(FakeRecipes.cafeTrend()), name)
    }
    RecipeContent(ui, onBack = onBack, onPick = { if (c.repo.demo) pick.launch("video/*") })
}

/** The screen as a function of [ui] (screenshots render it). */
@Composable
fun RecipeContent(ui: RecipeUi, onBack: () -> Unit, onPick: () -> Unit) {
    val m = muse
    ScreenBox(statusPad = true) {
        Column(Modifier.fillMaxSize()) {
            TopBar("Recreate an edit", onBack = onBack)
            BoxWithConstraints(Modifier.fillMaxSize()) {
                val wide = maxWidth >= 720.dp
                Column(
                    Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = if (wide) 32.dp else 16.dp, vertical = 8.dp)
                        .let { if (wide) it.widthIn(max = 960.dp) else it },
                    verticalArrangement = Arrangement.spacedBy(24.dp),
                ) {
                    when (val ph = ui.phase) {
                        RecipePhase.Pick -> PickBody(onPick)
                        is RecipePhase.Analysing -> AnalysingBody(ui.referenceName, ph)
                        is RecipePhase.Failed -> {
                            T(ph.message, m.scale.body, m.t.ink)
                            Secondary("Pick another video", onPick)
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
private fun ColumnScope.PickBody(onPick: () -> Unit) {
    val m = muse
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        T("See how an edit is made", m.scale.title, m.t.ink)
        T("Pick a video you saved: an edit you love, up to 60 s. MUSE breaks it into its recipe: the shots and their cuts, the beats, the text, the transitions, the grade and the pacing.",
            m.scale.body, m.t.ink2())
        T("The video stays private to your studio and is only used to read the recipe.", m.scale.caption, m.t.muted)
    }
    Primary("Pick a video", onPick)
}

@Composable
private fun AnalysingBody(name: String?, ph: RecipePhase.Analysing) {
    val m = muse
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        T(name ?: "Your reference", m.scale.heading, m.t.ink, maxLines = 1)
        T(ph.step + "…", m.scale.body, m.t.ink2())
        Bar(ph.progress)
    }
}

// ------------------------------------------------------------------------------------------------------------- Recipe

@Composable
private fun RecipeBody(r: Recipe, name: String?, wide: Boolean, onPick: () -> Unit) {
    val m = muse
    // The summary: what the reference is, in one line of value pairs, and what needs a look.
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        T(r.title ?: name ?: "Your reference", m.scale.title, m.t.ink, maxLines = 2)
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
            drawRoundRect(if (i % 2 == 0) m.t.surface2 else m.t.line, Offset(l, top), Size((rr - l).coerceAtLeast(1f), h), CornerRadius(3.dp.toPx()))
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
            val camera = listOfNotNull(s.move, s.speed, s.transform)
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
                T("“${t.text}”", m.scale.label, m.t.ink, Modifier.weight(1f), maxLines = 2)
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
            Confidence(if (t.kind == null) 0.0 else t.confidence)
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

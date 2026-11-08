package studio.muse.app.ui.screens.edit

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.animation.core.animateFloat
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.ScreenBox
import studio.muse.app.ui.screens.edit.learn.LearnHairline
import studio.muse.app.ui.screens.edit.learn.LearnQuiet
import studio.muse.app.ui.screens.edit.learn.LearnSegmented
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.radii
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale
import studio.muse.core.edit.RecipeSlot
import studio.muse.core.edit.RecreateSwatches
import studio.muse.core.edit.RecreateText

/*
 * Recreate's Recipe and Compare, built (the owner-approved Mac design, plans/recreate/built_*.png, adapted to phone and
 * tablet). Owner notes: the Look swatches are softened (RecreateSwatches), and the total sits right beside Build (in the
 * top bar on a tablet, in the bottom bar on a phone), with one confirmation listing each shot before anything is spent.
 */

/** What the screen can ask for. */
class RecreateActions(
    val onBack: () -> Unit = {},
    val onMode: (RecreateMode) -> Unit = {},
    val onSelect: (Int) -> Unit = {},
    val onBuild: () -> Unit = {},
    val onConfirm: () -> Unit = {},
    val onCancel: () -> Unit = {},
    val onUseTake: (String, RecreateTakeChoice) -> Unit = { _, _ -> },
    val onRemake: (String) -> Unit = {},
    val onCast: (String) -> Unit = {},
    /** G8: "Write the shot briefs" (asks with its price), then the yes. */
    val onBriefs: () -> Unit = {},
    val onBriefsConfirm: () -> Unit = {},
    val onBriefsCancel: () -> Unit = {},
    /** G2: how a shot to make is made ("swap" | "generate"), and whether a swap keeps the reference's setting. */
    val onMethod: (String, String) -> Unit = { _, _ -> },
    val onKeepBackground: (String, Boolean) -> Unit = { _, _ -> },
    /** The Build confirmation's per-shot tick ("pick which shots to make"). */
    val onConfirmTick: (String) -> Unit = {},
    /** "Use your own setting": a studio location for the shot, or null for the place in its brief. */
    val onLocation: (String, String?) -> Unit = { _, _ -> },
    val onExport: () -> Unit = {},
    /** Owner only (null: no Claude button): Claude on this reference (the "recreate" context, WS1 d7233b8). */
    val onClaude: (() -> Unit)? = null,
    val onExportGuide: (Boolean) -> Unit = {},
    val onExportRun: () -> Unit = {},
    val onExportClose: () -> Unit = {},
    val onFix: () -> Unit = {},
    val onOpenEditor: () -> Unit = {},
    val onPlay: () -> Unit = {},
    val onStep: (Int) -> Unit = {},
)

/**
 * What the players can play: [reference] is the reference video saved from its authenticated route (a local file), and
 * [takeVideo] a take's video link. Without them (demo mode, screenshots) the players show the poster or stand-in tones.
 */
class RecreateMedia(
    val reference: String? = null,
    val takeVideo: (String) -> String? = { null },
    /** The built edit, previewed on the device (Compare); without it, your edit plays each shot's take. */
    val edit: androidx.media3.common.Player? = null,
    /** "Preview of the cut" when the server's preview leaves part of the edit out (plans/api.md "The built edit, rendered"). */
    val editLabel: String? = null,
    /** Each shot's keyframe from the reference (slotId → picture), for the tiles. */
    val slotThumbs: Map<String, ImageBitmap> = emptyMap(),
    /** The built edit isn't playable yet: "Preparing the preview…" or "The preview didn't render" (with [onRetryEdit]). */
    val editStatus: String? = null,
    val onRetryEdit: () -> Unit = {},
)

private val LocalRecreateMedia = androidx.compose.runtime.staticCompositionLocalOf { RecreateMedia() }
private val LocalRemake = androidx.compose.runtime.staticCompositionLocalOf<(String) -> Unit> { {} }
private val LocalActions = androidx.compose.runtime.staticCompositionLocalOf { RecreateActions() }

/** The whole screen as a function of [ui] (screenshots render it). [picture]: the reference's poster, when the server has it. */
@Composable
fun RecreateBuildScreen(ui: RecreateBuildUi, a: RecreateActions, picture: ImageBitmap? = null, picking: String? = null, media: RecreateMedia = RecreateMedia()) {
    var pick by remember(picking) { mutableStateOf(picking) }
    androidx.compose.runtime.CompositionLocalProvider(LocalRecreateMedia provides media, LocalRemake provides a.onRemake, LocalActions provides a) { ScreenBox(statusPad = true) {
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val wide = maxWidth >= 720.dp
            val pickTake: (String) -> Unit = { pick = it }
            if (wide) TabletLayout(ui, a, picture, pickTake) else PhoneLayout(ui, a, picture, pickTake)
            ui.confirmSlots?.let { BuildConfirm(ui, it, a) }
            ui.export?.let { ExportSheet(it, a) }
            if (ui.askBriefs) ui.briefs?.let { b -> BriefsConfirm(b, a) }
            pick?.let { s -> TakePicker(ui.takes, onPick = { t -> a.onUseTake(s, t); pick = null }, onClose = { pick = null }) }
        }
    } }
}

// --------------------------------------------------------------------------------------------------------------- Phone

@Composable
private fun PhoneLayout(ui: RecreateBuildUi, a: RecreateActions, picture: ImageBitmap?, pickTake: (String) -> Unit) {
    val m = muse
    Column(Modifier.fillMaxSize()) {
        Header(ui, a.onBack, a.onClaude)
        LearnSegmented(listOf("Recipe", "Compare"), if (ui.mode == RecreateMode.Recipe) 0 else 1, Modifier.padding(horizontal = 16.dp).fillMaxWidth()) {
            a.onMode(if (it == 0) RecreateMode.Recipe else RecreateMode.Compare)
        }
        Column(
            Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            if (ui.mode == RecreateMode.Recipe) {
                Cast(ui, a.onCast)
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Player("Reference", ui, yours = false, picture, Modifier.fillMaxWidth(), height = 300.dp)
                    Transport(ui, a)
                }
                ShotTiles(ui, scores = false, a.onSelect)
                ui.slots.getOrNull(ui.selected)?.let { ShotPanel(ui, it, ui.selected, pickTake, a.onBuild) }
                LearnHairline()
                WholeEdit(ui)
            } else {
                Metrics(ui, phone = true)
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Player("Reference", ui, yours = false, picture, Modifier.weight(1f), height = 300.dp)
                    Player("Your edit", ui, yours = true, null, Modifier.weight(1f), height = 300.dp)
                }
                Transport(ui, a)
                ShotTiles(ui, scores = true, a.onSelect)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    ui.weakest?.let { w -> LearnQuiet("Fix shot ${w + 1}", icon = "arrows-clockwise", onClick = a.onFix) }
                    LearnQuiet("Export", icon = "download-simple", onClick = a.onExport)
                }
            }
        }
        LearnHairline()
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            if (ui.mode == RecreateMode.Recipe) {
                CostLine(ui, Modifier.weight(1f), end = false)
                BuildButton(ui, a.onBuild)
            } else {
                Primary("Open in the editor", Modifier.fillMaxWidth(), onClick = a.onOpenEditor)
            }
        }
    }
}

@Composable
private fun Header(ui: RecreateBuildUi, onBack: () -> Unit, onClaude: (() -> Unit)? = null) {
    val m = muse
    Row(Modifier.fillMaxWidth().height(56.dp).padding(end = 16.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(48.dp).press(onClick = onBack).semantics { contentDescription = "Back to references"; role = Role.Button }, contentAlignment = Alignment.Center) {
            EIc("caret-left", 22.dp, m.roles.ink)
        }
        Column(Modifier.weight(1f)) {
            T(ui.referenceName ?: ui.recipe.title ?: "Reference", m.scale.heading, m.roles.ink, maxLines = 1)
            T(facts(ui), m.scale.caption.tabular(), m.roles.ink2, maxLines = 1)
        }
        // Claude runs the flow with you here (explains the recipe, matches, fixes a shot); paid steps still ask you.
        if (onClaude != null) studio.muse.app.ui.screens.claude.ClaudeButton(onClaude)
    }
}

/** "Reference · 4.4 s · 3 shots · kept 30 days". */
private fun facts(ui: RecreateBuildUi): String =
    listOfNotNull("Reference", String.format(java.util.Locale.ROOT, "%.1f s", ui.recipe.durationSec), if (ui.slots.size == 1) "1 shot" else "${ui.slots.size} shots", ui.kept).joinToString(" · ")

@Composable
private fun CostLine(ui: RecreateBuildUi, modifier: Modifier, end: Boolean) {
    val m = muse
    val summary = ui.summary ?: return Box(modifier)
    Column(modifier.semantics(mergeDescendants = true) {}, horizontalAlignment = if (end) Alignment.End else Alignment.Start) {
        // A wrapped line breaks after the dot, never before it ("…to generate ·" / "$2.56 in all").
        T(summary.replace(" · ", "\u00A0· "), m.scale.label.tabular(), m.roles.ink, maxLines = 2)
        T(ui.note, m.scale.caption, m.roles.ink2, maxLines = 2)
    }
}

@Composable
private fun BuildButton(ui: RecreateBuildUi, onBuild: () -> Unit) =
    Primary(if (ui.estimating) "Pricing the shots" else "Build the edit", enabled = !ui.buildBusy, icon = "hammer", onClick = onBuild)

/** The screen's one filled action; disabled, it steps back to the field tone so its label stays readable. */
@Composable
private fun Primary(label: String, modifier: Modifier = Modifier, enabled: Boolean = true, icon: String? = null, onClick: () -> Unit) {
    val m = muse
    Row(
        modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(m.radii.control)).background(if (enabled) m.roles.action else m.roles.field)
            .press(enabled = enabled, onClick = onClick).padding(horizontal = 18.dp).semantics(mergeDescendants = true) { role = Role.Button },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
    ) {
        val ink = if (enabled) m.roles.onAction else m.roles.ink2
        if (icon != null) EIc(icon, 18.dp, ink)
        T(label, m.scale.label, ink, maxLines = 1)
    }
}

// -------------------------------------------------------------------------------------------------------------- Tablet

@Composable
private fun TabletLayout(ui: RecreateBuildUi, a: RecreateActions, picture: ImageBitmap?, pickTake: (String) -> Unit) {
    val m = muse
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().height(64.dp).padding(end = 16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(Modifier.weight(1f)) { Header(ui, a.onBack, a.onClaude) }
            LearnSegmented(listOf("Recipe", "Compare"), if (ui.mode == RecreateMode.Recipe) 0 else 1, Modifier.width(240.dp)) {
                a.onMode(if (it == 0) RecreateMode.Recipe else RecreateMode.Compare)
            }
            Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp, Alignment.End)) {
                if (ui.mode == RecreateMode.Recipe) {
                    CostLine(ui, Modifier.weight(1f, fill = false), end = true)
                    BuildButton(ui, a.onBuild)
                } else Primary("Open in the editor", icon = "export", onClick = a.onOpenEditor)
            }
        }
        LearnHairline()
        Row(Modifier.weight(1f).fillMaxWidth()) {
            if (ui.mode == RecreateMode.Recipe) {
                Column(Modifier.weight(1f).fillMaxHeight().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Player("Reference", ui, yours = false, picture, Modifier.weight(1f))
                    Transport(ui, a)
                }
                Box(Modifier.width(1.dp).fillMaxHeight().background(m.roles.hairline))
                Column(Modifier.width(328.dp).fillMaxHeight().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    Cast(ui, a.onCast)
                    LearnHairline()
                    ui.slots.getOrNull(ui.selected)?.let { ShotPanel(ui, it, ui.selected, pickTake, a.onBuild) }
                    LearnHairline()
                    WholeEdit(ui)
                }
            } else {
                Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Row(verticalAlignment = Alignment.Bottom) {
                        Box(Modifier.weight(1f)) { Metrics(ui, phone = false) }
                        ui.weakest?.let { w -> LearnQuiet("Fix shot ${w + 1}", icon = "arrows-clockwise", onClick = a.onFix) }
                        LearnQuiet("Export", icon = "download-simple", onClick = a.onExport)
                    }
                    Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                        Player("Reference", ui, yours = false, picture, Modifier.weight(1f).fillMaxHeight())
                        Player("Your edit", ui, yours = true, null, Modifier.weight(1f).fillMaxHeight())
                    }
                    Transport(ui, a)
                }
            }
        }
        LearnHairline()
        Lanes(ui, scores = ui.mode == RecreateMode.Compare, a.onSelect)
    }
}

/** Under the players: one lane each for the shots, the text, the transitions and the beats. Tap a shot to select it. */
@Composable
private fun Lanes(ui: RecreateBuildUi, scores: Boolean, onSelect: (Int) -> Unit) {
    val m = muse
    val d = ui.recipe.durationSec.coerceAtLeast(0.1)
    @Composable fun lane(h: Dp, icon: String, label: String, content: @Composable (Dp) -> Unit) {
        Row(Modifier.fillMaxWidth().height(h)) {
            Row(Modifier.width(176.dp).fillMaxHeight().padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                EIc(icon, 16.dp, m.roles.ink2)
                T(label, m.scale.label, m.roles.ink, maxLines = 1)
            }
            Box(Modifier.width(1.dp).fillMaxHeight().background(m.roles.hairline))
            BoxWithConstraints(Modifier.weight(1f).fillMaxHeight().padding(horizontal = 8.dp)) {
                content(maxWidth)
                // The shared playhead, across every lane.
                Box(Modifier.offset(x = maxWidth * (ui.time / d).toFloat() - 1.dp).width(2.dp).fillMaxHeight().background(m.roles.accent))
            }
        }
        LearnHairline()
    }
    fun x(sec: Double, w: Dp): Dp = w * (sec / d).toFloat()
    Column(Modifier.fillMaxWidth()) {
        lane(104.dp, "film-strip", "Shots") { w ->
            ui.slots.forEachIndexed { i, s ->
                val width = (x(s.endSec, w) - x(s.startSec, w) - 4.dp).coerceAtLeast(8.dp)
                Tile(ui, s, i, scores, i == ui.selected, Modifier.offset(x = x(s.startSec, w) + 2.dp, y = 6.dp).size(width, 92.dp)) { onSelect(i) }
            }
        }
        lane(40.dp, "text-t", "Text") { w ->
            ui.recipe.texts.forEach { t ->
                val words = if (t.text == studio.muse.core.edit.RecipeJson.UNREAD_WORDS) "Words not read" else "“${t.text.lowercase().replaceFirstChar { it.uppercase() }}”"
                Box(Modifier.offset(x = x(t.startSec, w), y = 8.dp).size((x(t.endSec, w) - x(t.startSec, w)).coerceAtLeast(24.dp), 24.dp)
                    .clip(RoundedCornerShape(m.radii.chip)).background(m.roles.field).padding(horizontal = 8.dp), contentAlignment = Alignment.CenterStart) {
                    T(words, m.scale.micro, m.roles.ink, maxLines = 1)
                }
            }
        }
        lane(36.dp, "arrows-left-right", "Transitions") { w ->
            ui.recipe.transitions.forEach { t ->
                Box(Modifier.offset(x = (x(t.atSec, w) - 28.dp).coerceAtLeast(0.dp), y = 7.dp).clip(RoundedCornerShape(m.radii.chip)).background(m.roles.field).padding(horizontal = 8.dp, vertical = 2.dp)) {
                    T(t.kind ?: "Not recognised", m.scale.micro, m.roles.ink, maxLines = 1)
                }
            }
        }
        val bpm = ui.recipe.beats?.bpm?.let { "Beats · ${Math.round(it)} BPM" } ?: "Beats"
        lane(44.dp, "metronome", bpm) { w ->
            val strong = ui.recipe.beats?.strong.orEmpty().map { Math.round(it * 1000) }.toSet()
            ui.recipe.beats?.beats.orEmpty().forEach { b ->
                val on = Math.round(b * 1000) in strong
                Box(Modifier.offset(x = x(b, w) - 1.dp, y = if (on) 10.dp else 16.dp).size(2.dp, if (on) 24.dp else 18.dp).clip(RoundedCornerShape(1.dp))
                    .background(if (on) m.roles.accent else m.roles.ink2.copy(alpha = .5f)))
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------------- Shared pieces

/** The shots as tiles: number, and whether each comes from your takes or will be generated (its score after Build). */
@Composable
private fun ShotTiles(ui: RecreateBuildUi, scores: Boolean, onSelect: (Int) -> Unit) {
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        ui.slots.forEachIndexed { i, s -> Tile(ui, s, i, scores, i == ui.selected, Modifier.size(112.dp, 152.dp)) { onSelect(i) } }
    }
}

@Composable
private fun Tile(ui: RecreateBuildUi, s: RecipeSlot, i: Int, scores: Boolean, selected: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(minOf(m.radii.container, 10.dp))
    val tag = ui.tag(s.id, scores)
    Box(
        modifier.clip(shape).border(if (selected) 2.dp else 0.dp, if (selected) m.roles.selection else Color.Transparent, shape)
            .press(onClick = onClick).semantics(mergeDescendants = true) { contentDescription = "Shot ${i + 1}, $tag"; this.selected = selected; role = Role.Button },
    ) {
        // The picture: your take's thumbnail when the shot comes from it, else the reference's own frame, else a calm tone.
        val media = LocalRecreateMedia.current
        val takeThumb = ui.slotFill(s.id)?.takeId?.let { id -> ui.takes.firstOrNull { it.id == id }?.thumb }
        val frame = media.slotThumbs[s.id]
        when {
            takeThumb != null -> studio.muse.app.ui.components.RefImage(takeThumb, Modifier.fillMaxSize())
            frame != null -> Image(frame, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            else -> StandIn(ui, i, Modifier.fillMaxSize())
        }
        Row(Modifier.align(Alignment.BottomStart).fillMaxWidth().padding(6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Box(Modifier.clip(RoundedCornerShape(m.radii.chip)).background(Color.Black.copy(alpha = .6f)).padding(horizontal = 6.dp, vertical = 2.dp)) {
                T("${i + 1}", m.scale.micro.tabular(), Color.White, maxLines = 1)
            }
            Spacer(Modifier.weight(1f))
            Box(Modifier.clip(RoundedCornerShape(m.radii.chip)).background(m.roles.raised).padding(horizontal = 6.dp, vertical = 2.dp)) {
                T(tag, m.scale.micro.tabular(), m.roles.ink, maxLines = 1)
            }
        }
    }
}

/** Stand-in footage (no picture of anyone): a calm tone from the reference's softened Look. */
@Composable
private fun StandIn(ui: RecreateBuildUi, tone: Int, modifier: Modifier, icon: Boolean = true) {
    val soft = remember(ui.recipe) { RecreateSwatches.soften(ui.recipe.grade?.swatches.orEmpty()) }
    val base = soft.getOrNull(tone % soft.size.coerceAtLeast(1))?.let(::swatch) ?: muse.roles.ink2
    Box(modifier.background(base), contentAlignment = Alignment.Center) {
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = .45f)))
        if (icon) EIc("film-strip", 20.dp, Color.White.copy(alpha = .55f))
    }
}

private fun swatch(hex: String): Color = runCatching { Color(android.graphics.Color.parseColor(hex)) }.getOrDefault(Color.Gray)

/**
 * One player: its label above the picture on the viewer tone. Both follow the shared playhead: the reference plays its
 * video (from its authenticated route); your edit plays, shot by shot, the take each shot comes from, cut at the
 * reference's cuts, with the recipe's text on top. Without video (demo mode), the poster or a stand-in tone.
 * [height]: the picture area on a phone (in a scrolling page); null fills the space left (a tablet).
 */
@Composable
private fun Player(label: String, ui: RecreateBuildUi, yours: Boolean, picture: ImageBitmap?, modifier: Modifier, height: Dp? = null) {
    val m = muse
    val media = LocalRecreateMedia.current
    val i = ui.slotAtTime
    val slot = ui.slots.getOrNull(i)
    val t = ui.time
    val built = if (yours) media.edit else null
    val video: Pair<String, Double>? = if (!yours) media.reference?.let { it to t }
        else if (built != null) null
        else slot?.let { s -> ui.slotFill(s.id)?.takeId?.let(media.takeVideo)?.let { it to (t - s.startSec).coerceAtLeast(0.0) } }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            T(label, m.scale.label, m.roles.ink, maxLines = 1)
            if (built != null) media.editLabel?.let { T(it, m.scale.caption, m.roles.ink2, maxLines = 1) }
        }
        Box(Modifier.fillMaxWidth().let { if (height != null) it.height(height) else it.weight(1f) }.clip(RoundedCornerShape(m.radii.container)).background(Color.Black).padding(vertical = 12.dp)
            .semantics { contentDescription = label }, contentAlignment = Alignment.Center) {
            Box(Modifier.aspectRatio(9f / 16f, matchHeightConstraintsFirst = true).clip(RoundedCornerShape(4.dp))) {
                val status = if (yours && built == null) media.editStatus else null
                when {
                    // The real built edit: its own cuts, speed, camera moves, text and Look, on the reference's timeline.
                    built != null -> SyncedSurface(built, t, ui.playing, muted = true, Modifier.fillMaxSize())
                    // Built but not playable yet: say so; never pictures or takes standing in for the edit.
                    status != null -> Column(Modifier.fillMaxSize().padding(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp, Alignment.CenterVertically),
                        horizontalAlignment = Alignment.CenterHorizontally) {
                        T(status, m.scale.caption, Color.White, maxLines = 2)
                        if (status == PREVIEW_FAILED) Box(Modifier.heightIn(min = 48.dp).press(onClick = media.onRetryEdit).padding(horizontal = 12.dp)
                            .semantics { role = Role.Button; contentDescription = "Retry the preview" }, contentAlignment = Alignment.Center) { T("Retry", m.scale.label, Color.White, maxLines = 1) }
                    }
                    video != null -> SyncedVideo(video.first, video.second, ui.playing, muted = yours, Modifier.fillMaxSize())
                    picture != null && !yours -> Image(picture, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                    else -> StandIn(ui, i + (if (yours) 1 else 0), Modifier.fillMaxSize(), icon = false)
                }
                // The reference's own video already shows its text; elsewhere the recipe's text stands in for it.
                if ((yours && built == null && status == null) || (!yours && media.reference == null)) ui.recipe.texts.firstOrNull { it.startSec <= t && t < it.endSec && it.text != studio.muse.core.edit.RecipeJson.UNREAD_WORDS }?.let { x ->
                    val bias = when (x.position) { "Top" -> -.7f; "Middle" -> 0f; else -> .6f }
                    T(x.text, m.scale.caption.copy(fontWeight = FontWeight.Bold), Color.White, Modifier.align(androidx.compose.ui.BiasAlignment(0f, bias)).padding(horizontal = 8.dp), maxLines = 2)
                }
            }
        }
    }
}

/**
 * A video held at [sourceSec] (the shared playhead, in this video's time): it plays while [playing], and is put back on
 * the playhead when paused or when it drifts more than a quarter second. Loops when the playhead runs past its end.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@Composable
private fun SyncedVideo(uri: String, sourceSec: Double, playing: Boolean, muted: Boolean, modifier: Modifier) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val player = remember(uri) {
        androidx.media3.exoplayer.ExoPlayer.Builder(context).build().apply {
            setMediaItem(androidx.media3.common.MediaItem.fromUri(uri))
            repeatMode = androidx.media3.common.Player.REPEAT_MODE_ONE
            prepare()
        }
    }
    androidx.compose.runtime.DisposableEffect(player) { onDispose { player.release() } }
    SyncedSurface(player, sourceSec, playing, muted, modifier)
}

/** A player someone else owns, held on the shared playhead like [SyncedVideo]. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@Composable
private fun SyncedSurface(player: androidx.media3.common.Player, sourceSec: Double, playing: Boolean, muted: Boolean, modifier: Modifier) {
    androidx.compose.runtime.LaunchedEffect(player, muted) { player.volume = if (muted) 0f else 1f }
    androidx.compose.runtime.LaunchedEffect(player, playing) { player.playWhenReady = playing }
    androidx.compose.runtime.LaunchedEffect(player, sourceSec, playing) {
        val len = player.duration.takeIf { it > 0 }
        val want = (sourceSec * 1000).toLong().let { ms -> if (len != null) ms % len else ms }
        if (!playing || kotlin.math.abs(player.currentPosition - want) > 250) player.seekTo(want)
    }
    androidx.lifecycle.compose.LifecycleResumeEffect(player) { onPauseOrDispose { player.pause() } }
    androidx.compose.ui.viewinterop.AndroidView(
        factory = { ctx ->
            androidx.media3.ui.PlayerView(ctx).apply {
                this.player = player
                useController = false
                resizeMode = androidx.media3.ui.AspectRatioFrameLayout.RESIZE_MODE_ZOOM
                setShutterBackgroundColor(android.graphics.Color.TRANSPARENT)
            }
        },
        modifier = modifier,
        update = { it.player = player },
    )
}

/** The timecode, a frame back, play / pause and a frame forward, under the players. */
@Composable
private fun Transport(ui: RecreateBuildUi, a: RecreateActions) {
    val m = muse
    Row(Modifier.fillMaxWidth().height(48.dp), verticalAlignment = Alignment.CenterVertically) {
        T("${suiteTime(ui.time)} / ${suiteTime(ui.duration)}", m.scale.label.tabular(), m.roles.ink, Modifier.weight(1f), maxLines = 1)
        Box(Modifier.size(44.dp).press { a.onStep(-1) }.semantics { contentDescription = "Back 1 frame"; role = Role.Button }, contentAlignment = Alignment.Center) {
            EIc("skip-back", 20.dp, m.roles.ink)
        }
        Box(Modifier.size(44.dp).clip(androidx.compose.foundation.shape.CircleShape).background(m.roles.ink).press(onClick = a.onPlay)
            .semantics { contentDescription = if (ui.playing) "Pause" else "Play"; role = Role.Button }, contentAlignment = Alignment.Center) {
            EIc(if (ui.playing) "pause" else "play", 20.dp, m.roles.canvas)
        }
        Box(Modifier.size(44.dp).press { a.onStep(1) }.semantics { contentDescription = "Forward 1 frame"; role = Role.Button }, contentAlignment = Alignment.Center) {
            EIc("skip-forward", 20.dp, m.roles.ink)
        }
        Spacer(Modifier.weight(1f))
    }
}

/** The selected shot: what happens, the camera and speed, how sure the analysis is, and how it will be made. */
@Composable
private fun ShotPanel(ui: RecreateBuildUi, s: RecipeSlot, index: Int, pickTake: (String) -> Unit, onRetry: () -> Unit) {
    val m = muse
    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            T("Shot ${index + 1} of ${ui.slots.size}", m.scale.heading, m.roles.ink)
            T("${suiteTime(s.startSec)}–${suiteTime(s.endSec)} · ${String.format(java.util.Locale.ROOT, "%.1f", s.lengthSec)} s · ${RecreateText.percent(s.confidence)} sure",
                m.scale.caption.tabular(), m.roles.ink2, maxLines = 1)
        }
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            T("What happens", m.scale.label, m.roles.ink)
            val what = listOfNotNull(s.shotSize, s.angle?.lowercase(), s.brief).joinToString(" · ")
            if (what.isNotEmpty()) T(what, m.scale.caption, m.roles.ink) else T("Not described yet", m.scale.caption, m.roles.ink2)
            T("Camera: ${(s.move ?: "Still").lowercase()} · Speed: ${(s.speed ?: "Steady").lowercase()}", m.scale.caption, m.roles.ink2)
        }
        FillBox(ui, s, pickTake, onRetry)
    }
}

@Composable
private fun FillBox(ui: RecreateBuildUi, s: RecipeSlot, pickTake: (String) -> Unit, onRetry: () -> Unit) {
    val m = muse
    val remakeShot = LocalRemake.current
    val acts = LocalActions.current
    val f = ui.slotFill(s.id)
    val state = f?.state ?: "empty"
    val failed = ui.fillErrors[s.id]
    val cant = if (state == "to_generate") ui.estimateErrors[s.id] else null
    val starting = s.id in ui.starting
    val making = state == "generating" || starting
    val heading = when { failed != null -> "Didn’t generate"; starting -> "Generating"; else -> RecreateText.fillState(state) }
    val price = ui.estimates[s.id]?.takeIf { it.ok }?.let { RecreateText.money(it.amount) } ?: f?.let { it.estimateLabel ?: it.estimate?.let(RecreateText::money) }
    val line = when {
        failed != null -> failed
        cant != null -> cant
        making -> "Being made with your model. You can leave this page; it carries on."
        state == "ready" -> "Generated for this shot."
        f?.reason != null -> f.reason!!
        state == "to_generate" && ui.estimates[s.id]?.method == "swap" ->
            "Your model is swapped into the reference's own shot, ${suiteTime(ui.estimates[s.id]?.segmentStart ?: s.startSec)}–${suiteTime(ui.estimates[s.id]?.segmentEnd ?: s.endSec)}. Its camera, speed and look come with it."
        state == "to_generate" -> "A new shot made with your model: ${String.format(java.util.Locale.ROOT, "%.1f", s.lengthSec)} s, ${ui.recipe.aspect ?: "9:16"}."
        state == "matched" -> "From one of your takes."
        else -> "Pick a take for this shot."
    }
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(m.radii.control)).background(m.roles.field).padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            T(heading, m.scale.label, if (failed != null) m.roles.caution else m.roles.ink, Modifier.weight(1f), maxLines = 1)
            when {
                state == "to_generate" && cant == null && failed == null && price != null -> T(price, m.scale.label.tabular(), m.roles.ink, maxLines = 1)
                state == "matched" && f?.score != null -> T("${RecreateText.percent(f.score)} alike", m.scale.label.tabular(), m.roles.ink, maxLines = 1)
                making && ui.progress(s.id) != null -> T("${ui.progress(s.id)}%", m.scale.label.tabular(), m.roles.ink, maxLines = 1)
            }
        }
        T(line, m.scale.caption, if (cant != null) m.roles.caution else m.roles.ink2)
        // G2: swap into the reference's own shot (the default) or generate a new one; a swap can keep the reference's setting.
        if (state == "to_generate" && !making && ui.fill != null) {
            val e = ui.estimates[s.id]
            val method = ui.methods[s.id] ?: e?.method ?: "swap"
            androidx.compose.foundation.layout.FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                studio.muse.app.ui.screens.edit.learn.LearnChip("Swap into the reference shot", on = method == "swap") { if (method != "swap") acts.onMethod(s.id, "swap") }
                studio.muse.app.ui.screens.edit.learn.LearnChip("Generate a new shot", on = method == "generate") { if (method != "generate") acts.onMethod(s.id, "generate") }
            }
            e?.swapUnavailable?.let { T(it, m.scale.caption, m.roles.caution) }
            if (method == "swap" && e?.method == "swap") {
                val keep = ui.keepBackground[s.id] ?: e.keepBackground
                Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).press { acts.onKeepBackground(s.id, !keep) }
                    .semantics(mergeDescendants = true) { role = Role.Switch; stateDescription = if (keep) "On" else "Off" }, verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        T(if (keep) "Keep the reference's setting" else "Use your own setting", m.scale.label, m.roles.ink, maxLines = 1)
                        T(if (keep) "Your model, in their place" else "The place from this shot's brief", m.scale.caption, m.roles.ink2, maxLines = 1)
                    }
                    studio.muse.app.ui.components.Toggle(keep, { acts.onKeepBackground(s.id, !keep) })
                }
                // Use your own setting: pick one of the studio's locations (free), or let the brief's place choose; a
                // background made from the brief is priced into the shot.
                if (!keep) {
                    val picked = ui.locations[s.id]
                    androidx.compose.foundation.layout.FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        studio.muse.app.ui.screens.edit.learn.LearnChip("From the brief", on = picked == null) { if (picked != null) acts.onLocation(s.id, null) }
                        ui.places.forEach { p -> studio.muse.app.ui.screens.edit.learn.LearnChip(p.name, on = picked == p.id) { if (picked != p.id) acts.onLocation(s.id, p.id) } }
                    }
                    e.background?.let { T(it.line, m.scale.caption, m.roles.ink2) }
                }
            }
            if (method == "generate" && e?.promptFrom != null && e.promptFrom != "brief") T("Write a brief for this shot first for a closer match.", m.scale.caption, m.roles.ink2)
        }
        if (making) ShotProgress(ui.progress(s.id))
        if (ui.fill != null && !making) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (failed != null) Quiet("Try again", enabled = !ui.buildBusy, onClick = onRetry)
            Quiet(if (state == "matched") "Pick another take" else "Use one of my takes") { pickTake(s.id) }
            // Fix a shot: make it anew (priced, and confirmed with the next Build).
            if (state == "matched" || state == "ready") Quiet("Make a new one") { remakeShot(s.id) }
        }
    }
}

/**
 * A shot being made: its job's progress when the studio's live jobs report it; otherwise a calm indeterminate state, a
 * short segment drifting slowly across the track (no spinner, no fake percentage).
 */
@Composable
private fun ShotProgress(percent: Int?) {
    val m = muse
    val track = Modifier.fillMaxWidth().height(4.dp).clip(RoundedCornerShape(2.dp)).background(m.roles.raised)
    if (percent != null) {
        Box(track.semantics { contentDescription = "$percent% made" }) { Box(Modifier.fillMaxWidth(percent / 100f).fillMaxHeight().background(m.roles.accent)) }
        return
    }
    val drift = androidx.compose.animation.core.rememberInfiniteTransition(label = "making")
    val x by drift.animateFloat(0f, 1f, androidx.compose.animation.core.infiniteRepeatable(androidx.compose.animation.core.tween(2400, easing = androidx.compose.animation.core.LinearEasing),
        androidx.compose.animation.core.RepeatMode.Reverse), label = "x")
    BoxWithConstraints(track.semantics { contentDescription = "Being made" }) {
        val w = maxWidth * .3f
        Box(Modifier.offset(x = (maxWidth - w) * x).width(w).fillMaxHeight().clip(RoundedCornerShape(2.dp)).background(m.roles.accent.copy(alpha = .6f)))
    }
}

/** Cast (plan step 3): who plays the lead. New shots are made with them, and your takes of them are matched first. */
@Composable
private fun Cast(ui: RecreateBuildUi, onCast: (String) -> Unit) {
    val m = muse
    if (ui.cast.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        T("Who plays the lead", m.scale.label, m.roles.ink)
        androidx.compose.foundation.layout.FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ui.cast.forEach { c ->
                studio.muse.app.ui.screens.edit.learn.LearnChip(c.name, on = c.id == ui.castId) { if (!ui.buildBusy || ui.fill == null) onCast(c.id) }
            }
        }
    }
}

/** A quiet button on the raised tone. */
@Composable
private fun Quiet(label: String, enabled: Boolean = true, onClick: () -> Unit) {
    val m = muse
    Box(
        Modifier.heightIn(min = 40.dp).clip(RoundedCornerShape(m.radii.control)).background(m.roles.raised).press(enabled = enabled, onClick = onClick)
            .padding(horizontal = 12.dp).semantics { role = Role.Button },
        contentAlignment = Alignment.Center,
    ) { T(label, m.scale.label, if (enabled) m.roles.ink else m.roles.ink2, maxLines = 1) }
}

/** The whole edit: summary, pacing and beat, the Look (softened), and what the editor can't do yet. */
@Composable
private fun WholeEdit(ui: RecreateBuildUi) {
    val m = muse
    val r = ui.recipe
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        T("The whole edit", m.scale.heading, m.roles.ink)
        r.summary?.let { T(it, m.scale.caption, m.roles.ink) }
        // G8: shots without a brief: Claude can write them (a quiet button with its price), or says why it can't here.
        ui.briefs?.let { b ->
            if (ui.writingBriefs) T("Writing the shot briefs", m.scale.caption, m.roles.ink2)
            else if (b.available) Quiet(b.label, onClick = LocalActions.current.onBriefs)
            else b.reason?.let { T(it, m.scale.caption, m.roles.ink2) }
        }
        T(listOfNotNull(if (r.slots.size == 1) "1 shot" else "${r.slots.size} shots", "${Math.round(r.cutsPerMinute)} cuts a minute", r.beats?.bpm?.let { "${Math.round(it)} BPM" }).joinToString(" · "),
            m.scale.caption.tabular(), m.roles.ink2, maxLines = 1)
    }
    r.grade?.let { g ->
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            T("Look · ${g.name}", m.scale.label, m.roles.ink, maxLines = 1)
            SwatchStrip(g.swatches)
        }
    }
    if (r.gaps.isNotEmpty()) Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        r.gaps.forEach { g ->
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                T(g.note ?: "Not supported yet", m.scale.label, m.roles.caution)
                T(g.atSec?.let { "${g.what} at ${suiteTime(it)}" } ?: g.what, m.scale.caption, m.roles.ink2)
            }
        }
    }
}

/** G8: the one confirmation before Claude (on the server) writes the shot briefs. */
@Composable
private fun BriefsConfirm(b: studio.muse.core.edit.RecreateBriefsEstimate, a: RecreateActions) {
    val m = muse
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = .32f)).press(onClick = a.onBriefsCancel), contentAlignment = Alignment.Center) {
        Column(Modifier.padding(24.dp).widthIn(max = 420.dp).fillMaxWidth().clip(RoundedCornerShape(m.radii.container)).background(m.roles.canvas).press { }.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)) {
            T("Write the shot briefs for about ${RecreateText.money(b.estimateUsd)}?", m.scale.title, m.roles.ink)
            T("Claude reads each shot and writes what happens in it, so new shots match the reference more closely. It's charged to the studio. Asking Claude on your Mac is free.",
                m.scale.body, m.roles.ink2)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End), verticalAlignment = Alignment.CenterVertically) {
                LearnQuiet("Cancel", onClick = a.onBriefsCancel)
                Primary("Write · about ${RecreateText.money(b.estimateUsd)}", onClick = a.onBriefsConfirm)
            }
        }
    }
}

/** The Look as calm swatches (owner note 1): the grade's real hues, softened and ordered dark to light. */
@Composable
fun SwatchStrip(swatches: List<String>, height: Dp = 28.dp) {
    val soft = remember(swatches) { RecreateSwatches.soften(swatches) }
    Row(Modifier.fillMaxWidth().height(height).clip(RoundedCornerShape(muse.radii.control)).semantics { contentDescription = "Look colours" }) {
        soft.forEach { Box(Modifier.weight(1f).fillMaxHeight().background(swatch(it))) }
    }
}

/** After Build: the match per element (Overall large). */
@Composable
private fun Metrics(ui: RecreateBuildUi, phone: Boolean) {
    val m = muse
    val mt = ui.match
    val items = listOf("Cuts" to mt?.cuts, "Text" to mt?.text, "Speed" to mt?.ramps, "Look" to mt?.grade, "Shots" to mt?.shots)
    @Composable fun metric(name: String, v: Double?, big: Boolean = false, mod: Modifier = Modifier) =
        Column(mod.widthIn(min = 64.dp).semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(name, m.scale.caption, m.roles.ink2, maxLines = 1)
            T(RecreateText.percent(v), (if (big) m.scale.title else m.scale.heading).tabular(), m.roles.ink, maxLines = 1)
        }
    if (phone) Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        metric("Overall", mt?.overall, big = true)
        Row(Modifier.fillMaxWidth()) { items.forEach { (n, v) -> metric(n, v, mod = Modifier.weight(1f)) } }
    } else Row(horizontalArrangement = Arrangement.spacedBy(24.dp), verticalAlignment = Alignment.Bottom) {
        metric("Overall", mt?.overall, big = true)
        items.forEach { (n, v) -> metric(n, v) }
    }
}

// ----------------------------------------------------------------------------------------------------- Confirmation

/** Build's one confirmation: the real total, a line per new shot, and any shot that can't be made said plainly. */
@Composable
private fun BuildConfirm(ui: RecreateBuildUi, paid: List<String>, a: RecreateActions) {
    val m = muse
    val cant = ui.toGenerate.filter { ui.estimateErrors[it] != null }
    val total = ui.confirmTotal
    val yours = ui.fill?.slots.orEmpty().count { it.state == "matched" || it.state == "ready" }
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = .32f)).press(onClick = a.onCancel), contentAlignment = Alignment.Center) {
        Column(
            Modifier.padding(24.dp).widthIn(max = 460.dp).fillMaxWidth().clip(RoundedCornerShape(m.radii.container)).background(m.roles.canvas).press { }.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            val chosen = ui.confirmChosen
            T(if (paid.isEmpty()) "Build the edit?" else "Build the edit for ${RecreateText.money(total)}?", m.scale.title, m.roles.ink, maxLines = 2)
            T(RecreateText.confirmMessage(chosen.size, yours, cant.size), m.scale.body, m.roles.ink2)
            // Pick which shots to make: all ticked; an unticked shot stays to generate. One stays ticked.
            if (paid.size > 1) T("Untick a shot to make it later.", m.scale.caption, m.roles.ink2)
            if (paid.isNotEmpty() || cant.isNotEmpty()) Column {
                paid.forEach { s ->
                    val on = s in chosen
                    ConfirmRow(ui, s, problem = null, ticked = if (paid.size > 1) on else null, onTick = { a.onConfirmTick(s) }, last = on && chosen.size == 1)
                }
                cant.forEach { s -> ConfirmRow(ui, s, problem = ui.estimateErrors[s]) }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End), verticalAlignment = Alignment.CenterVertically) {
                LearnQuiet("Cancel", onClick = a.onCancel)
                Primary(if (paid.isEmpty()) "Build the edit" else "Build · ${RecreateText.money(total)}", onClick = a.onConfirm)
            }
        }
    }
}

@Composable
private fun ConfirmRow(ui: RecreateBuildUi, slotId: String, problem: String?, ticked: Boolean? = null, onTick: () -> Unit = {}, last: Boolean = false) {
    val m = muse
    val slot = ui.slots.firstOrNull { it.id == slotId }
    val e = ui.estimates[slotId]
    val tick = if (ticked == null) Modifier else Modifier.toggleable(ticked, enabled = !last, role = Role.Checkbox) { onTick() }
    Column(Modifier.fillMaxWidth().then(tick).semantics(mergeDescendants = true) { if (last) stateDescription = "Ticked, at least one shot is made" }) {
        LearnHairline()
        Column(Modifier.padding(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                if (ticked != null) Box(Modifier.size(22.dp).clip(RoundedCornerShape(6.dp)).background(if (ticked) m.roles.action else Color.Transparent)
                    .border(1.5.dp, if (ticked) m.roles.action else m.roles.hairline, RoundedCornerShape(6.dp)), contentAlignment = Alignment.Center) {
                    if (ticked) studio.muse.app.ui.theme.Ic("check", 16.dp, m.roles.onAction)
                }
                T(ui.shotName(slotId), m.scale.label, m.roles.ink, maxLines = 1)
                T(slot?.let { listOfNotNull(it.shotSize, it.angle?.lowercase()).joinToString(" · ").ifEmpty { String.format(java.util.Locale.ROOT, "%.1f s", it.lengthSec) } } ?: "",
                    m.scale.caption, m.roles.ink2, Modifier.weight(1f), maxLines = 1)
                T(e?.takeIf { problem == null }?.let { RecreateText.money(it.amount) } ?: "–", m.scale.label.tabular(), m.roles.ink, maxLines = 1)
            }
            if (problem != null) T(problem, m.scale.caption, m.roles.caution)
            else e?.let {
                if (it.method == "swap") "Swapped into the reference, ${suiteTime(it.segmentStart ?: slot?.startSec ?: 0.0)}–${suiteTime(it.segmentEnd ?: slot?.endSec ?: 0.0)}"
                else RecreateText.madeLength(it.seconds, slot?.lengthSec ?: it.seconds)
            }?.let { T(it, m.scale.caption.tabular(), m.roles.ink2, maxLines = 1) }
            // Use your own setting: the background's part of the price (a plate made from the brief), or the location used.
            if (problem == null) e?.background?.let { T(it.line, m.scale.caption.tabular(), m.roles.ink2, maxLines = 2) }
        }
    }
}

/**
 * Export (plan step 7): the built edit with the reference's sound as a guide track, or silent and timed for the sound,
 * saved to the phone; with the "Use this sound" reminder either way.
 */
@Composable
private fun ExportSheet(e: RecreateExportUi, a: RecreateActions) {
    val m = muse
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = .32f)).press(onClick = a.onExportClose), contentAlignment = Alignment.Center) {
        Column(
            Modifier.padding(24.dp).widthIn(max = 460.dp).fillMaxWidth().clip(RoundedCornerShape(m.radii.container)).background(m.roles.canvas).press { }.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            val saved = e.saved
            if (saved != null) {
                T("Saved", m.scale.title, m.roles.ink)
                T(saved, m.scale.body, m.roles.ink2)
                val use = e.useThisSound
                if (use != null) {
                    T(use.title, m.scale.heading, m.roles.ink)
                    use.steps.forEachIndexed { i, step -> T("${i + 1}. $step", m.scale.body, m.roles.ink) }
                    use.note?.let { T(it, m.scale.caption, m.roles.ink2) }
                } else T(studio.muse.core.edit.RecreateExport.REMINDER, m.scale.caption, m.roles.ink2)
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) { Primary("Done", onClick = a.onExportClose) }
                return@Column
            }
            T("Export the edit", m.scale.title, m.roles.ink)
            LearnSegmented(listOf("With its sound", "Silent"), if (e.guide) 0 else 1, Modifier.fillMaxWidth()) { if (!e.busy) a.onExportGuide(it == 0) }
            T(if (e.guide) "The original's sound plays as a guide, so you can check the cuts land on the beat." else "No sound: the cuts are timed for the original's sound.",
                m.scale.body, m.roles.ink2)
            T(studio.muse.core.edit.RecreateExport.REMINDER, m.scale.caption, m.roles.ink2)
            e.error?.let { T(it, m.scale.caption, m.roles.caution) }
            if (e.rendering) T("Making the video. This takes about a minute.", m.scale.caption, m.roles.ink2)
            e.progress?.let { p ->
                Box(Modifier.fillMaxWidth().height(4.dp).clip(RoundedCornerShape(2.dp)).background(m.roles.raised).semantics { contentDescription = "${(p * 100).toInt()}% exported" }) {
                    Box(Modifier.fillMaxWidth(p.coerceIn(0f, 1f)).fillMaxHeight().background(m.roles.accent))
                }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End), verticalAlignment = Alignment.CenterVertically) {
                LearnQuiet("Cancel", onClick = a.onExportClose)
                Primary(if (e.busy) "Exporting" else "Save to this phone", enabled = !e.busy, onClick = a.onExportRun)
            }
        }
    }
}

/** "Use one of my takes": the studio's video takes, newest first. */
@Composable
private fun TakePicker(takes: List<RecreateTakeChoice>, onPick: (RecreateTakeChoice) -> Unit, onClose: () -> Unit) {
    val m = muse
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = .32f)).press(onClick = onClose), contentAlignment = Alignment.Center) {
        Column(
            Modifier.padding(24.dp).widthIn(max = 380.dp).fillMaxWidth().clip(RoundedCornerShape(m.radii.container)).background(m.roles.raised).press { }.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            T("Use one of my takes", m.scale.heading, m.roles.ink)
            if (takes.isEmpty()) T("No video takes yet. Make one in the Video suite.", m.scale.caption, m.roles.ink2)
            Column(Modifier.heightIn(max = 320.dp).verticalScroll(rememberScrollState())) {
                takes.forEach { t ->
                    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).press { onPick(t) }.padding(horizontal = 8.dp).semantics(mergeDescendants = true) { role = Role.Button },
                        verticalAlignment = Alignment.CenterVertically) {
                        T(t.caption, m.scale.label, m.roles.ink, Modifier.weight(1f), maxLines = 1)
                        (t.durationSec?.let { String.format(java.util.Locale.ROOT, "%.1f s", it) } ?: t.label)?.let { T(it, m.scale.caption.tabular(), m.roles.ink2, maxLines = 1) }
                    }
                }
            }
            LearnQuiet("Cancel", onClick = onClose)
        }
    }
}


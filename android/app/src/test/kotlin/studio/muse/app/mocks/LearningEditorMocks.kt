package studio.muse.app.mocks

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import studio.muse.app.data.ImageRef
import studio.muse.app.ui.components.RefImage
import studio.muse.app.ui.components.T
import studio.muse.app.ui.screens.edit.EIc
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.radii
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale

/*
 * MOCKS for the owner's approval (plans/learning-editor-ui.md, WS3's spec): the Android Playbook and Recipes screens and
 * Edit home's two entries, in all four themes, phone and tablet. Nothing here ships: these live in the test source set
 * and render with Roborazzi (LearningEditorMockTest). Built on the design-direction roles, type scale and Phosphor.
 * Sample content is the demo studio's; the numbers are illustrative.
 */

// ------------------------------------------------------------------------------------------------------------ Sample data

data class MRule(val text: String, val area: String, val who: String, val pinned: Boolean = false)

val sampleRules = listOf(
    MRule("Keep captions above the chin, never over the face.", "Captions", "Yours", pinned = true),
    MRule("Two or three words per caption page, word pop style.", "Captions", "From Claude · 3 corrections"),
    MRule("First cut by 0.8 s.", "Pacing", "Learned · 2 posts", pinned = true),
    MRule("Hold the last shot at least 1.5 s so the call to action can be read.", "Pacing", "Yours"),
    MRule("No glitch transitions.", "Transitions", "Yours", pinned = true),
    MRule("Whip pans only on a strong beat.", "Transitions", "From Claude · 2 corrections"),
    MRule("Golden warmth at 70% or less when skin fills the frame.", "Look", "From Claude · 4 corrections"),
)

data class MSuggestion(val text: String, val examples: String, val area: String)

val sampleSuggestions = listOf(
    MSuggestion("You changed the look after Claude's Look 4 times (1 undo)", "Morning café · 2 days ago · Kitchen walk · 5 days ago", "Look"),
    MSuggestion("You moved Claude's captions up 3 times", "Living room dance · yesterday", "Captions"),
    MSuggestion("You shortened Claude's first shot 2 times", "Rooftop turn · 3 days ago", "Pacing"),
)

data class MCorrection(val text: String, val area: String, val ago: String)

val sampleHistory = listOf(
    MCorrection("Changed the look from Film to Golden warmth", "Look", "2 h ago"),
    MCorrection("Moved the captions from lower third to top", "Captions", "Yesterday"),
    MCorrection("Undid Claude's glitch transition at 0:04", "Transitions", "Yesterday"),
    MCorrection("Trimmed the first shot from 1.4 s to 0.8 s", "Pacing", "3 days ago"),
    MCorrection("Turned the music down 3 dB under the voice-over", "Sound", "5 days ago"),
)

data class MRecipe(val name: String, val caption: String, val badge: String, val poster: String?, val reference: Boolean, val tags: List<String>)

val sampleRecipes = listOf(
    MRecipe("Morning café", "1.2k views · 42% completion", "15 s · 7 cuts", "g_front", false, listOf("cafe", "slow", "warm")),
    MRecipe("Tuff edit", "Three beats: a pan, a push-in, a still with a caption", "4 s · 2 cuts", "c_tq", true, listOf("dance", "fast")),
    MRecipe("Living room dance", "860 views · 38% completion", "12 s · 9 cuts", "g_side", false, listOf("dance", "fast")),
    MRecipe("Day in my life", "Seven shots cut on the beat, a warm film look", "15 s · 6 cuts", null, true, listOf("vlog", "warm")),
    MRecipe("Kitchen walk", "Not posted yet", "8 s · 4 cuts", "g_tq", false, listOf("slow")),
    MRecipe("Rooftop turn", "A slow push with a speed ramp at the turn", "6 s · 3 cuts", "c_front", true, listOf("transition")),
)

val sampleTags = listOf("dance", "warm", "fast", "slow", "cafe", "vlog", "transition", "hook")

// ---------------------------------------------------------------------------------------------------------- Building blocks

@Composable
private fun TopBar(title: String, back: Boolean = true, trailing: @Composable () -> Unit = {}) {
    val m = muse
    Row(Modifier.fillMaxWidth().height(56.dp).padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        if (back) Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) { EIc("caret-left", 22.dp, m.roles.ink) }
        if (title.isNotEmpty()) T(title, m.scale.heading, m.roles.ink, Modifier.weight(1f).padding(start = 4.dp), maxLines = 1) else Spacer(Modifier.weight(1f))
        trailing()
    }
}

/** One filled action per screen. */
@Composable
fun PrimaryButton(label: String, modifier: Modifier = Modifier, enabled: Boolean = true) {
    val m = muse
    Box(
        modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(m.radii.control)).background(if (enabled) m.roles.action else m.roles.field).padding(horizontal = 20.dp),
        contentAlignment = Alignment.Center,
    ) { T(label, m.scale.label, if (enabled) m.roles.onAction else m.roles.ink2, maxLines = 1) }
}

@Composable
fun QuietButton(label: String, icon: String? = null, color: Color = muse.roles.ink, modifier: Modifier = Modifier) {
    val m = muse
    Row(modifier.heightIn(min = 48.dp).padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (icon != null) EIc(icon, 20.dp, color)
        T(label, m.scale.label, color, maxLines = 1)
    }
}

/** A segmented control (never a menu, so the CI click-through reaches every segment). */
@Composable
fun Segmented(labels: List<String>, picked: Int, modifier: Modifier = Modifier) {
    val m = muse
    val outer = RoundedCornerShape(m.radii.control)
    val inner = RoundedCornerShape((m.radii.control - 2.dp).coerceAtLeast(0.dp))
    Row(modifier.height(40.dp).clip(outer).background(m.roles.field).padding(3.dp), verticalAlignment = Alignment.CenterVertically) {
        labels.forEachIndexed { i, l ->
            val on = i == picked
            Box(
                Modifier.weight(1f).fillMaxHeight().clip(inner).background(if (on) m.roles.raised else m.roles.field)
                    .let { if (on && m.isD) it.border(1.5.dp, m.roles.ink, inner) else it },
                contentAlignment = Alignment.Center,
            ) { T(l, m.scale.label.copy(fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal), if (on) m.roles.ink else m.roles.ink2, maxLines = 1) }
        }
    }
}

/** A tag chip: toggled by the accent outline and text, never a fill. */
@Composable
fun TagChip(tag: String, on: Boolean = false, removable: Boolean = false) {
    val m = muse
    val shape = RoundedCornerShape(m.radii.chip)
    Box(Modifier.heightIn(min = 48.dp), contentAlignment = Alignment.Center) {
        Row(
            Modifier.height(32.dp).clip(shape).border(1.dp, if (on) m.roles.selection else m.roles.hairline, shape).padding(start = 12.dp, end = if (removable) 6.dp else 12.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            T(tag, m.scale.label, if (on) m.roles.selection else m.roles.ink, maxLines = 1)
            if (removable) EIc("x", 16.dp, m.roles.ink2)
        }
    }
}

@Composable private fun Hairline() = Box(Modifier.fillMaxWidth().height(1.dp).background(muse.roles.hairline))

// ---------------------------------------------------------------------------------------------------------------- Edit home

/** Edit home with the two quiet entries beside "Recreate an edit" (owner only). */
@Composable
fun MockEditHome() {
    val m = muse
    Column(Modifier.fillMaxSize().background(m.roles.canvas)) {
        TopBar("Edit")
        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            T("Open a video to cut, caption, grade and export it. Edits are saved as new versions; the original stays.", m.scale.body, m.roles.ink2)
            Row(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(m.radii.container)).background(m.roles.raised).padding(14.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                EIc("film-strip", 22.dp, m.roles.ink)
                Column(Modifier.weight(1f)) {
                    T("Recreate an edit", m.scale.label, m.roles.ink)
                    T("Pick an edit you love and see its recipe: shots, beats, text and grade", m.scale.caption, m.roles.ink2, maxLines = 2)
                }
                EIc("caret-right", 16.dp, m.roles.ink2)
            }
            // The two new entries: quiet text buttons with their icon, not filled.
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                QuietButton("Playbook", "book-open-text")
                QuietButton("Recipes", "stack")
            }
            T("Recent videos", m.scale.heading, m.roles.ink, Modifier.padding(top = 8.dp))
            listOf("Morning café" to "g_front", "Living room dance" to "g_side").forEach { (t, a) ->
                Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    RefImage(ImageRef.asset(a), Modifier.size(44.dp, 62.dp).clip(RoundedCornerShape(m.radii.chip)))
                    Column(Modifier.weight(1f)) {
                        T(t, m.scale.label, m.roles.ink, maxLines = 1)
                        T("HD · 0:15.0", m.scale.caption, m.roles.ink2, maxLines = 1)
                    }
                    EIc("caret-right", 16.dp, m.roles.ink2)
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------- Playbook

enum class PlaybookTab { Rules, Suggestions, History }

private val AREA_ORDER = listOf("Captions", "Text", "Pacing", "Transitions", "Look", "Motion", "Speed", "Timing", "Sound", "Shape", "Other")

/** The Playbook. [wide]: the tablet layout (a centred column, "Add rule" top right). [empty]: no rules yet. */
@Composable
fun MockPlaybook(tab: PlaybookTab, wide: Boolean, empty: Boolean = false, overlay: (@Composable BoxScope.() -> Unit)? = null) {
    val m = muse
    Box(Modifier.fillMaxSize().background(m.roles.canvas)) {
        Column(Modifier.fillMaxSize()) {
            TopBar("", trailing = { if (wide && !empty) PrimaryButton("Add rule", Modifier.padding(end = 16.dp)) })
            Column(
                Modifier.weight(1f).align(Alignment.CenterHorizontally).let { if (wide) it.widthIn(max = 760.dp) else it }.fillMaxWidth()
                    .verticalScroll(rememberScrollState()).padding(horizontal = if (wide) 32.dp else 16.dp),
            ) {
                T("Playbook", m.scale.display, m.roles.ink)
                T("Claude reads these before every edit.", m.scale.caption, m.roles.ink2, Modifier.padding(top = 4.dp))
                Segmented(PlaybookTab.entries.map { it.name }, tab.ordinal, Modifier.padding(top = 20.dp).let { if (wide) it.widthIn(max = 420.dp) else it }.fillMaxWidth())
                Spacer(Modifier.height(16.dp))
                when {
                    empty -> EmptyState("No rules yet. Claude suggests some from the changes you make to its edits, and you can add your own.", "Add rule")
                    tab == PlaybookTab.Rules -> RulesList()
                    tab == PlaybookTab.Suggestions -> SuggestionsList()
                    else -> HistoryList()
                }
                Spacer(Modifier.height(96.dp))
            }
            // Phone: the one primary action in the bottom bar.
            if (!wide && !empty && tab == PlaybookTab.Rules) {
                Hairline()
                Box(Modifier.fillMaxWidth().background(m.roles.canvas).padding(horizontal = 16.dp, vertical = 12.dp)) { PrimaryButton("Add rule", Modifier.fillMaxWidth()) }
            }
        }
        overlay?.invoke(this)
    }
}

@Composable
private fun EmptyState(text: String, action: String) {
    val m = muse
    Column(Modifier.fillMaxWidth().padding(top = 32.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        T(text, m.scale.body, m.roles.ink2)
        PrimaryButton(action)
    }
}

@Composable
private fun RulesList() {
    val m = muse
    val groups = sampleRules.groupBy { it.area }
    Column(verticalArrangement = Arrangement.spacedBy(24.dp)) { // groups by space (s5), not boxes
        AREA_ORDER.filter { it in groups }.forEach { area ->
            Column {
                T(area, m.scale.heading, m.roles.ink, Modifier.padding(bottom = 4.dp))
                groups.getValue(area).sortedByDescending { it.pinned }.forEach { RuleRow(it) }
            }
        }
    }
}

@Composable
private fun RuleRow(r: MRule) {
    val m = muse
    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(r.text, m.scale.body, m.roles.ink, maxLines = 3)
            T(r.who, m.scale.caption, m.roles.ink2, maxLines = 1)
        }
        // Pin: icon-only toggle, labelled "Pin rule" / "Unpin rule".
        Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) { EIc("push-pin", 20.dp, if (r.pinned) m.roles.accent else m.roles.ink2) }
    }
}

@Composable
private fun SuggestionsList() {
    val m = muse
    Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
        sampleSuggestions.forEach { s ->
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                T(s.text, m.scale.body, m.roles.ink)
                T(s.examples, m.scale.caption, m.roles.ink2, maxLines = 2)
                T("Make a rule", m.scale.label, m.roles.link, Modifier.heightIn(min = 48.dp).padding(top = 14.dp))
            }
        }
    }
}

@Composable
private fun HistoryList() {
    val m = muse
    Column {
        sampleHistory.forEach { c ->
            Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    T(c.text, m.scale.body, m.roles.ink, maxLines = 2)
                    T(c.area, m.scale.caption, m.roles.ink2, maxLines = 1)
                }
                T(c.ago, m.scale.caption, m.roles.ink2, maxLines = 1)
            }
        }
    }
}

/** The rule editor: a sheet on the phone (it floats; the only shadow on these screens). */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun BoxScope.MockRuleEditor() {
    val m = muse
    Box(Modifier.matchParentSize().background(Color.Black.copy(alpha = .32f)))
    val shape = RoundedCornerShape(topStart = m.radii.container, topEnd = m.radii.container)
    Column(
        Modifier.align(Alignment.BottomCenter).fillMaxWidth().shadow(16.dp, shape).clip(shape).background(m.roles.raised).padding(horizontal = 16.dp).padding(top = 8.dp, bottom = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { Box(Modifier.size(40.dp, 4.dp).clip(RoundedCornerShape(2.dp)).background(m.roles.hairline)) }
        T("Edit rule", m.scale.title, m.roles.ink)
        // The rule's text.
        Box(Modifier.fillMaxWidth().heightIn(min = 96.dp).clip(RoundedCornerShape(m.radii.control)).background(m.roles.field).padding(12.dp)) {
            T("Golden warmth at 70% or less when skin fills the frame.", m.scale.body, m.roles.ink)
        }
        T("Area", m.scale.label, m.roles.ink)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            AREA_ORDER.forEach { TagChip(it, on = it == "Look") }
        }
        T("Evidence", m.scale.label, m.roles.ink)
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            T("Correction · Changed the look after Claude's “Look Film” · 2 days ago", m.scale.caption, m.roles.ink2)
            T("Correction · Lowered Golden warmth to 70% · 5 days ago", m.scale.caption, m.roles.ink2)
        }
        T("Add a note", m.scale.label, m.roles.link, Modifier.heightIn(min = 40.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            PrimaryButton("Save rule", Modifier.weight(1f))
            QuietButton("Cancel")
        }
        T("Delete rule", m.scale.label, m.roles.danger, Modifier.heightIn(min = 48.dp).padding(top = 12.dp))
    }
}

/** The delete confirmation: names the action; "Keep" is reachable. */
@Composable
fun BoxScope.MockConfirm(title: String, body: String?, confirm: String) {
    val m = muse
    Box(Modifier.matchParentSize().background(Color.Black.copy(alpha = .32f)))
    Column(
        Modifier.align(Alignment.Center).padding(32.dp).widthIn(max = 360.dp).fillMaxWidth().clip(RoundedCornerShape(m.radii.container)).background(m.roles.raised).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        T(title, m.scale.title, m.roles.ink)
        if (body != null) T(body, m.scale.caption, m.roles.ink2)
        Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End), verticalAlignment = Alignment.CenterVertically) {
            QuietButton("Keep")
            Box(Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(m.radii.control)).background(m.roles.danger).padding(horizontal = 16.dp), contentAlignment = Alignment.Center) {
                T(confirm, m.scale.label, Color.White, maxLines = 1)
            }
        }
    }
}

// ----------------------------------------------------------------------------------------------------------------- Recipes

/** The Recipes page: filters, the grid of posters, then the gaps. [wide]: the tablet with the detail panel on the right. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun MockRecipes(wide: Boolean, loading: Boolean = false, empty: Boolean = false) {
    val m = muse
    Row(Modifier.fillMaxSize().background(m.roles.canvas)) {
        Column(Modifier.weight(1f).fillMaxHeight()) {
            TopBar("")
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = if (wide) 32.dp else 16.dp)) {
                T("Recipes", m.scale.display, m.roles.ink)
                if (empty) {
                    EmptyState("No recipes yet. Recreate an edit or finish one in Edit, and it's saved here.", "Recreate an edit")
                    return@Column
                }
                // Search.
                Row(
                    Modifier.padding(top = 16.dp).fillMaxWidth().height(48.dp).clip(RoundedCornerShape(m.radii.control)).background(m.roles.field).padding(horizontal = 12.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    EIc("magnifying-glass", 20.dp, m.roles.ink2)
                    T("Search recipes", m.scale.body, m.roles.ink2)
                }
                if (wide) Row(Modifier.padding(top = 12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Segmented(listOf("All", "References", "Your edits"), 0, Modifier.weight(3f))
                    Segmented(listOf("Newest", "Most viewed"), 0, Modifier.weight(2f))
                } else {
                    Segmented(listOf("All", "References", "Your edits"), 0, Modifier.padding(top = 12.dp).fillMaxWidth())
                    Segmented(listOf("Newest", "Most viewed"), 0, Modifier.padding(top = 8.dp).fillMaxWidth())
                }
                FlowRow(Modifier.padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) { sampleTags.forEach { TagChip(it, on = it == "warm") } }
                Spacer(Modifier.height(12.dp))
                BoxWithConstraints(Modifier.fillMaxWidth()) {
                    val cols = if (wide) (maxWidth / 180.dp).toInt().coerceIn(2, 4) else 2
                    val items: List<MRecipe?> = if (loading) List(6) { null } else sampleRecipes
                    Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
                        items.chunked(cols).forEach { row ->
                            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                row.forEachIndexed { i, r -> Box(Modifier.weight(1f)) { if (r == null) SkeletonTile() else RecipeTile(r, selected = wide && r == sampleRecipes[0]) } }
                                repeat(cols - row.size) { Spacer(Modifier.weight(1f)) }
                            }
                        }
                    }
                }
                if (!loading) Gaps()
                Spacer(Modifier.height(32.dp))
            }
        }
        if (wide && !loading) {
            Box(Modifier.width(1.dp).fillMaxHeight().background(m.roles.hairline))
            Box(Modifier.width(420.dp).fillMaxHeight().background(m.roles.raised)) { MockRecipeDetail(sampleRecipes[0], panel = true) }
        }
    }
}

@Composable
private fun RecipeTile(r: MRecipe, selected: Boolean) {
    val m = muse
    val shape = RoundedCornerShape(m.radii.container)
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(Modifier.fillMaxWidth().aspectRatio(9f / 16f).clip(shape).background(m.roles.field).let { if (selected) it.border(2.dp, m.roles.selection, shape) else it }) {
            if (r.poster != null) RefImage(ImageRef.asset(r.poster), Modifier.fillMaxSize())
            else Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { EIc("film-strip", 24.dp, m.roles.ink2) } // the poster has expired
            T(r.badge, m.scale.micro.copy(fontFeatureSettings = "tnum"), Color.White,
                Modifier.align(Alignment.BottomEnd).padding(8.dp).clip(RoundedCornerShape(m.radii.chip)).background(Color.Black.copy(alpha = .55f)).padding(horizontal = 6.dp, vertical = 2.dp), maxLines = 1)
        }
        T(r.name, m.scale.label, m.roles.ink, Modifier.padding(top = 4.dp), maxLines = 1)
        T(r.caption, m.scale.caption, m.roles.ink2, maxLines = 2)
    }
}

@Composable
private fun SkeletonTile() {
    val m = muse
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.fillMaxWidth().aspectRatio(9f / 16f).clip(RoundedCornerShape(m.radii.container)).background(m.roles.field))
        Box(Modifier.fillMaxWidth(.7f).height(14.dp).clip(RoundedCornerShape(4.dp)).background(m.roles.field))
        Box(Modifier.fillMaxWidth(.9f).height(12.dp).clip(RoundedCornerShape(4.dp)).background(m.roles.field))
    }
}

@Composable
private fun Gaps() {
    val m = muse
    Column(Modifier.padding(top = 32.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        T("Effects MUSE can't make yet", m.scale.heading, m.roles.ink)
        listOf(
            Triple("Unknown transition", "4 references", "A spin with a light leak, in Tuff edit at 0:02"),
            Triple("Lens flare", "asked once", "Over the window shot in Day in my life"),
            Triple("Body poses", "3 references", "Not read yet"),
        ).forEach { (what, n, note) ->
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                T("$what · $n", m.scale.body, m.roles.ink)
                T(note, m.scale.caption, m.roles.ink2)
            }
        }
    }
}

/** A recipe's detail: a push on the phone, the right-hand panel on a tablet. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun MockRecipeDetail(r: MRecipe, panel: Boolean) {
    val m = muse
    Column(Modifier.fillMaxSize().background(if (panel) m.roles.raised else m.roles.canvas)) {
        if (!panel) TopBar("")
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = if (panel) 24.dp else 16.dp).padding(top = if (panel) 24.dp else 0.dp), verticalArrangement = Arrangement.spacedBy(24.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    T(r.name, m.scale.title, m.roles.ink, Modifier.weight(1f), maxLines = 2)
                    Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) { EIc("pencil-simple", 20.dp, m.roles.ink2) } // "Rename recipe"
                }
                T("Seven shots cut on the beat, a hook up top and a warm film look.", m.scale.body, m.roles.ink)
                T(if (r.reference) "Reference" else "Your edit", m.scale.caption, m.roles.ink2)
            }
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                T("Shape of the edit", m.scale.heading, m.roles.ink)
                ShapeStrip()
                T("7 shots · 28 cuts/min · 118 bpm · 3 text items", m.scale.caption.copy(fontFeatureSettings = "tnum"), m.roles.ink2)
            }
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                T("Look", m.scale.heading, m.roles.ink)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Row(Modifier.clip(RoundedCornerShape(m.radii.chip))) {
                        listOf(0xFF1E1813, 0xFF4A3A2C, 0xFF8A6A4E, 0xFFC9A57E, 0xFFF1E2C8).forEach { Box(Modifier.size(28.dp, 36.dp).background(Color(it))) }
                    }
                    T("Golden warmth", m.scale.label, m.roles.ink)
                }
            }
            if (!r.reference) Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                T("Performance", m.scale.heading, m.roles.ink)
                listOf("Views" to "1.2k", "Likes" to "80", "Saves" to "12", "Avg watch" to "6.5 s", "Completion" to "42%", "Posts" to "1").chunked(2).forEach { row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                        row.forEach { (k, v) ->
                            Row(Modifier.weight(1f)) {
                                T(k, m.scale.body, m.roles.ink2, Modifier.weight(1f), maxLines = 1)
                                T(v, m.scale.label.copy(fontFeatureSettings = "tnum"), m.roles.ink, maxLines = 1)
                            }
                        }
                    }
                }
            }
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                T("Tags", m.scale.heading, m.roles.ink)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.Center) {
                    r.tags.forEach { TagChip(it, removable = true) }
                    T("+ Tag", m.scale.label, m.roles.link, Modifier.heightIn(min = 48.dp).padding(horizontal = 8.dp, vertical = 14.dp))
                }
            }
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                T("Closest recipes", m.scale.heading, m.roles.ink)
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    listOf(Triple("Kitchen walk", "Very close", "g_tq"), Triple("Day in my life", "Close", null), Triple("Tuff edit", "Different", "c_tq")).forEach { (n, d, a) ->
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Box(Modifier.fillMaxWidth().aspectRatio(3f / 4f).clip(RoundedCornerShape(m.radii.control)).background(m.roles.field), contentAlignment = Alignment.Center) {
                                if (a != null) RefImage(ImageRef.asset(a), Modifier.fillMaxSize()) else EIc("film-strip", 20.dp, m.roles.ink2)
                            }
                            T(n, m.scale.caption, m.roles.ink, maxLines = 1)
                            T(d, m.scale.caption, m.roles.ink2, maxLines = 1)
                        }
                    }
                }
            }
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                PrimaryButton(if (r.reference) "Use in Recreate" else "Open edit", Modifier.fillMaxWidth())
                QuietButton("Delete recipe", color = m.roles.danger)
            }
            Spacer(Modifier.height(16.dp))
        }
    }
}

/** The slots as proportional bars on `field`, cuts as hairline gaps, transitions by their icon. */
@Composable
private fun ShapeStrip() {
    val m = muse
    val lengths = listOf(2.2f, 2.0f, 2.0f, 2.0f, 2.0f, 2.2f, 2.6f)
    val marks = mapOf(1 to "intersect", 4 to "lightning") // a whip at the 2nd cut, a flash at the 5th
    Row(Modifier.fillMaxWidth().height(40.dp), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        lengths.forEachIndexed { i, l ->
            Box(Modifier.weight(l).fillMaxHeight().clip(RoundedCornerShape(3.dp)).background(m.roles.ink.copy(alpha = if (i % 2 == 0) .14f else .24f)), contentAlignment = Alignment.CenterStart) {
                marks[i]?.let { EIc(it, 14.dp, m.roles.ink, Modifier.padding(start = 4.dp)) }
            }
        }
    }
}

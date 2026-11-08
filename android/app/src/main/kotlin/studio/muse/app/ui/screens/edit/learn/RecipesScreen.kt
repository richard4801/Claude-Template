package studio.muse.app.ui.screens.edit.learn

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import studio.muse.app.data.LearnGap
import studio.muse.app.data.LearnRecipeEntry
import studio.muse.app.data.LearnRecipePatch
import studio.muse.app.data.MuseApi
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.components.RefImage
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.ScreenBox
import studio.muse.app.ui.screens.edit.EIc
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.radii
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale
import studio.muse.core.edit.Recipe
import studio.muse.core.edit.RecipeJson
import kotlin.math.roundToInt

// Recipes (plans/learning-editor-ui.md §2–3, the owner-approved mock with the owner's notes): every analysed reference and
// every finished edit, so the owner can find what worked. Pictures are the owner's own: an edit's take thumbnail, a
// reference's poster (an authenticated route, fetched by the API layer); without one, a plain tinted tile with no figure.
// Data: /v1/learn/recipes, /recipes/{id}, /recipes/nearest, /gaps (owner only).

enum class RecipeOrigin(val label: String, val wire: String?) { ALL("All", null), REFERENCES("References", "reference"), EDITS("Your edits", "edit") }
enum class RecipeSort(val label: String) { NEWEST("Newest"), VIEWED("Most viewed") }

data class RecipeDetailUi(
    val entry: LearnRecipeEntry,
    val nearest: List<LearnRecipeEntry> = emptyList(),
    val renaming: String? = null,
    val addingTag: String? = null,
    val deleting: Boolean = false,
)

data class RecipesUi(
    val all: List<LearnRecipeEntry>? = null,
    val query: String = "",
    val origin: RecipeOrigin = RecipeOrigin.ALL,
    val sort: RecipeSort = RecipeSort.NEWEST,
    val tag: String? = null,
    val gaps: List<LearnGap> = emptyList(),
    val error: String? = null,
    val detail: RecipeDetailUi? = null,
) {
    /** The 8 most-used tags across the library. */
    val topTags: List<String> get() = all.orEmpty().flatMap { it.tags }.groupingBy { it }.eachCount().entries.sortedByDescending { it.value }.take(8).map { it.key }

    /** What the grid shows: search, origin and the tag filter here (the server does them too), then the sort. */
    val shown: List<LearnRecipeEntry> get() = all.orEmpty().filter { r ->
        (origin.wire == null || r.origin == origin.wire) && (tag == null || tag in r.tags) &&
            (query.isBlank() || listOf(r.name, r.summary).plus(r.tags).any { it.contains(query.trim(), ignoreCase = true) })
    }.let { l -> if (sort == RecipeSort.VIEWED) l.sortedByDescending { it.performance?.views ?: -1 } else l.sortedByDescending { it.createdAt } }

    val filtered: Boolean get() = query.isNotBlank() || origin != RecipeOrigin.ALL || tag != null
}

sealed interface RecipesAction {
    data object Retry : RecipesAction
    data class Query(val q: String) : RecipesAction
    data class Origin(val o: RecipeOrigin) : RecipesAction
    data class Sort(val s: RecipeSort) : RecipesAction
    data class Tag(val t: String) : RecipesAction
    data object ClearFilters : RecipesAction
    data class Open(val id: String) : RecipesAction
    data object CloseDetail : RecipesAction
    data class Rename(val name: String?) : RecipesAction
    data object SaveName : RecipesAction
    data class RemoveTag(val t: String) : RecipesAction
    data class TagDraft(val t: String?) : RecipesAction
    data object SaveTag : RecipesAction
    data object AskDelete : RecipesAction
    data object ConfirmDelete : RecipesAction
    data object Keep : RecipesAction
    data object Use : RecipesAction
    data object Recreate : RecipesAction
}

class RecipesModel(
    private val api: () -> MuseApi, private val toast: (String) -> Unit,
    private val openTake: (String) -> Unit, private val openReference: (String) -> Unit, private val recreate: () -> Unit,
) {
    var ui by mutableStateOf(RecipesUi())
        private set

    suspend fun load() {
        ui = ui.copy(error = null)
        runCatching { api().recipes() }.onSuccess { ui = ui.copy(all = it) }.onFailure { ui = ui.copy(error = "Couldn't load the recipes · check your connection") }
        runCatching { api().learnGaps(10) }.onSuccess { ui = ui.copy(gaps = it) }
    }

    suspend fun act(a: RecipesAction) {
        val d = ui.detail
        when (a) {
            RecipesAction.Retry -> load()
            is RecipesAction.Query -> ui = ui.copy(query = a.q)
            is RecipesAction.Origin -> ui = ui.copy(origin = a.o)
            is RecipesAction.Sort -> ui = ui.copy(sort = a.s)
            is RecipesAction.Tag -> ui = ui.copy(tag = if (ui.tag == a.t) null else a.t)
            RecipesAction.ClearFilters -> ui = ui.copy(query = "", origin = RecipeOrigin.ALL, tag = null)
            is RecipesAction.Open -> {
                val list = ui.all.orEmpty().firstOrNull { it.id == a.id }
                if (list != null) ui = ui.copy(detail = RecipeDetailUi(list))
                runCatching { api().recipe(a.id) }.onSuccess { full -> ui = ui.copy(detail = (ui.detail?.takeIf { it.entry.id == a.id } ?: RecipeDetailUi(full)).copy(entry = full)) }
                    .onFailure { toast(it.message ?: "Couldn't open the recipe") }
                runCatching { api().nearestRecipes(a.id, 3) }.onSuccess { n -> ui.detail?.takeIf { it.entry.id == a.id }?.let { ui = ui.copy(detail = it.copy(nearest = n.nearest)) } }
            }
            RecipesAction.CloseDetail -> ui = ui.copy(detail = null)
            is RecipesAction.Rename -> d?.let { ui = ui.copy(detail = it.copy(renaming = a.name)) }
            RecipesAction.SaveName -> d?.renaming?.trim()?.takeIf { it.isNotEmpty() }?.let { name -> patch(d, LearnRecipePatch(name = name.take(80))) }
            is RecipesAction.RemoveTag -> d?.let { patch(it, LearnRecipePatch(tags = it.entry.tags - a.t)) }
            is RecipesAction.TagDraft -> d?.let { ui = ui.copy(detail = it.copy(addingTag = a.t)) }
            RecipesAction.SaveTag -> d?.addingTag?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }?.let { t -> patch(d, LearnRecipePatch(tags = (d.entry.tags + t.take(32)).distinct())) }
            RecipesAction.AskDelete -> d?.let { ui = ui.copy(detail = it.copy(deleting = true)) }
            RecipesAction.Keep -> d?.let { ui = ui.copy(detail = it.copy(deleting = false)) }
            RecipesAction.ConfirmDelete -> d?.let { det ->
                runCatching { api().deleteRecipe(det.entry.id) }
                    .onSuccess { ui = ui.copy(detail = null, all = ui.all.orEmpty().filter { it.id != det.entry.id }) }
                    .onFailure { toast(it.message ?: "Couldn't delete · try again"); ui = ui.copy(detail = det.copy(deleting = false)) }
            }
            RecipesAction.Use -> d?.entry?.let { e -> if (e.isReference) e.referenceId?.let(openReference) else e.takeId?.let(openTake) }
            RecipesAction.Recreate -> recreate()
        }
    }

    private suspend fun patch(d: RecipeDetailUi, p: LearnRecipePatch) {
        runCatching { api().patchRecipe(d.entry.id, p) }
            .onSuccess { e ->
                ui = ui.copy(detail = d.copy(entry = e.copy(recipe = e.recipe ?: d.entry.recipe, performance = e.performance ?: d.entry.performance), renaming = null, addingTag = null),
                    all = ui.all.orEmpty().map { if (it.id == e.id) e.copy(recipe = null) else it })
            }
            .onFailure { toast(it.message ?: "Couldn't save · try again") }
    }
}

/** A recipe's picture: the owner's own (a take's thumbnail, a reference's poster), or a plain tinted tile. */
typealias RecipePicture = @Composable (LearnRecipeEntry, Modifier) -> Unit

@Composable
fun RecipesScreen(onBack: () -> Unit, onOpenTake: (String) -> Unit, onOpenReference: (String) -> Unit, onRecreate: () -> Unit) {
    val c = LocalContainer.current
    val scope = rememberCoroutineScope()
    val model = remember { RecipesModel({ c.repo.api }, { c.repo.toast(it) }, onOpenTake, onOpenReference, onRecreate) }
    LaunchedEffect(Unit) { model.load() }
    val state by c.repo.state.collectAsState()
    val posters = remember { HashMap<String, ImageBitmap?>() }
    val picture: RecipePicture = { e, mod ->
        val take = e.takeId?.let { id -> state.takes.firstOrNull { it.id == id } }
        when {
            take?.thumb != null -> RefImage(take.thumb, mod)
            e.referenceId != null -> {
                val img by produceState(posters[e.referenceId], e.referenceId) {
                    if (!posters.containsKey(e.referenceId)) {
                        val bytes = runCatching { c.repo.api.referencePoster(e.referenceId) }.getOrNull()
                        posters[e.referenceId] = bytes?.let { b -> runCatching { android.graphics.BitmapFactory.decodeByteArray(b, 0, b.size)?.asImageBitmap() }.getOrNull() }
                    }
                    value = posters[e.referenceId]
                }
                img?.let { Image(it, null, mod, contentScale = ContentScale.Crop) } ?: TintedTile(mod)
            }
            else -> TintedTile(mod)
        }
    }
    val ui = model.ui
    BackHandler {
        val d = ui.detail
        scope.launch {
            when {
                d?.deleting == true -> model.act(RecipesAction.Keep)
                d != null -> model.act(RecipesAction.CloseDetail)
                else -> onBack()
            }
        }
    }
    RecipesContent(ui, picture, onBack) { a -> scope.launch { model.act(a) } }
}

/** No picture: a plain tinted tile, no figure, no icon (the owner's note). */
@Composable
fun TintedTile(modifier: Modifier) = Box(modifier.background(muse.roles.field))

/** The screen as a function of [ui]; [picture] draws each recipe's picture (screenshots pass stand-ins). */
@Composable
fun RecipesContent(ui: RecipesUi, picture: RecipePicture, onBack: () -> Unit, act: (RecipesAction) -> Unit) {
    val m = muse
    ScreenBox(statusPad = true) {
        BoxWithConstraints(Modifier.fillMaxSize().background(m.roles.canvas)) {
            val wide = maxWidth >= 840.dp
            val d = ui.detail
            Row(Modifier.fillMaxSize()) {
                if (wide || d == null) Column(Modifier.weight(1f).fillMaxHeight()) {
                    LearnTopBar(onBack)
                    Grid(ui, picture, wide, act)
                }
                if (d != null) {
                    if (wide) Box(Modifier.width(1.dp).fillMaxHeight().background(m.roles.hairline))
                    Box(Modifier.let { if (wide) it.width(420.dp) else it.weight(1f) }.fillMaxHeight().background(if (wide) m.roles.raised else m.roles.canvas)) {
                        RecipeDetail(d, picture, wide, act)
                    }
                }
            }
            if (d?.deleting == true) LearnConfirm("Delete this recipe?",
                if (d.entry.isReference) "The reference stays; only the saved recipe goes." else "The edit and its video stay; only the saved recipe goes.",
                "Delete recipe", { act(RecipesAction.ConfirmDelete) }, { act(RecipesAction.Keep) })
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Grid(ui: RecipesUi, picture: RecipePicture, wide: Boolean, act: (RecipesAction) -> Unit) {
    val m = muse
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = if (wide) 32.dp else 16.dp)) {
        T("Recipes", m.scale.display, m.roles.ink)
        when {
            ui.error != null && ui.all == null -> return@Column LearnError(ui.error) { act(RecipesAction.Retry) }
            ui.all != null && ui.all.isEmpty() -> return@Column Column(Modifier.padding(top = 32.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                T("No recipes yet. Recreate an edit or finish one in Edit, and it's saved here.", m.scale.body, m.roles.ink2)
                LearnPrimary("Recreate an edit") { act(RecipesAction.Recreate) }
            }
        }
        // Search.
        Row(
            Modifier.padding(top = 16.dp).fillMaxWidth().height(48.dp).clip(RoundedCornerShape(m.radii.control)).background(m.roles.field).padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            EIc("magnifying-glass", 20.dp, m.roles.ink2)
            BasicTextField(ui.query, { act(RecipesAction.Query(it.take(80))) }, Modifier.weight(1f).semantics { contentDescription = "Search recipes" }, singleLine = true,
                textStyle = m.scale.body.copy(color = m.roles.ink), cursorBrush = SolidColor(m.roles.accent),
                decorationBox = { inner -> Box { if (ui.query.isEmpty()) T("Search recipes", m.scale.body, m.roles.ink2); inner() } })
        }
        val origin = @Composable { mod: Modifier -> LearnSegmented(RecipeOrigin.entries.map { it.label }, ui.origin.ordinal, mod) { act(RecipesAction.Origin(RecipeOrigin.entries[it])) } }
        val sort = @Composable { mod: Modifier -> LearnSegmented(RecipeSort.entries.map { it.label }, ui.sort.ordinal, mod) { act(RecipesAction.Sort(RecipeSort.entries[it])) } }
        if (wide) Row(Modifier.padding(top = 12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) { origin(Modifier.weight(3f)); sort(Modifier.weight(2f)) }
        else { origin(Modifier.padding(top = 12.dp).fillMaxWidth()); sort(Modifier.padding(top = 8.dp).fillMaxWidth()) }
        val tags = ui.topTags
        if (tags.isNotEmpty()) FlowRow(Modifier.padding(top = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            tags.forEach { t -> LearnChip(t, on = t == ui.tag) { act(RecipesAction.Tag(t)) } }
        }
        Spacer(Modifier.height(12.dp))
        val items: List<LearnRecipeEntry?> = ui.all?.let { ui.shown } ?: List(6) { null }
        if (ui.all != null && items.isEmpty()) {
            Column(Modifier.padding(top = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                T(if (ui.query.isNotBlank()) "Nothing matches “${ui.query.trim()}”" else "Nothing matches these filters", m.scale.body, m.roles.ink2)
                LearnQuiet("Clear filters") { act(RecipesAction.ClearFilters) }
            }
        }
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val cols = if (wide) (maxWidth / 180.dp).toInt().coerceIn(2, 5) else 2
            Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
                items.chunked(cols).forEach { row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        row.forEach { r -> Box(Modifier.weight(1f)) { if (r == null) SkeletonTile() else Tile(r, picture, ui.detail?.entry?.id == r.id) { act(RecipesAction.Open(r.id)) } } }
                        repeat(cols - row.size) { Spacer(Modifier.weight(1f)) }
                    }
                }
            }
        }
        if (ui.gaps.isNotEmpty() && !ui.filtered) Gaps(ui.gaps)
        Spacer(Modifier.height(32.dp))
    }
}

/** "15 s · 7 cuts" from the recipe's features. */
private fun badge(e: LearnRecipeEntry): String? {
    val d = e.features["durationSec"] ?: return null
    val shots = e.features["shots"]?.roundToInt()
    return listOfNotNull("${d.roundToInt()} s", shots?.let { "${(it - 1).coerceAtLeast(0)} cuts" }).joinToString(" · ")
}

/** "1.2k views · 42% completion", or the summary. */
private fun tileCaption(e: LearnRecipeEntry): String {
    val p = e.performance
    if (p != null && p.posts > 0) return listOfNotNull("${compact(p.views)} views", p.completion?.let { "${(it * 100).roundToInt()}% completion" }).joinToString(" · ")
    return e.summary.ifBlank { if (e.isReference) "Reference" else "Not posted yet" }
}

internal fun compact(n: Long): String = when {
    n >= 1_000_000 -> String.format(java.util.Locale.ROOT, "%.1fM", n / 1e6).replace(".0M", "M")
    n >= 1_000 -> String.format(java.util.Locale.ROOT, "%.1fk", n / 1e3).replace(".0k", "k")
    else -> "$n"
}

@Composable
private fun Tile(r: LearnRecipeEntry, picture: RecipePicture, selected: Boolean, onClick: () -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(m.radii.container)
    Column(Modifier.press(onClick = onClick).semantics(mergeDescendants = true) { role = Role.Button }, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Box(Modifier.fillMaxWidth().aspectRatio(9f / 16f).clip(shape).background(m.roles.field).let { if (selected) it.border(2.dp, m.roles.selection, shape) else it }) {
            picture(r, Modifier.fillMaxSize())
            badge(r)?.let {
                T(it, m.scale.micro.copy(fontFeatureSettings = "tnum"), Color.White,
                    Modifier.align(Alignment.BottomEnd).padding(8.dp).clip(RoundedCornerShape(m.radii.chip)).background(Color.Black.copy(alpha = .55f)).padding(horizontal = 6.dp, vertical = 2.dp), maxLines = 1)
            }
        }
        T(r.name, m.scale.label, m.roles.ink, Modifier.padding(top = 4.dp), maxLines = 1)
        T(tileCaption(r), m.scale.caption, m.roles.ink2, maxLines = 2)
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

/** "Effects MUSE can't make yet": what to build next. Read-only. */
@Composable
private fun Gaps(gaps: List<LearnGap>) {
    val m = muse
    Column(Modifier.padding(top = 32.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        T("Effects MUSE can't make yet", m.scale.heading, m.roles.ink)
        gaps.forEach { g ->
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                T("${g.what} · ${if (g.count == 1) "asked once" else "${g.count} references"}", m.scale.body, m.roles.ink)
                g.examples.firstOrNull()?.note?.takeIf { it.isNotBlank() }?.let { T(it, m.scale.caption, m.roles.ink2) }
            }
        }
    }
}

// ------------------------------------------------------------------------------------------------------------ Detail

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun RecipeDetail(d: RecipeDetailUi, picture: RecipePicture, panel: Boolean, act: (RecipesAction) -> Unit) {
    val m = muse
    val e = d.entry
    val recipe: Recipe? = remember(e.recipe) { e.recipe?.let { runCatching { RecipeJson.parse(it) }.getOrNull() } }
    Column(Modifier.fillMaxSize()) {
        if (!panel) LearnTopBar(onBack = { act(RecipesAction.CloseDetail) })
        Column(
            Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = if (panel) 24.dp else 16.dp).padding(top = if (panel) 24.dp else 0.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                if (d.renaming != null) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box(Modifier.weight(1f).clip(RoundedCornerShape(m.radii.control)).background(m.roles.field).padding(12.dp)) {
                        BasicTextField(d.renaming, { act(RecipesAction.Rename(it.take(80))) }, Modifier.fillMaxWidth().semantics { contentDescription = "Recipe name" }, singleLine = true,
                            textStyle = m.scale.title.copy(color = m.roles.ink), cursorBrush = SolidColor(m.roles.accent))
                    }
                    LearnLink("Save") { act(RecipesAction.SaveName) }
                } else Row(verticalAlignment = Alignment.CenterVertically) {
                    T(e.name, m.scale.title, m.roles.ink, Modifier.weight(1f), maxLines = 2)
                    Box(Modifier.size(48.dp).press { act(RecipesAction.Rename(e.name)) }.semantics { contentDescription = "Rename recipe"; role = Role.Button }, contentAlignment = Alignment.Center) {
                        EIc("pencil-simple", 20.dp, m.roles.ink2)
                    }
                }
                e.summary.takeIf { it.isNotBlank() }?.let { T(it, m.scale.body, m.roles.ink) }
                T(if (e.isReference) "Reference" else "Your edit", m.scale.caption, m.roles.ink2)
            }
            if (recipe != null) Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                T("Shape of the edit", m.scale.heading, m.roles.ink)
                ShapeStrip(recipe)
                T(listOfNotNull("${recipe.slots.size} shots", "${recipe.cutsPerMinute.roundToInt()} cuts/min", recipe.beats?.bpm?.let { "${it.roundToInt()} bpm" },
                    recipe.texts.size.takeIf { it > 0 }?.let { "$it text item${if (it == 1) "" else "s"}" }).joinToString(" · "),
                    m.scale.caption.copy(fontFeatureSettings = "tnum"), m.roles.ink2)
            }
            recipe?.grade?.let { g ->
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    T("Look", m.scale.heading, m.roles.ink)
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Row(Modifier.clip(RoundedCornerShape(m.radii.chip))) {
                            g.swatches.forEach { hex -> Box(Modifier.size(28.dp, 36.dp).background(runCatching { Color(android.graphics.Color.parseColor(hex)) }.getOrDefault(m.roles.field))) }
                        }
                        if (g.name != "Its own grade") T(g.name, m.scale.label, m.roles.ink)
                    }
                }
            }
            e.performance?.takeIf { it.posts > 0 }?.let { p ->
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    T("Performance", m.scale.heading, m.roles.ink)
                    // Value pairs, not a stat hero; fields the platforms didn't report are left out.
                    listOfNotNull("Views" to compact(p.views), "Likes" to compact(p.likes), p.saves?.let { "Saves" to compact(it) },
                        p.avgWatchSec?.let { "Avg watch" to String.format(java.util.Locale.ROOT, "%.1f s", it) },
                        p.completion?.let { "Completion" to "${(it * 100).roundToInt()}%" }, "Posts" to "${p.posts}").chunked(2).forEach { row ->
                        Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                            row.forEach { (k, v) ->
                                Row(Modifier.weight(1f)) {
                                    T(k, m.scale.body, m.roles.ink2, Modifier.weight(1f), maxLines = 1)
                                    T(v, m.scale.label.copy(fontFeatureSettings = "tnum"), m.roles.ink, maxLines = 1)
                                }
                            }
                            if (row.size == 1) Spacer(Modifier.weight(1f))
                        }
                    }
                }
            }
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                T("Tags", m.scale.heading, m.roles.ink)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.Center) {
                    e.tags.forEach { t -> LearnChip(t, onRemove = { act(RecipesAction.RemoveTag(t)) }) }
                    if (d.addingTag == null) LearnLink("+ Tag", modifier = Modifier.padding(horizontal = 8.dp)) { act(RecipesAction.TagDraft("")) }
                }
                if (d.addingTag != null) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box(Modifier.weight(1f).height(44.dp).clip(RoundedCornerShape(m.radii.control)).background(m.roles.field).padding(horizontal = 12.dp), contentAlignment = Alignment.CenterStart) {
                        BasicTextField(d.addingTag, { act(RecipesAction.TagDraft(it.take(32).lowercase())) }, Modifier.fillMaxWidth().semantics { contentDescription = "New tag" }, singleLine = true,
                            textStyle = m.scale.body.copy(color = m.roles.ink), cursorBrush = SolidColor(m.roles.accent))
                    }
                    LearnLink("Add") { act(RecipesAction.SaveTag) }
                }
            }
            if (d.nearest.isNotEmpty()) Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                T("Closest recipes", m.scale.heading, m.roles.ink)
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    d.nearest.take(3).forEach { n ->
                        Column(Modifier.weight(1f).press { act(RecipesAction.Open(n.id)) }.semantics(mergeDescendants = true) { role = Role.Button }, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Box(Modifier.fillMaxWidth().aspectRatio(3f / 4f).clip(RoundedCornerShape(m.radii.control)).background(m.roles.field)) { picture(n, Modifier.fillMaxSize()) }
                            T(n.name, m.scale.caption, m.roles.ink, maxLines = 1)
                            T(when { (n.distance ?: 1.0) < .3 -> "Very close"; (n.distance ?: 1.0) < .6 -> "Close"; else -> "Different" }, m.scale.caption, m.roles.ink2, maxLines = 1)
                        }
                    }
                    repeat(3 - d.nearest.take(3).size) { Spacer(Modifier.weight(1f)) }
                }
            }
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                val usable = e.available && if (e.isReference) e.referenceId != null else e.takeId != null
                if (!e.available) T(if (e.isReference) "The reference video has expired. The recipe stays." else "This edit isn't in your studio any more.", m.scale.caption, m.roles.ink2)
                if (usable) LearnPrimary(if (e.isReference) "Use in Recreate" else "Open edit", Modifier.fillMaxWidth()) { act(RecipesAction.Use) }
                LearnQuiet("Delete recipe", color = m.roles.danger) { act(RecipesAction.AskDelete) }
            }
            Spacer(Modifier.height(16.dp))
        }
    }
}

/** The slots as proportional bars on `field`, the cuts as hairline gaps, transitions by their icon. */
@Composable
private fun ShapeStrip(r: Recipe) {
    val m = muse
    val icons = r.transitions.mapNotNull { t ->
        val i = r.slots.indexOfLast { it.startSec <= t.atSec + 0.01 }.takeIf { it >= 0 } ?: return@mapNotNull null
        val icon = when (t.kind) { null, "Cut" -> null; "Flash" -> "lightning"; else -> "intersect" } ?: return@mapNotNull null
        i to icon
    }.toMap()
    Row(Modifier.fillMaxWidth().height(40.dp).semantics { contentDescription = "${r.slots.size} shots" }, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        r.slots.forEachIndexed { i, s ->
            Box(Modifier.weight(s.lengthSec.toFloat().coerceAtLeast(.05f)).fillMaxHeight().clip(RoundedCornerShape(3.dp)).background(m.roles.ink.copy(alpha = if (i % 2 == 0) .14f else .24f)),
                contentAlignment = Alignment.CenterStart) {
                icons[i]?.let { EIc(it, 14.dp, m.roles.ink, Modifier.padding(start = 4.dp)) }
            }
        }
    }
}

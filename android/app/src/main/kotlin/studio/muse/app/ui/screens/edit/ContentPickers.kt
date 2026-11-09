package studio.muse.app.ui.screens.edit

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import studio.muse.app.platform.edit.ContentCatalog
import studio.muse.app.platform.edit.ContentItem
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.theme.muse

/** Items of [kind] matching [query] (name or tags, every word) in [category] (null: all). */
internal fun contentSearch(cat: ContentCatalog, kind: String, query: String, category: String?): List<ContentItem> {
    val words = query.trim().lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }
    return cat.pack(kind).flatMap { it.items }.filter { it ->
        (category == null || it.category == category) &&
            words.all { w -> it.name.lowercase().contains(w) || it.tags.any { t -> t.lowercase().startsWith(w) } }
    }
}

@Composable
private fun SearchField(value: String, onChange: (String) -> Unit, hint: String) {
    val m = muse
    BasicTextField(
        value, onChange,
        Modifier.fillMaxWidth().background(m.t.surface).border(1.dp, m.t.line).padding(horizontal = 12.dp, vertical = 11.dp).semantics { contentDescription = hint },
        textStyle = m.type.body.copy(color = m.t.ink, fontSize = 14.sp), cursorBrush = SolidColor(m.t.accent), singleLine = true,
        decorationBox = { inner -> Box { if (value.isEmpty()) T(hint, m.type.body.copy(fontSize = 14.sp), m.t.muted, maxLines = 1); inner() } },
    )
}

@Composable
private fun CategoryRow(categories: List<Pair<String, String>>, selected: String?, onPick: (String?) -> Unit) {
    LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        item { SuiteChip("All", selected == null, { onPick(null) }) }
        items(categories) { (id, label) -> SuiteChip(label, selected == id, { onPick(id) }) }
    }
}

/** Stickers (Twemoji): search, categories, a grid; a tap places one at the playhead. */
@Composable
fun StickerPicker(cat: ContentCatalog, url: (String) -> String?, onPick: (ContentItem) -> Unit) {
    val m = muse
    var query by rememberSaveable { mutableStateOf("") }
    var category by rememberSaveable { mutableStateOf<String?>(null) }
    val packs = cat.pack("stickers")
    val shown = remember(cat.version, query, category) { contentSearch(cat, "stickers", query, category) }
    SearchField(query, { query = it }, "Search stickers")
    CategoryRow(packs.flatMap { it.categories }, category) { category = it }
    if (shown.isEmpty()) T("No stickers match “${query.trim()}”", m.type.body.copy(fontSize = 13.sp), m.t.muted)
    else LazyVerticalGrid(GridCells.Adaptive(56.dp), Modifier.fillMaxWidth().height(264.dp), horizontalArrangement = Arrangement.spacedBy(4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        items(shown, key = { it.ref }) { s ->
            Box(Modifier.aspectRatio(1f).press { onPick(s) }.semantics { contentDescription = "Sticker ${s.name}" }.padding(6.dp), contentAlignment = Alignment.Center) {
                val src = s.file?.let(url)
                // A downloaded sticker is a small local PNG: drawn straight away; otherwise loaded from the server.
                val local = remember(src) { src?.takeIf { it.startsWith("/") }?.let { android.graphics.BitmapFactory.decodeFile(it)?.asImageBitmap() } }
                if (local != null) androidx.compose.foundation.Image(local, null, Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
                else AsyncImage(src, null, Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
            }
        }
    }
    packs.firstOrNull()?.attribution?.let { T("Twemoji by Twitter, Inc. and contributors · CC BY 4.0", m.type.tiny.copy(fontSize = 11.sp), m.t.muted) }
}

/** Sound effects (CC0): search, styles, a list with a play preview; a tap on Add puts one at the playhead. */
@Composable
fun SoundEffectPicker(cat: ContentCatalog, playing: String?, onPlay: (ContentItem?) -> Unit, onPick: (ContentItem) -> Unit) {
    val m = muse
    var query by rememberSaveable { mutableStateOf("") }
    var category by rememberSaveable { mutableStateOf<String?>(null) }
    val shown = remember(cat.version, query, category) { contentSearch(cat, "sfx", query, category) }
    SearchField(query, { query = it }, "Search sound effects")
    CategoryRow(cat.pack("sfx").flatMap { it.categories }, category) { category = it }
    if (shown.isEmpty()) T("No sounds match “${query.trim()}”", m.type.body.copy(fontSize = 13.sp), m.t.muted)
    else LazyColumn(Modifier.fillMaxWidth().height(288.dp)) {
        items(shown, key = { it.ref }) { s ->
            val on = playing == s.ref
            Row(Modifier.fillMaxWidth().padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(48.dp).press { onPlay(if (on) null else s) }.semantics { contentDescription = if (on) "Stop ${s.name}" else "Play ${s.name}" }, contentAlignment = Alignment.Center) {
                    EIc(if (on) "pause" else "play", 18.dp, m.t.ink)
                }
                Column(Modifier.weight(1f)) {
                    T(s.name, m.type.body.copy(fontSize = 14.sp, fontWeight = FontWeight.Bold), m.t.ink, maxLines = 1)
                    T("${cat.packs.firstOrNull { p -> p.id == s.packId }?.categories?.firstOrNull { it.first == s.category }?.second ?: s.category ?: ""}, ${"%.1f".format(s.durationSec ?: 0.0)} s",
                        m.type.tiny.copy(fontSize = 12.sp), m.t.muted, maxLines = 1)
                }
                SuiteButton("Add", { onPick(s) }, height = 34.dp)
            }
        }
    }
    T("Sounds from UI SFX and Kenney · CC0", m.type.tiny.copy(fontSize = 11.sp), m.t.muted)
}

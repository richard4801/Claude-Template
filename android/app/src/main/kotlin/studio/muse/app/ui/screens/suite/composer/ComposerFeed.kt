package studio.muse.app.ui.screens.suite.composer

import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import studio.muse.app.data.SuiteFeedItem
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.components.RefImage
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.StageVideo
import studio.muse.app.ui.screens.edit.EIc
import studio.muse.app.ui.screens.edit.learn.LearnSegmented
import studio.muse.app.ui.screens.edit.tabular
import studio.muse.app.ui.screens.suite.SuiteFeedFilter
import studio.muse.app.ui.screens.suite.compare
import studio.muse.app.ui.screens.suite.loadFeed
import studio.muse.app.ui.screens.suite.reuseSettings
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.radii
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale

/*
 * The results feed and Compare (the AI suite plan, plans/ai-suite-design.md; the Mac's ComposerFeed): every take the
 * Suite made, newest first, filtered All / Rendering / Finished / Failed, with live progress on running cards (the
 * studio's jobs). A finished card opens its take; its square marks it for Compare, and two marked takes play side by side.
 */

/** The feed in place of the composer ("Takes" in the top bar). [onOpen]: a card's job (its take screen). */
@Composable
fun SuiteFeedView(photo: Boolean, wide: Boolean, onOpen: (String) -> Unit, modifier: Modifier = Modifier) {
    val m = muse
    val c = LocalContainer.current
    val store = c.suite
    val scope = rememberCoroutineScope()
    val items by store.feed.collectAsState()
    val filter by store.feedFilter.collectAsState()
    val comparing by store.compareIds.collectAsState()
    val st by c.repo.state.collectAsState()
    var older by remember { mutableStateOf(false) } // an older server without the feed: the Suite's jobs stand in
    LaunchedEffect(filter, photo) { older = !store.loadFeed(photo) }
    // The feed's stand-in: the Suite's recent jobs, as cards.
    val shown: List<SuiteFeedItem> = items?.takeIf { !older } ?: st.jobs.filter { it.request.engine == studio.muse.app.data.SuiteRules.ENGINE }.map { j ->
        val t = st.takes.firstOrNull { it.jobId == j.id }
        SuiteFeedItem(j.id, if (t != null) "take" else "job", when { j.state == "failed" -> "failed"; t != null -> "done"; else -> "running" }, jobId = j.id, title = j.title,
            poster = t?.thumb ?: j.thumb, progress = j.progress, takeId = t?.id, createdAt = j.createdAt)
    }.filter { filter.statuses.isEmpty() || it.status in filter.statuses }
    Column(modifier.fillMaxSize().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        LearnSegmented(SuiteFeedFilter.entries.map { it.label }, filter.ordinal, Modifier.fillMaxWidth().widthIn(max = 520.dp)) { store.feedFilter.value = SuiteFeedFilter.entries[it] }
        if (comparing.size == 1) T("Pick a second take to compare", m.scale.caption, m.roles.ink2)
        if (shown.isEmpty()) T(if (items == null && !older) "Loading your takes" else "No takes here yet. Generate one and it appears here.", m.scale.body, m.roles.ink2)
        val cols = if (wide) 4 else 2
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            shown.chunked(cols).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    row.forEach { item ->
                        val take = item.takeId?.let { id -> st.takes.firstOrNull { it.id == id } }
                        val live = item.jobId?.let { st.job(it) }
                        FeedCard(item, live?.progress ?: item.progress, take?.id in comparing, Modifier.weight(1f),
                            onOpen = { item.jobId?.let(onOpen) }, onCompare = take?.let { t -> { store.compare(t) } })
                    }
                    repeat(cols - row.size) { Spacer(Modifier.weight(1f)) }
                }
            }
            if (!older && store.feedCursor != null) Box(Modifier.fillMaxWidth().heightIn(min = 48.dp).press { scope.launch { store.loadFeed(photo, reset = false) } }
                .semantics { role = Role.Button }, contentAlignment = Alignment.Center) { T("Show older takes", m.scale.label, m.roles.link) }
            Spacer(Modifier.height(16.dp))
        }
    }
}

@Composable
private fun FeedCard(item: SuiteFeedItem, progress: Double?, comparing: Boolean, modifier: Modifier, onOpen: () -> Unit, onCompare: (() -> Unit)?) {
    val m = muse
    val shape = RoundedCornerShape(m.radii.container)
    val status = when (item.status) {
        "queued" -> "Waiting"
        "running" -> progress?.takeIf { it > 0 }?.let { "${it.toInt()}%" } ?: "Rendering"
        "failed" -> "Failed, not charged"
        else -> item.summary.ifBlank { "Ready" }
    }
    Column(modifier.semantics(mergeDescendants = true) { contentDescription = "${item.title.ifBlank { "Take" }}, $status" }, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.fillMaxWidth().aspectRatio(9f / 16f).clip(shape).background(m.roles.field).border(if (comparing) 2.dp else 0.dp, if (comparing) m.roles.selection else Color.Transparent, shape)
            .press(onClick = onOpen)) {
            RefImage(item.poster, Modifier.fillMaxSize(), 20)
            if (item.status == "running" || item.status == "queued") {
                Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(4.dp).background(Color.Black.copy(alpha = .3f))) {
                    Box(Modifier.fillMaxWidth(((progress ?: 0.0) / 100).toFloat().coerceIn(0f, 1f)).fillMaxHeight().background(m.roles.accent))
                }
            }
            // Compare: the square marks this take; two marked takes play side by side.
            if (onCompare != null) Box(Modifier.align(Alignment.TopEnd).size(44.dp).press(onClick = onCompare)
                .semantics { contentDescription = if (comparing) "Stop comparing" else "Compare"; role = Role.Checkbox; selected = comparing }, contentAlignment = Alignment.Center) {
                Box(Modifier.size(22.dp).clip(RoundedCornerShape(6.dp)).background(if (comparing) m.roles.selection else Color.Black.copy(alpha = .35f)), contentAlignment = Alignment.Center) {
                    if (comparing) EIc("check", 14.dp, Color.White) else EIc("columns", 13.dp, Color.White)
                }
            }
        }
        T(item.title.ifBlank { "Take" }, m.scale.label, m.roles.ink, maxLines = 1)
        T(status, m.scale.caption.tabular(), if (item.status == "failed") m.roles.caution else m.roles.ink2, maxLines = 1)
    }
}

/**
 * Compare: the two marked takes side by side over the composer, playing together ("Play both" starts them again in
 * step). "Reuse settings" under each puts that take's composer back; Close ends the comparison.
 */
@Composable
fun SuiteCompareOverlay(wide: Boolean, onReused: (String) -> Unit) {
    val m = muse
    val c = LocalContainer.current
    val store = c.suite
    val ids by store.compareIds.collectAsState()
    val st by c.repo.state.collectAsState()
    if (ids.size < 2) return
    val takes = ids.mapNotNull { id -> st.takes.firstOrNull { it.id == id } }
    if (takes.size < 2) return
    var round by remember { mutableIntStateOf(0) }
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = .5f)).press { store.compareIds.value = emptyList() }, contentAlignment = Alignment.Center) {
        Column(Modifier.padding(16.dp).widthIn(max = 900.dp).fillMaxWidth().clip(RoundedCornerShape(m.radii.container)).background(m.roles.canvas).press { }.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                T("Compare", m.scale.title, m.roles.ink, Modifier.weight(1f))
                Box(Modifier.heightIn(min = 48.dp).press { round++ }.padding(horizontal = 8.dp).semantics { role = Role.Button }, contentAlignment = Alignment.Center) {
                    T("Play both", m.scale.label, m.roles.link, maxLines = 1)
                }
                Box(Modifier.size(48.dp).press { store.compareIds.value = emptyList() }.semantics { contentDescription = "Close"; role = Role.Button }, contentAlignment = Alignment.Center) {
                    EIc("x", 20.dp, m.roles.ink)
                }
            }
            BoxWithConstraints(Modifier.fillMaxWidth()) {
                val h = if (wide) 520.dp else (maxWidth / 2 - 8.dp) * 16 / 9
                Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    takes.forEach { t ->
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Box(Modifier.fillMaxWidth().height(h).clip(RoundedCornerShape(m.radii.control)).background(Color.Black), contentAlignment = Alignment.Center) {
                                // A new round (Play both) rebuilds both players so they start together.
                                androidx.compose.runtime.key(round) {
                                    val url = t.videoUrl
                                    if (url != null) StageVideo(url, t.thumb, muted = true, modifier = Modifier.aspectRatio(9f / 16f))
                                    else RefImage(t.thumb, Modifier.aspectRatio(9f / 16f), 20)
                                }
                            }
                            T(if (t.of > 1) "${t.title}, take ${t.index}" else t.title, m.scale.label, m.roles.ink, maxLines = 1)
                            Box(Modifier.heightIn(min = 44.dp).press {
                                store.reuseSettings(t)?.let { tool -> store.compareIds.value = emptyList(); onReused(tool.id) } ?: c.repo.toast("This take was made before Reuse settings")
                            }.semantics { role = Role.Button }, contentAlignment = Alignment.CenterStart) { T("Reuse settings", m.scale.label, m.roles.link, maxLines = 1) }
                        }
                    }
                }
            }
        }
    }
}

package studio.muse.app.ui.screens.suite

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.edit.EIc
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.radii
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale

/**
 * Library collections (build step 3): which collections a take or photo is in. Tap one to add it or take it out (only
 * collections you can change), or make a new one with it in.
 */
@Composable
fun CollectionsSheet(takeId: String, onClose: () -> Unit) {
    val m = muse
    val c = LocalContainer.current
    val store = c.suite
    val scope = rememberCoroutineScope()
    val all by store.collections.collectAsState()
    var inIds by remember(takeId) { mutableStateOf<Set<String>?>(null) }
    var name by remember { mutableStateOf("") }
    LaunchedEffect(takeId) {
        store.loadCollections()
        inIds = runCatching { c.repo.api.takeCollections(takeId) }.getOrDefault(emptyList()).map { it.id }.toSet()
    }
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = .32f)).press(onClick = onClose), contentAlignment = Alignment.Center) {
        Column(Modifier.padding(24.dp).widthIn(max = 420.dp).fillMaxWidth().clip(RoundedCornerShape(m.radii.container)).background(m.roles.canvas).press { }.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            T("Add to collection", m.scale.title, m.roles.ink)
            val have = inIds
            if (all.isEmpty()) T("No collections yet. Name one below and this take goes in it.", m.scale.body, m.roles.ink2)
            Column(Modifier.heightIn(max = 300.dp).verticalScroll(rememberScrollState())) {
                all.forEach { col ->
                    val on = have?.contains(col.id) == true
                    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).press(enabled = col.canEdit && have != null) {
                        scope.launch { if (store.toggleInCollection(col.id, takeId, on)) inIds = if (on) have!! - col.id else have!! + col.id }
                    }.semantics(mergeDescendants = true) { role = Role.Checkbox; selected = on }, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Box(Modifier.size(22.dp).clip(RoundedCornerShape(6.dp)).background(if (on) m.roles.selection else m.roles.field), contentAlignment = Alignment.Center) {
                            if (on) EIc("check", 14.dp, Color.White)
                        }
                        T(col.name, m.scale.label, if (col.canEdit) m.roles.ink else m.roles.ink2, Modifier.weight(1f), maxLines = 1)
                        T("${col.count}", m.scale.caption, m.roles.ink2, maxLines = 1)
                    }
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Box(Modifier.weight(1f).heightIn(min = 48.dp).clip(RoundedCornerShape(m.radii.control)).background(m.roles.field).padding(horizontal = 12.dp), contentAlignment = Alignment.CenterStart) {
                    BasicTextField(name, { name = it.take(60) }, Modifier.fillMaxWidth().semantics { contentDescription = "New collection name" }, singleLine = true,
                        textStyle = m.scale.body.copy(color = m.roles.ink), cursorBrush = SolidColor(m.roles.accent),
                        decorationBox = { inner -> Box { if (name.isEmpty()) T("New collection", m.scale.body, m.roles.ink2, maxLines = 1); inner() } })
                }
                val ok = name.isNotBlank()
                Box(Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(m.radii.control)).background(if (ok) m.roles.raised else m.roles.field)
                    .press(enabled = ok) { scope.launch { if (store.createCollection(name, listOf(takeId))) { name = ""; inIds = (inIds ?: emptySet()) + (store.collections.value.firstOrNull()?.id ?: "") } } }
                    .padding(horizontal = 16.dp).semantics { role = Role.Button }, contentAlignment = Alignment.Center) { T("Make", m.scale.label, if (ok) m.roles.ink else m.roles.ink2, maxLines = 1) }
            }
            Box(Modifier.fillMaxWidth().heightIn(min = 48.dp).press(onClick = onClose), contentAlignment = Alignment.CenterEnd) { T("Done", m.scale.label, m.roles.link) }
        }
    }
}

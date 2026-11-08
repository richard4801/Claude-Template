package studio.muse.app.ui.screens.suite.composer

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
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
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.edit.EIc
import studio.muse.app.ui.screens.suite.applySavedRig
import studio.muse.app.ui.screens.suite.deleteSavedRig
import studio.muse.app.ui.screens.suite.loadSavedRigs
import studio.muse.app.ui.screens.suite.saveRig
import studio.muse.app.ui.screens.suite.setDefaultRig
import studio.muse.app.ui.screens.suite.soleMentioned
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.radii
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale

/**
 * Rigs (the AI suite plan, plans/ai-suite-design.md: "a strip of your saved rigs, one tap to apply"; the Mac's Setup rail
 * "Rigs" row): your saved rigs (tap to apply, with Undo on the row; delete your own), save the composer's rig under a
 * name, and make it the @-mentioned character's default rig.
 */
@Composable
internal fun ColumnScope.RigsBody(x: SheetContext) {
    val m = muse
    val store = LocalContainer.current.suite
    val scope = rememberCoroutineScope()
    val rigs by store.savedRigs.collectAsState()
    var name by remember { mutableStateOf("") }
    LaunchedEffect(Unit) { store.loadSavedRigs() }
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        if (rigs.isEmpty()) T("No saved rigs yet. Set the camera, light and look, then save them here.", m.scale.body, m.roles.ink2)
        Column {
            rigs.forEach { r ->
                Row(Modifier.fillMaxWidth().heightIn(min = 52.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.weight(1f).heightIn(min = 52.dp).press { store.applySavedRig(r); x.close() }.semantics { contentDescription = "Apply ${r.name}"; role = Role.Button },
                        contentAlignment = Alignment.CenterStart) { T(r.name, m.scale.label, m.roles.ink, maxLines = 1) }
                    if (r.mine) Box(Modifier.size(48.dp).press { scope.launch { store.deleteSavedRig(r) } }.semantics { contentDescription = "Delete ${r.name}"; role = Role.Button },
                        contentAlignment = Alignment.Center) { EIc("trash", 18.dp, m.roles.ink2) }
                }
            }
        }
        // Save the composer's rig (camera, light, look and its #moves) under a name.
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            T("Save this rig", m.scale.label, m.roles.ink)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Box(Modifier.weight(1f).heightIn(min = 48.dp).clip(RoundedCornerShape(m.radii.control)).background(m.roles.field).padding(horizontal = 12.dp), contentAlignment = Alignment.CenterStart) {
                    BasicTextField(name, { name = it.take(40) }, Modifier.fillMaxWidth().semantics { contentDescription = "Rig name" }, singleLine = true,
                        textStyle = m.scale.body.copy(color = m.roles.ink), cursorBrush = SolidColor(m.roles.accent),
                        decorationBox = { inner -> Box { if (name.isEmpty()) T("Golden hour handheld", m.scale.body, m.roles.ink2, maxLines = 1); inner() } })
                }
                val ok = name.isNotBlank()
                Box(Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(m.radii.control)).background(if (ok) m.roles.raised else m.roles.field)
                    .press(enabled = ok) { scope.launch { if (store.saveRig(name)) name = "" } }.padding(horizontal = 16.dp).semantics { role = Role.Button }, contentAlignment = Alignment.Center) {
                    T("Save", m.scale.label, if (ok) m.roles.ink else m.roles.ink2, maxLines = 1)
                }
            }
        }
        // A character's default rig: with exactly one @character in the prompt.
        store.soleMentioned()?.let { who ->
            val first = who.name.substringBefore(' ')
            Box(Modifier.fillMaxWidth().heightIn(min = 48.dp).press { scope.launch { store.setDefaultRig(who) } }.semantics { role = Role.Button }, contentAlignment = Alignment.CenterStart) {
                T("Make it $first's default", m.scale.label, m.roles.link, maxLines = 1)
            }
            T("It fills only the rows still on Auto when you @$first, and you can undo it.", m.scale.caption, m.roles.ink2)
        }
    }
}

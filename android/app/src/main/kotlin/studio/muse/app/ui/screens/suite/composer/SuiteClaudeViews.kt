package studio.muse.app.ui.screens.suite.composer

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
import studio.muse.app.data.DraftReference
import studio.muse.app.data.SuiteFeedItem
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.components.RefImage
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.StageVideo
import studio.muse.app.ui.screens.edit.EIc
import studio.muse.app.ui.screens.edit.learn.LearnChip
import studio.muse.app.ui.screens.edit.learn.LearnSegmented
import studio.muse.app.ui.screens.edit.tabular
import studio.muse.app.ui.screens.suite.SuiteAssistUi
import studio.muse.app.ui.screens.suite.SuiteFeedFilter
import studio.muse.app.ui.screens.suite.askRun
import studio.muse.app.ui.screens.suite.compare
import studio.muse.app.ui.screens.suite.confirmRun
import studio.muse.app.ui.screens.suite.deleteCollection
import studio.muse.app.ui.screens.suite.discardQueued
import studio.muse.app.ui.screens.suite.loadCollections
import studio.muse.app.ui.screens.suite.loadFeed
import studio.muse.app.ui.screens.suite.renameCollection
import studio.muse.app.ui.screens.suite.reuseSettings
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.radii
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale
// Claude in the AI Suite (SuiteClaude.kt): the approval of Claude's Generate and the draft's reference chips.

/**
 * Claude's Generate, waiting for the owner: the same one confirmation as the composer's Generate, at the price shown
 * ([SuitePending.maxUsd]); Decline leaves the composer as it is. Nothing runs without the tap.
 */
@Composable
fun SuiteClaudeApproval(a: SuiteAssistUi, onAnswer: (Boolean) -> Unit, modifier: Modifier = Modifier) {
    val m = muse
    val p = a.pending
    if (p == null && a.message == null) return
    Column(modifier.fillMaxWidth().clip(RoundedCornerShape(m.radii.container)).background(m.roles.raised).border(1.dp, m.roles.hairline, RoundedCornerShape(m.radii.container))
        .padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (p != null) {
            T("Claude wants to generate", m.scale.heading, m.roles.ink, maxLines = 1)
            T("Check the composer, then approve. It runs at this price or not at all.", m.scale.caption, m.roles.ink2)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.heightIn(min = 48.dp).press(!a.answering) { onAnswer(false) }.padding(horizontal = 12.dp).semantics { role = Role.Button }, contentAlignment = Alignment.Center) {
                    T("Decline", m.scale.label, m.roles.ink)
                }
                val label = p.label.takeIf { it.startsWith("Generate") } ?: "Generate · ${studio.muse.core.Pricing.money(p.maxUsd)}"
                Box(Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(m.radii.control)).background(if (a.answering) m.roles.field else m.roles.action)
                    .press(!a.answering) { onAnswer(true) }.padding(horizontal = 18.dp).semantics { role = Role.Button }, contentAlignment = Alignment.Center) {
                    T(if (a.answering) "Starting…" else label, m.scale.label.tabular(), if (a.answering) m.roles.ink2 else m.roles.onAction, maxLines = 1)
                }
            }
        }
        a.message?.let { T(it, m.scale.caption, m.roles.caution) }
    }
}

/** The draft's reference images as chips: the picture, its use ("Pose", "Style", "Location", "Outfit"), and remove. */
@Composable
fun SuiteReferenceChips(refs: List<DraftReference>, onRemove: (DraftReference) -> Unit, modifier: Modifier = Modifier) {
    val m = muse
    if (refs.isEmpty()) return
    Row(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        refs.forEach { r ->
            Row(Modifier.height(40.dp).clip(RoundedCornerShape(m.radii.control)).background(m.roles.field).padding(start = 4.dp)
                .semantics(mergeDescendants = true) { contentDescription = "${r.useLabel} reference${r.label?.let { ", $it" } ?: ""}" },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                studio.muse.app.ui.components.RefImage(studio.muse.app.data.ImageRef(url = r.url), Modifier.size(32.dp).clip(RoundedCornerShape(6.dp)))
                T(r.useLabel, m.scale.label, m.roles.ink, maxLines = 1)
                Box(Modifier.size(40.dp).press { onRemove(r) }.semantics { contentDescription = "Remove the ${r.useLabel.lowercase()} reference"; role = Role.Button },
                    contentAlignment = Alignment.Center) { studio.muse.app.ui.theme.Ic("x", 14.dp, m.roles.ink2) }
            }
        }
    }
}

/** The top of the Suite's Claude sheet: "Fills in this composer", and the three chips until one is used. */
@Composable
fun SuiteClaudeTop(a: SuiteAssistUi, showChips: Boolean, onChip: (String) -> Unit) {
    val m = muse
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        T(studio.muse.app.ui.screens.suite.SuiteClaudeWords.SUBTITLE, m.scale.caption, m.roles.ink2, maxLines = 1)
        if (showChips && a.pending == null) androidx.compose.foundation.layout.FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            studio.muse.app.ui.screens.suite.SuiteClaudeWords.suggestions.forEach { (label, prompt) ->
                Box(Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(m.radii.control)).border(1.dp, m.roles.hairline, RoundedCornerShape(m.radii.control))
                    .press { onChip(prompt) }.padding(horizontal = 14.dp).semantics { role = Role.Button }, contentAlignment = Alignment.Center) {
                    T(label, m.scale.label, m.roles.ink, maxLines = 1)
                }
            }
        }
    }
}

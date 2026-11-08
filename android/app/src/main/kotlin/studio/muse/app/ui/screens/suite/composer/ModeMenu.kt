package studio.muse.app.ui.screens.suite.composer

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.suite.SIc
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.scale

// AI suite: the composer title's mode menu (owner decision 2026-11-08). It replaces the big Tools sheet: the modes in
// groups, text only, no pictures and no presets (presets live in the page's presets row and its All templates). It follows
// the app theme, anchored under the title; a tap outside or Back closes it.

/** One row: a composer tool, Storyboard or Camera stage (their own screens). */
sealed interface ModeItem {
    val title: String
    data class Tool(val tool: ComposerTool) : ModeItem { override val title get() = tool.title }
    data object Storyboard : ModeItem { override val title = "Storyboard" }
    data object CameraStage : ModeItem { override val title = "Camera stage" }

    companion object {
        /** The groups, in order (the Mac's SuiteModeMenu has the same). */
        val GROUPS: List<Pair<String, List<ModeItem>>> = listOf(
            "Make" to listOf(Tool(ComposerTool.SHOT), Tool(ComposerTool.PHOTO), Tool(ComposerTool.TALKING), Tool(ComposerTool.UGC)),
            "Work from a clip" to listOf(Tool(ComposerTool.SWAP), Tool(ComposerTool.RECAST), Tool(ComposerTool.EXTEND)),
            "Plan" to listOf(Storyboard, CameraStage),
        )
    }
}

@Composable
fun BoxScope.ModeMenu(x: SheetContext) {
    val m = muse
    BackHandler(onBack = x.close)
    Box(Modifier.matchParentSize().clickable(remember { MutableInteractionSource() }, null) { x.close() }.semantics { contentDescription = "Close the modes" })
    val shape = RoundedCornerShape(12.dp)
    Column(Modifier.align(Alignment.TopStart).padding(start = if (x.wide) 20.dp else 12.dp, top = if (x.wide) 64.dp else 56.dp).width(248.dp)
        .shadow(12.dp, shape).clip(shape).background(m.t.surface).border(1.dp, m.t.line, shape)
        .clickable(remember { MutableInteractionSource() }, null) {}.padding(vertical = 4.dp)) {
        ModeItem.GROUPS.forEachIndexed { i, (title, items) ->
            if (i > 0) Box(Modifier.fillMaxWidth().padding(vertical = 4.dp).height(1.dp).background(m.t.line))
            T(title, m.scale.caption, m.t.muted, Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 2.dp), maxLines = 1)
            items.filter { it != ModeItem.CameraStage || x.owner }.forEach { item -> ModeRow(item, x) }
        }
    }
}

@Composable
private fun ModeRow(item: ModeItem, x: SheetContext) {
    val m = muse
    val on = item is ModeItem.Tool && item.tool == x.d.tool
    val soon = item is ModeItem.Tool && !item.tool.isLive(x.catalog)
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).press {
        x.close()
        when (item) {
            is ModeItem.Tool -> x.update { it.withTool(item.tool) }
            ModeItem.Storyboard -> x.onStoryboard()
            ModeItem.CameraStage -> x.onCameraStage()
        }
    }.padding(horizontal = 16.dp).semantics(mergeDescendants = true) { selected = on; role = Role.Button },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        T(item.title, m.type.body.copy(fontSize = 15.sp, fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal), m.t.ink, Modifier.weight(1f, fill = false), maxLines = 1)
        if (soon) T("Soon", m.scale.caption, m.t.muted, maxLines = 1)
        Box(Modifier.weight(1f))
        if (on) SIc("check", 18.dp, m.t.ink)
    }
}

package studio.muse.app.ui.screens.edit.learn

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.edit.EIc
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.radii
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale

// The learning editor's shared pieces (plans/learning-editor-ui.md, the owner-approved mocks): the top bar, the one filled
// action, quiet text buttons, segmented controls (never menus, so the CI click-through reaches every segment), tag chips
// (toggled by the selection outline, never a fill), the confirmation and skeleton lines.

@Composable
internal fun LearnTopBar(onBack: () -> Unit, trailing: @Composable () -> Unit = {}) {
    val m = muse
    Row(Modifier.fillMaxWidth().height(56.dp).padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(48.dp).press(onClick = onBack).semantics { contentDescription = "Back"; role = Role.Button }, contentAlignment = Alignment.Center) {
            EIc("caret-left", 22.dp, m.roles.ink)
        }
        Spacer(Modifier.weight(1f))
        trailing()
    }
}

/** The one filled action of a screen. */
@Composable
internal fun LearnPrimary(label: String, modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    val m = muse
    Box(
        modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(m.radii.control)).background(if (enabled) m.roles.action else m.roles.field)
            .press(enabled = enabled, onClick = onClick).padding(horizontal = 20.dp).semantics { role = Role.Button },
        contentAlignment = Alignment.Center,
    ) { T(label, m.scale.label, if (enabled) m.roles.onAction else m.roles.ink2, maxLines = 1) }
}

@Composable
internal fun LearnQuiet(label: String, icon: String? = null, color: Color = muse.roles.ink, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val m = muse
    Row(
        modifier.heightIn(min = 48.dp).press(onClick = onClick).padding(horizontal = 8.dp).semantics(mergeDescendants = true) { role = Role.Button },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (icon != null) EIc(icon, 20.dp, color)
        T(label, m.scale.label, color, maxLines = 1)
    }
}

/** A text link ("Make a rule", "+ Tag", "Add a note"). */
@Composable
internal fun LearnLink(label: String, color: Color = muse.roles.link, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val m = muse
    Box(modifier.heightIn(min = 48.dp).press(onClick = onClick).semantics { role = Role.Button }, contentAlignment = Alignment.CenterStart) {
        T(label, m.scale.label, color, maxLines = 1)
    }
}

@Composable
internal fun LearnSegmented(labels: List<String>, picked: Int, modifier: Modifier = Modifier, onPick: (Int) -> Unit) {
    val m = muse
    val outer = RoundedCornerShape(m.radii.control)
    val inner = RoundedCornerShape((m.radii.control - 2.dp).coerceAtLeast(0.dp))
    Row(modifier.height(44.dp).clip(outer).background(m.roles.field).padding(3.dp), verticalAlignment = Alignment.CenterVertically) {
        labels.forEachIndexed { i, l ->
            val on = i == picked
            Box(
                Modifier.weight(1f).fillMaxHeight().clip(inner).background(if (on) m.roles.raised else m.roles.field)
                    .let { if (on && m.isD) it.border(1.5.dp, m.roles.ink, inner) else it }
                    .press { onPick(i) }.semantics { selected = on; role = Role.Tab },
                contentAlignment = Alignment.Center,
            ) { T(l, m.scale.label.copy(fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal), if (on) m.roles.ink else m.roles.ink2, maxLines = 1) }
        }
    }
}

/** A tag (or area) chip: the selection outline and text when on, never a fill. [onRemove]: an × labelled "Remove tag …". */
@Composable
internal fun LearnChip(text: String, on: Boolean = false, onRemove: (() -> Unit)? = null, onClick: (() -> Unit)? = null) {
    val m = muse
    val shape = RoundedCornerShape(m.radii.chip)
    Box(Modifier.heightIn(min = 48.dp).let { if (onClick != null) it.press(onClick = onClick) else it }.semantics(mergeDescendants = true) { selected = on }, contentAlignment = Alignment.Center) {
        Row(
            Modifier.height(32.dp).clip(shape).border(1.dp, if (on) m.roles.selection else m.roles.hairline, shape).padding(start = 12.dp, end = if (onRemove != null) 2.dp else 12.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            T(text, m.scale.label, if (on) m.roles.selection else m.roles.ink, maxLines = 1)
            if (onRemove != null) Box(Modifier.size(32.dp).press(onClick = onRemove).semantics { contentDescription = "Remove tag $text"; role = Role.Button }, contentAlignment = Alignment.Center) {
                EIc("x", 16.dp, m.roles.ink2)
            }
        }
    }
}

/** A confirmation that names the action; "Keep" backs out. */
@Composable
internal fun LearnConfirm(title: String, body: String?, confirm: String, onConfirm: () -> Unit, onKeep: () -> Unit) {
    val m = muse
    Box(Modifier.fillMaxWidth().fillMaxHeight().background(Color.Black.copy(alpha = .32f)).press(onClick = onKeep), contentAlignment = Alignment.Center) {
        Column(
            Modifier.padding(32.dp).widthIn(max = 360.dp).fillMaxWidth().clip(RoundedCornerShape(m.radii.container)).background(m.roles.raised).press { }.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            T(title, m.scale.title, m.roles.ink)
            if (body != null) T(body, m.scale.caption, m.roles.ink2)
            Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End), verticalAlignment = Alignment.CenterVertically) {
                LearnQuiet("Keep", onClick = onKeep)
                Box(
                    Modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(m.radii.control)).background(m.roles.danger).press(onClick = onConfirm).padding(horizontal = 16.dp)
                        .semantics { role = Role.Button },
                    contentAlignment = Alignment.Center,
                ) { T(confirm, m.scale.label, Color.White, maxLines = 1) }
            }
        }
    }
}

/** Loading: skeleton lines shaped like the rows. */
@Composable
internal fun SkeletonRows(n: Int = 3) {
    val m = muse
    Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
        repeat(n) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Box(Modifier.fillMaxWidth(.85f).height(16.dp).clip(RoundedCornerShape(4.dp)).background(m.roles.field))
                Box(Modifier.fillMaxWidth(.4f).height(12.dp).clip(RoundedCornerShape(4.dp)).background(m.roles.field))
            }
        }
    }
}

/** What happened and how to fix it. */
@Composable
internal fun LearnError(message: String, onRetry: () -> Unit) {
    val m = muse
    Column(Modifier.fillMaxWidth().padding(top = 24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        T(message, m.scale.body, m.roles.ink2)
        LearnQuiet("Try again", onClick = onRetry)
    }
}

@Composable internal fun LearnHairline() = Box(Modifier.fillMaxWidth().height(1.dp).background(muse.roles.hairline))

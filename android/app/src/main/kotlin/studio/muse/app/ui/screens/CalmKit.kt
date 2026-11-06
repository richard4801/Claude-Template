package studio.muse.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import studio.muse.app.ui.components.FitText
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.MuseSpace
import studio.muse.app.ui.theme.MuseTypeScale
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.radii
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale

// The restyled screens' parts (plans/design-direction.md): role colours, the type scale, MuseSpace and radii only.
// No shadows except museFloat, no boxes for grouping, one `action` fill per screen. The older Kit stays for the
// screens that haven't been restyled yet.

/** The control shape (buttons, fields, segmented). */
@Composable
fun controlShape(): Shape = RoundedCornerShape(muse.radii.control)

/** The container shape (media tiles, sheets). */
@Composable
fun containerShape(): Shape = RoundedCornerShape(muse.radii.container)

/** Tabular figures in a style, for prices, durations and counts that line up. */
fun TextStyle.tabular(): TextStyle = MuseTypeScale.tabular(this)

// ---------------------------------------------------------------- buttons

/**
 * The one primary button per screen: the `action` fill, the label in `onAction`. [off] dims it but keeps it tappable so
 * it can say why. Creator Pop gives it the 2 px ink outline.
 */
@Composable
fun PrimaryButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, icon: String? = null, off: Boolean = false, busy: Boolean = false) {
    val m = muse
    val r = m.roles
    val shape = controlShape()
    Row(
        modifier.heightIn(min = 52.dp).clip(shape).background(r.action).let { if (m.isD) it.border(2.dp, r.ink, shape) else it }
            .graphicsLayer { alpha = if (off || busy) .5f else 1f }.press(onClick = onClick).padding(horizontal = MuseSpace.s5),
        horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) { Ic(icon, 20.dp, r.onAction); Spacer(Modifier.width(MuseSpace.s2)) }
        FitText(text, m.scale.label.copy(fontWeight = FontWeight.SemiBold).tabular(), r.onAction)
    }
}

/** A secondary action: a quiet `field` fill, ink label. Icon-only when [text] is empty (give it a [label]). */
@Composable
fun SecondaryButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, icon: String? = null, label: String? = null, height: Dp = 52.dp) {
    val m = muse
    val r = m.roles
    val shape = controlShape()
    Row(
        modifier.height(height).widthIn(min = height).clip(shape).background(r.field).press(onClick = onClick)
            .let { b -> if (label != null) b.semantics { contentDescription = label; role = Role.Button } else b }
            .padding(horizontal = if (text.isEmpty()) 0.dp else MuseSpace.s4),
        horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) { Ic(icon, 20.dp, r.ink); if (text.isNotEmpty()) Spacer(Modifier.width(MuseSpace.s2)) }
        if (text.isNotEmpty()) FitText(text, m.scale.label.tabular(), r.ink)
    }
}

/** A text action ("Library", "Forgot?"): the link colour, a 48 dp tall target. */
@Composable
fun TextAction(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, color: Color = muse.roles.link) {
    Box(modifier.heightIn(min = 48.dp).press(onClick = onClick).semantics { role = Role.Button }.padding(horizontal = MuseSpace.s1), contentAlignment = Alignment.Center) {
        T(text, muse.scale.label, color, maxLines = 1)
    }
}

/** An icon-only button in a bar: 24 dp glyph in a 48 dp target, always labelled for TalkBack. */
@Composable
fun BarButton(icon: String, label: String, onClick: () -> Unit, modifier: Modifier = Modifier, tint: Color = muse.roles.ink) {
    Box(modifier.size(48.dp).press(onClick = onClick).semantics { contentDescription = label; role = Role.Button }, contentAlignment = Alignment.Center) {
        Ic(icon, 24.dp, tint)
    }
}

// ---------------------------------------------------------------- structure

/** A pushed screen's bar: back, a title in `title`, and an optional action. No divider. */
@Composable
fun CalmTopBar(title: String = "", onBack: (() -> Unit)? = null, right: (@Composable () -> Unit)? = null) {
    val m = muse
    CompositionLocalProvider(androidx.compose.material3.LocalContentColor provides m.roles.ink) {
        Row(Modifier.fillMaxWidth().height(56.dp).padding(horizontal = MuseSpace.s1), verticalAlignment = Alignment.CenterVertically) {
            if (onBack != null) BarButton("back", "Back", onBack) else Spacer(Modifier.width(MuseSpace.s3))
            T(title, m.scale.title, m.roles.ink, Modifier.weight(1f).padding(horizontal = MuseSpace.s1).semantics { heading() }, maxLines = 1)
            right?.invoke()
        }
    }
}

/** The one screen title, in the theme's display face. */
@Composable
fun DisplayTitle(text: String, modifier: Modifier = Modifier) =
    T(text, muse.scale.display, muse.roles.ink, modifier.semantics { heading() })

/** A section heading in sentence case, with an optional trailing action on the same line. */
@Composable
fun Heading(text: String, modifier: Modifier = Modifier, trailing: (@Composable () -> Unit)? = null) {
    Row(modifier.fillMaxWidth().heightIn(min = if (trailing != null) 48.dp else 0.dp), verticalAlignment = Alignment.CenterVertically) {
        T(text, muse.scale.heading, muse.roles.ink, Modifier.weight(1f).semantics { heading() })
        trailing?.invoke()
    }
}

@Composable
fun Body(text: String, modifier: Modifier = Modifier, color: Color = muse.roles.ink2) = T(text, muse.scale.body, color, modifier)

@Composable
fun Caption(text: String, modifier: Modifier = Modifier, color: Color = muse.roles.ink2, maxLines: Int = Int.MAX_VALUE) =
    T(text, muse.scale.caption, color, modifier, maxLines = maxLines)

/** A field with its sentence-case label above it. */
@Composable
fun Labeled(label: String, modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
        T(label, muse.scale.label, muse.roles.ink)
        content()
    }
}

/**
 * One row of a list: title, an optional one-line meta under it, and a trailing control. 56 dp tall at least, grouped by
 * space (no box, no divider).
 */
@Composable
fun RowItem(title: String, sub: String? = null, onClick: (() -> Unit)? = null, modifier: Modifier = Modifier, lead: (@Composable () -> Unit)? = null,
    titleColor: Color = muse.roles.ink, trailing: (@Composable RowScope.() -> Unit)? = null) {
    val m = muse
    Row(
        modifier.fillMaxWidth().heightIn(min = 56.dp).let { if (onClick != null) it.press(onClick = onClick) else it }.padding(vertical = MuseSpace.s2),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(MuseSpace.s3),
    ) {
        lead?.invoke()
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(title, m.scale.body, titleColor)
            if (sub != null) Caption(sub)
        }
        trailing?.invoke(this)
    }
}

/** The "go further" mark at the end of a row. */
@Composable
fun Chevron() = Ic("chev", 16.dp, muse.roles.ink2)

/** A value at the end of a row (a price, a count): tabular, secondary ink. */
@Composable
fun RowValue(text: String, color: Color = muse.roles.ink2) = T(text, muse.scale.caption.tabular(), color, maxLines = 1)

/** The bottom action area: solid canvas, the 16 dp gutter, above the navigation bar. */
@Composable
fun BoxScope.ActionDock(content: @Composable RowScope.() -> Unit) {
    Row(
        Modifier.align(Alignment.BottomCenter).fillMaxWidth().background(muse.roles.canvas).navigationBarsPadding()
            .padding(start = MuseSpace.gutter, end = MuseSpace.gutter, top = MuseSpace.s3, bottom = MuseSpace.s4),
        horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2), verticalAlignment = Alignment.CenterVertically, content = content,
    )
}

// ---------------------------------------------------------------- choices

/** A chip: quiet `field` fill; the selected one gets the selection outline (ink in Creator Pop). 48 dp target. */
@Composable
fun ChoiceChip(text: String, on: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val m = muse
    val shape = RoundedCornerShape(m.radii.chip)
    Box(modifier.heightIn(min = 48.dp).press(onClick = onClick).semantics { role = Role.RadioButton }, contentAlignment = Alignment.Center) {
        Box(
            Modifier.height(36.dp).clip(shape).background(m.roles.field).let { if (on) it.border(2.dp, m.roles.selection, shape) else it }.padding(horizontal = MuseSpace.s3),
            contentAlignment = Alignment.Center,
        ) { T(text, m.scale.label, m.roles.ink, maxLines = 1, weight = if (on) FontWeight.SemiBold else null) }
    }
}

/** A segmented control: a `field` track; the chosen segment is `raised` with the selection outline. */
@Composable
fun Segmented(options: List<Pair<String, String>>, selected: String, onSelect: (String) -> Unit, modifier: Modifier = Modifier) {
    val m = muse
    val r = m.roles
    val outer = controlShape()
    val inner = RoundedCornerShape((m.radii.control - 2.dp).coerceAtLeast(2.dp))
    Row(modifier.fillMaxWidth().clip(outer).background(r.field).padding(2.dp)) {
        options.forEach { (k, label) ->
            val on = k == selected
            Box(
                Modifier.weight(1f).height(44.dp).clip(inner).let { if (on) it.background(r.raised).border(2.dp, r.selection, inner) else it }
                    .press { onSelect(k) }.semantics { role = Role.RadioButton }.padding(horizontal = MuseSpace.s1),
                contentAlignment = Alignment.Center,
            ) { FitText(label, m.scale.label.copy(fontWeight = if (on) FontWeight.SemiBold else FontWeight.Medium), if (on) r.ink else r.ink2) }
        }
    }
}

// ---------------------------------------------------------------- states

/** A loading block shaped like what it stands for (a tile, a line). Static: no shimmer. */
@Composable
fun Skeleton(modifier: Modifier, shape: Shape = controlShape()) = Box(modifier.clip(shape).background(muse.roles.field))

/** Lines of text still loading. */
@Composable
fun SkeletonLines(lines: Int = 2, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
        repeat(lines) { i -> Skeleton(Modifier.fillMaxWidth(if (i == lines - 1) .55f else .85f).height(14.dp), RoundedCornerShape(4.dp)) }
    }
}

/** Empty: what this is, and one action to start (primary unless the screen already has one). */
@Composable
fun EmptyState(title: String, body: String, action: String? = null, onAction: () -> Unit = {}, primary: Boolean = true, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth().padding(vertical = MuseSpace.s4), verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
        T(title, muse.scale.title, muse.roles.ink)
        Body(body)
        if (action != null) {
            Spacer(Modifier.height(MuseSpace.s2))
            if (primary) PrimaryButton(action, onAction, Modifier.fillMaxWidth()) else SecondaryButton(action, onAction, Modifier.fillMaxWidth())
        }
    }
}

/** Error: what happened and how to fix it, with one way to try again. */
@Composable
fun ErrorState(title: String, body: String, action: String? = "Try again", onAction: () -> Unit = {}, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth().padding(vertical = MuseSpace.s4), verticalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
        T(title, muse.scale.title, muse.roles.ink)
        Body(body)
        if (action != null) { Spacer(Modifier.height(MuseSpace.s2)); SecondaryButton(action, onAction, Modifier.fillMaxWidth(), icon = "retry") }
    }
}

enum class NoticeTone { NEUTRAL, POSITIVE, CAUTION, DANGER }

/** A short note in the flow of the screen: no box, the state colour only when it is a state. */
@Composable
fun Notice(text: String, modifier: Modifier = Modifier, tone: NoticeTone = NoticeTone.NEUTRAL) {
    val r = muse.roles
    val c = when (tone) { NoticeTone.NEUTRAL -> r.ink2; NoticeTone.POSITIVE -> r.positive; NoticeTone.CAUTION -> r.caution; NoticeTone.DANGER -> r.danger }
    val icon = when (tone) { NoticeTone.CAUTION, NoticeTone.DANGER -> "shield"; NoticeTone.POSITIVE -> "check"; NoticeTone.NEUTRAL -> null }
    Row(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(MuseSpace.s2)) {
        if (icon != null) Ic(icon, 16.dp, c, Modifier.padding(top = 1.dp))
        T(text, muse.scale.caption, if (tone == NoticeTone.NEUTRAL) r.ink2 else c, Modifier.weight(1f))
    }
}

/** Progress: ink on the field track, 4 dp. */
@Composable
fun ProgressLine(progress: Float, modifier: Modifier = Modifier) =
    studio.muse.app.ui.components.Bar(progress, modifier, muse.roles.ink, 4.dp, muse.roles.field)

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
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
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
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.suite.SIc
import studio.muse.app.ui.theme.MuseTheme
import studio.muse.app.ui.theme.ThemeId
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.scale
import studio.muse.app.ui.theme.MuseSpace
import studio.muse.app.ui.theme.MuseRoles

// AI suite (workstream 1): the one picker shell (plans/video-composer.md "The picker shell"), always dark whatever the app
// theme. Phone: a bottom sheet of about 85% height with a grab handle, title, Reset all and ×, sub-steps as a segmented
// control; tablet and wider: a centred modal with the sub-steps in a left rail (a dot marks a step with a value). Choices
// apply instantly: there is no OK button.

/** Which picker is open. [tab] is its sub-step; [token] the prompt token a token sheet edits. */
enum class SheetKind { CAMERA, STYLE, LOOK, LIGHTING, REFERENCES, SETTINGS, TOOLS, CHARACTER, TOKEN, PEOPLE, NEW_LOCATION, VIDEO }

data class ComposerSheet(val kind: SheetKind, val tab: String = "", val token: Long = 0)

/** One sub-step of a picker: its key, label and whether it holds a value (the rail's dot). */
data class SheetTab(val key: String, val label: String, val set: Boolean = false)

/**
 * The shell. [tabs] empty = no segmented control. [onReset] null hides Reset all. [footer] sits under the scrolling
 * content (the Look toggle, Settings' Generate). [content] fills the rest and scrolls itself.
 */
@Composable
fun BoxScope.PickerShell(
    title: String, wide: Boolean, onClose: () -> Unit, tabs: List<SheetTab> = emptyList(), tab: String = "", onTab: (String) -> Unit = {},
    onReset: (() -> Unit)? = null, heightFraction: Float = .85f, footer: (@Composable ColumnScope.() -> Unit)? = null,
    /** A dim note after the title ("Camera · Setup", as in the drum prototype). */
    titleNote: String? = null, content: @Composable ColumnScope.() -> Unit,
) {
    BackHandler(onBack = onClose)
    // The dimmed page: a tap outside closes the picker.
    Box(Modifier.matchParentSize().background(Color.Black.copy(alpha = .55f)).clickable(remember { MutableInteractionSource() }, null) { onClose() }
        .semantics { contentDescription = "Close $title" })
    MuseTheme(ThemeId.B) {
        val m = muse
        if (wide) {
            Box(Modifier.matchParentSize().padding(24.dp), contentAlignment = Alignment.Center) {
                Column(Modifier.widthIn(max = 860.dp).fillMaxWidth().heightIn(max = 800.dp).fillMaxHeight().clip(RoundedCornerShape(18.dp)).background(m.t.bg)
                    .border(1.dp, m.t.line, RoundedCornerShape(18.dp)).clickable(remember { MutableInteractionSource() }, null) {}) {
                    Header(title, titleNote, onReset, onClose, Modifier.padding(start = 24.dp, end = 14.dp).height(62.dp))
                    Box(Modifier.fillMaxWidth().height(1.dp).background(m.t.line))
                    Row(Modifier.weight(1f)) {
                        if (tabs.isNotEmpty()) {
                            Column(Modifier.width(184.dp).fillMaxHeight().padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                tabs.forEach { t -> RailItem(t, t.key == tab) { onTab(t.key) } }
                            }
                            Box(Modifier.width(1.dp).fillMaxHeight().background(m.t.line))
                        }
                        Column(Modifier.weight(1f).fillMaxHeight()) {
                            Column(Modifier.weight(1f).padding(top = 8.dp)) { content() }
                            footer?.let { f -> Column(Modifier.fillMaxWidth().background(m.t.surface).padding(horizontal = 20.dp, vertical = 10.dp)) { f() } }
                        }
                    }
                }
            }
        } else {
            Column(Modifier.align(Alignment.BottomCenter).fillMaxWidth().fillMaxHeight(heightFraction).clip(RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp))
                .background(m.t.bg).clickable(remember { MutableInteractionSource() }, null) {}) {
                Box(Modifier.fillMaxWidth().padding(top = 9.dp, bottom = 2.dp), contentAlignment = Alignment.Center) {
                    Box(Modifier.size(40.dp, 4.dp).clip(RoundedCornerShape(2.dp)).background(Color(0xFF3A3F43)))
                }
                Header(title, titleNote, onReset, onClose, Modifier.padding(start = 20.dp, end = 14.dp).height(56.dp))
                if (tabs.isNotEmpty()) Segmented(tabs, tab, onTab, Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
                Column(Modifier.weight(1f).padding(top = 8.dp)) { content() }
                footer?.let { f -> Column(Modifier.fillMaxWidth().background(m.t.surface).navigationBarsPadding().padding(horizontal = 16.dp, vertical = 10.dp)) { f() } }
                    ?: Spacer(Modifier.navigationBarsPadding())
            }
        }
    }
}

@Composable
private fun Header(title: String, note: String?, onReset: (() -> Unit)?, onClose: () -> Unit, modifier: Modifier) {
    val m = muse
    val bag = MuseRoles.bag
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        // Workstream 4 (design direction): sentence-case title on the type scale, no caps tracking.
        Row(Modifier.weight(1f), verticalAlignment = Alignment.Bottom) {
            T(title, m.scale.title, bag.ink, maxLines = 1)
            if (note != null) T(" · $note", m.scale.title.copy(fontWeight = FontWeight.Normal), bag.ink2, maxLines = 1)
        }
        if (onReset != null) {
            Box(Modifier.heightIn(min = 48.dp).press(onClick = onReset).semantics { contentDescription = "Reset all"; role = Role.Button }, contentAlignment = Alignment.Center) {
                Row(Modifier.padding(horizontal = MuseSpace.s2), verticalAlignment = Alignment.CenterVertically) {
                    T("Reset all", m.scale.label, bag.ink2, maxLines = 1)
                }
            }
        }
        Box(Modifier.size(48.dp).press(onClick = onClose).semantics { contentDescription = "Close"; role = Role.Button }, contentAlignment = Alignment.Center) {
            SIc("close", 24.dp, bag.ink)
        }
    }
}

/** The phone's sub-steps: a segmented control (Setup · Angle · Movement). */
@Composable
fun Segmented(tabs: List<SheetTab>, tab: String, onTab: (String) -> Unit, modifier: Modifier = Modifier, height: Dp = 40.dp) {
    val m = muse
    Row(modifier.fillMaxWidth().clip(RoundedCornerShape(11.dp)).background(m.t.surface2).padding(3.dp), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
        tabs.forEach { t ->
            val on = t.key == tab
            Box(Modifier.weight(1f).heightIn(min = 48.dp).press { onTab(t.key) }.semantics { selected = on; role = Role.Tab }, contentAlignment = Alignment.Center) {
                Box(Modifier.fillMaxWidth().height(height).clip(RoundedCornerShape(8.dp)).background(if (on) m.t.ink else Color.Transparent), contentAlignment = Alignment.Center) {
                    T(t.label, m.type.body.copy(fontSize = 14.sp, fontWeight = FontWeight.SemiBold), if (on) Color(0xFF0D0E0F) else m.t.muted, maxLines = 1, align = TextAlign.Center)
                }
            }
        }
    }
}

@Composable
private fun RailItem(t: SheetTab, on: Boolean, onClick: () -> Unit) {
    val m = muse
    Row(Modifier.fillMaxWidth().height(48.dp).clip(RoundedCornerShape(10.dp)).background(if (on) m.t.surface2 else Color.Transparent).press(onClick = onClick)
        .semantics { selected = on; role = Role.Tab }.padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        T(t.label, m.type.body.copy(fontSize = 15.sp, fontWeight = FontWeight.SemiBold), if (on) m.t.ink else m.t.muted, Modifier.weight(1f), maxLines = 1)
        if (t.set) Box(Modifier.size(6.dp).clip(CircleShape).background(m.t.accent))
    }
}

/** A section heading in the camera bag, sentence case, with an optional note on the right. */
@Composable
fun SheetLabel(text: String, right: String? = null, modifier: Modifier = Modifier) {
    val m = muse
    val bag = MuseRoles.bag
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        T(text, m.scale.heading, bag.ink, Modifier.weight(1f), maxLines = 1)
        if (right != null) T(right, m.scale.caption, bag.ink2, maxLines = 1)
    }
}

/**
 * Was a check badge on a selected card. The design direction keeps one selection mark per control (the outline from
 * [picked]), so it draws nothing; the call sites go in the next restyle pass.
 */
@Suppress("UnusedReceiverParameter")
@Composable
fun BoxScope.CheckBadge() = Unit

/** The one selection mark on a card: a 2 dp outline in the bag's selection colour ([accent] is kept for old call sites). */
@Suppress("UNUSED_PARAMETER")
fun Modifier.picked(on: Boolean, accent: Color, radius: Dp = 10.dp): Modifier =
    if (on) this.border(2.dp, MuseRoles.bag.selection, RoundedCornerShape(radius + 3.dp)).padding(3.dp) else this.padding(3.dp)

/** Fills the remaining height of a sheet with a Column that scrolls. */
@Composable
fun ColumnScope.SheetScroll(content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()), content = content)
}

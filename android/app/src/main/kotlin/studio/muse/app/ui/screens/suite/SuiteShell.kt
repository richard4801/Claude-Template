package studio.muse.app.ui.screens.suite

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.flow.MutableStateFlow
import studio.muse.app.ui.LocalNav
import studio.muse.app.ui.Routes
import studio.muse.app.ui.components.MenuItem
import studio.muse.app.ui.components.MoreMenu
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.theme.LocalMuse
import studio.muse.app.ui.theme.MuseRoles
import studio.muse.app.ui.theme.ThemeId
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.radii
import studio.muse.app.ui.theme.roles
import studio.muse.app.ui.theme.scale

// The Video suite redesign on Android (owner-approved 2026-11-14; plans/design/suite-redesign/, same decisions as the Mac's
// SuiteShell.swift): one header on every Suite screen ("Video suite" and the tabs Shot, Photo, Swap, Storyboard, Recreate,
// with More for the tools that have no tab), the stage on the field tone, the panels raised with a hairline, pills on the
// field tone. Camera Body uses the lifted dark tokens measured off the approved dark frame (DesignTokens.suite).

/** The Suite's tokens: Camera Body's lifted dark on the Suite's screens; every other theme unchanged. */
@Composable
fun SuiteTokens(content: @Composable () -> Unit) {
    val m = muse
    if (m.id != ThemeId.B || m.rolesOverride != null) { content(); return }
    val r = MuseRoles.suite(ThemeId.B)
    // The older tokens follow too, so screens not yet on roles (ScreenBox's background, cards) get the same tones.
    val t = m.t.copy(bg = r.canvas, surface = r.raised, surface2 = r.field, line = r.hairline)
    CompositionLocalProvider(LocalMuse provides m.copy(t = t, rolesOverride = r)) { content() }
}

/** Recreate opens inside Edit; the Recreate tab asks Edit to start there (EditSuiteScreen reads it once). */
object SuiteNavFlags {
    val openRecreate = MutableStateFlow(false)
}

enum class SuiteTab(val title: String, val icon: String) {
    SHOT("Shot", "video-camera"), PHOTO("Photo", "camera"), SWAP("Swap", "arrows-left-right"),
    STORYBOARD("Storyboard", "squares-four"), RECREATE("Recreate", "arrows-clockwise");

    fun open(go: (String) -> Unit) = when (this) {
        SHOT -> go(Routes.SUITE_SHOT)
        PHOTO -> go(Routes.SUITE_PHOTO)
        SWAP -> go(Routes.SUITE_SWAP)
        STORYBOARD -> go(Routes.SUITE_STORYBOARD)
        RECREATE -> { SuiteNavFlags.openRecreate.value = true; go(Routes.EDIT) }
    }

    companion object {
        /** The tab of a composer tool ("shot", "photo", "swap", "recast"); null for the tools in More. */
        fun ofTool(tool: String?): SuiteTab? = when (tool) {
            "shot" -> SHOT; "photo" -> PHOTO; "swap", "recast" -> SWAP; else -> null
        }
    }
}

/**
 * "Video suite", the tabs and the screen's own quiet controls. Phones: the title row with [trailing], the tabs scrolling
 * under it; wide screens: one row.
 */
@Composable
fun SuiteHeader(current: SuiteTab?, modifier: Modifier = Modifier, trailing: @Composable RowScope.() -> Unit = {}) {
    val m = muse
    val nav = LocalNav.current
    BoxWithConstraints(modifier.fillMaxWidth()) {
        val wide = maxWidth >= 720.dp
        val title = @Composable {
            Box(Modifier.heightIn(min = 48.dp).press { nav.go(Routes.SUITE) }.semantics { role = Role.Button; contentDescription = "Video suite home" },
                contentAlignment = Alignment.CenterStart) {
                T("Video suite", m.scale.display, m.roles.ink, maxLines = 1)
            }
        }
        if (wide) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                title()
                SuiteTabs(current) { nav.go(it) }
                Spacer(Modifier.weight(1f))
                Row(verticalAlignment = Alignment.CenterVertically, content = trailing)
            }
        } else {
            Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.weight(1f)) { title() }
                    Row(verticalAlignment = Alignment.CenterVertically, content = trailing)
                }
                Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())) { SuiteTabs(current) { nav.go(it) } }
            }
        }
    }
}

/** The tabs on the field track (the open one raised), then More. */
@Composable
fun SuiteTabs(current: SuiteTab?, go: (String) -> Unit) {
    val m = muse
    val shape = RoundedCornerShape(m.radii.control + 2.dp)
    Row(Modifier.clip(shape).background(m.roles.field).padding(3.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        SuiteTab.entries.forEach { tab ->
            val on = tab == current
            val inner = RoundedCornerShape(m.radii.control)
            Row(Modifier.heightIn(min = 40.dp).clip(inner).background(if (on) m.roles.raised else androidx.compose.ui.graphics.Color.Transparent)
                .let { if (on && !m.isA) it.border(1.dp, m.roles.hairline, inner) else it }
                .press { tab.open(go) }.padding(horizontal = 11.dp)
                .semantics(mergeDescendants = true) { role = Role.Tab; selected = on; contentDescription = tab.title },
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                SIc(tab.icon, 16.dp, if (on) m.roles.ink else m.roles.ink2)
                T(tab.title, m.scale.label.copy(fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal), if (on) m.roles.ink else m.roles.ink2, maxLines = 1)
            }
        }
        // The tools without a tab: nothing the old mode tiles reached is lost.
        Box(Modifier.heightIn(min = 40.dp), contentAlignment = Alignment.Center) {
            MoreMenu(listOf(
                MenuItem("arrow-line-right", "Extend & upscale") { go(Routes.suiteCompose("extend")) },
                MenuItem("users-three", "Recast") { go(Routes.suiteCompose("recast")) },
                MenuItem("microphone", "Talking") { go(Routes.suiteCompose("talking")) },
                MenuItem("bag", "UGC ad") { go(Routes.suiteCompose("ugc")) },
                MenuItem("cube", "Camera stage") { go(Routes.CAMERA_STAGE) },
            ), tint = m.roles.ink2, icon = "dots-three")
        }
    }
}

// ---------------------------------------------------------------- surfaces

/** The stage: media on the field tone (the frame is the hero, no border). */
@Composable
fun Modifier.suiteStage(): Modifier {
    val m = muse
    val shape = RoundedCornerShape(m.radii.container)
    return clip(shape).background(m.roles.field)
}

/** A panel: raised, with a hairline edge. */
@Composable
fun Modifier.suitePanel(): Modifier {
    val m = muse
    val shape = RoundedCornerShape(m.radii.container)
    return clip(shape).background(m.roles.raised).border(1.dp, m.roles.hairline, shape)
}

/** A pill: icon and value on the field tone. */
@Composable
fun SuitePill(icon: String, value: String, modifier: Modifier = Modifier, onClick: (() -> Unit)? = null) {
    val m = muse
    val shape = RoundedCornerShape(m.radii.control)
    Row(modifier.heightIn(min = 40.dp).clip(shape).background(m.roles.field).let { if (onClick != null) it.press(onClick = onClick) else it }
        .padding(horizontal = 10.dp).semantics(mergeDescendants = true) { if (onClick != null) role = Role.Button },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        SIc(icon, 14.dp, m.roles.ink2)
        T(value, m.scale.label.copy(fontWeight = FontWeight.Medium), m.roles.ink, maxLines = 1)
    }
}

/**
 * Owner decision 5: beside Generate, "Test render" with its switch, shown only when this render is a free test render
 * (the server's SUITE_MODE=mock; there is no per-render test mode, so it is never a switch that changes nothing). Generate
 * then reads "Test render · Free".
 */
@Composable
fun SuiteTestRenderSwitch(free: Boolean, compact: Boolean = false) {
    if (!free) return
    val m = muse
    Row(Modifier.semantics(mergeDescendants = true) { contentDescription = "Test render on: renders are free test patterns" },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        if (!compact) T("Test render", m.scale.label, m.roles.ink, maxLines = 1)
        Switch(checked = true, onCheckedChange = null, enabled = false, modifier = Modifier.size(width = 44.dp, height = 28.dp),
            colors = SwitchDefaults.colors(disabledCheckedTrackColor = m.roles.action.copy(alpha = .55f), disabledCheckedThumbColor = m.roles.onAction))
    }
}

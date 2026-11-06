package studio.muse.app.ui.screens.suite

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.update
import studio.muse.app.data.SuiteEstimate
import studio.muse.app.data.SuiteRigFix
import studio.muse.app.data.SuiteRigWarning
import studio.muse.app.data.SuiteShotRequest
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.components.MenuItem
import studio.muse.app.ui.components.MuseMenu
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.suite.composer.RigDismissals
import studio.muse.app.ui.screens.suite.composer.RigFixes
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse

// AI suite (workstream 3): the rig check's warning row, just above the composer's bottom bar (plans/video-composer.md
// "Rig check"). One line per warning: a severity dot, the reason and the one-tap fix; "+N" opens the rest; × hides a
// warning until the choices change. It never blocks or dims Generate.

/**
 * The composer's rig warnings: the estimate's `rig` when there is an estimate (kept while the next one loads, so the row
 * doesn't flicker), else POST /v1/suite/rig-check when the estimate failed or couldn't run ([estFailed]). [req] null =
 * no rig check (a tool without a prompt, an add-on render, a tool that isn't live).
 */
@Composable
fun rememberRigWarnings(req: SuiteShotRequest?, est: SuiteEstimate?, estFailed: Boolean): List<SuiteRigWarning> {
    val store = LocalContainer.current.suite
    val fallback = produceState(emptyList<SuiteRigWarning>(), req, estFailed) {
        if (req == null || !estFailed) return@produceState
        delay(300)
        value = store.rigCheck(req)
    }
    return when {
        req == null -> emptyList()
        est != null -> est.rig
        estFailed -> fallback.value
        else -> emptyList()
    }
}

/** The composer's row, wired to the store: a fix changes the choices like a picker tap; × hides until they change. */
@Composable
fun ComposerRigRow(req: SuiteShotRequest?, est: SuiteEstimate?, estFailed: Boolean, wide: Boolean, modifier: Modifier = Modifier) {
    val store = LocalContainer.current.suite
    val rig = rememberRigWarnings(req, est, estFailed)
    val d by store.composer.collectAsState()
    val dismissed by store.rigDismissed.collectAsState()
    val cat by store.catalog.collectAsState()
    val shown = dismissed.visible(rig, RigDismissals.choicesOf(d))
    RigCheckRow(shown, wide, modifier = modifier,
        onFix = { w, f ->
            val next = RigFixes.apply(store.composer.value, f.patch, cat?.camera ?: studio.muse.app.data.CameraCatalog())
            store.composer.value = next
            // Fixed: gone at once (the estimate that follows the new choices confirms it), back if the choices change again.
            store.rigDismissed.update { it.dismiss(w, RigDismissals.choicesOf(next)) }
        },
        onDismiss = { w -> store.rigDismissed.update { it.dismiss(w, RigDismissals.choicesOf(store.composer.value)) } })
}

/**
 * The row itself. Phone ([wide] false): the reason takes the full width (up to two lines) with the fix, "+N" and × under
 * it; the alt goes in the ⋯ overflow (with Hide).
 * Wide: one line, the alt and × beside the fix. Animates in and out; every tap target is at least 48 dp.
 */
@Composable
fun RigCheckRow(
    warnings: List<SuiteRigWarning>,
    wide: Boolean,
    onFix: (SuiteRigWarning, SuiteRigFix) -> Unit,
    onDismiss: (SuiteRigWarning) -> Unit,
    modifier: Modifier = Modifier,
) {
    val m = muse
    // While the row animates out, it keeps showing what it showed last.
    var last by remember { mutableStateOf(warnings) }
    LaunchedEffect(warnings) { if (warnings.isNotEmpty()) last = warnings }
    val list = warnings.ifEmpty { last }
    var expanded by remember { mutableStateOf(false) }
    LaunchedEffect(list.size) { if (list.size <= 1) expanded = false }
    AnimatedVisibility(warnings.isNotEmpty(), modifier.fillMaxWidth(),
        enter = fadeIn(tween(180)) + expandVertically(tween(220), expandFrom = Alignment.Bottom),
        exit = fadeOut(tween(150)) + shrinkVertically(tween(200), shrinkTowards = Alignment.Bottom)) {
        val shape = RoundedCornerShape(if (m.isA) 0.dp else 10.dp)
        // A tinted panel with no outline: it sits between the slot cards and the bar, which already carry borders.
        Column(Modifier.fillMaxWidth().clip(shape).background(m.t.surface2).animateContentSize(tween(200))) {
            val rows = if (expanded) list else list.take(1)
            rows.forEachIndexed { i, w ->
                key(RigDismissals.key(w)) {
                    if (i > 0) Box(Modifier.fillMaxWidth().padding(start = 12.dp).heightIn(min = 1.dp, max = 1.dp).background(m.t.line))
                    val toggle = if (i == 0 && list.size > 1) (if (expanded) "Less" else "+${list.size - 1}") else null
                    RigLine(w, wide, toggle, { expanded = !expanded }, onFix, onDismiss)
                }
            }
        }
    }
}


@Composable
private fun RigLine(
    w: SuiteRigWarning, wide: Boolean, toggle: String?, onToggle: () -> Unit,
    onFix: (SuiteRigWarning, SuiteRigFix) -> Unit, onDismiss: (SuiteRigWarning) -> Unit,
) {
    val m = muse
    val reasonStyle = m.type.body.copy(fontSize = 13.5.sp, lineHeight = 17.sp)
    val reasonSemantics = Modifier.semantics { contentDescription = (if (w.tip) "Tip: " else "Warning: ") + w.reason }
    if (wide) Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(start = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        SeverityDot(w.tip)
        Spacer(Modifier.width(10.dp))
        T(w.reason, reasonStyle, m.t.ink, Modifier.weight(1f).then(reasonSemantics), maxLines = 1)
        RigActions(w, wide = true, toggle, onToggle, onFix, onDismiss)
    } else Column(Modifier.fillMaxWidth()) {
        // Phone: the reason gets the full width (up to two lines); the fix, "+N" and × / ⋯ sit under it.
        Row(Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 10.dp), verticalAlignment = Alignment.Top) {
            Box(Modifier.padding(top = 4.dp)) { SeverityDot(w.tip) }
            Spacer(Modifier.width(10.dp))
            T(w.reason, reasonStyle, m.t.ink, Modifier.weight(1f).then(reasonSemantics), maxLines = 2)
        }
        Row(Modifier.fillMaxWidth().padding(start = 23.dp), verticalAlignment = Alignment.CenterVertically) {
            RigActions(w, wide = false, toggle, onToggle, onFix, onDismiss)
        }
    }
}

/** The fix (and on wide screens the alt), "+N" / "Less", and × (phone with an alt: ⋯ holding the alt and Hide). */
@Composable
private fun androidx.compose.foundation.layout.RowScope.RigActions(
    w: SuiteRigWarning, wide: Boolean, toggle: String?, onToggle: () -> Unit,
    onFix: (SuiteRigWarning, SuiteRigFix) -> Unit, onDismiss: (SuiteRigWarning) -> Unit,
) {
    val m = muse
    FixButton(w.fix.label, primary = true, maxWidth = 240) { onFix(w, w.fix) }
    val alt = w.alt
    if (wide && alt != null) FixButton(alt.label, primary = false, maxWidth = 200) { onFix(w, alt) }
    if (!wide) Spacer(Modifier.weight(1f))
    if (toggle != null) Box(Modifier.heightIn(min = 48.dp).widthIn(min = 48.dp).press(onClick = onToggle)
        .semantics { role = Role.Button; contentDescription = if (toggle == "Less") "Show fewer warnings" else "Show ${toggle.drop(1)} more warnings" },
        contentAlignment = Alignment.Center) {
        T(toggle, m.type.mono.copy(fontSize = 12.sp, fontWeight = FontWeight.Medium), m.t.muted, Modifier.padding(horizontal = 6.dp), maxLines = 1)
    }
    if (wide || alt == null) Box(Modifier.size(48.dp).press { onDismiss(w) }.semantics { role = Role.Button; contentDescription = "Hide this warning" }, contentAlignment = Alignment.Center) {
        SIc("close", 16.dp, m.t.muted)
    } else {
        var open by remember { mutableStateOf(false) }
        Box {
            Box(Modifier.size(48.dp).press { open = true }.semantics { role = Role.Button; contentDescription = "More fixes" }, contentAlignment = Alignment.Center) {
                Ic("more", 18.dp, m.t.muted)
            }
            MuseMenu(open, { open = false }, listOf(
                MenuItem("check", alt.label) { onFix(w, alt) },
                MenuItem("eye", "Hide this warning") { onDismiss(w) },
            ))
        }
    }
}

/** Warn: a filled dot in the theme's warning colour. Tip: a hollow ring in the muted ink (tells apart even where warn = accent). */
@Composable
private fun SeverityDot(tip: Boolean) {
    val m = muse
    val mod = Modifier.size(9.dp).clip(CircleShape)
    Box(if (tip) mod.border(1.6.dp, m.t.muted, CircleShape) else mod.background(m.t.warn))
}

@Composable
private fun FixButton(label: String, primary: Boolean, maxWidth: Int, onClick: () -> Unit) {
    val m = muse
    Box(Modifier.heightIn(min = 48.dp).widthIn(min = 48.dp, max = maxWidth.dp).press(onClick = onClick).semantics { role = Role.Button; contentDescription = label },
        contentAlignment = Alignment.Center) {
        T(label, m.type.body.copy(fontSize = 13.5.sp, fontWeight = if (primary) FontWeight.SemiBold else FontWeight.Medium),
            if (primary) m.link else m.t.muted, Modifier.padding(horizontal = 8.dp), maxLines = 1)
    }
}


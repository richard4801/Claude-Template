package studio.muse.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import studio.muse.app.data.Model
import studio.muse.app.data.Outfit
import studio.muse.app.ui.LocalContainer
import studio.muse.app.ui.components.Ink
import studio.muse.app.ui.components.MenuItem
import studio.muse.app.ui.components.RefImage
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.theme.muse

/** Full-screen themed background, content below the status bar. */
@Composable
fun ScreenBox(statusPad: Boolean = true, bg: Color = muse.t.bg, content: @Composable BoxScope.() -> Unit) {
    Box(Modifier.fillMaxSize().background(bg).let { if (statusPad) it.statusBarsPadding() else it }, content = content)
}

/** Dashed outline (`border: dashed`). */
fun Modifier.dashed(color: Color, radius: Dp, width: Dp = 1.dp): Modifier = drawBehind {
    drawRoundRect(color, cornerRadius = CornerRadius(radius.toPx()), style = Stroke(width.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(6.dp.toPx(), 4.dp.toPx()))))
}

/** Outfit tile (`.ofit`): 74 wide, image + name, ring when selected. */
@Composable
fun OutfitTile(outfit: Outfit, on: Boolean, onClick: () -> Unit, width: Dp = 74.dp, imgH: Dp = 78.dp) {
    val m = muse
    val shape = RoundedCornerShape(m.t.r * .6f)
    Column(Modifier.width(width).press(onClick = onClick), verticalArrangement = Arrangement.spacedBy(4.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Box(
            Modifier.fillMaxWidth().height(imgH).let { if (on) it.border(2.dp, m.t.accent, shape) else it }.clip(shape)
                .let { if (m.isD) it.border(2.5.dp, Ink, shape) else it },
        ) { RefImage(outfit.front, Modifier.fillMaxSize()) }
        T(outfit.name, m.type.tiny.copy(fontSize = 11.5.sp), m.t.muted, align = TextAlign.Center, maxLines = 1)
    }
}

/** "+" tile that opens the outfit-set generator. */
@Composable
fun AddOutfitTile(onClick: () -> Unit, label: Boolean = true, width: Dp = 74.dp, imgH: Dp = 78.dp) {
    val m = muse
    Column(Modifier.width(width).press(onClick = onClick), verticalArrangement = Arrangement.spacedBy(4.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.fillMaxWidth().height(imgH).dashed(m.t.line, m.t.r * .6f, m.t.stroke), contentAlignment = Alignment.Center) {
            T("+", m.type.body.copy(fontSize = 26.sp), m.t.muted)
        }
        if (label) T("Add outfit", m.type.tiny.copy(fontSize = 11.5.sp), m.t.muted, maxLines = 1)
    }
}

/** Model avatar tile with an initial for drafts. */
@Composable
fun ModelInitial(model: Model, modifier: Modifier = Modifier, size: Float = 42f) {
    val m = muse
    Box(modifier.background(m.t.surface2), contentAlignment = Alignment.Center) { T(model.initial, m.type.wm.copy(fontSize = size.sp), m.t.muted) }
}

/** The profile ⋯ menu (app.js MENUS.profile). */
@Composable
fun profileMenu(onSheet: () -> Unit, onOutfit: () -> Unit, onLora: () -> Unit = {}, onAccounts: () -> Unit = {}): List<MenuItem> {
    val repo = LocalContainer.current.repo
    return listOf(
        MenuItem("spark", "Edit character sheet", onClick = onSheet),
        MenuItem("grid", "Character sheet", onClick = onSheet),
        MenuItem("spark", "Identity LoRA", onClick = onLora),
        MenuItem("export", "Accounts", onClick = onAccounts),
        MenuItem("outfit", "Add outfit", onClick = onOutfit),
        MenuItem("retry", "Duplicate model") { repo.toast("Duplicated as \"Sienna Vale copy\"") },
        MenuItem("export", "Share profile card") { repo.toast("Profile card ready to share") },
        MenuItem("shield", "Delete model", danger = true) { repo.toast("Delete is disabled in this demo") },
    )
}

/** Members spend credit from the owner; the owner (and Demo mode) spends the studio balance they load. */
fun lowFundsMessage(c: studio.muse.app.AppContainer): String =
    if (c.repo.state.value.wallet?.owner == false || (!c.prefs.value.owner && !c.repo.demo)) studio.muse.app.data.ErrorText.NOT_ENOUGH_CREDIT
    else studio.muse.app.data.ErrorText.NOT_ENOUGH_STUDIO

/** The live photo prices (features.photo) for the "about $0.46" estimates; the contract's defaults until loaded. */
@androidx.compose.runtime.Composable
fun photoPrices(): studio.muse.core.PhotoPrices {
    val st = studio.muse.app.ui.LocalContainer.current.repo.state.collectAsState()
    return st.value.photo
}

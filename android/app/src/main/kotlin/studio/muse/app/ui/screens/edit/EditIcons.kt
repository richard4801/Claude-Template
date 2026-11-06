package studio.muse.app.ui.screens.edit

import studio.muse.app.ui.theme.PhosphorIcons
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** Draws MUSE's one icon set, Phosphor Regular (plans/design-direction.md §5). Old names resolve through [PhosphorIcons.ALIASES]. */
object EditIcons {
    fun get(name: String): ImageVector = PhosphorIcons.get(name)
}

/** An Edit suite icon, tinted with the content colour. */
@Composable
fun EIc(name: String, size: Dp = 20.dp, tint: Color = LocalContentColor.current, modifier: Modifier = Modifier) {
    Icon(EditIcons.get(name), contentDescription = null, tint = tint, modifier = modifier.size(size))
}

package studio.muse.app.ui.theme

import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** Draws MUSE's one icon set, Phosphor Regular (plans/design-direction.md §5). Old names resolve through [PhosphorIcons.ALIASES]. */
object MuseIcons {
    fun get(name: String): ImageVector = PhosphorIcons.get(name)
}

@Composable
fun Ic(name: String, size: Dp = 22.dp, tint: Color = androidx.compose.material3.LocalContentColor.current, modifier: Modifier = Modifier) {
    Icon(MuseIcons.get(name), contentDescription = null, tint = tint, modifier = modifier.size(size))
}

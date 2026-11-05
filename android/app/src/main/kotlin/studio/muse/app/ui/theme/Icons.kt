package studio.muse.app.ui.theme

import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** The prototype's icon set (prototype/screens/gen.py ICON), converted from SVG to path data. 24x24, 1.7 stroke. */
object MuseIcons {
    private val PATHS = mapOf(
    "home" to "M4 11l8-7 8 7v9h-5v-6H9v6H4z",
    "studio" to "M5 6h9a2 2 0 0 1 2 2v8a2 2 0 0 1 -2 2h-9a2 2 0 0 1 -2 -2v-8a2 2 0 0 1 2 -2z M16 10l5-3v10l-5-3z",
    "queue" to "M4 6h16M4 12h10M4 18h7 M15 16a3 3 0 1 0 6 0a3 3 0 1 0 -6 0z",
    "user" to "M8 8a4 4 0 1 0 8 0a4 4 0 1 0 -8 0z M4 21c1-4 4-6 8-6s7 2 8 6",
    "plus" to "M12 5v14M5 12h14",
    "back" to "M15 5l-7 7 7 7",
    "more" to "M3.7 12a1.3 1.3 0 1 0 2.6 0a1.3 1.3 0 1 0 -2.6 0z M10.7 12a1.3 1.3 0 1 0 2.6 0a1.3 1.3 0 1 0 -2.6 0z M17.7 12a1.3 1.3 0 1 0 2.6 0a1.3 1.3 0 1 0 -2.6 0z",
    "model" to "M8.5 7a3.5 3.5 0 1 0 7 0a3.5 3.5 0 1 0 -7 0z M5 21c.8-4.5 3.4-7 7-7s6.2 2.5 7 7",
    "outfit" to "M8 4l4 3 4-3 4 4-3 3v9H7v-9L4 8z",
    "camera" to "M4 8h3l2-2.5h6L17 8h3v11H4z M8.5 13a3.5 3.5 0 1 0 7 0a3.5 3.5 0 1 0 -7 0z",
    "light" to "M8 12a4 4 0 1 0 8 0a4 4 0 1 0 -8 0z M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.5 1.5M17.5 17.5L19 19M5 19l1.5-1.5M17.5 6.5L19 5",
    "bg" to "M5 5h14a2 2 0 0 1 2 2v10a2 2 0 0 1 -2 2h-14a2 2 0 0 1 -2 -2v-10a2 2 0 0 1 2 -2z M3 16l5-5 4 4 3-3 6 6",
    "quality" to "M4 7h10M18 7h2M4 17h4M12 17h8 M14 7a2 2 0 1 0 4 0a2 2 0 1 0 -4 0z M8 17a2 2 0 1 0 4 0a2 2 0 1 0 -4 0z",
    "audio" to "M4 9v6h4l5 4V5L8 9z M16 9c1 1 1 5 0 6M18.5 7c2 2.5 2 7.5 0 10",
    "mute" to "M4 9v6h4l5 4V5L8 9z M16 9.5l5 5M21 9.5l-5 5",
    "check" to "M5 12.5l4.5 4.5L19 7.5",
    "lock" to "M7 11h10a2 2 0 0 1 2 2v5a2 2 0 0 1 -2 2h-10a2 2 0 0 1 -2 -2v-5a2 2 0 0 1 2 -2z M8 11V8a4 4 0 018 0v3",
    "bell" to "M6 16V11a6 6 0 0112 0v5l2 2H4z M10 20a2 2 0 004 0",
    "play" to "M8 5v14l11-7z",
    "upload" to "M12 16V4M7 9l5-5 5 5M4 20h16",
    "spark" to "M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z",
    "google" to "M21.35 11.1H12v2.98h5.35c-.23 1.4-1.66 4.1-5.35 4.1a6.18 6.18 0 010-12.36c1.86 0 3.1.79 3.82 1.47l2.6-2.5C16.76 3.28 14.6 2.3 12 2.3a9.7 9.7 0 100 19.4c5.6 0 9.3-3.94 9.3-9.48 0-.64-.07-1.12-.15-1.62z",
    "apple" to "M16 3c-1 .1-2.2.7-2.8 1.5-.6.7-1.1 1.8-.9 2.8 1.1 0 2.2-.6 2.8-1.4.6-.8 1-1.8.9-2.9zM19.5 16.8c-.5 1.1-.8 1.6-1.4 2.6-.9 1.4-2.2 3-3.7 3-1.4 0-1.7-.9-3.6-.9s-2.3.9-3.6.9c-1.5 0-2.7-1.5-3.6-2.9C1.1 15.7.8 11 2.4 8.6c1.1-1.7 2.9-2.7 4.6-2.7 1.7 0 2.8.9 4.2.9 1.4 0 2.2-.9 4.2-.9 1.5 0 3.1.8 4.2 2.2-3.7 2-3.1 7.3-.1 8.7z",
    "mail" to "M5 5h14a2 2 0 0 1 2 2v10a2 2 0 0 1 -2 2h-14a2 2 0 0 1 -2 -2v-10a2 2 0 0 1 2 -2z M3 7l9 6 9-6",
    "export" to "M12 3v12M7 8l5-5 5 5 M5 14v6h14v-6",
    "retry" to "M4 12a8 8 0 0114-5.3L20 9M20 4v5h-5 M20 12a8 8 0 01-14 5.3L4 15M4 20v-5h5",
    "wallet" to "M5 6h14a2 2 0 0 1 2 2v9a2 2 0 0 1 -2 2h-14a2 2 0 0 1 -2 -2v-9a2 2 0 0 1 2 -2z M3 10h18M16 14.5h2",
    "palette" to "M12 3a9 9 0 100 18c1.2 0 1.8-1 1.3-2-.6-1.2.2-2.5 1.5-2.5H17a4 4 0 004-4c0-5-4-9.5-9-9.5z M6.3 11a1.2 1.2 0 1 0 2.4 0a1.2 1.2 0 1 0 -2.4 0z M9.3 7.5a1.2 1.2 0 1 0 2.4 0a1.2 1.2 0 1 0 -2.4 0z M13.8 8a1.2 1.2 0 1 0 2.4 0a1.2 1.2 0 1 0 -2.4 0z",
    "shield" to "M12 3l8 3v6c0 4.5-3.4 8-8 9-4.6-1-8-4.5-8-9V6z",
    "chev" to "M9 5l7 7-7 7",
    "grid" to "M4 4h7v7h-7z M13 4h7v7h-7z M4 13h7v7h-7z M13 13h7v7h-7z",
    "eye" to "M2.5 12c2.2-4.2 5.4-6.5 9.5-6.5s7.3 2.3 9.5 6.5c-2.2 4.2-5.4 6.5-9.5 6.5s-7.3-2.3-9.5-6.5z M9 12a3 3 0 1 0 6 0a3 3 0 1 0 -6 0z",
    "eye_off" to "M2.5 12c2.2-4.2 5.4-6.5 9.5-6.5s7.3 2.3 9.5 6.5c-2.2 4.2-5.4 6.5-9.5 6.5s-7.3-2.3-9.5-6.5z M9 12a3 3 0 1 0 6 0a3 3 0 1 0 -6 0z M4 4l16 16",
    )
    private val FILLED = setOf("play", "apple", "google")
    private val cache = HashMap<String, ImageVector>()

    fun get(name: String): ImageVector = cache.getOrPut(name) {
        val d = PATHS[name] ?: error("Unknown icon $name")
        val filled = name in FILLED
        ImageVector.Builder(name, 24.dp, 24.dp, 24f, 24f).apply {
            addPath(
                pathData = addPathNodes(d),
                fill = if (filled) SolidColor(Color.Black) else null,
                stroke = if (filled) null else SolidColor(Color.Black),
                strokeLineWidth = 1.7f,
                strokeLineCap = StrokeCap.Round,
                strokeLineJoin = StrokeJoin.Round,
            )
        }.build()
    }
}

@Composable
fun Ic(name: String, size: Dp = 22.dp, tint: Color = androidx.compose.material3.LocalContentColor.current, modifier: Modifier = Modifier) {
    Icon(MuseIcons.get(name), contentDescription = null, tint = tint, modifier = modifier.size(size))
}

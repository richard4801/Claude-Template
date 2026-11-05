package studio.muse.app.ui.screens.edit

import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
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

/**
 * The Edit suite's icons: the approved designs' set (design/source/base.py `P`, 24×24, square caps), converted to path
 * data (circles and rects as paths). Kept here so the shared icon set stays untouched.
 */
object EditIcons {
    private val PATHS: Map<String, Pair<String, Boolean>> = mapOf(
        "video" to ("M2.5 6.0h13.5v12.0h-13.5z M16 10.5l5.5-3v9l-5.5-3z" to false),
        "sliders" to ("M4 20v-6M4 10V4M12 20v-8M12 8V4M20 20v-4M20 12V4M1.5 14h5M9.5 8h5M17.5 16h5" to false),
        "plus" to ("M12 5v14M5 12h14" to false),
        "play" to ("M7 4.5v15l12.5-7.5z" to true),
        "pause" to ("M7 4.5h3.5v15H7zM13.5 4.5H17v15h-3.5z" to true),
        "scissors" to ("M3.2 6.0a2.8 2.8 0 1 0 5.6 0a2.8 2.8 0 1 0 -5.6 0z M3.2 18.0a2.8 2.8 0 1 0 5.6 0a2.8 2.8 0 1 0 -5.6 0z M20 4 8.2 15.8M14.5 14.5 20 20M8.2 8.2 12 12" to false),
        "wand" to ("M4 20l11-11M14 5l1-2 1 2 2 1-2 1-1 2-1-2-2-1zM19 12l.6-1.2L21 10l-1.4-.8L19 8l-.6 1.2L17 10l1.4.8z" to false),
        "mic" to ("M9.0 2.5h6.0v12.0h-6.0z M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21" to false),
        "music" to ("M9 18V5.5l11-2V16 M4.0 18.0a2.5 2.5 0 1 0 5.0 0a2.5 2.5 0 1 0 -5.0 0z M15.0 16.0a2.5 2.5 0 1 0 5.0 0a2.5 2.5 0 1 0 -5.0 0z" to false),
        "type" to ("M4.5 7V4.5h15V7M12 4.5v15M9 19.5h6" to false),
        "cc" to ("M2.5 5.0h19.0v14.0h-19.0z M10.5 10.2a2.4 2.4 0 1 0 0 3.6M17.5 10.2a2.4 2.4 0 1 0 0 3.6" to false),
        "sparkle" to ("M12 3l1.9 5.1L19 10l-5.1 1.9L12 17l-1.9-5.1L5 10l5.1-1.9z M19 16v4M17 18h4" to false),
        "search" to ("M4.5 11.0a6.5 6.5 0 1 0 13.0 0a6.5 6.5 0 1 0 -13.0 0z M20 20l-4.2-4.2" to false),
        "check" to ("M4.5 12.5 9.5 17.5 19.5 7" to false),
        "lock" to ("M4.5 11.0h15.0v10.0h-15.0z M8 11V7.5a4 4 0 0 1 8 0V11" to false),
        "eye" to ("M2 12s3.8-6.5 10-6.5S22 12 22 12s-3.8 6.5-10 6.5S2 12 2 12z M9.0 12.0a3.0 3.0 0 1 0 6.0 0a3.0 3.0 0 1 0 -6.0 0z" to false),
        "volume" to ("M4 9.5h3.5L12 5.5v13l-4.5-4H4z M15.5 9.5a3.5 3.5 0 0 1 0 5M18.5 6.5a7.5 7.5 0 0 1 0 11" to false),
        "film" to ("M3.5 3.0h17.0v18.0h-17.0z M7.5 3v18M16.5 3v18M3.5 8h4M3.5 12h4M3.5 16h4M16.5 8h4M16.5 12h4M16.5 16h4" to false),
        "sun" to ("M8.0 12.0a4.0 4.0 0 1 0 8.0 0a4.0 4.0 0 1 0 -8.0 0z M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4" to false),
        "palette" to ("M12 3a9 9 0 1 0 0 18c1.4 0 2-.9 2-1.9s-1-1.6-1-2.6 1-1.5 2-1.5h2.2A3.8 3.8 0 0 0 21 11.2C21 6.6 17 3 12 3z M6.5 11.0a1.0 1.0 0 1 0 2.0 0a1.0 1.0 0 1 0 -2.0 0z M9.0 7.0a1.0 1.0 0 1 0 2.0 0a1.0 1.0 0 1 0 -2.0 0z M14.0 7.5a1.0 1.0 0 1 0 2.0 0a1.0 1.0 0 1 0 -2.0 0z" to false),
        "move" to ("M12 3v18M3 12h18M12 3l-3 3M12 3l3 3M12 21l-3-3M12 21l3-3M3 12l3-3M3 12l3 3M21 12l-3-3M21 12l-3 3" to false),
        "clock" to ("M3.0 12.0a9.0 9.0 0 1 0 18.0 0a9.0 9.0 0 1 0 -18.0 0z M12 7v5l3.5 2" to false),
        "export" to ("M12 15V3.5M7.5 8 12 3.5 16.5 8M4 14v6.5h16V14" to false),
        "more" to ("M4.3 12.0a1.2 1.2 0 1 0 2.4 0a1.2 1.2 0 1 0 -2.4 0z M10.8 12.0a1.2 1.2 0 1 0 2.4 0a1.2 1.2 0 1 0 -2.4 0z M17.3 12.0a1.2 1.2 0 1 0 2.4 0a1.2 1.2 0 1 0 -2.4 0z" to true),
        "x" to ("M6 6l12 12M18 6 6 18" to false),
        "undo" to ("M9 14 4 9l5-5 M4 9h10.5a5.5 5.5 0 0 1 0 11H11" to false),
        "redo" to ("M15 14l5-5-5-5 M20 9H9.5a5.5 5.5 0 0 0 0 11H13" to false),
        "magnet" to ("M6 3.5v8a6 6 0 0 0 12 0v-8h-4v8a2 2 0 0 1-4 0v-8z M6 7.5h4M14 7.5h4" to false),
        "layers" to ("M12 3l9 5-9 5-9-5z M3 13l9 5 9-5" to false),
        "gauge" to ("M3.5 17.5a9 9 0 1 1 17 0 M12 13.5 16 9" to false),
        "mask" to ("M3.0 3.0h18.0v18.0h-18.0z M7.0 12.0a5.0 5.0 0 1 0 10.0 0a5.0 5.0 0 1 0 -10.0 0z" to false),
        "drop" to ("M12 3s6.5 7 6.5 11.3a6.5 6.5 0 0 1-13 0C5.5 10 12 3 12 3z" to false),
        "trans" to ("M3.0 6.0h11.0v12.0h-11.0z M10.0 6.0h11.0v12.0h-11.0z" to false),
        "refresh" to ("M20 11.5a8 8 0 1 0-2.3 5.8M20 4.5v7h-7" to false),
        "upload" to ("M12 16V4.5M7.5 9 12 4.5 16.5 9M4 15v5.5h16V15" to false),
        "image" to ("M3.0 4.0h18.0v16.0h-18.0z M7.2 9.5a1.8 1.8 0 1 0 3.6 0a1.8 1.8 0 1 0 -3.6 0z M3 17l5.5-5 4.5 4 3-2.5L21 18" to false),
        "expand" to ("M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5" to false),
        "trash" to ("M4 6.5h16M9.5 6.5V4h5v2.5M6 6.5l1 14h10l1-14" to false),
        "split" to ("M12 3v18M7 7l-4 5 4 5M17 7l4 5-4 5" to false),
        "beat" to ("M3 12h3l2-6 4 12 3-9 2 3h4" to false),
        "shield" to ("M12 3 4.5 6v6c0 4.5 3.2 7.6 7.5 9 4.3-1.4 7.5-4.5 7.5-9V6z M8.8 12.2l2.2 2.2 4.4-4.6" to false),
        "ratio" to ("M7.0 3.0h10.0v18.0h-10.0z" to false),
        // Drawn for the suite in the same style (transitions, timeline).
        "chev-r" to ("M9 6l6 6-6 6" to false),
        "chev-d" to ("M6 9l6 6 6-6" to false),
        "diamond" to ("M12 4l8 8-8 8-8-8z" to true),
        "copy" to ("M8 8h12v12H8z M16 8V4H4v12h4" to false),
        "ripple" to ("M3 12h4M17 12h4M7 7v10M17 7v10M10 12h4" to false),
        "keyframe" to ("M12 5l7 7-7 7-7-7z" to false),
        "rewind" to ("M11 6.5 4.5 12l6.5 5.5zM19.5 6.5 13 12l6.5 5.5z" to true),
        "ffwd" to ("M13 6.5 19.5 12 13 17.5zM4.5 6.5 11 12l-6.5 5.5z" to true),
        "heart" to ("M12 20s-7.5-4.6-7.5-10A4.3 4.3 0 0 1 12 7.4 4.3 4.3 0 0 1 19.5 10c0 5.4-7.5 10-7.5 10z" to false),
        "msg" to ("M4 4.5h16v11.5H9l-5 4z" to false),
        "send" to ("M21 3 10.5 13.5M21 3l-6.5 18-4-7.5L3 9.5z" to false),
        "whip" to ("M5 6l6 6-6 6M12 6l6 6-6 6" to false),
        "fx" to ("M5 20 9 4h6M7 11h6M14 13l5 6M19 13l-5 6" to false),
        "xfade" to ("M3 6h11v12H3z M10 6h11v12H10z" to false),
    )
    private val cache = HashMap<String, ImageVector>()

    fun get(name: String): ImageVector = cache.getOrPut(name) {
        val (d, filled) = PATHS[name] ?: error("Unknown edit icon $name")
        ImageVector.Builder(name, 24.dp, 24.dp, 24f, 24f).apply {
            addPath(
                pathData = addPathNodes(d),
                fill = if (filled) SolidColor(Color.Black) else null,
                stroke = if (filled) null else SolidColor(Color.Black),
                strokeLineWidth = 1.6f,
                strokeLineCap = StrokeCap.Square,
                strokeLineJoin = StrokeJoin.Miter,
            )
        }.build()
    }

    val names: Set<String> get() = PATHS.keys
}

/** An Edit suite icon, tinted with the content colour. */
@Composable
fun EIc(name: String, size: Dp = 20.dp, tint: Color = LocalContentColor.current, modifier: Modifier = Modifier) {
    Icon(EditIcons.get(name), contentDescription = null, tint = tint, modifier = modifier.size(size))
}

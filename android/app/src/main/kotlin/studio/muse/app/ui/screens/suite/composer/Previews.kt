package studio.muse.app.ui.screens.suite.composer

import android.content.Context
import android.os.PowerManager
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import studio.muse.app.ui.components.T
import studio.muse.app.ui.screens.StageVideo
import studio.muse.app.ui.screens.suite.HardwareImage
import studio.muse.app.ui.screens.suite.MovePictogram
import studio.muse.app.ui.screens.suite.SIc
import studio.muse.app.ui.theme.muse
import kotlin.math.atan
import kotlin.math.cos
import kotlin.math.sin

// AI suite (workstream 1): picker previews (plans/video-composer.md "Previews"). Every tile draws a [Preview]: a still
// today (a hardware render, or a diagram drawn in code) and, once the Blender loops exist, a looping clip — a data change
// only (`loop` on the catalog option). Loops autoplay muted while the tile is on screen and fall back to the still in
// battery saver.

/** What a tile shows. [still] is a bundled hardware render; [loop] an optional looping mp4/webm; [draw] a code diagram. */
data class Preview(
    val still: String? = null, val loop: String? = null, val draw: PreviewDraw? = null, val swatches: List<String> = emptyList(),
    /** A bundled preview still (`assets/previews/<poster>`): shown first, and as the fallback for [video]. */
    val poster: String? = null,
    /** A bundled preview loop (`assets/previews/<video>`): plays muted and looping while the tile is on screen. */
    val video: String? = null,
)

/** The bundled composer previews (assets/previews, from design/previews), decoded once and scaled down. */
object PreviewImages {
    private val cache = android.util.LruCache<String, androidx.compose.ui.graphics.ImageBitmap>(48)
    fun load(ctx: Context, path: String?, sample: Int = 1): androidx.compose.ui.graphics.ImageBitmap? {
        if (path.isNullOrBlank()) return null
        val key = "$path@$sample"
        cache.get(key)?.let { return it }
        return runCatching {
            ctx.assets.open("previews/$path").use { s -> android.graphics.BitmapFactory.decodeStream(s, null, android.graphics.BitmapFactory.Options().apply { inSampleSize = sample }) }?.let {
                it.asImageBitmap()
            }
        }.getOrNull()?.also { cache.put(key, it) }
    }

    /** Unit tests (Robolectric) can't decode video: the posters show there. */
    val videoOff: Boolean get() = android.os.Build.FINGERPRINT == "robolectric"
}

/** A bundled loop, muted and looping, over its poster; it plays only while the tile is composed (on screen). */
@Composable
private fun PreviewLoop(path: String, modifier: Modifier) {
    val ctx = LocalContext.current
    val player = remember(path) {
        androidx.media3.exoplayer.ExoPlayer.Builder(ctx).build().apply {
            setMediaItem(androidx.media3.common.MediaItem.fromUri("asset:///previews/$path"))
            repeatMode = androidx.media3.common.Player.REPEAT_MODE_ONE
            volume = 0f
            prepare()
        }
    }
    androidx.compose.runtime.DisposableEffect(player) { onDispose { player.release() } }
    androidx.lifecycle.compose.LifecycleResumeEffect(player) {
        player.playWhenReady = true
        onPauseOrDispose { player.pause() }
    }
    androidx.compose.ui.viewinterop.AndroidView(
        factory = { c ->
            androidx.media3.ui.PlayerView(c).apply {
                this.player = player
                useController = false
                resizeMode = androidx.media3.ui.AspectRatioFrameLayout.RESIZE_MODE_ZOOM
                setShutterBackgroundColor(android.graphics.Color.TRANSPARENT)
            }
        },
        modifier = modifier, update = { it.player = player },
    )
}

/** Previews drawn in code: the Auto plate, focal fields of view, the iris, angle and framing diagrams, a move's arrow. */
sealed interface PreviewDraw {
    data object Auto : PreviewDraw
    data class Focal(val mm: Int) : PreviewDraw
    data class Iris(val fStop: Double) : PreviewDraw
    data class Height(val id: String) : PreviewDraw
    data class Framing(val id: String) : PreviewDraw
    data class Move(val id: String, val category: String) : PreviewDraw
    data class Swatch(val colors: List<String>) : PreviewDraw
    data class Light(val id: String) : PreviewDraw
    data class Word(val text: String) : PreviewDraw
}

/** Battery saver: previews stay stills. */
@Composable
fun rememberLoopsAllowed(): Boolean {
    val ctx = LocalContext.current
    return remember { runCatching { (ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager)?.isPowerSaveMode != true }.getOrDefault(true) }
}

/** The neutral stage the move and lighting stills sit on until their loops are rendered. */
const val NEUTRAL_STILL = "light-03-overhead"

@Composable
fun PreviewTile(p: Preview, modifier: Modifier = Modifier, overlay: @Composable BoxScope.() -> Unit = {}) {
    val loops = rememberLoopsAllowed()
    Box(modifier.background(Color(0xFF101112))) {
        val ctx = LocalContext.current
        val poster = remember(p.poster) { PreviewImages.load(ctx, p.poster) }
        // A bundled preview replaces the drawn still (and the move's arrow); without one, the drawing stays.
        if (poster != null) androidx.compose.foundation.Image(poster, null, Modifier.matchParentSize(), contentScale = androidx.compose.ui.layout.ContentScale.Crop)
        else when (val d = p.draw) {
            null -> HardwareImage(p.still, Modifier.matchParentSize(), sample = 4)
            PreviewDraw.Auto -> Box(Modifier.matchParentSize().background(Brush.verticalGradient(listOf(Color(0xFF1A1C1E), Color(0xFF111213)))), contentAlignment = Alignment.Center) {
                SIc("aperture", 22.dp, Color(0xFF8C8A86)) // Auto: the aperture mark, as on the drums
            }
            is PreviewDraw.Move -> {
                HardwareImage(p.still ?: NEUTRAL_STILL, Modifier.matchParentSize(), sample = 4, gray = true)
                Box(Modifier.matchParentSize().background(Color.Black.copy(alpha = .5f)))
                MovePictogram(d.id, d.category, Modifier.matchParentSize(), ink = Color(0xFFE9E6E0), accent = muse.t.accent)
            }
            is PreviewDraw.Light -> {
                if (p.still != null) HardwareImage(p.still, Modifier.matchParentSize(), sample = 4)
                else Canvas(Modifier.matchParentSize()) { lightGlyph(d.id) }
            }
            is PreviewDraw.Swatch -> Canvas(Modifier.matchParentSize()) {
                val cs = d.colors.map { hex(it) }.ifEmpty { listOf(Color.DarkGray, Color.Gray) }
                drawRect(Brush.linearGradient(cs, Offset.Zero, Offset(size.width, size.height)))
            }
            is PreviewDraw.Word -> {
                if (p.still != null) HardwareImage(p.still, Modifier.matchParentSize(), sample = 4)
                Box(Modifier.matchParentSize().background(Color.Black.copy(alpha = .45f)))
                T(d.text, studio.muse.app.ui.theme.museFor(studio.muse.app.ui.theme.ThemeId.A).type.h2.copy(fontSize = 26.sp, lineHeight = 26.sp), Color(0xFFF8F5EF),
                    Modifier.align(Alignment.BottomStart).padding(start = 10.dp, bottom = 8.dp, end = 8.dp), maxLines = 2)
            }
            else -> Canvas(Modifier.matchParentSize()) { diagram(d) }
        }
        if (p.video != null && poster != null && loops && !PreviewImages.videoOff) PreviewLoop(p.video, Modifier.matchParentSize())
        else if (p.loop != null && loops && !PreviewImages.videoOff) StageVideo(p.loop, null, muted = true, modifier = Modifier.matchParentSize())
        overlay()
    }
}

/** A 5-colour strip under palette and film-stock tiles. */
@Composable
fun SwatchStrip(colors: List<String>, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth().height(10.dp)) {
        colors.forEach { c -> Box(Modifier.weight(1f).fillMaxSize().background(hex(c))) }
    }
}

fun hex(s: String): Color = runCatching { Color(android.graphics.Color.parseColor(s)) }.getOrDefault(Color.Gray)

private val LINE = Color(0xFFBDB9B2)
private val ACC = Color(0xFFF2A93B)

private fun DrawScope.diagram(d: PreviewDraw) {
    val w = size.width; val h = size.height
    val s = 1.5.dp.toPx()
    when (d) {
        is PreviewDraw.Focal -> {
            // A camera at the bottom and its field of view: 2·atan(18 / mm) on a 36 mm frame.
            val fov = 2 * atan(18.0 / d.mm)
            val apex = Offset(w / 2, h * .74f)
            val len = h * .62f
            val a = (fov / 2).toFloat()
            val l = Offset(apex.x - len * sin(a), apex.y - len * cos(a))
            val r = Offset(apex.x + len * sin(a), apex.y - len * cos(a))
            val path = Path().apply { moveTo(apex.x, apex.y); lineTo(l.x, l.y); lineTo(r.x, r.y); close() }
            drawPath(path, ACC.copy(alpha = .18f))
            drawLine(LINE, apex, l, s); drawLine(LINE, apex, r, s)
            drawCircle(Color(0xFFECEAE5), 5.dp.toPx(), apex)
            drawRect(Color(0xFFECEAE5), Offset(apex.x - 5.dp.toPx(), apex.y + 4.dp.toPx()), Size(10.dp.toPx(), 9.dp.toPx()))
            for (k in 1..3) drawLine(Color.White.copy(alpha = .06f), Offset(0f, h * k / 4f), Offset(w, h * k / 4f), 1f)
        }
        is PreviewDraw.Iris -> {
            drawCircle(Color(0xFF1C1E20), h * .42f, Offset(w / 2, h / 2))
            drawCircle(Color(0xFF2C3033), h * .42f, Offset(w / 2, h / 2), style = Stroke(s))
            val rr = (h * .36f * (1.4 / d.fStop).toFloat().coerceIn(.18f, 1f) * 1.0f).coerceAtLeast(h * .07f)
            val hexPath = Path().apply {
                for (k in 0..5) { val ang = Math.toRadians(60.0 * k - 90).toFloat(); val p = Offset(w / 2 + rr * cos(ang), h / 2 + rr * sin(ang)); if (k == 0) moveTo(p.x, p.y) else lineTo(p.x, p.y) }
                close()
            }
            drawPath(hexPath, Color(0xFF0A0A0B)); drawPath(hexPath, LINE, style = Stroke(s))
        }
        is PreviewDraw.Height -> {
            val ground = h * .84f
            drawLine(LINE.copy(alpha = .4f), Offset(w * .06f, ground), Offset(w * .94f, ground), 1.dp.toPx())
            val fx = w * .68f; val tall = h * .6f
            figure(Offset(fx, ground), tall)
            val camY = when (d.id) {
                "overhead" -> h * .08f; "high" -> h * .2f; "eye" -> ground - tall * .87f; "shoulder" -> ground - tall * .76f
                "hip" -> ground - tall * .5f; "low" -> ground - tall * .3f; "worm" -> ground - h * .04f; "ground" -> ground - h * .02f; else -> ground - tall * .85f
            }
            val camX = if (d.id == "overhead") fx else w * .24f
            val target = Offset(fx, ground - tall * .8f)
            drawLine(ACC, Offset(camX, camY), target, s, pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 3.dp.toPx())))
            drawRect(Color(0xFFECEAE5), Offset(camX - 7.dp.toPx(), camY - 4.dp.toPx()), Size(14.dp.toPx(), 9.dp.toPx()))
        }
        is PreviewDraw.Framing -> {
            val ground = h * .96f
            val fx = w / 2; val tall = h * .9f
            figure(Offset(fx, ground), tall, alpha = .55f)
            if (d.id == "two_shot") figure(Offset(fx - w * .2f, ground), tall * .96f, alpha = .55f)
            if (d.id == "ots") drawCircle(Color(0xFF5A5650), h * .3f, Offset(w * .1f, h * .62f))
            // The frame: the part of the body each size keeps (a 16:9-ish box, centred on the face for close sizes).
            val keep = when (d.id) { "els" -> 2.6f; "ls" -> 1.25f; "full" -> 1.05f; "cowboy" -> .78f; "ms" -> .6f; "mcu" -> .42f; "cu" -> .28f; "ecu" -> .15f; "insert" -> .12f; else -> .7f }
            val fh = (tall * keep).coerceAtMost(h * 1.6f)
            val fw = fh * 1.25f
            val top = ground - tall
            val cy = if (keep >= 1f) ground - tall / 2 else top + fh / 2
            drawRect(ACC, Offset(fx - fw / 2, cy - fh / 2), Size(fw, fh), style = Stroke(s))
            if (d.id == "pov") { drawLine(ACC, Offset(w * .1f, h * .9f), Offset(w * .3f, h * .6f), s); drawLine(ACC, Offset(w * .9f, h * .9f), Offset(w * .7f, h * .6f), s) }
        }
        else -> Unit
    }
}

private fun DrawScope.figure(feet: Offset, tall: Float, alpha: Float = .9f) {
    val c = Color(0xFFECEAE5).copy(alpha = alpha)
    val head = tall * .11f
    drawCircle(c, head, Offset(feet.x, feet.y - tall + head))
    drawLine(c, Offset(feet.x, feet.y - tall + head * 2), Offset(feet.x, feet.y - tall * .45f), head * 1.1f, StrokeCap.Round)
    drawLine(c, Offset(feet.x, feet.y - tall * .45f), Offset(feet.x - head * .5f, feet.y), head * .7f, StrokeCap.Round)
    drawLine(c, Offset(feet.x, feet.y - tall * .45f), Offset(feet.x + head * .5f, feet.y), head * .7f, StrokeCap.Round)
}

/** Lighting setups without a render yet: a mannequin and where the light comes from, drawn in code. */
private fun DrawScope.lightGlyph(id: String) {
    val w = size.width; val h = size.height
    val warm = when (id) { "golden_hour", "candle", "practicals" -> Color(0xFFF2A93B); "blue_hour", "moonlight" -> Color(0xFF5B8BD9); "neon" -> Color(0xFFE04BD0); else -> Color(0xFFECEAE5) }
    val from = when (id) { "silhouette" -> Offset(w * .5f, h * .5f); "harsh_sun", "overhead" -> Offset(w * .5f, 0f); "flash" -> Offset(w * .5f, h * .45f); else -> Offset(w * .15f, h * .2f) }
    drawRect(Brush.radialGradient(listOf(warm.copy(alpha = .55f), Color.Transparent), from, w * .9f))
    figure(Offset(w * .55f, h * .95f), h * .78f, alpha = if (id == "silhouette") .15f else .8f)
}

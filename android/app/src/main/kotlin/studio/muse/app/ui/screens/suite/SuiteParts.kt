package studio.muse.app.ui.screens.suite

import android.content.Context
import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import studio.muse.app.data.ImageRef
import studio.muse.app.ui.components.Bar
import studio.muse.app.ui.components.Ink
import studio.muse.app.ui.components.RefImage
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.hardShadow
import studio.muse.app.ui.components.press
import studio.muse.app.ui.screens.BlurredStageArt
import studio.muse.app.ui.screens.StageButton
import studio.muse.app.ui.screens.StagePhase
import studio.muse.app.ui.screens.StageVideo
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse

// ---------------------------------------------------------------- icons the app's set doesn't have

object SuiteIcons {
    private val PATHS = mapOf(
        "users" to "M6 8a3 3 0 1 0 6 0a3 3 0 1 0 -6 0z M2.5 20c.6-3.4 3-5.3 6.5-5.3s5.9 1.9 6.5 5.3 M15 5.2a3 3 0 0 1 0 5.6 M17.6 14.9c2.2.7 3.6 2.4 4 5.1",
        "type" to "M5 7V4h14v3 M12 4v16 M9 20h6",
        "clock" to "M3 12a9 9 0 1 0 18 0a9 9 0 1 0 -18 0z M12 7v5l3 2",
        "sliders" to "M4 6h9M17 6h3 M4 12h3M11 12h9 M4 18h11M19 18h1 M15 4v4 M9 10v4 M17 16v4",
        "close" to "M6 6l12 12M18 6L6 18",
        "bag" to "M5 8h14l-1 12H6z M9 8V6a3 3 0 0 1 6 0v2",
        "heart" to "M12 20s-7-4.4-7-10a4 4 0 0 1 7-2.6A4 4 0 0 1 19 10c0 5.6-7 10-7 10z",
        "refresh" to "M20 12a8 8 0 1 1-2.3-5.7 M20 4v5h-5",
        "scissors" to "M4 6.5a2.5 2.5 0 1 0 5 0a2.5 2.5 0 1 0 -5 0z M4 17.5a2.5 2.5 0 1 0 5 0a2.5 2.5 0 1 0 -5 0z M8.5 8l11.5 10M8.5 16L20 6",
        "share" to "M12 3v12M7 8l5-5 5 5 M5 14v6h14v-6",
        "copy" to "M9 9h11v11H9z M5 15H4V4h11v1",
        "swap" to "M4 8h15l-3-3M20 16H5l3 3",
        "film" to "M4 4h16v16H4z M8 4v16M16 4v16M4 8h4M4 12h4M4 16h4M16 8h4M16 12h4M16 16h4",
        "cube" to "M12 3l8 4.5v9L12 21l-8-4.5v-9z M12 12l8-4.5M12 12v9M12 12L4 7.5",
        "check" to "M5 12.5l4.5 4.5L19 7.5",
        "plus" to "M12 5v14M5 12h14",
        "chev" to "M9 5l7 7-7 7",
        "chevd" to "M6 9l6 6 6-6",
        "gauge" to "M4 16a8 8 0 1 1 16 0 M12 16l4-5",
        "ratio" to "M8 3h8v18H8z",
        "volume" to "M4 9h4l5-4v14l-5-4H4z M16.5 9a4 4 0 0 1 0 6 M19 6.5a7.5 7.5 0 0 1 0 11",
        "talk" to "M4 5h16v11H9l-5 4z M8 10h8",
        "layers" to "M12 3l9 5-9 5-9-5z M3 13l9 5 9-5",
        "move" to "M12 3v18M3 12h18 M9 6l3-3 3 3M9 18l3 3 3-3M6 9l-3 3 3 3M18 9l3 3-3 3",
        "search" to "M4 11a7 7 0 1 0 14 0a7 7 0 1 0 -14 0z M16 16l4.5 4.5",
        "image" to "M4 5h16v14H4z M4 16l5-5 4 4 3-3 4 4 M15 9.5a1.5 1.5 0 1 0 0.01 0z",
        "sparkle" to "M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z M18.5 15.5l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8z",
        "minus" to "M5 12h14",
        // Extend: a clip with more after it; Upscale: corners pulled outwards.
        "extend" to "M3 6h9v12H3z M15 12h6 M18 9l3 3-3 3",
        "upscale" to "M4 14v6h6 M20 10V4h-6 M4 20l6.5-6.5 M20 4l-6.5 6.5",
    )
    private val cache = HashMap<String, ImageVector>()
    fun get(name: String): ImageVector = cache.getOrPut(name) {
        ImageVector.Builder(name, 24.dp, 24.dp, 24f, 24f).apply {
            addPath(addPathNodes(PATHS[name] ?: error("Unknown icon $name")), stroke = SolidColor(Color.Black), strokeLineWidth = 1.7f,
                strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round)
        }.build()
    }
}

@Composable
fun SIc(name: String, size: Dp = 20.dp, tint: Color = androidx.compose.material3.LocalContentColor.current, modifier: Modifier = Modifier) =
    Icon(SuiteIcons.get(name), null, modifier.size(size), tint)

// ---------------------------------------------------------------- the hardware renders (assets/hardware/<render>.webp)

/** Decodes the bundled renders once, scaled down for the phone. */
object HardwareImages {
    private val cache = LruCache<String, ImageBitmap>(64)
    fun load(ctx: Context, render: String?, sample: Int = 2): ImageBitmap? {
        if (render.isNullOrBlank()) return null
        val key = "$render@$sample"
        cache.get(key)?.let { return it }
        return runCatching {
            ctx.assets.open("hardware/$render.webp").use { s -> BitmapFactory.decodeStream(s, null, BitmapFactory.Options().apply { inSampleSize = sample }) }?.asImageBitmap()
        }.getOrNull()?.also { cache.put(key, it) }
    }
}

/** A photoreal hardware render (no logos) from the catalog's `render`; a dark plate when there is none. */
@Composable
fun HardwareImage(render: String?, modifier: Modifier = Modifier, sample: Int = 2, scale: ContentScale = ContentScale.Crop, gray: Boolean = false) {
    val ctx = LocalContext.current
    val bmp = remember(render, sample) { HardwareImages.load(ctx, render, sample) }
    val filter = if (gray) remember { androidx.compose.ui.graphics.ColorFilter.colorMatrix(androidx.compose.ui.graphics.ColorMatrix().apply { setToSaturation(0f) }) } else null
    if (bmp != null) Image(bmp, null, modifier.background(Color(0xFF16181A)), contentScale = scale, colorFilter = filter)
    else Box(modifier.background(Color(0xFF1E2124)))
}

// ---------------------------------------------------------------- move pictograms (M4)

/**
 * A small diagram of a camera move: the subject, the camera and how it travels (a dashed accent arrow), drawn from the
 * move's category so every move of the catalog has one.
 */
@Composable
fun MovePictogram(id: String, category: String, modifier: Modifier = Modifier, ink: Color = muse.t.ink, accent: Color = muse.t.accent) {
    Canvas(modifier) {
        val w = size.width
        val h = size.height
        val ground = h * .82f
        drawLine(ink.copy(alpha = .35f), Offset(w * .08f, ground), Offset(w * .92f, ground), 1.dp.toPx())
        val sx = w * .72f
        figure(Offset(sx, ground), h * .55f, ink)
        val dash = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 3.dp.toPx()))
        val s = 1.4.dp.toPx()
        fun arrow(a: Offset, b: Offset) {
            drawLine(accent, a, b, s, pathEffect = dash)
            val dx = b.x - a.x; val dy = b.y - a.y
            val len = kotlin.math.sqrt(dx * dx + dy * dy).coerceAtLeast(1f)
            val ux = dx / len; val uy = dy / len
            val hl = 5.dp.toPx()
            drawLine(accent, b, Offset(b.x - ux * hl - uy * hl * .6f, b.y - uy * hl + ux * hl * .6f), s)
            drawLine(accent, b, Offset(b.x - ux * hl + uy * hl * .6f, b.y - uy * hl - ux * hl * .6f), s)
        }
        val cam = Offset(w * .3f, ground - h * .32f)
        when {
            id == "static" -> { camera(cam, ink); drawLine(ink, Offset(cam.x, cam.y + 5.dp.toPx()), Offset(cam.x - 6.dp.toPx(), ground), s); drawLine(ink, Offset(cam.x, cam.y + 5.dp.toPx()), Offset(cam.x + 6.dp.toPx(), ground), s) }
            id == "rack_focus" -> { figure(Offset(w * .45f, ground), h * .4f, ink.copy(alpha = .3f)); camera(Offset(w * .18f, cam.y), ink); arrow(Offset(w * .45f, h * .18f), Offset(sx, h * .18f)) }
            id == "selfie" -> { camera(Offset(w * .48f, cam.y - h * .08f), ink); drawLine(ink, Offset(w * .5f, cam.y - h * .04f), Offset(sx - 3.dp.toPx(), cam.y), s); arrow(Offset(w * .8f, ground + h * .09f), Offset(w * .3f, ground + h * .09f)) }
            id == "handheld" || id == "handheld_run" -> { camera(cam, ink); val p = (0..4).map { k -> Offset(w * (.18f + k * .05f), cam.y - h * .2f + (if (k % 2 == 0) 0f else h * .08f)) }; p.zipWithNext().forEach { (a, b) -> drawLine(accent, a, b, s) } }
            category == "push" || category == "zoom" -> {
                val out = id.contains("out")
                for (k in 0..2) camera(Offset(w * (.16f + k * .1f), cam.y), ink.copy(alpha = .25f + k * .3f))
                if (out) arrow(Offset(w * .5f, h * .2f), Offset(w * .12f, h * .2f)) else arrow(Offset(w * .12f, h * .2f), Offset(w * .55f, h * .2f))
            }
            category == "rotate" -> {
                drawCircle(accent, h * .34f, Offset(sx, ground - h * .3f), style = Stroke(s, pathEffect = dash))
                camera(Offset(sx - h * .34f, ground - h * .3f), ink); camera(Offset(sx, ground - h * .64f), ink.copy(alpha = .5f))
            }
            category == "vertical" -> { for (k in 0..2) camera(Offset(w * .3f, ground - h * (.15f + k * .2f)), ink.copy(alpha = .25f + k * .3f)); arrow(Offset(w * .2f, ground - h * .1f), Offset(w * .2f, h * .1f)) }
            category == "aerial" -> { camera(Offset(w * .55f, h * .25f), ink); val p = listOf(Offset(w * .08f, ground - h * .1f), Offset(w * .25f, h * .5f), Offset(w * .4f, h * .45f)); p.zipWithNext().forEach { (a, b) -> drawLine(accent, a, b, s, pathEffect = dash) }; arrow(p.last(), Offset(w * .5f, h * .28f)) }
            category == "lateral" || category == "follow" -> { camera(cam, ink); arrow(Offset(w * .15f, ground + h * .09f), Offset(w * .6f, ground + h * .09f)) }
            else -> { camera(cam, ink); arrow(Offset(w * .15f, h * .2f), Offset(w * .55f, h * .2f)) }
        }
    }
}

private fun DrawScope.figure(feet: Offset, tall: Float, c: Color) {
    val head = tall * .13f
    drawCircle(c, head, Offset(feet.x, feet.y - tall + head))
    drawLine(c, Offset(feet.x, feet.y - tall + head * 2), Offset(feet.x, feet.y - tall * .42f), head * .9f, StrokeCap.Round)
    drawLine(c, Offset(feet.x, feet.y - tall * .42f), Offset(feet.x - head * .5f, feet.y), head * .6f, StrokeCap.Round)
    drawLine(c, Offset(feet.x, feet.y - tall * .42f), Offset(feet.x + head * .5f, feet.y), head * .6f, StrokeCap.Round)
}

private fun DrawScope.camera(at: Offset, c: Color) {
    val bw = 11.dp.toPx(); val bh = 7.dp.toPx()
    drawRect(c, Offset(at.x - bw / 2, at.y - bh / 2), Size(bw, bh))
    drawRect(c, Offset(at.x + bw / 2, at.y - bh / 4), Size(3.dp.toPx(), bh / 2))
}

// ---------------------------------------------------------------- small pieces

/** A small square badge ("READY", "40%", "#2 IN LINE", "TAKE 1"). kind: good | busy | warn | bad | ink | "" */
@Composable
fun SBadge(text: String, kind: String = "", modifier: Modifier = Modifier) {
    val m = muse
    val (fg, bg, line) = when (kind) {
        "good" -> Triple(m.t.good, Color.Transparent, m.t.good)
        "busy", "bad" -> Triple(if (m.isD) Ink else m.t.accent, Color.Transparent, if (m.isD) Ink else m.t.accent)
        "warn" -> Triple(m.t.warnPillInk, m.t.warnPillBg, m.t.warnPillBg)
        "ink" -> Triple(m.t.bg, m.t.ink, m.t.ink)
        else -> Triple(m.t.muted, Color.Transparent, m.t.line)
    }
    val shape = RoundedCornerShape(if (m.isA) 1.dp else 6.dp)
    Box(modifier.heightIn(min = 22.dp).clip(shape).background(bg).border(1.dp, line, shape).padding(horizontal = 7.dp, vertical = 3.dp), contentAlignment = Alignment.Center) {
        T(text.uppercase(), m.type.mono.copy(fontSize = 10.5.sp, letterSpacing = .08.sp, fontWeight = FontWeight.Medium), fg, maxLines = 1)
    }
}

/** The black (theme) Generate bar with the estimate's price: "GENERATE · 2 TAKES · $3.84". */
@Composable
fun GenerateBar(label: String, onClick: () -> Unit, modifier: Modifier = Modifier, off: Boolean = false, busy: Boolean = false, note: String? = null) {
    val m = muse
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (note != null) T(note, m.type.tiny, if (off) m.t.warn else m.t.muted, align = TextAlign.Center, modifier = Modifier.fillMaxWidth(), maxLines = 2)
        studio.muse.app.ui.components.Cta(label, onClick, Modifier.fillMaxWidth(), off = off, busy = busy)
    }
}

/**
 * The 9:16 result pane (D10): empty, in line (heavy blur, line position), rendering (blur clears as % rises, the named
 * step), ready (plays inline, muted loop) or failed (plain words, retry free, a cheaper/next tier). [art]: the blurred
 * source or character.
 */
@Composable
fun BoxScope.SuiteResultPane(
    pane: SuitePane, art: ImageRef?, emptyTitle: String = "Your shot appears here", emptyHint: String = "Pick a character, describe the moment, press Generate.",
    onRetry: () -> Unit = {}, onTry: (() -> Unit)? = null, tryLabel: String? = null, onOpen: (() -> Unit)? = null, compact: Boolean = false,
) {
    val m = muse
    when (pane.phase) {
        StagePhase.IDLE -> {
            Box(Modifier.matchParentSize().background(m.t.surface2))
            if (art != null) RefImage(art, Modifier.matchParentSize(), 20)
            Box(Modifier.matchParentSize().background(Color.Black.copy(alpha = if (art != null) .28f else 0f)))
            Column(Modifier.align(Alignment.Center).padding(24.dp).widthIn(max = 280.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                val fg = if (art != null) Color.White else m.t.ink
                T(emptyTitle, m.type.h2.copy(fontSize = if (compact) 24.sp else 30.sp, lineHeight = if (compact) 26.sp else 32.sp), fg, align = TextAlign.Center)
                T(emptyHint, m.type.tiny, fg.copy(alpha = .85f), align = TextAlign.Center)
            }
        }
        StagePhase.QUEUED -> {
            BlurredStageArt(art, moving = true)
            Box(Modifier.align(Alignment.Center).background(Color(0xFF141210)).padding(horizontal = 10.dp, vertical = 5.dp)) {
                T(pane.badge.uppercase(), m.type.mono.copy(fontSize = 12.sp, letterSpacing = 1.sp), Color.White, maxLines = 1)
            }
            T(pane.step, m.type.tiny, Color.White.copy(alpha = .9f), Modifier.align(Alignment.BottomCenter).padding(14.dp), align = TextAlign.Center)
        }
        StagePhase.RENDERING -> {
            BlurredStageArt(art, moving = true)
            Box(Modifier.matchParentSize().background(Color.White.copy(alpha = (.32f * (1f - pane.progress)).coerceAtLeast(0f))))
            Column(Modifier.align(Alignment.Center).padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                T(pane.headline.uppercase(), m.type.mono.copy(fontSize = 11.sp, letterSpacing = 1.4.sp), Color.White, maxLines = 1)
                T(pane.percent, studio.muse.app.ui.theme.museFor(studio.muse.app.ui.theme.ThemeId.A).type.h2.copy(fontSize = if (compact) 48.sp else 64.sp, lineHeight = if (compact) 48.sp else 62.sp), Color.White)
                Bar(pane.progress, Modifier.width(150.dp), Color.White, 3.dp, Color.White.copy(alpha = .3f))
                T(pane.step, m.type.tiny, Color.White.copy(alpha = .92f), align = TextAlign.Center, maxLines = 2)
            }
        }
        StagePhase.READY -> {
            val take = pane.takes.firstOrNull()
            val url = take?.videoUrl
            if (take != null && url != null) StageVideo(url, take.thumb, true, Modifier.matchParentSize())
            else RefImage(take?.thumb ?: art, Modifier.matchParentSize(), 20)
            Box(Modifier.align(Alignment.Center).size(48.dp).clip(RoundedCornerShape(999.dp)).background(Color.White.copy(alpha = .9f)).let { if (onOpen != null) it.press(onClick = onOpen) else it }
                .semantics { contentDescription = "Play" }, contentAlignment = Alignment.Center) { Ic("play", 20.dp, Ink) }
        }
        StagePhase.FAILED -> {
            BlurredStageArt(art, moving = false)
            Column(Modifier.align(Alignment.Center).padding(20.dp).widthIn(max = 300.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                T("This take didn't work", m.type.h2.copy(fontSize = 26.sp, lineHeight = 28.sp), Color.White, align = TextAlign.Center)
                T(pane.failure ?: "We stopped early. You weren't charged.", m.type.tiny, Color.White.copy(alpha = .92f), align = TextAlign.Center, maxLines = 3)
                StageButton("Retry free", onRetry, primary = true, icon = "retry")
                if (onTry != null && tryLabel != null) StageButton(tryLabel, onTry)
            }
        }
    }
}

/** A suite tile frame: the theme's card border (D's sticker shadow). */
fun Modifier.suiteCard(m: studio.muse.app.ui.theme.Muse, on: Boolean = false): Modifier {
    val shape = RoundedCornerShape(if (m.isA) 2.dp else m.t.r)
    val base = if (m.isD) this.hardShadow(3.dp, m.t.r) else this
    return base.clip(shape).background(m.t.surface).border(if (on) 2.dp else if (m.isD) 2.5.dp else 1.dp, if (on) (if (m.isD) Ink else m.t.ink) else m.t.line, shape)
}

/** Section label in ink ("CAMERA BODIES"). */
@Composable
fun SLbl(text: String, modifier: Modifier = Modifier, color: Color = muse.t.ink) =
    T(text.uppercase(), muse.type.mono.copy(fontSize = 11.sp, letterSpacing = 1.4.sp, fontWeight = FontWeight.Medium), color, modifier, maxLines = 1)

@Composable
fun SuiteFill(modifier: Modifier = Modifier) = Box(modifier.fillMaxSize())

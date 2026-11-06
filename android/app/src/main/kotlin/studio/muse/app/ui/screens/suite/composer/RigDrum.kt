package studio.muse.app.ui.screens.suite.composer

import android.provider.Settings
import android.view.HapticFeedbackConstants
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ColorMatrix
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import studio.muse.app.ui.components.T
import studio.muse.app.ui.screens.suite.HardwareImages
import studio.muse.app.ui.theme.MuseRoles
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.scale
import studio.muse.core.RigDrumMath
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

// Workstream 4: the rig's drum picker, a faithful port of the owner-approved prototype (design/drum-wheels-prototype.html):
// unboxed hardware renders with a soft vignette, the focal wedge, the amber iris and the dashed "A" for Auto, the same 3D
// tilt, scale and fade, 84 dp rows (112 on a tablet) and one band across all four drums. One component for every HARDWARE
// choice: Camera → Setup (body, lens, focal, aperture), which the Photo tool's rig reuses. Non-hardware choices use grids.

/** The prototype's camera-bag colours (its :root): the panel matches the renders' own backdrop so they sit unboxed. */
object DrumBag {
    val panel = Color(0xFF141414)
    val band = Color.White.copy(alpha = .055f)
    val hair = Color.White.copy(alpha = .14f)
    val ink = Color(0xFFECE8E1)
    val dim = Color(0xFF8F8A82)
    val amber = Color(0xFFE7A54A)
}

/** One detent: 84 dp on a phone, 112 on a tablet (the prototype's --item). */
fun drumRow(wide: Boolean): Dp = if (wide) 112.dp else 84.dp

private val LABEL_H = 18.dp
private val GAP = 10.dp

/**
 * One drum column: [label], five rows with the selection centred, the item's name and caption under it. Drag follows the
 * finger and flings onto a detent; every detent ticks the haptics; a tap on a row goes to it. [onSelect] runs once the
 * drum settles on a new item. Drums of five or more items loop. [band] draws the selection band for a drum on its own;
 * [RigDrums] draws one band across all of them instead.
 */
@Composable
fun RigDrum(label: String, items: List<WheelItem>, selected: Int, onSelect: (WheelItem) -> Unit, modifier: Modifier = Modifier,
            rowHeight: Dp = 84.dp, band: Boolean = true) {
    val m = muse
    val n = items.size
    if (n == 0) return
    val loop = RigDrumMath.loops(n)
    val view = LocalView.current
    val ctx = LocalContext.current
    val reduce = remember { runCatching { Settings.Global.getFloat(ctx.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }.getOrDefault(false) }
    val pick by rememberUpdatedState(onSelect)
    val scope = rememberCoroutineScope()
    val rowPx = with(LocalDensity.current) { rowHeight.toPx() }
    val wide = rowHeight > 100.dp

    var pos by remember { mutableDoubleStateOf(selected.coerceIn(0, n - 1).toDouble()) }
    var shown by remember { mutableIntStateOf(selected.coerceIn(0, n - 1)) }   // the item under the band (ticks the haptics)
    var busy by remember { mutableStateOf(false) }                               // dragging or animating
    var job by remember { mutableStateOf<Job?>(null) }

    fun moveTo(p: Double) {
        pos = p
        val near = RigDrumMath.nearest(p, n, loop)
        if (near != shown) { shown = near; view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK) }
    }
    fun commit() {
        busy = false
        val near = RigDrumMath.nearest(pos, n, loop)
        if (near != selected) pick(items[near])
    }
    /** Settle on [target] (an unwrapped detent) with the critically damped spring; [v0] carries a fling's speed. */
    fun snapTo(target: Double, v0: Double = 0.0) {
        job?.cancel(); busy = true
        job = scope.launch {
            if (reduce) { moveTo(target); commit(); return@launch }
            var x = pos - target; var v = v0; var last = withFrameNanos { it }
            while (!RigDrumMath.settled(x, v)) {
                val now = withFrameNanos { it }
                val (nx, nv) = RigDrumMath.springStep(x, v, (now - last) / 1e9); last = now
                x = nx; v = nv; moveTo(target + x)
            }
            moveTo(target); commit()
        }
    }
    fun fling(velocity: Double) {
        job?.cancel(); busy = true
        if (reduce) { snapTo(RigDrumMath.flingTarget(pos, velocity, n, loop)); return }
        val start = pos
        val target = RigDrumMath.flingTarget(start, velocity, n, loop)
        job = scope.launch {
            val t0 = withFrameNanos { it }
            while (true) {
                val t = (withFrameNanos { it } - t0) / 1e9
                val p = RigDrumMath.decay(start, target, t)
                moveTo(p)
                if (abs(p - target) < 0.06) { snapTo(target, (target - p) / RigDrumMath.TAU); break }
            }
        }
    }
    fun goTo(i: Int) = snapTo(pos + RigDrumMath.delta(i, pos, n, loop))

    // An outside change (Reset all, a preset): turn the drum to it.
    LaunchedEffect(selected, n) { if (!busy && RigDrumMath.nearest(pos, n, loop) != selected.coerceIn(0, n - 1)) goTo(selected.coerceIn(0, n - 1)) }

    val item = items[shown]
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.height(LABEL_H), contentAlignment = Alignment.Center) {
            T(label, m.scale.caption.copy(fontSize = if (wide) 13.sp else 12.sp, lineHeight = 16.sp), DrumBag.dim, maxLines = 1)
        }
        Spacer(Modifier.height(GAP))
        BoxWithConstraints(
            Modifier.fillMaxWidth().height(rowHeight * 5)
                // The drum fades into the panel at the top and bottom (the prototype's mask).
                .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
                .drawWithContent {
                    drawContent()
                    drawRect(Brush.verticalGradient(0f to Color.Transparent, .22f to Color.Black, .78f to Color.Black, 1f to Color.Transparent), blendMode = BlendMode.DstIn)
                }
                .semantics {
                    contentDescription = label
                    stateDescription = listOf(item.name, item.caption).filter { it.isNotBlank() }.joinToString(", ")
                    progressBarRangeInfo = ProgressBarRangeInfo(shown.toFloat(), 0f..(n - 1).toFloat(), steps = (n - 2).coerceAtLeast(0))
                    setProgress { v -> goTo(v.roundToInt().coerceIn(0, n - 1)); true }
                }
                .pointerInput(n, loop) {
                    val tracker = VelocityTracker()
                    var startPos = 0.0; var dragged = 0f
                    detectVerticalDragGestures(
                        onDragStart = { job?.cancel(); busy = true; tracker.resetTracking(); startPos = pos; dragged = 0f },
                        onDragEnd = {
                            val v = -tracker.calculateVelocity().y / rowPx.toDouble()
                            val last = (n - 1).toDouble()
                            if ((!loop && (pos < 0 || pos > last)) || abs(v) < 0.8) snapTo(RigDrumMath.roundHalfUp(pos).let { if (loop) it else it.coerceIn(0.0, last) })
                            else fling(v)
                        },
                        onDragCancel = { snapTo(RigDrumMath.roundHalfUp(pos)) },
                    ) { change, dy ->
                        tracker.addPosition(change.uptimeMillis, change.position)
                        dragged += dy
                        moveTo(RigDrumMath.clampSoft(startPos - dragged / rowPx, n, loop))
                    }
                }
                .pointerInput(n, loop) {
                    // A tap on a row turns the drum to that row.
                    detectTapGestures { o -> goTo(RigDrumMath.nearest(pos + ((o.y - size.height / 2f) / rowPx).toDouble(), n, loop)) }
                },
            contentAlignment = Alignment.Center,
        ) {
            if (band) DrumBand(rowHeight)
            val face = min(rowHeight.value * .96f, maxWidth.value * .92f).dp
            // The prototype's 3D: the drum radius puts neighbours one detent apart; translateZ under a 700 px perspective.
            val radius = rowHeight.value / (2 * sin(RigDrumMath.STEP_DEGREES * PI / 360)).toFloat()
            items.forEachIndexed { i, it ->
                val d = RigDrumMath.delta(i, pos, n, loop)
                if (abs(d) > 2.6) return@forEachIndexed
                val look = RigDrumMath.look(d, rowPx.toDouble(), selected = i == shown)
                if (!look.visible) return@forEachIndexed
                val z = radius * (cos(d * RigDrumMath.STEP_DEGREES * PI / 180).toFloat() - 1)
                val persp = 700f / (700f - z)
                Box(
                    Modifier.size(face).offset { IntOffset(0, (look.y * persp).roundToInt()) }.graphicsLayer {
                        val s = look.scale.toFloat() * persp
                        scaleX = s; scaleY = s; alpha = look.alpha.toFloat()
                        rotationX = look.rotationDegrees.toFloat(); cameraDistance = 9.7f * density
                    },
                    contentAlignment = Alignment.Center,
                ) { DrumFace(it, look.brightness.toFloat()) }
            }
        }
        Spacer(Modifier.height(GAP))
        Crossfade(shown, animationSpec = tween(if (reduce) 0 else 180), label = "drum-name") { k ->
            val w = items[k.coerceIn(0, n - 1)]
            Column(Modifier.fillMaxWidth().heightIn(min = 50.dp).padding(horizontal = 4.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                T(w.name, TextStyle(fontFamily = m.scale.displayFamily, fontSize = if (wide) 14.5.sp else 13.sp, lineHeight = if (wide) 17.sp else 15.6.sp,
                    fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center), DrumBag.ink, maxLines = 2)
                if (w.caption.isNotBlank()) T(w.caption, TextStyle(fontFamily = m.scale.textFamily, fontSize = if (wide) 10.5.sp else 9.5.sp,
                    lineHeight = if (wide) 14.sp else 12.8.sp, textAlign = TextAlign.Center), DrumBag.dim, Modifier.padding(top = 3.dp), maxLines = 2)
            }
        }
    }
}

/** The one selection band: a faint fill with hairlines top and bottom. */
@Composable
private fun DrumBand(rowHeight: Dp, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().height(rowHeight).background(DrumBag.band)) {
        Box(Modifier.fillMaxWidth().height(1.dp).background(DrumBag.hair).align(Alignment.TopCenter))
        Box(Modifier.fillMaxWidth().height(1.dp).background(DrumBag.hair).align(Alignment.BottomCenter))
    }
}

/** An item on the drum: the unboxed render with its vignette, or the prototype's drawing; [bright] dims it off the band. */
@Composable
private fun DrumFace(it: WheelItem, bright: Float) {
    val draw = it.preview.draw
    when {
        it.id == null -> DrumGlyph { s -> autoGlyph(s, bright) }
        draw is PreviewDraw.Focal -> DrumGlyph { s -> focalGlyph(s, draw.mm, bright) }
        draw is PreviewDraw.Iris -> DrumGlyph { s -> irisGlyph(s, draw.fStop, bright) }
        else -> {
            val ctx = LocalContext.current
            val render = it.preview.still
            val bmp = remember(render) { HardwareImages.load(ctx, render, 2) }
            val filter = remember(bright) { ColorFilter.colorMatrix(ColorMatrix().apply { setToScale(bright, bright, bright, 1f) }) }
            if (bmp != null) Image(bmp, it.name, Modifier.fillMaxSize()
                // The prototype's radial mask: solid to 62 % of the closest side, then fading out, so the render melts into the bag.
                .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
                .drawWithContent {
                    drawContent()
                    val r = size.minDimension / 2
                    drawRect(Brush.radialGradient(0f to Color.Black, .62f to Color.Black, 1f to Color.Transparent, center = center, radius = r), blendMode = BlendMode.DstIn)
                }, contentScale = ContentScale.Fit, colorFilter = filter)
        }
    }
}

@Composable
private fun DrumGlyph(paint: DrawScope.(Float) -> Unit) {
    Canvas(Modifier.fillMaxSize()) { paint(size.minDimension / 100f) }
}

private fun dimmed(c: Color, bright: Float, alpha: Float) = Color(c.red * bright, c.green * bright, c.blue * bright, alpha)

/** Auto: a dashed circle with an "A" (the prototype's drawing, in a 100-unit box). */
private fun DrawScope.autoGlyph(u: Float, bright: Float) {
    val o = Offset((size.width - 100 * u) / 2, (size.height - 100 * u) / 2)
    drawCircle(dimmed(DrumBag.ink, bright, .55f), 30 * u, o + Offset(50 * u, 50 * u),
        style = Stroke(2 * u, pathEffect = PathEffect.dashPathEffect(floatArrayOf(4 * u, 5 * u))))
    // The "A": two strokes and a bar, drawn rather than typeset so it sits exactly in the circle on both platforms.
    val a = Path().apply {
        moveTo(o.x + 43 * u, o.y + 59 * u); lineTo(o.x + 50 * u, o.y + 41 * u); lineTo(o.x + 57 * u, o.y + 59 * u)
        moveTo(o.x + 45.6f * u, o.y + 53 * u); lineTo(o.x + 54.4f * u, o.y + 53 * u)
    }
    drawPath(a, dimmed(DrumBag.ink, bright, .8f), style = Stroke(1.8f * u))
}

/** Focal length: the horizontal field-of-view wedge from a small camera block; narrower as the focal length grows. */
private fun DrawScope.focalGlyph(u: Float, mm: Int, bright: Float) {
    val o = Offset((size.width - 100 * u) / 2, (size.height - 100 * u) / 2)
    val half = atan(36.0 / (2.0 * mm)); val l = 64f; val a = min(half, 1.2)
    val deg = (a * 180 / PI).toFloat()
    val wedge = Path().apply {
        moveTo(o.x + 18 * u, o.y + 50 * u)
        arcTo(Rect(Offset(o.x + (18 - l) * u, o.y + (50 - l) * u), Size(2 * l * u, 2 * l * u)), -deg, 2 * deg, false)
        close()
    }
    drawPath(wedge, dimmed(DrumBag.amber, bright, .16f))
    drawPath(wedge, dimmed(DrumBag.amber, bright, .8f), style = Stroke(1.6f * u))
    drawRoundRect(dimmed(DrumBag.ink, bright, .85f), Offset(o.x + 8 * u, o.y + 42 * u), Size(12 * u, 16 * u),
        androidx.compose.ui.geometry.CornerRadius(2 * u, 2 * u))
}

/** Aperture: the amber iris; its seven blades open wider at small f-numbers. */
private fun DrawScope.irisGlyph(u: Float, f: Double, bright: Float) {
    val o = Offset((size.width - 100 * u) / 2, (size.height - 100 * u) / 2)
    val c = o + Offset(50 * u, 50 * u)
    val open = (6 + 30 * sqrt(1.4 / f)).toFloat()
    drawCircle(dimmed(DrumBag.ink, bright, .7f), 38 * u, c, style = Stroke(2 * u))
    for (k in 0 until 7) {
        val t = k * 2 * PI / 7
        val p1 = c + Offset((open * cos(t)).toFloat() * u, (open * sin(t)).toFloat() * u)
        val p2 = c + Offset((38 * cos(t + 1.1)).toFloat() * u, (38 * sin(t + 1.1)).toFloat() * u)
        drawLine(dimmed(DrumBag.ink, bright, .5f), p1, p2, 1.4f * u)
    }
    drawCircle(dimmed(DrumBag.amber, bright, .22f), open * u, c)
    drawCircle(dimmed(DrumBag.amber, bright, 1f), open * u, c, style = Stroke(1.6f * u))
}

/**
 * The rig's hardware drums side by side on the camera-bag panel, under one selection band (the prototype's .bag):
 * [drums] get their column modifier and must pass `band = false` and [rowHeight].
 */
@Composable
fun RigDrums(rowHeight: Dp, drums: List<@Composable (Modifier) -> Unit>, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(DrumBag.panel).padding(start = 6.dp, end = 6.dp, top = 14.dp, bottom = 16.dp)) {
        DrumBand(rowHeight, Modifier.offset(y = LABEL_H + GAP + rowHeight * 2).padding(horizontal = 0.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(0.dp), verticalAlignment = Alignment.Top) {
            drums.forEach { it(Modifier.weight(1f)) }
        }
    }
}

/** The prototype's live rig line: an amber tally dot and the four picks ("35mm film · Warm vintage · 35 mm · f/2.8"). */
@Composable
fun RigLine(names: List<String>, modifier: Modifier = Modifier) {
    val m = muse
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(14.dp), contentAlignment = Alignment.Center) {
            Box(Modifier.size(14.dp).background(Brush.radialGradient(listOf(DrumBag.amber.copy(alpha = .45f), Color.Transparent)), CircleShape))
            Box(Modifier.size(7.dp).background(DrumBag.amber, CircleShape))
        }
        Spacer(Modifier.width(6.dp))
        androidx.compose.material3.Text(buildAnnotatedString {
            names.forEachIndexed { i, s ->
                if (i > 0) withStyle(SpanStyle(color = DrumBag.dim)) { append("  ·  ") }
                withStyle(SpanStyle(color = DrumBag.ink, fontWeight = FontWeight.Medium)) { append(s) }
            }
        }, style = TextStyle(fontFamily = m.scale.textFamily, fontSize = 13.sp, lineHeight = 18.sp, color = DrumBag.ink), maxLines = 1)
    }
}

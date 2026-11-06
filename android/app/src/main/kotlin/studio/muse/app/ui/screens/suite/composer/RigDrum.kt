package studio.muse.app.ui.screens.suite.composer

import android.provider.Settings
import android.view.HapticFeedbackConstants
import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import studio.muse.app.ui.components.T
import studio.muse.app.ui.screens.suite.SIc
import studio.muse.app.ui.theme.MuseRoles
import studio.muse.app.ui.theme.muse
import studio.muse.core.RigDrumMath
import kotlin.math.abs
import kotlin.math.roundToInt

// Workstream 4: the rig's drum picker, approved by the owner (design/drum-wheels-prototype.html, plans/design-direction.md
// §9 picker-b). One component for every HARDWARE choice: Camera → Setup (body, lens, focal, aperture) and any other rig
// that picks hardware (the Photo tool's Setup). Non-hardware choices (Angle, Movement, Lighting, Look, Style) use grids.

/**
 * One drum: [label] above, five rows visible, the selection centred in one band, neighbours shrinking, dimming and
 * tilting away. Drag follows the finger and flings onto a detent; every detent ticks the haptics; a tap on a row goes to
 * it. [onSelect] runs once the drum settles on a new item. Drums of five or more items loop. Item pictures are the
 * hardware renders (or the focal / iris drawings); Auto (null id) is the aperture mark on a disc.
 */
@Composable
fun RigDrum(label: String, items: List<WheelItem>, selected: Int, onSelect: (WheelItem) -> Unit, modifier: Modifier = Modifier, rowHeight: Dp = 64.dp) {
    val m = muse
    val bag = MuseRoles.bag   // the camera bag is dark in every theme (design tokens, §9)
    val n = items.size
    if (n == 0) return
    val loop = RigDrumMath.loops(n)
    val view = LocalView.current
    val ctx = LocalContext.current
    val reduce = remember { runCatching { Settings.Global.getFloat(ctx.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }.getOrDefault(false) }
    val pick by rememberUpdatedState(onSelect)
    val scope = rememberCoroutineScope()
    val rowPx = with(LocalDensity.current) { rowHeight.toPx() }

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
        T(label, m.type.body.copy(fontSize = 13.sp, lineHeight = 18.sp), bag.ink2, Modifier.padding(bottom = 6.dp), maxLines = 1)
        BoxWithConstraints(
            Modifier.fillMaxWidth().height(rowHeight * 5).clip(RoundedCornerShape(0.dp))
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
            // The one selection mark: a band with hairlines.
            Box(Modifier.fillMaxWidth().height(rowHeight).background(bag.field.copy(alpha = .6f)))
            Box(Modifier.fillMaxWidth().height(rowHeight).padding(0.dp)) {
                Box(Modifier.fillMaxWidth().height(1.dp).background(bag.hairline).align(Alignment.TopCenter))
                Box(Modifier.fillMaxWidth().height(1.dp).background(bag.hairline).align(Alignment.BottomCenter))
            }
            items.forEachIndexed { i, it ->
                val d = RigDrumMath.delta(i, pos, n, loop)
                if (abs(d) > 2.6) return@forEachIndexed
                val look = RigDrumMath.look(d, rowPx.toDouble(), selected = i == shown)
                if (!look.visible) return@forEachIndexed
                Box(
                    Modifier.size(rowHeight).offset { IntOffset(0, look.y.roundToInt()) }.graphicsLayer {
                        scaleX = look.scale.toFloat(); scaleY = look.scale.toFloat(); alpha = look.alpha.toFloat()
                        rotationX = look.rotationDegrees.toFloat(); cameraDistance = 12f * density
                    },
                    contentAlignment = Alignment.Center,
                ) {
                    DrumFace(it, Modifier.size(rowHeight - 4.dp))
                    if (look.brightness < 1) Box(Modifier.size(rowHeight).background(Color.Black.copy(alpha = (1 - look.brightness).toFloat())))
                }
            }
        }
        Crossfade(shown, animationSpec = tween(if (reduce) 0 else 200), label = "drum-name") { k ->
            val w = items[k.coerceIn(0, n - 1)]
            Column(Modifier.fillMaxWidth().heightIn(min = 54.dp).padding(top = 8.dp, start = 2.dp, end = 2.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                T(w.name, m.type.body.copy(fontSize = 14.sp, lineHeight = 18.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center), bag.ink, maxLines = 1)
                if (w.caption.isNotBlank()) T(w.caption, m.type.body.copy(fontSize = 12.sp, lineHeight = 16.sp, textAlign = TextAlign.Center), bag.ink2, maxLines = 2)
            }
        }
    }
}

/** An item's face on the drum: Auto is the aperture mark on a disc; the rest are their render or drawing. */
@Composable
private fun DrumFace(it: WheelItem, modifier: Modifier) {
    val bag = MuseRoles.bag
    if (it.id == null) Box(modifier.padding(4.dp).clip(CircleShape).background(bag.field), contentAlignment = Alignment.Center) { SIc("aperture", 26.dp, bag.ink) }
    else PreviewTile(it.preview, modifier.clip(RoundedCornerShape(8.dp)))
}

/** The rig's hardware drums side by side (Camera → Setup). */
@Composable
fun RigDrums(drums: List<@Composable (Modifier) -> Unit>, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth().padding(horizontal = 8.dp), horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.Top) {
        drums.forEach { it(Modifier.weight(1f)) }
    }
}

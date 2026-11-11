package studio.muse.app.ui.components

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.VectorConverter
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import coil3.compose.AsyncImage
import kotlinx.coroutines.launch
import studio.muse.app.data.ImageRef
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse
import studio.muse.app.ui.theme.scale

/** One picture in [ImageViewer]: the image and what it is ("Front", "¾"…). A null image is a slot still being made. */
data class ViewerImage(val ref: ImageRef?, val label: String)

/** A text action in the viewer's top bar for the picture shown (the outfit's "Redo · $0.03"). */
data class ViewerAction(val label: String, val onClick: () -> Unit, val enabled: Boolean = true)

/** How far a pinch can zoom in, and where a double tap lands. */
private const val MAX_ZOOM = 5f
private const val DOUBLE_TAP_ZOOM = 2.5f

/**
 * The full-screen picture viewer (owner request, 2026-11-08: "view the outfit's images full size"). Black, edge to edge,
 * the picture fitted whole. Pinch or double tap to zoom (up to 5×), drag to look around while zoomed, swipe between
 * pictures at 1×. Back or the close button leaves it. Shown in a full-screen [Dialog] so it covers the bars.
 */
@Composable
fun ImageViewer(images: List<ViewerImage>, start: Int, action: ((Int) -> ViewerAction?)? = null, onClose: () -> Unit) {
    Dialog(onClose, DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        ImageViewerContent(images, start, onClose, action = action)
    }
}

/** [ImageViewer]'s content, without the window (screenshot tests render this directly). */
@Composable
fun ImageViewerContent(images: List<ViewerImage>, start: Int, onClose: () -> Unit, modifier: Modifier = Modifier, action: ((Int) -> ViewerAction?)? = null) {
    val pager = rememberPagerState(initialPage = start.coerceIn(0, (images.size - 1).coerceAtLeast(0))) { images.size }
    // Each page's zoom; swiping between pictures only works at 1× (a zoomed picture pans instead).
    val zoomed = remember { mutableStateMapOf<Int, Boolean>() }
    val current = images.getOrNull(pager.currentPage)
    Box(modifier.fillMaxSize().background(Color.Black).testTag("image_viewer")) {
        HorizontalPager(pager, Modifier.fillMaxSize(), userScrollEnabled = zoomed[pager.currentPage] != true, key = { it }) { p ->
            ZoomableImage(images[p].ref, images[p].label, active = p == pager.currentPage, onZoomed = { zoomed[p] = it })
        }
        Row(
            Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 4.dp).height(56.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier.size(48.dp).clip(CircleShape).pointerInput(Unit) { detectTapGestures { onClose() } }
                    .semantics { contentDescription = "Close"; role = Role.Button },
                contentAlignment = Alignment.Center,
            ) { Ic("x", 24.dp, Color.White) }
            Column(Modifier.padding(start = 4.dp).weight(1f)) {
                T(current?.label.orEmpty(), muse.scale.title.copy(fontSize = muse.scale.body.fontSize), Color.White, maxLines = 1)
                if (images.size > 1) T("${pager.currentPage + 1} of ${images.size}", muse.scale.caption, Color.White.copy(alpha = .72f), maxLines = 1)
            }
            // The action for the picture shown (one quiet text button, white on the black bar).
            action?.invoke(pager.currentPage)?.let { a ->
                Box(
                    Modifier.height(48.dp).press(enabled = a.enabled, onClick = a.onClick).padding(horizontal = 12.dp)
                        .semantics { contentDescription = a.label; role = Role.Button },
                    contentAlignment = Alignment.Center,
                ) { T(a.label, muse.scale.label, Color.White.copy(alpha = if (a.enabled) 1f else .5f), maxLines = 1) }
            }
        }
        // Where you are in the set, as dots along the bottom (only with more than one picture).
        if (images.size > 1) Row(
            Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 20.dp),
            horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp),
        ) {
            images.indices.forEach { i ->
                Box(Modifier.size(6.dp).clip(CircleShape).background(Color.White.copy(alpha = if (i == pager.currentPage) 1f else .35f)))
            }
        }
    }
}

/**
 * One picture: fitted, pinch and double-tap zoom, pan while zoomed (kept inside the picture's edges). At 1× it leaves
 * one-finger drags alone so the pager can swipe. Going off-screen resets it to 1×.
 */
@Composable
private fun ZoomableImage(ref: ImageRef?, label: String, active: Boolean, onZoomed: (Boolean) -> Unit) {
    val scale = remember { Animatable(1f) }
    val offset = remember { Animatable(Offset.Zero, Offset.VectorConverter) }
    val scope = rememberCoroutineScope()
    fun clamp(o: Offset, s: Float, box: IntSize): Offset {
        val maxX = box.width * (s - 1f) / 2f
        val maxY = box.height * (s - 1f) / 2f
        return Offset(o.x.coerceIn(-maxX, maxX), o.y.coerceIn(-maxY, maxY))
    }
    LaunchedEffect(active) { if (!active) { scale.snapTo(1f); offset.snapTo(Offset.Zero) } }
    LaunchedEffect(Unit) { snapshotFlow { scale.value > 1.01f }.collect(onZoomed) }
    Box(
        Modifier.fillMaxSize()
            .pointerInput(Unit) {
                detectTapGestures(onDoubleTap = { at ->
                    scope.launch {
                        if (scale.value > 1.01f) { launch { scale.animateTo(1f) }; offset.animateTo(Offset.Zero) }
                        else {
                            // Zoom towards the tapped point.
                            val target = clamp((Offset(size.width / 2f, size.height / 2f) - at) * (DOUBLE_TAP_ZOOM - 1f), DOUBLE_TAP_ZOOM, size)
                            launch { scale.animateTo(DOUBLE_TAP_ZOOM) }; offset.animateTo(target)
                        }
                    }
                })
            }
            .pointerInput(Unit) {
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false)
                    do {
                        val event = awaitPointerEvent()
                        val fingers = event.changes.count { it.pressed }
                        // One finger at 1× belongs to the pager (swipe to the next picture).
                        if (fingers < 2 && scale.value <= 1.01f) continue
                        val zoom = event.calculateZoom()
                        val pan = event.calculatePan()
                        val centroid = event.calculateCentroid(useCurrent = true)
                        val s = (scale.value * zoom).coerceIn(1f, MAX_ZOOM)
                        val center = Offset(size.width / 2f, size.height / 2f)
                        // Keep the point under the fingers still while zooming.
                        val z = s / scale.value
                        val o = clamp(offset.value * z + (centroid - center) * (1f - z) + pan, s, size)
                        scope.launch { scale.snapTo(s); offset.snapTo(o) }
                        event.changes.forEach { if (it.positionChanged()) it.consume() }
                    } while (event.changes.any { it.pressed })
                }
            }
            .semantics { contentDescription = label; stateDescription = if (scale.value > 1.01f) "Zoomed in" else "Fitted" },
        contentAlignment = Alignment.Center,
    ) {
        val layer = Modifier.fillMaxSize().graphicsLayer {
            scaleX = scale.value; scaleY = scale.value
            translationX = offset.value.x; translationY = offset.value.y
        }
        val res = assetRes(ref?.asset)
        when {
            res != null -> Image(painterResource(res), null, layer, contentScale = ContentScale.Fit)
            ref?.url != null -> AsyncImage(ref.url, null, layer, contentScale = ContentScale.Fit)
            else -> T("Still being made", muse.scale.caption, Color.White.copy(alpha = .72f))
        }
    }
}

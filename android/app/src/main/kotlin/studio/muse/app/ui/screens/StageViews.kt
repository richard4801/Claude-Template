package studio.muse.app.ui.screens

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import studio.muse.app.data.ImageRef
import studio.muse.app.data.Take
import studio.muse.app.data.editable
import studio.muse.app.ui.components.Bar
import studio.muse.app.ui.components.ClipPlaceholder
import studio.muse.app.ui.components.FlowRow
import studio.muse.app.ui.components.Ink
import studio.muse.app.ui.components.RefImage
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.press
import studio.muse.app.ui.theme.Ic
import studio.muse.app.ui.theme.muse

// The Video studio's stage (owner request 2026-11-05): the canvas shows the source and the target while idle, the render's
// live state while it runs (blurred, softly moving, phase, progress and price), the finished take playing (muted loop with
// an unmute button, Open / Edit video / Generate again, a take switcher), or what went wrong with Try again. Member-safe
// wording only (`StudioStage`).

/** No clip yet: an empty placeholder (never a sample performer). Tapping it goes to choose one. */
@Composable
fun BoxScope.StageEmptySource(onChoose: () -> Unit) {
    val m = muse
    Box(Modifier.matchParentSize().background(m.t.surface2).press(onClick = onChoose), contentAlignment = Alignment.Center) {
        Column(Modifier.padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Box(Modifier.size(48.dp).clip(CircleShape).background(m.t.surface).let { if (m.isD) it.border(2.dp, Ink, CircleShape) else it }, contentAlignment = Alignment.Center) {
                Ic("upload", 22.dp, m.t.ink)
            }
            T("No clip yet", m.type.body.copy(fontWeight = FontWeight.Bold), m.t.ink)
            T("${StudioText.CHOOSE_TITLE} · ${StudioText.CHOOSE_HINT.replaceFirstChar { it.lowercase() }}", m.type.tiny, m.t.muted, align = TextAlign.Center)
        }
    }
}

/** The busy stage's picture: blurred, breathing slowly, with a soft light passing over it. [moving] false keeps it still. */
@Composable
fun BoxScope.BlurredStageArt(ref: ImageRef?, moving: Boolean) {
    val tr = rememberInfiniteTransition(label = "stage")
    // Read in the layer and draw phases only, so the animation never recomposes the stage.
    val breathe = tr.animateFloat(0f, 1f, infiniteRepeatable(tween(3000, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "breathe")
    val sweep = tr.animateFloat(-0.4f, 1.4f, infiniteRepeatable(tween(2600, easing = LinearEasing), RepeatMode.Restart), label = "sweep")
    Box(Modifier.matchParentSize().graphicsLayer { val s = 1.06f + (if (moving) .08f * breathe.value else 0f); scaleX = s; scaleY = s }.blur(18.dp)) {
        if (ref != null) RefImage(ref, Modifier.fillMaxSize(), 25) else ClipPlaceholder(Modifier.fillMaxSize(), 1, showPlay = false)
    }
    // A dark veil keeps the text readable (and stands in for the blur on phones older than Android 12).
    Box(
        Modifier.matchParentSize().background(Color.Black.copy(alpha = .38f)).drawWithContent {
            drawContent()
            if (moving) {
                val y = size.height * sweep.value
                drawRect(Brush.verticalGradient(listOf(Color.Transparent, Color.White.copy(alpha = .14f), Color.Transparent), startY = y - size.height * .25f, endY = y + size.height * .25f))
            }
        },
    )
}

/** Waiting or rendering: the phase, a progress bar (a gliding segment while waiting), the percent and the price. */
@Composable
fun BoxScope.StageBusy(stage: StudioStage, art: ImageRef?) {
    val m = muse
    BlurredStageArt(art, moving = true)
    Column(
        Modifier.align(Alignment.Center).padding(horizontal = 28.dp).widthIn(max = 300.dp).fillMaxWidth()
            .clip(RoundedCornerShape(if (m.isA) 2.dp else 14.dp)).background(Color.Black.copy(alpha = .35f)).padding(14.dp)
            .semantics(mergeDescendants = true) {},
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        T(stage.headline, m.type.body.copy(fontWeight = FontWeight.Bold, fontSize = 16.sp, lineHeight = 21.sp), Color.White, maxLines = 3)
        if (stage.phase == StagePhase.QUEUED) WaitingBar() else Bar(stage.progress, Modifier.fillMaxWidth(), Color.White, 5.dp, Color.White.copy(alpha = .25f))
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            if (stage.phase == StagePhase.RENDERING) T(stage.percent, m.type.mono.copy(fontSize = 13.sp), Color.White)
            Spacer(Modifier.weight(1f))
            T(stage.price, m.type.mono.copy(fontSize = 13.sp), Color.White)
        }
    }
}

/** Waiting to start: a soft segment gliding along the track (no progress to show yet). */
@Composable
private fun WaitingBar() {
    val tr = rememberInfiniteTransition(label = "wait")
    val x = tr.animateFloat(0f, 1f, infiniteRepeatable(tween(1400, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "x")
    Box(Modifier.fillMaxWidth().height(5.dp).clip(RoundedCornerShape(3.dp)).background(Color.White.copy(alpha = .25f)).drawWithContent {
        drawContent()
        val w = size.width * .3f
        drawRoundRect(Color.White.copy(alpha = .85f), topLeft = Offset((size.width - w) * x.value, 0f), size = androidx.compose.ui.geometry.Size(w, size.height),
            cornerRadius = androidx.compose.ui.geometry.CornerRadius(size.height / 2))
    })
}

/** Failed: the clear reason and Try again. */
@Composable
fun BoxScope.StageFailed(stage: StudioStage, art: ImageRef?, onRetry: () -> Unit) {
    val m = muse
    BlurredStageArt(art, moving = false)
    Column(
        Modifier.align(Alignment.Center).padding(horizontal = 28.dp).widthIn(max = 300.dp).fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        T("Render failed", m.type.body.copy(fontWeight = FontWeight.Bold, fontSize = 16.sp), Color.White)
        T(stage.failure ?: studio.muse.app.data.ErrorText.WENT_WRONG, m.type.body.copy(fontSize = 14.sp, lineHeight = 19.sp), Color.White.copy(alpha = .92f),
            align = TextAlign.Center, maxLines = 4)
        StageButton("Try again", onRetry, primary = true, icon = "retry")
    }
}

/**
 * Ready: the take playing (muted loop, unmute top right), "Ready" and the take switcher top left, Open / Edit video /
 * Generate again along the bottom.
 */
@Composable
fun BoxScope.StageReady(
    stage: StudioStage, picked: String?, fallback: ImageRef?, onPick: (String) -> Unit, onOpen: (Take) -> Unit, onEdit: (Take) -> Unit, onAgain: () -> Unit,
) {
    val m = muse
    val take = stage.take(picked)
    var muted by remember { mutableStateOf(true) }
    val url = take?.videoUrl
    if (take != null && url != null) StageVideo(url, take.thumb, muted, Modifier.matchParentSize())
    else RefImage(take?.thumb ?: fallback, Modifier.matchParentSize(), 25)
    Box(Modifier.fillMaxWidth().height(64.dp).align(Alignment.TopCenter).background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = .45f), Color.Transparent))))
    Box(Modifier.fillMaxWidth().height(110.dp).align(Alignment.BottomCenter).background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = .6f)))))
    Row(Modifier.align(Alignment.TopStart).padding(12.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
        StageTag(if (m.isA) "READY" else "Ready")
        if (stage.takes.size > 1) stage.takes.forEach { t ->
            val on = t.id == take?.id
            Box(
                Modifier.size(28.dp).clip(CircleShape).background(if (on) Color.White else Color.Black.copy(alpha = .45f))
                    .border(1.dp, Color.White.copy(alpha = if (on) 1f else .6f), CircleShape).press { onPick(t.id) }
                    .semantics { contentDescription = "Take ${t.index}" },
                contentAlignment = Alignment.Center,
            ) { T("${t.index}", m.type.mono.copy(fontSize = 12.sp, fontWeight = FontWeight.Bold), if (on) Ink else Color.White) }
        }
    }
    if (url != null) {
        Box(
            Modifier.align(Alignment.TopEnd).padding(10.dp).size(36.dp).clip(CircleShape).background(Color.Black.copy(alpha = .5f)).press { muted = !muted }
                .semantics { contentDescription = if (muted) "Unmute" else "Mute" },
            contentAlignment = Alignment.Center,
        ) { Ic(if (muted) "mute" else "audio", 18.dp, Color.White) }
    }
    Column(Modifier.align(Alignment.BottomStart).fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        val line = listOfNotNull(take?.let { stage.takeLabel(it) }, take?.durationSec?.let { stageClock(it) }, stage.price.ifBlank { null }).joinToString(" · ")
        if (line.isNotEmpty()) T(line, m.type.tiny.copy(fontSize = 12.sp), Color.White.copy(alpha = .9f), maxLines = 1)
        FlowRow(hGap = 8.dp, vGap = 8.dp) {
            if (take != null) {
                StageButton("Open", { onOpen(take) })
                StageButton("Edit video", { onEdit(take) }, enabled = take.editable)
            }
            StageButton("Generate again", onAgain, primary = true)
        }
    }
}

/** A small label over the stage ("Ready"). */
@Composable
private fun StageTag(text: String) {
    val m = muse
    Box(Modifier.height(24.dp).clip(RoundedCornerShape(999.dp)).background(Color.Black.copy(alpha = .5f)).padding(horizontal = 10.dp), contentAlignment = Alignment.Center) {
        T(text, m.type.mono.copy(fontSize = 11.sp), Color.White, maxLines = 1)
    }
}

/** A compact button over the video: white, or the theme's call-to-action colour for [primary]. */
@Composable
fun StageButton(text: String, onClick: () -> Unit, primary: Boolean = false, enabled: Boolean = true, icon: String? = null) {
    val m = muse
    val shape = RoundedCornerShape(if (m.isA) 2.dp else 999.dp)
    val (bg, fg) = when {
        !primary -> Color.White.copy(alpha = .94f) to Ink
        m.isA -> m.t.accent to m.t.accentInk
        else -> m.t.cta to m.t.ctaInk
    }
    Row(
        Modifier.height(36.dp).clip(shape).background(bg).let { if (m.isD) it.border(2.dp, Ink, shape) else it }
            .graphicsLayer { alpha = if (enabled) 1f else .5f }.press(onClick = onClick).padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        if (icon != null) Ic(icon, 16.dp, fg)
        T(text, m.type.body.copy(fontSize = 13.5.sp, fontWeight = FontWeight.Bold), fg, upper = m.isA, maxLines = 1)
    }
}

/** "0:07". */
private fun stageClock(sec: Double): String {
    val n = Math.round(sec).toInt()
    return String.format(java.util.Locale.US, "%d:%02d", n / 60, n % 60)
}

/** A finished take playing inline (Media3): muted by default, looping, no controls, the take's still underneath while it loads. */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@Composable
fun StageVideo(url: String, poster: ImageRef?, muted: Boolean, modifier: Modifier = Modifier) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val player = remember(url) {
        androidx.media3.exoplayer.ExoPlayer.Builder(context).build().apply {
            setMediaItem(androidx.media3.common.MediaItem.fromUri(url))
            repeatMode = androidx.media3.common.Player.REPEAT_MODE_ONE
            volume = 0f
            prepare()
        }
    }
    androidx.compose.runtime.DisposableEffect(player) { onDispose { player.release() } }
    androidx.compose.runtime.LaunchedEffect(player, muted) { player.volume = if (muted) 0f else 1f }
    androidx.lifecycle.compose.LifecycleResumeEffect(player) {
        player.playWhenReady = true
        onPauseOrDispose { player.pause() }
    }
    Box(modifier) {
        RefImage(poster, Modifier.fillMaxSize(), 25)
        androidx.compose.ui.viewinterop.AndroidView(
            factory = { ctx ->
                androidx.media3.ui.PlayerView(ctx).apply {
                    this.player = player
                    useController = false
                    resizeMode = androidx.media3.ui.AspectRatioFrameLayout.RESIZE_MODE_ZOOM
                    setShutterBackgroundColor(android.graphics.Color.TRANSPARENT)
                }
            },
            modifier = Modifier.fillMaxSize(),
            update = { it.player = player },
        )
    }
}

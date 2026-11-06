package studio.muse.app.ui.screens.suite.composer

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import studio.muse.app.data.ImageRef
import studio.muse.app.ui.components.T
import studio.muse.app.ui.components.assetRes
import studio.muse.app.ui.screens.suite.FaceMath
import studio.muse.app.ui.screens.suite.RecastPerson
import studio.muse.app.ui.theme.muse
import java.io.ByteArrayOutputStream

// AI suite (workstream 1): Recast's "tap a face" (plans/video-composer.md "Tools on the shell"). The clip's first frame is
// read on the device; the user taps each face to replace, a numbered marker shows on it, and a square crop around the tap
// is uploaded and sent as `cast[i].faceCrop`. The maths (third → position, the crop square) is FaceMath, unit-tested.

/** Where the first frame comes from: the clip's file (a local URI or a remote URL) and, failing that, its thumb. */
data class FrameSource(val video: String?, val thumb: ImageRef?)

object FirstFrame {
    /** Demo mode's sample clip has no bundled footage: its frame is the bundled stand-in still. */
    val DEMO = ImageRef.asset("hero")

    /** The frame at 0 s of [video] (content://, file:// or http(s)), or null when it can't be read. */
    fun ofVideo(ctx: Context, video: String): Bitmap? {
        val r = MediaMetadataRetriever()
        return try {
            if (video.startsWith("http")) r.setDataSource(video, emptyMap()) else r.setDataSource(ctx, Uri.parse(video))
            r.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
        } catch (e: Exception) {
            null
        } finally {
            runCatching { r.release() }
        }
    }

    /** A bundled still, decoded at once (no I/O wait). */
    fun ofAsset(ctx: Context, ref: ImageRef?): Bitmap? = assetRes(ref?.asset)?.let { runCatching { BitmapFactory.decodeResource(ctx.resources, it) }.getOrNull() }

    /** The clip's thumb: a bundled still, a local file, or a remote image through the app's image loader. */
    suspend fun ofThumb(ctx: Context, ref: ImageRef?): Bitmap? {
        ofAsset(ctx, ref)?.let { return it }
        val url = ref?.url ?: return null
        if (url.startsWith("file:")) return runCatching { BitmapFactory.decodeFile(Uri.parse(url).path) }.getOrNull()
        return runCatching {
            val req = coil3.request.ImageRequest.Builder(ctx).data(url).build()
            (coil3.SingletonImageLoader.get(ctx).execute(req) as? coil3.request.SuccessResult)?.image?.let { img ->
                val b = Bitmap.createBitmap(img.width.coerceAtLeast(1), img.height.coerceAtLeast(1), Bitmap.Config.ARGB_8888)
                img.draw(android.graphics.Canvas(b)); b
            }
        }.getOrNull()
    }

    suspend fun load(ctx: Context, src: FrameSource): Bitmap? = withContext(Dispatchers.IO) { src.video?.let { ofVideo(ctx, it) } ?: ofThumb(ctx, src.thumb) }

    /** The square around a tap ([FaceMath.crop]), at most 512 px, as a JPEG to upload. */
    fun cropJpeg(frame: Bitmap, x: Float, y: Float): ByteArray {
        val c = FaceMath.crop(frame.width, frame.height, x, y)
        var sq = Bitmap.createBitmap(frame, c.left, c.top, c.side, c.side)
        if (c.side > 512) sq = Bitmap.createScaledBitmap(sq, 512, 512, true)
        return ByteArrayOutputStream().use { out -> sq.compress(Bitmap.CompressFormat.JPEG, 88, out); out.toByteArray() }
    }
}

/** The first frame of [src]: a bundled still at once, else read in the background (null while it loads or if it can't). */
@Composable
fun rememberFirstFrame(src: FrameSource?): Bitmap? {
    val ctx = LocalContext.current
    val now = remember(src) { if (src?.video == null) FirstFrame.ofAsset(ctx, src?.thumb) else null }
    val later by produceState<Bitmap?>(null, src) { value = if (src == null || now != null) null else FirstFrame.load(ctx, src) }
    return now ?: later
}

/**
 * The first frame with a numbered marker on each tapped face ([people] in order; [active] ringed). A tap anywhere calls
 * [onTap] with its place as fractions of the frame. Always drawn on the dark picker.
 */
@Composable
fun FacePicker(frame: Bitmap?, people: List<RecastPerson>, active: Int, max: Int, onTap: (Float, Float) -> Unit, modifier: Modifier = Modifier, maxHeight: Dp = 300.dp) {
    val m = muse
    val tap by rememberUpdatedState(onTap)
    val ratio = frame?.let { it.width.toFloat() / it.height.coerceAtLeast(1) } ?: (9f / 16)
    val picked = people.count { it.tap != null }
    Box(modifier.heightIn(max = maxHeight).aspectRatio(ratio, matchHeightConstraintsFirst = true).clip(RoundedCornerShape(12.dp)).background(Color(0xFF17191B))
        .border(1.dp, m.t.line, RoundedCornerShape(12.dp))
        .semantics { contentDescription = "The clip's first frame. Tap a face to choose who to replace · $picked of $max picked. The position chips below work too." }) {
        if (frame != null) {
            val img = remember(frame) { frame.asImageBitmap() }
            Image(img, null, Modifier.fillMaxSize(), contentScale = ContentScale.FillBounds)
        } else T("Reading the first frame…", m.type.body.copy(fontSize = 13.sp), m.t.muted, Modifier.align(Alignment.Center))
        BoxWithConstraints(Modifier.fillMaxSize().pointerInput(frame != null) {
            if (frame != null) detectTapGestures { p -> tap((p.x / size.width).coerceIn(0f, 1f), (p.y / size.height).coerceIn(0f, 1f)) }
        }) {
            val w = maxWidth
            val h = maxHeight
            people.forEachIndexed { i, p ->
                val t = p.tap ?: return@forEachIndexed
                FaceMarker(i + 1, i == active, Modifier.offset(w * t.x - 17.dp, h * t.y - 17.dp))
            }
        }
    }
}

/** A numbered ring on a tapped face. */
@Composable
fun FaceMarker(n: Int, on: Boolean, modifier: Modifier = Modifier) {
    val m = muse
    Box(modifier.size(34.dp).clip(CircleShape).background(Color.Black.copy(alpha = .35f)).border(if (on) 3.dp else 2.dp, if (on) m.t.accent else Color.White, CircleShape),
        contentAlignment = Alignment.Center) {
        Box(Modifier.size(20.dp).clip(CircleShape).background(if (on) m.t.accent else Color.White), contentAlignment = Alignment.Center) {
            T("$n", m.type.mono.copy(fontSize = 12.sp, fontWeight = FontWeight.Bold), Color(0xFF0D0E0F), maxLines = 1)
        }
    }
}

/** The small numbered badge on a person's card that matches their marker on the frame. */
@Composable
fun FaceBadge(n: Int, modifier: Modifier = Modifier) {
    Box(modifier.padding(end = 2.dp).size(24.dp).clip(CircleShape).background(muse.t.accent), contentAlignment = Alignment.Center) {
        T("$n", muse.type.mono.copy(fontSize = 12.sp, fontWeight = FontWeight.Bold), Color(0xFF1A1205), maxLines = 1)
    }
}

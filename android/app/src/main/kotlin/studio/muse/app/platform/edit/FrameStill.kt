package studio.muse.app.platform.edit

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.media.MediaMetadataRetriever
import android.os.Build
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import studio.muse.core.edit.LayerRole
import studio.muse.core.edit.Look
import studio.muse.core.edit.PlannedClip
import studio.muse.core.edit.RenderPlan
import studio.muse.core.edit.hexArgb
import studio.muse.core.edit.renderLook
import java.io.ByteArrayOutputStream
import java.io.File
import kotlin.math.roundToInt

/**
 * Edit sessions (workstream 3, plans/claude-editing.md A "See"): a still of the composition at timeline t, for the
 * frames Claude asks for (`frame_request`). Built from the same [RenderPlan] the engine renders: every layer back to
 * front (the clip's source frame at its source time, through its look's CPU port with the item's colour matrix and
 * LUT, placed and faded like the compositor does), then the composition overlays (text, hooks, captions, flashes)
 * drawn by the engine's own [EditOverlay].
 *
 * Not drawn here (they need the GL pipeline): chroma keys, shape masks, highlights/shadows tone, transition blur/RGB
 * split. Needs a real phone to compare against the preview.
 */
@OptIn(UnstableApi::class)
class FrameStill(@Suppress("unused") private val context: Context, private val looks: LookLibrary) {
    /** The PNG of [plan] at [tSec], [width] pixels wide (height from the canvas). */
    suspend fun png(plan: RenderPlan, files: Map<String, File>, tSec: Double, width: Int): ByteArray = withContext(Dispatchers.IO) {
        val bmp = render(plan, files, tSec, width)
        ByteArrayOutputStream().use { out -> bmp.compress(Bitmap.CompressFormat.PNG, 100, out); bmp.recycle(); out.toByteArray() }
    }

    fun render(plan: RenderPlan, files: Map<String, File>, tSec: Double, width: Int): Bitmap {
        val t = tSec.coerceIn(0.0, maxOf(0.0, plan.durationSec - 1e-3))
        val w = width.coerceAtLeast(16)
        val h = (w.toDouble() * plan.height / plan.width).roundToInt().coerceAtLeast(16)
        val k = w.toDouble() / plan.width
        val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        canvas.drawColor(runCatching { hexArgb(plan.project.canvas.background ?: "#000000") }.getOrDefault(android.graphics.Color.BLACK))
        // Index 0 is drawn on top by the compositor, so back to front = highest index first.
        for (layer in plan.layers.sortedByDescending { it.index }) {
            if (layer.role == LayerRole.CLOCK || layer.role == LayerRole.BACKGROUND) continue
            val clip = plan.clipAt(layer.index, t) ?: continue
            val pl = plan.placement(layer.index, t)
            if (pl.alpha <= 0.0) continue
            val vl = clip.look
            val texW = ((vl?.textureWidth ?: plan.width) * k).roundToInt().coerceAtLeast(1)
            val texH = ((vl?.textureHeight ?: plan.height) * k).roundToInt().coerceAtLeast(1)
            val src = sourceFrame(clip, files, t, texW, texH) ?: continue
            val cropped = vl?.crop?.let { c ->
                val x0 = ((c.left + 1) / 2 * src.width).roundToInt().coerceIn(0, src.width - 1)
                val x1 = ((c.right + 1) / 2 * src.width).roundToInt().coerceIn(x0 + 1, src.width)
                val y0 = ((1 - c.top) / 2 * src.height).roundToInt().coerceIn(0, src.height - 1)
                val y1 = ((1 - c.bottom) / 2 * src.height).roundToInt().coerceIn(y0 + 1, src.height)
                Bitmap.createBitmap(src, x0, y0, x1 - x0, y1 - y0)
            } ?: src
            val looked = if (vl != null && (vl.look != null || vl.colorMatrix != null)) {
                val small = LookThumbnails.downscale(cropped, texH)
                LookThumbnails.toBitmap(renderLook(small, vl.look ?: Look(), vl.colorMatrix, looks.lutFor(vl.look, files), fps = plan.fps))
            } else cropped
            val scale = (vl?.baseScale ?: 1.0) * pl.scale
            val dw = (texW * scale).toFloat(); val dh = (texH * scale).toFloat()
            canvas.save()
            canvas.translate((pl.centerX * w).toFloat(), (pl.centerY * h).toFloat())
            canvas.rotate(pl.rotationCw.toFloat())
            val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG).apply { alpha = (pl.alpha.coerceIn(0.0, 1.0) * 255).roundToInt() }
            canvas.drawBitmap(looked, Rect(0, 0, looked.width, looked.height), RectF(-dw / 2, -dh / 2, dw / 2, dh / 2), paint)
            canvas.restore()
        }
        // Text, hooks, captions and flashes: the engine's overlay on its own transparent layer.
        val overlay = EditOverlay(plan)
        if (overlay.isNeeded) {
            val ov = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            overlay.onDraw(Canvas(ov), (t * 1_000_000).toLong())
            canvas.drawBitmap(ov, 0f, 0f, null)
            ov.recycle()
        }
        return out
    }

    /** The clip's picture at timeline [tSec]: its source time walks the clip's constant-speed pieces. */
    private fun sourceFrame(c: PlannedClip, files: Map<String, File>, tSec: Double, w: Int, h: Int): Bitmap? {
        val f = files[c.assetId] ?: return null
        if (c.isImage) return BitmapFactory.decodeFile(f.absolutePath)
        val srcUs = sourceUs(c, (tSec * 1_000_000).toLong())
        val r = MediaMetadataRetriever()
        return try {
            r.setDataSource(f.absolutePath)
            if (Build.VERSION.SDK_INT >= 27) r.getScaledFrameAtTime(srcUs, MediaMetadataRetriever.OPTION_CLOSEST, w, h) else r.getFrameAtTime(srcUs, MediaMetadataRetriever.OPTION_CLOSEST)
        } catch (_: Exception) { null } finally { r.release() }
    }

    companion object {
        /** Source microseconds shown at timeline [tUs] (pieces back to back, each at its own speed). */
        fun sourceUs(c: PlannedClip, tUs: Long): Long {
            var left = (tUs - c.startUs).coerceAtLeast(0)
            for (p in c.pieces) {
                val len = ((p.clipEndUs - p.clipStartUs) / p.speed).toLong()
                if (left <= len) return p.clipStartUs + (left * p.speed).toLong()
                left -= len
            }
            return c.pieces.lastOrNull()?.clipEndUs ?: c.clipEndUs
        }
    }
}

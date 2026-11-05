package studio.muse.app.platform.edit

import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.RectF
import android.graphics.Typeface
import android.os.Build
import android.text.Layout
import android.text.SpannableString
import android.text.Spanned
import android.text.StaticLayout
import android.text.TextPaint
import android.text.style.ForegroundColorSpan
import android.text.style.RelativeSizeSpan
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.CanvasOverlay
import studio.muse.core.edit.Align
import studio.muse.core.edit.CaptionPiece
import studio.muse.core.edit.FlashPiece
import studio.muse.core.edit.Font
import studio.muse.core.edit.RenderPlan
import studio.muse.core.edit.TextPiece
import studio.muse.core.edit.TextStyle
import studio.muse.core.edit.TransitionKind
import studio.muse.core.edit.hexArgb
import kotlin.math.ceil
import kotlin.math.roundToInt

/**
 * Draws the plan's composition-level overlays — black/white transition flashes, text and hook items, captions — on a
 * canvas the size of the output frame, per presentation time (applied as a composition effect, so on top of every
 * video layer). States come from the pure [RenderPlan.textFrame] / [RenderPlan.captionFrame] / [RenderPlan.flashAlpha].
 *
 * Fonts: the contract's families map to the platform's (sans/serif/monospace, sans-serif-condensed, casual for
 * marker; rounded falls back to sans) until the bundled font files land with the editor screens.
 */
@OptIn(UnstableApi::class)
class EditOverlay(private val plan: RenderPlan) : CanvasOverlay(/* useInputFrameSize = */ true) {
    private val paint = TextPaint(Paint.ANTI_ALIAS_FLAG)
    private val boxPaint = Paint(Paint.ANTI_ALIAS_FLAG)

    /** True when the plan has anything for this effect to draw (otherwise the engine leaves the effect out). */
    val isNeeded: Boolean get() = plan.overlays.isNotEmpty()

    override fun onDraw(canvas: Canvas, presentationTimeUs: Long) {
        canvas.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR)
        val t = presentationTimeUs / 1_000_000.0
        for (piece in plan.overlays) when (piece) {
            is FlashPiece -> {
                val a = plan.flashAlpha(piece.flash, t)
                if (a > 0) canvas.drawColor(withAlpha(if (piece.flash.kind == TransitionKind.WHITE) Color.WHITE else Color.BLACK, a))
            }
            is TextPiece -> plan.textFrame(piece, t)?.let { f ->
                drawText(canvas, f.text, piece.item.style, f.centerX, f.centerY, f.scale, f.rotationCw, f.alpha, highlight = null)
            }
            is CaptionPiece -> plan.captionFrame(piece, t)?.let { f ->
                val st = piece.style
                drawText(canvas, f.words.joinToString(" "), st.text, 0.5, st.y ?: 0.72, 1.0, 0.0, f.alpha,
                    highlight = Highlight(f.words, f.highlighted, f.boxed, if (f.boxed == null) f.active else null, f.activeScale, hexArgb(st.highlightColor), f.stripe),
                    maxLines = st.maxLines ?: 2)
            }
        }
    }

    private class Highlight(val words: List<String>, val on: List<Boolean>, val boxed: Int?, val scaled: Int?, val scale: Double, val color: Int, val stripe: Int? = null)

    private fun drawText(
        canvas: Canvas, text: String, s: TextStyle, cx: Double, cy: Double, scale: Double, rotationCw: Double, alpha: Double,
        highlight: Highlight?, maxLines: Int = Int.MAX_VALUE,
    ) {
        val w = canvas.width; val h = canvas.height
        val px = (s.sizePct * h * scale).toFloat().coerceAtLeast(1f)
        paint.reset(); paint.isAntiAlias = true
        paint.textSize = px
        paint.typeface = typeface(s.font, s.weight)
        s.letterSpacing?.let { paint.letterSpacing = it.toFloat() }
        val maxW = ((s.maxWidthPct ?: 0.85) * w).roundToInt().coerceAtLeast(1)
        // Two spannables: sizes only (for the stroke and shadow passes, whose paint colour must win) and sizes + colours.
        val sized = SpannableString(text)
        val spanned = SpannableString(text)
        val wordStarts = ArrayList<Int>()
        if (highlight != null) {
            var at = 0
            highlight.words.forEachIndexed { k, word ->
                wordStarts += at
                if (highlight.on.getOrElse(k) { false }) spanned.setSpan(ForegroundColorSpan(highlight.color), at, at + word.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                if (highlight.scaled == k && highlight.scale != 1.0) for (sp in listOf(sized, spanned))
                    sp.setSpan(RelativeSizeSpan(highlight.scale.toFloat()), at, at + word.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                at += word.length + 1
            }
        }
        val align = when (s.align) { Align.LEFT -> Layout.Alignment.ALIGN_NORMAL; Align.CENTER -> Layout.Alignment.ALIGN_CENTER; Align.RIGHT -> Layout.Alignment.ALIGN_OPPOSITE }
        fun layout(cs: CharSequence, p: TextPaint): StaticLayout = StaticLayout.Builder.obtain(cs, 0, cs.length, p, maxW)
            .setAlignment(align).setLineSpacing(0f, (s.lineHeight ?: 1.15).toFloat() / 1.15f).setIncludePad(false).setMaxLines(maxLines).build()
        paint.color = hexArgb(s.color)
        val fill = layout(spanned, paint)
        val lw = (0 until fill.lineCount).maxOfOrNull { fill.getLineWidth(it) } ?: 0f
        val lh = fill.height.toFloat()
        canvas.save()
        canvas.translate((cx * w).toFloat(), (cy * h).toFloat())
        canvas.rotate(rotationCw.toFloat())
        // The layout is maxW wide; its text block is centred on the item's position.
        val left = when (s.align) { Align.LEFT -> -lw / 2; Align.CENTER -> -maxW / 2f; Align.RIGHT -> lw / 2 - maxW }
        canvas.translate(left, -lh / 2)
        val layerAlpha = (alpha.coerceIn(0.0, 1.0) * 255).roundToInt()
        canvas.saveLayerAlpha(-2f * w, -2f * h, 2f * w, 2f * h, layerAlpha)
        s.background?.let { b ->
            val pad = (b.paddingPct * px).toFloat(); val r = (b.radiusPct * px).toFloat()
            val x0 = when (s.align) { Align.LEFT -> 0f; Align.CENTER -> (maxW - lw) / 2; Align.RIGHT -> maxW - lw }
            boxPaint.reset(); boxPaint.isAntiAlias = true; boxPaint.color = withAlpha(hexArgb(b.color), b.opacity)
            canvas.drawRoundRect(RectF(x0 - pad, -pad, x0 + lw + pad, lh + pad), r, r, boxPaint)
        }
        if (highlight?.boxed != null) {
            val k = highlight.boxed
            val start = wordStarts[k]; val end = start + highlight.words[k].length
            val line = fill.getLineForOffset(start)
            val x0 = fill.getPrimaryHorizontal(start); val x1 = if (fill.getLineForOffset(end) == line) fill.getPrimaryHorizontal(end) else fill.getLineRight(line)
            val pad = 0.2f * px
            boxPaint.reset(); boxPaint.isAntiAlias = true; boxPaint.color = highlight.color
            canvas.drawRoundRect(RectF(minOf(x0, x1) - pad, fill.getLineTop(line) - pad / 2, maxOf(x0, x1) + pad, fill.getLineBottom(line) + pad / 2), pad, pad, boxPaint)
        }
        if (highlight?.stripe != null) {
            // Edit suite "Highlighter": a marker stripe over the lower 45 % of the active word's line.
            val k = highlight.stripe
            val start = wordStarts[k]; val end = start + highlight.words[k].length
            val line = fill.getLineForOffset(start)
            val x0 = fill.getPrimaryHorizontal(start); val x1 = if (fill.getLineForOffset(end) == line) fill.getPrimaryHorizontal(end) else fill.getLineRight(line)
            val top = fill.getLineTop(line).toFloat(); val bottom = fill.getLineBottom(line).toFloat()
            val pad = 0.08f * px
            boxPaint.reset(); boxPaint.isAntiAlias = true; boxPaint.color = highlight.color
            canvas.drawRect(RectF(minOf(x0, x1) - pad, bottom - 0.45f * (bottom - top), maxOf(x0, x1) + pad, bottom), boxPaint)
        }
        s.shadow?.let { sh ->
            val shadow = TextPaint(paint)

            shadow.color = withAlpha(hexArgb(sh.color), sh.opacity)
            if (sh.blurPct > 0) shadow.maskFilter = BlurMaskFilter((sh.blurPct * px).toFloat().coerceAtLeast(0.5f), BlurMaskFilter.Blur.NORMAL)
            canvas.save(); canvas.translate(0f, (sh.dyPct * px).toFloat())
            layout(sized, shadow).draw(canvas)
            canvas.restore()
        }
        s.stroke?.let { st ->
            if (st.widthPct > 0) {
                val stroke = TextPaint(paint)
                stroke.style = Paint.Style.STROKE; stroke.strokeJoin = Paint.Join.ROUND
                stroke.strokeWidth = ceil(st.widthPct * px * 2).toFloat() // centred on the outline: half lies outside
                stroke.color = hexArgb(st.color)
                layout(sized, stroke).draw(canvas)
            }
        }
        fill.draw(canvas)
        canvas.restore()
        canvas.restore()
    }

    private fun typeface(font: Font, weight: Int): Typeface {
        val family = when (font) {
            Font.SANS, Font.ROUNDED -> Typeface.SANS_SERIF
            Font.SERIF -> Typeface.SERIF
            Font.MONO -> Typeface.MONOSPACE
            Font.CONDENSED -> Typeface.create("sans-serif-condensed", Typeface.NORMAL)
            Font.MARKER -> Typeface.create("casual", Typeface.NORMAL)
        }
        return if (Build.VERSION.SDK_INT >= 28) Typeface.create(family, weight, false)
        else Typeface.create(family, if (weight >= 700) Typeface.BOLD else Typeface.NORMAL)
    }

    private fun withAlpha(argb: Int, a: Double): Int = (argb and 0x00FFFFFF) or ((a.coerceIn(0.0, 1.0) * 255).roundToInt() shl 24)
}

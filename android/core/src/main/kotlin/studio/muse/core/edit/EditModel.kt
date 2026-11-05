package studio.muse.core.edit

import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/*
 * The pure functions of the reference model (server/api/src/editor/model.ts), one for one, with the same names,
 * order of operations and rounding, so every fixture answer matches to 1e-6.
 */

/** Rounds to 6 decimals like the reference (`Math.round(v * 1e6) / 1e6`, halves up). */
internal fun r6(v: Double): Double = Math.round(v * 1e6).toDouble() / 1e6
internal fun clamp(v: Double, lo: Double, hi: Double): Double = min(hi, max(lo, v))

// ------------------------------------------------------------------ easing and keyframes
fun ease(kind: Ease?, p0: Double): Double {
    val p = clamp(p0, 0.0, 1.0)
    return when (kind ?: Ease.LINEAR) {
        Ease.EASE_IN -> p * p
        Ease.EASE_OUT -> 1 - (1 - p) * (1 - p)
        Ease.EASE_IN_OUT -> if (p < 0.5) 2 * p * p else 1 - (-2 * p + 2).pow(2) / 2
        Ease.HOLD -> 0.0
        Ease.LINEAR -> p
    }
}

/** The value of a keyframed property at item-local time [t] (keys sorted by t); NaN without keys. */
fun keyframeValue(keys: List<Keyframe>, t: Double): Double {
    if (keys.isEmpty()) return Double.NaN
    if (t <= keys[0].t) return keys[0].v
    val last = keys.last()
    if (t >= last.t) return last.v
    for (k in 0 until keys.size - 1) {
        val a = keys[k]; val b = keys[k + 1]
        if (t >= a.t && t < b.t) {
            val span = b.t - a.t
            if (span <= 0) return b.v
            return a.v + (b.v - a.v) * ease(a.ease, (t - a.t) / span)
        }
    }
    return last.v
}

/** A property at item-local [t]: its keyframes when it has any, else [fallback]. */
fun propAt(keyframes: Keyframes?, prop: KfProp, fallback: Double, t: Double): Double {
    val k = keyframes?.get(prop)
    return if (!k.isNullOrEmpty()) keyframeValue(k, t) else fallback
}

// ------------------------------------------------------------------ timeline
/** Speed at [x] (0–1) of a curve: smoothstep between points in log speed. */
fun curveSpeed(c: SpeedCurve, x: Double): Double {
    val pts = c.points
    if (x <= pts[0].x) return pts[0].speed
    for (k in 0 until pts.size - 1) {
        val a = pts[k]; val b = pts[k + 1]
        if (x <= b.x) {
            val t = if (b.x > a.x) (x - a.x) / (b.x - a.x) else 1.0
            val e = t * t * (3 - 2 * t)
            return kotlin.math.exp(kotlin.math.ln(a.speed) + (kotlin.math.ln(b.speed) - kotlin.math.ln(a.speed)) * e)
        }
    }
    return pts.last().speed
}

/** A constant-speed piece of a clip's source. */
data class Piece(val inSec: Double, val outSec: Double, val speed: Double)

/** A clip as constant-speed pieces: one piece, or CURVE_PIECES equal source pieces of a speed curve (each at the curve's speed at its middle). Engines render these. */
fun speedPieces(inSec: Double, outSec: Double, speed: Double?, curve: SpeedCurve?): List<Piece> {
    if (curve == null) return listOf(Piece(inSec, outSec, speed ?: 1.0))
    val n = EditLimits.CURVE_PIECES; val len = (outSec - inSec) / n
    return List(n) { i -> Piece(r6(inSec + i * len), r6(if (i == n - 1) outSec else inSec + (i + 1) * len), r6(curveSpeed(curve, (i + 0.5) / n))) }
}

fun speedPieces(c: MediaClip): List<Piece> = speedPieces(c.inSec, c.outSec, c.speedOrNull, (c as? VideoClip)?.speedCurve)

fun clipLength(inSec: Double, outSec: Double, speed: Double?, curve: SpeedCurve? = null): Double =
    if (curve != null) speedPieces(inSec, outSec, speed, curve).sumOf { (it.outSec - it.inSec) / it.speed } else (outSec - inSec) / (speed ?: 1.0)
fun clipLength(c: MediaClip): Double = clipLength(c.inSec, c.outSec, c.speedOrNull, (c as? VideoClip)?.speedCurve)

/** Seconds from the clip's start on the timeline at source time [sec] (clamped to the clip). */
fun clipTimeAt(c: MediaClip, sec: Double): Double {
    var acc = 0.0
    for (p in speedPieces(c)) {
        if (sec <= p.outSec) return acc + max(0.0, sec - p.inSec) / p.speed
        acc += (p.outSec - p.inSec) / p.speed
    }
    return acc
}

/** The source time of the clip at [local] seconds from its start on the timeline (the inverse of [clipTimeAt]). */
fun clipSourceAt(c: MediaClip, local: Double): Double {
    var acc = 0.0
    for (p in speedPieces(c)) {
        val len = (p.outSec - p.inSec) / p.speed
        if (local <= acc + len) return p.inSec + max(0.0, local - acc) * p.speed
        acc += len
    }
    return c.outSec
}

/** A curve cut down to the source range [x0, x1] of its clip, rescaled to 0–1 (preset becomes custom). */
fun subCurve(c: SpeedCurve, x0: Double, x1: Double): SpeedCurve {
    val inner = c.points.filter { it.x > x0 + 1e-9 && it.x < x1 - 1e-9 }.map { SpeedPoint(r6((it.x - x0) / (x1 - x0)), it.speed) }
    return SpeedCurve(SpeedPreset.CUSTOM, listOf(SpeedPoint(0.0, r6(curveSpeed(c, x0)))) + inner + SpeedPoint(1.0, r6(curveSpeed(c, x1))))
}

data class MainSpan(val id: String, val index: Int, val startSec: Double, val endSec: Double, val transitionSec: Double)

/** Each main clip's place on the timeline. A clip with transitionIn starts that much before the previous clip ends. */
fun timeline(p: EditProject): List<MainSpan> {
    val out = ArrayList<MainSpan>()
    var end = 0.0
    p.mainClips.forEachIndexed { i, c ->
        val tr = if (i > 0 && c.transitionIn != null) c.transitionIn.durationSec else 0.0
        val start = max(0.0, end - tr)
        val len = clipLength(c)
        out += MainSpan(c.id, i, r6(start), r6(start + len), tr)
        end = start + len
    }
    return out
}

fun durationSec(p: EditProject): Double = timeline(p).lastOrNull()?.endSec ?: 0.0

data class Span(val startSec: Double, val endSec: Double)

/** Timeline start/end of any item (main clips through [timeline]; others from startSec). */
fun itemSpan(p: EditProject, track: Track, item: Item): Span {
    if (track.kind == TrackKind.MAIN) {
        val s = timeline(p).first { it.id == item.id }
        return Span(s.startSec, s.endSec)
    }
    val (start, len) = when (item) {
        is VideoClip -> (item.startSec ?: Double.NaN) to clipLength(item)
        is AudioClip -> item.startSec to clipLength(item)
        is ImageItem -> item.startSec to item.durationSec
        is TextItem -> item.startSec to item.durationSec
    }
    return Span(r6(start), r6(start + len))
}

// ------------------------------------------------------------------ v1 <-> v2
data class SourceSize(val width: Int, val height: Int, val fps: Double, val hasAudio: Boolean? = null)

fun fromV1(v1: EditListV1, info: SourceSize): EditProject {
    val asset = Asset("src", AssetKind.VIDEO, take = v1.sourceTakeId, durationSec = v1.sourceDurationSec, width = info.width, height = info.height, hasAudio = info.hasAudio ?: true)
    return EditProject(
        version = 2, sourceTakeId = v1.sourceTakeId, canvas = Canvas(info.width, info.height, info.fps, "#000000"),
        assets = listOf(asset),
        tracks = listOf(Track("main", TrackKind.MAIN, items = v1.segments.mapIndexed { i, s ->
            VideoClip("c${i + 1}", "src", s.inSec, s.outSec, s.speed, muted = if (s.muted == true) true else null)
        })),
        mute = if (v1.mute) true else null,
    )
}

/** The v1 on-device edit ([studio.muse.core.VideoEdit]) as a v2 project. */
fun fromV1(edit: studio.muse.core.VideoEdit, sourceTakeId: String, info: SourceSize): EditProject = fromV1(
    EditListV1(1, sourceTakeId, edit.sourceDurationSec, edit.segments.map { V1Segment(it.inSec, it.outSec, it.speed, if (it.muted) true else null) }, edit.mute), info,
)

/** The v1 edit list for a project that only uses v1 features (one source, main track only, v1 speeds, in order); else null. */
fun toV1(p: EditProject): EditListV1? {
    if (p.tracks.size != 1 || p.tracks[0].kind != TrackKind.MAIN) return null
    val t = p.tracks[0]
    if (t.muted != null && t.muted || t.hidden == true || (t.volume != null && t.volume != 1.0)) return null
    val src = p.assets.firstOrNull { it.take == p.sourceTakeId && it.kind == AssetKind.VIDEO } ?: return null
    val dur = src.durationSec ?: return null
    var prev = 0.0
    val segs = ArrayList<V1Segment>()
    for (it in p.mainClips) {
        if (it.asset != src.id || it.speed !in EditLimits.V1_SPEEDS || it.inSec < prev - 1e-9) return null
        if (it != VideoClip(it.id, it.asset, it.inSec, it.outSec, it.speed, muted = it.muted)) return null
        prev = it.outSec
        segs += V1Segment(it.inSec, it.outSec, it.speed, if (it.muted == true) true else null)
    }
    if (segs.size > 50) return null
    return EditListV1(1, p.sourceTakeId, dur, segs, p.mute == true)
}

/** A v1 edit list as the on-device v1 edit. */
fun EditListV1.toVideoEdit(): studio.muse.core.VideoEdit =
    studio.muse.core.VideoEdit(sourceDurationSec, segments.map { studio.muse.core.EditSegment(it.inSec, it.outSec, it.speed, it.muted == true) }, mute)

// ------------------------------------------------------------------ cuts (silence / filler removal)
data class Range(val startSec: Double, val endSec: Double)

/** Merges and sorts ranges ([joinGap]: ranges this close are joined too). */
fun mergeRanges(rs: List<Range>, joinGap: Double = 0.0): List<Range> {
    val s = rs.filter { it.endSec > it.startSec }.sortedBy { it.startSec }
    val out = ArrayList<Range>()
    for (r in s) {
        val last = out.lastOrNull()
        if (last != null && r.startSec <= last.endSec + joinGap) out[out.size - 1] = last.copy(endSec = max(last.endSec, r.endSec))
        else out += r
    }
    return out
}

/**
 * Removes source ranges of [assetId] from every main clip of that asset (silence/filler suggestions). Clips are split
 * around the cuts; pieces shorter than 0.1 s of source are dropped; looks and speed carry over; a transition stays only
 * on the first piece of a clip that kept its start. Ids: a split clip's pieces are `<id>`, `<id>.2`, `<id>.3`… Returns
 * the project unchanged when every clip would disappear.
 */
fun applyCuts(p: EditProject, assetId: String, cuts: List<Range>): EditProject {
    val rs = mergeRanges(cuts)
    val main = p.main
    val items = ArrayList<VideoClip>()
    for (it in p.mainClips) {
        if (it.asset != assetId) { items += it; continue }
        var pieces = listOf(Range(it.inSec, it.outSec))
        for (r in rs) {
            pieces = pieces.flatMap { pc ->
                if (r.endSec <= pc.startSec || r.startSec >= pc.endSec) listOf(pc)
                else buildList {
                    if (r.startSec > pc.startSec) add(Range(pc.startSec, r.startSec))
                    if (r.endSec < pc.endSec) add(Range(r.endSec, pc.endSec))
                }
            }
        }
        pieces = pieces.filter { pc -> pc.endSec - pc.startSec >= EditLimits.MIN_CLIP_SOURCE_SEC - 1e-9 }
        pieces.forEachIndexed { k, pc ->
            val keepsStart = k == 0 && kotlin.math.abs(pc.startSec - it.inSec) < 1e-9
            val curve = it.speedCurve?.let { sc -> subCurve(sc, (pc.startSec - it.inSec) / (it.outSec - it.inSec), (pc.endSec - it.inSec) / (it.outSec - it.inSec)) }
            items += it.copy(id = if (k == 0) it.id else "${it.id}.${k + 1}", inSec = r6(pc.startSec), outSec = r6(pc.endSec), speedCurve = curve,
                transitionIn = if (keepsStart) it.transitionIn else null)
        }
    }
    if (items.isEmpty()) return p
    // A transition may now be on the first clip, or longer than its new neighbours allow: drop those.
    val fixed = items.mapIndexed { i, c ->
        val tr = c.transitionIn ?: return@mapIndexed c
        val prev = items.getOrNull(i - 1)
        val ok = i > 0 && tr.durationSec <= clipLength(c) / 2 + 1e-9 && prev != null && tr.durationSec <= clipLength(prev) / 2 + 1e-9
        if (ok) c else c.copy(transitionIn = null)
    }
    return p.copy(tracks = p.tracks.map { t -> if (t === main) t.copy(items = fixed) else t })
}

// ------------------------------------------------------------------ captions
data class TimedWord(val text: String, val startSec: Double, val endSec: Double, val index: Int)

private fun captionTrack(p: EditProject): CaptionTrack? = p.tracks.firstOrNull { it.kind == TrackKind.CAPTION && it.caption != null }?.caption

/** Caption words on the timeline: each source word mapped through every main clip of the caption asset that keeps its midpoint. */
fun captionWords(p: EditProject): List<TimedWord> {
    val ct = captionTrack(p) ?: return emptyList()
    val spans = timeline(p)
    val out = ArrayList<TimedWord>()
    p.mainClips.forEachIndexed { i, c ->
        if (c.asset != ct.asset) return@forEachIndexed
        val s = spans[i]
        ct.words.forEachIndexed { idx, w ->
            val mid = (w.startSec + w.endSec) / 2
            if (mid < c.inSec || mid >= c.outSec) return@forEachIndexed
            val a = max(w.startSec, c.inSec); val b = min(w.endSec, c.outSec)
            out += TimedWord(w.text, r6(s.startSec + clipTimeAt(c, a)), r6(s.startSec + clipTimeAt(c, b)), idx)
        }
    }
    return out.sortedWith(compareBy<TimedWord> { it.startSec }.thenBy { it.index })
}

data class CaptionPage(val startSec: Double, val endSec: Double, val words: List<TimedWord>)

private val SENTENCE_END = Regex("[.!?][\"')\\]]*$")

fun captionPages(p: EditProject): List<CaptionPage> {
    val ct = captionTrack(p) ?: return emptyList()
    val per = if (ct.style.preset == CaptionPreset.SINGLE) 1 else Math.round((ct.style.wordsPerPage ?: 3).toDouble()).toInt().coerceIn(1, 8)
    val words = captionWords(p)
    val pages = ArrayList<List<TimedWord>>()
    var cur = ArrayList<TimedWord>()
    words.forEachIndexed { i, w ->
        cur += w
        val next = words.getOrNull(i + 1)
        val brk = cur.size >= per || next == null || next.startSec - w.endSec > EditLimits.CAPTION_GAP_SEC || SENTENCE_END.containsMatchIn(w.text.trim())
        if (brk) { pages += cur; cur = ArrayList() }
    }
    return pages.mapIndexed { i, ws ->
        val next = pages.getOrNull(i + 1)
        val tail = ws.last().endSec + EditLimits.CAPTION_TAIL_SEC
        CaptionPage(ws.first().startSec, r6(if (next != null) min(next.first().startSec, tail) else tail), ws)
    }
}

data class CaptionAt(val page: Int, val word: Int)

/** The page shown at [t] and its active word (index into page.words), or null. */
fun captionAt(pages: List<CaptionPage>, t: Double): CaptionAt? {
    pages.forEachIndexed { i, pg ->
        if (t >= pg.startSec && t < pg.endSec) {
            var w = 0
            pg.words.forEachIndexed { k, x -> if (x.startSec <= t) w = k }
            return CaptionAt(i, w)
        }
    }
    return null
}

fun captionAt(p: EditProject, t: Double): CaptionAt? = captionAt(captionPages(p), t)

// ------------------------------------------------------------------ transitions and animations
/** [rotation] in degrees clockwise; [blur] 0–1 (motion blur along the move, up to 4 % of the canvas); [rgbSplit] 0–1 (channel offset up to 2 %). */
data class LayerState(
    val opacity: Double = 1.0, val dx: Double = 0.0, val dy: Double = 0.0, val scale: Double = 1.0,
    val rotation: Double = 0.0, val blur: Double = 0.0, val rgbSplit: Double = 0.0,
)
data class TransitionState(val a: LayerState, val b: LayerState, val color: String?)

fun transitionState(kind: TransitionKind, p0: Double): TransitionState {
    val p = clamp(p0, 0.0, 1.0)
    val e = ease(Ease.EASE_IN_OUT, p)
    val l = LayerState()
    val e3 = if (p < 0.5) 4 * p * p * p else 1 - (-2 * p + 2).pow(3) / 2
    val peak = kotlin.math.sin(Math.PI * p)
    fun jit(seed: Int) = (hash01(kotlin.math.floor(p * 24).toInt(), seed, 7) - 0.5) * 2
    return when (kind) {
        TransitionKind.FADE -> TransitionState(l, LayerState(opacity = p), null)
        TransitionKind.BLACK, TransitionKind.WHITE -> TransitionState(
            LayerState(opacity = max(0.0, 1 - 2 * p)), LayerState(opacity = max(0.0, 2 * p - 1)), if (kind == TransitionKind.BLACK) "#000000" else "#FFFFFF",
        )
        TransitionKind.SLIDE_LEFT -> TransitionState(LayerState(dx = -e), LayerState(dx = 1 - e), null)
        TransitionKind.SLIDE_RIGHT -> TransitionState(LayerState(dx = e), LayerState(dx = -(1 - e)), null)
        TransitionKind.SLIDE_UP -> TransitionState(LayerState(dy = -e), LayerState(dy = 1 - e), null)
        TransitionKind.SLIDE_DOWN -> TransitionState(LayerState(dy = e), LayerState(dy = -(1 - e)), null)
        TransitionKind.ZOOM -> TransitionState(LayerState(scale = 1 + 0.25 * e, opacity = 1 - p), LayerState(opacity = p), null)
        TransitionKind.WHIP -> TransitionState(LayerState(dx = -e3, blur = peak), LayerState(dx = 1 - e3, blur = peak), null)
        TransitionKind.SPIN -> TransitionState(
            LayerState(rotation = 180 * e, scale = 1 - 0.6 * e, opacity = if (p < 0.5) 1.0 else 0.0),
            LayerState(rotation = -180 * (1 - e), scale = 0.4 + 0.6 * e, opacity = if (p < 0.5) 0.0 else 1.0), null,
        )
        TransitionKind.GLITCH -> TransitionState(
            LayerState(opacity = if (p < 0.5) 1.0 else 0.0, dx = 0.04 * peak * jit(1), rgbSplit = peak),
            LayerState(opacity = if (p < 0.5) 0.0 else 1.0, dx = 0.04 * peak * jit(2), rgbSplit = peak), null,
        )
    }
}

data class AnimState(val opacity: Double, val scale: Double, val dy: Double, val chars: Int?)

/** In/out animation of an image or text item at item-local [t] (chars: how many characters typewriter shows, else null). */
fun animState(durationSec: Double, animIn: Anim?, animOut: Anim?, text: String?, t: Double): AnimState {
    var opacity = 1.0; var scale = 1.0; var dy = 0.0; var chars: Int? = null
    val n = text?.let { it.codePointCount(0, it.length) } ?: 0
    fun apply(a: Anim?, p: Double) {
        if (a == null || a.kind == AnimKind.NONE) return
        val e = ease(Ease.EASE_OUT, p)
        when (a.kind) {
            AnimKind.FADE -> opacity *= e
            AnimKind.POP -> { opacity *= e; scale *= if (p < 0.7) 0.6 + (1.08 - 0.6) * (p / 0.7) else 1.08 + (1 - 1.08) * ((p - 0.7) / 0.3) }
            AnimKind.SLIDE_UP -> { opacity *= e; dy += 0.05 * (1 - e) }
            AnimKind.SLIDE_DOWN -> { opacity *= e; dy -= 0.05 * (1 - e) }
            AnimKind.ZOOM -> { opacity *= e; scale *= 1.3 + (1 - 1.3) * e }
            AnimKind.TYPEWRITER -> chars = min(chars ?: n, ceil(clamp(p, 0.0, 1.0) * n).toInt())
            AnimKind.NONE -> {}
        }
    }
    if (animIn != null) apply(animIn, if (animIn.durationSec > 0) clamp(t / animIn.durationSec, 0.0, 1.0) else 1.0)
    if (animOut != null) apply(animOut, if (animOut.durationSec > 0) clamp((durationSec - t) / animOut.durationSec, 0.0, 1.0) else 1.0)
    return AnimState(r6(opacity), r6(scale), r6(dy), chars)
}

fun animState(item: ImageItem, t: Double) = animState(item.durationSec, item.animIn, item.animOut, null, t)
fun animState(item: TextItem, t: Double) = animState(item.durationSec, item.animIn, item.animOut, item.text, t)

// ------------------------------------------------------------------ colour
data class Tint(val color: String, val strength: Double)
data class FilterPreset(val id: String, val label: String, val adjust: Adjust, val tint: Tint? = null)

fun hexRgb(h: String): DoubleArray {
    val n = h.substring(1).toInt(16)
    return doubleArrayOf(((n shr 16) and 255) / 255.0, ((n shr 8) and 255) / 255.0, (n and 255) / 255.0)
}

/** "#RRGGBB" as an opaque ARGB int. */
fun hexArgb(h: String): Int = (0xFF shl 24) or h.substring(1).toInt(16)

private val IDENTITY = doubleArrayOf(1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0)

/** a ∘ b on 3×4 affine matrices: apply b first, then a. */
private fun mul(a: DoubleArray, b: DoubleArray): DoubleArray {
    val o = DoubleArray(12)
    for (i in 0 until 3) for (j in 0 until 4) {
        var s = 0.0
        for (k in 0 until 3) s += a[i * 4 + k] * b[k * 4 + j]
        if (j == 3) s += a[i * 4 + 3]
        o[i * 4 + j] = s
    }
    return o
}

private val LUMA = doubleArrayOf(0.2126, 0.7152, 0.0722)

data class EffectiveLook(val adjust: Adjust, val tint: Tint?)

/** The adjust an item ends up with: its own plus amount × the filter preset's (each clamped to ±1), and the tint. */
fun effectiveAdjust(adjust: Adjust?, filter: FilterRef?, presets: List<FilterPreset> = Presets.FILTERS): EffectiveLook {
    var ex = adjust?.exposure ?: 0.0; var co = adjust?.contrast ?: 0.0; var sa = adjust?.saturation ?: 0.0; var te = adjust?.temperature ?: 0.0
    val pr = filter?.let { f -> presets.firstOrNull { it.id == f.id } }
    var tint: Tint? = null
    if (pr != null && filter != null) {
        val k = clamp(filter.amount, 0.0, 1.0)
        ex = clamp(ex + k * (pr.adjust.exposure ?: 0.0), -1.0, 1.0)
        co = clamp(co + k * (pr.adjust.contrast ?: 0.0), -1.0, 1.0)
        sa = clamp(sa + k * (pr.adjust.saturation ?: 0.0), -1.0, 1.0)
        te = clamp(te + k * (pr.adjust.temperature ?: 0.0), -1.0, 1.0)
        if (pr.tint != null && k > 0) tint = Tint(pr.tint.color, pr.tint.strength * k)
    }
    return EffectiveLook(Adjust(ex, co, sa, te), tint)
}

/**
 * One 3×4 affine RGB matrix for the item's look (exposure → temperature → contrast → saturation → tint), row-major
 * `[r0 r1 r2 r3, g0.., b0..]`, out = M · (r, g, b, 1) on 0–1 values.
 */
fun colorMatrix(adjust: Adjust?, filter: FilterRef?, presets: List<FilterPreset> = Presets.FILTERS): List<Double> {
    val look = effectiveAdjust(adjust, filter, presets)
    val a = look.adjust
    var m = IDENTITY
    val ex = 2.0.pow(a.exposure!!)
    m = mul(doubleArrayOf(ex, 0.0, 0.0, 0.0, 0.0, ex, 0.0, 0.0, 0.0, 0.0, ex, 0.0), m)
    val k = a.temperature!!
    m = mul(doubleArrayOf(1 + 0.1 * k, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1 - 0.1 * k, 0.0), m)
    val c = 1 + a.contrast!!; val off = 0.5 * (1 - c)
    m = mul(doubleArrayOf(c, 0.0, 0.0, off, 0.0, c, 0.0, off, 0.0, 0.0, c, off), m)
    val s = 1 + a.saturation!!
    val sat = DoubleArray(12)
    for (i in 0 until 3) { for (j in 0 until 3) sat[i * 4 + j] = (1 - s) * LUMA[j] + (if (i == j) s else 0.0); sat[i * 4 + 3] = 0.0 }
    m = mul(sat, m)
    val tint = look.tint
    if (tint != null && tint.strength > 0) {
        val rgb = hexRgb(tint.color); val t = clamp(tint.strength, 0.0, 1.0)
        m = mul(doubleArrayOf(1 - t, 0.0, 0.0, rgb[0] * t, 0.0, 1 - t, 0.0, rgb[1] * t, 0.0, 0.0, 1 - t, rgb[2] * t), m)
    }
    return m.map(::r6)
}

/**
 * Highlights/shadows (Adjust, −1…1) on one channel value, after the colour matrix: shadows move values around 1/3,
 * highlights around 2/3 (weights 4v(1−v)² and 4v²(1−v), at most ±0.25·0.6).
 */
fun toneAdjust(v: Double, shadows: Double = 0.0, highlights: Double = 0.0): Double {
    if (shadows == 0.0 && highlights == 0.0) return v
    return clamp(v + 0.25 * (shadows * 4 * v * (1 - v) * (1 - v) + highlights * 4 * v * v * (1 - v)), 0.0, 1.0)
}

// ------------------------------------------------------------------ masks
private fun smoothstep(a: Double, b: Double, x: Double): Double { val t = clamp((x - a) / (b - a), 0.0, 1.0); return t * t * (3 - 2 * t) }

/** Mask opacity (0–1) at [u], [v] of the item's own frame (0–1). Distances are in item fractions; feather is the soft edge width. */
fun maskAlpha(m: Mask, u: Double, v: Double): Double {
    val cx = m.x ?: 0.5; val cy = m.y ?: 0.5
    val w = max(0.01, m.width ?: 0.5); val h = max(0.01, m.height ?: 0.5); val f = max(1e-4, m.feather ?: 0.1)
    val a = (m.rotation ?: 0.0) * Math.PI / 180; val du = u - cx; val dv = v - cy
    val x = du * kotlin.math.cos(a) + dv * kotlin.math.sin(a); val y = -du * kotlin.math.sin(a) + dv * kotlin.math.cos(a)
    fun soft(d: Double) = 1 - smoothstep(-f / 2, f / 2, d)
    val alpha = when (m.shape) {
        MaskShape.LINEAR -> soft(y)
        MaskShape.MIRROR -> soft(kotlin.math.abs(y) - h / 2)
        MaskShape.CIRCLE -> { val r = kotlin.math.hypot(x / (w / 2), y / (h / 2)); soft((r - 1) * min(w, h) / 2) }
        MaskShape.RECT -> soft(max(kotlin.math.abs(x) - w / 2, kotlin.math.abs(y) - h / 2))
        MaskShape.HEART -> {
            val X = (x / (w / 2)) * 1.15; val Y = (-y / (h / 2)) * 1.15 + 0.25
            val F = (X * X + Y * Y - 1).pow(3) - X * X * Y * Y * Y
            soft(F * 0.6 * min(w, h))
        }
        MaskShape.STAR -> {
            val X = x / (w / 2); val Y = y / (h / 2); val r = kotlin.math.hypot(X, Y)
            val ang = ((kotlin.math.atan2(X, -Y) * 180 / Math.PI + 360) % 72); val t = kotlin.math.abs(ang - 36) / 36
            val edge = 0.45 + 0.55 * t
            soft((r - edge) * min(w, h) / 2)
        }
    }
    return r6(if (m.invert == true) 1 - alpha else alpha)
}

// ------------------------------------------------------------------ SRT
private fun srtTime(t: Double): String {
    val ms = kotlin.math.floor(max(0.0, t) * 1000 + 0.5).toLong()
    val h = ms / 3_600_000; val m = (ms / 60_000) % 60; val s = (ms / 1000) % 60
    return String.format(java.util.Locale.ROOT, "%02d:%02d:%02d,%03d", h, m, s, ms % 1000)
}

/** The captions as an .srt file (one cue per caption page; upper case when the style says so). Empty without captions. */
fun toSrt(p: EditProject): String {
    val ct = captionTrack(p) ?: return ""
    return captionPages(p).mapIndexed { i, pg ->
        val text = pg.words.joinToString(" ") { it.text }
        "${i + 1}\n${srtTime(pg.startSec)} --> ${srtTime(pg.endSec)}\n${if (ct.style.text.uppercase == true) text.uppercase() else text}\n"
    }.joinToString("\n")
}

/** True when [m] is the identity (no colour work needed). */
fun isIdentityMatrix(m: List<Double>): Boolean = m.indices.all { kotlin.math.abs(m[it] - IDENTITY[it]) < 1e-9 }

// ------------------------------------------------------------------ audio
data class GainPoint(val t: Double, val gain: Double)

/** Timeline ranges where speech/voice is heard, for ducking. */
fun duckRegions(p: EditProject, duck: Duck): List<Range> {
    val rs = ArrayList<Range>()
    if (DuckUnder.VOICE in duck.under) {
        for (t in p.tracks) if (t.kind == TrackKind.VOICE && t.muted != true) for (it in t.items) { val s = itemSpan(p, t, it); rs += Range(s.startSec, s.endSec) }
    }
    if (DuckUnder.SPEECH in duck.under) for (w in captionWords(p)) rs += Range(w.startSec, w.endSec)
    return mergeRanges(rs, EditLimits.SPEECH_JOIN_SEC)
}

/** Base gain of a clip at timeline t, without ducking (volume, keyframes, fades, transition crossfade). */
private fun baseGain(p: EditProject, track: Track, item: MediaClip, t: Double, spans: List<MainSpan>): Double {
    if (p.mute == true || track.muted == true || item.muted == true) return 0.0
    val span = itemSpan(p, track, item)
    if (t < span.startSec - 1e-9 || t > span.endSec + 1e-9) return 0.0
    val local = t - span.startSec; val len = span.endSec - span.startSec
    var g = (track.volume ?: 1.0) * propAt(item.keyframes, KfProp.VOLUME, item.volume ?: 1.0, local)
    item.fadeInSec?.let { if (it > 0) g *= clamp(local / it, 0.0, 1.0) }
    item.fadeOutSec?.let { if (it > 0) g *= clamp((len - local) / it, 0.0, 1.0) }
    if (track.kind == TrackKind.MAIN) {
        val i = spans.indexOfFirst { it.id == item.id }
        val me = spans[i]; val next = spans.getOrNull(i + 1)
        if (me.transitionSec > 0) g *= clamp(local / me.transitionSec, 0.0, 1.0)
        if (next != null && next.transitionSec > 0) g *= clamp((me.endSec - t) / next.transitionSec, 0.0, 1.0)
    }
    return g
}

/** Ramp down (attack, before speech) and back up (release, after it): attackSec/releaseSec, else fadeSec for both. */
fun duckTimes(d: Duck): Pair<Double, Double> {
    val f = d.fadeSec ?: 0.25
    return max(0.05, d.attackSec ?: f) to max(0.05, d.releaseSec ?: f)
}

/** Ducking multiplier at [t] for a music track with [duck]. */
private fun duckGain(regions: List<Range>, duck: Duck, t: Double): Double {
    val level = clamp(duck.level ?: 0.3, 0.05, 1.0); val (att, rel) = duckTimes(duck)
    var m = 1.0
    for (r in regions) {
        val d = when {
            t >= r.startSec && t <= r.endSec -> 1.0
            t < r.startSec -> clamp(1 - (r.startSec - t) / att, 0.0, 1.0)
            else -> clamp(1 - (t - r.endSec) / rel, 0.0, 1.0)
        }
        m = min(m, 1 - (1 - level) * d)
    }
    return m
}

/**
 * A clip's gain over the timeline as piecewise-linear points (t ascending, timeline seconds, from the clip's start to
 * its end). Points are placed at every corner (fades, transitions, keyframes, duck ramps), so linear interpolation
 * between them is exact except inside eased keyframes, which are sampled every 0.1 s.
 */
fun audioEnvelope(p: EditProject, trackId: String, itemId: String): List<GainPoint> {
    val track = p.track(trackId) ?: return emptyList()
    val item = track.items.firstOrNull { it.id == itemId } as? MediaClip ?: return emptyList()
    val span = itemSpan(p, track, item)
    val end = min(span.endSec, durationSec(p))
    if (end <= span.startSec) return emptyList()
    val ts = LinkedHashSet<Double>(listOf(span.startSec, end))
    fun add(t: Double) { if (t > span.startSec && t < end) ts += r6(t) }
    item.fadeInSec?.let { if (it != 0.0) add(span.startSec + it) }
    item.fadeOutSec?.let { if (it != 0.0) add(span.endSec - it) }
    val spans = timeline(p)
    if (track.kind == TrackKind.MAIN) {
        val i = spans.indexOfFirst { it.id == item.id }
        val me = spans[i]; val next = spans.getOrNull(i + 1)
        if (me.transitionSec != 0.0) add(me.startSec + me.transitionSec)
        if (next != null && next.transitionSec != 0.0) add(next.startSec)
    }
    val kv = item.keyframes?.get(KfProp.VOLUME) ?: emptyList()
    kv.forEachIndexed { idx, k ->
        add(span.startSec + k.t)
        val nk = kv.getOrNull(idx + 1)
        if (nk != null && k.ease != null && k.ease != Ease.LINEAR) {
            if (k.ease == Ease.HOLD) add(span.startSec + nk.t - 1e-4)
            else { var s = k.t + 0.1; while (s < nk.t - 1e-9) { add(span.startSec + s); s += 0.1 } }
        }
    }
    var regions = emptyList<Range>()
    val duck = track.duck
    if (track.kind == TrackKind.MUSIC && duck != null) {
        regions = duckRegions(p, duck)
        val (att, rel) = duckTimes(duck)
        for (r in regions) { add(r.startSec - att); add(r.startSec); add(r.endSec); add(r.endSec + rel) }

    }
    return ts.sorted().map { t ->
        var g = baseGain(p, track, item, t, spans)
        if (regions.isNotEmpty() && duck != null) g *= duckGain(regions, duck, t)
        GainPoint(r6(t), r6(g))
    }
}

/** Linear interpolation of an envelope at timeline [t] (0 outside it). */
fun envelopeGain(env: List<GainPoint>, t: Double): Double {
    if (env.isEmpty() || t < env.first().t - 1e-9 || t > env.last().t + 1e-9) return 0.0
    if (t <= env.first().t) return env.first().gain
    for (i in 0 until env.size - 1) {
        val a = env[i]; val b = env[i + 1]
        if (t <= b.t) return if (b.t - a.t <= 0) b.gain else a.gain + (b.gain - a.gain) * (t - a.t) / (b.t - a.t)
    }
    return env.last().gain
}

/**
 * Reads an envelope at increasing times in O(1) amortised, for per-sample gain in an audio processor (a time before
 * the previous one, i.e. a seek, restarts the search). Outside the envelope it holds the end values, so rounding of
 * a clip's edges never clicks to silence.
 */
class EnvelopeCursor(private val env: List<GainPoint>) {
    private var i = 0
    private var lastT = Double.NEGATIVE_INFINITY

    fun gainAt(t: Double): Double {
        if (env.isEmpty()) return 0.0
        if (t <= env.first().t) return env.first().gain
        if (t >= env.last().t) return env.last().gain
        if (t < lastT) i = 0
        lastT = t
        while (t > env[i + 1].t) i++
        val a = env[i]; val b = env[i + 1]
        return if (b.t - a.t <= 0) b.gain else a.gain + (b.gain - a.gain) * (t - a.t) / (b.t - a.t)
    }
}

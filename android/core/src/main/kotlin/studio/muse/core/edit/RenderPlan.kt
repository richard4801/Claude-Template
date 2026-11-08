package studio.muse.core.edit

import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/*
 * The render plan: everything the on-device composition engine (app: studio.muse.app.platform.edit) needs to turn a v2
 * project into a Media3 Composition, worked out here as plain data so it is unit-tested on the JVM. The Media3 layer
 * only translates this plan (one EditedMediaItemSequence per layer/lane, gaps, effects) and asks it per frame where
 * each layer goes ([RenderPlan.placement]) and what the overlays show ([RenderPlan.textFrame], [RenderPlan.captionFrame]).
 *
 * How the project maps onto a Composition (plans/video-editor.md "Editor v2", Android):
 *  - Video layers are compositor inputs. Media3's DefaultVideoCompositor draws input 0 ON TOP and takes the output
 *    frame times from it, and it stalls when an input runs out of frames, so: layer 0 is a transparent "clock" (an
 *    image at the canvas fps for the whole duration, alpha 0) that sets the output cadence; every other layer is padded
 *    with gaps to the full duration (gaps render black, so a layer is given alpha 0 wherever it has no item).
 *  - The main track is laid out A/B-roll: a clip goes to the other main layer than the previous clip when it has a
 *    transition into it (Composition can't crossfade inside one sequence), else to the same one. The compositor
 *    settings animate alpha/offset/scale per frame from [transitionState]. Draw order is fixed (main A above main B), so
 *    when the incoming clip sits on the lower layer the two alphas are remapped to give the same picture.
 *  - Black/white transitions keep both clips opaque and draw the colour as a composition-level overlay ([Flash]) whose
 *    alpha is 1 − max(opacity A, opacity B): the same mix as fading each clip over the colour.
 *  - Overlay video tracks (PiP) and image tracks are more layers, above the main track in track order.
 *  - Text, hooks and captions are composition-level overlays (drawn over all video layers), in track order.
 *  - Sound: every clip keeps its own audio in its layer/lane with a gain envelope ([audioEnvelope]); music, voice and
 *    sfx tracks are audio-only lanes padded with gaps; a clip with `audioAsset` plays that asset's sound in an extra lane.
 */

/** What the engine probed about an asset's file (display size: rotation already applied). */
data class MediaInfo(val durationSec: Double, val width: Int, val height: Int, val fps: Double = 0.0, val hasAudio: Boolean = false)

/** FILL (wave 1): the blurred copy of the main clip behind contain-fitted main clips (canvas.fill = blur). */
enum class LayerRole { CLOCK, OVERLAY, MAIN, FILL, BACKGROUND }

/** A source crop in normalised device coordinates (Media3 `Crop(left, right, bottom, top)`), -1…1. */
data class CropNdc(val left: Double, val right: Double, val bottom: Double, val top: Double)

/**
 * How a picture is prepared before the compositor places it: crop, scaled to [textureWidth]×[textureHeight] (its fitted
 * size on the canvas at scale 1, or the canvas itself for a full-frame cover), drawn at [baseScale] × the item's scale.
 */
data class VideoLook(
    val crop: CropNdc?,
    val textureWidth: Int,
    val textureHeight: Int,
    val baseScale: Double,
    /** 3×4 row-major affine colour matrix, null when it's the identity. */
    val colorMatrix: List<Double>?,
    val chroma: Chroma?,
    /** The item's look (plans/video-editor.md "Looks"), null when it has none or it changes nothing. */
    val look: Look? = null,
    /** Edit suite: highlights/shadows after the colour matrix (baked into the colour LUT), null when none. */
    val tone: Tone? = null,
    /** Edit suite: the item's shape mask (alpha), null when none. */
    val mask: Mask? = null,
    /** Background removal's matte (the clip's alpha from a video aligned with its source), null when none. */
    val alphaMatte: AlphaMatte? = null,
    /** Wave 1, blur fill: box-blur radius in canvas pixels (then × BLUR_FILL_DARKEN), null when this isn't the fill layer. */
    val fillBlur: Int? = null,
)

/** A clip or image in a layer or lane, placed on the timeline. */
data class PlannedClip(
    val trackId: String,
    val itemId: String,
    /** The file played (for a clip with `audioAsset` in an audio lane, that asset). */
    val assetId: String,
    val startUs: Long,
    val endUs: Long,
    /** Source clipping (0 / item length for images). */
    val clipStartUs: Long,
    val clipEndUs: Long,
    val speed: Double,
    val isImage: Boolean,
    /** Keep the sound (with [envelope]); false = the item's audio is removed. */
    val withAudio: Boolean,
    /** Drop the picture (audio lanes). */
    val removeVideo: Boolean,
    /** Gain over the timeline (seconds) while [withAudio]. */
    val envelope: List<GainPoint>,
    /** Thin faster clips back to this rate (like v1). */
    val frameDropFps: Double?,
    val look: VideoLook?,
    /**
     * Edit suite: constant-speed source pieces the engine renders back to back (a speed curve → 48 pieces, else one
     * piece = clipStart/clipEnd at [speed]). Microseconds of source; the sum of their lengths ≈ endUs − startUs.
     */
    val pieces: List<PlannedPiece> = listOf(PlannedPiece(clipStartUs, clipEndUs, speed)),
)

/** A constant-speed sub-clip of a [PlannedClip] (source microseconds). */
data class PlannedPiece(val clipStartUs: Long, val clipEndUs: Long, val speed: Double)

/**
 * The source time (µs) this clip shows at timeline time [timelineUs] (µs): its pieces play back to back from [PlannedClip.startUs],
 * each at its own speed. Clamped to the clip. Background removal's matte is sampled at this time (it is aligned with the
 * source), so trims and speed changes keep it on the subject.
 */
fun PlannedClip.sourceUsAt(timelineUs: Long): Long {
    var t = (timelineUs - startUs).coerceAtLeast(0).toDouble()
    for (p in pieces) {
        val len = (p.clipEndUs - p.clipStartUs) / p.speed
        if (t <= len) return (p.clipStartUs + t * p.speed).toLong().coerceIn(p.clipStartUs, p.clipEndUs)
        t -= len
    }
    return pieces.lastOrNull()?.clipEndUs ?: clipEndUs
}

sealed interface LaneEntry { val startUs: Long; val endUs: Long; val durationUs: Long get() = endUs - startUs }
data class Gap(override val startUs: Long, override val endUs: Long) : LaneEntry
data class ClipEntry(val clip: PlannedClip) : LaneEntry { override val startUs get() = clip.startUs; override val endUs get() = clip.endUs }
/** A still colour for the whole duration ([argb] 0 = transparent: the clock). */
data class StillEntry(override val startUs: Long, override val endUs: Long, val argb: Int) : LaneEntry

/** One compositor input ([index] = its sequence index; 0 is drawn on top). */
data class VideoLayer(val index: Int, val role: LayerRole, val trackId: String?, val entries: List<LaneEntry>, val withAudio: Boolean) {
    val clips: List<PlannedClip> get() = entries.filterIsInstance<ClipEntry>().map { it.clip }
}

/** An audio-only sequence. */
data class AudioLane(val trackId: String, val entries: List<LaneEntry>) {
    val clips: List<PlannedClip> get() = entries.filterIsInstance<ClipEntry>().map { it.clip }
}

/** A black/white dip between two main clips. */
data class Flash(val startSec: Double, val endSec: Double, val kind: TransitionKind)

/** A composition-level overlay, drawn in list order (later on top). */
sealed interface OverlayPiece
data class TextPiece(val trackId: String, val item: TextItem, val startSec: Double, val endSec: Double) : OverlayPiece
data class CaptionPiece(val trackId: String, val style: CaptionStyle, val pages: List<CaptionPage>) : OverlayPiece
data class FlashPiece(val flash: Flash) : OverlayPiece

/** Where a layer's picture goes at one moment: centre in canvas fractions, scale, clockwise degrees, alpha. */
data class Placement(
    val alpha: Double, val centerX: Double, val centerY: Double, val scale: Double, val rotationCw: Double,
    /** Edit suite transitions: motion blur 0–1 along x (whip) and RGB split 0–1 (glitch). */
    val blur: Double = 0.0, val rgbSplit: Double = 0.0,
    /** Wave 1, mirror: the picture flipped about its centre (before scale and rotation). */
    val flipX: Boolean = false, val flipY: Boolean = false,
) {
    companion object { val HIDDEN = Placement(0.0, 0.5, 0.5, 1.0, 0.0) }
}

/** A text item's state at one moment (the shown text after typewriter and uppercase). */
data class TextFrame(val text: String, val alpha: Double, val centerX: Double, val centerY: Double, val scale: Double, val rotationCw: Double, val flipX: Boolean = false, val flipY: Boolean = false)

/**
 * A caption page at one moment: its words (uppercased when the style says so), the active one, and how to draw each.
 * [stripe] = the word with a marker stripe behind it (highlighter preset).
 */
data class CaptionFrame(
    val words: List<String>, val active: Int, val highlighted: List<Boolean>, val boxed: Int?, val activeScale: Double, val alpha: Double,
    val stripe: Int? = null,
)

data class RenderPlan(
    val project: EditProject,
    val width: Int,
    val height: Int,
    val fps: Double,
    val durationSec: Double,
    val durationUs: Long,
    /** Compositor inputs, front (index 0, the clock) to back. */
    val layers: List<VideoLayer>,
    val audioLanes: List<AudioLane>,
    val overlays: List<OverlayPiece>,
    val hasAudio: Boolean,
) {
    private val spans = timeline(project)
    private val mainIndex = project.mainClips.withIndex().associate { (i, c) -> c.id to i }
    private val layerOfMain = layers.filter { it.role == LayerRole.MAIN }.flatMap { l -> l.clips.map { it.itemId to l.index } }.toMap()

    /** The clip or image layer [layerIndex] shows at [tSec], or null (a gap, the clock, the background). */
    fun clipAt(layerIndex: Int, tSec: Double): PlannedClip? {
        val tUs = us(tSec)
        return (layers.getOrNull(layerIndex)?.entries?.firstOrNull { it is ClipEntry && tUs >= it.startUs && tUs < it.endUs } as ClipEntry?)?.clip
    }

    /** Where layer [layerIndex] draws at timeline [tSec] (HIDDEN where it has no item, and always for the clock). */
    fun placement(layerIndex: Int, tSec: Double): Placement {
        val layer = layers.getOrNull(layerIndex) ?: return Placement.HIDDEN
        if (layer.role == LayerRole.CLOCK) return Placement.HIDDEN
        if (layer.role == LayerRole.BACKGROUND) return Placement(1.0, 0.5, 0.5, 1.0, 0.0)
        if (layer.role == LayerRole.FILL) return if (clipAt(layerIndex, tSec) != null) Placement(1.0, 0.5, 0.5, 1.0, 0.0) else Placement.HIDDEN
        val clip = clipAt(layerIndex, tSec) ?: return Placement.HIDDEN
        val track = project.track(clip.trackId) ?: return Placement.HIDDEN
        val item = track.items.firstOrNull { it.id == clip.itemId } ?: return Placement.HIDDEN
        return if (layer.role == LayerRole.MAIN) mainPlacement(item as VideoClip, tSec) else itemPlacement(item, track, tSec)
    }

    private fun basePlacement(item: Visual, local: Double): Placement {
        val tr = item.transform
        val k = item.keyframes
        return Placement(
            alpha = propAt(k, KfProp.OPACITY, item.opacity ?: 1.0, local),
            centerX = propAt(k, KfProp.X, tr?.x ?: 0.5, local),
            centerY = propAt(k, KfProp.Y, tr?.y ?: 0.5, local),
            scale = propAt(k, KfProp.SCALE, tr?.scale ?: 1.0, local),
            rotationCw = propAt(k, KfProp.ROTATION, tr?.rotation ?: 0.0, local),
            flipX = tr?.flipX == true, flipY = tr?.flipY == true,
        )
    }

    private fun itemPlacement(item: Item, track: Track, t: Double): Placement {
        val span = itemSpan(project, track, item)
        val local = t - span.startSec
        return when (item) {
            is ImageItem -> {
                val b = basePlacement(item, local)
                val a = animState(item, local)
                b.copy(alpha = b.alpha * a.opacity, scale = b.scale * a.scale, centerY = b.centerY + a.dy)
            }
            is VideoClip -> basePlacement(item, local)
            else -> Placement.HIDDEN
        }
    }

    private fun mainPlacement(c: VideoClip, t: Double): Placement {
        val i = mainIndex[c.id] ?: return Placement.HIDDEN
        val me = spans[i]
        val base = basePlacement(c, t - me.startSec)
        val next = spans.getOrNull(i + 1)
        // Incoming: inside my own transition. Outgoing: inside the next clip's.
        val (kind, p, incoming) = when {
            me.transitionSec > 0 && t < me.startSec + me.transitionSec -> Triple(c.transitionIn!!.kind, (t - me.startSec) / me.transitionSec, true)
            next != null && next.transitionSec > 0 && t >= next.startSec -> Triple(project.mainClips[i + 1].transitionIn!!.kind, (t - next.startSec) / next.transitionSec, false)
            else -> return base
        }
        val st = transitionState(kind, p)
        val mine = if (incoming) st.b else st.a
        var placed = base.copy(
            centerX = base.centerX + mine.dx, centerY = base.centerY + mine.dy, scale = base.scale * mine.scale,
            rotationCw = base.rotationCw + mine.rotation, blur = mine.blur, rgbSplit = mine.rgbSplit,
        )
        if (kind == TransitionKind.BLACK || kind == TransitionKind.WHITE) {
            // The colour is drawn by a Flash overlay; the clip shows fully while it is the visible one.
            return placed.copy(alpha = if (mine.opacity > 0) base.alpha else 0.0)
        }
        if (kind != TransitionKind.FADE && kind != TransitionKind.ZOOM) return placed.copy(alpha = base.alpha * mine.opacity)
        // Fade/zoom: B (incoming) belongs on top. If its layer is behind A's, remap: A' = a(1−b), B' = b / (1 − A').
        val outIdx = if (incoming) i - 1 else i
        val inIdx = outIdx + 1
        val outClip = project.mainClips[outIdx]; val inClip = project.mainClips[inIdx]
        val a = basePlacement(outClip, t - spans[outIdx].startSec).alpha * st.a.opacity
        val b = basePlacement(inClip, t - spans[inIdx].startSec).alpha * st.b.opacity
        val inOnTop = (layerOfMain[inClip.id] ?: 0) < (layerOfMain[outClip.id] ?: 0)
        val alpha = if (inOnTop) (if (incoming) b else a) else {
            val a2 = a * (1 - b)
            if (incoming) (if (a2 < 1 - 1e-9) clamp(b / (1 - a2), 0.0, 1.0) else b) else a2
        }
        placed = placed.copy(alpha = alpha)
        return placed
    }

    /** The alpha of a black/white [flash] colour at [tSec] (0 outside it). */
    fun flashAlpha(flash: Flash, tSec: Double): Double {
        if (tSec < flash.startSec || tSec >= flash.endSec) return 0.0
        val st = transitionState(flash.kind, (tSec - flash.startSec) / (flash.endSec - flash.startSec))
        return 1 - max(st.a.opacity, st.b.opacity)
    }

    /** A text item's state at [tSec], or null when it isn't on screen. */
    fun textFrame(piece: TextPiece, tSec: Double): TextFrame? {
        if (tSec < piece.startSec || tSec >= piece.endSec) return null
        val it = piece.item
        val local = tSec - it.startSec
        val a = animState(it, local)
        val k = it.keyframes; val tr = it.transform
        var text = if (it.style.uppercase == true) it.text.uppercase() else it.text
        a.chars?.let { n -> text = text.substring(0, text.offsetByCodePoints(0, min(n, text.codePointCount(0, text.length)))) }
        val alpha = propAt(k, KfProp.OPACITY, it.opacity ?: 1.0, local) * a.opacity
        if (alpha <= 0.0 || text.isEmpty()) return null
        return TextFrame(
            text, alpha,
            centerX = propAt(k, KfProp.X, tr?.x ?: 0.5, local),
            centerY = propAt(k, KfProp.Y, tr?.y ?: 0.5, local) + a.dy,
            scale = propAt(k, KfProp.SCALE, tr?.scale ?: 1.0, local) * a.scale,
            rotationCw = propAt(k, KfProp.ROTATION, tr?.rotation ?: 0.0, local),
            flipX = tr?.flipX == true, flipY = tr?.flipY == true,
        )
    }

    /**
     * The caption shown at [tSec], or null. Presets: highlight/pop = the active word in highlightColor (pop also 1.15×),
     * karaoke = every word up to the active one, box = a highlightColor box behind the active word, single = one word
     * popping in (0.6 → 1 over 0.15 s), plain = no highlight.
     */
    fun captionFrame(piece: CaptionPiece, tSec: Double): CaptionFrame? {
        val at = captionAt(piece.pages, tSec) ?: return null
        val page = piece.pages[at.page]
        val style = piece.style
        val words = page.words.map { if (style.text.uppercase == true) it.text.uppercase() else it.text }
        val hl = words.indices.map { k ->
            when (style.preset) {
                CaptionPreset.HIGHLIGHT, CaptionPreset.POP, CaptionPreset.NEON -> k == at.word
                CaptionPreset.KARAOKE -> k <= at.word
                else -> false
            }
        }
        val scale = when (style.preset) {
            CaptionPreset.POP -> 1.15
            CaptionPreset.SINGLE -> 0.6 + 0.4 * ease(Ease.EASE_OUT, (tSec - page.startSec) / 0.15)
            else -> 1.0
        }
        return CaptionFrame(words, at.word, hl, if (style.preset == CaptionPreset.BOX) at.word else null, scale, 1.0,
            stripe = if (style.preset == CaptionPreset.HIGHLIGHTER) at.word else null)
    }

    companion object {
        fun us(sec: Double): Long = (sec * 1_000_000).roundToLong()
    }
}

/**
 * Plans the render of [project]: [infos] = probed file facts per asset id (assets without an entry use the project's
 * own width/height/duration/hasAudio); [paletteIds] = the suite looks the app ships. Throws [EditProblem] when the
 * project isn't valid.
 */
fun planRender(project: EditProject, infos: Map<String, MediaInfo>, presets: List<FilterPreset> = Presets.FILTERS, paletteIds: Set<String> = emptySet()): RenderPlan {
    val total = validate(project, presets, paletteIds = paletteIds)
    val p = project
    val cv = p.canvas
    val totalUs = RenderPlan.us(total)
    fun info(id: String): MediaInfo {
        infos[id]?.let { return it }
        val a = p.asset(id) ?: throw EditProblem("edits.assets", "asset $id is missing")
        return MediaInfo(a.durationSec ?: 0.0, a.width ?: cv.width, a.height ?: cv.height, 0.0, a.hasAudio ?: (a.kind != AssetKind.IMAGE))
    }
    val frameDrop = cv.fps

    fun look(v: Visual, assetId: String, defaultFit: Fit): VideoLook {
        val inf = info(assetId)
        val cr = v.crop
        var l = cr?.left ?: 0.0; var t = cr?.top ?: 0.0; var r = cr?.right ?: 0.0; var b = cr?.bottom ?: 0.0
        val sw = max(1, inf.width).toDouble(); val sh = max(1, inf.height).toDouble()
        var cw = sw * (1 - l - r); var ch = sh * (1 - t - b)
        val fit = v.fit ?: defaultFit
        val geometryStatic = v.keyframes.orEmpty().keys.none { it == KfProp.X || it == KfProp.Y || it == KfProp.SCALE || it == KfProp.ROTATION } &&
            (v.transform == null || (v.transform!!.x ?: 0.5) == 0.5 && (v.transform!!.y ?: 0.5) == 0.5 && (v.transform!!.scale ?: 1.0) == 1.0 && (v.transform!!.rotation ?: 0.0) == 0.0)
        val tw: Int; val th: Int; var base = 1.0
        if (fit == Fit.COVER && geometryStatic) {
            // Crop the source to the canvas aspect and render it at the canvas size: no oversized texture.
            val ca = cv.width.toDouble() / cv.height
            if (cw / ch > ca) { val extra = (cw - ch * ca) / sw / 2; l += extra; r += extra; cw = ch * ca }
            else if (cw / ch < ca) { val extra = (ch - cw / ca) / sh / 2; t += extra; b += extra; ch = cw / ca }
            tw = cv.width; th = cv.height
        } else {
            val k = if (fit == Fit.COVER) max(cv.width / cw, cv.height / ch) else min(cv.width / cw, cv.height / ch)
            val fw = cw * k; val fh = ch * k
            val q = min(1.0, MAX_TEXTURE / max(fw, fh))
            tw = max(2, (fw * q).roundToInt()); th = max(2, (fh * q).roundToInt()); base = 1 / q
        }
        val crop = if (l > 1e-9 || r > 1e-9 || t > 1e-9 || b > 1e-9) CropNdc(-1 + 2 * l, 1 - 2 * r, -1 + 2 * b, 1 - 2 * t) else null
        val m = colorMatrix(v.adjust, v.filter, presets).takeUnless(::isIdentityMatrix)
        return VideoLook(crop, tw, th, base, m, (v as? VideoClip)?.chroma, v.look?.takeUnless { it.isNoop() }, Tone.of(v.adjust), v.mask, (v as? VideoClip)?.alphaMatte)
    }

    /** A clip limited to the project's end; null when it starts after it. */
    fun place(track: Track, item: MediaClip, span: Span, assetId: String, withVideoLook: VideoLook?, removeVideo: Boolean): PlannedClip? {
        val startUs = RenderPlan.us(span.startSec)
        if (startUs >= totalUs) return null
        (item as? VideoClip)?.holdSec?.let { hold ->
            // Freeze frame (wave 1): one source frame played slowly enough to last the hold (each frame shows until the
            // next one, as in slow motion), silent.
            val inf = info(assetId)
            val frame = 1.0 / (inf.fps.takeIf { it > 0 } ?: cv.fps)
            val src0 = if (inf.durationSec > frame) min(item.inSec, inf.durationSec - frame) else item.inSec
            val inUs = RenderPlan.us(src0); val outUs = RenderPlan.us(src0 + frame)
            val sp = frame / hold
            return PlannedClip(track.id, item.id, assetId, startUs, RenderPlan.us(min(span.endSec, total)), inUs, outUs, sp, isImage = false, withAudio = false,
                removeVideo = removeVideo, envelope = emptyList(), frameDropFps = null, look = withVideoLook, pieces = listOf(PlannedPiece(inUs, outUs, sp)))
        }
        val endSec = min(span.endSec, total)
        val speed = item.speedOrNull ?: 1.0
        val outSec = min(item.outSec, clipSourceAt(item, endSec - span.startSec))
        val env = audioEnvelope(p, track.id, item.id)
        val inf = info(assetId)
        val audible = inf.hasAudio && env.any { it.gain > 0 }
        // Speed curves play as constant-speed pieces, cut where the project ends.
        val pieces = speedPieces(item).filter { it.inSec < outSec - 1e-9 }.map { pc -> PlannedPiece(RenderPlan.us(pc.inSec), RenderPlan.us(min(pc.outSec, outSec)), pc.speed) }
        val fast = pieces.any { it.speed > 1.0 }
        return PlannedClip(
            track.id, item.id, assetId, startUs, RenderPlan.us(endSec), RenderPlan.us(item.inSec), RenderPlan.us(outSec), speed, isImage = false,
            withAudio = audible, removeVideo = removeVideo, envelope = if (audible) env else emptyList(),
            frameDropFps = if (fast && !removeVideo) frameDrop else null, look = withVideoLook, pieces = pieces,
        )

    }

    fun lane(clips: List<PlannedClip>): List<LaneEntry> {
        val out = ArrayList<LaneEntry>()
        var cur = 0L
        for (c in clips.sortedBy { it.startUs }) {
            if (c.startUs - cur >= MIN_GAP_US) out += Gap(cur, c.startUs)
            out += ClipEntry(if (c.startUs < cur) c.copy(startUs = cur) else c)
            cur = c.endUs
        }
        if (totalUs - cur >= MIN_GAP_US) out += Gap(cur, totalUs)
        return out
    }

    var fillLayer: List<PlannedClip>? = null
    val audioLanes = ArrayList<AudioLane>()
    val extraAudio = ArrayList<PlannedClip>()

    // Main track: A/B roll.
    val main = p.main
    val mainLayers = arrayOf(ArrayList<PlannedClip>(), ArrayList())
    run {
        var layer = 0
        val spans = timeline(p)
        p.mainClips.forEachIndexed { i, c ->
            if (i > 0 && c.transitionIn != null) layer = 1 - layer
            val span = Span(spans[i].startSec, spans[i].endSec)
            val withLook = if (main.hidden == true) null else look(c, c.asset, Fit.COVER)
            val pc = place(main, c, span, c.asset, withLook, removeVideo = main.hidden == true) ?: return@forEachIndexed
            if (c.audioAsset != null) {
                mainLayers[layer] += pc.copy(withAudio = false, envelope = emptyList())
                place(main, c, span, c.audioAsset, null, removeVideo = true)?.let { extraAudio += it.copy(frameDropFps = null) }
            } else mainLayers[layer] += pc
        }
    }

    // Other visual tracks, bottom to top.
    val overlayLayers = ArrayList<Pair<Track, List<PlannedClip>>>()
    val overlays = ArrayList<OverlayPiece>()
    val flashes = ArrayList<Flash>()
    if (main.hidden != true) {
        val spans = timeline(p)
        p.mainClips.forEachIndexed { i, c ->
            val tr = c.transitionIn ?: return@forEachIndexed
            if (i > 0 && (tr.kind == TransitionKind.BLACK || tr.kind == TransitionKind.WHITE)) flashes += Flash(spans[i].startSec, spans[i].startSec + spans[i].transitionSec, tr.kind)
        }
        flashes.forEach { overlays += FlashPiece(it) }
    }
    for (t in p.tracks) {
        when (t.kind) {
            TrackKind.VIDEO -> {
                val clips = t.items.mapNotNull { it ->
                    val c = it as VideoClip
                    val span = itemSpan(p, t, c)
                    val withLook = if (t.hidden == true) null else look(c, c.asset, Fit.CONTAIN)
                    val pc = place(t, c, span, c.asset, withLook, removeVideo = t.hidden == true) ?: return@mapNotNull null
                    if (c.audioAsset != null) {
                        place(t, c, span, c.audioAsset, null, removeVideo = true)?.let { extraAudio += it.copy(frameDropFps = null) }
                        pc.copy(withAudio = false, envelope = emptyList())
                    } else pc
                }
                if (t.hidden == true) { if (clips.any { it.withAudio }) audioLanes += AudioLane(t.id, lane(clips.filter { it.withAudio })) }
                else if (clips.isNotEmpty()) overlayLayers += t to clips
            }
            TrackKind.IMAGE -> if (t.hidden != true) {
                val clips = t.items.mapNotNull { it ->
                    val im = it as ImageItem
                    val startUs = RenderPlan.us(im.startSec)
                    if (startUs >= totalUs) return@mapNotNull null
                    val endUs = min(RenderPlan.us(im.startSec + im.durationSec), totalUs)
                    PlannedClip(t.id, im.id, im.asset, startUs, endUs, 0, endUs - startUs, 1.0, isImage = true, withAudio = false, removeVideo = false,
                        envelope = emptyList(), frameDropFps = null, look = look(im, im.asset, Fit.CONTAIN))
                }
                if (clips.isNotEmpty()) overlayLayers += t to clips
            }
            TrackKind.TEXT -> if (t.hidden != true) for (it in t.items) {
                val tx = it as TextItem
                if (tx.startSec < total) overlays += TextPiece(t.id, tx, tx.startSec, min(tx.startSec + tx.durationSec, total))
            }
            TrackKind.CAPTION -> if (t.hidden != true && t.caption != null) {
                val pages = captionPages(p)
                if (pages.isNotEmpty()) overlays += CaptionPiece(t.id, t.caption.style, pages)
            }
            TrackKind.MUSIC, TrackKind.VOICE, TrackKind.SFX -> {
                val clips = t.items.mapNotNull { it ->
                    val c = it as AudioClip
                    place(t, c, itemSpan(p, t, c), c.asset, null, removeVideo = true)?.takeIf { pc -> pc.withAudio }?.copy(frameDropFps = null)
                }
                if (clips.isNotEmpty()) audioLanes += AudioLane(t.id, lane(clips))
            }
            TrackKind.MAIN -> {}
        }
    }
    if (extraAudio.any { it.withAudio }) {
        // Sound taken from another asset ("audioAsset"), by track so items never overlap within a lane.
        extraAudio.filter { it.withAudio }.groupBy { it.trackId }.forEach { (tid, cs) -> audioLanes += AudioLane("$tid~audio", lane(cs)) }
    }

    // Compositor inputs front to back: clock, overlay tracks (top first), main A, main B, background.
    val layers = ArrayList<VideoLayer>()
    fun addLayer(role: LayerRole, trackId: String?, entries: List<LaneEntry>, withAudio: Boolean) { layers += VideoLayer(layers.size, role, trackId, entries, withAudio) }
    addLayer(LayerRole.CLOCK, null, listOf(StillEntry(0, totalUs, 0)), false)
    for ((t, clips) in overlayLayers.asReversed()) addLayer(LayerRole.OVERLAY, t.id, lane(clips), clips.any { it.withAudio })
    for (k in 0..1) {
        val clips = mainLayers[k]
        if (clips.isEmpty()) continue
        if (main.hidden == true) { if (clips.any { it.withAudio }) audioLanes += AudioLane("${main.id}#$k", lane(clips.filter { it.withAudio }.map { it.copy(frameDropFps = null) })) }
        else addLayer(LayerRole.MAIN, main.id, lane(clips), clips.any { it.withAudio })
    }
    // Wave 1, blur fill: each main clip again, cover-fitted, blurred and darkened, behind the main layers. During a
    // transition the fill switches to the incoming clip half-way through (blurFillClip).
    if (cv.fill == CanvasFill.BLUR && main.hidden != true) {
        val spans = timeline(p)
        val radius = blurFillRadius(cv.width, cv.height)
        val fill = ArrayList<PlannedClip>()
        p.mainClips.forEachIndexed { i, c ->
            val s = spans[i]
            val from = if (s.transitionSec > 0) s.startSec + s.transitionSec / 2 else s.startSec
            val next = spans.getOrNull(i + 1)
            val to = if (next != null && next.transitionSec > 0) next.startSec + next.transitionSec / 2 else s.endSec
            if (to - from < 1e-3) return@forEachIndexed
            val a = from - s.startSec; val b = to - s.startSec
            val piece: VideoClip = if (c.holdSec != null) c.copy(holdSec = b - a) else {
                val x0 = (clipSourceAt(c, a) - c.inSec) / (c.outSec - c.inSec); val x1 = (clipSourceAt(c, b) - c.inSec) / (c.outSec - c.inSec)
                c.copy(inSec = clipSourceAt(c, a), outSec = clipSourceAt(c, b), speedCurve = c.speedCurve?.let { subCurve(it, x0, x1) })
            }
            val bare = piece.copy(transform = null, crop = null, mask = null, chroma = null, alphaMatte = null, keyframes = null, fit = Fit.COVER)
            val lk = look(bare, c.asset, Fit.COVER).copy(fillBlur = radius)
            place(main, bare, Span(from, to), c.asset, lk, removeVideo = false)?.let { fill += it.copy(withAudio = false, envelope = emptyList()) }
        }
        if (fill.isNotEmpty()) fillLayer = fill
    }
    val bg = cv.background ?: "#000000"
    fillLayer?.let { addLayer(LayerRole.FILL, main.id, lane(it), false) }
    if (!bg.equals("#000000", ignoreCase = true)) addLayer(LayerRole.BACKGROUND, null, listOf(StillEntry(0, totalUs, hexArgb(bg))), false)

    val hasAudio = layers.any { it.withAudio } || audioLanes.isNotEmpty()
    return RenderPlan(p, cv.width, cv.height, cv.fps, total, totalUs, layers, audioLanes, overlays, hasAudio)
}

/** Textures are kept within this many pixels a side (GL limits); the compositor scales them back up. */
const val MAX_TEXTURE = 4096.0

/** Gaps shorter than this are left out (the next item starts a hair early instead). */
const val MIN_GAP_US = 1_000L

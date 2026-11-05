package studio.muse.app.ui.screens.edit

import studio.muse.core.edit.Asset
import studio.muse.core.edit.AssetKind
import studio.muse.core.edit.AudioClip
import studio.muse.core.edit.CaptionPreset
import studio.muse.core.edit.CaptionStyle
import studio.muse.core.edit.CaptionTrack
import studio.muse.core.edit.CaptionWord
import studio.muse.core.edit.Duck
import studio.muse.core.edit.DuckUnder
import studio.muse.core.edit.EditLimits
import studio.muse.core.edit.EditProject
import studio.muse.core.edit.ExportShape
import studio.muse.core.edit.Fit
import studio.muse.core.edit.HookTemplate
import studio.muse.core.edit.ImageItem
import studio.muse.core.edit.Item
import studio.muse.core.edit.Keyframe
import studio.muse.core.edit.KfProp
import studio.muse.core.edit.Look
import studio.muse.core.edit.MediaClip
import studio.muse.core.edit.Presets
import studio.muse.core.edit.SpeedCurve
import studio.muse.core.edit.TextItem
import studio.muse.core.edit.Track
import studio.muse.core.edit.TrackKind
import studio.muse.core.edit.Transform
import studio.muse.core.edit.Transition
import studio.muse.core.edit.VideoClip
import studio.muse.core.edit.addItem
import studio.muse.core.edit.clipLength
import studio.muse.core.edit.clipTimeAt
import studio.muse.core.edit.ids
import studio.muse.core.edit.itemSpan
import studio.muse.core.edit.locate
import studio.muse.core.edit.newId
import studio.muse.core.edit.removeItem
import studio.muse.core.edit.startSecOrNull
import studio.muse.core.edit.timeline
import studio.muse.core.edit.updateItem
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * The Edit suite's project operations (pure; each returns a new project or null when it doesn't apply). They build on
 * the core editing API (studio.muse.core.edit.Editing) and keep the contract's rules; the controller validates the
 * result before it becomes an undo step.
 */
object SuiteOps {
    fun dbToGain(db: Double): Double = 10.0.pow(db / 20)
    fun gainToDb(g: Double): Double = if (g <= 0) -60.0 else 20 * log10(g)

    /** The asset the main track mostly plays (the source take). */
    fun sourceAsset(p: EditProject): Asset? = p.mainClips.firstOrNull()?.let { p.asset(it.asset) }

    // ------------------------------------------------------------ clips
    /** A copy of main clip [id] right after it (`<id>.2`…), without a transition. */
    fun duplicate(p: EditProject, id: String): EditProject? {
        val (t, i) = p.locate(id) ?: return null
        val item = t.items[i]
        if (t.kind == TrackKind.MAIN) {
            val c = item as VideoClip
            return p.addItem(t.id, c.copy(id = p.newId(c.id, dotted = true), transitionIn = null), i + 1)
        }
        // Other tracks: the copy goes right after the original, where it fits.
        val span = itemSpan(p, t, item)
        val copy = withStart(withId(item, p.newId(item.id, dotted = true)), span.endSec)
        return p.addItem(t.id, copy)
    }

    /** Deletes an item; with [ripple] the later items of its (non-main) track move left to close the gap. */
    fun delete(p: EditProject, id: String, ripple: Boolean): EditProject? {
        val (t, i) = p.locate(id) ?: return null
        val removed = p.removeItem(id) ?: return null
        if (!ripple || t.kind == TrackKind.MAIN) return removed
        val span = itemSpan(p, t, t.items[i])
        val gap = span.endSec - span.startSec
        val track = removed.track(t.id) ?: return removed
        val shifted = track.items.map { it ->
            val s = it.startSecOrNull ?: return@map it
            if (s >= span.endSec - 1e-9) withStart(it, maxOf(0.0, s - gap)) else it
        }
        return removed.copy(tracks = removed.tracks.map { if (it.id == t.id) it.copy(items = shifted) else it })
    }

    /** Constant speed on a main/PiP clip (drops a curve; keyframes past the new end are dropped). */
    fun setSpeed(p: EditProject, id: String, speed: Double): EditProject? = p.updateItem(id) { it ->
        val c = it as? VideoClip ?: return@updateItem it
        val n = c.copy(speed = speed.coerceIn(EditLimits.MIN_SPEED, EditLimits.MAX_SPEED), speedCurve = null)
        n.copy(keyframes = trimKeys(n.keyframes, clipLength(n)))
    }

    fun setCurve(p: EditProject, id: String, curve: SpeedCurve?): EditProject? = p.updateItem(id) { it ->
        val c = it as? VideoClip ?: return@updateItem it
        val n = c.copy(speedCurve = curve, speed = if (curve != null) 1.0 else c.speed)
        n.copy(keyframes = trimKeys(n.keyframes, clipLength(n)))
    }

    private fun trimKeys(k: Map<KfProp, List<Keyframe>>?, len: Double) = k?.mapValues { (_, v) -> v.filter { it.t <= len + EditLimits.END_SLACK_SEC } }?.filterValues { it.isNotEmpty() }?.ifEmpty { null }

    /** The same transition into every main clip after the first (shortened to fit short clips; Cut = none). */
    fun transitionAll(p: EditProject, tr: Transition?): EditProject? {
        val main = p.main
        val clips = p.mainClips
        val items = clips.mapIndexed { i, c ->
            if (i == 0 || tr == null) c.copy(transitionIn = null)
            else {
                val max = minOf(clipLength(c), clipLength(clips[i - 1])) / 2
                val d = minOf(tr.durationSec, max)
                if (d < EditLimits.MIN_TRANSITION_SEC) c.copy(transitionIn = null) else c.copy(transitionIn = tr.copy(durationSec = (d * 100).toInt() / 100.0))
            }
        }
        if (items == clips) return null
        return p.copy(tracks = p.tracks.map { if (it === main) it.copy(items = items) else it })
    }

    /** Sets keyframe [prop] at item-local [t] to [v] (replacing one within 0.05 s). */
    fun keyframe(p: EditProject, id: String, prop: KfProp, t: Double, v: Double): EditProject? = p.updateItem(id) { it ->
        fun keys(k: Map<KfProp, List<Keyframe>>?): Map<KfProp, List<Keyframe>> {
            val list = (k?.get(prop).orEmpty().filter { abs(it.t - t) > 0.05 } + Keyframe((t * 1000).roundToInt() / 1000.0, v, studio.muse.core.edit.Ease.EASE_IN_OUT)).sortedBy { it.t }
            return (k.orEmpty() + (prop to list))
        }
        when (it) { is VideoClip -> it.copy(keyframes = keys(it.keyframes)); is ImageItem -> it.copy(keyframes = keys(it.keyframes)); is TextItem -> it.copy(keyframes = keys(it.keyframes)); else -> it }
    }

    // ------------------------------------------------------------ captions
    fun withCaptions(p: EditProject, assetId: String, words: List<CaptionWord>, preset: CaptionPreset = CaptionPreset.POP): EditProject {
        val existing = p.tracks.firstOrNull { it.kind == TrackKind.CAPTION }
        val style = existing?.caption?.style ?: Presets.CAPTION_STYLES.getValue(preset)
        val track = Track(existing?.id ?: "captions", TrackKind.CAPTION, caption = CaptionTrack(assetId, words.take(EditLimits.MAX_WORDS), style))
        return if (existing != null) p.copy(tracks = p.tracks.map { if (it === existing) track else it }) else p.copy(tracks = p.tracks + track)
    }

    fun captionStyle(p: EditProject, f: (CaptionStyle) -> CaptionStyle): EditProject? {
        val t = p.tracks.firstOrNull { it.kind == TrackKind.CAPTION && it.caption != null } ?: return null
        val c = t.caption!!
        val n = f(c.style)
        if (n == c.style) return null
        return p.copy(tracks = p.tracks.map { if (it === t) it.copy(caption = c.copy(style = n)) else it })
    }

    /** A preset's look with the user's position/highlight choice kept. */
    fun switchPreset(old: CaptionStyle, preset: CaptionPreset): CaptionStyle =
        Presets.CAPTION_STYLES.getValue(preset).let { s -> s.copy(y = old.y ?: s.y) }

    // ------------------------------------------------------------ audio
    fun musicTrack(p: EditProject): Track? = p.tracks.firstOrNull { it.kind == TrackKind.MUSIC }

    /** Auto-duck the music under speech/voice (on) or not; [levelDb] e.g. −12. */
    fun duck(p: EditProject, on: Boolean, levelDb: Double = -12.0, attack: Double? = null, release: Double? = null): EditProject? {
        val t = musicTrack(p) ?: return null
        val duck = if (!on) null else Duck(
            level = dbToGain(levelDb).coerceIn(0.05, 1.0).let { (it * 1000).roundToInt() / 1000.0 },
            under = listOf(DuckUnder.SPEECH, DuckUnder.VOICE), attackSec = attack ?: t.duck?.attackSec ?: 0.2, releaseSec = release ?: t.duck?.releaseSec ?: 0.6,
        )
        if (duck == t.duck) return null
        return p.copy(tracks = p.tracks.map { if (it === t) it.copy(duck = duck) else it })
    }

    /** Adds an audio file as a new asset on a music (or voice) track at [atSec]. */
    fun addAudio(p: EditProject, upload: String, durationSec: Double, atSec: Double, kind: TrackKind = TrackKind.MUSIC, name: String? = null): EditProject? {
        val assetId = newAssetId(p, if (kind == TrackKind.VOICE) "vo" else "music")
        val withAsset = p.copy(assets = p.assets + Asset(assetId, AssetKind.AUDIO, upload = upload, durationSec = durationSec, hasAudio = true))
        val trackId = withAsset.tracks.firstOrNull { it.kind == kind && fitsAt(withAsset, it, atSec, durationSec) }?.id
        val base = if (trackId != null) withAsset else withAsset.copy(tracks = withAsset.tracks + Track(withAsset.newId(kind.wire), kind, name = name))
        val tid = trackId ?: base.tracks.last().id
        val len = minOf(durationSec, EditLimits.MAX_OUTPUT_SEC)
        return base.addItem(tid, AudioClip(base.newId(if (kind == TrackKind.VOICE) "v" else "m"), assetId, atSec, 0.0, len))
    }

    private fun fitsAt(p: EditProject, t: Track, at: Double, len: Double) = t.items.none { val s = itemSpan(p, t, it); at < s.endSec && at + len > s.startSec }

    fun newAssetId(p: EditProject, prefix: String): String { var k = 1; while (p.assets.any { it.id == "$prefix$k" }) k++; return "$prefix$k" }

    /** Timeline times of the music beat marks (all or strong ones) inside each music clip. */
    fun beatTimes(p: EditProject, strongOnly: Boolean): List<Double> {
        val out = ArrayList<Double>()
        for (t in p.tracks) if (t.kind == TrackKind.MUSIC) for (it in t.items) {
            val c = it as AudioClip
            val marks = (if (strongOnly) c.strongBeats ?: c.beats else c.beats).orEmpty()
            for (b in marks) if (b >= c.inSec && b <= c.outSec) out += c.startSec + (b - c.inSec)
        }
        return out.sorted()
    }

    /** [t] moved to the nearest beat within [within] seconds (else unchanged). */
    fun snap(t: Double, beats: List<Double>, within: Double = 0.35): Double = beats.minByOrNull { abs(it - t) }?.takeIf { abs(it - t) <= within } ?: t

    // ------------------------------------------------------------ text, overlay, looks, ratio
    fun addHook(p: EditProject, hook: HookTemplate, atSec: Double, text: String = hook.text): Pair<EditProject, String>? {
        val dur = studio.muse.core.edit.durationSec(p)
        val start = atSec.coerceIn(0.0, maxOf(0.0, dur - 0.5))
        val len = minOf(hook.durationSec, maxOf(0.5, dur - start))
        val base = p.tracks.firstOrNull { t -> t.kind == TrackKind.TEXT && fitsAt(p, t, start, len) }?.let { p } ?: p.copy(tracks = p.tracks + Track(p.newId("text"), TrackKind.TEXT, name = "Hook"))
        val tid = base.tracks.last { t -> t.kind == TrackKind.TEXT && fitsAt(base, t, start, len) }.id
        val id = base.newId("t")
        val item = hook.toItem(id, start, text).copy(durationSec = len)
        return base.addItem(tid, item)?.let { it to id }
    }

    /** Adds a take as a picture-in-picture clip at [atSec] (lower right, 40 %). */
    fun addPip(p: EditProject, takeId: String, durationSec: Double, atSec: Double, width: Int? = null, height: Int? = null): Pair<EditProject, String>? {
        val assetId = p.assets.firstOrNull { it.take == takeId && it.kind == AssetKind.VIDEO }?.id ?: newAssetId(p, "pip")
        val withAsset = if (p.assets.any { it.id == assetId }) p else p.copy(assets = p.assets + Asset(assetId, AssetKind.VIDEO, take = takeId, durationSec = durationSec, width = width, height = height, hasAudio = true))
        val dur = studio.muse.core.edit.durationSec(withAsset)
        val start = atSec.coerceIn(0.0, maxOf(0.0, dur - 0.5))
        val len = minOf(durationSec, maxOf(0.5, dur - start))
        val base = withAsset.tracks.firstOrNull { t -> t.kind == TrackKind.VIDEO && fitsAt(withAsset, t, start, len) }?.let { withAsset }
            ?: withAsset.copy(tracks = withAsset.tracks + Track(withAsset.newId("pip"), TrackKind.VIDEO, name = "Overlay"))
        val tid = base.tracks.last { t -> t.kind == TrackKind.VIDEO && fitsAt(base, t, start, len) }.id
        val id = base.newId("p")
        val clip = VideoClip(id, assetId, 0.0, len, 1.0, startSec = start, fit = Fit.CONTAIN, transform = Transform(0.72, 0.68, 0.4), muted = true)
        return base.addItem(tid, clip)?.let { it to id }
    }

    /** Sets (null = removes) a look on [ids]. */
    fun setLook(p: EditProject, ids: List<String>, look: Look?): EditProject? {
        var cur = p
        var changed = false
        for (id in ids) cur.updateItem(id) { when (it) { is VideoClip -> it.copy(look = look); is ImageItem -> it.copy(look = look); else -> it } }?.let { cur = it; changed = true }
        return if (changed) cur else null
    }

    /** The canvas for [shape] keeping the project's short side. */
    fun ratio(p: EditProject, shape: ExportShape): EditProject? {
        val short = minOf(p.canvas.width, p.canvas.height)
        fun even(v: Double) = (v / 2).roundToInt() * 2
        val (w, h) = if (shape.w <= shape.h) short to even(short.toDouble() * shape.h / shape.w) else even(short.toDouble() * shape.w / shape.h) to short
        if (w == p.canvas.width && h == p.canvas.height) return null
        return p.copy(canvas = p.canvas.copy(width = w.coerceAtMost(4096), height = h.coerceAtMost(4096)))
    }

    // ------------------------------------------------------------ words (edit by text)
    /** A transcript word and whether the edit still plays it (its middle is inside a kept main clip of its asset). */
    data class WordState(val index: Int, val text: String, val startSec: Double, val endSec: Double, val kept: Boolean, val filler: Boolean)

    /** The core filler list plus "like" (also passed to suggestCuts as an extra filler). */
    val FILLERS: Set<String> = (studio.muse.core.edit.CutDefaults.FILLERS + "like").toSet()

    fun words(p: EditProject): List<WordState> {
        val ct = p.tracks.firstOrNull { it.kind == TrackKind.CAPTION }?.caption ?: return emptyList()
        val clips = p.mainClips.filter { it.asset == ct.asset }
        return ct.words.mapIndexed { i, w ->
            val mid = (w.startSec + w.endSec) / 2
            WordState(i, w.text, w.startSec, w.endSec, clips.any { mid >= it.inSec && mid < it.outSec }, studio.muse.core.edit.normWord(w.text) in FILLERS)
        }
    }

    /** Where in the timeline source time [sec] of [assetId] plays (first main clip that keeps it), or null. */
    fun timelineAt(p: EditProject, assetId: String, sec: Double): Double? {
        val spans = timeline(p)
        p.mainClips.forEachIndexed { i, c -> if (c.asset == assetId && sec >= c.inSec && sec < c.outSec) return spans[i].startSec + clipTimeAt(c, sec) }
        return null
    }

    // ------------------------------------------------------------ helpers
    fun withStart(it: Item, s: Double): Item = when (it) {
        is VideoClip -> it.copy(startSec = s); is AudioClip -> it.copy(startSec = s); is ImageItem -> it.copy(startSec = s); is TextItem -> it.copy(startSec = s)
    }

    fun withId(it: Item, id: String): Item = when (it) {
        is VideoClip -> it.copy(id = id); is AudioClip -> it.copy(id = id); is ImageItem -> it.copy(id = id); is TextItem -> it.copy(id = id)
    }

    /** The clip with sound the audio tools act on: the selected video/audio clip, else the main clip. */
    fun soundClip(p: EditProject, selectedId: String?, fallback: VideoClip?): MediaClip? =
        (selectedId?.let { id -> p.tracks.flatMap { it.items }.firstOrNull { it.id == id } } as? MediaClip) ?: fallback

    val EditProject.allIds: Set<String> get() = ids
}

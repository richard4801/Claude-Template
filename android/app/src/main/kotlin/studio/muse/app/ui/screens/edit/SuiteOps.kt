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
import studio.muse.core.edit.moveMainClip
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
    fun keyframe(p: EditProject, id: String, prop: KfProp, t: Double, v: Double, ease: studio.muse.core.edit.Ease? = null): EditProject? = p.updateItem(id) { it ->
        fun keys(k: Map<KfProp, List<Keyframe>>?): Map<KfProp, List<Keyframe>> {
            val old = k?.get(prop).orEmpty().firstOrNull { abs(it.t - t) <= 0.05 }
            val list = (k?.get(prop).orEmpty().filter { abs(it.t - t) > 0.05 } + Keyframe(old?.t ?: ((t * 1000).roundToInt() / 1000.0), v, ease ?: old?.ease ?: studio.muse.core.edit.Ease.EASE_IN_OUT)).sortedBy { it.t }
            return (k.orEmpty() + (prop to list))
        }
        when (it) { is VideoClip -> it.copy(keyframes = keys(it.keyframes)); is ImageItem -> it.copy(keyframes = keys(it.keyframes)); is TextItem -> it.copy(keyframes = keys(it.keyframes)); else -> it }
    }

    /** The item's keyframes, changed by [f] (empty lists and maps are dropped). */
    fun editKeys(p: EditProject, id: String, f: (Map<KfProp, List<Keyframe>>) -> Map<KfProp, List<Keyframe>>): EditProject? = p.updateItem(id) { it ->
        fun g(k: Map<KfProp, List<Keyframe>>?) = f(k.orEmpty()).filterValues { v -> v.isNotEmpty() }.ifEmpty { null }
        when (it) { is VideoClip -> it.copy(keyframes = g(it.keyframes)); is ImageItem -> it.copy(keyframes = g(it.keyframes)); is TextItem -> it.copy(keyframes = g(it.keyframes)); is AudioClip -> it.copy(keyframes = g(it.keyframes)) }
    }

    /** Easing of every keyframe at item-local [t] (±0.05 s). */
    fun easeAt(p: EditProject, id: String, t: Double, ease: studio.muse.core.edit.Ease): EditProject? =
        editKeys(p, id) { k -> k.mapValues { (_, l) -> l.map { if (abs(it.t - t) <= 0.05) it.copy(ease = ease) else it } } }

    /** Removes the keyframes at item-local [t] (±0.05 s), of [prop] or of every property. */
    fun removeKeysAt(p: EditProject, id: String, t: Double, prop: KfProp? = null): EditProject? =
        editKeys(p, id) { k -> k.mapValues { (pr, l) -> if (prop == null || pr == prop) l.filter { abs(it.t - t) > 0.05 } else l } }

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

    /** The name of the track a detached clip sound goes on (a voice track, so music ducks under it). */
    const val CLIP_SOUND_TRACK = "Clip sound"

    /** Whether main clip [c]'s own sound is there to hear or detach (its asset has sound). */
    fun hasSound(p: EditProject, c: VideoClip): Boolean = p.asset(c.audioAsset ?: c.asset)?.hasAudio != false

    /**
     * Detach audio (extract the clip's sound): main clip [clipId]'s sound becomes its own audio clip at the same place
     * on a "Clip sound" voice track (same source times, volume, fades and voice settings), and the video clip goes
     * silent, so the sound can be moved, trimmed or kept when the picture is cut. Refused for a silent clip, an already
     * muted one, and a clip not at 1× (audio clips play at 1×). Returns the project and the new audio clip's id.
     */
    fun detachAudio(p: EditProject, clipId: String): Pair<EditProject, String>? {
        val (t, i) = p.locate(clipId) ?: return null
        if (t.kind != TrackKind.MAIN) return null
        val c = t.items[i] as VideoClip
        if (c.muted == true || c.speedCurve != null || abs(c.speed - 1.0) > 1e-9 || !hasSound(p, c)) return null
        val span = itemSpan(p, t, c)
        val len = span.endSec - span.startSec
        val track = p.tracks.firstOrNull { it.kind == TrackKind.VOICE && it.name == CLIP_SOUND_TRACK && fitsAt(p, it, span.startSec, len) }
        val base = if (track != null) p else p.copy(tracks = p.tracks + Track(p.newId("sound"), TrackKind.VOICE, name = CLIP_SOUND_TRACK))
        val tid = track?.id ?: base.tracks.last().id
        val id = base.newId("a")
        val audio = AudioClip(id, c.audioAsset ?: c.asset, (span.startSec * 1e6).roundToInt() / 1e6, c.inSec, c.outSec,
            volume = c.volume, fadeInSec = c.fadeInSec, fadeOutSec = c.fadeOutSec, voiceEffect = c.voiceEffect, enhance = c.enhance,
            keyframes = c.keyframes?.filterKeys { it == KfProp.VOLUME }?.ifEmpty { null })
        val added = base.addItem(tid, audio) ?: return null
        val muted = added.updateItem(clipId) { (it as VideoClip).copy(muted = true, fadeInSec = null, fadeOutSec = null) } ?: return null
        return muted to id
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

    /** The style a new plain text starts with: bold sans, white with a soft shadow, centred, 5.5 % of the height. */
    val DEFAULT_TEXT_STYLE = studio.muse.core.edit.TextStyle(studio.muse.core.edit.Font.SANS, 700, .055, "#FFFFFF", studio.muse.core.edit.Align.CENTER,
        maxWidthPct = .85, lineHeight = 1.15, shadow = studio.muse.core.edit.Shadow("#000000", .5, .08, .04))

    /** Plain text at [atSec] for 3 s, in the middle of the picture, on a text track where it fits. */
    fun addText(p: EditProject, atSec: Double, text: String = "Your text", style: studio.muse.core.edit.TextStyle = DEFAULT_TEXT_STYLE): Pair<EditProject, String>? {
        val dur = studio.muse.core.edit.durationSec(p)
        val start = atSec.coerceIn(0.0, maxOf(0.0, dur - 0.5))
        val len = minOf(3.0, maxOf(0.5, dur - start))
        val base = p.tracks.firstOrNull { t -> t.kind == TrackKind.TEXT && fitsAt(p, t, start, len) }?.let { p } ?: p.copy(tracks = p.tracks + Track(p.newId("text"), TrackKind.TEXT, name = "Text"))
        val tid = base.tracks.last { t -> t.kind == TrackKind.TEXT && fitsAt(base, t, start, len) }.id
        val id = base.newId("t")
        val item = TextItem(id, (start * 1000).roundToInt() / 1000.0, (len * 1000).roundToInt() / 1000.0, text, style, transform = Transform(0.5, 0.5),
            animIn = studio.muse.core.edit.Anim(studio.muse.core.edit.AnimKind.FADE, 0.3))
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

    /**
     * Another take (or edited version) added to the end of the main track, whole, as a new clip (its asset is shared
     * with a PiP of the same take). Returns the project and the new clip's id.
     */
    fun appendTake(p: EditProject, takeId: String, durationSec: Double, width: Int? = null, height: Int? = null, hasAudio: Boolean? = true): Pair<EditProject, String>? {
        if (durationSec < EditLimits.MIN_CLIP_SOURCE_SEC) return null
        val assetId = p.assets.firstOrNull { it.take == takeId && it.kind == AssetKind.VIDEO }?.id ?: newAssetId(p, "take")
        val withAsset = if (p.assets.any { it.id == assetId }) p else p.copy(assets = p.assets + Asset(assetId, AssetKind.VIDEO, take = takeId, durationSec = durationSec, width = width, height = height, hasAudio = hasAudio))
        val id = withAsset.newId("c")
        val clip = VideoClip(id, assetId, 0.0, durationSec, 1.0)
        return withAsset.addItem(withAsset.main.id, clip, withAsset.main.items.size)?.let { it to id }
    }

    // ------------------------------------------------------------ moving and trimming on the timeline
    /**
     * Item [id] (not on the main track) moved by [deltaSec] from where it is in [p]; its start or end snaps to the
     * nearest of [snaps] within [snapSec]. Items on a track stay in time order; an overlap is refused by validation.
     */
    fun moveBy(p: EditProject, id: String, deltaSec: Double, snaps: List<Double> = emptyList(), snapSec: Double = 0.0): EditProject? {
        val (t, i) = p.locate(id) ?: return null
        if (t.kind == TrackKind.MAIN) return null
        val item = t.items[i]
        val span = itemSpan(p, t, item)
        val len = span.endSec - span.startSec
        var start = maxOf(0.0, span.startSec + deltaSec)
        if (snapSec > 0) {
            val best = snaps.flatMap { s -> listOf(s to s, (s - len) to s) }.filter { it.first >= 0 }.minByOrNull { abs(it.first - start) }
            if (best != null && abs(best.first - start) <= snapSec) start = best.first
        }
        start = (start * 1000).roundToInt() / 1000.0
        if (abs(start - span.startSec) < 1e-9) return null
        val moved = withStart(item, start)
        val items = t.items.toMutableList().apply { set(i, moved) }.sortedBy { it.startSecOrNull ?: 0.0 }
        return p.copy(tracks = p.tracks.map { if (it === t) it.copy(items = items) else it })
    }

    /** Main clip [id] moved to position [toIndex] (transitions that no longer fit are dropped). */
    fun reorder(p: EditProject, id: String, toIndex: Int): EditProject? {
        val from = p.main.items.indexOfFirst { it.id == id }
        if (from < 0) return null
        return p.moveMainClip(from, toIndex.coerceIn(0, p.main.items.size - 1))
    }

    /**
     * Any item trimmed by its [left] or right edge by [deltaSec] of timeline time, measured from its state in [p]:
     * video/audio clips change their source in/out (a left trim on another track also moves the start, so the
     * picture stays put); text and images change their start and duration. Clamped to the file and to 0.1 s.
     */
    fun trimBy(p: EditProject, id: String, left: Boolean, deltaSec: Double): EditProject? {
        val (t, i) = p.locate(id) ?: return null
        val item = t.items[i]
        val min = EditLimits.MIN_CLIP_SOURCE_SEC
        fun r(v: Double) = (v * 1000).roundToInt() / 1000.0
        val next: Item = when (item) {
            // A freeze frame's edges change how long it holds.
            is VideoClip if item.holdSec != null -> item.copy(holdSec = r((item.holdSec!! + if (left) -deltaSec else deltaSec).coerceIn(studio.muse.core.edit.HOLD_MIN_SEC, studio.muse.core.edit.HOLD_MAX_SEC)),
                startSec = if (left) item.startSec?.let { r(maxOf(0.0, it + deltaSec)) } else item.startSec)
            is MediaClip -> {
                val sp = when (item) { is VideoClip -> if (item.speedCurve != null) (item.outSec - item.inSec) / clipLength(item) else item.speed; is AudioClip -> item.speed ?: 1.0 }
                val dur = p.asset(item.asset)?.durationSec ?: item.outSec
                if (left) {
                    val ni = r((item.inSec + deltaSec * sp).coerceIn(0.0, item.outSec - min))
                    val moved = (ni - item.inSec) / sp
                    when (item) {
                        is VideoClip -> item.copy(inSec = ni, startSec = item.startSec?.let { r(maxOf(0.0, it + moved)) })
                        is AudioClip -> item.copy(inSec = ni, startSec = r(maxOf(0.0, item.startSec + moved)))
                    }
                } else {
                    val no = r((item.outSec + deltaSec * sp).coerceIn(item.inSec + min, dur))
                    when (item) { is VideoClip -> item.copy(outSec = no); is AudioClip -> item.copy(outSec = no) }
                }
            }
            is TextItem -> if (left) { val d = deltaSec.coerceIn(-item.startSec, item.durationSec - min); item.copy(startSec = r(item.startSec + d), durationSec = r(item.durationSec - d)) }
                else item.copy(durationSec = r(maxOf(min, item.durationSec + deltaSec)))
            is ImageItem -> if (left) { val d = deltaSec.coerceIn(-item.startSec, item.durationSec - min); item.copy(startSec = r(item.startSec + d), durationSec = r(item.durationSec - d)) }
                else item.copy(durationSec = r(maxOf(min, item.durationSec + deltaSec)))
            else -> return null
        }
        if (next == item) return null
        return p.copy(tracks = p.tracks.map { if (it === t) it.copy(items = it.items.toMutableList().apply { set(i, next) }) else it })
    }

    /**
     * Replace: main clip [clipId] plays take [takeId] instead, from its start, for the same source length where the
     * take is long enough (else the whole take); speed, look, transform, sound settings and transition stay.
     */
    fun replaceClip(p: EditProject, clipId: String, takeId: String, durationSec: Double): EditProject? {
        val c = p.mainClips.firstOrNull { it.id == clipId } ?: return null
        if (durationSec < EditLimits.MIN_CLIP_SOURCE_SEC) return null
        val assetId = p.assets.firstOrNull { it.take == takeId && it.kind == AssetKind.VIDEO }?.id ?: newAssetId(p, "take")
        val withAsset = if (p.assets.any { it.id == assetId }) p else p.copy(assets = p.assets + Asset(assetId, AssetKind.VIDEO, take = takeId, durationSec = durationSec, hasAudio = true))
        val len = if (c.holdSec != null) EditLimits.MIN_CLIP_SOURCE_SEC else minOf(c.outSec - c.inSec, durationSec)
        return withAsset.updateItem(clipId) { (it as VideoClip).copy(asset = assetId, inSec = 0.0, outSec = (len * 1000).roundToInt() / 1000.0, audioAsset = null, alphaMatte = null) }
    }

    /** The music clip at timeline [t] (or the selected one): its track and clip. */
    fun musicAt(p: EditProject, t: Double, selectedId: String?): Pair<Track, AudioClip>? {
        for (tr in p.tracks) if (tr.kind == TrackKind.MUSIC) for (it in tr.items) {
            val c = it as AudioClip
            if (c.id == selectedId) return tr to c
        }
        for (tr in p.tracks) if (tr.kind == TrackKind.MUSIC) for (it in tr.items) {
            val sp = itemSpan(p, tr, it)
            if (t >= sp.startSec && t < sp.endSec) return tr to (it as AudioClip)
        }
        return null
    }

    /** Another take's sound (its video file, sound only) at [atSec] on a sound effects track. */
    fun addTakeSound(p: EditProject, takeId: String, durationSec: Double, atSec: Double): Pair<EditProject, String>? {
        val assetId = p.assets.firstOrNull { it.take == takeId && it.kind == AssetKind.VIDEO }?.id ?: newAssetId(p, "take")
        val withAsset = if (p.assets.any { it.id == assetId }) p else p.copy(assets = p.assets + Asset(assetId, AssetKind.VIDEO, take = takeId, durationSec = durationSec, hasAudio = true))
        val start = atSec.coerceIn(0.0, maxOf(0.0, studio.muse.core.edit.durationSec(withAsset) - 0.1))
        val len = minOf(durationSec, maxOf(0.1, studio.muse.core.edit.durationSec(withAsset) - start))
        val tr = withAsset.tracks.firstOrNull { it.kind == TrackKind.SFX && fitsAt(withAsset, it, start, len) }
        val base = if (tr != null) withAsset else withAsset.copy(tracks = withAsset.tracks + Track(withAsset.newId("sfx"), TrackKind.SFX, name = "Sound"))
        val tid = tr?.id ?: base.tracks.last().id
        val id = base.newId("s")
        return base.addItem(tid, AudioClip(id, assetId, (start * 1000).roundToInt() / 1000.0, 0.0, (len * 1000).roundToInt() / 1000.0))?.let { it to id }
    }

    /** Audio clip [id] repeated back to back until the video's end (each copy as long as the original, the last cut short). */
    fun loopToEnd(p: EditProject, id: String): EditProject? {
        val (t, i) = p.locate(id) ?: return null
        val c = t.items[i] as? AudioClip ?: return null
        val end = studio.muse.core.edit.durationSec(p)
        val len = clipLength(c)
        var at = c.startSec + len
        var cur = p
        var n = 2
        while (at < end - 0.1 && n < 200) {
            val l = minOf(len, end - at)
            val copy = c.copy(id = cur.newId(c.id, dotted = true), startSec = (at * 1000).roundToInt() / 1000.0, outSec = ((c.inSec + l) * 1000).roundToInt() / 1000.0, fadeInSec = null)
            cur = cur.addItem(t.id, copy) ?: break
            at += l; n++
        }
        return if (cur === p) null else cur
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

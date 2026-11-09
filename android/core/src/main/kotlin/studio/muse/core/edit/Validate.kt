package studio.muse.core.edit

/**
 * All the rules of plans/video-editor.md "Rules", in the reference's order: throws [EditProblem] (field path + message)
 * on the first one broken, else returns the project's duration. Shape problems (missing fields, wrong types, unknown
 * kinds) are caught earlier by [EditJson.parse] with the same field paths. [presets] = the known filters (the
 * reference defaults to none, which skips the filter-id check; the apps always pass the bundled table); [lookIds] = the
 * bundled looks a `pack:` LUT may name (empty skips that check, like the reference); [paletteIds] = the suite looks a
 * `palette:` LUT may name (empty = none, so every `palette:` look is refused, like the reference).
 */
fun validate(p: EditProject, presets: List<FilterPreset> = Presets.FILTERS, lookIds: Set<String> = LookPack.IDS, paletteIds: Set<String> = emptySet()): Double =
    Validator(p, presets, lookIds, paletteIds).run()

/** The first problem, or null when [p] is valid. */
fun problemOf(p: EditProject, presets: List<FilterPreset> = Presets.FILTERS, lookIds: Set<String> = LookPack.IDS, paletteIds: Set<String> = emptySet()): EditProblem? =
    try { validate(p, presets, lookIds, paletteIds); null } catch (e: EditProblem) { e }

private val HEX = Regex("^#[0-9A-Fa-f]{6}$")

private class Validator(val p: EditProject, presets: List<FilterPreset>, private val lookIds: Set<String>, private val paletteIds: Set<String>) {
    private val assets = HashMap<String, Asset>()
    private val ids = HashSet<String>()
    private val filterIds = presets.map { it.id }.toSet()

    fun bad(f: String, m: String): Nothing = throw EditProblem(f, m)
    private fun fmt(v: Double) = EditJson.number(v).content
    fun num(f: String, v: Double?, lo: Double, hi: Double, optional: Boolean = true) {
        if (v == null && optional) return
        if (v == null || !v.isFinite() || v < lo || v > hi) bad(f, "must be a number from ${fmt(lo)} to ${fmt(hi)}")
    }
    fun color(f: String, v: String?, optional: Boolean = true) {
        if (v == null && optional) return
        if (v == null || !HEX.matches(v)) bad(f, "must be a colour like #FF0000")
    }
    fun id(f: String, v: String) { if (v.isEmpty() || v.length > 64) bad(f, "must be an id of 1–64 characters") }

    fun run(): Double {
        if (p.version != 2) bad("edits.version", "must be 2")
        if (p.sourceTakeId.isEmpty()) bad("edits.sourceTakeId", "is required")
        val cv = p.canvas
        num("edits.canvas.width", cv.width.toDouble(), 16.0, 4096.0, false); num("edits.canvas.height", cv.height.toDouble(), 16.0, 4096.0, false)
        num("edits.canvas.fps", cv.fps, 1.0, 120.0, false)
        color("edits.canvas.background", cv.background)
        if (p.assets.size > EditLimits.MAX_ASSETS) bad("edits.assets", "must be a list of at most ${EditLimits.MAX_ASSETS}")
        p.assets.forEachIndexed { i, a ->
            val f = "edits.assets.$i"
            id("$f.id", a.id)
            if (assets.containsKey(a.id)) bad("$f.id", "is used twice")
            if (a.kind == AssetKind.LUT && a.upload == null) bad(f, "a lut asset must be an upload")
            val refs = listOfNotNull(a.take, a.upload, a.library)
            if (refs.size != 1 || refs.any { it.isEmpty() || it.length > 100 }) bad(f, "needs exactly one of take, upload or library")
            num("$f.durationSec", a.durationSec, 0.01, 36_000.0)
            num("$f.width", a.width?.toDouble(), 1.0, 16384.0); num("$f.height", a.height?.toDouble(), 1.0, 16384.0)
            assets[a.id] = a
        }
        if (p.tracks.isEmpty() || p.tracks.size > EditLimits.MAX_TRACKS) bad("edits.tracks", "must have 1–${EditLimits.MAX_TRACKS} tracks")
        if (p.tracks[0].kind != TrackKind.MAIN) bad("edits.tracks.0.kind", "the first track must be the main track")
        if (p.tracks.count { it.kind == TrackKind.MAIN } != 1) bad("edits.tracks", "needs exactly one main track")
        if (p.tracks.count { it.kind == TrackKind.CAPTION } > 1) bad("edits.tracks", "at most one caption track")
        var total = 0
        p.tracks.forEachIndexed { ti, t -> total = track("edits.tracks.$ti", t, total) }
        val d = durationSec(p)
        if (d < EditLimits.MIN_OUTPUT_SEC - 1e-9) bad("edits", "the edited video must be at least ${fmt(EditLimits.MIN_OUTPUT_SEC)} s")
        if (d > EditLimits.MAX_OUTPUT_SEC + 1e-9) bad("edits", "the edited video must be at most ${fmt(EditLimits.MAX_OUTPUT_SEC)} s")
        return d
    }

    private fun track(f: String, t: Track, before: Int): Int {
        id("$f.id", t.id)
        if (t.id in ids) bad("$f.id", "is used twice")
        ids += t.id
        num("$f.volume", t.volume, 0.0, 2.0)
        if (t.items.size > EditLimits.MAX_ITEMS_PER_TRACK) bad("$f.items", "at most ${EditLimits.MAX_ITEMS_PER_TRACK} items")
        val total = before + t.items.size
        if (total > EditLimits.MAX_ITEMS) bad("$f.items", "at most ${EditLimits.MAX_ITEMS} items in all")
        if (t.kind == TrackKind.MAIN && t.items.isEmpty()) bad("$f.items", "the main track needs at least one clip")
        if (t.kind == TrackKind.CAPTION) {
            if (t.items.isNotEmpty()) bad("$f.items", "a caption track has no items")
            val c = t.caption ?: bad("$f.caption", "is required")
            val a = assets[c.asset]
            if (a == null || (a.kind != AssetKind.VIDEO && a.kind != AssetKind.AUDIO)) bad("$f.caption.asset", "must be a video or audio asset")
            if (c.words.size > EditLimits.MAX_WORDS) bad("$f.caption.words", "at most ${EditLimits.MAX_WORDS} words")
            c.words.forEachIndexed { j, w ->
                if (w.text.isEmpty() || w.text.length > 60) bad("$f.caption.words.$j.text", "must be 1–60 characters")
                num("$f.caption.words.$j.startSec", w.startSec, 0.0, 36_000.0, false)
                num("$f.caption.words.$j.endSec", w.endSec, w.startSec, 36_000.0, false)
            }
            textStyle("$f.caption.style", c.style.text)
            color("$f.caption.style.highlightColor", c.style.highlightColor, false)
            num("$f.caption.style.y", c.style.y, 0.0, 1.0); num("$f.caption.style.wordsPerPage", c.style.wordsPerPage?.toDouble(), 1.0, 8.0)
            num("$f.caption.style.maxLines", c.style.maxLines?.toDouble(), 1.0, 2.0)
        } else if (t.caption != null) bad("$f.caption", "only on a caption track")
        t.duck?.let { d ->
            if (t.kind != TrackKind.MUSIC) bad("$f.duck", "only on a music track")
            num("$f.duck.level", d.level, 0.05, 1.0); num("$f.duck.fadeSec", d.fadeSec, 0.05, 2.0)
            num("$f.duck.attackSec", d.attackSec, 0.05, 2.0); num("$f.duck.releaseSec", d.releaseSec, 0.05, 3.0)
            if (d.under.isEmpty()) bad("$f.duck.under", "must list voice and/or speech")
        }
        var prevEnd = Double.NEGATIVE_INFINITY
        t.items.forEachIndexed { ii, it ->
            val g = "$f.items.$ii"
            id("$g.id", it.id)
            if (it.id in ids) bad("$g.id", "is used twice")
            ids += it.id
            when (t.kind) {
                TrackKind.MAIN, TrackKind.VIDEO -> videoClip(g, t, ii, it as? VideoClip ?: bad(g, "must be a video clip"))
                TrackKind.IMAGE -> imageItem(g, it as? ImageItem ?: bad(g, "must be an image item"))
                TrackKind.TEXT -> textItem(g, it as? TextItem ?: bad(g, "must be a text item"))
                TrackKind.MUSIC, TrackKind.VOICE, TrackKind.SFX -> audioClip(g, it as? AudioClip ?: bad(g, "must be an audio clip"))
                TrackKind.CAPTION -> {}
            }
            if (t.kind != TrackKind.MAIN) {
                val s = when (it) { is VideoClip -> it.startSec ?: Double.NaN; is AudioClip -> it.startSec; is ImageItem -> it.startSec; is TextItem -> it.startSec }
                if (s < prevEnd - EditLimits.OVERLAP_SLACK_SEC) bad("$g.startSec", "items on a track must be in order and not overlap")
                prevEnd = itemSpan(p, t, it).endSec
            }
        }
        return total
    }

    private fun keyframes(f: String, k: Keyframes?, len: Double, allowed: Set<KfProp>) {
        k ?: return
        for ((prop, list) in k) {
            if (prop !in allowed) bad("$f.${prop.wire}", "is not a keyframe property here")
            if (list.size > EditLimits.MAX_KEYFRAMES) bad("$f.${prop.wire}", "at most ${EditLimits.MAX_KEYFRAMES} keyframes")
            var prev = Double.NEGATIVE_INFINITY
            list.forEachIndexed { j, kf ->
                val g = "$f.${prop.wire}.$j"
                num("$g.t", kf.t, 0.0, len + EditLimits.END_SLACK_SEC, false)
                if (kf.t < prev) bad("$g.t", "keyframes must be in time order")
                prev = kf.t
                val (lo, hi) = when (prop) {
                    KfProp.X, KfProp.Y -> -2.0 to 3.0
                    KfProp.SCALE -> 0.05 to 10.0
                    KfProp.ROTATION -> -3600.0 to 3600.0
                    KfProp.OPACITY -> 0.0 to 1.0
                    KfProp.VOLUME -> 0.0 to 2.0
                }
                num("$g.v", kf.v, lo, hi, false)
            }
        }
    }

    private fun transform(f: String, t: Transform?) {
        t ?: return
        num("$f.transform.x", t.x, -2.0, 3.0); num("$f.transform.y", t.y, -2.0, 3.0)
        num("$f.transform.scale", t.scale, 0.05, 10.0); num("$f.transform.rotation", t.rotation, -3600.0, 3600.0)
    }

    private fun visual(f: String, it: Visual) {
        transform(f, it.transform)
        it.crop?.let { c -> num("$f.crop.left", c.left, 0.0, 0.45); num("$f.crop.top", c.top, 0.0, 0.45); num("$f.crop.right", c.right, 0.0, 0.45); num("$f.crop.bottom", c.bottom, 0.0, 0.45) }
        num("$f.opacity", it.opacity, 0.0, 1.0)
        it.adjust?.let { a ->
            num("$f.adjust.exposure", a.exposure, -1.0, 1.0); num("$f.adjust.contrast", a.contrast, -1.0, 1.0)
            num("$f.adjust.saturation", a.saturation, -1.0, 1.0); num("$f.adjust.temperature", a.temperature, -1.0, 1.0); num("$f.adjust.tint", a.tint, -1.0, 1.0)
            num("$f.adjust.highlights", a.highlights, -1.0, 1.0); num("$f.adjust.shadows", a.shadows, -1.0, 1.0)
        }
        it.mask?.let { m ->
            num("$f.mask.x", m.x, -1.0, 2.0); num("$f.mask.y", m.y, -1.0, 2.0); num("$f.mask.width", m.width, 0.01, 3.0); num("$f.mask.height", m.height, 0.01, 3.0)
            num("$f.mask.rotation", m.rotation, -360.0, 360.0); num("$f.mask.feather", m.feather, 0.0, 1.0)
        }
        it.filter?.let { fl ->
            if (filterIds.isNotEmpty() && fl.id !in filterIds) bad("$f.filter.id", "unknown filter")
            num("$f.filter.amount", fl.amount, 0.0, 1.0, false)
        }
        it.look?.let { look("$f.look", it) }
    }

    /** The reference's lookProblem (look.ts), same order and field paths; shapes were checked when parsing. */
    private fun look(f: String, l: Look) {
        l.lut?.let { lut ->
            if (lut.startsWith(Look.PACK_PREFIX)) { if (lookIds.isNotEmpty() && lut.substring(Look.PACK_PREFIX.length) !in lookIds) bad("$f.lut", "unknown look") }
            else if (lut.startsWith(Look.PALETTE_PREFIX)) { if (lut.substring(Look.PALETTE_PREFIX.length) !in paletteIds) bad("$f.lut", "unknown look") }
            else if (assets[lut]?.kind != AssetKind.LUT) bad("$f.lut", "must be \"pack:<id>\", \"palette:<id>\" or a lut asset id")
        }
        num("$f.strength", l.strength, 0.0, 1.0); num("$f.lift", l.lift, 0.0, 1.0); num("$f.sharpen", l.sharpen, 0.0, 1.0); num("$f.chromatic", l.chromatic, 0.0, 1.0)
        l.curves?.forEach { (ch, pts) ->
            val g = "$f.curves.${ch.wire}"
            if (pts.size < 2 || pts.size > LookLimits.MAX_CURVE_POINTS) bad(g, "2–${LookLimits.MAX_CURVE_POINTS} points")
            var prev = -1.0
            pts.forEachIndexed { i, pt ->
                if (pt.x < 0 || pt.x > 1 || pt.y < 0 || pt.y > 1) bad("$g.$i", "must be [x, y], each 0–1")
                if (pt.x <= prev) bad("$g.$i", "x must increase")
                prev = pt.x
            }
        }
        l.grain?.let { num("$f.grain.amount", it.amount, 0.0, 1.0, false); num("$f.grain.size", it.size, 0.5, 3.0) }
        l.vignette?.let { num("$f.vignette.amount", it.amount, -1.0, 1.0, false); num("$f.vignette.size", it.size, 0.0, 1.0); num("$f.vignette.softness", it.softness, 0.0, 1.0) }
        l.halation?.let { num("$f.halation.amount", it.amount, 0.0, 1.0, false); num("$f.halation.radius", it.radius, 0.05, 1.0); num("$f.halation.threshold", it.threshold, 0.0, 0.99) }
        l.leak?.let { num("$f.leak.amount", it.amount, 0.0, 1.0, false); num("$f.leak.angle", it.angle, -360.0, 360.0) }
    }

    private fun anim(f: String, a: Anim?, text: Boolean) {
        a ?: return
        if (a.kind == AnimKind.TYPEWRITER && !text) bad("$f.kind", "unknown animation")
        num("$f.durationSec", a.durationSec, 0.1, 2.0, false)
    }

    private fun clipBase(f: String, c: MediaClip, kinds: Set<AssetKind>) {
        val a = assets[c.asset] ?: bad("$f.asset", "is not in assets")
        if (a.kind !in kinds) bad("$f.asset", "must be ${kinds.joinToString(" or ") { it.wire }}")
        num("$f.inSec", c.inSec, 0.0, 36_000.0, false); num("$f.outSec", c.outSec, 0.0, 36_000.0, false)
        if (c.outSec - c.inSec < EditLimits.MIN_CLIP_SOURCE_SEC - 1e-9) bad("$f.outSec", "a clip must keep at least ${fmt(EditLimits.MIN_CLIP_SOURCE_SEC)} s of its source")
        if (a.durationSec != null && c.outSec > a.durationSec + EditLimits.END_SLACK_SEC) bad("$f.outSec", "is past the end of its source")
        num("$f.volume", c.volume, 0.0, 2.0); num("$f.fadeInSec", c.fadeInSec, 0.0, 10.0); num("$f.fadeOutSec", c.fadeOutSec, 0.0, 10.0)
    }

    private fun videoClip(g: String, t: Track, ii: Int, c: VideoClip) {
        clipBase(g, c, setOf(AssetKind.VIDEO))
        num("$g.speed", c.speed, EditLimits.MIN_SPEED, EditLimits.MAX_SPEED, false)
        c.holdSec?.let { h ->
            num("$g.holdSec", h, HOLD_MIN_SEC, HOLD_MAX_SEC, false)
            if (c.speed != 1.0 || c.speedCurve != null) bad("$g.holdSec", "a freeze frame plays at 1× without a speed curve")
        }
        if (c.blend != null && t.kind != TrackKind.VIDEO) bad("$g.blend", "only on overlay tracks (video, image)")
        c.speedCurve?.let { sc ->
            if (sc.points.size < 2 || sc.points.size > 16) bad("$g.speedCurve.points", "2–16 points")
            sc.points.forEachIndexed { j, pt ->
                if (pt.x < 0 || pt.x > 1 || pt.speed < EditLimits.MIN_SPEED || pt.speed > EditLimits.MAX_SPEED)
                    bad("$g.speedCurve.points.$j", "must be [x 0–1, speed ${fmt(EditLimits.MIN_SPEED)}–${fmt(EditLimits.MAX_SPEED)}]")
                if (j > 0 && pt.x <= sc.points[j - 1].x) bad("$g.speedCurve.points.$j", "x must increase")
            }
            if (sc.points.first().x != 0.0 || sc.points.last().x != 1.0) bad("$g.speedCurve.points", "must start at x 0 and end at x 1")
        }
        visual(g, c)
        keyframes("$g.keyframes", c.keyframes, clipLength(c), KfProp.entries.toSet())
        c.audioAsset?.let { aa -> val a = assets[aa]; if (a == null || (a.kind != AssetKind.VIDEO && a.kind != AssetKind.AUDIO)) bad("$g.audioAsset", "must be an audio or video asset") }
        // Background removal's matte (workstream 1): the asset must be a video of the project (the server's message).
        c.alphaMatte?.let { m -> if (assets[m.asset]?.kind != AssetKind.VIDEO) bad("$g.alphaMatte.asset", "must be a video asset") }
        c.chroma?.let { ch ->
            color("$g.chroma.color", ch.color, false)
            num("$g.chroma.similarity", ch.similarity, 0.0, 1.0); num("$g.chroma.smoothness", ch.smoothness, 0.0, 1.0); num("$g.chroma.spill", ch.spill, 0.0, 1.0)
        }
        if (t.kind == TrackKind.MAIN) {
            if (c.startSec != null) bad("$g.startSec", "main clips play back to back (no startSec)")
            c.transitionIn?.let { tr ->
                if (ii == 0) bad("$g.transitionIn", "the first clip has no transition")
                num("$g.transitionIn.durationSec", tr.durationSec, EditLimits.MIN_TRANSITION_SEC, EditLimits.MAX_TRANSITION_SEC, false)
                val prev = t.items[ii - 1] as VideoClip
                if (tr.durationSec > clipLength(c) / 2 + 1e-9 || tr.durationSec > clipLength(prev) / 2 + 1e-9) bad("$g.transitionIn.durationSec", "at most half of each clip")
            }
        } else {
            if (c.transitionIn != null) bad("$g.transitionIn", "transitions are on the main track only")
            num("$g.startSec", c.startSec, 0.0, 600.0, false)
        }
    }

    private fun imageItem(g: String, im: ImageItem) {
        val a = assets[im.asset] ?: bad("$g.asset", "is not in assets")
        if (a.kind != AssetKind.IMAGE) bad("$g.asset", "must be image")
        num("$g.startSec", im.startSec, 0.0, 600.0, false); num("$g.durationSec", im.durationSec, EditLimits.MIN_ITEM_SEC, 600.0, false)
        visual(g, im)
        keyframes("$g.keyframes", im.keyframes, im.durationSec, VISUAL_PROPS)
        anim("$g.animIn", im.animIn, false); anim("$g.animOut", im.animOut, false)
    }

    private fun textItem(g: String, tx: TextItem) {
        if (tx.text.isEmpty() || tx.text.length > EditLimits.MAX_TEXT) bad("$g.text", "must be 1–${EditLimits.MAX_TEXT} characters")
        num("$g.startSec", tx.startSec, 0.0, 600.0, false); num("$g.durationSec", tx.durationSec, EditLimits.MIN_ITEM_SEC, 600.0, false)
        textStyle("$g.style", tx.style)
        transform(g, tx.transform)
        num("$g.opacity", tx.opacity, 0.0, 1.0)
        keyframes("$g.keyframes", tx.keyframes, tx.durationSec, VISUAL_PROPS)
        anim("$g.animIn", tx.animIn, true); anim("$g.animOut", tx.animOut, true)
    }

    private fun audioClip(g: String, c: AudioClip) {
        clipBase(g, c, setOf(AssetKind.AUDIO, AssetKind.VIDEO))
        num("$g.startSec", c.startSec, 0.0, 600.0, false)
        if (c.speed != null && c.speed != 1.0) bad("$g.speed", "audio clips play at 1×")
        keyframes("$g.keyframes", c.keyframes, clipLength(c), setOf(KfProp.VOLUME))
        c.beats?.let { b -> if (b.size > 2000 || b.any { !it.isFinite() || it < 0 }) bad("$g.beats", "must be up to 2000 times") }
        c.strongBeats?.let { b -> if (b.size > 2000 || b.any { !it.isFinite() || it < 0 }) bad("$g.strongBeats", "must be up to 2000 times") }

    }

    private fun textStyle(f: String, s: TextStyle) {
        if (s.weight !in setOf(400, 700, 900)) bad("$f.weight", "must be 400, 700 or 900")
        num("$f.sizePct", s.sizePct, 0.015, 0.25, false)
        color("$f.color", s.color, false)
        num("$f.maxWidthPct", s.maxWidthPct, 0.1, 1.0); num("$f.lineHeight", s.lineHeight, 0.8, 2.0); num("$f.letterSpacing", s.letterSpacing, -0.1, 0.5)
        s.stroke?.let { color("$f.stroke.color", it.color, false); num("$f.stroke.widthPct", it.widthPct, 0.0, 0.3, false) }
        s.shadow?.let {
            color("$f.shadow.color", it.color, false); num("$f.shadow.opacity", it.opacity, 0.0, 1.0, false)
            num("$f.shadow.blurPct", it.blurPct, 0.0, 1.0, false); num("$f.shadow.dyPct", it.dyPct, -1.0, 1.0, false)
        }
        s.background?.let {
            color("$f.background.color", it.color, false); num("$f.background.opacity", it.opacity, 0.0, 1.0, false)
            num("$f.background.paddingPct", it.paddingPct, 0.0, 1.0, false); num("$f.background.radiusPct", it.radiusPct, 0.0, 1.0, false)
        }
    }

    companion object {
        val VISUAL_PROPS = setOf(KfProp.X, KfProp.Y, KfProp.SCALE, KfProp.ROTATION, KfProp.OPACITY)
    }
}

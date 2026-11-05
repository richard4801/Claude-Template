package studio.muse.core.edit

import kotlin.math.abs

/*
 * A small immutable editing API for the editor screens (which wait for the Figma review): every operation returns a
 * new project, or null when it isn't allowed (so a tap that can't apply does nothing), and [ProjectHistory] keeps
 * undo/redo as a list of values like the v1 EditHistory.
 */

/** Every id in use (tracks and items). */
val EditProject.ids: Set<String> get() = tracks.flatMapTo(HashSet()) { t -> t.items.map { it.id } + t.id }

/** A fresh id: [prefix]1, [prefix]2… (or `<prefix>.2`, `<prefix>.3`… when [dotted], for split pieces). */
fun EditProject.newId(prefix: String, dotted: Boolean = false): String {
    val used = ids
    if (dotted) { var k = 2; while ("$prefix.$k" in used) k++; return "$prefix.$k" }
    var k = 1; while ("$prefix$k" in used) k++; return "$prefix$k"
}

/** The track holding item [itemId] and the item's index there. */
fun EditProject.locate(itemId: String): Pair<Track, Int>? {
    for (t in tracks) { val i = t.items.indexOfFirst { it.id == itemId }; if (i >= 0) return t to i }
    return null
}

private fun EditProject.replaceTrack(old: Track, new: Track) = copy(tracks = tracks.map { if (it === old) new else it })

/** Timeline start of a non-main item. */
val Item.startSecOrNull: Double?
    get() = when (this) { is VideoClip -> startSec; is AudioClip -> startSec; is ImageItem -> startSec; is TextItem -> startSec }

private fun Item.withStart(s: Double): Item = when (this) {
    is VideoClip -> copy(startSec = s); is AudioClip -> copy(startSec = s); is ImageItem -> copy(startSec = s); is TextItem -> copy(startSec = s)
}

/** True when the non-main [items] are in order and don't overlap (the validation rule). */
private fun EditProject.fits(track: Track, items: List<Item>): Boolean {
    var prevEnd = Double.NEGATIVE_INFINITY
    val t = track.copy(items = items)
    for (it in items) {
        val s = it.startSecOrNull ?: return false
        if (s < 0 || s < prevEnd - EditLimits.OVERLAP_SLACK_SEC) return false
        prevEnd = itemSpan(this, t, it).endSec
    }
    return true
}

/** Adds a track of [kind] (above the others; the main track stays first). A caption track only when there is none. */
fun EditProject.addTrack(kind: TrackKind, id: String = newId(kind.wire), caption: CaptionTrack? = null, duck: Duck? = null): EditProject? {
    if (kind == TrackKind.MAIN || tracks.size >= EditLimits.MAX_TRACKS || id in ids) return null
    if (kind == TrackKind.CAPTION && (caption == null || tracks.any { it.kind == TrackKind.CAPTION })) return null
    return copy(tracks = tracks + Track(id, kind, caption = if (kind == TrackKind.CAPTION) caption else null, duck = if (kind == TrackKind.MUSIC) duck else null))
}

fun EditProject.removeTrack(trackId: String): EditProject? {
    val t = track(trackId) ?: return null
    if (t.kind == TrackKind.MAIN) return null
    return copy(tracks = tracks.filter { it !== t })
}

/** Changes a track's flags or settings ([f] gets the track, returns the new one; id, kind and items are kept). */
fun EditProject.updateTrack(trackId: String, f: (Track) -> Track): EditProject? {
    val t = track(trackId) ?: return null
    val n = f(t).copy(id = t.id, kind = t.kind, items = t.items)
    return if (n == t) null else replaceTrack(t, n)
}

/**
 * Adds [item] to [trackId]: a main clip at [mainIndex] (default: the end); any other item at its startSec, refused when
 * it would overlap a neighbour (use another track to stack).
 */
fun EditProject.addItem(trackId: String, item: Item, mainIndex: Int? = null): EditProject? {
    val t = track(trackId) ?: return null
    if (item.id in ids || t.kind == TrackKind.CAPTION) return null
    val okType = when (t.kind) {
        TrackKind.MAIN -> item is VideoClip && item.startSec == null
        TrackKind.VIDEO -> item is VideoClip && item.startSec != null && item.transitionIn == null
        TrackKind.IMAGE -> item is ImageItem
        TrackKind.TEXT -> item is TextItem
        TrackKind.MUSIC, TrackKind.VOICE, TrackKind.SFX -> item is AudioClip
        TrackKind.CAPTION -> false
    }
    if (!okType || t.items.size >= EditLimits.MAX_ITEMS_PER_TRACK) return null
    if (t.kind == TrackKind.MAIN) {
        val at = (mainIndex ?: t.items.size).coerceIn(0, t.items.size)
        val clip = if (at == 0) (item as VideoClip).copy(transitionIn = null) else item
        val items = t.items.toMutableList().apply { add(at, clip) }
        return replaceTrack(t, t.copy(items = dropBadTransitions(items)))
    }
    val items = (t.items + item).sortedBy { it.startSecOrNull ?: 0.0 }
    return if (fits(t, items)) replaceTrack(t, t.copy(items = items)) else null
}

/** Removes an item. The main track keeps at least one clip; a transition that would land on the first clip is dropped. */
fun EditProject.removeItem(itemId: String): EditProject? {
    val (t, i) = locate(itemId) ?: return null
    if (t.kind == TrackKind.MAIN && t.items.size <= 1) return null
    val items = t.items.filterIndexed { k, _ -> k != i }
    return replaceTrack(t, t.copy(items = if (t.kind == TrackKind.MAIN) dropBadTransitions(items) else items))
}

/** Replaces an item with [f] of it (same id). Non-main items must still fit their track. */
fun EditProject.updateItem(itemId: String, f: (Item) -> Item): EditProject? {
    val (t, i) = locate(itemId) ?: return null
    val n = f(t.items[i])
    if (n.id != itemId || n::class != t.items[i]::class || n == t.items[i]) return null
    val items = t.items.toMutableList().apply { set(i, n) }
    if (t.kind == TrackKind.MAIN) return replaceTrack(t, t.copy(items = dropBadTransitions(items)))
    val sorted = items.sortedBy { it.startSecOrNull ?: 0.0 }
    return if (fits(t, sorted)) replaceTrack(t, t.copy(items = sorted)) else null
}

/** Moves a non-main item to timeline [startSec] (refused when it would overlap a neighbour). */
fun EditProject.moveItem(itemId: String, startSec: Double): EditProject? {
    val (t, _) = locate(itemId) ?: return null
    if (t.kind == TrackKind.MAIN) return null
    return updateItem(itemId) { it.withStart(maxOf(0.0, startSec)) }
}

/** Moves an item to another track of a compatible kind, keeping its time. */
fun EditProject.moveItemToTrack(itemId: String, toTrackId: String): EditProject? {
    val (from, i) = locate(itemId) ?: return null
    val to = track(toTrackId) ?: return null
    if (from === to || from.kind == TrackKind.MAIN || to.kind == TrackKind.MAIN) return null
    val item = from.items[i]
    return removeItem(itemId)?.addItem(toTrackId, item)
}

/** Reorders main clip [from] to index [to]; transitions that no longer fit are dropped. */
fun EditProject.moveMainClip(from: Int, to: Int): EditProject? {
    val t = main
    if (from !in t.items.indices || to !in t.items.indices || from == to) return null
    val items = t.items.toMutableList().apply { add(to, removeAt(from)) }
    return replaceTrack(t, t.copy(items = dropBadTransitions(items)))
}

/** Main-track transitions that broke (on the first clip, or longer than half a neighbour) are removed. */
private fun dropBadTransitions(items: List<Item>): List<Item> = items.mapIndexed { i, it ->
    val c = it as VideoClip
    val tr = c.transitionIn ?: return@mapIndexed c
    val prev = items.getOrNull(i - 1) as VideoClip?
    val ok = prev != null && tr.durationSec <= clipLength(c) / 2 + 1e-9 && tr.durationSec <= clipLength(prev) / 2 + 1e-9
    if (ok) c else c.copy(transitionIn = null)
}

/**
 * Splits the main clip playing at timeline [t] into two clips at that point (the second gets `<id>.2`…). Refused inside
 * a transition overlap or when a piece would keep less than 0.1 s of source. Looks carry over to both; the transition
 * stays on the first piece, fade-in on the first and fade-out on the second; keyframes are split at the cut.
 */
fun EditProject.splitAt(t: Double): EditProject? {
    val spans = timeline(this)
    val i = spans.indexOfFirst { t > it.startSec && t < it.endSec }.takeIf { it >= 0 } ?: return null
    val s = spans[i]
    if (t < s.startSec + s.transitionSec) return null
    spans.getOrNull(i + 1)?.let { if (t >= it.startSec) return null }
    val c = mainClips[i]
    val local = t - s.startSec
    val src = clipSourceAt(c, local)
    if (src - c.inSec < EditLimits.MIN_CLIP_SOURCE_SEC - 1e-9 || c.outSec - src < EditLimits.MIN_CLIP_SOURCE_SEC - 1e-9) return null
    if (main.items.size >= EditLimits.MAX_ITEMS_PER_TRACK) return null
    // A speed curve stays on each piece (cut down to its part of the source; preset becomes custom).
    val xs = (src - c.inSec) / (c.outSec - c.inSec)
    val first = c.copy(outSec = r6(src), fadeOutSec = null, keyframes = splitKeys(c.keyframes, local, first = true), speedCurve = c.speedCurve?.let { subCurve(it, 0.0, xs) })
    val second = c.copy(id = newId(c.id, dotted = true), inSec = r6(src), fadeInSec = null, transitionIn = null, keyframes = splitKeys(c.keyframes, local, first = false),
        speedCurve = c.speedCurve?.let { subCurve(it, xs, 1.0) })
    val items = main.items.toMutableList().apply { set(i, first); add(i + 1, second) }
    return replaceTrack(main, main.copy(items = dropBadTransitions(items)))
}

/** Keyframes of one side of a split at item-local [at]: the keys on that side plus the value at the cut. */
private fun splitKeys(k: Keyframes?, at: Double, first: Boolean): Keyframes? = k?.mapValues { (_, keys) ->
    val v = keyframeValue(keys, at)
    if (first) keys.filter { it.t < at - 1e-9 } + Keyframe(r6(at), r6(v))
    else listOf(Keyframe(0.0, r6(v), keys.lastOrNull { it.t <= at }?.ease)) + keys.filter { it.t > at + 1e-9 }.map { it.copy(t = r6(it.t - at)) }
}

/** Sets (or with null removes) the transition into main clip [clipId]. Refused on the first clip or when too long. */
fun EditProject.setTransition(clipId: String, transition: Transition?): EditProject? {
    val t = main
    val i = t.items.indexOfFirst { it.id == clipId }
    if (i <= 0) return null
    val c = t.items[i] as VideoClip
    if (transition != null) {
        val prev = t.items[i - 1] as VideoClip
        val d = transition.durationSec
        if (d < EditLimits.MIN_TRANSITION_SEC - 1e-9 || d > EditLimits.MAX_TRANSITION_SEC + 1e-9) return null
        if (d > clipLength(c) / 2 + 1e-9 || d > clipLength(prev) / 2 + 1e-9) return null
    }
    if (c.transitionIn == transition) return null
    return replaceTrack(t, t.copy(items = t.items.toMutableList().apply { set(i, c.copy(transitionIn = transition)) }))
}

/** Trims main clip [clipId] to source [inSec]–[outSec] (clamped to its asset; ≥ 0.1 s kept). */
fun EditProject.trimClip(clipId: String, inSec: Double, outSec: Double): EditProject? {
    val (t, i) = locate(clipId) ?: return null
    val c = t.items[i] as? MediaClip ?: return null
    val end = asset(c.asset)?.durationSec ?: Double.MAX_VALUE
    val a = inSec.coerceIn(0.0, end); val b = outSec.coerceIn(0.0, end)
    if (b - a < EditLimits.MIN_CLIP_SOURCE_SEC - 1e-9 || (abs(a - c.inSec) < 1e-9 && abs(b - c.outSec) < 1e-9)) return null
    return updateItem(clipId) { when (it) { is VideoClip -> it.copy(inSec = a, outSec = b); is AudioClip -> it.copy(inSec = a, outSec = b); else -> it } }
}

/** Undo / redo over project values (every change; null changes are ignored). */
class ProjectHistory(initial: EditProject, private val limit: Int = 100) {
    private val past = ArrayDeque<EditProject>()
    private val future = ArrayDeque<EditProject>()
    var current: EditProject = initial
        private set
    val canUndo get() = past.isNotEmpty()
    val canRedo get() = future.isNotEmpty()

    /** Applies [next] when it's a change. Returns whether it applied. */
    fun apply(next: EditProject?): Boolean {
        if (next == null || next == current) return false
        past.addLast(current)
        while (past.size > limit) past.removeFirst()
        future.clear()
        current = next
        return true
    }

    /**
     * Replaces the current project without a new undo step (a slider being dragged: the drag is one step). The value
     * before the drag stays the undo target; redo is cleared. False when [next] is null or no change.
     */
    fun amend(next: EditProject?): Boolean {
        if (next == null || next == current) return false
        future.clear()
        current = next
        return true
    }

    /** Applies an operation on the current project (e.g. `edit { it.splitAt(3.2) }`). */
    fun edit(op: (EditProject) -> EditProject?): Boolean = apply(op(current))

    fun undo(): Boolean { val p = past.removeLastOrNull() ?: return false; future.addLast(current); current = p; return true }
    fun redo(): Boolean { val n = future.removeLastOrNull() ?: return false; past.addLast(current); current = n; return true }
}

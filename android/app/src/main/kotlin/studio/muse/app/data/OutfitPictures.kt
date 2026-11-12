package studio.muse.app.data

import studio.muse.core.PhotoPrices
import studio.muse.core.PhotoPricing

/**
 * An outfit's 7 pictures (plans/outfit-faces.md): the 4 body angles (front, ¾, side, back), then its 3 face close-ups
 * (face front, face ¾, face side) with the outfit's hair, make-up and accessories. Older outfits have no faces.
 */
object OutfitPictures {
    /** The /redo `angle` of each picture, in order. */
    val KEYS = listOf("front", "tq", "side", "back", "face", "faceTq", "profile")
    val LABELS = listOf("Front", "¾", "Side", "Back", "Face front", "Face ¾", "Face side")
    const val BODY = 4
    const val FACES = 3

    /** All 7 in order (null = missing or not made yet). */
    fun all(o: Outfit): List<ImageRef?> = (0 until BODY).map { o.angles.getOrNull(it) } + (0 until FACES).map { o.faces?.getOrNull(it) }

    /** The pictures the full-size viewer pages through: index into [KEYS] and the image, missing ones skipped. */
    fun shown(pictures: List<ImageRef?>): List<Pair<Int, ImageRef>> = pictures.take(KEYS.size).mapIndexedNotNull { i, r -> r?.let { i to it } }

    /** Where picture [index] sits in [shown] (0 when it isn't shown). */
    fun pageOf(pictures: List<ImageRef?>, index: Int): Int = shown(pictures).indexOfFirst { it.first == index }.coerceAtLeast(0)

    /**
     * "Move to…" for picture [from] (owner, 2026-11-12: "the picture in Side is actually the back"): the other 6 slots in
     * order, each "Swap with Back" when that slot has a picture, "Move to Back" when it's empty.
     */
    fun moveTargets(pictures: List<ImageRef?>, from: Int): List<Pair<Int, String>> =
        KEYS.indices.filter { it != from }.map { i -> i to (if (pictures.getOrNull(i) != null) "Swap with ${LABELS[i]}" else "Move to ${LABELS[i]}") }

    /** The 7 pictures with [from] and [to] swapped (what POST /reorder does with one move; nothing is lost). */
    fun swapped(pictures: List<ImageRef?>, from: Int, to: Int): List<ImageRef?> {
        val all = (0 until KEYS.size).map { pictures.getOrNull(it) }.toMutableList()
        if (from !in all.indices || to !in all.indices || from == to) return all
        val a = all[from]
        all[from] = all[to]
        all[to] = a
        return all
    }

    /** One move from slot [from] to slot [to], as /reorder takes it (null for a slot that isn't one of the 7, or the same slot). */
    fun move(from: Int, to: Int): OutfitMove? {
        val f = KEYS.getOrNull(from) ?: return null
        val t = KEYS.getOrNull(to) ?: return null
        return if (from == to) null else OutfitMove(f, t)
    }

    /** [o] with [moves] applied in order (the demo's /reorder); an unknown slot is refused with [IllegalArgumentException]. */
    fun reordered(o: Outfit, moves: List<OutfitMove>): Outfit {
        var all = all(o)
        moves.forEach { m ->
            val f = KEYS.indexOf(m.from)
            val t = KEYS.indexOf(m.to)
            require(f >= 0 && t >= 0) { "Unknown picture" }
            all = swapped(all, f, t)
        }
        val faces = all.drop(BODY)
        // An older outfit with no faces stays without them unless a picture moved into a face slot.
        return o.copy(angles = all.take(BODY), faces = if (o.faces == null && faces.all { it == null }) null else faces)
    }

    /** How many face close-ups it has. */
    fun madeFaces(o: Outfit): Int = (0 until FACES).count { o.faces?.getOrNull(it) != null }

    /** An older outfit (made before every outfit had face close-ups): none at all. */
    fun noFaces(o: Outfit): Boolean = madeFaces(o) == 0

    /** "Add face close-ups": one edit per missing face. */
    fun facesEstimate(p: PhotoPrices, o: Outfit): Double = (FACES - madeFaces(o)) * p.perEdit

    /** Redo one picture: the front is a new shot, the others one edit each. */
    fun redoEstimate(p: PhotoPrices, index: Int): Double = if (index == 0) PhotoPricing.newShot(p, 1.0, p.maxRefs) else p.perEdit

    /** The New outfit sheet's price: describe / product photo = the set + 3 faces; keep-from-base = 7 edits; My own set = 3 faces. */
    fun createEstimate(p: PhotoPrices, mode: String, keeping: Boolean): Double = when {
        mode == "own" -> FACES * p.perEdit
        keeping -> (BODY + FACES) * p.perEdit
        else -> PhotoPricing.outfitSet(p) + FACES * p.perEdit
    }
}

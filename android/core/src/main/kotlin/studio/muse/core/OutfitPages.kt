package studio.muse.core

/**
 * The outfit section's folders (plans/outfit-head-looks.md §4): newest first, 8 per page, "‹ 1 of 3 ›". A delete
 * refills the page from the next one; when the last page empties, the page steps back one.
 */
object OutfitPages {
    const val PER_PAGE = 8

    /** Newest first by [createdAt] (ms); equal or missing dates keep the later-listed one first. */
    fun <T> newestFirst(items: List<T>, createdAt: (T) -> Long?): List<T> =
        items.withIndex().sortedWith(compareByDescending<IndexedValue<T>> { createdAt(it.value) ?: 0L }.thenByDescending { it.index }).map { it.value }

    /** At least one page, so the pager reads "1 of 1" (and is hidden) when there are none. */
    fun count(items: Int, perPage: Int = PER_PAGE): Int = maxOf(1, (items + perPage - 1) / perPage)

    fun clamp(page: Int, items: Int, perPage: Int = PER_PAGE): Int = page.coerceIn(0, count(items, perPage) - 1)

    fun <T> slice(items: List<T>, page: Int, perPage: Int = PER_PAGE): List<T> =
        items.drop(clamp(page, items.size, perPage) * perPage).take(perPage)

    fun label(page: Int, items: Int, perPage: Int = PER_PAGE): String = "${clamp(page, items, perPage) + 1} of ${count(items, perPage)}"
}

/** A new outfit's name before it is added (§5): what was typed, else the photo's file name, else "Outfit · 11 Nov". */
object OutfitNaming {
    const val MAX = 80
    private val camera = setOf("img", "dsc", "image", "photo", "screenshot", "pxl")

    fun suggestion(description: String, fileName: String?, dayMonth: String): String {
        val typed = description.trim()
        if (typed.isNotEmpty()) return typed.replaceFirstChar { it.uppercaseChar() }.take(MAX).trim()
        val f = fileName?.let(::cleanFileName).orEmpty()
        if (f.isNotEmpty()) return f.take(MAX).trim()
        return "Outfit · $dayMonth"
    }

    /** "green_halter-set.final.jpg" → "Green halter set final"; camera names like "IMG_2041" give nothing. */
    fun cleanFileName(name: String): String {
        val base = name.substringBeforeLast('.', name)
        val words = base.split(Regex("[_\\-. ]+")).filter { it.isNotEmpty() }
        if (words.all { w -> w.all(Char::isDigit) || w.lowercase() in camera }) return ""
        return words.joinToString(" ").replaceFirstChar { it.uppercaseChar() }
    }
}

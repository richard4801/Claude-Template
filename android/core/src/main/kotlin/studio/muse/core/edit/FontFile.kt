package studio.muse.core.edit

/**
 * Own fonts: whether bytes are a TrueType/OpenType font, and its display name (server/api/src/editor/font.ts
 * `fontName`): full name (name ID 4), else family + subfamily (1 + 2), at most 80 characters. WOFF/WOFF2 and
 * collections are not fonts here.
 */
object FontFile {
    const val MAX_BYTES = 10 * 1024 * 1024

    /** The font's name, or null when [b] is not a .ttf/.otf. */
    fun name(b: ByteArray): String? {
        if (b.size < 12) return null
        val tag = u32(b, 0)
        if (tag != 0x00010000L && tag != 0x74727565L && tag != 0x4f54544fL) return null
        val n = u16(b, 4)
        if (12 + n * 16 > b.size) return null
        var nameOff = -1; var nameLen = 0L
        for (i in 0 until n) {
            val r = 12 + i * 16
            if (String(b, r, 4, Charsets.ISO_8859_1) == "name") { nameOff = u32(b, r + 8).toInt(); nameLen = u32(b, r + 12) }
        }
        val names = HashMap<Int, String>()
        if (nameOff >= 0 && nameOff + 6 <= b.size && nameOff + nameLen <= b.size) {
            val count = u16(b, nameOff + 2); val strings = nameOff + u16(b, nameOff + 4)
            for (i in 0 until count) {
                val r = nameOff + 6 + i * 12
                if (r + 12 > b.size) break
                val platform = u16(b, r); val id = u16(b, r + 6); val len = u16(b, r + 8); val off = strings + u16(b, r + 10)
                if (id !in setOf(1, 2, 4) || off + len > b.size) continue
                // Windows/Unicode names are UTF-16BE; Mac Roman is read as Latin-1. Windows wins.
                val s = when (platform) {
                    3, 0 -> String(b, off, len - len % 2, Charsets.UTF_16BE)
                    1 -> String(b, off, len, Charsets.ISO_8859_1)
                    else -> ""
                }.trim()
                if (s.isNotEmpty() && (id !in names || platform == 3)) names[id] = s
            }
        }
        val full = names[4] ?: listOfNotNull(names[1], names[2]).joinToString(" ")
        return full.ifEmpty { "Font" }.filter { it.code >= 0x20 }.take(80)
    }

    private fun u16(b: ByteArray, i: Int) = ((b[i].toInt() and 0xFF) shl 8) or (b[i + 1].toInt() and 0xFF)
    private fun u32(b: ByteArray, i: Int) = (u16(b, i).toLong() shl 16) or u16(b, i + 2).toLong()
}

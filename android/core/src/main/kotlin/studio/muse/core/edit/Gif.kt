package studio.muse.core.edit

import java.io.OutputStream

/*
 * The Edit suite's GIF export (plans/edit-parity.md, S row "GIF export"): an animated GIF89a that loops, one local
 * palette per frame (median cut over the frame's colours, 256 at most), LZW-coded. Pure, so it runs in unit tests; the
 * app feeds it the frames of a small render of the edit.
 */

/** Writes an animated GIF to [out], frame by frame. [width] × [height] in px; frames are ARGB (alpha ignored). */
class GifWriter(private val out: OutputStream, private val width: Int, private val height: Int) {
    private var frames = 0
    private var done = false

    init {
        require(width in 1..65535 && height in 1..65535) { "size" }
        out.write("GIF89a".toByteArray(Charsets.US_ASCII))
        short(width); short(height)
        out.write(0x70) // no global palette; 8-bit colour resolution
        out.write(0); out.write(0)
        // Netscape loop extension: loop forever.
        out.write(byteArrayOf(0x21, 0xFF.toByte(), 0x0B)); out.write("NETSCAPE2.0".toByteArray(Charsets.US_ASCII))
        out.write(byteArrayOf(3, 1, 0, 0, 0))
    }

    /** One frame shown for [delayCs] hundredths of a second. */
    fun add(argb: IntArray, delayCs: Int) {
        check(!done) { "finished" }
        require(argb.size == width * height) { "frame size" }
        val q = GifQuantizer.of(argb)
        // Graphic control: no transparency, the delay.
        out.write(byteArrayOf(0x21, 0xF9.toByte(), 4, 0)); short(delayCs.coerceIn(2, 65535)); out.write(0); out.write(0)
        // Image descriptor with a local 256-entry palette.
        out.write(0x2C); short(0); short(0); short(width); short(height); out.write(0x87)
        for (i in 0 until 256) { val c = q.palette.getOrElse(i) { 0 }; out.write((c shr 16) and 0xFF); out.write((c shr 8) and 0xFF); out.write(c and 0xFF) }
        val idx = ByteArray(argb.size) { q.index(argb[it]).toByte() }
        GifLzw.write(out, idx, 8)
        frames++
    }

    /** Ends the file (the stream stays open). */
    fun finish() {
        if (done) return
        done = true
        out.write(0x3B)
        out.flush()
    }

    val frameCount: Int get() = frames

    private fun short(v: Int) { out.write(v and 0xFF); out.write((v shr 8) and 0xFF) }
}

/** A frame's palette (median cut on 5-bit-per-channel colours) and its colour → index lookup. */
class GifQuantizer private constructor(val palette: IntArray) {
    private val cache = IntArray(32 * 32 * 32) { -1 }

    fun index(argb: Int): Int {
        val k = key(argb)
        val hit = cache[k]
        if (hit >= 0) return hit
        val r = ((k shr 10) and 31) * 8 + 4; val g = ((k shr 5) and 31) * 8 + 4; val b = (k and 31) * 8 + 4
        var best = 0; var bestD = Int.MAX_VALUE
        for (i in palette.indices) {
            val c = palette[i]
            val dr = ((c shr 16) and 0xFF) - r; val dg = ((c shr 8) and 0xFF) - g; val db = (c and 0xFF) - b
            val d = 2 * dr * dr + 4 * dg * dg + 3 * db * db
            if (d < bestD) { bestD = d; best = i }
        }
        cache[k] = best
        return best
    }

    companion object {
        private fun key(c: Int) = (((c shr 19) and 31) shl 10) or (((c shr 11) and 31) shl 5) or ((c shr 3) and 31)

        /** Up to 256 colours for [argb]. */
        fun of(argb: IntArray): GifQuantizer {
            val hist = IntArray(32 * 32 * 32)
            for (c in argb) hist[key(c)]++
            val colours = hist.indices.filter { hist[it] > 0 }.toIntArray()
            val boxes = ArrayList<IntArray>().apply { add(colours) }
            fun ch(k: Int, axis: Int) = when (axis) { 0 -> (k shr 10) and 31; 1 -> (k shr 5) and 31; else -> k and 31 }
            while (boxes.size < 256) {
                // Split the box with the widest channel range (ties: the most pixels).
                var pick = -1; var pickRange = 0; var pickAxis = 0
                for ((i, box) in boxes.withIndex()) {
                    if (box.size < 2) continue
                    for (axis in 0..2) {
                        var lo = 31; var hi = 0
                        for (k in box) { val v = ch(k, axis); if (v < lo) lo = v; if (v > hi) hi = v }
                        if (hi - lo > pickRange) { pickRange = hi - lo; pick = i; pickAxis = axis }
                    }
                }
                if (pick < 0) break
                val box = boxes[pick].sortedBy { ch(it, pickAxis) }
                // Split at the pixel-weighted median.
                val total = box.sumOf { hist[it].toLong() }
                var acc = 0L; var cut = 1
                for (i in box.indices) { acc += hist[box[i]]; if (acc * 2 >= total) { cut = (i + 1).coerceIn(1, box.size - 1); break } }
                boxes[pick] = box.subList(0, cut).toIntArray(); boxes.add(box.subList(cut, box.size).toIntArray())
            }
            val pal = IntArray(boxes.size) { i ->
                var n = 0L; var r = 0L; var g = 0L; var b = 0L
                for (k in boxes[i]) { val w = hist[k].toLong(); n += w; r += w * (((k shr 10) and 31) * 8 + 4); g += w * (((k shr 5) and 31) * 8 + 4); b += w * ((k and 31) * 8 + 4) }
                if (n == 0L) 0 else ((r / n).toInt() shl 16) or ((g / n).toInt() shl 8) or (b / n).toInt()
            }
            return GifQuantizer(if (pal.isEmpty()) intArrayOf(0) else pal)
        }
    }
}

/** GIF's variable-width LZW (codes up to 12 bits, a clear code when the table fills), in ≤255-byte sub-blocks. */
object GifLzw {
    fun write(out: OutputStream, indices: ByteArray, minCodeSize: Int) {
        out.write(minCodeSize)
        val clear = 1 shl minCodeSize; val eoi = clear + 1
        val block = ByteArray(255); var blockLen = 0
        var bitBuf = 0L; var bitCount = 0
        var codeSize = minCodeSize + 1
        fun flushBlock() { if (blockLen > 0) { out.write(blockLen); out.write(block, 0, blockLen); blockLen = 0 } }
        fun emit(code: Int) {
            bitBuf = bitBuf or (code.toLong() shl bitCount); bitCount += codeSize
            while (bitCount >= 8) { block[blockLen++] = (bitBuf and 0xFF).toByte(); bitBuf = bitBuf ushr 8; bitCount -= 8; if (blockLen == 255) flushBlock() }
        }
        // (prefix code << 8 | byte) → code.
        val table = HashMap<Int, Int>(8192)
        var next = eoi + 1
        emit(clear)
        if (indices.isNotEmpty()) {
            var prefix = indices[0].toInt() and 0xFF
            for (i in 1 until indices.size) {
                val c = indices[i].toInt() and 0xFF
                val key = (prefix shl 8) or c
                val hit = table[key]
                if (hit != null) { prefix = hit; continue }
                emit(prefix)
                if (next < 4096) {
                    table[key] = next++
                    if (next > (1 shl codeSize) && codeSize < 12) codeSize++
                } else {
                    emit(clear); table.clear(); next = eoi + 1; codeSize = minCodeSize + 1
                }
                prefix = c
            }
            emit(prefix)
            // The decoder adds one more entry on reading that code and may widen before the end code.
            if (next >= (1 shl codeSize) && codeSize < 12) codeSize++
        }
        emit(eoi)
        if (bitCount > 0) { block[blockLen++] = (bitBuf and 0xFF).toByte(); if (blockLen == 255) flushBlock() }
        flushBlock()
        out.write(0)
    }
}

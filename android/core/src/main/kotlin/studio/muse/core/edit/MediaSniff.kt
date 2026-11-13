package studio.muse.core.edit

// What a file really is, from its first bytes, not its name or the picker's MIME type (owner issue ci_f99f93616ece,
// 2026-11-12: a song that was raw ADTS AAC, sound only, named .mp4, was taken for a video). The Mac twin is MuseCore
// MediaSniff.swift; keep them in step. An MP4 container needs its tracks to decide: the app reads them
// (MediaExtractor) and passes hasVideo / hasAudio.

object MediaSniff {
    /** Enough of the file's start for every check here. */
    const val HEADER_BYTES = 64

    /** The one line when a file can't be used. */
    const val UNREADABLE = "This file has no video or sound MUSE can read."

    sealed interface Format {
        data object Adts : Format
        data object Mp3 : Format
        data object Wav : Format
        data object Aiff : Format
        data object Flac : Format
        /** ISO base media (MP4, M4A, MOV, HEIC): the `ftyp` brand decides pictures; tracks decide video vs sound. */
        data class IsoMedia(val brand: String) : Format
        data object Png : Format
        data object Jpeg : Format
        data object Webp : Format
        data object Unknown : Format
    }

    enum class Kind { VIDEO, PICTURE, AUDIO }

    /** What MUSE does with a file: its kind and the content type it is uploaded as. */
    data class Verdict(val kind: Kind, val contentType: String, val ext: String)

    fun format(data: ByteArray): Format {
        val b = if (data.size > HEADER_BYTES) data.copyOf(HEADER_BYTES) else data
        fun ascii(at: Int, n: Int): String? = if (b.size >= at + n) String(b, at, n, Charsets.ISO_8859_1) else null
        fun u(i: Int) = b[i].toInt() and 0xFF
        if (ascii(4, 4) == "ftyp") return Format.IsoMedia(ascii(8, 4) ?: "")
        // An older QuickTime file starts with another top-level atom (no ftyp): a container whose tracks decide.
        if (ascii(4, 4) in quickTimeAtoms) return Format.IsoMedia("qt  ")
        if (b.size >= 4 && u(0) == 0x89 && u(1) == 0x50 && u(2) == 0x4E && u(3) == 0x47) return Format.Png
        if (b.size >= 3 && u(0) == 0xFF && u(1) == 0xD8 && u(2) == 0xFF) return Format.Jpeg
        if (ascii(0, 4) == "RIFF" && ascii(8, 4) == "WAVE") return Format.Wav
        if (ascii(0, 4) == "RIFF" && ascii(8, 4) == "WEBP") return Format.Webp
        if (ascii(0, 4) == "FORM" && (ascii(8, 4) == "AIFF" || ascii(8, 4) == "AIFC")) return Format.Aiff
        if (ascii(0, 4) == "fLaC") return Format.Flac
        if (ascii(0, 3) == "ID3") return Format.Mp3
        if (b.size >= 2 && u(0) == 0xFF) {
            // ADTS (AAC): 12-bit sync 0xFFF, layer 00. MPEG audio (MP3): 11-bit sync, layer not 00.
            if (u(1) and 0xF6 == 0xF0) return Format.Adts
            if (u(1) and 0xE0 == 0xE0 && (u(1) shr 1) and 0x3 != 0) return Format.Mp3
        }
        return Format.Unknown
    }

    private val quickTimeAtoms = setOf("moov", "mdat", "wide", "free", "skip", "pnot")
    private val heicBrands = setOf("heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1")
    private val audioBrands = setOf("M4A ", "M4B ", "M4P ")

    /**
     * The verdict, from the format and (for an MP4 container) its tracks. A name alone never makes a file usable (Mac
     * bundle-10 run 617: a text file named .mp4 was taken): bytes that say nothing need real tracks read by the app.
     */
    fun verdict(f: Format, fileExtension: String = "", hasVideo: Boolean? = null, hasAudio: Boolean? = null): Verdict? = when (f) {
        Format.Adts -> Verdict(Kind.AUDIO, "audio/aac", "aac")
        Format.Mp3 -> Verdict(Kind.AUDIO, "audio/mpeg", "mp3")
        Format.Wav -> Verdict(Kind.AUDIO, "audio/wav", "wav")
        Format.Aiff -> Verdict(Kind.AUDIO, "audio/aiff", "aiff")
        Format.Flac -> Verdict(Kind.AUDIO, "audio/flac", "flac")
        Format.Png -> Verdict(Kind.PICTURE, "image/png", "png")
        Format.Jpeg -> Verdict(Kind.PICTURE, "image/jpeg", "jpg")
        Format.Webp -> Verdict(Kind.PICTURE, "image/webp", "webp")
        is Format.IsoMedia -> {
            val mov = f.brand == "qt  "
            val video = Verdict(Kind.VIDEO, if (mov) "video/quicktime" else "video/mp4", if (mov) "mov" else "mp4")
            when {
                f.brand in heicBrands -> Verdict(Kind.PICTURE, "image/heic", "heic")
                hasVideo == true -> video
                hasAudio == true -> Verdict(Kind.AUDIO, "audio/mp4", "m4a")
                hasVideo == false && hasAudio == false -> null
                f.brand in audioBrands -> Verdict(Kind.AUDIO, "audio/mp4", "m4a") // tracks not read: the brand's word
                else -> video
            }
        }
        Format.Unknown -> {
            val mov = fileExtension.lowercase() == "mov"
            when {
                hasVideo == true -> Verdict(Kind.VIDEO, if (mov) "video/quicktime" else "video/mp4", if (mov) "mov" else "mp4")
                hasAudio == true -> Verdict(Kind.AUDIO, "audio/mp4", "m4a")
                else -> null
            }
        }
    }
}

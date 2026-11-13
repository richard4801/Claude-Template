package studio.muse.core.edit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Owner issues of 2026-11-12 on Android: a song that is raw AAC named .mp4 (ci_f99f93616ece), and another edit's Approve card (ci_e546642a4026). */
class EditAudioApprovalsTest {
    private fun bytes(vararg b: Int, pad: Int = 64) = ByteArray(maxOf(pad, b.size)) { i -> if (i < b.size) b[i].toByte() else 0 }
    private fun ascii(s: String) = s.toByteArray(Charsets.ISO_8859_1).map { it.toInt() and 0xFF }.toIntArray()
    private fun iso(brand: String) = bytes(0, 0, 0, 0x20, *ascii("ftyp"), *ascii(brand))

    @Test fun theFormatComesFromTheBytes() {
        assertEquals(MediaSniff.Format.Adts, MediaSniff.format(bytes(0xFF, 0xF1, 0x50, 0x80)))
        assertEquals(MediaSniff.Format.Adts, MediaSniff.format(bytes(0xFF, 0xF9, 0x50, 0x80)))
        assertEquals(MediaSniff.Format.Mp3, MediaSniff.format(bytes(0xFF, 0xFB, 0x90, 0x64)))
        assertEquals(MediaSniff.Format.Mp3, MediaSniff.format(bytes(*ascii("ID3"), 4, 0)))
        assertEquals(MediaSniff.Format.Wav, MediaSniff.format(bytes(*ascii("RIFF"), 0, 0, 0, 0, *ascii("WAVE"))))
        assertEquals(MediaSniff.Format.Webp, MediaSniff.format(bytes(*ascii("RIFF"), 0, 0, 0, 0, *ascii("WEBP"))))
        assertEquals(MediaSniff.Format.Aiff, MediaSniff.format(bytes(*ascii("FORM"), 0, 0, 0, 0, *ascii("AIFF"))))
        assertEquals(MediaSniff.Format.Flac, MediaSniff.format(bytes(*ascii("fLaC"))))
        assertEquals(MediaSniff.Format.Png, MediaSniff.format(bytes(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A)))
        assertEquals(MediaSniff.Format.Jpeg, MediaSniff.format(bytes(0xFF, 0xD8, 0xFF, 0xE0)))
        assertEquals(MediaSniff.Format.IsoMedia("isom"), MediaSniff.format(iso("isom")))
        assertEquals(MediaSniff.Format.Unknown, MediaSniff.format("just text".toByteArray()))
        assertEquals(MediaSniff.Format.Unknown, MediaSniff.format(ByteArray(0)))
    }

    @Test fun rawAacNamedMp4IsASong() {
        assertEquals(MediaSniff.Verdict(MediaSniff.Kind.AUDIO, "audio/aac", "aac"), MediaSniff.verdict(MediaSniff.format(bytes(0xFF, 0xF1, 0x50, 0x80)), "mp4"))
    }

    @Test fun anMp4IsDecidedByItsTracks() {
        val f = MediaSniff.format(iso("isom"))
        assertEquals(MediaSniff.Verdict(MediaSniff.Kind.AUDIO, "audio/mp4", "m4a"), MediaSniff.verdict(f, "mp4", hasVideo = false, hasAudio = true))
        assertEquals(MediaSniff.Verdict(MediaSniff.Kind.VIDEO, "video/mp4", "mp4"), MediaSniff.verdict(f, "mp4", hasVideo = true, hasAudio = true))
        assertEquals("video/quicktime", MediaSniff.verdict(MediaSniff.format(iso("qt  ")), "mov", hasVideo = true)?.contentType)
        assertNull(MediaSniff.verdict(f, "mp4", hasVideo = false, hasAudio = false))
        assertEquals(MediaSniff.Kind.AUDIO, MediaSniff.verdict(MediaSniff.format(iso("M4A ")), "mp4")?.kind)
        assertEquals(MediaSniff.Kind.PICTURE, MediaSniff.verdict(MediaSniff.format(iso("heic")), "mp4")?.kind)
    }

    @Test fun anUnreadableFileSaysWhyInOnePlainLine() {
        assertNull(MediaSniff.verdict(MediaSniff.Format.Unknown, "pdf"))
        assertNull("an .mp3 with no MPEG audio inside", MediaSniff.verdict(MediaSniff.Format.Unknown, "mp3"))
        assertNull("a name alone never makes a file usable (Mac run 617)", MediaSniff.verdict(MediaSniff.format("not a video".toByteArray()), "mp4"))
        assertNull(MediaSniff.verdict(MediaSniff.Format.Unknown, "mov", hasVideo = false, hasAudio = false))
        assertEquals("video/quicktime", MediaSniff.verdict(MediaSniff.Format.Unknown, "mov", hasVideo = true)?.contentType)
        assertEquals(MediaSniff.Format.IsoMedia("qt  "), MediaSniff.format(bytes(0, 0, 0, 8, *ascii("wide"))))
        assertEquals("This file has no video or sound MUSE can read.", MediaSniff.UNREADABLE)
        assertFalse(MediaSniff.UNREADABLE.contains("·"))
    }

    @Test fun theSameAnswersAsTheMac() {
        // MuseCore MediaSniff.swift's verdicts for the same inputs (keep the twins in step).
        assertEquals("audio/mpeg", MediaSniff.verdict(MediaSniff.Format.Mp3)?.contentType)
        assertEquals("audio/wav", MediaSniff.verdict(MediaSniff.Format.Wav)?.contentType)
        assertEquals("image/jpeg", MediaSniff.verdict(MediaSniff.Format.Jpeg)?.contentType)
    }

    private fun sp(session: String, take: String, id: String, created: Long, status: String = "waiting", label: String = "Remove background", usd: Double = 0.4) =
        SessionPending(session, take, id, label, usd, created, status)

    @Test fun everyEditsWaitingHelpersOldestFirst() {
        val list = EditApprovalList.of(listOf(sp("es_open", "tk_a", "pd_1", 20), sp("es_other", "tk_b", "pd_2", 10, label = "Captions", usd = 0.05),
            sp("es_other", "tk_b", "pd_3", 5, status = "running")))
        assertEquals(listOf("es_other/pd_2", "es_open/pd_1"), list.items.map { it.id })
        assertEquals("the open edit asks with its own sheet", listOf("es_other/pd_2"), list.except("es_open").map { it.id })
        assertEquals("Allow · $0.40", list.items.last().allowLabel)
        assertEquals("Allow · $0.05", list.items.first().allowLabel)
    }

    @Test fun liveEventsAddUpdateAndRemove() {
        var list = EditApprovalList()
        list = list.apply(sp("es_2", "tk_2", "pd_9", 3))
        assertEquals(listOf("es_2/pd_9"), list.items.map { it.id })
        list = list.apply(sp("es_2", "", "pd_9", 3, status = "approved"), takeIdKnown = false)
        assertTrue("answered elsewhere: gone", list.isEmpty())
        list = list.apply(sp("es_2", "tk_2", "pd_9", 3)).apply(sp("es_2", "", "pd_10", 4), takeIdKnown = false)
        assertEquals("tk_2", list.items.last().takeId)
        assertEquals(1, list.remove("es_2/pd_9").size)
    }

    @Test fun theCardNamesItsEdit() {
        assertEquals("Living room dance", EditApprovalList.editName("tk_1", " Living room dance "))
        assertEquals("New project", EditApprovalList.editName(BLANK_SOURCE, null))
        assertEquals("an edit", EditApprovalList.editName("tk_gone", null))
    }
}

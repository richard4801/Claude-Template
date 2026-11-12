package studio.muse.core.edit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** "New" in Edit (blank project, the server's and the Mac's rules): empty while editing, a clip needed to save. */
class BlankProjectTest {
    @Test fun aBlankProjectIsEmptyWhileEditingAndNeedsAClipToSave() {
        val p = blankProject()
        assertTrue(p.isBlank)
        assertEquals(BLANK_SOURCE, p.sourceTakeId)
        assertEquals(Canvas(1080, 1920, 30.0, "#000000"), p.canvas)
        assertNull(problemOf(p, draft = true))
        assertEquals("edits.tracks.0.items", problemOf(p)!!.field) // saving checks without draft
        // The same JSON as the server's blankProject().
        assertEquals(p, EditJson.parse(EditJson.encode(p)))
        // Draft only covers the blank marker: an ordinary project with an empty main track is still refused.
        assertNotNull(problemOf(p.copy(sourceTakeId = "t_1"), draft = true))
    }

    @Test fun withAClipItIsAnOrdinaryProject() {
        val p = blankProject()
        val withClip = p.copy(assets = listOf(Asset("a1", AssetKind.VIDEO, take = "t_1", durationSec = 4.0, width = 1080, height = 1920, hasAudio = true)),
            tracks = listOf(Track("main", TrackKind.MAIN, items = listOf(VideoClip("c1", "a1", 0.0, 4.0, 1.0)))))
        assertNull(problemOf(withClip))
        assertEquals(4.0, durationSec(withClip), 1e-9)
    }
}

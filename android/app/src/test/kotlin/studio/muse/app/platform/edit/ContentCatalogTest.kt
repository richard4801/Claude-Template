package studio.muse.app.platform.edit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import studio.muse.app.ui.screens.edit.contentSearch
import studio.muse.core.edit.Font
import java.io.File

/** The app reads the server's real catalog (server/api/assets/content/catalog.json) the way the Edit suite uses it. */
class ContentCatalogTest {
    private val cat = ContentCatalog.parse(File("../../server/api/assets/content/catalog.json").readText())

    @Test fun packsItemsAndRefs() {
        assertEquals(listOf("twemoji", "uisfx", "kenney", "fonts", "muse-looks", "muse-captions", "muse-transitions"), cat.packs.map { it.id })
        val grin = cat.item("content:twemoji/1f600")!!
        assertEquals("grinning face", grin.name); assertEquals("stickers/twemoji/1f600.png", grin.file); assertEquals(160, grin.width)
        assertEquals("content:uisfx/glass-notification", cat.item("content:uisfx/glass-notification")!!.ref)
        assertTrue(cat.item("content:uisfx/glass-notification")!!.durationSec!! > 0)
        assertNull(cat.item("content:twemoji/nope")); assertNull(cat.item("music_upbeat_01"))
    }

    @Test fun fontFilesPerWeightIncludingTheExceptions() {
        assertEquals("fonts/inter_700.ttf", cat.fontPath(Font.INTER, 700))
        assertEquals("fonts/jetbrainsMono_900.ttf", cat.fontPath(Font.JETBRAINS_MONO, 900))
        assertEquals("fonts/caveat_400.ttf", cat.fontPath(Font.CAVEAT, 500))
        assertNull(cat.fontPath(Font.SANS, 400))
        // Every font file the catalog names exists in the server's content dir.
        for (f in Font.entries.filter { it.isContent }) for (w in listOf(400, 700, 900)) assertTrue("$f $w", File("../../server/api/assets/content/${cat.fontPath(f, w)}").exists())
    }

    @Test fun searchByNameTagsAndCategory() {
        val hearts = contentSearch(cat, "stickers", "red heart", null)
        assertTrue(hearts.any { it.id == "2764" })
        assertTrue(contentSearch(cat, "stickers", "", "flags").all { it.category == "flags" })
        assertTrue(contentSearch(cat, "sfx", "success", "cinematic").isNotEmpty())
        assertTrue(contentSearch(cat, "stickers", "zzzqqq", null).isEmpty())
    }
}

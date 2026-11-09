package studio.muse.core.edit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File

class FontFileTest {
    /** The server's bundled Figtree (OFL), also what server/api/test/editor-fonts.test.ts names. */
    private val figtree = File("../../server/api/assets/fonts/figtree_700.ttf").readBytes()

    @Test fun namesATrueTypeFontLikeTheServer() {
        assertEquals("Figtree Bold", FontFile.name(figtree))
        assertEquals("DM Mono Regular", FontFile.name(File("../../server/api/assets/fonts/dm_mono_400.ttf").readBytes()))
    }

    @Test fun refusesOtherFiles() {
        assertNull(FontFile.name("wOFF0000000000000000".toByteArray()))
        assertNull(FontFile.name("hello".toByteArray()))
        assertEquals("Font", FontFile.name(ByteArray(12).also { it[1] = 1 }))
    }

    @Test fun ownFontContract() {
        val base = fromV1(EditListV1(sourceTakeId = "take_f", sourceDurationSec = 6.0, segments = listOf(V1Segment(0.0, 6.0, 1.0)), mute = false), SourceSize(1080, 1920, 30.0, true))
        val p = base.copy(
            assets = base.assets + Asset("fnt", AssetKind.FONT, upload = "up_font", name = "Figtree Bold"),
            tracks = base.tracks + Track("txt", TrackKind.TEXT, items = listOf(TextItem("t1", 0.0, 2.0, "Hello", Presets.HOOKS[0].style.copy(fontAsset = "fnt")))),
        )
        assertNull(problemOf(p))
        // Round trip keeps the asset's name and the style's fontAsset.
        assertEquals(p, EditJson.parse(EditJson.encode(p)))
        // A kit keeps the fallback family only.
        assertNull(kitOf(p).textStyle!!.fontAsset)
    }
}

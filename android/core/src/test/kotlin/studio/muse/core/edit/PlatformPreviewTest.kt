package studio.muse.core.edit

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Edit's platform preview (plans/edit-platform-preview.md): the same answers as the Mac and the server. */
class PlatformPreviewTest {
    private fun project(name: String): EditProject =
        EditJson.parse(Fixtures.load("projects.json").arr.first { it.obj["name"]!!.str == name }.obj["project"]!!)

    private fun withCaptionsAt(p: EditProject, y: Double, wrap: Double = .6) = p.copy(tracks = p.tracks.map { t ->
        val ct = t.caption ?: return@map t
        t.copy(caption = ct.copy(style = ct.style.copy(y = y, text = ct.style.text.copy(maxWidthPct = wrap))))
    })

    @Test fun viewsFollowTheCanvasShape() {
        assertEquals(listOf(PreviewView.CLEAN, PreviewView.TIKTOK, PreviewView.REELS, PreviewView.SHORTS, PreviewView.FACEBOOK), PreviewView.options(1080, 1920))
        assertEquals(listOf(PreviewView.CLEAN, PreviewView.YOUTUBE, PreviewView.FACEBOOK), PreviewView.options(1920, 1080))
        assertEquals(EditPreview(PreviewView.CLEAN, false), EditPreview(PreviewView.TIKTOK, false).resolved(1920, 1080))
    }

    @Test fun theRedBoxWorksInEveryView() {
        assertEquals(PreviewLayouts.DEFAULTS.zone(PreviewView.TIKTOK), EditSafeBox.zone(EditPreview(PreviewView.TIKTOK), 1080, 1920))
        val all = EditSafeBox.zone(EditPreview(), 1080, 1920)!!
        assertEquals(.11, all.top, 1e-9); assertEquals(.30, all.bottom, 1e-9); assertEquals(.17, all.right, 1e-9)
        assertEquals(PreviewLayouts.DEFAULTS.landscapeZone(PreviewView.YOUTUBE), EditSafeBox.zone(EditPreview(PreviewView.YOUTUBE), 1920, 1080))
        assertEquals(EditSafeBox.TITLE_SAFE, EditSafeBox.zone(EditPreview(), 1920, 1080))
        assertNull(EditSafeBox.zone(EditPreview(PreviewView.TIKTOK, false), 1080, 1920))
        assertEquals("TikTok's caption and buttons", EditSafeBox.covers(EditPreview(PreviewView.TIKTOK), 1080, 1920))
    }

    @Test fun theServersTableGoesOverTheDefaults() {
        val o = Json.parseToJsonElement("""{"zones":{"tiktok":{"top":0.12,"bottom":0.3,"left":0.02,"right":0.18},"bad":{"top":1}},"landscape":{"youtube":{"top":0.2,"bottom":0.2,"left":0,"right":0}}}""").jsonObject
        val l = PreviewLayouts.parse(o)
        assertEquals(.12, l.zone(PreviewView.TIKTOK)!!.top, 1e-9)
        assertEquals(PreviewLayouts.DEFAULTS.zone(PreviewView.REELS), l.zone(PreviewView.REELS))
        assertEquals(.2, l.landscapeZone(PreviewView.YOUTUBE)!!.top, 1e-9)
        assertEquals(PreviewLayouts.DEFAULTS.note, l.note)
    }

    @Test fun captionsLowOnTheFrameAreFlaggedAndMovedIn() {
        val z = PreviewLayouts.DEFAULTS.zone(PreviewView.TIKTOK)!!
        val low = withCaptionsAt(project("captions pop 2"), .85)
        val found = EditSafeCheck.issues(low, z)
        assertEquals(listOf("bottom"), found.single().edges)
        assertTrue(found.single().captions && found.single().endSec > found.single().startSec)
        assertTrue(EditSafeCheck.line(found, "TikTok's caption and buttons")!!.startsWith("Captions sit under TikTok's caption and buttons ("))
        assertTrue(EditSafeCheck.issues(withCaptionsAt(project("captions pop 2"), .5, .95), z).single().edges.contains("right"))
        val fixed = EditSafeCheck.fixed(low, z)!!
        assertTrue(EditSafeCheck.issues(fixed, z).isEmpty())
        assertNull(problemOf(fixed))
        assertNull(EditSafeCheck.fixed(fixed, z))
    }

    @Test fun textUnderTheRailIsFlaggedAndNudgedIn() {
        val z = PreviewLayouts.DEFAULTS.zone(PreviewView.TIKTOK)!!
        val p = project("pip text image look")
        val moved = p.copy(tracks = p.tracks.map { t -> if (t.kind != TrackKind.TEXT) t else t.copy(items = t.items.map { (it as TextItem).copy(transform = Transform(x = .92, y = .5)) }) })
        val issue = EditSafeCheck.issues(moved, z).first { !it.captions }
        assertTrue("right" in issue.edges)
        val fixed = EditSafeCheck.fixed(moved, z)
        assertNotNull(fixed)
        assertTrue(EditSafeCheck.issues(fixed!!, z).none { !it.captions })
    }

    @Test fun theChoiceIsRememberedPerProject() {
        var prefs = EditPreviewPrefs()
        assertEquals(EditPreview(), prefs.choice("a"))
        prefs = prefs.set(EditPreview(PreviewView.TIKTOK), "a").set(EditPreview(PreviewView.REELS, false), "b")
        assertEquals(PreviewView.TIKTOK, prefs.choice("a").view)
        assertEquals(EditPreview(PreviewView.REELS, false), prefs.choice("new"))
        repeat(EditPreviewPrefs.KEPT + 5) { prefs = prefs.set(EditPreview(PreviewView.SHORTS), "t$it") }
        assertTrue(prefs.byProject.size <= EditPreviewPrefs.KEPT)
        assertEquals(prefs, EditPreviewPrefs.decode(prefs.encode()))
        assertEquals(EditPreviewPrefs(), EditPreviewPrefs.decode("not json"))
    }
}

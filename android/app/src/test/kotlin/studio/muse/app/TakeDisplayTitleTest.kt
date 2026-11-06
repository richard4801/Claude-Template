package studio.muse.app

import org.junit.Assert.assertEquals
import org.junit.Test
import studio.muse.app.data.Take
import studio.muse.app.data.takeDisplayTitle
import studio.muse.app.ui.Routes
import studio.muse.app.ui.TAB_ITEMS

/** Photoshoot is the Photo tool now: old takes keep their stored titles but read "Photo"; the bottom bar has five tabs, no "+". */
class TakeDisplayTitleTest {
    @Test fun oldShootTitlesReadPhoto() {
        assertEquals("Photo · crystal 1", takeDisplayTitle("Shoot · crystal 1"))
        assertEquals("Photo · Café window", takeDisplayTitle("Photoshoot · Café window"))
        assertEquals("Photo", takeDisplayTitle("Shoot"))
        assertEquals("Photo", takeDisplayTitle("Photoshoot"))
        assertEquals("Shooting star · 1", takeDisplayTitle("Shooting star · 1"))
        assertEquals("Kick test", takeDisplayTitle("Kick test"))
        val t = Take(id = "t", kind = "shot", title = "Shoot · Beach", label = "Shoot")
        assertEquals("Photo · Beach" to "Photo", t.shownTitle to t.shownLabel)
    }

    @Test fun bottomBarIsFiveTabsInTheApprovedOrder() {
        assertEquals(listOf("Home", "Suite", "Library", "Queue", "You"), TAB_ITEMS.map { it.label })
        assertEquals(listOf("house", "video-camera", "squares-four", "stack", "user"), TAB_ITEMS.map { it.icon })
        assertEquals(listOf(Routes.HOME, Routes.SUITE, Routes.GALLERY, Routes.QUEUE, Routes.SETTINGS), TAB_ITEMS.map { it.route })
        assertEquals(Routes.TABS, TAB_ITEMS.map { it.route }.toSet())
    }
}

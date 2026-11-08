package studio.muse.core.edit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SharedLinkTest {
    @Test fun `finds the link in a shared text`() {
        assertEquals("https://vm.tiktok.com/ZMabc123/", SharedLink.first("Check this out https://vm.tiktok.com/ZMabc123/ #fyp"))
        assertEquals("https://www.instagram.com/reel/Cx1/?igsh=xyz", SharedLink.first("https://www.instagram.com/reel/Cx1/?igsh=xyz"))
        assertEquals("https://youtube.com/shorts/abc", SharedLink.first("Watch (https://youtube.com/shorts/abc)."))
        assertNull(SharedLink.first("no link here"))
        assertNull(SharedLink.first(null))
    }

    @Test fun `names the reference by where it came from`() {
        assertEquals("TikTok link", SharedLink.name("https://vm.tiktok.com/ZM1/"))
        assertEquals("Instagram link", SharedLink.name("https://www.instagram.com/reel/x"))
        assertEquals("YouTube link", SharedLink.name("https://youtu.be/x"))
        assertEquals("Shared link", SharedLink.name("https://vimeo.com/1"))
    }
}
